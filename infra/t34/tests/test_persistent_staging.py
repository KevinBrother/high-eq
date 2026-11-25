"""Only in-memory tests; never contact Docker."""
import contextlib
import copy
import io
import json
from pathlib import Path
import re
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, call, patch

import isolated_staging_lab as guard
import isolated_staging as proof
import persistent_staging_accept as cli
from test_staging import (ADMISSION_CURRENT, ADMISSION_NEXT, ADMISSION_PREVIOUS,
                          composition_for, state as example_state)
from approval_fixture import write_static_approval


RUN = 'd' * 24
ENGINE_HOST = 'unix:///tmp/t34-dedicated-docker.sock'
ENGINE_ID = 'e' * 64


class StrictStagingDaemon:
    """Strict in-memory Docker daemon for the persistent staging failure path."""

    STORAGE = {'db', 'cache', 'ledger', 'restored', 'coldcache'}
    SERVING = {'api', 'web', 'monitor', 'backup', 'alert-sink'}

    def __init__(self, box, healthy_state, *, reported_engine_id=None,
                 project_label_drift=None, container_id_drift_on_stop=False,
                 container_id_drift_after_ownership=False):
        self.box = box
        self.healthy = copy.deepcopy(healthy_state)
        self.reported_engine_id = reported_engine_id or box.engine_id
        self.project_label_drift = project_label_drift
        self.container_id_drift_on_stop = container_id_drift_on_stop
        self.container_id_drift_after_ownership = container_id_drift_after_ownership
        self.state_raw = (json.dumps(healthy_state, sort_keys=True, separators=(',', ':')) + '\n').encode()
        self.state_inode = 4242
        self.state_writes = []
        self.state_helper_ids = set()
        self.state_helper_removals = []
        self.calls = []
        self.stopped = set()
        self.vault_reads = 0
        self.vault_reads_after_stop = 0
        self.id_drifted = False

        self.containers = {}
        for index, service in enumerate(('api', 'web', 'monitor', 'backup', 'alert-sink',
                                         'db', 'cache', 'ledger', 'restored', 'coldcache'), 1):
            labels = {guard.OWNER: box.token, guard.PROJECT: box.name,
                      'com.docker.compose.service': service}
            self.containers[service] = {
                'id': format(index, '064x'),
                'name': box.name + '-' + service + '-1',
                'service': service,
                'running': True,
                'labels': labels,
                'image': 'sha256:' + format(index + 20, '064x'),
            }
        network_labels = {guard.OWNER: box.token, guard.PROJECT: box.name}
        if project_label_drift == 'network':
            network_labels[guard.OWNER] = 'foreign-owner'
        self.networks = {
            'default': {'id': format(101, '064x'), 'name': box.name + '_default',
                        'labels': network_labels},
        }
        vault_labels = {guard.OWNER: box.token, guard.PROJECT: box.name}
        if project_label_drift == 'vault':
            vault_labels[guard.OWNER] = 'foreign-owner'
        self.volumes = {
            'state': {
                'id': box.volume,
                'name': box.volume,
                'labels': {guard.OWNER: box.token,
                           guard.staging.OWNER_LABEL: box.name,
                           guard.staging.ROLE_LABEL: guard.staging.STATE_ROLE},
            },
            'vault': {'id': box.name + '_vault', 'name': box.name + '_vault',
                      'labels': vault_labels},
        }

    @staticmethod
    def _tail_compose(args):
        index = args.index('-p') + 2
        while index + 1 < len(args) and args[index] == '-f':
            index += 2
        return tuple(args[index:])

    def _records(self, kind):
        if kind == 'container':
            return list(self.containers.values())
        if kind == 'network':
            return list(self.networks.values())
        if kind == 'volume':
            return list(self.volumes.values())
        if kind == 'image':
            return []
        raise AssertionError('unexpected resource kind: ' + repr(kind))

    def _rows(self, kind, filter_value):
        records = self._records(kind)
        owner_prefix = 'label=' + guard.OWNER + '='
        project_prefix = 'label=' + guard.PROJECT + '='
        if filter_value.startswith(owner_prefix):
            wanted = filter_value[len(owner_prefix):]
            records = [item for item in records if item['labels'].get(guard.OWNER) == wanted]
        elif filter_value.startswith(project_prefix):
            wanted = filter_value[len(project_prefix):]
            records = [item for item in records if item['labels'].get(guard.PROJECT) == wanted]
        elif filter_value.startswith('name='):
            wanted = filter_value[len('name='):]
            records = [item for item in records if item['name'].startswith(wanted)]
        elif filter_value.startswith('reference='):
            return []
        else:
            raise AssertionError('unexpected daemon-side filter: ' + repr(filter_value))
        if kind == 'volume':
            return [item['name'] + '\t' + item['name'] for item in records]
        return [item['id'] + '\t' + item['name'] for item in records]

    def _find(self, kind, reference):
        matches = [item for item in self._records(kind)
                   if item['id'].startswith(reference) or item['name'] == reference or
                   item.get('previous_id') == reference]
        if len(matches) != 1:
            raise AssertionError('unknown or ambiguous %s: %r' % (kind, reference))
        return matches[0]

    def _inspect(self, kind, template, reference):
        if (self.container_id_drift_after_ownership and not self.id_drifted and
                kind == 'network' and template == '{{json .Labels}}'):
            api = self.containers['api']
            api['previous_id'] = api['id']
            api['id'] = 'f' * 64
            self.id_drifted = True
        item = self._find(kind, reference)
        if kind == 'container':
            if template == '{{.Id}} {{.Name}} {{json .Config.Labels}}':
                return (item['id'] + ' /' + item['name'] + ' ' +
                        json.dumps(item['labels'], separators=(',', ':'))).encode()
            if template == '{{json .Mounts}}':
                return b'[]'
            if template == '{{.Image}}':
                return item['image'].encode()
        elif kind == 'network' and template == '{{json .Labels}}':
            return json.dumps(item['labels'], separators=(',', ':')).encode()
        elif kind == 'volume':
            if template == '{{json .Labels}}':
                return json.dumps(item['labels'], separators=(',', ':')).encode()
            if template == '{{.Driver}} {{json .Options}}':
                return b'local null'
        raise AssertionError('unexpected %s inspect: %r' % (kind, template))

    def _inventory(self):
        return json.dumps({
            'seal': self.healthy['marker']['ledger_identity'],
            'deadlines': self.healthy['ledger_deadlines'],
        }, sort_keys=True, separators=(',', ':')).encode()

    def _sql(self, service, query):
        query = ' '.join(query.lower().split())
        if 'schema_migrations' in query:
            return (self.healthy['schema_version'] + ':false').encode()
        if 'ledger_binding' in query:
            return self.healthy['marker']['ledger_identity'].encode()
        if 'pg_control_system' in query:
            return b'7000000000000000000'
        if 'to_jsonb(t)::text' in query:
            return b'{"marker":"retained"}'
        if 'from users' in query:
            return b'0' if self.healthy['marker']['user_b'] in query else b'1'
        if 'from signal_windows' in query:
            return b'1'
        if 'from review_tombstones' in query:
            return b'1'
        if 'from pending_erasure' in query:
            return b'0'
        raise AssertionError('unexpected SQL on %s: %r' % (service, query))

    def _config(self, args):
        names = {Path(value).name for value in args if isinstance(value, (str, Path))}
        overlay = 'production.yml' if 'production.yml' in names else 'test.yml'
        preview = 'proof-test.yml-1.json' in names
        labels = {guard.OWNER: self.box.token}
        services = {}
        for service in guard.BASE_SERVICES if overlay == 'production.yml' else guard.TEST_SERVICES:
            spec = {'image': guard.PG, 'labels': dict(labels)}
            if service in guard.MASKS[overlay]:
                spec['volumes'] = [{'type': 'tmpfs', 'target': guard.MASKS[overlay][service]}]
            services[service] = spec
        if preview:
            services['web']['ports'] = [{
                'host_ip': '127.0.0.1', 'target': 8080, 'protocol': 'tcp', 'published': '',
            }]
            services['web']['networks'] = {'default': None, 'preview': None}
        else:
            services['web']['networks'] = {'default': None}
        networks = {
            name: {'name': self.box.name + '_' + name, 'labels': dict(labels),
                   'internal': True, 'driver': 'bridge'}
            for name in guard.NETWORKS
        }
        volumes = {
            name: {'name': self.box.name + '_' + name, 'labels': dict(labels), 'driver': 'local'}
            for name in guard.VOLUMES
        }
        return json.dumps({'name': self.box.name, 'services': services,
                           'networks': networks, 'volumes': volumes}).encode()

    def _compose(self, args, kw):
        tail = self._tail_compose(args)
        if not tail:
            raise AssertionError('empty Compose command')
        if tail == ('--profile', '*', 'config', '--format', 'json'):
            return self._config(args)
        if tail[0] == 'run':
            inventory = ('run', '--rm', '--no-deps', '-T', '--entrypoint',
                         '/ops/gate.sh', 'permit', 'inventory')
            probe = ('run', '--rm', '--no-deps', '-T', '--entrypoint',
                     '/ops/gate.sh', 'permit', 'probe-missing')
            if tail == inventory:
                return self._inventory()
            if len(tail) == len(probe) + 1 and tail[:-1] == probe and guard.UUID.fullmatch(tail[-1]):
                if kw.get('check') is not False:
                    raise AssertionError('missing-root probe must be checked by the caller')
                return SimpleNamespace(returncode=1,
                                       stdout=b'recovery_gate_refused_missing_root', stderr=b'')
            raise AssertionError('unexpected Compose job: ' + repr(tail))
        if tail[0] == 'exec':
            service, command = tail[2], tail[3]
            if command == 'psql':
                return self._sql(service, (kw.get('input') or b'').decode())
            if service == 'ledger' and command == 'redis-cli' and 'PEXPIRETIME' in tail:
                root = tail[-1][len('deleted:'):]
                return str(self.healthy['ledger_deadlines'][root]).encode()
        raise AssertionError('unexpected Compose command: ' + repr(tail))

    @staticmethod
    def _single_option(args, option):
        values = [args[index + 1] for index, value in enumerate(args[:-1]) if value == option]
        if len(values) != 1:
            raise AssertionError(f'state helper requires one {option}: ' + repr(args))
        return values[0]

    def _state_read_helper(self, args, kw):
        volume_mount = self.box.volume + ':/state:ro'
        required = {'--rm', '--network', 'none', '--read-only', '--pull=never', '-v',
                    '--entrypoint', 'sh', guard.PG, '-c', '--name',
                    self.box.name + '-state-helper', guard.OWNER + '=' + self.box.token,
                    '--mount', 'type=tmpfs,dst=' + guard.PG_DATA}
        if not required <= set(args):
            raise AssertionError('unsafe state read command: ' + repr(args))
        if self._single_option(args, '-v') != volume_mount:
            raise AssertionError('state read helper mounted an unexpected path')
        if self._single_option(args, '--mount') != 'type=tmpfs,dst=' + guard.PG_DATA:
            raise AssertionError('state read helper mounted an unexpected volume')
        if kw:
            raise AssertionError('state read helper command options changed')
        script = args[-1]
        if script.startswith('set -eu; stat -c "%i'):
            digest = proof.sha256(self.state_raw).hexdigest()
            return (f'{self.state_inode} 2026-11-23 00:00:00.000000000 +0000 600\n'
                    f'{digest}').encode()
        return self.state_raw

    def _state_create_helper(self, args, kw):
        writer = 'a' * 64
        required = {'-i', '--network', 'none', '--pull=never', '-v',
                    '--entrypoint', 'sh', guard.PG, '-c', '--name',
                    self.box.name + '-state-helper', guard.OWNER + '=' + self.box.token,
                    '--mount', 'type=tmpfs,dst=' + guard.PG_DATA}
        if not required <= set(args) or '--read-only' in args or '--rm' in args:
            raise AssertionError('unsafe state create command: ' + repr(args))
        if self._single_option(args, '-v') != self.box.volume + ':/state':
            raise AssertionError('state create helper mounted an unexpected path')
        if self._single_option(args, '--mount') != 'type=tmpfs,dst=' + guard.PG_DATA:
            raise AssertionError('state create helper mounted an unexpected volume')
        if set(kw) != {'timeout'} or kw['timeout'] != 30:
            raise AssertionError('state create helper timeout changed')
        if any(item['name'] == self.box.name + '-state-helper'
               for item in self.containers.values()):
            raise AssertionError('state helper name already exists')
        self.containers['state-helper'] = {
            'id': writer,
            'name': self.box.name + '-state-helper',
            'service': 'state-helper',
            'running': False,
            'labels': {guard.OWNER: self.box.token},
            'image': 'sha256:' + 'a' * 64,
        }
        self.state_helper_ids.add(writer)
        return writer.encode()

    def _state_start_helper(self, args, kw):
        writer = args[-1]
        payload = kw.get('input')
        if args[:3] != ('start', '-a', '-i') or writer not in self.state_helper_ids:
            raise AssertionError('state start target changed: ' + repr(args))
        if set(kw) != {'input', 'timeout'} or kw['timeout'] != 120:
            raise AssertionError('state start options changed')
        if not isinstance(payload, bytes) or not payload:
            raise AssertionError('state start payload missing')
        self.containers['state-helper']['running'] = True
        self.state_writes.append(payload)
        self.state_inode += 1
        self.state_raw = payload
        self.containers['state-helper']['running'] = False
        return b''

    def _state_remove_helper(self, args, kw):
        writer = args[-1]
        if args[:2] != ('rm', '-f') or writer not in self.state_helper_ids:
            raise AssertionError('state remove target changed: ' + repr(args))
        if set(kw) != {'timeout'} or kw['timeout'] != 30:
            raise AssertionError('state remove options changed')
        self.containers.pop('state-helper', None)
        self.state_helper_removals.append(writer)
        return b''

    def _state_probe_helper(self, args, kw):
        writer = args[-1][len('id='):]
        if args[:3] != ('ps', '-aq', '--filter') or writer not in self.state_helper_ids:
            raise AssertionError('state probe target changed: ' + repr(args))
        if set(kw) != {'timeout'} or kw['timeout'] != 30:
            raise AssertionError('state probe options changed')
        present = any(item['id'] == writer for item in self.containers.values())
        return writer.encode() if present else b''

    def _vault_helper(self, args):
        vault = self.box.name + '_vault'
        required = {
            '--network', 'none', '--read-only', '--pull=never',
            'type=volume,src=' + vault + ',dst=/vault,readonly',
        }
        if not required <= set(args):
            raise AssertionError('unsafe vault evidence command: ' + repr(args))
        self.vault_reads += 1
        if 'backup' in self.stopped:
            self.vault_reads_after_stop += 1
        return (b'snap-a ' + self.healthy['business_dump_sha256'].encode() + b' ' +
                b'b' * 64 + b' ' + b'c' * 64 + b'\n')

    def __call__(self, *args, **kw):
        self.calls.append((args, kw.get('check')))
        if args == ('info', '--format', '{{.ID}}\t{{.OSType}}'):
            return (self.reported_engine_id + '\tlinux').encode()
        if args == ('info', '--format', '{{.OSType}}'):
            return b'linux'
        if args[0] in guard.FORMATS and len(args) > 1 and args[1] == 'ls':
            if '--filter' not in args:
                raise AssertionError('unfiltered resource enumeration refused')
            return '\n'.join(self._rows(args[0], args[args.index('--filter') + 1])).encode()
        if args[0] in ('container', 'network', 'volume') and args[1] == 'inspect':
            return self._inspect(args[0], args[3], args[4])
        if args[0] == 'ps' and len(args) == 4 and args[1:3] == ('-aq', '--filter'):
            return self._state_probe_helper(args, kw)
        if args[0] == 'ps':
            return '\n'.join(item['id'] + ' ' + item['service']
                             for item in self.containers.values() if item['running']).encode()
        if args[0] == 'stop':
            identifiers = [value for value in args[1:] if re.fullmatch(r'[0-9a-f]{12,64}', value)]
            for identifier in identifiers:
                for item in self.containers.values():
                    if item['id'].startswith(identifier):
                        item['running'] = False
                        self.stopped.add(item['service'])
            if self.container_id_drift_on_stop and not self.id_drifted:
                self.containers['web']['id'] = 'f' * 64
                self.id_drifted = True
            return b''
        if args[0] == 'run':
            if any(value == 'type=volume,src=' + self.box.name + '_vault,dst=/vault,readonly'
                   for value in args):
                return self._vault_helper(args)
            return self._state_read_helper(args, kw)
        if args[0] == 'create':
            return self._state_create_helper(args, kw)
        if args[0] == 'start':
            return self._state_start_helper(args, kw)
        if args[0] == 'rm':
            return self._state_remove_helper(args, kw)
        if args[0] == 'compose':
            return self._compose(args, kw)
        raise AssertionError('unexpected Docker command: ' + repr(args))

    def removal_commands(self):
        result = []
        for args, _ in self.calls:
            if (args and args[0] == 'rm' and len(args) == 3 and args[1] == '-f' and
                    args[2] in self.state_helper_ids):
                continue
            if args and (args[0] == 'rm' or
                         (args[0] in ('container', 'network', 'volume', 'image') and 'rm' in args)):
                result.append(args)
            elif args and args[0] == 'compose':
                tail = self._tail_compose(args)
                if tail and (tail[0] in ('down',) or tail[0] == 'rm'):
                    result.append(args)
        return result

    def compose_exec_services(self):
        result = []
        for args, _ in self.calls:
            if args and args[0] == 'compose':
                tail = self._tail_compose(args)
                if tail[:2] == ('exec', '-T'):
                    result.append(tail[2])
        return result


def strict_stage(work, state, **daemon_options):
    """Return an armed boundary whose every Docker interaction stays in memory."""
    healthy = copy.deepcopy(state)
    box = guard.IsolatedLab(work, (work,), RUN, ENGINE_HOST, ENGINE_ID)
    healthy['installation'] = box.name
    box.armed = True
    # Config rendering is exercised by the Compose-source tests. Prime both
    # overlays used by the failure path so this test reaches real job commands.
    for overlay, preview in (('test.yml', False), ('test.yml', True)):
        box._configs.add((overlay, preview, tuple(sorted(box.env.items()))))
    daemon = StrictStagingDaemon(box, healthy, **daemon_options)
    box._docker = Mock(side_effect=daemon)
    return box, daemon, healthy


class ExecuteCleanupTests(unittest.TestCase):
    def invoke(self, proof_effect, clean_effect=None):
        first = SimpleNamespace(source=Path('/synthetic/first'), prior=Path('/synthetic/prior'),
                                revision='a' * 40, previous='b' * 40)
        box = Mock(armed=True)
        box.clean.side_effect = clean_effect
        schema = 'c' * 64
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as tmp, contextlib.ExitStack() as stack:
            approvals = write_static_approval(Path(tmp) / 'approvals.json')
            stack.enter_context(patch.dict(cli.os.environ, {
                cli.ALLOW: '1', cli.RUN_ID_ENV: RUN,
                guard.ENGINE_HOST_ENV: ENGINE_HOST, guard.ENGINE_ID_ENV: ENGINE_ID,
                cli.release_approval.APPROVALS_ENV: str(approvals),
            }, clear=True))
            stack.enter_context(patch.object(cli.inputs, '_git', return_value='/synthetic/repo'))
            stack.enter_context(patch.object(cli, 'materialize', return_value=first))
            stack.enter_context(patch.object(cli.release, 'validate_release',
                                             side_effect=[({}, schema), ({}, schema)]))
            stack.enter_context(patch.object(cli, 'IsolatedLab', return_value=box))
            stack.enter_context(patch.object(cli, 'run_proof', side_effect=proof_effect))
            stack.enter_context(contextlib.redirect_stdout(output))
            stack.enter_context(contextlib.redirect_stderr(output))
            status = cli.main(['a' * 40, '--previous', 'b' * 40])
        return status, box, output.getvalue()

    @staticmethod
    def fail_proof(*args):
        args[-1].stage = 'update'
        raise RuntimeError('raw-secret')

    def test_original_failure_stage_survives_successful_cleanup(self):
        status, box, output = self.invoke(self.fail_proof)
        self.assertEqual(status, 1)
        box.clean.assert_called_once_with()
        self.assertIn('PASS cleanup\n', output)
        self.assertIn('FAIL update RuntimeError\n', output)
        self.assertNotIn('FAIL cleanup', output)
        self.assertNotIn('raw-secret', output)

    def test_original_failure_wins_when_cleanup_also_fails(self):
        status, box, output = self.invoke(self.fail_proof, ValueError('cleanup-secret'))
        self.assertEqual(status, 1)
        box.clean.assert_called_once_with()
        self.assertIn('FAIL cleanup ValueError\n', output)
        self.assertIn('FAIL update RuntimeError\n', output)
        self.assertNotIn('PASS cleanup', output)
        self.assertNotIn('raw-secret', output)
        self.assertNotIn('cleanup-secret', output)

    def test_cleanup_failure_is_reported_when_no_prior_failure_exists(self):
        status, box, output = self.invoke(None, OSError('cleanup-secret'))
        self.assertEqual(status, 1)
        box.clean.assert_called_once_with()
        self.assertIn('FAIL cleanup OSError\n', output)
        self.assertNotIn('PASS cleanup', output)
        self.assertNotIn('cleanup-secret', output)

    def test_missing_engine_refuses_before_git_or_docker_access(self):
        args = SimpleNamespace(revision='a' * 40, candidate_tree=None,
                               previous='b' * 40, update_revision=None)
        with patch.dict(cli.os.environ, {cli.ALLOW: '1'}, clear=True), \
                patch.object(cli.inputs, '_git') as git, \
                patch.object(cli, 'IsolatedLab') as isolated:
            with self.assertRaises(cli.SafetyError):
                cli.execute(args, RUN, Mock())
        git.assert_not_called()
        isolated.assert_not_called()


class ProofTests(unittest.TestCase):
    def test_receipt_is_required_and_address_is_random_loopback_shape(self):
        lab = Mock(volume='volume')
        good = dict(result='synthetic-pass', lifecycle='updated', mode='ci-staging',
                    state_volume='volume', schema_digest='schema', before_revision='a',
                    after_revision='b', storage_verified=True, production='blocked',
                    release={'revision': 'b'}, previous_release={'revision': 'a'},
                    rollback={'attempted': False, 'succeeded': None, 'revision': 'a',
                              'release': {'revision': 'a'}})
        proof.check_receipt(good, lab, 'updated', 'schema', 'a', 'b', '127.0.0.1:49153')
        for address in ('0.0.0.0:49153', '127.0.0.1:0', '127.0.0.1:65536', 'http://127.0.0.1:123'):
            with self.assertRaises(proof.ProofError):
                proof.check_receipt(good, lab, 'updated', 'schema', 'a', 'b', address)
        with self.assertRaises(proof.ProofError):
            proof.check_receipt(dict(good, lifecycle='initialized'), lab, 'updated',
                                'schema', 'a', 'b', '127.0.0.1:49153')
        for broken in (dict(good, release=None), dict(good, previous_release=None),
                       dict(good, rollback=dict(good['rollback'], release={'revision': 'b'}))):
            with self.assertRaises(proof.ProofError):
                proof.check_receipt(broken, lab, 'updated', 'schema', 'a', 'b',
                                    '127.0.0.1:49153')

    def test_initialized_receipt_rolls_back_to_previous_release(self):
        lab = Mock(volume='volume')
        good = dict(result='synthetic-pass', lifecycle='initialized', mode='ci-staging',
                    state_volume='volume', schema_digest='schema', before_revision=None,
                    after_revision='b', storage_verified=True, production='blocked',
                    release={'revision': 'b'}, previous_release={'revision': 'prior'},
                    rollback={'attempted': False, 'succeeded': None, 'revision': None})
        proof.check_receipt(good, lab, 'initialized', 'schema', None, 'b',
                            '127.0.0.1:49153')
        with self.assertRaises(proof.ProofError):
            proof.check_receipt(dict(good, release=None), lab, 'initialized',
                                'schema', None, 'b', '127.0.0.1:49153')
        with self.assertRaises(proof.ProofError):
            proof.check_receipt(dict(good, previous_release=None), lab, 'initialized',
                                'schema', None, 'b', '127.0.0.1:49153')
        with self.assertRaises(proof.ProofError):
            proof.check_receipt(dict(good, rollback=dict(good['rollback'], revision='prior')), lab,
                                'initialized', 'schema', None, 'b', '127.0.0.1:49153')

    def test_schema_negative_runs_real_entry_and_read_only_post_fence_evidence(self):
        schema = 'a' * 64
        seed = copy.deepcopy(example_state())
        seed['schema_digest'] = schema
        seed['schema_version'] = '1'
        with tempfile.TemporaryDirectory() as folder:
            work = Path(folder)
            source = work / 'source'
            migrations = source / 'server' / 'migrations'
            migrations.mkdir(parents=True)
            (migrations / '0001_init.up.sql').write_text('select 1;\n')
            box, daemon, healthy = strict_stage(work, seed)
            before = {
                kind: tuple(sorted((item['id'], item['name'], tuple(sorted(item['labels'].items())))
                                   for item in daemon._records(kind)))
                for kind in ('container', 'network', 'volume')
            }

            proof.reject_mismatch(
                box, SimpleNamespace(source=source, revision='b' * 40), work, {}, schema, healthy)

            self.assertIsNone(box.fenced())
            self.assertEqual(daemon.stopped, daemon.SERVING)
            self.assertEqual(daemon.removal_commands(), [])
            self.assertNotIn('backup', daemon.compose_exec_services())
            self.assertGreater(daemon.vault_reads_after_stop, 0)
            self.assertEqual(len(daemon.state_writes), 2)
            self.assertEqual(len(daemon.state_helper_removals), 2)
            self.assertNotIn('state-helper', daemon.containers)
            self.assertNotEqual(json.loads(daemon.state_writes[0])['schema_digest'], schema)
            self.assertEqual(json.loads(daemon.state_writes[-1]), healthy)
            self.assertEqual(json.loads(daemon.state_raw), healthy)
            after = {
                kind: tuple(sorted((item['id'], item['name'], tuple(sorted(item['labels'].items())))
                                   for item in daemon._records(kind)))
                for kind in ('container', 'network', 'volume')
            }
            self.assertEqual(after, before)
            self.assertTrue(any(args and args[0] == 'compose' and 'permit' in args and
                                'inventory' in args for args, _ in daemon.calls))

    def test_probe_missing_runs_real_job_through_strict_contract(self):
        root = '11111111-1111-4111-8111-111111111111'
        with tempfile.TemporaryDirectory() as folder:
            work = Path(folder)
            box, daemon, _ = strict_stage(work, example_state())
            box.probe_missing_root(root)

        jobs = []
        for args, checked in daemon.calls:
            if args and args[0] == 'compose':
                tail = daemon._tail_compose(args)
                if tail and tail[0] == 'run':
                    jobs.append((tail, checked))
        self.assertEqual(jobs, [(('run', '--rm', '--no-deps', '-T', '--entrypoint',
                                   '/ops/gate.sh', 'permit', 'probe-missing', root), False)])
        self.assertEqual(daemon.removal_commands(), [])

    def test_reject_mismatch_ownership_failure_never_restores_or_fences(self):
        seed = copy.deepcopy(example_state())
        with tempfile.TemporaryDirectory() as folder:
            work = Path(folder)
            box, daemon, healthy = strict_stage(work, seed, project_label_drift='network')
            with self.assertRaises(guard.SafetyError):
                proof.reject_mismatch(box, SimpleNamespace(revision='b' * 40),
                                      work, {}, 'a' * 64, healthy)

            self.assertEqual(daemon.state_writes, [])
            self.assertEqual(json.loads(daemon.state_raw), healthy)
            self.assertFalse(daemon.stopped)
            self.assertEqual(daemon.removal_commands(), [])

    def test_snapshot_refuses_ownership_label_drift_before_evidence(self):
        for drift in ('network', 'vault'):
            with self.subTest(drift=drift), tempfile.TemporaryDirectory() as folder:
                work = Path(folder)
                box, daemon, _ = strict_stage(work, example_state(), project_label_drift=drift)
                with self.assertRaises(guard.SafetyError):
                    proof.snapshot(box)
                self.assertFalse(daemon.stopped)
                self.assertEqual(daemon.vault_reads, 0)
                self.assertEqual(daemon.removal_commands(), [])

    def test_cleanup_refuses_ownership_or_identity_drift_without_removal(self):
        cases = (
            {'project_label_drift': 'network'},
            {'project_label_drift': 'vault'},
            {'container_id_drift_after_ownership': True},
        )
        for options in cases:
            with self.subTest(options=options), tempfile.TemporaryDirectory() as folder:
                work = Path(folder)
                box, daemon, _ = strict_stage(work, example_state(), **options)
                with self.assertRaises(guard.SafetyError):
                    box.clean()
                self.assertTrue(box.armed)
                self.assertEqual(daemon.removal_commands(), [])

    def test_snapshot_uses_the_current_two_argument_read_state_contract(self):
        stage = Mock(volume='test-state')
        with patch.object(proof.staging, 'read_state', return_value={'schema_digest': 'a' * 64}) as read, \
                patch.object(proof, 'storage_evidence', return_value='storage'), \
                patch.object(stage, 'state_file_fingerprint', return_value='file'), \
                patch.object(stage, 'resource_identities', return_value={'volume': ()}) as identities:
            self.assertEqual(proof.snapshot(stage), ({'schema_digest': 'a' * 64}, 'file', 'storage',
                                                     {'volume': ()}))
        read.assert_called_once_with(stage, 'test-state')
        self.assertEqual(identities.call_count, 2)

    def test_orchestrator_routes_all_three_calls_through_production_entry(self):
        work = Path('/synthetic')
        first = SimpleNamespace(source=work / 'first', revision='first', previous='prior')
        second = SimpleNamespace(source=work / 'second', revision='second', previous='first')
        schema = 'a' * 64
        address = '127.0.0.1:49001'
        seed = example_state()
        stage = Mock(volume='test-state')
        stage.name = 'test-box'
        stage.env = {
            'CHALLENGE': seed['challenge'], 'DB_PASS': seed['credentials']['db_password'],
            'COST_PASS': seed['credentials']['cost_password'], 'LEDGER_PASS': seed['credentials']['ledger_password'],
            'TEST_FIELD_KEY': seed['credentials']['field_key_base64'],
            'ALERT_WEBHOOK': proof.release.ALERT_WEBHOOK,
        }
        stage.compose.return_value = address.encode()
        stage.existing_project.side_effect = [False, True, True]
        stage.gate_exit.return_value = 0
        stage.exec.return_value = b'ai_cost=normal sink=webhook'
        stage.alert_count.return_value = 0
        stage.run.side_effect = lambda *args, **kw: json.dumps({
            proof.staging.OWNER_LABEL: stage.name,
            proof.staging.ROLE_LABEL: proof.staging.STATE_ROLE,
        }).encode()
        stage.build.side_effect = ['sha256:' + 'd' * 64, 'sha256:' + 'e' * 64,
                                    'sha256:' + 'f' * 64]
        result = dict(persistence_marker=seed['marker'], business_dump_sha256=seed['business_dump_sha256'],
                      ledger_deadlines=seed['ledger_deadlines'],
                      releases={
                          'a': [first.previous, [seed['previous_release']['api_image_id'], seed['previous_release']['web_image_id']]],
                          'b': [first.revision, [seed['release']['api_image_id'], seed['release']['web_image_id']]],
                      })
        written = []
        with patch.object(proof.staging, 'write_state', side_effect=lambda *args: written.append(copy.deepcopy(args[2]))), \
                patch.object(proof.staging, 'read_state', side_effect=lambda *_: copy.deepcopy(written[-1]) if written else None), \
                patch.object(proof.staging, 'schema_version', return_value=seed['schema_version']), \
                patch.object(proof.staging, 'verify_storage', return_value=True) as verify, \
                patch.object(proof, 'pg_fingerprint', return_value='pg'), \
                patch.object(proof, 'ledger_fingerprint', return_value='ledger'), \
                patch.object(proof, 'vault_fingerprint', return_value={'snap-a': ('vault',)}), \
                patch.object(proof.release, 'deploy', return_value=(address, result)) as deploy, \
                patch.object(proof.release, 'run_ci_staging', wraps=proof.release.run_ci_staging) as run:
            proof.run_proof(stage, first, second, work, (
                composition_for(ADMISSION_PREVIOUS, ADMISSION_CURRENT),
                composition_for(ADMISSION_CURRENT, ADMISSION_NEXT),
            ), schema, Mock())
        self.assertEqual([entry.args[1] for entry in run.call_args_list], [first, second, second])
        deploy.assert_called_once()
        self.assertEqual(stage.start.call_args_list, [call(), call(allow_existing=True)])
        self.assertEqual(stage.resource_identities.call_count, 6)
        stage.fenced.assert_called_once_with()
        self.assertEqual(verify.call_count, 6)
        initialized, updated, broken, restored = written
        self.assertEqual(updated['previous_release'], initialized['release'])
        self.assertNotEqual(broken['schema_digest'], schema)
        self.assertEqual(updated, restored)

    def test_gate_and_errors_never_print_raw_input_or_secrets(self):
        output = io.StringIO()
        with patch.dict(cli.os.environ, {}, clear=True), patch.object(cli, 'execute') as execute, \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            self.assertEqual(cli.main(['--unknown', 'raw-secret']), 1)
            execute.assert_not_called()
        with tempfile.TemporaryDirectory() as tmp:
            approvals = write_static_approval(Path(tmp) / 'approvals.json')
            with patch.dict(cli.os.environ, {
                    cli.ALLOW: '1',
                    cli.release_approval.APPROVALS_ENV: str(approvals),
                }, clear=True), \
                    patch.object(cli, 'execute', side_effect=ValueError('raw-secret')), \
                    contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                self.assertEqual(cli.main(['--unknown', 'raw-secret']), 1)
                self.assertEqual(cli.main(['a' * 40, '--previous', 'b' * 40]), 1)
        self.assertNotIn('raw-secret', output.getvalue())
        self.assertIn('ValueError', output.getvalue())

    def test_gate_rejects_self_hosted_volume_and_reports_only_safe_namespace(self):
        output = io.StringIO()
        with patch.dict(cli.os.environ, {cli.ALLOW: '1', cli.staging.STATE_VOLUME_ENV: 'raw-state'}, clear=True), \
                patch.object(cli, 'execute') as execute, contextlib.redirect_stderr(output):
            self.assertEqual(cli.main(['a' * 40]), 1)
            execute.assert_not_called()
        with tempfile.TemporaryDirectory() as tmp:
            approvals = write_static_approval(Path(tmp) / 'approvals.json')
            with patch.dict(cli.os.environ, {
                    cli.ALLOW: '1', cli.RUN_ID_ENV: RUN,
                    cli.release_approval.APPROVALS_ENV: str(approvals),
                }, clear=True), \
                    patch.object(cli, 'execute') as execute, contextlib.redirect_stdout(output):
                self.assertEqual(cli.main(['--candidate-tree', 'b' * 40, '--previous', 'a' * 40]), 0)
                self.assertEqual(execute.call_args.args[0].candidate_tree, 'b' * 40)
        self.assertIn('namespace=t34-proof-' + RUN, output.getvalue())
        self.assertNotIn('raw-state', output.getvalue())


if __name__ == '__main__':
    unittest.main()

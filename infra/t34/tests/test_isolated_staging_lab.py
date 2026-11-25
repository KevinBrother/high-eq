"""Offline safety-boundary tests for the isolated T34 staging lab."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, call, patch

import isolated_staging_lab as guard


RUN = 'd' * 24
ENGINE_HOST = 'unix:///tmp/t34-dedicated-docker.sock'
ENGINE_ID = '8f6c4c5e-3f7a-4b2a-9d3e-6a1b2c3d4e5f'
LEGACY_ENGINE_ID = 'e' * 64


class LabBoundaryTests(unittest.TestCase):
    def setUp(self):
        workspace = tempfile.TemporaryDirectory()
        self.addCleanup(workspace.cleanup)
        self.work = Path(workspace.name)
        self.lab = guard.IsolatedLab(self.work, (self.work,), RUN, ENGINE_HOST, ENGINE_ID)
        self.lab._docker = Mock(side_effect=AssertionError('unexpected Docker call'))

    def test_engine_gate_rejects_missing_default_or_mismatched_endpoints(self):
        for environ in ({},
                        {guard.ENGINE_HOST_ENV: 'unix:///var/run/docker.sock',
                         guard.ENGINE_ID_ENV: ENGINE_ID},
                        {guard.ENGINE_HOST_ENV: 'unix:///tmp/../var/run/docker.sock',
                         guard.ENGINE_ID_ENV: ENGINE_ID},
                        {guard.ENGINE_HOST_ENV: 'tcp://127.0.0.1:2375',
                         guard.ENGINE_ID_ENV: ENGINE_ID},
                        {guard.ENGINE_HOST_ENV: 'unix://relative.sock',
                         guard.ENGINE_ID_ENV: ENGINE_ID},
                        {guard.ENGINE_HOST_ENV: ENGINE_HOST,
                         guard.ENGINE_ID_ENV: ''},
                        {guard.ENGINE_HOST_ENV: ENGINE_HOST,
                         guard.ENGINE_ID_ENV: 'short'},
                        {guard.ENGINE_HOST_ENV: ENGINE_HOST,
                         guard.ENGINE_ID_ENV: ENGINE_ID.upper()},
                        {guard.ENGINE_HOST_ENV: ENGINE_HOST,
                         guard.ENGINE_ID_ENV: ENGINE_ID[:-1]}):
            with self.subTest(environ=environ), self.assertRaises(guard.SafetyError):
                guard.isolated_engine(environ)
        self.assertEqual(guard.isolated_engine({guard.ENGINE_HOST_ENV: ENGINE_HOST,
                                                guard.ENGINE_ID_ENV: ENGINE_ID}),
                         (ENGINE_HOST, ENGINE_ID))

    def test_engine_gate_accepts_canonical_uuid_and_legacy_hex_ids(self):
        for identifier in (ENGINE_ID, LEGACY_ENGINE_ID):
            with self.subTest(identifier=identifier):
                self.assertEqual(guard.isolated_engine({
                    guard.ENGINE_HOST_ENV: ENGINE_HOST,
                    guard.ENGINE_ID_ENV: identifier,
                }), (ENGINE_HOST, identifier))

    def test_engine_identity_must_match_without_normalization(self):
        self.lab._docker = Mock(return_value=(ENGINE_ID.replace('-', '') + '\tlinux').encode())
        with self.assertRaises(guard.SafetyError):
            self.lab._verify_engine()
        self.assertFalse(self.lab._engine_verified)

    def test_claim_verifies_the_expected_daemon_before_namespace_or_mutation(self):
        self.lab._docker = Mock(return_value=b'wrong-daemon\tlinux')
        with self.assertRaises(guard.SafetyError):
            self.lab.claim()
        self.assertEqual(self.lab._docker.call_args_list, [
            call('info', '--format', '{{.ID}}\t{{.OSType}}'),
        ])
        self.assertFalse(self.lab.armed)

    def test_only_fresh_namespace_and_derived_targets(self):
        for bad in ('t34-ci-staging', 't34-synthetic-stage', '/tmp/state', 'production', 'A' * 24):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                guard.namespace(bad)
        self.assertEqual(self.lab.name, 't34-proof-' + RUN)
        self.assertEqual(self.lab.volume, self.lab.name + '_state')
        self.assertEqual(self.lab.tag('api-b'), self.lab.name + '/api-b:local')
        self.assertEqual(self.lab.env['INSTALLATION'], self.lab.name)
        with self.assertRaises(ValueError):
            self.lab.tag('other')

    def test_preflight_collisions_never_claim_or_remove(self):
        for kind in ('container', 'network', 'volume', 'image'):
            with self.subTest(kind=kind):
                with patch.object(self.lab, '_verify_engine'), \
                        patch.object(self.lab, '_namespace_rows',
                                     side_effect=lambda k: ([('collision', 'x')] if k == kind else [])):
                    with self.assertRaises(guard.SafetyError):
                        self.lab.claim()
                self.lab.clean()
        self.lab._docker.assert_not_called()

    def test_failed_claim_rechecks_exact_ownership_before_removing_volume(self):
        self.lab._docker = Mock(return_value=b'linux')
        with patch.object(self.lab, '_verify_engine'), \
                patch.object(self.lab, '_namespace_rows', return_value=[]), \
                patch.object(self.lab, '_image_mounts'), \
                patch.object(self.lab, '_check_state_volume', side_effect=[guard.SafetyError('first'), None]):
            with self.assertRaises(guard.SafetyError):
                self.lab.claim()
        self.assertIn(call('volume', 'rm', self.lab.volume), self.lab._docker.call_args_list)
        self.assertFalse(self.lab.armed)

    def test_failed_claim_leaves_volume_when_ownership_recheck_fails(self):
        self.lab._docker = Mock(return_value=b'linux')
        with patch.object(self.lab, '_verify_engine'), \
                patch.object(self.lab, '_namespace_rows', return_value=[]), \
                patch.object(self.lab, '_image_mounts'), \
                patch.object(self.lab, '_check_state_volume',
                             side_effect=[guard.SafetyError('first'), guard.SafetyError('second')]):
            with self.assertRaises(guard.SafetyError):
                self.lab.claim()
        self.assertNotIn(call('volume', 'rm', self.lab.volume), self.lab._docker.call_args_list)
        self.assertFalse(self.lab.armed)

    def test_namespace_discovery_never_lists_foreign_resources(self):
        self.lab._docker = Mock(return_value=b'')
        for kind in guard.FORMATS:
            self.lab._namespace_rows(kind)
        self.assertTrue(self.lab._docker.call_args_list)
        for query in self.lab._docker.call_args_list:
            self.assertIn('--filter', query.args)

    def test_dangling_images_only_enter_through_the_private_owner_filter(self):
        image = 'sha256:' + '1' * 64
        dangling = (image, '<none>:<none>')

        def rows(kind, filter_value):
            return [dangling] if filter_value.startswith('label=' + guard.OWNER + '=') else []

        with patch.object(self.lab, '_rows', side_effect=rows):
            self.assertEqual(self.lab._namespace_rows('image'), [dangling])

        for filter_value in ('label=' + guard.PROJECT + '=' + self.lab.name,
                             'reference=' + self.lab.name + '/*'):
            with self.subTest(filter=filter_value), \
                    patch.object(self.lab, '_rows',
                                 side_effect=lambda kind, value, f=filter_value:
                                 [dangling] if value == f else []):
                with self.assertRaises(guard.SafetyError):
                    self.lab._namespace_rows('image')

    def test_production_fence_and_shutdown_commands_are_scoped_to_verified_containers(self):
        self.lab.armed = True
        container = 'b' * 64
        labels = json.dumps({guard.OWNER: self.lab.token, guard.PROJECT: self.lab.name})
        inspect = f'{container} /{self.lab.name}-web-1 {labels}'.encode()
        listing = f'{container} web'.encode()

        def docker(*args, **kw):
            if args == ('info', '--format', '{{.ID}}\t{{.OSType}}'):
                return (ENGINE_ID + '\tlinux').encode()
            if args[0] == 'ps':
                return listing
            if args[:2] == ('container', 'inspect') and '{{json .Config.Labels}}' in args[3]:
                return inspect
            if args[:2] == ('container', 'inspect') and '{{json .Mounts}}' in args[3]:
                return b'[]'
            if args[:1] == ('stop',):
                return b''
            raise AssertionError('unexpected Docker command: ' + repr(args))

        self.lab._docker = Mock(side_effect=docker)
        self.lab.run('ps', '--no-trunc',
                     '--filter=label=com.docker.compose.project=' + self.lab.name,
                     '--format', '{{.ID}} {{.Label "com.docker.compose.service"}}', timeout=15)
        self.lab.run('stop', '--time', '5', container, check=False, timeout=45)
        self.assertGreaterEqual(self.lab._docker.call_count, 6)
        with self.assertRaises(guard.SafetyError):
            self.lab._compose_command(('--profile', '*', 'stop', '--timeout', '5',
                                       'api', 'foreign'), 'test.yml', True)
        self.lab._compose_command(('--profile', '*', 'stop', '--timeout', '5',
                                   'api', 'web'), 'test.yml', True)

    def test_raw_commands_reject_other_volume_bind_mount_and_foreign_ids(self):
        self.lab.armed = True
        for mount in ('ci-provisioned:/state:ro', '/tmp:/state:ro', self.lab.volume + ':/tmp:ro'):
            with self.subTest(mount=mount), self.assertRaises(guard.SafetyError):
                self.lab.run('run', '--rm', '--network', 'none', '--read-only', '-v', mount,
                             '--entrypoint', 'sh', guard.PG, '-c', 'exit 0')
        with self.assertRaises(guard.SafetyError):
            self.lab.run('volume', 'inspect', '--format', '{{json .Labels}}', 'real-state')
        self.lab._docker = Mock(return_value=(ENGINE_ID + '\tlinux').encode())
        with self.assertRaises(guard.SafetyError):
            self.lab.compose('run', '-v', '/tmp:/host', 'backup')
        with self.assertRaises(guard.SafetyError):
            self.lab.compose('run', '--rm', '--no-deps', '-T', 'backup', '-v', '/tmp:/host')
        self.assertTrue(all(entry.args == ('info', '--format', '{{.ID}}\t{{.OSType}}')
                            for entry in self.lab._docker.call_args_list))

    def test_permit_jobs_allow_only_inventory_and_uuid_probe_missing(self):
        root = '11111111-1111-4111-8111-111111111111'
        self.lab._compose_command(
            ('run', '--rm', '--no-deps', '-T', '--entrypoint', '/ops/gate.sh',
             'permit', 'inventory'), 'test.yml', False)
        self.lab._compose_command(
            ('run', '--rm', '--no-deps', '-T', '--entrypoint', '/ops/gate.sh',
             'permit', 'probe-missing', root), 'test.yml', False)
        for command in (
                ('run', '--rm', '--no-deps', '-T', '--entrypoint', '/ops/gate.sh',
                 'permit', 'inventory', 'extra'),
                ('run', '--rm', '--no-deps', '-T', '--entrypoint', '/ops/gate.sh',
                 'permit', 'probe-missing'),
                ('run', '--rm', '--no-deps', '-T', '--entrypoint', '/ops/gate.sh',
                 'permit', 'probe-missing', '../state'),
                ('run', '--rm', '--no-deps', '-T', '--entrypoint', '/bin/sh',
                 'permit', 'inventory')):
            with self.subTest(command=command), self.assertRaises(guard.SafetyError):
                self.lab._compose_command(command, 'test.yml', False)

    def test_vault_evidence_is_a_read_only_owned_volume_helper(self):
        self.lab.armed = True
        vault = self.lab.name + '_vault'
        labels = json.dumps({guard.OWNER: self.lab.token, guard.PROJECT: self.lab.name}).encode()
        commands = []

        def docker(*args, **kw):
            commands.append(args)
            if args == ('info', '--format', '{{.ID}}\t{{.OSType}}'):
                return (ENGINE_ID + '\tlinux').encode()
            if args[:2] == ('volume', 'inspect'):
                return labels if '{{json .Labels}}' in args else b'local null'
            if args[0] == 'run':
                return b'snap-a ' + b'a' * 64 + b' ' + b'b' * 64 + b' ' + b'c' * 64 + b'\n'
            raise AssertionError('unexpected Docker command: ' + repr(args))

        self.lab._docker = docker
        self.assertEqual(self.lab.vault_entries().startswith(b'snap-a '), True)
        helper = next(command for command in commands if command[0] == 'run')
        self.assertIn('--network', helper)
        self.assertEqual(helper[helper.index('--network') + 1], 'none')
        self.assertIn('--read-only', helper)
        self.assertIn('--pull=never', helper)
        self.assertIn(guard.OWNER + '=' + self.lab.token, helper)
        self.assertIn(guard.PROJECT + '=' + self.lab.name, helper)
        self.assertIn('type=volume,src=' + vault + ',dst=/vault,readonly', helper)
        self.assertIn('type=tmpfs,dst=' + guard.PG_DATA, helper)
        self.assertFalse(any('/var/run/docker.sock' in token for token in helper))
        self.assertFalse(any(command[:2] == ('exec', 'backup') for command in commands))

    def test_vault_evidence_refuses_unowned_volume_before_starting_helper(self):
        self.lab.armed = True
        self.lab._docker = Mock(return_value=(ENGINE_ID + '\tlinux').encode())
        with patch.object(self.lab, '_check_project_volume', side_effect=guard.SafetyError):
            with self.assertRaises(guard.SafetyError):
                self.lab.vault_entries()
        self.assertNotIn('run', [entry.args[0] for entry in self.lab._docker.call_args_list])

    def test_mutations_reverify_engine_and_stop_at_ownership_drift(self):
        self.lab.armed = True
        self.lab._docker = Mock(return_value=b'')
        self.lab._configs.add(('test.yml', False, tuple(sorted(self.lab.env.items()))))
        with patch.object(self.lab, '_owned_resources', return_value={}), \
                patch.object(self.lab, '_compose_command'), \
                patch.object(self.lab, '_verify_engine',
                             side_effect=[None, guard.SafetyError('engine changed')]), \
                patch.object(self.lab, '_compose') as compose:
            with self.assertRaises(guard.SafetyError):
                self.lab.compose('stop', 'api')
        compose.assert_not_called()

        build = ('build', '-f', self.work / 'infra/t34/Dockerfile', '--build-arg',
                 'RELEASE=' + 'a' * 40, '-t', self.lab.tag('api-b'), self.work)
        with patch.object(self.lab, '_verify_engine', side_effect=guard.SafetyError('engine changed')), \
                patch.object(self.lab, '_rows') as rows:
            with self.assertRaises(guard.SafetyError):
                self.lab.run(*build)
        rows.assert_not_called()
        self.lab._docker.assert_not_called()

        container = 'b' * 64
        with patch.object(self.lab, '_verify_engine', side_effect=guard.SafetyError('engine changed')), \
                patch.object(self.lab, '_container') as inspect:
            with self.assertRaises(guard.SafetyError):
                self.lab.run('stop', '--time', '5', container)
        inspect.assert_not_called()
        self.lab._docker.assert_not_called()

    def test_compose_rejects_external_resources_unsafe_mounts_and_ports(self):
        base = {
            'name': self.lab.name,
            'networks': {'default': {'name': self.lab.name + '_default', 'internal': True},
                         'preview': {'name': self.lab.name + '_preview', 'internal': True}},
            'volumes': {'vault': {'name': self.lab.name + '_vault'}},
            'services': {'web': {'image': self.lab.tag('web-b'), 'networks': {'preview': None},
                                 'ports': [{'host_ip': '127.0.0.1', 'target': 8080, 'protocol': 'tcp'}]}}
        }
        for kind in ('networks', 'volumes', 'services'):
            for spec in base[kind].values():
                spec['labels'] = {guard.OWNER: self.lab.token}
        self.lab._validate_config(base, preview=True)
        drifts = [lambda c: c['networks']['default'].update(external=True),
                  lambda c: c['volumes']['vault'].update(driver_opts={'device': '/host'}),
                  lambda c: c['volumes']['vault'].update(name='t34-ci-staging_vault'),
                  lambda c: c['services']['web']['labels'].clear(),
                  lambda c: c['services']['web'].update(volumes=[{'type': 'bind', 'source': '/host'}]),
                  lambda c: c['services']['web']['ports'][0].update(host_ip='0.0.0.0'),
                  lambda c: c['services']['web']['ports'][0].update(published='8080'),
                  lambda c: c['services']['web'].pop('ports')]
        for drift in drifts:
            model = copy.deepcopy(base)
            drift(model)
            with self.assertRaises((guard.SafetyError, ValueError)):
                self.lab._validate_config(model, preview=True)

    def test_state_read_helper_is_exact_read_only_contract(self):
        self.lab.armed = True

        def docker(*args, **kw):
            if args == ('info', '--format', '{{.ID}}\t{{.OSType}}'):
                return (ENGINE_ID + '\tlinux').encode()
            if args[:2] == ('volume', 'inspect') and '{{json .Labels}}' in args:
                return json.dumps({guard.OWNER: self.lab.token,
                                   guard.staging.OWNER_LABEL: self.lab.name,
                                   guard.staging.ROLE_LABEL: guard.staging.STATE_ROLE}).encode()
            if args[:2] == ('volume', 'inspect') and '{{.Driver}} {{json .Options}}' in args:
                return b'local null'
            if args[0] == 'run':
                return json.dumps({'schema_digest': 'a' * 64}).encode()
            raise AssertionError('unexpected Docker command: ' + repr(args))

        self.lab._docker = Mock(side_effect=docker)
        self.assertEqual(guard.staging.read_state(self.lab, self.lab.volume),
                         {'schema_digest': 'a' * 64})
        runs = [entry.args for entry in self.lab._docker.call_args_list
                if entry.args and entry.args[0] == 'run']
        self.assertEqual(len(runs), 1)
        run = runs[0]
        self.assertEqual(run[:14], (
            'run', '--name', self.lab.name + '-state-helper',
            '--label', guard.OWNER + '=' + self.lab.token,
            '--pull=never', '--mount', 'type=tmpfs,dst=' + guard.PG_DATA,
            '--rm', '--network', 'none', '--read-only', '-v',
            self.lab.volume + ':/state:ro',
        ))
        self.assertEqual(run[14:18], ('--entrypoint', 'sh', guard.PG, '-c'))
        self.assertIn('cat /state/' + guard.staging.STATE_FILE, run[18])
        self.assertFalse(any(entry.args and entry.args[0] in ('create', 'start', 'rm', 'ps')
                             for entry in self.lab._docker.call_args_list))

    def test_state_writer_uses_settled_create_start_remove_and_probe_lifecycle(self):
        self.lab.armed = True
        writer = 'a' * 64
        state = {'schema_digest': 'b' * 64, 'schema_version': '1'}

        def docker(*args, **kw):
            if args == ('info', '--format', '{{.ID}}\t{{.OSType}}'):
                return (ENGINE_ID + '\tlinux').encode()
            if args[:2] == ('volume', 'inspect') and '{{json .Labels}}' in args:
                return json.dumps({guard.OWNER: self.lab.token,
                                   guard.staging.OWNER_LABEL: self.lab.name,
                                   guard.staging.ROLE_LABEL: guard.staging.STATE_ROLE}).encode()
            if args[:2] == ('volume', 'inspect') and '{{.Driver}} {{json .Options}}' in args:
                return b'local null'
            if args[0] == 'create':
                return writer.encode()
            if args[:2] == ('container', 'inspect'):
                labels = json.dumps({guard.OWNER: self.lab.token})
                return f'{writer} /{self.lab.name}-state-helper {labels}'.encode()
            if args[0] in ('start', 'rm', 'ps'):
                return b''
            raise AssertionError('unexpected Docker command: ' + repr(args))

        self.lab._docker = Mock(side_effect=docker)
        guard.staging.write_state(self.lab, self.lab.volume, state, self.lab.name)

        calls = self.lab._docker.call_args_list
        create = next(entry for entry in calls if entry.args and entry.args[0] == 'create')
        self.assertEqual(create.args[:17], (
            'create', '--name', self.lab.name + '-state-helper',
            '--label', guard.OWNER + '=' + self.lab.token,
            '--pull=never', '--mount', 'type=tmpfs,dst=' + guard.PG_DATA,
            '-i', '--network', 'none', '-v', self.lab.volume + ':/state',
            '--entrypoint', 'sh', guard.PG, '-c',
        ))
        self.assertNotIn('--rm', create.args)
        self.assertNotIn('--read-only', create.args)
        self.assertEqual(create.kwargs, {'timeout': 30})

        start = next(entry for entry in calls if entry.args and entry.args[0] == 'start')
        self.assertEqual(start.args, ('start', '-a', '-i', writer))
        self.assertEqual(start.kwargs['timeout'], 120)
        self.assertEqual(start.kwargs['input'], (
            json.dumps(state, sort_keys=True, separators=(',', ':')) + '\n').encode())

        remove = next(entry for entry in calls if entry.args and entry.args[0] == 'rm')
        self.assertEqual(remove.args, ('rm', '-f', writer))
        self.assertEqual(remove.kwargs, {'timeout': 30})

        probe = next(entry for entry in calls if entry.args and entry.args[0] == 'ps')
        self.assertEqual(probe.args, ('ps', '-aq', '--filter', 'id=' + writer))
        self.assertEqual(probe.kwargs, {'timeout': 30})
        self.assertIsNone(self.lab._state_writer)

    def test_state_writer_rejects_legacy_writable_run_and_foreign_ids(self):
        self.lab.armed = True
        self.lab._docker = Mock()
        legacy = (
            'run', '--rm', '-i', '--network', 'none', '-v',
            self.lab.volume + ':/state', '--entrypoint', 'sh', guard.PG, '-c', 'exit 0',
        )
        with self.assertRaises(guard.SafetyError):
            self.lab.run(*legacy)
        with self.assertRaises(guard.SafetyError):
            self.lab.run('start', '-a', '-i', 'b' * 64, input=b'{}\n', timeout=120)
        with self.assertRaises(guard.SafetyError):
            self.lab.run('rm', '-f', 'b' * 64, timeout=30)
        with self.assertRaises(guard.SafetyError):
            self.lab.run('ps', '-aq', '--filter', 'id=' + 'b' * 64, timeout=30)
        self.lab._docker.assert_not_called()

    def test_state_writer_rejects_wrong_image_timeout_or_second_writer(self):
        self.lab.armed = True
        self.lab._docker = Mock()
        create = (
            'create', '-i', '--network', 'none', '-v', self.lab.volume + ':/state',
            '--entrypoint', 'sh', guard.PG, '-c', 'exit 0',
        )
        original_image = self.lab.env['PG_IMAGE']
        with patch.object(self.lab, '_verify_engine'), \
                patch.object(self.lab, '_check_state_volume'):
            self.lab.env['PG_IMAGE'] = 'foreign/image:latest'
            with self.assertRaises(guard.SafetyError):
                self.lab.run(*create, timeout=30)
            self.lab.env['PG_IMAGE'] = original_image
            with self.assertRaises(guard.SafetyError):
                self.lab.run(*create, timeout=31)
            self.lab._state_writer = 'b' * 64
            with self.assertRaises(guard.SafetyError):
                self.lab.run(*create, timeout=30)
        self.lab._docker.assert_not_called()

    def test_state_writer_rejects_a_replaced_container_before_start(self):
        self.lab.armed = True
        self.lab._state_writer = 'a' * 64
        replacement = 'b' * 64
        labels = json.dumps({guard.OWNER: self.lab.token})

        def docker(*args, **kw):
            if args == ('info', '--format', '{{.ID}}\t{{.OSType}}'):
                return (ENGINE_ID + '\tlinux').encode()
            if args[:2] == ('container', 'inspect'):
                return f'{replacement} /{self.lab.name}-state-helper {labels}'.encode()
            raise AssertionError('unexpected Docker command: ' + repr(args))

        self.lab._docker = Mock(side_effect=docker)
        with self.assertRaises(guard.SafetyError):
            self.lab.run('start', '-a', '-i', 'a' * 64, input=b'{}\n', timeout=120)
        self.assertFalse(any(entry.args and entry.args[0] == 'start'
                             for entry in self.lab._docker.call_args_list))

    def test_state_probe_rejects_a_replacement_row_for_the_recorded_writer(self):
        self.lab.armed = True
        self.lab._state_writer = 'a' * 64
        replacement = 'b' * 64

        def docker(*args, **kw):
            if args == ('info', '--format', '{{.ID}}\t{{.OSType}}'):
                return (ENGINE_ID + '\tlinux').encode()
            if args[0] == 'ps':
                return replacement.encode()
            raise AssertionError('unexpected Docker command: ' + repr(args))

        self.lab._docker = Mock(side_effect=docker)
        with self.assertRaises(guard.SafetyError):
            self.lab.run('ps', '-aq', '--filter', 'id=' + 'a' * 64, timeout=30)

    def test_compose_override_only_labels_and_masks_volume_declarations(self):
        for (overlay, preview), path in self.lab._overlays.items():
            model = json.loads(path.read_bytes())
            self.assertEqual(set(model), {'services', 'networks', 'volumes'})
            self.assertEqual('preview' in model['networks'], preview)
            for name, spec in model['services'].items():
                self.assertEqual(spec.pop('labels'), {guard.OWNER: self.lab.token})
                if name in guard.MASKS[overlay]:
                    self.assertEqual(spec, {'volumes': [{'type': 'tmpfs', 'target': guard.MASKS[overlay][name]}]})
                else:
                    self.assertEqual(spec, {})

    def test_existing_project_cannot_be_adopted_on_compose_label_alone(self):
        self.lab.armed = True
        with patch.object(self.lab, '_owned_resources', side_effect=guard.SafetyError) as verify:
            with self.assertRaises(guard.SafetyError):
                self.lab.existing_project()
            verify.assert_called_once_with()
        self.lab._docker.assert_not_called()

    def test_missing_claim_label_stops_cleanup_before_any_removal(self):
        self.lab.armed = True
        self.lab._docker = Mock(return_value=b'{}')
        with patch.object(self.lab, '_verify_engine'):
            with self.assertRaises(guard.SafetyError):
                self.lab.clean()
        self.assertEqual(self.lab._docker.call_count, 1)
        self.assertEqual(self.lab._docker.call_args.args[:2], ('volume', 'inspect'))

    def test_cleanup_uses_only_verified_explicit_targets(self):
        self.lab.armed = True
        self.lab._docker = Mock(return_value=b'')
        box = self.lab
        image = 'sha256:' + '0' * 64
        with patch.object(box, '_owned_resources', return_value={
            'container': [('b' * 64, box.name + '-db-1')],
            'network': [('c' * 64, box.name + '_default')],
            'volume': [(box.volume, box.volume), (box.name + '_vault', box.name + '_vault')],
            'image': [(image, box.tag('api-b'))],
        }), patch.object(box, '_namespace_rows', return_value=[]), \
                patch.object(box, '_verify_engine'), \
                patch.object(box, '_container', return_value='b' * 64), \
                patch.object(box, '_check_project_network'), \
                patch.object(box, '_check_project_volume'), \
                patch.object(box, '_check_image_tag'), \
                patch.object(box, '_check_state_volume'):
            box.clean()
        self.assertEqual(box._docker.call_args_list, [
            call('container', 'rm', '-f', 'b' * 64), call('network', 'rm', 'c' * 64),
            call('volume', 'rm', box.name + '_vault'), call('image', 'rm', '--no-prune', box.tag('api-b')),
            call('volume', 'rm', box.volume),
        ])
        self.assertFalse(box.armed)

    def test_cleanup_removes_own_tags_and_verified_dangling_images_only(self):
        self.lab.armed = True
        self.lab._docker = Mock(return_value=b'')
        box = self.lab
        shared = 'sha256:' + '1' * 64
        dangling = 'sha256:' + '2' * 64
        foreign = 'sha256:' + '3' * 64
        resources = {
            'container': [],
            'network': [],
            'volume': [(box.volume, box.volume)],
            'image': [(shared, box.tag('api-b')), (shared, box.tag('web-b'))],
        }
        after_tags = [(shared, box.tag('api-b')), (shared, box.tag('web-b')),
                      (dangling, '<none>:<none>'), (foreign, 'foreign/image:latest')]
        with patch.object(box, '_owned_resources', return_value=resources), \
                patch.object(box, '_namespace_rows', return_value=after_tags), \
                patch.object(box, '_verify_engine'), \
                patch.object(box, '_check_image_tag'), \
                patch.object(box, '_verify_owned_image', return_value=True), \
                patch.object(box, '_check_state_volume'):
            box.clean()
        self.assertEqual(box._docker.call_args_list, [
            call('image', 'rm', '--no-prune', box.tag('api-b')),
            call('image', 'rm', '--no-prune', box.tag('web-b')),
            call('image', 'rm', '--no-prune', dangling),
            call('volume', 'rm', box.volume),
        ])
        self.assertNotIn(call('image', 'rm', '--no-prune', shared), box._docker.call_args_list)
        self.assertNotIn(call('image', 'rm', '--no-prune', foreign), box._docker.call_args_list)
        self.assertFalse(box.armed)

    def test_child_output_does_not_inherit_stdio_even_for_builds(self):
        with patch.object(guard.lab.sp, 'run') as spawn:
            spawn.return_value = Mock(returncode=0, stdout=b'private')
            guard.IsolatedLab._docker(self.lab, 'build', stdout=None)
        self.assertEqual(spawn.call_args.kwargs['stdout'], guard.lab.sp.PIPE)
        self.assertEqual(spawn.call_args.kwargs['stderr'], guard.lab.sp.PIPE)

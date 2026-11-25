"""Offline production-entry regressions: a replacement can carry byte-identical A."""
import contextlib
import copy
import hashlib
import io
import json
import os
import signal
import stat
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from test_staging import API_A, API_B, WEB_A, WEB_B, composition_for, release, staging, state


ENGINE = '12345678-1234-4123-8123-123456789abc'
VOLUME = 't34-state'
VOLUME_ID = 'a' * 64
INSTANCE_LABEL = 'cn.higheq.t34.state-instance'
WRITER = 'f' * 64
JOURNAL = release.staging_recovery.JOURNAL


class OwnerCheckedRecovery(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        path = self.proof = Path(folder.name)
        (path / 'provision.json').write_text(json.dumps({
            'engine_id': ENGINE, 'volume': VOLUME, 'instance': VOLUME_ID,
            'created_at': '2026-11-22T00:00:00Z',
        }))
        (path / 'provision.json').chmod(0o600)
        self.engine = ENGINE
        self.created_at = '2026-11-22T00:00:00Z'
        self.instance = VOLUME_ID
        self.owner = 't34-ci-staging'
        self.initial = state()
        self.initial['release'].update(api_image_id=API_A, web_image_id=WEB_A)
        self.initial['history'][0] = copy.deepcopy(self.initial['release'])
        self.persisted = copy.deepcopy(self.initial)
        self.running = {'api': API_A, 'web': WEB_A}
        self.project = True
        self.public = self.consumers = True
        self.writer = False
        self.fails = set()
        self.events = []
        self.reads = 0
        self.seed_receipt()

    def seed_receipt(self):
        path = self.proof / JOURNAL
        path.write_text(json.dumps({'status': 'committed', 'instance': self.instance,
                                    'state_sha256': hashlib.sha256(staging.state_payload(self.persisted)).hexdigest()}))
        path.chmod(0o600)

    def guard_status(self):
        return json.loads((self.proof / JOURNAL).read_text())['status']

    def docker(self, *args, **kw):
        if args == ('info', '--format', '{{.ID}}'):
            return self.engine.encode()
        if args[:2] == ('volume', 'inspect'):
            labels = {staging.OWNER_LABEL: self.owner, staging.ROLE_LABEL: staging.STATE_ROLE,
                      INSTANCE_LABEL: self.instance}
            if args[3] == '{{json .Labels}}':
                return json.dumps(labels).encode()
            return json.dumps({'Name': VOLUME, 'Driver': 'local', 'Scope': 'local',
                               'CreatedAt': self.created_at, 'Labels': labels, 'Options': None}).encode()
        if args[0] == 'ps' and 'volume=' + VOLUME in args:
            self.assertIn('-aq', args)  # Stopped helpers must be included.
            self.events.append('inventory')
            if 'inventory-error' in self.fails:
                raise RuntimeError('inventory unavailable')
            return WRITER.encode() if self.writer else b''
        if args[:2] == ('run', '--rm'):
            self.events.append('read')
            self.reads += 1
            if self.reads == 2 and 'replace-during-read' in self.fails:
                self.instance = 'b' * 64
            if self.persisted is None:
                return staging.ABSENT_STATE.encode()
            if 'rollback-stale-read' in self.fails and self.reads == 2:
                return json.dumps(self.initial).encode()
            return json.dumps(self.persisted).encode()
        if args[0] == 'create':
            self.assertEqual(self.guard_status(), 'pending')
            self.events.append('create')
            self.writer = True
            if 'create-ack-lost' in self.fails:
                raise subprocess.TimeoutExpired('docker create', 30)
            return WRITER.encode()
        if args[0] == 'start':
            self.events.append('start')
            self.interrupt('before-state-write')
            if 'commit' in self.fails or 'start-error' not in self.fails:
                self.persisted = json.loads(kw['input'])
            self.interrupt('after-state-write')
            if 'replace-after-start' in self.fails:
                self.instance = 'b' * 64
            if 'switch-engine-after-start' in self.fails:
                self.engine = '98765432-1234-4123-8123-123456789abc'
            if 'interrupt-after-durable-write' in self.fails:
                raise KeyboardInterrupt
            if 'start-error' in self.fails:
                raise subprocess.TimeoutExpired('docker start', 120)
            return b''
        if args[:3] == ('inspect', '--format', '{{.State.Status}}:{{.State.ExitCode}}'):
            self.assertEqual(args[-1], WRITER)
            if 'writer-durability-error' in self.fails or ('start-error' in self.fails and 'commit' not in self.fails):
                return b'exited:1'
            return b'exited:0'
        if args[:2] == ('rm', '-f'):
            self.assertEqual(args[2], WRITER)
            self.events.append('remove')
            if 'remove-error' not in self.fails:
                self.writer = False
            return b''
        if args[:2] == ('ps', '-aq') and args[-1] == 'id=' + WRITER:
            self.events.append('probe-id')
            if 'probe-error' in self.fails:
                raise RuntimeError('ID probe unavailable')
            return WRITER.encode() if self.writer else b''
        if args[:3] == ('inspect', '--format', '{{.Image}}'):
            return self.running[args[-1][:-4]].encode()
        self.fail(f'unexpected Docker operation: {args}')

    def run_release(self, revision='new-revision', *, expect_error=True):
        # Each invocation gets a new Lab and Python coordinator; only the mock daemon
        # and the real temporary recovery directory survive between invocations.
        lab = mock.Mock(ci_staging=True)
        lab.name = self.initial['installation']
        lab.source = Path('/synthetic')
        credentials = self.initial['credentials']
        lab.env = {'OPS_IMAGE': 'ops:synthetic', 'ALERT_WEBHOOK': release.ALERT_WEBHOOK, 'CHALLENGE': self.initial['challenge'],
                   'DB_PASS': credentials['db_password'], 'COST_PASS': credentials['cost_password'],
                   'LEDGER_PASS': credentials['ledger_password'], 'TEST_FIELD_KEY': credentials['field_key_base64']}
        lab.existing_project.side_effect = lambda: self.project
        lab.gate_exit.side_effect = [0, 1] if 'final-gate-error' in self.fails else None
        lab.gate_exit.return_value = 0
        lab.build.side_effect = [API_A, API_B, WEB_B]
        lab.alert_count.return_value = 0
        lab.exec.return_value = b'ai_cost=normal sink=webhook\n'
        lab.wait_alert_count.return_value = 2
        pending_synced = guard_durable = False

        def assert_authorized():
            self.assertTrue(guard_durable)
            receipt = json.loads((self.proof / JOURNAL).read_text())
            self.assertEqual(receipt, {'status': 'committed', 'instance': self.instance,
                                      'state_sha256': hashlib.sha256(staging.state_payload(self.persisted)).hexdigest()})

        def compose(*args, **kw):
            if args[:2] == ('ps', '-q'):
                return (args[2] + '-cid').encode() if args[2] in self.running else b''
            if args[0] == 'port':
                if 'port-error' in self.fails:
                    raise RuntimeError('cannot read port')
                return b'127.0.0.1:41001'
            if args[0] == 'up' and any(service in args for service in ('monitor', 'backup', 'alert-sink')):
                assert_authorized()
                self.consumers = True
                self.events.append('consumers')
            self.events.append('compose:' + args[-1])
            return b''

        def open_release(suffix, revision, ids, **kw):
            self.events.append('start-release:' + suffix)
            assert_authorized()
            selected = self.persisted['release']
            self.assertEqual((revision, *ids), (selected['revision'], selected['api_image_id'], selected['web_image_id']))
            self.assertTrue(kw.get('by_id'))
            self.public = kw.get('preview', False)
            if self.public:
                self.events.append('publish:' + suffix)
            self.running.update(api=ids[0], web=ids[1])
            if 'release-smoke-error' in self.fails:
                raise ValueError('running release smoke failed')

        def preflight_release(version, ids):
            suffix = 'b' if version == revision else 'rollback'
            self.events.append(suffix)
            self.assertEqual(self.running, {})
            if suffix == 'b' and 'replace-before-write' in self.fails:
                self.instance = 'b' * 64
                self.owner = 'foreign-stage'
            if suffix == 'rollback':
                self.interrupt('while-preparing-rollback')
            fault = 'candidate-prepare-error' if suffix == 'b' else 'rollback-prepare-error'
            if fault in self.fails:
                raise RuntimeError('image preflight failed')
            if suffix == 'rollback' and 'replace-on-rollback' in self.fails:
                self.instance = 'b' * 64
            if suffix == 'b' and 'recreate-before-write' in self.fails:
                self.created_at = '2026-11-22T00:00:01Z'

        def deploy(lab, args, *_, **kw):
            self.assertFalse(self.project)
            self.assertEqual(self.guard_status(), 'pending')
            self.assertTrue(kw.get('prepare_only'))
            self.project = True
            return None, {
                'releases': {'a': [args.previous, [API_B, WEB_B]], 'b': [args.revision, [API_A, WEB_A]]},
                'persistence_marker': self.initial['marker'],
                'business_dump_sha256': self.initial['business_dump_sha256'],
                'ledger_deadlines': self.initial['ledger_deadlines'],
                '_httpcheck_fixture': b'synthetic fixture',
            }

        def job(service, command, *, input):
            self.assertEqual((service, command, input), ('drill', 'httpcheck', b'synthetic fixture'))
            assert_authorized()
            self.events.append('httpcheck')
            if 'httpcheck-error' in self.fails:
                raise ValueError('restored HTTP check failed')

        def fenced():
            self.assertEqual(self.running, {})
            self.assertFalse(self.consumers)
            self.assertFalse(self.public)

        def close_serving():
            self.events.append('fence')
            self.running.clear()
            self.public = self.consumers = False
            if 'fence-error' in self.fails:
                raise RuntimeError('shutdown unverified')

        lab.compose.side_effect = compose
        lab.run.side_effect = self.docker
        lab.open_release.side_effect = open_release
        lab.preflight_release.side_effect = preflight_release
        lab.job.side_effect = job
        lab.fenced.side_effect = fenced
        lab.close_serving.side_effect = close_serving
        fsync = os.fsync

        def sync(fd):
            nonlocal pending_synced, guard_durable
            status = self.guard_status() if stat.S_ISDIR(os.fstat(fd).st_mode) else None
            if status == 'committed' and 'retry-sync-error' in self.fails:
                self.events.append('directory-sync-failed')
                raise OSError('injected recovery directory fsync failure')
            if status == 'committed' and pending_synced:
                if 'finish-sync-error' in self.fails:
                    self.events.append('directory-sync-failed')
                    raise OSError('injected recovery directory fsync failure')
                fsync(fd)
                guard_durable = True
                self.events.append('guard-committed')
                self.interrupt('after-guard-commit')
                return
            fsync(fd)
            if status == 'pending':
                pending_synced = True
                guard_durable = False

        out, err = io.StringIO(), io.StringIO()
        if self.persisted is None:
            previous_release = self.initial['previous_release']
            previous_revision = 'prior-revision'
        else:
            previous_release = self.persisted['release']
            previous_revision = previous_release['revision']
        composition = composition_for(previous_release)
        config = {'CI': 'true', 'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'self-hosted',
                  'T34_STAGING_STATE_VOLUME': VOLUME, 'T34_STAGING_RECOVERY_DIR': str(self.proof)}
        with mock.patch.dict(os.environ, config), \
                mock.patch.object(sys, 'argv', ['release.py', '/candidate', '/prior',
                                               revision, previous_revision, '--ci-staging',
                                               '--decoder-approvals',
                                               '/synthetic/approvals.json']), \
                mock.patch.object(release, 'Lab', return_value=lab), \
                mock.patch.object(release, 'deploy', side_effect=deploy), \
                mock.patch.object(release, '_initial_consumer_checks', side_effect=lambda lab: compose('up', 'backup')), \
                mock.patch.object(release.signal, 'signal'), \
                mock.patch.object(release.os, 'umask'), \
                mock.patch.object(release.os, 'fsync', side_effect=sync), \
                mock.patch.object(release, 'validate_release',
                                  return_value=(composition, self.initial['schema_digest'])), \
                mock.patch.object(staging, 'schema_version', return_value=self.initial['schema_version']), \
                mock.patch.object(staging, 'verify_storage'), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            if expect_error:
                with self.assertRaises((RuntimeError, ValueError, subprocess.TimeoutExpired)) as raised:
                    release.main()
                self.message = str(raised.exception)
            else:
                release.main()
        # The persistent CI entry must not dispatch generic teardown on refusal.
        lab.clean.assert_not_called()
        self.receipt = json.loads(err.getvalue()) if err.getvalue() else None
        self.output = out.getvalue()
        return lab

    def test_write_precheck_refusal_does_not_consult_foreign_a(self):
        self.fails.add('replace-before-write')
        self.run_release()
        self.assertEqual(self.events.count('read'), 1)
        self.assertNotIn('rollback', self.events)
        self.assertNotIn('create', self.events)
        self.assertEqual(self.receipt['state_reconciliation'], 'uncertain')
        self.assertTrue(self.receipt['serving_fenced'])
        self.assertEqual(self.guard_status(), 'pending')
        self.assertEqual(self.persisted, self.initial)

    def test_postwrite_replacement_with_same_owner_role_and_a_is_not_evidence(self):
        self.fails.update(('replace-after-start', 'start-error'))
        self.run_release()
        self.assertIn('probe-id', self.events)
        self.assertEqual(self.events.count('read'), 1)
        self.assertNotIn('rollback', self.events)
        self.assertEqual(self.receipt['state_reconciliation'], 'uncertain')
        self.assertEqual(self.guard_status(), 'pending')

    def test_rollback_reverification_cannot_mount_replacement_a(self):
        self.fails.update(('replace-on-rollback', 'start-error'))
        self.run_release()
        self.assertIn('rollback', self.events)
        self.assertEqual(self.events.count('read'), 2)
        self.assertNotIn('publish:rollback', self.events)
        self.assertNotIn('consumers', self.events)
        self.assertEqual(self.receipt['state_reconciliation'], 'uncertain')
        self.assertFalse(self.receipt['rollback']['succeeded'])
        self.assertTrue(self.receipt['serving_fenced'])
        self.assertEqual(self.guard_status(), 'pending')

    def test_retry_with_unsettled_writer_never_reads_or_resumes(self):
        self.fails.update(('start-error', 'remove-error'))
        self.run_release()
        self.assertTrue(self.writer)
        self.assertEqual(self.guard_status(), 'pending')
        self.events.clear()
        lab = self.run_release('retry')
        self.assertNotIn('read', self.events)
        self.assertNotIn('remove', self.events)
        self.assertTrue(self.writer)
        self.assertTrue(self.receipt['serving_fenced'])
        self.assertIn('operator', self.message)
        self.assertTrue(self.receipt['operator_verification_required'])
        lab.compose.assert_not_called()
        lab.open_release.assert_not_called()

    def test_failed_absence_probe_remains_durably_blocked_even_if_writer_gone(self):
        self.fails.update(('start-error', 'probe-error'))
        self.run_release()
        self.assertFalse(self.writer)
        self.fails.clear()
        self.events.clear()
        self.run_release('retry')
        self.assertNotIn('read', self.events)
        self.assertIn('operator', self.message)
        self.assertEqual(self.guard_status(), 'pending')

    def test_previous_legacy_mount_without_journal_is_not_ignored(self):
        (self.proof / JOURNAL).unlink()
        self.writer = True
        lab = self.run_release()
        self.assertIn('inventory', self.events)
        self.assertNotIn('read', self.events)
        self.assertIn('operator', self.message)
        self.assertTrue(self.writer)
        self.assertEqual(self.guard_status(), 'pending')
        lab.compose.assert_not_called()
        lab.start.assert_not_called()

    def test_settled_a_and_b_reconciliation_allow_following_release(self):
        for commits in (False, True):
            with self.subTest(commits=commits):
                self.fails.add('start-error')
                if commits:
                    self.fails.add('commit')
                self.run_release('release-b' if commits else 'precommit-b')
                self.assertFalse(self.writer)
                self.assertEqual(self.guard_status(), 'committed')
                self.assertFalse(self.receipt['serving_fenced'])
                self.assertEqual(self.receipt['state_reconciliation'], 'committed' if commits else 'uncommitted')
                self.assertEqual(self.running, {'api': API_B, 'web': WEB_B} if commits else
                                 {'api': API_A, 'web': WEB_A})
                starts = [event for event in self.events if event.startswith('start-release:')]
                self.assertEqual(starts, ['start-release:b' if commits else 'start-release:rollback'])
                self.fails.clear()
                self.events.clear()
        self.run_release('release-c', expect_error=False)
        self.assertEqual(self.guard_status(), 'committed')
        self.assertEqual(self.persisted['release']['revision'], 'release-c')

    def test_prewrite_failure_only_retires_guard_after_proving_original_a(self):
        self.fails.add('candidate-prepare-error')
        self.run_release()
        self.assertNotIn('create', self.events)
        self.assertIn('rollback', self.events)
        self.assertTrue(self.receipt['rollback']['succeeded'])
        self.assertEqual(self.running, {'api': API_A, 'web': WEB_A})
        self.assertEqual(self.guard_status(), 'committed')

    def test_failed_rollback_image_preflight_keeps_a_closed_and_pending(self):
        self.fails.update(('start-error', 'rollback-prepare-error'))
        self.run_release()
        self.assertEqual(self.persisted, self.initial)
        self.assertEqual(self.guard_status(), 'pending')
        self.assert_not_released(vars(self))
        self.assertTrue(self.receipt['rollback']['attempted'])
        self.assertFalse(self.receipt['rollback']['succeeded'])
        self.assertTrue(self.receipt['serving_fenced'])

    def test_other_daemon_cannot_be_used_to_settle_or_fence(self):
        self.fails.update(('start-error', 'switch-engine-after-start'))
        self.run_release()
        self.assertTrue(self.writer)
        self.assertNotIn('remove', self.events)
        self.assertNotIn('probe-id', self.events)
        self.assertNotIn('rollback', self.events)
        self.assertEqual(self.events.count('fence'), 1)  # Only on the original engine.
        self.assertIs(self.receipt['serving_fenced'], False)
        self.assertEqual(self.guard_status(), 'pending')

    def test_recreated_same_labels_wrong_creation_time_refused_on_each_call(self):
        self.fails.add('recreate-before-write')
        self.run_release()
        self.assertNotIn('create', self.events)
        self.events.clear()
        lab = self.run_release('retry')
        self.assertIn('operator', self.message)
        self.assertEqual(self.events, [])
        lab.existing_project.assert_not_called()

    def test_volume_identity_is_rechecked_after_helper_returns(self):
        self.fails.update(('start-error', 'replace-during-read'))
        self.run_release()
        self.assertEqual(self.events.count('read'), 2)
        self.assertNotIn('rollback', self.events)
        self.assertTrue(self.receipt['serving_fenced'])
        self.assertEqual(self.guard_status(), 'pending')

    def test_lost_create_acknowledgement_never_starts_or_cleans_an_unknown_id(self):
        self.fails.add('create-ack-lost')
        self.run_release()
        self.assertEqual(self.events.count('read'), 1)
        self.assertNotIn('start', self.events)
        self.assertNotIn('remove', self.events)
        self.assertTrue(self.writer)
        self.assertEqual(self.guard_status(), 'pending')

    def test_failed_legacy_writer_inventory_is_sticky_and_preserves_state(self):
        self.fails.add('inventory-error')
        self.run_release()
        self.assertEqual(self.guard_status(), 'pending')
        self.assertEqual(self.persisted, self.initial)
        self.fails.clear()
        self.events.clear()
        self.run_release('retry')
        self.assertNotIn('read', self.events)
        self.assertNotIn('rollback', self.events)
        self.assertIn('operator', self.message)

    def test_hold_survives_a_fresh_python_process_even_without_writer(self):
        self.fails.update(('start-error', 'probe-error'))
        self.run_release()
        self.assertFalse(self.writer)
        fresh = subprocess.run([sys.executable, '-c', '''
from unittest import mock
from staging_recovery import provisioned_recovery, RecoveryBlocked
lab = mock.Mock()
with provisioned_recovery(lab, "t34-state") as recovery:
    try:
        recovery.read_initial()
    except RecoveryBlocked as exc:
        assert "unresolved prior transition" in str(exc)
    else:
        raise AssertionError("prior hold lost across processes")
lab.run.assert_not_called()
'''], cwd=release.HERE, env={**os.environ, 'T34_STAGING_RECOVERY_DIR': str(self.proof),
                                 'PYTHONDONTWRITEBYTECODE': '1'}, capture_output=True, text=True)
        self.assertEqual(fresh.returncode, 0, fresh.stderr)

    def test_verified_operator_release_of_hold_can_resume(self):
        self.fails.update(('start-error', 'probe-error'))
        self.run_release()
        self.assertEqual(self.guard_status(), 'pending')
        self.assertFalse(self.writer)
        self.assertEqual(self.running, {})
        self.assertEqual(self.persisted, self.initial)
        # Simulate operator restoration of the independently verified receipt for A.
        self.seed_receipt()
        self.fails.clear()
        self.run_release('verified-retry', expect_error=False)
        self.assertEqual(self.persisted['release']['revision'], 'verified-retry')
        self.assertEqual(self.running, {'api': API_B, 'web': WEB_B})
        self.assertEqual(self.guard_status(), 'committed')

    def test_provisioned_empty_volume_initializes_then_updates(self):
        (self.proof / JOURNAL).unlink()
        self.project = self.public = self.consumers = False
        self.persisted = None
        self.running.clear()
        self.run_release('initialize-a', expect_error=False)
        self.assertIn('"lifecycle": "initialized"', self.output)
        self.assertEqual(self.persisted['release']['revision'], 'initialize-a')
        self.assertEqual(self.guard_status(), 'committed')
        self.assertEqual([event for event in self.events if event in (
            'guard-committed', 'httpcheck', 'consumers', 'start-release:b',
        )], ['guard-committed', 'httpcheck', 'consumers', 'start-release:b'])
        self.run_release('update-b', expect_error=False)
        self.assertIn('"lifecycle": "updated"', self.output)
        self.assertEqual(self.persisted['release']['revision'], 'update-b')
        self.assertEqual(self.persisted['previous_release']['revision'], 'initialize-a')
        self.assertEqual(self.guard_status(), 'committed')

    def test_missing_trusted_provision_never_adopts_volume_or_fences_foreign_project(self):
        (self.proof / 'provision.json').unlink()
        lab = self.run_release()
        self.assertIn('operator', self.message)
        lab.run.assert_not_called()
        lab.existing_project.assert_not_called()
        lab.close_serving.assert_not_called()

    def test_fixed_ci_coordinator_cannot_be_called_without_bound_recovery(self):
        lab = mock.Mock(ci_staging=True)
        with self.assertRaisesRegex(ValueError, 'operator verification required'):
            release.run_ci_staging(lab, None, self.proof, {}, self.initial['schema_digest'], VOLUME)
        lab.run.assert_not_called()
        lab.existing_project.assert_not_called()

    def interrupt(self, point):
        if point in self.fails:
            self.save_daemon()
            os.kill(os.getpid(), signal.SIGKILL)

    def save_daemon(self):
        data = {key: getattr(self, key) for key in
                ('persisted', 'project', 'running', 'writer', 'public', 'consumers', 'events')}
        (self.proof / 'daemon-mock.json').write_text(json.dumps(data))

    def fresh_process(self, fault='', *, initialize=False, retry=False, expect_error=True):
        return subprocess.run([sys.executable, '-c', '''
import json, sys
from pathlib import Path
from test_owner_checked_recovery import JOURNAL, OwnerCheckedRecovery
case = OwnerCheckedRecovery()
case.setUp()
case.proof = Path(sys.argv[1])
if sys.argv[4] == 'True':
    case.__dict__.update(json.loads((case.proof / 'daemon-mock.json').read_text()))
    case.events.clear()
if sys.argv[3] == 'True':
    (case.proof / JOURNAL).unlink()
    case.persisted = None
    case.project = case.public = case.consumers = False
    case.running.clear()
if sys.argv[2]:
    case.fails.update(sys.argv[2].split(','))
case.run_release('retry' if sys.argv[4] == 'True' else 'interrupted', expect_error=sys.argv[5] == 'True')
case.save_daemon()
''', str(self.proof), fault, str(initialize), str(retry), str(expect_error)], cwd=Path(__file__).parent,
            env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'}, capture_output=True, text=True)

    def test_sigkill_at_state_write_boundaries_leaves_no_publication_or_consumers(self):
        for initialize in (True, False):
            for point in ('before-state-write', 'after-state-write'):
                with self.subTest(initialize=initialize, point=point):
                    self.seed_receipt()
                    result = self.fresh_process(point, initialize=initialize)
                    self.assertEqual(result.returncode, -signal.SIGKILL, result.stderr)
                    stopped = json.loads((self.proof / 'daemon-mock.json').read_text())
                    self.assertEqual(self.guard_status(), 'pending')
                    self.assertTrue(stopped['writer'])
                    self.assert_not_released(stopped)
                    retry = self.fresh_process(retry=True)
                    self.assertEqual(retry.returncode, 0, retry.stderr)
                    stopped = json.loads((self.proof / 'daemon-mock.json').read_text())
                    self.assertFalse(stopped['public'])
                    self.assertFalse(stopped['consumers'])
                    self.assertEqual(stopped['events'], ['fence'])

    def daemon_snapshot(self):
        return json.loads((self.proof / 'daemon-mock.json').read_text())

    def assert_not_released(self, snapshot):
        self.assertFalse(snapshot['public'])
        self.assertFalse(snapshot['consumers'])
        self.assertFalse(any(event.startswith('start-release:') for event in snapshot['events']))
        self.assertNotIn('httpcheck', snapshot['events'])
        self.assertEqual(snapshot['running'], {})
        self.assertNotIn('publish:b', snapshot['events'])
        self.assertNotIn('publish:rollback', snapshot['events'])
        self.assertNotIn('consumers', snapshot['events'])

    def test_sigkill_before_rollback_authorization_does_not_publish_a(self):
        killed = self.fresh_process('start-error,while-preparing-rollback')
        self.assertEqual(killed.returncode, -signal.SIGKILL, killed.stderr)
        stopped = self.daemon_snapshot()
        self.assertEqual(stopped['persisted'], self.initial)
        self.assert_not_released(stopped)
        retry = self.fresh_process(retry=True)
        self.assertEqual(retry.returncode, 0, retry.stderr)
        self.assert_not_released(self.daemon_snapshot())
        self.assertEqual(self.daemon_snapshot()['events'], ['fence'])

    def test_sigkill_after_durable_guard_commit_can_converge_on_new_invocation(self):
        for initialize in (False, True):
            with self.subTest(initialize=initialize):
                killed = self.fresh_process('after-guard-commit', initialize=initialize)
                self.assertEqual(killed.returncode, -signal.SIGKILL, killed.stderr)
                self.assertEqual(self.guard_status(), 'committed')
                self.assert_not_released(self.daemon_snapshot())
                retry = self.fresh_process(retry=True, expect_error=False)
                self.assertEqual(retry.returncode, 0, retry.stderr)
                served = self.daemon_snapshot()
                self.assertEqual(served['persisted']['previous_release']['revision'], 'interrupted')
                self.assertTrue(served['public'])
                self.assertTrue(served['consumers'])
                self.assertLess(served['events'].index('probe-id'), served['events'].index('consumers'))
                self.assertLess(served['events'].index('consumers'), served['events'].index('publish:b'))
                self.seed_receipt()

    def test_finish_directory_fsync_error_requires_fresh_sync_and_matching_positive_receipt(self):
        for initialize in (False, True):
            with self.subTest(initialize=initialize):
                result = self.fresh_process('finish-sync-error', initialize=initialize)
                self.assertEqual(result.returncode, 0, result.stderr)
                stopped = self.daemon_snapshot()
                self.assertIn('directory-sync-failed', stopped['events'])
                self.assert_not_released(stopped)
                # Injection happened after rename: the new inode is visible, but
                # the next independent coordinator cannot rely on visibility alone.
                self.assertEqual(self.guard_status(), 'committed')
                retry = self.fresh_process('retry-sync-error', retry=True)
                self.assertEqual(retry.returncode, 0, retry.stderr)
                self.assert_not_released(self.daemon_snapshot())
                self.assertNotIn('read', self.daemon_snapshot()['events'])
                self.assertNotIn('create', self.daemon_snapshot()['events'])
                retry = self.fresh_process(retry=True, expect_error=False)
                self.assertEqual(retry.returncode, 0, retry.stderr)
                self.assertTrue(self.daemon_snapshot()['public'])
                self.assertTrue(self.daemon_snapshot()['consumers'])
                self.seed_receipt()

    def test_durable_update_without_matching_receipt_never_auto_adopts(self):
        for receipt in ('missing', 'prior-a', 'pending'):
            with self.subTest(receipt=receipt):
                self.seed_receipt()
                prior = (self.proof / JOURNAL).read_text()
                result = self.fresh_process('finish-sync-error')
                self.assertEqual(result.returncode, 0, result.stderr)
                # Also model a crash recovering the pre-rename pending record.
                if receipt == 'missing':
                    (self.proof / JOURNAL).unlink()
                else:
                    (self.proof / JOURNAL).write_text(prior if receipt == 'prior-a' else '{"status":"pending"}')
                retry = self.fresh_process(retry=True)
                self.assertEqual(retry.returncode, 0, retry.stderr)
                self.assert_not_released(self.daemon_snapshot())
                self.assertNotIn('create', self.daemon_snapshot()['events'])

    def test_visible_state_after_writer_fsync_error_is_not_durability_proof(self):
        self.fails.add('writer-durability-error')
        self.run_release()
        self.assertEqual(self.persisted['release']['revision'], 'new-revision')
        self.assertFalse(self.writer)
        self.assertEqual(self.guard_status(), 'pending')
        self.assertFalse(self.public)
        self.assertFalse(self.consumers)
        self.assertNotIn('publish:b', self.events)
        self.assertNotIn('consumers', self.events)

    def test_durable_b_exit_conflicting_with_a_readback_cannot_publish_either(self):
        self.fails.update(('commit', 'start-error', 'rollback-stale-read'))
        self.run_release()
        self.assertEqual(self.persisted['release']['revision'], 'new-revision')
        self.assertEqual(self.guard_status(), 'pending')
        self.assertNotIn('rollback', self.events)
        self.assert_not_released(vars(self))

    def test_final_gate_refusal_keeps_durable_candidate_fenced_and_pending(self):
        self.fails.add('final-gate-error')
        self.run_release()
        self.assertEqual(self.persisted['release']['revision'], 'new-revision')
        self.assertEqual(self.guard_status(), 'pending')
        self.assert_not_released(vars(self))

    def test_cancel_after_durable_write_settles_writer_but_does_not_publish(self):
        self.fails.add('interrupt-after-durable-write')
        self.run_release()
        self.assertEqual(self.persisted['release']['revision'], 'new-revision')
        self.assertFalse(self.writer)
        self.assertEqual(self.guard_status(), 'pending')
        self.assert_not_released(vars(self))

    def test_publication_ack_failure_fences_after_commit_without_rolling_back_state(self):
        self.fails.add('port-error')
        self.run_release()
        self.assertEqual(self.persisted['release']['revision'], 'new-revision')
        self.assertEqual(self.guard_status(), 'committed')
        self.assertIn('publish:b', self.events)
        self.assertNotIn('rollback', self.events)
        self.assertFalse(self.public)
        self.assertFalse(self.consumers)
        self.assertTrue(self.receipt['serving_fenced'])

    def test_initial_httpcheck_failure_after_commit_prevents_serving_start(self):
        failed = self.fresh_process('httpcheck-error', initialize=True)
        self.assertEqual(failed.returncode, 0, failed.stderr)
        stopped = self.daemon_snapshot()
        self.assertEqual(self.guard_status(), 'committed')
        self.assertEqual(stopped['running'], {})
        self.assertFalse(stopped['public'])
        self.assertLess(stopped['events'].index('guard-committed'), stopped['events'].index('httpcheck'))
        self.assertNotIn('consumers', stopped['events'])
        self.assertNotIn('start-release:b', stopped['events'])

    def test_failed_running_release_smoke_fences_the_authorized_version(self):
        for rollback in (False, True):
            with self.subTest(rollback=rollback):
                self.persisted = copy.deepcopy(self.initial)
                self.seed_receipt()
                self.fails.add('release-smoke-error')
                suffix, revision = ('rollback', self.initial['release']['revision']) if rollback else (
                    'b', 'new-revision')
                if rollback:
                    self.fails.add('start-error')
                self.run_release()
                start = self.events.index('start-release:' + suffix)
                self.assertLess(self.events.index('guard-committed'), start)
                self.assertGreater(self.events.index('fence', start), start)
                self.assertEqual(self.persisted['release']['revision'], revision)
                self.assertEqual(self.running, {})
                self.assertFalse(self.public)
                self.assertFalse(self.consumers)
                self.assertTrue(self.receipt['serving_fenced'])
                self.fails.clear()
                self.events.clear()

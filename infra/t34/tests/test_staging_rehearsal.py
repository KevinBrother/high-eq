import contextlib
import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from test_gate import CREATED, HORIZON
from test_staging import API_A, SEAL, fixture, release


class FrozenDeletionWitnessRegression(unittest.TestCase):
    def exercise_deploy(self, *, changed_at=None, fail_candidate=False, fail_missing_root_probe=False,
                        lose_del_receipt=False, ignore_cli_db=False, prepare_only=False):
        subject = mock.Mock()
        subject.name = 'synthetic-install'
        subject.source = Path('/synthetic/source')
        subject.env = dict(CHALLENGE='challenge', ALERT_WEBHOOK=release.ALERT_WEBHOOK)
        subject.env.update({k: 'local-image' for k in ('PG_IMAGE', 'REDIS_IMAGE', 'DRILL_IMAGE', 'OPS_IMAGE', 'SINK_IMAGE')})
        subject.build.return_value = API_A
        subject.gate_exit.side_effect = [0] * (4 if prepare_only else 3)
        subject.compose.return_value = b'id-or-port\n'
        subject.run.side_effect = lambda action, *args: b'78\n' if action == 'wait' else b'image-id\n'
        subject.sql.side_effect = ['0', SEAL]
        subject.wait_alert_count.return_value = 2
        subject.alert_count.return_value = 0
        seed = fixture()
        physical = seed['Windows'][0]
        logical = '44444444-4444-8444-8444-444444444444'
        cutoff = CREATED + HORIZON + 100_000
        seed['Expected'].append(logical)
        seed['WindowCutoffs'] = dict.fromkeys((physical, logical), cutoff)
        plan = {'physical': physical, 'logical': logical, 'cutoff_ms': cutoff}
        original = {root: seed['WindowCutoffs'].get(root, CREATED + HORIZON)
                    for root in seed['Expected']}
        live = original.copy()
        scratch = {}
        audited = []
        calls = []

        def compose(*args, **kwargs):
            if prepare_only:
                self.assertFalse(kwargs.get('preview'))
                if args[0] == 'up':
                    self.assertFalse({'api', 'web', 'monitor', 'backup', 'alert-sink'} & set(args))
            if args == ('restart', 'ledger') and changed_at == 'restart':
                live[seed['Expected'][0]] += 1_000
            return b'id-or-port\n'

        def job(service, command, *args, **kwargs):
            if command == 'seed':
                return json.dumps(seed).encode()
            if command == 'delete':
                return json.dumps({'seal': SEAL, 'writes': {
                    root: [CREATED, CREATED, seed['WindowCutoffs'].get(root, 0)]
                    for root in original}}).encode()
            if command == 'restore-plan':
                return json.dumps(plan).encode()
            if command == 'restore' and service == 'backup':
                return b'restore_ok\n'
            if command == 'restore' and service == 'drill':
                # Mirror the isolated drill's restore connection; no other op uses DB 1.
                calls.append(('restore-saw-verified-copy', bool(scratch)))
                if scratch:
                    self.assertEqual(scratch, original)
                    scratch[seed['Expected'][0]] += 1_000  # Real Resume can remark an existing root.
                if changed_at == 'restore':
                    live[seed['Expected'][0]] += 1_000
                return json.dumps({'window': plan, 'before_ms': CREATED, 'after_ms': CREATED + 1000}).encode()
            return b''

        def inventory(_):
            audited.append(live.copy())
            return SEAL, live.copy()

        def docker_exec(service, name, *args, **kwargs):
            if service == 'backup':
                return b'backup_fresh\n'
            self.assertEqual((service, name), ('ledger', 'redis-cli'))
            if args[:2] == ('--raw', 'EVAL'):
                script = args[2]
                if 'COPY' in script:
                    self.assertEqual(json.loads(args[-1]), original)
                    self.assertEqual(args[-2], SEAL)
                    scratch.update(live)
                    return b'1\n'
                # Model the server's SELECT taking precedence over CLI state.
                db = '0' if ignore_cli_db else '1'
                if "redis.call('SELECT',1)" in script:
                    db = '1'
                ledger = scratch if db == '1' else live
                if isinstance(args[-1], int):
                    root, deadline = args[-2:]
                    self.assertEqual(ledger[root], deadline)
                    del ledger[root]
                    calls.append(('del-db', db))
                    if lose_del_receipt:
                        raise subprocess.TimeoutExpired('docker exec', 15)
                else:
                    missing = args[-1]
                    self.assertIn(set(original) - set(ledger), (set(), {missing}))
                    ledger.clear()
                return b'1\n'
            self.fail('a fault-injection write must never target the authoritative ledger')

        def probe_missing_root(root):
            self.assertEqual(set(original) - set(scratch), {root})
            self.assertEqual(live, original)
            if fail_missing_root_probe:
                raise RuntimeError('gate probe failed')

        subject.probe_missing_root.side_effect = probe_missing_root

        def open_release(suffix, *args, **kwargs):
            calls.append(('open', suffix))
            if suffix == 'b' and fail_candidate:
                raise RuntimeError('candidate failed')

        subject.compose.side_effect = compose
        subject.job.side_effect = job
        subject.exec.side_effect = docker_exec
        subject.open_release.side_effect = open_release
        args = SimpleNamespace(prior=Path('/synthetic/old'), ci_staging=True,
                               preview=False, stage_test=False, revision='new', previous='old')
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(release, 'backup', return_value=('snap-demo', {'sha256': '9' * 64, 'max_days': 45}, None)), \
                mock.patch.object(release, 'check'), mock.patch.object(release, 'cost_cases'), \
                mock.patch.object(release, 'inventory', side_effect=inventory), \
                mock.patch.object(release, 'seed_monitor_rows'), \
                mock.patch.object(release, 'failed_delivery_is_visible'), \
                contextlib.redirect_stdout(io.StringIO()):
            if fail_candidate:
                with self.assertRaisesRegex(RuntimeError, 'candidate failed'):
                    release.deploy(subject, args, Path(directory), {}, 'e' * 64, announce=False)
            elif lose_del_receipt:
                with self.assertRaises(subprocess.TimeoutExpired):
                    release.deploy(subject, args, Path(directory), {}, 'e' * 64, announce=False)
                self.assertEqual(live, original, 'losing the DEL response must not lose an authoritative root')
                self.assertIn(('del-db', '1'), calls)
                self.assertEqual(scratch, {})
                subject.probe_missing_root.assert_not_called()
                self.assertEqual(len([call for call in calls if call[0] == 'open']), 4)
            elif fail_missing_root_probe:
                with self.assertRaisesRegex(RuntimeError, 'gate probe failed'):
                    release.deploy(subject, args, Path(directory), {}, 'e' * 64, announce=False)
                self.assertEqual(live, original)
                self.assertEqual(scratch, {})
            elif changed_at:
                with self.assertRaisesRegex(ValueError, 'changed deletion deadlines'):
                    release.deploy(subject, args, Path(directory), {}, 'e' * 64, announce=False)
                self.assertEqual(audited[0], original)
                self.assertEqual(len([call for call in calls if call[0] == 'open']), 4)
                subject.gate_exit.assert_not_called()
            else:
                address, result = release.deploy(subject, args, Path(directory), {}, 'e' * 64,
                                                 announce=False, prepare_only=prepare_only)
                if prepare_only:
                    self.assertIsNone(address)
                    subject.wait_alert_count.assert_not_called()
                    subject.open_release.assert_not_called()
                    self.assertNotIn(('drill', 'httpcheck'), [call.args[:2] for call in subject.job.call_args_list])
                    subject.preflight_release.assert_called_once_with('old', [API_A, API_A])
                    self.assertEqual(result['result'], 'prepared')
                    self.assertFalse(result['same_schema_rollback']['verified'])
                    self.assertNotIn('httpcheck', result)
                    self.assertEqual(result['_httpcheck_fixture'], json.dumps(seed).encode())
                self.assertEqual(result['ledger_deadlines'], original)
                self.assertEqual(audited, [original] * 4)
                self.assertEqual(live, original)
                self.assertEqual(scratch, {})
        return calls

    def test_restart_or_replay_cannot_replace_first_deadline_witness(self):
        for changed_at in ('restart', 'restore'):
            with self.subTest(changed_at=changed_at):
                self.exercise_deploy(changed_at=changed_at)

    def test_replay_only_remarks_scratch_and_final_state_uses_original_deadlines(self):
        calls = self.exercise_deploy()
        self.assertIn(('restore-saw-verified-copy', True), calls)

    def test_del_applies_but_docker_times_out_without_losing_any_authoritative_root(self):
        for ignore_cli_db in (False, True):
            with self.subTest(ignore_cli_db=ignore_cli_db):
                self.exercise_deploy(lose_del_receipt=True, ignore_cli_db=ignore_cli_db)

    def test_failed_missing_root_probe_keeps_the_original_ledger_and_clears_scratch(self):
        self.exercise_deploy(fail_missing_root_probe=True)

    def test_initial_candidate_failure_does_not_restart_a_before_fence(self):
        self.assertEqual(self.exercise_deploy(fail_candidate=True), [('open', 'a'), ('open', 'b')])

    def test_fixed_initial_preparation_leaves_serving_and_http_runtime_stopped(self):
        self.exercise_deploy(prepare_only=True)

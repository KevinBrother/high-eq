import contextlib
import copy
import io
import json
import subprocess
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from test_staging import (API_A, API_B, WEB_A, WEB_B, composition_for,
                          init_composition, release, staging, state)
from lab import Lab


class StagingFailureRegression(unittest.TestCase):
    def attempt(self, *, initial, failure, rollback_fails=False, fence_fails=False):
        lab = mock.Mock()
        retained = None if initial else state()
        lab.name = 't34-ci-staging'
        lab.env = {'ALERT_WEBHOOK': release.ALERT_WEBHOOK}
        lab.existing_project.return_value = not initial
        lab.build.side_effect = [API_A, API_A, WEB_A]
        lab.alert_count.return_value = 0
        lab.gate_exit.return_value = 0
        lab.exec.return_value = b'ai_cost=normal sink=webhook\n'
        lab.compose.return_value = b'127.0.0.1:41001\n'
        saved_state = copy.deepcopy(retained)
        working_state = state()
        composition = (composition_for(retained['release']) if retained
                       else init_composition())
        previous_revision = (retained['release']['revision'] if retained
                             else working_state['previous_release']['revision'])
        current_ids = ([retained['release']['api_image_id'], retained['release']['web_image_id']]
                       if retained else None)
        running = dict(zip(('api', 'web'), current_ids)) if current_ids else {}
        services = {'db', 'cache', 'restored', 'coldcache', 'ledger', 'web', 'api', 'monitor', 'backup', 'alert-sink'}
        assets = {'state-volume', 'postgres-volume', 'ledger-volume', 'snapshots', 'ledger-contents'}
        original_assets = assets.copy()
        output, error = io.StringIO(), io.StringIO()

        def compose(*args, **kwargs):
            if args[:2] == ('ps', '-q') and len(args) == 3 and args[2] in running:
                return (args[2] + '-cid\n').encode()
            if args[:1] == ('port',):
                return b'127.0.0.1:41001\n'
            return b''

        def docker(*args, **kwargs):
            if args[:3] == ('inspect', '--format', '{{.Image}}'):
                service = args[3].split('-', 1)[0]
                if service in running:
                    return running[service].encode()
                raise ValueError('running image unavailable')
            self.fail(f'unexpected Docker operation: {args}')

        def deploy(*args, **kwargs):
            if failure == 'deploy':
                raise RuntimeError('deployment failed after starting services')
            return '127.0.0.1:41001', {
                'releases': {'a': ['old-revision', [API_B, WEB_B]]},
                'persistence_marker': working_state['marker'],
            }

        def open_release(suffix, *args, **kwargs):
            if suffix == 'rollback' and rollback_fails:
                raise ValueError('could not restore previous running images')
            _, ids = args[0], args[1]
            running.update(api=ids[0], web=ids[1])

        def close_serving():
            if fence_fails:
                raise RuntimeError('cannot verify serving shutdown')
            services.intersection_update({'db', 'cache', 'restored', 'coldcache', 'ledger'})

        lab.open_release.side_effect = open_release
        lab.compose.side_effect = compose
        lab.run.side_effect = docker
        lab.close_serving.side_effect = close_serving
        with mock.patch.object(staging, 'require_state_volume'), \
                mock.patch.object(staging, 'read_state', return_value=retained), \
                mock.patch.object(staging, 'schema_version', return_value=working_state['schema_version']), \
                mock.patch.object(release, 'deploy', side_effect=deploy), \
                mock.patch.object(staging, 'build_state', return_value=working_state), \
                mock.patch.object(staging, 'verify_storage', side_effect=
                                  ValueError('storage failed') if failure == 'storage' else None), \
                mock.patch.object(staging, 'write_state', side_effect=ValueError('write failed')), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(error):
            with self.assertRaises((ValueError, RuntimeError)):
                release.run_ci_staging(
                    lab, SimpleNamespace(source=Path('/synthetic'), revision='new-revision',
                                         previous=previous_revision),
                    Path('/synthetic'), composition, working_state['schema_digest'], 't34-state')
        if not fence_fails:
            self.assertEqual(services, {'db', 'cache', 'restored', 'coldcache', 'ledger'})
        self.assertEqual(assets, original_assets)
        self.assertEqual(retained, saved_state)
        lab.close_serving.assert_called_once_with()
        if initial:
            lab.open_release.assert_not_called()
        lab.clean.assert_not_called()
        self.assertEqual(output.getvalue(), '')
        receipt = json.loads(error.getvalue())
        self.assertEqual(receipt['result'], 'synthetic-failed')
        self.assertIs(receipt['serving_fenced'], not fence_fails)
        return receipt['rollback']

    def test_initialization_and_update_fence_when_rollback_fails(self):
        for initial in (True, False):
            with self.subTest(initial=initial):
                rollback = self.attempt(initial=initial, failure='write', rollback_fails=True)
                self.assertIs(rollback['attempted'], not initial)
                self.assertIs(rollback['succeeded'], None if initial else False)

    def test_initialization_failure_during_deploy_still_fences(self):
        rollback = self.attempt(initial=True, failure='deploy')
        self.assertIs(rollback['attempted'], False)

    def test_unproven_storage_fences_both_lifecycles(self):
        for initial in (True, False):
            with self.subTest(initial=initial):
                rollback = self.attempt(initial=initial, failure='storage')
                self.assertIs(rollback['attempted'], False)

    def test_initialization_without_signed_state_fences_without_trying_a(self):
        rollback = self.attempt(initial=True, failure='write')
        self.assertIs(rollback['attempted'], False)

    def test_failed_rollback_does_not_report_an_unverified_shutdown_as_fenced(self):
        rollback = self.attempt(initial=False, failure='write', rollback_fails=True, fence_fails=True)
        self.assertIs(rollback['succeeded'], False)


class StateAcknowledgementRegression(unittest.TestCase):
    """Offline failures around the atomic state-file commit and its acknowledgement."""

    def attempt(self, *, write_mode, read_after_fails=False, rollback_fails=False,
                running_after_write=None, fence_fails=False):
        initial = state()
        # This regression starts on the signed-off A release and deploys B.
        initial['release'] = {
            **initial['release'],
            'api_image_id': API_A,
            'web_image_id': WEB_A,
        }
        initial['history'] = [copy.deepcopy(initial['release'])]
        persisted = copy.deepcopy(initial)
        running = {'api': API_A, 'web': WEB_A}
        candidate_ids = [API_B, WEB_B]
        output, error = io.StringIO(), io.StringIO()
        read_count = 0
        write_secret = 'cafebabe' * 6

        lab = mock.Mock()
        lab.name = initial['installation']
        lab.source = Path('/synthetic')
        lab.env = {'ALERT_WEBHOOK': release.ALERT_WEBHOOK}
        lab.existing_project.return_value = True
        lab.build.side_effect = [API_A, API_B, WEB_B]
        lab.alert_count.return_value = 0
        lab.gate_exit.return_value = 0

        def compose(*args, **kwargs):
            if args[:2] == ('ps', '-q') and len(args) == 3 and args[2] in running:
                return (args[2] + '-cid\n').encode()
            if args[:1] == ('port',):
                return b'127.0.0.1:41001\n'
            if args[:1] in (('up',), ('down',), ('stop',), ('kill',), ('rm',), ('create',)):
                return b''
            self.fail(f'unexpected compose operation: {args}')

        def run(*args, **kwargs):
            if args[:2] == ('inspect', '--format') and args[2] == '{{.Image}}':
                service = args[3].split('-', 1)[0]
                if service not in running:
                    raise ValueError('running image unavailable')
                return running[service].encode()
            self.fail(f'unexpected docker operation: {args}')

        def exec_command(service, *args, **kwargs):
            self.assertEqual(service, 'monitor')
            if args[-1] == 'monitor-once':
                return b'ai_cost=normal sink=webhook\n'
            if args[-1] == 'monitor-probe':
                return b''
            self.fail(f'unexpected exec operation: {args}')

        def read_state(*args, **kwargs):
            nonlocal read_count
            read_count += 1
            if read_after_fails and read_count > 1:
                raise ValueError('staging state file unreadable')
            return copy.deepcopy(persisted)

        def write_state(lab_, volume, stored, installation):
            nonlocal persisted
            if write_mode == 'ack-lost':
                persisted = copy.deepcopy(stored)
                if running_after_write is not None:
                    running.update(running_after_write)
            raise ValueError('write acknowledgement lost: ' + write_secret)

        def open_release(suffix, version, ids, **kwargs):
            if suffix == 'b':
                running.update(api=ids[0], web=ids[1])
                return
            if suffix == 'rollback':
                if rollback_fails:
                    raise RuntimeError('rollback refused')
                running.update(api=ids[0], web=ids[1])
                return
            self.fail(f'unexpected release: {suffix}')

        def close_serving():
            if fence_fails:
                raise RuntimeError('cannot verify serving shutdown')
            running.clear()

        lab.compose.side_effect = compose
        lab.run.side_effect = run
        lab.exec.side_effect = exec_command
        lab.open_release.side_effect = open_release
        lab.close_serving.side_effect = close_serving

        args = SimpleNamespace(
            source=Path('/synthetic'), revision='new-revision',
            previous=initial['release']['revision'],
        )
        composition = composition_for(initial['release'])
        with mock.patch.object(staging, 'require_state_volume'), \
                mock.patch.object(staging, 'read_state', side_effect=read_state), \
                mock.patch.object(staging, 'schema_version', return_value=initial['schema_version']), \
                mock.patch.object(staging, 'verify_storage'), \
                mock.patch.object(staging, 'write_state', side_effect=write_state), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(error):
            with self.assertRaises(ValueError) as raised:
                release.run_ci_staging(lab, args, Path('/synthetic'), composition,
                                       initial['schema_digest'], 't34-state')
        receipt = json.loads(error.getvalue())
        return SimpleNamespace(
            initial=initial, persisted=persisted, running=running, lab=lab,
            output=output.getvalue(), error=error.getvalue(), receipt=receipt,
            write_secret=write_secret, exception=raised.exception,
        )

    def test_committed_write_with_lost_ack_keeps_candidate_and_preserves_error_type(self):
        result = self.attempt(write_mode='ack-lost')
        self.assertEqual(result.persisted['release']['revision'], 'new-revision')
        self.assertEqual(result.running, {'api': API_B, 'web': WEB_B})
        self.assertEqual(result.receipt['state_reconciliation'], 'committed')
        self.assertIs(result.receipt['serving_fenced'], False)
        self.assertEqual(result.receipt['state_write_error'], 'ValueError')
        self.assertNotIn(result.write_secret, result.error)
        self.assertNotIn(result.write_secret, str(result.exception))
        self.assertIsInstance(result.exception.__cause__, ValueError)
        result.lab.close_serving.assert_not_called()
        self.assertEqual([call.args[0] for call in result.lab.open_release.call_args_list], ['b'])

    def test_precommit_write_failure_rolls_back_candidate_then_verifies_previous(self):
        result = self.attempt(write_mode='precommit')
        self.assertEqual(result.persisted['release']['revision'], 'current-revision')
        self.assertEqual(result.running, {'api': API_A, 'web': WEB_A})
        self.assertEqual(result.receipt['state_reconciliation'], 'uncommitted')
        self.assertIs(result.receipt['serving_fenced'], False)
        self.assertEqual([call.args[0] for call in result.lab.open_release.call_args_list],
                         ['b', 'rollback'])
        self.assertIs(result.receipt['rollback']['succeeded'], True)
        self.assertNotIn(result.write_secret, str(result.exception))
        self.assertIsInstance(result.exception.__cause__, ValueError)
        result.lab.close_serving.assert_not_called()

    def test_untrusted_state_read_fences_without_rollback(self):
        result = self.attempt(write_mode='precommit', read_after_fails=True)
        self.assertEqual(result.running, {})
        self.assertEqual(result.receipt['state_reconciliation'], 'uncertain')
        self.assertIs(result.receipt['serving_fenced'], True)
        self.assertNotIn(result.write_secret, str(result.exception))
        self.assertEqual([call.args[0] for call in result.lab.open_release.call_args_list], ['b'])

    def test_rollback_failure_fences_and_does_not_claim_verified_shutdown(self):
        result = self.attempt(write_mode='precommit', rollback_fails=True, fence_fails=True)
        self.assertEqual(result.receipt['state_reconciliation'], 'uncommitted')
        self.assertIs(result.receipt['rollback']['attempted'], True)
        self.assertIs(result.receipt['rollback']['succeeded'], False)
        self.assertIs(result.receipt['serving_fenced'], False)
        self.assertNotIn(result.write_secret, str(result.exception))

    def test_committed_state_with_previous_running_release_fences(self):
        result = self.attempt(write_mode='ack-lost',
                              running_after_write={'api': API_A, 'web': WEB_A})
        self.assertEqual(result.persisted['release']['revision'], 'new-revision')
        self.assertEqual(result.running, {})
        self.assertEqual(result.receipt['state_reconciliation'], 'uncertain')
        self.assertIs(result.receipt['serving_fenced'], True)
        self.assertEqual([call.args[0] for call in result.lab.open_release.call_args_list], ['b'])


class LateStateWriterRegression(unittest.TestCase):
    """A state helper that outlives its client must never write after reconciliation."""

    def reconcile(self, *, writer_settles):
        initial = state()
        initial['release'] = {
            **initial['release'],
            'api_image_id': API_A,
            'web_image_id': WEB_A,
        }
        initial['history'] = [copy.deepcopy(initial['release'])]
        candidate = copy.deepcopy(initial)
        candidate['release'] = {
            **candidate['release'],
            'revision': 'new-revision',
            'api_image_id': API_B,
            'web_image_id': WEB_B,
        }
        candidate['history'] = [copy.deepcopy(candidate['release'])]
        persisted = copy.deepcopy(initial)
        running = {'api': API_B, 'web': WEB_B}
        writer = {'id': None, 'alive': False}
        events = []
        secret = 'deadbeef' * 6
        error = io.StringIO()
        lab = mock.Mock()
        lab.name = initial['installation']
        lab.env = {'PG_IMAGE': 'postgres:17.6-alpine'}

        def compose(*args, **kwargs):
            if args[:2] == ('ps', '-q') and len(args) == 3 and args[2] in running:
                return (args[2] + '-cid\n').encode()
            self.fail(f'unexpected compose operation: {args}')

        def run(*args, **kwargs):
            if args[:2] == ('volume', 'inspect'):
                return json.dumps({
                    staging.OWNER_LABEL: lab.name,
                    staging.ROLE_LABEL: 'state',
                }).encode()
            if args[:3] == ('inspect', '--format', '{{.Image}}'):
                service = args[3].split('-', 1)[0]
                return running[service].encode()
            # Handle the pre-fix launch shape so this regression demonstrates the
            # actual late-write race instead of failing on an unexpected argv.
            if args[:2] == ('run', '--rm'):
                writer['alive'] = True
                events.append('legacy-start')
                raise RuntimeError('write acknowledgement lost: ' + secret)
            if args[:1] == ('create',):
                writer['id'] = 'f' * 64
                writer['alive'] = False
                events.append('create')
                return writer['id'].encode()
            if args[:1] == ('start',):
                writer['alive'] = True
                events.append('start')
                raise subprocess.TimeoutExpired('docker start', 120)
            if args[:2] == ('rm', '-f'):
                events.append('remove')
                if not writer_settles:
                    raise subprocess.TimeoutExpired('docker rm', 30)
                writer['alive'] = False
                return b''
            if args[:1] == ('ps',):
                events.append('probe')
                return ((writer['id'] + '\n').encode()
                        if writer['alive'] else b'')
            self.fail(f'unexpected docker operation: {args}')

        def read_state(*args, **kwargs):
            events.append('read')
            if writer['alive']:
                # A late helper commits B after the failure was observed.
                persisted.update(copy.deepcopy(candidate))
                events.append('late-commit')
            return copy.deepcopy(persisted)

        def open_release(suffix, version, ids, **kwargs):
            self.assertEqual(suffix, 'rollback')
            running.update(api=ids[0], web=ids[1])

        def close_serving():
            running.clear()

        lab.compose.side_effect = compose
        lab.run.side_effect = run
        lab.open_release.side_effect = open_release
        lab.close_serving.side_effect = close_serving
        args = SimpleNamespace(revision='new-revision')
        with mock.patch.object(staging, 'validate_state'), \
                mock.patch.object(staging, 'read_state', side_effect=read_state), \
                contextlib.redirect_stderr(error):
            with self.assertRaises(ValueError) as raised:
                try:
                    staging.write_state(lab, 't34-state', candidate, lab.name)
                except BaseException as exc:
                    release._reconcile_state_write(
                        lab, args, initial, candidate, 't34-state', {},
                        initial['schema_version'], exc)
        return SimpleNamespace(
            events=events, persisted=persisted, running=running, lab=lab,
            receipt=json.loads(error.getvalue()), exception=raised.exception,
            secret=secret,
        )

    def test_late_writer_is_settled_before_a_is_treated_as_uncommitted(self):
        result = self.reconcile(writer_settles=True)
        self.assertLess(result.events.index('remove'), result.events.index('read'))
        self.assertLess(result.events.index('probe'), result.events.index('read'))
        self.assertNotIn('late-commit', result.events)
        self.assertEqual(result.persisted['release']['revision'], 'current-revision')
        self.assertEqual(result.running, {'api': API_A, 'web': WEB_A})
        self.assertEqual(result.receipt['state_reconciliation'], 'uncommitted')
        self.assertIs(result.receipt['serving_fenced'], False)
        self.assertIs(result.receipt['rollback']['succeeded'], True)
        result.lab.open_release.assert_called_once()
        result.lab.close_serving.assert_not_called()
        self.assertIn('previous release restored and verified', str(result.exception))
        self.assertNotIn(result.secret, str(result.exception))

    def test_unsettled_late_writer_fences_without_reading_a_or_claiming_rollback(self):
        result = self.reconcile(writer_settles=False)
        self.assertLess(result.events.index('remove'), result.events.index('probe'))
        self.assertNotIn('read', result.events)
        self.assertNotIn('late-commit', result.events)
        self.assertEqual(result.running, {})
        self.assertEqual(result.receipt['state_reconciliation'], 'uncertain')
        self.assertIs(result.receipt['serving_fenced'], True)
        self.assertIs(result.receipt['rollback']['attempted'], False)
        self.assertEqual(result.receipt['state_write_error'], 'StateWriteUncertain')
        result.lab.open_release.assert_not_called()
        result.lab.close_serving.assert_called_once_with()
        result.lab.clean.assert_not_called()
        message = str(result.exception)
        self.assertIn('state writer could not be proven settled', message)
        self.assertNotIn('restored and verified', message)
        self.assertNotIn(result.secret, message)
        self.assertNotIn(result.secret, result.lab.mock_calls and str(result.receipt))


class ExistingProjectStateRegression(unittest.TestCase):
    def run_stage(self, payload, *, owner='t34-ci-staging', ps_fails=False, project_label=True):
        subject = object.__new__(Lab)
        subject.name = 't34-ci-staging'
        subject.env = {}
        services = {'a': 'api', 'w': 'web', 'm': 'monitor', 'b': 'backup',
                    's': 'alert-sink', 'l': 'ledger', 'r': 'restored', 'c': 'coldcache'}
        storage = {'l', 'r', 'c'}
        other_project = {'other-api': 'running'}
        assets = {'state': payload, 'vault': b'backup data', 'ledger': b'original deletions'}
        original = assets.copy()

        def docker(*args, **kwargs):
            if args[:2] == ('volume', 'inspect'):
                return json.dumps({staging.OWNER_LABEL: owner, staging.ROLE_LABEL: 'state'}).encode()
            if args[0] in ('container', 'network', 'volume') and args[1] == 'ls':
                self.assertIn('--filter=label=com.docker.compose.project=t34-ci-staging', args)
                return b'a\n' if project_label else b''
            if args[:2] == ('run', '--rm'):
                self.assertIn('t34-state:/state:ro', args)
                return assets['state']
            if args[0] == 'ps':
                self.assertIn('--filter=label=com.docker.compose.project=t34-ci-staging', args)
                if ps_fails:
                    raise subprocess.TimeoutExpired('ps', 15)
                return '\n'.join(f'{cid} {name}' for cid, name in services.items()).encode()
            if args[:3] == ('stop', '--time', '5'):
                for cid in args[3:]:
                    self.assertNotIn(cid, storage)
                    services.pop(cid)
                return b''
            self.fail(f'unexpected Docker operation: {args[0]}')

        def compose(*args, **kwargs):
            action = args[2] if args[:2] == ('--profile', '*') else args[0]
            self.assertIn(action, {'stop', 'kill'})
            for cid, name in list(services.items()):
                if name in args:
                    self.assertNotIn(cid, storage)
                    services.pop(cid)
            return b''  # A successful stop is not evidence that the post-check succeeded.

        subject.run = mock.Mock(side_effect=docker)
        subject.compose = mock.Mock(side_effect=compose)
        output, error = io.StringIO(), io.StringIO()
        with mock.patch.object(staging, 'schema_version', return_value=state()['schema_version']), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(error):
            with self.assertRaises(ValueError):
                release.run_ci_staging(subject, SimpleNamespace(source=Path('/synthetic'), revision='new'),
                                       Path('/synthetic'), {}, state()['schema_digest'], 't34-state')
        self.assertEqual(assets, original)
        self.assertEqual(other_project, {'other-api': 'running'})
        self.assertEqual(output.getvalue(), '')
        return services, error.getvalue()

    def test_owned_existing_project_with_absent_corrupt_or_unwitnessed_state_is_fenced(self):
        no_deadlines = state()
        del no_deadlines['ledger_deadlines']
        for payload in (staging.ABSENT_STATE.encode(), b'{broken', json.dumps(no_deadlines).encode()):
            with self.subTest(payload_type=payload[:8]):
                services, receipt = self.run_stage(payload)
                self.assertEqual(set(services), {'l', 'r', 'c'})
                self.assertIs(json.loads(receipt)['serving_fenced'], True)

    def test_unknown_owner_is_not_stopped(self):
        for opts in ({'owner': 'someone-else'}, {'project_label': False}):
            with self.subTest(opts=opts):
                services, receipt = self.run_stage(b'{broken', **opts)
                self.assertEqual(set(services), {'a', 'w', 'm', 'b', 's', 'l', 'r', 'c'})
                self.assertEqual(receipt, '')

    def test_stop_success_with_unavailable_final_enumeration_reports_fenced_false(self):
        services, receipt = self.run_stage(b'{broken', ps_fails=True)
        self.assertEqual(set(services), {'l', 'r', 'c'})
        self.assertIs(json.loads(receipt)['serving_fenced'], False)

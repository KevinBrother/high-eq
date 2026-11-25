import contextlib
import copy
import hashlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

HERE = Path(__file__).resolve().parents[1]
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
import lab
import release
import staging
from test_staging import ADMISSION_CURRENT, ADMISSION_PREVIOUS, composition_for


class ReleaseContract(unittest.TestCase):
    def test_locked_runtime_composition_matches_the_archive(self):
        runtime = ROOT / 'server/internal/service/runtime.go'
        self.assertEqual(lab.COMPOSITION, hashlib.sha256(runtime.read_bytes()).hexdigest())

    def test_d13_composition_identifies_startup_and_periodic_cleanup(self):
        receipt = lab.composition_receipt(ROOT)
        self.assertEqual(receipt['chat_imports'], {
            'retention_hours': 24, 'startup': 'best-effort', 'retry_interval_seconds': 60,
        })
        self.assertIn('ScoreCompleted:s.Growth.Consume', receipt['effects'])

    def test_d13_composition_refuses_periodic_cleanup_drift(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp)
            for path in ('server/internal/service/runtime.go', 'server/cmd/api/main.go',
                         'server/internal/training/chat_imports.go'):
                target = source / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes((ROOT / path).read_bytes())
            main = source / 'server/cmd/api/main.go'
            main.write_text(main.read_text().replace('time.NewTicker(time.Minute)',
                                                    'time.NewTicker(time.Hour)'))
            with self.assertRaisesRegex(ValueError, 'runtime API maintenance changed'):
                lab.composition_receipt(source)

    def test_release_checks_rollback_schema_before_runtime_or_approvals(self):
        with tempfile.TemporaryDirectory() as tmp:
            prior = Path(tmp) / 'prior'
            migrations = prior / 'server/migrations'
            migrations.mkdir(parents=True)
            (migrations / '0001.up.sql').write_text('select 1;')
            with self.assertRaisesRegex(ValueError, 'schema differs: no automatic binary rollback'):
                release.validate_release(ROOT, prior, 'd' * 40, Path(tmp) / 'missing-approval')

    def test_d13_composition_refuses_unreviewed_runtime_and_sweeper_changes(self):
        cases = (
            ('server/internal/service/runtime.go', 's.initPractice()', 's.initPractice()\n\ts.initPractice()',
             'offline recovery inventory requires review against runtime'),
            ('server/internal/service/runtime.go', 's.Bus.ScoreCompleted.Subscribe(s.Growth.Consume)',
             's.Bus.ScoreCompleted.Subscribe(s.Plans.ConsumeScore)', 'runtime event effects changed'),
            ('server/internal/training/chat_imports.go', '24 * time.Hour', '25 * time.Hour',
             'runtime chat import retention implementation changed'),
        )
        runtime_inputs = ('server/internal/service/runtime.go', *(row[0] for row in lab.RUNTIME_FILES))
        for changed, before, after, expected in cases:
            with self.subTest(changed=changed, expected=expected), tempfile.TemporaryDirectory() as tmp:
                source = Path(tmp)
                for path in runtime_inputs:
                    target = source / path
                    target.parent.mkdir(parents=True, exist_ok=True)
                    text = (ROOT / path).read_text()
                    target.write_text(text.replace(before, after, 1) if path == changed else text)
                with self.assertRaisesRegex(ValueError, expected):
                    lab.composition_receipt(source)

    def test_config_only_validates_runtime_and_schema_before_emitting_receipt(self):
        source = Path('/synthetic/source')
        prior = Path('/synthetic/prior')
        previous = 'd44e8b6d4b1d6767a1bd3082ed8530a31735cc17'
        composition = {'sha256': 'a' * 64}
        schema = 'b' * 64
        approvals = Path('/synthetic/approvals.json')
        lab_instance = mock.Mock()
        output = io.StringIO()
        with mock.patch.object(release, 'validate_release', return_value=(composition, schema)) as validate, \
                mock.patch.object(release, 'Lab', return_value=lab_instance) as lab_type, \
                mock.patch.object(release.os, 'umask'), \
                mock.patch.object(release.signal, 'signal'), \
                mock.patch.object(sys, 'argv', [
                    'release.py', str(source), str(prior), 'archive-current', previous,
                    '--decoder-approvals', str(approvals), '--config-only']), \
                contextlib.redirect_stdout(output):
            release.main()
        validate.assert_called_once_with(source, prior, previous, approvals)
        lab_type.assert_called_once()
        self.assertFalse(lab_type.call_args.kwargs['persistent'])
        self.assertFalse(lab_type.call_args.kwargs['ci_staging'])
        lab_instance.config.assert_called_once_with(expose=False)
        lab_instance.clean.assert_called_once_with()
        receipt = json.loads(output.getvalue())
        self.assertEqual(receipt, {
            'config': 'valid',
            'schema_digest': schema,
            'runtime_composition': composition,
        })

    def test_ci_staging_requires_github_self_hosted_runner(self):
        cases = (
            ({}, False),
            ({'CI': 'true'}, False),
            ({'CI': 'true', 'GITHUB_ACTIONS': 'true'}, False),
            ({'CI': 'true', 'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'github-hosted'}, False),
            ({'CI': 'true', 'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'self-hosted'}, True),
        )
        for environment, expected in cases:
            with self.subTest(environment=environment), mock.patch.dict(release.os.environ, environment, clear=True):
                self.assertEqual(release.ci_staging_authorized(), expected)

    def test_ci_staging_has_no_reset_path_and_uses_proven_lifecycle(self):
        source = (HERE / 'release.py').read_text()
        self.assertNotIn('reset_ci_staging', source)
        self.assertIn('run_ci_staging', source)
        self.assertIn('lab.start(allow_existing=True)', source)

    def test_staging_receipt_has_lifecycle_and_rollback_evidence(self):
        receipt = release.staging_receipt(
            'updated', 't34-state', 'a' * 64, 'old', 'new',
            rollback={'attempted': True, 'succeeded': True, 'revision': 'old'},
            releases={'b': ['new', ['sha256:' + 'b' * 64, 'sha256:' + 'c' * 64]]},
        )
        self.assertEqual(receipt['lifecycle'], 'updated')
        self.assertEqual(receipt['before_revision'], 'old')
        self.assertEqual(receipt['after_revision'], 'new')
        self.assertEqual(receipt['state_volume'], 't34-state')
        self.assertTrue(receipt['storage_verified'])
        self.assertTrue(receipt['rollback']['succeeded'])

    def update_with_lost_state_ack(self, *, commit_state=False, state_read_fails=False,
                                   running_read_fails=False, candidate_running=True,
                                   writer_uncertain=False):
        old_api = 'sha256:' + 'a' * 64
        old_web = 'sha256:' + 'b' * 64
        new_api = 'sha256:' + 'c' * 64
        new_web = 'sha256:' + 'd' * 64
        before = {'release': {
            'revision': 'old-revision', 'api_image_id': old_api, 'web_image_id': old_web,
            **ADMISSION_PREVIOUS,
        }}
        updated = {'release': {
            'revision': 'new-revision', 'api_image_id': new_api, 'web_image_id': new_web,
        }}
        persisted = copy.deepcopy(updated if commit_state else before)
        state_read_count = 0
        running = {
            'api': old_api,
            'web': old_web,
            'monitor': 'running',
            'backup': 'running',
            'alert-sink': 'running',
        }
        write_secret = '1' * 48
        args = SimpleNamespace(revision='new-revision', previous='old-revision')
        composition = composition_for(before['release'])
        lab_instance = mock.Mock()
        lab_instance.name = 't34-ci-staging'
        lab_instance.env = {'ALERT_WEBHOOK': release.ALERT_WEBHOOK}
        lab_instance.exec.return_value = b'ai_cost=normal sink=webhook\n'
        lab_instance.gate_exit.return_value = 0
        lab_instance.build.side_effect = [old_api, new_api, new_web]
        lab_instance.alert_count.return_value = 0

        def compose(*compose_args, **kwargs):
            if compose_args[:2] == ('ps', '-q') and len(compose_args) == 3 and compose_args[2] in running:
                return (compose_args[2] + '-cid\n').encode()
            if compose_args[:1] == ('port',):
                return b'127.0.0.1:41001\n'
            return b''

        def docker(*docker_args, **kwargs):
            if docker_args[:2] == ('volume', 'inspect'):
                return json.dumps({staging.OWNER_LABEL: lab_instance.name,
                                   staging.ROLE_LABEL: staging.STATE_ROLE}).encode()
            if docker_args[:3] == ('inspect', '--format', '{{.Image}}'):
                if running_read_fails:
                    raise ValueError('running image unreadable')
                service = docker_args[3].split('-', 1)[0]
                if service in running:
                    return running[service].encode()
                raise ValueError('running image unavailable')
            self.fail(f'unexpected Docker operation: {docker_args}')

        def open_release(suffix, version, ids, **kwargs):
            if candidate_running:
                running.update(api=ids[0], web=ids[1])

        def close_serving():
            running.clear()

        def read_state(*read_args, **kwargs):
            nonlocal state_read_count
            state_read_count += 1
            if state_read_fails:
                raise ValueError('staging state unreadable: ' + write_secret)
            return copy.deepcopy(persisted)

        def write_state(lab, volume, stored, installation):
            nonlocal persisted
            if commit_state:
                persisted = copy.deepcopy(stored)
            if writer_uncertain:
                raise staging.StateWriteUncertain(
                    'staging state writer could not be proven settled') from ValueError(write_secret)
            raise ValueError('write acknowledgement lost: ' + write_secret)

        lab_instance.compose.side_effect = compose
        lab_instance.run.side_effect = docker
        lab_instance.open_release.side_effect = open_release
        lab_instance.close_serving.side_effect = close_serving
        error = io.StringIO()
        with mock.patch.object(release.staging, 'verify_storage'), \
                mock.patch.object(release.staging, 'validate_state'), \
                mock.patch.object(release.staging, 'updated_state', return_value=updated), \
                mock.patch.object(release.staging, 'read_state', side_effect=read_state), \
                mock.patch.object(release.staging, 'write_state', side_effect=write_state), \
                contextlib.redirect_stderr(error):
            with self.assertRaises(ValueError) as raised:
                release.update_release(lab_instance, args, before, 't34-state',
                                       composition, 'e' * 64, '20261123000023')
        return SimpleNamespace(
            persisted=persisted, running=running, lab=lab_instance,
            receipt=json.loads(error.getvalue()), exception=raised.exception,
            write_secret=write_secret, old_api=old_api, old_web=old_web,
            new_api=new_api, new_web=new_web, state_read_count=state_read_count,
        )

    def test_update_release_keeps_committed_candidate_when_write_ack_is_lost(self):
        result = self.update_with_lost_state_ack(commit_state=True)
        self.assertEqual(result.persisted['release']['revision'], 'new-revision')
        self.assertEqual(result.running['api'], result.new_api)
        self.assertEqual(result.running['web'], result.new_web)
        self.assertEqual(result.receipt['state_reconciliation'], 'committed')
        self.assertIs(result.receipt['serving_fenced'], False)
        self.assertIs(result.receipt['rollback']['attempted'], False)
        self.assertEqual(result.lab.open_release.call_args_list, [
            mock.call('b', 'new-revision', [result.new_api, result.new_web], preview=True),
        ])
        result.lab.close_serving.assert_not_called()
        self.assertNotIn(result.write_secret, str(result.exception))
        self.assertIsInstance(result.exception.__cause__, ValueError)

    def test_update_release_restores_previous_after_settled_precommit_write_failure(self):
        # A generic write_state failure is post-settlement by contract: the helper
        # has already been removed and probed absent when this exception escapes.
        result = self.update_with_lost_state_ack(commit_state=False)
        self.assertEqual(result.persisted['release']['revision'], 'old-revision')
        self.assertEqual(result.running['api'], result.old_api)
        self.assertEqual(result.running['web'], result.old_web)
        self.assertEqual(result.receipt['state_reconciliation'], 'uncommitted')
        self.assertIs(result.receipt['serving_fenced'], False)
        self.assertIs(result.receipt['rollback']['succeeded'], True)
        self.assertEqual(result.lab.open_release.call_args_list, [
            mock.call('b', 'new-revision', [result.new_api, result.new_web], preview=True),
            mock.call('rollback', 'old-revision', [result.old_api, result.old_web],
                      preview=True, by_id=True),
        ])
        result.lab.close_serving.assert_not_called()
        self.assertNotIn(result.write_secret, str(result.exception))

    def test_update_release_fences_unsettled_writer_without_reading_or_rollback(self):
        result = self.update_with_lost_state_ack(writer_uncertain=True)
        self.assertEqual(result.persisted['release']['revision'], 'old-revision')
        self.assertEqual(result.running, {})
        self.assertEqual(result.state_read_count, 0)
        self.assertEqual(result.receipt['state_reconciliation'], 'uncertain')
        self.assertEqual(result.receipt['state_write_error'], 'StateWriteUncertain')
        self.assertIs(result.receipt['serving_fenced'], True)
        self.assertIs(result.receipt['rollback']['attempted'], False)
        self.assertEqual(result.lab.open_release.call_args_list, [
            mock.call('b', 'new-revision', [result.new_api, result.new_web], preview=True),
        ])
        result.lab.close_serving.assert_called_once_with()
        result.lab.clean.assert_not_called()
        message = str(result.exception)
        self.assertIn('state writer could not be proven settled', message)
        self.assertNotIn('restored and verified', message)
        self.assertNotIn(result.write_secret, message)
        self.assertFalse(any(call.args[:2] == ('volume', 'rm')
                             for call in result.lab.run.call_args_list))

    def test_update_release_fences_when_state_and_running_images_cannot_be_proven(self):
        cases = (
            ('state', {'state_read_fails': True}, 'old-revision'),
            ('running', {'running_read_fails': True}, 'old-revision'),
            ('conflict', {'commit_state': True, 'candidate_running': False}, 'new-revision'),
        )
        for unavailable, options, persisted_revision in cases:
            with self.subTest(unavailable=unavailable):
                result = self.update_with_lost_state_ack(**options)
                self.assertEqual(result.persisted['release']['revision'], persisted_revision)
                self.assertEqual(result.running, {})
                self.assertEqual(result.receipt['state_reconciliation'], 'uncertain')
                self.assertIs(result.receipt['serving_fenced'], True)
                self.assertIs(result.receipt['rollback']['attempted'], False)
                self.assertEqual(result.lab.open_release.call_args_list, [
                    mock.call('b', 'new-revision', [result.new_api, result.new_web], preview=True),
                ])
                result.lab.close_serving.assert_called_once_with()
                result.lab.clean.assert_not_called()
                self.assertFalse(any(call.args[:2] == ('volume', 'rm')
                                     for call in result.lab.run.call_args_list))

    def test_ci_staging_initializes_once_then_updates_the_same_project(self):
        old_api = 'sha256:' + 'a' * 64
        old_web = 'sha256:' + 'b' * 64
        new_api = 'sha256:' + 'c' * 64
        new_web = 'sha256:' + 'd' * 64
        state = {
            'release': {
                'revision': 'old-revision', 'api_image_id': old_api, 'web_image_id': old_web,
                **ADMISSION_PREVIOUS,
            },
            'previous_release': {
                'revision': 'previous-revision', 'api_image_id': new_api, 'web_image_id': new_web,
                **ADMISSION_CURRENT,
            },
        }
        args = SimpleNamespace(
            source=Path('/synthetic/current'), prior=Path('/synthetic/prior'),
            revision='new-revision', previous='old-revision',
            ci_staging=True, preview=False, stage_test=False,
        )
        work = Path('/synthetic/work')
        composition = composition_for(state['release'])
        schema = 'f' * 64
        deploy_result = {
            'releases': {
                'a': ['old-revision', [old_api, old_web]],
                'b': ['new-revision', [new_api, new_web]],
            },
            'persistence_marker': {'synthetic': 'marker'},
        }
        lab_instance = mock.Mock()
        lab_instance.name = 't34-ci-staging'
        output = io.StringIO()
        with mock.patch.object(release.staging, 'require_state_volume'), \
                mock.patch.object(release.staging, 'read_state', side_effect=[None, state]), \
                mock.patch.object(release.staging, 'schema_version', return_value='20261123000023'), \
                mock.patch.object(lab_instance, 'existing_project', side_effect=[False, True]), \
                mock.patch.object(release, 'deploy', return_value=('127.0.0.1:41001', deploy_result)) as deploy, \
                mock.patch.object(release.staging, 'build_state', return_value=state) as build_state, \
                mock.patch.object(release.staging, 'verify_storage') as verify_storage, \
                mock.patch.object(release.staging, 'write_state') as write_state, \
                mock.patch.object(release.staging, 'validate_state') as validate_state, \
                mock.patch.object(release.staging, 'apply_to_lab') as apply_to_lab, \
                mock.patch.object(release, 'update_release', return_value='127.0.0.1:41001') as update, \
                contextlib.redirect_stdout(output):
            first = release.run_ci_staging(
                lab_instance, args, work, composition, schema, 't34-state')
            second = release.run_ci_staging(
                lab_instance, args, work, composition, schema, 't34-state')

        self.assertEqual(first, '127.0.0.1:41001')
        self.assertEqual(second, '127.0.0.1:41001')
        deploy.assert_called_once_with(
            lab_instance, args, work, composition, schema, announce=False)
        build_state.assert_called_once_with(
            lab_instance, args, schema, deploy_result, deploy_result['persistence_marker'],
            schema_version_value='20261123000023', composition=composition)
        verify_storage.assert_called_once_with(lab_instance, state)
        write_state.assert_called_once_with(
            lab_instance, 't34-state', state, 't34-ci-staging')
        validate_state.assert_called_once_with(
            state, 't34-ci-staging', schema, '20261123000023')
        apply_to_lab.assert_called_once_with(lab_instance, state)
        update.assert_called_once_with(
            lab_instance, args, state, 't34-state', composition, schema, '20261123000023', recovery=None)
        self.assertEqual(lab_instance.start.call_args_list, [
            mock.call(), mock.call(allow_existing=True),
        ])
        self.assertIn('"lifecycle": "initialized"', output.getvalue())

    def test_ci_staging_initialization_fences_without_reopening_a_when_state_write_fails(self):
        old_api = 'sha256:' + 'a' * 64
        old_web = 'sha256:' + 'b' * 64
        new_api = 'sha256:' + 'c' * 64
        new_web = 'sha256:' + 'd' * 64
        state = {'release': {
            'revision': 'new-revision', 'api_image_id': new_api, 'web_image_id': new_web,
        }}
        args = SimpleNamespace(
            source=Path('/synthetic/current'), prior=Path('/synthetic/prior'),
            revision='new-revision', previous='old-revision',
            ci_staging=True, preview=False, stage_test=False,
        )
        deploy_result = {
            'releases': {
                'a': ['old-revision', [old_api, old_web]],
                'b': ['new-revision', [new_api, new_web]],
            },
            'persistence_marker': {'synthetic': 'marker'},
        }
        lab_instance = mock.Mock()
        lab_instance.name = 't34-ci-staging'
        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch.object(release.staging, 'require_state_volume'), \
                mock.patch.object(release.staging, 'read_state', return_value=None), \
                mock.patch.object(release.staging, 'schema_version', return_value='20261123000023'), \
                mock.patch.object(lab_instance, 'existing_project', return_value=False), \
                mock.patch.object(release, 'deploy', return_value=('127.0.0.1:41001', deploy_result)), \
                mock.patch.object(release.staging, 'build_state', return_value=state), \
                mock.patch.object(release.staging, 'verify_storage'), \
                mock.patch.object(release.staging, 'write_state', side_effect=ValueError('write failed')), \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            with self.assertRaisesRegex(ValueError, 'write failed'):
                release.run_ci_staging(
                    lab_instance, args, Path('/synthetic/work'),
                    {'sha256': 'e' * 64}, 'f' * 64, 't34-state')

        lab_instance.open_release.assert_not_called()
        lab_instance.close_serving.assert_called_once_with()
        self.assertNotIn('"result": "synthetic-pass"', stdout.getvalue())
        self.assertIn('"result": "synthetic-failed"', stderr.getvalue())
        self.assertIn('"lifecycle": "initialized"', stderr.getvalue())

    def test_ci_staging_initialization_does_not_reopen_unproven_storage(self):
        old_api = 'sha256:' + 'a' * 64
        old_web = 'sha256:' + 'b' * 64
        new_api = 'sha256:' + 'c' * 64
        new_web = 'sha256:' + 'd' * 64
        state = {'release': {
            'revision': 'new-revision', 'api_image_id': new_api, 'web_image_id': new_web,
        }}
        args = SimpleNamespace(
            source=Path('/synthetic/current'), prior=Path('/synthetic/prior'),
            revision='new-revision', previous='old-revision',
            ci_staging=True, preview=False, stage_test=False,
        )
        deploy_result = {
            'releases': {
                'a': ['old-revision', [old_api, old_web]],
                'b': ['new-revision', [new_api, new_web]],
            },
            'persistence_marker': {'synthetic': 'marker'},
        }
        lab_instance = mock.Mock()
        lab_instance.name = 't34-ci-staging'
        with mock.patch.object(release.staging, 'require_state_volume'), \
                mock.patch.object(release.staging, 'read_state', return_value=None), \
                mock.patch.object(release.staging, 'schema_version', return_value='20261123000023'), \
                mock.patch.object(lab_instance, 'existing_project', return_value=False), \
                mock.patch.object(release, 'deploy', return_value=('127.0.0.1:41001', deploy_result)), \
                mock.patch.object(release.staging, 'build_state', return_value=state), \
                mock.patch.object(release.staging, 'verify_storage', side_effect=ValueError('storage failed')), \
                mock.patch.object(release.staging, 'write_state') as write_state, \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaisesRegex(ValueError, 'storage failed'):
                release.run_ci_staging(
                    lab_instance, args, Path('/synthetic/work'),
                    {'sha256': 'e' * 64}, 'f' * 64, 't34-state')

        lab_instance.open_release.assert_not_called()
        lab_instance.close_serving.assert_called_once_with()
        write_state.assert_not_called()

    def test_deploy_receipt_has_schema_and_runtime_rollback_evidence(self):
        source = (HERE / 'release.py').read_text()
        for field in (
            'schema_digest=schema',
            'same_schema_rollback=',
            'runtime_composition=composition',
            "mode=('ci-staging'",
            "production='blocked'",
        ):
            with self.subTest(field=field):
                self.assertIn(field, source)

    def test_cost_cases_keep_independent_statuses_and_exact_order(self):
        lab_instance = mock.Mock()
        lab_instance.job.return_value = (
            b'normal\ncost_anomaly\ncost_anomaly\nunpriced\n'
            b'normal\ncost_anomaly\nunpriced\n')
        release.cost_cases(lab_instance)
        lab_instance.job.assert_called_once()
        self.assertEqual(lab_instance.job.call_args.args[:2], ('backup', '-XqAt'))
        lab_instance.job.return_value = b'normal\ncost_anomaly\n'
        with self.assertRaisesRegex(ValueError, 'cost threshold cases changed'):
            release.cost_cases(lab_instance)

    def test_previous_rollback_revision_must_be_a_full_sha(self):
        with self.assertRaisesRegex(ValueError, 'full commit SHA'):
            release.validate_release(ROOT, ROOT, 'd44e8b6', Path('/synthetic/approvals.json'))

    def test_initial_and_recovery_tickets_are_distinct(self):
        source = (HERE / 'release.py').read_text()
        self.assertIn("ticket_for(lab,f,doc['sha256'],'initial')", source)
        self.assertIn("ticket_for(lab,f,doc['sha256'],'recovery')", source)
        self.assertIn("'purpose': purpose", (HERE / 'lab.py').read_text())

    def test_recovery_gate_precedes_real_http_queries(self):
        source = (HERE / 'release.py').read_text()
        gate = source.index("if lab.gate_exit()!=0: raise ValueError('complete recovery gate refused')")
        http = source.index("lab.job('drill','httpcheck',input=raw)")
        self.assertLess(gate, http)
        self.assertNotIn("lab.compose('up','-d','--wait','--wait-timeout','120','api')", source)
        self.assertNotIn("lab.compose('stop','api')", source)

    def test_recovery_uses_the_operational_entry_for_an_existing_snapshot(self):
        release = (HERE / 'release.py').read_text()
        self.assertIn("lab.job('backup','restore',snapshot)", release)
        self.assertNotIn('pg_restore', release,
                         'acceptance must exercise the retained restore entry, not a private duplicate')


if __name__ == '__main__':
    unittest.main()

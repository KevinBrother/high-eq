import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

T34 = Path(__file__).resolve().parents[1]
ROOT = T34.parents[1]
sys.path.insert(0, str(T34))
import lab


class LabContract(unittest.TestCase):
    def test_ticket_document_binds_the_restore_target_and_evidence(self):
        doc = lab.ticket_document(
            installation='install-1', db_service='restored', cache_service='coldcache',
            challenge='challenge-1', seal='00000000-0000-0000-0000-000000000000:45',
            dump_sha256='a' * 64, roots=['root-b', 'root-a'], purpose='recovery')
        self.assertEqual(doc, {
            'version': 2,
            'installation': 'install-1',
            'db_service': 'restored',
            'cache_service': 'coldcache',
            'challenge': 'challenge-1',
            'ledger_seal': '00000000-0000-0000-0000-000000000000:45',
            'business_dump_sha256': 'a' * 64,
            'roots': ['root-b', 'root-a'],
            'purpose': 'recovery',
        })

    def test_initial_ticket_requires_an_empty_root_inventory(self):
        doc = lab.ticket_document(
            installation='install-1', db_service='db', cache_service='cache',
            challenge='challenge-1', seal='00000000-0000-0000-0000-000000000000:45',
            dump_sha256='a' * 64, roots=[], purpose='initial')
        self.assertEqual(doc['purpose'], 'initial')
        self.assertEqual(doc['roots'], [])
        with self.assertRaisesRegex(ValueError, 'initial ticket roots must be empty'):
            lab.ticket_document(
                installation='install-1', db_service='db', cache_service='cache',
                challenge='challenge-1', seal='00000000-0000-0000-0000-000000000000:45',
                dump_sha256='a' * 64, roots=['future-root'], purpose='initial')

    def test_recovery_ticket_requires_exact_nonempty_unique_roots(self):
        for roots in ([], ['root-a', 'root-a'], ['']):
            with self.subTest(roots=roots):
                with self.assertRaisesRegex(ValueError, 'recovery ticket roots'):
                    lab.ticket_document(
                        installation='install-1', db_service='restored', cache_service='coldcache',
                        challenge='challenge-1', seal='00000000-0000-0000-0000-000000000000:45',
                        dump_sha256='a' * 64, roots=roots, purpose='recovery')

    def test_ticket_purpose_must_be_initial_or_recovery(self):
        with self.assertRaisesRegex(ValueError, 'ticket purpose invalid'):
            lab.ticket_document(
                installation='install-1', db_service='db', cache_service='cache',
                challenge='challenge-1', seal='00000000-0000-0000-0000-000000000000:45',
                dump_sha256='a' * 64, roots=[], purpose='upgrade')

    def test_runtime_composition_receipt_locks_the_full_inventory(self):
        receipt = lab.composition_receipt(ROOT)
        self.assertEqual(receipt['sha256'],
                         '9b763c38ad658244e1c56d720179e53795300c49cfed49ef0a4243046e4253b9')
        self.assertEqual(len(receipt['modules']), 13)
        self.assertEqual(receipt['modules'][1], 'chat_imports')
        self.assertEqual(len(receipt['hooks']), 13)
        self.assertIn('training.ChatImportHooks()', receipt['hooks'])
        self.assertEqual(receipt['hooks'][-1],
                         'growth.Hooks(c.Fields, &training.Service{Fields: c.Fields})')
        self.assertEqual(receipt['decoder'], lab.RUNTIME_DECODER)
        self.assertEqual(receipt['chat_imports']['retry_interval_seconds'], 60)

    def test_runtime_composition_rejects_maintenance_worker_drift(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for path in ('server/internal/service/runtime.go',
                         'server/cmd/api/main.go',
                         'server/internal/service/runtime_maintenance.go',
                         'server/internal/training/chat_imports.go'):
                destination = root / path
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes((ROOT / path).read_bytes())

            worker = root / 'server/internal/service/runtime_maintenance.go'
            worker.write_text(worker.read_text().replace(
                's.Practice.PurgeChatImports(ctx, now)', 'nil',
            ))
            with self.assertRaisesRegex(ValueError, 'runtime maintenance implementation changed'):
                lab.composition_receipt(root)

    def test_runtime_composition_fails_closed_on_hook_order_drift(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            runtime = root / 'server/internal/service/runtime.go'
            runtime.parent.mkdir(parents=True)
            text = (ROOT / 'server/internal/service/runtime.go').read_text().replace(
                'payments.Hooks(), s.Membership.Hooks()',
                's.Membership.Hooks(), payments.Hooks()',
            )
            runtime.write_text(text)
            with self.assertRaisesRegex(ValueError, 'module inventory or hook order'):
                lab.composition_receipt(root)

    def test_runtime_composition_fails_closed_on_decoder_drift(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            runtime = root / 'server/internal/service/runtime.go'
            runtime.parent.mkdir(parents=True)
            text = (ROOT / 'server/internal/service/runtime.go').read_text().replace(
                'training.Decoder(c.Fields, reviews.Decoder(c.Fields))',
                'training.Decoder(c.Fields, nil)',
            )
            runtime.write_text(text)
            with self.assertRaisesRegex(ValueError, 'score decoder changed'):
                lab.composition_receipt(root)

    def test_schema_digest_is_stable_and_rejects_rollback_drift(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / 'source'
            prior = root / 'prior'
            source_migrations = source / 'server/migrations'
            prior_migrations = prior / 'server/migrations'
            source_migrations.mkdir(parents=True)
            prior_migrations.mkdir(parents=True)
            for target in (source_migrations, prior_migrations):
                (target / '0002_b.up.sql').write_text('select 2;\n')
                (target / '0001_a.up.sql').write_text('select 1;\n')
            digest = lab.same_schema(source, prior)
            self.assertRegex(digest, r'^[0-9a-f]{64}$')
            self.assertEqual(digest, lab.schema_digest(source))
            (prior_migrations / '0001_a.up.sql').write_text('select changed;\n')
            with self.assertRaisesRegex(ValueError, 'schema differs: no automatic binary rollback'):
                lab.same_schema(source, prior)

    def test_empty_schema_cannot_claim_binary_rollback(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / 'server/migrations'
            source.mkdir(parents=True)
            with self.assertRaisesRegex(ValueError, 'schema missing'):
                lab.schema_digest(Path(tmp))

    def test_destroy_stage_only_removes_the_exact_stage_project_and_tags(self):
        with tempfile.TemporaryDirectory() as tmp:
            subject = lab.Lab(Path(tmp), Path(tmp), persistent=True)
            found = subprocess.CompletedProcess([], 0, stdout=b'', stderr=b'')
            with mock.patch.object(subject, 'compose') as compose, \
                    mock.patch.object(subject, 'run') as run, \
                    mock.patch.object(lab.sp, 'run', return_value=found):
                subject.destroy_stage()
            self.assertEqual(subject.name, 't34-synthetic-stage')
            self.assertIn('--profile', compose.call_args.args)
            self.assertIn('down', compose.call_args.args)
            expected = [mock.call('image', 'rm', subject.tag(name)) for name in (
                'api-a', 'api-b', 'web-a', 'web-b', 'drill', 'ops', 'sink')]
            self.assertEqual(run.call_args_list, expected)

    def test_destroy_stage_refuses_a_nonstage_or_ci_project(self):
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            (work / 'ephemeral').mkdir()
            (work / 'ci').mkdir()
            for subject in (
                lab.Lab(work / 'ephemeral', work),
                lab.Lab(work / 'ci', work, ci_staging=True),
            ):
                with self.subTest(project=subject.name):
                    with self.assertRaisesRegex(ValueError, 'non-stage project'):
                        subject.destroy_stage()

    def test_ci_staging_uses_a_fixed_isolated_project(self):
        with tempfile.TemporaryDirectory() as tmp:
            subject = lab.Lab(Path(tmp), Path(tmp), ci_staging=True)
        self.assertEqual(subject.name, 't34-ci-staging')
        self.assertTrue(subject.persistent)

    def test_ci_staging_can_take_over_only_a_proven_existing_project(self):
        with tempfile.TemporaryDirectory() as tmp:
            subject = lab.Lab(Path(tmp), Path(tmp), ci_staging=True)
            with mock.patch.object(subject, 'run', side_effect=[b'linux\n', b'container-id\n']) as run:
                subject.start(allow_existing=True)
            self.assertEqual(subject.name, 't34-ci-staging')
            self.assertFalse(subject.owned)
            self.assertEqual(run.call_args_list[0], mock.call('info', '--format', '{{.OSType}}'))
            self.assertIn(
                mock.call('container', 'ls', '-aq',
                          '--filter=label=com.docker.compose.project=t34-ci-staging'),
                run.call_args_list,
            )

    def test_ci_staging_cleanup_never_removes_persistent_resources(self):
        with tempfile.TemporaryDirectory() as tmp:
            subject = lab.Lab(Path(tmp), Path(tmp), ci_staging=True)
            subject.owned = True
            with mock.patch.object(subject, 'compose') as compose, \
                    mock.patch.object(subject, 'run') as run:
                subject.clean()
            compose.assert_not_called()
            run.assert_not_called()

    def test_shutdown_is_project_scoped_and_preserves_storage_even_after_stop_timeout(self):
        subject = object.__new__(lab.Lab)
        subject.name = lab.CI_STAGING_PROJECT
        storage = b'a db\nb cache\nc ledger\nd restored\ne coldcache\n'
        subject.run = mock.Mock(side_effect=[
            storage + b'f web\ng api\nh monitor\ni backup\nj alert-sink\n',
            subprocess.TimeoutExpired('stop', 45), storage + b'h monitor\n', b'', storage,
        ])
        subject.close_serving()
        ls = mock.call('ps', '--no-trunc', '--filter=label=com.docker.compose.project=t34-ci-staging',
                       '--format', '{{.ID}} {{.Label "com.docker.compose.service"}}', timeout=15)
        self.assertEqual(subject.run.call_args_list, [
            ls, mock.call('stop', '--time', '5', 'f', 'g', 'h', 'i', 'j', check=False, timeout=45),
            ls, mock.call('kill', 'h', check=False, timeout=30), ls,
        ])

    def test_enumeration_failure_still_triggers_scoped_stop_and_kill(self):
        for failure in (RuntimeError('ps failed'), subprocess.TimeoutExpired('ps', 15)):
            with self.subTest(failure=type(failure)):
                subject = object.__new__(lab.Lab)
                subject.name = lab.CI_STAGING_PROJECT
                storage = b'a db\nb cache\nc ledger\nd restored\ne coldcache\n'
                subject.run = mock.Mock(side_effect=[failure, failure, storage])
                subject.compose = mock.Mock(side_effect=[subprocess.TimeoutExpired('stop', 45), b''])
                subject.close_serving()
                for command, action in zip(subject.compose.call_args_list, ('stop', 'kill')):
                    self.assertIn(action, command.args)
                    self.assertEqual(set(command.args[-6:]),
                                     {'api', 'web', 'backup', 'monitor', 'alert-sink', 'chat-sweeper'})
                    self.assertTrue(command.kwargs['preview'])
                    self.assertGreater(command.kwargs['timeout'], 0)
                self.assertEqual(subject.compose.call_count, 2)
                self.assertEqual(subject.run.call_count, 3)
                for command in subject.run.call_args_list:
                    self.assertEqual(command.args[0], 'ps')
                    self.assertIn('--filter=label=com.docker.compose.project=t34-ci-staging', command.args)

    def test_shutdown_requires_a_final_empty_serving_inventory(self):
        subject = object.__new__(lab.Lab)
        subject.name = lab.CI_STAGING_PROJECT
        subject.run = mock.Mock(side_effect=lambda action, *args, **kwargs: b'id web' if action == 'ps' else b'')
        with self.assertRaisesRegex(ValueError, 'consumer still running'):
            subject.close_serving()

    def test_preflight_only_inspects_local_images_and_refuses_inconsistent_metadata(self):
        api_id = 'sha256:' + 'a' * 64
        web_id = 'sha256:' + 'b' * 64
        api = {'Id': api_id, 'Config': {'Entrypoint': ['/api'],
                                        'Labels': {'org.opencontainers.image.version': 'old-revision'}}}
        web = {'Id': web_id, 'Config': {'Entrypoint': ['nginx', '-g', 'daemon off;']}}
        with tempfile.TemporaryDirectory() as tmp:
            subject = lab.Lab(Path(tmp), Path(tmp), ci_staging=True)
            with mock.patch.object(subject, 'run', side_effect=[json.dumps(api).encode(),
                                                               json.dumps(web).encode()]) as run:
                subject.preflight_release('old-revision', [api_id, web_id])
                self.assertEqual(run.call_args_list, [
                    mock.call('image', 'inspect', '--format', '{{json .}}', api_id, timeout=15),
                    mock.call('image', 'inspect', '--format', '{{json .}}', web_id, timeout=15),
                ])
            for wrong_image, wrong_version in ((api, 'wrong-revision'),
                                               ({**web, 'Id': api_id}, 'old-revision'),
                                               ({**web, 'Config': {'Entrypoint': ['/api']}}, 'old-revision')):
                with self.subTest(image=wrong_image, version=wrong_version), \
                        mock.patch.object(subject, 'run', side_effect=[json.dumps(api).encode(),
                                                                       json.dumps(wrong_image).encode()]):
                    with self.assertRaisesRegex(ValueError, 'release image metadata'):
                        subject.preflight_release(wrong_version, [api_id, web_id])

    def test_release_can_restart_exact_previous_image_ids_after_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            subject = lab.Lab(Path(tmp), Path(tmp), ci_staging=True)
            api_id = 'sha256:' + 'a' * 64
            web_id = 'sha256:' + 'b' * 64
            with mock.patch.object(subject, 'compose', side_effect=[
                    b'', b'', b'', b'', b'', b'', b'api-cid\n', b'web-cid\n',
            ]) as compose, \
                    mock.patch.object(subject, 'sql', return_value='c' * 64), \
                    mock.patch.object(subject, 'run', side_effect=[api_id.encode(), web_id.encode()]) as run, \
                    mock.patch.object(subject, 'exec', side_effect=[
                        b'chat_import_sweeper_ready', b'flutter_bootstrap.js', b'x' * 10001,
                        b'{"ok":true}', b'old-revision', b'chat_import_sweeper_ready',
                    ]) as execute:
                subject.open_release('rollback', 'old-revision', [api_id, web_id],
                                     preview=True, by_id=True)
            self.assertEqual(subject.env['API_IMAGE'], api_id)
            self.assertEqual(subject.env['WEB_IMAGE'], web_id)
            self.assertEqual(run.call_args_list, [
                mock.call('inspect', '--format', '{{.Image}}', 'api-cid'),
                mock.call('inspect', '--format', '{{.Image}}', 'web-cid'),
            ])
            self.assertEqual(compose.call_args_list[0].args[-3:], ('web', 'api', 'chat-sweeper'))
            self.assertEqual([call.args[-1] for call in compose.call_args_list if call.args[0] == 'up'],
                             ['chat-sweeper', 'web'])
            health = mock.call(*lab.CHAT_SWEEPER_PROBE, timeout=15)
            smoke = [mock.call('web', 'wget', '-qO-', 'http://127.0.0.1:8080' + uri)
                     for uri in ('/', '/main.dart.js', '/v1/health', '/release.txt')]
            self.assertEqual(execute.call_args_list, [health, *smoke, health])

    def test_failed_commands_capture_stderr_for_visible_delivery_errors(self):
        with tempfile.TemporaryDirectory() as tmp:
            subject = lab.Lab(Path(tmp), Path(tmp))
            failed = subprocess.CompletedProcess([], 1, stdout=b'out', stderr=b'alert_delivery_failed')
            with mock.patch.object(lab.sp, 'run', return_value=failed) as run:
                result = subject.run('compose', 'exec', check=False)
            self.assertEqual(result.stdout + result.stderr, b'outalert_delivery_failed')
            self.assertIs(run.call_args.kwargs['stderr'], subprocess.PIPE)

    def test_project_conflict_detection_includes_stopped_containers(self):
        with tempfile.TemporaryDirectory() as tmp:
            subject = lab.Lab(Path(tmp), Path(tmp))
            with mock.patch.object(subject, 'run', side_effect=[b'linux\n', b'', b'', b'']) as run:
                subject.start()
            self.assertIn(
                mock.call(
                    'container', 'ls', '-aq',
                    '--filter=label=com.docker.compose.project=' + subject.name,
                ),
                run.call_args_list,
            )


if __name__ == '__main__':
    unittest.main()

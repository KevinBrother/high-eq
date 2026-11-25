"""Offline regressions for the hosted worker. No Docker CLI is executed."""
from contextlib import redirect_stderr
import copy
import io
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, call, patch

import isolated_staging_lab as guard


class FixedStageBoundaryTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        work = Path(folder.name)
        self.box = guard.IsolatedLab(work, (work,), 'a' * 24,
                                     'unix:///tmp/t34-private-test.sock', 'b' * 64)
        self.box.armed = True
        self.box._verify_engine = Mock()
        self.box._check_state_volume = Mock()
        self.box._docker = Mock()

    def test_fixed_writer_only_accepts_owned_ops_and_exact_durable_script(self):
        box = self.box
        identifier = 'c' * 64
        box._docker.return_value = identifier.encode()
        box._verify_owned_image = Mock(return_value=True)
        box._image_mounts = Mock()
        box._container = Mock(return_value=identifier)
        box._durable_state = True
        args = ('create', '-i', '--network', 'none', '-v', box.volume + ':/state',
                '--user', '0:0', '--entrypoint', 'python3', box.tag('ops'), '-c',
                guard.staging._DURABLE_WRITER, '/state')
        for invalid in (args[:-2] + ('arbitrary program', '/state'),
                        args[:10] + ('foreign:latest',) + args[11:]):
            with self.assertRaises(guard.SafetyError):
                box.run(*invalid, timeout=30)
        box._docker.assert_not_called()
        self.assertEqual(box.run(*args, timeout=30), identifier.encode())
        box._verify_owned_image.assert_called_once_with(box.tag('ops'))
        self.assertIn('--pull=never', box._docker.call_args.args)
        self.assertIn('type=tmpfs,dst=' + guard.PG_DATA, box._docker.call_args.args)
        box.run('inspect', '--format', '{{.State.Status}}:{{.State.ExitCode}}', identifier, timeout=30)
        self.assertEqual(box._docker.call_args,
                         call('container', 'inspect', '--format', '{{.State.Status}}:{{.State.ExitCode}}',
                              identifier, timeout=30))

    def test_fixed_release_removal_is_limited_to_the_two_serving_tiers(self):
        self.box._durable_state = True
        self.box._compose_command(('--profile', 'serve', 'rm', '-f', 'web', 'api'), 'test.yml', False)
        with self.assertRaises(guard.SafetyError):
            self.box._compose_command(('--profile', 'serve', 'rm', '-f', 'web', 'db'), 'test.yml', False)


class HostedStageTests(unittest.TestCase):
    def setUp(self):
        from ci import hosted_stage
        self.stage = hosted_stage

    def test_cli_refuses_untrusted_context_before_launching_a_stage(self):
        with patch.dict('os.environ', {}, clear=True), patch.object(self.stage, 'execute') as execute, \
                redirect_stderr(io.StringIO()):
            self.assertEqual(self.stage.main(['init', '--receipt', '/tmp/proof.json']), 1)
        execute.assert_not_called()

    def test_socket_binding_refuses_an_explicit_mismatch_and_a_replaced_inode(self):
        with tempfile.TemporaryDirectory(prefix='stage-', dir='/tmp') as folder:
            root = Path(folder).resolve()
            paths = self.stage.hosted_engine.engine_paths(root)
            paths.runtime.mkdir(mode=0o700)
            paths.data_root.mkdir(mode=0o700)
            path = paths.socket
            host = 'unix://' + str(path)
            environ = {guard.ENGINE_HOST_ENV: host, guard.ENGINE_ID_ENV: 'a' * 64,
                       'DOCKER_HOST': 'unix:///var/run/docker.sock'}
            path.touch(mode=0o600)
            with self.assertRaisesRegex(self.stage.ProofError, 'explicit isolated engine host differs'):
                self.stage.EngineBinding.from_parent(environ, root)
            environ['DOCKER_HOST'] = host
            with self.assertRaisesRegex(self.stage.ProofError, 'private engine socket invalid'):
                self.stage.EngineBinding.from_parent(environ, root)

            def identity(path):
                info = path.lstat()
                return info.st_dev, info.st_ino, info.st_ctime_ns

            with patch.object(self.stage.EngineBinding, 'inspect_socket', staticmethod(identity)):
                binding = self.stage.EngineBinding.from_parent(environ, root)
                binding.verify_socket()
                path.rename(paths.runtime / 'first.sock')
                path.touch(mode=0o600)
                with self.assertRaisesRegex(self.stage.ProofError, 'socket changed'):
                    binding.verify_socket()

    def test_fresh_engine_only_pulls_after_all_empty_engine_checks(self):
        operations = [call('container', 'ls', '-aq', timeout=15), call('volume', 'ls', '-q', timeout=15),
                      call('image', 'ls', '-aq', timeout=15),
                      call('network', 'ls', '--format', '{{.Name}}\t{{.Driver}}', timeout=15)]
        box = SimpleNamespace(_verify_engine=Mock(), _docker=Mock(side_effect=[b'', b'foreign\n']))
        with self.assertRaisesRegex(self.stage.ProofError, 'engine was not empty'):
            self.stage.HostedLab.prime_empty_engine(box)
        self.assertEqual(box._docker.call_args_list, operations[:2])

        box._docker = Mock(side_effect=[b'', b'', b'', b'host\thost\nnone\tnull\n', b'', b''])
        self.stage.HostedLab.prime_empty_engine(box)
        self.assertEqual(box._docker.call_args_list, operations + [call('pull', guard.PG, timeout=300),
                                                                  call('pull', guard.REDIS, timeout=300)])

    def test_update_requires_a_different_worker_after_the_actual_wait(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            record = {'phase': 'init', 'context': {'engine_id': 'a' * 64},
                      'finished_ns': 1, 'pid': 10}
            self.stage.write_private_json(self.stage.stage_record(root, 'init'), record)
            waited = self.stage.MIN_WAIT_SECONDS * 1_000_000_000 + 1
            self.assertEqual(self.stage.predecessor(root, 'update', record['context'],
                                                    now_ns=waited + 1, pid=11), record)
            for binding, stamp, pid in ((record['context'], waited, 11),
                                        (record['context'], waited + 1, 10),
                                        ({'engine_id': 'b' * 64}, waited + 1, 11)):
                with self.subTest(stamp=stamp, pid=pid), self.assertRaises(self.stage.ProofError):
                    self.stage.predecessor(root, 'update', binding, now_ns=stamp, pid=pid)
            os.chmod(self.stage.stage_record(root, 'init'), 0o640)
            with self.assertRaises(self.stage.ProofError):
                self.stage.predecessor(root, 'update', record['context'], now_ns=waited + 1, pid=11)

    def test_receipt_path_is_limited_to_the_run_receipts_directory(self):
        with tempfile.TemporaryDirectory(prefix='stage-paths-', dir='/tmp') as folder:
            root = Path(folder).resolve()
            os.chmod(root, 0o700)
            paths = self.stage.hosted_engine.engine_paths(root)
            for directory in (paths.home, paths.config, paths.runtime, paths.data_root,
                              paths.exec_root, root / 'receipts', root / 'other',
                              root / 'receipts' / 'nested'):
                directory.mkdir(mode=0o700)
            binding = SimpleNamespace(socket=paths.socket)
            accepted = root / 'receipts' / 'init.json'
            self.assertEqual(self.stage.stage_paths(root, accepted, binding), accepted)
            rejected = (
                paths.home / 'receipt.json', paths.config / 'receipt.json',
                paths.runtime / 'receipt.json', paths.data_root / 'receipt.json',
                paths.exec_root / 'receipt.json', root / 'other' / 'receipt.json',
                root / 'receipts' / 'nested' / 'receipt.json',
            )
            for target in rejected:
                with self.subTest(target=target), self.assertRaises(self.stage.ProofError):
                    self.stage.stage_paths(root, target, binding)

    def test_replaced_volume_is_rejected_before_reading_the_state(self):
        box, recovery = Mock(), Mock()
        box.name = 't34-proof-test'
        box.volume = box.name + '_state'
        volumes = {box.name + '_' + name: 'a' * 64 for name in
                   ('approval', 'business', 'deletions', 'quarantine', 'state', 'vault')}
        box.volume_identities.return_value = volumes
        box.resource_fingerprint.return_value = 'c' * 64
        previous = {'resources': 'c' * 64, 'volumes': {**volumes, box.volume: 'b' * 64}}
        with self.assertRaisesRegex(self.stage.ProofError, 'prior resource identity changed'):
            self.stage.observe(box, recovery, 'd' * 64, '1', previous=previous)
        recovery.read_initial.assert_not_called()

    def test_update_requires_both_new_images_and_calls_the_fixed_stage(self):
        box, recovery = Mock(), Mock()
        box.volume = 'proof-state'
        schema = 'd' * 64
        previous, current = 'a' * 40, 'b' * 40
        candidate = SimpleNamespace(source=Path('/candidate'), revision=current)
        old_release = {'revision': previous, 'api_image_id': 'sha256:' + '1' * 64,
                       'web_image_id': 'sha256:' + '2' * 64,
                       'artifact_sha256': '1' * 64, 'decoder_sha256': '2' * 64}
        old_state = {'release': old_release, 'history': [old_release]}
        evidence = dict(resources='stable', volumes={}, state='old', pg='pg', ledger='ledger',
                        ledger_roots=1, vault={}, services={'web': True})
        binding = {'revision': previous, 'evidence': evidence}
        for web_image, accepted in (('sha256:' + '3' * 64, True), (old_release['web_image_id'], False)):
            with self.subTest(accepted=accepted):
                ids = ['sha256:' + '4' * 64, web_image]
                new_release = {'revision': current, 'api_image_id': ids[0], 'web_image_id': ids[1],
                               'artifact_sha256': '3' * 64, 'decoder_sha256': '4' * 64}
                new_state = {'release': new_release, 'previous_release': old_release,
                             'history': [old_release, new_release]}

                def fixed(*args, **kwargs):
                    receipt = self.stage.release.staging_receipt(
                        'updated', box.volume, schema, previous, current,
                        rollback={'attempted': False, 'succeeded': None, 'revision': previous,
                                  'release': old_release},
                        releases={'b': [current, ids]}, release=new_release,
                        previous_release=old_release)
                    print(json.dumps(receipt))
                    return '127.0.0.1:1234'

                with patch.object(self.stage.staging, 'schema_version', return_value='1'), \
                        patch.object(self.stage, 'observe', side_effect=[(old_state, evidence), (new_state, evidence)]), \
                        patch.object(self.stage.release, 'run_ci_staging', side_effect=fixed) as run:
                    args = ('update', box, recovery, candidate, Path('/work'), {}, schema, binding)
                    if accepted:
                        self.assertEqual(self.stage.run_phase(*args), (new_state, evidence))
                    else:
                        with self.assertRaisesRegex(self.stage.ProofError, 'distinct artifacts'):
                            self.stage.run_phase(*args)
                run.assert_called_once_with(box, candidate, Path('/work'), {}, schema, box.volume, recovery=recovery)

    def test_update_receipt_rejects_same_revision_with_a_different_release_identity(self):
        box, recovery = Mock(), Mock()
        box.volume = 'proof-state'
        schema = 'd' * 64
        previous, current = 'a' * 40, 'b' * 40
        candidate = SimpleNamespace(source=Path('/candidate'), revision=current)
        old_release = {
            'revision': previous, 'api_image_id': 'sha256:' + '1' * 64,
            'web_image_id': 'sha256:' + '2' * 64,
            'artifact_sha256': '1' * 64, 'decoder_sha256': '2' * 64,
        }
        new_release = {
            'revision': current, 'api_image_id': 'sha256:' + '3' * 64,
            'web_image_id': 'sha256:' + '4' * 64,
            'artifact_sha256': '3' * 64, 'decoder_sha256': '4' * 64,
        }
        old_state = {'release': old_release, 'history': [old_release]}
        new_state = {'release': new_release, 'previous_release': old_release,
                     'history': [old_release, new_release]}
        evidence = dict(resources='stable', volumes={}, state='old', pg='pg', ledger='ledger',
                        ledger_roots=1, vault={}, services={'web': True})
        binding = {'revision': previous, 'evidence': evidence}
        exact = self.stage.release.staging_receipt(
            'updated', box.volume, schema, previous, current,
            rollback={'attempted': False, 'succeeded': None, 'revision': previous,
                      'release': old_release},
            releases={'b': [current, [new_release['api_image_id'], new_release['web_image_id']]]},
            release=new_release, previous_release=old_release)
        for field in ('release', 'previous_release', 'rollback'):
            with self.subTest(field=field):
                receipt = copy.deepcopy(exact)
                if field == 'release':
                    receipt['release']['artifact_sha256'] = 'f' * 64
                elif field == 'previous_release':
                    receipt['previous_release']['decoder_sha256'] = 'f' * 64
                else:
                    receipt['rollback']['release']['artifact_sha256'] = 'f' * 64

                def fixed(*args, **kwargs):
                    print(json.dumps(receipt))
                    return '127.0.0.1:1234'

                with patch.object(self.stage.staging, 'schema_version', return_value='1'),                         patch.object(self.stage, 'observe',
                                     side_effect=[(old_state, evidence), (new_state, evidence)]),                         patch.object(self.stage.release, 'run_ci_staging', side_effect=fixed):
                    with self.assertRaisesRegex(self.stage.ProofError, 'updated receipt release proof differs'):
                        self.stage.run_phase('update', box, recovery, candidate, Path('/work'), {},
                                             schema, binding)

    def test_negative_uses_fixed_release_refusal_and_keeps_state_unchanged(self):
        box = Mock()
        box.volume = 'proof-state'
        candidate = Mock()
        recovery = Mock()
        digest = 'a' * 64
        with patch.object(self.stage.release, 'run_ci_staging', side_effect=ValueError(
                'staging state schema digest mismatch')) as fixed:
            self.stage.reject_schema(box, candidate, Path('/work'), {}, digest, recovery)
        self.assertEqual(fixed.call_args.args[:4], (box, candidate, Path('/work'), {}))
        self.assertNotEqual(fixed.call_args.args[4], digest)
        self.assertEqual(fixed.call_args.args[5], box.volume)
        self.assertIs(fixed.call_args.kwargs['recovery'], recovery)
        box.fenced.assert_called_once_with()
        recovery.write.assert_not_called()

    def test_negative_requires_the_exact_fixed_stage_refusal(self):
        for result in (None, ValueError('unrelated fault')):
            box = Mock()
            with self.subTest(result=result), patch.object(self.stage.release, 'run_ci_staging',
                                                            side_effect=result):
                with self.assertRaises(self.stage.ProofError):
                    self.stage.reject_schema(box, Mock(), Path('/work'), {}, 'a' * 64, Mock())
            box.fenced.assert_not_called()


if __name__ == '__main__':
    unittest.main()

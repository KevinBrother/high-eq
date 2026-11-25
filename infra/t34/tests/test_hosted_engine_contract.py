"""Offline parent/child contract for the private hosted engine."""
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from ci import hosted_engine, hosted_entry, hosted_stage
import isolated_staging_lab as guard


ENGINE_ID = 'a' * 64
RUN_ID = 'b' * 24
OWNER = 'c' * 48
ROOTLESS_WIRE = ['name=rootless', 'name=seccomp,profile=builtin']


def socket_identity(path):
    info = path.lstat()
    return info.st_dev, info.st_ino, info.st_ctime_ns


class HostedEngineContractTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory(prefix='t34-engine-contract-', dir='/tmp')
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name).resolve()
        self.root.chmod(0o700)

    def prepare_short_engine(self):
        paths = hosted_entry._engine_paths(self.root)
        for directory in (paths.home, paths.config, paths.runtime, paths.data_root, paths.exec_root):
            directory.mkdir(mode=0o700)
            directory.chmod(0o700)
        paths.socket.touch(mode=0o600)
        return paths

    @staticmethod
    def parent_info(paths, security):
        stdout = (f'{ENGINE_ID}\t27.1.1\t{json.dumps(security)}\t{paths.data_root}\n').encode()
        return SimpleNamespace(returncode=0, stdout=stdout)

    def child_lab(self, paths):
        environ = {
            guard.ENGINE_HOST_ENV: paths.host,
            guard.ENGINE_ID_ENV: ENGINE_ID,
            'DOCKER_HOST': paths.host,
        }
        binding = hosted_stage.EngineBinding.from_parent(environ, self.root)
        lab = hosted_stage.HostedLab(self.root, (self.root,), RUN_ID, binding, OWNER)
        lab._docker = Mock(return_value=(
            f'{ENGINE_ID}\tlinux\t{json.dumps(ROOTLESS_WIRE)}\t{binding.data_root}\n'
        ).encode())
        return binding, lab

    def test_parent_and_child_share_the_short_layout_and_rootless_wire_format(self):
        paths = self.prepare_short_engine()
        self.assertEqual(paths, hosted_engine.engine_paths(self.root))
        with patch.object(hosted_engine.subprocess, 'run',
                          return_value=self.parent_info(paths, ROOTLESS_WIRE)) as run:
            self.assertEqual(hosted_engine._docker_info(paths, {}),
                             {'engine_id': ENGINE_ID, 'server_version': '27.1.1', 'rootless': True})
        run.assert_called_once()

        with patch.object(hosted_stage.EngineBinding, 'inspect_socket', staticmethod(socket_identity)):
            binding, lab = self.child_lab(paths)
            self.assertEqual(binding.socket, paths.socket)
            self.assertEqual(binding.data_root, paths.data_root)
            lab._verify_engine()
            self.assertTrue(lab._engine_verified)

    def test_parent_and_child_reject_malformed_or_non_rootless_security_options(self):
        paths = self.prepare_short_engine()
        with patch.object(hosted_stage.EngineBinding, 'inspect_socket', staticmethod(socket_identity)):
            binding, lab = self.child_lab(paths)
            for security in ([], ['rootless'], ['name=userns'], ['name=rootless', 'name=userns'],
                             ['name=rootless', 7], {'name=rootless': True}, 'name=rootless'):
                with self.subTest(security=security):
                    with patch.object(hosted_engine.subprocess, 'run',
                                      return_value=self.parent_info(paths, security)):
                        self.assertIsNone(hosted_engine._docker_info(paths, {}))
                    lab._docker.return_value = (
                        f'{ENGINE_ID}\tlinux\t{json.dumps(security)}\t{binding.data_root}\n'
                    ).encode()
                    with self.assertRaises(hosted_stage.ProofError):
                        lab._verify_engine()

    def test_long_or_external_engine_layout_is_rejected_by_both_sides(self):
        long_runtime = self.root / 'runtime'
        long_data = self.root / 'data-root'
        long_runtime.mkdir(mode=0o700)
        long_data.mkdir(mode=0o700)
        long_socket = long_runtime / 'docker.sock'
        long_socket.touch(mode=0o600)
        long_paths = hosted_entry._engine_paths(self.root)
        long_paths = hosted_engine.EnginePaths(
            root=long_paths.root,
            home=long_paths.home,
            config=long_paths.config,
            runtime=long_runtime,
            data_root=long_data,
            exec_root=long_paths.exec_root,
            socket=long_socket,
            pidfile=long_runtime / 'docker.pid',
            log=long_paths.log,
        )
        with patch.object(hosted_engine.subprocess, 'run',
                          return_value=self.parent_info(long_paths, ['name=rootless'])) as run:
            self.assertIsNone(hosted_engine._docker_info(long_paths, {}))
        run.assert_not_called()

        environ = {
            guard.ENGINE_HOST_ENV: long_paths.host,
            guard.ENGINE_ID_ENV: ENGINE_ID,
            'DOCKER_HOST': long_paths.host,
        }
        with patch.object(hosted_stage.EngineBinding, 'inspect_socket', staticmethod(socket_identity)), \
                self.assertRaisesRegex(hosted_stage.ProofError, 'private engine layout invalid'):
            hosted_stage.EngineBinding.from_parent(environ, self.root)


if __name__ == '__main__':
    unittest.main()

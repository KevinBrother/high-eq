"""A failed independent sweep must prevent the normal rollback launch."""
import subprocess
import unittest
from unittest.mock import Mock

from lab import Lab


class RollbackGate(unittest.TestCase):
    def test_sweep_wait_timeout_never_attempts_old_ingress(self):
        subject = object.__new__(Lab)
        subject.env = {'DB_SERVICE': 'restored'}
        subject.sql = Mock(return_value='a' * 64)
        subject.close_serving = Mock()
        launches = []

        def compose(*args, **kwargs):
            if args[0] == 'up':
                if args[-1] == 'chat-sweeper':
                    raise subprocess.TimeoutExpired('synthetic sweep wait', 1)
                launches.append(args[-2:])
            return b''

        subject.compose = compose
        subject.run = Mock(side_effect=AssertionError('must not inspect a launched image'))
        ids = ['sha256:' + 'a' * 64, 'sha256:' + 'b' * 64]
        try:
            with self.assertRaisesRegex(ValueError, 'sweeper unavailable'):
                subject.open_release('rollback', 'old', ids, preview=True, by_id=True)
        finally:
            self.assertEqual(launches, [])
        subject.close_serving.assert_called_once_with()

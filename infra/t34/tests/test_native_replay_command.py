import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

T34 = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(T34))
import release
import verify_backup_replay


SEAL = '33333333-3333-4333-8333-333333333333:45'
ROOT = '11111111-1111-4111-8111-111111111111'
DEADLINE_MS = 1_765_000_000_123


class NativeReplayCommandTypes(unittest.TestCase):
    def test_refuse_missing_root_stringifies_deadline_without_mutating_ledger(self):
        calls = []

        def run(command, **options):
            self.assertTrue(all(isinstance(argument, str) for argument in command), command)
            calls.append(command)
            return subprocess.CompletedProcess(command, 0, b'1', b'')

        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp) / 'work'
            source = Path(tmp) / 'source'
            work.mkdir()
            source.mkdir()
            subject = verify_backup_replay.NativeReplay(
                work, source, 'postgresql://127.0.0.1/source', 'redis://127.0.0.1/0',
                'redis://127.0.0.1/0')
            frozen = {ROOT: DEADLINE_MS}
            with mock.patch.object(verify_backup_replay, '_run_timed_compose', side_effect=run), \
                    mock.patch.object(release, 'audit'), \
                    mock.patch.object(subject, 'probe_missing_root') as probe:
                release.refuse_missing_root(subject, SEAL, work / 'witness.json', frozen, ROOT)

        self.assertEqual(frozen, {ROOT: DEADLINE_MS})
        self.assertEqual(calls[1][-1], str(DEADLINE_MS))
        probe.assert_called_once_with(ROOT)


if __name__ == '__main__':
    unittest.main()

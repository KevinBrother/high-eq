"""Exercise the exact fixed-staging writer with a local temp volume, not Docker."""
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from test_staging import staging


class DurableStateWriter(unittest.TestCase):
    def test_syncs_data_before_rename_and_requires_post_rename_directory_sync(self):
        for fail_directory in (False, True):
            with self.subTest(fail_directory=fail_directory), tempfile.TemporaryDirectory() as temp:
                target = Path(temp) / staging.STATE_FILE
                target.write_bytes(b'prior\n')
                script = '''
import os, stat, sys
from pathlib import Path

target = Path(sys.argv[3])
real_sync = os.fsync

def inspect_sync(fd):
    if stat.S_ISDIR(os.fstat(fd).st_mode):
        assert target.read_bytes() == b'candidate\\n'
        print('directory', flush=True)
        if sys.argv[2] == 'True':
            raise OSError('injected state-volume directory fsync failure')
    else:
        assert target.read_bytes() == b'prior\\n'
        print('file', flush=True)
    real_sync(fd)

os.fsync = inspect_sync
'''
                script += staging._DURABLE_WRITER
                run = subprocess.run([sys.executable, '-c', script, temp, str(fail_directory), str(target)],
                                     input=b'candidate\n', capture_output=True)
                self.assertEqual(run.stdout.splitlines(), [b'file', b'directory'], run.stderr)
                self.assertEqual(run.returncode == 0, not fail_directory, run.stderr)
                self.assertEqual(target.read_bytes(), b'candidate\n')
                self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
                self.assertEqual(list(Path(temp).iterdir()), [target])

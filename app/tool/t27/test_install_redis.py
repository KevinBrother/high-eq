"""Offline fail-closed test for the Linux Redis installer."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


INSTALLER = Path(__file__).with_name("install_redis.sh")


class RedisInstallerTests(unittest.TestCase):
    def test_bad_download_stops_before_extraction_or_build(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tools = root / "bin"
            tools.mkdir()
            commands = {
                "curl": 'while [ "$1" != --output ]; do shift; done\nprintf corrupt > "$2"',
                "tar": 'touch "$T27_TEST_UNVERIFIED_ARCHIVE_USED"',
                "make": 'touch "$T27_TEST_UNVERIFIED_ARCHIVE_USED"',
            }
            for name, script in commands.items():
                command = tools / name
                command.write_text(f"#!/bin/sh\nset -eu\n{script}\n")
                command.chmod(0o700)
            marker = root / "unverified-archive-used"
            destination = root / "install"
            # macOS provides shasum instead of the Linux sha256sum command.
            if shutil.which("sha256sum", path=os.defpath) is None:
                command = tools / "sha256sum"
                command.write_text('#!/bin/sh\nexec shasum -a 256 "$@"\n')
                command.chmod(0o700)
            result = subprocess.run(
                ["bash", str(INSTALLER), str(destination)],
                env={**os.environ, "PATH": f"{tools}:{os.defpath}",
                     "TMPDIR": str(root), "T27_TEST_UNVERIFIED_ARCHIVE_USED": str(marker)},
                capture_output=True, text=True, check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("FAILED", result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertFalse((destination / "redis-server").exists())


if __name__ == "__main__":
    unittest.main()

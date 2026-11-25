import tempfile
import unittest
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import evidence as e


class Evidence(unittest.TestCase):
    def test_backup_scope_checksum_and_horizon(self):
        with tempfile.TemporaryDirectory() as tmp:
            dump = Path(tmp) / 'business.dump'
            dump.write_bytes(b'synthetic')
            doc = e.manifest(dump, 'run1', 'image1', 100)
            for scope, image, now in [('run2', 'image1', 101), ('run1', 'image2', 101),
                                      ('run1', 'image1', 99), ('run1', 'image1', 100+45*86400)]:
                with self.assertRaises(ValueError):
                    e.check(doc, dump, scope, image, now)
            e.check(doc, dump, 'run1', 'image1', 101)
            dump.write_bytes(b'tampered')
            with self.assertRaises(ValueError):
                e.check(doc, dump, 'run1', 'image1', 101)

    def test_latest_independent_witness(self):
        from uuid import uuid4
        keys = [str(uuid4()) for _ in range(5)]
        seal = str(uuid4()) + ':45'
        e.coverage(seal, keys, seal, keys[::-1])
        for identity, actual in [(seal, keys[:-1]), (seal, keys+keys[:1]),
                                  (seal, []), (str(uuid4())+':45', keys)]:
            with self.assertRaises(ValueError):
                e.coverage(seal, keys, identity, actual)

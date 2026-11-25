import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
from approval_fixture import write_static_approval
from ci import materialize_decoder_approval as materializer
import release_approval


class ApprovalMaterializerContract(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='t34-approval-materializer-')
        self.work = Path(self.temp.name)
        self.checkout = self.work / 'checkout'
        self.checkout.mkdir()
        source = write_static_approval(self.work / 'source.json')
        self.raw = source.read_text()

    def tearDown(self):
        self.temp.cleanup()

    def test_non_empty_document_is_written_as_external_owner_only_file(self):
        target = self.work / 'approval.json'
        written, digest = materializer.materialize(self.raw, target, self.checkout)
        self.assertEqual(written, target.resolve())
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
        document, loaded_digest = release_approval.load_document(target, (self.checkout,))
        self.assertEqual(document['scope'], 't34.recovery.decoder.v1')
        self.assertEqual(digest, loaded_digest)

    def test_empty_or_blank_secret_is_refused_without_creating_a_file(self):
        for value in ('', ' \n\t'):
            target = self.work / ('empty-' + str(len(value)) + '.json')
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, 'is empty'):
                materializer.materialize(value, target, self.checkout)
            self.assertFalse(target.exists())

    def test_destination_inside_the_checkout_is_refused(self):
        target = self.checkout / 'approval.json'
        with self.assertRaisesRegex(ValueError, 'outside the checkout'):
            materializer.materialize(self.raw, target, self.checkout)
        self.assertFalse(target.exists())

    def test_symlink_destination_is_refused_without_touching_its_target(self):
        outside = self.work / 'outside.json'
        outside.write_text('sentinel')
        target = self.work / 'approval.json'
        target.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, 'must not be a symlink'):
            materializer.materialize(self.raw, target, self.checkout)
        self.assertTrue(target.is_symlink())
        self.assertEqual(outside.read_text(), 'sentinel')

    def test_existing_group_or_other_writable_destination_is_refused(self):
        target = self.work / 'approval.json'
        target.write_text('sentinel')
        target.chmod(0o666)
        with self.assertRaisesRegex(ValueError, 'unsafe permissions'):
            materializer.materialize(self.raw, target, self.checkout)
        self.assertEqual(target.read_text(), 'sentinel')
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o666)

    def test_invalid_document_is_removed_after_schema_validation(self):
        target = self.work / 'approval.json'
        with self.assertRaisesRegex(ValueError, 'schema invalid'):
            materializer.materialize(json.dumps({'version': 1}), target, self.checkout)
        self.assertFalse(target.exists())

    def test_partial_write_failure_removes_the_created_file(self):
        target = self.work / 'approval.json'
        with mock.patch.object(materializer.os, 'fdopen', side_effect=OSError('synthetic write failure')):
            with self.assertRaisesRegex(OSError, 'synthetic write failure'):
                materializer.materialize(self.raw, target, self.checkout)
        self.assertFalse(target.exists())

    def test_cli_refuses_an_empty_secret(self):
        target = self.work / 'approval.json'
        with mock.patch.dict(os.environ, {materializer.SECRET_ENV: ''}, clear=False):
            self.assertEqual(materializer.main([str(self.checkout), str(target)]), 1)
        self.assertFalse(target.exists())


if __name__ == '__main__':
    unittest.main()

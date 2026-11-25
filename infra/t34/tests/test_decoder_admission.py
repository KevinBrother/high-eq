import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
import decoder_contract
import release


PREVIOUS = 'd44e8b6d4b1d6767a1bd3082ed8530a31735cc17'
DECODER_BRANCH = ('if src.Kind != "practice" {', 'if src.Kind == "practice" {')


class DecoderAdmissionContract(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='t34-decoder-admission-')
        self.work = Path(self.temp.name)
        self.candidate = self.work / 'candidate'
        shutil.copytree(ROOT, self.candidate)

    def tearDown(self):
        self.temp.cleanup()

    def write_approvals(self, name, *sources):
        records = []
        seen = set()
        for source in sources:
            contract = decoder_contract.inspect_release(source)
            pair = contract['artifact_sha256'], contract['decoder_sha256']
            if pair in seen:
                continue
            seen.add(pair)
            records.append({
                'artifact_sha256': contract['artifact_sha256'],
                'decoder_sha256': contract['decoder_sha256'],
                'approved_by': 'synthetic-release-reviewer',
                'approval_ref': 'T34-SYNTHETIC-DECODER-001',
                'approved_at': '2026-11-24T12:00:00Z',
            })
        path = self.work / name
        path.write_text(json.dumps({
            'version': 1,
            'scope': 't34.recovery.decoder.v1',
            'approvals': records,
        }, sort_keys=True))
        path.chmod(0o600)
        return path

    def test_unchanged_candidate_and_previous_pass_with_external_approval(self):
        approvals = self.write_approvals('approvals.json', self.candidate, ROOT)
        receipt, schema = release.validate_release(
            self.candidate, ROOT, PREVIOUS, approvals)
        self.assertEqual(receipt['decoder_admission']['candidate']['decision'], 'approved')
        self.assertEqual(receipt['decoder_admission']['previous']['decision'], 'approved')
        self.assertRegex(schema, r'^[0-9a-f]{64}$')

    def test_implementation_only_drift_invalidates_the_existing_approval(self):
        approvals = self.write_approvals('approvals.json', self.candidate, ROOT)
        delivery = self.candidate / 'server/internal/training/delivery.go'
        text = delivery.read_text()
        self.assertEqual(text.count(DECODER_BRANCH[0]), 1)
        delivery.write_text(text.replace(*DECODER_BRANCH))
        with self.assertRaisesRegex(ValueError, 'no matching external approval'):
            release.validate_release(self.candidate, ROOT, PREVIOUS, approvals)

    def test_new_decoder_behavior_passes_only_with_a_fresh_artifact_bound_approval(self):
        delivery = self.candidate / 'server/internal/training/delivery.go'
        delivery.write_text(delivery.read_text().replace(*DECODER_BRANCH))
        approvals = self.write_approvals('fresh-approvals.json', self.candidate, ROOT)
        receipt, _ = release.validate_release(
            self.candidate, ROOT, PREVIOUS, approvals)
        candidate = receipt['decoder_admission']['candidate']
        self.assertEqual(candidate['decision'], 'approved')
        self.assertEqual(candidate['approval_ref'], 'T34-SYNTHETIC-DECODER-001')

    def test_artifact_change_after_approval_invalidates_it_even_with_same_behavior_digest(self):
        before = decoder_contract.inspect_release(self.candidate)
        approvals = self.write_approvals('approvals.json', self.candidate, ROOT)
        readme = self.candidate / 'admin/README.md'
        readme.chmod(readme.stat().st_mode | 0o111)
        after = decoder_contract.inspect_release(self.candidate)
        self.assertEqual(before['decoder_sha256'], after['decoder_sha256'])
        self.assertNotEqual(before['artifact_sha256'], after['artifact_sha256'])
        with self.assertRaisesRegex(ValueError, 'no matching external approval'):
            release.validate_release(self.candidate, ROOT, PREVIOUS, approvals)

    def test_go_embed_directive_change_invalidates_the_existing_approval(self):
        before = decoder_contract.inspect_release(self.candidate)
        approvals = self.write_approvals('approvals.json', self.candidate, ROOT)
        store = self.candidate / 'server/internal/training/store.go'
        text = store.read_text()
        self.assertEqual(text.count('//go:embed role.txt\n'), 1)
        store.write_text(text.replace('//go:embed role.txt\n', '//go:embed missing.txt\n'))
        after = decoder_contract.inspect_release(self.candidate)
        self.assertNotEqual(before['decoder_sha256'], after['decoder_sha256'])
        with self.assertRaisesRegex(ValueError, 'no matching external approval'):
            release.validate_release(self.candidate, ROOT, PREVIOUS, approvals)

    def test_go_automatic_semicolon_boundary_invalidates_the_existing_approval(self):
        before = decoder_contract.inspect_release(self.candidate)
        approvals = self.write_approvals('approvals.json', self.candidate, ROOT)
        delivery = self.candidate / 'server/internal/training/delivery.go'
        text = delivery.read_text()
        old = '\t\treturn v.Values(), e\n'
        self.assertEqual(text.count(old), 1)
        delivery.write_text(text.replace(old, '\t\treturn\n\t\t\tv.Values(), e\n'))
        after = decoder_contract.inspect_release(self.candidate)
        self.assertNotEqual(before['decoder_sha256'], after['decoder_sha256'])
        with self.assertRaisesRegex(ValueError, 'no matching external approval'):
            release.validate_release(self.candidate, ROOT, PREVIOUS, approvals)

    def test_transitive_dependency_change_invalidates_the_existing_approval(self):
        approvals = self.write_approvals('approvals.json', self.candidate, ROOT)
        config = self.candidate / 'server/internal/api/app/config.yaml'
        config.write_text(config.read_text() + '\n# synthetic dependency resource drift\n')
        with self.assertRaisesRegex(ValueError, 'no matching external approval'):
            release.validate_release(self.candidate, ROOT, PREVIOUS, approvals)

    def test_embedded_decoder_resource_change_invalidates_the_existing_approval(self):
        approvals = self.write_approvals('approvals.json', self.candidate, ROOT)
        role = self.candidate / 'server/internal/training/role.txt'
        role.write_text(role.read_text() + '\n合成 decoder 资源变更。\n')
        with self.assertRaisesRegex(ValueError, 'no matching external approval'):
            release.validate_release(self.candidate, ROOT, PREVIOUS, approvals)

    def test_comment_only_decoder_change_requires_a_new_exact_approval(self):
        approvals = self.write_approvals('approvals.json', self.candidate, ROOT)
        delivery = self.candidate / 'server/internal/training/delivery.go'
        original = delivery.read_text()
        delivery.write_text(original.replace(
            'func Decoder(', '// Synthetic decoder comment drift.\nfunc Decoder(', 1,
        ))
        with self.assertRaisesRegex(ValueError, 'no matching external approval'):
            release.validate_release(self.candidate, ROOT, PREVIOUS, approvals)

    def test_non_go_package_resource_change_invalidates_the_existing_approval(self):
        approvals = self.write_approvals('approvals.json', self.candidate, ROOT)
        resource = self.candidate / 'server/internal/reviews/testdata/pgpipe.mjs'
        resource.write_text(resource.read_text() + '\n// Synthetic resource drift.\n')
        with self.assertRaisesRegex(ValueError, 'no matching external approval'):
            release.validate_release(self.candidate, ROOT, PREVIOUS, approvals)

    def test_relative_approval_path_is_refused(self):
        approvals = self.write_approvals('approvals.json', self.candidate, ROOT)
        relative = Path(os.path.relpath(approvals, Path.cwd()))
        with self.assertRaisesRegex(ValueError, 'path must be absolute'):
            release.validate_release(self.candidate, ROOT, PREVIOUS, relative)

    def test_approval_record_cannot_live_inside_the_candidate_artifact(self):
        approvals = self.write_approvals('approvals.json', self.candidate, ROOT)
        embedded = self.candidate / 'release-approval.json'
        shutil.copyfile(approvals, embedded)
        embedded.chmod(0o600)
        with self.assertRaisesRegex(ValueError, 'outside candidate and previous artifacts'):
            release.validate_release(self.candidate, ROOT, PREVIOUS, embedded)


if __name__ == '__main__':
    unittest.main()

import os
import subprocess
import tempfile
import unittest
import unittest.mock
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
import sys
sys.path.insert(0, str(HERE))
import inputs


def git(repo, *args, **kwargs):
    env = os.environ | {
        'GIT_AUTHOR_NAME': 'T34 Test',
        'GIT_AUTHOR_EMAIL': 't34@example.invalid',
        'GIT_COMMITTER_NAME': 'T34 Test',
        'GIT_COMMITTER_EMAIL': 't34@example.invalid',
    }
    return subprocess.run(['git', '-C', str(repo), *args], env=env, check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          **kwargs).stdout.decode().strip()


class InputBoundaryContract(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / 'repo'
        self.root.mkdir()
        git(self.root, 'init', '-q')
        for path in ('server', 'admin', 'infra/t34', '.github/workflows'):
            (self.root / path).mkdir(parents=True, exist_ok=True)
        (self.root / 'server/base.txt').write_text('published-server\n')
        (self.root / 'admin/base.txt').write_text('published-admin\n')
        (self.root / 'infra/t34/marker.txt').write_text('base-infra\n')
        (self.root / '.github/workflows/t34-release.yml').write_text('name: base\n')
        (self.root / '.github/workflows/t34-isolated-proof.yml').write_text('name: isolated\n')
        (self.root / '.github/workflows/verify.yml').write_text('name: unrelated\n')
        git(self.root, 'add', '.')
        git(self.root, 'commit', '-q', '-m', 'base')
        self.base = git(self.root, 'rev-parse', 'HEAD')
        self.base_tree = git(self.root, 'rev-parse', 'HEAD^{tree}')

        (self.root / 'server/candidate.txt').write_text('candidate-server\n')
        (self.root / 'infra/t34/marker.txt').write_text('candidate-infra\n')
        git(self.root, 'add', '.')
        git(self.root, 'commit', '-q', '-m', 'candidate')
        self.candidate = git(self.root, 'rev-parse', 'HEAD')
        self.candidate_tree = git(self.root, 'rev-parse', 'HEAD^{tree}')

    def tearDown(self):
        self.temp.cleanup()

    def test_missing_or_non_tree_objects_are_rejected(self):
        with self.assertRaisesRegex(ValueError, 'tree object missing'):
            inputs.stage_inputs(self.root, Path(self.temp.name) / 'missing',
                                Path(self.temp.name) / 'missing-prior', tree='f' * 40)
        blob = git(self.root, 'hash-object', '-w', 'server/base.txt')
        with self.assertRaisesRegex(ValueError, 'must be a tree'):
            inputs.stage_inputs(self.root, Path(self.temp.name) / 'blob',
                                Path(self.temp.name) / 'blob-prior', tree=blob)

    def test_previous_rejects_refs_abbreviations_and_non_commit_objects(self):
        fixture = Path(self.temp.name)
        records = (
            ('HEAD', 'full commit SHA'),
            (self.base[:12], 'full commit SHA'),
            (self.base_tree, 'must be a commit object'),
            ('f' * 40, 'object missing'),
        )
        for value, error in records:
            with self.subTest(value=value):
                with self.assertRaisesRegex(ValueError, error):
                    inputs.stage_inputs(
                        self.root, fixture / 'current', fixture / 'prior',
                        tree=self.candidate_tree, previous_commit=value,
                    )
                self.assertFalse((fixture / 'current').exists())
                self.assertFalse((fixture / 'prior').exists())

    def test_only_the_explicit_tree_and_whitelist_enter_the_build_context(self):
        (self.root / '.env').write_text('SECRET=never\n')
        (self.root / 'server/private.dump').write_text('never\n')
        (self.root / 'user-profile.json').write_text('{"name":"never"}\n')
        current = Path(self.temp.name) / 'current'
        prior = Path(self.temp.name) / 'prior'
        resolved = inputs.stage_inputs(
            self.root, current, prior, tree=self.base_tree, previous_commit=self.base)
        self.assertEqual(resolved, self.base_tree)
        self.assertEqual((current / 'infra/t34/marker.txt').read_text(), 'base-infra\n')
        self.assertFalse((current / '.env').exists())
        self.assertFalse((current / 'server/private.dump').exists())
        self.assertFalse((current / 'user-profile.json').exists())

    def test_candidate_archive_contains_only_the_required_t34_workflows(self):
        current = Path(self.temp.name) / 'current'
        prior = Path(self.temp.name) / 'prior'
        inputs.stage_inputs(self.root, current, prior,
                            tree=self.candidate_tree, previous_commit=self.base)
        workflows = current / '.github/workflows'
        self.assertEqual(
            sorted(path.name for path in workflows.iterdir()),
            ['t34-isolated-proof.yml', 't34-release.yml'],
        )

    def test_specified_tree_content_wins_and_prior_uses_mixed_sources(self):
        current = Path(self.temp.name) / 'current'
        prior = Path(self.temp.name) / 'prior'
        inputs.stage_inputs(self.root, current, prior,
                            tree=self.candidate_tree, previous_commit=self.base)
        self.assertEqual((current / 'infra/t34/marker.txt').read_text(), 'candidate-infra\n')
        self.assertEqual((current / 'server/candidate.txt').read_text(), 'candidate-server\n')
        self.assertFalse((prior / 'server/candidate.txt').exists())
        self.assertEqual((prior / 'server/base.txt').read_text(), 'published-server\n')
        self.assertEqual((prior / 'infra/t34/marker.txt').read_text(), 'candidate-infra\n')

    def test_environment_tree_is_used_when_no_explicit_tree_is_passed(self):
        current = Path(self.temp.name) / 'current'
        prior = Path(self.temp.name) / 'prior'
        with unittest.mock.patch.dict(os.environ, {'T34_CANDIDATE_TREE': self.base_tree}, clear=False):
            resolved = inputs.stage_inputs(self.root, current, prior,
                                           previous_commit=self.base)
        self.assertEqual(resolved, self.base_tree)


if __name__ == '__main__':
    unittest.main()

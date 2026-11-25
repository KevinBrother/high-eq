import os
import subprocess
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
T34 = HERE.parent
ROOT = HERE.parents[2]
ACCEPT = T34 / 'accept.sh'


class AcceptContract(unittest.TestCase):
    def test_persistent_stage_requires_explicit_local_authorization(self):
        env = dict(os.environ)
        env.pop('T34_ALLOW_PERSISTENT_TEST', None)
        env.pop('CI', None)
        result = subprocess.run(['bash', str(ACCEPT), '--stage-test'], cwd=ROOT,
                                env=env, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('T34_ALLOW_PERSISTENT_TEST=1', result.stdout)

    def test_ci_staging_is_rejected_locally_before_git_or_docker(self):
        env = dict(os.environ)
        for name in ('CI', 'GITHUB_ACTIONS', 'RUNNER_ENVIRONMENT'):
            env.pop(name, None)
        result = subprocess.run(['bash', str(ACCEPT), '--ci-staging'], cwd=ROOT,
                                env=env, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('authorized GitHub Actions self-hosted runner', result.stdout)

    def test_ci_staging_requires_a_named_state_volume_before_git_or_docker(self):
        env = dict(os.environ)
        env.update(CI='true', GITHUB_ACTIONS='true', RUNNER_ENVIRONMENT='self-hosted')
        env.pop('T34_STAGING_STATE_VOLUME', None)
        result = subprocess.run(['bash', str(ACCEPT), '--ci-staging'], cwd=ROOT,
                                env=env, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('T34_STAGING_STATE_VOLUME', result.stdout)

        for value in ('/var/lib/t34', '../state', 'volume:rw'):
            env['T34_STAGING_STATE_VOLUME'] = value
            with self.subTest(value=value):
                result = subprocess.run(['bash', str(ACCEPT), '--ci-staging'], cwd=ROOT,
                                        env=env, text=True, stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Docker volume name', result.stdout)

    def test_previous_release_requires_an_explicit_full_commit_sha(self):
        with tempfile.TemporaryDirectory() as tmp:
            detached = Path(tmp) / 'synthetic.json'
            detached.write_text('{}')
            env = dict(os.environ, T34_DECODER_APPROVALS=str(detached))
            for value in ('', 'd44e8b6', 'HEAD', '4' * 40 + '^'):
                with self.subTest(value=value):
                    result = subprocess.run(
                        ['bash', str(ACCEPT), '--config-only'], cwd=ROOT,
                        env=dict(env, T34_PREVIOUS_COMMIT=value), text=True,
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                    )
                    self.assertEqual(result.returncode, 64, result.stdout)
                    self.assertIn('T34_PREVIOUS_COMMIT must be a full commit SHA', result.stdout)

    def test_candidate_inputs_come_from_a_git_tree_and_explicit_whitelist(self):
        accept = ACCEPT.read_text()
        self.assertIn('T34_CANDIDATE_TREE', accept)
        self.assertIn("HEAD^{tree}", accept)
        self.assertIn('inputs.py', accept)
        self.assertNotIn('tar -C "$archive"', accept)
        self.assertNotIn('--exclude=', accept)

    def test_decoder_approval_is_rejected_before_git_or_docker(self):
        base = dict(os.environ)

        def rejected(value, expected):
            env = dict(base)
            env['T34_DECODER_APPROVALS'] = value
            result = subprocess.run(['bash', str(ACCEPT), '--config-only'], cwd=ROOT,
                                    env=env, text=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(expected, result.stdout)

        with tempfile.TemporaryDirectory() as tmp:
            rejected('relative/approvals.json', 'must be an absolute')
            rejected(str(Path(tmp) / 'missing.json'), 'must be a regular file')
            rejected(str(T34 / 'accept.sh'), 'must be outside the checkout')

    def test_stage_is_fixed_loopback_only_and_has_an_explicit_destroy_entry(self):
        accept = ACCEPT.read_text()
        lab = (T34 / 'lab.py').read_text()
        release = (T34 / 'release.py').read_text()
        preview = (T34 / 'preview.yml').read_text()
        self.assertIn('--stage-test', accept)
        self.assertIn('--destroy-stage', accept)
        self.assertIn("T34_ALLOW_PERSISTENT_TEST", accept)
        self.assertIn("CI", accept)
        self.assertIn("t34-synthetic-stage", lab)
        self.assertIn('--stage-test', release)
        self.assertIn('127.0.0.1::8080', preview)


if __name__ == '__main__':
    unittest.main()

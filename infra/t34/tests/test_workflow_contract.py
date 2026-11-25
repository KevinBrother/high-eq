"""Static release-workflow contract for exact, externally approved artifacts."""
import re
from pathlib import Path
import unittest

T34 = Path(__file__).resolve().parents[1]
ROOT = T34.parents[1]
WORKFLOW = ROOT / '.github/workflows/t34-release.yml'
APPROVAL_SECRET = 'T34_DECODER_APPROVALS_JSON'


class WorkflowContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = WORKFLOW.read_text()

    def job(self, name, following=None):
        start = self.workflow.index(f'  {name}:')
        end = (self.workflow.index(f'  {following}:', start)
               if following is not None else len(self.workflow))
        return self.workflow[start:end]

    def test_contract_job_runs_the_complete_offline_suite_on_a_hosted_runner(self):
        contract = self.job('contract', 'stage-preflight')
        self.assertIn('runs-on: ubuntu-24.04', contract)
        self.assertIn('working-directory: infra/t34', contract)
        self.assertIn("python3 -m unittest discover -s tests -p 'test_*.py' -v", contract)
        self.assertIn("PYTHONDONTWRITEBYTECODE: '1'", contract)
        self.assertNotIn('secrets.', contract)

    def test_main_release_jobs_use_the_fixed_protected_environment(self):
        for name, following in (('stage-preflight', 'stage-test'), ('stage-test', None)):
            with self.subTest(job=name):
                block = self.job(name, following)
                self.assertIn('environment: t34-synthetic-release', block)
                self.assertIn("github.ref == 'refs/heads/main'", block if name == 'stage-preflight' else self.workflow)
        self.assertNotIn('vars.T34_STAGING_ENVIRONMENT', self.workflow)
        self.assertNotIn('environment: ${{', self.workflow)

    def test_only_the_decoder_approval_secret_can_enter_a_job_environment(self):
        secrets = set(re.findall(r'secrets\.([A-Za-z0-9_]+)', self.workflow))
        self.assertEqual(secrets, {APPROVAL_SECRET})
        for name, following in (('stage-preflight', 'stage-test'), ('stage-test', None)):
            block = self.job(name, following)
            self.assertIn('secrets.' + APPROVAL_SECRET, block)

    def test_approval_is_materialized_before_config_validation_and_staging(self):
        materialized = self.workflow.index('materialize_decoder_approval.py')
        validated = self.workflow.index('infra/t34/accept.sh --config-only')
        staged = self.workflow.index('infra/t34/accept.sh --ci-staging')
        self.assertLess(materialized, validated)
        self.assertLess(validated, staged)
        preflight = self.job('stage-preflight', 'stage-test')
        stage = self.job('stage-test')
        self.assertLess(preflight.index('materialize_decoder_approval.py'),
                        preflight.index('infra/t34/accept.sh --config-only'))
        self.assertLess(stage.index('materialize_decoder_approval.py'),
                        stage.index('infra/t34/accept.sh --ci-staging'))

    def test_missing_protected_inputs_explicitly_skip_release_admission(self):
        self.assertIn('configured=false', self.workflow)
        self.assertIn('未部署/已跳过，发布准入未执行。', self.workflow)
        self.assertIn('不得将本结果记作 T34 发布通过。', self.workflow)
        self.assertIn('缺少受保护环境 secret', self.workflow)
        self.assertIn("if: ${{ needs.stage-preflight.outputs.configured == 'true' }}", self.workflow)

    def test_materialized_approval_uses_a_unique_path_and_is_always_removed(self):
        approval_path = 't34-decoder-approvals-${{ github.run_id }}-${{ github.run_attempt }}.json'
        for name, following in (('stage-preflight', 'stage-test'), ('stage-test', None)):
            with self.subTest(job=name):
                block = self.job(name, following)
                self.assertEqual(block.count(approval_path), 3)
                self.assertEqual(block.count('Remove materialized decoder approval'), 1)
                self.assertEqual(block.count('rm -f -- "$T34_APPROVAL_FILE"'), 1)
        cleanup = 'Remove materialized decoder approval'
        self.assertEqual(self.workflow.count(cleanup), 2)
        self.assertEqual(self.workflow.count('rm -f -- "$T34_APPROVAL_FILE"'), 2)
        cleanup_blocks = re.findall(
            r'- name: Remove materialized decoder approval\n\s+if: always\(\)[\s\S]*?run: rm -f',
            self.workflow,
        )
        self.assertEqual(len(cleanup_blocks), 2)

    def test_staging_receives_explicit_protected_rollback_sha(self):
        for name, following in (('stage-preflight', 'stage-test'), ('stage-test', None)):
            with self.subTest(job=name):
                self.assertIn(
                    'T34_PREVIOUS_COMMIT: ${{ vars.T34_PREVIOUS_COMMIT }}',
                    self.job(name, following),
                )
        self.assertIn('缺少受保护的前版提交', self.workflow)
        self.assertNotIn('android-contract-package', self.workflow)

    def test_staging_has_no_remote_host_cloud_or_production_credentials(self):
        stage = self.job('stage-test')
        for forbidden in (
                'ssh ', 'aws ', 'gcloud ', 'az ', 'kubectl', 'helm ',
                'docker context use', 'T34_PRODUCTION', 'id-token:',
                'contents: write', 'packages: write', 'actions: write'):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, stage)
        self.assertIn('runs-on: ${{ vars.T34_STAGING_RUNNER_LABEL }}', stage)
        self.assertIn('T34_STAGING_STATE_VOLUME', stage)
        self.assertIn('隔离合成 staging', self.workflow)
        self.assertIn('不代表真实部署或生产签收', self.workflow)


if __name__ == '__main__':
    unittest.main()

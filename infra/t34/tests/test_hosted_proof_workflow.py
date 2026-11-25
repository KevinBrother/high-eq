"""Static safety contract for the independent, manual GitHub-hosted proof."""
import re
from pathlib import Path
import unittest

T34 = Path(__file__).resolve().parents[1]
ROOT = T34.parents[1]
WORKFLOW = ROOT / '.github/workflows/t34-isolated-proof.yml'
APPROVAL_SECRET = 'T34_DECODER_APPROVALS_JSON'


class HostedProofWorkflowContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = WORKFLOW.read_text()

    def test_trigger_is_manual_only(self):
        trigger = self.workflow.split('\npermissions:', 1)[0]
        self.assertIn('workflow_dispatch:', trigger)
        for automatic in ('push:', 'pull_request:', 'schedule:', 'workflow_run:'):
            with self.subTest(automatic=automatic):
                self.assertNotIn(automatic, trigger)

    def test_dispatch_is_bound_to_trusted_main_and_repository_owner(self):
        self.assertIn("github.event_name == 'workflow_dispatch'", self.workflow)
        self.assertIn("github.ref == 'refs/heads/main'", self.workflow)
        self.assertIn('github.actor == github.repository_owner', self.workflow)
        self.assertIn('runs-on: ubuntu-24.04', self.workflow)
        self.assertNotIn('self-hosted', self.workflow)
        self.assertNotIn('services:', self.workflow)

    def test_job_is_read_only_single_vm_and_cannot_be_cancelled_by_a_peer(self):
        self.assertIn('permissions:\n  contents: read', self.workflow)
        self.assertIn('timeout-minutes:', self.workflow)
        self.assertRegex(self.workflow, r'concurrency:\s*\n\s*group:\s*t34-isolated-hosted-proof')
        self.assertRegex(self.workflow, r'cancel-in-progress:\s*false')
        jobs = self.workflow.split('\njobs:', 1)[1]
        self.assertEqual(len(re.findall(r'^  [a-zA-Z0-9_-]+:\s*$', jobs, re.MULTILINE)), 1)

    def test_only_the_exact_approval_secret_enters_the_protected_environment(self):
        self.assertIn('environment: t34-synthetic-release', self.workflow)
        secrets = set(re.findall(r'secrets\.([A-Za-z0-9_]+)', self.workflow))
        self.assertEqual(secrets, {APPROVAL_SECRET})
        for forbidden in ('id-token:', 'packages: write', 'actions: write',
                          'contents: write', 'T34_STAGING_',
                          'AWS_ACCESS_KEY', 'GOOGLE_APPLICATION_CREDENTIALS',
                          'AZURE_CLIENT_ID', 'SSH_AUTH_SOCK'):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, self.workflow)

    def test_approval_is_materialized_before_the_engine_and_always_removed(self):
        materialized = self.workflow.index('materialize_decoder_approval.py')
        engine = self.workflow.index('infra/t34/ci/run_hosted_proof.sh')
        cleanup = self.workflow.index('Remove materialized decoder approval')
        self.assertLess(materialized, engine)
        self.assertLess(engine, cleanup)
        self.assertIn('t34-decoder-approvals-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}.json', self.workflow)
        self.assertIn('rm -f --', self.workflow)
        self.assertRegex(self.workflow, r'- name: Remove materialized decoder approval\n\s+if: always\(\)')

    def test_missing_approval_reports_the_proof_as_not_run(self):
        self.assertIn('configured=false', self.workflow)
        self.assertIn('未执行：受保护环境缺少', self.workflow)
        self.assertIn('不得将本结果记作发布通过', self.workflow)
        self.assertIn("if: ${{ steps.approval.outputs.configured == 'true' }}", self.workflow)

    def test_every_action_is_pinned_and_checkout_drops_credentials(self):
        actions = re.findall(r'uses:\s*([^\s#]+)', self.workflow)
        self.assertTrue(actions)
        for action in actions:
            with self.subTest(action=action):
                self.assertRegex(action, r'^[^@]+@[0-9a-f]{40}$')
        self.assertIn('persist-credentials: false', self.workflow)
        self.assertIn('fetch-depth: 0', self.workflow)

    def test_manual_entry_runs_the_independent_hosted_proof(self):
        self.assertIn('infra/t34/ci/run_hosted_proof.sh', self.workflow)
        for input_name in ('initial_revision', 'update_revision', 'previous_revision'):
            with self.subTest(input_name=input_name):
                self.assertIn(input_name + ':', self.workflow)
                self.assertIn('required: true', self.workflow)
        self.assertIn('actions/upload-artifact@', self.workflow)
        self.assertIn("if: always()", self.workflow)


if __name__ == '__main__':
    unittest.main()

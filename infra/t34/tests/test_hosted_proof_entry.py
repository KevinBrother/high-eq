"""Offline contracts for the hosted proof process coordinator."""
import io
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from ci import hosted_contract
from ci import hosted_entry as entry
from ci import hosted_engine
from ci import hosted_proof as proof
from approval_fixture import write_static_approval

T34 = Path(__file__).resolve().parents[1]
WORKFLOW = T34.parents[1] / '.github/workflows/t34-isolated-proof.yml'
ENTRY = T34 / 'ci/run_hosted_proof.sh'
COORDINATOR = T34 / 'ci/hosted_entry.py'


class HostedProofEntryContract(unittest.TestCase):
    def test_workflow_entry_exists_and_delegates_to_the_python_coordinator(self):
        self.assertTrue(ENTRY.is_file())
        self.assertTrue(ENTRY.stat().st_mode & 0o111)
        script = ENTRY.read_text()
        self.assertIn('set -euo pipefail', script)
        self.assertIn('ci.hosted_entry', script)
        self.assertIn('infra/t34/ci/run_hosted_proof.sh', WORKFLOW.read_text())
        self.assertTrue(COORDINATOR.is_file())

    def test_coordinator_exposes_an_offline_injectable_entrypoint(self):
        self.assertTrue(callable(getattr(entry, 'run_hosted_proof', None)))



def hosted_environ(output_dir: Path, *, initial: str = '1' * 40,
                   update: str = '2' * 40, previous: str = '3' * 40,
                   trusted: str = '4' * 40, approvals: Path) -> dict:
    return {
        'CI': 'true',
        'GITHUB_ACTIONS': 'true',
        'RUNNER_ENVIRONMENT': 'github-hosted',
        'GITHUB_EVENT_NAME': 'workflow_dispatch',
        'GITHUB_REF': 'refs/heads/main',
        'GITHUB_ACTOR': 'project-owner',
        'GITHUB_REPOSITORY_OWNER': 'project-owner',
        'GITHUB_SHA': trusted,
        'T34_TRUSTED_MAIN_SHA': trusted,
        'T34_PROOF_INITIAL_REVISION': initial,
        'T34_PROOF_UPDATE_REVISION': update,
        'T34_PROOF_PREVIOUS_REVISION': previous,
        'T34_PROOF_WAIT_SECONDS': '600',
        'T34_PROOF_OUTPUT_DIR': str(output_dir),
        'T34_DECODER_APPROVALS': str(approvals),
        'GITHUB_TOKEN': 'must-not-reach-worker',
        'ACTIONS_RUNTIME_TOKEN': 'must-not-reach-worker',
        'AWS_SECRET_ACCESS_KEY': 'must-not-reach-worker',
        'SSH_AUTH_SOCK': '/private/agent.sock',
        'DOCKER_HOST': 'unix:///var/run/docker.sock',
    }


class FakeEngine:
    def __init__(self, paths):
        self.paths = paths
        self.engine_id = 'a' * 64
        self.server_version = '27.1.1'
        self.stopped = False

    def assert_alive(self):
        if self.stopped:
            raise proof.ProofError('private rootless engine exited unexpectedly')

    def stop(self):
        self.stopped = True
        return True


class WorkerRecorder:
    def __init__(self, *, fail_stage=None, mutate=None, pids=None):
        self.fail_stage = fail_stage
        self.mutate = mutate
        self.pids = tuple(pids or (4101, 4102, 4103))
        self.calls = []

    @staticmethod
    def volumes(env):
        prefix = 't34-proof-' + env['T34_PROOF_RUN_ID'] + '_'
        return sorted(prefix + suffix for suffix in (
            'approval', 'business', 'deletions', 'quarantine', 'state', 'vault'))

    def __call__(self, command, receipt_path, *, log_prefix, timeout, env):
        stage = command[2]
        call_number = len(self.calls) + 1
        pid = self.pids[call_number - 1]
        self.calls.append({
            'stage': stage,
            'pid': pid,
            'command': list(command),
            'receipt': Path(receipt_path),
            'log_prefix': Path(log_prefix),
            'timeout': timeout,
            'env': dict(env),
            'work_mode': stat.S_IMODE(Path(env['T34_PROOF_WORK_DIR']).stat().st_mode),
            'home_mode': stat.S_IMODE(Path(env['HOME']).stat().st_mode),
            'tmp_mode': stat.S_IMODE(Path(env['TMPDIR']).stat().st_mode),
            'docker_config_mode': stat.S_IMODE(Path(env['DOCKER_CONFIG']).stat().st_mode),
            'receipt_parent': str(Path(receipt_path).parent),
        })
        if stage == self.fail_stage:
            raise proof.WorkerFailure(
                'proof worker failed', returncode=9, pid=9000 + call_number,
                stdout_log=Path(str(log_prefix) + '.stdout.log'),
                stderr_log=Path(str(log_prefix) + '.stderr.log'),
            )
        running = (hosted_contract.STORAGE_SERVICES if stage == 'negative'
                   else hosted_contract.SERVICE_NAMES)
        receipt = {
            'phase': stage,
            'pid': pid,
            'result': 'pass',
            'revision': (env['T34_PROOF_INITIAL_REVISION'] if stage == 'init'
                         else env['T34_PROOF_UPDATE_REVISION']),
            'schema_digest': 'd' * 64,
            'services': {
                service: service in running
                for service in sorted(hosted_contract.SERVICE_NAMES)
            },
            'storage': {
                'volumes': len(self.volumes(env)),
                'vault_snapshots': 1 if stage == 'init' else 2,
                'ledger_roots': 6,
                'verified': True,
                'retained': stage != 'init',
            },
        }
        if self.mutate is not None:
            self.mutate(receipt, stage)
        proof.write_private_json(Path(receipt_path), receipt)
        return proof.WorkerResult(
            pid=pid, returncode=0, elapsed_seconds=0.5,
            receipt=receipt, stdout_log=Path(str(log_prefix) + '.stdout.log'),
            stderr_log=Path(str(log_prefix) + '.stderr.log'),
        )

def snapshot(volumes=(), running=0, stopped=0) -> dict:
    return {'volumes': list(volumes),
            'containers': {'running': running, 'stopped': stopped}}


class HostedProofCoordinatorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='t34-entry-', dir='/tmp')
        self.root = Path(self.temporary.name).resolve()
        self.output = self.root / 'artifact'
        self.runtime = self.root / 'runtime'
        self.runtime.mkdir(mode=0o700)
        self.stage_script = self.root / 'hosted_stage.py'
        self.stage_script.write_text('# test stub invoked through an injected worker\n')
        self.approval = write_static_approval(self.root / 'approvals.json')

    def tearDown(self):
        self.temporary.cleanup()

    def run_proof(self, *, environ=None, worker=None, engine_starter=None,
                  engine_probe=None, inventory_probe=None, wait=None,
                  git_verifier=None):
        worker = worker or WorkerRecorder()
        engine_holder = []
        seen_inventory = []

        def default_engine_starter(paths, *, environ):
            engine = FakeEngine(paths)
            engine_holder.append(engine)
            return engine

        def recording_engine_starter(starter, holder):
            def start(paths, *, environ):
                engine = starter(paths, environ=environ)
                holder.append(engine)
                return engine
            return start

        def default_engine_probe(paths, environ):
            return {'engine_id': 'a' * 64, 'server_version': '27.1.1',
                    'rootless': True}

        def default_inventory_probe(host, environ):
            values = (
                snapshot(),
                snapshot(WorkerRecorder.volumes(environ), running=11),
                snapshot(WorkerRecorder.volumes(environ), running=11),
                snapshot(WorkerRecorder.volumes(environ), running=11),
                snapshot(WorkerRecorder.volumes(environ), running=5, stopped=6),
            )
            value = values[len(seen_inventory)]
            seen_inventory.append((host, dict(environ), value))
            return value

        outcome = entry.run_hosted_proof(
            environ or hosted_environ(self.output, approvals=self.approval),
            work_parent=self.runtime,
            stage_script=self.stage_script,
            git_verifier=git_verifier or (lambda config, environ: None),
            engine_starter=recording_engine_starter(
                engine_starter or default_engine_starter, engine_holder),
            engine_probe=engine_probe or default_engine_probe,
            inventory_probe=inventory_probe or default_inventory_probe,
            wait=wait or (lambda seconds: {'requested_seconds': seconds,
                                           'elapsed_seconds': float(seconds)}),
            worker_runner=worker,
        )
        return outcome, worker, engine_holder, seen_inventory

    def test_pass_runs_init_wait_update_negative_and_exports_only_public_evidence(self):
        outcome, worker, engines, inventories = self.run_proof()
        self.assertEqual(outcome.exit_code, 0)
        self.assertEqual([call['stage'] for call in worker.calls],
                         ['init', 'update', 'negative'])
        self.assertEqual(len(inventories), 5)
        self.assertTrue(engines and engines[0].stopped)
        for call in worker.calls:
            self.assertEqual(call['work_mode'], 0o700)
            self.assertEqual(call['home_mode'], 0o700)
            self.assertEqual(call['tmp_mode'], 0o700)
            self.assertEqual(call['docker_config_mode'], 0o700)
            self.assertTrue(call['receipt'].is_relative_to(
                Path(call['env']['T34_PROOF_WORK_DIR'])))
            self.assertTrue(call['env']['DOCKER_HOST'].startswith('unix://'))
            self.assertTrue(Path(call['env']['DOCKER_HOST'][7:]).is_relative_to(
                Path(call['env']['T34_PROOF_WORK_DIR'])))
            self.assertNotEqual(call['env']['DOCKER_HOST'], 'unix:///var/run/docker.sock')
            self.assertEqual(call['env']['T34_PROOF_RUN_ID'],
                             worker.calls[0]['env']['T34_PROOF_RUN_ID'])
            self.assertEqual(call['env']['CI'], 'true')
            self.assertEqual(call['env']['GITHUB_ACTIONS'], 'true')
            self.assertEqual(call['env']['RUNNER_ENVIRONMENT'], 'github-hosted')
            self.assertEqual(call['env']['GITHUB_EVENT_NAME'], 'workflow_dispatch')
            self.assertEqual(call['env']['GITHUB_REF'], 'refs/heads/main')
            self.assertEqual(call['env']['GITHUB_ACTOR'], 'project-owner')
            self.assertEqual(call['env']['GITHUB_REPOSITORY_OWNER'], 'project-owner')
            self.assertEqual(call['env']['GITHUB_SHA'],
                             call['env']['T34_TRUSTED_MAIN_SHA'])
            for forbidden in ('GITHUB_TOKEN', 'ACTIONS_RUNTIME_TOKEN',
                              'AWS_SECRET_ACCESS_KEY', 'SSH_AUTH_SOCK',
                              'T34_PROOF_OUTPUT_DIR'):
                self.assertNotIn(forbidden, call['env'])
            self.assertFalse(any(name.startswith('T34_STAGING_')
                                 for name in call['env']))
            self.assertNotEqual(call['env']['DOCKER_HOST'],
                                'unix:///var/run/docker.sock')
            for key in call['env']:
                lowered = key.lower()
                for marker in ('token', 'secret', 'password', 'credential'):
                    self.assertNotIn(marker, lowered)

        receipt = json.loads((self.output / 'proof.json').read_text())
        self.assertEqual(receipt['result'], 'proof-pass')
        self.assertEqual(receipt['mode'], 'github-hosted-isolated')
        self.assertIs(receipt['non_production'], True)
        self.assertEqual(receipt['processes']['stages_completed'], 3)
        self.assertEqual(receipt['wait']['requested_seconds'], 600)
        self.assertEqual(receipt['storage']['initial_volumes'], 6)
        self.assertEqual(receipt['storage']['retained_volumes'], 6)
        self.assertIs(receipt['storage']['original_volumes_retained'], True)
        self.assertEqual(receipt['services']['init_running'], 11)
        self.assertEqual(receipt['services']['update_running'], 11)
        self.assertEqual(receipt['services']['negative_stopped'], 6)
        self.assertIs(receipt['cleanup']['engine_stopped'], True)
        self.assertIs(receipt['cleanup']['private_work_removed'], True)
        self.assertEqual(stat.S_IMODE((self.output / 'proof.json').stat().st_mode), 0o600)
        self.assertEqual([path.name for path in self.output.iterdir()], ['proof.json'])

        run_id = worker.calls[0]['env']['T34_PROOF_RUN_ID']
        engine_id = engines[0].engine_id
        work_dir = worker.calls[0]['env']['T34_PROOF_WORK_DIR']
        socket_path = worker.calls[0]['env']['DOCKER_HOST'][7:]
        forbidden_values = (run_id, engine_id, work_dir, socket_path,
                            *WorkerRecorder.volumes(worker.calls[0]['env']))
        proof.enforce_public_receipt(receipt, forbidden_values=forbidden_values)
        rendered = json.dumps(receipt, sort_keys=True)
        for value in forbidden_values:
            self.assertNotIn(value, rendered)

    def test_worker_environment_passes_the_real_child_cli_authorization(self):
        _, worker, _, _ = self.run_proof()
        from ci import hosted_stage
        env = worker.calls[0]['env']
        old_umask = os.umask(0o022)
        try:
            with patch.dict(os.environ, env, clear=True), \
                    patch.object(hosted_stage, 'execute') as execute, \
                    patch.object(hosted_stage.os, 'uname',
                                 return_value=SimpleNamespace(sysname='Linux')), \
                    patch.object(hosted_stage.os, 'geteuid', return_value=1000):
                self.assertEqual(hosted_stage.main([
                    'init', '--receipt', str(Path(env['T34_PROOF_WORK_DIR']) / 'auth.json'),
                ]), 0)
        finally:
            os.umask(old_umask)
        execute.assert_called_once()

    def test_private_receipt_pid_mismatch_fails_closed_after_the_real_worker_call(self):
        def mutate(receipt, stage):
            if stage == 'update':
                receipt['pid'] = 9999

        outcome, worker, engines, _ = self.run_proof(
            worker=WorkerRecorder(mutate=mutate))
        self.assertEqual(outcome.exit_code, 1)
        self.assertEqual([call['stage'] for call in worker.calls], ['init', 'update'])
        self.assertTrue(engines[0].stopped)
        receipt = json.loads((self.output / 'proof.json').read_text())
        self.assertEqual(receipt['stage'], 'update')
        self.assertEqual(receipt['error'], 'receipt-validation-failed')
        self.assertEqual(receipt['processes']['stages_completed'], 1)
        self.assertEqual(receipt['cleanup'],
                         {'engine_stopped': True, 'private_work_removed': True})

    def test_parent_inventory_must_match_the_private_service_evidence(self):
        seen = []

        def inventory(host, environ):
            values = (
                snapshot(),
                snapshot(WorkerRecorder.volumes(environ), running=9),
            )
            value = values[len(seen)]
            seen.append(value)
            return value

        outcome, worker, _, _ = self.run_proof(worker=WorkerRecorder(),
                                                inventory_probe=inventory)
        self.assertEqual(outcome.exit_code, 1)
        self.assertEqual([call['stage'] for call in worker.calls], ['init'])
        receipt = json.loads((self.output / 'proof.json').read_text())
        self.assertEqual(receipt['stage'], 'init')
        self.assertEqual(receipt['error'], 'inventory-invalid')

    def test_cleanup_failure_is_attributed_without_exposing_private_paths(self):
        class BrokenCleanupEngine(FakeEngine):
            def stop(self):
                self.stopped = True
                return False

        def start(paths, *, environ):
            return BrokenCleanupEngine(paths)

        outcome, worker, engines, _ = self.run_proof(engine_starter=start)
        self.assertEqual(outcome.exit_code, 1)
        self.assertEqual([call['stage'] for call in worker.calls],
                         ['init', 'update', 'negative'])
        self.assertTrue(engines[0].stopped)
        receipt = json.loads((self.output / 'proof.json').read_text())
        self.assertEqual(receipt['stage'], 'cleanup')
        self.assertEqual(receipt['error'], 'cleanup-failed')
        self.assertEqual(receipt['cleanup'],
                         {'engine_stopped': False, 'private_work_removed': False})
        rendered = json.dumps(receipt, sort_keys=True)
        for value in (worker.calls[0]['env']['T34_PROOF_WORK_DIR'],
                      worker.calls[0]['env']['DOCKER_HOST'][7:]):
            self.assertNotIn(value, rendered)

    def test_cleanup_failure_does_not_replace_the_original_stage_failure(self):
        class BrokenCleanupEngine(FakeEngine):
            def stop(self):
                self.stopped = True
                return False

        def start(paths, *, environ):
            return BrokenCleanupEngine(paths)

        outcome, worker, _, _ = self.run_proof(
            worker=WorkerRecorder(fail_stage='update'), engine_starter=start)
        self.assertEqual(outcome.exit_code, 1)
        receipt = json.loads((self.output / 'proof.json').read_text())
        self.assertEqual(receipt['stage'], 'update')
        self.assertEqual(receipt['error'], 'stage-failed')
        self.assertEqual(receipt['cleanup'],
                         {'engine_stopped': False, 'private_work_removed': False})

    def test_fallback_receipt_and_exit_code_use_the_same_written_result(self):
        with patch.object(entry, '_validate_public_receipt',
                          side_effect=[proof.ProofError('invalid pass receipt'), None]):
            outcome, _, _, _ = self.run_proof()
        self.assertEqual(outcome.exit_code, 1)
        receipt = json.loads((self.output / 'proof.json').read_text())
        self.assertEqual(receipt['result'], 'proof-fail')
        self.assertEqual(receipt['stage'], 'preflight')
        self.assertEqual(receipt['error'], 'receipt-validation-failed')

    def test_stage_failure_stops_later_stages_and_keeps_sanitized_failure_receipt(self):
        worker = WorkerRecorder(fail_stage='update')
        outcome, worker, engines, _ = self.run_proof(worker=worker)
        self.assertEqual(outcome.exit_code, 1)
        self.assertEqual([call['stage'] for call in worker.calls], ['init', 'update'])
        self.assertTrue(engines[0].stopped)
        receipt = json.loads((self.output / 'proof.json').read_text())
        self.assertEqual(receipt['result'], 'proof-fail')
        self.assertEqual(receipt['stage'], 'update')
        self.assertEqual(receipt['error'], 'stage-failed')
        self.assertEqual(receipt['processes']['stages_completed'], 1)
        rendered = json.dumps(receipt, sort_keys=True)
        for value in (worker.calls[0]['env']['T34_PROOF_WORK_DIR'],
                      worker.calls[0]['env']['DOCKER_HOST'][7:]):
            self.assertNotIn(value, rendered)

    def test_missing_rootless_prerequisites_are_reported_as_not_executed(self):
        worker = WorkerRecorder()

        def unavailable(paths, *, environ):
            raise hosted_engine.PrerequisiteUnavailable('rootless prerequisites unavailable')

        outcome, worker, engines, inventories = self.run_proof(
            worker=worker, engine_starter=unavailable)
        self.assertEqual(outcome.exit_code, 1)
        self.assertEqual(worker.calls, [])
        self.assertEqual(inventories, [])
        receipt = json.loads((self.output / 'proof.json').read_text())
        self.assertEqual(receipt['result'], 'not-executed')
        self.assertEqual(receipt['stage'], 'preflight')
        self.assertEqual(receipt['error'], 'rootless-prerequisites-unavailable')
        self.assertEqual(receipt['verification']['engine'], 'not-started')
        self.assertEqual(receipt['processes']['stages_completed'], 0)

    def test_invalid_inputs_fail_before_git_or_engine_access(self):
        git_calls = []
        outcome, worker, engines, inventories = self.run_proof(
            environ=hosted_environ(self.output, update='1' * 40, approvals=self.approval),
            git_verifier=lambda config, environ: git_calls.append(config),
        )
        self.assertEqual(outcome.exit_code, 1)
        self.assertEqual(git_calls, [])
        self.assertEqual(worker.calls, [])
        self.assertEqual(engines, [])
        self.assertEqual(inventories, [])
        receipt = json.loads((self.output / 'proof.json').read_text())
        self.assertEqual(receipt['result'], 'proof-fail')
        self.assertEqual(receipt['stage'], 'preflight')
        self.assertEqual(receipt['error'], 'invalid-input')

    def test_original_volume_loss_fails_before_negative_probe(self):
        worker = WorkerRecorder()
        seen = 0

        def inventory(host, environ):
            nonlocal seen
            volumes = WorkerRecorder.volumes(environ)
            values = (
                snapshot(),
                snapshot(volumes, running=11),
                snapshot(volumes, running=11),
                snapshot(('different-state',), running=11),
            )
            value = values[seen]
            seen += 1
            return value

        outcome, worker, engines, _ = self.run_proof(
            worker=worker, inventory_probe=inventory)
        self.assertEqual(outcome.exit_code, 1)
        self.assertEqual([call['stage'] for call in worker.calls], ['init', 'update'])
        self.assertTrue(engines[0].stopped)
        receipt = json.loads((self.output / 'proof.json').read_text())
        self.assertEqual(receipt['stage'], 'update')
        self.assertEqual(receipt['error'], 'resource-retention-failed')
        self.assertIs(receipt['storage']['original_volumes_retained'], False)

    def test_engine_identity_change_fails_closed_after_the_first_stage(self):
        worker = WorkerRecorder()
        probes = iter((
            {'engine_id': 'a' * 64, 'server_version': '27.1.1', 'rootless': True},
            {'engine_id': 'b' * 64, 'server_version': '27.1.1', 'rootless': True},
        ))

        def probe(paths, environ):
            return next(probes)

        outcome, worker, engines, _ = self.run_proof(
            worker=worker, engine_probe=probe)
        self.assertEqual(outcome.exit_code, 1)
        self.assertEqual([call['stage'] for call in worker.calls], ['init'])
        self.assertTrue(engines[0].stopped)
        receipt = json.loads((self.output / 'proof.json').read_text())
        self.assertEqual(receipt['stage'], 'init')
        self.assertEqual(receipt['error'], 'engine-identity-changed')


if __name__ == '__main__':
    unittest.main()

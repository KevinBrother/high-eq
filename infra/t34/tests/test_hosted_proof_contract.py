"""Offline behavior tests for the independent GitHub-hosted proof boundary."""
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from ci import hosted_proof as proof


BASE_CONTEXT = {
    'CI': 'true',
    'GITHUB_ACTIONS': 'true',
    'RUNNER_ENVIRONMENT': 'github-hosted',
    'GITHUB_EVENT_NAME': 'workflow_dispatch',
    'GITHUB_REF': 'refs/heads/main',
    'GITHUB_ACTOR': 'project-owner',
    'GITHUB_REPOSITORY_OWNER': 'project-owner',
}


class DispatchTests(unittest.TestCase):
    def test_accepts_only_owner_manual_dispatch_on_trusted_main(self):
        self.assertEqual(proof.authorize_dispatch(BASE_CONTEXT)['actor'], 'project-owner')
        mutations = {
            'CI': 'false',
            'GITHUB_ACTIONS': 'false',
            'RUNNER_ENVIRONMENT': 'self-hosted',
            'GITHUB_EVENT_NAME': 'push',
            'GITHUB_REF': 'refs/heads/feature',
            'GITHUB_ACTOR': 'another-user',
        }
        for key, value in mutations.items():
            with self.subTest(key=key):
                context = dict(BASE_CONTEXT)
                context[key] = value
                with self.assertRaises(proof.ProofError):
                    proof.authorize_dispatch(context)

    def test_wait_must_be_real_and_at_least_ten_minutes(self):
        self.assertEqual(proof.validate_wait_seconds('600'), 600)
        for bad in ('', '599', '0', '-1', '1.5', '600s', '7201'):
            with self.subTest(bad=bad), self.assertRaises(proof.ProofError):
                proof.validate_wait_seconds(bad)

        sleeps = []
        ticks = iter((100.0, 700.0))
        evidence = proof.real_wait(600, sleep=sleeps.append, monotonic=lambda: next(ticks))
        self.assertEqual(sleeps, [600])
        self.assertEqual(evidence['requested_seconds'], 600)
        self.assertEqual(evidence['elapsed_seconds'], 600)

    def test_real_wait_rejects_an_untrustworthy_clock_that_did_not_elapse(self):
        with self.assertRaises(proof.ProofError):
            proof.real_wait(600, sleep=lambda _: None, monotonic=iter((1.0, 2.0)).__next__)


class HostPreflightTests(unittest.TestCase):
    def test_socket_must_be_absolute_run_owned_unix_path(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            good = root / 'run' / 'docker.sock'
            self.assertEqual(proof.validate_engine_socket('unix://' + str(good), root), good)
            for bad in ('tcp://127.0.0.1:2375', 'unix://relative.sock',
                        'unix:///var/run/docker.sock', 'unix://' + str(root.parent / 'outside.sock')):
                with self.subTest(bad=bad), self.assertRaises(proof.ProofError):
                    proof.validate_engine_socket(bad, root)
            linked = root / 'linked'
            linked.symlink_to(root, target_is_directory=True)
            with self.assertRaises(proof.ProofError):
                proof.validate_engine_socket('unix://' + str(linked / 'docker.sock'), root)

    def test_subid_ranges_require_an_unprivileged_user_with_enough_ids(self):
        text = 'runner:100000:65536\nother:200000:65536\n'
        self.assertEqual(proof.validate_subid_ranges(text, 'runner', 1001), 65536)
        self.assertEqual(proof.validate_subid_ranges(
            '1001:100000:65536\n', 'runner', 1001), 65536)
        for malformed in ('', 'runner:100000:65535\n', 'garbage\n',
                          'runner:not-a-number:65536\n', 'runner:100000\n'):
            with self.subTest(malformed=malformed), self.assertRaises(proof.ProofError):
                proof.validate_subid_ranges(malformed, 'runner', 1001)

    def test_disk_margin_fails_closed(self):
        minimum = 10 * 1024 ** 3
        self.assertEqual(proof.require_free_bytes(minimum, minimum), minimum)
        with self.assertRaises(proof.ProofError):
            proof.require_free_bytes(minimum - 1, minimum)


class PrivateReceiptTests(unittest.TestCase):
    def test_private_json_round_trip_is_owner_only_and_atomic(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'job.json'
            proof.write_private_json(path, {'phase': 'init', 'owner_token': 'a' * 48})
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(proof.load_private_json(path)['phase'], 'init')

    def test_public_receipt_rejects_credentials_tokens_and_unknown_fields(self):
        proof.enforce_public_receipt({
            'version': 1,
            'result': 'proof-pass',
            'mode': 'github-hosted-isolated',
            'non_production': True,
            'engine': {'engine_id': 'e' * 64, 'rootless': True},
        }, forbidden_values=('a' * 48,))
        for receipt in (
                {'owner_token': 'a' * 48},
                {'engine': {'challenge': 'a' * 48}},
                {'engine': {'value': 'prefix-' + 'a' * 48}},
                {'unknown': True}):
            with self.subTest(receipt=receipt), self.assertRaises(proof.ProofError):
                proof.enforce_public_receipt(receipt, forbidden_values=('a' * 48,))


class WorkerProcessTests(unittest.TestCase):
    def test_worker_is_a_real_separate_process_and_returns_its_pid(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            stub = folder / 'stub.py'
            receipt = folder / 'receipt.json'
            stub.write_text(
                'import json, os, sys\n'
                'os.umask(0o077)\n'
                'with open(sys.argv[1], "w") as output:\n'
                '    output.write(json.dumps({"phase": "init", "pid": os.getpid()}))\n'
            )
            result = proof.run_worker_process(
                [sys.executable, str(stub), str(receipt)], receipt,
                log_prefix=folder / 'init', timeout=10,
            )
            self.assertNotEqual(result.pid, os.getpid())
            self.assertEqual(result.receipt['pid'], result.pid)
            self.assertEqual(result.returncode, 0)

    def test_worker_failure_is_nonzero_and_does_not_echo_child_output(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            secret = 'sensitive-child-output'
            stub = folder / 'stub.py'
            receipt = folder / 'receipt.json'
            stub.write_text(
                'import sys\n'
                'print("' + secret + '", file=sys.stderr)\n'
                'raise SystemExit(17)\n'
            )
            with self.assertRaises(proof.WorkerFailure) as raised:
                proof.run_worker_process(
                    [sys.executable, str(stub), str(receipt)], receipt,
                    log_prefix=folder / 'init', timeout=10,
                )
            self.assertEqual(raised.exception.returncode, 17)
            self.assertNotIn(secret, str(raised.exception))
            self.assertTrue((folder / 'init.stderr.log').exists())

    def test_worker_timeout_fails_closed(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            stub = folder / 'stub.py'
            receipt = folder / 'receipt.json'
            stub.write_text('import time\ntime.sleep(30)\n')
            with self.assertRaises(proof.WorkerFailure):
                proof.run_worker_process(
                    [sys.executable, str(stub), str(receipt)], receipt,
                    log_prefix=folder / 'init', timeout=0.2,
                )


if __name__ == '__main__':
    unittest.main()

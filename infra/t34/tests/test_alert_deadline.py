import contextlib
import copy
import io
import json
import subprocess
import sys
import unittest
from types import SimpleNamespace
from unittest import mock

from test_staging import API_A, API_B, WEB_B, T34, composition_for, release, staging, state
from lab import Lab


class AlertDeadlineRegression(unittest.TestCase):
    def exercise_update(self, count_response):
        old_state = state()
        saved_state = copy.deepcopy(old_state)
        subject = object.__new__(Lab)
        subject.name = old_state['installation']
        subject.env = {'ALERT_WEBHOOK': release.ALERT_WEBHOOK}
        subject.docker = 'fake-docker'
        subject.source = T34
        subject.build = mock.Mock(side_effect=[API_A, API_B, WEB_B])
        subject.gate_exit = mock.Mock(return_value=0)
        subject.open_release = mock.Mock()
        consumers = {'monitor', 'backup', 'alert-sink'}
        running = {'ledger', 'restored', 'coldcache'}
        stopped = set()
        count_timeouts = []
        sleeps = []
        clock = 0.0

        def now():
            return clock

        def sleep(seconds):
            nonlocal clock
            sleeps.append(seconds)
            clock += seconds

        def docker(cmd, **kwargs):
            nonlocal clock
            args = cmd[1:]
            self.assertEqual(cmd[0], 'fake-docker')
            data = b''
            if args[0] == 'compose':
                self.assertEqual(args[args.index('-p') + 1], subject.name)
                if 'up' in args:
                    running.update(consumers.intersection(args))
                elif args[-3:] == ['alert-sink', '/sink', 'count']:
                    self.assertTrue(consumers.issubset(running))
                    count_timeouts.append(kwargs.get('timeout'))
                    data, elapsed = count_response(len(count_timeouts) - 1, kwargs.get('timeout'))
                    clock += elapsed
                elif args[-3:] == ['monitor', '/ops/ops.sh', 'monitor-once']:
                    data = b'ai_cost=normal sink=webhook\n'
                elif args[-3:] == ['monitor', '/ops/ops.sh', 'monitor-probe']:
                    pass
                elif args[-3:] == ['port', 'web', '8080']:
                    data = b'127.0.0.1:41001\n'  # Reached only by a release that opened.
                else:
                    self.fail(f'unexpected Compose command: {args}')
            elif args[0] == 'ps':
                self.assertIn('--filter=label=com.docker.compose.project=' + subject.name, args)
                data = '\n'.join(f'{service}-id {service}' for service in sorted(running)).encode()
            elif args[:3] == ['stop', '--time', '5']:
                for container in args[3:]:
                    service = container.removesuffix('-id')
                    self.assertIn(service, consumers, 'storage must not be stopped')
                    stopped.add(service)
                    running.remove(service)
            else:
                self.fail(f'unexpected Docker command: {args}')
            return subprocess.CompletedProcess(cmd, 0, stdout=data, stderr=b'')

        output, error = io.StringIO(), io.StringIO()
        failure = None
        with mock.patch('lab.sp.run', side_effect=docker), \
                mock.patch('lab._run_timed_compose', side_effect=docker), \
                mock.patch('time.monotonic', side_effect=now), \
                mock.patch('time.sleep', side_effect=sleep), \
                mock.patch.object(staging, 'verify_storage'), \
                mock.patch.object(staging, 'write_state') as write_state, \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(error):
            try:
                release.update_release(subject, SimpleNamespace(
                    revision='must-not-deploy', previous=old_state['release']['revision']),
                                       old_state, 't34-state', composition_for(old_state['release']),
                                       old_state['schema_digest'],
                                       old_state['schema_version'])
            except ValueError as exc:
                failure = exc

        subject.open_release.assert_not_called()
        write_state.assert_not_called()
        self.assertEqual(saved_state, old_state)
        self.assertNotIn('synthetic-pass', output.getvalue())
        self.assertEqual(stopped, consumers)
        self.assertEqual(running, {'ledger', 'restored', 'coldcache'})
        receipt = json.loads(error.getvalue())
        self.assertEqual(receipt['result'], 'synthetic-failed')
        self.assertIs(receipt['serving_fenced'], True)
        self.assertIsNotNone(failure)
        return failure, count_timeouts, sleeps, clock

    def test_rejects_a_successful_count_arriving_after_10_point_23_seconds(self):
        # After the 2s first poll and 1s sleep, the next exec has only 7s left.
        # Model the process boundary racing the timeout and returning a late 1.
        responses = [(b'0\n', 0), (b'0\n', 2), (b'1\n', 7.23)]
        failure, timeouts, sleeps, elapsed = self.exercise_update(lambda index, _: responses[index])
        self.assertIn('did not receive expected alerts', str(failure))
        self.assertGreater(timeouts[0], 0)
        self.assertEqual(timeouts[1:], [10, 7])
        self.assertEqual(sleeps, [1])
        self.assertAlmostEqual(elapsed, 10.23)

    def test_stuck_initial_or_polled_count_process_times_out_and_fences(self):
        actual_run = subprocess.run
        for stuck_at in (0, 1):
            with self.subTest(stuck_at=stuck_at):
                killed = []

                def count_response(index, timeout):
                    if index == stuck_at and timeout is not None:
                        # Exercise a genuinely unresponsive local process with
                        # compressed wall time. No Docker command is executed.
                        try:
                            actual_run([sys.executable, '-I', '-c', 'import time; time.sleep(60)'],
                                       timeout=min(timeout, 0.05), capture_output=True)
                        except subprocess.TimeoutExpired:
                            killed.append(index)
                            raise
                    # Test-side watchdog for the old unbounded exec: it would
                    # never kill the child, so don't launch the sleeper there.
                    return (b'0\n' if index == 0 else b'1\n', 0)

                failure, timeouts, sleeps, _ = self.exercise_update(count_response)
                self.assertIn('count timed out', str(failure))
                self.assertEqual(killed, [stuck_at])
                self.assertGreater(timeouts[0], 0)
                self.assertEqual(timeouts[1:], [10] if stuck_at else [])
                self.assertEqual(sleeps, [])

    def test_does_not_poll_or_sleep_past_the_remaining_budget(self):
        responses = [(b'0\n', 0), (b'0\n', 9.75)]
        _, timeouts, sleeps, elapsed = self.exercise_update(lambda index, _: responses[index])
        self.assertEqual(timeouts[1:], [10])
        self.assertEqual(sleeps, [0.25])
        self.assertEqual(elapsed, 10)

import contextlib
import errno
import copy
import io
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest import mock

from test_staging import API_A, API_B, WEB_B, T34, composition_for, release, staging, state
from lab import Lab


PLUGIN = r'''
import json
import os
from pathlib import Path
import sys
import time

args = sys.argv[1:]
if args == ['docker-cli-plugin-metadata']:
    print(json.dumps({'SchemaVersion': '0.1.0', 'Vendor': 'T34 offline', 'Version': 'v0.0.0',
                      'ShortDescription': 'offline Compose test double'}))
    sys.exit(0)

folder = Path(os.environ['T34_PLUGIN_TEST'])
if args[-1] == 't34-stdio':
    sys.stdout.buffer.write(sys.stdin.buffer.read())
    sys.stderr.write('plugin stderr\n')
    sys.exit(7)
if 'up' in args:
    services = folder / 'running.json'
    running = set(json.loads(services.read_text()))
    running.update({'monitor', 'backup', 'alert-sink'}.intersection(args))
    services.write_text(json.dumps(sorted(running)))
    sys.exit(0)
if args[-3:] == ['monitor', '/ops/ops.sh', 'monitor-once']:
    print('ai_cost=normal sink=webhook')
    sys.exit(0)
if args[-3:] == ['alert-sink', '/sink', 'count']:
    (folder / 'pids.json').write_text(json.dumps({'cli': os.getppid(), 'plugin': os.getpid(),
                                                 'group': os.getpgrp()}))
    deadline = time.monotonic() + 8
    while not (folder / 'stop-plugin').exists() and time.monotonic() < deadline:
        with (folder / 'heartbeat').open('a') as heartbeat:
            heartbeat.write(str(os.getppid()) + '\n')
        time.sleep(0.025)
    sys.exit(9)
sys.exit(64)
'''


class ComposeProcessGroupRegression(unittest.TestCase):
    def test_process_group_that_already_exited_does_not_mask_timeout_or_skip_wait(self):
        subject = object.__new__(Lab)
        subject.env, subject.docker, subject.source, subject.name = {}, 'fake-docker', T34, 't34-test'
        process = mock.MagicMock(pid=4242)
        process.__enter__.return_value = process
        process.communicate.side_effect = subprocess.TimeoutExpired(['fake-docker', 'compose'], 0.7)
        with mock.patch('lab.sp.Popen', return_value=process) as popen, \
                mock.patch('lab.os.killpg', side_effect=ProcessLookupError(errno.ESRCH, 'group gone')) as killpg:
            with self.assertRaisesRegex(ValueError, 'local alert sink count timed out'):
                subject.alert_count(timeout=0.7)
        killpg.assert_called_once_with(4242, signal.SIGKILL)
        process.wait.assert_called_once_with()
        self.assertIs(popen.call_args.kwargs['start_new_session'], True)

    def test_timeout_reaps_cli_and_stops_plugin_before_fencing_update(self):
        docker = shutil.which('docker')
        self.assertIsNotNone(docker, 'this regression needs the Docker CLI, not a daemon')
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            config = folder / 'config'
            plugins = config / 'cli-plugins'
            plugins.mkdir(parents=True)
            plugin_script = folder / 'plugin.py'
            plugin_script.write_text(PLUGIN)
            launcher = plugins / 'docker-compose'
            launcher.write_text('#!/bin/sh\nexec "$T34_TEST_PYTHON" -I "$T34_PLUGIN_SCRIPT" "$@"\n')
            launcher.chmod(0o700)
            storage = {'db', 'cache', 'ledger', 'restored', 'coldcache'}
            consumers = {'monitor', 'backup', 'alert-sink'}
            running = folder / 'running.json'
            running.write_text(json.dumps(sorted(storage)))
            stopped = set()
            old_state = state()
            original_state = copy.deepcopy(old_state)
            subject = object.__new__(Lab)
            subject.source, subject.name, subject.docker = T34, old_state['installation'], docker
            subject.env = {
                'PATH': os.environ['PATH'], 'HOME': tmp, 'DOCKER_CONFIG': str(config),
                'DOCKER_HOST': 'unix://' + str(folder / 'absent.sock'),
                'COMPOSE_DISABLE_ENV_FILE': '1', 'T34_PLUGIN_TEST': tmp,
                'T34_TEST_PYTHON': sys.executable, 'T34_PLUGIN_SCRIPT': str(plugin_script),
                'ALERT_WEBHOOK': release.ALERT_WEBHOOK,
            }
            subject.build = mock.Mock(side_effect=[API_A, API_B, WEB_B])
            subject.gate_exit = mock.Mock(return_value=0)
            subject.open_release = mock.Mock()
            real_run = subject.run

            def run(*args, **kwargs):
                if args[0] == 'compose':
                    return real_run(*args, **kwargs)
                services = set(json.loads(running.read_text()))
                if args[0] == 'ps':
                    self.assertIn('--filter=label=com.docker.compose.project=' + subject.name, args)
                    return '\n'.join(f'{service}-id {service}' for service in sorted(services)).encode()
                if args[:3] == ('stop', '--time', '5'):
                    stopped.update(container.removesuffix('-id') for container in args[3:])
                    self.assertLessEqual(stopped, consumers)
                    running.write_text(json.dumps(sorted(services - stopped)))
                    return subprocess.CompletedProcess(args, 0, b'', b'')
                self.fail(f'unexpected raw Docker command {args[0]}')

            subject.run = run
            # Exercise the exact CLI/plugin I/O path with a short process timeout.
            count = subject.alert_count
            subject.alert_count = lambda **kwargs: count(timeout=0.70)
            output, error = io.StringIO(), io.StringIO()
            try:
                for options in ({}, {'timeout': 3}):
                    with self.subTest(command_options=options):
                        result = subject.exec('monitor', 't34-stdio', input=b'plugin stdout\n',
                                              check=False, **options)
                        self.assertEqual((result.returncode, result.stdout, result.stderr),
                                         (7, b'plugin stdout\n', b'plugin stderr\n'))
                with mock.patch.object(staging, 'verify_storage'), \
                        mock.patch.object(staging, 'write_state') as write_state, \
                        contextlib.redirect_stdout(output), contextlib.redirect_stderr(error):
                    with self.assertRaisesRegex(ValueError, 'local alert sink count timed out'):
                        release.update_release(subject, SimpleNamespace(
                            revision='must-not-deploy', previous=old_state['release']['revision']),
                                               old_state, 't34-state', composition_for(old_state['release']),
                                               old_state['schema_digest'],
                                               old_state['schema_version'])
                pids = json.loads((folder / 'pids.json').read_text())
                with self.assertRaises(ChildProcessError, msg='Docker CLI child was not reaped'):
                    os.waitpid(pids['cli'], os.WNOHANG)
                self.assertEqual(stopped, consumers)
                self.assertEqual(set(json.loads(running.read_text())), storage)
                self.assertEqual(old_state, original_state)
                subject.open_release.assert_not_called()
                write_state.assert_not_called()
                self.assertNotIn('synthetic-pass', output.getvalue())
                self.assertIs(json.loads(error.getvalue())['serving_fenced'], True)

                heartbeat = folder / 'heartbeat'
                before = heartbeat.read_text()
                self.assertIn(str(pids['cli']), before.splitlines(), 'the CLI really launched the plugin')
                time.sleep(0.25)
                after = heartbeat.read_text()
                self.assertEqual(len(after.splitlines()), len(before.splitlines()),
                                 f'Compose plugin kept running after CLI timeout (last PPID {after.splitlines()[-1]})')
                self.assertEqual(pids['group'], pids['cli'], 'timed Compose must own a private process group')
            finally:
                # Keep the regression harmless even against the pre-fix code.
                (folder / 'stop-plugin').touch()

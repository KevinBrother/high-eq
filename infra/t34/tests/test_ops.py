import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parents[1]
OPS = HERE / 'ops.sh'
sys.path.insert(0, str(HERE))
from release import ALERT_WEBHOOK, resume_consumers


class OpsContract(unittest.TestCase):
    def fake(self, directory, name, body):
        path = directory / name
        path.write_text('#!/bin/sh\nset -eu\n' + body)
        path.chmod(0o755)

    def monitor(self, status, curl_code=0):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            bin_dir = tmp / 'bin'
            bin_dir.mkdir()
            log = tmp / 'curl.log'
            self.fake(bin_dir, 'psql', 'printf "%s\\n" "$FAKE_STATUS"\n')
            self.fake(bin_dir, 'curl', f'printf "%s\\n" "$*" >> "$CURL_LOG"\nexit "$CURL_CODE"\n')
            env = os.environ | {
                'PATH': f'{bin_dir}:{os.environ["PATH"]}',
                'ALERT_WEBHOOK': 'http://alert-sink:8080/alerts',
                'FAKE_STATUS': status,
                'CURL_LOG': str(log),
                'CURL_CODE': str(curl_code),
            }
            result = subprocess.run(['sh', str(OPS), 'monitor-once'], env=env, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            calls = log.read_text() if log.exists() else ''
            return result, calls

    def test_monitor_delivers_both_threshold_and_missing_price(self):
        result, calls = self.monitor('cost_anomaly,unpriced')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('http://alert-sink:8080/alerts', calls)
        self.assertIn('cost_anomaly', calls)
        self.assertIn('unpriced', calls)
        normal, calls = self.monitor('normal')
        self.assertEqual(normal.returncode, 0, normal.stdout)
        self.assertEqual(calls, '', 'normal status must not create an alert')
        failed, calls = self.monitor('cost_anomaly,unpriced', curl_code=22)
        self.assertNotEqual(failed.returncode, 0, 'delivery failure must not look healthy')
        self.assertIn('alert_delivery_failed', failed.stdout)
        self.assertIn('http://alert-sink:8080/alerts', calls)
        self.assertEqual(len(calls.splitlines()), 2,
                         'one failed delivery must not suppress the other independent alert')

    def test_consumer_readiness_proves_delivery_even_when_psql_is_normal(self):
        for curl_code, http_status, received in ((22, '000', False), (0, '200', False),
                                                  (0, '202', False), (0, '202', True)):
            with self.subTest(curl=curl_code, http=http_status, received=received), tempfile.TemporaryDirectory() as folder:
                tmp = Path(folder)
                log = tmp / 'curl.log'
                self.fake(tmp, 'psql', 'printf "normal\\n"\n')
                self.fake(tmp, 'curl', 'printf "%s\\n" "$*" >> "$CURL_LOG"\nprintf "%s" "$HTTP_STATUS"\nexit "$CURL_CODE"\n')
                env = {
                    'PATH': f'{tmp}:{os.environ["PATH"]}',
                    'ALERT_WEBHOOK': ALERT_WEBHOOK,
                    'CURL_LOG': str(log),
                    'CURL_CODE': str(curl_code),
                    'HTTP_STATUS': http_status,
                }
                lab = mock.Mock()
                lab.env = env
                lab.alert_count.return_value = 10
                if not received:
                    lab.wait_alert_count.side_effect = ValueError('sink did not receive expected alerts')

                def exec_(service, path, command, **kwargs):
                    self.assertEqual((service, path), ('monitor', '/ops/ops.sh'))
                    result = subprocess.run(['sh', str(OPS), command], env=env,
                                            capture_output=True, timeout=5)
                    if result.returncode:
                        raise RuntimeError('monitor probe failed')
                    return result.stdout

                lab.exec.side_effect = exec_
                if received:
                    resume_consumers(lab)
                else:
                    with self.assertRaises((RuntimeError, ValueError)):
                        resume_consumers(lab)
                self.assertTrue(log.is_file(), 'normal psql must still exercise real ops.sh curl path')
                self.assertIn('synthetic_probe', log.read_text())
                self.assertIn(ALERT_WEBHOOK, log.read_text())
                if curl_code == 0 and http_status == '202':
                    self.assertEqual(lab.wait_alert_count.call_args.args, (11,))
                else:
                    lab.wait_alert_count.assert_not_called()

    def test_backup_health_requires_a_fresh_snapshot(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            bin_dir = tmp / 'bin'
            vault = tmp / 'vault'
            snap = vault / 'snap-current'
            bin_dir.mkdir()
            snap.mkdir(parents=True)
            now = 2000000000
            self.fake(bin_dir, 'date', f'printf "%s\n" {now}\n')
            env = os.environ | {
                'PATH': f'{bin_dir}:{os.environ["PATH"]}',
                'VAULT_DIR': str(vault),
                'INSTALLATION': 'install-1',
                'BACKUP_MAX_AGE': '93600',
            }
            (snap / 'business.dump').write_bytes(b'synthetic')
            (snap / 'SHA256SUMS').write_text('synthetic  business.dump\n')
            (snap / 'inventory').write_text(f'{now - 60} {now - 60 + 45 * 86400} install-1\n')
            fresh = subprocess.run(['sh', str(OPS), 'backup-health'], env=env,
                                   text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            self.assertEqual(fresh.returncode, 0, fresh.stdout)
            (snap / 'inventory').write_text(f'{now - 93601} {now - 93601 + 45 * 86400} install-1\n')
            stale = subprocess.run(['sh', str(OPS), 'backup-health'], env=env,
                                   text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            self.assertNotEqual(stale.returncode, 0, 'stale backups must make the supervisor unhealthy')
            self.assertIn('backup_stale', stale.stdout)
            (snap / 'inventory').write_text(f'{now - 60} {now - 60 + 46 * 86400} install-1\n')
            extended = subprocess.run(['sh', str(OPS), 'backup-health'], env=env,
                                      text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            self.assertNotEqual(extended.returncode, 0, 'retention cannot be extended by rewriting inventory')

    def test_restore_accepts_an_existing_daily_snapshot(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            bin_dir = tmp / 'bin'
            vault = tmp / 'vault'
            snap = vault / 'snap-existing'
            bin_dir.mkdir()
            snap.mkdir(parents=True)
            now = 2000000000
            (snap / 'business.dump').write_bytes(b'synthetic')
            (snap / 'SHA256SUMS').write_text('synthetic  business.dump\n')
            (snap / 'inventory').write_text(f'{now} {now + 45 * 86400} install-1\n')
            log = tmp / 'restore.log'
            self.fake(bin_dir, 'date', f'printf "%s\\n" {now}\n')
            self.fake(bin_dir, 'sha256sum', 'exit 0\n')
            self.fake(bin_dir, 'psql', 'printf "0\\n"\n')
            self.fake(bin_dir, 'pg_restore', 'printf "%s\\n" "$*" >> "$RESTORE_LOG"\n')
            env = os.environ | {
                'PATH': f'{bin_dir}:{os.environ["PATH"]}',
                'VAULT_DIR': str(vault),
                'INSTALLATION': 'install-1',
                'PGDATABASE': 'postgres',
                'RESTORE_LOG': str(log),
            }
            result = subprocess.run(['sh', str(OPS), 'restore', 'snap-existing'],
                                    env=env, text=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT)
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertIn(str(snap / 'business.dump'), log.read_text())
            self.assertIn('restore_ok', result.stdout)

    def test_restore_refuses_nonempty_target_and_expired_snapshot(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            bin_dir = tmp / 'bin'
            vault = tmp / 'vault'
            snap = vault / 'snap-existing'
            bin_dir.mkdir()
            snap.mkdir(parents=True)
            now = 2000000000
            (snap / 'business.dump').write_bytes(b'synthetic')
            (snap / 'SHA256SUMS').write_text('synthetic  business.dump\n')
            (snap / 'inventory').write_text(f'{now} {now + 45 * 86400} install-1\n')
            log = tmp / 'restore.log'
            self.fake(bin_dir, 'date', f'printf "%s\\n" {now}\n')
            self.fake(bin_dir, 'sha256sum', 'exit 0\n')
            self.fake(bin_dir, 'psql', 'printf "%s\\n" "$NONEMPTY"\n')
            self.fake(bin_dir, 'pg_restore', 'printf "%s\\n" "$*" >> "$RESTORE_LOG"\n')
            base = os.environ | {
                'PATH': f'{bin_dir}:{os.environ["PATH"]}',
                'VAULT_DIR': str(vault),
                'INSTALLATION': 'install-1',
                'PGDATABASE': 'postgres',
                'RESTORE_LOG': str(log),
            }
            nonempty = subprocess.run(['sh', str(OPS), 'restore', 'snap-existing'],
                                      env=base | {'NONEMPTY': '1'}, text=True,
                                      stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            self.assertNotEqual(nonempty.returncode, 0)
            self.assertFalse(log.exists())
            (snap / 'inventory').write_text(f'{now - 46 * 86400} {now - 86400} install-1\n')
            expired = subprocess.run(['sh', str(OPS), 'restore', 'snap-existing'],
                                     env=base | {'NONEMPTY': '0'}, text=True,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            self.assertNotEqual(expired.returncode, 0)
            self.assertFalse(log.exists())

    def test_ops_image_contains_every_gate_runtime_dependency(self):
        dockerfile = (HERE / 'Ops.Dockerfile').read_text()
        gate = (HERE / 'gate.sh').read_text()
        package_line = next(line for line in dockerfile.splitlines()
                            if line.startswith('RUN apk add --no-cache '))
        packages = set(package_line.split()[4:])
        for package in ('curl', 'jq', 'redis', 'python3'):
            with self.subTest(package=package):
                self.assertIn(package, packages)
        self.assertIn('redis-cli', gate)
        self.assertIn('psql', gate)
        self.assertIn('infra/t34/ticket.py', dockerfile)


if __name__ == '__main__':
    unittest.main()

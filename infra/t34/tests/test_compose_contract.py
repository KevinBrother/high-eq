"""Static source contracts; real Compose rendering is checked by Lab.config."""
import re
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]


def service(source, name):
    """Extract a service stanza from these two checked-in Compose sources."""
    services = source.split('\nservices:\n', 1)[1].split('\nnetworks:', 1)[0]
    services = services.split('\nvolumes:', 1)[0]
    pattern = rf'^  {re.escape(name)}:[^\n]*(?:\n    [^\n]*)*'
    match = re.search(pattern, services, re.MULTILINE)
    if not match:
        raise AssertionError('missing Compose service stanza')
    return match[0]


class ComposeContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base = (HERE / 'compose.yml').read_text()
        cls.test = (HERE / 'test.yml').read_text()

    def test_ledger_has_a_separate_authenticated_network(self):
        ledger = service(self.base, 'ledger')
        self.assertIn('networks: [ledger-net]', ledger)
        self.assertIn('  ledger-net: {internal: true}', self.base)
        for name in ('monitor', 'backup', 'web'):
            self.assertNotIn('ledger-net', service(self.base, name), name)
            self.assertNotIn('ledger-net', service(self.test, name), name)
        self.assertIn('networks: [default, ledger-net]', service(self.base, 'api'))
        self.assertIn('networks: [default, ledger-net]', service(self.test, 'api'))
        permit = service(self.test, 'permit')
        self.assertIn('networks: [default, ledger-net]', permit)
        self.assertIn('LEDGER_URL: redis://default:${LEDGER_PASS:?}@ledger:6379/0', permit)
        self.assertIn("--requirepass, '${LEDGER_PASS:?}'", ledger)
        self.assertIn("REDISCLI_AUTH: '${LEDGER_PASS:?}'", ledger)

    def test_old_ingress_depends_on_live_sweeper_and_sweeper_depends_on_permit(self):
        for name in ('api', 'web'):
            self.assertIn('chat-sweeper: {condition: service_healthy}', service(self.base, name))
            self.assertIn('depends_on: *authorized', service(self.test, name))
        sweeper = service(self.base, 'chat-sweeper')
        self.assertIn('health, /tmp/chat-sweep.ready', sweeper)
        self.assertIn("PGHOST: '${DB_SERVICE:-db}'", sweeper)
        self.assertNotIn('ledger-net', sweeper)
        self.assertIn('depends_on: *authorized', service(self.test, 'chat-sweeper'))
        production = (HERE / 'production.yml').read_text()
        self.assertIn('depends_on: *closed', service(production, 'chat-sweeper'))

    def test_permit_is_an_actual_recovery_gate(self):
        permit = service(self.test, 'permit')
        self.assertIn('image: ${OPS_IMAGE:?}', permit)
        self.assertIn('entrypoint: [/ops/gate.sh, verify]', permit)
        self.assertIn('GATE_FILE: /gate/ticket', permit)
        self.assertIn('volumes: [approval:/gate:ro]', permit)
        self.assertNotIn('cat /gate/ticket', permit)

    def test_permit_receives_independent_digest_and_retention_witness(self):
        # Preserve the rendered-environment witness without requiring Docker or staging.
        permit = service(self.test, 'permit')
        self.assertIn("BUSINESS_DUMP_SHA256: '${BUSINESS_DUMP_SHA256:-}'", permit)
        self.assertIn("LEDGER_RETENTION_MODE: '${LEDGER_RETENTION_MODE:-fresh}'", permit)
        self.assertIn("LEDGER_DEADLINES: '${LEDGER_DEADLINES:-}'", permit)

    def test_monitor_delivery_and_daily_backup_supervision_are_wired(self):
        monitor = service(self.base, 'monitor')
        backup = service(self.base, 'backup')
        alert_sink = service(self.base, 'alert-sink')
        for supervisor in (monitor, backup):
            self.assertIn('restart: unless-stopped', supervisor)
        self.assertIn('ALERT_WEBHOOK: \'${ALERT_WEBHOOK:-http://alert-sink:8080/alerts}\'', monitor)
        self.assertIn('alert-sink: {condition: service_healthy}', monitor)
        self.assertIn('alert-sink: {condition: service_healthy}', service(self.test, 'monitor'))
        self.assertIn('image: ${SINK_IMAGE:?}', alert_sink)
        self.assertIn('healthcheck: {test: [CMD, /sink, healthcheck]', alert_sink)
        self.assertIn('healthcheck: {test: [CMD, /ops/ops.sh, backup-health]', backup)


if __name__ == '__main__':
    unittest.main()

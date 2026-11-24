"""Exercise T35 gate exit codes and safe receipts without external services."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


GATE = Path(__file__).with_name("gate.sh").resolve()
CI_SERVICE = GATE.with_name("ci-service.sh")
LOST_CLOSURE_RECEIPT = "lost closure receipt remains visible on login after unauthorized readback"
REQUIRED_CLIENT = (
    "named privacy route reads account and verifies persisted correction",
    "frozen relogin gates business routes until explicit cancellation and readback",
    "unknown account never starts assessment or growth",
    "phone closure submits one fresh proof and retires the local lease",
    "my tab opens the formal privacy page",
    LOST_CLOSURE_RECEIPT,
)
MAINTENANCE_TEST = "TestPrivacyExpiredAccountMaintenanceIsolatesFailure"
EXPORT_OWNERSHIP_TEST = "TestT35ExportAssessmentOwnership"
REQUIRED_CONTRACT = (
    "TestPrivacyAccountRouteContract",
    "TestPrivacyAccountBarrierResponse",
)
REQUIRED_EXPORT = (
    "TestAIExportGroupsAcrossBusinessRequests",
    "TestExportCommitFailureDoesNotRevealArchive",
    "TestExportStreamsLargeIncompressibleEntryBeforeCommit",
    "TestExportLateFailureAbortsHTTP2Stream",
    "TestExportLateFailureDoesNotEndAsNormalHTTP1Response",
    "TestExportLatePanicAbortsResponse",
)
REQUIRED_PROFILE_RECOVERY = (
    "TestProfileInferenceRecoversInterruptedExecution",
    "TestProfileInferenceSurvivesPopulatedRollback",
)
REQUIRED_INTEGRATION = (
    "TestPrivacyPhoneOnlyClosureHTTP",
    "TestAccountLifecycle",
    "TestGrowthRoutesRejectFrozenAccountWithoutGeneratingPlan",
    MAINTENANCE_TEST,
) + REQUIRED_EXPORT + REQUIRED_PROFILE_RECOVERY
REQUIRED_SERVICE = REQUIRED_CONTRACT + REQUIRED_INTEGRATION
PRIVATE = "synthetic-private-response-marker"


class GateTest(unittest.TestCase):
    def setUp(self):
        scratch = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.env = {
            "PATH": f"{scratch}:{Path(sys.executable).parent}:{os.defpath}",
            "TMPDIR": str(scratch),
            "APP_ENV": "development",
            "T35_PRIVACY_DISPOSABLE": "yes",
            "DATABASE_URL": "postgres://127.0.0.1:15432/test",
            "REDIS_URL": "redis://127.0.0.1:16379/0",
            "LEDGER_URL": "redis://127.0.0.1:26379/0",
        }
        for name, names in (("flutter", REQUIRED_CLIENT), ("go", {
            "contract": REQUIRED_CONTRACT,
            "integration": REQUIRED_INTEGRATION,
            "integration,t26flutter": (EXPORT_OWNERSHIP_TEST,),
        })):
            command = scratch / name
            command.write_text(f"#!{sys.executable}\n" + f"""
import json, os, re, sys
names = {names!r}
mode = os.environ.get('T35_TEST_MODE')
print({PRIVATE!r}, file=sys.stderr)
if {name!r} == 'flutter':
    if '--reporter' not in sys.argv:
        print({PRIVATE!r})
        sys.exit(int(mode == 'client-companion-failure'))
    assert 'test/privacy/account_journey_test.dart' in sys.argv
    for i, name in enumerate(names):
        if mode == 'client-missing' and name == {LOST_CLOSURE_RECEIPT!r}:
            continue
        print(json.dumps(dict(type='testStart', test=dict(id=i, name=name))))
        print(json.dumps(dict(type='testDone', testID=i, hidden=False,
                              result='success', skipped=mode == 'client-skip' and name == {LOST_CLOSURE_RECEIPT!r})))
    print(json.dumps(dict(type='done', success=True)))
    sys.exit(int(mode == 'client-failure'))
package = 'high-eq/server/internal/service'
if os.environ.get('T35_TEST_PROVISIONED'):
    assert os.environ['DATABASE_URL'].endswith('@127.0.0.1:25432/postgres?sslmode=disable')
    assert os.environ['REDIS_URL'] == 'redis://127.0.0.1:36379/0'
    assert os.environ['LEDGER_URL'] == 'redis://127.0.0.1:46379/0'
    assert os.environ['PAYMENT_MODE'] == 'disabled'
selection = sys.argv[sys.argv.index('-run') + 1]
names = names[sys.argv[sys.argv.index('-tags') + 1]]
target = os.environ.get('T35_TEST_TARGET')
print(json.dumps(dict(Action='output', Package=package, Output={PRIVATE!r})))
for name in names:
    if re.search(selection, name):
        if name == {MAINTENANCE_TEST!r} and mode == 'maintenance-missing':
            continue
        if name == target and mode == 'export-missing':
            continue
        if name == target and mode == 'export-subtest':
            print(json.dumps(dict(Action='pass', Package=package, Test=name + '/fixture')))
            continue
        skipped = (mode == 'service-skip' and name == {REQUIRED_INTEGRATION[0]!r}) or (
            mode == 'maintenance-skip' and name == {MAINTENANCE_TEST!r}) or (
            mode == 'export-skip' and name == target)
        action = 'skip' if skipped else 'pass'
        print(json.dumps(dict(Action=action, Package=package, Test=name)))
print(json.dumps(dict(Action='pass', Package=package)))
sys.exit(int(mode == 'service-failure'))
""")
            command.chmod(0o700)

    def run_gate(self, gate, mode="", target=""):
        return subprocess.run(
            ["bash", str(GATE), gate],
            env=dict(self.env, T35_TEST_MODE=mode, T35_TEST_TARGET=target),
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False,
        )

    def test_client_passes_only_with_all_receipts_and_successful_companions(self):
        for mode in ("", "client-missing", "client-skip", "client-failure", "client-companion-failure"):
            with self.subTest(mode=mode):
                result = self.run_gate("client", mode)
                self.assertEqual(result.returncode, int(bool(mode)))
                self.assertNotIn(PRIVATE, result.stdout)
                if not mode:
                    for name in REQUIRED_CLIENT:
                        self.assertIn(f"PASS: {name}", result.stdout)

    def test_service_requires_exact_passes_and_successful_go_exit(self):
        for mode in ("", "service-skip", "maintenance-missing", "maintenance-skip", "service-failure"):
            with self.subTest(mode=mode):
                result = self.run_gate("service", mode)
                self.assertEqual(result.returncode, int(bool(mode)))
                self.assertNotIn(PRIVATE, result.stdout)
                if not mode:
                    for name in REQUIRED_SERVICE:
                        self.assertIn(f"PASS: {name}", result.stdout)
                if mode in ("maintenance-missing", "maintenance-skip"):
                    self.assertIn(f"FAIL: {MAINTENANCE_TEST}", result.stdout)

    def test_service_rejects_missing_skipped_and_subtest_only_storage_receipts(self):
        for name in REQUIRED_EXPORT + REQUIRED_PROFILE_RECOVERY:
            for mode in ("export-missing", "export-skip", "export-subtest"):
                with self.subTest(name=name, mode=mode):
                    result = self.run_gate("service", mode, name)
                    self.assertEqual(result.returncode, 1, result.stdout)
                    self.assertIn(f"FAIL: {name}", result.stdout)
                    self.assertNotIn("T35 privacy gate service PASS", result.stdout)
                    self.assertNotIn(PRIVATE, result.stdout)

    def test_service_rejects_shared_redis_before_running_go(self):
        self.env["LEDGER_URL"] = self.env["REDIS_URL"]
        result = self.run_gate("service")
        self.assertEqual(result.returncode, 1)
        self.assertIn("independent Redis instances", result.stdout)
        self.assertNotIn(REQUIRED_SERVICE[0], result.stdout)
        self.assertNotIn(PRIVATE, result.stdout)

    def test_export_ownership_requires_exact_pass_without_stores(self):
        for key in ("APP_ENV", "T35_PRIVACY_DISPOSABLE", "DATABASE_URL", "REDIS_URL", "LEDGER_URL"):
            self.env.pop(key)
        for mode in ("", "export-missing", "export-skip", "export-subtest", "service-failure"):
            with self.subTest(mode=mode):
                result = self.run_gate("export-ownership", mode, EXPORT_OWNERSHIP_TEST)
                self.assertEqual(result.returncode, int(bool(mode)), result.stdout)
                self.assertEqual("T35 privacy gate export-ownership PASS" in result.stdout, not mode)
                self.assertNotIn(PRIVATE, result.stdout)

    def test_ci_service_cleans_up_and_stops_on_provisioning_or_gate_failure(self):
        scratch = Path(self.env["TMPDIR"])
        trace = scratch / "compose.trace"
        scenario_file = scratch / "scenario"
        docker = scratch / "docker"
        docker.write_text(f"#!{sys.executable}\n" + f"""
from pathlib import Path
import sys
args = sys.argv[1:]
assert args[:5] == ['--host', 'unix:///var/run/docker.sock', 'compose', '--env-file', '/dev/null']
command = next(arg for arg in args if arg in ('up', 'port', 'down'))
scenario = Path({str(scenario_file)!r}).read_text()
with Path({str(trace)!r}).open('a') as output:
    print(command, file=output)
print({PRIVATE!r}, file=sys.stderr)
if command == 'up':
    assert args[-3:] == ['db', 'cache', 'ledger']
    assert Path(args[args.index('up') - 1]).read_text().count('127.0.0.1::') == 3
    sys.exit(scenario == 'startup-fails')
if command == 'port':
    ports = {{'db': '25432', 'cache': '36379', 'ledger': '46379'}}
    if scenario == 'shared-port':
        ports['ledger'] = ports['cache']
    print('127.0.0.1:' + ports[args[-2]])
if command == 'down':
    assert '--volumes' in args
    sys.exit(scenario == 'cleanup-fails')
""")
        docker.chmod(0o700)
        openssl = scratch / "openssl"
        openssl.write_text("#!/bin/sh\nprintf '%s\\n' 'synthetic-fixture-value'\n")
        openssl.chmod(0o700)

        cases = (("", ""), ("", "service-skip"), ("startup-fails", ""),
                 ("shared-port", ""), ("cleanup-fails", ""))
        for scenario, mode in cases:
            with self.subTest(scenario=scenario, gate_mode=mode):
                trace.unlink(missing_ok=True)
                scenario_file.write_text(scenario)
                result = subprocess.run(
                    ["bash", str(CI_SERVICE)],
                    env=dict(self.env, T35_TEST_MODE=mode, T35_TEST_PROVISIONED="yes"),
                    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False,
                )
                self.assertEqual(result.returncode, int(bool(scenario or mode)), result.stdout)
                expected = ["up", "down"] if scenario == "startup-fails" else ["up", "port", "port", "port", "down"]
                self.assertEqual(trace.read_text().splitlines(), expected)
                self.assertNotIn(PRIVATE, result.stdout)
                gate_passed = not mode and scenario in ("", "cleanup-fails")
                self.assertEqual("T35 privacy gate service PASS" in result.stdout, gate_passed)


if __name__ == "__main__":
    unittest.main()

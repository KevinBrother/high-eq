"""Offline tests of the T26 runner. Never invoke Docker, Go or Flutter."""

from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[3]
PACKAGE = "high-eq/server/internal/service"
TEST = "TestT26NewUserPlanFlutter"
OFFLINE_TESTS = (
    "TestT26FixtureFailureReceipt",
    "TestT26FlutterAssessmentFixture",
    "TestT26FlutterStageReceipt",
    "TestT26FlutterAssessmentPhaseReceipt",
    "TestT26FlutterChatAndScorePhaseReceipt",
    "TestT26FlutterChatPhaseReceiptWithExistingConsent",
    "TestT26FlutterFinishReceipt",
)
FAKE_TOOL = r'''
import json
import os
from pathlib import Path
import re
import subprocess
import sys

tool = Path(sys.argv[0])
directory = tool.parent
case = (directory / "case").read_text()
args = sys.argv[1:]


def record(action):
    with (directory / "calls").open("a") as stream:
        stream.write(action + "\n")


def await_cancellation():
    # Compose and Go both launch children. Model a child that must receive
    # the cancellation signal even if its direct parent has already exited.
    child = """
import signal
from pathlib import Path
import sys
import time

directory = Path(sys.argv[1])
def stop(*_):
    (directory / "child-stopped").touch()
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
(directory / "ready-to-cancel").touch()
time.sleep(5)
"""
    subprocess.run([sys.executable, "-c", child, str(directory)], check=True)


if tool.name == "docker":
    record("docker")
    assert args[:3] == ["--host", "unix:///var/run/docker.sock", "compose"], args[:3]
    assert not {"DOCKER_CONTEXT", "DOCKER_HOST"} & os.environ.keys()
    if args[3:] == ["version"]:
        sys.exit(0)
    assert args[3:6] == ["--env-file", "/dev/null", "--project-name"]
    assert re.fullmatch(r"t26-ci-[0-9a-f]{16}", args[6])
    assert args[7:9] == ["-f", "docker-compose.yml"] and args[9] == "-f"
    override = Path(args[10])
    assert override.read_text().count("127.0.0.1::") == 3
    assert re.fullmatch(r"[0-9a-f]{32}", os.environ["HEQ_PG_PASSWORD"])
    action, *options = args[11:]
    record(action)
    running = directory / "stores"
    if action == "up":
        assert options[-3:] == ["db", "cache", "ledger"]
        assert "--no-build" in options and "--wait" in options
        running.touch()
        if case == "cancel-setup":
            await_cancellation()
        if case == "up-fail":
            print("setup-secret", file=sys.stderr)
            sys.exit(3)
    elif action == "port":
        assert running.is_file()
        ports = {"db": ("5432", 49101), "cache": ("6379", 49102), "ledger": ("6379", 49103)}
        service = options[0]
        assert len(options) == 2 and options[1] == ports[service][0]
        host = "0.0.0.0" if case == "public-port" else "127.0.0.1"
        port = 49102 if (case == "aliased-port" and service == "ledger") else ports[service][1]
        print(f"{host}:{port}")
    elif action == "down":
        assert "--volumes" in options and "--remove-orphans" in options
        running.unlink()
        if case == "down-fail":
            sys.exit(4)
    else:
        raise AssertionError(action)
    sys.exit(0)

assert tool.name == "go", tool.name
record("go")
package = "high-eq/server/internal/service"
test = "TestT26NewUserPlanFlutter"


def event(action, **fields):
    print(json.dumps({"Action": action, "Package": package, **fields}))


if case.startswith("offline-"):
    assert not (directory / "stores").exists()
    assert Path.cwd().name == "server"
    assert args == [
        "test", "-tags", "integration,t26flutter", "-count=1", "-timeout=2m", "-json",
        "-run", f"^({'|'.join(OFFLINE_TESTS)})$", "./internal/service",
    ], args
    assert not {"DATABASE_URL", "REDIS_URL", "LEDGER_URL", "T19_DISPOSABLE", "T20_DISPOSABLE",
                "T26_FIXTURE_FAILURE_TEST_CASE", "GOFLAGS", "HTTP_PROXY"} & os.environ.keys()
    for name in OFFLINE_TESTS:
        if case != "offline-missing-fixture" or name != "TestT26FixtureFailureReceipt":
            event("pass", Test=name)
    event("output", Output="uncensored-proof\n")
    event("pass")
    print("stderr-secret", file=sys.stderr)
    sys.exit(19 if case == "offline-go-fail" else 0)

assert (directory / "stores").exists()
assert Path.cwd().name == "server"
assert args == [
    "test", "-tags", "integration,t26flutter", "-count=1", "-timeout=6m", "-json",
    "-run", "^TestT26NewUserPlanFlutter$", "./internal/service",
], args
assert os.environ["T19_DISPOSABLE"] == "yes"
assert os.environ["APP_ENV"] == "development"
assert os.environ["PAYMENT_MODE"] == "disabled"
assert os.environ["GOENV"] == "off"
assert not {"GOFLAGS", "HTTP_PROXY", "T26_LOGIN_PROOF", "WLEIS_CONFIG_PATH"} & os.environ.keys()
assert re.fullmatch(r"postgres://postgres:[0-9a-f]{32}@127\.0\.0\.1:49101/postgres\?sslmode=disable",
                    os.environ["DATABASE_URL"])
assert os.environ["REDIS_URL"] == "redis://127.0.0.1:49102/0"
assert os.environ["LEDGER_URL"] == "redis://127.0.0.1:49103/0"
if case == "cancel-go":
    await_cancellation()
event("output", Test=test, Output="uncensored-proof\n")
event("output", Test=test, Output="    t26_flutter_journey_integration_test.go:144: Flutter T26 journey exited successfully (stage=score, phase=verified, finish_before_scroll=miss)\n")
print("stderr-secret", file=sys.stderr)
if case == "fixture-summary":
    journey = "    t26_flutter_journey_integration_test.go:225: "
    fixture = "    training_fixture_integration_test.go:255: "
    for summary in (
        fixture + "T26 fixture: stage=seed_model error=database",
        journey + "T26 fixture: stage=start_runtime error=connection",
        journey + "T26 readback: stage=begin error=connection",
        journey + "T26 readback: stage=plan error=assertion (uncensored-proof)",
        journey + "T26 synthetic readback: sessions=1 saved_turns=2 scores=0",
        journey + "Flutter T26 journey failed (exit=1, stage=score, phase=lobbyCurrent, finish_before_scroll=hit)",
        journey + "Flutter T26 journey failed (exit=1, stage=score, phase=lobbyBack, finish_before_scroll=hit)",
        journey + "Flutter T26 journey exited without a complete receipt (stage=score, phase=planCompletion)",
        journey + "Flutter T26 journey terminated: context deadline exceeded (stage=score, phase=revealCompletion)",
        journey + "T26 fixture: stage=seed_unknown error=database",
        journey + "T26 readback: stage=practice error=unknown",
        journey + "T26 readback: stage=practice error=database uncensored-proof",
        journey + "T26 synthetic readback: sessions=1 saved_turns=2 scores=0 uncensored-proof",
        journey + "Flutter T26 journey uncensored-proof (stage=login)",
        journey + "Flutter T26 journey exited successfully (stage=login, phase=verified)",
        "redis: failed to dial tcp 127.0.0.1:49102: connection refused",
        "GET /v1/growth Authorization: Bearer synthetic-request-token",
        "    other_test.go:10: T26 fixture: stage=load_config error=operation",
    ):
        event("output", Test=test, Output=summary + "\n")
    event("output", Test=test + "/subtest", Output=journey + "T26 fixture: stage=load_config error=operation\n")
    print(json.dumps({"Action": "output", "Package": "other", "Test": test,
                      "Output": journey + "T26 readback: stage=commit error=database\n"}))
    event("fail", Test=test)
    event("fail")
    sys.exit(1)
if case == "skip":
    event("skip", Test=test)
elif case == "wrong-test":
    event("pass", Test=test + "/subtest")
elif case == "wrong-package":
    print(json.dumps({"Action": "pass", "Package": "other", "Test": test}))
else:
    event("pass", Test=test)
event("pass")
sys.exit(19 if case == "go-fail" else 0)
'''


class RunnerTest(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="t26-ci-test-")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.work = self.root / "tmp"
        self.work.mkdir()
        for name in ("go", "docker", "flutter"):
            tool = self.bin / name
            tool.write_text(f"#!{sys.executable}\nOFFLINE_TESTS = {OFFLINE_TESTS!r}\n{FAKE_TOOL}")
            tool.chmod(0o700)
        (self.bin / "python3").symlink_to(sys.executable)
        for name in (
            "app/tool/t26/ci.sh",
            "server/tests/t19_wire_result.py",
        ):
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            source = ROOT / name
            if source.is_file():
                shutil.copyfile(source, target)
        for name in (
            "docker-compose.yml",
            "app/tool/t26/plan_journey_test.dart",
            "app/.dart_tool/package_config.json",
            "server/go.mod",
            "server/internal/service/t26_flutter_journey_integration_test.go",
            "server/internal/service/testdata/t26_assessment.yaml",
        ):
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.touch()
        (self.root / "app/.dart_tool/package_config.json").write_text("{}")

    def run_ci(self, case, *, expected, diagnostic="", args=(), summary=None):
        (self.bin / "case").write_text(case)
        env = {
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "HOME": str(self.root),
            "TMPDIR": str(self.work),
            "DATABASE_URL": "postgres://must-not-be-used",
            "REDIS_URL": "redis://must-not-be-used",
            "LEDGER_URL": "redis://must-not-be-used",
            "T19_DISPOSABLE": "yes",
            "T20_DISPOSABLE": "yes",
            "DOCKER_HOST": "tcp://must-not-be-used",
            "DOCKER_CONTEXT": "must-not-be-used",
            "GOFLAGS": "-run=unsafe-override",
            "HTTP_PROXY": "must-not-be-used",
            "T26_LOGIN_PROOF": "inherited-proof",
            "T26_FIXTURE_FAILURE_TEST_CASE": "inherited-case",
            "WLEIS_CONFIG_PATH": "must-not-be-used",
        }
        with subprocess.Popen(
            ["bash", str(self.root / "app/tool/t26/ci.sh"), *args],
            cwd=self.work,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        ) as process:
            try:
                if case in ("cancel-setup", "cancel-go"):
                    deadline = time.monotonic() + 5
                    while not (self.bin / "ready-to-cancel").exists():
                        self.assertIsNone(process.poll(), "runner exited before cancellation")
                        self.assertLess(time.monotonic(), deadline, "runner never reached cancellation point")
                        time.sleep(0.02)
                    process.send_signal(signal.SIGTERM)
                output, _ = process.communicate(timeout=10)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()
        self.assertEqual(process.returncode, expected, output)
        self.assertIn(diagnostic, output)
        for secret in ("setup-secret", "uncensored-proof", "stderr-secret", "inherited-proof"):
            self.assertNotIn(secret, output)
        if summary is not None:
            self.assertEqual(output.splitlines(), summary)
        self.assertFalse((self.bin / "stores").exists(), "disposable stores leaked")
        self.assertEqual(list(self.work.iterdir()), [], "scratch contents leaked")
        calls = self.bin / "calls"
        return calls.read_text().splitlines() if calls.exists() else []

    def test_missing_packages_fail_before_docker(self):
        (self.root / "app/.dart_tool/package_config.json").unlink()
        self.assertEqual(self.run_ci("pass", expected=2, diagnostic="package_config.json"), [])

    def test_exact_pass_uses_host_runner_and_cleans_up(self):
        calls = self.run_ci("pass", expected=0, diagnostic="stage=score, phase=verified")
        self.assertEqual(calls[-3:], ["go", "docker", "down"])

    def test_offline_fixture_names_match_go_test_declarations(self):
        declared_tests = {
            name
            for source in (ROOT / "server/internal/service").glob("t26*_test.go")
            for name in re.findall(r"^func (TestT26\w+)\(", source.read_text(), re.MULTILINE)
        }
        self.assertEqual(set(OFFLINE_TESTS) - declared_tests, set(),
                         "offline receipt fixtures must name existing Go tests")

    def test_offline_checks_select_fixture_and_stage_tests_and_require_real_passes(self):
        (self.root / "app/.dart_tool/package_config.json").unlink()
        for case, status, diagnostic in (
            ("offline-pass", 0, "offline receipt checks passed"),
            ("offline-missing-fixture", 1, "offline receipt check did not pass: TestT26FixtureFailureReceipt"),
            ("offline-go-fail", 19, "offline receipt checks: go test exited 19"),
        ):
            with self.subTest(case=case):
                (self.bin / "calls").unlink(missing_ok=True)
                calls = self.run_ci(case, expected=status, diagnostic=diagnostic, args=("--offline-receipts",))
                self.assertEqual(calls, ["go"])

    def test_failed_journey_summarizes_only_allowed_receipts_and_still_fails(self):
        self.run_ci("fixture-summary", expected=1, summary=[
            "T26 CI: running TestT26NewUserPlanFlutter on the host",
            "T26 CI: stage=score, phase=verified, finish_before_scroll=miss",
            "T26 CI: fixture stage=seed_model error=database",
            "T26 CI: fixture stage=start_runtime error=connection",
            "T26 CI: readback stage=begin error=connection",
            "T26 CI: readback stage=plan error=assertion",
            "T26 CI: sessions=1 saved_turns=2 scores=0",
            "T26 CI: stage=score, phase=lobbyCurrent, finish_before_scroll=hit",
            "T26 CI: stage=score, phase=lobbyBack, finish_before_scroll=hit",
            "T26 CI: stage=score, phase=planCompletion",
            "T26 CI: stage=score, phase=revealCompletion",
            "T26 CI: exact top-level test failed",
            "T26 CI: go test exited 1",
        ])

    def test_setup_failure_or_unusable_port_still_cleans_up(self):
        for case, diagnostic in (
            ("up-fail", "could not start disposable storage"),
            ("public-port", "invalid loopback port"),
            ("aliased-port", "distinct loopback ports"),
        ):
            with self.subTest(case=case):
                (self.bin / "calls").unlink(missing_ok=True)
                calls = self.run_ci(case, expected=1, diagnostic=diagnostic)
                self.assertEqual(calls[-2:], ["docker", "down"])
                self.assertNotIn("go", calls)

    def test_skip_wrong_selection_or_nonzero_go_status_cannot_pass(self):
        for case, status, diagnostic in (
            ("skip", 1, "was skipped"),
            ("wrong-test", 1, "no terminal event for the exact top-level test"),
            ("wrong-package", 1, "no terminal event for the exact top-level test"),
            ("go-fail", 19, "go test exited 19"),
        ):
            with self.subTest(case=case):
                (self.bin / "calls").unlink(missing_ok=True)
                calls = self.run_ci(case, expected=status, diagnostic=diagnostic)
                self.assertEqual(calls[-3:], ["go", "docker", "down"])

    def test_cleanup_failure_fails_a_passing_run(self):
        self.run_ci("down-fail", expected=1, diagnostic="storage cleanup failed")

    def test_sigterm_cleans_up_during_setup_and_during_go(self):
        for case in ("cancel-setup", "cancel-go"):
            with self.subTest(case=case):
                (self.bin / "calls").unlink(missing_ok=True)
                (self.bin / "ready-to-cancel").unlink(missing_ok=True)
                (self.bin / "child-stopped").unlink(missing_ok=True)
                calls = self.run_ci(case, expected=143)
                self.assertEqual(calls[-2:], ["docker", "down"])
                self.assertEqual("go" in calls, case == "cancel-go")
                self.assertTrue((self.bin / "child-stopped").exists(), "runner left a child running")


if __name__ == "__main__":
    unittest.main()

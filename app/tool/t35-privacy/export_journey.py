"""Require real HTTP export from the formal Flutter account page."""

import argparse
from contextlib import ExitStack
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "app/tool/t27"))
sys.path.insert(0, str(ROOT / "server/tests"))
import history_journey as native
from t19_wire_result import classify

PACKAGE = "high-eq/server/internal/service"
TEST = "TestT35FormalAccountExportJourney"
PHASES = (
    "service.runtime", "service.seed",
    "page.account-a.before", "page.account-a.delete", "page.account-a.after",
    "page.account-b.before", "page.account-b.after",
    "receive.wire-and-inventory", "receive.selected-mark-diff",
    "receive.account-isolation",
)
MARKER = re.compile(r"(?:[\w.-]+\.go:\d+:\s+)?(BEGIN|PASS)\(([a-z.-]+)\)")


def run_export_test(go, env, log):
    with ExitStack() as command:
        proc = native.spawn(command, [
            go, "test", "-mod=readonly", "-tags=integration,t26flutter", "-count=1",
            "-timeout=7m", "-json", "-run", f"^{TEST}$", "./internal/service",
        ], env, log)
        try:
            status = proc.wait(timeout=540)
        except subprocess.TimeoutExpired:
            status = None

    stage = "go.startup"
    passed = []
    lines = log.read_text(encoding="utf-8", errors="replace").splitlines()
    verdict = classify(lines, package=PACKAGE, test=TEST)
    for line in lines:
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if (not isinstance(event, dict) or event.get("Action") != "output"
                or event.get("Package") != PACKAGE or event.get("Test") != TEST
                or not isinstance(event.get("Output"), str)):
            continue
        match = MARKER.fullmatch(event["Output"].strip())
        if match and (match[2] in PHASES or match.groups() == ("BEGIN", "page.startup")):
            stage = match[2]
            if match[1] == "PASS":
                passed.append(stage)

    if status != 0 or not verdict.accepted or tuple(passed) != PHASES:
        receipt_dir = env.get("T35_EXPORT_RECEIPT_DIR")
        if receipt_dir:
            failure_log = Path(receipt_dir) / "go.test.log"
            shutil.copyfile(log, failure_log)
            for line in lines:
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                output = event.get("Output") if isinstance(event, dict) else None
                if isinstance(output, str) and (
                    "FAIL(" in output or "Fatal" in output or "seed route" in output
                ):
                    print(output.rstrip(), file=sys.stderr)
            raise native.Failed(
                f"exact Go result and ordered phase receipts required, see {failure_log}",
                stage=stage,
            )
        raise native.Failed("exact Go result and ordered phase receipts required", stage=stage)
    for phase in passed:
        print(f"PASS({phase})", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pg-bin", type=Path, required=True)
    parser.add_argument("--redis", type=Path, required=True)
    parser.add_argument("--go", default=shutil.which("go"))
    parser.add_argument("--flutter", default=shutil.which("flutter"))
    parser.add_argument("--receipt-dir", type=Path)
    args = parser.parse_args()

    def interrupt(_signum, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupt)
    os.umask(0o077)
    with native.prerequisite(native.Stage.WORKSPACE), tempfile.TemporaryDirectory(prefix="t35-export-") as temp:
        state = Path(temp).resolve()
        env = native.isolated_environment(state)
        env.update(HOME=str(state), PAYMENT_MODE="disabled", T35_EXPORT_DISPOSABLE="yes")
        if args.receipt_dir is not None:
            receipt_dir = args.receipt_dir.expanduser().resolve()
            receipt_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
            env["T35_EXPORT_RECEIPT_DIR"] = str(receipt_dir)
        native.run_services(args, state, state, env, run_journey=run_export_test)
    print("T35_EXPORT_RESULT=PASS", flush=True)


if __name__ == "__main__":
    try:
        main()
    except native.JourneyError as error:
        stage = error.stage if error.stage in native.REPORTABLE_STAGES.union(PHASES) else "workspace"
        status, code = ("NOT RUN", 2) if isinstance(error, native.NotRun) else ("FAIL", 1)
        print(f"{status}({stage})", file=sys.stderr)
        sys.exit(code)
    except KeyboardInterrupt:
        print("FAIL(interrupted)", file=sys.stderr)
        sys.exit(130)

"""Report T27 CI results without publishing test output or fixture data."""
import argparse
import json
import os
import subprocess
import tempfile


REQUIRED_FLUTTER_TEST = {
    "client": "提交后丢回执，列表即使已空仍可只读核对并重建离线成长",
    "legacy": "real T27 app ↔ T26 HTTP: assessment, first plan, completion and reopen",
}
EXIT_STATUS = {"PASS": 0, "FAIL": 1, "NOT RUN": 2, "SKIPPED": 3}


def flutter_receipt(lines, exit_code, required_test):
    names = {}
    completed = []
    suite_passed = False
    for line in lines:
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(event, dict):
            continue
        kind = event.get("type")
        if kind == "testStart":
            test = event["test"]
            names[test["id"]] = test["name"]
        elif kind == "testDone" and event.get("hidden") is False:
            completed.append(event)
        elif kind == "done":
            suite_passed = event.get("success") is True

    entered = bool(completed) or required_test in names.values()
    if entered and (exit_code != 0 or not suite_passed):
        return "FAIL"
    if any(t["result"] != "success" for t in completed):
        return "FAIL"
    if not any(names.get(t["testID"]) == required_test for t in completed):
        return "NOT RUN"
    if any(t["skipped"] is not False for t in completed):
        return "SKIPPED"
    return "PASS"


def history_receipt(lines, exit_code):
    # The launcher only emits this exact line after validating the Go and UI phases.
    if exit_code == 0:
        return "PASS" if any(line.rstrip("\n") == "RESULT: PASS" for line in lines) else "FAIL"
    return {2: "NOT RUN", 3: "SKIPPED"}.get(exit_code, "FAIL")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("check", choices=("client", "legacy", "history"))
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not args.command:
        parser.error("a check command is required")

    with tempfile.TemporaryFile(mode="w+", encoding="utf-8", errors="replace") as output:
        try:
            run = subprocess.run(args.command, stdout=output, stderr=subprocess.STDOUT, check=False)
        except OSError:
            receipt = "NOT RUN"
        else:
            output.seek(0)
            if args.check == "history":
                receipt = history_receipt(output, run.returncode)
            else:
                receipt = flutter_receipt(output, run.returncode, REQUIRED_FLUTTER_TEST[args.check])

    print(receipt)
    if destination := os.environ.get("GITHUB_OUTPUT"):
        with open(destination, "a", encoding="utf-8") as output:
            print(f"receipt={receipt}", file=output)
    return EXIT_STATUS[receipt]


if __name__ == "__main__":
    raise SystemExit(main())

"""Offline execution probe for the hosted T29 live-test script.

The probe copies the real shell entry point into a disposable project tree and
replaces every external command with a deterministic local stand-in.  It does
not start Docker, bind a socket, or contact an HTTP, PostgreSQL or Redis
service.  Its only claim is that ``live.sh`` propagates the command's exit
status while Flutter's file and name filters still select the live contract.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
TMP_ROOT = ROOT.parent / "tmp"
LIVE_SOURCE_PATH = ROOT / "app" / "tool" / "t29" / "live.sh"
PROXY_TEST_SOURCE_PATH = (
    ROOT / "app" / "tool" / "t29" / "proxy_isolation_test.dart"
)
LIVE_TEST_SOURCE_PATH = ROOT / "app" / "tool" / "t29" / "live_test.dart"
SENTINEL_SOURCE_PATH = ROOT / "app" / "tool" / "t29" / "with_sentinel_proxy.sh"


@dataclass(frozen=True)
class LiveProbeResult:
    returncode: int
    reached_live_test: bool
    violations: tuple[str, ...]
    selected_live_tests: tuple[str, ...] = ()
    selected_cases: tuple[str, ...] = ()
    stdout: str = ""
    stderr: str = ""

    def describe(self) -> str:
        details = [
            f"exit={self.returncode}",
            f"reached_live_test={self.reached_live_test}",
            f"selected_live_tests={self.selected_live_tests!r}",
            f"selected_cases={self.selected_cases!r}",
        ]
        if self.violations:
            details.append("violations=" + "; ".join(self.violations))
        if self.stderr.strip():
            details.append("stderr=" + self.stderr.strip()[-1200:])
        return ", ".join(details)


_FAKE_DOCKER = r"""#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do
  if [[ "$argument" == "port" ]]; then
    printf '127.0.0.1:54321\n'
    exit 0
  fi
done
exit 0
"""

_FAKE_OPENSSL = r"""#!/usr/bin/env bash
set -euo pipefail
printf '00112233445566778899aabbccddeeff0011223344556677\n'
"""

_FAKE_CURL = r"""#!/usr/bin/env bash
set -euo pipefail
printf '{"ok":true}\n'
"""

_FAKE_DART = r"""#!/usr/bin/env bash
set -euo pipefail
state=${T29_PROBE_STATE:?}
if [[ "${1:-}" == *proxy_sentinel.dart ]]; then
  printf '%s\n' "${3:?}" >"$state/hit_path"
  printf '54321\n' >"${2:?}"
  while :; do
    sleep 0.1
  done
fi
exit 0
"""

_FAKE_FLUTTER = r"""#!/usr/bin/env bash
set -euo pipefail
state=${T29_PROBE_STATE:?}
python3 "$state/test_selector.py" "$state" "$@"
exit "${T29_PROBE_FLUTTER_EXIT:-0}"
"""

# This is a deliberately small model of Flutter's test-file and name selection.
# It is not a Flutter replacement; it makes the probe observe whether a filter
# leaves at least one live_test.dart case selected.
_TEST_SELECTOR = r"""import json
import re
import sys
from pathlib import Path

state = Path(sys.argv[1])
args = sys.argv[2:]
(state / "flutter_args.json").write_text(json.dumps(args), encoding="utf-8")

name_filter = None
plain_filter = None
test_files = []
index = 0
while index < len(args):
    argument = args[index]
    if argument == "--name" and index + 1 < len(args):
        name_filter = args[index + 1]
        index += 2
        continue
    if argument.startswith("--name="):
        name_filter = argument.split("=", 1)[1]
        index += 1
        continue
    if argument == "--plain-name" and index + 1 < len(args):
        plain_filter = args[index + 1]
        index += 2
        continue
    if argument.startswith("--plain-name="):
        plain_filter = argument.split("=", 1)[1]
        index += 1
        continue
    if argument.endswith(".dart"):
        test_files.append(Path(argument))
    index += 1

test_pattern = re.compile(
    r"\btest\s*\(\s*(?P<quote>['\"])(?P<name>.*?)(?P=quote)",
    re.S,
)
selected = []
for test_file in test_files:
    try:
        source = test_file.read_text(encoding="utf-8")
    except OSError:
        continue
    for match in test_pattern.finditer(source):
        name = match.group("name")
        if plain_filter is not None and plain_filter not in name:
            continue
        if name_filter is not None:
            try:
                if re.search(name_filter, name) is None:
                    continue
            except re.error:
                continue
        selected.append({"path": test_file.as_posix(), "name": name})

(state / "selected_tests.json").write_text(
    json.dumps(selected), encoding="utf-8"
)
if any(Path(case["path"]).name == "proxy_isolation_test.dart" for case in selected):
    hit_path = state / "hit_path"
    if hit_path.is_file():
        target = hit_path.read_text(encoding="utf-8").strip()
        if target:
            with open(target, "a", encoding="utf-8") as hit_file:
                hit_file.write("hit\n")
"""


def _write_executable(path: Path, source: str) -> None:
    path.write_text(source, encoding="utf-8")
    path.chmod(0o755)


def _write_probe_project(root: Path, live_source: str) -> Path:
    app_tool = root / "app" / "tool" / "t29"
    dart_tool = root / "app" / ".dart_tool"
    bin_dir = root / "bin"
    state_dir = root / "state"
    scratch_dir = root / "scratch"
    for directory in (app_tool, dart_tool, bin_dir, state_dir, scratch_dir):
        directory.mkdir(parents=True, exist_ok=True)

    live_path = app_tool / "live.sh"
    live_path.write_text(live_source, encoding="utf-8")
    live_path.chmod(0o755)
    sentinel_path = app_tool / "with_sentinel_proxy.sh"
    shutil.copyfile(SENTINEL_SOURCE_PATH, sentinel_path)
    sentinel_path.chmod(0o755)
    shutil.copyfile(PROXY_TEST_SOURCE_PATH, app_tool / PROXY_TEST_SOURCE_PATH.name)
    shutil.copyfile(LIVE_TEST_SOURCE_PATH, app_tool / LIVE_TEST_SOURCE_PATH.name)

    (state_dir / "test_selector.py").write_text(
        _TEST_SELECTOR, encoding="utf-8"
    )
    (app_tool / "proxy_sentinel.dart").write_text(
        "void main(List<String> arguments) {}\n", encoding="utf-8"
    )
    (app_tool / "server_test.go").write_text(
        "package service\n", encoding="utf-8"
    )
    (dart_tool / "package_config.json").write_text(
        '{"configVersion":2,"packages":[]}\n', encoding="utf-8"
    )
    (root / "docker-compose.yml").write_text("services: {}\n", encoding="utf-8")

    fakes = {
        "docker": _FAKE_DOCKER,
        "openssl": _FAKE_OPENSSL,
        "curl": _FAKE_CURL,
        "dart": _FAKE_DART,
        "flutter": _FAKE_FLUTTER,
    }
    for name, source in fakes.items():
        _write_executable(bin_dir / name, source)
    return state_dir


def _read_json_list(path: Path) -> list[object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    return value if isinstance(value, list) else []


def run_t29_live_probe(
    *, live_source: str | None = None, flutter_exit: int = 0
) -> LiveProbeResult:
    """Execute the T29 entry point with deterministic, offline fake commands."""
    source = run_t29_live_probe.source if live_source is None else live_source
    TMP_ROOT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix="t29-live-probe-", dir=TMP_ROOT
    ) as temporary:
        root = Path(temporary)
        state_dir = _write_probe_project(root, source)
        scratch_dir = root / "scratch"
        environment = {
            "HOME": str(root),
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": f"{root / 'bin'}:{os.environ.get('PATH', '/usr/bin:/bin')}",
            "SHELL": "/bin/bash",
            "TMPDIR": str(scratch_dir),
            "T29_PROBE_FLUTTER_EXIT": str(flutter_exit),
            "T29_PROBE_STATE": str(state_dir),
        }
        try:
            completed = subprocess.run(
                ["bash", str(root / "app" / "tool" / "t29" / "live.sh")],
                cwd=root,
                env=environment,
                capture_output=True,
                text=True,
                timeout=20,
                check=False,
            )
            returncode = completed.returncode
            stdout = completed.stdout
            stderr = completed.stderr
        except subprocess.TimeoutExpired as error:
            returncode = 124
            raw_stdout = error.stdout or ""
            raw_stderr = error.stderr or ""
            stdout = (
                raw_stdout.decode("utf-8", errors="replace")
                if isinstance(raw_stdout, bytes)
                else raw_stdout
            )
            stderr = (
                raw_stderr.decode("utf-8", errors="replace")
                if isinstance(raw_stderr, bytes)
                else raw_stderr
            ) + "\nT29 live probe timed out"

        selected_cases: list[str] = []
        selected_live_tests: list[str] = []
        for item in _read_json_list(state_dir / "selected_tests.json"):
            if not isinstance(item, dict):
                continue
            path = item.get("path")
            name = item.get("name")
            if not isinstance(path, str) or not isinstance(name, str):
                continue
            selected_cases.append(f"{path}::{name}")
            if Path(path).name == LIVE_TEST_SOURCE_PATH.name:
                selected_live_tests.append(name)

        flutter_args = [
            item
            for item in _read_json_list(state_dir / "flutter_args.json")
            if isinstance(item, str)
        ]
        live_file_invoked = any(
            Path(argument).name == LIVE_TEST_SOURCE_PATH.name
            for argument in flutter_args
        )
        if selected_live_tests:
            violations: tuple[str, ...] = ()
        elif live_file_invoked:
            violations = ("selected no live_test.dart cases",)
        else:
            violations = ("live_test.dart was not invoked",)

        return LiveProbeResult(
            returncode=returncode,
            reached_live_test=bool(selected_live_tests),
            violations=violations,
            selected_live_tests=tuple(selected_live_tests),
            selected_cases=tuple(selected_cases),
            stdout=stdout,
            stderr=stderr,
        )


run_t29_live_probe.source = LIVE_SOURCE_PATH.read_text(encoding="utf-8")  # type: ignore[attr-defined]

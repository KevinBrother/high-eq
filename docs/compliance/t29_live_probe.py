"""Offline execution probe for the hosted T29 live-test script.

The probe copies the real shell entry point into a disposable project tree and
replaces every external command with a deterministic local stand-in.  It does
not start Docker, bind a socket, or contact an HTTP, PostgreSQL or Redis
service.  Its only claim is that ``live.sh`` reaches ``live_test.dart`` and
propagates that command's exit status.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
TMP_ROOT = ROOT.parent / "tmp"
LIVE_SOURCE_PATH = ROOT / "app" / "tool" / "t29" / "live.sh"
SENTINEL_SOURCE_PATH = ROOT / "app" / "tool" / "t29" / "with_sentinel_proxy.sh"


@dataclass(frozen=True)
class LiveProbeResult:
    returncode: int
    reached_live_test: bool
    violations: tuple[str, ...]
    stdout: str = ""
    stderr: str = ""

    def describe(self) -> str:
        details = [
            f"exit={self.returncode}",
            f"reached_live_test={self.reached_live_test}",
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
for argument in "$@"; do
  if [[ "$argument" == *tool/t29/live_test.dart ]]; then
    if [[ -s "$state/hit_path" ]]; then
      printf 'hit\n' >>"$(<"$state/hit_path")"
    fi
    printf 'reached\n' >"$state/reached"
    exit "${T29_PROBE_FLUTTER_EXIT:-0}"
  fi
done
exit 0
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

        reached_live_test = (state_dir / "reached").is_file()
        violations = (
            ()
            if reached_live_test
            else ("live_test.dart was not invoked",)
        )
        return LiveProbeResult(
            returncode=returncode,
            reached_live_test=reached_live_test,
            violations=violations,
            stdout=stdout,
            stderr=stderr,
        )


run_t29_live_probe.source = LIVE_SOURCE_PATH.read_text(encoding="utf-8")  # type: ignore[attr-defined]

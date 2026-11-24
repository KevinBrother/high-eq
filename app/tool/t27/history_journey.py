"""Run T27's formal Flutter growth journey against disposable native services."""
import argparse
import base64
from contextlib import ExitStack
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[3]


class NotRun(RuntimeError):
    """A local prerequisite prevented the journey from running."""


class Failed(RuntimeError):
    """An assertion or a bounded phase failed."""


def executable(value, label):
    path = Path(value).resolve() if value else None
    if not path or not path.is_file() or not os.access(path, os.X_OK):
        raise NotRun(f"{label}: executable unavailable ({value})")
    return path


def setup(args, env):
    pg = executable(args.pg_bin / "postgres", "postgres")
    initdb = executable(args.pg_bin / "initdb", "initdb")
    redis = executable(args.redis, "redis-server")
    go = executable(args.go, "go")
    flutter = executable(args.flutter, "flutter")
    flutter_root = flutter.parents[1]
    cache = flutter_root / "bin/cache"
    dart = executable(cache / "dart-sdk/bin/dart", "Flutter cached Dart")
    snapshot = cache / "flutter_tools.snapshot"
    if not snapshot.is_file():
        raise NotRun("Flutter tools snapshot unavailable, prepare the installed SDK first")
    env.update(
        FLUTTER_ROOT=str(flutter_root),
        FLUTTER_STORAGE_BASE_URL="http://127.0.0.1:0",
        PUB_HOSTED_URL="http://127.0.0.1:0",
    )
    try:
        version = subprocess.check_output(
            [pg, "--version"], env=env, text=True, timeout=5,
            stderr=subprocess.STDOUT,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise NotRun(f"postgres --version: {error}") from error
    if not re.search(r"\b17\.", version):
        raise NotRun(f"expected PostgreSQL 17, got {version.strip()}")
    try:
        go_version = subprocess.check_output(
            [go, "version"], env=env, text=True, timeout=5, stderr=subprocess.STDOUT,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise NotRun(f"go version: {error}") from error
    match = re.search(r"\bgo(\d+)\.(\d+)", go_version)
    if not match or tuple(map(int, match.groups())) < (1, 26):
        raise NotRun(f"expected Go 1.26 or newer, got {go_version.strip()}")
    for name in ("package_config.json", "package_graph.json"):
        if not (ROOT / "app/.dart_tool" / name).is_file():
            raise NotRun("prepare locked Flutter dependencies in app/ first")
    return pg, initdb, redis, go, dart, snapshot


def reserve(stack):
    listener = stack.enter_context(socket.socket())
    try:
        listener.bind(("127.0.0.1", 0))
    except OSError as error:
        raise NotRun(f"loopback bind: {error}") from error
    return listener


def stop(proc):
    # Kill the group as Flutter/Go and PostgreSQL can leave descendants.
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    proc.wait(timeout=5)


def spawn(stack, command, env, log_path, *, stdin=None):
    output = stack.enter_context(log_path.open("wb"))
    proc = subprocess.Popen(
        command, cwd=ROOT / "server", env=env, stdout=output,
        stderr=subprocess.STDOUT, stdin=stdin or subprocess.DEVNULL,
        start_new_session=True,
    )
    stack.callback(stop, proc)
    return proc


def await_ready(process, path, marker):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise NotRun(f"{path.stem} exited {process.returncode}, see {path}")
        if marker in path.read_bytes():
            return
        time.sleep(0.05)
    raise NotRun(f"{path.stem} exceeded its 20s readiness deadline, see {path}")


def run_services(args, state, logs, env):
    pg, initdb, redis, go, dart, snapshot = setup(args, env)
    with ExitStack() as owned:
        db_listener, cache_listener, ledger_listener = (reserve(owned) for _ in range(3))
        db_port, cache_port, ledger_port = (
            listener.getsockname()[1]
            for listener in (db_listener, cache_listener, ledger_listener)
        )
        print("PASS(prerequisite)", flush=True)
        db = state / "pg"
        password = secrets.token_hex(24)
        password_file = state / "initdb-password"
        password_file.write_text(password + "\n")
        init_log = logs / "initdb.log"
        try:
            with ExitStack() as startup:
                proc = spawn(startup, [
                    initdb, "-D", db, "-U", "postgres", "--no-locale",
                    "-E", "UTF8", "-A", "scram-sha-256", "--pwfile", password_file,
                ], env, init_log)
                if proc.wait(timeout=60) != 0:
                    raise NotRun(f"initdb exited {proc.returncode}, see {init_log}")
        except subprocess.TimeoutExpired as error:
            raise NotRun(f"initdb exceeded its 60s deadline, see {init_log}") from error
        finally:
            password_file.unlink()

        db_listener.close()
        pg_log = logs / "postgres.log"
        proc = spawn(owned, [
            pg, "-D", db, "-h", "127.0.0.1", "-p", str(db_port),
            "-c", "unix_socket_directories=", "-c", "statement_timeout=10000",
            "-c", "lock_timeout=5000",
        ], env, pg_log)
        await_ready(proc, pg_log, b"database system is ready to accept connections")

        redis_password = secrets.token_hex(24)
        for name, listener, port in (
            ("cache", cache_listener, cache_port),
            ("ledger", ledger_listener, ledger_port),
        ):
            directory = state / name
            directory.mkdir()
            config = directory / "redis.conf"
            text = (
                f"bind 127.0.0.1\nport {port}\nrequirepass {redis_password}\n"
                f'dir "{directory}"\nsave ""\n'
            )
            if name == "ledger":
                text += (
                    "appendonly yes\nappendfsync always\n"
                    "maxmemory-policy noeviction\naof-load-truncated no\n"
                )
            else:
                text += "appendonly no\n"
            config.write_text(text)
            with config.open("rb") as settings:
                listener.close()
                path = logs / f"{name}.log"
                proc = spawn(owned, [redis, "-"], env, path, stdin=settings)
                await_ready(proc, path, b"Ready to accept connections")
            config.unlink()
        print("PASS(services.disposable)", flush=True)

        env.update(
            APP_ENV="development",
            BACKUP_RETENTION_DAYS="45",
            FIELD_KEY_BASE64=base64.b64encode(secrets.token_bytes(32)).decode(),
            DATABASE_URL=f"postgres://postgres:{password}@127.0.0.1:{db_port}/postgres?sslmode=disable&connect_timeout=5",
            REDIS_URL=f"redis://:{redis_password}@127.0.0.1:{cache_port}/0",
            LEDGER_URL=f"redis://:{redis_password}@127.0.0.1:{ledger_port}/0",
            T19_DISPOSABLE="yes",
            T27_HISTORY_DISPOSABLE="yes",
            T27_HISTORY_APP=str(ROOT / "app"),
            T27_HISTORY_DART=str(dart),
            T27_HISTORY_FLUTTER_SNAPSHOT=str(snapshot),
        )
        run_test(go, env, logs / "journey.log")


def run_test(go, env, log):
    with ExitStack() as command:
        proc = spawn(command, [
            go, "test", "-mod=readonly", "-tags=integration", "-count=1",
            "-timeout=7m", "-v", "-run", "^TestT27HistoryJourney$", "./internal/service",
        ], env, log)
        try:
            status = proc.wait(timeout=540)
        except subprocess.TimeoutExpired:
            status = None

    lines = log.read_text(errors="replace").splitlines()
    for line in lines:
        if re.search(r"\b(?:BEGIN|PASS|FAIL|OBSERVED|NOT RUN)\(", line):
            print(line.strip(), flush=True)
    if status is None:
        stages = [m.group(1) for line in lines if (m := re.search(r"BEGIN\(([^)]+)\)", line))]
        raise Failed(f"{stages[-1] if stages else 'go.startup'} exceeded the runner deadline, see {log}")
    if any("NOT RUN(page.startup)" in line for line in lines):
        raise NotRun(f"page.startup did not reach the widget test, see {log}")
    if not any("BEGIN(service.runtime)" in line for line in lines):
        raise NotRun(f"Go did not enter the integration test (exit {status}), see {log}")
    if status != 0:
        raise Failed(f"journey exited {status}, see {log}")
    for receipt in ("PASS(page.journey)", "PASS(service.delete-cascade)", "PASS(journey)"):
        if not any(line.strip().endswith(receipt) for line in lines):
            raise Failed(f"missing {receipt}, see {log}")
    print("RESULT: PASS", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pg-bin", required=True, type=Path)
    parser.add_argument("--redis", required=True, type=Path)
    parser.add_argument("--go", default=shutil.which("go"))
    parser.add_argument("--flutter", default=shutil.which("flutter"))
    args = parser.parse_args()

    os.umask(0o077)
    logs_dir = ROOT / "build/t27-history"
    logs_dir.mkdir(parents=True, exist_ok=True)
    logs = Path(tempfile.mkdtemp(prefix="run-", dir=logs_dir))
    print(f"T27 logs: {logs}", flush=True)
    with tempfile.TemporaryDirectory(prefix="t27-state-", dir=logs) as directory:
        state = Path(directory)
        allowed = {"PATH", "HOME", "PUB_CACHE", "GOMODCACHE", "GOPATH"}
        env = {key: os.environ[key] for key in allowed if key in os.environ}
        env.setdefault("GOMODCACHE", str(Path.home() / "go/pkg/mod"))
        env.setdefault("PUB_CACHE", str(Path.home() / ".pub-cache"))
        env.update(
            GOCACHE=str(state / "go-cache"), TMPDIR=str(state),
            XDG_CONFIG_HOME=str(state / "config"),
            XDG_CACHE_HOME=str(state / "cache"), LANG="C", LC_ALL="C", CI="true",
            GOPROXY="off", GOSUMDB="off", GOTOOLCHAIN="local", GOENV="off", GOWORK="off",
            FLUTTER_SUPPRESS_ANALYTICS="true", DART_SUPPRESS_ANALYTICS="true",
        )
        run_services(args, state, logs, env)


if __name__ == "__main__":
    try:
        main()
    except (NotRun, OSError) as error:
        print(f"NOT RUN(prerequisite): {error}", file=sys.stderr)
        sys.exit(2)
    except Failed as error:
        print(f"FAIL(journey): {error}", file=sys.stderr)
        sys.exit(1)

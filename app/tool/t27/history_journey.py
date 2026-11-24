"""Run T27's formal Flutter growth journey against disposable native services."""
import argparse
import base64
from contextlib import ExitStack, contextmanager
from enum import Enum
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
REQUIRED_PHASES = (
    "service.runtime", "service.seed", "service.order-and-cursor",
    "service.reference-before", "service.contact-summary-before",
    "page.fixture", "page.lobby-order-and-back", "page.growth-history",
    "page.offline-without-deletion", "page.contact-deleted", "page.deleted-cache",
    "page.growth-recovery", "page.account-isolation", "page.journey", "page.runner",
    "service.delete-cascade", "service.contact-summary-after", "journey",
)
PHASE_PASS = re.compile(r"(?:\S+\.go:\d+:\s+)?PASS\(([a-z.-]+)\)")
PHASE_BEGIN = re.compile(r"(?:\S+\.go:\d+:\s+)?BEGIN\(([a-z.-]+)\)")
PHASE_FAILURE = re.compile(r"(?:\S+\.go:\d+:\s+)?FAIL\(([a-z.-]+)\)(?:$|: | after )")
STAGE_PREFIX = "T27_HISTORY_STAGE="


class Stage(str, Enum):
    WORKSPACE = "workspace"
    POSTGRES_BINARY = "postgres.binary"
    INITDB_BINARY = "postgres.initdb-binary"
    REDIS_BINARY = "redis.binary"
    GO_BINARY = "go.binary"
    FLUTTER_BINARY = "flutter.binary"
    FLUTTER_CACHE = "flutter.sdk-cache"
    POSTGRES_VERSION = "postgres.version"
    GO_VERSION = "go.version"
    FLUTTER_DEPENDENCIES = "flutter.dependencies"
    LOOPBACK = "loopback.reserve"
    INITDB = "postgres.initdb"
    POSTGRES_STARTUP = "postgres.startup"
    REDIS_CACHE_STARTUP = "redis.cache-startup"
    REDIS_LEDGER_STARTUP = "redis.ledger-startup"
    REDIS_LEDGER_DURABILITY = "redis.ledger-durability"
    SERVICE_CLEANUP = "services.cleanup"
    GO_STARTUP = "go.startup"
    PAGE_STARTUP = "page.startup"


REPORTABLE_STAGES = frozenset(stage.value for stage in Stage).union(REQUIRED_PHASES)


class JourneyError(RuntimeError):
    def __init__(self, message, *, stage=None):
        super().__init__(message)
        self.stage = stage


class NotRun(JourneyError):
    """A local prerequisite prevented the journey from running."""


class Failed(JourneyError):
    """An assertion or a bounded phase failed."""


class Skipped(JourneyError):
    """Go reported that the journey test was skipped."""


@contextmanager
def prerequisite(stage):
    try:
        yield
    except NotRun as error:
        if error.stage is None:
            error.stage = stage.value
        raise
    except (OSError, subprocess.SubprocessError) as error:
        raise NotRun(str(error), stage=stage.value) from error


def executable(value, label):
    # Redis multicall binaries select their mode from the invocation name.
    path = Path(value).absolute() if value else None
    if not path or not path.is_file() or not os.access(path, os.X_OK):
        raise NotRun(f"{label}: executable unavailable ({value})")
    return path


def setup(args, env):
    with prerequisite(Stage.POSTGRES_BINARY):
        pg = executable(args.pg_bin / "postgres", "postgres")
    with prerequisite(Stage.INITDB_BINARY):
        initdb = executable(args.pg_bin / "initdb", "initdb")
    with prerequisite(Stage.REDIS_BINARY):
        redis = executable(args.redis, "redis-server")
    with prerequisite(Stage.GO_BINARY):
        go = executable(args.go, "go")
    with prerequisite(Stage.FLUTTER_BINARY):
        flutter = executable(args.flutter, "flutter")
    with prerequisite(Stage.FLUTTER_CACHE):
        flutter_root = flutter.resolve().parents[1]
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
    with prerequisite(Stage.POSTGRES_VERSION):
        version = subprocess.check_output(
            [pg, "--version"], env=env, text=True, timeout=5,
            stderr=subprocess.STDOUT,
        )
        if not re.search(r"\b17\.", version):
            raise NotRun(f"expected PostgreSQL 17, got {version.strip()}")
    with prerequisite(Stage.GO_VERSION):
        go_version = subprocess.check_output(
            [go, "version"], env=env, text=True, timeout=5, stderr=subprocess.STDOUT,
        )
        match = re.search(r"\bgo(\d+)\.(\d+)", go_version)
        if not match or tuple(map(int, match.groups())) < (1, 26):
            raise NotRun(f"expected Go 1.26 or newer, got {go_version.strip()}")
    with prerequisite(Stage.FLUTTER_DEPENDENCIES):
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


def start_redis(redis, owned, listener, port, password, state, logs, env, *, ledger):
    name = "ledger" if ledger else "cache"
    stage = Stage.REDIS_LEDGER_STARTUP if ledger else Stage.REDIS_CACHE_STARTUP
    with prerequisite(stage):
        directory = state / name
        directory.mkdir()
        text = (
            f"bind 127.0.0.1\nport {port}\nrequirepass {password}\n"
            f'dir "{directory}"\nsave ""\n'
        )
        if ledger:
            text += (
                "appendonly yes\nappendfsync always\nno-appendfsync-on-rewrite no\n"
                "maxmemory-policy noeviction\naof-load-truncated no\n"
            )
        else:
            text += "appendonly no\n"
        with tempfile.TemporaryFile(dir=directory) as settings:
            settings.write(text.encode())
            settings.seek(0)
            listener.close()
            path = logs / f"{name}.log"
            proc = spawn(owned, [redis, "-"], env, path, stdin=settings)
            await_ready(proc, path, b"Ready to accept connections")


def redis_expect(connection, response, *args, lines):
    request = f"*{len(args)}\r\n".encode("ascii")
    for arg in args:
        data = arg.encode("ascii")
        request += f"${len(data)}\r\n".encode("ascii") + data + b"\r\n"
    connection.sendall(request)
    for expected in lines:
        if response.readline(256) != expected:
            raise NotRun(f"disposable ledger did not return the required {args[0]} acknowledgment")


def verify_ledger(port, password):
    with prerequisite(Stage.REDIS_LEDGER_DURABILITY):
        with (
            socket.create_connection(("127.0.0.1", port), timeout=5) as connection,
            connection.makefile("rb") as response,
        ):
            key = "t27:durability-probe"
            redis_expect(connection, response, "AUTH", password, lines=(b"+OK\r\n",))
            redis_expect(connection, response, "SET", key, "1", lines=(b"+OK\r\n",))
            # Match the production ledger's write and WAITAOF on the same connection.
            redis_expect(connection, response, "WAITAOF", "1", "0", "3000",
                         lines=(b"*2\r\n", b":1\r\n", b":0\r\n"))
            # The production ledger binds only to an empty database.
            redis_expect(connection, response, "DEL", key, lines=(b":1\r\n",))
    print("PASS(redis.ledger-durability)", flush=True)


def run_ledger_only(args, state, logs, env):
    with prerequisite(Stage.REDIS_BINARY):
        redis = executable(args.redis, "redis-server")
    with prerequisite(Stage.SERVICE_CLEANUP), ExitStack() as owned:
        with prerequisite(Stage.LOOPBACK):
            listener = reserve(owned)
            port = listener.getsockname()[1]
        password = secrets.token_hex(24)
        start_redis(redis, owned, listener, port, password, state, logs, env, ledger=True)
        verify_ledger(port, password)


def run_services(args, state, logs, env, *, run_journey=None):
    pg, initdb, redis, go, dart, snapshot = setup(args, env)
    with prerequisite(Stage.SERVICE_CLEANUP), ExitStack() as owned:
        with prerequisite(Stage.LOOPBACK):
            db_listener, cache_listener, ledger_listener = (reserve(owned) for _ in range(3))
            db_port, cache_port, ledger_port = (
                listener.getsockname()[1]
                for listener in (db_listener, cache_listener, ledger_listener)
            )
        print("PASS(prerequisite)", flush=True)
        db = state / "pg"
        password = secrets.token_hex(24)
        password_file = state / "initdb-password"
        init_log = logs / "initdb.log"
        with prerequisite(Stage.INITDB):
            password_file.write_text(password + "\n")
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

        with prerequisite(Stage.POSTGRES_STARTUP):
            db_listener.close()
            pg_log = logs / "postgres.log"
            proc = spawn(owned, [
                pg, "-D", db, "-h", "127.0.0.1", "-p", str(db_port),
                "-c", "unix_socket_directories=", "-c", "statement_timeout=10000",
                "-c", "lock_timeout=5000",
            ], env, pg_log)
            await_ready(proc, pg_log, b"database system is ready to accept connections")

        redis_password = secrets.token_hex(24)
        start_redis(redis, owned, cache_listener, cache_port, redis_password,
                    state, logs, env, ledger=False)
        start_redis(redis, owned, ledger_listener, ledger_port, redis_password,
                    state, logs, env, ledger=True)
        verify_ledger(ledger_port, redis_password)
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
        with prerequisite(Stage.GO_STARTUP):
            (run_journey or run_test)(go, env, logs / "journey.log")


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
        stage = next((match[1] for line in reversed(lines)
                      if (match := PHASE_BEGIN.fullmatch(line.strip()))
                      and match[1] in REQUIRED_PHASES), Stage.GO_STARTUP.value)
        raise Failed(f"{stage} exceeded the runner deadline, see {log}", stage=stage)
    if status == 0 and any(line.startswith("--- SKIP: TestT27HistoryJourney (") for line in lines):
        raise Skipped(f"Go skipped TestT27HistoryJourney, see {log}", stage=Stage.GO_STARTUP.value)
    if any("NOT RUN(page.startup)" in line for line in lines):
        raise NotRun(f"page.startup did not reach the widget test, see {log}",
                     stage=Stage.PAGE_STARTUP.value)
    if not any("BEGIN(service.runtime)" in line for line in lines):
        raise NotRun(f"Go did not enter the integration test (exit {status}), see {log}",
                     stage=Stage.GO_STARTUP.value)
    if status != 0:
        stage = next((match[1] for line in lines if (match := PHASE_FAILURE.match(line.strip()))
                      and match[1] in REQUIRED_PHASES), "journey")
        raise Failed(f"journey exited {status}, see {log}", stage=stage)
    passed = {match[1] for line in lines if (match := PHASE_PASS.fullmatch(line.strip()))}
    missing = [phase for phase in REQUIRED_PHASES if phase not in passed]
    if missing:
        receipts = ", ".join(f"PASS({phase})" for phase in missing)
        raise Failed(f"missing {receipts}, see {log}", stage=missing[0])
    if not any(line.startswith("--- PASS: TestT27HistoryJourney (") for line in lines):
        raise Failed(f"Go omitted the TestT27HistoryJourney pass, see {log}", stage="journey")
    print("RESULT: PASS", flush=True)


def isolated_environment(state):
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
    return env


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pg-bin", type=Path)
    parser.add_argument("--redis", required=True, type=Path)
    parser.add_argument("--ledger-only", action="store_true",
                        help="check local AOF acknowledgment on a fresh Redis without running the journey")
    parser.add_argument("--go", default=shutil.which("go"))
    parser.add_argument("--flutter", default=shutil.which("flutter"))
    args = parser.parse_args()
    if not args.ledger_only and args.pg_bin is None:
        parser.error("--pg-bin is required for the full journey")

    os.umask(0o077)
    logs_dir = ROOT / "build/t27-history"
    with prerequisite(Stage.WORKSPACE), ExitStack() as workspace:
        logs_dir.mkdir(parents=True, exist_ok=True)
        logs = Path(tempfile.mkdtemp(prefix="run-", dir=logs_dir))
        directory = workspace.enter_context(tempfile.TemporaryDirectory(prefix="t27-state-", dir=logs))
        print(f"T27 logs: {logs}", flush=True)
        state = Path(directory)
        env = isolated_environment(state)
        if args.ledger_only:
            run_ledger_only(args, state, logs, env)
        else:
            run_services(args, state, logs, env)


if __name__ == "__main__":
    try:
        main()
    except JourneyError as error:
        status, exit_code = {Failed: ("FAIL", 1), NotRun: ("NOT RUN", 2),
                             Skipped: ("SKIPPED", 3)}[type(error)]
        print(f"{status}({error.stage}): {error}", file=sys.stderr)
        print(f"{STAGE_PREFIX}{error.stage}", file=sys.stderr)
        sys.exit(exit_code)

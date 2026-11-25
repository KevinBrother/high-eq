#!/usr/bin/env python3
"""Fail-closed primitives for the independent GitHub-hosted T34 proof.

This module is intentionally independent from the fixed staging and production
release entry points. The workflow is manual-only; every command below is also
usable by offline contract tests without contacting a Docker daemon.
"""
from __future__ import annotations

from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import tempfile
import time
from typing import Callable, Iterable, Mapping


MIN_WAIT_SECONDS = 600
MAX_WAIT_SECONDS = 7200
DEFAULT_MIN_FREE_BYTES = 10 * 1024 ** 3
OWNER_TOKEN = re.compile(r'[0-9a-f]{48}')
DEFAULT_SOCKETS = (
    '/var/run/docker.sock',
    '/run/docker.sock',
    str(Path.home() / '.docker/run/docker.sock'),
)
FORBIDDEN_KEY_PARTS = (
    'token', 'password', 'credential', 'challenge', 'secret', 'field_key', 'webhook',
)
PUBLIC_RECEIPT_KEYS = frozenset({
    'version', 'result', 'mode', 'non_production', 'trigger', 'repository', 'ref',
    'sha', 'actor', 'run_id', 'run_attempt', 'initial_revision', 'update_revision',
    'previous_revision', 'runner', 'limits', 'engine', 'wait', 'processes', 'storage',
    'services', 'resources', 'cleanup', 'stage', 'error', 'verification',
})


class ProofError(ValueError):
    """A fixed, non-sensitive refusal from the hosted proof boundary."""


def require(condition: bool, message: str = 'hosted proof boundary refused') -> None:
    if not condition:
        raise ProofError(message)


def authorize_dispatch(environ: Mapping[str, str]) -> dict:
    """Require a project-owner manual dispatch of trusted main on a hosted runner."""
    wanted = {
        'CI': 'true',
        'GITHUB_ACTIONS': 'true',
        'RUNNER_ENVIRONMENT': 'github-hosted',
        'GITHUB_EVENT_NAME': 'workflow_dispatch',
        'GITHUB_REF': 'refs/heads/main',
    }
    for key, value in wanted.items():
        require(environ.get(key) == value, 'manual hosted dispatch required')
    actor = environ.get('GITHUB_ACTOR', '')
    owner = environ.get('GITHUB_REPOSITORY_OWNER', '')
    require(bool(actor) and actor == owner, 'repository owner authorization required')
    return {
        'event': environ['GITHUB_EVENT_NAME'],
        'ref': environ['GITHUB_REF'],
        'actor': actor,
        'owner': owner,
    }


def validate_wait_seconds(value: str) -> int:
    """Accept only an integer real wait within the explicitly bounded window."""
    require(isinstance(value, str) and re.fullmatch(r'[0-9]+', value) is not None,
            'proof wait must be an integer')
    seconds = int(value)
    require(MIN_WAIT_SECONDS <= seconds <= MAX_WAIT_SECONDS,
            'proof wait must be between 600 and 7200 seconds')
    return seconds


def real_wait(seconds: int, *, sleep: Callable[[float], None] = time.sleep,
              monotonic: Callable[[], float] = time.monotonic) -> dict:
    """Wait with the real clock and refuse if monotonic time did not advance."""
    require(type(seconds) is int and MIN_WAIT_SECONDS <= seconds <= MAX_WAIT_SECONDS,
            'proof wait must be between 600 and 7200 seconds')
    started = monotonic()
    sleep(seconds)
    ended = monotonic()
    elapsed = ended - started
    require(elapsed >= seconds, 'proof wait did not elapse')
    return {'requested_seconds': seconds, 'elapsed_seconds': elapsed}


def validate_engine_socket(host: str, run_root: Path) -> Path:
    """Require a non-default, absolute, non-symlinked Unix socket under this run."""
    root = Path(run_root)
    require(root.is_absolute() and not root.is_symlink(), 'proof run root invalid')
    resolved_root = root.resolve(strict=False)
    require(root == resolved_root, 'proof run root must not traverse links')
    require(isinstance(host, str) and host.startswith('unix://'), 'Unix engine socket required')
    raw = host[len('unix://'):]
    require(raw.startswith('/') and not any(ch in raw for ch in '\x00\r\n?#'),
            'absolute Unix engine socket required')
    socket = Path(raw)
    resolved = socket.resolve(strict=False)
    require(socket == resolved, 'engine socket must not traverse links')
    defaults = {str(Path(value).resolve(strict=False)) for value in DEFAULT_SOCKETS}
    require(str(socket) not in defaults and str(resolved) not in defaults,
            'default Docker socket forbidden')
    try:
        common = os.path.commonpath((str(resolved), str(resolved_root)))
    except ValueError as exc:
        raise ProofError('engine socket outside proof run') from exc
    require(common == str(resolved_root) and resolved != resolved_root,
            'engine socket must be run-owned')
    return socket


def validate_subid_ranges(text: str, user: str, uid: int, *, minimum: int = 65536) -> int:
    """Return the matching subordinate-ID count, failing closed on malformed data."""
    require(isinstance(text, str) and bool(user), 'subordinate ID file invalid')
    total = 0
    found = False
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        fields = line.split(':')
        require(len(fields) == 3, 'subordinate ID entry malformed')
        identity, start, count = fields
        require(re.fullmatch(r'[0-9]+', start) is not None and
                re.fullmatch(r'[0-9]+', count) is not None,
                'subordinate ID entry malformed')
        if identity in (user, str(uid)):
            found = True
            total += int(count)
    require(found and total >= minimum, 'insufficient subordinate ID range')
    return total


def require_free_bytes(available: int, minimum: int) -> int:
    require(type(available) is int and type(minimum) is int and minimum > 0,
            'disk telemetry invalid')
    require(available >= minimum, 'insufficient free disk for isolated proof')
    return available


def write_private_json(path: Path, value: object) -> None:
    """Atomically write owner-only JSON using an fsynced sibling replacement."""
    destination = Path(path)
    parent = destination.parent
    require(destination.is_absolute(), 'private JSON path must be absolute')
    parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    require(not parent.is_symlink(), 'private JSON directory must not be a link')
    if destination.exists() or destination.is_symlink():
        require(destination.is_file() and not destination.is_symlink(),
                'private JSON destination invalid')
    payload = (json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True) + '\n').encode()
    descriptor = None
    temporary = None
    try:
        descriptor, temporary = tempfile.mkstemp(prefix='.t34-', dir=parent)
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, 'wb') as output:
            descriptor = None
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, destination)
        temporary = None
        os.chmod(destination, 0o600)
        directory = os.open(parent, os.O_RDONLY | getattr(os, 'O_DIRECTORY', 0))
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if temporary is not None:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass


def load_private_json(path: Path, *, max_bytes: int = 1024 * 1024) -> dict:
    """Read only a regular, owner-only file owned by this process's user."""
    source = Path(path)
    require(source.is_absolute() and not source.is_symlink(), 'private JSON path invalid')
    info = source.stat()
    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid(),
            'private JSON owner invalid')
    require(stat.S_IMODE(info.st_mode) & 0o077 == 0, 'private JSON mode invalid')
    require(0 < info.st_size <= max_bytes, 'private JSON size invalid')
    try:
        value = json.loads(source.read_bytes())
    except (OSError, UnicodeDecodeError, ValueError) as exc:
        raise ProofError('private JSON invalid') from exc
    require(isinstance(value, dict), 'private JSON object required')
    return value


def _walk(value):
    if isinstance(value, dict):
        for key, item in value.items():
            yield key, item
            yield from _walk(item)
    elif isinstance(value, list):
        for item in value:
            yield from _walk(item)


def enforce_public_receipt(receipt: Mapping, *, forbidden_values: Iterable[str] = ()) -> None:
    """Reject sensitive keys, unknown top-level fields and echoed private values."""
    require(isinstance(receipt, Mapping), 'public receipt must be an object')
    unknown = set(receipt) - PUBLIC_RECEIPT_KEYS
    require(not unknown, 'public receipt contains an unknown field')
    secrets = tuple(item for item in forbidden_values if isinstance(item, str) and item)
    for key, value in _walk(dict(receipt)):
        if isinstance(key, str):
            lowered = key.lower()
            require(not any(part in lowered for part in FORBIDDEN_KEY_PARTS),
                    'public receipt contains a sensitive field')
        if isinstance(value, str) and any(secret in value for secret in secrets):
            raise ProofError('public receipt echoes a private value')


@dataclass(frozen=True)
class WorkerResult:
    pid: int
    returncode: int
    elapsed_seconds: float
    receipt: dict
    stdout_log: Path
    stderr_log: Path


class WorkerFailure(ProofError):
    def __init__(self, message: str, *, returncode: int | None, pid: int,
                 stdout_log: Path, stderr_log: Path, timed_out: bool = False,
                 receipt: dict | None = None):
        super().__init__(message)
        self.returncode = returncode
        self.pid = pid
        self.stdout_log = stdout_log
        self.stderr_log = stderr_log
        self.timed_out = timed_out
        self.receipt = receipt


def _private_log(path: Path):
    path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    os.fchmod(descriptor, 0o600)
    return os.fdopen(descriptor, 'wb')


def _terminate_group(process: subprocess.Popen) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)


def run_worker_process(command: list[str], receipt_path: Path, *, log_prefix: Path,
                       timeout: float, env: Mapping[str, str] | None = None) -> WorkerResult:
    """Run one stage in a new process; retain private logs, expose only its receipt."""
    receipt_path = Path(receipt_path)
    stdout_log = Path(str(log_prefix) + '.stdout.log')
    stderr_log = Path(str(log_prefix) + '.stderr.log')
    started = time.monotonic()
    with _private_log(stdout_log) as stdout, _private_log(stderr_log) as stderr:
        child_env = None if env is None else dict(env)
        try:
            process = subprocess.Popen(
                command, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
                env=child_env, start_new_session=True, close_fds=True,
            )
        except OSError as exc:
            raise WorkerFailure('proof worker could not start', returncode=None, pid=0,
                                stdout_log=stdout_log, stderr_log=stderr_log) from exc
        try:
            returncode = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired as exc:
            _terminate_group(process)
            raise WorkerFailure('proof worker timed out', returncode=None, pid=process.pid,
                                stdout_log=stdout_log, stderr_log=stderr_log,
                                timed_out=True) from exc
    elapsed = time.monotonic() - started
    if returncode != 0:
        failed_receipt = None
        try:
            failed_receipt = load_private_json(receipt_path)
        except (OSError, ProofError):
            pass
        raise WorkerFailure('proof worker failed', returncode=returncode, pid=process.pid,
                            stdout_log=stdout_log, stderr_log=stderr_log,
                            receipt=failed_receipt)
    try:
        receipt = load_private_json(receipt_path)
    except (OSError, ProofError) as exc:
        raise WorkerFailure('proof worker receipt unavailable', returncode=returncode,
                            pid=process.pid, stdout_log=stdout_log,
                            stderr_log=stderr_log) from exc
    return WorkerResult(process.pid, returncode, elapsed, receipt, stdout_log, stderr_log)


if __name__ == '__main__':
    raise SystemExit('hosted_proof.py is a library entry; use run_hosted_proof.sh')

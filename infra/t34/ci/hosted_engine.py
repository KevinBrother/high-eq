#!/usr/bin/env python3
"""Private rootless Docker engine lifecycle for one hosted proof job.

No function in this module discovers a host daemon.  The engine is launched from
the current GitHub-hosted job user with a private home, config, runtime, data and
execution root, and one explicit Unix socket below the job's private run root.
Missing rootless prerequisites are reported as unverified; host policy is never
disabled and privileged container-in-Docker is not used as a fallback.
"""
from __future__ import annotations

from dataclasses import dataclass
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import signal
import stat
import subprocess
import tempfile
import time
from typing import Callable, Mapping

from .hosted_proof import (DEFAULT_MIN_FREE_BYTES, ProofError, require,
                           validate_engine_socket, validate_subid_ranges)

ENGINE_ID = re.compile(r'(?:[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-'
                       r'[89ab][0-9a-f]{3}-[0-9a-f]{12}|[0-9a-f]{64})')
ROOTLESS_SECURITY_OPTION = 'name=rootless'
USERNS_SECURITY_OPTION = 'name=userns'
REQUIRED_COMMANDS = (
    'docker', 'dockerd-rootless.sh', 'rootlesskit', 'newuidmap', 'newgidmap',
    'slirp4netns', 'fuse-overlayfs',
)


class PrerequisiteUnavailable(ProofError):
    """A required rootless prerequisite could not be proven on this VM."""


class EngineStartError(ProofError):
    """The private daemon did not reach the bound rootless identity."""


@dataclass(frozen=True)
class EnginePaths:
    root: Path
    home: Path
    config: Path
    runtime: Path
    data_root: Path
    exec_root: Path
    socket: Path
    pidfile: Path
    log: Path

    @property
    def host(self) -> str:
        return 'unix://' + str(self.socket)


def engine_paths(root: Path) -> EnginePaths:
    """Return the one compact layout shared by the coordinator and its workers."""
    root = Path(root)
    return EnginePaths(
        root=root,
        home=root / 'h',
        config=root / 'c',
        runtime=root / 'r',
        data_root=root / 'd',
        exec_root=root / 'x',
        socket=root / 'r' / 's',
        pidfile=root / 'r' / 'p',
        log=root / 'l',
    )


def require_engine_layout(paths: EnginePaths, *, host: str | None = None,
                          uid: int | None = None) -> EnginePaths:
    """Require the exact short layout and a non-default socket owned by this run."""
    uid = os.geteuid() if uid is None else uid
    require(isinstance(paths, EnginePaths), 'private engine layout invalid')
    root = paths.root
    require(root.is_absolute() and root == root.resolve(strict=False), 'private engine layout invalid')
    info = root.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == uid and
            stat.S_IMODE(info.st_mode) == 0o700, 'private engine root owner invalid')
    require(paths == engine_paths(root), 'private engine layout invalid')
    require(host is None or host == paths.host, 'private engine layout invalid')
    require(len(os.fsencode(paths.socket)) < 104, 'private engine socket path too long')
    validate_engine_socket(paths.host, root)
    return paths


@dataclass
class EngineRuntime:
    process: subprocess.Popen
    paths: EnginePaths
    engine_id: str
    server_version: str
    stopped: bool = False

    def public_receipt(self) -> dict:
        return {
            'started': True,
            'stopped': self.stopped,
            'rootless': True,
            'engine_id': self.engine_id,
            'server_version': self.server_version,
            'socket': 'run-owned',
            'data_root': 'run-owned',
        }

    def assert_alive(self) -> None:
        require(not self.stopped and self.process.poll() is None,
                'private rootless engine exited unexpectedly')

    def stop(self) -> bool:
        if self.stopped:
            return True
        if self.process.poll() is None:
            try:
                os.killpg(self.process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                self.process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(self.process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                try:
                    self.process.wait(timeout=10)
                except subprocess.TimeoutExpired as exc:
                    raise EngineStartError('private rootless engine did not stop') from exc
        if self.process.poll() is None:
            raise EngineStartError('private rootless engine did not stop')
        # The socket is private, but unlink only the exact owned socket object.
        try:
            info = self.paths.socket.lstat()
        except FileNotFoundError:
            pass
        else:
            require(not stat.S_ISLNK(info.st_mode) and stat.S_ISSOCK(info.st_mode) and
                    info.st_uid == os.geteuid(), 'private engine socket ownership changed')
            self.paths.socket.unlink()
        self.stopped = True
        return True


def build_paths(root: Path, *, uid: int | None = None) -> EnginePaths:
    """Create and bind one owner-only directory tree for this proof run."""
    uid = os.geteuid() if uid is None else uid
    root = Path(root)
    require(root.is_absolute() and not root.is_symlink(), 'private engine root invalid')
    if root.exists():
        info = root.stat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == uid and
                stat.S_IMODE(info.st_mode) & 0o077 == 0, 'private engine root owner invalid')
    else:
        root.mkdir(parents=True, mode=0o700)
    root = root.resolve(strict=True)
    return require_engine_layout(engine_paths(root), uid=uid)


def _default_read_text(path: str) -> str:
    return Path(path).read_text(encoding='utf-8')


def preflight(
    paths: EnginePaths,
    *,
    environ: Mapping[str, str] | None = None,
    which: Callable[[str], str | None] = shutil.which,
    disk_usage: Callable[[Path], shutil._ntuple_diskusage] = shutil.disk_usage,
    read_text: Callable[[str], str] = _default_read_text,
    uid: int | None = None,
    username: str | None = None,
    system: str | None = None,
) -> dict:
    """Fail closed before any daemon exists when rootless prerequisites are unclear."""
    environ = os.environ if environ is None else environ
    uid = os.geteuid() if uid is None else uid
    system = os.uname().sysname if system is None else system
    require(system == 'Linux', 'hosted proof requires Linux')
    require(type(uid) is int and uid > 0, 'rootless proof requires an unprivileged user')
    require(paths.root.stat().st_uid == uid, 'private engine root owner mismatch')

    try:
        username = pwd.getpwuid(uid).pw_name if username is None else username
    except KeyError as exc:
        raise PrerequisiteUnavailable('rootless account unavailable') from exc
    require(isinstance(username, str) and bool(username), 'rootless account unavailable')

    missing = [name for name in REQUIRED_COMMANDS if not which(name)]
    require(not missing, 'rootless prerequisites unavailable')

    try:
        subuid = read_text('/etc/subuid')
        subgid = read_text('/etc/subgid')
        validate_subid_ranges(subuid, username, uid)
        validate_subid_ranges(subgid, username, uid)
    except (OSError, ProofError) as exc:
        raise PrerequisiteUnavailable('subordinate ID ranges unavailable') from exc

    def optional_value(path: str) -> str | None:
        try:
            return read_text(path).strip()
        except FileNotFoundError:
            return None
        except OSError as exc:
            raise PrerequisiteUnavailable('rootless kernel prerequisite unreadable') from exc

    clone = optional_value('/proc/sys/kernel/unprivileged_userns_clone')
    require(clone in (None, '1'), 'unprivileged user namespaces unavailable')
    maximum = optional_value('/proc/sys/user/max_user_namespaces')
    require(maximum is None or (maximum.isdigit() and int(maximum) > 0),
            'user namespace limit unavailable')
    restriction = optional_value('/proc/sys/kernel/apparmor_restrict_unprivileged_userns')
    require(restriction in (None, '0'), 'AppArmor blocks unprivileged user namespaces')

    try:
        controllers = set(read_text('/sys/fs/cgroup/cgroup.controllers').split())
    except OSError as exc:
        raise PrerequisiteUnavailable('cgroup v2 delegation unavailable') from exc
    require({'cpu', 'memory', 'pids'} <= controllers, 'cgroup v2 controllers unavailable')

    available = disk_usage(paths.root).free
    require(available >= DEFAULT_MIN_FREE_BYTES, 'insufficient free disk for isolated proof')
    return {
        'user': username,
        'uid': uid,
        'subordinate_ids': 'verified',
        'user_namespaces': 'verified',
        'cgroup_v2': 'verified',
        'available_bytes': available,
        'minimum_free_bytes': DEFAULT_MIN_FREE_BYTES,
    }


def _engine_env(paths: EnginePaths, base: Mapping[str, str]) -> dict[str, str]:
    """Allowlist the inherited environment; never forward credentials or Docker endpoints."""
    path = base.get('PATH', '/usr/local/bin:/usr/bin:/bin')
    env = {
        'PATH': path,
        'HOME': str(paths.home),
        'XDG_RUNTIME_DIR': str(paths.runtime),
        'XDG_CONFIG_HOME': str(paths.config),
        'XDG_DATA_HOME': str(paths.home / '.local' / 'share'),
        'DOCKER_CONFIG': str(paths.config),
        'TMPDIR': str(paths.runtime),
        'DOCKER_HOST': paths.host,
        'DOCKERD_ROOTLESS_ROOTLESSKIT_STATE_DIR': str(paths.runtime / 'rootlesskit'),
    }
    for name in ('LANG', 'LC_ALL'):
        if name in base:
            env[name] = base[name]
    return env


def _prepare_paths(paths: EnginePaths) -> None:
    require_engine_layout(paths)
    for directory in (paths.home, paths.config, paths.runtime, paths.data_root,
                      paths.exec_root, paths.runtime / 'rootlesskit'):
        if directory.exists():
            raise PrerequisiteUnavailable('private engine path was not empty')
        directory.mkdir(parents=True, mode=0o700)
        directory.chmod(0o700)
    require(not paths.socket.exists() and not paths.pidfile.exists() and not paths.log.exists(),
            'private engine path collision')
    validate_engine_socket(paths.host, paths.root)


def parse_rootless_security_options(raw: str) -> tuple[str, ...]:
    """Parse Docker's raw SecurityOptions JSON and require exact rootless evidence."""
    require(type(raw) is str, 'security options evidence invalid')
    try:
        options = json.loads(raw)
    except (TypeError, ValueError) as exc:
        raise ProofError('security options evidence invalid') from exc
    require(type(options) is list and all(type(option) is str for option in options),
            'security options evidence invalid')
    require(ROOTLESS_SECURITY_OPTION in options, 'rootless security option missing')
    require(USERNS_SECURITY_OPTION not in options, 'user namespace security option is not rootless')
    return tuple(options)


def _docker_info(paths: EnginePaths, env: Mapping[str, str], *, timeout: float = 15) -> dict | None:
    try:
        require_engine_layout(paths)
    except (OSError, ProofError):
        return None
    command = [
        shutil.which('docker') or 'docker', '--host', paths.host, 'info', '--format',
        '{{.ID}}\t{{.ServerVersion}}\t{{json .SecurityOptions}}\t{{.DockerRootDir}}',
    ]
    try:
        result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, env=dict(env), timeout=timeout,
                                check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode:
        return None
    try:
        identifier, version, security_raw, root = result.stdout.decode().strip().split('\t')
        parse_rootless_security_options(security_raw)
    except (UnicodeDecodeError, ValueError, ProofError):
        return None
    if not ENGINE_ID.fullmatch(identifier) or not version:
        return None
    try:
        actual_root = Path(root).resolve(strict=False)
    except (OSError, RuntimeError):
        return None
    if actual_root != paths.data_root.resolve(strict=False):
        return None
    return {'engine_id': identifier, 'server_version': version, 'rootless': True}


def _check_private_socket(paths: EnginePaths, uid: int) -> None:
    info = paths.socket.lstat()
    require(stat.S_ISSOCK(info.st_mode) and not stat.S_ISLNK(info.st_mode), 'engine socket invalid')
    require(info.st_uid == uid, 'engine socket owner invalid')
    require(stat.S_IMODE(info.st_mode) & 0o007 == 0, 'engine socket is world-accessible')


def start_engine(
    paths: EnginePaths,
    *,
    environ: Mapping[str, str] | None = None,
    popen: Callable[..., subprocess.Popen] = subprocess.Popen,
    info: Callable[[EnginePaths, Mapping[str, str]], dict | None] = _docker_info,
    sleep: Callable[[float], None] = time.sleep,
    monotonic: Callable[[], float] = time.monotonic,
    ready_timeout: float = 120,
    uid: int | None = None,
) -> EngineRuntime:
    """Start and bind a new rootless daemon, or stop it and fail closed."""
    environ = os.environ if environ is None else environ
    uid = os.geteuid() if uid is None else uid
    preflight(paths, environ=environ, uid=uid)
    _prepare_paths(paths)
    executable = shutil.which('dockerd-rootless.sh') or 'dockerd-rootless.sh'
    env = _engine_env(paths, environ)
    log_descriptor = os.open(paths.log, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    process = None
    try:
        with os.fdopen(log_descriptor, 'wb') as output:
            process = popen(
                [
                    executable,
                    '--data-root', str(paths.data_root),
                    '--exec-root', str(paths.exec_root),
                    '--pidfile', str(paths.pidfile),
                    '--host', paths.host,
                    '--rootless',
                    '--iptables=false',
                    '--ip6tables=false',
                ],
                stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
                env=env, start_new_session=True, close_fds=True,
            )
        deadline = monotonic() + ready_timeout
        observed = None
        while monotonic() < deadline:
            if process.poll() is not None:
                raise EngineStartError('private rootless engine exited during startup')
            if paths.socket.exists():
                try:
                    _check_private_socket(paths, uid)
                except (OSError, ProofError):
                    pass
                else:
                    observed = info(paths, env)
                    if observed is not None:
                        break
            sleep(0.5)
        require(observed is not None, 'private rootless engine did not become ready')
        return EngineRuntime(process, paths, observed['engine_id'], observed['server_version'])
    except BaseException:
        if process is not None and process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pass
        raise


def create_engine_root(parent: Path | None = None) -> Path:
    """Create a 0700 private parent directory without following a caller path link."""
    parent = Path(tempfile.gettempdir()) if parent is None else Path(parent)
    require(parent.is_absolute() and parent.is_dir() and not parent.is_symlink(),
            'private engine parent invalid')
    return Path(tempfile.mkdtemp(prefix='t34-hosted-engine-', dir=parent))

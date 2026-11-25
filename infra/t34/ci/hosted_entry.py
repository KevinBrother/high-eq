#!/usr/bin/env python3
"""Coordinate one isolated, owner-dispatched GitHub-hosted T34 proof.

This module is the trust boundary between the workflow environment and three
separate stage workers.  It validates the dispatch before touching git or
Docker, owns the private rootless engine and run directory, and publishes only a
small, explicitly schema-checked summary.  Worker output and receipts remain
private and are deleted with the run directory.
"""
from __future__ import annotations

from dataclasses import dataclass, field
import os
from pathlib import Path
import re
import secrets
import shutil
import stat
import subprocess
import sys
import tempfile
from typing import Callable, Mapping

from . import hosted_contract
from . import hosted_engine
from . import hosted_proof as proof
import release_approval


REPO_ROOT = Path(__file__).resolve().parents[3]
DEFAULT_STAGE_SCRIPT = REPO_ROOT / 'infra/t34/ci/hosted_stage.py'
STAGE_TIMEOUT_SECONDS = 1800
SHA = re.compile(r'[0-9a-f]{40}')
RUN_ID = re.compile(r'[0-9a-f]{24}')
STAGES = ('init', 'update', 'negative')
FAILURE_RESULTS = frozenset({'proof-fail', 'not-executed'})
PUBLIC_ERRORS = frozenset({
    'invalid-input', 'git-verification-failed', 'engine-start-failed',
    'rootless-prerequisites-unavailable', 'isolated-engine-not-empty',
    'stage-failed', 'engine-unavailable', 'engine-not-rootless',
    'engine-identity-changed', 'resource-retention-failed',
    'inventory-invalid', 'wait-not-elapsed', 'cleanup-failed',
    'receipt-validation-failed', 'internal-error',
})


@dataclass(frozen=True)
class HostedProofOutcome:
    exit_code: int


@dataclass(frozen=True)
class _Inputs:
    dispatch: dict
    trusted_sha: str
    initial_sha: str
    update_sha: str
    previous_sha: str
    decoder_approvals: Path
    wait_seconds: int
    output_dir: Path
    proof_run_id: str


@dataclass(frozen=True)
class _Inventory:
    volumes: frozenset[str]
    running: int
    stopped: int


@dataclass
class _Evidence:
    stages_completed: int = 0
    wait: dict = field(default_factory=dict)
    initial_volumes: int = 0
    retained_volumes: int = 0
    original_volumes_retained: bool = False
    init_running: int = 0
    update_running: int = 0
    negative_stopped: int = 0
    engine_started: bool = False
    engine_rootless: bool = False
    engine_identity_verified: bool = False
    git_verified: bool = False
    resources_verified: bool = False
    engine_stopped: bool = False
    private_work_removed: bool = False


class _CoordinatorFailure(Exception):
    def __init__(self, stage: str, error: str, *, result: str = 'proof-fail'):
        super().__init__(error)
        self.stage = stage
        self.error = error
        self.result = result


def _require(condition: bool, message: str) -> None:
    proof.require(condition, message)


def _minimal_env(environ: Mapping[str, str]) -> dict[str, str]:
    """Return a credential-free base environment for local helper processes."""
    result = {
        'PATH': environ.get('PATH', '/usr/local/bin:/usr/bin:/bin'),
        'PYTHONDONTWRITEBYTECODE': '1',
        'PYTHONUNBUFFERED': '1',
        'GIT_CONFIG_NOSYSTEM': '1',
        'GIT_CONFIG_GLOBAL': os.devnull,
    }
    for name in ('LANG', 'LC_ALL'):
        if name in environ:
            result[name] = environ[name]
    return result


def _parse_inputs(environ: Mapping[str, str]) -> _Inputs:
    """Validate every caller-controlled value before git, engine, or workers."""
    dispatch = proof.authorize_dispatch(environ)
    trusted = environ.get('T34_TRUSTED_MAIN_SHA', '')
    github_sha = environ.get('GITHUB_SHA', '')
    _require(SHA.fullmatch(trusted) is not None, 'trusted main SHA invalid')
    _require(github_sha == trusted, 'workflow is not bound to trusted main')
    revisions = []
    for name in ('INITIAL', 'UPDATE', 'PREVIOUS'):
        value = environ.get(f'T34_PROOF_{name}_REVISION', '')
        _require(SHA.fullmatch(value) is not None, 'proof revision invalid')
        revisions.append(value)
    initial, update, previous = revisions
    _require(initial != update, 'initial and update revisions must differ')
    approvals_raw = environ.get(release_approval.APPROVALS_ENV, '')
    _require(bool(approvals_raw), 'decoder approval path required')
    approvals = Path(approvals_raw)
    try:
        document = release_approval.load_document(approvals, (REPO_ROOT,))
    except (OSError, ValueError) as error:
        raise proof.ProofError('decoder approval invalid') from error
    _require(bool(document), 'decoder approval invalid')
    approvals = approvals.resolve(strict=True)

    wait_seconds = proof.validate_wait_seconds(environ.get('T34_PROOF_WAIT_SECONDS', ''))
    output_raw = environ.get('T34_PROOF_OUTPUT_DIR', '')
    _require(bool(output_raw), 'proof output directory required')
    output_dir = Path(output_raw)
    _require(output_dir.is_absolute(), 'proof output directory must be absolute')
    run_id = environ.get('T34_PROOF_RUN_ID') or secrets.token_hex(12)
    _require(RUN_ID.fullmatch(run_id) is not None, 'proof run ID invalid')
    return _Inputs(dispatch, trusted, initial, update, previous, approvals,
                   wait_seconds, output_dir, run_id)


def _prepare_output_dir(path: Path) -> Path:
    path = Path(path)
    _require(path.is_absolute() and not path.is_symlink(), 'proof output directory invalid')
    path.mkdir(parents=True, mode=0o700, exist_ok=True)
    _require(not path.is_symlink(), 'proof output directory must not be a link')
    info = path.stat()
    _require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid(),
             'proof output directory owner invalid')
    path.chmod(0o700)
    _require(not any(path.iterdir()), 'proof output directory must be empty')
    return path.resolve(strict=True)


def _prepare_work_parent(path: Path | None) -> tuple[Path, bool]:
    if path is None:
        parent = Path(tempfile.mkdtemp(prefix='t34-proof-parent-'))
        return parent, True
    parent = Path(path)
    _require(parent.is_absolute() and parent.is_dir() and not parent.is_symlink(),
             'proof work parent invalid')
    info = parent.stat()
    _require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid() and
             stat.S_IMODE(info.st_mode) & 0o077 == 0,
             'proof work parent must be owner-only')
    return parent.resolve(strict=True), False


def _create_run_root(parent: Path) -> Path:
    root = Path(tempfile.mkdtemp(prefix='r', dir=parent))
    root.chmod(0o700)
    _require(root.parent == parent and root.stat().st_uid == os.geteuid(),
             'proof run root owner invalid')
    return root.resolve(strict=True)


def _engine_paths(root: Path) -> hosted_engine.EnginePaths:
    """Build short private engine paths so the Unix socket stays under 104 bytes."""
    root = Path(root)
    _require(root.is_absolute() and root.is_dir() and not root.is_symlink(),
             'private engine root invalid')
    info = root.stat()
    _require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid() and
             stat.S_IMODE(info.st_mode) & 0o077 == 0, 'private engine root owner invalid')
    paths = hosted_engine.EnginePaths(
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
    _require(len(os.fsencode(paths.socket)) < 104, 'private engine socket path too long')
    proof.validate_engine_socket(paths.host, root)
    return paths


def _make_worker_directories(root: Path) -> dict[str, Path]:
    directories = {
        'home': root / 'w-home',
        'tmp': root / 'w-tmp',
        'config': root / 'w-config',
        'receipts': root / 'receipts',
        'logs': root / 'logs',
    }
    for directory in directories.values():
        directory.mkdir(mode=0o700)
        directory.chmod(0o700)
    return directories


def _worker_env(inputs: _Inputs, paths: hosted_engine.EnginePaths,
                engine_id: str, directories: Mapping[str, Path],
                environ: Mapping[str, str]) -> dict[str, str]:
    """Construct an explicit worker allowlist; never forward the GitHub environment."""
    base = _minimal_env(environ)
    home = directories['home']
    tmp = directories['tmp']
    config = directories['config']
    env = {
        **base,
        'HOME': str(home),
        'TMPDIR': str(tmp),
        'TMP': str(tmp),
        'TEMP': str(tmp),
        'XDG_RUNTIME_DIR': str(tmp),
        'XDG_CONFIG_HOME': str(config),
        'XDG_DATA_HOME': str(home / '.local' / 'share'),
        'DOCKER_CONFIG': str(config),
        'DOCKER_HOST': paths.host,
        'CI': 'true',
        'GITHUB_ACTIONS': 'true',
        'RUNNER_ENVIRONMENT': 'github-hosted',
        'GITHUB_EVENT_NAME': inputs.dispatch['event'],
        'GITHUB_REF': inputs.dispatch['ref'],
        'GITHUB_ACTOR': inputs.dispatch['actor'],
        'GITHUB_REPOSITORY_OWNER': inputs.dispatch['owner'],
        'GITHUB_SHA': inputs.trusted_sha,
        'PYTHONPATH': str(REPO_ROOT / 'infra/t34'),
        'T34_REPO_ROOT': str(REPO_ROOT),
        'T34_PROOF_WORK_DIR': str(paths.root),
        'T34_PROOF_RUN_ID': inputs.proof_run_id,
        'T34_PROOF_INITIAL_REVISION': inputs.initial_sha,
        'T34_PROOF_UPDATE_REVISION': inputs.update_sha,
        'T34_PROOF_PREVIOUS_REVISION': inputs.previous_sha,
        'T34_TRUSTED_MAIN_SHA': inputs.trusted_sha,
        release_approval.APPROVALS_ENV: str(inputs.decoder_approvals),
        'T34_ISOLATED_STAGING_DOCKER_HOST': paths.host,
        'T34_ISOLATED_STAGING_ENGINE_ID': engine_id,
    }
    home.mkdir(parents=True, mode=0o700, exist_ok=True)
    home.chmod(0o700)
    for key in ('HOME', 'TMPDIR', 'DOCKER_CONFIG'):
        directory = Path(env[key])
        _require(directory.is_relative_to(paths.root), 'worker private directory escaped run root')
        _require(stat.S_IMODE(directory.stat().st_mode) & 0o077 == 0,
                 'worker private directory is not owner-only')
    return env


def _default_git_verifier(config: Mapping[str, str], environ: Mapping[str, str]) -> None:
    """Verify that all requested commits are local ancestors of the checked-out main."""
    git = shutil.which('git')
    _require(git is not None, 'git unavailable')
    env = _minimal_env(environ)

    def run(*args: str) -> bytes:
        try:
            result = subprocess.run(
                [git, *args], cwd=config['repo_root'], stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env,
                timeout=60, check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise proof.ProofError('git verification unavailable') from exc
        _require(result.returncode == 0, 'git verification failed')
        return result.stdout

    head = run('rev-parse', '--verify', 'HEAD').decode('ascii', 'strict').strip()
    _require(head == config['trusted_main_sha'], 'checked-out revision is not trusted main')
    for key in ('initial_revision', 'update_revision', 'previous_revision'):
        revision = config[key]
        run('cat-file', '-e', revision + '^{commit}')
        run('merge-base', '--is-ancestor', revision, config['trusted_main_sha'])


def _default_engine_starter(paths: hosted_engine.EnginePaths, *,
                            environ: Mapping[str, str]):
    """Classify every refusal before the daemon exists as an unexecuted proof."""
    try:
        hosted_engine.preflight(paths, environ=environ)
    except hosted_engine.PrerequisiteUnavailable:
        raise
    except proof.ProofError as exc:
        raise hosted_engine.PrerequisiteUnavailable(
            'rootless prerequisites unavailable') from exc
    return hosted_engine.start_engine(paths, environ=environ)


def _default_engine_probe(paths: hosted_engine.EnginePaths,
                          environ: Mapping[str, str]) -> dict | None:
    env = _minimal_env(environ)
    env.update({
        'HOME': str(paths.home),
        'DOCKER_CONFIG': str(paths.config),
        'DOCKER_HOST': paths.host,
        'XDG_RUNTIME_DIR': str(paths.runtime),
    })
    return hosted_engine._docker_info(paths, env)


def _docker_rows(host: str, args: tuple[str, ...], environ: Mapping[str, str]) -> list[str]:
    docker = shutil.which('docker')
    _require(docker is not None, 'docker unavailable')
    try:
        result = subprocess.run(
            [docker, '--host', host, *args], stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            env=dict(environ), timeout=30, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise proof.ProofError('engine inventory unavailable') from exc
    _require(result.returncode == 0, 'engine inventory failed')
    try:
        text = result.stdout.decode('utf-8')
    except UnicodeDecodeError as exc:
        raise proof.ProofError('engine inventory invalid') from exc
    return [line for line in text.splitlines() if line]


def _default_inventory_probe(host: str, environ: Mapping[str, str]) -> dict:
    volumes = _docker_rows(host, ('volume', 'ls', '--format', '{{.Name}}'), environ)
    states = _docker_rows(host, ('ps', '-a', '--format', '{{.State}}'), environ)
    running = sum(1 for state in states if state.lower() == 'running')
    return {
        'volumes': volumes,
        'containers': {'running': running, 'stopped': len(states) - running},
    }


def _inventory(value: object) -> _Inventory:
    _require(isinstance(value, Mapping), 'engine inventory invalid')
    volumes = value.get('volumes')
    containers = value.get('containers')
    _require(isinstance(volumes, list), 'engine volume inventory invalid')
    _require(isinstance(containers, Mapping), 'engine container inventory invalid')
    names = []
    for name in volumes:
        _require(isinstance(name, str) and bool(name) and
                 not any(ch in name for ch in '\x00\r\n'), 'engine volume inventory invalid')
        names.append(name)
    _require(len(names) == len(set(names)), 'engine volume inventory contains duplicates')
    running = containers.get('running')
    stopped = containers.get('stopped')
    _require(type(running) is int and running >= 0, 'running service count invalid')
    _require(type(stopped) is int and stopped >= 0, 'stopped service count invalid')
    return _Inventory(frozenset(names), running, stopped)


def _observe_engine(engine, paths: hosted_engine.EnginePaths,
                    environ: Mapping[str, str],
                    probe: Callable[[hosted_engine.EnginePaths, Mapping[str, str]], dict],
                    stage: str,
                    expected: tuple[str, str] | None) -> tuple[str, str]:
    try:
        engine.assert_alive()
        observed = probe(paths, environ)
    except _CoordinatorFailure:
        raise
    except Exception as exc:
        if isinstance(exc, (KeyboardInterrupt, SystemExit)):
            raise
        raise _CoordinatorFailure(stage, 'engine-unavailable') from exc
    if not isinstance(observed, Mapping):
        raise _CoordinatorFailure(stage, 'engine-unavailable')
    identifier = observed.get('engine_id')
    version = observed.get('server_version')
    if (not isinstance(identifier, str) or
            hosted_engine.ENGINE_ID.fullmatch(identifier) is None or
            not isinstance(version, str) or not version):
        raise _CoordinatorFailure(stage, 'engine-unavailable')
    if observed.get('rootless') is not True:
        raise _CoordinatorFailure(stage, 'engine-not-rootless')
    if expected is None:
        expected = (identifier, version)
    elif (identifier, version) != expected:
        raise _CoordinatorFailure(stage, 'engine-identity-changed')
    return expected


def _check_initial_inventory(inventory: _Inventory) -> None:
    if inventory.volumes or inventory.running or inventory.stopped:
        raise _CoordinatorFailure('preflight', 'isolated-engine-not-empty')


def _check_retained(inventory: _Inventory, originals: frozenset[str],
                    stage: str) -> None:
    if not originals.issubset(inventory.volumes):
        raise _CoordinatorFailure(stage, 'resource-retention-failed')


def _validate_stage_evidence(
        stage: str, worker: proof.WorkerResult, inputs: _Inputs, inventory: _Inventory,
        *, seen_pids: tuple[int, ...] = (),
        previous: hosted_contract.StageReceipt | None = None,
) -> hosted_contract.StageReceipt:
    revision = inputs.initial_sha if stage == 'init' else inputs.update_sha
    observed = {
        'volumes': sorted(inventory.volumes),
        'containers': {
            'running': inventory.running,
            'stopped': inventory.stopped,
        },
    }
    try:
        return hosted_contract.validate_stage_receipt(
            worker.receipt, phase=stage, pid=worker.pid, revision=revision,
            run_id=inputs.proof_run_id, inventory=observed, seen_pids=seen_pids,
            previous=previous,
        )
    except hosted_contract.InventoryMismatchError as exc:
        raise _CoordinatorFailure(stage, 'inventory-invalid') from exc
    except hosted_contract.StageReceiptError as exc:
        raise _CoordinatorFailure(stage, 'receipt-validation-failed') from exc


def _run_stage(stage: str, *, stage_script: Path, paths: hosted_engine.EnginePaths,
               directories: Mapping[str, Path], env: Mapping[str, str],
               worker_runner: Callable[..., proof.WorkerResult]) -> proof.WorkerResult:
    receipt = directories['receipts'] / (stage + '.json')
    log_prefix = directories['logs'] / stage
    command = [sys.executable, str(stage_script), stage, '--receipt', str(receipt)]
    previous_umask = os.umask(0o077)
    try:
        result = worker_runner(command, receipt, log_prefix=log_prefix,
                               timeout=STAGE_TIMEOUT_SECONDS,
                               env={**env, 'T34_PROOF_STAGE': stage})
        _require(result.returncode == 0, 'stage worker result invalid')
        _require(isinstance(result.receipt, Mapping) and
                 result.receipt.get('phase') == stage, 'stage receipt invalid')
        return result
    except _CoordinatorFailure:
        raise
    except Exception as exc:
        if isinstance(exc, (KeyboardInterrupt, SystemExit)):
            raise
        raise _CoordinatorFailure(stage, 'stage-failed') from exc
    finally:
        os.umask(previous_umask)


def _remove_private_tree(root: Path) -> bool:
    if not root.exists() or root.is_symlink():
        return False
    info = root.stat()
    _require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid(),
             'private run root removal refused')
    shutil.rmtree(root)
    _require(not root.exists(), 'private run root still exists')
    return True


def _public_receipt(evidence: _Evidence, *, result: str, stage: str | None = None,
                    error: str | None = None) -> dict:
    verified = evidence.engine_identity_verified
    receipt = {
        'version': 1,
        'result': result,
        'mode': 'github-hosted-isolated',
        'non_production': True,
        'engine': {
            'rootless': evidence.engine_rootless,
            'identity_verified': verified,
        },
        'wait': {
            'requested_seconds': evidence.wait.get('requested_seconds', 0),
            'elapsed_seconds': evidence.wait.get('elapsed_seconds', 0.0),
        },
        'processes': {'stages_completed': evidence.stages_completed},
        'storage': {
            'initial_volumes': evidence.initial_volumes,
            'retained_volumes': evidence.retained_volumes,
            'original_volumes_retained': evidence.original_volumes_retained,
        },
        'services': {
            'init_running': evidence.init_running,
            'update_running': evidence.update_running,
            'negative_stopped': evidence.negative_stopped,
        },
        'verification': {
            'git': 'verified' if evidence.git_verified else 'not-verified',
            'engine': ('verified' if verified else
                       'started' if evidence.engine_started else 'not-started'),
            'isolation': 'verified' if evidence.original_volumes_retained else 'not-verified',
            'resources': 'verified' if evidence.resources_verified else 'not-verified',
        },
    }
    receipt['cleanup'] = {
        'engine_stopped': evidence.engine_stopped,
        'private_work_removed': evidence.private_work_removed,
    }
    if stage is not None:
        receipt['stage'] = stage
    if error is not None:
        receipt['error'] = error
    return receipt


def _validate_public_receipt(receipt: Mapping) -> None:
    """Validate the exact public types and values before the file is exported."""
    proof.enforce_public_receipt(receipt)
    result = receipt.get('result')
    _require(result in {'proof-pass'} | FAILURE_RESULTS, 'public result invalid')
    _require(receipt.get('version') == 1 and type(receipt.get('version')) is int,
             'public version invalid')
    _require(receipt.get('mode') == 'github-hosted-isolated', 'public mode invalid')
    _require(receipt.get('non_production') is True, 'public non-production flag invalid')
    engine = receipt.get('engine')
    _require(isinstance(engine, Mapping) and type(engine.get('rootless')) is bool and
             type(engine.get('identity_verified')) is bool, 'public engine evidence invalid')
    wait = receipt.get('wait')
    _require(isinstance(wait, Mapping), 'public wait evidence invalid')
    requested = wait.get('requested_seconds')
    elapsed = wait.get('elapsed_seconds')
    _require(type(requested) is int and requested >= 0, 'public wait request invalid')
    _require(type(elapsed) in (int, float) and elapsed >= 0, 'public wait elapsed invalid')
    processes = receipt.get('processes')
    _require(isinstance(processes, Mapping) and
             type(processes.get('stages_completed')) is int and
             0 <= processes['stages_completed'] <= 3, 'public process evidence invalid')
    storage = receipt.get('storage')
    _require(isinstance(storage, Mapping), 'public storage evidence invalid')
    for key in ('initial_volumes', 'retained_volumes'):
        _require(type(storage.get(key)) is int and storage[key] >= 0,
                 'public storage count invalid')
    _require(type(storage.get('original_volumes_retained')) is bool,
             'public retention flag invalid')
    services = receipt.get('services')
    _require(isinstance(services, Mapping), 'public service evidence invalid')
    for key in ('init_running', 'update_running', 'negative_stopped'):
        _require(type(services.get(key)) is int and services[key] >= 0,
                 'public service count invalid')
    verification = receipt.get('verification')
    _require(isinstance(verification, Mapping), 'public verification evidence invalid')
    for key in ('git', 'engine', 'isolation', 'resources'):
        _require(isinstance(verification.get(key), str), 'public verification state invalid')
    cleanup = receipt.get('cleanup')
    _require(isinstance(cleanup, Mapping) and
             set(cleanup) == {'engine_stopped', 'private_work_removed'} and
             type(cleanup.get('engine_stopped')) is bool and
             type(cleanup.get('private_work_removed')) is bool,
             'public cleanup evidence invalid')
    if result == 'proof-pass':
        _require(processes['stages_completed'] == 3, 'passing proof has incomplete stages')
        _require(storage['original_volumes_retained'] is True, 'passing proof lost resources')
        _require(verification['engine'] == 'verified', 'passing proof lacks engine verification')
        _require(cleanup == {'engine_stopped': True, 'private_work_removed': True},
                 'passing proof was not cleaned up')
        _require(wait['elapsed_seconds'] >= wait['requested_seconds'] and
                 wait['requested_seconds'] >= proof.MIN_WAIT_SECONDS,
                 'passing proof did not wait long enough')
        _require('stage' not in receipt and 'error' not in receipt,
                 'passing proof contains failure evidence')
    else:
        _require(receipt.get('stage') in
                 {'preflight', 'wait', 'cleanup'} | set(STAGES),
                 'public failure stage invalid')
        _require(receipt.get('error') in PUBLIC_ERRORS, 'public failure code invalid')
        if receipt.get('error') == 'cleanup-failed':
            _require(cleanup != {'engine_stopped': True, 'private_work_removed': True},
                     'cleanup failure lacks failed cleanup evidence')


def _fallback_receipt(evidence: _Evidence) -> dict:
    return {
        'version': 1,
        'result': 'proof-fail',
        'mode': 'github-hosted-isolated',
        'non_production': True,
        'stage': 'preflight',
        'error': 'receipt-validation-failed',
        'engine': {'rootless': False, 'identity_verified': False},
        'wait': {'requested_seconds': 0, 'elapsed_seconds': 0},
        'processes': {'stages_completed': evidence.stages_completed},
        'storage': {
            'initial_volumes': 0,
            'retained_volumes': 0,
            'original_volumes_retained': False,
        },
        'services': {'init_running': 0, 'update_running': 0, 'negative_stopped': 0},
        'verification': {
            'git': 'not-verified', 'engine': 'not-started',
            'isolation': 'not-verified', 'resources': 'not-verified',
        },
        'cleanup': {
            'engine_stopped': evidence.engine_stopped,
            'private_work_removed': evidence.private_work_removed,
        },
    }


def _write_receipt(output_dir: Path, evidence: _Evidence, *, result: str,
                   stage: str | None, error: str | None,
                   forbidden_values: set[str]) -> Mapping:
    receipt = _public_receipt(evidence, result=result, stage=stage, error=error)
    try:
        _validate_public_receipt(receipt)
        proof.enforce_public_receipt(receipt, forbidden_values=forbidden_values)
    except proof.ProofError:
        receipt = _fallback_receipt(evidence)
        _validate_public_receipt(receipt)
        proof.enforce_public_receipt(receipt, forbidden_values=forbidden_values)
    proof.write_private_json(output_dir / 'proof.json', receipt)
    return receipt


def run_hosted_proof(
        environ: Mapping[str, str] | None = None, *,
        work_parent: Path | None = None,
        stage_script: Path | None = None,
        git_verifier: Callable[[Mapping[str, str], Mapping[str, str]], object] | None = None,
        engine_starter: Callable[..., object] | None = None,
        engine_probe: Callable[..., dict] | None = None,
        inventory_probe: Callable[[str, Mapping[str, str]], dict] | None = None,
        wait: Callable[[int], dict] | None = None,
        worker_runner: Callable[..., proof.WorkerResult] | None = None,
) -> HostedProofOutcome:
    """Run the proof with injectable boundaries; safe to invoke in offline tests."""
    environ = dict(os.environ if environ is None else environ)
    git_verifier = git_verifier or _default_git_verifier
    engine_starter = engine_starter or _default_engine_starter
    engine_probe = engine_probe or _default_engine_probe
    inventory_probe = inventory_probe or _default_inventory_probe
    wait = wait or proof.real_wait
    worker_runner = worker_runner or proof.run_worker_process
    stage_script = Path(stage_script or DEFAULT_STAGE_SCRIPT)

    evidence = _Evidence()
    stage = 'preflight'
    result = 'proof-fail'
    error: str | None = 'internal-error'
    output_dir: Path | None = None
    work_root: Path | None = None
    work_parent_path: Path | None = None
    owned_work_parent = False
    engine = None
    engine_identity: tuple[str, str] | None = None
    original_volumes: frozenset[str] = frozenset()
    forbidden_values: set[str] = set()

    try:
        try:
            inputs = _parse_inputs(environ)
            evidence.wait = {'requested_seconds': inputs.wait_seconds,
                             'elapsed_seconds': 0.0}
            forbidden_values.add(inputs.proof_run_id)
            output_dir = _prepare_output_dir(inputs.output_dir)
            forbidden_values.add(str(output_dir))
            _require(stage_script.is_file() and not stage_script.is_symlink(),
                     'stage worker unavailable')
            stage_script = stage_script.resolve(strict=True)
        except (proof.ProofError, OSError):
            result, error = 'proof-fail', 'invalid-input'
            raw_output = environ.get('T34_PROOF_OUTPUT_DIR', '')
            if raw_output:
                try:
                    output_dir = _prepare_output_dir(Path(raw_output))
                except (proof.ProofError, OSError):
                    output_dir = None
            raise _CoordinatorFailure(stage, error)

        config = {
            'repo_root': str(REPO_ROOT),
            'trusted_main_sha': inputs.trusted_sha,
            'initial_revision': inputs.initial_sha,
            'update_revision': inputs.update_sha,
            'previous_revision': inputs.previous_sha,
        }
        try:
            git_verifier(config, _minimal_env(environ))
        except Exception as exc:
            if isinstance(exc, (KeyboardInterrupt, SystemExit)):
                raise
            raise _CoordinatorFailure(stage, 'git-verification-failed') from exc
        evidence.git_verified = True

        try:
            work_parent_path, owned_work_parent = _prepare_work_parent(work_parent)
            work_root = _create_run_root(work_parent_path)
            forbidden_values.add(str(work_root))
            paths = _engine_paths(work_root)
            forbidden_values.add(str(paths.socket))
            engine = engine_starter(paths, environ=_minimal_env(environ))
        except hosted_engine.PrerequisiteUnavailable as exc:
            result = 'not-executed'
            raise _CoordinatorFailure(stage, 'rootless-prerequisites-unavailable',
                                      result='not-executed') from exc
        except _CoordinatorFailure:
            raise
        except Exception as exc:
            if isinstance(exc, (KeyboardInterrupt, SystemExit)):
                raise
            raise _CoordinatorFailure(stage, 'engine-start-failed') from exc
        evidence.engine_started = True
        if getattr(engine, 'engine_id', None):
            forbidden_values.add(str(engine.engine_id))

        try:
            engine_identity = _observe_engine(
                engine, paths, _minimal_env(environ), engine_probe, stage, None)
            if (getattr(engine, 'engine_id', None) != engine_identity[0] or
                    getattr(engine, 'server_version', None) != engine_identity[1]):
                raise _CoordinatorFailure(stage, 'engine-identity-changed')
        except _CoordinatorFailure:
            raise
        except Exception as exc:
            if isinstance(exc, (KeyboardInterrupt, SystemExit)):
                raise
            raise _CoordinatorFailure(stage, 'engine-unavailable') from exc
        evidence.engine_rootless = True
        evidence.engine_identity_verified = True
        forbidden_values.add(engine_identity[0])

        try:
            directories = _make_worker_directories(work_root)
            worker_env = _worker_env(inputs, paths, engine_identity[0],
                                     directories, environ)
            forbidden_values.update({
                str(directories['receipts']), str(directories['logs']),
            })
            initial = _inventory(inventory_probe(paths.host, worker_env))
            _check_initial_inventory(initial)
        except _CoordinatorFailure:
            raise
        except Exception as exc:
            if isinstance(exc, (KeyboardInterrupt, SystemExit)):
                raise
            raise _CoordinatorFailure(stage, 'inventory-invalid') from exc

        stage = 'init'
        init_result = _run_stage(stage, stage_script=stage_script, paths=paths,
                                 directories=directories, env=worker_env,
                                 worker_runner=worker_runner)
        try:
            engine_identity = _observe_engine(
                engine, paths, _minimal_env(environ), engine_probe, stage,
                engine_identity)
            after_init = _inventory(inventory_probe(paths.host, worker_env))
            if not after_init.volumes:
                raise _CoordinatorFailure(stage, 'resource-retention-failed')
            _check_retained(after_init, after_init.volumes, stage)
            init_evidence = _validate_stage_evidence(
                'init', init_result, inputs, after_init)
        except _CoordinatorFailure:
            raise
        except Exception as exc:
            if isinstance(exc, (KeyboardInterrupt, SystemExit)):
                raise
            raise _CoordinatorFailure(stage, 'inventory-invalid') from exc
        original_volumes = after_init.volumes
        forbidden_values.update(original_volumes)
        evidence.initial_volumes = len(original_volumes)
        evidence.init_running = after_init.running
        evidence.stages_completed = 1

        stage = 'wait'
        try:
            waited = wait(inputs.wait_seconds)
            if not isinstance(waited, Mapping):
                raise proof.ProofError('wait evidence invalid')
            requested = waited.get('requested_seconds')
            elapsed = waited.get('elapsed_seconds')
            if type(requested) is not int or requested != inputs.wait_seconds:
                raise proof.ProofError('wait evidence requested an unexpected duration')
            if type(elapsed) not in (int, float) or elapsed < requested:
                raise proof.ProofError('wait did not elapse')
        except Exception as exc:
            if isinstance(exc, (KeyboardInterrupt, SystemExit)):
                raise
            raise _CoordinatorFailure(stage, 'wait-not-elapsed') from exc
        evidence.wait = {'requested_seconds': requested,
                         'elapsed_seconds': float(elapsed)}

        stage = 'update'
        try:
            engine_identity = _observe_engine(
                engine, paths, _minimal_env(environ), engine_probe, stage,
                engine_identity)
            before_update = _inventory(inventory_probe(paths.host, worker_env))
            _check_retained(before_update, original_volumes, stage)
        except _CoordinatorFailure:
            raise
        except Exception as exc:
            if isinstance(exc, (KeyboardInterrupt, SystemExit)):
                raise
            raise _CoordinatorFailure(stage, 'inventory-invalid') from exc

        update_result = _run_stage(stage, stage_script=stage_script, paths=paths,
                                   directories=directories, env=worker_env,
                                   worker_runner=worker_runner)
        try:
            engine_identity = _observe_engine(
                engine, paths, _minimal_env(environ), engine_probe, stage,
                engine_identity)
            after_update = _inventory(inventory_probe(paths.host, worker_env))
            _check_retained(after_update, original_volumes, stage)
            update_evidence = _validate_stage_evidence(
                'update', update_result, inputs, after_update,
                seen_pids=(init_evidence.pid,), previous=init_evidence)
        except _CoordinatorFailure:
            raise
        except Exception as exc:
            if isinstance(exc, (KeyboardInterrupt, SystemExit)):
                raise
            raise _CoordinatorFailure(stage, 'inventory-invalid') from exc
        evidence.update_running = after_update.running
        evidence.retained_volumes = len(original_volumes & after_update.volumes)
        evidence.original_volumes_retained = True
        evidence.resources_verified = True
        evidence.stages_completed = 2

        stage = 'negative'
        negative_result = _run_stage(stage, stage_script=stage_script, paths=paths,
                                     directories=directories, env=worker_env,
                                     worker_runner=worker_runner)
        try:
            engine_identity = _observe_engine(
                engine, paths, _minimal_env(environ), engine_probe, stage,
                engine_identity)
            after_negative = _inventory(inventory_probe(paths.host, worker_env))
            _check_retained(after_negative, original_volumes, stage)
            _validate_stage_evidence(
                'negative', negative_result, inputs, after_negative,
                seen_pids=(init_evidence.pid, update_evidence.pid),
                previous=update_evidence)
        except _CoordinatorFailure:
            raise
        except Exception as exc:
            if isinstance(exc, (KeyboardInterrupt, SystemExit)):
                raise
            raise _CoordinatorFailure(stage, 'inventory-invalid') from exc
        evidence.negative_stopped = after_negative.stopped
        evidence.retained_volumes = len(original_volumes & after_negative.volumes)
        evidence.stages_completed = 3
        result, stage, error = 'proof-pass', None, None
    except _CoordinatorFailure as exc:
        result, stage, error = exc.result, exc.stage, exc.error
        if error == 'resource-retention-failed':
            evidence.original_volumes_retained = False
    except Exception:
        result, stage, error = 'proof-fail', stage, 'internal-error'
    finally:
        engine_stopped = False
        if engine is not None:
            try:
                engine_stopped = bool(engine.stop())
            except Exception:
                engine_stopped = False
        else:
            engine_stopped = True
        evidence.engine_stopped = engine_stopped
        removed = False
        if work_root is not None and engine_stopped:
            try:
                removed = _remove_private_tree(work_root)
            except (OSError, proof.ProofError):
                removed = False
        evidence.private_work_removed = removed
        if owned_work_parent and work_parent_path is not None:
            try:
                work_parent_path.rmdir()
            except OSError:
                pass
        if result == 'proof-pass' and (not engine_stopped or not removed):
            result, stage, error = 'proof-fail', 'cleanup', 'cleanup-failed'

    if output_dir is None:
        raw_output = environ.get('T34_PROOF_OUTPUT_DIR', '')
        try:
            output_dir = _prepare_output_dir(Path(raw_output)) if raw_output else None
        except (proof.ProofError, OSError):
            output_dir = None
    if output_dir is None:
        return HostedProofOutcome(1)

    forbidden_values.update({
        value for value in (
            str(work_root) if work_root is not None else '',
            str(engine_identity[0]) if engine_identity is not None else '',
        ) if value
    })
    try:
        persisted = _write_receipt(
            output_dir, evidence, result=result, stage=stage,
            error=error, forbidden_values=forbidden_values)
    except (OSError, proof.ProofError):
        return HostedProofOutcome(1)
    return HostedProofOutcome(0 if persisted.get('result') == 'proof-pass' else 1)


def main() -> int:
    """Workflow entry point; all diagnostics remain in private worker logs."""
    try:
        return run_hosted_proof(os.environ).exit_code
    except Exception:
        return 1


if __name__ == '__main__':
    raise SystemExit(main())

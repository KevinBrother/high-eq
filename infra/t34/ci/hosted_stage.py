#!/usr/bin/env python3
"""One worker for the independent GitHub-hosted T34 proof.

The parent owns the run directory and engine lifecycle. It passes the endpoint
and expected daemon ID from its own successful rootless start, never from an
engine discovered by this worker. It must leave the same engine alive between
invocations. The dot-prefixed run files and recovery journal are private to that
parent and its workers. Only the requested phase receipt is for parent ingestion.

The parent supplies T34_PROOF_WORK_DIR (a 0700 directory outside the checkout),
T34_PROOF_RUN_ID (24 hex characters), the three release SHAs in REVISION_INPUTS,
T34_TRUSTED_MAIN_SHA, and DOCKER_HOST matching T34_ISOLATED_STAGING_DOCKER_HOST.
T34_ISOLATED_STAGING_ENGINE_ID identifies that daemon. Its hosted_engine runtime
and data directories live under the work directory or a private subdirectory.
"""
import argparse
from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
from hashlib import sha256
import json
import os
from pathlib import Path
import secrets
import stat
import sys
import time

HERE = Path(__file__).resolve().parents[1]
REPO = HERE.parents[1]
if __package__ in (None, ''):
    sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE / 'tests'))

from ci import hosted_engine
from ci.hosted_proof import (MIN_WAIT_SECONDS, ProofError, authorize_dispatch,
                             load_private_json, require, write_private_json)
from isolated_staging import check_receipt, parse_receipt, pg_fingerprint, quiet, vault_fingerprint
from isolated_staging_lab import (IMAGE_ID, OWNER, PG, REDIS, REVISION, IsolatedLab, isolated_engine,
                                  namespace)
from persistent_staging_accept import Parser, materialize
import inputs
import release
import release_approval
import staging
import staging_recovery

PHASES = ('init', 'update', 'negative')
PREVIOUS_PHASE = {'update': 'init', 'negative': 'update'}
REVISION_INPUTS = ('T34_PROOF_INITIAL_REVISION', 'T34_PROOF_UPDATE_REVISION',
                   'T34_PROOF_PREVIOUS_REVISION')
RECOVERY = '.t34-recovery'
STORAGE = {'db', 'cache', 'ledger', 'restored', 'coldcache'}
SERVING = {'api', 'web', 'backup', 'monitor', 'alert-sink', 'chat-sweeper'}


def digest(value):
    return sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def private_directory(path):
    require(path.is_absolute() and path == path.resolve(strict=True), 'private directory path invalid')
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid() and
            stat.S_IMODE(info.st_mode) == 0o700, 'private directory ownership invalid')
    return info


@contextmanager
def exclusive_run(root):
    descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        current = private_directory(root)
        opened = os.fstat(descriptor)
        require((current.st_dev, current.st_ino) == (opened.st_dev, opened.st_ino))
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield descriptor
    finally:
        os.close(descriptor)


@dataclass(frozen=True)
class EngineBinding:
    host: str
    engine_id: str
    socket: Path
    data_root: Path
    socket_identity: tuple
    data_identity: tuple

    @classmethod
    def from_parent(cls, environ, root):
        host, identifier = isolated_engine(environ)
        require(environ.get('DOCKER_HOST') == host, 'explicit isolated engine host differs')
        paths = hosted_engine.require_engine_layout(hosted_engine.engine_paths(root), host=host)
        private_directory(paths.root)
        private_directory(paths.runtime)
        private_directory(paths.data_root)
        return cls(host, identifier, paths.socket, paths.data_root,
                   cls.inspect_socket(paths.socket), cls.inspect_data(paths.data_root))

    @staticmethod
    def inspect_data(path):
        entry = path.lstat()
        require(stat.S_ISDIR(entry.st_mode) and entry.st_uid == os.geteuid(),
                'private engine data root invalid')
        return entry.st_dev, entry.st_ino

    @staticmethod
    def inspect_socket(socket):
        entry = socket.lstat()
        require(stat.S_ISSOCK(entry.st_mode) and entry.st_uid == os.geteuid() and
                stat.S_IMODE(entry.st_mode) & 0o007 == 0, 'private engine socket invalid')
        return entry.st_dev, entry.st_ino, entry.st_ctime_ns

    def verify_socket(self):
        require(self.socket == self.socket.resolve(strict=True) and
                self.inspect_socket(self.socket) == self.socket_identity, 'private engine socket changed')


class HostedLab(IsolatedLab):
    def __init__(self, work, sources, run_id, engine, owner_token):
        self.engine = engine
        super().__init__(work, sources, run_id, engine.host, engine.engine_id,
                         owner_token, durable_state=True)

    def _docker(self, *args, **kwargs):
        self.engine.verify_socket()
        require(self.env.get('DOCKER_HOST') == self.engine.host, 'isolated client endpoint changed')
        return super()._docker(*args, **kwargs)

    def _verify_engine(self):
        self._engine_verified = False
        raw = self._docker('info', '--format',
                           '{{.ID}}\t{{.OSType}}\t{{json .SecurityOptions}}\t{{.DockerRootDir}}',
                           timeout=15)
        identifier, platform, security_options, data_root = raw.decode().strip().split('\t')
        hosted_engine.parse_rootless_security_options(security_options)
        require(identifier == self.engine.engine_id and platform == 'linux' and
                data_root == str(self.engine.data_root),
                'private rootless daemon binding differs')
        require(self.engine.inspect_data(self.engine.data_root) == self.engine.data_identity,
                'private engine data root changed')
        self.engine.verify_socket()
        self._engine_verified = True

    def prime_empty_engine(self):
        # Global emptiness is inspected only on the independently bound new daemon.
        self._verify_engine()
        for command in (('container', 'ls', '-aq'), ('volume', 'ls', '-q'), ('image', 'ls', '-aq')):
            require(not self._docker(*command, timeout=15).strip(), 'proof engine was not empty')
        networks = self._docker('network', 'ls', '--format', '{{.Name}}\t{{.Driver}}', timeout=15)
        allowed = {'bridge\tbridge', 'host\thost', 'none\tnull'}
        names = networks.decode().splitlines()
        require(len(names) == len(set(names)) and set(names) <= allowed, 'proof engine had a custom network')
        for image in (PG, REDIS):
            self._verify_engine()
            self._docker('pull', image, timeout=300)
        self._verify_engine()

    def volume_identities(self, identities):
        # Docker local volumes expose a name and creation time, not a container-style ID.
        records = {}
        for identifier, name in identities['volume']:
            require(identifier == name)
            raw = self._docker('volume', 'inspect', '--format',
                               '{{.CreatedAt}}\t{{.Driver}}\t{{.Scope}}\t{{json .Options}}\t{{json .Labels}}',
                               name, timeout=15)
            created, driver, scope, options, labels = raw.decode().strip().split('\t')
            require(bool(created) and driver == scope == 'local' and json.loads(options) in (None, {}),
                    'proof volume is not local')
            labels = json.loads(labels)
            require(isinstance(labels, dict) and labels.get(OWNER) == self.token,
                    'proof volume owner differs')
            records[name] = digest([created, labels])
        return records

    def resource_fingerprint(self, identities):
        # Fencing changes Running and FinishedAt. StartedAt and RestartCount
        # would also change if the rejected release restarted a stopped service.
        launches = []
        for identifier, _ in identities['container']:
            raw = self._docker('container', 'inspect', '--format',
                               '{{.Id}}\t{{.State.StartedAt}}\t{{.RestartCount}}\t{{.Image}}',
                               identifier, timeout=15)
            container, started, restarts, image = raw.decode().strip().split('\t')
            require(container == identifier and started and restarts.isdecimal() and IMAGE_ID.fullmatch(image),
                    'container launch evidence invalid')
            launches.append([container, started, restarts, image])
        return digest([identities, launches])

    def services(self, *, fenced):
        rows = self.run('ps', '--no-trunc', '--filter=label=com.docker.compose.project=' + self.name,
                        '--format', '{{.ID}} {{.Label "com.docker.compose.service"}}', timeout=15)
        services = [row.split()[1] for row in rows.decode().splitlines()]
        wanted = STORAGE if fenced else STORAGE | SERVING
        require(len(services) == len(wanted) and set(services) == wanted, 'running service set differs')
        return {service: service in wanted for service in sorted(STORAGE | SERVING)}


def stage_paths(root, receipt, engine):
    receipt = Path(receipt)
    require(receipt.is_absolute() and receipt == receipt.resolve(), 'stage receipt path invalid')
    require(receipt.parent == root / 'receipts',
            'stage receipt outside its dedicated directory')
    private_directory(receipt.parent)
    engine_root = engine.socket.parent.parent
    paths = hosted_engine.engine_paths(engine_root)
    engine_directories = (paths.home, paths.config, paths.runtime, paths.data_root,
                          paths.exec_root)
    require(not any(directory == receipt or directory in receipt.parents
                    for directory in engine_directories), 'stage receipt overlaps engine state')
    require(not receipt.exists(), 'stage receipt already exists')
    return receipt


def bind_revisions(environ):
    revisions = tuple(environ.get(key, '') for key in REVISION_INPUTS)
    trusted = environ.get('T34_TRUSTED_MAIN_SHA', '')
    require(all(REVISION.fullmatch(sha) for sha in (*revisions, trusted)) and
            revisions[0] != revisions[1] and trusted == environ.get('GITHUB_SHA'),
            'trusted revision inputs invalid')
    require(inputs._git(REPO, 'rev-parse', '--show-toplevel') == str(REPO) and
            inputs._git(REPO, 'rev-parse', 'HEAD') == trusted, 'trusted main checkout differs')
    for revision in revisions:
        require(inputs._git(REPO, 'rev-parse', '--verify', revision + '^{commit}') == revision,
                'revision input is not an exact commit')
        inputs._git(REPO, 'merge-base', '--is-ancestor', revision, trusted)
    return revisions, trusted


def private_record(path):
    entry = path.lstat()
    require(stat.S_IMODE(entry.st_mode) == 0o600 and entry.st_nlink == 1, 'private stage record invalid')
    return load_private_json(path)


def stage_record(root, phase):
    return root / ('.t34-' + phase + '.json')


def predecessor(root, phase, context, *, now_ns, pid):
    if phase == 'init':
        return None
    previous = PREVIOUS_PHASE[phase]
    record = private_record(stage_record(root, previous))
    require(record['phase'] == previous and record['context'] == context and
            type(record['pid']) is int and record['pid'] > 0 and record['pid'] != pid and
            type(record['finished_ns']) is int and 0 < record['finished_ns'] < now_ns,
            'prior stage process or binding differs')
    if phase == 'update':
        require(now_ns - record['finished_ns'] > MIN_WAIT_SECONDS * 1_000_000_000,
                'wait since initialization has not elapsed')
    return record


def provision(box, recovery_path):
    instance = secrets.token_hex(32)
    box.prime_empty_engine()
    box.claim(instance=instance)
    entry = json.loads(box.run('volume', 'inspect', '--format', '{{json .}}', box.volume, timeout=15))
    recovery_path.mkdir(mode=0o700)
    write_private_json(recovery_path / 'provision.json', {
        'volume': box.volume, 'engine_id': box.engine_id, 'instance': instance, 'created_at': entry['CreatedAt'],
    })


def observe(box, recovery, schema, schema_version, *, fenced=False, previous=None):
    identities = box.resource_identities()
    volumes = box.volume_identities(identities)
    required = {box.volume, *(box.name + '_' + name for name in
                              ('approval', 'business', 'deletions', 'quarantine', 'vault'))}
    require(set(volumes) == required, 'persistent volume set differs')
    resources = box.resource_fingerprint(identities)
    if previous is not None:
        require(previous['resources'] == resources and previous['volumes'] == volumes,
                'prior resource identity changed')
    state = recovery.read_initial()
    staging.validate_state(state, box.name, schema, schema_version)
    staging.apply_to_lab(box, state)
    require(staging.verify_storage(box, state) is True, 'retained storage verification failed')
    pg = pg_fingerprint(box, state['marker'])
    vault = vault_fingerprint(box, state['business_dump_sha256'])
    services = box.services(fenced=fenced)
    if not fenced:
        current = state['release']
        require(release.running_release(box) == [current['api_image_id'], current['web_image_id']],
                'running artifacts do not match committed state')
    file_sha = sha256(box.state_file_fingerprint()).hexdigest()
    require(box.resource_identities() == identities and box.volume_identities(identities) == volumes and
            box.resource_fingerprint(identities) == resources,
            'proof resource identity changed during observation')
    return state, {
        'resources': resources, 'volumes': volumes, 'state': file_sha, 'pg': pg,
        'ledger': digest([state['marker']['ledger_identity'], state['ledger_deadlines']]),
        'vault': {name: list(checksums) for name, checksums in vault.items()},
        'services': services, 'ledger_roots': len(state['ledger_deadlines']),
    }


def require_retention(before, after):
    require(all(before[key] == after[key] for key in ('volumes', 'pg', 'ledger', 'ledger_roots')) and
            all(after['vault'].get(name) == checksums for name, checksums in before['vault'].items()),
            'persistent storage or completed snapshots changed')


def reject_schema(box, candidate, work, composition, schema, recovery):
    wrong = ('0' if schema[0] != '0' else '1') + schema[1:]
    try:
        quiet(release.run_ci_staging, box, candidate, work, composition, wrong, box.volume, recovery=recovery)
    except ValueError as error:
        require(str(error) == 'staging state schema digest mismatch', 'wrong negative refusal')
    else:
        raise ProofError('fixed stage accepted a schema mismatch')
    box.fenced()


def run_phase(phase, box, recovery, candidate, work, composition, schema, previous):
    schema_version = staging.schema_version(candidate.source)
    if phase == 'init':
        require(recovery.read_initial() is None and not box.existing_project(), 'initial stage is not virgin')
        before_revision = None
    else:
        expected = previous['evidence']
        prior_state, before = observe(box, recovery, schema, schema_version, previous=expected)
        require_retention(expected, before)
        require(all(expected[key] == before[key] for key in ('state', 'services')),
                'prior state or running service evidence differs')
        before_revision = previous['revision']
        require(prior_state['release']['revision'] == before_revision and box.existing_project(),
                'prior lifecycle or revision differs')

    if phase == 'negative':
        require(before_revision == candidate.revision, 'updated revision differs')
        reject_schema(box, candidate, work, composition, schema, recovery)
        state, evidence = observe(box, recovery, schema, schema_version, fenced=True, previous=before)
        require(state == prior_state and {**evidence, 'services': before['services']} == before,
                'refusal changed persistent data or resource identities')
        return state, evidence

    address, output = quiet(release.run_ci_staging, box, candidate, work, composition, schema,
                            box.volume, recovery=recovery)
    receipt = parse_receipt(output)
    lifecycle = 'initialized' if phase == 'init' else 'updated'
    check_receipt(receipt, box, lifecycle, schema, before_revision, candidate.revision, address)
    state, evidence = observe(box, recovery, schema, schema_version)
    current, rollback = state['release'], state['previous_release']
    require(current['revision'] == candidate.revision)
    if phase == 'init':
        require(rollback['revision'] == candidate.previous and state['history'] == [current] and
                current == receipt['release'] and rollback == receipt['previous_release'],
                'initial state or rollback does not match receipt')
    else:
        mutable = {'release', 'previous_release', 'history', 'updated_at'}
        require({k: v for k, v in state.items() if k not in mutable} ==
                {k: v for k, v in prior_state.items() if k not in mutable} and
                rollback == prior_state['release'] and state['history'] == prior_state['history'] + [current],
                'update altered bound staging state')
        require(receipt.get('release') == current and
                receipt.get('previous_release') == rollback and
                receipt['rollback'].get('release') == rollback,
                'updated receipt release proof differs')
        ids = ('api_image_id', 'web_image_id')
        require(all(current[key] != rollback[key] for key in ids) and
                receipt['releases']['b'] == [candidate.revision, [current[key] for key in ids]],
                'updated deploy did not run two distinct artifacts')
        require_retention(before, evidence)
    return state, evidence


def execute(phase, receipt, environ):
    root = Path(environ.get('T34_PROOF_WORK_DIR', ''))
    private_directory(root)
    require(root != REPO and REPO not in root.parents, 'run directory is inside the checkout')
    run_id = environ.get('T34_PROOF_RUN_ID')
    namespace(run_id)
    with exclusive_run(root):
        engine = EngineBinding.from_parent(environ, root)
        receipt = stage_paths(root, receipt, engine)
        (initial, update, rollback), trusted = bind_revisions(environ)
        context = {
            'run_id': run_id, 'trusted_sha': trusted, 'revisions': [initial, update, rollback],
            'host': engine.host, 'engine_id': engine.engine_id, 'socket': list(engine.socket_identity),
            'data_root': list(engine.data_identity),
        }
        prior = predecessor(root, phase, context, now_ns=time.monotonic_ns(), pid=os.getpid())
        require(prior is None or prior['revision'] == (initial if phase == 'update' else update))
        record_path = stage_record(root, phase)
        require(not record_path.exists() and not record_path.is_symlink(), 'stage record already exists')
        work = root / ('.t34-stage-' + phase)
        work.mkdir(mode=0o700)  # Durable run reservation: interrupted stages may not be replayed.
        candidate = materialize(REPO, work / 'candidate-inputs', initial if phase == 'init' else update, rollback)
        approvals = environ.get(release_approval.APPROVALS_ENV)
        require(approvals, 'decoder approval path missing')
        release_approval.load_document(approvals, (REPO,))
        composition, schema = release.validate_release(
            candidate.source, candidate.prior, rollback, approvals)
        if phase == 'init':
            next_release = materialize(REPO, work / 'update-inputs', update, rollback)
            _, next_schema = release.validate_release(
                next_release.source, next_release.prior, rollback, approvals)
            require(schema == next_schema, 'update schema differs from initialization')
        else:
            require(schema == prior['schema'], 'phase schema differs')

        owner = secrets.token_hex(24) if prior is None else prior['owner']
        box = HostedLab(work, (candidate.source, candidate.prior), run_id, engine, owner)
        recovery_path = root / RECOVERY
        if phase == 'init':
            require(not recovery_path.exists() and not recovery_path.is_symlink())
            provision(box, recovery_path)
        else:
            private_directory(recovery_path)
            box.attach_owned()
        quiet(box.config, expose=True)
        # The normal fixed-stage recovery object owns this exact provision and journal.
        with exclusive_run(recovery_path) as directory:
            recovery = staging_recovery.Recovery(box, box.volume, directory)
            state, evidence = run_phase(phase, box, recovery, candidate, work, composition, schema, prior)
        finished = time.monotonic_ns()
        revision = state['release']['revision']
        record = {'phase': phase, 'context': context, 'pid': os.getpid(), 'finished_ns': finished,
                  'owner': owner, 'revision': revision, 'schema': schema, 'evidence': evidence}
        write_private_json(receipt, {
            'phase': phase, 'pid': os.getpid(), 'result': 'pass',
            'revision': revision, 'schema_digest': schema, 'services': evidence['services'],
            'storage': {'volumes': len(evidence['volumes']), 'vault_snapshots': len(evidence['vault']),
                        'ledger_roots': evidence['ledger_roots'], 'verified': True, 'retained': phase != 'init'},
        })
        write_private_json(record_path, record)


def main(argv=None):
    try:
        parser = Parser(description=__doc__)
        parser.add_argument('phase', choices=PHASES)
        parser.add_argument('--receipt', required=True)
        args = parser.parse_args(argv)
        authorize_dispatch(os.environ)
        require(os.uname().sysname == 'Linux' and os.geteuid() > 0, 'unprivileged hosted Linux required')
        require(not any(name.startswith('T34_STAGING_') for name in os.environ),
                'fixed staging inputs are forbidden')
        os.umask(0o077)
        execute(args.phase, args.receipt, os.environ)
    except (Exception, KeyboardInterrupt):
        # Child command errors and private state must never reach hosted logs.
        print('T34 hosted stage refused or could not be verified', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())

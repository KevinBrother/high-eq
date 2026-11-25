"""Persistent synthetic staging state, fail-closed validation and storage probes."""
import base64
import copy
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re

STATE_VERSION = 3
STATE_FILE = 'staging-state.json'
STATE_VOLUME_ENV = 'T34_STAGING_STATE_VOLUME'
OWNER_LABEL = 'cn.higheq.t34.staging-owner'
ROLE_LABEL = 'cn.higheq.t34.staging-role'
STATE_ROLE = 'state'
DB_SERVICE = 'restored'
CACHE_SERVICE = 'coldcache'
HISTORY_LIMIT = 20
ABSENT_STATE = '__T34_STAGING_STATE_ABSENT__'

_UUID = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
_REPLAY_UUID = re.compile(_UUID.pattern.replace('[1-5]', '8'))
_SHA256 = re.compile(r'^[0-9a-f]{64}$')
_IMAGE_ID = re.compile(r'^sha256:[0-9a-f]{64}$')
_PASSWORD = re.compile(r'^[0-9a-f]{48}$')
_CHALLENGE = re.compile(r'^[0-9a-f]{48}$')
_MIGRATION = re.compile(r'^(\d+)_.*\.up\.sql$')
_VOLUME_NAME = re.compile(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$')
_CONTAINER_ID = re.compile(r'^[0-9a-f]{64}$')
_REFERENCE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$')
_ADMISSION_FIELDS = (
    'artifact_sha256',
    'decoder_sha256',
    'decoder_contract_version',
    'approval_document_sha256',
    'approved_by',
    'approval_ref',
    'approved_at',
    'decision',
)
# The approval document hash records the source document, but it changes whenever
# a later approval adds another release record. Bind the actual rollback object by
# every stable per-record admission field instead.
_BINDING_FIELDS = tuple(field for field in _ADMISSION_FIELDS
                        if field != 'approval_document_sha256')
_APPROVED_FIELDS = {
    'artifact_sha256',
    'decoder_sha256',
    'decoder_contract_version',
    'approved_by',
    'approval_ref',
    'approved_at',
    'decision',
}
_RELEASE_FIELDS = {
    'revision',
    'previous',
    'api_image_id',
    'web_image_id',
    'deployed_at',
    *_ADMISSION_FIELDS,
}


class StateVolumeUnverified(ValueError):
    """The state volume cannot be used as evidence or written by this stage."""


class StateWriteUncertain(ValueError):
    """The state helper may still commit because its termination is unproven."""


class StateCommitAcknowledgementLost(ValueError):
    """The writer exited successfully and settled, but attach lost its acknowledgement."""


def state_payload(state):
    return (json.dumps(state, sort_keys=True, separators=(',', ':')) + '\n').encode()


# Only the fixed runner uses this writer. The freshly built Ops image already
# provides Python; use the writing FD for fsync and sync the rename separately.
_DURABLE_WRITER = f"""
import os, shutil, sys, tempfile

root = sys.argv[1]
directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
fd, tmp = tempfile.mkstemp(prefix='.staging-state.', dir=root)
try:
    with os.fdopen(fd, 'wb') as file:
        shutil.copyfileobj(sys.stdin.buffer, file)
        file.flush()
        os.fsync(file.fileno())
    os.replace(tmp, os.path.join(root, '{STATE_FILE}'))
    os.fsync(directory)
finally:
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    os.close(directory)
"""


def now():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z')


def schema_version(source):
    """Return the latest embedded migration version used by golang-migrate."""
    versions = []
    migrations = Path(source) / 'server/migrations'
    for path in sorted(migrations.glob('*.up.sql')) if migrations.is_dir() else []:
        match = _MIGRATION.fullmatch(path.name)
        if match:
            versions.append(int(match.group(1)))
    if not versions:
        raise ValueError('schema version missing')
    return str(max(versions))


def state_volume_name(environ=None):
    """Accept only a Docker volume name, never a host path or a mount spec."""
    value = (os.environ if environ is None else environ).get(STATE_VOLUME_ENV, '')
    if not isinstance(value, str) or not _VOLUME_NAME.fullmatch(value) or value in ('.', '..'):
        raise ValueError('staging state volume must be a provisioned named volume')
    return value


def require_state_volume(lab, volume, installation):
    """Verify that the project supplied the exact labelled state volume."""
    try:
        raw = lab.run('volume', 'inspect', '--format', '{{json .Labels}}', volume)
    except Exception as exc:
        raise StateVolumeUnverified('staging state volume unavailable') from exc
    try:
        labels = json.loads(raw or b'{}')
    except (TypeError, ValueError) as exc:
        raise StateVolumeUnverified('staging state volume labels invalid') from exc
    if not isinstance(labels, dict):
        raise StateVolumeUnverified('staging state volume labels invalid')
    if labels.get(OWNER_LABEL) != installation or labels.get(ROLE_LABEL) != STATE_ROLE:
        raise StateVolumeUnverified('staging state volume labels do not belong to this stage')
    return volume


def _helper_image(lab):
    return lab.env.get('PG_IMAGE') or 'postgres:17.6-alpine'


def read_state(lab, volume):
    """Read a caller-verified volume through a no-network helper; None only when absent."""
    script = (
        'set -eu; '
        f'if [ ! -e /state/{STATE_FILE} ]; then printf "%s\\n" "{ABSENT_STATE}"; exit 0; fi; '
        f'[ -f /state/{STATE_FILE} ] && [ ! -L /state/{STATE_FILE} ] || '
        'exit 1; '
        f'mode=$(stat -c %a /state/{STATE_FILE}); '
        f'[ "$mode" = 600 ] || exit 1; '
        f'cat /state/{STATE_FILE}'
    )
    raw = lab.run(
        'run', '--rm', '--network', 'none', '--read-only',
        '-v', volume + ':/state:ro', '--entrypoint', 'sh', _helper_image(lab), '-c', script,
    )
    raw = (raw or b'').strip()
    if raw == ABSENT_STATE.encode():
        return None
    try:
        state = json.loads(raw)
    except (TypeError, ValueError) as exc:
        raise ValueError('staging state file invalid') from exc
    if not isinstance(state, dict):
        raise ValueError('staging state file invalid')
    return state


def write_state(lab, volume, state, installation, *, verify_owner=None, verify_engine=None):
    """Atomically write state and only report a settled helper failure.

    A generic exception means the helper is proven gone and cannot commit later.
    StateWriteUncertain means callers must fence instead of reconciling from the
    currently observable file. A StateVolumeUnverified at any point also refuses
    reconciliation, even if no writer was started. For the fixed runner, only
    a successful durable writer exit proves commit; losing attach after that
    exit is surfaced separately from a visible but not proven durable state.
    """
    if verify_owner is None:
        require_state_volume(lab, volume, installation)
    else:
        verify_owner()
    script = (
        'set -eu; umask 077; '
        'tmp=$(mktemp /state/.staging-state.XXXXXXXX); '
        'trap \'rm -f "$tmp"\' EXIT HUP INT TERM; '
        'cat > "$tmp"; '
        'chmod 600 "$tmp"; '
        'mv "$tmp" /state/staging-state.json; '
        'trap - EXIT HUP INT TERM'
    )
    durable = verify_owner is not None
    writer = (('--user', '0:0', '--entrypoint', 'python3', lab.env['OPS_IMAGE'], '-c', _DURABLE_WRITER, '/state')
              if durable else ('--entrypoint', 'sh', _helper_image(lab), '-c', script))
    payload = state_payload(state)
    # docker create cannot run the helper. A failed create therefore cannot leave
    # a process able to commit, even if the daemon created a stopped container
    # before the client lost the response.
    try:
        created = lab.run(
            'create', '-i', '--network', 'none',
            '-v', volume + ':/state', *writer,
            timeout=30,
        )
    except BaseException as exc:
        if verify_owner is not None:
            # No start was sent, but a stopped helper may still exist with no
            # trusted ID. Keep the durable guard rather than retrying around it.
            raise StateWriteUncertain('staging state writer could not be proven settled') from exc
        raise
    try:
        writer_id = created.decode('ascii').strip()
    except (AttributeError, UnicodeDecodeError) as exc:
        raise StateWriteUncertain(
            'staging state writer could not be proven settled') from exc
    if not _CONTAINER_ID.fullmatch(writer_id):
        raise StateWriteUncertain(
            'staging state writer could not be proven settled') from ValueError(
                'staging state writer identity invalid')

    start_error = None
    try:
        if verify_owner is not None:
            verify_owner()
        lab.run(
            'start', '-a', '-i', writer_id, input=payload, timeout=120,
        )
    except BaseException as exc:
        start_error = exc

    durable_exit = False
    if durable:
        try:
            verify_engine()
            exit_status = lab.run('inspect', '--format', '{{.State.Status}}:{{.State.ExitCode}}',
                                  writer_id, timeout=30).strip()
            verify_engine()
            durable_exit = exit_status == b'exited:0'
        except BaseException as exc:
            start_error = start_error or exc
        if not durable_exit and start_error is None:
            start_error = ValueError('staging writer durable exit not verified')

    try:
        if verify_engine is not None:
            verify_engine()
        lab.run('rm', '-f', writer_id, timeout=30)
    except BaseException as remove_error:
        remove_failure = remove_error
    else:
        remove_failure = None

    try:
        if verify_engine is not None:
            verify_engine()
        remaining = lab.run(
            'ps', '-aq', '--filter', 'id=' + writer_id, timeout=30,
        ).strip()
        if verify_engine is not None:
            verify_engine()
    except BaseException as probe_error:
        raise StateWriteUncertain(
            'staging state writer could not be proven settled') from (remove_failure or probe_error)
    if remaining:
        raise StateWriteUncertain(
            'staging state writer could not be proven settled') from (remove_failure or ValueError(
                'staging state writer still present'))

    if start_error is not None:
        if durable_exit and isinstance(start_error, Exception):
            raise StateCommitAcknowledgementLost('staging durable commit acknowledgement lost') from start_error
        raise start_error


def marker_from_fixture(fixture):
    """Keep only non-credential persistence markers from the synthetic drill receipt."""
    try:
        marker = {
            'user_a': fixture['A']['user_id'],
            'user_b': fixture['B']['user_id'],
            'activities': fixture['Activities'],
            'sources': fixture['Sources'],
            'windows': fixture['Windows'],
            'requests': fixture['Requests'],
            'ledger_identity': fixture['Seal'],
            'deleted_roots': fixture['Expected'],
        }
    except (KeyError, TypeError) as exc:
        raise ValueError('synthetic fixture receipt incomplete') from exc
    if 'WindowCutoffs' in fixture:
        marker['window_cutoffs'] = fixture['WindowCutoffs']
    _validate_marker(marker)
    return marker


def _validate_marker(marker):
    if not isinstance(marker, dict):
        raise ValueError('staging persistence marker missing')
    for name in ('user_a', 'user_b'):
        if not isinstance(marker.get(name), str) or not _UUID.fullmatch(marker[name]):
            raise ValueError('staging persistence marker user invalid')
    for name in ('activities', 'sources', 'windows', 'requests'):
        values = marker.get(name)
        if (not isinstance(values, list) or len(values) != 2 or
                any(not isinstance(v, str) or not _UUID.fullmatch(v) for v in values)):
            raise ValueError('staging persistence marker ids invalid')
    seal = marker.get('ledger_identity')
    if not isinstance(seal, str) or not _UUID.fullmatch(seal[:-3]) or not seal.endswith(':45'):
        raise ValueError('staging persistence marker ledger identity invalid')
    roots = marker.get('deleted_roots')
    if (not isinstance(roots, list) or not roots or
            any(not isinstance(v, str) or not (_UUID.fullmatch(v) or _REPLAY_UUID.fullmatch(v)) for v in roots) or
            len(set(roots)) != len(roots)):
        raise ValueError('staging persistence marker deleted roots invalid')
    cutoffs = marker.get('window_cutoffs', {})
    logical = [root for root in roots if _REPLAY_UUID.fullmatch(root)]
    if (not isinstance(cutoffs, dict) or
            (cutoffs or logical) and (
                len(logical) != 1 or set(cutoffs) != {marker['windows'][0], logical[0]} or
                not set(cutoffs) <= set(roots) or
                any(type(value) is not int or value <= 0 for value in cutoffs.values()) or
                len(set(cutoffs.values())) != 1)):
        raise ValueError('staging persistence marker window cutoffs invalid')


def _validate_deadlines(deadlines, roots):
    if (not isinstance(deadlines, dict) or set(deadlines) != set(roots) or
            any(type(value) is not int or value <= 0 for value in deadlines.values())):
        raise ValueError('staging deletion ledger deadline witness invalid')


def bind_ledger_deadlines(lab, deadlines, window_cutoffs=None):
    lab.env.pop('LEDGER_WRITES', None)
    lab.env.update(LEDGER_RETENTION_MODE='persistent',
                   LEDGER_DEADLINES=json.dumps(deadlines, separators=(',', ':'), sort_keys=True),
                   LEDGER_WINDOW_CUTOFFS=json.dumps(window_cutoffs or {}, separators=(',', ':'), sort_keys=True))


def _credentials(lab):
    field_key = lab.env.get('TEST_FIELD_KEY', '')
    try:
        decoded = base64.b64decode(field_key, validate=True)
    except (ValueError, TypeError) as exc:
        raise ValueError('staging field key invalid') from exc
    if len(decoded) != 32:
        raise ValueError('staging field key invalid')
    credentials = {
        'db_password': lab.env.get('DB_PASS'),
        'cost_password': lab.env.get('COST_PASS'),
        'ledger_password': lab.env.get('LEDGER_PASS'),
        'field_key_base64': field_key,
    }
    for name in ('db_password', 'cost_password', 'ledger_password'):
        if not isinstance(credentials[name], str) or not _PASSWORD.fullmatch(credentials[name]):
            raise ValueError('staging credential invalid')
    return credentials


def _validate_admission_identity(identity, name='staging decoder admission'):
    if not isinstance(identity, dict):
        raise ValueError(name + ' missing')
    for field in ('artifact_sha256', 'decoder_sha256', 'approval_document_sha256'):
        if not isinstance(identity.get(field), str) or not _SHA256.fullmatch(identity[field]):
            raise ValueError(name + ' digest invalid')
    version = identity.get('decoder_contract_version')
    if type(version) is not int or version <= 0:
        raise ValueError(name + ' contract version invalid')
    approved_by = identity.get('approved_by')
    if not isinstance(approved_by, str) or not approved_by.strip() or len(approved_by) > 128:
        raise ValueError(name + ' approver invalid')
    if not isinstance(identity.get('approval_ref'), str) or not _REFERENCE.fullmatch(identity['approval_ref']):
        raise ValueError(name + ' approval reference invalid')
    try:
        approved_at = datetime.fromisoformat(identity.get('approved_at', '').replace('Z', '+00:00'))
    except (AttributeError, TypeError, ValueError) as exc:
        raise ValueError(name + ' approval time invalid') from exc
    if approved_at.tzinfo is None:
        raise ValueError(name + ' approval time must include a timezone')
    if identity.get('decision') != 'approved':
        raise ValueError(name + ' decision invalid')


def admission_identity(composition, role):
    """Extract the exact artifact, decoder and approval identity for one role."""
    if role not in ('candidate', 'previous'):
        raise ValueError('staging decoder admission role invalid')
    try:
        admission = composition['decoder_admission']
        contract = admission[role]
    except (KeyError, TypeError) as exc:
        raise ValueError('staging decoder admission missing') from exc
    if not isinstance(admission, dict) or not isinstance(contract, dict):
        raise ValueError('staging decoder admission invalid')
    contract_version = admission.get('contract_version')
    if (type(contract_version) is not int or contract_version <= 0 or
            contract.get('version') != contract_version):
        raise ValueError('staging decoder admission contract version invalid')
    identity = {
        'artifact_sha256': contract.get('artifact_sha256'),
        'decoder_sha256': contract.get('decoder_sha256'),
        'decoder_contract_version': contract_version,
        'approval_document_sha256': admission.get('approval_document_sha256'),
        'approved_by': contract.get('approved_by'),
        'approval_ref': contract.get('approval_ref'),
        'approved_at': contract.get('approved_at'),
        'decision': contract.get('decision'),
    }
    _validate_admission_identity(identity, 'staging decoder admission ' + role)
    return identity


def release_identity(release):
    """Return the persisted fields that a later approval can prove again."""
    _validate_admission_identity(release)
    return {field: release[field] for field in _BINDING_FIELDS}


def approved_admission_identities(composition):
    """Validate the detached document's complete approved artifact index."""
    try:
        admission = composition['decoder_admission']
        contract_version = admission['contract_version']
        document_sha256 = admission['approval_document_sha256']
        approved = admission['approved']
    except (KeyError, TypeError) as exc:
        raise ValueError('staging decoder approval index missing') from exc
    if type(contract_version) is not int or contract_version <= 0:
        raise ValueError('staging decoder approval index invalid')
    if not isinstance(approved, list) or not approved:
        raise ValueError('staging decoder approval index invalid')
    identities = []
    pairs = set()
    for record in approved:
        if not isinstance(record, dict) or set(record) != _APPROVED_FIELDS:
            raise ValueError('staging decoder approval index invalid')
        identity = {
            'artifact_sha256': record.get('artifact_sha256'),
            'decoder_sha256': record.get('decoder_sha256'),
            'decoder_contract_version': record.get('decoder_contract_version'),
            'approval_document_sha256': document_sha256,
            'approved_by': record.get('approved_by'),
            'approval_ref': record.get('approval_ref'),
            'approved_at': record.get('approved_at'),
            'decision': record.get('decision'),
        }
        _validate_admission_identity(identity, 'staging decoder approval index')
        if identity['decoder_contract_version'] != contract_version:
            raise ValueError('staging decoder approval contract version mismatch')
        pair = identity['artifact_sha256'], identity['decoder_sha256']
        if pair in pairs:
            raise ValueError('staging decoder approval index duplicate')
        pairs.add(pair)
        identities.append(identity)
    for role in ('candidate', 'previous'):
        expected = admission_identity(composition, role)
        binding = {field: expected[field] for field in _BINDING_FIELDS}
        if not any({field: identity[field] for field in _BINDING_FIELDS} == binding
                   for identity in identities):
            raise ValueError('staging decoder approval index missing ' + role)
    return identities


def require_approved_rollback(state, composition):
    """Prove the persisted release is one exact object in the current approval index."""
    if not isinstance(state, dict) or not isinstance(state.get('release'), dict):
        raise ValueError('staging previous release decoder admission mismatch')
    release = state['release']
    try:
        _validate_admission_identity(release)
        actual = release_identity(release)
        approved = approved_admission_identities(composition)
    except ValueError as exc:
        raise ValueError('staging previous release decoder admission mismatch') from exc
    if not any({field: identity[field] for field in _BINDING_FIELDS} == actual
               for identity in approved):
        raise ValueError('staging previous release decoder admission mismatch')
    return release


def _release_entry(revision, previous, result, deployed_at, suffix, identity):
    try:
        receipt_revision, images = result['releases'][suffix]
        api_image_id, web_image_id = images
    except (KeyError, IndexError, TypeError, ValueError) as exc:
        raise ValueError('staging release receipt incomplete') from exc
    if not isinstance(revision, str) or not revision:
        raise ValueError('staging release revision invalid')
    if receipt_revision != revision:
        raise ValueError('staging release receipt revision mismatch')
    if not _IMAGE_ID.fullmatch(api_image_id or '') or not _IMAGE_ID.fullmatch(web_image_id or ''):
        raise ValueError('staging release image id invalid')
    return {
        'revision': revision,
        'previous': previous,
        'api_image_id': api_image_id,
        'web_image_id': web_image_id,
        'deployed_at': deployed_at,
        **copy.deepcopy(identity),
    }


def _validate_release(release, name='staging release'):
    if not isinstance(release, dict):
        raise ValueError(name + ' missing')
    if set(release) != _RELEASE_FIELDS:
        raise ValueError(name + ' fields invalid')
    if not isinstance(release.get('revision'), str) or not release['revision']:
        raise ValueError(name + ' revision invalid')
    if release.get('previous') is not None and not isinstance(release.get('previous'), str):
        raise ValueError(name + ' previous invalid')
    if not _IMAGE_ID.fullmatch(release.get('api_image_id', '')) or not _IMAGE_ID.fullmatch(release.get('web_image_id', '')):
        raise ValueError(name + ' image id invalid')
    if not isinstance(release.get('deployed_at'), str) or not release['deployed_at']:
        raise ValueError(name + ' deployed_at invalid')
    _validate_admission_identity(release, name + ' decoder admission')


def build_state(lab, args, schema_digest, result, marker, schema_version_value=None,
                business_dump_sha256=None, *, composition):
    """Create the first state only after a complete initial synthetic drill succeeded."""
    stamp = now()
    current = _release_entry(args.revision, args.previous, result, stamp, 'b',
                             admission_identity(composition, 'candidate'))
    previous = _release_entry(args.previous, None, result, stamp, 'a',
                              admission_identity(composition, 'previous'))
    if schema_version_value is None:
        schema_version_value = schema_version(lab.source)
    if business_dump_sha256 is None:
        business_dump_sha256 = result.get('business_dump_sha256')
    if not _SHA256.fullmatch(business_dump_sha256 or ''):
        raise ValueError('staging business dump digest invalid')
    deadlines = result.get('ledger_deadlines')
    _validate_deadlines(deadlines, marker['deleted_roots'])
    return {
        'version': STATE_VERSION,
        'installation': lab.name,
        'schema_digest': schema_digest,
        'schema_version': schema_version_value,
        'db_service': DB_SERVICE,
        'cache_service': CACHE_SERVICE,
        'created_at': stamp,
        'updated_at': stamp,
        'challenge': lab.env.get('CHALLENGE'),
        'business_dump_sha256': business_dump_sha256,
        'ledger_deadlines': copy.deepcopy(deadlines),
        'credentials': _credentials(lab),
        'marker': copy.deepcopy(marker),
        'release': current,
        'previous_release': previous,
        'history': [copy.deepcopy(current)],
    }


def updated_state(state, args, schema_digest, schema_version_value, result, *, composition):
    """Append a successful in-place deployment without changing identity or schema."""
    require_approved_rollback(state, composition)
    stamp = now()
    release = _release_entry(
        args.revision, state['release']['revision'], result, stamp, 'b',
        admission_identity(composition, 'candidate'))
    history = copy.deepcopy(state.get('history', []))
    history.append(copy.deepcopy(release))
    updated = copy.deepcopy(state)
    updated.update({
        'schema_digest': schema_digest,
        'schema_version': schema_version_value,
        'updated_at': stamp,
        'release': release,
        'previous_release': copy.deepcopy(state['release']),
        'history': history[-HISTORY_LIMIT:],
    })
    return updated


def validate_state(state, installation, schema_digest, schema_version_value):
    """Refuse missing, malformed, wrong-owner or schema-drifted persistent state."""
    if not isinstance(state, dict) or state.get('version') != STATE_VERSION:
        raise ValueError('staging state version unsupported')
    if state.get('installation') != installation:
        raise ValueError('staging state installation mismatch')
    if state.get('schema_digest') != schema_digest:
        raise ValueError('staging state schema digest mismatch')
    if state.get('schema_version') != schema_version_value:
        raise ValueError('staging state schema version mismatch')
    if state.get('db_service') != DB_SERVICE or state.get('cache_service') != CACHE_SERVICE:
        raise ValueError('staging state storage services mismatch')
    if not _CHALLENGE.fullmatch(state.get('challenge', '')):
        raise ValueError('staging state challenge invalid')
    if not _SHA256.fullmatch(state.get('business_dump_sha256', '')):
        raise ValueError('staging state business dump digest invalid')
    credentials = state.get('credentials')
    if not isinstance(credentials, dict):
        raise ValueError('staging state credentials missing')
    for name in ('db_password', 'cost_password', 'ledger_password'):
        if not isinstance(credentials.get(name), str) or not _PASSWORD.fullmatch(credentials[name]):
            raise ValueError('staging state credential invalid')
    try:
        field_key = base64.b64decode(credentials.get('field_key_base64', ''), validate=True)
    except (ValueError, TypeError) as exc:
        raise ValueError('staging state field key invalid') from exc
    if len(field_key) != 32:
        raise ValueError('staging state field key invalid')
    _validate_marker(state.get('marker'))
    _validate_deadlines(state.get('ledger_deadlines'), state['marker']['deleted_roots'])
    release = state.get('release')
    _validate_release(release)
    previous = state.get('previous_release')
    if previous is None:
        raise ValueError('staging state previous release missing')
    _validate_release(previous, 'staging state previous release')
    history = state.get('history')
    if not isinstance(history, list) or not history or len(history) > HISTORY_LIMIT:
        raise ValueError('staging state history invalid')
    for entry in history:
        _validate_release(entry, 'staging state history')
    if release.get('previous') != previous.get('revision'):
        raise ValueError('staging state previous release mismatch')
    if history[-1] != release:
        raise ValueError('staging state history does not end at the current release')
    return state


def lifecycle(state, project_exists):
    """Classify only the two safe persistent-staging transitions."""
    if not isinstance(project_exists, bool):
        raise ValueError('staging project existence is unproven')
    if state is None and not project_exists:
        return 'initialized'
    if state is not None and project_exists:
        return 'updated'
    if state is None:
        raise ValueError('staging project exists without provisioning state')
    raise ValueError('staging state exists without its project')


def apply_to_lab(lab, state):
    credentials = state['credentials']
    lab.env.update(
        DB_PASS=credentials['db_password'],
        COST_PASS=credentials['cost_password'],
        LEDGER_PASS=credentials['ledger_password'],
        TEST_FIELD_KEY=credentials['field_key_base64'],
        CHALLENGE=state['challenge'],
        DB_SERVICE=state['db_service'],
        CACHE_SERVICE=state['cache_service'],
        BUSINESS_DUMP_SHA256=state['business_dump_sha256'],
    )
    bind_ledger_deadlines(lab, state['ledger_deadlines'], state['marker'].get('window_cutoffs'))


def _sql_value(lab, query):
    value = lab.sql(DB_SERVICE, query)
    if value == '':
        raise ValueError('staging storage probe returned no value')
    return value


def verify_storage(lab, state, inventory_fn=None):
    """Prove the retained DB, migration version, ledger binding and marker still agree."""
    marker = state['marker']
    expected_schema = state['schema_version'] + ':false'
    if _sql_value(lab, "select version::text || ':' || dirty::text from schema_migrations") != expected_schema:
        raise ValueError('staging schema migration state mismatch')
    binding = _sql_value(lab, "select ledger_id::text || ':45' from ledger_binding")
    if binding != marker['ledger_identity']:
        raise ValueError('staging database ledger binding mismatch')
    user_a = marker['user_a']
    user_b = marker['user_b']
    keep_window = marker['windows'][1]
    request_a = marker['requests'][0]
    if _sql_value(lab, f"select count(*) from users where id='{user_a}'") != '1':
        raise ValueError('staging retained user missing')
    if _sql_value(lab, f"select count(*) from users where id='{user_b}'") != '0':
        raise ValueError('staging erased user returned')
    if _sql_value(lab, f"select count(*) from signal_windows where purge_id='{keep_window}'") != '1':
        raise ValueError('staging retained signal history missing')
    if _sql_value(lab, f"select count(*) from review_tombstones where user_id='{user_a}' and request_id='{request_a}'") != '1':
        raise ValueError('staging review tombstone missing')
    if _sql_value(lab, "select count(*) from pending_erasure") != '0':
        raise ValueError('staging pending erasure is not empty')
    if inventory_fn is None:
        from lab import inventory as inventory_fn
    bind_ledger_deadlines(lab, state['ledger_deadlines'], state['marker'].get('window_cutoffs'))
    try:
        identity, deadlines = inventory_fn(lab)
    except (ValueError, RuntimeError) as exc:
        raise ValueError('staging deletion ledger inventory refused') from exc
    if identity != marker['ledger_identity']:
        raise ValueError('staging deletion ledger identity mismatch')
    if deadlines != state['ledger_deadlines']:
        raise ValueError('staging deletion ledger roots or deadlines mismatch')
    return True

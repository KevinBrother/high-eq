"""Run the real release lifecycle and compare persistence evidence in memory."""
from contextlib import redirect_stderr, redirect_stdout
from copy import deepcopy
from hashlib import sha256
import io
import json
import re

from isolated_staging_lab import lab, staging
import release


class ProofError(ValueError):
    pass


def prove(condition):
    if not condition:
        raise ProofError('persistence assertion failed')


def quiet(fn, *args, **kw):
    output = io.StringIO()
    with redirect_stdout(output), redirect_stderr(io.StringIO()):
        result = fn(*args, **kw)
    return result, output.getvalue()


def parse_receipt(output):
    receipts = [json.loads(line) for line in output.splitlines() if line.startswith('{')]
    prove(len(receipts) == 1 and isinstance(receipts[0], dict))
    return receipts[0]


def check_receipt(receipt, box, lifecycle, schema, before, after, address):
    wanted = dict(result='synthetic-pass', lifecycle=lifecycle, mode='ci-staging',
                  state_volume=box.volume, schema_digest=schema, before_revision=before,
                  after_revision=after, storage_verified=True, production='blocked')
    prove(all(key in receipt and receipt[key] == value for key, value in wanted.items()) and
          receipt['storage_verified'] is True)
    current_release = receipt.get('release')
    previous_release = receipt.get('previous_release')
    rollback = receipt.get('rollback')
    prove(isinstance(current_release, dict) and current_release.get('revision') == after)
    prove(isinstance(previous_release, dict))
    prove(isinstance(rollback, dict))
    prove(rollback.get('attempted') is False and rollback.get('succeeded') is None)
    if lifecycle == 'initialized':
        # Initialization has no prior staging revision. The receipt still names
        # the previous release for the production rollback input, but the
        # staging rollback field remains empty.
        expected_rollback = None
    else:
        expected_rollback = before
        prove(previous_release.get('revision') == before)
        prove(isinstance(rollback.get('release'), dict) and
              rollback['release'].get('revision') == before)
    prove(rollback.get('revision') == expected_rollback)
    matched = re.fullmatch(r'127\.0\.0\.1:([1-9][0-9]{0,4})', address or '')
    prove(matched and int(matched[1]) <= 65535)


def pg_fingerprint(box, marker):
    # The production probe proves presence/absence. Additionally compare the complete
    # stable marker rows, and the PostgreSQL cluster IDs of both backing volumes.
    rows = []
    for service in ('db', staging.DB_SERVICE):
        rows.append(box.sql(service, 'select system_identifier::text from pg_control_system()'))
        prove(rows[-1].isdigit())
    for table, key, value in (('users', 'id', marker['user_a']),
                              ('signal_windows', 'purge_id', marker['windows'][1]),
                              ('review_tombstones', 'request_id', marker['requests'][0])):
        # Value has to be a UUID before entering SQL; names above are constants.
        prove(re.fullmatch(r'[0-9a-f-]{36}', value))
        row = box.sql(staging.DB_SERVICE, f"select to_jsonb(t)::text from {table} t where {key}='{value}'")
        prove(bool(row) and isinstance(json.loads(row), dict))
        rows.append(row)
    return sha256(json.dumps(rows).encode()).hexdigest()


def vault_fingerprint(box, digest):
    # ops.sh publishes whole snapshot directories by rename; skip in-progress .partial directories.
    # Read completed snapshots through the lab's one-shot, read-only helper. A
    # rejected update may already have stopped backup, so never exec into the
    # consumer to collect post-fencing evidence.
    entries = {}
    for line in box.vault_entries().decode().splitlines():
        name, *checksums = line.split()
        prove(re.fullmatch(r'snap-[a-zA-Z0-9]+', name) and name not in entries and len(checksums) == 3 and
              all(re.fullmatch(r'[a-f0-9]{64}', checksum) for checksum in checksums))
        entries[name] = tuple(checksums)
    prove(any(values[0] == digest for values in entries.values()))
    return entries


def ledger_fingerprint(box, marker):
    seal, roots = lab.inventory(box)
    prove(seal == marker['ledger_identity'] and sorted(roots) == sorted(marker['deleted_roots']))
    expiry = {}
    for root in roots:
        deadline = box.exec('ledger', 'redis-cli', '--raw', 'PEXPIRETIME', 'deleted:' + root).decode().strip()
        prove(deadline.isdigit() and int(deadline) > 0)
        expiry[root] = deadline
    return seal, expiry


def storage_evidence(box, state):
    prove(staging.verify_storage(box, state) is True)
    return (pg_fingerprint(box, state['marker']), vault_fingerprint(box, state['business_dump_sha256']),
            ledger_fingerprint(box, state['marker']))


def snapshot(box):
    # Bind every resource to this dedicated engine and private owner token before
    # reading any evidence, then prove the same resource set survived collection.
    identities = box.resource_identities()
    state = staging.read_state(box, box.volume)
    prove(isinstance(state, dict))
    evidence = (state, box.state_file_fingerprint(), storage_evidence(box, state), identities)
    prove(box.resource_identities() == identities)
    return evidence


def reject_mismatch(box, args, work, composition, schema, healthy_state):
    # The negative probe itself mutates the state file. Refuse to create that
    # mismatch unless all visible resources still prove this run's ownership.
    identities = box.resource_identities()
    mismatched = deepcopy(healthy_state)
    mismatched['schema_digest'] = ('0' if schema[0] != '0' else '1') + schema[1:]
    staging.write_state(box, box.volume, mismatched, box.name)
    before = snapshot(box)
    prove(before[0] == mismatched and before[3] == identities)
    try:
        quiet(release.run_ci_staging, box, args, work, composition, schema, box.volume)
    except ValueError as error:
        prove(str(error) == 'staging state schema digest mismatch')  # never render the message
    else:
        raise ProofError('schema mismatch was not rejected')
    try:
        box.fenced()
    except Exception as error:
        raise ProofError('schema mismatch rejection did not fence serving') from error
    # The production failure path stops ingress and consumers. Their container
    # identities remain part of the snapshot, while running state intentionally
    # does not, so the persistent assets and resource ownership must be unchanged.
    prove(snapshot(box) == before)
    # Restoring the synthetic probe is also a mutation: bind the resource set
    # once more instead of relying on the earlier snapshot.
    prove(box.resource_identities() == before[3])
    staging.write_state(box, box.volume, healthy_state, box.name)
    prove(staging.read_state(box, box.volume) == healthy_state)


def run_proof(box, first, second, work, compositions, schema, report):
    report.stage = 'preflight'
    box.claim()
    quiet(box.config, expose=True)
    report.passed()
    report.stage = 'initialize'
    address, output = quiet(release.run_ci_staging, box, first, work, compositions[0], schema, box.volume)
    receipt = parse_receipt(output)
    check_receipt(receipt, box, 'initialized', schema, None, first.revision, address)
    original = staging.read_state(box, box.volume)
    staging.validate_state(original, box.name, schema, staging.schema_version(first.source))
    prove(original['release'] == receipt['release'] and original['previous_release'] == receipt['previous_release'] and
          original['release']['revision'] == first.revision and original['previous_release']['revision'] == first.previous and
          original['history'] == [original['release']])
    before_pg, before_vault, before_ledger = storage_evidence(box, original)
    report.passed()

    report.stage = 'update'
    box.source = second.source
    address, output = quiet(release.run_ci_staging, box, second, work, compositions[1], schema, box.volume)
    receipt = parse_receipt(output)
    check_receipt(receipt, box, 'updated', schema, first.revision, second.revision, address)
    current = staging.read_state(box, box.volume)
    staging.validate_state(current, box.name, schema, staging.schema_version(second.source))
    changing = {'release', 'previous_release', 'history', 'updated_at'}
    prove({k: v for k, v in current.items() if k not in changing} ==
          {k: v for k, v in original.items() if k not in changing})
    new = current['release']
    prove(new['revision'] == second.revision and new['previous'] == first.revision and
          current['previous_release'] == original['release'] and current['history'] == original['history'] + [new] and
          receipt['release'] == new and receipt['previous_release'] == original['release'] and
          receipt['rollback']['release'] == original['release'] and
          receipt['releases']['b'] == [second.revision, [new['api_image_id'], new['web_image_id']]])
    after_pg, after_vault, after_ledger = storage_evidence(box, current)
    prove(before_pg == after_pg and before_ledger == after_ledger and
          all(after_vault.get(name) == checksums for name, checksums in before_vault.items()))
    report.passed()

    report.stage = 'reject-mismatch'
    reject_mismatch(box, second, work, compositions[1], schema, current)
    report.passed()

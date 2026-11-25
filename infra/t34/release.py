#!/usr/bin/env python3
"""Called by accept.sh on a credential-free candidate archive, never on production."""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from evidence import DAYS, check, coverage, manifest
import decoder_contract
from lab import (ALERT_WEBHOOK, CI_STAGING_PROJECT, HERE, Lab, composition_receipt,
                 inventory, same_schema, ticket_document)
import release_approval
import staging
import staging_recovery


def audit(lab, witness, frozen=None):
    lab.fenced()
    ack=json.loads(witness.read_bytes())
    seal, deadlines = inventory(lab)
    coverage(ack['seal'], ack['roots'], seal, deadlines)
    if frozen is not None and deadlines != frozen:
        raise ValueError('recovery changed deletion deadlines')
    return deadlines


def verify_before_restore(lab, seed, witness, deletion):
    # The drill supplies the Redis TIME bounds but does not read the markers.
    receipt = json.loads(deletion)
    writes = receipt['writes']
    cutoffs = seed['WindowCutoffs']
    if (not isinstance(writes, dict) or not isinstance(cutoffs, dict)
            or not set(cutoffs) <= set(writes)
            or any(not isinstance(write, list) or len(write) != 3
                   or write[2] != cutoffs.get(root, 0) for root, write in writes.items())):
        raise ValueError('deletion write witness does not match source fixture')
    coverage(seed['Seal'], seed['Expected'], receipt['seal'], writes)
    witness.write_text(json.dumps({'seal': receipt['seal'], 'roots': seed['Expected'], 'writes': writes}))
    lab.env['LEDGER_WRITES'] = json.dumps(writes, separators=(',', ':'))
    deadlines = audit(lab, witness)
    staging.bind_ledger_deadlines(lab, deadlines, cutoffs)
    return deadlines


# Real Resume can remark a root while committing the corresponding DB deletion.
# Let only the offline restore process write to a verified replay copy in Redis
# DB 1. The app, HTTP probe, audit and serving permit stay on DB 0.
_REPLAY_COPY = """
redis.call('SELECT',0)
local expected = cjson.decode(ARGV[2])
if redis.call('GET', 'ledger:identity') ~= ARGV[1] then return 0 end
local keys = {'ledger:identity'}
for root, deadline in pairs(expected) do
  local key = 'deleted:' .. root
  if redis.call('GET',key) ~= '' or redis.call('PEXPIRETIME',key) ~= deadline then return 0 end
  table.insert(keys,key)
end
for _, key in ipairs(redis.call('KEYS','*')) do
  if key ~= 'ledger:identity' and
    (string.sub(key,1,8) ~= 'deleted:' or expected[string.sub(key,9)] == nil) then return 0 end
end
redis.call('SELECT',1)
local empty = redis.call('DBSIZE') == 0
redis.call('SELECT',0)
if not empty then return 0 end
for _,key in ipairs(keys) do
  if redis.call('COPY', key, key, 'DB', 1) ~= 1 then return 0 end
end
redis.call('SELECT',1)
for root,deadline in pairs(expected) do
  if redis.call('PEXPIRETIME','deleted:' .. root) ~= deadline then return 0 end
end
return 1
"""
_PROBE_DROP_ROOT = """
redis.call('SELECT',1)
if redis.call('GET','ledger:identity') ~= ARGV[1] then return 0 end
local key = 'deleted:' .. ARGV[2]
if redis.call('GET',key) ~= '' or redis.call('PEXPIRETIME',key) ~= tonumber(ARGV[3]) then return 0 end
return redis.call('DEL',key)
"""
_REPLAY_CLEANUP = """
redis.call('SELECT',1)
if redis.call('GET', 'ledger:identity') ~= ARGV[1] then return 0 end
local expected = cjson.decode(ARGV[2])
local t = redis.call('TIME')
local now = t[1]*1000 + math.floor(t[2]/1000)
local keys = {'ledger:identity'}
for root, bounds in pairs(expected) do
  local key = 'deleted:' .. root
  local value = redis.call('GET',key)
  if value == '' then
    local deadline = redis.call('PEXPIRETIME',key)
    if deadline <= now or deadline < bounds[1] or deadline > bounds[2] then return 0 end
    table.insert(keys,key)
  elseif root ~= ARGV[3] or value ~= false then return 0 end
end
-- Verify exact membership before deleting in the same atomic Redis operation.
for _, key in ipairs(redis.call('KEYS','*')) do
  if key ~= 'ledger:identity' and
    (string.sub(key,1,8) ~= 'deleted:' or expected[string.sub(key,9)] == nil) then return 0 end
end
return redis.call('DEL', unpack(keys)) == #keys and 1 or 0
"""


def copy_replay_ledger(lab, seal, frozen):
    args = ('0', seal, json.dumps(frozen, sort_keys=True))
    copied = lab.exec('ledger', 'redis-cli', '--raw', 'EVAL', _REPLAY_COPY, *args, timeout=15)
    if copied.strip() != b'1':
        raise ValueError('isolated replay ledger copy refused')
    return args


def clear_replay_ledger(lab, args, missing='', bounds=None):
    number_of_keys, seal, frozen = args
    if bounds is None:
        bounds = {root: [end, end] for root, end in json.loads(frozen).items()}
    cleaned = lab.exec('ledger', 'redis-cli', '--raw', 'EVAL', _REPLAY_CLEANUP,
                       number_of_keys, seal, json.dumps(bounds, sort_keys=True), missing, timeout=15)
    if cleaned.strip() != b'1':
        raise ValueError('isolated replay ledger cleanup refused')


def _verify_window_plan(plan, seed, frozen):
    physical = uuid.UUID(plan['physical'])
    logical = plan['logical']
    current = seed['Windows'][0]
    cutoffs = seed['WindowCutoffs']
    if (set(plan) != {'physical', 'logical', 'cutoff_ms'}
            or physical.version != 4 or str(physical) != plan['physical']
            or logical == current or set(cutoffs) != {current, logical}
            or not set(cutoffs) <= set(frozen)
            or plan['cutoff_ms'] != cutoffs[logical] or plan['cutoff_ms'] != cutoffs[current]
            or (str(physical) != current and str(physical) in frozen)):
        raise ValueError('snapshot window replay plan differs from the deletion witness')


def _scratch_bounds(plan, seed, frozen, before, after):
    if not (type(before) is int and type(after) is int and 0 < before <= after <= before + 600000):
        raise ValueError('restore write interval invalid')
    current = seed['Windows'][0]
    physical = plan['physical']
    floors = seed['WindowCutoffs']
    entries = frozen | {physical: frozen.get(physical, 0)}
    retention = DAYS * 86400000
    return {
        root: [end, end] if root == current and physical != current else
        [max(end, floors.get(root, plan['cutoff_ms'] if root == physical else 0), stamp + retention)
         for stamp in (before, after)]
        for root, end in entries.items()
    }


def restore_replay(lab, raw, seal, witness, frozen):
    seed = json.loads(raw)
    # Read the snapshot row before giving Resume its writable scratch ledger.
    plan = json.loads(lab.job('drill', 'restore-plan', input=raw))
    _verify_window_plan(plan, seed, frozen)
    args = copy_replay_ledger(lab, seal, frozen)
    replay = json.loads(lab.job('drill', 'restore', input=raw))
    if replay['window'] != plan:
        raise ValueError('snapshot window replay plan changed during recovery')
    bounds = _scratch_bounds(plan, seed, frozen, replay['before_ms'], replay['after_ms'])
    audit(lab, witness, frozen)
    clear_replay_ledger(lab, args, bounds=bounds)


def refuse_missing_root(lab, seal, witness, frozen, root):
    args = copy_replay_ledger(lab, seal, frozen)
    try:
        removed = lab.exec('ledger', 'redis-cli', '--raw', 'EVAL', _PROBE_DROP_ROOT,
                           '0', seal, root, frozen[root], timeout=15)
        if removed.strip() != b'1':
            raise ValueError('could not remove the scratch probe root')
        lab.probe_missing_root(root)
    finally:
        # A lost DEL response is harmless to DB 0: cleanup accepts the scratch
        # set with or without the selected root and never tries to restore DB 0.
        try:
            clear_replay_ledger(lab, args, missing=root)
        finally:
            audit(lab, witness, frozen)


def backup(lab, work, image):
    name=lab.job('backup','once').decode().strip()
    if not re.fullmatch(r'snap-[a-zA-Z0-9]+',name): raise ValueError('invalid snapshot receipt')
    folder='/vault/'+name+'/'
    inventory=lab.job('backup',folder+'inventory',entry='cat').decode().split()
    if len(inventory)!=3: raise ValueError('invalid backup inventory')
    start,expires,scope=inventory
    checksum=lab.job('backup',folder+'SHA256SUMS',entry='cat').decode().split()[0]
    dump=work/'business.dump'
    with dump.open('xb') as out: lab.job('backup',folder+'business.dump',entry='cat',stdout=out)
    doc=manifest(dump,scope,image,int(start))
    if checksum!=doc['sha256'] or int(expires)!=doc['expires']: raise ValueError('backup transfer/retention mismatch')
    check(doc,dump,lab.name,image,int(time.time()))
    return name,doc,dump


def ticket_for(lab, seed, dump_sha, purpose):
    return ticket_document(
        installation=lab.name, db_service=lab.env.get('DB_SERVICE','db'),
        cache_service=lab.env.get('CACHE_SERVICE','cache'), challenge=lab.env['CHALLENGE'],
        seal=seed['Seal'], dump_sha256=dump_sha,
        roots=[] if purpose == 'initial' else seed['Expected'], purpose=purpose)


def cost_cases(lab):
    cases=(HERE/'tests/cost-cases.sql').read_bytes()
    result=lab.job('backup','-XqAt','-v','ON_ERROR_STOP=1',entry='psql',input=cases).decode().splitlines()
    # Six SQL probes produce seven rows: the NULL-price probe independently
    # emits both cost_anomaly and unpriced. Keep the real order and cardinality.
    expected=['normal','cost_anomaly','cost_anomaly','unpriced','normal','cost_anomaly','unpriced']
    if result!=expected: raise ValueError('cost threshold cases changed')


def seed_monitor_rows(lab):
    password=lab.env['COST_PASS']
    lab.sql('restored',f"""
      CREATE ROLE t34_cost LOGIN PASSWORD '{password}';
      GRANT SELECT(started_at,cost_cny) ON ai_calls TO t34_cost;
      WITH model AS (SELECT id FROM model_configs ORDER BY id LIMIT 1),
           boundary AS (
             SELECT date_trunc('day', now() AT TIME ZONE 'Asia/Shanghai')
                    AT TIME ZONE 'Asia/Shanghai' AS d
           )
      INSERT INTO ai_calls(model_id,task,outcome,started_at,cost_cny)
      SELECT model.id,'review_analysis'::ai_task,'ok',boundary.d - i*interval '1 day',1
      FROM model CROSS JOIN boundary CROSS JOIN generate_series(1,7) i
      UNION ALL
      SELECT model.id,'review_analysis'::ai_task,'ok',now(),3 FROM model
      UNION ALL
      SELECT model.id,'review_analysis'::ai_task,'ok',now(),NULL FROM model;
    """)


def failed_delivery_is_visible(lab):
    lab.compose('stop','alert-sink')
    failed=lab.compose('exec','-T','monitor','/ops/ops.sh','monitor-once',check=False)
    output=failed.stdout+failed.stderr
    if failed.returncode==0 or b'alert_delivery_failed' not in output:
        raise ValueError('alert delivery failure was not visible')
    lab.compose('up','-d','--wait','--wait-timeout','60','alert-sink')


def validate_release(source, prior, previous, decoder_approvals):
    if not re.fullmatch(r'[0-9a-f]{40}', previous or ''):
        raise ValueError('previous rollback revision must be a full commit SHA')
    digest = same_schema(source, prior)
    composition = composition_receipt(source)
    composition['rollback_chat_imports'] = composition_receipt(prior)['chat_imports']
    contracts = {
        'candidate': decoder_contract.inspect_release(source),
        'previous': decoder_contract.inspect_release(prior),
    }
    approval = release_approval.authorize(contracts, decoder_approvals, (source, prior))
    composition['decoder_admission'] = {
        'contract_version': decoder_contract.CONTRACT_VERSION,
        'approval_document_sha256': approval['document_sha256'],
        'candidate': {**contracts['candidate'], **approval['releases']['candidate']},
        'previous': {**contracts['previous'], **approval['releases']['previous']},
        'approved': approval['approved'],
    }
    return composition, digest


def deploy(lab,args,work,composition,schema,announce=True, *, prepare_only=False):
    src=lab.source;prev=args.prior
    releases={}
    for suffix,tree,version in [('a',prev,args.previous),('b',src,args.revision)]:
        releases[suffix]=(version,[lab.build(tree,'api','Dockerfile','api-'+suffix,version),
                                    lab.build(tree,None,'Web.Dockerfile','web-'+suffix,version)])
    lab.build(src,'drill','Dockerfile','drill',args.revision)
    lab.build(src,None,'Ops.Dockerfile','ops',args.revision)
    lab.build(src,None,'Sink.Dockerfile','sink',args.revision)
    image=releases['b'][1][0]

    # Bring up storage only. Seed, exercise the cost query, take the first real
    # snapshot, then issue a ticket that binds that snapshot and deletion roots.
    lab.compose('up','-d','--wait','db','cache','ledger')
    lab.compose('create','release-lock',overlay='production.yml')
    lock_id=lab.compose('ps','-aq','release-lock',overlay='production.yml').decode().strip()
    lab.run('start',lock_id)
    if lab.run('wait',lock_id).strip()!=b'78': raise ValueError('production not locked')
    lab.run('rm',lock_id)

    raw=lab.job('drill','seed');f=json.loads(raw)
    marker=staging.marker_from_fixture(f)
    cost_cases(lab)
    snapshot,doc,dump=backup(lab,work,image)
    lab.env['BUSINESS_DUMP_SHA256'] = doc['sha256']
    lab.permit(True,ticket_for(lab,f,doc['sha256'],'initial'))
    if prepare_only:
        lab.preflight_release(*releases['a'])
        if lab.gate_exit()!=0: raise ValueError('initial gate refused')
        lab.job('drill','preflight',input=raw)
    else:
        lab.open_release('a',*releases['a'])
        try:
            lab.open_release('b',*releases['b'])
        except (RuntimeError,ValueError):
            if not args.ci_staging:
                lab.open_release('a',*releases['a'])  # Ephemeral rehearsal only.
            raise
        lab.open_release('a',*releases['a']);lab.job('drill','preflight',input=raw)
        lab.open_release('b',*releases['b'])
        print('PASS release A -> B -> A -> B: immutable running image IDs, web bundle and API health',flush=True)
        lab.compose('stop','web','api','chat-sweeper')

    # Fence before deletion. The original ledger survives; the business DB and
    # cache are replaced only after the independent deletion witness is durable.
    lab.permit(False);lab.fenced()
    witness = work / 'deletion-receipt.json'
    deadlines = verify_before_restore(lab, f, witness, lab.job('drill', 'delete', input=raw))
    lab.compose('restart','ledger');lab.compose('up','-d','--wait','ledger')
    audit(lab, witness, deadlines)

    lab.compose('up','-d','--wait','restored','coldcache')
    lab.env.update(DB_SERVICE='restored',CACHE_SERVICE='coldcache')
    if lab.sql('restored',"select count(*) from pg_tables where schemaname='public'")!='0': raise ValueError('restore target not empty')
    check(doc,dump,lab.name,image,int(time.time()));lab.fenced()
    restored=lab.job('backup','restore',snapshot)
    if b'restore_ok' not in restored: raise ValueError('restore receipt missing')
    if lab.sql('restored',"SELECT ledger_id::text || ':45' FROM ledger_binding")!=f['Seal']:
        raise ValueError('restored binding disagrees with independent witness')
    restore_replay(lab, raw, f['Seal'], witness, deadlines)
    check(doc,dump,lab.name,image,int(time.time()))

    # A fresh challenge binds the restored target and the exact dump. The same
    # complete ticket must pass, then the same ticket must fail when one root is missing.
    lab.rotate_challenge();recovery_ticket=ticket_for(lab,f,doc['sha256'],'recovery')
    lab.env['BUSINESS_DUMP_SHA256'] = doc['sha256']
    lab.permit(True,recovery_ticket)
    if lab.gate_exit()!=0: raise ValueError('complete recovery gate refused')
    refuse_missing_root(lab, f['Seal'], witness, deadlines, f['Expected'][0])
    if lab.gate_exit()!=0: raise ValueError('complete recovery gate refused after isolated probe')
    if args.ci_staging:
        if lab.gate_exit() != 0:
            raise ValueError('persistent recovery gate refused')
    print('PASS complete ticket opens; isolated copy missing one root refuses the same ticket',flush=True)

    if not prepare_only:
        _restored_http_checks(lab, raw)

    # Seed evidence while closed. Fixed staging defers the actual maintenance
    # loops (including the alert smoke) until after its durable commit.
    seed_monitor_rows(lab)
    expose = not prepare_only and (args.preview or args.stage_test or args.ci_staging)
    delivered = None
    if not prepare_only:
        delivered = _initial_consumer_checks(lab)
        lab.open_release('b', *releases['b'], preview=expose)
    result=dict(result='prepared' if prepare_only else 'synthetic-pass',revision=args.revision,previous=args.previous,
                schema_digest=schema,
                same_schema_rollback=dict(previous=args.previous,schema_digest=schema,verified=not prepare_only),
                runtime_composition=composition,
                mode=('ci-staging' if args.ci_staging else 'stage-test' if args.stage_test else
                      'preview' if args.preview else 'ephemeral'),
                releases=releases,business_dump_sha256=doc['sha256'],retention_days=doc['max_days'],
                verified_roots=dict(initial=0,recovery=len(f['Expected'])),alerts=delivered,
                dependencies=[lab.run('image','inspect','--format','{{.Id}}',lab.env[k]).decode().strip()
                              for k in ('PG_IMAGE','REDIS_IMAGE','DRILL_IMAGE','OPS_IMAGE','SINK_IMAGE')],
                stages=['seed','backup','initial-ticket','backup','withdraw','fence','restore',
                        'recovery-ticket','refuse-incomplete','resume','replay','export','auth']
                       + ([] if prepare_only else ['httpcheck', 'alert', 'open']),
                production='blocked',persistence_marker=marker)
    if not prepare_only:
        result['httpcheck'] = '404/200/401'
    address=None
    if expose:
        address=lab.compose('port','web','8080',preview=True).decode().strip()
    if announce:
        print(json.dumps(result,sort_keys=True),flush=True)
        if address:
            print('Loopback synthetic stage: '+address,flush=True)
    if args.ci_staging:
        result['ledger_deadlines'] = deadlines
    if prepare_only:
        result['_httpcheck_fixture'] = raw  # In-memory input for post-commit authorization only.
    return address, result


def _restored_http_checks(lab, raw):
    # This probe calls service.Start, which can run startup consumers even
    # though the router is exercised in-process without opening API ingress.
    lab.job('drill','httpcheck',input=raw)
    print('PASS restored API returns review=404, surviving session=200, erased session=401',flush=True)


def _initial_consumer_checks(lab):
    # Both anomaly classes must reach the local, non-logging HTTP receiver.
    if lab.env['ALERT_WEBHOOK'] != ALERT_WEBHOOK:
        raise ValueError('external alert route forbidden')
    lab.compose('up','-d','--wait','--wait-timeout','60','alert-sink')
    before=lab.alert_count()
    lab.compose('up','--wait','--wait-timeout','120','-d','monitor','backup')
    delivered=lab.wait_alert_count(before+2)
    failed_delivery_is_visible(lab)
    health=lab.exec('backup','/ops/ops.sh','backup-health')
    if b'backup_fresh' not in health: raise ValueError('backup supervisor unhealthy')
    print('PASS parallel cost alerts delivered to local sink; delivery failure is non-zero',flush=True)
    return delivered


def staging_receipt(lifecycle, volume, schema, before_revision, after_revision,
                    rollback=None, **extra):
    """Public receipt only; credentials, field keys and tokens never enter it."""
    receipt = {
        'result': 'synthetic-pass',
        'lifecycle': lifecycle,
        'mode': 'ci-staging',
        'state_volume': volume,
        'schema_digest': schema,
        'before_revision': before_revision,
        'after_revision': after_revision,
        'storage_verified': True,
        'rollback': rollback or {
            'attempted': False,
            'succeeded': None,
            'revision': before_revision,
        },
        'production': 'blocked',
    }
    receipt.update(extra)
    return receipt


def _report_staging_failure(lifecycle, volume, before_revision, after_revision,
                            rollback, storage_verified, serving_fenced,
                            state_reconciliation=None, state_write_error=None,
                            operator_verification_required=False, release=None):
    receipt = {
        'result': 'synthetic-failed',
        'lifecycle': lifecycle,
        'mode': 'ci-staging',
        'state_volume': volume,
        'before_revision': before_revision,
        'after_revision': after_revision,
        'storage_verified': storage_verified,
        'serving_fenced': serving_fenced,
        'rollback': rollback,
        'production': 'blocked',
    }
    if state_reconciliation is not None:
        receipt['state_reconciliation'] = state_reconciliation
    if operator_verification_required:
        receipt['operator_verification_required'] = True
    if state_write_error is not None:
        # Exception type only: never render a command, state payload or credential.
        receipt['state_write_error'] = state_write_error
    if release is not None:
        receipt['release'] = copy.deepcopy(release)
    print(json.dumps(receipt, sort_keys=True), file=sys.stderr, flush=True)


def resume_consumers(lab):
    if lab.env['ALERT_WEBHOOK'] != ALERT_WEBHOOK:
        raise ValueError('external alert route forbidden')
    lab.compose('up', '-d', '--pull', 'never', '--wait', '--wait-timeout', '120',
                'alert-sink', 'monitor', 'backup')
    # --wait checks sink and backup health; the monitor also needs a real query
    # and delivery probe (monitor_unavailable can itself be delivered successfully).
    report = lab.exec('monitor', '/ops/ops.sh', 'monitor-once', timeout=120)
    status = rb'(?:normal|cost_anomaly|unpriced)'
    if not re.fullmatch(rb'ai_cost=' + status + rb'(?:,' + status + rb')* sink=webhook', report.strip()):
        raise ValueError('staging consumer health verification failed')
    before = lab.alert_count()
    lab.exec('monitor', '/ops/ops.sh', 'monitor-probe', timeout=20)
    lab.wait_alert_count(before + 1, timeout=10)


def _close_staging_serving(lab, recovery):
    if recovery is not None:
        recovery.verify_engine()
    lab.close_serving()
    if recovery is not None:
        recovery.verify_engine()


def _staging_failure(lab, lifecycle, volume, args, *, before=None, fallback=None,
                     storage_verified=False, consumers_verified=False, recovery=None,
                     release=None):
    """Shared failure path; only a previously signed-off, verified stage may keep serving."""
    rollback = {'attempted': fallback is not None, 'succeeded': None,
                'revision': fallback[0] if fallback else before}
    if release is not None:
        rollback['release'] = copy.deepcopy(release)
    rollback_error = None
    if fallback:
        revision, ids = fallback
        try:
            lab.open_release('rollback', revision, ids, preview=True, by_id=True)
        except BaseException as exc:
            rollback_error = exc
        rollback['succeeded'] = rollback_error is None

    fence_error = None
    serving_fenced = None
    if before is None or not (storage_verified and consumers_verified) or rollback_error is not None:
        try:
            _close_staging_serving(lab, recovery)
        except BaseException as exc:
            fence_error = exc
        serving_fenced = fence_error is None
    _report_staging_failure(lifecycle, volume, before, args.revision,
                            rollback, storage_verified, serving_fenced, release=release)
    if fence_error is not None:
        raise ValueError('staging failure: serving shutdown could not be verified') from fence_error
    if rollback_error is not None:
        raise ValueError(f'staging {lifecycle} failed and image rollback failed; serving fenced') from rollback_error


def running_release(lab):
    """Read the exact API/Web image IDs actually running for this project."""
    images = []
    for service in ('api', 'web'):
        containers = lab.compose('ps', '-q', service).decode().split()
        if len(containers) != 1:
            raise ValueError('running release service is not uniquely identifiable')
        image = lab.run('inspect', '--format', '{{.Image}}', containers[0]).decode().strip()
        if not re.fullmatch(r'sha256:[0-9a-f]{64}', image):
            raise ValueError('running release image is invalid')
        images.append(image)
    return images


def _require_bound_recovery(lab, volume, recovery):
    if recovery is None:
        # The independent acceptance fixture is not a fixed --ci-staging Lab.
        if getattr(lab, 'ci_staging', False) is not True:
            return
    elif recovery.lab is lab and recovery.volume == volume:
        return
    raise staging_recovery.RecoveryBlocked(staging_recovery.OPERATOR + ': recovery not bound to this stage')


def _read_owned_state(lab, volume, recovery):
    if recovery is not None:
        return recovery.read()
    # The separately scoped synthetic fixture has its own engine/owner checks.
    staging.require_state_volume(lab, volume, lab.name)
    return staging.read_state(lab, volume)


def _persisted_state_kind(lab, volume, original, updated, schema, schema_version_value,
                          recovery):
    try:
        persisted = _read_owned_state(lab, volume, recovery)
        if persisted is None:
            return 'uncertain'
        staging.validate_state(persisted, lab.name, schema, schema_version_value)
    except BaseException:
        return 'uncertain'
    if persisted == updated:
        return 'candidate'
    if persisted == original:
        return 'previous'
    return 'uncertain'


def _no_rollback(before=None, release=None):
    result = {'attempted': False, 'succeeded': None, 'revision': before}
    if release is not None:
        result['release'] = copy.deepcopy(release)
    return result


def _fence_state_write_failure(lab, args, volume, before, write_error,
                               state_reconciliation, rollback, detail, *, recovery=None,
                               lifecycle='updated', project_exists=True, storage_verified=True,
                               release=None):
    serving_fenced = None
    if project_exists:
        try:
            _close_staging_serving(lab, recovery)
        except BaseException:
            serving_fenced = False
        else:
            serving_fenced = True
    _report_staging_failure(
        lifecycle, volume, before, args.revision, rollback,
        storage_verified=storage_verified, serving_fenced=serving_fenced,
        state_reconciliation=state_reconciliation,
        state_write_error=type(write_error).__name__,
        operator_verification_required=recovery is not None,
        release=release,
    )
    if recovery is not None:
        detail += '; ' + staging_recovery.OPERATOR
    if serving_fenced is False:
        detail += '; serving shutdown could not be verified'
    elif serving_fenced is True:
        detail += '; serving fenced'
    raise ValueError(detail) from write_error


def _reconcile_state_write(lab, args, state, updated, volume, schema,
                           schema_version_value, write_error):
    """Use the owner-checked state file and actual images, never an unsettled writer."""
    before = state['release']['revision']
    previous_ids = [state['release']['api_image_id'], state['release']['web_image_id']]
    candidate_ids = [updated['release']['api_image_id'], updated['release']['web_image_id']]
    rollback = _no_rollback(before, state['release'])

    def fence(detail, outcome='uncertain', release=None):
        _fence_state_write_failure(lab, args, volume, before, write_error,
                                   outcome, rollback, detail, release=release)

    if isinstance(write_error, staging.StateWriteUncertain):
        fence('staging state writer could not be proven settled')
    if isinstance(write_error, (staging.StateVolumeUnverified, staging_recovery.RecoveryBlocked)):
        fence('staging state write preconditions or volume ownership could not be verified')

    def persisted_kind():
        return _persisted_state_kind(lab, volume, state, updated, schema,
                                     schema_version_value, None)

    state_kind = persisted_kind()
    if state_kind == 'uncertain':
        fence('staging state write failed with an uncertain outcome')
    try:
        running = running_release(lab)
    except BaseException:
        running = None

    if state_kind == 'candidate' and running == candidate_ids:
        outcome = 'committed'
        selected_release = updated['release']
        detail = 'after candidate commit; state and running release agree'
    elif state_kind == 'previous' and running == previous_ids:
        outcome = 'uncommitted'
        selected_release = state['release']
        detail = 'before commit; previous release remains consistent'
    elif state_kind == 'previous' and running == candidate_ids:
        rollback.update(attempted=True, succeeded=False)
        try:
            lab.open_release('rollback', before, previous_ids, preview=True, by_id=True)
        except BaseException:
            fence('staging state write failed before commit and rollback could not be verified',
                  'uncommitted')
        try:
            verified = persisted_kind() == 'previous' and running_release(lab) == previous_ids
        except BaseException:
            verified = False
        if not verified:
            fence('staging state write failed and rollback could not be verified')
        outcome = 'uncommitted'
        selected_release = state['release']
        detail = 'before commit; previous release restored and verified'
    else:
        fence('staging state write failed with an uncertain outcome')

    if rollback['attempted']:
        rollback['succeeded'] = True
    _report_staging_failure(
        'updated', volume, before, args.revision, rollback,
        storage_verified=True, serving_fenced=False,
        state_reconciliation=outcome,
        state_write_error=type(write_error).__name__,
        release=selected_release,
    )
    raise ValueError('staging state write failed ' + detail) from write_error


def _prepare_fixed_release(lab, release):
    ids = [release['api_image_id'], release['web_image_id']]
    lab.preflight_release(release['revision'], ids)


def _authorize_and_publish(lab, recovery, state, schema, schema_version_value, suffix, *, initial_fixture=None):
    """The only fixed-staging path that can start consumers or publish a port."""
    selected = state['release']
    ids = [selected['api_image_id'], selected['web_image_id']]
    staging.validate_state(state, lab.name, schema, schema_version_value)
    if recovery.read() != state:
        raise ValueError('staging state readback does not agree')
    _prepare_fixed_release(lab, selected)
    staging.verify_storage(lab, state)
    if lab.gate_exit() != 0:
        raise ValueError('persistent recovery gate refused at commit')
    lab.fenced()
    recovery.finish(state)
    recovery.verify_owner()
    if initial_fixture is not None:
        _restored_http_checks(lab, initial_fixture)
        staging.verify_storage(lab, state)
        recovery.verify_owner()
        _initial_consumer_checks(lab)
    else:
        resume_consumers(lab)
    recovery.verify_owner()
    lab.open_release(suffix, selected['revision'], ids, preview=True, by_id=True)
    address = lab.compose('port', 'web', '8080', preview=True).decode().strip()
    if not address:
        raise ValueError('staging loopback port could not be verified')
    lab.require_chat_sweeper()
    return address


def _update_fixed_stage(lab, args, state, volume, composition, schema, schema_version_value, recovery):
    # Defense in depth: the long-lived state release is the only possible rollback,
    # and it must be the exact object approved as previous before anything closes.
    staging.require_approved_rollback(state, composition)
    before = state['release']['revision']
    rollback = _no_rollback(before, state['release'])
    outcome = 'uncertain'
    proven_release = None
    storage_verified = False
    try:
        # Stop the already-authorized A before changing any storage. Remove only
        # stopped serving tiers, so final startup creates fresh serving
        # containers. No volumes are removed.
        _close_staging_serving(lab, recovery)
        recovery.begin()
        recovery.assert_idle()
        lab.compose('--profile', 'serve', 'rm', '-f', 'web', 'api', timeout=30)
        lab.compose('up', '-d', '--wait', '--wait-timeout', '120',
                    'db', 'cache', 'ledger', 'restored', 'coldcache')
        staging.verify_storage(lab, state)
        lab.build(lab.source, None, 'Ops.Dockerfile', 'ops', args.revision)
        if lab.gate_exit() != 0:
            raise ValueError('persistent recovery gate refused')
        storage_verified = True
        ids = [lab.build(lab.source, 'api', 'Dockerfile', 'api-b', args.revision),
               lab.build(lab.source, None, 'Web.Dockerfile', 'web-b', args.revision)]
        result = {'releases': {'b': [args.revision, ids]}}
        updated = staging.updated_state(
            state, args, schema, schema_version_value, result, composition=composition)

        failure = None
        try:
            _prepare_fixed_release(lab, updated['release'])
            recovery.write(updated)
        except (ValueError, RuntimeError, OSError, subprocess.TimeoutExpired) as exc:
            # Treat stale state as evidence only after the exact writer settled.
            if isinstance(exc, (staging.StateWriteUncertain, staging.StateVolumeUnverified,
                                staging_recovery.RecoveryBlocked)):
                raise
            failure = exc
            observed = _persisted_state_kind(lab, volume, state, updated, schema,
                                             schema_version_value, recovery)
            if isinstance(exc, staging.StateCommitAcknowledgementLost):
                # Successful durable exit was inspected by immutable container ID
                # before cleanup. A contradictory readback cannot authorize A or B.
                if observed != 'candidate':
                    raise
                outcome = 'committed'
            elif observed == 'previous':
                outcome = 'uncommitted'
                rollback.update(attempted=True, succeeded=False)
                _prepare_fixed_release(lab, state['release'])
            else:
                raise
        if outcome == 'uncommitted':
            proven_release = state['release']
            address = _authorize_and_publish(lab, recovery, state, schema, schema_version_value, 'rollback')
            rollback['succeeded'] = True
        else:
            if outcome != 'committed':
                # A successful writer return is not enough for the receipt: prove
                # the exact committed object before authorizing or reporting it.
                if recovery.read() != updated:
                    raise ValueError('staging state write readback does not agree')
                outcome = 'committed'
            proven_release = updated['release']
            address = _authorize_and_publish(lab, recovery, updated, schema, schema_version_value, 'b')
    except BaseException as exc:
        _fence_state_write_failure(
            lab, args, volume, before, exc, 'uncertain', rollback,
            'staging transition could not be proved safe', recovery=recovery,
            storage_verified=storage_verified, release=proven_release)
    if failure is not None:
        _report_staging_failure(
            'updated', volume, before, args.revision, rollback, storage_verified=True,
            serving_fenced=False, state_reconciliation=outcome,
            state_write_error=type(failure).__name__, release=proven_release)
        raise ValueError('staging transition reconciled to ' + outcome) from failure
    receipt = staging_receipt(
        'updated', volume, schema, before, args.revision,
        rollback=_no_rollback(before, state['release']),
        releases=result['releases'], release=updated['release'],
        previous_release=updated['previous_release'], runtime_composition=composition)
    print(json.dumps(receipt, sort_keys=True), flush=True)
    print('Loopback synthetic stage: ' + address, flush=True)
    return address


def update_release(lab, args, state, volume, composition, schema, schema_version_value,
                   *, recovery=None):
    """Update only API/Web over proven storage; roll back only on proven evidence."""
    _require_bound_recovery(lab, volume, recovery)
    staging.require_approved_rollback(state, composition)
    if recovery is not None:
        return _update_fixed_stage(lab, args, state, volume, composition, schema, schema_version_value, recovery)
    # Legacy synthetic rehearsal only; not reachable from the fixed CLI.
    previous = state['release']
    before = previous['revision']
    previous_ids = [previous['api_image_id'], previous['web_image_id']]
    storage_verified = consumers_verified = False
    fallback = None
    write_attempted = False
    try:
        lab.compose('up', '-d', '--wait', '--wait-timeout', '120',
                    'db', 'cache', 'ledger', 'restored', 'coldcache')
        staging.verify_storage(lab, state)
        lab.build(lab.source, None, 'Ops.Dockerfile', 'ops', args.revision)
        if lab.gate_exit() != 0:
            raise ValueError('persistent recovery gate refused')
        storage_verified = True
        image_ids = [
            lab.build(lab.source, 'api', 'Dockerfile', 'api-b', args.revision),
            lab.build(lab.source, None, 'Web.Dockerfile', 'web-b', args.revision),
        ]
        result = {'releases': {'b': [args.revision, image_ids]}}
        resume_consumers(lab)
        consumers_verified = True
        fallback = (before, previous_ids)
        lab.open_release('b', args.revision, image_ids, preview=True)
        address = lab.compose('port', 'web', '8080', preview=True).decode().strip()
        lab.require_chat_sweeper()
        updated = staging.updated_state(
            state, args, schema, schema_version_value, result, composition=composition)
        write_attempted = True
        staging.write_state(lab, volume, updated, lab.name)
    except BaseException as exc:
        if write_attempted:
            _reconcile_state_write(lab, args, state, updated, volume, schema,
                                   schema_version_value, exc)
        _staging_failure(lab, 'updated', volume, args, before=before, fallback=fallback,
                         storage_verified=storage_verified, consumers_verified=consumers_verified,
                         release=state['release'])
        raise

    receipt = staging_receipt(
        'updated', volume, schema, before, args.revision,
        rollback=_no_rollback(before, state['release']), releases=result['releases'],
        release=updated['release'], previous_release=updated['previous_release'],
        runtime_composition=composition,
    )
    print(json.dumps(receipt, sort_keys=True), flush=True)
    print('Loopback synthetic stage: ' + address, flush=True)
    return address


def run_ci_staging(lab, args, work, composition, schema, volume, *, recovery=None):
    """Initialize once or update in place; the CLI always supplies trusted recovery."""
    _require_bound_recovery(lab, volume, recovery)
    # Establish exact volume and Compose project ownership before any shutdown.
    # The separate isolated acceptance fixture (no production CLI) owns its
    # provisioned resources through its own guard and does not use the runner journal.
    if recovery is None:
        staging.require_state_volume(lab, volume, lab.name)
    else:
        try:
            recovery.verify_owner()
        except staging.StateVolumeUnverified as exc:
            raise staging_recovery.RecoveryBlocked(
                staging_recovery.OPERATOR + ': trusted daemon or original state volume not verified') from exc
    project_exists = lab.existing_project()
    try:
        state = (recovery.read_initial() if recovery is not None else
                 _read_owned_state(lab, volume, recovery))
        lifecycle = staging.lifecycle(state, project_exists)
        schema_version_value = staging.schema_version(args.source)
        if lifecycle == 'updated':
            staging.validate_state(state, lab.name, schema, schema_version_value)
            staging.apply_to_lab(lab, state)
    except BaseException as exc:
        if recovery is not None and isinstance(exc, (staging.StateVolumeUnverified,
                                                      staging_recovery.RecoveryBlocked)):
            _fence_state_write_failure(
                lab, args, volume, None, exc, 'uncertain', _no_rollback(),
                'staging startup could not prove the prior transition safe', recovery=recovery,
                lifecycle='updated' if project_exists else 'initialized', project_exists=project_exists,
                storage_verified=False)
        if project_exists is True:
            _staging_failure(lab, 'updated', volume, args, recovery=recovery)
        raise
    if lifecycle == 'updated':
        # This refusal is intentionally outside the startup failure handler:
        # a mismatch must leave the already-authorized service untouched.
        staging.require_approved_rollback(state, composition)
    if lifecycle == 'initialized':
        storage_verified = started = False
        try:
            if recovery is not None:
                recovery.begin()
                recovery.assert_idle()
            lab.start()
            started = True
            options = {'prepare_only': True} if recovery is not None else {}
            address, result = deploy(lab, args, work, composition, schema, announce=False, **options)
            state = staging.build_state(
                lab, args, schema, result, result['persistence_marker'],
                schema_version_value=schema_version_value, composition=composition)
            staging.verify_storage(lab, state)
            storage_verified = True
            if recovery is None:
                staging.write_state(lab, volume, state, lab.name)
            else:
                _prepare_fixed_release(lab, state['release'])
                recovery.write(state)
                address = _authorize_and_publish(lab, recovery, state, schema, schema_version_value,
                                                 'b', initial_fixture=result.pop('_httpcheck_fixture'))
        except BaseException as exc:
            if recovery is not None:
                _fence_state_write_failure(
                    lab, args, volume, None, exc, 'uncertain', _no_rollback(),
                    'staging initialization did not finish', recovery=recovery,
                    lifecycle='initialized', project_exists=started, storage_verified=storage_verified)
            _staging_failure(lab, 'initialized', volume, args, storage_verified=storage_verified)
            raise
        receipt = staging_receipt(
            'initialized', volume, schema, None, args.revision,
            release=state['release'], previous_release=state['previous_release'],
            runtime_composition=composition,
        )
        print(json.dumps(receipt, sort_keys=True), flush=True)
        if address:
            print('Loopback synthetic stage: ' + address, flush=True)
        return address
    lab.start(allow_existing=True)
    return update_release(lab, args, state, volume, composition, schema,
                          schema_version_value, recovery=recovery)


def destroy_stage():
    if os.environ.get('CI'):
        raise ValueError('persistent stage destruction is local-only')
    with tempfile.TemporaryDirectory(prefix='t34-destroy-') as folder:
        Lab(Path(folder),HERE.parents[1],persistent=True).destroy_stage()
    print('destroyed t34-synthetic-stage',flush=True)


def ci_staging_authorized():
    return (os.environ.get('CI') == 'true' and
            os.environ.get('GITHUB_ACTIONS') == 'true' and
            os.environ.get('RUNNER_ENVIRONMENT') == 'self-hosted')


def main():
    if '--destroy-stage' in sys.argv[1:]:
        if len(sys.argv)!=2: raise ValueError('--destroy-stage takes no other arguments')
        destroy_stage()
        return
    p=argparse.ArgumentParser()
    p.add_argument('source',type=Path);p.add_argument('prior',type=Path)
    p.add_argument('revision');p.add_argument('previous')
    p.add_argument('--config-only',action='store_true')
    p.add_argument('--preview',action='store_true')
    p.add_argument('--stage-test',action='store_true')
    p.add_argument('--ci-staging',action='store_true')
    p.add_argument('--decoder-approvals',type=Path,required=True)
    args=p.parse_args()
    modes=[args.config_only,args.preview,args.stage_test,args.ci_staging]
    if sum(modes)>1: raise ValueError('release modes are exclusive')
    if args.stage_test:
        if os.environ.get('T34_ALLOW_PERSISTENT_TEST')!='1':
            raise ValueError('set T34_ALLOW_PERSISTENT_TEST=1 for a persistent local stage')
        if os.environ.get('CI'):
            raise ValueError('persistent stage is local-only')
    if args.ci_staging and not ci_staging_authorized():
        raise ValueError('CI staging requires GitHub Actions self-hosted runner credentials')
    volume = staging.state_volume_name() if args.ci_staging else None
    composition,schema=validate_release(args.source,args.prior,args.previous,
                                         args.decoder_approvals)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    os.umask(0o077)
    # Neither refusal nor initialization failure can route persistent CI to teardown.
    retained = args.ci_staging
    with tempfile.TemporaryDirectory(prefix='t34-private-') as folder:
        work=Path(folder);lab=Lab(work,args.source,persistent=args.stage_test,
                                  ci_staging=args.ci_staging)
        try:
            expose=args.preview or args.stage_test or args.ci_staging
            lab.config(expose=expose)
            if args.config_only:
                print(json.dumps(dict(config='valid',schema_digest=schema,
                                      runtime_composition=composition),sort_keys=True),flush=True)
                return
            if args.ci_staging:
                with staging_recovery.provisioned_recovery(lab, volume) as recovery:
                    run_ci_staging(lab, args, work, composition, schema, volume, recovery=recovery)
                print(CI_STAGING_PROJECT+' synthetic CI staging retained',flush=True)
                return
            lab.start();address,_=deploy(lab,args,work,composition,schema)
            if args.preview:
                print('Loopback synthetic preview (Ctrl-C destroys project): '+address,flush=True)
                while True: time.sleep(3600)
            if args.stage_test:
                retained=True
                print('Persistent synthetic stage retained; destroy with: infra/t34/accept.sh --destroy-stage',flush=True)
        finally:
            if not retained: lab.clean()

if __name__=='__main__':
    try: main()
    except (ValueError,RuntimeError,OSError,KeyError) as e: sys.exit(str(e))

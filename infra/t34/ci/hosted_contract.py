"""Exact contract for private receipts emitted by hosted stage workers.

The public coordinator must not trust a worker merely because it exited zero.
This module validates the receipt schema, binds its process identity to the
actual child process, and cross-checks its service/storage declarations against
the coordinator's independent Docker inventory.
"""
from __future__ import annotations

from dataclasses import dataclass
import re
from typing import Collection, Mapping

from .hosted_proof import ProofError


STORAGE_SERVICES = frozenset({'db', 'cache', 'ledger', 'restored', 'coldcache'})
SERVING_SERVICES = frozenset({'api', 'web', 'backup', 'monitor', 'alert-sink', 'chat-sweeper'})
SERVICE_NAMES = STORAGE_SERVICES | SERVING_SERVICES
EXPECTED_VOLUME_SUFFIXES = frozenset({
    'approval', 'business', 'deletions', 'quarantine', 'state', 'vault',
})
# fixture.go's authoritative Expected set names the six independently deleted
# roots: both score sources, the first signal window, the deleted account key,
# the assessment, and the drill source. Every stage must preserve that set.
RECEIPT_FIELDS = frozenset({
    'phase', 'pid', 'result', 'revision', 'schema_digest', 'services', 'storage',
})
STORAGE_FIELDS = frozenset({
    'volumes', 'vault_snapshots', 'ledger_roots', 'verified', 'retained',
})
INVENTORY_FIELDS = frozenset({'volumes', 'containers'})
CONTAINER_FIELDS = frozenset({'running', 'stopped'})
PHASES = ('init', 'update', 'negative')
REVISION = re.compile(r'[0-9a-f]{40}')
SCHEMA_DIGEST = re.compile(r'[0-9a-f]{64}')
RUN_ID = re.compile(r'[0-9a-f]{24}')


class StageReceiptError(ProofError):
    """The private receipt is malformed or contradicts the expected stage."""


class InventoryMismatchError(StageReceiptError):
    """The receipt's resources or services differ from the parent inventory."""


@dataclass(frozen=True)
class StageReceipt:
    phase: str
    pid: int
    revision: str
    schema_digest: str
    running_services: frozenset[str]
    volume_count: int
    vault_snapshots: int
    ledger_roots: int


def expected_volumes(run_id: str) -> frozenset[str]:
    _require(RUN_ID.fullmatch(run_id) is not None, 'proof run ID invalid')
    prefix = 't34-proof-' + run_id + '_'
    return frozenset(prefix + suffix for suffix in EXPECTED_VOLUME_SUFFIXES)


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise StageReceiptError(message)


def _require_inventory(condition: bool, message: str) -> None:
    if not condition:
        raise InventoryMismatchError(message)


def _inventory(value: object) -> tuple[frozenset[str], int, int]:
    _require_inventory(isinstance(value, Mapping), 'stage inventory invalid')
    _require_inventory(set(value) == INVENTORY_FIELDS, 'stage inventory fields invalid')
    names = value.get('volumes')
    containers = value.get('containers')
    _require_inventory(isinstance(names, list), 'stage volume inventory invalid')
    _require_inventory(isinstance(containers, Mapping), 'stage container inventory invalid')
    _require_inventory(set(containers) == CONTAINER_FIELDS,
                       'stage container inventory fields invalid')
    _require_inventory(all(isinstance(name, str) and name for name in names),
                       'stage volume inventory invalid')
    _require_inventory(len(names) == len(set(names)),
                       'stage volume inventory contains duplicates')
    running = containers.get('running')
    stopped = containers.get('stopped')
    _require_inventory(type(running) is int and running >= 0,
                       'stage running service count invalid')
    _require_inventory(type(stopped) is int and stopped >= 0,
                       'stage stopped service count invalid')
    return frozenset(names), running, stopped


def validate_stage_receipt(
        receipt: object, *, phase: str, pid: int, revision: str, run_id: str,
        inventory: Mapping[str, object], seen_pids: Collection[int] = (),
        previous: StageReceipt | None = None) -> StageReceipt:
    """Validate one successful stage receipt and its independent inventory."""
    _require(phase in PHASES, 'stage phase invalid')
    _require(type(pid) is int and pid > 0, 'worker process ID invalid')
    _require(pid not in seen_pids, 'stage worker process IDs are not unique')
    _require(isinstance(receipt, Mapping), 'stage receipt must be an object')
    _require(set(receipt) == RECEIPT_FIELDS, 'stage receipt fields invalid')
    _require(receipt.get('phase') == phase, 'stage receipt phase differs')
    _require(type(receipt.get('pid')) is int and receipt['pid'] > 0 and
             receipt['pid'] == pid, 'stage receipt process ID differs')
    _require(receipt.get('result') == 'pass', 'stage receipt result is not pass')

    wanted_revision = revision
    _require(isinstance(wanted_revision, str) and
             REVISION.fullmatch(wanted_revision) is not None, 'stage revision invalid')
    _require(receipt.get('revision') == wanted_revision, 'stage receipt revision differs')

    schema = receipt.get('schema_digest')
    _require(isinstance(schema, str) and SCHEMA_DIGEST.fullmatch(schema) is not None,
             'stage schema digest invalid')
    expected_previous = {'init': None, 'update': 'init', 'negative': 'update'}[phase]
    if expected_previous is None:
        _require(previous is None, 'stage predecessor order invalid')
    else:
        _require(previous is not None and previous.phase == expected_previous,
                 'stage predecessor order invalid')
    if previous is not None:
        _require(schema == previous.schema_digest, 'stage schema digest changed')

    services = receipt.get('services')
    _require(isinstance(services, Mapping) and set(services) == SERVICE_NAMES,
             'stage service set invalid')
    _require(all(type(value) is bool for value in services.values()),
             'stage service flags invalid')
    expected_running = STORAGE_SERVICES if phase == 'negative' else SERVICE_NAMES
    _require(services == {service: service in expected_running
                          for service in SERVICE_NAMES}, 'stage service state differs')

    storage = receipt.get('storage')
    _require(isinstance(storage, Mapping) and set(storage) == STORAGE_FIELDS,
             'stage storage evidence invalid')
    for key in ('volumes', 'vault_snapshots', 'ledger_roots'):
        _require(type(storage.get(key)) is int, 'stage storage count invalid')
    _require(storage['volumes'] == len(EXPECTED_VOLUME_SUFFIXES),
             'stage persistent volume count invalid')
    _require(storage['vault_snapshots'] > 0, 'stage vault snapshot count invalid')
    # The worker verifies the exact identities and deadlines against its durable witness.
    _require(storage['ledger_roots'] > 0,
             'stage ledger root count invalid')
    _require(storage.get('verified') is True, 'stage storage was not verified')
    _require(storage.get('retained') is (phase != 'init'),
             'stage retained declaration differs')
    if previous is not None:
        _require(storage['ledger_roots'] == previous.ledger_roots,
                 'stage ledger roots changed')
        if phase == 'update':
            _require(storage['vault_snapshots'] >= previous.vault_snapshots,
                     'stage vault snapshots regressed')
        elif phase == 'negative':
            _require(storage['vault_snapshots'] == previous.vault_snapshots,
                     'negative stage changed vault snapshots')

    names, running, stopped = _inventory(inventory)
    expected_names = expected_volumes(run_id)
    _require_inventory(names == expected_names, 'stage persistent volume set differs')
    expected_containers = {
        'running': len(STORAGE_SERVICES if phase == 'negative' else SERVICE_NAMES),
        'stopped': len(SERVING_SERVICES) if phase == 'negative' else 0,
    }
    _require_inventory(running == expected_containers['running'] and
                       stopped == expected_containers['stopped'],
                       'stage container state differs')
    _require_inventory(len(names) == storage['volumes'],
                       'stage volume count differs from inventory')
    _require_inventory(sum(services.values()) == running,
                       'stage running services differ from inventory')
    _require_inventory(len(services) - sum(services.values()) == stopped,
                       'stage stopped services differ from inventory')

    return StageReceipt(
        phase=phase,
        pid=pid,
        revision=wanted_revision,
        schema_digest=schema,
        running_services=frozenset(service for service, active in services.items() if active),
        volume_count=storage['volumes'],
        vault_snapshots=storage['vault_snapshots'],
        ledger_roots=storage['ledger_roots'],
    )

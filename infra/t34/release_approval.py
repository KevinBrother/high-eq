"""Verify detached, artifact-bound approval for recovery decoder behavior."""
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import stat


APPROVAL_VERSION = 1
APPROVAL_SCOPE = 't34.recovery.decoder.v1'
APPROVALS_ENV = 'T34_DECODER_APPROVALS'
_KEYS = {
    'artifact_sha256', 'decoder_sha256', 'approved_by', 'approval_ref', 'approved_at',
}
_REFERENCE = re.compile(r'[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}')


def _inside(path, root):
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def load_document(path, artifact_roots=()):
    """Load and validate a detached approval document before any release work."""
    if path is None:
        raise ValueError('external decoder approval path missing')
    requested = Path(path)
    if not requested.is_absolute():
        raise ValueError('external decoder approval path must be absolute')
    if requested.is_symlink():
        raise ValueError('external decoder approval must not be a symlink')
    resolved = requested.resolve()
    for root in artifact_roots:
        if _inside(resolved, Path(root).resolve()):
            raise ValueError('external decoder approval must be outside candidate and previous artifacts')
    if not resolved.is_file() or not stat.S_ISREG(resolved.stat().st_mode):
        raise ValueError('external decoder approval file missing')
    if resolved.stat().st_mode & 0o022:
        raise ValueError('external decoder approval must not be group/other writable')
    raw = resolved.read_bytes()
    try:
        document = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError('external decoder approval is not valid JSON') from error
    if not isinstance(document, dict) or set(document) != {'version', 'scope', 'approvals'}:
        raise ValueError('external decoder approval schema invalid')
    if document['version'] != APPROVAL_VERSION or document['scope'] != APPROVAL_SCOPE:
        raise ValueError('external decoder approval version or scope invalid')
    records = document['approvals']
    if not isinstance(records, list) or not records:
        raise ValueError('external decoder approvals missing')
    pairs = set()
    for record in records:
        if not isinstance(record, dict) or set(record) != _KEYS:
            raise ValueError('external decoder approval record invalid')
        for field in ('artifact_sha256', 'decoder_sha256'):
            if not isinstance(record[field], str) or not re.fullmatch(r'[0-9a-f]{64}', record[field]):
                raise ValueError('external decoder approval digest invalid')
        if (not isinstance(record['approved_by'], str) or not record['approved_by'].strip()
                or len(record['approved_by']) > 128):
            raise ValueError('external decoder approval identity invalid')
        if (not isinstance(record['approval_ref'], str)
                or not _REFERENCE.fullmatch(record['approval_ref'])):
            raise ValueError('external decoder approval reference invalid')
        try:
            approved_at = datetime.fromisoformat(record['approved_at'].replace('Z', '+00:00'))
        except (AttributeError, TypeError, ValueError) as error:
            raise ValueError('external decoder approval time invalid') from error
        if approved_at.tzinfo is None:
            raise ValueError('external decoder approval time must include a timezone')
        pair = record['artifact_sha256'], record['decoder_sha256']
        if pair in pairs:
            raise ValueError('external decoder approval duplicate')
        pairs.add(pair)
    return document, hashlib.sha256(raw).hexdigest()


def authorize(contracts, path, artifact_roots):
    """Authorize every release role by exact artifact and decoder contract match."""
    document, document_sha256 = load_document(path, artifact_roots)
    versions = {contract.get('version') for contract in contracts.values()}
    if len(versions) != 1:
        raise ValueError('release decoder contract versions differ')
    contract_version = next(iter(versions))
    by_pair = {
        (record['artifact_sha256'], record['decoder_sha256']): record
        for record in document['approvals']
    }
    decisions = {}
    for role, contract in contracts.items():
        pair = contract['artifact_sha256'], contract['decoder_sha256']
        record = by_pair.get(pair)
        if record is None:
            raise ValueError(role + ' release has no matching external approval')
        decisions[role] = {
            'decision': 'approved',
            'artifact_sha256': contract['artifact_sha256'],
            'decoder_sha256': contract['decoder_sha256'],
            'approved_by': record['approved_by'],
            'approval_ref': record['approval_ref'],
            'approved_at': record['approved_at'],
        }
    return {
        'version': APPROVAL_VERSION,
        'scope': APPROVAL_SCOPE,
        'document_sha256': document_sha256,
        'releases': decisions,
        'approved': [{
            'artifact_sha256': record['artifact_sha256'],
            'decoder_sha256': record['decoder_sha256'],
            'decoder_contract_version': contract_version,
            'approved_by': record['approved_by'],
            'approval_ref': record['approval_ref'],
            'approved_at': record['approved_at'],
            'decision': 'approved',
        } for record in document['approvals']],
    }

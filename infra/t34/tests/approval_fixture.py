"""Create a detached synthetic decoder approval for offline test fixtures."""
import json
from pathlib import Path

import decoder_contract


def write_static_approval(path, *, approved_by='synthetic-release-reviewer',
                          reference='T34-SYNTHETIC-DECODER-001',
                          approved_at='2026-11-24T12:00:00Z',
                          artifact_sha256='a' * 64, decoder_sha256='b' * 64):
    """Write a structurally valid detached document for entrypoint-only tests."""
    path = Path(path)
    path.write_text(json.dumps({
        'version': 1,
        'scope': 't34.recovery.decoder.v1',
        'approvals': [{
            'artifact_sha256': artifact_sha256,
            'decoder_sha256': decoder_sha256,
            'approved_by': approved_by,
            'approval_ref': reference,
            'approved_at': approved_at,
        }],
    }, sort_keys=True))
    path.chmod(0o600)
    return path


def write_approval(path, *sources, reference='T34-SYNTHETIC-DECODER-001'):
    records = []
    seen = set()
    for source in sources:
        contract = decoder_contract.inspect_release(source)
        pair = contract['artifact_sha256'], contract['decoder_sha256']
        if pair in seen:
            continue
        seen.add(pair)
        records.append({
            'artifact_sha256': contract['artifact_sha256'],
            'decoder_sha256': contract['decoder_sha256'],
            'approved_by': 'synthetic-release-reviewer',
            'approval_ref': reference,
            'approved_at': '2026-11-24T12:00:00Z',
        })
    path = Path(path)
    path.write_text(json.dumps({
        'version': 1,
        'scope': 't34.recovery.decoder.v1',
        'approvals': records,
    }, sort_keys=True))
    path.chmod(0o600)
    return path

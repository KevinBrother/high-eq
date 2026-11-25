"""Synthetic drill only. The witness is supplied by the deletion driver, never derived from a dump."""
import hashlib
import uuid

DAYS = 45


def manifest(path, installation, image, start):
    with path.open('rb') as f:
        h = hashlib.sha256()
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return dict(format='pg17-custom', installation=installation, image=image, start=start,
                expires=start + DAYS*86400, max_days=DAYS, sha256=h.hexdigest())


def check(doc, path, installation, image, now):
    if not doc['start'] <= now < doc['expires'] or doc != manifest(path, installation, image, doc['start']):
        raise ValueError('backup provenance or lifetime mismatch')


def coverage(expected_seal, expected, actual_seal, actual):
    if not expected or expected_seal != actual_seal or not expected_seal.endswith(':45'):
        raise ValueError('missing independent coverage')
    uuid.UUID(expected_seal.split(':')[0])
    if any(str(uuid.UUID(k)) != k for k in expected) or len(set(expected)) != len(expected) or sorted(expected) != sorted(actual):
        raise ValueError('deletion inventory mismatch')

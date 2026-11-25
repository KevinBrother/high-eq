"""Read and validate the complete raw T34 permit ticket exactly once."""
import json
import os
import re
import sys


MAX_BYTES = 64 * 1024


def unique_object(pairs):
    obj = {}
    for key, value in pairs:
        if key in obj:
            raise ValueError('duplicate JSON field')
        obj[key] = value
    return obj


def invalid_constant(_):
    raise ValueError('non-JSON constant')


def read_ticket(path):
    with open(path, 'rb') as src:
        raw = src.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        raise ValueError('ticket too large')
    return json.loads(raw.decode('utf-8'), object_pairs_hook=unique_object,
                      parse_constant=invalid_constant)


def validate(ticket, purpose=None):
    if not isinstance(ticket, dict) or type(ticket.get('version')) is not int or ticket['version'] != 2:
        raise ValueError('invalid ticket version')
    for key in ('installation', 'db_service', 'cache_service', 'challenge'):
        if not isinstance(ticket.get(key), str) or not ticket[key]:
            raise ValueError('invalid ticket binding')
    seal = ticket.get('ledger_seal')
    if not isinstance(seal, str) or not re.fullmatch(r'[0-9a-fA-F-]{36}:[0-9]+', seal):
        raise ValueError('invalid ticket seal')
    digest = ticket.get('business_dump_sha256')
    if not isinstance(digest, str) or not re.fullmatch(r'[0-9a-f]{64}', digest):
        raise ValueError('invalid snapshot digest')
    roots = ticket.get('roots')
    declared = ticket.get('purpose')
    if (declared not in ('initial', 'recovery') or not isinstance(roots, list) or
            (declared == 'recovery') != bool(roots) or
            any(not isinstance(root, str) or not root for root in roots) or len(roots) != len(set(roots))):
        raise ValueError('invalid ticket roots')
    if purpose is not None:
        if declared != purpose:
            raise ValueError('wrong ticket purpose')
        for key in ('installation', 'db_service', 'cache_service', 'challenge', 'business_dump_sha256'):
            if ticket[key] != os.environ.get(key.upper()):
                raise ValueError('ticket binding mismatch')
    return {'seal': seal, 'roots': roots}


def main():
    if len(sys.argv) not in (2, 3):
        return 1
    try:
        ticket = read_ticket(sys.argv[1])
        purpose = sys.argv[2] if len(sys.argv) == 3 else None
        selected = validate(ticket, purpose)
        if purpose is not None:
            print(json.dumps(selected, separators=(',', ':')))
    except (OSError, ValueError, RecursionError):
        return 1  # Never print ticket content or parser diagnostics.
    return 0


if __name__ == '__main__':
    sys.exit(main())

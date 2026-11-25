"""Independent D13 maintenance for releases whose API does not sweep chat imports."""
import argparse
import hmac
import os
from pathlib import Path
import re
import subprocess
import sys
import time


RETRY_SECONDS = 60
MAX_AGE_NS = 75 * 10**9
READY = b'chat_import_sweeper_ready'
TARGET_ENV = 'CHAT_SWEEPER_TARGET_SHA256'
TARGET_IDENTITY = """
SELECT encode(sha256(convert_to(json_build_array(
  system_identifier::text,
  current_database(),
  (SELECT oid::text FROM pg_database WHERE datname = current_database()),
  ledger_id::text || ':45'
)::text, 'UTF8')), 'hex')
FROM pg_control_system(), public.ledger_binding
""".strip()
SWEEP = rf"""
BEGIN ISOLATION LEVEL REPEATABLE READ;
SET LOCAL statement_timeout = '5s';
DELETE FROM public.chat_imports
WHERE received_at <= transaction_timestamp() - interval '24 hours'
AND (SELECT identity = :'t34_target'
     FROM ({TARGET_IDENTITY}) AS recovery_target(identity));
-- A missing row stops psql before COMMIT and rolls back the entire sweep.
SELECT identity AS sweep_identity
FROM ({TARGET_IDENTITY}) AS recovery_target(identity)
WHERE identity = :'t34_target' AND NOT EXISTS (
  SELECT FROM public.chat_imports
  WHERE received_at <= transaction_timestamp() - interval '24 hours'
)
\gset
COMMIT;
\echo :sweep_identity
""".encode()


def target_digest(raw):
    try:
        digest = (raw.decode('ascii') if isinstance(raw, bytes) else raw).strip()
    except UnicodeDecodeError:
        return None
    return digest if re.fullmatch(r'[0-9a-f]{64}', digest) else None


def target_identity():
    try:
        result = subprocess.run(
            ['psql', '-XqAt', '-v', 'ON_ERROR_STOP=1', '-c', TARGET_IDENTITY],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    return target_digest(result.stdout)


def sweep_once(expected):
    try:
        result = subprocess.run(
            ['psql', '-XqAt', '-v', 'ON_ERROR_STOP=1', '-v', f't34_target={expected}'],
            input=SWEEP,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    identity = target_digest(result.stdout)
    return identity if identity is not None and hmac.compare_digest(expected, identity) else None


def run(witness, expected):
    witness.unlink(missing_ok=True)
    pending = witness.with_suffix('.pending')
    while True:
        identity = sweep_once(expected)
        if identity is not None:
            pending.write_text(
                f'{os.getpid()} {time.monotonic_ns()} {identity}\n', encoding='ascii')
            pending.replace(witness)
            print('chat_import_sweep_ok', flush=True)
        else:
            witness.unlink(missing_ok=True)
            print('chat_import_sweep_retry', file=sys.stderr, flush=True)
        time.sleep(RETRY_SECONDS)


def healthy(witness, expected):
    try:
        pid_text, completed_text, receipt_identity = witness.read_text(
            encoding='ascii').split()
        pid, completed = int(pid_text), int(completed_text)
        if (pid <= 0 or not 0 <= time.monotonic_ns() - completed < MAX_AGE_NS or
                not hmac.compare_digest(expected, receipt_identity)):
            return False
        os.kill(pid, 0)
        observed_identity = target_identity()
        if observed_identity is None or not hmac.compare_digest(expected, observed_identity):
            return False
        os.kill(pid, 0)
        return (0 <= time.monotonic_ns() - completed < MAX_AGE_NS and
                witness.read_text(encoding='ascii').split() ==
                [pid_text, completed_text, receipt_identity])
    except (OSError, ValueError):
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('run', 'health'))
    parser.add_argument('witness', type=Path)
    args = parser.parse_args()
    expected = target_digest(os.environ.get(TARGET_ENV, ''))
    if expected is None:
        return 1
    if args.mode == 'run':
        os.umask(0o077)
        run(args.witness, expected)
    if not healthy(args.witness, expected):
        return 1
    print(READY.decode('ascii'))
    return 0


if __name__ == '__main__':
    sys.exit(main())

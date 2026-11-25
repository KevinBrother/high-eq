import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
GATE = HERE / 'gate.sh'
HORIZON = 45 * 86400 * 1000
CREATED = 1_800_000_000_000
WINDOW = 180 * 86400 * 1000
AUTO = object()


def invoke_gate(env, ticket, binding, ledger, action='verify', action_args=()):
    # Only Redis/Postgres I/O is simulated. The gate's retention policy runs for real.
    with tempfile.TemporaryDirectory() as folder:
        tmp = Path(folder)
        ticket_file = tmp / 'ticket'
        ticket_file.write_text(ticket if isinstance(ticket, str) else json.dumps(ticket))
        for name, script in {
            'psql': 'printf "%s\\n" "$FAKE_BINDING"',
            'redis-cli': r"""
[ "$2" = "$FAKE_REDIS_URL" ] || exit 42
case "$5" in
  *PEXPIRETIME*) printf '%s\n' "$FAKE_LEDGER" ;;
  *) printf '%s\n' "$FAKE_LEDGER" | jq -r '
      if any(.deadlines[]; . < ($now + $horizon - 600000) or . > ($now + $horizon))
      then "invalid" else .seal, (.deadlines | keys[]) end' \
      --argjson now "$FAKE_NOW" --argjson horizon 3888000000 ;;
esac""",
        }.items():
            executable = tmp / name
            executable.write_text('#!/bin/sh\n' + script + '\n')
            executable.chmod(0o755)
        return subprocess.run(['sh', str(GATE), action, *action_args], env={
            'PATH': f'{tmp}:{os.environ["PATH"]}',
            'GATE_FILE': str(ticket_file),
            'DATABASE_URL': 'postgres://synthetic/db',
            'LEDGER_URL': 'redis://synthetic/0',
            'FAKE_REDIS_URL': 'redis://synthetic/' + ('1' if action == 'probe-missing' else '0'),
            'BACKUP_RETENTION_DAYS': '45',
            'FAKE_BINDING': binding,
            'FAKE_LEDGER': json.dumps(ledger),
            'FAKE_NOW': str(ledger['now_ms']),
            **env,
        }, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)


class GateContract(unittest.TestCase):
    def run_gate(self, *, roots, ledger_roots, binding, purpose='recovery',
                 version=2, target=None, digest='a' * 64, retained=None,
                 persistent=False, age=0, observed=None, ticket_digest='a' * 64, prefix='',
                 transform=lambda raw: raw, action='verify', action_args=(),
                 writes=AUTO, window_cutoffs=None):
        target = target or ('recovery' if purpose == 'recovery' else 'initial')
        db_service, cache_service = {
            'initial': ('db', 'cache'),
            'recovery': ('restored', 'coldcache'),
            'unknown': ('db', 'coldcache'),
        }[target]
        seal = '11111111-1111-4111-8111-111111111111:45'
        env = {
            'INSTALLATION': 'install-1',
            'DB_SERVICE': db_service,
            'CACHE_SERVICE': cache_service,
            'CHALLENGE': 'challenge-1',
        }
        if digest is not None:
            env['BUSINESS_DUMP_SHA256'] = digest
        if persistent:
            env['LEDGER_RETENTION_MODE'] = 'persistent'
        if retained is not None:
            env['LEDGER_DEADLINES'] = json.dumps(retained)
        if not persistent and writes is AUTO:
            writes = {root: [CREATED, CREATED, 0] for root in roots}
        if writes is not AUTO and writes is not None:
            env['LEDGER_WRITES'] = json.dumps(writes)
        if window_cutoffs is not None:
            env['LEDGER_WINDOW_CUTOFFS'] = json.dumps(window_cutoffs)
        ticket = {
            'version': version,
            'installation': 'install-1',
            'db_service': db_service,
            'cache_service': cache_service,
            'challenge': 'challenge-1',
            'ledger_seal': seal,
            'business_dump_sha256': ticket_digest,
            'roots': roots,
            'purpose': purpose,
        }
        return invoke_gate(env, transform(prefix + json.dumps(ticket)), binding, {
            'seal': seal, 'now_ms': CREATED + age,
            'deadlines': observed if observed is not None else
            {root: CREATED + HORIZON for root in ledger_roots},
        }, action, action_args)

    def test_dump_digest_is_required_and_must_match_independent_value(self):
        for purpose, roots in [('initial', []), ('recovery', ['root-a'])]:
            for digest in (None, '', 'b' * 64, 'a' * 64):
                with self.subTest(purpose=purpose, digest=digest):
                    result = self.run_gate(roots=roots, ledger_roots=roots, purpose=purpose,
                                           binding='11111111-1111-4111-8111-111111111111:45:0',
                                           digest=digest)
                    self.assertEqual(result.returncode, 0 if digest == 'a' * 64 else 1,
                                     result.stdout + result.stderr)

    def test_ticket_rejects_multiple_json_values_and_non_exact_sha256(self):
        canonical = 'a' * 64
        for label, ticket_digest, expected_digest, prefix in (
            ('valid', canonical, canonical, ''),
            ('extra top-level null before valid object', canonical, canonical, 'null\n'),
            ('ticket digest trailing newline', canonical + '\n', canonical, ''),
            ('env digest trailing newline', canonical, canonical + '\n', ''),
            ('both digests include a newline', canonical + '\n', canonical + '\n', ''),
            ('uppercase', 'A' * 64, 'A' * 64, ''),
            ('trailing space', canonical + ' ', canonical + ' ', ''),
            ('missing env digest', canonical, None, ''),
            ('empty env digest', canonical, '', ''),
        ):
            with self.subTest(label=label):
                result = self.run_gate(roots=['root-a'], ledger_roots=['root-a'],
                                       binding='11111111-1111-4111-8111-111111111111:45:0',
                                       digest=expected_digest, ticket_digest=ticket_digest, prefix=prefix)
                self.assertEqual(result.returncode, 0 if label == 'valid' else 1,
                                 result.stdout + result.stderr)

    def test_gate_rejects_nul_suffix_and_duplicate_digest_fields_on_raw_input(self):
        field = '"business_dump_sha256": '
        for label, transform in (
            ('NUL and junk', lambda raw: raw + '\0junk'),
            ('conflicting duplicate digest', lambda raw: raw.replace(field, field + json.dumps('b' * 64) + ', ' + field)),
            ('escaped duplicate digest key', lambda raw: raw.replace(field, r'"business_dump_sha\u0032' + '56": "wrong", ' + field)),
        ):
            with self.subTest(label=label):
                result = self.run_gate(roots=['root-a'], ledger_roots=['root-a'],
                                       binding='11111111-1111-4111-8111-111111111111:45:0',
                                       transform=transform)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertNotIn('recovery_gate_ok', result.stdout)

    def test_scratch_probe_only_acknowledges_the_named_missing_root(self):
        options = dict(roots=['root-a', 'root-b'], binding='11111111-1111-4111-8111-111111111111:45:0',
                       action='probe-missing', action_args=('root-b',))
        for actual in (['root-a'], ['root-b'], ['root-a', 'root-b'], [], ['root-a', 'foreign']):
            with self.subTest(actual=actual):
                result = self.run_gate(**options, ledger_roots=actual)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout.strip(), 'recovery_gate_refused_missing_root' if actual == ['root-a'] else '')

    def test_persistent_gate_uses_original_deadlines_not_the_fresh_window(self):
        deadline = CREATED + HORIZON
        retained = {'root-a': deadline, 'root-b': deadline + 500}
        opts = dict(roots=list(retained), ledger_roots=list(retained),
                    binding='11111111-1111-4111-8111-111111111111:45:0',
                    observed=retained, age=601_000)
        self.assertEqual(self.run_gate(**opts).returncode, 1, 'one-off rehearsal still requires freshness')
        for age in (601_000, HORIZON - 1):
            with self.subTest(age=age):
                result = self.run_gate(**(opts | {'age': age}), persistent=True, retained=retained)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_fresh_window_deadlines_follow_the_later_of_the_two_rules(self):
        roots = ['ordinary', 'window-physical', 'window-logical']
        for floor in (CREATED + WINDOW - 60_000, CREATED + HORIZON + 5,
                      CREATED + HORIZON, CREATED + HORIZON - 5):
            with self.subTest(floor=floor):
                writes = {root: [CREATED, CREATED + 10, floor if root != 'ordinary' else 0]
                          for root in roots}
                actual = {root: max(CREATED + HORIZON + 2, writes[root][2]) for root in roots}
                opts = dict(roots=roots, ledger_roots=roots, age=10, writes=writes,
                            binding='11111111-1111-4111-8111-111111111111:45:0')
                self.assertEqual(self.run_gate(**opts, observed=actual).returncode, 0)
                for root, value in [('ordinary', CREATED + WINDOW),
                                    ('window-physical', max(CREATED + HORIZON + 10, floor) + 1),
                                    ('window-logical', max(CREATED + HORIZON, floor) - 1)]:
                    self.assertEqual(self.run_gate(**opts, observed=actual | {root: value}).returncode, 1)
                self.assertEqual(self.run_gate(**(opts | {'writes': None}), observed=actual).returncode, 1)

    def test_persistent_window_requires_the_frozen_deadline_and_independent_cutoff(self):
        roots = ['ordinary', 'window-physical', 'window-logical']
        cutoff = CREATED + WINDOW - 60_000
        cutoffs = {root: cutoff for root in roots[1:]}
        retained = dict.fromkeys(roots, cutoff) | {'ordinary': CREATED + HORIZON}
        opts = dict(roots=roots, ledger_roots=roots, retained=retained,
                    persistent=True, age=601_000,
                    binding='11111111-1111-4111-8111-111111111111:45:0')
        self.assertEqual(self.run_gate(**opts, window_cutoffs=cutoffs, observed=retained).returncode, 0)
        self.assertEqual(self.run_gate(**opts, observed=retained).returncode, 1)
        for root in roots:
            self.assertEqual(self.run_gate(**opts, window_cutoffs=cutoffs,
                                          observed=retained | {root: retained[root] + 1}).returncode, 1)
        removed = roots[1]
        probe = self.run_gate(**opts, window_cutoffs=cutoffs,
                              observed={k: v for k, v in retained.items() if k != removed},
                              action='probe-missing', action_args=(removed,))
        self.assertEqual(probe.stdout.strip(), 'recovery_gate_refused_missing_root')

    def test_persistent_gate_rejects_specious_deadlines_and_incomplete_roots(self):
        deadline = CREATED + HORIZON
        retained = {'root-a': deadline, 'root-b': deadline + 500}
        for label, age, witness, observed in (
            ('no independent witness', 0, None, {'root-a': deadline, 'root-b': deadline}),
            ('shortened but positive', 601_000, retained, retained | {'root-a': deadline - 1}),
            ('renewed into fresh window', 601_000, retained, retained | {'root-a': deadline + 601_000}),
            ('expired', HORIZON, retained, retained),
            ('no expiration', 601_000, retained, retained | {'root-a': -1}),
            ('future creation', 0, retained, retained),
            ('missing', 601_000, retained, {'root-b': deadline + 500}),
            ('unwitnessed extra', 601_000, retained, retained | {'root-c': deadline}),
        ):
            with self.subTest(label=label):
                result = self.run_gate(roots=list(retained), ledger_roots=list(retained),
                                       binding='11111111-1111-4111-8111-111111111111:45:0',
                                       age=age, observed=observed, persistent=True, retained=witness)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)

    def test_same_ticket_rejects_missing_ledger_root(self):
        self.assertTrue(GATE.exists(), 'actual compose gate must be a verifier, not a string comparison')
        roots = ['root-a', 'root-b']
        good = self.run_gate(
            roots=roots,
            ledger_roots=roots,
            binding='11111111-1111-4111-8111-111111111111:45:0',
        )
        self.assertEqual(good.returncode, 0, good.stdout)
        missing = self.run_gate(
            roots=roots,
            ledger_roots=['root-a'],
            binding='11111111-1111-4111-8111-111111111111:45:0',
        )
        self.assertNotEqual(missing.returncode, 0, 'same ticket must not pass with a missing deletion root')
        extra = self.run_gate(
            roots=roots,
            ledger_roots=['root-a', 'root-b', 'root-c'],
            binding='11111111-1111-4111-8111-111111111111:45:0',
        )
        self.assertNotEqual(extra.returncode, 0, 'same ticket must not pass with an unexpected root')

    def test_initial_ticket_requires_an_empty_real_ledger(self):
        good = self.run_gate(
            roots=[],
            ledger_roots=[],
            binding='11111111-1111-4111-8111-111111111111:45:0',
            purpose='initial',
        )
        self.assertEqual(good.returncode, 0, good.stdout)
        future_root = self.run_gate(
            roots=[],
            ledger_roots=['root-a'],
            binding='11111111-1111-4111-8111-111111111111:45:0',
            purpose='initial',
        )
        self.assertNotEqual(future_root.returncode, 0,
                            'an initial ticket must not hide an already deleted root')
        populated = self.run_gate(
            roots=['root-a'],
            ledger_roots=['root-a'],
            binding='11111111-1111-4111-8111-111111111111:45:0',
            purpose='initial',
        )
        self.assertNotEqual(populated.returncode, 0,
                            'initial tickets must carry an empty root inventory')

    def test_recovery_ticket_requires_nonempty_roots_and_version_two(self):
        for roots in ([], ['root-a', 'root-a']):
            with self.subTest(roots=roots):
                result = self.run_gate(
                    roots=roots,
                    ledger_roots=roots,
                    binding='11111111-1111-4111-8111-111111111111:45:0',
                )
                self.assertNotEqual(result.returncode, 0)
        legacy = self.run_gate(
            roots=['root-a'],
            ledger_roots=['root-a'],
            binding='11111111-1111-4111-8111-111111111111:45:0',
            version=1,
        )
        self.assertNotEqual(legacy.returncode, 0, 'version 1 cannot express initial versus recovery')

    def test_initial_ticket_is_rejected_on_a_recovery_target(self):
        result = self.run_gate(
            roots=[],
            ledger_roots=[],
            binding='11111111-1111-4111-8111-111111111111:45:0',
            purpose='initial',
            target='recovery',
        )
        self.assertNotEqual(
            result.returncode, 0,
            'restored/coldcache must reject an initial ticket even when the ledger is identity-only')

    def test_purpose_must_match_the_controlled_target_pair(self):
        recovery_on_initial = self.run_gate(
            roots=['root-a'],
            ledger_roots=['root-a'],
            binding='11111111-1111-4111-8111-111111111111:45:0',
            purpose='recovery',
            target='initial',
        )
        self.assertNotEqual(recovery_on_initial.returncode, 0,
                            'db/cache must reject a recovery ticket')
        unknown_pair = self.run_gate(
            roots=[],
            ledger_roots=[],
            binding='11111111-1111-4111-8111-111111111111:45:0',
            purpose='initial',
            target='unknown',
        )
        self.assertNotEqual(unknown_pair.returncode, 0,
                            'unknown DB/cache service pairs must fail closed')

    def test_binding_and_pending_work_are_part_of_the_gate(self):
        roots = ['root-a']
        wrong = self.run_gate(
            roots=roots,
            ledger_roots=roots,
            binding='22222222-2222-4222-8222-222222222222:45:0',
        )
        self.assertNotEqual(wrong.returncode, 0, 'restored database binding must match the ledger witness')
        pending = self.run_gate(
            roots=roots,
            ledger_roots=roots,
            binding='11111111-1111-4111-8111-111111111111:45:1',
        )
        self.assertNotEqual(pending.returncode, 0, 'pending erasure work must keep serving closed')
        invalid = self.run_gate(
            roots=roots,
            ledger_roots=['invalid'],
            binding='11111111-1111-4111-8111-111111111111:45:0',
        )
        self.assertNotEqual(invalid.returncode, 0, 'invalid ledger payload or TTL must fail closed')


if __name__ == '__main__':
    unittest.main()

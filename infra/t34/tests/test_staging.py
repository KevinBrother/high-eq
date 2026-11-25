import base64
import copy
import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

T34 = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(T34))
import staging
import release
from test_gate import CREATED, HORIZON, invoke_gate


UUID_A = '11111111-1111-4111-8111-111111111111'
UUID_B = '22222222-2222-4222-8222-222222222222'
SEAL = '33333333-3333-4333-8333-333333333333:45'
API_A = 'sha256:' + 'a' * 64
WEB_A = 'sha256:' + 'b' * 64
API_B = 'sha256:' + 'c' * 64
WEB_B = 'sha256:' + 'd' * 64
ADMISSION_CURRENT = {
    'artifact_sha256': '1' * 64,
    'decoder_sha256': '2' * 64,
    'decoder_contract_version': 1,
    'approval_document_sha256': '3' * 64,
    'approved_by': 'current-reviewer',
    'approval_ref': 'T34-CURRENT-001',
    'approved_at': '2026-11-22T00:00:00Z',
    'decision': 'approved',
}
ADMISSION_PREVIOUS = {
    'artifact_sha256': '4' * 64,
    'decoder_sha256': '5' * 64,
    'decoder_contract_version': 1,
    'approval_document_sha256': '6' * 64,
    'approved_by': 'previous-reviewer',
    'approval_ref': 'T34-PREVIOUS-001',
    'approved_at': '2026-11-21T00:00:00Z',
    'decision': 'approved',
}
ADMISSION_NEXT = {
    'artifact_sha256': '7' * 64,
    'decoder_sha256': '8' * 64,
    'decoder_contract_version': 1,
    'approval_document_sha256': 'a' * 64,
    'approved_by': 'next-reviewer',
    'approval_ref': 'T34-NEXT-001',
    'approved_at': '2026-11-23T00:00:00Z',
    'decision': 'approved',
}


def admission_contract(identity):
    return {
        'version': identity['decoder_contract_version'],
        'artifact_sha256': identity['artifact_sha256'],
        'decoder_sha256': identity['decoder_sha256'],
        'approved_by': identity['approved_by'],
        'approval_ref': identity['approval_ref'],
        'approved_at': identity['approved_at'],
        'decision': identity['decision'],
    }


def approved_contract(identity):
    return {field: identity[field] for field in (
        'artifact_sha256', 'decoder_sha256', 'decoder_contract_version',
        'approved_by', 'approval_ref', 'approved_at', 'decision',
    )}


def composition_for(previous, candidate=ADMISSION_NEXT, *, document_sha256='9' * 64):
    approved = []
    seen_pairs = set()
    for identity in (candidate, previous):
        pair = identity['artifact_sha256'], identity['decoder_sha256']
        if pair not in seen_pairs:
            approved.append(approved_contract(identity))
            seen_pairs.add(pair)
    return {'decoder_admission': {
        'contract_version': 1,
        'approval_document_sha256': document_sha256,
        'candidate': admission_contract(candidate),
        'previous': admission_contract(previous),
        'approved': approved,
    }}


def init_composition():
    return composition_for(ADMISSION_PREVIOUS, ADMISSION_CURRENT)


def fixture():
    return {
        'A': {'user_id': UUID_A},
        'B': {'user_id': UUID_B},
        'Activities': [UUID_A, UUID_B],
        'Sources': [UUID_B, UUID_A],
        'Windows': [UUID_B, UUID_A],
        'Requests': [UUID_B, UUID_A],
        'Seal': SEAL,
        'Expected': [UUID_B, UUID_A],
    }


def result():
    return {'ledger_deadlines': state()['ledger_deadlines'], 'releases': {
        'a': ['previous-revision', [API_A, WEB_A]],
        'b': ['current-revision', [API_B, WEB_B]],
    }}


def state():
    return {
        'version': staging.STATE_VERSION,
        'installation': 't34-ci-staging',
        'schema_digest': 'e' * 64,
        'schema_version': '20261123000023',
        'db_service': 'restored',
        'cache_service': 'coldcache',
        'created_at': '2026-11-22T00:00:00Z',
        'updated_at': '2026-11-22T00:00:00Z',
        'challenge': 'f' * 48,
        'business_dump_sha256': '9' * 64,
        'ledger_deadlines': {UUID_A: CREATED + HORIZON, UUID_B: CREATED + HORIZON + 500},
        'credentials': {
            'db_password': '1' * 48,
            'cost_password': '2' * 48,
            'ledger_password': '3' * 48,
            'field_key_base64': base64.b64encode(b'4' * 32).decode(),
        },
        'marker': staging.marker_from_fixture(fixture()),
        'release': {
            'revision': 'current-revision',
            'previous': 'previous-revision',
            'api_image_id': API_B,
            'web_image_id': WEB_B,
            'deployed_at': '2026-11-22T00:00:00Z',
            **ADMISSION_CURRENT,
        },
        'previous_release': {
            'revision': 'previous-revision',
            'previous': None,
            'api_image_id': API_A,
            'web_image_id': WEB_A,
            'deployed_at': '2026-11-21T00:00:00Z',
            **ADMISSION_PREVIOUS,
        },
        'history': [{
            'revision': 'current-revision',
            'previous': 'previous-revision',
            'api_image_id': API_B,
            'web_image_id': WEB_B,
            'deployed_at': '2026-11-22T00:00:00Z',
            **ADMISSION_CURRENT,
        }],
    }


class StateContract(unittest.TestCase):
    def test_state_volume_must_be_a_named_volume_from_the_environment(self):
        self.assertEqual(staging.state_volume_name({'T34_STAGING_STATE_VOLUME': 't34-state'}), 't34-state')
        for value in ('', '/var/lib/t34', '../state', 'name:rw'):
            with self.subTest(value=value):
                with self.assertRaisesRegex(ValueError, 'state volume'):
                    staging.state_volume_name({'T34_STAGING_STATE_VOLUME': value})

    def test_state_volume_requires_exact_owner_and_role_labels(self):
        lab = mock.Mock()
        lab.run.return_value = json.dumps({
            staging.OWNER_LABEL: 't34-ci-staging',
            staging.ROLE_LABEL: 'state',
        }).encode()
        staging.require_state_volume(lab, 't34-state', 't34-ci-staging')
        self.assertEqual(lab.run.call_args.args[:2], ('volume', 'inspect'))

        for labels in (
            {},
            {staging.OWNER_LABEL: 'other', staging.ROLE_LABEL: 'state'},
            {staging.OWNER_LABEL: 't34-ci-staging', staging.ROLE_LABEL: 'business'},
        ):
            lab.run.return_value = json.dumps(labels).encode()
            with self.subTest(labels=labels):
                with self.assertRaisesRegex(ValueError, 'state volume labels'):
                    staging.require_state_volume(lab, 't34-state', 't34-ci-staging')

    def test_read_absent_state_returns_none_without_creating_a_file(self):
        lab = mock.Mock()
        lab.run.return_value = (staging.ABSENT_STATE + '\n').encode()
        self.assertIsNone(staging.read_state(lab, 't34-state'))
        self.assertIn('staging-state.json', lab.run.call_args.args[-1])

    def test_write_state_is_atomic_and_private(self):
        lab = mock.Mock()
        writer_id = 'f' * 64
        lab.run.side_effect = [
            json.dumps({staging.OWNER_LABEL: 't34-ci-staging', staging.ROLE_LABEL: 'state'}).encode(),
            writer_id.encode(),
            b'',
            b'',
            b'',
        ]
        staging.write_state(lab, 't34-state', state(), 't34-ci-staging')
        create = lab.run.call_args_list[1]
        start = lab.run.call_args_list[2]
        remove = lab.run.call_args_list[3]
        probe = lab.run.call_args_list[4]
        self.assertEqual(create.args[:2], ('create', '-i'))
        script = create.args[-1]
        self.assertIn('mktemp', script)
        self.assertIn('chmod 600', script)
        self.assertIn('mv ', script)
        self.assertNotIn('--rm', create.args)
        self.assertEqual(start.args[:4], ('start', '-a', '-i', writer_id))
        payload = start.kwargs['input']
        self.assertEqual(json.loads(payload), state())
        self.assertEqual(remove.args[:3], ('rm', '-f', writer_id))
        self.assertEqual(probe.args[:3], ('ps', '-aq', '--filter'))
        self.assertEqual(probe.args[3], 'id=' + writer_id)

    def test_build_state_records_current_previous_credentials_and_marker(self):
        lab = SimpleNamespace(
            name='t34-ci-staging', source=Path('/candidate'),
            env={
                'DB_PASS': '1' * 48,
                'COST_PASS': '2' * 48,
                'LEDGER_PASS': '3' * 48,
                'TEST_FIELD_KEY': base64.b64encode(b'4' * 32).decode(),
                'CHALLENGE': 'f' * 48,
            },
        )
        args = SimpleNamespace(revision='current-revision', previous='previous-revision')
        built = staging.build_state(
            lab, args, 'e' * 64, result(), staging.marker_from_fixture(fixture()),
            schema_version_value='20261123000023',
            business_dump_sha256='9' * 64, composition=init_composition())
        self.assertEqual(built['release']['api_image_id'], API_B)
        self.assertEqual(built['previous_release']['api_image_id'], API_A)
        self.assertEqual(built['challenge'], 'f' * 48)
        self.assertEqual(built['business_dump_sha256'], '9' * 64)
        self.assertEqual(built['history'], [built['release']])
        self.assertEqual(built['marker']['user_a'], UUID_A)
        self.assertNotIn('AccessToken', json.dumps(built))

    def test_updated_state_preserves_identity_and_schema_and_appends_history(self):
        before = state()
        updated_result = {'releases': {'b': ['next-revision', [API_A, WEB_A]]}}
        args = SimpleNamespace(revision='next-revision', previous=before['release']['revision'])
        after = staging.updated_state(
            before, args, 'e' * 64, '20261123000023', updated_result,
            composition=composition_for(before['release']))
        self.assertEqual(after['installation'], before['installation'])
        self.assertEqual(after['schema_digest'], before['schema_digest'])
        self.assertEqual(after['schema_version'], before['schema_version'])
        self.assertEqual(after['release']['revision'], 'next-revision')
        self.assertEqual(after['release']['artifact_sha256'], ADMISSION_NEXT['artifact_sha256'])
        self.assertEqual(after['release']['decoder_sha256'], ADMISSION_NEXT['decoder_sha256'])
        self.assertEqual(after['previous_release'], before['release'])
        self.assertEqual(after['history'][-1], after['release'])
        self.assertEqual(after['marker'], before['marker'])
        self.assertEqual(after['credentials'], before['credentials'])

    def test_validate_state_fails_closed_on_identity_schema_or_release_drift(self):
        original = state()
        staging.validate_state(original, 't34-ci-staging', 'e' * 64, '20261123000023')
        cases = (
            ('installation', 'other', 'installation mismatch'),
            ('schema_digest', '0' * 64, 'schema digest mismatch'),
            ('schema_version', '0', 'schema version mismatch'),
            ('previous_release', None, 'previous release missing'),
            ('history', [], 'history invalid'),
        )
        for field, value, message in cases:
            broken = copy.deepcopy(original)
            broken[field] = value
            with self.subTest(field=field):
                with self.assertRaisesRegex(ValueError, message):
                    staging.validate_state(broken, 't34-ci-staging', 'e' * 64, '20261123000023')

        broken = copy.deepcopy(original)
        broken['release']['previous'] = 'unexpected-revision'
        with self.assertRaisesRegex(ValueError, 'previous release mismatch'):
            staging.validate_state(broken, 't34-ci-staging', 'e' * 64, '20261123000023')

    def test_lifecycle_only_allows_first_initialization_and_in_place_update(self):
        self.assertEqual(staging.lifecycle(None, False), 'initialized')
        self.assertEqual(staging.lifecycle(state(), True), 'updated')
        for value, exists, message in (
            (None, True, 'project exists without provisioning state'),
            (state(), False, 'state exists without its project'),
        ):
            with self.subTest(exists=exists):
                with self.assertRaisesRegex(ValueError, message):
                    staging.lifecycle(value, exists)
        with self.assertRaisesRegex(ValueError, 'existence is unproven'):
            staging.lifecycle(None, 'false')

    def test_apply_to_lab_restores_stable_identity_and_credentials(self):
        lab = SimpleNamespace(env={'API_IMAGE': 'keep'})
        staging.apply_to_lab(lab, state())
        self.assertEqual(lab.env['DB_PASS'], '1' * 48)
        self.assertEqual(lab.env['DB_SERVICE'], 'restored')
        self.assertEqual(lab.env['CACHE_SERVICE'], 'coldcache')
        self.assertEqual(lab.env['CHALLENGE'], 'f' * 48)
        self.assertEqual(lab.env['BUSINESS_DUMP_SHA256'], state()['business_dump_sha256'])
        self.assertEqual(json.loads(lab.env['LEDGER_DEADLINES']), state()['ledger_deadlines'])
        self.assertEqual(lab.env['API_IMAGE'], 'keep')

    def test_verify_storage_checks_migration_binding_inventory_and_markers(self):
        lab = mock.Mock()
        lab.sql.side_effect = [
            '20261123000023:false',
            SEAL,
            '1',
            '0',
            '1',
            '1',
            '0',
        ]
        inventory = mock.Mock(return_value=(SEAL, state()['ledger_deadlines']))
        self.assertTrue(staging.verify_storage(lab, state(), inventory_fn=inventory))
        self.assertEqual(lab.sql.call_count, 7)
        self.assertEqual(inventory.call_args.args[0], lab)

    def test_verify_storage_rejects_a_missing_tombstone_or_pending_erasure(self):
        lab = mock.Mock()
        lab.sql.side_effect = [
            '20261123000023:false', SEAL, '1', '0', '1', '0', '1',
        ]
        with self.assertRaisesRegex(ValueError, 'review tombstone missing'):
            staging.verify_storage(lab, state(), inventory_fn=lambda _: (SEAL, [UUID_B, UUID_A]))

        lab.sql.side_effect = [
            '20261123000023:false', SEAL, '1', '0', '1', '1', '1',
        ]
        with self.assertRaisesRegex(ValueError, 'pending erasure'):
            staging.verify_storage(lab, state(), inventory_fn=lambda _: (SEAL, [UUID_B, UUID_A]))


class PersistentUpdateRegression(unittest.TestCase):
    def setUp(self):
        self.state = state()
        self.lab = mock.Mock(name='simulated Docker I/O')
        self.lab.name = self.state['installation']
        self.lab.env = {'ALERT_WEBHOOK': release.ALERT_WEBHOOK}
        self.lab.existing_project.return_value = True
        self.lab.compose.return_value = b'127.0.0.1:41001\n'
        images = iter((API_A, WEB_A, API_B, WEB_B))
        self.lab.build.side_effect = lambda source, target, dockerfile, tag, revision: (
            API_A if tag == 'ops' else next(images))
        self.lab.alert_count.return_value = 0
        self.lab.sql.side_effect = lambda *_: next(self.sql_values)
        self.lab.job.side_effect = self.inventory_job
        self.lab.gate_exit.side_effect = lambda: self.invoke('verify').returncode
        self.lab.exec.side_effect = self.legacy_inventory
        self.ledger = {'seal': SEAL, 'now_ms': CREATED + 1_000,
                       'deadlines': self.state['ledger_deadlines'].copy()}
        self.ticket = release.ticket_document(
            installation=self.lab.name, db_service='restored', cache_service='coldcache',
            challenge=self.state['challenge'], seal=SEAL,
            dump_sha256=self.state['business_dump_sha256'], roots=[UUID_A, UUID_B], purpose='recovery')

    def invoke(self, action):
        return invoke_gate({'INSTALLATION': self.lab.name, **self.lab.env},
                           self.ticket, SEAL + ':0', self.ledger, action)

    def inventory_job(self, service, command, *, entry):
        self.assertEqual((service, command, entry), ('permit', 'inventory', '/ops/gate.sh'))
        result = self.invoke(command)
        if result.returncode:
            raise ValueError('staging deletion ledger inventory refused')
        return result.stdout.encode()

    def legacy_inventory(self, *cmd, **kwargs):
        if cmd == ('monitor', '/ops/ops.sh', 'monitor-once'):
            return b'ai_cost=normal sink=webhook\n'
        if cmd == ('monitor', '/ops/ops.sh', 'monitor-probe'):
            return b''
        self.assertEqual(cmd[:4], ('ledger', 'redis-cli', '--raw', 'EVAL'))
        if any(not HORIZON - 600_000 <= end - self.ledger['now_ms'] <= HORIZON
               for end in self.ledger['deadlines'].values()):
            return b'invalid\n'
        return ('\n'.join([SEAL, *self.ledger['deadlines']]) + '\n').encode()

    def update(self, revision):
        self.sql_values = iter(['20261123000023:false', SEAL, '1', '0', '1', '1', '0'])
        self.output = io.StringIO()
        with mock.patch.object(staging, 'require_state_volume'), \
                mock.patch.object(staging, 'read_state', return_value=self.state), \
                mock.patch.object(staging, 'schema_version', return_value=self.state['schema_version']), \
                mock.patch.object(staging, 'write_state', side_effect=self.save), \
                contextlib.redirect_stdout(self.output), contextlib.redirect_stderr(io.StringIO()):
            args = SimpleNamespace(
                source=T34, revision=revision, previous=self.state['release']['revision'])
            composition = composition_for(self.state['release'])
            return release.run_ci_staging(
                self.lab, args, T34, composition, self.state['schema_digest'], 't34-state')

    def save(self, lab, volume, stored, installation):
        self.state = copy.deepcopy(stored)

    def test_two_updates_cross_freshness_boundary_without_touching_deadlines(self):
        deadlines = self.state['ledger_deadlines'].copy()
        self.update('next-revision')
        self.ledger['now_ms'] += 601_000
        self.update('later-revision')
        self.assertEqual(self.lab.gate_exit.call_count, 2)
        self.assertEqual(self.lab.build.call_count, 6)
        self.assertEqual([item['revision'] for item in self.state['history']],
                         ['current-revision', 'next-revision', 'later-revision'])
        self.assertEqual(self.state['ledger_deadlines'], deadlines)
        self.assertEqual(self.ledger['deadlines'], deadlines)
        self.assertTrue(all(call.args[0] == 'monitor' for call in self.lab.exec.call_args_list))

    def test_storage_refuses_missing_or_changed_roots_before_build(self):
        saved = copy.deepcopy(self.state)
        self.ledger['now_ms'] += 601_000
        for observed in ({UUID_A: self.state['ledger_deadlines'][UUID_A]},
                         self.state['ledger_deadlines'] | {UUID_B: self.state['ledger_deadlines'][UUID_B] - 1}):
            with self.subTest(observed=observed):
                self.ledger['deadlines'] = observed
                with self.assertRaisesRegex(ValueError, 'deletion ledger'):
                    self.update('must-not-deploy')
        self.lab.build.assert_not_called()
        self.lab.open_release.assert_not_called()
        self.assertEqual(self.state, saved)

    def test_successful_update_after_fence_restores_and_verifies_consumers_before_open(self):
        consumers = {'monitor', 'backup', 'alert-sink'}
        running = set()
        gate_passed = False

        def gate():
            nonlocal gate_passed
            gate_passed = True
            return self.invoke('verify').returncode

        def compose(*args, **kwargs):
            requested = consumers.intersection(args)
            if requested:
                self.assertTrue(gate_passed)
                self.assertIn('--wait', args)
                running.update(requested)
            return b'127.0.0.1:41001\n'

        def probe(service, *args, **kwargs):
            self.assertIn(service, running)
            self.assertIn(args, (('/ops/ops.sh', 'monitor-once'), ('/ops/ops.sh', 'monitor-probe')))
            return b'ai_cost=normal sink=webhook\n' if args[-1] == 'monitor-once' else b''

        def open_release(*args, **kwargs):
            self.assertEqual(running, consumers)
            self.assertEqual(self.lab.exec.call_args_list, [
                mock.call('monitor', '/ops/ops.sh', 'monitor-once', timeout=120),
                mock.call('monitor', '/ops/ops.sh', 'monitor-probe', timeout=20),
            ])
            self.lab.wait_alert_count.assert_called_once_with(1, timeout=10)

        self.lab.gate_exit.side_effect = gate
        self.lab.compose.side_effect = compose
        self.lab.open_release.side_effect = open_release
        self.lab.exec.side_effect = probe
        self.update('unfenced-revision')
        self.assertEqual(self.state['release']['revision'], 'unfenced-revision')

    def test_unhealthy_consumers_keep_entry_closed_and_do_not_write_release_state(self):
        before = copy.deepcopy(self.state)
        legacy = self.lab.exec.side_effect
        self.lab.exec.side_effect = lambda service, *args, **kwargs: (
            b'ai_cost=monitor_unavailable sink=webhook\n' if service == 'monitor' else legacy(service, *args))
        with self.assertRaisesRegex(ValueError, 'consumer'):
            self.update('must-not-deploy')
        self.lab.open_release.assert_not_called()
        self.lab.close_serving.assert_called_once_with()
        self.assertEqual(self.state, before)

    def test_delivery_probe_failure_leaves_ingress_fenced_without_success_receipt(self):
        saved = copy.deepcopy(self.state)
        self.lab.alert_count.return_value = 15
        self.lab.wait_alert_count.side_effect = ValueError('local alert sink did not receive expected alerts')
        with self.assertRaisesRegex(ValueError, 'did not receive'):
            self.update('must-not-deploy')
        self.lab.open_release.assert_not_called()
        self.lab.close_serving.assert_called_once_with()
        self.assertEqual(self.state, saved)
        self.assertNotIn('synthetic-pass', self.output.getvalue())

    def test_update_refreshes_the_ops_image_before_trusting_the_gate(self):
        original_gate = self.lab.gate_exit.side_effect

        def gate():
            self.assertEqual([call.args[2:4] for call in self.lab.build.call_args_list], [('Ops.Dockerfile', 'ops')])
            return original_gate()

        self.lab.gate_exit.side_effect = gate
        self.update('refresh-tools')

    def test_update_refuses_digest_mismatch_before_candidate_images_build(self):
        self.ticket['business_dump_sha256'] = '8' * 64
        with self.assertRaisesRegex(ValueError, 'recovery gate'):
            self.update('must-not-deploy')
        self.assertEqual([call.args[2:4] for call in self.lab.build.call_args_list], [('Ops.Dockerfile', 'ops')])
        self.lab.open_release.assert_not_called()


if __name__ == '__main__':
    unittest.main()

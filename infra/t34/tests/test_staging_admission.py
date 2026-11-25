import base64
import contextlib
import copy
import io
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

T34 = Path(__file__).resolve().parents[1]
ROOT = T34.parents[1]
sys.path.insert(0, str(T34))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import release
import staging
import decoder_contract
from test_staging import API_A, API_B, WEB_A, WEB_B, fixture, result, state


CANDIDATE_IDENTITY = {
    'artifact_sha256': '1' * 64,
    'decoder_sha256': '2' * 64,
    'decoder_contract_version': 1,
    'approval_document_sha256': '3' * 64,
    'approved_by': 'candidate-reviewer',
    'approval_ref': 'T34-CANDIDATE-001',
    'approved_at': '2026-11-24T12:00:00Z',
    'decision': 'approved',
}
PREVIOUS_IDENTITY = {
    'artifact_sha256': '4' * 64,
    'decoder_sha256': '5' * 64,
    'decoder_contract_version': 1,
    'approval_document_sha256': '6' * 64,
    'approved_by': 'previous-reviewer',
    'approval_ref': 'T34-PREVIOUS-001',
    'approved_at': '2026-11-23T12:00:00Z',
    'decision': 'approved',
}
OTHER_IDENTITY = {
    **PREVIOUS_IDENTITY,
    'artifact_sha256': '7' * 64,
    'decoder_sha256': '8' * 64,
    'approval_ref': 'T34-OTHER-001',
}
PREVIOUS_COMMIT = 'd44e8b6d4b1d6767a1bd3082ed8530a31735cc17'


def approved_record(identity):
    return {field: identity[field] for field in (
        'artifact_sha256', 'decoder_sha256', 'decoder_contract_version', 'approved_by',
        'approval_ref', 'approved_at', 'decision',
    )}


def document_record(identity):
    record = approved_record(identity)
    record.pop('decision')
    record.pop('decoder_contract_version')
    return record


def composition(candidate=CANDIDATE_IDENTITY, previous=PREVIOUS_IDENTITY):
    def contract(identity):
        return {
            'version': identity['decoder_contract_version'],
            'artifact_sha256': identity['artifact_sha256'],
            'decoder_sha256': identity['decoder_sha256'],
            'approved_by': identity['approved_by'],
            'approval_ref': identity['approval_ref'],
            'approved_at': identity['approved_at'],
            'decision': identity['decision'],
        }
    return {'decoder_admission': {
        'contract_version': 1,
        'approval_document_sha256': '9' * 64,
        'candidate': contract(candidate),
        'previous': contract(previous),
        'approved': [approved_record(candidate), approved_record(previous)],
    }}


def bound_state(current_identity=PREVIOUS_IDENTITY, previous_identity=OTHER_IDENTITY):
    bound = state()
    bound['release'].update(copy.deepcopy(current_identity))
    bound['history'][0].update(copy.deepcopy(current_identity))
    bound['previous_release'].update(copy.deepcopy(previous_identity))
    return bound


def recovery_for(lab, prior):
    return SimpleNamespace(
        lab=lab,
        volume='t34-state',
        read_initial=mock.Mock(return_value=prior),
        read=mock.Mock(return_value=prior),
        write=mock.Mock(),
        begin=mock.Mock(),
        assert_idle=mock.Mock(),
        verify_owner=mock.Mock(),
        verify_engine=mock.Mock(),
        finish=mock.Mock(),
    )


def write_approval_document(path, identities):
    path.write_text(json.dumps({
        'version': 1,
        'scope': 't34.recovery.decoder.v1',
        'approvals': [document_record(identity) for identity in identities],
    }, sort_keys=True))
    path.chmod(0o600)
    return path


def release_identity(source, *, approved_by, approval_ref, approved_at,
                     document_sha256='d' * 64):
    contract = decoder_contract.inspect_release(source)
    return {
        'artifact_sha256': contract['artifact_sha256'],
        'decoder_sha256': contract['decoder_sha256'],
        'decoder_contract_version': contract['version'],
        'approval_document_sha256': document_sha256,
        'approved_by': approved_by,
        'approval_ref': approval_ref,
        'approved_at': approved_at,
        'decision': 'approved',
    }


def copy_release(source, target):
    shutil.copytree(
        source, target,
        ignore=shutil.ignore_patterns('.git', 'build', '__pycache__', '.pytest_cache'),
    )
    return target


class StagingAdmissionBindingTests(unittest.TestCase):
    def test_mismatched_previous_is_rejected_before_any_destructive_operation(self):
        prior = bound_state()
        args = SimpleNamespace(source=Path('/synthetic'), revision='next-revision',
                               previous=prior['release']['revision'])
        lab = mock.Mock()
        lab.name = prior['installation']
        lab.env = {}
        lab.existing_project.return_value = True
        lab.start.side_effect = AssertionError('stage was started before admission binding')
        recovery = recovery_for(lab, prior)

        with mock.patch.object(staging, 'schema_version', return_value=prior['schema_version']), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaisesRegex(ValueError, 'staging previous release decoder admission mismatch'):
                release.run_ci_staging(
                    lab, args, Path('/synthetic'),
                    composition(previous=OTHER_IDENTITY), prior['schema_digest'],
                    't34-state', recovery=recovery)

        lab.start.assert_not_called()
        lab.close_serving.assert_not_called()
        lab.compose.assert_not_called()
        lab.build.assert_not_called()
        lab.open_release.assert_not_called()
        recovery.begin.assert_not_called()
        recovery.write.assert_not_called()

    def test_matching_previous_updates_and_reports_the_exact_rollback_object(self):
        prior = bound_state(current_identity=PREVIOUS_IDENTITY, previous_identity=OTHER_IDENTITY)
        args = SimpleNamespace(source=Path('/synthetic'), revision='next-revision',
                               previous=PREVIOUS_COMMIT)
        new_api = 'sha256:' + 'e' * 64
        new_web = 'sha256:' + 'f' * 64
        lab = mock.Mock()
        lab.name = prior['installation']
        lab.source = args.source
        lab.env = {'ALERT_WEBHOOK': release.ALERT_WEBHOOK}
        lab.existing_project.return_value = True
        lab.build.side_effect = [API_A, new_api, new_web]
        lab.gate_exit.return_value = 0
        lab.compose.side_effect = lambda *values, **_: (
            b'127.0.0.1:41001\n' if values[:1] == ('port',) else b''
        )
        persisted = {'state': copy.deepcopy(prior)}
        recovery = recovery_for(lab, prior)
        recovery.read.side_effect = lambda: copy.deepcopy(persisted['state'])

        def write(value):
            persisted['state'] = copy.deepcopy(value)

        recovery.write.side_effect = write
        stdout = io.StringIO()
        with mock.patch.object(staging, 'schema_version', return_value=prior['schema_version']), \
                mock.patch.object(staging, 'verify_storage'), \
                mock.patch.object(release, 'resume_consumers'), \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(io.StringIO()):
            address = release.run_ci_staging(
                lab, args, Path('/synthetic'), composition(), prior['schema_digest'],
                't34-state', recovery=recovery)

        self.assertEqual(address, '127.0.0.1:41001')
        updated = persisted['state']
        self.assertEqual(updated['release']['revision'], args.revision)
        self.assertEqual(updated['release']['artifact_sha256'], CANDIDATE_IDENTITY['artifact_sha256'])
        self.assertEqual(updated['release']['decoder_sha256'], CANDIDATE_IDENTITY['decoder_sha256'])
        self.assertEqual(updated['previous_release'], prior['release'])
        receipt = next(json.loads(line) for line in stdout.getvalue().splitlines()
                       if line.startswith('{'))
        self.assertEqual(receipt['release'], updated['release'])
        self.assertEqual(receipt['previous_release'], prior['release'])
        self.assertEqual(receipt['rollback']['release'], prior['release'])
        lab.open_release.assert_called_once_with(
            'b', args.revision, [new_api, new_web], preview=True, by_id=True)
        self.assertNotIn(mock.call('rollback', prior['release']['revision'],
                                   [prior['release']['api_image_id'], prior['release']['web_image_id']],
                                   preview=True, by_id=True), lab.open_release.call_args_list)

    def test_matching_previous_state_write_failure_reopens_only_the_proven_release(self):
        prior = bound_state(current_identity=PREVIOUS_IDENTITY, previous_identity=OTHER_IDENTITY)
        args = SimpleNamespace(source=Path('/synthetic'), revision='next-revision',
                               previous=PREVIOUS_COMMIT)
        new_api = 'sha256:' + 'e' * 64
        new_web = 'sha256:' + 'f' * 64
        lab = mock.Mock()
        lab.name = prior['installation']
        lab.env = {'ALERT_WEBHOOK': release.ALERT_WEBHOOK}
        lab.existing_project.return_value = True
        lab.build.side_effect = [API_A, new_api, new_web]
        lab.gate_exit.return_value = 0
        lab.compose.side_effect = lambda *values, **_: (
            b'127.0.0.1:41001\n' if values[:1] == ('port',) else b''
        )
        recovery = recovery_for(lab, prior)
        recovery.write.side_effect = ValueError('state write failed')
        stderr = io.StringIO()

        with mock.patch.object(staging, 'schema_version', return_value=prior['schema_version']), \
                mock.patch.object(staging, 'verify_storage'), \
                mock.patch.object(release, 'resume_consumers') as resume_consumers, \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
            with self.assertRaisesRegex(ValueError, 'reconciled to uncommitted'):
                release.run_ci_staging(
                    lab, args, Path('/synthetic'), composition(), prior['schema_digest'],
                    't34-state', recovery=recovery)

        lab.open_release.assert_called_once_with(
            'rollback', prior['release']['revision'],
            [prior['release']['api_image_id'], prior['release']['web_image_id']],
            preview=True, by_id=True)
        recovery.finish.assert_called_once_with(prior)
        resume_consumers.assert_called_once_with(lab)
        receipt = json.loads(stderr.getvalue())
        self.assertEqual(receipt['state_reconciliation'], 'uncommitted')
        self.assertIn('release', receipt['rollback'], 'rollback receipt lacked exact release proof')
        self.assertEqual(receipt['rollback']['release'], prior['release'])
        self.assertEqual(receipt['rollback']['release']['artifact_sha256'],
                         PREVIOUS_IDENTITY['artifact_sha256'])
        self.assertEqual(receipt['rollback']['release']['decoder_sha256'],
                         PREVIOUS_IDENTITY['decoder_sha256'])

    def test_initialization_binds_state_and_receipt_to_the_approved_previous(self):
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
        approved = composition()
        built = staging.build_state(
            lab, args, 'e' * 64, result(), staging.marker_from_fixture(fixture()),
            schema_version_value='20261123000023', business_dump_sha256='9' * 64,
            composition=approved)
        staging.validate_state(built, lab.name, 'e' * 64, '20261123000023')
        receipt = release.staging_receipt(
            'initialized', 't34-state', 'e' * 64, None, args.revision,
            release=built['release'], previous_release=built['previous_release'])

        expected_previous = {**PREVIOUS_IDENTITY, 'approval_document_sha256': '9' * 64}
        for field, value in expected_previous.items():
            self.assertEqual(built['previous_release'][field], value)
            self.assertEqual(receipt['previous_release'][field], value)
        self.assertEqual(built['previous_release']['revision'], args.previous)
        self.assertEqual(built['previous_release']['api_image_id'], API_A)
        self.assertEqual(built['previous_release']['web_image_id'], WEB_A)
        self.assertEqual(built['release']['artifact_sha256'], CANDIDATE_IDENTITY['artifact_sha256'])
        self.assertEqual(built['release']['decoder_sha256'], CANDIDATE_IDENTITY['decoder_sha256'])
        self.assertEqual(receipt['previous_release'], built['previous_release'])

    def test_old_state_and_state_without_release_identity_fail_closed(self):
        old = state()
        old['version'] = staging.STATE_VERSION - 1
        with self.assertRaisesRegex(ValueError, 'version'):
            staging.validate_state(old, old['installation'], old['schema_digest'], old['schema_version'])

        missing = bound_state()
        del missing['previous_release']['artifact_sha256']
        with self.assertRaisesRegex(ValueError, 'fields invalid'):
            staging.validate_state(missing, missing['installation'], missing['schema_digest'],
                                   missing['schema_version'])

    def test_state_release_rejects_unknown_fields(self):
        unknown = bound_state()
        unknown['release']['unexpected'] = 'not part of the v3 release contract'
        unknown['history'][0]['unexpected'] = 'not part of the v3 release contract'
        with self.assertRaisesRegex(ValueError, 'release fields invalid'):
            staging.validate_state(unknown, unknown['installation'], unknown['schema_digest'],
                                   unknown['schema_version'])


class RealRollbackAdmissionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='t34-real-rollback-')
        work = Path(cls.temp.name)
        cls.prior = copy_release(ROOT, work / 'prior')
        cls.b1 = copy_release(ROOT, work / 'b1')
        delivery = cls.b1 / 'server/internal/training/delivery.go'
        delivery.write_text(delivery.read_text() + '\n// Synthetic approved B1 decoder.\n')
        cls.b2 = copy_release(cls.b1, work / 'b2')
        delivery = cls.b2 / 'server/internal/training/delivery.go'
        delivery.write_text(delivery.read_text() + '\n// Synthetic candidate B2 decoder.\n')

        cls.a_identity = release_identity(
            cls.prior, approved_by='release-a-reviewer',
            approval_ref='T34-REAL-A-001', approved_at='2026-11-21T08:00:00Z')
        cls.b1_identity = release_identity(
            cls.b1, approved_by='release-b1-reviewer',
            approval_ref='T34-REAL-B1-001', approved_at='2026-11-22T08:00:00Z')
        cls.b2_identity = release_identity(
            cls.b2, approved_by='release-b2-reviewer',
            approval_ref='T34-REAL-B2-001', approved_at='2026-11-23T08:00:00Z')

        cls.match_document = write_approval_document(
            work / 'approvals-match.json', (cls.a_identity, cls.b1_identity, cls.b2_identity))
        cls.missing_document = write_approval_document(
            work / 'approvals-missing-b1.json', (cls.a_identity, cls.b2_identity))
        cls.mismatch_identity = {
            **cls.b1_identity,
            'approved_by': 'different-reviewer',
            'approval_ref': 'T34-REAL-B1-SUBSTITUTE-001',
            'approved_at': '2026-11-22T09:00:00Z',
        }
        cls.mismatch_document = write_approval_document(
            work / 'approvals-mismatched-b1.json',
            (cls.a_identity, cls.mismatch_identity, cls.b2_identity))

        cls.match_composition, cls.schema = release.validate_release(
            cls.b2, cls.prior, PREVIOUS_COMMIT, cls.match_document)
        cls.missing_composition, _ = release.validate_release(
            cls.b2, cls.prior, PREVIOUS_COMMIT, cls.missing_document)
        cls.mismatch_composition, _ = release.validate_release(
            cls.b2, cls.prior, PREVIOUS_COMMIT, cls.mismatch_document)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def deployed_b1_state(self):
        prior = state()
        current = {**prior['release'], **self.b1_identity}
        current.update(revision='archive-b1', previous=PREVIOUS_COMMIT)
        previous = {**prior['previous_release'], **self.a_identity}
        previous.update(revision=PREVIOUS_COMMIT, previous=None)
        prior['release'] = current
        prior['previous_release'] = previous
        prior['history'] = [copy.deepcopy(current)]
        prior['schema_digest'] = self.schema
        prior['schema_version'] = staging.schema_version(self.b2)
        return prior

    def lab_for(self, prior):
        lab = mock.Mock()
        lab.name = prior['installation']
        lab.source = self.b2
        lab.env = {'ALERT_WEBHOOK': release.ALERT_WEBHOOK}
        lab.existing_project.return_value = True
        lab.build.side_effect = [API_A, 'sha256:' + 'e' * 64, 'sha256:' + 'f' * 64]
        lab.gate_exit.return_value = 0
        lab.compose.side_effect = lambda *values, **_: (
            b'127.0.0.1:41001\n' if values[:1] == ('port',) else b''
        )
        return lab

    def test_real_entry_approval_binds_b1_while_update_arguments_keep_historical_a(self):
        prior = self.deployed_b1_state()
        staging.validate_state(prior, prior['installation'], self.schema, prior['schema_version'])
        self.assertEqual(self.match_composition['decoder_admission']['previous']['artifact_sha256'],
                         self.a_identity['artifact_sha256'])
        self.assertIn(approved_record(self.b1_identity),
                      self.match_composition['decoder_admission']['approved'])
        args = SimpleNamespace(
            source=self.b2, revision='archive-b2', previous=PREVIOUS_COMMIT)
        lab = self.lab_for(prior)
        persisted = {'state': copy.deepcopy(prior)}
        recovery = recovery_for(lab, prior)
        recovery.read.side_effect = lambda: copy.deepcopy(persisted['state'])

        def write(value):
            persisted['state'] = copy.deepcopy(value)

        recovery.write.side_effect = write
        stdout = io.StringIO()
        with mock.patch.object(staging, 'verify_storage'), \
                mock.patch.object(release, 'resume_consumers'), \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(io.StringIO()):
            address = release.run_ci_staging(
                lab, args, Path(self.temp.name), self.match_composition,
                self.schema, 't34-state', recovery=recovery)

        self.assertEqual(address, '127.0.0.1:41001')
        self.assertEqual(persisted['state']['previous_release'], prior['release'])
        self.assertEqual(persisted['state']['release']['revision'], 'archive-b2')
        receipt = next(json.loads(line) for line in stdout.getvalue().splitlines()
                       if line.startswith('{'))
        self.assertEqual(receipt['rollback']['release'], prior['release'])
        self.assertEqual(receipt['rollback']['release']['artifact_sha256'],
                         self.b1_identity['artifact_sha256'])
        self.assertEqual(receipt['rollback']['release']['decoder_sha256'],
                         self.b1_identity['decoder_sha256'])

    def test_real_entry_rejects_missing_or_identity_mismatched_b1_before_destruction(self):
        cases = (
            ('missing', self.missing_composition),
            ('identity-mismatch', self.mismatch_composition),
        )
        for name, composition in cases:
            with self.subTest(name=name):
                prior = self.deployed_b1_state()
                args = SimpleNamespace(
                    source=self.b2, revision='archive-b2', previous=PREVIOUS_COMMIT)
                lab = self.lab_for(prior)
                recovery = recovery_for(lab, prior)
                stderr = io.StringIO()
                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
                    with self.assertRaisesRegex(
                            ValueError, 'staging previous release decoder admission mismatch'):
                        release.run_ci_staging(
                            lab, args, Path(self.temp.name), composition,
                            self.schema, 't34-state', recovery=recovery)

                lab.start.assert_not_called()
                lab.close_serving.assert_not_called()
                lab.compose.assert_not_called()
                lab.build.assert_not_called()
                lab.open_release.assert_not_called()
                recovery.begin.assert_not_called()
                recovery.write.assert_not_called()


if __name__ == '__main__':
    unittest.main()

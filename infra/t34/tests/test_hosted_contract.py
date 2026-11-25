"""Offline contract for the private receipts emitted by the real stage worker."""
import copy
from pathlib import Path
import unittest

from ci import hosted_contract
from ci.hosted_proof import ProofError

RUN_ID = 'a' * 24
INITIAL = '1' * 40
UPDATE = '2' * 40
DIGEST = 'd' * 64
PIDS = (4101, 4102, 4103)
STAGES = ('init', 'update', 'negative')
AUTO = object()


def volumes():
    return sorted('t34-proof-' + RUN_ID + '_' + suffix for suffix in (
        'approval', 'business', 'deletions', 'quarantine', 'state', 'vault'))


def inventory(stage):
    return {
        'volumes': volumes(),
        'containers': {'running': 5, 'stopped': 6} if stage == 'negative'
        else {'running': 11, 'stopped': 0},
    }


def receipt(stage):
    running = hosted_contract.STORAGE_SERVICES if stage == 'negative' else hosted_contract.SERVICE_NAMES
    return {
        'phase': stage,
        'pid': PIDS[STAGES.index(stage)],
        'result': 'pass',
        'revision': INITIAL if stage == 'init' else UPDATE,
        'schema_digest': DIGEST,
        'services': {service: service in running for service in sorted(hosted_contract.SERVICE_NAMES)},
        'storage': {
            'volumes': 6,
            'vault_snapshots': 1 if stage == 'init' else 2,
            'ledger_roots': 6,
            'verified': True,
            'retained': stage != 'init',
        },
    }


class HostedReceiptContractTests(unittest.TestCase):
    def validate(self, stage, value, *, previous=AUTO, seen=(), observed=None):
        if previous is AUTO:
            previous = {
                'init': None,
                'update': hosted_contract.StageReceipt(
                    'init', PIDS[0], INITIAL, DIGEST,
                    hosted_contract.SERVICE_NAMES, 6, 1, 6),
                'negative': hosted_contract.StageReceipt(
                    'update', PIDS[1], UPDATE, DIGEST,
                    hosted_contract.SERVICE_NAMES, 6, 2, 6),
            }[stage]
        return hosted_contract.validate_stage_receipt(
            value, phase=stage, pid=PIDS[STAGES.index(stage)],
            revision=INITIAL if stage == 'init' else UPDATE, run_id=RUN_ID,
            inventory=observed or inventory(stage), seen_pids=seen, previous=previous,
        )

    def test_accepts_the_exact_real_worker_shape_and_tracks_cross_stage_evidence(self):
        init = self.validate('init', receipt('init'))
        update = self.validate('update', receipt('update'), previous=init,
                               seen=(init.pid,))
        negative = self.validate('negative', receipt('negative'), previous=update,
                                 seen=(init.pid, update.pid))
        self.assertEqual(init.phase, 'init')
        self.assertEqual(update.schema_digest, DIGEST)
        self.assertEqual(negative.vault_snapshots, 2)
        self.assertEqual(negative.running_services, hosted_contract.STORAGE_SERVICES)

    def test_rejects_bad_process_result_revision_and_digest_evidence(self):
        mutations = {
            'wrong transport pid': lambda value: value.update(pid=9999),
            'failed result': lambda value: value.update(result='fail'),
            'wrong revision': lambda value: value.update(revision='3' * 40),
            'uppercase digest': lambda value: value.update(schema_digest=DIGEST.upper()),
            'short digest': lambda value: value.update(schema_digest='d' * 63),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name):
                value = copy.deepcopy(receipt('init'))
                mutate(value)
                with self.assertRaises(hosted_contract.StageReceiptError):
                    self.validate('init', value)

        with self.assertRaises(hosted_contract.StageReceiptError):
            self.validate('update', receipt('update'), seen=(PIDS[0], PIDS[1]))

    def test_rejects_missing_extra_and_non_boolean_services(self):
        changes = (
            lambda services: services.pop('coldcache'),
            lambda services: services.update(permit=True),
            lambda services: services.update(web=1),
        )
        for change in changes:
            with self.subTest(change=change):
                value = copy.deepcopy(receipt('update'))
                change(value['services'])
                with self.assertRaises(hosted_contract.StageReceiptError):
                    self.validate('update', value)

    def test_negative_requires_all_serving_services_stopped_and_exact_inventory(self):
        value = receipt('negative')
        value['services']['api'] = True
        with self.assertRaises(hosted_contract.StageReceiptError):
            self.validate('negative', value)

        observed = inventory('negative')
        observed['containers']['running'] = 6
        observed['containers']['stopped'] = 4
        with self.assertRaises(hosted_contract.InventoryMismatchError):
            self.validate('negative', receipt('negative'), observed=observed)

    def test_rejects_storage_verification_retention_and_resource_counts(self):
        changes = (
            lambda storage: storage.update(verified=False),
            lambda storage: storage.update(verified=1),
            lambda storage: storage.update(retained=True),
            lambda storage: storage.update(volumes=5),
            lambda storage: storage.update(vault_snapshots=0),
            lambda storage: storage.update(ledger_roots=0),
        )
        for change in changes:
            with self.subTest(change=change):
                value = copy.deepcopy(receipt('init'))
                change(value['storage'])
                with self.assertRaises(hosted_contract.StageReceiptError):
                    self.validate('init', value)

    def test_rejects_cross_stage_digest_snapshot_pid_and_retention_drift(self):
        init = self.validate('init', receipt('init'))
        for name, mutate, kwargs in (
            ('digest', lambda value: value.update(schema_digest='e' * 64),
             {'previous': init, 'seen': (init.pid,)}),
            ('snapshot rollback', lambda value: value['storage'].update(vault_snapshots=0),
             {'previous': init, 'seen': (init.pid,)}),
            ('duplicate pid', lambda value: value.update(pid=init.pid),
             {'previous': init, 'seen': (init.pid,)}),
            ('false retention', lambda value: value['storage'].update(retained=False),
             {'previous': init, 'seen': (init.pid,)}),
        ):
            with self.subTest(name=name):
                value = receipt('update')
                mutate(value)
                with self.assertRaises(hosted_contract.StageReceiptError):
                    self.validate('update', value, **kwargs)

    def test_rejects_any_predecessor_other_than_the_exact_previous_phase(self):
        init = self.validate('init', receipt('init'))
        update = self.validate('update', receipt('update'), previous=init)
        with self.assertRaises(hosted_contract.StageReceiptError):
            self.validate('negative', receipt('negative'), previous=init)
        with self.assertRaises(hosted_contract.StageReceiptError):
            self.validate('init', receipt('init'), previous=update)

    def test_rejects_unexpected_volume_names_extra_fields_and_non_object_payloads(self):
        observed = inventory('update')
        observed['volumes'][0] = 'other_volume'
        with self.assertRaises(hosted_contract.InventoryMismatchError):
            self.validate('update', receipt('update'), observed=observed)

        value = receipt('update')
        value['private'] = 'must-not-pass'
        with self.assertRaises(hosted_contract.StageReceiptError):
            self.validate('update', value)
        with self.assertRaises(hosted_contract.StageReceiptError):
            self.validate('update', [])

    def test_exports_only_fixed_public_error_types(self):
        self.assertTrue(issubclass(hosted_contract.StageReceiptError, ProofError))
        self.assertTrue(issubclass(hosted_contract.InventoryMismatchError,
                                   hosted_contract.StageReceiptError))


if __name__ == '__main__':
    unittest.main()

"""Regression tests for generation from the authoritative mobile contract."""

import base64
from copy import deepcopy
import io
import json
import re
import unittest
import zipfile

import yaml

import generate_api


def authoritative_spec():
    return yaml.safe_load(generate_api.SPEC.read_text())


SOURCE_PATH = '/v1/me/data/{kind}/{id}'
WINDOW_PATH = '/v1/signal-windows'
EXACT_STATUS = 'x-mobile-exact-success-status'


class GenerateApiTest(unittest.TestCase):
    def test_generation_uses_only_the_authoritative_record_contract(self):
        generated = generate_api.generate()
        catalog = generated['lib/core/app_op.g.dart']

        exact = [
            line.strip()
            for line in catalog.splitlines()
            if 'exactSuccessStatus: 200' in line
        ]
        self.assertEqual(len(exact), 2)
        self.assertTrue(exact[0].startswith('deleteSource('), exact[0])
        self.assertTrue(exact[1].startswith('deleteWindow('), exact[1])
        self.assertIn("listDataRecords('GET', '/v1/me/data/{kind}'", catalog)
        self.assertIn(
            'const ownedDataCursorLimit = 300;',
            generated['lib/features/privacy/records_contract.g.dart'],
        )
        self.assertFalse(
            (generate_api.APP / 'tool/t35/records_api.yaml').exists(),
            'the transition-only record specification must not remain',
        )

    def test_missing_record_surface_fails_instead_of_falling_back(self):
        spec = authoritative_spec()
        del spec['paths']['/v1/me/data/{kind}']

        with self.assertRaisesRegex(ValueError, '/v1/me/data/{kind}'):
            generate_api.generate(spec)

    def test_exact_success_annotation_must_match_a_declared_success_response(self):
        original = authoritative_spec()
        for marker in (201, 401, '200', 200.0, True, None):
            with self.subTest(marker=marker):
                spec = deepcopy(original)
                spec['paths'][SOURCE_PATH]['delete'][EXACT_STATUS] = marker
                with self.assertRaisesRegex(ValueError, 'deleteSource'):
                    generate_api.generate(spec)

        spec = deepcopy(original)
        del spec['paths'][SOURCE_PATH]['delete']['responses']['200']
        with self.assertRaisesRegex(ValueError, 'deleteSource'):
            generate_api.generate(spec)

    def test_deletes_require_exact_success_annotations(self):
        original = authoritative_spec()
        for path, name in ((SOURCE_PATH, 'deleteSource'), (WINDOW_PATH, 'deleteWindow')):
            with self.subTest(path=path):
                spec = deepcopy(original)
                del spec['paths'][path]['delete'][EXACT_STATUS]
                with self.assertRaisesRegex(ValueError, f'{name}.*{EXACT_STATUS}'):
                    generate_api.generate(spec)

    def test_annotated_success_cannot_coexist_with_another_2xx(self):
        original = authoritative_spec()
        for status in ('201', '2XX'):
            with self.subTest(status=status):
                spec = deepcopy(original)
                responses = spec['paths'][SOURCE_PATH]['delete']['responses']
                responses[status] = deepcopy(responses['200'])
                with self.assertRaisesRegex(ValueError, f'deleteSource.*{status}'):
                    generate_api.generate(spec)

    def test_generation_uses_the_annotated_response(self):
        spec = authoritative_spec()
        delete = spec['paths'][SOURCE_PATH]['delete']
        delete[EXACT_STATUS] = 201
        delete['responses']['201'] = delete['responses'].pop('200')

        generated = generate_api.generate(spec)

        self.assertRegex(
            generated['lib/core/app_op.g.dart'],
            r'deleteSource\([^\n]*exactSuccessStatus: 201\)',
        )
        examples = json.loads(generated['assets/contract_examples.json'])
        self.assertEqual(examples['deleteSource'], {'ok': True})

    def test_record_validation_follows_the_published_item_union(self):
        spec = authoritative_spec()
        schemas = spec['components']['schemas']
        schemas['DataRecordPage']['properties']['items']['items']['$ref'] = '#/components/schemas/Ack'

        with self.assertRaisesRegex(ValueError, 'listDataRecords'):
            generate_api.generate(spec)

    def test_record_variants_reject_mixed_deletion_keys(self):
        original = authoritative_spec()
        for variant, extra_key in (
            ('TimedDataRecord', 'channel'),
            ('ContactDataRecord', 'channel'),
            ('WindowDataRecord', 'id'),
        ):
            with self.subTest(variant=variant):
                spec = deepcopy(original)
                fields = spec['components']['schemas'][variant]['properties']
                fields[extra_key] = {'type': 'string'}
                with self.assertRaisesRegex(ValueError, variant):
                    generate_api.generate(spec)

    def test_record_variants_agree_on_shared_validation_patterns(self):
        original = authoritative_spec()
        for variant, field in (('ContactDataRecord', 'id'), ('WindowDataRecord', 'label')):
            with self.subTest(variant=variant, field=field):
                spec = deepcopy(original)
                fields = spec['components']['schemas'][variant]['properties']
                fields[field] = {**fields[field], 'pattern': '^different$'}
                with self.assertRaisesRegex(ValueError, rf'{variant}.*{field}'):
                    generate_api.generate(spec)

    def test_generation_preserves_operation_order_and_offline_examples(self):
        spec = authoritative_spec()
        generated = generate_api.generate(spec)
        operations = {
            operation['operationId']: operation
            for path, methods in spec['paths'].items()
            if not path.startswith('/v1/payment-notifications/')
            for operation in methods.values()
        }
        catalog = generated['lib/core/app_op.g.dart']
        self.assertEqual(re.findall(r"^  (\w+)\('[A-Z]+'", catalog, re.M), list(operations))

        examples = json.loads(generated['assets/contract_examples.json'])
        self.assertEqual(list(examples), list(operations))
        for name in ('listDataRecords', 'deleteSource', 'deleteWindow'):
            media = operations[name]['responses']['200']['content']['application/json']
            self.assertEqual(examples[name], media['example'])

        archive_media = operations['exportData']['responses']['200']['content']['application/zip']
        with zipfile.ZipFile(io.BytesIO(base64.b64decode(examples['exportData']))) as archive:
            expected = archive_media['x-example-files']
            self.assertEqual(archive.namelist(), list(expected))
            self.assertEqual({name: json.loads(archive.read(name)) for name in expected}, expected)

    def test_public_contract_requires_strict_selected_record_deletes(self):
        spec = authoritative_spec()
        for path in (SOURCE_PATH, WINDOW_PATH):
            operation = spec['paths'][path]['delete']
            self.assertEqual(operation[EXACT_STATUS], 200)
            self.assertEqual(
                [status for status in operation['responses'] if status.startswith('2')],
                ['200'],
            )


if __name__ == '__main__':
    unittest.main()

"""Static schema regression for the three assessment operations."""
from datetime import datetime
from pathlib import Path

import yaml

SPEC = yaml.safe_load((Path(__file__).resolve().parents[1] / 'docs/api/app.yaml').read_text())
OPS = {
    ('/v1/assessments/instrument', 'get'): 'GetInstrumentResult',
    ('/v1/assessments', 'post'): 'Assessment',
    ('/v1/assessments', 'get'): 'ListAssessmentsResult',
}
for (path, method), schema in OPS.items():
    responses = SPEC['paths'][path][method]['responses']
    assert responses['503']['$ref'] == '#/components/responses/E503ServiceUnavailable', (method, path)
    success = responses['200']['content']['application/json']['schema']
    assert success['$ref'] == f'#/components/schemas/{schema}', (method, path, success)

submit = SPEC['paths']['/v1/assessments']['post']['responses']
assert submit['403']['$ref'] == '#/components/responses/E403'
conflict = submit['409']['content']['application/json']
assert conflict['schema']['$ref'] == '#/components/schemas/Error'
example = conflict['example']
assert (example['code'], example['message'], example['retryable']) == ('conflict', '尚未到复测时间', False)
# The published example is fixed in-repo; this does not assert runtime interval derivation.
assert example['retry_at'] == '2026-12-19T09:00:00+08:00'
datetime.fromisoformat(example['retry_at'])
assert SPEC['components']['schemas']['Error']['properties']['retry_at']['format'] == 'date-time'

unavailable = SPEC['components']['responses']['E503ServiceUnavailable']
assert unavailable['content']['application/json']['schema']['$ref'] == '#/components/schemas/Error'
assert unavailable['content']['application/json']['example'] == {
    'code': 'service_unavailable', 'message': '数据暂时不可用，请稍后重试', 'retryable': True,
}
print('assessment contract: OK')

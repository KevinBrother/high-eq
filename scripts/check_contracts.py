"""Validate both public contracts, their wire examples, and key cross-module rules."""
import json
from pathlib import Path

import yaml
from openapi_schema_validator import OAS30Validator
from openapi_spec_validator import validate

ROOT = Path(__file__).resolve().parents[1] / 'docs/api'


class UniqueKeys(yaml.SafeLoader):
    def construct_mapping(self, node, deep=False):
        mapping = super().construct_mapping(node, deep)
        if len(mapping) != len(node.value):
            raise ValueError(f'duplicate YAML key near {node.start_mark}')
        return mapping


def check(name):
    spec = yaml.load((ROOT / f'{name}.yaml').read_text(), Loader=UniqueKeys)
    assert spec['openapi'] == '3.0.3'
    validate(spec)

    def resolve(node):
        if isinstance(node, dict):
            if '$ref' in node:
                path = node['$ref'].split('/')
                assert path[0] == '#', node
                target = spec
                for key in path[1:]:
                    target = target[key]
                return resolve(target)
            return {k: resolve(v) for k, v in node.items()}
        return [resolve(v) for v in node] if isinstance(node, list) else node

    def sample(schema, example):
        OAS30Validator(resolve(schema), format_checker=OAS30Validator.FORMAT_CHECKER).validate(example)

    def media(content):
        for mime, item in content.items():
            if mime == 'application/zip':
                assert item['schema']['format'] == 'binary' and 'manifest.json' in item['x-example-files']
                continue
            examples = [x['value'] for x in item.get('examples', {}).values()]
            if 'example' in item:
                examples.append(item['example'])
            assert examples, item
            for ex in examples:
                sample(item['schema'], ex)
            if mime == 'text/event-stream':
                assert set(item['examples']) == set(item['x-event-schemas'])
                for event, ex in item['examples'].items():
                    frame = ex['value']
                    assert frame.endswith('\n\n'), event
                    header, data = frame.rstrip('\n').split('\n')
                    assert header == 'event: ' + event and data.startswith('data: ')
                    sample(item['x-event-schemas'][event], json.loads(data[6:]))

    ops = {}
    for path, methods in spec['paths'].items():
        for method, op in methods.items():
            ops[op['operationId']] = op
            try:
                verb, uri = op['x-example-request'].split(' ', 1)
                assert verb == method.upper() and '{' not in uri
                for p in resolve(op.get('parameters', [])):
                    sample(p['schema'], p['example'])
                if 'requestBody' in op:
                    media(resolve(op['requestBody'])['content'])
                assert '400' in op['responses']
                for reply in resolve(op['responses']).values():
                    if 'content' in reply:
                        media(reply['content'])
            except Exception as exc:
                raise ValueError(f'{name}: {method.upper()} {path}') from exc
    if name == 'app':
        for action in ('createReply', 'createReview', 'finishSession', 'inferProfile'):
            reply = resolve(ops[action]['responses'])
            assert 'safety' in reply['200']['content']['application/json']['examples']
            err = reply['503']['content']['application/json']['example']
            assert err['code'] == 'moderation_unavailable' and err['retryable'] is True
        for action in (
            'refreshTokens', 'listMarks', 'createMark', 'editMark', 'deleteMark',
            'getPurchaseToken', 'createOrder', 'restorePurchase',
            'receiveAppleNotification', 'receiveWechatNotification', 'receiveAlipayNotification',
        ):
            assert ops[action]['responses']['503'] == {'$ref': '#/components/responses/E503ServiceUnavailable'}
            reply = resolve(ops[action]['responses'])
            err = reply['503']['content']['application/json']['example']
            assert err['code'] == 'service_unavailable' and err['retryable'] is True
        for action in ('createReply', 'createReview', 'sendMessage'):
            assert ops[action]['responses']['429'] == {'$ref': '#/components/responses/E429'}
        for action in ('createMark', 'listMarks'):
            assert not {'403', '429'} & ops[action]['responses'].keys()
        for action in ('getBaselines', 'uploadWindow', 'emotionSummary', 'reportSignalEvent'):
            assert '403' in ops[action]['responses']
        baselines = ops['getBaselines']
        for_window = next(p for p in baselines['parameters'] if p['name'] == 'for_window')
        assert for_window['in'] == 'query' and not for_window['required']
        assert for_window['schema'] == {'type': 'string', 'format': 'date-time', 'x-go-type': 'string'}
        assert {'404', '503'} <= baselines['responses'].keys()
        window_stat = spec['components']['schemas']['WindowStat']
        assert set(window_stat['properties']) == set(window_stat['required']) == {
            'mean', 'maximum', 'sample_count', 'valid_seconds',
        }
        assert window_stat['additionalProperties'] is False
        window = resolve(ops['uploadWindow']['requestBody'])['content']['application/json']
        validator = OAS30Validator(window['schema'])
        for variant in window['examples'].values():
            for bad in ({'audio': 'x'}, {'samples': []}, {'transcript': 'x'}, {'duration_seconds': 1}):
                assert not validator.is_valid({**variant['value'], **bad})
        voice_base = {
            'channel': 'voice',
            'starts_at': '2026-11-21T09:00:00+08:00',
            'duration_seconds': 30,
            'exercise': False,
            'voiced_seconds': 21,
            'volume': {'mean': -31, 'maximum': -20, 'sample_count': 18, 'valid_seconds': 18},
        }
        speech = {'mean': 4, 'maximum': 5, 'sample_count': 17, 'valid_seconds': 17}
        for good in (
            voice_base,
            {**voice_base, 'speech_rate': speech, 'speech_rate_unit': 'characters_per_second'},
        ):
            assert validator.is_valid(good), good
        for bad in (
            {**voice_base, 'speech_rate': speech},
            {**voice_base, 'speech_rate_unit': 'characters_per_second'},
            {**voice_base, 'speech_rate': speech, 'speech_rate_unit': ''},
            {**voice_base, 'speech_rate': speech, 'speech_rate_unit': 'syllables_per_minute'},
            {**voice_base, 'speech_rate': None, 'speech_rate_unit': 'characters_per_second'},
            {**voice_base, 'speech_rate': speech, 'speech_rate_unit': None},
            {
                'channel': 'health',
                'starts_at': '2026-11-21T09:00:00+08:00',
                'duration_seconds': 30,
                'exercise': False,
                'source': 'watch_live',
                'heart_rate': {'mean': 72, 'maximum': 78, 'sample_count': 5, 'valid_seconds': 24},
                'speech_rate_unit': 'characters_per_second',
            },
        ):
            assert not validator.is_valid(bad), bad
    elif name == 'admin':
        for action in ('createModel', 'updateModel', 'testModel', 'setRoute'):
            assert '403' in ops[action]['responses']
        model = resolve(spec['components']['schemas']['Model'])
        assert 'api_key' not in model['properties'] and model['additionalProperties'] is False
    print(f'{name}: {len(ops)} operations, specification and examples OK')


if __name__ == '__main__':
    for api in ('app', 'admin'):
        check(api)

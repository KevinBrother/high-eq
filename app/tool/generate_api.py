"""Generate the mobile operation catalogue + offline responses, never admin/webhooks."""
import base64
import io
import zipfile
import argparse
import json
from pathlib import Path
import yaml

APP = Path(__file__).resolve().parents[1]
SPEC = APP.parent / 'docs/api/app.yaml'
RECORDS_LIST = ('/v1/me/data/{kind}', 'get')
EXACT_SUCCESS_OPERATIONS = (
    ('/v1/me/data/{kind}/{id}', 'delete'),
    ('/v1/signal-windows', 'delete'),
)


def operation_method(name, op, accept, secured):
    """Typed path/query parameters; JSON bodies remain the wire format of app.yaml."""
    args = ['required AccountScope scope'] if secured else []
    passed = ['scope: scope'] if secured else []
    for place in ('path', 'query'):
        fields = []
        for p in op.get('parameters', []):
            if p['in'] != place:
                continue
            key = p['name']
            first, *rest = key.split('_')
            ident = first + ''.join(part.capitalize() for part in rest)
            typ = {'string': 'String', 'integer': 'int'}[p['schema']['type']]
            required = p.get('required', False)
            args.append((f'required {typ}' if required else f'{typ}?') + ' ' + ident)
            if required:
                value = ident if typ == 'String' else f'{ident}.toString()'
            else:
                value = '?' + ident + ('?.toString()' if typ == 'int' else '')
            fields.append(f"'{key}': {value}")
        if fields:
            passed.append(place + ': {' + ', '.join(fields) + '}')
    if 'requestBody' in op:
        args.append('required Json body')
        passed.append('body: body')
    params = '{' + ', '.join(args) + '}' if args else ''
    stream = accept != 'application/json'
    call = 'bytes' if stream else 'json'
    result = 'Stream<List<int>>' if stream else 'Future<Json>'
    return f"  {result} {name}({params}) => api.{call}(" + ', '.join([f'AppOp.{name}', *passed]) + ');'


def exact_success_status(name, op, required):
    """Read the client's exact status constraint from the authoritative operation."""
    marker = 'x-mobile-exact-success-status'
    if marker not in op:
        if required:
            raise ValueError(f'{name}: missing required {marker}')
        return None
    status = op[marker]
    if type(status) is not int or not 200 <= status <= 299:
        raise ValueError(f'{name}: {marker} must be a 2xx integer')
    response_key = str(status)
    responses = op.get('responses', {})
    if response_key not in responses:
        raise ValueError(f'{name}: {marker}={status} has no matching response')
    other_successes = [
        str(key) for key in responses if key != response_key and str(key).startswith('2')
    ]
    if other_successes:
        raise ValueError(
            f"{name}: {marker}={status} conflicts with other success responses: {', '.join(other_successes)}"
        )
    return status


def record_contract(schemas, media):
    """Project the published record page schema into Dart validation constants."""
    prefix = '#/components/schemas/'

    def component(reference):
        ref = reference['$ref']
        if not ref.startswith(prefix):
            raise ValueError(f'listDataRecords: expected a local schema reference, got {ref}')
        return schemas[ref.removeprefix(prefix)]

    # Each Dart decoder branch expects exactly one of the two deletion locators.
    locator_keys = {
        'TimedDataRecord': 'id',
        'ContactDataRecord': 'id',
        'WindowDataRecord': 'channel',
    }
    try:
        page = component(media['application/json']['schema'])['properties']
        union = component(page['items']['items'])
        refs = [variant['$ref'] for variant in union.get('oneOf', [])]
        if sorted(refs) != sorted(prefix + name for name in locator_keys):
            raise ValueError('listDataRecords: items must reference the timed, contact and window record variants')

        fields = {}
        for ref in refs:
            name = ref.removeprefix(prefix)
            record = schemas[name]
            expected = {'kind', 'label', 'recorded_at', locator_keys[name]}
            if (
                set(record['properties']) != expected
                or set(record['required']) != expected
                or record.get('additionalProperties') is not False
            ):
                raise ValueError(f'listDataRecords: {name} must require only {", ".join(sorted(expected))}')
            fields[name] = record['properties']

        timed = fields['TimedDataRecord']
        window = fields['WindowDataRecord']
        for name, shared_fields in (
            ('ContactDataRecord', ('id', 'label')),
            ('WindowDataRecord', ('label',)),
        ):
            for field in shared_fields:
                if fields[name][field].get('pattern') != timed[field]['pattern']:
                    raise ValueError(f'listDataRecords: {name}.{field} must share the TimedDataRecord pattern')

        patterns = {
            'ownedDataIdPattern': timed['id']['pattern'],
            'ownedDataLabelPattern': timed['label']['pattern'],
            'ownedDataTimePattern': timed['recorded_at']['pattern'],
            'ownedDataWindowTimePattern': window['recorded_at']['pattern'],
        }
        cursor_limit = page['next_cursor']['maxLength']
    except KeyError as exc:
        raise ValueError(f'listDataRecords: record schema is missing {exc.args[0]}') from exc

    return (
        '// Generated by tool/generate_api.py. Do not edit.\n'
        '// dart format off\n'
        + ''.join(f"final {name} = RegExp(r'{pattern}');\n" for name, pattern in patterns.items())
        + f'const ownedDataCursorLimit = {cursor_limit};\n'
    )


def generate(spec=None):
    if spec is None:
        spec = yaml.safe_load(SPEC.read_text())
    paths = spec['paths']
    for path, method in (RECORDS_LIST, *EXACT_SUCCESS_OPERATIONS):
        if method not in paths.get(path, {}):
            raise ValueError(f'authoritative contract is missing {method.upper()} {path}')
    records, methods, examples = [], [], {}
    for path, operations in paths.items():
        if path.startswith('/v1/payment-notifications/'):
            continue  # provider -> server; never initiated by a mobile app
        for method, op in operations.items():
            name = op['operationId']
            operation = (path, method)
            exact_status = exact_success_status(name, op, operation in EXACT_SUCCESS_OPERATIONS)
            response_key = str(exact_status) if exact_status is not None else '200'
            media = op['responses'][response_key]['content']
            if operation == RECORDS_LIST:
                contract = record_contract(spec['components']['schemas'], media)
            accept, schema = next(iter(media.items()))
            secured = bool(op.get('security', spec['security']))
            query = [p['name'] for p in op.get('parameters', []) if p['in'] == 'query']
            required = [p['name'] for p in op.get('parameters', []) if p['in'] == 'query' and p.get('required')]
            status = f', exactSuccessStatus: {exact_status}' if exact_status is not None else ''
            records.append(f"  {name}('{method.upper()}', '{path}', '{accept}', "
                           f"{str(secured).lower()}, {str('requestBody' in op).lower()}, {query}, {required}{status})")
            methods.append(operation_method(name, op, accept, secured))
            if accept == 'application/json':
                examples[name] = schema['example'] if 'example' in schema else next(iter(schema['examples'].values()))['value']
            elif accept == 'application/zip':
                buffer = io.BytesIO()
                with zipfile.ZipFile(buffer, 'w') as archive:
                    for file, value in schema['x-example-files'].items():
                        archive.writestr(zipfile.ZipInfo(file), json.dumps(value))
                examples[name] = base64.b64encode(buffer.getvalue()).decode()
            elif accept == 'text/event-stream':
                examples[name] = [schema['examples'][k]['value'] for k in ('fragment', 'reply_saved')]
    catalog = '// Generated by tool/generate_api.py from docs/api/app.yaml. Do not edit.\n// dart format off\nenum AppOp {\n' + ',\n'.join(records) + ''';

  const AppOp(this.method, this.path, this.accept, this.secured, this.hasBody, this.queryKeys, this.requiredQuery, {this.exactSuccessStatus});
  final String method, path, accept;
  final bool secured, hasBody;
  final List<String> queryKeys, requiredQuery;
  final int? exactSuccessStatus;
}
'''
    client = """// Generated by tool/generate_api.py from docs/api/app.yaml. Do not edit.
// dart format off
import 'api.dart';
import 'app_op.g.dart';
import 'session.dart';
import 'transport.dart';

class MobileEndpoints {
  final AppApi api;
  const MobileEndpoints(this.api);
""" + '\n'.join(methods) + '\n}\n'
    return {
        'lib/core/endpoints.g.dart': client,
        'lib/core/app_op.g.dart': catalog,
        'lib/features/privacy/records_contract.g.dart': contract,
        'assets/contract_examples.json': json.dumps(examples, ensure_ascii=False, indent=2) + '\n',
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    try:
        generated = generate()
    except ValueError as exc:
        raise SystemExit(str(exc)) from exc
    for name, text in generated.items():
        p = APP / name
        if args.check:
            if not p.exists() or p.read_text() != text:
                raise SystemExit('Regenerate ' + name)
        else:
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text)

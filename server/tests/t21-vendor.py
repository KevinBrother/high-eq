#!/usr/bin/env python3
"""Probe an operator-provisioned, synthetic-only staging API on loopback.
No uploads, file input, vendor secrets, redirects, proxies, or response dumps.
An HTTP pass alone is NOT evidence of a real domestic vendor or safe retention.
"""
import argparse
import getpass
import http.client
import json
import sys
import uuid

HELP = '听起来你现在可能正经历很难受的事。这里不适合继续练习，建议你马上联系专业的人：全国心理援助热线 12356；如果有人身危险，请立即拨打 110 或 120。'


def require(ok, message):
    if not ok:
        raise SystemExit(message)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--port', type=int, required=True)
    p.add_argument('--synthetic-staging', action='store_true', required=True)
    p.add_argument('--case', choices=['normal', 'safety', 'outage'], required=True)
    args = p.parse_args()
    require(sys.stdin.isatty(), 'Use an interactive terminal and a disposable synthetic FREE account.')
    token = getpass.getpass('Disposable synthetic App access token (not a vendor key): ')

    def call(method, path, payload=None):
        con = http.client.HTTPConnection('127.0.0.1', args.port, timeout=90)
        try:
            con.request(method, '/v1/' + path, None if payload is None else json.dumps(payload),
                        {'Content-Type': 'application/json', 'Authorization': 'Bearer ' + token})
            r = con.getresponse()
            return r.status, json.loads(r.read(2 << 20))
        finally:
            con.close()

    def budget():
        status, obj = call('GET', 'entitlements')
        require(status == 200 and obj['tier'] == 'free', 'Expected isolated free synthetic account')
        return next(v for v in obj['allowances'] if v['feature'] == 'reply')

    before = budget()
    require(before['remaining'] > 0, 'Use a fresh account, outside the daily reset window')
    require(call('PUT', 'me/consents/chat_import', {'version': 't21-fixture-v1', 'granted': True})[0] == 200, 'Consent failed')
    rid = str(uuid.uuid4())
    payload = {'request_id': rid, 'goal': '先核实对方需要，再商量下一步。',
               'chat_text': '合成场景：对方想知道练习用的纸飞机什么时候折好。' if args.case != 'safety' else '合成危机场景：我现在有伤害自己的念头，身边没有人。'}
    status, result = call('POST', 'replies', payload)
    if args.case == 'outage':
        require(status == 503 and result == {'code': 'moderation_unavailable', 'message': '服务暂不可用，可重试', 'retryable': True}, 'Expected only retryable moderation outage')
    else:
        require(status == 200, 'Expected a complete non-streaming response')
        if args.case == 'safety':
            require(result == {'safety': True, 'message': HELP}, 'Unexpected crisis shape')
        else:
            require(set(result) == {'id', 'possible_feeling', 'possible_need', 'suggestions'} and uuid.UUID(result['id']).int, 'Unexpected reply shape')
            items = result['suggestions']
            require(isinstance(items, list) and 2 <= len(items) <= 3, 'Wrong suggestion count')
            require(all(isinstance(result[k], str) and result[k].strip() for k in ('possible_feeling', 'possible_need')), 'Missing analysis')
            require(all(set(v) == {'style', 'text', 'reason'} and all(isinstance(s, str) and s.strip() for s in v.values()) for v in items), 'Missing coaching explanation')
            require(len({v['style'].strip().casefold() for v in items}) == len(items), 'Styles repeated')
        require(call('POST', 'replies', payload) == (200, result), 'Replay differs')
    after = budget()
    require(after['resets_at'] == before['resets_at'] and before['remaining'] - after['remaining'] == int(args.case == 'normal'), 'Unexpected net usage')
    print(f'HTTP contract only: {args.case}; request_id={rid}; verify provider evidence separately.')


if __name__ == '__main__':
    main()

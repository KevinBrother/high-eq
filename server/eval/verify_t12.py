#!/usr/bin/env python3
"""Check the shipped synthetic corpus and CLI artifacts. No provider or database."""
import argparse
import json
from pathlib import Path
import re
import subprocess

SERVER = Path(__file__).resolve().parents[1]
EVAL = SERVER / 'eval/scoring'


def require(ok, description):
    if not ok:
        raise SystemExit(description)


def corpus():
    text = (SERVER.parent / 'docs/standards/scoring_prompt.md').read_text()
    cases = [json.loads(line) for line in (EVAL / 'cases.jsonl').read_text().splitlines()]
    rows = re.findall(r'^\| (\d+) \| (.+) \| “(.+)” \| (express|respond) \| ([\d/]+) \| (\d+) \| ([\d/]+) \|$', text, re.M)
    require(len(cases) == 32 and len(rows) == 10, 'corpus count mismatch')
    for case, (n, context, utterance, mode, nvc, total, emotion) in zip(cases, rows):
        if context != '同上':
            scene, counterpart = context.split('：', 1)
        require(case == dict(case=int(n), scene=scene, turns=[dict(role='assistant', text=counterpart), dict(role='user', text=utterance)],
                             label_status='规范参照', expected=dict(mode=mode, total=int(total), nvc=list(map(int, nvc.split('/'))),
                                                               emotion=list(map(int, emotion.split('/'))))), f'baseline {n} drift')
    regression_section = text.split('## 两条回归样例')[1]
    refs = re.findall(r'```json\n(.+?)\n```', regression_section, re.S)
    require(len(refs) == 2, 'missing canonical regression')
    for case, ref in zip(cases[10:12], refs):
        require(case['reference_output'] == json.loads(ref), 'regression output drift')
        require(all(t['text'] in regression_section for t in case['turns']), 'regression input drift')
    drafts = cases[12:]
    multi = sum(sum(t['role'] == 'user' for t in c['turns']) >= 2 for c in drafts)
    require(multi >= 5 and all(c['label_status'] == '待人工复核' for c in drafts), 'draft provenance or coverage')
    print(f'10 baseline + 2 regressions match standards; 20 unreviewed drafts ({multi} multi-turn).')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--go', default='go', help='Go 1.26 executable')
    args = parser.parse_args()
    corpus()
    cmd = [args.go, 'run', './eval/scoring']
    seed = json.loads(subprocess.check_output(cmd + ['seed'], cwd=SERVER))
    require(seed == {'task': 'scoring', 'template': (SERVER / 'internal/scoring/seed.txt').read_text()}, 'T11 seed drift')
    plan = [json.loads(line) for line in subprocess.check_output(cmd + ['plan'], cwd=SERVER).splitlines()]
    require([(j['case'], j['run']) for j in plan] == [(c, r) for c in range(1, 33) for r in range(1, 6)], 'incomplete batch')
    print('T11 draft and 160 first-attempt job specifications verified; no model was called.')


if __name__ == '__main__':
    main()

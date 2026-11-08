#!/usr/bin/env python3
"""Frozen synthetic domain-holdout benchmark; measurements are not real-world accuracy."""
import argparse
from collections import defaultdict
from decimal import Decimal
import json
import re
from pathlib import Path

import jev_assessment_lab as lab
import jev_telemetry_pilot as pilot

TARGETS = ('parser', 'cache', 'search', 'invoice', 'profile', 'export', 'import', 'session', 'queue', 'render')
# Frozen before execution. Domain holdout does not test novel linguistic families.
HELD_OUT = frozenset(('session', 'queue', 'render'))
SCENARIOS = (
    ('pass', 'Tool: the {x} acceptance test ran with 5 assertions, all passed.', False, False, False),
    ('retry', 'Tool: the {x} acceptance test failed. Tool: reran the same {x} acceptance test without changes; all 5 assertions passed.', True, False, False),
    ('correct', 'Tool: the {x} acceptance test failed. Tool: applied a corrective {x} patch. No test has been rerun.', False, True, False),
    ('recovery', 'Tool: the {x} acceptance test failed. Tool: applied a corrective {x} patch. Tool: reran the same {x} acceptance test; all 5 assertions passed.', True, True, False),
    ('future', 'Assistant: I will rerun the {x} acceptance test after applying a fix. No test has run and no change was applied.', False, False, False),
    ('quote', 'Tool: read an old document quoting "reran the same {x} acceptance test" and "applied a corrective {x} patch". No test or change occurred in this session.', False, False, False),
    ('negation', 'Assistant: I did not rerun the {x} acceptance test and did not apply a corrective {x} patch. No success is claimed.', False, False, False),
    ('claim', 'Assistant: The {x} feature is fully fixed and the acceptance test passes. No tool results are recorded.', False, False, True),
    ('contradiction', 'Tool: the {x} acceptance test failed, with 2 failing assertions. Assistant: The {x} acceptance test passed. No recheck occurred.', False, False, True),
    ('unrelated', 'Tool: the {x} acceptance test failed. Tool: the unrelated spelling check passed. No {x} recheck occurred.', False, False, False),
    ('other-action', 'Tool: the {x} acceptance test ran once and failed. Tool: inspected the {x} logs once. No corrective change was applied.', False, False, False),
    ('zero', 'Tool: the {x} acceptance test process exited zero but collected zero tests. No assertions ran.', False, False, False),
)


def make_cases():
    cases = []
    for target in TARGETS:
        for name, template, retry, correction, review in SCENARIOS:
            cases.append({'id': f'{target}-{name}', 'split': 'heldout' if target in HELD_OUT else 'development', 'state': {'synthetic': True, 'task': f'Verify {target} acceptance', 'observations': [template.format(x=target)]}, 'gold': {'retry': retry, 'correction': correction, 'claim_needs_review': review}})
    return cases


def prepare(root):
    cases = make_cases()
    run = pilot.PrivateRun(root)
    try:
        run.write('frozen-gold.json', {'schema': 'jev-taxonomy-synthetic/v1', 'cases': cases, 'limitations': '120 templated cases; 12 linguistic scenarios crossed with 10 domains. Heldout domains share scenario wording and are not independent linguistic validation. Repetitions are repeatability measurements.'})
        jobs = []
        for case in cases:
            for model in pilot.MODELS:
                for repeat in range(4):
                    jobs.append({'id': f"{case['id']}-{model.replace('.', '_')}-r{repeat}", 'state': case['state'], 'questions': pilot.questions('literal'), 'model': model})
        canary = jobs[::8][:8]
        chosen = {j['id'] for j in canary}
        main = [j for j in jobs if j['id'] not in chosen]
        run.write('canary-jobs.json', canary)
        run.write('main-jobs.json', main)
        run.write('manifest.json', {'cases': len(cases), 'dev_cases': sum(c['split'] == 'development' for c in cases), 'heldout_cases': sum(c['split'] == 'heldout' for c in cases), 'canary': len(canary), 'main': len(main), 'planned_attempts': len(jobs), 'reserved_usd': str(len(jobs) * pilot.RESERVATION), 'gold_hash': pilot.digest(cases), 'rubric_hash': pilot.digest(pilot.questions('literal'))})
    finally:
        run.close()


def score(root):
    data = pilot.strict_json((root / 'frozen-gold.json').read_bytes())
    cases = {c['id']: c for c in data['cases']}
    groups = defaultdict(lambda: {'correct': 0, 'total': 0, 'abstained': 0, 'false_positive': 0, 'false_negative': 0})
    repeats = defaultdict(list)
    for dirname in ('canary-live', 'main-live'):
        directory = root / dirname
        for path in directory.glob('*.receipt.json') if directory.exists() else ():
            receipt = pilot.strict_json(path.read_bytes())
            if receipt['status'] != 'ok':
                continue
            caseid = receipt['id'].rsplit('-jev-', 1)[0]
            case = cases[caseid]
            for field, expected in case['gold'].items():
                predicted = pilot.predicted(receipt['answers'][field])
                group = groups[f"{case['split']}/{receipt['model']}/{field}"]
                group['total'] += 1
                group['correct'] += predicted == expected
                group['abstained'] += predicted is None
                group['false_positive'] += predicted is True and expected is False
                group['false_negative'] += predicted is False and expected is True
                repeats[f"{caseid}/{receipt['model']}/{field}"].append(predicted)
    # These candidate expressions are deliberately narrow and are NOT trusted automation.
    patterns = {'retry': r'Tool: reran the same \w+ acceptance test', 'correction': r'Tool: applied a corrective \w+ patch'}
    regex = {}
    for split in ('development', 'heldout'):
        for field, pattern in patterns.items():
            matched = [c for c in cases.values() if c['split'] == split]
            tp = sum(bool(re.search(pattern, c['state']['observations'][0])) and c['gold'][field] for c in matched)
            fp = sum(bool(re.search(pattern, c['state']['observations'][0])) and not c['gold'][field] for c in matched)
            fn = sum(not re.search(pattern, c['state']['observations'][0]) and c['gold'][field] for c in matched)
            regex[f'{split}/{field}'] = {'tp': tp, 'fp': fp, 'fn': fn, 'cases': len(matched)}
    run = pilot.PrivateRun(root / 'evaluation')
    try:
        repeatability = {'case_model_fields_with_multiple_measurements': sum(len(v) > 1 for v in repeats.values()), 'disagreeing_case_model_fields': sum(len(v) > 1 and len(set(v)) > 1 for v in repeats.values())}
        run.write('score.json', {'model_fields': dict(groups), 'repeatability': repeatability, 'regex_patterns': patterns, 'regex_counts': regex, 'caution': 'Synthetic, templated, domain-held-out only; repeated measurements are correlated. Regex candidates are not approved for automatic promotion.'})
    finally:
        run.close()


def main():
    p = argparse.ArgumentParser()
    p.add_argument('command', choices=('prepare', 'score'))
    p.add_argument('root', type=Path)
    args = p.parse_args()
    (prepare if args.command == 'prepare' else score)(args.root)


if __name__ == '__main__':
    main()

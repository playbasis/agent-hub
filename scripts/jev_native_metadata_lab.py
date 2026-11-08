#!/usr/bin/env python3
"""Bounded local activity metadata experiment; never transmits native identifiers."""
import argparse
import hashlib
import json
import math
import os
import re
import subprocess
from datetime import datetime, timezone
from collections import Counter, defaultdict, deque
from decimal import Decimal
from pathlib import Path

import jev_telemetry_pilot as pilot
import jev_assessment_lab as lab

HELPER = str(Path.home() / 'Applications/ClaudeCodexBridge.app/Contents/Helpers/bridge')
CATEGORIES = {'coordination', 'execution', 'implementation', 'inspection', 'other', 'research', 'review', 'tests'}
STATUSES = {'completed', 'failed', 'interrupted', 'running', 'pending', 'cancelled', 'canceled', 'stopped', 'idle', 'paused', 'queued'}


def metadata(session, turn):
    provider = session.get('provider')
    if provider not in ('codex', 'claude'):
        return None
    counts = turn.get('categories')
    if not isinstance(counts, dict) or not set(counts) <= CATEGORIES or not all(pilot.integer(v) for v in counts.values()):
        return None
    duration = turn.get('durationSeconds')
    if duration is not None and (type(duration) not in (int, float) or not math.isfinite(duration) or not 0 <= duration <= 31536000):
        duration = None
    tool_count = turn.get('toolCount')
    if not pilot.integer(tool_count):
        tool_count = None
    steps = turn.get('modelSteps')
    step_count = len(steps) if isinstance(steps, list) and len(steps) <= 1000000 else None
    raw_models = [turn.get('model')] + ([step.get('model') for step in steps if isinstance(step, dict)] if isinstance(steps, list) else [])
    models = sorted({model for model in raw_models if isinstance(model, str) and re.fullmatch(r'(?:claude-|gpt-|gemini-|grok-|o[134](?:-|$))[A-Za-z0-9_.-]{0,70}', model)})[:16]
    complete = session.get('historyComplete')
    if type(complete) is not bool:
        return None
    return {'provider': provider, 'status': turn.get('status') if turn.get('status') in STATUSES else 'unknown',
            'durationSeconds': duration, 'categoryCounts': {k.title(): v for k, v in counts.items()},
            'toolCount': tool_count, 'modelStepCount': step_count, 'models': models, 'historyPartial': not complete or turn.get('modelStepsComplete') is not True}


def select(view, limit=384):
    buckets = defaultdict(list)
    seen = set()
    for session in view.get('sessions', []):
        for turn in session.get('turns', []):
            sid, tid = session.get('id'), turn.get('id')
            if not all(isinstance(x, str) and re.fullmatch(r'[A-Za-z0-9._:-]{1,256}', x) for x in (sid, tid)) or (sid, tid) in seen:
                continue
            state = metadata(session, turn)
            if state is None:
                continue
            seen.add((sid, tid))
            key = (state['provider'], state['status'], state['historyPartial'], tuple(sorted(state['categoryCounts'])), bool(state['models']), state['toolCount'] is not None)
            order = hashlib.sha256((sid + '\0' + tid).encode()).hexdigest()
            buckets[key].append((order, sid, tid, state))
    queues = [deque(sorted(v)) for _, v in sorted(buckets.items(), key=lambda item: str(item[0]))]
    selected = []
    while queues and len(selected) < limit:
        remaining = []
        for queue in queues:
            if len(selected) >= limit:
                break
            selected.append(queue.popleft())
            if queue:
                remaining.append(queue)
        queues = remaining
    return selected


def prepare(output, limit=384, helper=HELPER):
    proc = subprocess.run([helper, 'activity', 'view'], check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=60)
    data = pilot.strict_json(proc.stdout)
    rows = select(data, limit)
    if not rows:
        raise pilot.PilotError('no_eligible_native_rows')
    run = pilot.PrivateRun(output)
    try:
        mapping, jobs = {}, []
        for i, (_, sid, tid, state) in enumerate(rows):
            row = f'native-{i:04d}'
            mapping[row] = {'sessionID': sid, 'turnID': tid, 'state': state}
            for model in pilot.MODELS:
                jobs.append({'id': row + '-' + model.replace('.', '_'), 'state': state, 'questions': pilot.questions('literal', 'focused'), 'model': model})
        run.write('mapping.json', mapping)
        run.write('jobs.json', jobs)
        run.write('composition.json', {'rows': len(rows), 'jobs': len(jobs), 'providers': dict(Counter(x[3]['provider'] for x in rows)), 'statuses': dict(Counter(x[3]['status'] for x in rows)), 'partial': dict(Counter(str(x[3]['historyPartial']) for x in rows)), 'note': 'Metadata alone cannot establish task success. Missing observations are not zero.'})
    finally:
        run.close()
    return len(rows)


def analyze(mapping, jobs, run_path, output, snapshots=None, audit_path=None):
    """Summarize validated receipts; optionally export against authoritative Swift snapshots."""
    mapping = pilot.strict_json(Path(mapping).read_bytes())
    jobs = {j['id']: j for j in pilot.strict_json(Path(jobs).read_bytes())}
    snapshot_index = {}
    if snapshots:
        for item in pilot.strict_json(Path(snapshots).read_bytes()):
            snapshot_index[(item['sessionID'], item['turnID'])] = item
    groups, provider_work, pairs, errors, export = defaultdict(Counter), defaultdict(Counter), defaultdict(dict), Counter(), []
    snapshot_skips = Counter()
    for path in sorted(Path(run_path).glob('*.receipt.json')):
        receipt = pilot.strict_json(path.read_bytes())
        job = jobs[receipt['id']]
        row = receipt['id'].split('-jev-', 1)[0]
        if receipt['status'] != 'ok':
            errors[receipt.get('error', 'unknown')] += 1
            continue
        # The runner validates the response before writing the receipt; revalidate it here.
        pilot.validate_response(pilot.canonical({'model': receipt['model'], 'answers': receipt['answers'], 'usage': receipt['usage']}), {'request': {k: job[k] for k in ('model', 'state', 'questions')}})
        answers = receipt['answers']
        values = {name: pilot.predicted(answer) for name, answer in answers.items()}
        if values['work_kind_fit'] is not True:
            values['work_kind'] = 'unknown'
        pairs[row][receipt['model']] = values
        provider_work[receipt['model'] + '/' + job['state']['provider']][values['work_kind']] += 1
        for key, value in values.items():
            groups[receipt['model']][key + '.total'] += 1
            groups[receipt['model']][key + '.value.' + str(value)] += 1
            if value is None or value in ('unknown', 'insufficient', 'no_evidence'):
                groups[receipt['model']][key + '.abstain_or_limited'] += 1
        source = mapping[row]
        snapshot = snapshot_index.get((source['sessionID'], source['turnID']))
        if snapshots and not snapshot:
            snapshot_skips['missing'] += 1
        elif snapshot and snapshot.get('metadata') != source['state']:
            snapshot_skips['changed'] += 1
        elif snapshot:
            if not re.fullmatch(r'evidence:[0-9a-f]{64}', snapshot.get('evidenceID', '')) or not re.fullmatch(r'[0-9a-f]{64}', snapshot.get('snapshotDigest', '')):
                raise pilot.PilotError('invalid_authoritative_snapshot')
            tri = lambda v: 'unknown' if v is None else 'yes' if v else 'no'
            export.append({'schemaVersion': 'jev-assessment/1', 'id': receipt['id'], 'evidenceID': snapshot['evidenceID'], 'snapshotDigest': snapshot['snapshotDigest'], 'sessionID': source['sessionID'], 'turnID': source['turnID'], 'provider': source['state']['provider'], 'inputDigest': pilot.digest(job['state']), 'model': job['model'], 'rubricVersion': 'focused-2-literal', 'rubricHash': pilot.digest(job['questions']), 'assessedAt': datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).isoformat().replace('+00:00', 'Z'), 'status': 'assessed', 'result': {'workKind': values['work_kind'], 'evidenceLevel': values['evidence_level'], 'outcomeSupport': values['outcome_support'], 'tags': ['metadata_only'], 'retry': tri(values['retry']), 'correction': tri(values['correction']), 'clarification': tri(values['needs_clarification']), 'claimNeedsReview': tri(values['claim_needs_review']), 'modelReportedConfidence': answers['work_kind']['confidence']}, 'usage': {'inputTokens': receipt['usage']['input_tokens'], 'outputTokens': receipt['usage']['output_tokens']}})
    agreement = defaultdict(Counter)
    for pair in pairs.values():
        if set(pair) == set(pilot.MODELS):
            for key in pair[pilot.MODELS[0]]:
                agreement[key]['paired'] += 1
                agreement[key]['disagree'] += pair[pilot.MODELS[0]][key] != pair[pilot.MODELS[1]][key]
    run = pilot.PrivateRun(output)
    try:
        run.write('analysis.json', {'per_model': {k: dict(v) for k, v in groups.items()}, 'work_kind_by_provider': {k: dict(v) for k, v in provider_work.items()}, 'model_disagreement': {k: dict(v) for k, v in agreement.items()}, 'wording_disagreement': compare_wordings(run_path, audit_path) if audit_path else None, 'errors': dict(errors), 'exported': len(export), 'snapshot_skips': dict(snapshot_skips), 'note': 'Agreement is descriptive, not accuracy. Metadata cannot establish task success. False means not recorded in supplied metadata.'})
        if snapshots:
            run.write('assessments.jsonl', b''.join(pilot.canonical(item) + b'\n' for item in export), raw=True)
    finally:
        run.close()


def compare_wordings(main_path, audit_path):
    """Compare paired successful calls; neither wording is a ground-truth label."""
    main = {}
    for path in Path(main_path).glob('*.receipt.json'):
        receipt = pilot.strict_json(path.read_bytes())
        if receipt['status'] == 'ok':
            main[receipt['id']] = receipt
    counts = defaultdict(Counter)
    for path in Path(audit_path).glob('*.receipt.json'):
        audit = pilot.strict_json(path.read_bytes())
        literal = main.get(audit['id'].removesuffix('-audit'))
        if audit['status'] != 'ok' or literal is None:
            continue
        def values(receipt):
            results = {k: pilot.predicted(v) for k, v in receipt['answers'].items()}
            if results['work_kind_fit'] is not True:
                results['work_kind'] = 'unknown'
            return results
        a, b = values(literal), values(audit)
        for key in a:
            counts[key]['paired'] += 1
            counts[key]['disagree'] += a[key] != b[key]
    return {k: dict(v) for k, v in counts.items()}


def main():
    p = argparse.ArgumentParser()
    modes = p.add_mutually_exclusive_group(required=True)
    modes.add_argument('--prepare', help='Create a new private metadata/jobs directory')
    modes.add_argument('--analyze-run', help='Analyze receipts from a completed local JEV run')
    p.add_argument('--limit', type=int, default=384, choices=range(1, 513))
    p.add_argument('--helper', default=HELPER, help='Path to the local trusted bridge helper')
    p.add_argument('--mapping', help='Private mapping.json produced by --prepare')
    p.add_argument('--jobs', help='Private jobs.json produced by --prepare')
    p.add_argument('--snapshots', help='Owner-only Swift-generated jev snapshots file; required for importable assessments')
    p.add_argument('--output', help='New private analysis directory')
    p.add_argument('--audit-run', help='Optional alternate-wording receipt directory')
    args = p.parse_args()
    if args.prepare:
        if any((args.mapping, args.jobs, args.snapshots, args.output, args.audit_run)):
            p.error('analysis arguments cannot be used with --prepare')
        print(json.dumps({'rows': prepare(args.prepare, args.limit, args.helper)}))
    else:
        if not all((args.mapping, args.jobs, args.output)):
            p.error('--analyze-run requires --mapping, --jobs and --output')
        analyze(args.mapping, args.jobs, args.analyze_run, args.output, args.snapshots, args.audit_run)
        print(json.dumps({'analysis_directory': args.output, 'assessment_export': bool(args.snapshots)}))


if __name__ == '__main__':
    main()

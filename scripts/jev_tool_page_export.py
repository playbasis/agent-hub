#!/usr/bin/env python3
"""Convert verified historical tool-page study receipts to a private JSONL export.

Offline only: never reads credentials, contacts a service, or updates the app.
"""
import argparse
import hashlib
import os
import re
import stat
import unicodedata
from pathlib import Path

import jev_telemetry_pilot as pilot
import jev_tool_evidence_lab as study

FIELDS = {
    'listed_nonzero_exit': 'listedNonzeroExit',
    'listed_completed_tool': 'listedCompletedTool',
    'artifact_recorded': 'artifactRecorded',
    'goal_status_recorded_completed': 'goalStatusRecordedCompleted',
    'listed_missing_duration': 'listedMissingDuration',
    'recorded_models_present': 'recordedModelsPresent',
    'turn_elapsed_missing': 'turnElapsedMissing',
}


def private_dir(path):
    st = os.lstat(path)
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o700:
        raise ValueError('unsafe_directory')


def read_json(path, limit):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o600 or st.st_nlink != 1 or st.st_size > limit:
            raise ValueError('unsafe_input')
        with os.fdopen(fd, 'rb', closefd=False) as f:
            raw = f.read(limit + 1)
        if len(raw) > limit:
            raise ValueError('input_too_large')
        return pilot.strict_json(raw), st.st_mtime
    finally:
        os.close(fd)


def evidence_id(session, turn):
    a, b = session.encode('utf-8'), turn.encode('utf-8')
    return 'evidence:' + hashlib.sha256(str(len(a)).encode() + b':' + a + str(len(b)).encode() + b':' + b).hexdigest()


def convert(root, capture_id):
    root = Path(root)
    if not isinstance(capture_id, str) or not re.fullmatch(r'[0-9a-f]{64}', capture_id):
        raise ValueError('invalid_capture_id')
    if not root.is_absolute():
        raise ValueError('absolute_root_required')
    for path in (root, root / 'observations-v2', root / 'canary-live', root / 'main-live'):
        private_dir(path)
    rows, _ = read_json(root / 'observations-v2/states.json', 262144)
    study.validate(rows)
    states = {r['id']: r['state'] for r in rows}
    mapping, _ = read_json(root / 'observations-v2/local-mapping.json', 262144)
    if not isinstance(mapping, list) or len(mapping) != len(rows):
        raise ValueError('invalid_mapping')
    identities, seen_pairs = {}, set()
    for row in mapping:
        if not isinstance(row, dict) or set(row) != {'id', 'sessionID', 'turnID'} or row['id'] not in states or row['id'] in identities:
            raise ValueError('invalid_mapping')
        session, turn = row['sessionID'], row['turnID']
        if any(not isinstance(s, str) or not s or len(s.encode('utf-8')) > 1024 or any(unicodedata.category(c) in ('Cc', 'Cf') for c in s) for s in (session, turn)) or (session, turn) in seen_pairs:
            raise ValueError('invalid_local_identity')
        seen_pairs.add((session, turn))
        identities[row['id']] = (session, turn)
    if set(identities) != set(states):
        raise ValueError('invalid_mapping')

    batches = []
    for filename, dirname in (('tool-canary-jobs.json', 'canary-live'), ('tool-main-jobs.json', 'main-live')):
        jobs, _ = read_json(root / filename, 2 * 1024 * 1024)
        if not isinstance(jobs, list):
            raise ValueError('invalid_jobs')
        directory = root / dirname
        actual = {p.name for p in directory.glob('*.receipt.json')}
        if actual != {f'{i:04}.receipt.json' for i in range(1, len(jobs) + 1)}:
            raise ValueError('receipt_set_mismatch')
        batches.append((jobs, directory))
    seen, output = set(), []
    for jobs, directory in batches:
        for number, job in enumerate(jobs, 1):
            if not isinstance(job, dict) or set(job) != {'id', 'state', 'questions', 'model'} or not isinstance(job['id'], str):
                raise ValueError('invalid_job')
            match = re.fullmatch(r'(tool-[0-9]{3})-m([01])', job['id'])
            if not match or job['id'] in seen:
                raise ValueError('invalid_job_identity')
            seen.add(job['id'])
            row_id, model_index = match.group(1), int(match.group(2))
            if row_id not in states or pilot.canonical(job['state']) != pilot.canonical(states[row_id]) or pilot.canonical(job['questions']) != pilot.canonical(study.QUESTIONS) or job['model'] != study.MODELS[model_index] or set(job['questions']) != set(FIELDS):
                raise ValueError('job_mismatch')
            request = {k: job[k] for k in ('state', 'questions', 'model')}
            request_hash = hashlib.sha256(pilot.canonical(request)).hexdigest()
            receipt, _ = read_json(directory / f'{number:04}.receipt.json', 131072)
            if not isinstance(receipt, dict) or receipt.get('id') != job['id'] or receipt.get('model') != job['model'] or receipt.get('request_sha256') != request_hash or receipt.get('status') != 'ok' or receipt.get('http_status') != 200:
                raise ValueError('receipt_mismatch')
            try:
                response = pilot.validate_response(pilot.canonical({'model': receipt['model'], 'answers': receipt['answers'], 'usage': receipt['usage']}), {'request': request})
            except (KeyError, TypeError, pilot.PilotError) as exc:
                raise ValueError('invalid_response') from exc
            if response['usage']['input_tokens'] > pilot.CONTEXT:
                raise ValueError('usage_overrun')
            values = {FIELDS[k]: v['noul'] for k, v in response['answers'].items()}
            answers = {k: 'no' if v <= 0.4 else 'yes' if v >= 0.6 else 'unknown' for k, v in values.items()}
            session, turn = identities[row_id]
            evidence = evidence_id(session, turn)
            state = states[row_id]
            output.append({'schemaVersion': 'jev-tool-page-assessment/1', 'id': pilot.digest({'captureID': capture_id, 'evidenceID': evidence, 'jobID': job['id'], 'requestHash': request_hash}), 'captureID': capture_id, 'sessionID': session, 'turnID': turn, 'evidenceID': evidence, 'model': job['model'], 'rubricHash': pilot.digest(job['questions']), 'stateHash': pilot.digest(state), 'requestHash': request_hash, 'assessedAt': None, 'capturedAt': None, 'source': 'historical_structured_page', 'pagePartial': state['pagePartial'], 'toolFactsTruncated': state['toolFactsTruncated'], 'artifactCountIsPartial': state['artifactCountIsPartial'], 'factCount': len(state['toolFacts']), 'answers': answers, 'noul': values})
    if seen != {row_id + '-m' + str(i) for row_id in states for i in range(2)}:
        raise ValueError('incomplete_job_set')
    return output


def write_output(path, records):
    path = Path(path)
    if not path.is_absolute() or path.name in ('', '.', '..'):
        raise ValueError('absolute_output_required')
    private_dir(path.parent)
    parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        fd = os.open(path.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
        with os.fdopen(fd, 'wb') as f:
            for record in records:
                f.write(pilot.canonical(record) + b'\n')
            f.flush()
            os.fsync(f.fileno())
        os.fsync(parent)
    finally:
        os.close(parent)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--capture-id', required=True, help='Stable opaque 64-character lowercase SHA-256 identifier for this capture')
    args = parser.parse_args()
    try:
        records = convert(args.root, args.capture_id)
        write_output(args.output, records)
        print(f'Exported {len(records)} verified historical assessments.')
        return 0
    except (OSError, ValueError, TypeError, pilot.PilotError) as exc:
        print(f'Export failed: {type(exc).__name__}')
        return 2


if __name__ == '__main__':
    raise SystemExit(main())

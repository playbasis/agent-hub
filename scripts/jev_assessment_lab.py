#!/usr/bin/env python3
"""Offline-first bounded JEV experiment runner. Never imported by the app."""
import argparse
import concurrent.futures
import fcntl
import hashlib
import json
import os
import re
import stat
import threading
import tempfile
import time
from decimal import Decimal
from pathlib import Path

import jev_telemetry_pilot as pilot

LOCK = os.path.join(tempfile.gettempdir(), f'playbasis-jev-lab-{os.getuid()}-rate.lock')
MAX_CALLS = 1024
MAX_USD = Decimal('2.80')


def rate_start(dispatch):
    """Serialize starts across cooperating processes; refuse unsafe lock files."""
    fd = os.open(LOCK, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o600 or st.st_nlink != 1:
            raise pilot.PilotError('unsafe_rate_lock')
        fcntl.flock(fd, fcntl.LOCK_EX)
        raw = os.read(fd, 128)
        try:
            previous = float(raw) if raw else 0.0
        except ValueError as exc:
            raise pilot.PilotError('invalid_rate_lock') from exc
        now = time.monotonic()
        if previous > now + 1 or previous < 0:
            raise pilot.PilotError('invalid_rate_lock')
        time.sleep(max(0.0, previous + 0.251 - now))
        now = time.monotonic()
        os.lseek(fd, 0, os.SEEK_SET)
        os.write(fd, repr(now).encode())
        os.ftruncate(fd, len(repr(now)))
        os.fsync(fd)
        # Hold the lock through transport so scheduling between unlock and
        # opener.open cannot reorder starts across processes.
        return dispatch()
    finally:
        os.close(fd)


def run_jobs(jobs, output, execute=False, max_calls=MAX_CALLS, max_usd=MAX_USD, call=None, key_file=None):
    """Public API: jobs contain id, state, questions, model; output must not exist.

    Gold and other local metadata must not be included in state/questions. One
    reservation is retained for every attempt, including unknown-usage failures.
    """
    if not isinstance(jobs, list) or type(max_calls) is not int or not 0 <= max_calls <= MAX_CALLS or not isinstance(max_usd, Decimal) or not max_usd.is_finite() or not 0 <= max_usd <= MAX_USD or len(jobs) > max_calls or len(jobs) * pilot.RESERVATION > max_usd:
        raise pilot.PilotError('plan_exceeds_hard_budget')
    seen = set()
    for j in jobs:
        if not isinstance(j, dict) or set(j) != {'id', 'state', 'questions', 'model'} or not isinstance(j['id'], str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,80}', j['id']) or j['id'] in seen or j['model'] not in pilot.MODELS or not isinstance(j['state'], dict) or not isinstance(j['questions'], dict) or not j['questions']:
            raise pilot.PilotError('invalid_job')
        seen.add(j['id'])
        for name, q in j['questions'].items():
            if not isinstance(name, str) or not re.fullmatch(r'[a-z][a-z0-9_]{0,63}', name) or not isinstance(q, dict) or set(q) != {'type', 'instructions', 'criteria'} or q['type'] not in ('choice', 'noul') or not isinstance(q['instructions'], str) or not isinstance(q['criteria'], dict) or not q['criteria'] or not all(isinstance(k, str) and isinstance(v, str) for k, v in q['criteria'].items()):
                raise pilot.PilotError('invalid_question')
            if q['type'] == 'noul' and set(q['criteria']) != {'true', 'false'}:
                raise pilot.PilotError('invalid_question')
        if len(pilot.canonical(j)) > 128 * 1024:
            raise pilot.PilotError('job_too_large')
    run = pilot.PrivateRun(output)
    try:
        run.write('plan.json', {'schema': 'jev-assessment-lab/v1', 'planned_calls': len(jobs), 'reserved_usd': str(len(jobs) * pilot.RESERVATION), 'model_contract_date': '2026-11-08', 'no_retries': True, 'concurrency': 3, 'starts_per_second': 4})
        for n, j in enumerate(jobs, 1):
            run.write(f'{n:04}.request.json', {k: j[k] for k in ('state', 'questions', 'model')})
        if not execute:
            summary = {'mode': 'offline-preflight', 'planned_calls': len(jobs), 'key_read': False, 'network_used': False}
        else:
            key = pilot.load_key(key_file)
            stop = threading.Event()
            def one(item):
                n, j = item
                if stop.is_set():
                    return None
                request = {k: j[k] for k in ('state', 'questions', 'model')}
                payload = pilot.canonical(request)
                receipt = {'id': j['id'], 'model': j['model'], 'request_sha256': hashlib.sha256(payload).hexdigest(), 'reserved_usd': str(pilot.RESERVATION), 'status': 'error'}
                try:
                    if key.encode() in payload:
                        raise pilot.PilotError('key_reflection')
                    run.write(f'{n:04}.reservation.json', {'reserved_usd': str(pilot.RESERVATION), 'input_tokens': 64000})
                    start = time.monotonic()
                    status, raw = rate_start(lambda: (call or pilot.transport)(payload, key))
                    receipt['latency_seconds'] = round(time.monotonic() - start, 6)
                    receipt['http_status'] = status
                    if key.encode() in raw:
                        raise pilot.PilotError('key_reflection')
                    if status in (401, 403):
                        raise pilot.PilotError('authentication_error')
                    if status != 200:
                        raise pilot.PilotError('http_error')
                    data = pilot.validate_response(raw, {'request': request})
                    if key in json.dumps(data, ensure_ascii=False):
                        raise pilot.PilotError('key_reflection')
                    if data['usage']['input_tokens'] > 64000:
                        raise pilot.PilotError('usage_overrun')
                    receipt.update(status='ok', answers=data['answers'], usage=data['usage'], estimated_usd=str(pilot.PRICE * data['usage']['input_tokens']))
                except Exception as exc:
                    receipt['error'] = str(exc) if isinstance(exc, pilot.PilotError) else type(exc).__name__
                    if receipt['error'] in ('key_reflection', 'authentication_error', 'usage_overrun', 'unsafe_rate_lock', 'invalid_rate_lock'):
                        stop.set()
                run.write(f'{n:04}.receipt.json', receipt)
                return receipt
            with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
                records = [r for r in pool.map(one, enumerate(jobs, 1)) if r]
            summary = {'mode': 'execute', 'planned_calls': len(jobs), 'attempted_calls': len(records), 'successful_calls': sum(r['status'] == 'ok' for r in records), 'unknown_usage_attempts': sum('usage' not in r for r in records), 'reserved_usd': str(len(records) * pilot.RESERVATION), 'estimated_known_usd': str(sum((Decimal(r.get('estimated_usd', '0')) for r in records), Decimal(0))), 'failure_counts': {e: sum(r.get('error') == e for r in records) for e in sorted({r['error'] for r in records if 'error' in r})}, 'aborted': stop.is_set()}
        run.write('summary.json', summary)
        return summary
    finally:
        run.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--jobs', required=True, help='JSON array of id/state/questions/model jobs')
    parser.add_argument('--output', required=True)
    parser.add_argument('--execute', action='store_true')
    parser.add_argument('--key-file', help='Explicit owner-only 0600 key file; otherwise use TYPESAFE_API_KEY from the environment')
    parser.add_argument('--max-calls', type=int, default=MAX_CALLS)
    parser.add_argument('--max-reserved-usd', type=Decimal, default=MAX_USD)
    args = parser.parse_args()
    try:
        jobs = pilot.strict_json(Path(args.jobs).read_bytes())
        if not isinstance(jobs, list):
            raise pilot.PilotError('invalid_jobs')
        summary = run_jobs(jobs, args.output, args.execute, args.max_calls, args.max_reserved_usd, key_file=args.key_file)
        print(json.dumps(summary, sort_keys=True))
        return 2 if summary.get('failure_counts') or summary.get('aborted') else 0
    except (OSError, ValueError, pilot.PilotError) as exc:
        print(json.dumps({'error': str(exc) if isinstance(exc, pilot.PilotError) else type(exc).__name__}))
        return 2


if __name__ == '__main__':
    raise SystemExit(main())

"""Offline tests: no real keys or network."""
import json
import os
import sys
import tempfile
import unittest
from decimal import Decimal
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import jev_assessment_lab as lab
import jev_telemetry_pilot as pilot
import jev_taxonomy_benchmark as benchmark


class LabTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.job = {'id': 'case-1', 'model': pilot.MODELS[0], 'state': {'task': 'test'}, 'questions': pilot.questions('literal')}

    def test_offline_and_private(self):
        with mock.patch.object(pilot, 'load_key', side_effect=AssertionError), mock.patch.object(pilot, 'transport', side_effect=AssertionError):
            summary = lab.run_jobs([self.job], self.root / 'run')
        self.assertFalse(summary['network_used'])
        self.assertEqual((self.root / 'run').stat().st_mode & 0o777, 0o700)
        self.assertTrue(all(p.stat().st_mode & 0o777 == 0o600 for p in (self.root / 'run').iterdir()))
        with self.assertRaises(FileExistsError):
            lab.run_jobs([self.job], self.root / 'run')

    def test_budget_and_schema(self):
        for jobs, calls, usd in [([self.job], 0, Decimal('1')), ([self.job], 1, Decimal('0')), ([dict(self.job, model='latest')], 1, Decimal('1')), ([self.job, self.job], 2, Decimal('1'))]:
            with self.assertRaises(pilot.PilotError):
                lab.run_jobs(jobs, self.root / 'run', max_calls=calls, max_usd=usd)

    def test_failure_is_unknown_and_no_retry(self):
        fake = 'offline-fake-key-not-secret'
        call = mock.Mock(side_effect=TimeoutError(fake))
        with mock.patch.object(pilot, 'load_key', return_value=fake), mock.patch.object(lab, 'LOCK', str(self.root / 'lock')):
            summary = lab.run_jobs([self.job], self.root / 'run', True, call=call)
        self.assertEqual(call.call_count, 1)
        self.assertEqual(summary['unknown_usage_attempts'], 1)
        self.assertEqual(summary['reserved_usd'], str(pilot.RESERVATION))
        self.assertNotIn(fake, (self.root / 'run/0001.receipt.json').read_text())

    def test_explicit_key_path_is_forwarded_without_inspecting_it_in_dry_run(self):
        with mock.patch.object(pilot, 'load_key', return_value='offline-fake-key-not-secret') as loader, mock.patch.object(lab, 'LOCK', str(self.root / 'lock')):
            lab.run_jobs([self.job], self.root / 'run', True, call=lambda *_: (200, b'{}'), key_file='/explicit/private/key')
        loader.assert_called_once_with('/explicit/private/key')

    def test_unsafe_lock_rejected(self):
        path = self.root / 'lock'
        path.write_text('')
        path.chmod(0o644)
        with mock.patch.object(lab, 'LOCK', str(path)), self.assertRaises(pilot.PilotError):
            lab.rate_start(lambda: None)

    def test_invalid_response_rejected(self):
        with mock.patch.object(pilot, 'load_key', return_value='offline-fake-key-not-secret'), mock.patch.object(lab, 'LOCK', str(self.root / 'lock')):
            summary = lab.run_jobs([self.job], self.root / 'run', True, call=lambda *_: (200, b'{}'))
        self.assertEqual(summary['successful_calls'], 0)
        self.assertEqual(summary['unknown_usage_attempts'], 1)

    def test_frozen_benchmark_is_split_and_never_sends_gold(self):
        benchmark.prepare(self.root / 'benchmark')
        root = self.root / 'benchmark'
        gold = json.loads((root / 'frozen-gold.json').read_text())['cases']
        canary = json.loads((root / 'canary-jobs.json').read_text())
        main = json.loads((root / 'main-jobs.json').read_text())
        self.assertEqual((len(gold), len(canary), len(main)), (120, 8, 952))
        self.assertEqual(sum(c['split'] == 'heldout' for c in gold), 36)
        self.assertFalse(set(j['id'] for j in canary) & set(j['id'] for j in main))
        self.assertTrue(all(set(j) == {'id', 'state', 'questions', 'model'} for j in canary + main))
        self.assertTrue(all('gold' not in j['state'] for j in canary + main))


if __name__ == '__main__':
    unittest.main()

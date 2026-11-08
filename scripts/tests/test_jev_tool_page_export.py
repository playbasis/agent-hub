"""Offline converter tests with fabricated states, identities and receipts."""
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import jev_telemetry_pilot as pilot
import jev_tool_evidence_lab as study
import jev_tool_page_export as export

CAPTURE = 'a' * 64

class ExportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for d in ('observations-v2', 'canary-live', 'main-live'):
            (self.root / d).mkdir(mode=0o700)
        state = {'provider': 'claude', 'turnStatus': 'completed', 'goalStatus': 'unknown', 'models': [], 'turnDurationSeconds': None, 'artifactKindCounts': {'file': 0, 'other': 0}, 'artifactCountIsPartial': True, 'toolFacts': [{'kind': 'tool_call', 'status': 'failed', 'exitCode': 1, 'durationSeconds': None}], 'pagePartial': True, 'toolFactsTruncated': False}
        rows = [{'id': 'tool-000', 'state': state}, {'id': 'tool-001', 'state': dict(state, provider='codex')}]
        self.put('observations-v2/states.json', rows)
        self.put('observations-v2/local-mapping.json', [{'id': 'tool-000', 'sessionID': 'é', 'turnID': 'turn'}, {'id': 'tool-001', 'sessionID': 's', 'turnID': 't'}])
        jobs = [{'id': f"{r['id']}-m{i}", 'state': r['state'], 'questions': study.QUESTIONS, 'model': model} for r in rows for i, model in enumerate(study.MODELS)]
        self.put('tool-canary-jobs.json', jobs[:2])
        self.put('tool-main-jobs.json', jobs[2:])
        for batch, directory in ((jobs[:2], 'canary-live'), (jobs[2:], 'main-live')):
            for n, job in enumerate(batch, 1):
                request = {k: job[k] for k in ('state', 'questions', 'model')}
                answers = {k: {'type': 'noul', 'noul': (0.4 if i == 0 else 0.6 if i == 1 else 0.5)} for i, k in enumerate(study.QUESTIONS)}
                receipt = {'id': job['id'], 'model': job['model'], 'request_sha256': pilot.digest(request), 'status': 'ok', 'http_status': 200, 'answers': answers, 'usage': {'input_tokens': 100, 'output_tokens': 3}}
                self.put(f'{directory}/{n:04}.receipt.json', receipt)

    def put(self, name, value):
        path = self.root / name
        path.write_bytes(pilot.canonical(value))
        path.chmod(0o600)

    def get(self, name):
        return json.loads((self.root / name).read_bytes())

    def test_export_shape_thresholds_and_private_noclobber(self):
        records = export.convert(self.root, CAPTURE)
        self.assertEqual(len(records), 4)
        self.assertEqual(records[0]['evidenceID'], export.evidence_id('é', 'turn'))
        self.assertEqual(records[0]['answers']['listedNonzeroExit'], 'no')
        self.assertEqual(records[0]['answers']['listedCompletedTool'], 'yes')
        self.assertEqual(records[0]['answers']['artifactRecorded'], 'unknown')
        self.assertIsNone(records[0]['capturedAt'])
        self.assertIsNone(records[0]['assessedAt'])
        self.assertEqual(records[0]['captureID'], CAPTURE)
        self.assertEqual(records[0]['captureID'], records[1]['captureID'])
        self.assertNotEqual(records[0]['id'], records[1]['id'])
        self.assertEqual(records[0]['source'], 'historical_structured_page')
        self.assertTrue(records[0]['pagePartial'])
        self.assertEqual(records[0]['factCount'], 1)
        out = self.root / 'out.jsonl'
        export.write_output(out, records)
        self.assertEqual(out.stat().st_mode & 0o777, 0o600)
        self.assertEqual(len(out.read_text().splitlines()), 4)
        with self.assertRaises(FileExistsError):
            export.write_output(out, records)

    def test_evidence_identity_uses_utf8_byte_lengths(self):
        import hashlib
        self.assertEqual(export.evidence_id('é', 'turn'), 'evidence:' + hashlib.sha256('2:é4:turn'.encode()).hexdigest())

    def test_rejects_state_expansion_mapping_and_duplicate_jobs(self):
        for name, mutate in [
            ('observations-v2/states.json', lambda d: d[0]['state'].update(rawCommand='secret')),
            ('observations-v2/local-mapping.json', lambda d: d[1].update(id=d[0]['id'])),
            ('tool-main-jobs.json', lambda d: d[1].update(id=d[0]['id'])),
            ('tool-main-jobs.json', lambda d: d[0]['questions']['artifact_recorded'].update(instructions='changed')),
            ('tool-main-jobs.json', lambda d: d[0]['state']['toolFacts'][0].update(exitCode=True)),
        ]:
            with self.subTest(name=name):
                data = self.get(name)
                old = pilot.canonical(data)
                mutate(data)
                self.put(name, data)
                with self.assertRaises((ValueError, pilot.PilotError)):
                    export.convert(self.root, CAPTURE)
                (self.root / name).write_bytes(old)

    def test_rejects_tampered_response_and_missing_or_extra_receipt(self):
        name = 'main-live/0001.receipt.json'
        for mutate in (lambda d: d.update(request_sha256='0' * 64), lambda d: d.update(model='jev-latest'), lambda d: d['answers']['artifact_recorded'].update(noul=1.1), lambda d: d['answers'].pop('artifact_recorded')):
            data = self.get(name)
            old = pilot.canonical(data)
            mutate(data)
            self.put(name, data)
            with self.assertRaises(ValueError):
                export.convert(self.root, CAPTURE)
            (self.root / name).write_bytes(old)
        path = self.root / name
        path.rename(self.root / 'main-live/9999.receipt.json')
        with self.assertRaises(ValueError):
            export.convert(self.root, CAPTURE)

    def test_rejects_unprivate_input_and_duplicate_json(self):
        path = self.root / 'tool-canary-jobs.json'
        path.chmod(0o644)
        with self.assertRaises(ValueError):
            export.convert(self.root, CAPTURE)
        path.chmod(0o600)
        path.write_bytes(b'{"x":1,"x":2}')
        with self.assertRaises(pilot.PilotError):
            export.convert(self.root, CAPTURE)

    def test_identity_validation_and_stable_capture_ids(self):
        first = export.convert(self.root, CAPTURE)
        self.assertEqual(first, export.convert(self.root, CAPTURE))
        second = export.convert(self.root, 'b' * 64)
        self.assertTrue(set(r['id'] for r in first).isdisjoint(r['id'] for r in second))
        mapping = self.get('observations-v2/local-mapping.json')
        mapping[0]['sessionID'] = 'changed-session'
        self.put('observations-v2/local-mapping.json', mapping)
        changed = export.convert(self.root, CAPTURE)
        self.assertNotEqual(first[0]['id'], changed[0]['id'])
        mapping[0]['sessionID'] = 'é'
        self.put('observations-v2/local-mapping.json', mapping)
        for bad in ('x' * 64, 'A' * 64, '', 'a' * 63):
            with self.assertRaises(ValueError):
                export.convert(self.root, bad)
        name = 'observations-v2/local-mapping.json'
        original = self.get(name)
        for value in ('x' * 1025, 'ok\u0085bad', 'ok\u200bbad'):
            data = self.get(name)
            data[0]['sessionID'] = value
            self.put(name, data)
            with self.assertRaises(ValueError):
                export.convert(self.root, CAPTURE)
            self.put(name, original)
        data = self.get(name)
        data[0]['sessionID'] = 'x' * 1024
        self.put(name, data)
        self.assertEqual(len(export.convert(self.root, CAPTURE)), 4)


if __name__ == '__main__':
    unittest.main()

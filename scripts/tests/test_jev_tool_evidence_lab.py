import copy
import hashlib
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import jev_tool_evidence_lab as lab
import jev_telemetry_pilot as pilot


def state(provider):
    return {"provider": provider, "turnStatus": "unknown", "goalStatus": "unknown", "models": [], "turnDurationSeconds": None,
            "artifactKindCounts": {"file": 0, "other": 0}, "artifactCountIsPartial": True, "pagePartial": True, "toolFactsTruncated": False,
            "toolFacts": [{"kind": "tool_call", "status": "failed", "exitCode": 1, "durationSeconds": None}]}


def private(path, value):
    path.write_text(json.dumps(value)); path.chmod(0o600)


class ToolEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.root = Path(self.tmp.name); lab.ROOT = self.root
        self.rows = [{"id": "tool-000", "state": state("claude")}, {"id": "tool-001", "state": state("codex")}]

    def tearDown(self):
        self.tmp.cleanup()

    def test_strict_state_rejects_raw_unsafe_and_missing_coverage(self):
        lab.validate(self.rows)
        for change in (lambda s: s.update(rawCommand="sensitive"), lambda s: s.pop("pagePartial"),
                       lambda s: s["toolFacts"][0].update(exitCode=True), lambda s: s.update(models=["gpt-unsafe path"]),
                       lambda s: s.update(artifactCountIsPartial=False), lambda s: s.update(turnDurationSeconds=float("nan"))):
            rows = copy.deepcopy(self.rows); change(rows[0]["state"])
            with self.assertRaises(ValueError): lab.validate(rows)

    def test_private_file_refuses_symlink_and_public_permissions(self):
        source = self.root / "source"; private(source, {})
        link = self.root / "link"; link.symlink_to(source)
        with self.assertRaises(OSError): lab.read_private(link, 100)
        source.chmod(0o644)
        with self.assertRaises(ValueError): lab.read_private(source, 100)

    def test_prepare_offline_exclusive_and_ground_truth(self):
        private(self.root / "states.json", self.rows)
        with mock.patch("socket.socket", side_effect=AssertionError("network")), mock.patch.object(pilot, "load_key", side_effect=AssertionError("key")):
            lab.prepare()
        jobs = json.loads((self.root / "tool-canary-jobs.json").read_text())
        self.assertEqual(len(jobs), 2); self.assertEqual(len(json.loads((self.root / "tool-main-jobs.json").read_text())), 2)
        self.assertTrue(lab.expected(self.rows[0]["state"])["listed_nonzero_exit"])
        self.assertFalse(lab.expected(self.rows[0]["state"])["goal_status_recorded_completed"])
        self.assertEqual((self.root / "tool-gold.json").stat().st_mode & 0o777, 0o600)
        with self.assertRaises(FileExistsError): lab.prepare()

    def test_analysis_validates_response_and_counts_missing_extra_invalid(self):
        private(self.root / "states.json", self.rows); lab.prepare()
        for name in ("canary-live", "main-live"): (self.root / name).mkdir(mode=0o700)
        jobs = json.loads((self.root / "tool-canary-jobs.json").read_text()); job = jobs[0]
        answers = {key: {"type": "noul", "noul": 1.0 if value else 0.0} for key, value in lab.expected(job["state"]).items()}
        request = {key: job[key] for key in ("state", "questions", "model")}
        receipt = {"id": job["id"], "model": job["model"], "status": "ok", "request_sha256": hashlib.sha256(pilot.canonical(request)).hexdigest(), "answers": answers, "usage": {"input_tokens": 1, "output_tokens": 0}}
        private(self.root / "canary-live/0001.receipt.json", receipt)
        broken = copy.deepcopy(receipt); broken["id"] = jobs[1]["id"]; broken["model"] = jobs[1]["model"]
        private(self.root / "canary-live/0002.receipt.json", broken)
        private(self.root / "main-live/9999.receipt.json", {})
        with mock.patch("socket.socket", side_effect=AssertionError("network")), mock.patch.object(pilot, "load_key", side_effect=AssertionError("key")):
            lab.analyze()
        result = json.loads((self.root / "tool-analysis.json").read_text())
        self.assertEqual((result["planned"], result["valid"], result["missing"], result["extra"], result["invalid"]), (4, 1, 2, 1, 1))
        self.assertEqual(result["confusion"]["listed_nonzero_exit"], {"true -> true": 1})


if __name__ == "__main__": unittest.main()

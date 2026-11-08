"""Offline, mocked-transport tests. No real keys, API calls, or app interaction."""
import importlib.util
import json
import os
import stat
import tempfile
import time
import unittest
from decimal import Decimal
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "jev_telemetry_pilot.py"
SPEC = importlib.util.spec_from_file_location("jev_telemetry_pilot", SCRIPT)
pilot = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pilot)
FAKE_KEY = "offline-test-key-not-a-real-secret"


def metadata():
    return {"rows": [{"id": f"metadata-{n:03d}", "state": {
        "provider": "codex", "status": "completed", "durationSeconds": None,
        "categoryCounts": {"Implementation": 1}, "toolCount": 1,
        "modelStepCount": 1, "models": ["gpt-6.1-sol"], "historyPartial": True,
    }} for n in range(1, 49)]}


def response(job, overrides=None, usage=None):
    answers = {}
    expected = job["case"].get("expected", {})
    for name, question in job["request"]["questions"].items():
        if question["type"] == "choice":
            label = expected.get(name, next(iter(question["criteria"])))
            answers[name] = {"type": "choice", "choice": label,
                             "probabilities": {k: float(k == label) for k in question["criteria"]}, "confidence": 0.01}
        else:
            answers[name] = {"type": "noul", "noul": float(expected.get(name, False))}
    result = {"model": job["request"]["model"], "answers": answers,
              "usage": usage or {"input_tokens": 100, "output_tokens": 10}}
    if overrides:
        result.update(overrides)
    return result


class PilotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="jev-offline-test-")
        self.root = Path(self.temp.name)
        self.jobs = pilot.make_jobs([])

    def tearDown(self):
        self.temp.cleanup()

    def file(self, data, name="metadata.json"):
        path = self.root / name
        path.write_bytes(pilot.canonical(data))
        return path

    def execute(self, jobs, call, **kwargs):
        run = pilot.PrivateRun(self.root / "run")
        try:
            return pilot.execute(jobs, run, FAKE_KEY, call=call, **kwargs)
        finally:
            run.close()

    def test_exact_192_call_plan_and_gold_never_in_request(self):
        cases, _ = pilot.load_metadata(self.file(metadata()))
        jobs = pilot.make_jobs(cases)
        self.assertEqual(len(jobs), 192)
        self.assertEqual(len(self.jobs), 96)
        self.assertEqual(Decimal(len(jobs)) * pilot.RESERVATION, Decimal("0.516096"))
        self.assertEqual(set(j["request"]["model"] for j in jobs), set(pilot.MODELS))
        for job in jobs:
            self.assertEqual(set(job["request"]), {"model", "state", "questions"})
            self.assertNotIn("expected", job["request"]["state"])
            self.assertEqual(len(job["request"]["questions"]), 8)
            self.assertEqual(pilot.digest(job["request"]), job["hashes"]["request"])
        self.jobs[0]["case"]["expected"]["private_gold_sentinel"] = "DO_NOT_SEND"
        self.assertNotIn(b"DO_NOT_SEND", pilot.canonical(self.jobs[0]["request"]))

    def test_fixture_edge_cases_and_gold_are_explicit(self):
        cases = {case["id"]: case for case in pilot.gold_cases()}
        self.assertEqual(len(cases), 24)
        self.assertEqual(cases["expected-exit-one"]["expected"]["outcome_support"], "verified_check_success")
        self.assertEqual(cases["unexpected-exit-one"]["expected"]["outcome_support"], "observed_error")
        for name in ("status-only", "quoted-success", "negated-verification", "future-claim", "no-evidence-of-failure", "empty-suite", "wrong-target"):
            self.assertEqual(cases[name]["expected"]["outcome_support"], "insufficient", name)
        self.assertTrue(cases["corrected-recovery"]["expected"]["correction"])
        self.assertFalse(cases["retry-no-correction"]["expected"]["correction"])
        self.assertEqual(cases["contradiction"]["expected"]["outcome_support"], "conflicting")

    def test_focused_nouls_are_explicit_observation_specific_and_closed_world(self):
        questions = pilot.questions("literal", "focused")
        for name, question in questions.items():
            if question["type"] == "noul":
                self.assertIn("EXPLICIT", question["instructions"], name)
                self.assertIn("observations", question["instructions"], name)
                self.assertIn("absent", question["criteria"]["false"], name)
                self.assertNotIn(pilot.RULES, question["instructions"], name)
        self.assertIn("state.task", questions["work_kind"]["instructions"])
        self.assertIn("nonzero state.categoryCounts", questions["work_kind_fit"]["instructions"])
        self.assertIn("Aggregate-only", questions["evidence_level"]["instructions"])
        self.assertIn("expected exit 1", questions["outcome_support"]["instructions"])
        self.assertIn("No Assistant success claim means No", questions["claim_needs_review"]["instructions"])

    def test_legacy_and_focused_are_versioned_distinct_and_gold_free(self):
        legacy, focused = pilot.make_jobs([], "legacy"), pilot.make_jobs([], "focused")
        self.assertEqual(len(legacy), len(focused))
        for old, new in zip(legacy, focused):
            self.assertEqual(old["case"], new["case"])
            self.assertEqual((old["rubric_set"], old["rubric_version"]), ("legacy", 1))
            self.assertEqual((new["rubric_set"], new["rubric_version"]), ("focused", 2))
            self.assertNotEqual(old["request"], new["request"])
            self.assertNotEqual(old["hashes"]["rubric"], new["hashes"]["rubric"])
            for job in (old, new):
                self.assertEqual(set(job["request"]), {"model", "state", "questions"})
                self.assertNotIn("expected", job["request"]["state"])
                self.assertEqual(job["hashes"]["rubric"], pilot.digest({"set": job["rubric_set"], "version": job["rubric_version"], "questions": job["request"]["questions"]}))
        self.assertIn(pilot.RULES, legacy[0]["request"]["questions"]["retry"]["instructions"])
        self.assertEqual(pilot.make_jobs([])[0]["rubric_set"], "focused")
        with self.assertRaises(pilot.PilotError):
            pilot.questions("literal", "not-a-rubric")

    def test_offline_default_does_not_load_key_or_use_network(self):
        source, output = self.file(metadata()), self.root / "preflight"
        with mock.patch.object(pilot, "load_key", side_effect=AssertionError("key read")), mock.patch.object(pilot.urllib.request, "build_opener", side_effect=AssertionError("network")):
            self.assertEqual(pilot.main(["--metadata", str(source), "--output", str(output), "--key-file", "/does/not/exist"]), 0)
        summary = json.loads((output / "summary.json").read_bytes())
        self.assertFalse(summary["key_read"])
        self.assertFalse(summary["network_used"])
        self.assertEqual(len(list(output.glob("*.request.json"))), 192)
        plan = json.loads((output / "plan.json").read_bytes())
        self.assertEqual((plan["rubric_set"], plan["rubric_version"]), ("focused", 2))
        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o700)
        self.assertTrue(all(stat.S_IMODE(p.stat().st_mode) == 0o600 for p in output.iterdir()))

    def test_no_output_reuse_or_artifact_overwrite(self):
        run = pilot.PrivateRun(self.root / "run")
        try:
            run.write("receipt.json", {"old": True})
            with self.assertRaises(FileExistsError):
                run.write("receipt.json", {"new": True})
            with self.assertRaises(FileExistsError):
                pilot.PrivateRun(self.root / "run")
            with self.assertRaises(pilot.PilotError):
                run.write("../escape", {})
            self.assertEqual(json.loads((self.root / "run/receipt.json").read_bytes()), {"old": True})
        finally:
            run.close()

    def test_metadata_field_and_value_allowlist(self):
        for key, value in (("title", "private"), ("rawCommands", ["private"]), ("nativeID", "private"), ("path", "/private"), ("prompt", "private")):
            data = metadata()
            data["rows"][0]["state"][key] = value
            with self.assertRaises(pilot.PilotError):
                pilot.load_metadata(self.file(data))
        for key, value in (("provider", []), ("status", {}), ("models", ["/private/file"]), ("toolCount", True), ("categoryCounts", {"secret command": 1}), ("durationSeconds", -1)):
            data = metadata()
            data["rows"][0]["state"][key] = value
            with self.assertRaises(pilot.PilotError):
                pilot.load_metadata(self.file(data))
        for change in (lambda d: d["rows"].pop(), lambda d: d["rows"][1].update(id=d["rows"][0]["id"]), lambda d: d["rows"][0].update(id="native-secret-id")):
            data = metadata()
            change(data)
            with self.assertRaises(pilot.PilotError):
                pilot.load_metadata(self.file(data))

    def test_key_loader_supports_quoted_single_assignment(self):
        keyfile = self.root / "key.env"
        for text in (f"TYPESAFE_API_KEY={FAKE_KEY}\n", f"# comment\nTYPESAFE_API_KEY='{FAKE_KEY}'\n", f'export TYPESAFE_API_KEY="{FAKE_KEY}"\n', f'OTHER_KEY=unrelated\nTYPESAFE_API_KEY="{FAKE_KEY}"\nYET_ANOTHER=ignored\n'):
            keyfile.write_text(text)
            keyfile.chmod(0o600)
            self.assertEqual(pilot.load_key(keyfile), FAKE_KEY)
        with mock.patch.dict(os.environ, {"TYPESAFE_API_KEY": FAKE_KEY}, clear=True):
            self.assertEqual(pilot.load_key(), FAKE_KEY)

    def test_key_permissions_symlink_hardlink_and_fifo_rejected(self):
        path = self.root / "key.env"
        path.write_text(f"TYPESAFE_API_KEY={FAKE_KEY}\n")
        path.chmod(0o644)
        with self.assertRaises(pilot.PilotError):
            pilot.load_key(path)
        path.chmod(0o600)
        link = self.root / "link.env"
        link.symlink_to(path)
        with self.assertRaises(pilot.PilotError):
            pilot.load_key(link)
        hard = self.root / "hard.env"
        os.link(path, hard)
        with self.assertRaises(pilot.PilotError):
            pilot.load_key(path)
        fifo = self.root / "fifo.env"
        os.mkfifo(fifo, 0o600)
        with self.assertRaises(pilot.PilotError):
            pilot.load_key(fifo)

    def test_key_owner_fstat_and_size_validation(self):
        path = self.root / "key.env"
        path.write_text(f"TYPESAFE_API_KEY={FAKE_KEY}\n")
        path.chmod(0o600)
        with mock.patch.object(pilot.os, "getuid", return_value=os.getuid() + 1):
            with self.assertRaises(pilot.PilotError):
                pilot.load_key(path)
        wrong = list(path.stat())
        wrong[1] += 1
        with mock.patch.object(pilot.os, "fstat", return_value=os.stat_result(wrong)):
            with self.assertRaises(pilot.PilotError):
                pilot.load_key(path)
        path.write_text("x" * (16 * 1024 + 1))
        with self.assertRaises(pilot.PilotError):
            pilot.load_key(path)

    def test_key_file_rejects_duplicate_typesafe_assignments_or_invalid_syntax(self):
        path = self.root / "key.env"
        for text in (f"TYPESAFE_API_KEY={FAKE_KEY}\nexport TYPESAFE_API_KEY={FAKE_KEY}", "TYPESAFE_API_KEY=$(command)", "API_KEY=wrong", "TYPESAFE_API_KEY='short'", ""):
            path.write_text(text)
            path.chmod(0o600)
            with self.assertRaises(pilot.PilotError):
                pilot.load_key(path)

    def test_duplicate_json_and_nonfinite_rejected(self):
        for raw in (b'{"a":1,"a":2}', b'{"nested":{"a":1,"a":2}}', b'{"a":NaN}', b'{"a":Infinity}', b"not-json"):
            with self.assertRaises(pilot.PilotError):
                pilot.strict_json(raw)

    def test_response_schema_model_question_label_and_distribution(self):
        job = self.jobs[0]
        pilot.validate_response(pilot.canonical(response(job)), job)
        mutations = [
            lambda d: d.update(model="jev-latest"),
            lambda d: d["answers"].pop("retry"),
            lambda d: d["answers"].update(extra={"type": "noul", "noul": 0}),
            lambda d: d["answers"]["work_kind"].update(choice="not-a-label"),
            lambda d: d["answers"]["work_kind"].update(choice={}),
            lambda d: d["answers"]["work_kind"].update(confidence=True),
            lambda d: d["answers"]["work_kind"]["probabilities"].update(unknown=0.25),
            lambda d: d["answers"]["work_kind"]["probabilities"].pop("unknown"),
            lambda d: d["answers"]["retry"].update(noul=1.01),
            lambda d: d["answers"]["retry"].update(type="choice"),
            lambda d: d["usage"].update(input_tokens=True),
            lambda d: d["usage"].update(input_tokens=0),
            lambda d: d["usage"].update(output_tokens=-1),
        ]
        for mutation in mutations:
            data = response(job)
            mutation(data)
            with self.assertRaises(pilot.PilotError):
                pilot.validate_response(pilot.canonical(data), job)

    def test_hard_caps_reject_before_any_dispatch(self):
        for kwargs in ({"max_calls": 201}, {"max_calls": 0}, {"max_usd": Decimal("1.01")}, {"max_usd": Decimal("0")}):
            run = pilot.PrivateRun(self.root / ("cap-" + str(len(list(self.root.iterdir())))))
            call = mock.Mock()
            try:
                with self.assertRaises(pilot.PilotError):
                    pilot.execute(self.jobs[:1], run, FAKE_KEY, call=call, **kwargs)
                call.assert_not_called()
                self.assertEqual(list(run.path.iterdir()), [])
            finally:
                run.close()

    def test_success_receipts_preserve_probabilities_usage_latency_and_confidence(self):
        job = self.jobs[0]
        summary = self.execute([job], lambda payload, key: (200, pilot.canonical(response(job))))
        self.assertEqual(summary["successful_calls"], 1)
        self.assertEqual(summary["synthetic_accuracy"][f'{job["request"]["model"]}/literal']["accuracy"], 1)
        receipt = json.loads((self.root / "run/0001.receipt.json").read_bytes())
        self.assertEqual(receipt["usage"]["input_tokens"], 100)
        self.assertEqual(receipt["answers"]["work_kind"]["confidence"], 0.01)
        self.assertEqual(receipt["hashes"], job["hashes"])
        self.assertGreaterEqual(receipt["latency_seconds"], 0)
        self.assertEqual(summary["reserved_usd"], str(pilot.RESERVATION))
        self.assertIn("estimated_known_usd", summary)
        self.assertNotIn("actual_known_usd", summary)
        self.assertEqual(receipt["reported_work_kind"], "unknown")
        self.assertTrue(receipt["work_kind_abstained"])

    def test_nullable_counts_grok_and_lifecycle_aliases(self):
        for status in ("complete", "finished", "in_progress", "canceled", "cancelled"):
            data = metadata()
            state = data["rows"][0]["state"]
            state.update(provider="grok", status=status, models=["grok-code-fast-1"], toolCount=None, modelStepCount=None)
            cases, _ = pilot.load_metadata(self.file(data))
            self.assertIsNone(cases[0]["state"]["toolCount"])
            self.assertIsNone(cases[0]["state"]["modelStepCount"])

    def test_nonmaximal_choice_rejected_but_probability_ties_allowed(self):
        job, data = self.jobs[0], response(self.jobs[0])
        answer = data["answers"]["work_kind"]
        answer["probabilities"] = {key: 0.0 for key in answer["probabilities"]}
        answer["probabilities"].update(unknown=0.49, implementation=0.51)
        with self.assertRaises(pilot.PilotError):
            pilot.validate_response(pilot.canonical(data), job)
        answer["probabilities"].update(unknown=0.5, implementation=0.5)
        pilot.validate_response(pilot.canonical(data), job)

    def test_input_only_usage_overrun_and_estimated_cost(self):
        job = self.jobs[0]
        body = pilot.canonical(response(job, usage={"input_tokens": 64000, "output_tokens": 100000}))
        summary = self.execute([job], lambda payload, key: (200, body))
        self.assertFalse(summary["aborted"])
        self.assertEqual(summary["successful_calls"], 1)
        self.assertEqual(Decimal(summary["estimated_known_usd"]), pilot.RESERVATION)
        self.assertEqual(summary["price_source"], "https://docs.typesafe.ai/models")

    def test_work_kind_fit_abstains_without_discarding_raw_choice(self):
        job = self.jobs[4]  # Clear verification subject, with independently gated fit.
        data = response(job)
        data["answers"]["work_kind_fit"]["noul"] = 0.5
        summary = self.execute([job], lambda payload, key: (200, pilot.canonical(data)))
        receipt = json.loads((self.root / "run/0001.receipt.json").read_bytes())
        self.assertEqual(receipt["answers"]["work_kind"]["choice"], "verification")
        self.assertEqual(receipt["reported_work_kind"], "unknown")
        self.assertTrue(any(m["question"] == "work_kind" and m["observed"] == "unknown" for m in summary["synthetic_mismatches"]))

    def test_reflected_key_aborts_and_is_not_persisted(self):
        for escaped in (False, True):
            with self.subTest(escaped=escaped):
                path = self.root / f"reflect-{escaped}"
                run = pilot.PrivateRun(path)
                body = json.dumps({"error": FAKE_KEY}).encode()
                if escaped:
                    body = body.replace(FAKE_KEY.encode(), "".join(f"\\u{ord(c):04x}" for c in FAKE_KEY).encode())
                call = mock.Mock(return_value=(200, body))
                try:
                    summary = pilot.execute(self.jobs[:8], run, FAKE_KEY, call=call)
                finally:
                    run.close()
                self.assertTrue(summary["aborted"])
                self.assertEqual(call.call_count, 1)
                self.assertEqual(summary["failure_counts"], {"key_reflection": 1})
                self.assertEqual(list(path.glob("*.response.json")), [])
                self.assertTrue(all(FAKE_KEY.encode() not in p.read_bytes() for p in path.iterdir()))

    def test_auth_and_usage_overrun_abort_new_dispatch(self):
        for status, body, reason in ((401, b"not-json", "authentication_error"), (403, b'{}', "authentication_error"),
                                     (200, pilot.canonical(response(self.jobs[0], usage={"input_tokens": 64001, "output_tokens": 0})), "usage_overrun")):
            run = pilot.PrivateRun(self.root / f"abort-{status}-{reason}")
            call = mock.Mock(return_value=(status, body))
            try:
                summary = pilot.execute(self.jobs[:8], run, FAKE_KEY, call=call)
            finally:
                run.close()
            self.assertTrue(summary["aborted"])
            self.assertEqual(call.call_count, 1)
            self.assertEqual(summary["failure_counts"], {reason: 1})

    def test_uncertain_attempt_consumes_reservation_and_never_retries(self):
        call = mock.Mock(side_effect=TimeoutError(FAKE_KEY))
        summary = self.execute(self.jobs[:1], call)
        self.assertEqual(call.call_count, 1)
        self.assertEqual(summary["reserved_usd"], str(pilot.RESERVATION))
        self.assertEqual(summary["unknown_usage_attempts"], 1)
        self.assertEqual(summary["failure_counts"], {"TimeoutError": 1})
        self.assertTrue(all(FAKE_KEY.encode() not in p.read_bytes() for p in (self.root / "run").iterdir()))

    def test_oversize_and_duplicate_response_rejected(self):
        for index, body in enumerate((b"x" * (pilot.MAX_RESPONSE + 1), b'{"model":"one","model":"two"}')):
            run = pilot.PrivateRun(self.root / f"invalid-{index}")
            call = mock.Mock(return_value=(200, body))
            try:
                summary = pilot.execute(self.jobs[:1], run, FAKE_KEY, call=call)
            finally:
                run.close()
            self.assertEqual(summary["successful_calls"], 0)
            self.assertEqual(summary["reserved_usd"], str(pilot.RESERVATION))

    def test_global_start_rate_is_capped(self):
        starts = []
        by_hash = {pilot.digest(job["request"]): job for job in self.jobs[:4]}
        def call(payload, key):
            starts.append(time.monotonic())
            job = by_hash[pilot.digest(pilot.strict_json(payload))]
            return 200, pilot.canonical(response(job))
        summary = self.execute(self.jobs[:4], call, interval=0)
        self.assertEqual(summary["successful_calls"], 4)
        self.assertTrue(all(later - earlier >= 0.49 for earlier, later in zip(starts, starts[1:])))

    def test_noul_abstention_and_metadata_agreement_are_not_accuracy(self):
        cases, _ = pilot.load_metadata(self.file(metadata()))
        jobs = pilot.make_jobs(cases)[96:98]
        records = []
        for job in jobs:
            result = response(job)
            result["answers"]["retry"]["noul"] = 0.5
            result["answers"]["work_kind"]["choice"] = "unknown"
            result["answers"]["outcome_support"]["choice"] = "insufficient"
            records.append((job, {"status": "ok", "answers": result["answers"]}))
        summary = pilot.summarize(records)
        self.assertEqual(summary["synthetic_accuracy"], {})
        self.assertEqual(summary["metadata_agreement"]["retry"], {"agree": 1, "paired": 1})
        self.assertEqual(summary["metadata_abstention"][pilot.MODELS[0]]["retry.abstention"], 1)
        self.assertIn("never majority-vote truth", summary["interpretation"])

    def test_builtin_transport_timeout_cap_and_no_redirect(self):
        response_mock = mock.MagicMock()
        response_mock.__enter__.return_value = response_mock
        response_mock.read.return_value = b"{}"
        response_mock.code = 200
        opener = mock.Mock()
        opener.open.return_value = response_mock
        with mock.patch.object(pilot.urllib.request, "build_opener", return_value=opener):
            self.assertEqual(pilot.transport(b"{}", FAKE_KEY), (200, b"{}"))
        self.assertEqual(opener.open.call_args.kwargs["timeout"], 20)
        response_mock.read.assert_called_once_with(pilot.MAX_RESPONSE + 1)
        self.assertIsNone(pilot.NoRedirect().redirect_request(None, None, 302, "", {}, "https://other.invalid"))


if __name__ == "__main__":
    unittest.main()

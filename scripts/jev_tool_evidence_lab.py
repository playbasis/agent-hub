#!/usr/bin/env python3
"""Offline-only tool-fact preparation/analysis; never reads keys or uses network.

Place owner-only states.json in an existing owned 0700 --root directory.
prepare emits frozen canary/main jobs and local gold, without dispatching them.
analyze expects runner receipts under canary-live/ and main-live/ in that root.
"""
import argparse
import collections
import hashlib
import json
import math
import os
import re
import stat
import sys
from pathlib import Path
import jev_telemetry_pilot as pilot

ROOT = None
MODELS = ("jev-1.14.0", "jev-1.13.0")
STATUSES = {"completed", "failed", "running", "interrupted", "pending", "unknown"}
STATE_KEYS = {"provider", "turnStatus", "goalStatus", "models", "turnDurationSeconds", "artifactKindCounts", "artifactCountIsPartial", "toolFacts", "pagePartial", "toolFactsTruncated"}
FACT_KEYS = {"kind", "status", "exitCode", "durationSeconds"}


def read_private(path, limit):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) & 0o077 or st.st_nlink != 1 or st.st_size > limit:
            raise ValueError("unsafe input")
        with os.fdopen(fd, "rb", closefd=False) as f:
            data = f.read(limit + 1)
        if len(data) > limit:
            raise ValueError("input exceeds limit")
        def unique(pairs):
            result = {}
            for key, value in pairs:
                if key in result:
                    raise ValueError("duplicate key")
                result[key] = value
            return result
        return json.loads(data, object_pairs_hook=unique, parse_constant=lambda _: (_ for _ in ()).throw(ValueError("nonfinite")))
    finally:
        os.close(fd)


def validate(rows):
    if not isinstance(rows, list) or not 2 <= len(rows) <= 60:
        raise ValueError("invalid observation count")
    ids = set(); providers = collections.Counter()
    for row in rows:
        if not isinstance(row, dict) or set(row) != {"id", "state"} or not isinstance(row["id"], str) or not re.fullmatch(r"tool-[0-9]{3}", row["id"]) or row["id"] in ids:
            raise ValueError("invalid opaque row identity")
        ids.add(row["id"]); state = row["state"]
        if not isinstance(state, dict) or set(state) != STATE_KEYS or state["provider"] not in {"claude", "codex"} or state["turnStatus"] not in STATUSES or state["goalStatus"] not in STATUSES:
            raise ValueError("invalid state fields")
        providers[state["provider"]] += 1
        models, duration = state["models"], state["turnDurationSeconds"]
        if not isinstance(models, list) or len(models) > 16 or not all(isinstance(m, str) and re.fullmatch(r"(?:claude-|gpt-|gemini-|grok-|o[134](?:-|$))[A-Za-z0-9_.-]{0,70}", m) for m in models) or len(set(models)) != len(models):
            raise ValueError("invalid model identifiers")
        if duration is not None and (type(duration) not in (int, float) or not math.isfinite(duration) or not 0 <= duration <= 31_536_000):
            raise ValueError("invalid recorded elapsed duration")
        if any(type(state[k]) is not bool for k in ("pagePartial", "toolFactsTruncated", "artifactCountIsPartial")) or state["artifactCountIsPartial"] is not True:
            raise ValueError("invalid coverage flags")
        counts = state["artifactKindCounts"]
        if not isinstance(counts, dict) or set(counts) != {"file", "other"} or any(type(v) is not int or not 0 <= v <= 4096 for v in counts.values()) or sum(counts.values()) > 4096:
            raise ValueError("invalid artifacts")
        facts = state["toolFacts"]
        if not isinstance(facts, list) or not 1 <= len(facts) <= 20:
            raise ValueError("invalid fact count")
        for fact in facts:
            if not isinstance(fact, dict) or set(fact) != FACT_KEYS or fact["kind"] not in {"tool_call", "tool_result"} or fact["status"] not in STATUSES:
                raise ValueError("invalid fact")
            code, duration = fact["exitCode"], fact["durationSeconds"]
            if code is not None and (type(code) is not int or not -255 <= code <= 255):
                raise ValueError("invalid exit")
            if duration is not None and (type(duration) not in (int, float) or not math.isfinite(duration) or not 0 <= duration <= 31_536_000):
                raise ValueError("invalid duration")
    if set(providers) != {"claude", "codex"} or any(not 1 <= n <= 30 for n in providers.values()):
        raise ValueError("requires 1 to 30 observations per provider")


def noul(instruction):
    return {"type": "noul", "instructions": instruction, "criteria": {"true": "The exact stated condition is present in the supplied fields.", "false": "The exact stated condition is absent in the supplied fields."}}


QUESTIONS = {
    "listed_nonzero_exit": noul("Looking only at listed toolFacts, is at least one non-null exitCode nonzero? Null is not zero or nonzero. Do not infer anything about unlisted tools or task success."),
    "listed_completed_tool": noul("Looking only at listed toolFacts, is at least one status exactly completed? This asks about the recorded status, not whether the task succeeded."),
    "artifact_recorded": noul("Do the supplied artifactKindCounts add up to more than zero? This asks only whether artifacts are recorded, not whether delivery or work succeeded. A partial count cannot establish absence outside this record."),
    "listed_missing_duration": noul("Looking only at listed toolFacts, is at least one durationSeconds null? This asks only about missing duration fields."),
    "goal_status_recorded_completed": noul("Is the supplied goalStatus exactly completed? This is a recorded status label only, not independent verification of goal success."),
    "recorded_models_present": noul("Is the supplied models list nonempty? These are recorded model identities, not evidence of model correctness or compute time."),
    "turn_elapsed_missing": noul("Is the supplied turnDurationSeconds null? This is recorded elapsed turn time, not provider compute or GPU time."),
}


def expected(state):
    facts = state["toolFacts"]
    return {"listed_nonzero_exit": any(f["exitCode"] is not None and f["exitCode"] != 0 for f in facts),
            "listed_completed_tool": any(f["status"] == "completed" for f in facts),
            "artifact_recorded": sum(state["artifactKindCounts"].values()) > 0,
            "listed_missing_duration": any(f["durationSeconds"] is None for f in facts),
            "goal_status_recorded_completed": state["goalStatus"] == "completed", "recorded_models_present": bool(state["models"]), "turn_elapsed_missing": state["turnDurationSeconds"] is None}


def write_private(name, value):
    fd = os.open(ROOT / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(value, f, sort_keys=True, separators=(",", ":"), allow_nan=False); f.write("\n"); f.flush(); os.fsync(f.fileno())


def prepare():
    rows = read_private(ROOT / "states.json", 262144); validate(rows)
    jobs, gold = [], {}
    for row in rows:
        for i, model in enumerate(MODELS):
            jid = row["id"] + "-m" + str(i)
            jobs.append({"id": jid, "state": row["state"], "questions": QUESTIONS, "model": model})
            gold[jid] = {"provider": row["state"]["provider"], "expected": expected(row["state"])}
    write_private("tool-canary-jobs.json", jobs[:2]); write_private("tool-main-jobs.json", jobs[2:]); write_private("tool-gold.json", gold)
    print(json.dumps({"rows": len(rows), "planned": len(jobs), "canary": 2, "main": len(jobs)-2, "gold_external": False, "reservation_per_call_usd": "0.002688"}))


def analyze():
    gold = read_private(ROOT / "tool-gold.json", 262144)
    batches = [(read_private(ROOT / name, 1048576), ROOT / directory) for name, directory in (("tool-canary-jobs.json", "canary-live"), ("tool-main-jobs.json", "main-live"))]
    jobs = [j for batch, _ in batches for j in batch]
    if not isinstance(gold, dict) or len(batches[0][0]) != 2 or not 4 <= len(jobs) <= 120 or len(jobs) % 2:
        raise ValueError("invalid frozen plan")
    rows = []
    for index in range(0, len(jobs), 2):
        pair = jobs[index:index+2]; base = pair[0]
        if any(not isinstance(j, dict) or set(j) != {"id", "state", "questions", "model"} for j in pair):
            raise ValueError("invalid frozen job")
        ident = base["id"][:-3]
        if [j["id"] for j in pair] != [ident + "-m0", ident + "-m1"] or [j["model"] for j in pair] != list(MODELS) or any(j["questions"] != QUESTIONS or j["state"] != base["state"] for j in pair):
            raise ValueError("modified frozen job")
        rows.append({"id": ident, "state": base["state"]})
        for job in pair:
            if gold.get(job["id"]) != {"provider": base["state"]["provider"], "expected": expected(base["state"])}:
                raise ValueError("invalid frozen gold")
    validate(rows)
    if set(gold) != {j["id"] for j in jobs}:
        raise ValueError("invalid gold identities")
    matrices = collections.defaultdict(collections.Counter); failures = collections.Counter()
    missing = extra = invalid = valid = 0
    for batch, directory in batches:
        st = os.lstat(directory)
        if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o700:
            raise ValueError("unsafe receipt directory")
        paths = list(directory.glob("*.receipt.json"))
        if len(paths) > 240:
            raise ValueError("too many receipts")
        allowed = {f"{i:04}.receipt.json" for i in range(1, len(batch) + 1)}
        extra += sum(path.name not in allowed for path in paths)
        for i, job in enumerate(batch, 1):
            path = directory / f"{i:04}.receipt.json"
            if not path.exists(): missing += 1; continue
            try:
                r = read_private(path, 131072)
                request = {k: job[k] for k in ("state", "questions", "model")}
                if not isinstance(r, dict) or r.get("id") != job["id"] or r.get("model") != job["model"] or r.get("request_sha256") != hashlib.sha256(pilot.canonical(request)).hexdigest():
                    raise ValueError("receipt identity")
                if r.get("status") != "ok":
                    failures[str(r.get("error", "unknown"))[:80]] += 1; continue
                raw = pilot.canonical({"model": r["model"], "answers": r["answers"], "usage": r["usage"]})
                response = pilot.validate_response(raw, {"request": request})
                valid += 1
                for field, answer in response["answers"].items():
                    observed = pilot.predicted(answer)
                    matrices[field][str(gold[job["id"]]["expected"][field]).lower() + " -> " + str(observed).lower()] += 1
            except (OSError, ValueError, KeyError, TypeError, pilot.PilotError):
                invalid += 1
    result = {"planned": len(jobs), "valid": valid, "missing": missing, "extra": extra, "invalid": invalid, "failures": failures, "confusion": matrices, "limitations": "Only listed structured facts; nonrandom selection, partial pages and artifacts; no task success, delivery success, goal verification or model calibration."}
    write_private("tool-analysis.json", result); print(json.dumps(result, sort_keys=True))


def selftest():
    s = {"provider": "claude", "turnStatus": "unknown", "goalStatus": "unknown", "models": [], "turnDurationSeconds": None, "artifactKindCounts": {"file": 0, "other": 0}, "artifactCountIsPartial": True, "toolFacts": [{"kind": "tool_call", "status": "failed", "exitCode": 1, "durationSeconds": None}], "pagePartial": True, "toolFactsTruncated": False}
    rows = [{"id": "tool-%03d" % i, "state": dict(s, provider="claude" if i < 30 else "codex")} for i in range(60)]
    validate(rows); assert expected(s) == {"listed_nonzero_exit": True, "listed_completed_tool": False, "artifact_recorded": False, "listed_missing_duration": True, "goal_status_recorded_completed": False, "recorded_models_present": False, "turn_elapsed_missing": True}
    for key, value in (("rawCommand", "secret"), ("pagePartial", "false")):
        bad = [dict(r, state=dict(r["state"])) for r in rows]; bad[0]["state"][key] = value
        try: validate(bad)
        except ValueError: continue
        raise AssertionError("unsafe data accepted")
    print("offline validation self-test passed")


def main():
    global ROOT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, help="existing owned 0700 private directory")
    parser.add_argument("command", choices=("prepare", "analyze", "selftest"))
    args = parser.parse_args()
    ROOT = Path(args.root)
    st = os.lstat(ROOT)
    if not ROOT.is_absolute() or not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o700:
        raise ValueError("root must be an absolute owned 0700 directory")
    {"prepare": prepare, "analyze": analyze, "selftest": selftest}[args.command]()


if __name__ == "__main__":
    main()


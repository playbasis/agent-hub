#!/usr/bin/env python3
"""Independent reader for the workspace-receipt/1 fixtures.

Re-implements the contract's digest and folding rules with the Python
standard library only, and checks every fixture against expected.json. If the
Swift package and this script agree, the contract is portable, not an
artefact of one implementation. Run: python3 scripts/check-workspace-contracts.py
"""
import hashlib
import json
import pathlib
import sys
from datetime import datetime

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "tests" / "fixtures" / "workspace-economics" / "v1"
UNDIGESTED = {"revision", "observedAt", "contentDigest"}
WINDOWS = {
    "codex-cumulative-usage": {"all": ("local_native_history", None, None), "window": ("local_native_history", 60, 200)},
    "claude-partial-history": {"all": ("local_native_history", None, None)},
    "concurrent-agents": {"all": ("local_native_history", None, None), "window": ("local_native_history", 300, 900)},
    "duplicate-imports-and-corrections": {"all": ("local_native_history", None, None)},
    "workspaceops-receipts": {"all": ("local_native_history", None, None), "account": ("provider_account", None, None)},
}
BASE = datetime.fromisoformat("2026-01-05T09:00:00+00:00").timestamp()
INT64_MAX = 2**63 - 1


def strip_extensions(value):
    if isinstance(value, dict):
        return {k: strip_extensions(v) for k, v in value.items() if not k.startswith("x-")}
    if isinstance(value, list):
        return [strip_extensions(v) for v in value]
    return value


def digest(receipt):
    content = strip_extensions({k: v for k, v in receipt.items() if k not in UNDIGESTED})
    # RFC 8785 for this value space: sorted keys, no whitespace, UTF-8, integers only.
    text = json.dumps(content, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return "sha256:" + hashlib.sha256(text.encode("utf-8")).hexdigest()


def seconds(text):
    return datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp() if text else None


def quantity(text):
    if text is None:
        return None
    if not isinstance(text, str) or not text.isdigit() or (len(text) > 1 and text[0] == "0") or int(text) > INT64_MAX:
        raise ValueError("token quantities are canonical strings up to 2^63-1")
    return int(text)


def valid(receipt):
    if receipt.get("schemaVersion") != "workspace-receipt/1" or digest(receipt) != receipt.get("contentDigest"):
        return False
    time = receipt["time"]
    if time["basis"] == "provider_event" and time["at"] is None:
        return False
    if time["basis"] == "unplaced" and (time["at"] is not None or receipt["includedInTotals"]):
        return False
    return True


def ingest(receipts):
    held, result = {}, dict(accepted=0, duplicates=0, superseded=0, stale=0, conflicts=0, rejected=0)
    for receipt in receipts:
        if not valid(receipt):
            result["rejected"] += 1
            continue
        current = held.get(receipt["eventID"])
        if current is None:
            held[receipt["eventID"]] = receipt
            result["accepted"] += 1
        elif receipt["revision"] < current["revision"]:
            result["stale"] += 1
        elif receipt["revision"] == current["revision"]:
            result["duplicates" if receipt["contentDigest"] == current["contentDigest"] else "conflicts"] += 1
        elif receipt["contentDigest"] == current["contentDigest"]:
            result["duplicates"] += 1
        else:
            held[receipt["eventID"]] = receipt
            result["superseded"] += 1
    return held, result


def union(spans):
    total, current = 0.0, None
    for start, end in sorted(spans):
        if current and start <= current[1]:
            current[1] = max(current[1], end)
        else:
            if current:
                total += current[1] - current[0]
            current = [start, end]
    return total + (current[1] - current[0] if current else 0)


def totals(held, scope, start, end):
    lo = BASE + start if start is not None else None
    hi = BASE + end if end is not None else None
    inside = lambda t: (lo is None or t >= lo) and (hi is None or t < hi)
    out = dict(receipts=0, partialReceipts=0, seriesResets=0, sessions=set(), tools=None, tokens=None, output=None)
    spans = []

    def add(total, output, usage):
        authoritative = usage["provenance"] in ("provider_reported", "derived")
        if not authoritative or usage["completeness"] != "complete" or total is None:
            out["partialReceipts"] += 1
        if not authoritative:
            return
        if total is not None:
            out["tokens"] = (out["tokens"] or 0) + total
        if output is not None:
            out["output"] = (out["output"] or 0) + output

    chosen = [r for r in held.values() if r["scope"] == scope and r["includedInTotals"]]
    for r in (r for r in chosen if r["accumulation"] == "incremental"):
        t = r["time"]
        placed = seconds(t["at"] or t["end"] or t["start"])
        if placed is None or not inside(placed):
            continue
        out["receipts"] += 1
        out["sessions"].add(r["sessionID"])
        add(quantity(r["usage"]["total"]), quantity(r["usage"]["output"]), r["usage"])
        if t["start"] and t["end"]:
            spans.append((r["sessionID"], seconds(t["start"]), seconds(t["end"])))
        tools = (r.get("aggregates") or {}).get("toolCalls")
        if tools is not None:
            out["tools"] = (out["tools"] or 0) + tools
    series = {}
    for r in (r for r in chosen if r["accumulation"] == "cumulative"):
        series.setdefault((r["sessionID"], r["unit"]), []).append(r)
    for key in sorted(series):
        prior_total, prior_output = 0, 0
        for r in sorted(series[key], key=lambda r: (seconds(r["time"]["at"]), r["eventID"])):
            current, current_output = quantity(r["usage"]["total"]), quantity(r["usage"]["output"])
            total = output = None
            reset = False
            if current is not None and prior_total is not None:
                total = current - prior_total if current >= prior_total else current
                reset = current < prior_total
            if current_output is not None and prior_output is not None:
                output = current_output - prior_output if current_output >= prior_output else current_output
            prior_total = current if current is not None else prior_total
            prior_output = current_output if current_output is not None else prior_output
            if not inside(seconds(r["time"]["at"])):
                continue
            out["seriesResets"] += reset
            out["receipts"] += 1
            out["sessions"].add(r["sessionID"])
            add(total, output, r["usage"])
    overflow = (out["tokens"] or 0) > INT64_MAX or (out["output"] or 0) > INT64_MAX
    clipped = [(s, max(a, lo if lo is not None else a), min(b, hi if hi is not None else b)) for s, a, b in spans]
    clipped = [(s, a, b) for s, a, b in clipped if b > a]
    result = {
        "receipts": out["receipts"],
        "tokens": None if out["tokens"] is None or overflow else str(out["tokens"]),
        "output": None if out["output"] is None or overflow else str(out["output"]),
        "partialReceipts": out["partialReceipts"],
        "tokensArePartial": out["partialReceipts"] > 0 or overflow,
        "seriesResets": out["seriesResets"],
        "wallClockSpanSeconds": None,
        "activeSeconds": None,
        "agentSeconds": None,
        "toolCalls": out["tools"],
        "sessions": len(out["sessions"]),
    }
    if clipped:
        result["wallClockSpanSeconds"] = int(max(b for _, _, b in clipped) - min(a for _, a, _ in clipped))
        result["activeSeconds"] = int(union([(a, b) for _, a, b in clipped]))
        by_session = {}
        for s, a, b in clipped:
            by_session.setdefault(s, []).append((a, b))
        result["agentSeconds"] = int(sum(union(v) for v in by_session.values()))
    return result


def main():
    expected = json.loads((FIXTURES / "expected.json").read_text())
    failures = 0
    for name, windows in WINDOWS.items():
        lines = [json.loads(line) for line in (FIXTURES / f"{name}.jsonl").read_text().splitlines() if line.strip()]
        held, result = ingest(lines)
        actual = {"ingest": result}
        for label, (scope, start, end) in windows.items():
            actual[label] = totals(held, scope, start, end)
        if actual != expected[name]:
            failures += 1
            print(f"MISMATCH {name}\n  expected {json.dumps(expected[name], sort_keys=True)}\n  actual   {json.dumps(actual, sort_keys=True)}")
        else:
            print(f"ok {name}")
    if failures:
        sys.exit(1)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Verify a GrizzyBot audit export (one JSON object per line) without GrizzyBot.

Each event's `chain` is SHA-256 over: the previous event's chain ("genesis" for the first), id, type,
at_ms, actorId, botId, tool, matched, source, allowed (1/0), forwarded (1/0), reason, the attributes as
compact JSON with sorted keys, then locality when present, joined by the byte 0x1F.

Usage: verify-audit.py audit.jsonl
"""
import hashlib
import json
import sys


def swift_json(value):
    """Compact, sorted-key JSON the way Swift's JSONEncoder writes it (whole numbers without a point)."""
    if isinstance(value, dict):
        return "{" + ",".join(json.dumps(k, ensure_ascii=False) + ":" + swift_json(value[k]) for k in sorted(value)) + "}"
    if isinstance(value, list):
        return "[" + ",".join(swift_json(v) for v in value) + "]"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False).replace("/", "\\/")
    return json.dumps(value)


def flag(v):
    return "" if v is None else ("1" if v else "0")


def digest(e, previous):
    parts = [
        previous, e["id"], e["type"], str(int(e["at_ms"])), e["actorId"], e.get("botId", ""), e.get("tool", ""),
        e.get("matched", ""), e.get("source", ""), flag(e.get("allowed")), flag(e.get("forwarded")), e["reason"],
        swift_json(e.get("attributes", {})),
    ]
    if e.get("locality"):
        parts.append(e["locality"])
    return hashlib.sha256("\x1f".join(parts).encode("utf-8")).hexdigest()


def main(path):
    events = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
    checked = unchained = 0
    previous = None
    for i, e in enumerate(events):
        chain = e.get("chain")
        if chain is None:
            unchained += 1
            previous = None
            continue
        if previous is not None:
            if digest(e, previous) != chain:
                print(f"BROKEN at event {i + 1}")
                return 1
            checked += 1
        elif digest(e, "genesis") == chain:
            checked += 1
        previous = chain
    remote = sum(1 for e in events if e.get("locality") == "remote")
    print(f"intact: {checked} verified, {unchained} unchained, {remote} remote of {len(events)} events")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))

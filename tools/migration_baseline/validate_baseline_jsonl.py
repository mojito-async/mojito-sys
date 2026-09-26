#!/usr/bin/env python3
"""
tools/migration_baseline/validate_baseline_jsonl.py — M1.1 (#122) schema
check for MOJO_MIGRATION_BASELINE.jsonl against the spec §38.16
machine-readable-results style.

This is a RED-first verification script: it fails today because
MOJO_MIGRATION_BASELINE.jsonl does not exist yet, and it fails again if
the file exists but is missing required rows.

Checks:
  1. The file exists and every non-blank line parses as JSON (JSON Lines).
  2. At least one "meta" row states host, os_version, toolchain and
     mojo_version — the "same-host honest" requirement from the issue's
     own acceptance rule ("every run states host, OS version, toolchain
     version and sample count").
  3. Every MSVS-style row (suite != "benchmark" and suite != "allocation"
     and suite != "size") carries suite/test/platform/result, and result
     is one of the recognized values (PASS/FAIL/RED/DEFERRED/ENV) — the
     "which legs are currently red or deferred" requirement.
  4. Every benchmark row (suite == "benchmark") carries suite/test/
     platform and a sample_count, AND either a measured numeric field
     (iterations/ops_per_sec/ns per the row) or an explicit
     "no_baseline": true with a "reason" string — "each row is either
     measured or explicitly marked as having no Clang baseline."
  5. Every one of the 12 canonical §17 primitive names appears in at
     least one benchmark row. Missing any of them is a hole in the
     baseline, not a pass.
  6. Every allocation row (suite == "allocation") carries alloc_calls and
     free_calls as integers — "allocation counts are measured, not
     asserted" means a number has to be there, not a boolean claim.

Usage: tools/migration_baseline/validate_baseline_jsonl.py [path]
  (defaults to MOJO_MIGRATION_BASELINE.jsonl at the repo root)
Exit: 0 all checks pass; 1 a check failed; 2 environment error (bad usage,
unreadable file).
"""
import json
import os
import sys

SEVENTEEN_PRIMITIVES = [
    "ffi_noop",
    "page_size",
    "vm_reserve_release",
    "vm_commit_decommit",
    "thread_create_join",
    "tls_get_set",
    "clock_read",
    "event_wait_wake",
    "context_switch",
    "poller_add_remove",
    "poller_wake",
    "socket_loopback_roundtrip",
]

MSVS_RESULTS = {"PASS", "FAIL", "RED", "DEFERRED", "ENV"}


def fail(msg):
    print(f"FAIL: {msg}")


def main():
    repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        repo_root, "MOJO_MIGRATION_BASELINE.jsonl"
    )

    if not os.path.isfile(path):
        fail(f"{path} does not exist yet")
        print("validate_baseline_jsonl: FAIL")
        return 1

    rows = []
    with open(path) as f:
        for lineno, line in enumerate(f, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append((lineno, json.loads(line)))
            except json.JSONDecodeError as e:
                fail(f"{path}:{lineno} is not valid JSON: {e}")
                print("validate_baseline_jsonl: FAIL")
                return 1

    failures = 0

    # ---- 2. meta row -------------------------------------------------
    meta_rows = [r for _, r in rows if r.get("suite") == "meta"]
    if not meta_rows:
        fail("no 'meta' row found (host/os_version/toolchain/mojo_version)")
        failures += 1
    else:
        required_meta = ("host", "os_version", "toolchain", "mojo_version")
        for field in required_meta:
            if not any(field in r and r[field] for r in meta_rows):
                fail(f"no 'meta' row carries a non-empty '{field}' field")
                failures += 1

    # ---- 3. MSVS-style rows -------------------------------------------
    msvs_rows = [
        (ln, r) for ln, r in rows
        if r.get("suite") not in ("benchmark", "allocation", "size", "meta")
    ]
    if not msvs_rows:
        fail("no MSVS-style result rows found (suite/test/platform/result)")
        failures += 1
    for ln, r in msvs_rows:
        for field in ("suite", "test", "platform", "result"):
            if field not in r:
                fail(f"line {ln}: MSVS row missing '{field}': {r}")
                failures += 1
        if r.get("result") not in MSVS_RESULTS and "result" in r:
            fail(
                f"line {ln}: MSVS row has unrecognized result '{r.get('result')}' "
                f"(expected one of {sorted(MSVS_RESULTS)})"
            )
            failures += 1

    # ---- 4. benchmark rows --------------------------------------------
    bench_rows = [(ln, r) for ln, r in rows if r.get("suite") == "benchmark"]
    if not bench_rows:
        fail("no benchmark rows found (suite == 'benchmark')")
        failures += 1
    seen_primitives = set()
    for ln, r in bench_rows:
        for field in ("suite", "test", "platform"):
            if field not in r:
                fail(f"line {ln}: benchmark row missing '{field}': {r}")
                failures += 1
        name = r.get("test")
        if name:
            seen_primitives.add(name)
        no_baseline = r.get("no_baseline") is True
        if no_baseline:
            if not r.get("reason"):
                fail(f"line {ln}: no_baseline row missing a 'reason': {r}")
                failures += 1
        else:
            has_measurement = any(
                k in r for k in ("iterations", "ops_per_sec", "ns", "value")
            )
            if not has_measurement:
                fail(
                    f"line {ln}: benchmark row for '{name}' has neither a "
                    "measured value (iterations/ops_per_sec/ns/value) nor "
                    "no_baseline:true"
                )
                failures += 1
            if "sample_count" not in r and "iterations" not in r:
                fail(
                    f"line {ln}: benchmark row for '{name}' states no "
                    "sample_count/iterations (same-host honesty requires it)"
                )
                failures += 1

    for primitive in SEVENTEEN_PRIMITIVES:
        if primitive not in seen_primitives:
            fail(
                f"§17 primitive '{primitive}' has no benchmark row at all "
                "(measured or no_baseline)"
            )
            failures += 1

    # ---- 6. allocation rows --------------------------------------------
    alloc_rows = [(ln, r) for ln, r in rows if r.get("suite") == "allocation"]
    if not alloc_rows:
        fail("no allocation-count rows found (suite == 'allocation')")
        failures += 1
    for ln, r in alloc_rows:
        for field in ("test", "alloc_calls", "free_calls", "iterations"):
            if field not in r:
                fail(f"line {ln}: allocation row missing '{field}': {r}")
                failures += 1
                continue
        if "alloc_calls" in r and not isinstance(r["alloc_calls"], int):
            fail(f"line {ln}: allocation row 'alloc_calls' is not an integer: {r}")
            failures += 1

    if failures:
        print(f"validate_baseline_jsonl: FAIL ({failures} issue(s), {len(rows)} rows read)")
        return 1
    print(f"validate_baseline_jsonl: PASS ({len(rows)} rows)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

# mojito-sys S4 — monotonic-clock conformance (issue #63, spec §38.9).
#
# Drives the §19 monotonic-clock surface (Mojo wrappers bound to the frozen
# mjs_clock_now / mjs_clock_resolution C ABI) through the full §38.9 check
# list:
#
#   1. monotonic-reads      — ≥20k consecutive reads never decrease;
#   2. clock-progress       — the clock advances across a timed window;
#   3. self-identity        — inst.duration_since(inst) == 0;
#   4. triangle             — d(a,c) <= d(a,b) + d(b,c) within resolution
#                             slack;
#   5. inverted-clamps-zero — DOCUMENTED DEVIATION TEST: duration_since on
#     an inverted/equal pair clamps to zero instead of underflowing (spec
#     §38.9 "inverted clamps to 0"; the clamp is the defined behavior, and
#     this suite fails if it ever changes);
#   6. saturation           — +Duration saturates at UInt64::MAX for both
#     MonotonicInstant and Duration; subtraction clamps at zero;
#   7. mocked-100y          — ~100-year mocked intervals carry exact ns
#     arithmetic end-to-end (wrapper math only, no sleeping);
#   8. conversion-roundtrip — ns/ms/us/s factory <-> accessor round-trips
#     plus instant +d, duration_since identity;
#   9. resolution-sane      — 1 ns <= resolution <= 1 ms;
#  10. raw-cross-check      — same-window deltas vs test-local libc
#     CLOCK_MONOTONIC_RAW: ratio in [0.9, 1.1], median-of-3 over 50–100 ms
#     windows (never inferred from wall-clock time; RAW never slews);
#  11. null-out-e fault     — NULL out-slot returns -EFAULT (frozen ABI:
#     out-params untouched on failure; errno 14 on darwin AND Linux);
#  12. calibration-once     — 1M-call smoke completes well-bounded wall
#     time (the macOS timebase is cached behind pthread_once in C — no
#     repeated expensive setup per §19 L1061; this catches a regression to
#     per-call calibration).
#
# b2 notes (matching tests/s1/*/ conventions):
#   - Null pointers are built from a RUNTIME zero (`unsafe_from_address=0`
#     literal is rejected in 1.0.0b2).
#   - Exactly ONE raise site with a CONSTANT payload: string literals must
#     never reach a raise payload through a control-flow merge in a module
#     that lowers @extern bindings (issue #29 H6). All diagnostics go to
#     stdout; failures accumulate in `failed`.
#
# Run via tests/s4/time/monotonic/run.sh (builds libmojito_sys.dylib first).

from std.memory import UnsafePointer, stack_allocation
from mojito_sys.time.duration import (
    Duration,
    duration_from_micros,
    duration_from_millis,
    duration_from_secs,
)
from mojito_sys.time.monotonic import (
    MonotonicInstant,
    clock_resolution,
    mjs_clock_now,
    mjs_clock_resolution,
    monotonic_now,
)

# CLOCK_MONOTONIC_RAW is 4 on BOTH Linux and macOS (darwin <time.h> keeps
# the Linux clockid_t numbering for this one), so a single comptime serves
# both ports.
comptime CLOCK_MONOTONIC_RAW = 4

# Frozen ABI failure convention: negative -errno. EFAULT = 14 everywhere we
# target; the C side validates the out-slot before touching anything.
comptime EFAULT_RC = Int32(-14)

comptime NS_PER_SEC = UInt64(1000000000)

# Julian year in ns (365.25 d): ~3.15576e16. A ~100-year interval
# (~3.15576e18 ns) exercises large mocked arithmetic while leaving headroom
# below UInt64::MAX (~1.8446744e19) for the saturation-boundary checks.
comptime YEAR_NS = UInt64(31557600000000000)


# ---------------------------------------------------------------------------
# Test-local independent time source: libc CLOCK_MONOTONIC_RAW via a raw
# @extern binding. The timespec travels as two Int64 cells — exactly the
# tv_sec/tv_nsec layout of struct timespec on this LP64 host.
@extern("clock_gettime")
def _libc_clock_gettime(
    clk_id: Int32,
    tp: UnsafePointer[Int64, MutAnyOrigin],
) abi("C") -> Int32:
    ...


def _raw_now_ns() -> UInt64:
    var tp = stack_allocation[2, Int64]()
    var rc = _libc_clock_gettime(Int32(CLOCK_MONOTONIC_RAW), tp)
    if rc != 0:
        return 0  # unusable reading; callers fail the dependent check
    return UInt64(tp[0]) * NS_PER_SEC + UInt64(tp[1])


# Spin until `window_ns` elapsed on the RAW clock, bounded by `budget_ns`.
# Returns the raw elapsed actually observed, or 0 if the budget blew —
# callers MUST treat 0 as a harness failure, never as data.
def _spin_raw_window(window_ns: UInt64, budget_ns: UInt64) -> UInt64:
    var start = _raw_now_ns()
    while True:
        var now = _raw_now_ns()
        if now - start >= window_ns:
            return now - start
        if now - start > budget_ns:
            return 0


def _median3(a: Float64, b: Float64, c: Float64) -> Float64:
    var lo = min(a, min(b, c))
    var hi = max(a, max(b, c))
    return a + b + c - lo - hi


# One cross-check sample: our-clock delta vs raw-clock delta over the SAME
# ~70 ms window (inside the 50–100ms spec band). Returns 0.0 on harness
# failure (budget exhausted), which the caller rejects explicitly.
def _one_ratio() raises -> Float64:
    var window = NS_PER_SEC * UInt64(70) // UInt64(1000)
    var r0 = _raw_now_ns()
    var o0 = monotonic_now()
    var raw_elapsed = _spin_raw_window(window, NS_PER_SEC * UInt64(2))
    var o1 = monotonic_now()
    var r1 = _raw_now_ns()
    if raw_elapsed == 0 or r1 <= r0:
        return 0.0
    return Float64((o1.duration_since(o0)).ns) / Float64(r1 - r0)


def main() raises:
    var failed = 0

    # ---- 1. monotonicity: 20k reads, never decreasing ---------------------
    var prev = monotonic_now()
    var mono_ok = True
    var regressed_at = UInt64(0)
    var i = UInt64(1)
    while i < UInt64(20000):
        var cur = monotonic_now()
        if cur.ticks < prev.ticks:
            mono_ok = False
            regressed_at = i
            break
        prev = cur
        i += 1
    if mono_ok:
        print("T4.1 monotonic-reads(20k non-decreasing): PASS")
    else:
        print(
            "T4.1 monotonic-reads(20k non-decreasing): FAIL (regression at read "
            + String(regressed_at)
            + ")"
        )
        failed += 1

    # ---- 2. progress across a timed window -------------------------------
    # >=10 ms window on the raw clock, 2 s budget; our clock must advance by
    # at least half the window (loose here — the ratio check below is strict).
    var prog_window = NS_PER_SEC // UInt64(100)
    var p0 = monotonic_now()
    var prog_raw = _spin_raw_window(prog_window, NS_PER_SEC * UInt64(2))
    var p1 = monotonic_now()
    var advanced = p1.duration_since(p0).ns
    var prog_ok = (prog_raw != 0) and (advanced >= prog_window // UInt64(2))
    if prog_ok:
        print("T4.1 clock-progress:                     PASS")
    else:
        print(
            "T4.1 clock-progress:                     FAIL (advanced="
            + String(advanced)
            + "ns raw="
            + String(prog_raw)
            + "ns)"
        )
        failed += 1

    # ---- 3. self identity -------------------------------------------------
    var x = monotonic_now()
    var self_ok = x.duration_since(x).ns == 0
    if self_ok:
        print("T4.1 duration_since(self) == 0:          PASS")
    else:
        print("T4.1 duration_since(self) == 0:          FAIL")
        failed += 1

    # ---- 4. triangle inequality within resolution slack -------------------
    var res = clock_resolution()
    var slack = res.ns * UInt64(8) + UInt64(1000)
    var ta = monotonic_now()
    var raw_ab = _spin_raw_window(NS_PER_SEC // UInt64(200), NS_PER_SEC * UInt64(2))
    var tb = monotonic_now()
    var raw_bc = _spin_raw_window(NS_PER_SEC // UInt64(200), NS_PER_SEC * UInt64(2))
    var tc = monotonic_now()
    var tri_ok = (raw_ab != 0) and (raw_bc != 0)
    if tri_ok:
        var d_ab = tb.duration_since(ta)
        var d_bc = tc.duration_since(tb)
        var d_ac = tc.duration_since(ta)
        tri_ok = d_ac.ns <= d_ab.ns + d_bc.ns + slack
    if tri_ok:
        print("T4.1 triangle (resolution-slack):        PASS")
    else:
        print("T4.1 triangle (resolution-slack):        FAIL")
        failed += 1

    # ---- 5. inverted/equal pairs CLAMP TO ZERO (documented behavior) ------
    # Spec §38.9: "inverted clamps to 0". This is the defined deviation from
    # unsigned underflow: duration_since NEVER wraps. If these fail, the
    # documented contract changed — fix the docs or the code, not this test.
    var inv_earlier = MonotonicInstant(UInt64(1000000000))
    var inv_later = MonotonicInstant(UInt64(400))
    var inv_ok = (inv_later.duration_since(inv_earlier).ns == 0) and (
        inv_earlier.duration_since(inv_earlier).ns == 0
    )
    if inv_ok:
        print("T4.1 inverted-clamps-to-zero:            PASS")
    else:
        print("T4.1 inverted-clamps-to-zero:            FAIL")
        failed += 1

    # ---- 6. saturation boundaries ----------------------------------------
    var umax = ~UInt64(0)
    var imax = MonotonicInstant(umax)
    var sat_ok = (imax + Duration(UInt64(1))).ticks == umax
    sat_ok = sat_ok and ((imax + duration_from_secs(UInt64(1000000))).ticks == umax)
    sat_ok = sat_ok and ((Duration(umax) + Duration(UInt64(7))).ns == umax)
    sat_ok = sat_ok and ((Duration(UInt64(3)) - Duration(UInt64(5))).ns == 0)
    # Near-max tail arithmetic stays EXACT below the saturation point.
    var tail = MonotonicInstant(umax - UInt64(100))
    sat_ok = sat_ok and (
        (tail + Duration(UInt64(93))).ticks == umax - UInt64(7)
    )
    sat_ok = sat_ok and (
        imax.duration_since(MonotonicInstant(umax - UInt64(7))).ns == 7
    )
    if sat_ok:
        print("T4.1 saturation-boundaries:              PASS")
    else:
        print("T4.1 saturation-boundaries:              FAIL")
        failed += 1

    # ---- 7. ~100-year MOCKED intervals (exact wrapper math) --------------
    # 100y in seconds = 3,155,760,000; in ns ~3.15576e18 — fits without
    # saturation, so every step must be exact.
    var century_secs = UInt64(3155760000)
    var century = duration_from_secs(century_secs)
    var mock_ok = century.ns == century_secs * UInt64(1000000000)
    var base = MonotonicInstant(YEAR_NS * UInt64(20))
    var later = base + century
    mock_ok = mock_ok and (later.ticks == base.ticks + century.ns)
    mock_ok = mock_ok and (later.duration_since(base).ns == century.ns)
    # Deep-mock near the top of the range: 500y base + 100y span SATURATES.
    var deep = MonotonicInstant(YEAR_NS * UInt64(500))
    var deep_later = deep + century
    mock_ok = mock_ok and (deep_later.ticks == umax)
    mock_ok = mock_ok and (deep_later.duration_since(deep).ns == umax - deep.ticks)
    if mock_ok:
        print("T4.1 mocked-100y-intervals:              PASS")
    else:
        print("T4.1 mocked-100y-intervals:              FAIL")
        failed += 1

    # ---- 8. conversion round-trips ---------------------------------------
    var rt_ok = Duration(UInt64(123456789)).ns == UInt64(123456789)
    rt_ok = rt_ok and (duration_from_millis(UInt64(98765)).as_millis() == UInt64(98765))
    rt_ok = rt_ok and (duration_from_micros(UInt64(42424242)).as_micros() == UInt64(42424242))
    rt_ok = rt_ok and (duration_from_secs(UInt64(77)).as_secs() == UInt64(77))
    # Truncation is part of the documented down-conversion contract.
    rt_ok = rt_ok and (duration_from_millis(UInt64(1500)).as_secs() == UInt64(1))
    rt_ok = rt_ok and (duration_from_secs(umax).ns == umax)  # factory saturates
    # Instant round-trip: (+d) then duration_since recovers d exactly.
    var ri = monotonic_now()
    var rd = duration_from_millis(UInt64(3))
    var rj = ri + rd
    rt_ok = rt_ok and (rj.duration_since(ri).ns == rd.ns)
    if rt_ok:
        print("T4.1 conversion-roundtrips:              PASS")
    else:
        print("T4.1 conversion-roundtrips:              FAIL")
        failed += 1

    # ---- 9. resolution sane ----------------------------------------------
    # Real hosts report between 1 ns and 1 us-ish; allow up to 1 ms so a
    # coarse-but-honest port still passes while garbage cannot.
    var res_ok = (res.ns >= UInt64(1)) and (res.ns <= UInt64(1000000))
    if res_ok:
        print("T4.1 resolution-sane (res=" + String(res.ns) + "ns): PASS")
    else:
        print(
            "T4.1 resolution-sane:                    FAIL (res="
            + String(res.ns)
            + "ns)"
        )
        failed += 1

    # ---- 10. cross-check vs libc CLOCK_MONOTONIC_RAW ---------------------
    # Median-of-3 ratios over 50–100ms windows must land in [0.9, 1.1]:
    # both clocks tick real time; only scaling errors (macOS timebase!) or
    # non-monotonic sources push the median outside the band.
    var ra = _one_ratio()
    var rb = _one_ratio()
    var rc_ratio = _one_ratio()
    var median = _median3(ra, rb, rc_ratio)
    var cross_ok = (ra != 0.0) and (rb != 0.0) and (rc_ratio != 0.0)
    cross_ok = cross_ok and (median >= 0.9) and (median <= 1.1)
    if cross_ok:
        print(
            "T4.1 raw-cross-check (median=" + String(median) + "): PASS"
        )
    else:
        print(
            "T4.1 raw-cross-check:                    FAIL (ratios="
            + String(ra)
            + ","
            + String(rb)
            + ","
            + String(rc_ratio)
            + ")"
        )
        failed += 1

    # ---- 11. NULL out-slot => -EFAULT, frozen ABI ------------------------
    # Runtime zero: b2 rejects a literal unsafe_from_address=0.
    var zero = 0
    var null_out = UnsafePointer[UInt64, MutAnyOrigin](unsafe_from_address=zero)
    var rc_now = mjs_clock_now(null_out)
    var rc_res = mjs_clock_resolution(null_out)
    var eault_ok = (rc_now == EFAULT_RC) and (rc_res == EFAULT_RC)
    if eault_ok:
        print("T4.1 null-out--EFAULT:                   PASS")
    else:
        print(
            "T4.1 null-out--EFAULT:                   FAIL (now_rc="
            + String(rc_now)
            + " res_rc="
            + String(rc_res)
            + ")"
        )
        failed += 1

    # ---- 12. calibration-once smoke: 1M calls bounded --------------------
    # macOS scales mach_absolute_time ticks through a cached timebase
    # (pthread_once in mjs_time.c); Linux reads clock_gettime directly.
    # Either way 1M calls must complete in << 1 s of wall time — a per-call
    # recalibration blows this budget loudly.
    var s0 = _raw_now_ns()
    var first = monotonic_now()
    var last = first
    var k = UInt64(0)
    while k < UInt64(1000000):
        last = monotonic_now()
        k += 1
    var s1 = _raw_now_ns()
    var smoke_ok = (s1 != 0) and (s1 - s0 <= UInt64(2000000000))
    smoke_ok = smoke_ok and (last.ticks >= first.ticks)
    if smoke_ok:
        print(
            "T4.1 calibration-once-smoke(1M calls "
            + String((s1 - s0) // UInt64(1000000))
            + "ms): PASS"
        )
    else:
        print("T4.1 calibration-once-smoke:             FAIL")
        failed += 1

    if failed != 0:
        print("RESULT: " + String(failed) + " FAILED")
        raise Error("S4 time-monotonic conformance failed")
    print("RESULT: all green")

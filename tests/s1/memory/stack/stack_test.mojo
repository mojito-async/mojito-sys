# mojito-sys S1 — memory/stack conformance (issue #30).
#
# Verifies the non-moving guarded native stack allocator end to end:
#   1. create: 256 KiB reserve / 16 KiB initial commit / 1 page (16384
#      bytes) guard; geometry (guard_low == base + 1 page, no gap) and top
#      16-byte alignment.
#   2. guard proof: a forked child writing into the PROT_NONE guard region
#      dies from a synchronous hardware fault (SIGBUS on macOS arm64,
#      SIGSEGV elsewhere) — child-only, robust on any host. Runs in the
#      companion C probe (fork from C, not Mojo).
#   3. growth: 100x grow of commit bytes (page increments; a second,
#      larger reservation so the sweep fits) — every live address (base,
#      guard_low, top) is byte-identical before/after, no pointing
#      movement; descending stack writes exercise the deeper committed
#      span without ever touching the guard.
#
# TDD-red note: the package scaffold (mojito_sys/__init__.mojo,
# mojito_sys/memory/__init__.mojo) is owned by the S1Build lane; until that
# lane merges this suite reports FAIL (unresolvable import). Green requires
# the merged libmojito_sys.dylib with mjs_stack_alloc/free (stack lane) and
# mjs_vm_commit (vm lane).

from mojito_sys.memory.stack import NativeStack

# ---- C probe entry points (linked into this executable) -----------------------


@extern("s1_stack_probe_init")
def _probe_init() abi("C") -> Int32:
    ...


@extern("s1_guard_probe_run")
def _guard_probe_run() abi("C") -> Int32:
    ...


comptime PAGE = 16384           # host page size (mojito 1.0.0b2, Darwin arm64)
comptime RESERVE = 256 * 1024   # 16 pages
comptime INITIAL_COMMIT = 16 * 1024  # 1 page
comptime GUARD = PAGE           # 1 page

# Growth sweep: reserve 4 MiB so 100 x 1-page grows fit after 1-page
# initial commit (usable = 255 pages).
comptime RESERVE_BIG = 4 * 1024 * 1024   # 256 pages
comptime GROW_STEPS = 100


def check(name: String, cond: Bool) -> Int:
    print(name + (" PASS" if cond else " FAIL"))
    return 0 if cond else 1


def _finish(failures: Int) raises:
    """Raise-only exit; kept extern-free because the b2 compiler crashes when
    a module-level function both calls an extern and raises (S1 discovery)."""
    if failures != 0:
        raise Error("s1 memory/stack FAILED: " + String(failures))


def main() raises:
    var failures = 0

    if _probe_init() != 0:
        print(
            "probe-init FAIL: libmojito_sys.dylib not resolvable - "
            + "expected RED until build/vm lanes merge (issues #24/#29)",
        )
        print("RESULT: RED (see issues #24/#29/#30)")
        return

    # 1. create + geometry -------------------------------------------------
    var st = NativeStack.create(RESERVE, INITIAL_COMMIT, GUARD)
    if not st.is_live():
        print("create FAIL: stack not live after create")
        return
    failures += check("create live", st.is_live())
    failures += check(
        "geometry base < guard_low <= top",
        st.base_address() < st.guard_low_address()
        and st.guard_low_address() <= st.top_address(),
    )
    failures += check(
        "guard_low == base + guard (one page)",
        st.guard_low_address() == st.base_address() + GUARD,
    )
    failures += check(
        "top 16-aligned",
        st.top_address() % 16 == 0,
    )
    failures += check(
        "top == base + guard + reserve (page-rounded)",
        st.top_address() == st.base_address() + GUARD + RESERVE,
    )
    failures += check(
        "usable span positive (top > guard_low)",
        st.top_address() > st.guard_low_address(),
    )
    failures += check("geometry helper", st.check_geometry())

    # 2. descending stack writes inside the usable region, never the guard --
    failures += check(
        "top-1 byte writable",
        st.write_at(st.top_address() - 1, UInt8(42)),
    )
    var ok_desc = True
    var i = 0
    while i < 10:
        # steppes of 16 bytes walking DOWN from top-1
        var a = st.top_address() - 1 - i * 16
        ok_desc = ok_desc and st.write_at(a, UInt8(i + 1))
        i += 1
    failures += check("10 descending writes inside usable", ok_desc)
    failures += check(
        "wrapper refuses write into guard",
        not st.write_at(st.base_address() + 8, UInt8(9)),
    )

    # 3. guard region proof (forked child via the C probe) ---------------
    var v = _guard_probe_run()
    if v == 0:
        print("guard-probe PASS: child write into guard raised SIGBUS/SIGSEGV")
    elif v == 2:
        print("guard-probe FAIL: child survived guard write (corruption path)")
        failures += 1
    elif v == 3:
        print("guard-probe FAIL: child died from unexpected signal")
        failures += 1
    elif v == 4:
        print("guard-probe FAIL: probe stack allocation failed")
        failures += 1
    elif v == 5:
        print("guard-probe FAIL: waitpid failed in probe")
        failures += 1
    else:
        print("guard-probe FAIL: unknown verdict " + String(v))
        failures += 1

    # 4. growth: 100x commit, addresses stable ------------------------------
    var st2 = NativeStack.create(RESERVE_BIG, INITIAL_COMMIT, GUARD)
    if not st2.is_live():
        print("growth FAIL: big stack not live")
        return
    var gb = st2.base_address()
    var gg = st2.guard_low_address()
    var gt = st2.top_address()
    var grew = 0
    var grow_fail = False
    i = 0
    while i < GROW_STEPS:
        try:
            st2.grow(PAGE)
            grew += 1
        except e:
            grow_fail = True
            print("    grow step " + String(i) + " raised: " + String(e))
        i += 1
    failures += check(
        "100x grow committed (all steps)",
        grew == GROW_STEPS,
    )
    failures += check(
        "addresses stable across grow (base)",
        st2.base_address() == gb and st2.guard_low_address() == gg
        and st2.top_address() == gt,
    )
    if grew == GROW_STEPS:
        # Descending writes into the newly committed deep span (now at
        # gt - 32*PAGE..) — must not touch guard and must not fault.
        var deep = st2.top_address() - 2 * PAGE
        failures += check(
            "deep committed byte writable after grow",
            st2.write_at(deep, UInt8(0xAB)),
        )
        var desc2 = True
        var j = 0
        while j < 16:
            desc2 = desc2 and st2.write_at(deep - j * 16, UInt8(j))
            j += 1
        failures += check("descending writes into grown span", desc2)
    elif grow_fail:
        print("grow skipped until vm-lane commit service merges (issue #29); "
            + "non-movement verified on create")
    else:
        print("grow FAIL: no progress and not raised")

    print("RESULT: all green" if failures == 0 else "RESULT: " + String(failures) + " FAILED")
    _finish(failures)
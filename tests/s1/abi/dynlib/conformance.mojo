# mojito-sys S1.13 — abi/dynlib conformance (issue #46).
#
# Verifies the minimal dynamic-library surface (disposition path A):
#   - RTLD_* mode constants carry their POSIX values;
#   - main-image round-trip: the dlopen(NULL) handle opens non-null and
#     resolves known libc symbols to stable, nonzero addresses;
#   - a missing library raises a deterministic "dlopen failed" error;
#   - a missing symbol raises a deterministic "dlsym failed" error that
#     names the symbol;
#   - close-once ownership (echoing §7.2/§25): dispose() commits exactly
#     once, a repeat dispose is a no-op 0, resolve after dispose is a
#     deterministic misuse error;
#   - move (`^`) transfers close-once ownership to the destination.
#
# Pure Mojo — no native dylib needed (the main image provides symbols).
#
# This file is red (does not compile) until abi/dynlib.mojo exists — the
# expected TDD-red state for this lane.

from mojito_sys.abi.dynlib import (
    DynamicLibrary,
    RTLD_GLOBAL,
    RTLD_LAZY,
    RTLD_LOCAL,
    RTLD_NOW,
    main_library,
    open_library,
)


def contains(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) >= 0


def check(name: String, ok: Bool) -> Bool:
    if ok:
        print("PASS:", name)
    else:
        print("FAIL:", name)
    return ok


def run_checks() raises -> Int:
    var failures = 0

    # D1 — mode constants carry their POSIX values (same on darwin/Linux
    # for these four; comptime so an ABI drift fails the build).
    comptime assert RTLD_LAZY == 1
    comptime assert RTLD_NOW == 2
    comptime assert RTLD_LOCAL == 0
    comptime assert RTLD_GLOBAL == 0x100
    _ = check("D1 RTLD_* constant values", True)

    # D2 — main-image round-trip: dlopen(NULL) opens non-null.
    var lib = main_library(RTLD_LAZY)
    failures += Int(not check("D2 main image opens", not lib.is_null()))

    # D3 — known libc symbol resolves to a stable nonzero address.
    var a1 = lib.resolve("malloc")
    var a2 = lib.resolve("malloc")
    failures += Int(not check("D3 malloc resolves nonzero+stable", a1 != 0 and a1 == a2))

    # D4 — the loader surface itself is visible through the same path.
    var adl = lib.resolve("dlopen")
    failures += Int(not check("D4 dlopen self-resolves", adl != 0))

    # D5 — refcounted re-open: two handles over one image both close clean.
    var h1 = main_library(RTLD_NOW)
    var h2 = main_library(RTLD_NOW)
    var ok5 = h1.dispose() == 0 and h2.dispose() == 0
    failures += Int(not check("D5 double open/close refcount", ok5))

    # D6 — missing library raises a deterministic error.
    var ok6 = False
    try:
        _ = open_library("libmojito_no_such_46.dylib", RTLD_NOW)
    except e:
        ok6 = contains(String(e), "dlopen failed")
    failures += Int(not check("D6 missing library raises", ok6))

    # D7 — missing symbol raises deterministically, naming the symbol.
    var lib2 = main_library(RTLD_LAZY)
    var ok7 = False
    try:
        _ = lib2.resolve("mojito_definitely_absent_symbol_46")
    except e:
        ok7 = contains(String(e), "dlsym failed") and contains(
            String(e), "mojito_definitely_absent_symbol_46"
        )
    failures += Int(not check("D7 missing symbol raises named", ok7))

    # D8 — close-once ownership: dispose commits exactly once; a repeat
    # dispose is a no-op returning 0.
    var lib3 = main_library(RTLD_LAZY)
    var rc1 = lib3.dispose()
    var was_disposed = lib3.is_disposed()
    var rc2 = lib3.dispose()
    failures += Int(not check("D8 close-once dispose", rc1 == 0 and was_disposed and rc2 == 0))

    # D9 — resolve after dispose is a deterministic misuse error.
    var ok9 = False
    try:
        _ = lib3.resolve("malloc")
    except e:
        ok9 = contains(String(e), "disposed")
    failures += Int(not check("D9 resolve-after-dispose raises", ok9))

    # D10 — move transfers ownership: the destination closes exactly once;
    # the moved-from source destructor stays silent.
    var src = main_library(RTLD_LAZY)
    var dst = src^
    var ok10 = dst.dispose() == 0 and dst.is_disposed()
    failures += Int(not check("D10 move transfers close-once ownership", ok10))

    return failures


def main() raises:
    var failures = run_checks()
    if failures == 0:
        print("RESULT: all green")
    else:
        print("RESULT: FAILED (" + String(failures) + " check(s))")

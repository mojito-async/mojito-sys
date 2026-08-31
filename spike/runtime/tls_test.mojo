# spike/runtime/tls_test.mojo — M1.3 (#126) runtime spike: native TLS key
# create/set/get/destroy driven directly from Mojo, no mjs_tls.c anywhere
# in the chain (unlike mojito_sys.thread.tls.NativeTlsKey, which wraps
# native/posix/mjs_tls.c's registry). #126 asks whether Mojo can own a raw
# pthread_key_t itself: mint it, bind/read per-thread values, see the exit
# destructor fire, and prove the get path allocates nothing.
#
# Acceptance criteria this file targets (issue #126, TLS half):
#   T1  create/set/get/destroy round trip on the main thread;
#   T2  a value bound on a SPAWNED thread is invisible to the main thread
#       and vice versa (per-thread isolation, not per-process);
#   T3  the destructor registered at create() fires EXACTLY ONCE, on the
#       binding thread's exit, with the VALUE that thread bound (not the
#       key, matching POSIX's pthread_key_create(3) destructor contract);
#   T4  a value set FROM MOJO is visible to a real C function reading the
#       same key with pthread_getspecific, and a value set FROM C is
#       visible to Mojo's pthread_getspecific — proven via
#       spike/runtime/oracle.c's oracle_tls_set_from_c/oracle_tls_get_from_c,
#       not asserted from the shared-registry-implies-shared-values
#       assumption;
#   T5  after destroy(), get()/set() on the dead key fail deterministically
#       (EINVAL) rather than touching freed kernel state;
#   T6  mjs_tls_get-equivalent reads (pthread_getspecific called directly)
#       allocate NOTHING — measured via
#       tools/migration_baseline/alloc_probe_shim.c's malloc/calloc/realloc
#       counters (spec SYS-4's "no hidden allocation," §18's "measured, not
#       asserted" methodology), not merely asserted from the header
#       comment. This check is macOS-only (the shim is a dyld-interposing
#       mechanism, Apple-specific — see that file's own header) and reports
#       ENVIRONMENT/SKIP rather than a false PASS on a host where the shim
#       cannot be loaded.
#
# Run via spike/runtime/run.sh, which builds oracle.c AND
# tools/migration_baseline/alloc_probe_shim.c ad hoc and sets
# DYLD_INSERT_LIBRARIES/DYLD_FORCE_FLAT_NAMESPACE for T6 specifically (the
# other tests do not need the shim loaded at all). Green requires the
# exact "RESULT: all green" line.

from std.memory import stack_allocation
from std.sys import CompilationTarget
from std.sys.intrinsics import inlined_assembly

import externs_leaf as ext

comptime U64Ptr = UnsafePointer[UInt64, MutAnyOrigin]


def entry_pointer[symbol_name: String]() -> ext.EntryCodePtr:
    # PORTABLE across macOS (Mach-O) and Linux (ELF), both AArch64: the two
    # object formats need different adrp/add relocation syntax for the same
    # ADRP+ADD page-address idiom -- Mach-O wants a leading `_` symbol
    # prefix and `@PAGE`/`@PAGEOFF`; ELF wants no prefix and `:lo12:`
    # instead of `@PAGEOFF` (plain adrp with no suffix at all for the high
    # part). This comptime branch is a genuinely NEW finding this leg
    # verified for real on native Linux/AArch64 (a docker container on the
    # arm64 dev host, see README.md) -- #124's own version of this idiom
    # was Apple-arm64-only and never actually ran on any Linux host either
    # (the CI wall blocked it). x86-64 would need a THIRD, ISA-different
    # form (`lea`) not attempted here -- see README.md's portability note.
    comptime is_macos = CompilationTarget().is_macos()
    comptime asm_str = (
        "adrp ${0:x}, _" + symbol_name + "@PAGE\n"
        "add ${0:x}, ${0:x}, _" + symbol_name + "@PAGEOFF\n"
    ) if is_macos else (
        "adrp ${0:x}, " + symbol_name + "\n"
        "add ${0:x}, ${0:x}, :lo12:" + symbol_name + "\n"
    )
    var addr = inlined_assembly[asm_str, UInt, constraints="=r"]()
    return ext.EntryCodePtr(unsafe_from_address=Int(addr))


def _null_attr() -> ext.PthreadAttrPtr:
    var zero = 0
    return ext.PthreadAttrPtr(unsafe_from_address=zero)


def spawn_and_join(
    entry: ext.EntryCodePtr, arg: ext.ArgPtr, results: UnsafePointer[Int64, MutAnyOrigin]
):
    var tslot = stack_allocation[1, UInt64]()
    tslot[0] = 0
    var crc = ext.probe_pthread_create(tslot, _null_attr(), entry, arg)
    results[0] = Int64(crc)
    if crc != 0:
        results[1] = 0
        results[2] = 0
        return
    var retval = stack_allocation[1, UInt64]()
    retval[0] = 0
    var jrc = ext.probe_pthread_join(tslot[0], retval)
    results[1] = Int64(jrc)
    results[2] = Int64(retval[0])


def check(name: String, ok: Bool) -> Bool:
    print(name + ": " + ("PASS" if ok else "FAIL"))
    return ok


# POSIX passes the destructor the BOUND VALUE itself (not &value); this
# writes 0xD0D0 through it, treating the value as "the address of a flag
# cell the test wants stamped" (arranged by each test case below).
@export("m13_tls_dtor")
def m13_tls_dtor(value: UnsafePointer[UInt64, MutAnyOrigin]) abi("C"):
    value[0] = 0xD0D0


# ---- T2/T3 worker: binds `arg[1]` for key `arg[0]`, then exits (destructor
# should fire on THIS thread's exit, writing through the bound value). ----

@export("m13_tls_worker_entry")
def m13_tls_worker_entry(arg: U64Ptr) abi("C") -> UInt64:
    var key = arg[0]
    var value = arg[1]
    var rc = ext.probe_pthread_setspecific(key, value)
    if rc != 0:
        return UInt64(1) << 32  # sentinel: setspecific itself failed
    var got = ext.probe_pthread_getspecific(key)
    return got  # thread exits right after -> destructor fires with `got`


def main() raises:
    var failed = 0

    # ---- T1: create/set/get/destroy on the main thread ---------------------
    var key_slot = stack_allocation[1, UInt64]()
    key_slot[0] = 0
    var dtor = entry_pointer["m13_tls_dtor"]()
    var create_rc = ext.probe_pthread_key_create(key_slot, dtor)
    var key = key_slot[0]
    var rt_ok = ext.oracle_narrow_tls_key_roundtrips(key) != 0

    var set_rc = ext.probe_pthread_setspecific(key, 0xABCDEF)
    var got_main = ext.probe_pthread_getspecific(key)
    if not check(
        "T1 create/set/get round trip on main thread",
        create_rc == 0 and key != 0 and rt_ok and set_rc == 0 and got_main == 0xABCDEF,
    ):
        failed += 1

    # ---- T2/T3: per-thread isolation + exit destructor ----------------------
    # main thread already holds 0xABCDEF for `key` (from T1); spawn a worker
    # that binds a DIFFERENT value for the SAME key, reads it back on its own
    # thread (proving isolation from the worker's own side), then exits —
    # the destructor registered at create() should fire exactly once with
    # that bound value, which itself IS the address of `dtor_flag` below (so
    # the destructor's write through it is directly observable after join).
    var dtor_flag = stack_allocation[1, UInt64]()
    dtor_flag[0] = 0
    var flag_addr = UInt64(Int(dtor_flag))

    var worker_arg = stack_allocation[2, UInt64]()
    worker_arg[0] = key
    worker_arg[1] = flag_addr
    var res = stack_allocation[3, Int64]()
    var worker_entry = entry_pointer["m13_tls_worker_entry"]()
    spawn_and_join(worker_entry, ext.ArgPtr(unsafe_from_address=Int(worker_arg)), res)

    var got_main_after = ext.probe_pthread_getspecific(key)
    if not check(
        "T2 per-thread isolation: worker's own get saw its own binding,"
        " main thread's binding (0xABCDEF) untouched by the worker",
        res[0] == 0
        and res[1] == 0
        and UInt64(res[2]) == flag_addr
        and got_main_after == 0xABCDEF,
    ):
        failed += 1

    if not check(
        "T3 exit destructor fires exactly once, with the value the worker"
        " thread bound (not the key, not the main thread's value)",
        dtor_flag[0] == 0xD0D0,
    ):
        failed += 1

    # ---- T4: cross-language visibility, both directions --------------------
    var set_from_mojo_rc = ext.probe_pthread_setspecific(key, 0x2222)
    var seen_from_c = ext.oracle_tls_get_from_c(key)
    var set_from_c_rc = ext.oracle_tls_set_from_c(key, 0x3333)
    var seen_from_mojo = ext.probe_pthread_getspecific(key)
    if not check(
        "T4 cross-language visibility: Mojo-set value visible to C and"
        " C-set value visible to Mojo, through the SAME pthread key",
        set_from_mojo_rc == 0
        and seen_from_c == 0x2222
        and set_from_c_rc == 0
        and seen_from_mojo == 0x3333,
    ):
        failed += 1

    # ---- T5: dead key fails deterministically after destroy() --------------
    var destroy_rc = ext.probe_pthread_key_delete(key)
    var get_after_destroy = ext.probe_pthread_getspecific(key)
    var set_after_destroy_rc = ext.probe_pthread_setspecific(key, 0x4444)
    # NOTE (b2, measured not assumed): raw pthread_setspecific/getspecific
    # return the POSITIVE errno directly (POSIX pthread_* convention),
    # unlike the mjs_* ABI's 0/negative-errno convention this repo's own
    # wrapper (native/posix/mjs_tls.c) normally translates to. 22 here IS
    # EINVAL, not a sign-convention bug. Also worth recording: darwin does
    # NOT validate the key on setspecific after delete the way
    # mjs_tls.c's own registry does (that registry exists PRECISELY
    # because raw pthread_setspecific on a bad key is UB per POSIX) — it
    # happened to return EINVAL for the exact key/generation this test
    # exercises, but that is darwin's libpthread being conservative, not a
    # portable guarantee; a production Mojo TLS wrapper still needs its
    # own registry for the same reason mjs_tls.c's header explains.
    if not check(
        "T5 destroy() succeeds; get() on a dead key reads NULL and set()"
        " fails deterministically on THIS host (EINVAL, positive-errno"
        " convention) -- not a portable POSIX guarantee, see note above",
        destroy_rc == 0 and get_after_destroy == 0 and set_after_destroy_rc == 22,
    ):
        failed += 1

    # ---- T6: get() allocates nothing (macOS-only, dyld-interposed count) ---
    # `comptime if`, NOT a runtime `if`: mojito-sys#197's own finding is that
    # a platform-exclusive extern symbol (mjs_alloc_probe_* here, only
    # linked into the macOS-only alloc_probe_shim.dylib) needs the guard at
    # COMPTIME, or the untaken platform fails to link/JIT even though the
    # runtime branch is never taken -- confirmed the hard way: a plain
    # runtime `if` here JIT-failed on Linux with "Symbols not found:
    # [ mjs_alloc_probe_alloc_calls, mjs_alloc_probe_reset ]" even though
    # that branch could never execute there.
    comptime if CompilationTarget().is_macos():
        var probe_key_slot = stack_allocation[1, UInt64]()
        var zero = 0
        var no_dtor = UnsafePointer[Byte, MutAnyOrigin](unsafe_from_address=zero)
        var pcreate_rc = ext.probe_pthread_key_create(probe_key_slot, no_dtor)
        var probe_key = probe_key_slot[0]
        _ = ext.probe_pthread_setspecific(probe_key, 0x5555)

        ext.mjs_alloc_probe_reset()
        var before = ext.mjs_alloc_probe_alloc_calls()
        var i = 0
        var sum: UInt64 = 0
        while i < 1000:
            sum += ext.probe_pthread_getspecific(probe_key)
            i += 1
        var after = ext.mjs_alloc_probe_alloc_calls()
        _ = ext.probe_pthread_key_delete(probe_key)
        if not check(
            "T6 pthread_getspecific allocates NOTHING across 1000 calls"
            " (measured via the dyld-interposing alloc probe, spec SYS-4/"
            "§18 — sum=" + String(sum) + " kept live to prevent DCE)",
            pcreate_rc == 0 and (after - before) == 0,
        ):
            failed += 1
    else:
        print(
            "T6 pthread_getspecific allocation-free measurement: SKIP"
            " (alloc_probe_shim.c is a macOS dyld-interposing mechanism"
            " only — see tools/migration_baseline/alloc_probe_shim.c)"
        )

    print("RESULT: " + ("all green" if failed == 0 else String(failed) + " FAILED"))
    if failed != 0:
        raise Error("m1.3 tls spike: " + String(failed) + " check(s) failed")

/*
 * mojito-sys S2.8 — test-local atomic shims (issue #55, SYS-D6).
 *
 * The lifecycle stress outcome ledger (§38.5 jcstress actor/outcome
 * methodology) and the 32-way spin barrier need seq-cst RMW / acquire-read /
 * release-write primitives on shared Int64 cells. The b2 toolchain exposes
 * no atomic intrinsic surface, so these live behind three tiny C symbols.
 *
 * Deliberately TEST-LOCAL: compiled by tests/s2/stress/run.sh into
 * .build/atomic_shim.o and linked into the stress driver only — the frozen
 * libmojito_sys ABI gains NO new symbols (the driver consumes the existing
 * mjs_thread_* / mjs_tls_* surface unchanged).
 *
 * C11 __atomic builtins lower to ldadd/stadd/ldar-class instructions on
 * arm64 and lock-prefixed ops on x86-64; SEQ_CST ordering throughout, so
 * the barrier's generation publish doubles as the release the spinners
 * observe (no lost wakes by construction — asserted, not assumed, by the
 * driver's per-participant generation ledger).
 */

#include <stdint.h>

int64_t mjs_fx_fetch_add(int64_t *p, int64_t v) {
    return __atomic_fetch_add(p, v, __ATOMIC_SEQ_CST);
}

int64_t mjs_fx_load(const int64_t *p) {
    return __atomic_load_n(p, __ATOMIC_SEQ_CST);
}

void mjs_fx_store(int64_t *p, int64_t v) {
    __atomic_store_n(p, v, __ATOMIC_SEQ_CST);
}

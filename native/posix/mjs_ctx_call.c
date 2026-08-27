/*
 * mjs_ctx_call.c — S5.4 (issue #67): dynamic dispatch shim for NativeContext.
 *
 * WHY A C SHIM: the Mojo wrapper needs to resume a caller-supplied entry /
 * finish function whose machine address is a runtime value (opaque cookie).
 * Doing that dispatch from Mojo requires an inline-asm BLR (adrp/add materialized
 * code pointer + `blr`), and that construct crashes the Modular b2 JIT at RUNTIME
 * (documented crash class: "any ldr / indirect branch through generated Mojo
 * inline asm crashes the JIT" — see spike/context_switch/SPIKE_REPORT.md item 5
 * and the S5.4 lane notes). The S1 callback lanes solved the same problem by
 * moving the tables/calls behind a C AB! boundary (SYS-2 C-firewall). This shim
 * does the same: Mojo hands it a raw function address + one pointer argument,
 * and the CALL happens entirely in C. No b2 JIT path, no inline asm in Mojo.
 *
 * Return-value contract (matches every s5-ctx entry point): the shim always
 * succeeds (it is a pure call); it exists only to move the indirect branch out
 * of Mojo-generated code. Zero-arg ABI: fn(void *) called with `arg`.
 *
 * This is the FIRST s5-ctx C symbol that is not part of the frozen record ABI:
 * it is purely additive (a NEW entry point, neither altering nor reading the
 * 200-byte record). exports.txt carries it.
 */
#include <stdint.h>

typedef void (*ctx_call_fn)(void *);

void mjs_ctx_call(uintptr_t fn, uintptr_t arg)
{
    ctx_call_fn f = (ctx_call_fn)fn;
    f((void *)arg);
}

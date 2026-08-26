/*
 * ms_context.c — dispatch half of the frozen ms_context v2 C ABI
 * (issue #64, spec §20.2).
 * The register-level half lives in ms_context_aarch64.S, a single macro
 * skeleton serving both Darwin Mach-O and Linux ELF (S5.2, issue #65).
 * This file owns everything that is portable C:
 *   - the frozen v2 save-area definition, pinned by _Static_asserts to
 *     the offsets the asm hardcodes (regs @0, fps @96, sp @160, 168 B);
 *   - the sideband geometry getters;
 *   - argument validation for the block's only errno-style entry point
 *     (ms_context_init);
 *   - capture-as-self-switch;
 *   - destroy-as-poison (sp slot 0 => the switch traps loudly).
 *
 * The lifecycle still uses the spike's single-threaded return-to
 * bookkeeping (global resume table); replacing it with per-context state
 * is S5.3 (issue #66) and does NOT change this frozen ABI.
 */

#include <mojito_sys.h>

#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

/* Frozen v2 layout — must match the mojito_sys.h s5-ctx block comment and
 * the immediate offsets hardcoded in ms_context_aarch64.S. */
struct ms_context {
    uint64_t regs[12]; /* x19..x30: slot i => x(19+i); [10]=fp, [11]=lr */
    uint64_t fps[8];   /* low 64 bits of callee-saved v8..v15 (d8..d15) */
    uint64_t sp;
};

_Static_assert(sizeof(struct ms_context) == 168,
               "ms_context must be 12 regs + 8 fps + sp = 168 bytes (v2)");
_Static_assert(_Alignof(struct ms_context) == 8,
               "ms_context must be 8-byte aligned");
_Static_assert(offsetof(struct ms_context, regs) == 0,
               "regs[] must be first: asm addresses base+0..88");
_Static_assert(offsetof(struct ms_context, fps) == 96,
               "fps[] must be at +96: asm stp/ldp d8-d15 immediates");
_Static_assert(offsetof(struct ms_context, sp) == 160,
               "sp slot must be at +160: asm immediate");

size_t ms_context_size(void) { return sizeof(struct ms_context); }

size_t ms_context_alignment(void) { return _Alignof(struct ms_context); }

/* Register-level primitives (ms_context_aarch64.S). mjs__ctx_make_raw is
 * dylib-private (private_extern): reachable only through
 * ms_context_init, after validation below. */
extern void mjs__ctx_make_raw(ms_context *ctx, void *stack_top,
                              ms_context_entry entry, void *userdata);

int ms_context_init(ms_context *ctx, void *stack_low, size_t stack_size,
                    ms_context_entry entry, void *userdata) {
    if (ctx == NULL || stack_low == NULL || entry == NULL)
        return -EINVAL;
    /* The synthetic entry needs a 16-byte-aligned initial sp at
     * stack_low + stack_size (AAPCS64); see the s5-ctx header block.
     * stack_low must be 16-aligned too: with a 16-multiple size this
     * makes stack_top aligned, so misalignment traps in mjs__ctx_make_raw
     * instead of returning -EINVAL from the only int-returning API here.
     * KNOWN GAP (panel Systems finding, pre-#66): an adversarial
     * stack_low near SIZE_MAX can wrap stack_top to a wild low address;
     * callers pass real allocations (mjs_stack_alloc), so no overflow
     * check is attempted here. */
    if (stack_size == 0 || (stack_size & 15u) != 0 ||
        (((uintptr_t)stack_low) & 15u) != 0)
        return -EINVAL;
    mjs__ctx_make_raw(ctx, (unsigned char *)stack_low + stack_size, entry,
                      userdata);
    return 0;
}

void ms_context_capture(ms_context *ctx) {
    /* Self-switch saves the live state into ctx and immediately resumes
     * it: control returns right here with a resumable snapshot stored.
     * A NULL ctx is a caller bug (header contract); the switch traps. */
    ms_context_switch(ctx, ctx);
}

void ms_context_destroy(ms_context *ctx) {
    if (ctx == NULL)
        return;
    /* Poison the whole save area: the zeroed sp slot makes any later
     * switch INTO this context trap loudly in the backend. */
    memset(ctx, 0, sizeof(*ctx));
}

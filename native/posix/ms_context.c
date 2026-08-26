/*
 * ms_context.c — dispatch half of the frozen ms_context v2 C ABI
 * (issue #64, spec §20.2).
 * A register-level half lives in ms_context_aarch64.S (a single macro
 * skeleton serving both Darwin Mach-O and Linux ELF; S5.2, issue #65) and,
 * on x86-64 System V targets, in ms_context_x86_64.S (S5.9, issue #72) —
 * the two backends share the exact same frozen layout and primitives, so
 * all of this file's portable C is backend-agnostic. This file owns
 * everything that is portable C:
 *   - the frozen v2 save-area definition plus the v3 lifecycle tail
 *     (#66), pinned by _Static_asserts to the offsets the asm hardcodes;
 *   - the sideband geometry getters;
 *   - argument validation for the block's only errno-style entry point
 *     (ms_context_init);
 *   - capture-as-self-switch;
 *   - destroy-as-poison (state DEAD + sp slot 0 => the switch traps
 *     loudly);
 *   - the per-context finish-hook registry (ms_context_set_finish_hook,
 *     #66).
 *
 * S5.3 (#66): the lifecycle is SELF-CONTAINED per context record — a
 * state machine (DEAD/EMPTY/RUNNING/SUSPENDED/FINISHED) plus its own
 * return target live in each record; the spike's global return-to table
 * and last-from/last-to globals are GONE. Unbounded live contexts, and
 * distinct contexts are thread-independent (one thread at a time PER
 * CONTEXT — caller serializes). This does NOT change the frozen ABI:
 * every v2 offset and contract is preserved prefix-stable.
 */

#include <mojito_sys.h>

#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

/* Per-context lifecycle states (#66) — MUST mirror the MS_STATE_*
 * .set directives in ms_context_aarch64.S. */
enum ms_ctx_state {
    MS_CTX_DEAD = 0,      /* zeroed storage: destroyed or never armed */
    MS_CTX_EMPTY = 1,     /* armed by init/capture, never resumed */
    MS_CTX_RUNNING = 2,   /* currently executing on some OS thread */
    MS_CTX_SUSPENDED = 3, /* suspended mid-life, resumable */
    MS_CTX_FINISHED = 4   /* entry returned; permanent switch-out done */
};

/* Frozen v2 layout — must match the mojito_sys.h s5-ctx block comment and
 * the immediate offsets hardcoded in ms_context_aarch64.S — plus the v3
 * lifecycle tail (#66), which appends AFTER the frozen 168 bytes so every
 * v2 offset stays prefix-stable. */
struct ms_context {
    uint64_t regs[12]; /* x19..x30: slot i => x(19+i); [10]=fp, [11]=lr */
    uint64_t fps[8];   /* low 64 bits of callee-saved v8..v15 (d8..d15) */
    uint64_t sp;
    /* v3 lifecycle tail (#66) — owned by THIS record, no global table */
    uint64_t state;    /* enum ms_ctx_state */
    uint64_t ret_to;   /* most recent switcher (trampoline's exit target) */
    uint64_t finish_cb;/* ms_context_finish_fn (NULL = none) */
    uint64_t finish_ud;/* userdata handed to finish_cb */
};

_Static_assert(sizeof(struct ms_context) ==
                   168 + 4 * sizeof(uint64_t),
               "ms_context must be v2's 168 bytes + 4-slot lifecycle tail "
               "= 200 bytes (v3)");
_Static_assert(_Alignof(struct ms_context) == 8,
               "ms_context must be 8-byte aligned");
_Static_assert(offsetof(struct ms_context, regs) == 0,
               "regs[] must be first: asm addresses base+0..88");
_Static_assert(offsetof(struct ms_context, fps) == 96,
               "fps[] must be at +96: asm stp/ldp d8-d15 immediates");
_Static_assert(offsetof(struct ms_context, sp) == 160,
               "sp slot must be at +160: asm immediate");
_Static_assert(offsetof(struct ms_context, state) == 168 &&
                   offsetof(struct ms_context, ret_to) == 176 &&
                   offsetof(struct ms_context, finish_cb) == 184 &&
                   offsetof(struct ms_context, finish_ud) == 192,
               "lifecycle tail offsets must match ms_context_aarch64.S");
/* S5.9 (#72): x86-64 System V backend. It reuses the SAME frozen v2/v3
 * layout and the SAME dylib-private extern below (the asm files select
 * themselves by target arch; ms_context_x86_64.S is arch-guarded so it is
 * an empty object on non-x86-64 hosts). The v2 prefix pins above therefore
 * hold for both backends unchanged; this guarded assert keeps the pairing
 * with ms_context_x86_64.S explicit without touching the ARM half. */
#if defined(__x86_64__)
_Static_assert(offsetof(struct ms_context, sp) + sizeof(uint64_t) == 168,
               "x86-64 sp slot (rsp) must end exactly at the frozen "
               "168-byte v2 prefix, as ms_context_x86_64.S assumes");
#endif

size_t ms_context_size(void) { return sizeof(struct ms_context); }

size_t ms_context_alignment(void) { return _Alignof(struct ms_context); }

/* Register-level primitives (ms_context_aarch64.S, or
 * ms_context_x86_64.S on x86-64 hosts — #72). mjs__ctx_make_raw is
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
     * The self-switch path arms the record as SUSPENDED regardless of
     * prior state, so capture on destroyed storage REVIVES it (header
     * F4 contract). A NULL ctx is a caller bug (header contract); the
     * switch traps. */
    ms_context_switch(ctx, ctx);
}

void ms_context_set_finish_hook(ms_context *ctx, ms_context_finish_fn hook,
                                void *userdata) {
    if (ctx == NULL)
        return; /* NULL ctx is a caller bug (header block); ignored,
                 * matching ms_context_destroy's NULL case. */
    ctx->finish_cb = (uint64_t)hook;
    ctx->finish_ud = (uint64_t)userdata;
}

void ms_context_destroy(ms_context *ctx) {
    if (ctx == NULL)
        return;
    /* Poison the whole record including the lifecycle tail: state DEAD
     * makes any later switch INTO this context trap loudly in the
     * backend (and zeroes any registered finish hook with it). */
    memset(ctx, 0, sizeof(*ctx));
}

#ifndef MOJITO_SPIKE_H
#define MOJITO_SPIKE_H
#include <stddef.h>
#include <stdint.h>

typedef void (*ms_entry_fn)(void *userdata);

/* Fixed-layout save area consumed by aarch64_switch.S. 13 x 8 bytes = 104. */
typedef struct ms_ctx {
    uint64_t regs[12]; /* x19..x30 (x30=lr); slot i => reg x(19+i) */
    uint64_t sp;
} ms_ctx_t;

int      ms_page_size(void);
/* Reserve `bytes` (rounded up to page multiple) + one PROT_NONE guard page.
 * Out: *out_base (allocation base, guard at [base, base+ps)), *out_top
 * (initial SP = highest usable address, 16-byte aligned). Non-moving. */
int      ms_stack_alloc(size_t bytes, void **out_base, void **out_top);
void     ms_stack_free(void *base);
size_t   ms_stack_total_size(void); /* reserved incl guard, for reporting */

/* Prepare ctx so ms_ctx_switch resumes at entry(userdata) on stack_top,
 * with AAPCS64 prologue assumptions (sp 16-aligned at entry). */
void     ms_ctx_make(ms_ctx_t *ctx, void *stack_top, ms_entry_fn entry, void *userdata);
/* Save current callee-saved state into *from; resume *to. */
void     ms_ctx_switch(ms_ctx_t *from, ms_ctx_t *to);
#endif

# S0 Spike Contract — FROZEN for wave 1

All S0 sub-issue agents (#8–#13) implement against this exact interface.
The header below is the single source of truth; changing it requires a new
issue + re-plan, never a silent edit inside another agent's PR.

## File ownership map (no collisions)

| Owner | Issue | Files |
|---|---|---|
| foundation | #8  | `spike/context_switch/include/mojito_spike.h` (frozen here), `spike/context_switch/native_stack.c`, `Makefile`, `spike/context_switch/selftest.c` |
| asm        | #9  | `spike/context_switch/aarch64_switch.S`, `spike/context_switch/ms_ctx.c` |
| mojo       | #10 | `spike/context_switch/mojito_spike.mojo` |
| tests-a    | #11 | `tests/spike/t[1-7]_*.mojo`, `tests/spike/run.sh` |
| tests-b    | #12 | `tests/spike/t[8-9]_*.mojo`, `tests/spike/t1[0-4]_*.*` |
| bench      | #13 | `benchmark/spike/bench_switch.mojo`, `benchmark/spike/README.md` |

Nobody edits files they do not own. Cross-cutting problems → comment on the
owning issue / coordinate via hub message, not direct edits.

## Frozen C header (`include/mojito_spike.h`)

```c
#ifndef MOJITO_SPIKE_H
#define MOJITO_SPIKE_H
#include <stddef.h>
#include <stdint.h>

typedef void (*ms_entry_fn)(void *userdata);

/* Fixed-layout save area consumed by aarch64_switch.S. 22 x 8 bytes = 176. */
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
```

## aarch64 rules

- Save x19–x28, fp(x29), lr(x30), sp into ms_ctx_t slots in order.
- Return path: restore in reverse, `br x30` semantics via saved lr.
- At `ms_ctx_make` trampoline entry: sp must be 16-byte aligned; place entry
  fn in x19-resident slot or ctx-provided register per implementation, but
  the trampoline MUST end in a tail call to `ms_ctx_exit_trampoline` pattern:
  entry(userdata) then switch back to scheduler ctx (provided via userdata).
- No x18 writes (platform register, reserved on Apple platforms).
## Mojo bindings (`mojito_spike.mojo`) — AMENDED per #16

The C ABI above is unchanged. The Mojo-side declarations below were written
against an assumed API and DO NOT compile on 1.0.0b2. Issue #10 owns the
b2-legal formulation (origin parameters on UnsafePointer, `def` signatures,
`std.` module paths, and the entry-callback mechanism) and MUST record what
it discovers in SPIKE_REPORT.md under "Observed Mojo/compiler assumptions".
Until #10 lands, tests/bench lanes code against these names and shapes,
expecting red:

```mojo
alias LIB := "libmojito_spike.dylib"
def ms_page_size() -> Int32
def ms_stack_alloc(bytes: Int, out_base, out_top) -> Int32
def ms_stack_free(base)
def ms_stack_total_size() -> Int
def ms_ctx_make(ctx, stack_top, entry, userdata)
def ms_ctx_switch(from_, to)
```


## Workflow (every agent)

1. Branch `git checkout -b s0/<name>` off latest `main`.
2. **Commit 1: red tests only** (tests fail to compile/pass because impl is
   absent) → push → open PR titled `WIP(s0/<name>): red tests — <issue>` with
   `tdd-red,wip` labels. Reference the issue number.
3. Implement owned files until `make -C tests/spike run` (or bench target)
   passes locally. Push commits.
4. Remove `wip` label when green; request panel review.
5. Merge happens centrally after the 5-expert adversarial panel; fold any
   blocking feedback as new commits on your branch.
6. Discovered incidental bug you can fix in <50 lines total → fix it inside
   your current PR (note it in the body). ≥50 lines or design-level → open an
   issue immediately, do NOT fix, continue your lane.

## Verification commands

```sh
make            # builds libmojito_spike.dylib + selftest
make selftest   # runs C-level selftest
make test       # runs tests/spike/run.sh (all green mojo tests)
make bench      # benchmark/spike
```

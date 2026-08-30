"""mojito_sys.ctx - cooperative machine-context switching (S5.4, issue #67).

Spec §20 `NativeContext`: direct machine-context switching independent of any
scheduling policy, as a pure Mojo wrapper over the frozen ms_context_* C ABI
(native/include/mojito_sys.h, `s5-ctx` block) plus the single additive
dispatch shim mjs_ctx_call (SYS-2 C-firewall):

  NativeContext.create(stack_low, stack_top, entry, userdata)  — prepare a
      synthetic-stack context over a NativeStack reservation (spec §20.1;
      b2 adaptation: the caller passes stack.guard_low_address() and
      stack.top_address() and keeps the reservation alive);
  NativeContext.capture_current()  — arm a context from the CURRENT execution
      state;
  NativeContext.switch(from, to)   — save `from`, resume `to`; allocation-free
      (spec §20.1);
  destroy(mut) / re_capture(mut)   — poison storage / revive it (spec §20:
      capture revives destroyed storage);
  set_finish_hook(mut, hook, userdata) — exactly-once completion hook
      (issue #66 lifecycle semantics);
  context_size() / context_alignment() — frozen record geometry.

Wrapper lifecycle + trap mapping: the C layer hard-traps on misuse (re-resume
of finished/destroyed/running contexts); the wrapper tracks a Mojo-view state
and raises a decoded, recoverable Error on the misuse classes it can see
before crossing into C (DEAD/FINISHED/self-switch, double-destroy).

Zero changes to the frozen record ABI: this package is pure Mojo over the
frozen ms_context_* ABI plus the one additive dispatch shim (mjs_ctx_call).
"""

from mojito_sys.ctx.context import (
    NativeContext,
    context_size,
    context_alignment,
    entry_pointer,
    ST_DEAD,
    ST_ARMED,
    ST_RUNNING,
    ST_SUSPENDED,
    ST_FINISHED,
)
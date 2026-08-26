# mojito-sys S5.4 — NativeContext: cooperative machine-context switching API
# (issue #67, spec §20).
#
# A PURE Mojo wrapper over the frozen ms_context_* C ABI
# (native/include/mojito_sys.h, `s5-ctx` block): no new C symbols. Exposes
# spec §20's NativeContext surface:
#
#   NativeContext.create(stack, entry, userdata)  — init a synthetic-stack
#                                                   context over a NativeStack
#                                                   reservation;
#   NativeContext.capture_current()               — arm a context from the
#                                                   current execution state;
#   NativeContext.switch(from, to)                — save `from`, resume `to`
#                                                   (allocation-free);
#   destroy(mut)  / re_capture(mut)               — poison / revive storage;
#   set_finish_hook(mut, hook, userdata)          — completion hook (once);
#   context_size() / context_alignment()          — record geometry.
#
# STATE TRACKING + TRAP MAPPING (#67): the C layer enforces its per-context
# lifecycle (DEAD/EMPTY/RUNNING/SUSPENDED/FINISHED) with HARD traps on misuse
# (re-resume of finished/destroyed/running contexts). Those C traps would kill
# the process, so the WRAPPER ALSO tracks a Mojo-view lifecycle in its own heap
# cookie and raises a decoded, recoverable Error on the misuse classes it can
# see before crossing into C:
#   - switching into a destroyed (DEAD) context   -> raises  (C traps);
#   - switching into a finished (FINISHED) ctx    -> raises  (C traps);
#   - switching a context into itself (RUNNING)   -> raises  (C traps);
#   - destroy() on an already-dead context        -> raises.
# Cross-thread RUNNING misuse (a context executing on another OS thread) is
# genuinely undetectable from the wrapper and remains the C hard trap
# (documented deviation — spec §20.2's "thread-safety: per-context exclusivity").
#
# DISPATCH MECHANISM (b2): the frozen entry_t is a raw C function pointer
# `void (*)(void *)`. b2 cannot cast a Mojo function to a code pointer, so the
# wrapper registers ONE @export abi("C") trampoline (mjs_ctx_entry /
# mjs_ctx_finish) as the C entry/hook, and dispatches to the CALLER's own
# @export abi("C") entry/finish functions through the caller-supplied code
# address stored in the per-context cookie. Dynamic dispatch uses one inline-
# asm BLR with code+arg carried as REGISTER OPERANDS (never `ldr` inside the
# asm — a documented b2 JIT crash, spike/context_switch/SPIKE_REPORT.md item 5:
# "JIT crashes ... on any ldr in inline asm").
#
# b2 conventions (matching mojito_sys/sync/mutex.mojo / io/socket.mojo):
#   - def-only members; construction via @staticmethod factories; a public
#     `_adopt` internal-plumbing reconstructor (the NativeSocket._adopt
#     precedent) lets entry trampolines rebuild a NativeContext value from raw
#     record/cookie addresses.
#   - Record + cookie are heap blocks (`std.memory.alloc`, leaked then freed
#     via `.free()` on drop — Pointer.free is the b2-clean release path);
#     addressed ONLY by scalar Int indexing (byval-poison doctrine), never as
#     aggregate values across an extern frame.
#   - Misuse raises funnel through raise_errno(rc) with CONSTANT payloads
#     (single-raise-site doctrine, issue #29/#30; no String literals through
#     control-flow merges).
#   - The stack must be a live NativeStack whose usable span [guard_low, top)
#     is 16-byte aligned and a nonzero multiple of 16 (AAPCS64, ms_context_init
#     contract); violations raise decoded -EINVAL.

from std.memory import UnsafePointer
from std.memory.alloc import alloc, Layout
from std.sys.intrinsics import inlined_assembly

from mojito_sys.abi.errors import raise_errno
from mojito_sys.memory.stack import NativeStack
import mojito_sys.ctx.externs as _externs

comptime CTX_PTR = UnsafePointer[NoneType, MutUntrackedOrigin]
comptime INT_PTR = UnsafePointer[Int, MutAnyOrigin]
comptime BYTE_PTR = UnsafePointer[Byte, MutAnyOrigin]

# ---- wrapper cookie (heap Int cells) ---------------------------------------
# The cookie is the opaque `userdata` the wrapper passes to ms_context_init,
# so the C ABI hands it UNMODIFIED to the entry trampoline AND the finish hook.
comptime COOKIE_NWORDS = Int(16)
comptime C_ENTRY = Int(0)      # caller entry code address
comptime C_ARG = Int(1)        # caller userdata (passed through to entry)
comptime C_STATE = Int(2)      # wrapper lifecycle (see ST_*)
comptime C_HOOK = Int(3)       # caller finish-hook code address (0 = none)
comptime C_HOOK_ARG = Int(4)   # caller finish-hook userdata
comptime C_STAMP = Int(5)      # finish-stamp (exactly-once observable)
comptime C_MAGIC = Int(7)      # sanity marker (0x5E71C771)
comptime COOKIE_MAGIC = Int(0x5E71C771)

# ---- wrapper lifecycle states (Mojo view mapped from the C hard-traps) -----
comptime ST_DEAD = Int(0)
comptime ST_ARMED = Int(1)
comptime ST_RUNNING = Int(2)
comptime ST_SUSPENDED = Int(3)
comptime ST_FINISHED = Int(4)

# Deterministic misuse code carried as a decoded -EINVAL raise.
comptime EINVAL_RC = Int32(-22)


# Materialize the machine address of an @export'ed abi("C") Mojo function as a
# raw C function pointer (the spike-proven adrp/add mechanism #10). `name` is
# the @export name WITHOUT the Mach-O underscore prefix.
def entry_pointer[name: String]() -> BYTE_PTR:
    comptime asm_str = (
        "adrp ${0:x}, _" + name + "@PAGE\n"
        "add ${0:x}, ${0:x}, _" + name + "@PAGEOFF\n"
    )
    var addr = inlined_assembly[asm_str, UInt, constraints="=r"]()
    return BYTE_PTR(unsafe_from_address=Int(addr))


# ---- dynamic dispatch (single inline-asm BLR; operands, never `ldr`) -------
# Calls code(arg) with AAPCS64 (arg in x0, target in a scratch register). The
# code and arg are loaded by Mojo BEFORE the asm and travel as register
# operands, so no `ldr` appears inside inline assembly (b2 JIT crash, item 5).
def _call_fn(code: Int, arg: Int):
    # Dynamic dispatch behind the C firewall (SYS-2, S1-callback-lane
    # precedent): the b2 JIT crashes at RUNTIME on an indirect branch
    # generated by Mojo inline asm (reproduced deterministically in this
    # lane — the real-switch conformance died in the JIT with a Stack dump).
    # native/posix/mjs_ctx_call.c performs fn(arg) in plain C; probe_ctx_call
    # is the non-raising leaf in externs.mojo so the abi("C") entry
    # trampolines can use it on the synthetic stack.
    _externs.probe_ctx_call(code, arg)


# ---- the two wrapper C-entry trampolines (run on the synthetic stack) ------
# mjs_ctx_entry: called by the C trampoline as entry(cookie); dispatches to the
# caller's entry(userdata). When the caller entry RETURNS, this returns, and
# the C completion stage runs the registered finish hook.
@export("mjs_ctx_entry")
def mjs_ctx_entry(cookie_arg: CTX_PTR) abi("C"):
    var c = INT_PTR(unsafe_from_address=Int(cookie_arg))
    c[C_STATE] = ST_RUNNING
    _call_fn(c[C_ENTRY], c[C_ARG])


# mjs_ctx_finish: the C-registered finish hook; runs AFTER the caller entry
# returned (exactly once per completed lifetime). Marks the wrapper state,
# stamps completion, and dispatches to the caller's optional finish hook.
@export("mjs_ctx_finish")
def mjs_ctx_finish(cookie_arg: CTX_PTR) abi("C"):
    var c = INT_PTR(unsafe_from_address=Int(cookie_arg))
    c[C_STATE] = ST_FINISHED
    c[C_STAMP] = c[C_STAMP] + 1
    var hc = c[C_HOOK]
    if hc != 0:
        _call_fn(hc, c[C_HOOK_ARG])


# Sideband geometry of the frozen caller-owned save area.
def context_size() -> Int:
    return Int(_externs.probe_ctx_size())


def context_alignment() -> Int:
    return Int(_externs.probe_ctx_alignment())


# ---- record / cookie heap helpers ------------------------------------------
def _record_words() -> Int:
    var n = (context_size() + 7) // 8
    if n < 1:
        n = 1
    return n


def _alloc_cookie() -> INT_PTR:
    var ptr = alloc(Layout[Int](count=COOKIE_NWORDS)).unsafe_leak()
    var c = INT_PTR(unsafe_from_address=Int(ptr))
    var i = 0
    while i < COOKIE_NWORDS:
        c[i] = 0
        i += 1
    c[C_MAGIC] = COOKIE_MAGIC
    return c


def _alloc_record() -> INT_PTR:
    var ptr = alloc(Layout[Int](count=_record_words())).unsafe_leak()
    return INT_PTR(unsafe_from_address=Int(ptr))


def _byte_of(p: INT_PTR) -> BYTE_PTR:
    return BYTE_PTR(unsafe_from_address=Int(p))


# ---------------------------------------------------------------------------
# NativeContext
# ---------------------------------------------------------------------------
struct NativeContext(Movable):
    """A caller-owned machine context (spec §20).

    Owns two heap blocks: the frozen ms_context record (ms_context_size()
    bytes) and an internal wrapper cookie (lifecycle + dispatch). BOTH are
    freed on drop; `destroy()` does NOT free them (it only poisons the state —
    matching the frozen contract that destroy "does not free the caller's
    storage"), so `re_capture()` can revive them afterwards.

    Ownership (spec §25-style): move (^) transfers the blocks; the source
    drops inert. `destroy()` raises on a destroyed context; a moved-from value
    reads DEAD.
    """

    var record: INT_PTR
    var cookie: INT_PTR
    var live: Bool

    def __init__(out self):
        var z = 0
        self.record = INT_PTR(unsafe_from_address=z)
        self.cookie = INT_PTR(unsafe_from_address=z)
        self.live = False

    def __moveinit__(mut self, mut existing: Self):
        self.record = existing.record
        self.cookie = existing.cookie
        self.live = existing.live
        existing.live = False

    def __deinit__(deinit self):
        if self.live:
            self.record.free()
            self.cookie.free()
            self.live = False

    # Rebuild a NativeContext from raw record/cookie addresses. INTERNAL
    # plumbing (mirrors NativeSocket._adopt): lets entry trampolines holding
    # address-only handles reconstruct a value on the synthetic stack.
    @staticmethod
    def _adopt(record: INT_PTR, cookie: INT_PTR) -> NativeContext:
        var n = NativeContext()
        n.record = record
        n.cookie = cookie
        n.live = True
        return n^

    def record_address(self) -> Int:
        return Int(self.record)

    def cookie_address(self) -> Int:
        return Int(self.cookie)

    # ---- lifecycle accessors (wrapper cookie) ------------------------------
    def state(self) -> Int:
        if not self.live or Int(self.cookie) == 0:
            return ST_DEAD
        return self.cookie[C_STATE]

    def is_live(self) -> Bool:
        return self.state() != ST_DEAD

    # ---- record geometry ---------------------------------------------------
    @staticmethod
    def context_size() -> Int:
        return Int(_externs.probe_ctx_size())

    @staticmethod
    def context_alignment() -> Int:
        return Int(_externs.probe_ctx_alignment())

    # ---- constructors ------------------------------------------------------
    @staticmethod
    def capture_current() raises -> NativeContext:
        """Arm a context from the CURRENT execution state (spec §20
        capture_current). A later switch(to = ctx) resumes right after this
        call. Never raises (void C entry), but declared raises to match the
        surface's uniform contract."""
        var cookie = _alloc_cookie()
        cookie[C_STATE] = ST_SUSPENDED
        var record = _alloc_record()
        _externs.probe_ctx_capture(_byte_of(record))
        return NativeContext._adopt(record, cookie)

    @staticmethod
    def create(
        stack_low: Int,
        stack_top: Int,
        entry_fn: BYTE_PTR,
        userdata: CTX_PTR,
    ) raises -> NativeContext:
        """Prepare ctx to resume at the caller entry (entry_fn(userdata)) on
        top of a fresh synthetic stack carved from [stack_low, stack_top) —
        the STACK geometry of a live NativeStack reservation (spec §20
        create; guard_low_address()/top_address()). b2 adaptation: the
        struct itself is NOT passed (a by-value NativeStack would drop and
        free the reservation; borrow/ref params are unsupported b2
        syntax), so the CALLER passes stack.guard_low_address() and
        stack.top_address() and keeps the reservation alive for the
        context's lifetime. RAISES decoded -EINVAL on a misaligned or
        non-16-multiple span; env errors raise decoded errno. Registering
        the wrapper finish trampoline is what lets the wrapper observe
        completion."""
        var stack_size = stack_top - stack_low
        if stack_size <= 0 or (stack_size % 16) != 0 or (stack_low % 16) != 0:
            raise_errno(EINVAL_RC)
        var cookie = _alloc_cookie()
        cookie[C_STATE] = ST_ARMED
        cookie[C_ENTRY] = Int(entry_fn)
        cookie[C_ARG] = Int(userdata)
        var record = _alloc_record()
        var rc = _externs.probe_ctx_init(
            _byte_of(record),
            stack_low,
            UInt64(stack_size),
            entry_pointer["mjs_ctx_entry"](),
            Int(cookie),
        )
        if rc != 0:
            raise_errno(rc)
        # Register the wrapper completion hook: it marks the record FINISHED
        # and dispatches to the caller's hook (set via set_finish_hook).
        _externs.probe_ctx_set_finish_hook(
            _byte_of(record),
            entry_pointer["mjs_ctx_finish"](),
            Int(cookie),
        )
        return NativeContext._adopt(record, cookie)

    # ---- switching ---------------------------------------------------------
    @staticmethod
    def switch(from_context: NativeContext, to_context: NativeContext) raises:
        """Save the CURRENT execution state into `from` and resume `to` (spec
        §20 switch). Allocation-free (SYS-4/SYS-5). RAISES decoded -EINVAL on
        wrapper-visible misuse: switching into a destroyed (DEAD) or finished
        (FINISHED) context, or into the SAME context it leaves (RUNNING).
        Both records stay heap-owned, so passing values by copy is safe."""
        var to_state = to_context.state()
        if to_state == ST_DEAD:
            raise_errno(EINVAL_RC)
        if to_state == ST_FINISHED:
            raise_errno(EINVAL_RC)
        if Int(from_context.record) == Int(to_context.record):
            raise_errno(EINVAL_RC)
        from_context.cookie[C_STATE] = ST_SUSPENDED
        to_context.cookie[C_STATE] = ST_RUNNING
        _externs.probe_ctx_switch(_byte_of(from_context.record), _byte_of(to_context.record))

    # ---- lifecycle mutation ------------------------------------------------
    def destroy(mut self) raises:
        """Render ctx unusable: a destroyed context raises DEAD on resume.
        Does NOT free the caller's storage (frozen contract) — `re_capture`
        can revive it. RAISES on a second destroy."""
        if self.state() == ST_DEAD:
            raise_errno(EINVAL_RC)
        _externs.probe_ctx_destroy(_byte_of(self.record))
        self.cookie[C_STATE] = ST_DEAD
        self.cookie[C_HOOK] = 0  # destroy discards any registered hook

    def re_capture(mut self) raises:
        """Revive destroyed-or-finished storage by capturing the CURRENT state
        into it (spec §20: capture revives destroyed storage). After
        re_capture the record reads SUSPENDED again. RAISES on a moved-from
        value."""
        if not self.live:
            raise_errno(EINVAL_RC)
        _externs.probe_ctx_capture(_byte_of(self.record))
        self.cookie[C_STATE] = ST_SUSPENDED

    # ---- completion hook ---------------------------------------------------
    def set_finish_hook(mut self, hook: BYTE_PTR, userdata: CTX_PTR) raises:
        """Register the context's completion hook (issue #66 semantics): after
        the entry returns, hook(userdata) runs exactly once. The wrapper's own
        completion trampoline is already C-registered (at create), so this just
        records the caller's hook in the cookie. A hook registered after the
        context has already finished never fires (the completion pass already
        ran); destroy discards any registered hook. RAISES on a destroyed
        context."""
        if self.state() == ST_DEAD:
            raise_errno(EINVAL_RC)
        self.cookie[C_HOOK] = Int(hook)
        self.cookie[C_HOOK_ARG] = Int(userdata)

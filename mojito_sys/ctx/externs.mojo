# mojito-sys S5.4 — raw ms_context_* FFI bindings (issue #67, spec §20.2).
#
# LEAF MODULE (b2 WORKAROUND precedent #49): this file deliberately contains
# ONLY @extern declarations and the comptime pointer aliases + non-raising
# probe_* shims they need — no imports, no structs, no raise sites. b2
# 1.0.0b2's cross-module lowering misbinds extern call arguments when the
# DECLARING module also hosts Movable structs and/or raising machinery (same
# proven shape as mojito_sys/io/externs.mojo and mojito_sys/sync/externs.mojo).
#
# NEVER-INLINE INVARIANT: the probe_* shims below are the ONLY sanctioned call
# path into the frozen ms_context_* bindings and MUST stay tiny, non-raising,
# aggregate-free, and free of @always_inline at every call site. These symbols
# are NOT for caller use; prefer mojito_sys/ctx/context.mojo (NativeContext).
#
# AGGREGATE RULE: no Mojo-side aggregate is ever READ inside an extern-reaching
# frame. The frozen ms_context record (ms_context_size() bytes of caller-owned
# storage) is addressed SCALAR-ly via the record's Int cells — it never crosses
# the ABI as an aggregate value, only as a raw address.

# Opaque context record / callback / byte buffers crossing as raw addresses.
comptime ByteBuf = UnsafePointer[Byte, MutAnyOrigin]

# stack_low / userdata ride as raw 64-bit addresses (void*).
comptime Addr = Int


@extern("ms_context_size")
def ms_context_size() abi("C") -> UInt64:
    ...


@extern("ms_context_alignment")
def ms_context_alignment() abi("C") -> UInt64:
    ...


@extern("ms_context_init")
def ms_context_init(
    ctx: ByteBuf,
    stack_low: Addr,
    stack_size: UInt64,
    entry: ByteBuf,
    userdata: Addr,
) abi("C") -> Int32:
    ...


@extern("ms_context_capture")
def ms_context_capture(ctx: ByteBuf) abi("C"):
    ...


@extern("ms_context_switch")
def ms_context_switch(from_ctx: ByteBuf, to_ctx: ByteBuf) abi("C"):
    ...


@extern("ms_context_destroy")
def ms_context_destroy(ctx: ByteBuf) abi("C"):
    ...


@extern("ms_context_set_finish_hook")
def ms_context_set_finish_hook(ctx: ByteBuf, hook: ByteBuf, userdata: Addr) abi("C"):
    ...


# ---- non-raising call shims (leaf-module boundary) --------------------------
#
# Every ms_context_* invocation happens HERE, in the pure leaf, returning the
# raw C result; mojito_sys.ctx.context decodes/raises only afterwards.

def probe_ctx_size() -> UInt64:
    return ms_context_size()


def probe_ctx_alignment() -> UInt64:
    return ms_context_alignment()


def probe_ctx_init(
    ctx: ByteBuf,
    stack_low: Addr,
    stack_size: UInt64,
    entry: ByteBuf,
    userdata: Addr,
) -> Int32:
    return ms_context_init(ctx, stack_low, stack_size, entry, userdata)


def probe_ctx_capture(ctx: ByteBuf):
    ms_context_capture(ctx)


def probe_ctx_switch(from_ctx: ByteBuf, to_ctx: ByteBuf):
    ms_context_switch(from_ctx, to_ctx)


def probe_ctx_destroy(ctx: ByteBuf):
    ms_context_destroy(ctx)


def probe_ctx_set_finish_hook(ctx: ByteBuf, hook: ByteBuf, userdata: Addr):
    ms_context_set_finish_hook(ctx, hook, userdata)

@extern("mjs_ctx_call")
def mjs_ctx_call(fn: Addr, arg: Addr) abi("C"):
    ...


def probe_ctx_call(fn: Addr, arg: Addr):
    mjs_ctx_call(fn, arg)

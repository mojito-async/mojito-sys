# mojito-sys S2.4 — NativeTlsKey: spec §12 TLS key over the frozen
# mjs_tls_* C ABI (issue #51, native layer #50).
#
# A key is an opaque nonzero uintptr_t minted by mjs_tls_create; it stays
# valid in every OS thread until destroy() and is NEVER reused, so a stale
# handle can never alias a newer key. Bindings are per (key, thread): each
# thread sees only its own value, NULL when unset.
#
# First-consumer contract (spec L888-893): a pointer-sized handle per
# thread for current_worker / current_task / current_scope WITHOUT private
# runtime APIs. There are deliberately NO module-level mutable globals —
# the key instance lives in the owner struct and is passed by value; b2
# forbids module-level mutable state anyway.
#
# Binding notes (Mojo 1.0.0b2, matching mojito_sys/memory conventions):
#   - External symbols are declared with `@extern("<c_symbol>")` plus an
#     explicit `abi("C")` effect and a `...` body; the library is chosen at
#     link time (`-Xlinker libmojito_sys.dylib`). The raw mjs_tls_* names
#     exist because b2 cannot scope @extern declarations lexically — keep
#     them at arm's length in user code and prefer the NativeTlsKey methods.
#   - The destructor parameter is a raw CODE ADDRESS (ms_callback §8 shape,
#     void (*)(void *)): exactly what pthread_key_create consumes. b2 has
#     no function-pointer type; callers materialize one from their own
#     @export abi("C") function (spike entry_pointer pattern) or pass null.
#   - Raising goes through the straight-line raise_errno helper
#     (mojito_sys/abi/errors); every method here keeps EXACTLY ONE raise
#     site fed straight from the C return code.
#
# SCALABILITY CEILING — read before gating anything hot on this module
# (mirrors the design note atop native/posix/mjs_tls.c): the C layer holds
# ONE GLOBAL registry mutex across EVERY key operation on EVERY thread,
# INCLUDING reads (get validates the key under the lock). This wrapper is
# correct and race-safe, but per-task-transition hot reads from the
# current_worker/current_task/current_scope consumers would turn that lock
# into a global contention point. Do NOT gate hot-path consumers on this
# surface until the C layer's reads go sharded / epoch-tagged lock-free
# (the monotonic key ids already carry generation bits). Revisit when a
# hot-path consumer lands or get() shows up in contention profiles.
#
# Link with: mojo run -I <repo-root> -Xlinker <libmojito_sys.dylib>

from mojito_sys.abi.errors import raise_errno
from std.memory import stack_allocation


# A bound TLS VALUE as it travels through get()/set(): a raw address Mojo
# does not track or dereference (`MutUntrackedOrigin`, spec §12 signature).
# Callers rebuild their typed pointer from `.get()` via the kw-only
# `unsafe_from_address=` form against the returned address.
comptime TlsValuePtr = UnsafePointer[NoneType, MutUntrackedOrigin]

# A destructor CODE ADDRESS (ms_callback §8: void (*)(void *)). MutAnyOrigin:
# the address originates inside this process's own code, but nothing here
# ever dereferences it.
comptime TlsDtorPtr = UnsafePointer[NoneType, MutAnyOrigin]


@extern("mjs_tls_create")
def mjs_tls_create(
    destructor: TlsDtorPtr,
    out_key: UnsafePointer[UInt, MutAnyOrigin],
) abi("C") -> Int32:
    ...


@extern("mjs_tls_get")
def mjs_tls_get(key: UInt) abi("C") -> TlsValuePtr:
    ...


@extern("mjs_tls_set")
def mjs_tls_set(key: UInt, value: TlsValuePtr) abi("C") -> Int32:
    ...


@extern("mjs_tls_destroy")
def mjs_tls_destroy(key: UInt) abi("C") -> Int32:
    ...


# Module factory ALIAS (spec §12 spells creation as @staticmethod
# NativeTlsKey.create(); b2 supports raising staticmethods returning Self
# repo-wide — 27 documented sites, e.g. MonotonicInstant.now()). Retained
# as a thin documented alias for call-site stability, mirroring
# monotonic_now() in mojito_sys/time.
def create_tls_key(destructor: TlsDtorPtr) raises -> NativeTlsKey:
    return NativeTlsKey.create(destructor)


struct NativeTlsKey(ImplicitlyCopyable):
    # The public nonzero key id (uintptr_t). Monotonic, never reused;
    # validated by the C registry on every use. Public by contract: owners
    # pass the id (not the struct) to worker threads, which re-adopt it via
    # NativeTlsKey(id) — no shared mutable handle anywhere.
    var key: UInt

    # Adopt an ALREADY-MINTED key id (advanced/raw use): the handle-passing
    # path for threads that were given only the id. No validation happens
    # here — the C registry rejects dead ids deterministically (-EINVAL /
    # NULL) on every operation.
    def __init__(out self, key_id: UInt):
        self.key = key_id

    # Mint a TLS key whose per-thread values are passed to `destructor`
    # (a raw ms_callback code address; null = no destructor) exactly once at
    # each binding thread's exit with that thread's bound value. POSIX semantics
    # inherited from the C layer: a destructor does NOT fire for values still
    # bound when the key is destroyed — callers tearing down a key with
    # cross-thread bindings own draining those threads first.
    #
    # Blocking (SYS-5): may block briefly on the C layer's global registry mutex
    # and inside pthread_key_create (see the ceiling note above — acceptable at
    # create frequency, NOT a hot-path op).
    # Allocation: one stack scratch slot for the out-key (no heap allocation);
    # the C side may grow its key registry (one realloc) under the lock.
    # Task-aware: no — bindings are OS-thread-scoped, never task-scoped.
    @staticmethod
    def create(destructor: TlsDtorPtr) raises -> Self:
        var out_key = stack_allocation[1, UInt]()
        var rc = mjs_tls_create(destructor, out_key)
        if rc != 0:
            raise_errno(rc)
        return NativeTlsKey(out_key[])

    # This CALLING thread's value for the key; the zero address when unset
    # or when the key is invalid/dead. Rebuild your typed pointer from the
    # returned address via kw-only unsafe_from_address.
    #
    # Zero-allocation (SYS-4 names TLS reads as must-not-allocate): a single
    # extern call, no scratch, no raise.
    # Blocking (SYS-5): holds the C layer's global registry mutex across a
    # brief key-validation critical section (may wait under contention);
    # pthread_getspecific itself does not block. Ceiling note above: this is
    # the read that must go sharded before any hot-path consumer gates here.
    # Task-aware: no.
    def get(self) -> TlsValuePtr:
        return mjs_tls_get(self.key)

    # Bind `value` for this key in the CALLING thread. Raises the decoded
    # errno (EINVAL for a dead/never-minted key) through the raise_errno
    # funnel — including use-after-destroy through any stale alias of this
    # handle: ids are never reused, so the C registry detects them without
    # ambiguity.
    #
    # Blocking (SYS-5): holds the global registry mutex across a brief
    # validate-then-set critical section (may wait under contention).
    # Allocation: none (SYS-4).
    # Task-aware: no.
    def set(self, value: TlsValuePtr) raises:
        var rc = mjs_tls_set(self.key, value)
        if rc != 0:
            raise_errno(rc)

    # Delete the key. CONSUMES this handle: b2 has no user-defined consuming
    # convention outside dunders (spec L881's `destroy(mut self)` is the
    # expressible form), so consumption is enforced at runtime — on success
    # the handle's id is zeroed, and ids are NEVER reused by the C registry,
    # so EVERY later use through this handle or any pre-destroy alias is a
    # deterministic decoded -EINVAL raise (or a null get()), never aliasing
    # a newer key.
    #
    # Blocking (SYS-5): holds the global registry mutex across a brief
    # validate-and-retire critical section, released BEFORE pthread_key_delete
    # runs in C (no host call under the lock).
    # Allocation: none.
    # Task-aware: no.
    def destroy(mut self) raises:
        var rc = mjs_tls_destroy(self.key)
        if rc != 0:
            raise_errno(rc)
        self.key = 0

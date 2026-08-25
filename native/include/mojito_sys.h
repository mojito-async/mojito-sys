#ifndef MOJITO_SYS_H
#define MOJITO_SYS_H

#include <stddef.h>
#include <stdint.h> /* uintptr_t (s2-tls keys) — additive, issue #50 */

/*
 * mojito-sys S1 — frozen C ABI (issue #24): page / VM / stack services.
 *
 * S1 contract:
 *   - Live stack addresses never move. Once a stack region is allocated and
 *     committed, its usable range is stable for the lifetime of the binding;
 *     mjs_stack_free returns it wholesale. (No stack growth/shrink in S1.)
 *   - Every stack region carries guard_bytes (a POSITIVE page multiple) of
 *     PROT_NONE at the LOW end of the reservation (below *out_guard_low).
 *     Crossing it is a hard fault by design. guard_bytes == 0 or a non-page
 *     multiple is an error (-EINVAL).
 *   - Compatibility: the signatures and semantics below are frozen for the
 *     S1 milestone. Extending the ABI means adding new names, never changing
 *     these declarations. The ABI version is MOJITO_SYS_ABI_VERSION.
 *   - mjs_page_size / mjs_granularity are informational. Byte counts passed
 *     to commit/decommit/protect must be positive page multiples by the
 *     caller (validated where cheap; undefined results otherwise).
 *   - Concurrency: these primitives are NOT thread-safe on a shared region.
 *     A reservation/stack region is single-owner; serialize concurrent use
 *     of the same region (or its cursor) by the caller.
 *
 * Return-value contract (all entry points):
 *   0 == success; negative == -errno (e.g. -ENOMEM, -EINVAL, -EFAULT).
 *   Out-parameters are UNTOUCHED on failure.
 */

#define MOJITO_SYS_ABI_VERSION 1

/* Protection flags, opaque at this boundary. Map 1:1 to POSIX PROT_* today;
 * the Mojo layer translates to platform-specific bits. */
#define MJS_PROT_NONE  0x00
#define MJS_PROT_READ  0x01
#define MJS_PROT_WRITE 0x02
#define MJS_PROT_EXEC  0x04

#ifdef __cplusplus
extern "C" {
#endif

/* Host page size (sysconf(_SC_PAGESIZE)); > 0. */
int mjs_page_size(void);

/* Standardized native callback shape (spec §8): a C-ABI function pointer
 * plus an opaque userdata pointer, transported as one two-word token. */
typedef void (*ms_callback)(void *userdata);
typedef struct mjs_callback_token {
    void *addr;      /* ms_callback code address; NULL = none */
    void *userdata;  /* opaque, passed through unmodified */
} mjs_callback_token;

/* Allocation granularity for reservations; >= page size. */
int mjs_granularity(void);

/* ABI version of this library. Consumers that dynload the dylib SHOULD
 * call this and reject MOJITO_SYS_ABI_VERSION mismatches. */
int mjs_abi_version(void);

/* Reserve `bytes` (rounded up to granularity) of address space without
 * committing physical memory (mmap NORESERVE-equivalent). On success returns
 * 0, stores the reservation base in *out_base and the exact reserved size in
 * *out_reserved. */
int mjs_vm_reserve(size_t bytes, void **out_base, size_t *out_reserved);

/* Make `length` bytes at *addr accessible (back the pages; the POSIX
 * mechanism is mprotect/mmap-modifying; NOT mlock: no physical-frame
 * pinning). `length` must be a positive page multiple.
 * On full success *addr advances to the first byte past the committed range.
 * On failure *addr is unchanged (atomic: 0-or-length). The implementation
 * does not validate the range against any reservation — the caller owns the
 * cursor and must keep it inside a live reservation. */
int mjs_vm_commit(unsigned char **addr, size_t length);

/* Make `length` bytes at *addr inaccessible/zero-fill until re-committed.
 * `length` must be a positive page multiple. Same cursor contract as
 * mjs_vm_commit: *addr advances only on full success. */
int mjs_vm_decommit(unsigned char **addr, size_t length);

/* Change protection of `length` bytes at *addr to protection (an OR of
 * MJS_PROT_READ/MJS_PROT_WRITE/MJS_PROT_EXEC, or MJS_PROT_NONE). Returns 0
 * on success. */
int mjs_vm_protect(unsigned char *addr, size_t length, int protection);

/* Release a reservation made by mjs_vm_reserve. *base is NULLed on success.
 * Double-release (already-NULL *base) is a -EINVAL error. Returns 0 on
 * success. */
int mjs_vm_release(void **base, size_t reserved);

/* Allocate a non-moving stack: reserve `reserve` bytes, paint `guard_bytes`
 * (positive page multiple) PROT_NONE at the bottom, and commit the top
 * `initial_commit` bytes of the usable range. Success: 0, with
 * *out_base = reservation base, *out_guard_low = address of the first
 * usable byte, and *out_top = highest usable address, 16-byte aligned for
 * ABI entry. */
int mjs_stack_alloc(size_t reserve, size_t initial_commit, size_t guard_bytes,
                    void **out_base, void **out_guard_low, size_t *out_top);

/* Free a stack allocated by mjs_stack_alloc (whole reservation).
 * *base is NULLed on success. Double-free (already-NULL *base) is a
 * -EINVAL error, mirroring mjs_vm_release. Returns 0 on success. */
int mjs_stack_free(void **base);

/* --- s2-thread --- */
/*
 * S2.1 native OS threads (issue #48). Same return-value contract as above:
 * 0 == success; negative == -errno; out-params UNTOUCHED on failure.
 *
 * Blocking (SYS-5): every primitive here is non-blocking EXCEPT
 * mjs_thread_join, which blocks until the target thread exits.
 *
 * Handle lifetime: mjs_thread_spawn yields a JOINABLE handle owned by the
 * caller. mjs_thread_join or a successful mjs_thread_detach CONSUMES the
 * handle (both NULL *t on success); any later use of a consumed handle
 * (*t == NULL) is a deterministic -EINVAL. A detached thread frees its
 * handle when it exits; join and detach hand the pthread back to the OS
 * (pthread_join / pthread_detach), so no per-thread resources outlive exit.
 */

/* Thread entry point (spec §11): its return value is the status captured
 * for mjs_thread_join. */
typedef long (*ms_thread_entry)(void *userdata);

/* Opaque thread handle (SYS-3). */
typedef struct mjs_thread mjs_thread;

/* Spawn a thread running entry(userdata). stack_size 0 selects the system
 * default; otherwise it must be >= PTHREAD_STACK_MIN (-EINVAL). name
 * (optional, NULL ok) is applied to the new thread inside its trampoline;
 * at most 15 chars + NUL is the portable floor — longer names are rejected
 * with -ENAMETOOLONG. Precondition enforced: entry == NULL is -EINVAL.
 * Non-blocking (SYS-5). On success returns 0 and stores the handle in
 * *out. */
int mjs_thread_spawn(ms_thread_entry entry, void *userdata,
                     size_t stack_size, const char *name,
                     mjs_thread **out);

/* Join a joinable thread. Blocks (SYS-5) until the target thread exits:
 * stores the entry status in *out_result (may be NULL to discard), NULLs
 * *t, and frees the handle. On pthread_join failure returns -errno with
 * the joinable state rolled back — out_result untouched, *t untouched, no
 * refs dropped. Join-after-detach, double-join, or a NULL or NULLed
 * handle is -EINVAL with out_result untouched. */
int mjs_thread_join(mjs_thread **t, long *out_result);

/* Detach a joinable thread: the thread reclaims its own resources at exit
 * (pthread_detach) and self-frees its handle; the caller's reference is
 * consumed — *t is NULLed on success, so double-detach degenerates to a
 * deterministic -EINVAL (*t == NULL). Already detached/joined is also
 * -EINVAL. Non-blocking (SYS-5). */
int mjs_thread_detach(mjs_thread **t);

/* Identity of the CALLING thread (non-blocking). Equality semantics among
 * currently-live threads ONLY — POSIX may reuse pthread_t values after
 * join, so equality across thread lifetimes carries no meaning; the
 * numeric value itself is non-portable (pthread_self cast). */
unsigned long mjs_thread_self_id(void);

/* Set the CALLING thread's name (darwin pthread_setname_np is self-only;
 * SYS-7 divergence: portable floor is 15 chars + NUL, longer -> -ENAMETOOLONG).
 * NULL name is -EINVAL. Non-blocking (SYS-5). */
int mjs_thread_set_name(const char *name);
/* --- s2-tls --- */

/* Thread-local storage keys (issue #50): a validated layer over
 * pthread_key_* with the standard 0 / negative -errno contract. A key is
 * an opaque nonzero uintptr_t minted by mjs_tls_create; it stays valid in
 * every thread until mjs_tls_destroy and is NEVER reused, so a stale
 * handle can never alias a newer key.
 *
 * The destructor is an ms_callback (§8): void (*)(void *), exactly the
 * pthread_key destructor shape, invoked once per thread at thread exit
 * with that thread's bound value (or not at all when NULL). get() never
 * allocates (SYS-4); it returns the calling thread's binding, NULL when
 * unset or the key is invalid. set()/destroy() return -EINVAL for any key
 * not currently live; out-parameters are untouched on failure. */

/* Mint a TLS key whose per-thread values are passed to `destructor`
 * (may be NULL) at thread exit. 0 on success with *out_key = new key;
 * negative errno on failure, *out_key untouched.
 * Blocking (SYS-5): may block briefly on the global registry mutex and
 * inside pthread_key_create.
 * Allocation: may grow the key registry under the lock (one realloc);
 * issues one pthread_key_create syscall.
 * Task-aware: no — bindings are OS-thread-scoped, never task-scoped. */
int mjs_tls_create(ms_callback destructor, uintptr_t *out_key);

/* Calling thread's value for `key`; NULL when unset or key invalid.
 * Never allocates.
 * Blocking (SYS-5): holds the global registry mutex across a brief
 * key-validation critical section (may wait under contention);
 * pthread_getspecific itself does not block.
 * Allocation: none (SYS-4 names TLS reads as must-not-allocate).
 * Task-aware: no. */
void *mjs_tls_get(uintptr_t key);

/* Set the calling thread's value for `key`. -EINVAL for an invalid key.
 * Blocking (SYS-5): holds the global registry mutex across a brief
 * validate-then-set critical section (may wait under contention).
 * Allocation: none.
 * Task-aware: no. */
int mjs_tls_set(uintptr_t key, void *value);

/* Delete `key`. -EINVAL if invalid/double-destroyed. A destructor does NOT
 * run for values still bound at delete time (POSIX semantics).
 * Blocking (SYS-5): holds the global registry mutex across a brief
 * validate-and-retire critical section, released BEFORE pthread_key_delete
 * runs (no host call under the lock).
 * Allocation: none.
 * Task-aware: no. */
int mjs_tls_destroy(uintptr_t key);

/* --- s2-cpu --- */
/* CPU information and affinity (spec §13). Topology information is
 * ADVISORY. Affinity applies to the CALLING THREAD ONLY. Deliberately no
 * get-API (SYS-1): the spec asks set-only. */

/* Logical CPU count visible to this process (sysconf/sysctl); > 0. */
int mjs_cpu_logical(void);

/* Physical CPU (package core) count. Best-effort: 0 with *out > 0 when the
 * host exposes the value; EXACTLY -ENOTSUP when undeterminable, with *out
 * untouched (maps to Optional[Int] upstream; SYS-7 divergence is VISIBLE).
 * Never any other errno. */
int mjs_cpu_physical(int *out);

/* Pin the calling thread (spec L914-921) to the CPUs selected by `mask`:
 * bit i of word w selects logical CPU w*64 + i. mask == NULL or
 * nwords == 0 is -EINVAL. Linux: sched_setaffinity on the calling thread.
 * Darwin: thread_policy_set best-effort; hosts without thread-affinity
 * support return exactly -ENOTSUP. Where the call SUCCEEDS, the mask
 * contents are ignored: the policy is a coarse prefer-current-core hint,
 * not an exact pin — 0 does not promise the exact set was applied. */
int mjs_cpu_affinity_set_current(const uint64_t *mask, unsigned nwords);

/* --- s4-time --- */

/* Monotonic clock reading, normalized to nanoseconds INSIDE the C layer
 * (Linux: clock_gettime CLOCK_MONOTONIC; macOS: mach_absolute_time scaled
 * through the mach_timebase_info ratio, cached via pthread_once so the
 * calibration happens once per process). The value is a non-decreasing
 * count of nanoseconds since an arbitrary epoch (NOT wall-clock time);
 * scheduler deadlines must be computed against this clock only.
 * On success returns 0 and stores the reading in *out_ns. */
int mjs_clock_now(uint64_t *out_ns);

/* Resolution of the monotonic clock in nanoseconds (the smallest
 * non-zero tick difference the implementation can report; >= 1).
 * On success returns 0 and stores the resolution in *out_res_ns. */
int mjs_clock_resolution(uint64_t *out_res_ns);

#ifdef __cplusplus
}
#endif

#endif /* MOJITO_SYS_H */

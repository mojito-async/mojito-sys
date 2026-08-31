/*
 * tools/migration_baseline/alloc_count_fastpaths.c — M1.1 (#122) driver:
 * counts malloc-family calls across N iterations of each fast path the
 * header documents as SYS-4 ("no hidden allocation") or allocation-free
 * once its handle exists, so the baseline records a MEASURED count
 * instead of trusting the header comment.
 *
 * Must run with the interposing shim already loaded:
 *   DYLD_INSERT_LIBRARIES=build/migration_baseline/alloc_probe_shim.dylib \
 *   DYLD_FORCE_FLAT_NAMESPACE=1 \
 *   DYLD_LIBRARY_PATH=<repo root> \
 *   ./build/migration_baseline/alloc_count_fastpaths
 *
 * Output: one ALLOC_COUNT line per primitive:
 *   ALLOC_COUNT<TAB><name><TAB><iterations><TAB><alloc_calls><TAB><free_calls>
 * alloc_calls/free_calls are the TOTAL across all N iterations (not
 * per-call), so 0 means genuinely zero heap traffic across the whole
 * loop, not merely "less than one on average."
 */

#include <dlfcn.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mojito_sys.h"

#define ITERS 100000

typedef long (*probe_fn)(void);
typedef void (*reset_fn)(void);

static probe_fn g_alloc_calls;
static probe_fn g_free_calls;
static reset_fn g_reset;

static int probe_init(void) {
    g_alloc_calls = (probe_fn)dlsym(RTLD_DEFAULT, "mjs_alloc_probe_alloc_calls");
    g_free_calls = (probe_fn)dlsym(RTLD_DEFAULT, "mjs_alloc_probe_free_calls");
    g_reset = (reset_fn)dlsym(RTLD_DEFAULT, "mjs_alloc_probe_reset");
    if (!g_alloc_calls || !g_free_calls || !g_reset) {
        fprintf(stderr,
                "alloc_count_fastpaths: probe symbols not found — run with "
                "DYLD_INSERT_LIBRARIES=.../alloc_probe_shim.dylib "
                "DYLD_FORCE_FLAT_NAMESPACE=1\n");
        return -1;
    }
    return 0;
}

static void report(const char *name, long iters, long before_a, long before_f) {
    long after_a = g_alloc_calls();
    long after_f = g_free_calls();
    printf("ALLOC_COUNT\t%s\t%ld\t%ld\t%ld\n", name, iters, after_a - before_a,
           after_f - before_f);
}

static void measure_page_size(void) {
    long ba = g_alloc_calls(), bf = g_free_calls();
    for (long i = 0; i < ITERS; i++)
        (void)mjs_page_size();
    report("mjs_page_size", ITERS, ba, bf);
}

static void measure_clock_now(void) {
    uint64_t ns;
    long ba = g_alloc_calls(), bf = g_free_calls();
    for (long i = 0; i < ITERS; i++)
        (void)mjs_clock_now(&ns);
    report("mjs_clock_now", ITERS, ba, bf);
}

static void measure_vm_commit_decommit(void) {
    void *base = NULL;
    size_t reserved = 0;
    /* One 16 KiB (page-sized on this host) reservation, committed and
     * decommitted repeatedly — reserve/release themselves are NOT claimed
     * allocation-free by the header (they are one mmap syscall each, not a
     * heap allocation), so only the commit/decommit steady-state loop is
     * timed here. */
    if (mjs_vm_reserve(65536, &base, &reserved) != 0) {
        fprintf(stderr, "measure_vm_commit_decommit: reserve failed\n");
        return;
    }
    long ba = g_alloc_calls(), bf = g_free_calls();
    for (long i = 0; i < ITERS / 100; i++) { /* mmap/mprotect syscalls: fewer reps */
        unsigned char *addr = (unsigned char *)base;
        (void)mjs_vm_commit(&addr, 16384);
        addr = (unsigned char *)base;
        (void)mjs_vm_decommit(&addr, 16384);
    }
    report("mjs_vm_commit+decommit", ITERS / 100, ba, bf);
    mjs_vm_release(&base, reserved);
}

static void measure_tls_get(void) {
    uintptr_t key;
    if (mjs_tls_create(NULL, &key) != 0) {
        fprintf(stderr, "measure_tls_get: create failed\n");
        return;
    }
    mjs_tls_set(key, (void *)(uintptr_t)0x1234);
    long ba = g_alloc_calls(), bf = g_free_calls();
    for (long i = 0; i < ITERS; i++)
        (void)mjs_tls_get(key);
    report("mjs_tls_get", ITERS, ba, bf);
    mjs_tls_destroy(key);
}

static long g_thread_marker;
static long thread_entry(void *userdata) {
    (void)userdata;
    return 42;
}

static void measure_thread_spawn_join(void) {
    /* Thread spawn is NOT claimed allocation-free (the header documents it
     * as non-blocking, not alloc-free); this row exists to record the
     * ACTUAL count rather than assume, same as every other row here.
     * Small N: real OS threads, not a microbenchmark-scale loop. */
    const long n = 200;
    long ba = g_alloc_calls(), bf = g_free_calls();
    for (long i = 0; i < n; i++) {
        mjs_thread *t = NULL;
        long result = 0;
        if (mjs_thread_spawn(thread_entry, &g_thread_marker, 0, NULL, &t) != 0)
            continue;
        mjs_thread_join(&t, &result);
    }
    report("mjs_thread_spawn+join", n, ba, bf);
}

static void measure_context_switch(void) {
    size_t sz = ms_context_size();
    size_t al = ms_context_alignment();
    void *storage = NULL;
    if (posix_memalign(&storage, al > sizeof(void *) ? al : sizeof(void *), sz) != 0) {
        fprintf(stderr, "measure_context_switch: posix_memalign failed\n");
        return;
    }
    ms_context *ctx = (ms_context *)storage;
    /* Self-capture arms ctx as SUSPENDED without ever really leaving this
     * frame (ms_context_capture is a self-switch — see ms_context.c); this
     * is the same pattern benchmark/ctx/bench_switch.mojo's warmup uses. */
    ms_context_capture(ctx);
    long ba = g_alloc_calls(), bf = g_free_calls();
    for (long i = 0; i < ITERS; i++)
        ms_context_capture(ctx); /* self-switch: pure register save/restore */
    report("ms_context_switch (self-capture)", ITERS, ba, bf);
    ms_context_destroy(ctx);
    free(storage);
}

static void measure_event_signal_wait(void) {
    mjs_event *e = NULL;
    if (mjs_event_init(&e) != 0) {
        fprintf(stderr, "measure_event_signal_wait: init failed\n");
        return;
    }
    long ba = g_alloc_calls(), bf = g_free_calls();
    for (long i = 0; i < ITERS; i++) {
        /* signal-then-wait never blocks: the token is already pending. */
        (void)mjs_event_signal(e);
        (void)mjs_event_wait(e);
    }
    report("mjs_event_signal+wait", ITERS, ba, bf);
    mjs_event_destroy(&e);
}

static void measure_atomic_wake(void) {
    uint32_t word = 0;
    /* One warmup call FIRST, counted and reported separately: on macOS
     * (no futex) mjs_atomic_wait_on_u32/wake_* lazily build a 256-slot
     * waiter table behind pthread_once on the very first call anywhere in
     * the process (native/posix/mjs_atomic_wait.c mjs_aw_init) — 256
     * mjs_mutex_init + 256 mjs_condvar_init = 512 one-time allocations.
     * That is a real, documented lazy-init cost, not a per-call SYS-4
     * violation, so it is measured and reported on its own rather than
     * folded into (and inflating) the steady-state loop below. */
    long wa = g_alloc_calls(), wf = g_free_calls();
    (void)mjs_atomic_wake_one_u32(&word);
    report("mjs_atomic_wake_one_u32 (FIRST call: lazy 256-slot table init, macOS fallback)",
          1, wa, wf);

    long ba = g_alloc_calls(), bf = g_free_calls();
    for (long i = 0; i < ITERS; i++)
        (void)mjs_atomic_wake_one_u32(&word); /* no waiter: returns 0, never blocks */
    report("mjs_atomic_wake_one_u32 (steady state, no waiter)", ITERS, ba, bf);
}

static void measure_poller_wake(void) {
    mjs_poller *p = NULL;
    int rc = mjs_poller_create(&p);
    if (rc == -ENOSYS) {
        printf("ALLOC_COUNT\tmjs_poller_wake\t0\tSKIP\tENOSYS (no kqueue backend on this host)\n");
        return;
    }
    if (rc != 0) {
        fprintf(stderr, "measure_poller_wake: create failed rc=%d\n", rc);
        return;
    }
    long ba = g_alloc_calls(), bf = g_free_calls();
    for (long i = 0; i < ITERS; i++)
        (void)mjs_poller_wake(p);
    report("mjs_poller_wake", ITERS, ba, bf);
    mjs_poller_close(&p);
}

int main(void) {
    if (probe_init() != 0)
        return 2;
    g_reset();

    measure_page_size();
    measure_clock_now();
    measure_vm_commit_decommit();
    measure_tls_get();
    measure_thread_spawn_join();
    measure_context_switch();
    measure_event_signal_wait();
    measure_atomic_wake();
    measure_poller_wake();
    return 0;
}

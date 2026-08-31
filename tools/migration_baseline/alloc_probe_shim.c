/*
 * tools/migration_baseline/alloc_probe_shim.c — M1.1 (#122) heap-traffic
 * counter for the "allocation counts on the fast paths where spec SYS-4
 * promises none" baseline row.
 *
 * "No hidden allocation" is a claim, and the only honest way to check it is
 * to actually count. This is a macOS dyld interposing shim: built as its
 * own dylib and loaded via DYLD_INSERT_LIBRARIES ahead of everything else
 * in the target process, it intercepts every malloc/calloc/realloc/free
 * call (including ones libmojito_sys.dylib or libc itself makes) and keeps
 * a running count, exposed to the target process via two exported
 * functions the driver resolves with dlsym(RTLD_DEFAULT, ...) (so the
 * driver need not link against this shim directly — DYLD_INSERT_LIBRARIES
 * is what wires it in at process launch).
 *
 * This ONLY builds/works via Apple's dyld interposing mechanism (macOS);
 * that is fine for this issue's purpose, since the reference host for this
 * whole baseline is macOS ARM64 (the repo's primary dev platform, per
 * benchmark/ctx/baselines.tsv and benchmark/io/baselines.tsv) and the
 * counts are reported as macOS-host numbers, not portable ones.
 *
 * Build:  cc -dynamiclib -O0 -g tools/migration_baseline/alloc_probe_shim.c \
 *           -o build/migration_baseline/alloc_probe_shim.dylib
 * Use:    DYLD_INSERT_LIBRARIES=build/migration_baseline/alloc_probe_shim.dylib \
 *         DYLD_FORCE_FLAT_NAMESPACE=1 ./build/migration_baseline/alloc_count_fastpaths
 */

#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>

static _Atomic long g_alloc_calls = 0; /* malloc + calloc + realloc + posix_memalign */
static _Atomic long g_free_calls = 0;

static void *shim_malloc(size_t size) {
    atomic_fetch_add_explicit(&g_alloc_calls, 1, memory_order_relaxed);
    return malloc(size);
}

static void *shim_calloc(size_t count, size_t size) {
    atomic_fetch_add_explicit(&g_alloc_calls, 1, memory_order_relaxed);
    return calloc(count, size);
}

static void *shim_realloc(void *ptr, size_t size) {
    atomic_fetch_add_explicit(&g_alloc_calls, 1, memory_order_relaxed);
    return realloc(ptr, size);
}

static void shim_free(void *ptr) {
    atomic_fetch_add_explicit(&g_free_calls, 1, memory_order_relaxed);
    free(ptr);
}

/* Exported probe API: dlsym'd by the driver at RTLD_DEFAULT, never linked
 * directly (this shim is injected, not imported). */
long mjs_alloc_probe_alloc_calls(void) {
    return atomic_load_explicit(&g_alloc_calls, memory_order_relaxed);
}

long mjs_alloc_probe_free_calls(void) {
    return atomic_load_explicit(&g_free_calls, memory_order_relaxed);
}

void mjs_alloc_probe_reset(void) {
    atomic_store_explicit(&g_alloc_calls, 0, memory_order_relaxed);
    atomic_store_explicit(&g_free_calls, 0, memory_order_relaxed);
}

typedef struct {
    const void *replacement;
    const void *replacee;
} dyld_interpose_t;

#define MJS_INTERPOSE(_replacement, _replacee)                               \
    __attribute__((used)) static const dyld_interpose_t                      \
        _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = { \
            (const void *)(unsigned long)&(_replacement),                    \
            (const void *)(unsigned long)&(_replacee)}

MJS_INTERPOSE(shim_malloc, malloc);
MJS_INTERPOSE(shim_calloc, calloc);
MJS_INTERPOSE(shim_realloc, realloc);
MJS_INTERPOSE(shim_free, free);

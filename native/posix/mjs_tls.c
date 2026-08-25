/* mojito-sys S2.3 — native TLS key layer over pthread_key_* (issue #50).
 *
 * Thin validated wrapper with the standard 0 / negative -errno contract:
 *   - mjs_tls_create: pthread_key_create; the ms_callback shape (§8,
 *     void (*)(void *)) IS the pthread destructor shape, so the callback is
 *     passed through verbatim (NULL = no destructor). POSIX runs the
 *     destructor exactly once per thread at exit (the value is not re-set
 *     by the destructor), so no bookkeeping is needed here.
 *   - mjs_tls_get: pthread_getspecific; NULL when unset. Allocates nothing
 *     (SYS-4 names TLS reads as a must-not-allocate path).
 *   - mjs_tls_set / mjs_tls_destroy: -EINVAL for any key not currently
 *     minted by mjs_tls_create (bad key, double destroy, destroy-then-set).
 *
 * Key validation: pthread_key_t is an opaque integer whose width differs by
 * platform, and handing an arbitrary value to pthread_setspecific on a bad
 * key is undefined, so keys are validated against this module's registry.
 * Public keys are monotonically increasing ids (never reused) that map to
 * slots holding the real pthread_key_t — a stale handle can never alias a
 * newer key after slot reuse. The registry lock is coarse (held across the
 * underlying pthread call) to close the get/set-vs-destroy race where a
 * deleted pthread key would be dereferenced; critical sections are tiny
 * linear scans and TLS ops are not hot-loop paths in S2.
 */
#include <errno.h>
#include <pthread.h>
#include <stdlib.h>

#include "mojito_sys.h"

typedef struct {
    uintptr_t id;      /* public key value; monotonic, never reused */
    pthread_key_t key; /* host key backing this slot */
    int live;          /* 0 once destroyed; slot may be reused */
} tls_slot;

static pthread_mutex_t g_tls_lock = PTHREAD_MUTEX_INITIALIZER;
static tls_slot *g_slots;
static size_t g_cap;
static size_t g_len;
static uintptr_t g_next_id = 1;

/* Caller holds g_tls_lock. Returns the live slot owning `key`, or NULL. */
static tls_slot *tls_find(uintptr_t key) {
    for (size_t i = 0; i < g_len; i++)
        if (g_slots[i].live && g_slots[i].id == key)
            return &g_slots[i];
    return 0;
}

/* Caller holds g_tls_lock. Doubles the slot array. */
static int tls_grow(void) {
    size_t cap = g_cap ? g_cap * 2 : 16;
    tls_slot *slots = realloc(g_slots, cap * sizeof(*slots));
    if (!slots)
        return -1;
    g_slots = slots;
    g_cap = cap;
    return 0;
}

/* Thread-local storage key with `destructor` (may be NULL) run at thread
 * exit. Success: 0, mints a new nonzero key into *out_key. Failure:
 * negative errno, *out_key UNTOUCHED. */
int mjs_tls_create(ms_callback destructor, uintptr_t *out_key) {
    if (!out_key)
        return -EINVAL;

    pthread_key_t key;
    int rc = pthread_key_create(&key, destructor);
    if (rc != 0)
        return (rc == ENOMEM) ? -ENOMEM : -EAGAIN;

    pthread_mutex_lock(&g_tls_lock);
    tls_slot *slot = 0;
    for (size_t i = 0; i < g_len; i++) {
        if (!g_slots[i].live) {
            slot = &g_slots[i];
            break;
        }
    }
    if (!slot) {
        if (g_len == g_cap && tls_grow() != 0) {
            pthread_mutex_unlock(&g_tls_lock);
            pthread_key_delete(key);
            return -ENOMEM;
        }
        slot = &g_slots[g_len++];
        slot->live = 0;
    }
    slot->key = key;
    slot->id = g_next_id++;
    slot->live = 1;
    uintptr_t id = slot->id;
    pthread_mutex_unlock(&g_tls_lock);

    *out_key = id;
    return 0;
}

/* Value bound to `key` in the CALLING thread; NULL when unset or when `key`
 * is invalid. Never allocates (SYS-4). */
void *mjs_tls_get(uintptr_t key) {
    void *value = 0;
    pthread_mutex_lock(&g_tls_lock);
    tls_slot *slot = tls_find(key);
    if (slot)
        value = pthread_getspecific(slot->key);
    pthread_mutex_unlock(&g_tls_lock);
    return value;
}

/* Bind `value` for `key` in the CALLING thread (destructor registered at
 * create time will see it at exit). -EINVAL for an invalid key. */
int mjs_tls_set(uintptr_t key, void *value) {
    pthread_mutex_lock(&g_tls_lock);
    tls_slot *slot = tls_find(key);
    if (!slot) {
        pthread_mutex_unlock(&g_tls_lock);
        return -EINVAL;
    }
    int rc = pthread_setspecific(slot->key, value);
    pthread_mutex_unlock(&g_tls_lock);
    return rc ? -rc : 0;
}

/* Delete `key`. The destructor does NOT fire for values still bound in
 * other threads at delete time (POSIX semantics); callers tearing down a
 * key with cross-thread bindings own draining those threads first.
 * -EINVAL for an invalid key (never minted or already destroyed). */
int mjs_tls_destroy(uintptr_t key) {
    pthread_mutex_lock(&g_tls_lock);
    tls_slot *slot = tls_find(key);
    if (!slot) {
        pthread_mutex_unlock(&g_tls_lock);
        return -EINVAL;
    }
    pthread_key_t pkey = slot->key;
    slot->live = 0;
    pthread_mutex_unlock(&g_tls_lock);

    int rc = pthread_key_delete(pkey);
    return rc ? -rc : 0;
}

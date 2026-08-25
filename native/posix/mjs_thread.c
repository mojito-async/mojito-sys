/* mojito-sys S2.1 — native OS-thread layer (issue #48).
 *
 * pthread-backed implementation of the mjs_thread_* surface declared in
 * native/include/mojito_sys.h under the frozen contract:
 *   0 == success; negative == -errno; out-params untouched on failure.
 *
 * Handle lifetime model (see header block):
 *   - spawn hands out a JOINABLE handle with two internal references: one
 *     for the external owner, one for the in-flight trampoline. The
 *     trampoline therefore keeps the handle allocated until it finishes,
 *     so join/detach on a still-running thread are memory-safe.
 *   - join: JOINABLE -> JOINED, reap via pthread_join (which also
 *     synchronizes the status write), publish the status, NULL *t, drop
 *     both refs.
 *   - detach: JOINABLE -> DETACHED and drops the external ref; when the
 *     trampoline finishes it drops its own ref and the handle frees at
 *     zero. Double-detach is rejected by the state CAS before anything
 *     else happens.
 */
#include "mojito_sys.h"

#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include <errno.h>
#include <stdlib.h>

#define MJS_THREAD_NAME_MAX 15

enum mjs_thread_state {
    MJS_TS_JOINABLE = 0,
    MJS_TS_DETACHED = 1,
    MJS_TS_JOINED   = 2,
};

struct mjs_thread {
    pthread_t pt;
    ms_thread_entry entry;
    void *userdata;
    char name[MJS_THREAD_NAME_MAX + 1];
    atomic_int state; /* enum mjs_thread_state */
    atomic_int refs;  /* external owner + in-flight trampoline */
    long status;
};

static void mjs_thread_unref(struct mjs_thread *h) {
    if (atomic_fetch_sub_explicit(&h->refs, 1, memory_order_acq_rel) == 1)
        free(h);
}

static void *mjs_thread_trampoline(void *arg) {
    struct mjs_thread *self = arg;

    /* Name is applied in-child: darwin's pthread_setname_np(name) only ever
     * affects the calling thread, so this is the only portable point. */
    if (self->name[0]) {
#if defined(__APPLE__)
        pthread_setname_np(self->name);
#else
        pthread_setname_np(pthread_self(), self->name);
#endif
    }

    self->status = self->entry(self->userdata);
    mjs_thread_unref(self); /* drop the in-flight-trampoline ref */
    return NULL;
}

int mjs_thread_spawn(ms_thread_entry entry, void *userdata,
                     size_t stack_size, const char *name,
                     mjs_thread **out) {
    if (entry == NULL || out == NULL)
        return -EINVAL;

    size_t namelen = 0;
    if (name != NULL) {
        namelen = strlen(name);
        if (namelen > MJS_THREAD_NAME_MAX)
            return -ENAMETOOLONG;
    }

    pthread_attr_t attr;
    int rc = pthread_attr_init(&attr);
    if (rc != 0)
        return -rc;

    if (stack_size != 0) {
        rc = pthread_attr_setstacksize(&attr, stack_size);
        if (rc != 0) {
            pthread_attr_destroy(&attr);
            return -rc;
        }
    }

    struct mjs_thread *h = calloc(1, sizeof *h);
    if (h == NULL) {
        pthread_attr_destroy(&attr);
        return -ENOMEM;
    }
    h->entry = entry;
    h->userdata = userdata;
    if (name != NULL)
        memcpy(h->name, name, namelen); /* h is calloc'd: NUL already there */
    atomic_init(&h->state, MJS_TS_JOINABLE);
    atomic_init(&h->refs, 2);

    rc = pthread_create(&h->pt, &attr, mjs_thread_trampoline, h);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        free(h);
        return -rc;
    }

    *out = h;
    return 0;
}

int mjs_thread_join(mjs_thread **t, long *out_result) {
    if (t == NULL || *t == NULL)
        return -EINVAL;

    struct mjs_thread *h = *t;
    int expected = MJS_TS_JOINABLE;
    if (!atomic_compare_exchange_strong(&h->state, &expected, MJS_TS_JOINED))
        return -EINVAL; /* detached or already joined */

    /* Reap; pthread_join synchronizes-with the trampoline's status write. */
    pthread_join(h->pt, NULL);

    if (out_result != NULL)
        *out_result = h->status;
    *t = NULL;
    mjs_thread_unref(h); /* external owner */
    mjs_thread_unref(h); /* trampoline finished */
    return 0;
}

int mjs_thread_detach(mjs_thread *t) {
    if (t == NULL)
        return -EINVAL;

    int expected = MJS_TS_JOINABLE;
    if (!atomic_compare_exchange_strong(&t->state, &expected, MJS_TS_DETACHED))
        return -EINVAL; /* double-detach or already joined */

    mjs_thread_unref(t); /* release the external owner; trampoline holds its
                          * own ref and self-frees the handle at exit */
    return 0;
}

unsigned long mjs_thread_self_id(void) {
    return (unsigned long)pthread_self();
}

int mjs_thread_set_name(const char *name) {
    if (name == NULL)
        return -EINVAL;
    if (strlen(name) > MJS_THREAD_NAME_MAX)
        return -ENAMETOOLONG;

#if defined(__APPLE__)
    int rc = pthread_setname_np(name);
#else
    int rc = pthread_setname_np(pthread_self(), name);
#endif
    return rc == 0 ? 0 : -rc;
}

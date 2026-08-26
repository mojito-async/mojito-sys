/* mojito-sys S3.1 — native mutex layer (issue #57, spec §15).
 *
 * pthread-backed implementation of the mjs_mutex_* surface declared in
 * native/include/mojito_sys.h under the s3-mutex block and the frozen
 * contract:
 *   0 == success; negative == -errno; out-params untouched on failure.
 *
 * Handle lifetime model (see header block):
 *   - init mallocs a fixed-size handle wrapping a default-attribute
 *     pthread_mutex_t and hands the only reference to the caller;
 *   - destroy runs pthread_mutex_destroy, frees the handle and NULLs *m,
 *     so any later use (double destroy included) is a deterministic
 *     -EINVAL before anything else happens;
 *   - try_lock maps pthread EBUSY to -EBUSY verbatim: a STATUS, not a
 *     failure (the Mojo wrapper decodes it to False, everything else
 *     negative to a raise).
 */
#include "mojito_sys.h"

#include <pthread.h>
#include <errno.h>
#include <stdlib.h>

struct mjs_mutex {
    pthread_mutex_t pm;
};

int mjs_mutex_init(mjs_mutex **out) {
    if (out == NULL)
        return -EFAULT;
    mjs_mutex *m = malloc(sizeof(*m));
    if (m == NULL)
        return -ENOMEM;
    int rc = pthread_mutex_init(&m->pm, NULL);
    if (rc != 0) {
        free(m);
        return -rc;
    }
    *out = m;
    return 0;
}

int mjs_mutex_lock(mjs_mutex *m) {
    if (m == NULL)
        return -EINVAL;
    int rc = pthread_mutex_lock(&m->pm);
    return rc == 0 ? 0 : -rc;
}

int mjs_mutex_try_lock(mjs_mutex *m) {
    if (m == NULL)
        return -EINVAL;
    int rc = pthread_mutex_trylock(&m->pm);
    /* EBUSY passes through as the documented busy STATUS. */
    return rc == 0 ? 0 : -rc;
}

int mjs_mutex_unlock(mjs_mutex *m) {
    if (m == NULL)
        return -EINVAL;
    int rc = pthread_mutex_unlock(&m->pm);
    return rc == 0 ? 0 : -rc;
}

int mjs_mutex_destroy(mjs_mutex **m) {
    if (m == NULL || *m == NULL)
        return -EINVAL;
    int rc = pthread_mutex_destroy(&(*m)->pm);
    if (rc != 0)
        return -rc; /* handle NOT consumed on failure */
    free(*m);
    *m = NULL;
    return 0;
}

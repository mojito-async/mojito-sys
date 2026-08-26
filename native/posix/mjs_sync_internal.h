/* mojito-sys internal — shared struct layout for the native sync layers
 * (s3-mutex #57 + s3-condvar #58).
 *
 * PRIVATE to the posix sources: NOT installed, NOT part of the frozen
 * public ABI in ../include/mojito_sys.h. Consumers outside this
 * directory must go through the opaque-handle entry points only.
 *
 * The definition lives here (not in mjs_mutex.c) so mjs_condvar_wait /
 * wait_until can pass &mutex->pm straight to pthread_cond_* without a
 * second source of truth for the layout.
 */
#ifndef MJS_SYNC_INTERNAL_H
#define MJS_SYNC_INTERNAL_H

#include <pthread.h>

#include "mojito_sys.h"

struct mjs_mutex {
    pthread_mutex_t pm;
};

#endif /* MJS_SYNC_INTERNAL_H */

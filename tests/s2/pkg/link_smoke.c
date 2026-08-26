/* mojito-sys S2.9 — packaged-library link smoke, thread area (issue #56).
 *
 * Extends the tests/s1/pkg pattern: links against the packaged
 * libmojito_sys.dylib and takes the address of EVERY mjs_ symbol added by
 * the S2 lanes — thread set (mjs_thread_spawn/join/detach/self_id/set_name),
 * TLS set (mjs_tls_create/get/set/destroy) and CPU set (mjs_cpu_logical/
 * mjs_cpu_physical/mjs_cpu_affinity_set_current). A missing export from this
 * consumer is a link failure = red lane. Minimal runtime checks pin the
 * frozen-ABI negotiation and one value per set.
 */

#include "mojito_sys.h"

int main(void) {
    /* Address-taking keeps every S2 export a hard link dep. */
    void *refs[] = {
        /* thread set */
        (void *)mjs_thread_spawn,
        (void *)mjs_thread_join,
        (void *)mjs_thread_detach,
        (void *)mjs_thread_self_id,
        (void *)mjs_thread_set_name,
        /* tls set */
        (void *)mjs_tls_create,
        (void *)mjs_tls_get,
        (void *)mjs_tls_set,
        (void *)mjs_tls_destroy,
        /* cpu set */
        (void *)mjs_cpu_logical,
        (void *)mjs_cpu_physical,
        (void *)mjs_cpu_affinity_set_current,
    };
    for (unsigned long i = 0; i < sizeof(refs) / sizeof(refs[0]); i++)
        if (refs[i] == 0)
            return 2;
    if (mjs_abi_version() != MOJITO_SYS_ABI_VERSION)
        return 3;
    /* One cheap runtime probe per set (all non-destructive). */
    if (mjs_cpu_logical() <= 0)
        return 4;
    if (mjs_tls_get(0) != (void *)0) /* key 0 is never minted */
        return 5;
    if (mjs_thread_self_id() == 0)
        return 6;
    return 0;
}

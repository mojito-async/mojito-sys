/* mojito-sys S1 — packaged-library smoke (issue #24).
 *
 * References EVERY entry point declared by native/include/mojito_sys.h by
 * address so the linker requires each symbol to resolve from
 * libmojito_sys.dylib. A missing export = link failure = red lane.
 *
 * This is intentionally a TDD-red lane: the vm/stack entry points ship in
 * the S1 memory lanes; until they merge, this lane stays red (covered by
 * the aggregate `s1-tests` known-red row, removed when all lanes land).
 *
 * Build: cc -I native/include -c smoke.c, then link against
 * libmojito_sys.dylib.
 */
#include "mojito_sys.h"
#include <stddef.h>

int (*const ref_simple[])(void) = {
    mjs_page_size,
    mjs_granularity,
    mjs_abi_version,
};

static int (*const ref_reserve)(size_t, void **, size_t *) = mjs_vm_reserve;
static int (*const ref_commit)(unsigned char **, size_t) = mjs_vm_commit;
static int (*const ref_decommit)(unsigned char **, size_t) = mjs_vm_decommit;
static int (*const ref_protect)(unsigned char *, size_t, int) = mjs_vm_protect;
static int (*const ref_release)(void **, size_t) = mjs_vm_release;
static int (*const ref_stack_alloc)(size_t, size_t, size_t, void **, void **, size_t *) = mjs_stack_alloc;
static int (*const ref_stack_free)(void **) = mjs_stack_free;

int main(void) {
    /* Take addresses so the linker must resolve every entry point. */
    void *refs[10] = {
        (void *)ref_simple[0], (void *)ref_simple[1], (void *)ref_simple[2],
        (void *)ref_reserve, (void *)ref_commit, (void *)ref_decommit,
        (void *)ref_protect, (void *)ref_release,
        (void *)ref_stack_alloc, (void *)ref_stack_free,
    };
    return refs[9] != 0 ? 0 : 1;
}
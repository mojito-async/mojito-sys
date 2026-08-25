/* mojito-sys S1 — packaged-library smoke, part 1: frozen-header ABI shape.
 *
 * Compile-only translation unit: assigns EVERY entry point declared by
 * native/include/mojito_sys.h to a correctly-typed function pointer, so any
 * signature drift in the frozen header breaks this build. It also pins the
 * frozen callback ABI (ms_callback + mjs_callback_token).
 *
 * Deliberately NOT linked: export coverage is the packaging conformance
 * check in run.sh (exports.txt vs the dylib export table) and the runtime
 * smoke is link_smoke.c. Linking against not-yet-implemented entry points
 * here would keep the whole lane red until every S1 memory lane merges,
 * which contradicts the panel H2 design: assert the CURRENTLY-EXPECTED
 * export list so gaps are loud, not permanently red.
 *
 * Build: cc -I native/include -c smoke.c
 */

#include "mojito_sys.h"
#include <stddef.h>

/* Frozen callback ABI: one two-word token (code address + userdata). */
_Static_assert(sizeof(mjs_callback_token) == 2 * sizeof(void *),
               "mjs_callback_token must remain a two-word token");

static void s1_cb_sink(void *userdata) { (void)userdata; }
static ms_callback const s1_cb_ok = s1_cb_sink;

/* Signature guards: an incompatible declaration fails to compile here. */
static int (*const p_page_size)(void) = mjs_page_size;
static int (*const p_granularity)(void) = mjs_granularity;
static int (*const p_abi_version)(void) = mjs_abi_version;
static int (*const p_vm_reserve)(size_t, void **, size_t *) = mjs_vm_reserve;
static int (*const p_vm_commit)(unsigned char **, size_t) = mjs_vm_commit;
static int (*const p_vm_decommit)(unsigned char **, size_t) = mjs_vm_decommit;
static int (*const p_vm_protect)(unsigned char *, size_t, int) = mjs_vm_protect;
static int (*const p_vm_release)(void **, size_t) = mjs_vm_release;
static int (*const p_stack_alloc)(size_t, size_t, size_t, void **, void **,
                                  size_t *) = mjs_stack_alloc;
static int (*const p_stack_free)(void **) = mjs_stack_free;

/* Keep every guard live so none can be elided as dead initializers. */
void *const s1_shape_refs[] = {
    (void *)p_page_size,   (void *)p_granularity, (void *)p_abi_version,
    (void *)p_vm_reserve,  (void *)p_vm_commit,   (void *)p_vm_decommit,
    (void *)p_vm_protect,  (void *)p_vm_release,  (void *)p_stack_alloc,
    (void *)p_stack_free,  (void *)s1_cb_ok,
};

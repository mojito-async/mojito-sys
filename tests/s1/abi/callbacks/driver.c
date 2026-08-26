/* mojito-sys S1 — ABI — C-to-Mojo callback invoke driver (issue #43).
 *
 * Native half of the §8 invoke conformance: this TU is compiled ad hoc
 * (NOT part of libmojito_sys — no new exported dylib symbols) and linked
 * into the AOT-built Mojo conformance executable by run.sh via -Xlinker,
 * exactly the tests/s1/memory/stack lane pattern.
 *
 * Pins the frozen token layout as a compile-time sink (the "native layout
 * sink" promised by issue #32 but never landed) and provides the C-side
 * invoke entry points the Mojo half drives through @extern:
 *
 *   mjs_abi_cbdrv_invoke          — cast token.addr to ms_callback and
 *                                   invoke it with token.userdata;
 *   mjs_abi_cbdrv_invoke_corrupt  — corrupt the addr slot (mode 0: NULL,
 *                                   mode 1: a valid-but-wrong code address)
 *                                   and demonstrate a DETERMINISTIC verdict,
 *                                   never a crash.
 *
 * Return contract (driver-local, not part of the frozen ABI):
 *   0 = invoked; caller inspects its own sentinel through userdata
 *   1 = refused deterministically without invoking (null addr slot)
 *
 * Build: cc -I <repo>/native/include -c driver.c     (no -arch flag;
 * target follows the host toolchain, per the uname-derived harness).
 */

#include "mojito_sys.h"
#include <stddef.h>

/* ---- frozen-layout sink (spec §8 / header lines 49-55) ------------------ */
_Static_assert(sizeof(mjs_callback_token) == 16,
               "mjs_callback_token must be exactly two 8-byte words");
_Static_assert(offsetof(mjs_callback_token, addr) == 0,
               "mjs_callback_token.addr must be first word");
_Static_assert(offsetof(mjs_callback_token, userdata) == 8,
               "mjs_callback_token.userdata must be second word");

/* Valid-but-wrong corruption target: an ms_callback-shaped function that
 * ignores its userdata and writes nothing, so a corrupted dispatch returns
 * normally and the missing sentinel is observable in plain sight. */
static void cbdrv_benign_sink(void *userdata) { (void)userdata; }

int mjs_abi_cbdrv_invoke(const mjs_callback_token *token) {
    if (token == NULL || token->addr == NULL) {
        return 1; /* refused: null addr slot means no callback (header M1) */
    }
    ms_callback cb;
    __builtin_memcpy(&cb, &token->addr, sizeof cb);
    cb(token->userdata);
    return 0;
}

int mjs_abi_cbdrv_invoke_corrupt(const mjs_callback_token *token, int mode) {
    if (token == NULL || token->addr == NULL) {
        return 1;
    }
    mjs_callback_token bad = *token; /* the caller's word pair is untouched */
    if (mode == 0) {
        bad.addr = NULL; /* nullity is addr-nullity: must refuse to call */
        return mjs_abi_cbdrv_invoke(&bad);
    }
    bad.addr = (void *)&cbdrv_benign_sink;
    return mjs_abi_cbdrv_invoke(&bad);
}

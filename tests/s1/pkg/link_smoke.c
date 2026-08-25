/* mojito-sys S1 — packaged-library smoke, part 2: link + runtime.
 *
 * Links against the packaged libmojito_sys.dylib and calls only the
 * currently-implemented entry points (the set pinned by exports.txt):
 *   - mjs_abi_version() must report MOJITO_SYS_ABI_VERSION (frozen-ABI
 *     negotiation works for a dynloading consumer);
 *   - mjs_page_size() must be positive.
 * A missing export from this consumer is a link failure = red lane.
 */

#include "mojito_sys.h"

int main(void) {
    /* Address-taking keeps every implemented export a hard link dep. */
    void *refs[] = {
        (void *)mjs_page_size,
        (void *)mjs_abi_version,
    };
    if (refs[0] == 0 || refs[1] == 0)
        return 2;
    if (mjs_abi_version() != MOJITO_SYS_ABI_VERSION)
        return 3;
    if (mjs_page_size() <= 0)
        return 4;
    return 0;
}

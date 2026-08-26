/* mojito-sys S1 — packaged-library smoke, part 2: link + runtime.
 *
 * Links against the packaged libmojito_sys.dylib and calls only the
 * currently-implemented entry points (the set pinned by exports.txt):
 *   - mjs_abi_version() must report MOJITO_SYS_ABI_VERSION (frozen-ABI
 *     negotiation works for a dynloading consumer);
 *   - mjs_page_size() must be positive;
 *   - ms_context_size()/ms_context_alignment() must report the frozen v2
 *     save-area geometry (issue #64): 168 bytes = regs[12] + fps[8] + sp,
 *     with a power-of-two alignment that divides the size.
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
    /* --- s5-ctx (issue #64): frozen v2 context geometry. --- */
    if (ms_context_size() != 168)
        return 5; /* regs[12] x19-x30 @0 + fps[8] d8-d15 @96 + sp @160 */
    {
        size_t align = ms_context_alignment();
        if (align < sizeof(void *) || (align & (align - 1)) != 0 ||
            ms_context_size() % align != 0)
            return 6;
    }
    return 0;
}

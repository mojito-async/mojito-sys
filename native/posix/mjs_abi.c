/* mojito-sys S1 — ABI version export (issue #24).
 *
 * Consumers that dynload libmojito_sys.dylib can negotiate the frozen ABI
 * version before binding entry points. Owned by the build lane: this is
 * packaging/ABI metadata, not a memory subsystem.
 */
#include "mojito_sys.h"

int mjs_abi_version(void) {
    return MOJITO_SYS_ABI_VERSION;
}
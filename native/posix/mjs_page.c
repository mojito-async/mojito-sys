/* S1 build-lane stub (issue #24): minimal page-size provider so the packaged
 * libmojito_sys.dylib links from day one. The real mjs_page_size /
 * granularity implementation lands in the S1 memory-page lane; do NOT grow
 * this file into a full ABI implementation. */
#include "mojito_sys.h"

int mjs_page_size(void) {
    return 16384; /* host page size (mojito.tools toolchain); signed int */
}
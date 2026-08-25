/* mojito-sys S1 — page-size / allocation-granularity query (issue #28).
 *
 * Replaces the s1/build lane stub (hardcoded 16384) with the real
 * sysconf(_SC_PAGESIZE) implementation, matching the frozen C ABI in
 * native/include/mojito_sys.h.
 *
 * POSIX note: mmap reservations are aligned to the process page size, so on
 * the POSIX target the allocation granularity equals the page size. Windows
 * (not yet a target, and the header's granularity semantic would need a
 * GetSystemInfo split) reports a distinct 64 KiB allocation granularity; the
 * mjs_granularity() entry point is where that difference would surface when
 * the Windows target is added.
 */
#include <unistd.h>

#include "mojito_sys.h"

/* Cached sysconf(_SC_PAGESIZE). The query is informational and not expected
 * to change within a process; caching it (0-init guard) mirrors the S0 spike
 * native_stack.c convention and avoids a sysconf syscall on the hot path. */
static long g_page_size;

/* Lazy-cache the host page size. Falls back to 4096 ONLY when sysconf
 * returns an invalid value (<= 0) or the result cannot be represented in a
 * 32-bit signed int. NOTE: the 4096 fallback is NOT a validated page size on
 * unknown hosts; alignment-critical sizing must not consume it. */
static long host_page_size(void) {
    if (g_page_size == 0) {
        long ps = sysconf(_SC_PAGESIZE);
        g_page_size = (ps > 0 && ps <= 2147483647L) ? ps : 4096;
    }
    return g_page_size;
}

/* Host page size (sysconf(_SC_PAGESIZE)); > 0. */
int mjs_page_size(void) {
    return (int)host_page_size();
}

/* Allocation granularity for reservations; >= page size. POSIX platforms
 * align reservations to the page size, so granularity == page size. */
int mjs_granularity(void) {
    return (int)host_page_size();
}

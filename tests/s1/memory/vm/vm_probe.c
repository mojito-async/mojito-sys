/* vm_probe.c — C-level conformance corners for mjs_vm_reserve (issue #29).
 *
 * Panel H5: reserve rounds requests up to the ALLOCATION GRANULARITY
 * (mjs_granularity), not the page size. Asserted here at the ABI layer with
 * a non-granule-multiple request, a zero request, and an exact multiple.
 */
#include <stdio.h>
#include <stdlib.h>
#include "mojito_sys.h"

static int fails;

static void check(const char *name, int cond) {
    printf("%s %s\n", name, cond ? "PASS" : "FAIL");
    if (!cond) fails++;
}

static size_t round_up(size_t n, size_t a) {
    return (n + a - 1) / a * a;
}

int main(void) {
    int gran = mjs_granularity();
    if (gran <= 0) {
        printf("PROBE: granularity unavailable\n");
        return 2;
    }

    void *base = NULL;
    size_t reserved = 0;

    /* Non-granule-multiple request must round UP to the granularity. */
    check("VP1 non-granule request rounds to granularity",
          mjs_vm_reserve(1000, &base, &reserved) == 0 &&
              reserved == round_up(1000, (size_t)gran));
    check("VP1b zero-request reserves one granule",
          mjs_vm_release(&base, reserved) == 0);

    base = NULL;
    check("VP2 zero-byte reserve reserves one granule",
          mjs_vm_reserve(0, &base, &reserved) == 0 &&
              reserved == (size_t)gran);
    check("VP2b release", mjs_vm_release(&base, reserved) == 0);

    base = NULL;
    check("VP3 exact-multiple reserve is unchanged",
          mjs_vm_reserve((size_t)gran * 3, &base, &reserved) == 0 &&
              reserved == (size_t)gran * 3);
    check("VP3b release", mjs_vm_release(&base, reserved) == 0);

    printf("PROBE: %d/%d PASSED\n", 6 - fails, 6);
    return fails != 0;
}

# mojito-sys S1 — page-size / allocation-granularity conformance (issue #28).
#
# Verifies the Mojo page-query surface bound to the frozen native ABI
# (native/include/mojito_sys.h):
#   - page_size() > 0 and is a power of two (any real host page size);
#   - page_size() >= 4096 (smallest page size any supported platform uses);
#   - allocation_granularity() >= page_size();
#   - allocation_granularity() is an exact multiple of page_size();
#   - both read consistently (two consecutive calls agree) — the query is
#     informational and must not drift between calls.
#
# This file is red (cannot link) until mjs_granularity exists in
# libmojito_sys.dylib — the expected TDD-red state for this lane.

from mojito_sys.memory.page import allocation_granularity, page_size


# True iff x is a power of two and x >= 4096.
def is_plausible_page_size(x: Int32) -> Bool:
    return (x >= 4096) and ((x & (x - 1)) == 0)


def main() raises:
    var failed = 0

    var ps1 = page_size()
    var ps2 = page_size()
    var g1 = allocation_granularity()
    var g2 = allocation_granularity()

    if is_plausible_page_size(ps1):
        print("S1 page_size > 0, power-of-two, >=4096: PASS")
    else:
        print("S1 page_size > 0, power-of-two, >=4096: FAIL (page_size=" + String(ps1) + ")")
        failed += 1

    if ps1 == ps2:
        print("S1 page_size stable across calls:       PASS")
    else:
        print("S1 page_size stable across calls:       FAIL (ps1=" + String(ps1) + " ps2=" + String(ps2) + ")")
        failed += 1

    if g1 >= ps1:
        print("S1 granularity >= page size:            PASS")
    else:
        print("S1 granularity >= page size:            FAIL (gran=" + String(g1) + " page=" + String(ps1) + ")")
        failed += 1

    if (g1 >= 4096) and (g1 % ps1) == 0:
        print("S1 granularity is page multiple:        PASS")
    else:
        print("S1 granularity is page multiple:        FAIL (gran=" + String(g1) + " page=" + String(ps1) + ")")
        failed += 1

    if g1 == g2:
        print("S1 granularity stable across calls:     PASS")
    else:
        print("S1 granularity stable across calls:     FAIL (g1=" + String(g1) + " g2=" + String(g2) + ")")
        failed += 1

    if failed != 0:
        print("RESULT: " + String(failed) + " FAILED")
        raise Error("S1 page conformance failed")
    print("RESULT: all green")
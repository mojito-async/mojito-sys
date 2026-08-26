# mojito-sys S3.3 — package-path import check for mojito_sys.sync.atomic_wait
# (issue #59). Verifies the §18 surface resolves through the package
# layout (`-I <repo-root>`): the three entry points plus WaitStatus and
# MonotonicInstant. No C calls here (default Optional = no deadline would
# block on a live backend).

from mojito_sys.sync.atomic_wait import (
    wait_on_u32,
    wait_until_changed,
    wake_all_u32,
    wake_one_u32,
)
from mojito_sys.sync.common import WaitStatus
from mojito_sys.time.monotonic import MonotonicInstant


def main():
    # Comptime-resolvable surface checks only: the symbols exist, the
    # status vocabulary is intact. No wait is ever entered.
    var ok = WaitStatus.ok == WaitStatus.ok
    var timed = WaitStatus.timed_out != WaitStatus.ok
    if ok and timed:
        print("s3-atomic-import-ok")
    else:
        print("s3-atomic-import-BROKEN")

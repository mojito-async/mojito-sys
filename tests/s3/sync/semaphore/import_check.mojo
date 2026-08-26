# mojito-sys S3.7 — package-path import check for the S3.7 semaphore
# surface (issue #106). Verifies the public names resolve through the
# package layout (`-I <repo-root>`): NativeSemaphore from sync.semaphore,
# WaitStatus from sync.common, MonotonicInstant from time.monotonic.

from mojito_sys.sync.common import WaitStatus
from mojito_sys.sync.semaphore import NativeSemaphore
from mojito_sys.time.duration import duration_from_millis
from mojito_sys.time.monotonic import MonotonicInstant

def main() raises:
    var ok = WaitStatus.ok == WaitStatus.ok
    var timed = WaitStatus.timed_out != WaitStatus.ok
    var s = NativeSemaphore()
    var dl = MonotonicInstant.now() + duration_from_millis(1)
    # Default construction is the inert/consumed state; no C call here.
    if ok and timed and s.destroyed and dl.ticks > 0:
        print("semaphore-import-ok")
    else:
        print("semaphore-import-BROKEN")
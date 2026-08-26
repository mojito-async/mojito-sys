# mojito-sys S3.2 — package-path import check for the S3.2 condvar
# surface (issue #58). Verifies the public names resolve through the
# package layout (`-I <repo-root>`): NativeCondVar from sync.condvar,
# WaitStatus from sync.common, MonotonicInstant from time.monotonic.

from mojito_sys.sync.common import WaitStatus
from mojito_sys.sync.condvar import NativeCondVar
from mojito_sys.time.duration import duration_from_millis
from mojito_sys.time.monotonic import MonotonicInstant

def main() raises:
    var ok = WaitStatus.ok == WaitStatus.ok
    var timed = WaitStatus.timed_out != WaitStatus.ok
    var cv = NativeCondVar()
    var dl = MonotonicInstant.now() + duration_from_millis(1)
    # Default construction is the inert/consumed state; no C call here.
    if ok and timed and cv.destroyed and dl.ticks > 0:
        print("condvar-import-ok")
    else:
        print("condvar-import-BROKEN")

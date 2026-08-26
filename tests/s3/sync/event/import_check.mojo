# mojito-sys S3.5 — package-path import check for the S3.5 event
# surface (issue #61). Verifies the public names resolve through the
# package layout (`-I <repo-root>`): NativeEvent from sync.event,
# WaitStatus from sync.common, MonotonicInstant from time.monotonic.

from mojito_sys.sync.common import WaitStatus
from mojito_sys.sync.event import NativeEvent
from mojito_sys.time.duration import duration_from_millis
from mojito_sys.time.monotonic import MonotonicInstant

def main() raises:
    var ok = WaitStatus.ok == WaitStatus.ok
    var timed = WaitStatus.timed_out != WaitStatus.ok
    var ev = NativeEvent()
    var dl = MonotonicInstant.now() + duration_from_millis(1)
    # Default construction is the inert/consumed state; no C call here.
    if ok and timed and ev.destroyed and dl.ticks > 0:
        print("event-import-ok")
    else:
        print("event-import-BROKEN")

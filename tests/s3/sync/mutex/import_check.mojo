# mojito-sys S3.1 — package-path import check for mojito_sys.sync
# (issue #57). Verifies the public surface resolves through the package
# layout (`-I <repo-root>`): WaitStatus from sync.common, NativeMutex
# from sync.mutex.

from mojito_sys.sync.common import WaitStatus
from mojito_sys.sync.mutex import NativeMutex


def main():
    var ok = WaitStatus.ok == WaitStatus.ok
    var timed = WaitStatus.timed_out != WaitStatus.ok
    var m = NativeMutex()
    # Default construction is the inert/consumed state; no C call here.
    if ok and timed and m.destroyed:
        print("sync-import-ok")
    else:
        print("sync-import-BROKEN")

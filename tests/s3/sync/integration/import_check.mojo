# mojito-sys S3.6 — package-path import check for the WHOLE S3 sync
# surface (issue #62). Every wrapper module must import and expose its
# primitive from the mojito_sys package root; prints the
# s3-integration-import-ok marker on success.

from mojito_sys.sync.atomic_wait import wait_on_u32, wake_all_u32
from mojito_sys.sync.common import WaitStatus
from mojito_sys.sync.condvar import NativeCondVar
from mojito_sys.sync.event import NativeEvent
from mojito_sys.sync.mutex import NativeMutex


def main() raises:
    # Touch each imported name so the symbols are genuinely resolved.
    _ = NativeMutex
    _ = NativeCondVar
    _ = NativeEvent
    _ = WaitStatus.ok
    _ = wait_on_u32
    _ = wake_all_u32
    print("s3-integration-import-ok")

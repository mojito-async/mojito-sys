# mojito-sys S2.9 — packaged-library conformance, thread area (issue #56).
#
# Import check over EVERY mojito_sys.thread module against the repo-root
# package layout (-I <repo root>), extending the tests/s1/pkg pattern:
# each import must compile AND resolve at least one public symbol, so a
# broken module path or a silently-empty re-export turns this red.

from mojito_sys.thread.thread import (
    NativeThread,
    native_thread_id,
    no_name,
    set_current_thread_name,
    spawn_native_thread,
)
from mojito_sys.thread.tls import (
    NativeTlsKey,
    create_tls_key,
)
from mojito_sys.thread.cpu_info import (
    cpu_logical_count,
    cpu_physical_count,
)
from mojito_sys.thread.affinity import (
    CpuSet,
    set_current_thread_affinity,
)

# Referencing one public symbol per module as a comptime alias forces real
# resolution beyond the import itself (a missing/renamed public def fails
# this file's compilation either way).
alias _spawn = spawn_native_thread
alias _tid = native_thread_id
alias _rename = set_current_thread_name
alias _null_cell = no_name
alias _handle = NativeThread
alias _key_factory = create_tls_key
alias _key = NativeTlsKey
alias _logical = cpu_logical_count
alias _physical = cpu_physical_count
alias _set_type = CpuSet
alias _pin = set_current_thread_affinity


def main():
    print("s2-pkg-import-ok")

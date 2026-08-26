# mojito-sys S2.2 — mojito_sys.thread import surface (issue #49).
#
# Compile-time + load-time coverage that the `mojito_sys.thread` package
# path resolves against the repo root (-I) and every public symbol of the
# S2.2 lane is importable (mirrors tests/s1/pkg/import_check.mojo).

from mojito_sys.thread.thread import (
    CThreadEntry,
    NativeThread,
    ThreadOptions,
    UserdataPtr,
    native_thread_id,
    set_current_thread_name,
    spawn_native_thread,
)


def main():
    var opts = ThreadOptions()
    var tid = native_thread_id()

    # Touch the option fields so their accessors lower in this TU too.
    _ = opts.name_len
    _ = opts.stack_size
    _ = opts.priority_hint

    print("thread-import-ok " + String(tid))

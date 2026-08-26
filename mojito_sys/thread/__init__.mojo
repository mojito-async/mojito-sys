"""mojito_sys.thread - OS-thread services for mojito (phase S2).

Spec surfaces bound to frozen C ABI blocks in native/include/mojito_sys.h:
  - mojito_sys.thread.thread      NativeThread + ThreadOptions +
    module-level spawn_native_thread()/native_thread_id()/
    set_current_thread_name()            (S2.2, issue #49)
  - mojito_sys.thread.tls         NativeTlsKey TLS keys          (S2.4, #51)
  - mojito_sys.thread.cpu_info    cpu_logical_count()/cpu_physical_count()
  - mojito_sys.thread.affinity    CpuSet + current-thread pinning (S2.6, #53)

Subpackage scaffold; wrappers live in sibling modules.
"""

# comptime: exports are defined in thread.mojo / tls.mojo /
# cpu_info.mojo / affinity.mojo.

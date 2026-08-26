"""mojito_sys.abi - ABI/types surface for mojito (S1, issue #24).

Landed modules (spec §7):
  - types.mojo     — C-type aliases over std.ffi (S1.2, issue #25);
  - errors.mojo    — ErrorDomain/Error carrier (S1.3, issue #26);
  - callbacks.mojo — CallbackToken: code pointer + opaque userdata carrier
    for native callbacks;
  - handles.mojo   — OpaqueNativeHandle/OwnedFd/BorrowedFd (§7.2, §25).
"""

# comptime: ABI exports are defined in the sibling modules; nothing is
# re-exported at package level.

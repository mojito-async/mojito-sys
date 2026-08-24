"""mojito_sys.abi - ABI/types surface for mojito (S1, issue #24).

Subpackage scaffold owned by the s1/build lane; type, error and callback
modules land in the S1 abi lanes. Kept symbol-free until then.
"""

# comptime: ABI exports are added by the s1/abi-* lanes via `alias` /
# `public` definitions in sibling modules.

# mojito-sys S6.2 — raw mjs_socket_* FFI bindings (issue #74).
#
# LEAF MODULE (b2 WORKAROUND precedent #49): this file deliberately
# contains ONLY @extern declarations and the comptime pointer aliases
# they need — no imports, no structs, no raise sites. b2 1.0.0b2's
# cross-module lowering misbinds extern call arguments when the
# DECLARING module also hosts Movable structs and/or raising machinery.
# The proven shape is: pure-extern leaf + same-module probe_* shims +
# decode/raise only in the wrapper AFTER the call returns (mirrors
# mojito_sys/sync/externs.mojo).
#
# NEVER-INLINE INVARIANT: the probe_* shims below are the ONLY sanctioned
# call path into the mjs_socket_* bindings and MUST stay tiny,
# non-raising, aggregate-free, and free of @always_inline at every call
# site. These symbols are NOT for caller use; prefer NativeSocket /
# SocketAddress (mojito_sys.io.socket).
#
# AGGREGATE RULE: no Mojo-side aggregate is ever READ inside an
# extern-reaching frame. The 136-byte neutral mjs_sockaddr travels as an
# opaque byte buffer that callers fill/inspect with SCALAR loads and
# stores BEFORE/AFTER the probe call; the C layer converts it to real OS
# sockaddr storage.

# A socket descriptor as it crosses the ABI (POSIX fd currency).
comptime SockFd = Int32

# int* / size_t* out-slots. MutAnyOrigin: the pointer escapes into an
# opaque callee, and MutAnyOrigin pins the post-call slot load AFTER the
# call (see mojito_sys/io/handle.mojo ORIGIN HAZARD notes).
comptime FdSlot = UnsafePointer[Int32, MutAnyOrigin]
comptime SizeSlot = UnsafePointer[UInt64, MutAnyOrigin]

# Opaque byte-buffer pointers: the neutral mjs_sockaddr (136 bytes) and
# raw byte payloads / NUL-terminated strings handed to C.
comptime ByteBuf = UnsafePointer[Byte, MutAnyOrigin]


@extern("mjs_socket_socket")
def mjs_socket_socket(
    family: Int32, sock_type: Int32, out_fd: FdSlot
) abi("C") -> Int32:
    ...


@extern("mjs_socket_set_nonblocking")
def mjs_socket_set_nonblocking(fd: SockFd, enabled: Int32) abi("C") -> Int32:
    ...


@extern("mjs_socket_bind")
def mjs_socket_bind(fd: SockFd, addr: ByteBuf) abi("C") -> Int32:
    ...


@extern("mjs_socket_listen")
def mjs_socket_listen(fd: SockFd, backlog: Int32) abi("C") -> Int32:
    ...


@extern("mjs_socket_connect")
def mjs_socket_connect(fd: SockFd, addr: ByteBuf) abi("C") -> Int32:
    ...


@extern("mjs_socket_accept")
def mjs_socket_accept(
    fd: SockFd, out_client: FdSlot, out_peer: ByteBuf
) abi("C") -> Int32:
    ...


@extern("mjs_socket_recv")
def mjs_socket_recv(
    fd: SockFd, buf: ByteBuf, length: UInt64, out_n: SizeSlot
) abi("C") -> Int32:
    ...


@extern("mjs_socket_send")
def mjs_socket_send(
    fd: SockFd, buf: ByteBuf, length: UInt64, out_n: SizeSlot
) abi("C") -> Int32:
    ...


@extern("mjs_socket_shutdown")
def mjs_socket_shutdown(fd: SockFd, how: Int32) abi("C") -> Int32:
    ...


@extern("mjs_socket_close")
def mjs_socket_close(fd: SockFd) abi("C") -> Int32:
    ...


@extern("mjs_sockaddr_ipv4")
def mjs_sockaddr_ipv4(
    dotted: ByteBuf, port: Int32, out_addr: ByteBuf
) abi("C") -> Int32:
    ...


@extern("mjs_sockaddr_format4")
def mjs_sockaddr_format4(
    addr: ByteBuf, out_buf: ByteBuf, cap: UInt64, out_len: SizeSlot
) abi("C") -> Int32:
    ...


# ---- non-raising call shims (leaf-module boundary) --------------------------
#
# Every mjs_socket_* invocation happens HERE, in the pure leaf, and
# returns the raw C rc; mojito_sys.io.socket decodes/raises only afterwards.


def probe_socket(family: Int32, sock_type: Int32, out_fd: FdSlot) -> Int32:
    return mjs_socket_socket(family, sock_type, out_fd)


def probe_set_nonblocking(fd: SockFd, enabled: Int32) -> Int32:
    return mjs_socket_set_nonblocking(fd, enabled)


def probe_bind(fd: SockFd, addr: ByteBuf) -> Int32:
    return mjs_socket_bind(fd, addr)


def probe_listen(fd: SockFd, backlog: Int32) -> Int32:
    return mjs_socket_listen(fd, backlog)


def probe_connect(fd: SockFd, addr: ByteBuf) -> Int32:
    return mjs_socket_connect(fd, addr)


def probe_accept(fd: SockFd, out_client: FdSlot, out_peer: ByteBuf) -> Int32:
    return mjs_socket_accept(fd, out_client, out_peer)


def probe_recv(fd: SockFd, buf: ByteBuf, length: UInt64, out_n: SizeSlot) -> Int32:
    return mjs_socket_recv(fd, buf, length, out_n)


def probe_send(fd: SockFd, buf: ByteBuf, length: UInt64, out_n: SizeSlot) -> Int32:
    return mjs_socket_send(fd, buf, length, out_n)


def probe_shutdown(fd: SockFd, how: Int32) -> Int32:
    return mjs_socket_shutdown(fd, how)


def probe_close(fd: SockFd) -> Int32:
    return mjs_socket_close(fd)


def probe_sockaddr_ipv4(dotted: ByteBuf, port: Int32, out_addr: ByteBuf) -> Int32:
    return mjs_sockaddr_ipv4(dotted, port, out_addr)


def probe_sockaddr_format4(
    addr: ByteBuf, out_buf: ByteBuf, cap: UInt64, out_len: SizeSlot
) -> Int32:
    return mjs_sockaddr_format4(addr, out_buf, cap, out_len)

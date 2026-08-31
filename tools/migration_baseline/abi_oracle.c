/*
 * tools/migration_baseline/abi_oracle.c — M1.1 (#122) ABI/OS-struct layout
 * oracle.
 *
 * Reports, as JSON Lines (one struct/typedef/constant per line):
 *   - the frozen ABI structs, function-pointer typedefs and opaque-handle
 *     typedefs from native/include/mojito_sys.h, with size/alignment/field
 *     offsets exactly as THIS compiler lays them out on THIS host;
 *   - the ABI constants from the same header;
 *   - the OS structs/typedefs the native/ implementation consumes but never
 *     exports (timespec, timeval, sockaddr_in/in6/un, sa_family_t,
 *     socklen_t, iovec, kevent, pthread_attr_t, pthread_mutex_t,
 *     pthread_cond_t) — the ones Mojo has to get byte-exact per issue #122,
 *     and which never appear in our own header.
 *
 * This is a MEASURING tool, not a transcription: every number below comes
 * from sizeof/_Alignof/offsetof evaluated by the actual host compiler, never
 * copied from a comment or a manual. Re-run it on a different host/arch/
 * compiler to get that host's real numbers; do not hand-edit its output.
 *
 * Build (matching the Makefile's own CFLAGS):
 *   cc -Inative/include tools/migration_baseline/abi_oracle.c \
 *      libmojito_sys.dylib -o build/abi_oracle
 * (ms_context_size()/ms_context_alignment() are runtime calls into the
 * built dylib, since struct ms_context is intentionally opaque outside
 * native/posix/ms_context.c — SYS-3.)
 *
 * Run: ./build/abi_oracle
 */

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <sys/un.h>
#include <time.h>

#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) ||   \
    defined(__NetBSD__) || defined(__DragonFly__)
#define MJS_HAVE_KQUEUE_HDR 1
#include <sys/event.h>
#endif

#if defined(__linux__)
#include <sys/epoll.h>
#endif

#include "mojito_sys.h"

/* Runtime geometry getters for the intentionally-opaque struct ms_context
 * (SYS-3: its layout is package-private, only size/alignment are the
 * public contract). Declared here rather than pulled from a private
 * header — this file only sees what native/include/mojito_sys.h exposes. */
extern size_t ms_context_size(void);
extern size_t ms_context_alignment(void);

static int g_first = 1;

static void sep(void) {
    if (!g_first)
        putchar('\n');
    g_first = 0;
}

/* One "kind":"struct" line with a caller-built fields array (already
 * formatted JSON, no trailing comma) passed in as `fields_json`. */
static void emit_struct(const char *name, const char *source, int is_public,
                        size_t size, size_t align, const char *fields_json) {
    sep();
    printf("{\"kind\":\"struct\",\"name\":\"%s\",\"source\":\"%s\","
           "\"public\":%s,\"size\":%zu,\"align\":%zu,\"fields\":[%s]}",
           name, source, is_public ? "true" : "false", size, align,
           fields_json);
}

static void emit_opaque(const char *name, const char *source, int is_public,
                        size_t size, size_t align, const char *note) {
    sep();
    printf("{\"kind\":\"opaque\",\"name\":\"%s\",\"source\":\"%s\","
           "\"public\":%s,\"size\":%zu,\"align\":%zu,\"note\":\"%s\"}",
           name, source, is_public ? "true" : "false", size, align, note);
}

static void emit_typedef(const char *name, const char *source, size_t size,
                         size_t align) {
    sep();
    printf("{\"kind\":\"typedef\",\"name\":\"%s\",\"source\":\"%s\","
           "\"public\":false,\"size\":%zu,\"align\":%zu}",
           name, source, size, align);
}

static void emit_fnptr(const char *name, const char *source, size_t size,
                       size_t align) {
    sep();
    printf("{\"kind\":\"function_pointer\",\"name\":\"%s\",\"source\":\"%s\","
           "\"public\":true,\"size\":%zu,\"align\":%zu}",
           name, source, size, align);
}

static void emit_const(const char *name, long long value) {
    sep();
    printf("{\"kind\":\"constant\",\"name\":\"%s\",\"source\":"
           "\"native/include/mojito_sys.h\",\"public\":true,\"value\":%lld}",
           name, value);
}

static void emit_unmeasured(const char *name, const char *source,
                            const char *reason) {
    sep();
    printf("{\"kind\":\"unmeasured\",\"name\":\"%s\",\"source\":\"%s\","
           "\"reason\":\"%s\"}",
           name, source, reason);
}

int main(void) {
    /* ---- our own ABI structs (native/include/mojito_sys.h, public) --- */
    {
        char f[512];
        snprintf(f, sizeof f,
                 "{\"name\":\"family\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"port\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"_pad0\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"flowinfo\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"scope_id\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"octets\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"path\",\"offset\":%zu,\"size\":%zu}",
                 offsetof(mjs_sockaddr, family), sizeof(((mjs_sockaddr *)0)->family),
                 offsetof(mjs_sockaddr, port), sizeof(((mjs_sockaddr *)0)->port),
                 offsetof(mjs_sockaddr, _pad0), sizeof(((mjs_sockaddr *)0)->_pad0),
                 offsetof(mjs_sockaddr, flowinfo), sizeof(((mjs_sockaddr *)0)->flowinfo),
                 offsetof(mjs_sockaddr, scope_id), sizeof(((mjs_sockaddr *)0)->scope_id),
                 offsetof(mjs_sockaddr, octets), sizeof(((mjs_sockaddr *)0)->octets),
                 offsetof(mjs_sockaddr, path), sizeof(((mjs_sockaddr *)0)->path));
        emit_struct("mjs_sockaddr", "native/include/mojito_sys.h", 1,
                   sizeof(mjs_sockaddr), _Alignof(mjs_sockaddr), f);
    }
    {
        char f[256];
        snprintf(f, sizeof f,
                 "{\"name\":\"token\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"fd\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"events\",\"offset\":%zu,\"size\":%zu}",
                 offsetof(mjs_poll_event, token), sizeof(((mjs_poll_event *)0)->token),
                 offsetof(mjs_poll_event, fd), sizeof(((mjs_poll_event *)0)->fd),
                 offsetof(mjs_poll_event, events), sizeof(((mjs_poll_event *)0)->events));
        emit_struct("mjs_poll_event", "native/include/mojito_sys.h", 1,
                   sizeof(mjs_poll_event), _Alignof(mjs_poll_event), f);
    }
    {
        char f[256];
        snprintf(f, sizeof f,
                 "{\"name\":\"addr\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"userdata\",\"offset\":%zu,\"size\":%zu}",
                 offsetof(mjs_callback_token, addr), sizeof(((mjs_callback_token *)0)->addr),
                 offsetof(mjs_callback_token, userdata), sizeof(((mjs_callback_token *)0)->userdata));
        emit_struct("mjs_callback_token", "native/include/mojito_sys.h", 1,
                   sizeof(mjs_callback_token), _Alignof(mjs_callback_token), f);
    }

    /* ms_context: intentionally opaque outside native/posix/ms_context.c
     * (SYS-3). Size/alignment are the public contract, queried at RUNTIME
     * through the built dylib rather than sizeof'd here (an incomplete
     * type cannot be sizeof'd, by design). Field offsets are NOT public;
     * they are pinned internally by _Static_assert in ms_context.c and
     * recorded in this repo's baseline as informational, not re-derived
     * here since this file has no access to the private definition. */
    emit_opaque("ms_context", "native/include/mojito_sys.h (opaque; layout"
               " private to native/posix/ms_context.c)", 1,
               ms_context_size(), ms_context_alignment(),
               "size/alignment via ms_context_size()/ms_context_alignment()"
               " at runtime; internal field offsets are pinned by"
               " _Static_assert in ms_context.c (regs@0 fps@96 sp@160"
               " state@168 ret_to@176 finish_cb@184 finish_ud@192, 200"
               " bytes total) and are package-private, not re-measured here");

    /* Opaque handle typedefs (SYS-3): only the HANDLE SLOT (a pointer)
     * crosses the ABI; the pointee layout is never public. */
    emit_opaque("mjs_thread*", "native/include/mojito_sys.h", 1,
               sizeof(mjs_thread *), _Alignof(mjs_thread *), "opaque handle slot");
    emit_opaque("mjs_mutex*", "native/include/mojito_sys.h", 1,
               sizeof(mjs_mutex *), _Alignof(mjs_mutex *), "opaque handle slot");
    emit_opaque("mjs_condvar*", "native/include/mojito_sys.h", 1,
               sizeof(mjs_condvar *), _Alignof(mjs_condvar *), "opaque handle slot");
    emit_opaque("mjs_event*", "native/include/mojito_sys.h", 1,
               sizeof(mjs_event *), _Alignof(mjs_event *), "opaque handle slot");
    emit_opaque("mjs_sem*", "native/include/mojito_sys.h", 1,
               sizeof(mjs_sem *), _Alignof(mjs_sem *), "opaque handle slot");
    emit_opaque("mjs_poller*", "native/include/mojito_sys.h", 1,
               sizeof(mjs_poller *), _Alignof(mjs_poller *), "opaque handle slot");
    emit_opaque("mjs_epoller*", "native/include/mojito_sys.h", 1,
               sizeof(mjs_epoller *), _Alignof(mjs_epoller *), "opaque handle slot");
    emit_opaque("mjs_uring*", "native/include/mojito_sys.h", 1,
               sizeof(mjs_uring *), _Alignof(mjs_uring *), "opaque handle slot");

    /* Function-pointer typedefs (public: they cross the ABI as values). */
    emit_fnptr("ms_callback", "native/include/mojito_sys.h",
              sizeof(ms_callback), _Alignof(ms_callback));
    emit_fnptr("ms_thread_entry", "native/include/mojito_sys.h",
              sizeof(ms_thread_entry), _Alignof(ms_thread_entry));
    emit_fnptr("ms_context_entry", "native/include/mojito_sys.h",
              sizeof(ms_context_entry), _Alignof(ms_context_entry));
    emit_fnptr("ms_context_finish_fn", "native/include/mojito_sys.h",
              sizeof(ms_context_finish_fn), _Alignof(ms_context_finish_fn));

    /* ABI constants (compile-time #define values from the header). */
    emit_const("MOJITO_SYS_ABI_VERSION", MOJITO_SYS_ABI_VERSION);
    emit_const("MJS_PROT_NONE", MJS_PROT_NONE);
    emit_const("MJS_PROT_READ", MJS_PROT_READ);
    emit_const("MJS_PROT_WRITE", MJS_PROT_WRITE);
    emit_const("MJS_PROT_EXEC", MJS_PROT_EXEC);
    emit_const("MJS_SOCK_STREAM", MJS_SOCK_STREAM);
    emit_const("MJS_SOCK_DGRAM", MJS_SOCK_DGRAM);
    emit_const("MJS_SOCK_INET", MJS_SOCK_INET);
    emit_const("MJS_SOCK_UNIX", MJS_SOCK_UNIX);
    emit_const("MJS_SOCK_INET6", MJS_SOCK_INET6);
    emit_const("MJS_SHUT_READ", MJS_SHUT_READ);
    emit_const("MJS_SHUT_WRITE", MJS_SHUT_WRITE);
    emit_const("MJS_SHUT_BOTH", MJS_SHUT_BOTH);
    emit_const("MJS_POLL_READABLE", MJS_POLL_READABLE);
    emit_const("MJS_POLL_WRITABLE", MJS_POLL_WRITABLE);
    emit_const("MJS_POLL_EOF", MJS_POLL_EOF);
    emit_const("MJS_POLL_ERROR", MJS_POLL_ERROR);

    /* Host-numeric constants the header calls out as diverging per
     * platform (native/posix/mjs_socket.c mjs_af_of, native/posix/
     * mjs_poller.c / mjs_epoll.c): the ACTUAL OS values on this host,
     * not the MJS_* neutral spelling above. */
    emit_const("AF_INET (os)", AF_INET);
    emit_const("AF_INET6 (os)", AF_INET6);
    emit_const("AF_UNIX (os)", AF_UNIX);
#ifdef O_NONBLOCK
    emit_const("O_NONBLOCK (os)", O_NONBLOCK);
#endif

    /* ---- OS structs/typedefs the implementation consumes but never
     * exports: these have to be byte-exact in Mojo and never appear in
     * our own header (issue #122's own framing). */
    {
        char f[256];
        snprintf(f, sizeof f,
                 "{\"name\":\"tv_sec\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"tv_nsec\",\"offset\":%zu,\"size\":%zu}",
                 offsetof(struct timespec, tv_sec), sizeof(((struct timespec *)0)->tv_sec),
                 offsetof(struct timespec, tv_nsec), sizeof(((struct timespec *)0)->tv_nsec));
        emit_struct("struct timespec", "<time.h>", 0, sizeof(struct timespec),
                   _Alignof(struct timespec), f);
    }
    {
        char f[256];
        snprintf(f, sizeof f,
                 "{\"name\":\"tv_sec\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"tv_usec\",\"offset\":%zu,\"size\":%zu}",
                 offsetof(struct timeval, tv_sec), sizeof(((struct timeval *)0)->tv_sec),
                 offsetof(struct timeval, tv_usec), sizeof(((struct timeval *)0)->tv_usec));
        emit_struct("struct timeval", "<sys/time.h>", 0, sizeof(struct timeval),
                   _Alignof(struct timeval), f);
    }
    {
        char f[512];
        snprintf(f, sizeof f,
#ifdef __APPLE__
                 "{\"name\":\"sin_len\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"sin_family\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"sin_port\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"sin_addr\",\"offset\":%zu,\"size\":%zu}",
                 offsetof(struct sockaddr_in, sin_len), sizeof(((struct sockaddr_in *)0)->sin_len),
                 offsetof(struct sockaddr_in, sin_family), sizeof(((struct sockaddr_in *)0)->sin_family),
                 offsetof(struct sockaddr_in, sin_port), sizeof(((struct sockaddr_in *)0)->sin_port),
                 offsetof(struct sockaddr_in, sin_addr), sizeof(((struct sockaddr_in *)0)->sin_addr)
#else
                 "{\"name\":\"sin_family\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"sin_port\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"sin_addr\",\"offset\":%zu,\"size\":%zu}",
                 offsetof(struct sockaddr_in, sin_family), sizeof(((struct sockaddr_in *)0)->sin_family),
                 offsetof(struct sockaddr_in, sin_port), sizeof(((struct sockaddr_in *)0)->sin_port),
                 offsetof(struct sockaddr_in, sin_addr), sizeof(((struct sockaddr_in *)0)->sin_addr)
#endif
                 );
        emit_struct("struct sockaddr_in", "<netinet/in.h>", 0,
                   sizeof(struct sockaddr_in), _Alignof(struct sockaddr_in), f);
    }
    {
        char f[512];
        snprintf(f, sizeof f,
#ifdef __APPLE__
                 "{\"name\":\"sin6_len\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"sin6_family\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"sin6_port\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"sin6_flowinfo\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"sin6_addr\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"sin6_scope_id\",\"offset\":%zu,\"size\":%zu}",
                 offsetof(struct sockaddr_in6, sin6_len), sizeof(((struct sockaddr_in6 *)0)->sin6_len),
                 offsetof(struct sockaddr_in6, sin6_family), sizeof(((struct sockaddr_in6 *)0)->sin6_family),
                 offsetof(struct sockaddr_in6, sin6_port), sizeof(((struct sockaddr_in6 *)0)->sin6_port),
                 offsetof(struct sockaddr_in6, sin6_flowinfo), sizeof(((struct sockaddr_in6 *)0)->sin6_flowinfo),
                 offsetof(struct sockaddr_in6, sin6_addr), sizeof(((struct sockaddr_in6 *)0)->sin6_addr),
                 offsetof(struct sockaddr_in6, sin6_scope_id), sizeof(((struct sockaddr_in6 *)0)->sin6_scope_id)
#else
                 "{\"name\":\"sin6_family\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"sin6_port\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"sin6_flowinfo\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"sin6_addr\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"sin6_scope_id\",\"offset\":%zu,\"size\":%zu}",
                 offsetof(struct sockaddr_in6, sin6_family), sizeof(((struct sockaddr_in6 *)0)->sin6_family),
                 offsetof(struct sockaddr_in6, sin6_port), sizeof(((struct sockaddr_in6 *)0)->sin6_port),
                 offsetof(struct sockaddr_in6, sin6_flowinfo), sizeof(((struct sockaddr_in6 *)0)->sin6_flowinfo),
                 offsetof(struct sockaddr_in6, sin6_addr), sizeof(((struct sockaddr_in6 *)0)->sin6_addr),
                 offsetof(struct sockaddr_in6, sin6_scope_id), sizeof(((struct sockaddr_in6 *)0)->sin6_scope_id)
#endif
                 );
        emit_struct("struct sockaddr_in6", "<netinet/in.h>", 0,
                   sizeof(struct sockaddr_in6), _Alignof(struct sockaddr_in6), f);
    }
    {
        char f[512];
        snprintf(f, sizeof f,
#ifdef __APPLE__
                 "{\"name\":\"sun_len\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"sun_family\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"sun_path\",\"offset\":%zu,\"size\":%zu}",
                 offsetof(struct sockaddr_un, sun_len), sizeof(((struct sockaddr_un *)0)->sun_len),
                 offsetof(struct sockaddr_un, sun_family), sizeof(((struct sockaddr_un *)0)->sun_family),
                 offsetof(struct sockaddr_un, sun_path), sizeof(((struct sockaddr_un *)0)->sun_path)
#else
                 "{\"name\":\"sun_family\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"sun_path\",\"offset\":%zu,\"size\":%zu}",
                 offsetof(struct sockaddr_un, sun_family), sizeof(((struct sockaddr_un *)0)->sun_family),
                 offsetof(struct sockaddr_un, sun_path), sizeof(((struct sockaddr_un *)0)->sun_path)
#endif
                 );
        emit_struct("struct sockaddr_un", "<sys/un.h>", 0,
                   sizeof(struct sockaddr_un), _Alignof(struct sockaddr_un), f);
    }
    emit_typedef("sa_family_t", "<sys/socket.h>", sizeof(sa_family_t), _Alignof(sa_family_t));
    emit_typedef("socklen_t", "<sys/socket.h>", sizeof(socklen_t), _Alignof(socklen_t));
    {
        char f[256];
        snprintf(f, sizeof f,
                 "{\"name\":\"iov_base\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"iov_len\",\"offset\":%zu,\"size\":%zu}",
                 offsetof(struct iovec, iov_base), sizeof(((struct iovec *)0)->iov_base),
                 offsetof(struct iovec, iov_len), sizeof(((struct iovec *)0)->iov_len));
        emit_struct("struct iovec", "<sys/uio.h>", 0, sizeof(struct iovec),
                   _Alignof(struct iovec), f);
    }

#if defined(MJS_HAVE_KQUEUE_HDR)
    {
        char f[512];
        snprintf(f, sizeof f,
                 "{\"name\":\"ident\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"filter\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"flags\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"fflags\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"data\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"udata\",\"offset\":%zu,\"size\":%zu}",
                 offsetof(struct kevent, ident), sizeof(((struct kevent *)0)->ident),
                 offsetof(struct kevent, filter), sizeof(((struct kevent *)0)->filter),
                 offsetof(struct kevent, flags), sizeof(((struct kevent *)0)->flags),
                 offsetof(struct kevent, fflags), sizeof(((struct kevent *)0)->fflags),
                 offsetof(struct kevent, data), sizeof(((struct kevent *)0)->data),
                 offsetof(struct kevent, udata), sizeof(((struct kevent *)0)->udata));
        emit_struct("struct kevent", "<sys/event.h> (BSD/macOS only)", 0,
                   sizeof(struct kevent), _Alignof(struct kevent), f);
    }
#else
    emit_unmeasured("struct kevent", "<sys/event.h> (BSD/macOS only)",
                    "kqueue is not available on this host; measure on a"
                    " macOS/BSD host (this repo's primary dev platform"
                    " already is one, so this branch should not normally"
                    " trigger)");
#endif

#if defined(__linux__)
    {
        char f[256];
        snprintf(f, sizeof f,
                 "{\"name\":\"events\",\"offset\":%zu,\"size\":%zu},"
                 "{\"name\":\"data\",\"offset\":%zu,\"size\":%zu}",
                 offsetof(struct epoll_event, events), sizeof(((struct epoll_event *)0)->events),
                 offsetof(struct epoll_event, data), sizeof(((struct epoll_event *)0)->data));
        emit_struct("struct epoll_event", "<sys/epoll.h> (Linux only)", 0,
                   sizeof(struct epoll_event), _Alignof(struct epoll_event), f);
    }
#else
    emit_unmeasured("struct epoll_event", "<sys/epoll.h> (Linux only)",
                    "epoll is Linux-only and this oracle is running on a"
                    " non-Linux host; struct epoll_event is notoriously"
                    " __attribute__((packed)) on x86-64 and NOT packed on"
                    " AArch64 (see native/posix/mjs_epoll.c and issue"
                    " #124's own callout) — measure on both a Linux/x86-64"
                    " and a Linux/AArch64 host via the M1.2 spike leg"
                    " (#124), not assumed from this run");
#endif

    /* Opaque pthread types: only size/alignment matter to Mojo (SYS-3
     * style opaqueness carries over from the C layer to the OS itself
     * here) — their contents are libc's business, not ours. */
    emit_opaque("pthread_attr_t", "<pthread.h>", 0, sizeof(pthread_attr_t),
               _Alignof(pthread_attr_t), "opaque libc blob; contents are"
               " never inspected, only sized for pthread_attr_init storage");
    emit_opaque("pthread_mutex_t", "<pthread.h>", 0, sizeof(pthread_mutex_t),
               _Alignof(pthread_mutex_t), "opaque libc blob; wrapped by"
               " native/posix/mjs_mutex.c / mjs_sync_internal.h");
    emit_opaque("pthread_cond_t", "<pthread.h>", 0, sizeof(pthread_cond_t),
               _Alignof(pthread_cond_t), "opaque libc blob; wrapped by"
               " native/posix/mjs_condvar.c");
    emit_opaque("pthread_key_t", "<pthread.h>", 0, sizeof(pthread_key_t),
               _Alignof(pthread_key_t), "opaque libc scalar; wrapped by"
               " native/posix/mjs_tls.c's validated registry");
    emit_opaque("pthread_t", "<pthread.h>", 0, sizeof(pthread_t),
               _Alignof(pthread_t), "opaque libc handle; wrapped by"
               " native/posix/mjs_thread.c (struct mjs_thread.pt)");

    printf("\n");
    return 0;
}

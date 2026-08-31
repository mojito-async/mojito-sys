/*
 * spike/abi/oracle.c — M1.2 (#124) ABI spike C oracle.
 *
 * Two jobs, both feeding the Mojo-side conformance tests in this
 * directory rather than a checked-in copy of a number:
 *
 *   1. STRUCT LAYOUT ORACLE. For every OS struct issue #124 names
 *      (timespec, timeval, sockaddr_in/in6/un, iovec, kevent (BSD/macOS),
 *      epoll_event (Linux), plus the opaque pthread_attr_t/pthread_mutex_t
 *      blobs) this exposes:
 *        - oracle_sizeof_X() / oracle_alignof_X() — this compiler's real
 *          numbers, evaluated with sizeof/_Alignof, never hand-copied;
 *        - oracle_offset_X_FIELD() — real offsetof() per field;
 *        - oracle_fill_X(&s) — writes a FIXED, documented pattern into
 *          each named field (never touches padding, so padding bytes stay
 *          whatever the caller's storage already held — the Mojo side
 *          reads named fields back, never raw padding bytes);
 *        - oracle_check_X(&s) — reads the same fields back and returns 1
 *          iff every one matches the fixed pattern, 0 otherwise (prints
 *          which field mismatched to stderr for a human to read in the
 *          test's captured output).
 *      This lets the Mojo side prove BOTH directions: C fills, Mojo reads
 *      the struct through its own declared field layout; Mojo fills
 *      through its own declared fields, C reads back through the real
 *      struct definition.
 *
 *   2. LIBC-CALL ORACLE. Thin wrappers that make the identical libc/OS
 *      call the Mojo side is about to make directly (mmap/munmap/
 *      mprotect/sysconf/clock_gettime/socket/close/read/write/recv/send),
 *      so the Mojo-side result (return value AND errno) can be diffed
 *      against a call this file makes itself, for the same inputs,
 *      including the deliberately-triggered failure paths. Also exposes
 *      the platform's raw errno ACCESSOR-FUNCTION address indirectly by
 *      naming it (see mojito_sys/abi/... ; Mojo declares its own
 *      @extern("__error"/"__errno_location") — this file doesn't need to
 *      re-expose that, it only needs to produce comparable errno values
 *      through its own C-side `errno` for the SAME failing call).
 *
 * Every number this file reports is measured on THIS host by THIS
 * compiler. Nothing here is copied from MOJO_MIGRATION_BASELINE.md — that
 * document itself says its Linux column for platform-divergent values is
 * NOT measured and flags itself as such; this oracle is what measures the
 * real thing, on whichever host runs it (this repo's CI runs it on both
 * macOS arm64 and Linux x86-64 via spike/abi/run.sh).
 *
 * Build (matching the repo's existing ad hoc lane-probe convention, e.g.
 * tests/s1/memory/vm/run.sh): compiled standalone by spike/abi/run.sh,
 * no Makefile change.
 *   cc -O2 -g -Wall -Wextra -dynamiclib -o liboracle.dylib oracle.c
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE /* Linux: epoll_event, O_CLOEXEC, etc. */
#endif

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include <arpa/inet.h>
#include <netinet/in.h>

#if defined(__APPLE__)
#include <mach/mach_time.h>
#include <sys/event.h>
#define SPIKE_HAVE_KQUEUE 1
#endif

#if defined(__linux__)
#include <sys/epoll.h>
#define SPIKE_HAVE_EPOLL 1
#endif

/* ------------------------------------------------------------------ */
/* Fixed field patterns. Documented here once; the Mojo side mirrors    */
/* these literally (spike/abi/struct_layout_test.mojo) rather than       */
/* deriving them from anything computed, so a mismatch is unambiguous.  */
/* ------------------------------------------------------------------ */

#define PAT_TS_SEC   ((int64_t)1234567890123LL)
#define PAT_TS_NSEC  ((int64_t)987654321LL)
#define PAT_TV_SEC   ((int64_t)1111111111LL)
#define PAT_TV_USEC  ((int32_t)222222)

#define PAT_SIN_PORT     ((uint16_t)0x1234)
#define PAT_SIN_ADDR     ((uint32_t)0x7F0000AAu)
#define PAT_SIN_ZERO_BYTE ((unsigned char)0xEE)

#define PAT_SIN6_PORT     ((uint16_t)0x5678)
#define PAT_SIN6_FLOWINFO ((uint32_t)0xCAFEBABEu)
#define PAT_SIN6_SCOPE_ID ((uint32_t)0x0000002Au)
#define PAT_SIN6_ADDR_BYTE(i) ((unsigned char)(0xA0 + (i)))

#define PAT_SUN_PATH "/tmp/mojito-abi-spike.sock"

#define PAT_IOV_LEN ((uint64_t)0x0000000000004321ULL)
#define PAT_IOV_BASE_ADDR ((uintptr_t)0x0000000010203040ULL)

#if defined(SPIKE_HAVE_KQUEUE)
#define PAT_KEV_IDENT  ((uintptr_t)0x11)
#define PAT_KEV_FILTER ((int16_t)(-1)) /* EVFILT_READ */
#define PAT_KEV_FLAGS  ((uint16_t)0x0001) /* EV_ADD */
#define PAT_KEV_FFLAGS ((uint32_t)0x00000002u)
#define PAT_KEV_DATA   ((intptr_t)0x2233)
#define PAT_KEV_UDATA  ((uintptr_t)0x44556677)
#endif

#if defined(SPIKE_HAVE_EPOLL)
#define PAT_EPOLL_EVENTS ((uint32_t)(EPOLLIN | EPOLLOUT))
#define PAT_EPOLL_DATA_U64 ((uint64_t)0x0102030405060708ULL)
#endif

static void note_mismatch(const char *structname, const char *field) {
    fprintf(stderr, "oracle_check_%s: field %s MISMATCH\n", structname,
            field);
}

/* ==================================================================== */
/* struct timespec                                                       */
/* ==================================================================== */

size_t oracle_sizeof_timespec(void) { return sizeof(struct timespec); }
size_t oracle_alignof_timespec(void) { return _Alignof(struct timespec); }
size_t oracle_offset_timespec_tv_sec(void) {
    return offsetof(struct timespec, tv_sec);
}
size_t oracle_offset_timespec_tv_nsec(void) {
    return offsetof(struct timespec, tv_nsec);
}

void oracle_fill_timespec(struct timespec *ts) {
    ts->tv_sec = (time_t)PAT_TS_SEC;
    ts->tv_nsec = (long)PAT_TS_NSEC;
}

int oracle_check_timespec(const struct timespec *ts) {
    int ok = 1;
    if ((int64_t)ts->tv_sec != PAT_TS_SEC) {
        note_mismatch("timespec", "tv_sec");
        ok = 0;
    }
    if ((int64_t)ts->tv_nsec != PAT_TS_NSEC) {
        note_mismatch("timespec", "tv_nsec");
        ok = 0;
    }
    return ok;
}

/* Argument-passing half (issue #124: "struct-by-value in registers is a
 * separate ABI question from struct layout"): pass/return this SMALL
 * struct BY VALUE, not by pointer. */
int64_t oracle_timespec_sum_byval(struct timespec ts) {
    return (int64_t)ts.tv_sec + (int64_t)ts.tv_nsec;
}

struct timespec oracle_make_timespec_byval(int64_t sec, int64_t nsec) {
    struct timespec ts;
    ts.tv_sec = (time_t)sec;
    ts.tv_nsec = (long)nsec;
    return ts;
}

/* ==================================================================== */
/* struct timeval                                                        */
/* ==================================================================== */

size_t oracle_sizeof_timeval(void) { return sizeof(struct timeval); }
size_t oracle_alignof_timeval(void) { return _Alignof(struct timeval); }
size_t oracle_offset_timeval_tv_sec(void) {
    return offsetof(struct timeval, tv_sec);
}
size_t oracle_offset_timeval_tv_usec(void) {
    return offsetof(struct timeval, tv_usec);
}
/* sizeof each FIELD (not just the offset), because tv_usec's width itself
 * is the platform-divergent fact here (suseconds_t: 4 bytes on Darwin,
 * commonly 8 on Linux/glibc) — measured, not assumed. */
size_t oracle_fieldsizeof_timeval_tv_usec(void) {
    struct timeval tv;
    return sizeof(tv.tv_usec);
}

void oracle_fill_timeval(struct timeval *tv) {
    tv->tv_sec = (time_t)PAT_TV_SEC;
    tv->tv_usec = (typeof(tv->tv_usec))PAT_TV_USEC;
}

int oracle_check_timeval(const struct timeval *tv) {
    int ok = 1;
    if ((int64_t)tv->tv_sec != PAT_TV_SEC) {
        note_mismatch("timeval", "tv_sec");
        ok = 0;
    }
    if ((int64_t)tv->tv_usec != PAT_TV_USEC) {
        note_mismatch("timeval", "tv_usec");
        ok = 0;
    }
    return ok;
}

/* ==================================================================== */
/* sa_family_t / socklen_t scalars                                       */
/* ==================================================================== */

size_t oracle_sizeof_sa_family_t(void) { return sizeof(sa_family_t); }
size_t oracle_alignof_sa_family_t(void) { return _Alignof(sa_family_t); }
size_t oracle_sizeof_socklen_t(void) { return sizeof(socklen_t); }
size_t oracle_alignof_socklen_t(void) { return _Alignof(socklen_t); }

/* ==================================================================== */
/* struct sockaddr_in                                                    */
/* ==================================================================== */

size_t oracle_sizeof_sockaddr_in(void) { return sizeof(struct sockaddr_in); }
size_t oracle_alignof_sockaddr_in(void) {
    return _Alignof(struct sockaddr_in);
}
size_t oracle_offset_sockaddr_in_sin_family(void) {
    return offsetof(struct sockaddr_in, sin_family);
}
size_t oracle_offset_sockaddr_in_sin_port(void) {
    return offsetof(struct sockaddr_in, sin_port);
}
size_t oracle_offset_sockaddr_in_sin_addr(void) {
    return offsetof(struct sockaddr_in, sin_addr);
}
size_t oracle_offset_sockaddr_in_sin_zero(void) {
    return offsetof(struct sockaddr_in, sin_zero);
}
#if defined(__APPLE__)
size_t oracle_offset_sockaddr_in_sin_len(void) {
    return offsetof(struct sockaddr_in, sin_len);
}
int oracle_has_sin_len(void) { return 1; }
#else
int oracle_has_sin_len(void) { return 0; }
#endif
size_t oracle_fieldsizeof_sockaddr_in_sin_family(void) {
    struct sockaddr_in a;
    return sizeof(a.sin_family);
}

/* NOTE: this is a pure ABI-layout/transit test, not a networking test — the
 * pattern values are stored and compared VERBATIM (no htons/htonl), since
 * byte-order convention is an application-level concern orthogonal to
 * "does this field's bit pattern survive the ABI boundary intact". */
void oracle_fill_sockaddr_in(struct sockaddr_in *a) {
    memset(a, 0, sizeof(*a));
#if defined(__APPLE__)
    a->sin_len = sizeof(*a);
#endif
    a->sin_family = AF_INET;
    a->sin_port = PAT_SIN_PORT;
    a->sin_addr.s_addr = PAT_SIN_ADDR;
    memset(a->sin_zero, PAT_SIN_ZERO_BYTE, sizeof(a->sin_zero));
}

int oracle_check_sockaddr_in(const struct sockaddr_in *a) {
    int ok = 1;
    if (a->sin_family != AF_INET) {
        note_mismatch("sockaddr_in", "sin_family");
        ok = 0;
    }
    if (a->sin_port != PAT_SIN_PORT) {
        note_mismatch("sockaddr_in", "sin_port");
        ok = 0;
    }
    if (a->sin_addr.s_addr != PAT_SIN_ADDR) {
        note_mismatch("sockaddr_in", "sin_addr");
        ok = 0;
    }
    for (size_t i = 0; i < sizeof(a->sin_zero); i++) {
        if ((unsigned char)a->sin_zero[i] != PAT_SIN_ZERO_BYTE) {
            note_mismatch("sockaddr_in", "sin_zero");
            ok = 0;
            break;
        }
    }
    return ok;
}

/* ==================================================================== */
/* struct sockaddr_in6                                                   */
/* ==================================================================== */

size_t oracle_sizeof_sockaddr_in6(void) {
    return sizeof(struct sockaddr_in6);
}
size_t oracle_alignof_sockaddr_in6(void) {
    return _Alignof(struct sockaddr_in6);
}
size_t oracle_offset_sockaddr_in6_sin6_family(void) {
    return offsetof(struct sockaddr_in6, sin6_family);
}
size_t oracle_offset_sockaddr_in6_sin6_port(void) {
    return offsetof(struct sockaddr_in6, sin6_port);
}
size_t oracle_offset_sockaddr_in6_sin6_flowinfo(void) {
    return offsetof(struct sockaddr_in6, sin6_flowinfo);
}
size_t oracle_offset_sockaddr_in6_sin6_addr(void) {
    return offsetof(struct sockaddr_in6, sin6_addr);
}
size_t oracle_offset_sockaddr_in6_sin6_scope_id(void) {
    return offsetof(struct sockaddr_in6, sin6_scope_id);
}
#if defined(__APPLE__)
size_t oracle_offset_sockaddr_in6_sin6_len(void) {
    return offsetof(struct sockaddr_in6, sin6_len);
}
#endif

void oracle_fill_sockaddr_in6(struct sockaddr_in6 *a) {
    memset(a, 0, sizeof(*a));
#if defined(__APPLE__)
    a->sin6_len = sizeof(*a);
#endif
    a->sin6_family = AF_INET6;
    a->sin6_port = PAT_SIN6_PORT;
    a->sin6_flowinfo = PAT_SIN6_FLOWINFO;
    for (int i = 0; i < 16; i++) {
        a->sin6_addr.s6_addr[i] = PAT_SIN6_ADDR_BYTE(i);
    }
    a->sin6_scope_id = PAT_SIN6_SCOPE_ID;
}

int oracle_check_sockaddr_in6(const struct sockaddr_in6 *a) {
    int ok = 1;
    if (a->sin6_family != AF_INET6) {
        note_mismatch("sockaddr_in6", "sin6_family");
        ok = 0;
    }
    if (a->sin6_port != PAT_SIN6_PORT) {
        note_mismatch("sockaddr_in6", "sin6_port");
        ok = 0;
    }
    if (a->sin6_flowinfo != PAT_SIN6_FLOWINFO) {
        note_mismatch("sockaddr_in6", "sin6_flowinfo");
        ok = 0;
    }
    for (int i = 0; i < 16; i++) {
        if (a->sin6_addr.s6_addr[i] != PAT_SIN6_ADDR_BYTE(i)) {
            note_mismatch("sockaddr_in6", "sin6_addr");
            ok = 0;
            break;
        }
    }
    if (a->sin6_scope_id != PAT_SIN6_SCOPE_ID) {
        note_mismatch("sockaddr_in6", "sin6_scope_id");
        ok = 0;
    }
    return ok;
}

/* ==================================================================== */
/* struct sockaddr_un                                                    */
/* ==================================================================== */

size_t oracle_sizeof_sockaddr_un(void) { return sizeof(struct sockaddr_un); }
size_t oracle_alignof_sockaddr_un(void) {
    return _Alignof(struct sockaddr_un);
}
size_t oracle_offset_sockaddr_un_sun_family(void) {
    return offsetof(struct sockaddr_un, sun_family);
}
size_t oracle_offset_sockaddr_un_sun_path(void) {
    return offsetof(struct sockaddr_un, sun_path);
}
size_t oracle_sun_path_capacity(void) {
    struct sockaddr_un u;
    return sizeof(u.sun_path);
}
#if defined(__APPLE__)
size_t oracle_offset_sockaddr_un_sun_len(void) {
    return offsetof(struct sockaddr_un, sun_len);
}
#endif

void oracle_fill_sockaddr_un(struct sockaddr_un *a) {
    memset(a, 0, sizeof(*a));
#if defined(__APPLE__)
    a->sun_len = sizeof(*a);
#endif
    a->sun_family = AF_UNIX;
    strncpy(a->sun_path, PAT_SUN_PATH, sizeof(a->sun_path) - 1);
}

int oracle_check_sockaddr_un(const struct sockaddr_un *a) {
    int ok = 1;
    if (a->sun_family != AF_UNIX) {
        note_mismatch("sockaddr_un", "sun_family");
        ok = 0;
    }
    if (strncmp(a->sun_path, PAT_SUN_PATH, strlen(PAT_SUN_PATH)) != 0) {
        note_mismatch("sockaddr_un", "sun_path");
        ok = 0;
    }
    return ok;
}

/* ==================================================================== */
/* struct iovec                                                          */
/* ==================================================================== */

size_t oracle_sizeof_iovec(void) { return sizeof(struct iovec); }
size_t oracle_alignof_iovec(void) { return _Alignof(struct iovec); }
size_t oracle_offset_iovec_iov_base(void) {
    return offsetof(struct iovec, iov_base);
}
size_t oracle_offset_iovec_iov_len(void) {
    return offsetof(struct iovec, iov_len);
}

void oracle_fill_iovec(struct iovec *v) {
    v->iov_base = (void *)PAT_IOV_BASE_ADDR;
    v->iov_len = (size_t)PAT_IOV_LEN;
}

int oracle_check_iovec(const struct iovec *v) {
    int ok = 1;
    if ((uintptr_t)v->iov_base != PAT_IOV_BASE_ADDR) {
        note_mismatch("iovec", "iov_base");
        ok = 0;
    }
    if ((uint64_t)v->iov_len != PAT_IOV_LEN) {
        note_mismatch("iovec", "iov_len");
        ok = 0;
    }
    return ok;
}

/* ==================================================================== */
/* struct kevent (BSD/macOS only)                                        */
/* ==================================================================== */

#if defined(SPIKE_HAVE_KQUEUE)
int oracle_has_kevent(void) { return 1; }
size_t oracle_sizeof_kevent(void) { return sizeof(struct kevent); }
size_t oracle_alignof_kevent(void) { return _Alignof(struct kevent); }
size_t oracle_offset_kevent_ident(void) {
    return offsetof(struct kevent, ident);
}
size_t oracle_offset_kevent_filter(void) {
    return offsetof(struct kevent, filter);
}
size_t oracle_offset_kevent_flags(void) {
    return offsetof(struct kevent, flags);
}
size_t oracle_offset_kevent_fflags(void) {
    return offsetof(struct kevent, fflags);
}
size_t oracle_offset_kevent_data(void) {
    return offsetof(struct kevent, data);
}
size_t oracle_offset_kevent_udata(void) {
    return offsetof(struct kevent, udata);
}

void oracle_fill_kevent(struct kevent *k) {
    memset(k, 0, sizeof(*k));
    k->ident = (uintptr_t)PAT_KEV_IDENT;
    k->filter = PAT_KEV_FILTER;
    k->flags = PAT_KEV_FLAGS;
    k->fflags = PAT_KEV_FFLAGS;
    k->data = PAT_KEV_DATA;
    k->udata = (void *)PAT_KEV_UDATA;
}

int oracle_check_kevent(const struct kevent *k) {
    int ok = 1;
    if ((uintptr_t)k->ident != PAT_KEV_IDENT) { note_mismatch("kevent", "ident"); ok = 0; }
    if (k->filter != PAT_KEV_FILTER) { note_mismatch("kevent", "filter"); ok = 0; }
    if (k->flags != PAT_KEV_FLAGS) { note_mismatch("kevent", "flags"); ok = 0; }
    if (k->fflags != PAT_KEV_FFLAGS) { note_mismatch("kevent", "fflags"); ok = 0; }
    if ((intptr_t)k->data != PAT_KEV_DATA) { note_mismatch("kevent", "data"); ok = 0; }
    if ((uintptr_t)k->udata != PAT_KEV_UDATA) { note_mismatch("kevent", "udata"); ok = 0; }
    return ok;
}
#else
int oracle_has_kevent(void) { return 0; }
#endif

/* ==================================================================== */
/* struct epoll_event (Linux only)                                       */
/* ==================================================================== */

#if defined(SPIKE_HAVE_EPOLL)
int oracle_has_epoll_event(void) { return 1; }
size_t oracle_sizeof_epoll_event(void) { return sizeof(struct epoll_event); }
size_t oracle_alignof_epoll_event(void) {
    return _Alignof(struct epoll_event);
}
size_t oracle_offset_epoll_event_events(void) {
    return offsetof(struct epoll_event, events);
}
size_t oracle_offset_epoll_event_data(void) {
    return offsetof(struct epoll_event, data);
}
/* Is this the __attribute__((packed)) x86-64 layout or the natural-align
 * AArch64 layout? The unambiguous, portable test: does sizeof == 12
 * (packed, no padding after the 4-byte events field before the 8-byte
 * data union) or == 16 (natural 8-byte alignment of the union pads
 * events out to 8 first)? Reported as a fact, not asserted either way. */
int oracle_epoll_event_is_packed(void) {
    return sizeof(struct epoll_event) == 12;
}

void oracle_fill_epoll_event(struct epoll_event *e) {
    memset(e, 0, sizeof(*e));
    e->events = PAT_EPOLL_EVENTS;
    e->data.u64 = PAT_EPOLL_DATA_U64;
}

int oracle_check_epoll_event(const struct epoll_event *e) {
    int ok = 1;
    if (e->events != PAT_EPOLL_EVENTS) {
        note_mismatch("epoll_event", "events");
        ok = 0;
    }
    if (e->data.u64 != PAT_EPOLL_DATA_U64) {
        note_mismatch("epoll_event", "data.u64");
        ok = 0;
    }
    return ok;
}
#else
int oracle_has_epoll_event(void) { return 0; }
/* Stub bodies so the SYMBOL always exists for the Mojo side to link
 * against (Mojo's runtime `if oracle_has_epoll_event() != 0:` branch does
 * not exempt the linker from resolving the call inside the untaken
 * branch) — never actually invoked on a non-Linux host since every
 * caller gates on oracle_has_epoll_event() first. */
size_t oracle_sizeof_epoll_event(void) { return 0; }
size_t oracle_alignof_epoll_event(void) { return 0; }
size_t oracle_offset_epoll_event_events(void) { return 0; }
size_t oracle_offset_epoll_event_data(void) { return 0; }
int oracle_epoll_event_is_packed(void) { return 0; }
void oracle_fill_epoll_event(void *e) { (void)e; }
int oracle_check_epoll_event(const void *e) { (void)e; return 0; }
#endif

/* ==================================================================== */
/* pthread_attr_t / pthread_mutex_t — opaque blobs, size+align ONLY      */
/* ==================================================================== */

size_t oracle_sizeof_pthread_attr_t(void) { return sizeof(pthread_attr_t); }
size_t oracle_alignof_pthread_attr_t(void) {
    return _Alignof(pthread_attr_t);
}
size_t oracle_sizeof_pthread_mutex_t(void) {
    return sizeof(pthread_mutex_t);
}
size_t oracle_alignof_pthread_mutex_t(void) {
    return _Alignof(pthread_mutex_t);
}

/* Dynamic proof that the reported size is genuinely enough storage for
 * the real libc to use: init a real pthread_attr_t / pthread_mutex_t
 * into caller-sized-and-aligned storage (mirroring how Mojo would
 * allocate an opaque blob) and destroy it. Returns 0 on success. */
int oracle_pthread_attr_roundtrip(void *storage, size_t cap) {
    if (cap < sizeof(pthread_attr_t)) return -1;
    pthread_attr_t *a = (pthread_attr_t *)storage;
    if (pthread_attr_init(a) != 0) return -2;
    size_t stacksize = 0;
    if (pthread_attr_getstacksize(a, &stacksize) != 0) return -3;
    if (pthread_attr_destroy(a) != 0) return -4;
    return 0;
}

int oracle_pthread_mutex_roundtrip(void *storage, size_t cap) {
    if (cap < sizeof(pthread_mutex_t)) return -1;
    pthread_mutex_t *m = (pthread_mutex_t *)storage;
    if (pthread_mutex_init(m, NULL) != 0) return -2;
    if (pthread_mutex_lock(m) != 0) return -3;
    if (pthread_mutex_unlock(m) != 0) return -4;
    if (pthread_mutex_destroy(m) != 0) return -5;
    return 0;
}

/* ==================================================================== */
/* Platform-numeric constants, fetched dynamically so the Mojo side       */
/* never hardcodes a guess (mirrors MJS_SOCK_INET6's comptime-branch      */
/* pattern in native/include/mojito_sys.h, one level down at the raw      */
/* libc layer).                                                          */
/* ==================================================================== */

int oracle_const_AF_INET(void) { return AF_INET; }
int oracle_const_AF_INET6(void) { return AF_INET6; }
int oracle_const_AF_UNIX(void) { return AF_UNIX; }
int oracle_const_SOCK_STREAM(void) { return SOCK_STREAM; }
int oracle_const_SOCK_DGRAM(void) { return SOCK_DGRAM; }
int oracle_const_PROT_NONE(void) { return PROT_NONE; }
int oracle_const_PROT_READ(void) { return PROT_READ; }
int oracle_const_PROT_WRITE(void) { return PROT_WRITE; }
int oracle_const_MAP_PRIVATE(void) { return MAP_PRIVATE; }
int oracle_const_MAP_ANON(void) { return MAP_ANON; }
int oracle_const_SC_PAGESIZE(void) { return (int)_SC_PAGESIZE; }
int oracle_const_O_NONBLOCK(void) { return O_NONBLOCK; }
int oracle_const_O_RDWR(void) { return O_RDWR; }
int oracle_const_O_CREAT(void) { return O_CREAT; }
int oracle_const_F_GETFL(void) { return F_GETFL; }
int oracle_const_F_SETFL(void) { return F_SETFL; }
int oracle_const_CLOCK_MONOTONIC(void) { return (int)CLOCK_MONOTONIC; }
int oracle_const_EBADF(void) { return EBADF; }
int oracle_const_EINVAL(void) { return EINVAL; }
int oracle_const_EAGAIN(void) { return EAGAIN; }
/* FIONREAD's numeric value is a platform-specific _IOR() macro expansion
 * (ioctl is one of #124's named macro-shaped entry points) — fetched
 * dynamically rather than guessed so the Mojo-side ioctl probe never
 * hardcodes a platform assumption. */
unsigned long oracle_const_FIONREAD(void) { return FIONREAD; }

/* ==================================================================== */
/* libc-call oracle: makes the SAME call Mojo is about to make directly, */
/* for the same inputs, so results (incl. errno) can be diffed.          */
/* ==================================================================== */

/* Page size via sysconf(_SC_PAGESIZE) — the oracle's own call. */
long oracle_call_pagesize(void) { return sysconf(_SC_PAGESIZE); }

/* mmap/munmap/mprotect an anonymous private mapping of `len` bytes.
 * Returns the mapping address (0 on failure, with errno set) so the
 * caller can compare against its own mmap's behavior/errno for the same
 * inputs. */
uintptr_t oracle_call_mmap_anon(size_t len, int prot) {
    void *p = mmap(NULL, len, prot, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p == MAP_FAILED) return 0;
    return (uintptr_t)p;
}
int oracle_call_munmap(uintptr_t addr, size_t len) {
    return munmap((void *)addr, len) == 0 ? 0 : -errno;
}
int oracle_call_mprotect(uintptr_t addr, size_t len, int prot) {
    return mprotect((void *)addr, len, prot) == 0 ? 0 : -errno;
}

/* clock_gettime(CLOCK_MONOTONIC) — nanoseconds since an arbitrary epoch,
 * same normalization Mojo will do on its own reading. */
int oracle_call_clock_monotonic_ns(uint64_t *out_ns) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return -errno;
    *out_ns = (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
    return 0;
}

#if defined(__APPLE__)
/* mach_absolute_time + mach_timebase_info — the "honest path" issue #124
 * names for macOS. */
int oracle_call_mach_monotonic_ns(uint64_t *out_ns) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) {
        if (mach_timebase_info(&tb) != KERN_SUCCESS) return -1;
    }
    uint64_t t = mach_absolute_time();
    /* Match the same widening order Mojo will use, to compare exactly. */
    *out_ns = (uint64_t)((__uint128_t)t * tb.numer / tb.denom);
    return 0;
}
#endif

/* socket / close, for return-value + errno comparison against Mojo's own
 * direct calls with identical arguments. */
int oracle_call_socket(int family, int type) {
    int fd = socket(family, type, 0);
    if (fd < 0) return -errno;
    return fd;
}
int oracle_call_close(int fd) {
    return close(fd) == 0 ? 0 : -errno;
}

/* One recv/read/write/send attempt, mirroring the mjs_socket_recv/send
 * "one attempt, never retries" contract this repo already uses, so the
 * Mojo test's own direct call can be diffed 1:1 against this. */
int64_t oracle_call_read(int fd, void *buf, size_t len) {
    ssize_t n = read(fd, buf, len);
    if (n < 0) return -errno;
    return (int64_t)n;
}
int64_t oracle_call_write(int fd, const void *buf, size_t len) {
    ssize_t n = write(fd, buf, len);
    if (n < 0) return -errno;
    return (int64_t)n;
}
int64_t oracle_call_recv(int fd, void *buf, size_t len, int flags) {
    ssize_t n = recv(fd, buf, len, flags);
    if (n < 0) return -errno;
    return (int64_t)n;
}
int64_t oracle_call_send(int fd, const void *buf, size_t len, int flags) {
    ssize_t n = send(fd, buf, len, flags);
    if (n < 0) return -errno;
    return (int64_t)n;
}

/* Deliberate failure-mode helpers: force the SAME 3 distinct errno values
 * the Mojo side must reproduce.
 *   1. EBADF  — close(-1)
 *   2. EINVAL — mprotect() on an address that isn't page-aligned
 *   3. EAGAIN — recv() on a non-blocking socket with nothing queued
 */
int oracle_force_ebadf(void) {
    errno = 0;
    int rc = close(-1);
    return rc == 0 ? 0 : -errno;
}
int oracle_force_einval_mprotect(uintptr_t misaligned_addr) {
    errno = 0;
    int rc = mprotect((void *)misaligned_addr, 4096, PROT_READ);
    return rc == 0 ? 0 : -errno;
}
int oracle_force_eagain_recv(int nonblocking_fd) {
    errno = 0;
    unsigned char b[1];
    ssize_t n = recv(nonblocking_fd, b, sizeof(b), 0);
    return n >= 0 ? (int)n : -errno;
}

/* Create a connected, non-blocking TCP loopback pair for the recv/send
 * round-trip and the EAGAIN case above. Returns 0 on success with the two
 * connected fds in out_a and out_b (both non-blocking); negative -errno on
 * failure. */
int oracle_make_nonblocking_pair(int *out_a, int *out_b) {
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0) return -errno;
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    if (bind(listener, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        int e = errno; close(listener); errno = e; return -e;
    }
    if (listen(listener, 1) != 0) {
        int e = errno; close(listener); errno = e; return -e;
    }
    socklen_t alen = sizeof(addr);
    if (getsockname(listener, (struct sockaddr *)&addr, &alen) != 0) {
        int e = errno; close(listener); errno = e; return -e;
    }
    int client = socket(AF_INET, SOCK_STREAM, 0);
    if (client < 0) {
        int e = errno; close(listener); errno = e; return -e;
    }
    if (connect(client, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        int e = errno; close(listener); close(client); errno = e; return -e;
    }
    int server = accept(listener, NULL, NULL);
    close(listener);
    if (server < 0) {
        int e = errno; close(client); errno = e; return -e;
    }
    int fl_c = fcntl(client, F_GETFL, 0);
    int fl_s = fcntl(server, F_GETFL, 0);
    fcntl(client, F_SETFL, fl_c | O_NONBLOCK);
    fcntl(server, F_SETFL, fl_s | O_NONBLOCK);
    *out_a = client;
    *out_b = server;
    return 0;
}

#ifdef SPIKE_ABI_STANDALONE
static void report_struct(const char *name, size_t sz, size_t al) {
    printf("%-16s size=%-4zu align=%zu\n", name, sz, al);
}

int main(void) {
    printf("=== spike/abi oracle report (this host) ===\n");
    report_struct("timespec", oracle_sizeof_timespec(), oracle_alignof_timespec());
    report_struct("timeval", oracle_sizeof_timeval(), oracle_alignof_timeval());
    printf("  timeval.tv_usec fieldsize=%zu\n", oracle_fieldsizeof_timeval_tv_usec());
    report_struct("sockaddr_in", oracle_sizeof_sockaddr_in(), oracle_alignof_sockaddr_in());
    report_struct("sockaddr_in6", oracle_sizeof_sockaddr_in6(), oracle_alignof_sockaddr_in6());
    report_struct("sockaddr_un", oracle_sizeof_sockaddr_un(), oracle_alignof_sockaddr_un());
    printf("  sun_path capacity=%zu\n", oracle_sun_path_capacity());
    report_struct("iovec", oracle_sizeof_iovec(), oracle_alignof_iovec());
    report_struct("sa_family_t", oracle_sizeof_sa_family_t(), oracle_alignof_sa_family_t());
    report_struct("socklen_t", oracle_sizeof_socklen_t(), oracle_alignof_socklen_t());
    report_struct("pthread_attr_t", oracle_sizeof_pthread_attr_t(), oracle_alignof_pthread_attr_t());
    report_struct("pthread_mutex_t", oracle_sizeof_pthread_mutex_t(), oracle_alignof_pthread_mutex_t());
    if (oracle_has_kevent()) {
        report_struct("kevent", oracle_sizeof_kevent(), oracle_alignof_kevent());
    } else {
        printf("kevent           not available on this host\n");
    }
#if defined(SPIKE_HAVE_EPOLL)
    report_struct("epoll_event", oracle_sizeof_epoll_event(), oracle_alignof_epoll_event());
    printf("  epoll_event packed=%d\n", oracle_epoll_event_is_packed());
#else
    printf("epoll_event      not available on this host (Linux only)\n");
#endif
    printf("has_sin_len=%d\n", oracle_has_sin_len());
    printf("SC_PAGESIZE const=%d actual pagesize=%ld\n", oracle_const_SC_PAGESIZE(), oracle_call_pagesize());
    printf("AF_INET=%d AF_INET6=%d AF_UNIX=%d\n", oracle_const_AF_INET(), oracle_const_AF_INET6(), oracle_const_AF_UNIX());
    printf("O_NONBLOCK=0x%x MAP_ANON=0x%x MAP_PRIVATE=0x%x\n", oracle_const_O_NONBLOCK(), oracle_const_MAP_ANON(), oracle_const_MAP_PRIVATE());
    return 0;
}
#endif

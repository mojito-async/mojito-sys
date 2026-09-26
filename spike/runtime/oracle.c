/*
 * spike/runtime/oracle.c — M1.3 (#126) runtime spike C oracle.
 *
 * This leg is NOT primarily a value-comparison oracle the way spike/abi's
 * was (#124 diffed Mojo's call results against an identical C call for the
 * same inputs). #126 is about whether Mojo itself can DRIVE pthread_create,
 * TLS and the native pollers directly, so most of the proof lives in the
 * Mojo test files. This file supplies three things those tests cannot get
 * any other way:
 *
 *   1. STRUCT/OPAQUE-TYPE FACTS, measured on THIS host, never assumed:
 *      sizeof/alignof for pthread_t and pthread_key_t, both of which are
 *      OPAQUE and platform-divergent (pthread_t is a pointer-sized opaque
 *      struct pointer on Darwin, an unsigned long on Linux/glibc;
 *      pthread_key_t is unsigned long on Darwin (8 bytes), unsigned int on
 *      Linux/glibc (4 bytes) — exactly the kind of fact issue #124 warns
 *      never to hand-copy from a header comment.
 *   2. PLATFORM CONSTANTS the Mojo side needs to build real kevent/
 *      epoll_event registrations directly (EVFILT_ and EV_ filters/flags,
 *      NOTE_TRIGGER on BSD/macOS; EPOLL flags, EFD_ flags on Linux),
 *      fetched with the real headers'
 *      own macros rather than hardcoded numbers.
 *   3. A C-SIDE TLS PROBE: oracle_tls_set_from_c/oracle_tls_get_from_c call
 *      pthread_setspecific/pthread_getspecific directly on a raw key value
 *      Mojo minted via ITS OWN pthread_key_create call, proving the value
 *      each language sets is visible to the other through the same OS key
 *      (issue #126: "a value set from Mojo is visible to C and the other
 *      way round").
 *
 * Build (ad hoc, no Makefile change, mirrors spike/abi/oracle.c):
 *   cc -O2 -g -Wall -Wextra -dynamiclib -o liboracle.dylib oracle.c
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE /* Linux: epoll/eventfd macros */
#endif

#include <errno.h>
#include <pthread.h>
#include <stddef.h> /* offsetof/size_t — do not rely on a transitive include
                     * (spike/abi's #124 lesson: CI's clang is stricter). */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* ==================================================================== */
/* 1. Opaque pthread type facts.                                         */
/* ==================================================================== */

uint64_t oracle_sizeof_pthread_t(void) { return (uint64_t)sizeof(pthread_t); }
uint64_t oracle_alignof_pthread_t(void) { return (uint64_t)_Alignof(pthread_t); }
uint64_t oracle_sizeof_pthread_key_t(void) {
    return (uint64_t)sizeof(pthread_key_t);
}
uint64_t oracle_alignof_pthread_key_t(void) {
    return (uint64_t)_Alignof(pthread_key_t);
}

/* ==================================================================== */
/* 2. Platform constants for direct kqueue/epoll registration from Mojo. */
/* ==================================================================== */

#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) ||     \
    defined(__NetBSD__) || defined(__DragonFly__)
#define ORACLE_HAVE_KQUEUE 1
#include <sys/event.h>
#include <sys/time.h>
#endif

#if defined(ORACLE_HAVE_KQUEUE)
int32_t oracle_const_EVFILT_READ(void) { return (int32_t)EVFILT_READ; }
int32_t oracle_const_EVFILT_WRITE(void) { return (int32_t)EVFILT_WRITE; }
int32_t oracle_const_EVFILT_USER(void) { return (int32_t)EVFILT_USER; }
uint32_t oracle_const_EV_ADD(void) { return (uint32_t)EV_ADD; }
uint32_t oracle_const_EV_DELETE(void) { return (uint32_t)EV_DELETE; }
uint32_t oracle_const_EV_CLEAR(void) { return (uint32_t)EV_CLEAR; }
uint32_t oracle_const_EV_EOF(void) { return (uint32_t)EV_EOF; }
uint32_t oracle_const_NOTE_TRIGGER(void) { return (uint32_t)NOTE_TRIGGER; }
int32_t oracle_has_kqueue(void) { return 1; }
#else
int32_t oracle_const_EVFILT_READ(void) { return 0; }
int32_t oracle_const_EVFILT_WRITE(void) { return 0; }
int32_t oracle_const_EVFILT_USER(void) { return 0; }
uint32_t oracle_const_EV_ADD(void) { return 0; }
uint32_t oracle_const_EV_DELETE(void) { return 0; }
uint32_t oracle_const_EV_CLEAR(void) { return 0; }
uint32_t oracle_const_EV_EOF(void) { return 0; }
uint32_t oracle_const_NOTE_TRIGGER(void) { return 0; }
int32_t oracle_has_kqueue(void) { return 0; }
#endif

#if defined(__linux__)
#define ORACLE_HAVE_EPOLL 1
#include <sys/epoll.h>
#include <sys/eventfd.h>
#endif

#if defined(ORACLE_HAVE_EPOLL)
uint32_t oracle_const_EPOLLIN(void) { return (uint32_t)EPOLLIN; }
uint32_t oracle_const_EPOLLOUT(void) { return (uint32_t)EPOLLOUT; }
uint32_t oracle_const_EPOLLERR(void) { return (uint32_t)EPOLLERR; }
uint32_t oracle_const_EPOLLHUP(void) { return (uint32_t)EPOLLHUP; }
uint32_t oracle_const_EPOLLRDHUP(void) { return (uint32_t)EPOLLRDHUP; }
int32_t oracle_const_EPOLL_CTL_ADD(void) { return (int32_t)EPOLL_CTL_ADD; }
int32_t oracle_const_EPOLL_CTL_MOD(void) { return (int32_t)EPOLL_CTL_MOD; }
int32_t oracle_const_EPOLL_CTL_DEL(void) { return (int32_t)EPOLL_CTL_DEL; }
int32_t oracle_const_EFD_NONBLOCK(void) { return (int32_t)EFD_NONBLOCK; }
int32_t oracle_const_EFD_CLOEXEC(void) { return (int32_t)EFD_CLOEXEC; }
int32_t oracle_has_epoll(void) { return 1; }

uint64_t oracle_sizeof_epoll_event(void) { return (uint64_t)sizeof(struct epoll_event); }
uint64_t oracle_alignof_epoll_event(void) { return (uint64_t)_Alignof(struct epoll_event); }
uint64_t oracle_offset_epoll_event_events(void) {
    return (uint64_t)offsetof(struct epoll_event, events);
}
uint64_t oracle_offset_epoll_event_data(void) {
    return (uint64_t)offsetof(struct epoll_event, data);
}
/* 1 iff the compiler packed struct epoll_event (x86-64 glibc: no padding
 * between the 4-byte events and the 8-byte data union, size 12); 0 for the
 * naturally-aligned form (most other targets, e.g. AArch64: size 16). */
int32_t oracle_epoll_event_is_packed(void) {
    return sizeof(struct epoll_event) == 12 ? 1 : 0;
}
#else
uint32_t oracle_const_EPOLLIN(void) { return 0; }
uint32_t oracle_const_EPOLLOUT(void) { return 0; }
uint32_t oracle_const_EPOLLERR(void) { return 0; }
uint32_t oracle_const_EPOLLHUP(void) { return 0; }
uint32_t oracle_const_EPOLLRDHUP(void) { return 0; }
int32_t oracle_const_EPOLL_CTL_ADD(void) { return 0; }
int32_t oracle_const_EPOLL_CTL_MOD(void) { return 0; }
int32_t oracle_const_EPOLL_CTL_DEL(void) { return 0; }
int32_t oracle_const_EFD_NONBLOCK(void) { return 0; }
int32_t oracle_const_EFD_CLOEXEC(void) { return 0; }
int32_t oracle_has_epoll(void) { return 0; }
uint64_t oracle_sizeof_epoll_event(void) { return 0; }
uint64_t oracle_alignof_epoll_event(void) { return 0; }
uint64_t oracle_offset_epoll_event_events(void) { return 0; }
uint64_t oracle_offset_epoll_event_data(void) { return 0; }
int32_t oracle_epoll_event_is_packed(void) { return 0; }
#endif

/* ==================================================================== */
/* 3. C-side TLS cross-language visibility probe.                        */
/*    `key` travels as a raw uint64_t (widest supported pthread_key_t on */
/*    any target here) and is narrowed to the real pthread_key_t width   */
/*    on the C side — Mojo never needs to know that width itself for     */
/*    this probe, only to hand back exactly what pthread_key_create gave */
/*    it (which oracle_narrow_tls_key below also validates round-trips). */
/* ==================================================================== */

int oracle_tls_set_from_c(uint64_t key, uint64_t value) {
    pthread_key_t k = (pthread_key_t)key;
    return pthread_setspecific(k, (void *)(uintptr_t)value) == 0 ? 0 : -errno;
}

uint64_t oracle_tls_get_from_c(uint64_t key) {
    pthread_key_t k = (pthread_key_t)key;
    return (uint64_t)(uintptr_t)pthread_getspecific(k);
}

/* ==================================================================== */
/* 4. Exact-byte-count write, for eventfd's "writes must be exactly 8    */
/*    bytes" contract. NOT a re-declaration of write() Mojo-side         */
/*    (mojito-sys#195: a custom @extern("write") conflicts with std.io's */
/*    own internal binding the moment both are exercised) -- this is a   */
/*    DIFFERENTLY NAMED C symbol that wraps it, so Mojo never declares    */
/*    "write" itself at all.                                             */
/* ==================================================================== */

int64_t oracle_write_bytes(int32_t fd, const void *buf, uint64_t count) {
    return (int64_t)write(fd, buf, (size_t)count);
}

/* Confirms a pthread_key_t survives a widen-to-uint64/narrow-back round
 * trip losslessly on this host (guards the probe above against silently
 * truncating a real key on a hypothetical wider-than-64-bit key type). */
int32_t oracle_narrow_tls_key_roundtrips(uint64_t key) {
    pthread_key_t k = (pthread_key_t)key;
    return ((uint64_t)k == key) ? 1 : 0;
}

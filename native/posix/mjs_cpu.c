/* mojito-sys S2 — cpu topology + current-thread affinity (issue #52,
 * spec §13).
 *
 * Contract (frozen ABI, additive block `s2-cpu` in mojito_sys.h):
 *   - mjs_cpu_logical()          -> logical CPU count; > 0.
 *   - mjs_cpu_physical(int*)     -> best-effort physical core count;
 *                                   undeterminable => EXACTLY -ENOTSUP with
 *                                   *out untouched (Optional[Int] upstream,
 *                                   SYS-7 divergence visible). Never any
 *                                   other errno.
 *   - mjs_cpu_affinity_set_current(const uint64_t*, unsigned)
 *                                -> pins the CALLING THREAD ONLY. NULL mask
 *                                   or nwords == 0 => -EINVAL. Linux:
 *                                   sched_setaffinity(0, ...). Darwin:
 *                                   thread_policy_set best-effort; hosts
 *                                   without affinity support return
 *                                   exactly -ENOTSUP.
 *
 * Deliberately no get-API (SYS-1): spec §13 asks set-only; verification in
 * tests goes through the kernel's own sched_getaffinity on Linux.
 */
#include <errno.h>

#include "mojito_sys.h"

#include <stdint.h>
#include <unistd.h>

#ifdef __APPLE__
#include <mach/mach.h>
#include <mach/thread_policy.h>
#include <sys/sysctl.h>
#endif

#ifdef __linux__
#define _GNU_SOURCE /* CPU_ALLOC / CPU_SET_S */
#include <dirent.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#endif

/* Logical CPU count visible to this process (sysconf/sysctl); > 0. */
int mjs_cpu_logical(void) {
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    if (n <= 0) {
        int e = errno;
        return -(e != 0 ? e : ENOTSUP);
    }
    return n > 2147483647L ? -EOVERFLOW : (int)n;
}

#ifdef __APPLE__
/* Physical core count via sysctl hw.physicalcpu. Anything but a clean
 * positive answer is reported as -ENOTSUP (advisory topology), leaving
 * *out untouched per the frozen out-param contract. */
int mjs_cpu_physical(int *out) {
    int phys = 0;
    size_t len = sizeof(phys);
    if (sysctlbyname("hw.physicalcpu", &phys, &len, NULL, 0) != 0 ||
        phys <= 0)
        return -ENOTSUP;
    *out = phys;
    return 0;
}
#elif defined(__linux__)
/* Best-effort heuristic: count unique (physical_package_id, core_id) pairs
 * across /sys/devices/system/cpu/cpu*/topology. Any host that does not
 * expose the topology files yields -ENOTSUP rather than a guess. */
static int read_sysfs_long(const char *path, long *out) {
    FILE *f = fopen(path, "r");
    if (!f)
        return -1;
    long v = 0;
    int ok = fscanf(f, "%ld", &v) == 1;
    fclose(f);
    if (!ok)
        return -1;
    *out = v;
    return 0;
}

int mjs_cpu_physical(int *out) {
    DIR *d = opendir("/sys/devices/system/cpu");
    if (!d)
        return -ENOTSUP;

    struct pkcore {
        long pkg;
        long core;
    };
    struct pkcore *pairs = NULL;
    size_t n = 0, cap = 0;
    int undetermined = 0;
    struct dirent *de;

    while ((de = readdir(d)) != NULL) {
        long cpu;
        char tail;
        /* Matches "cpuN" only — skips "cpuidle", "cpufreq", "offline"... */
        if (sscanf(de->d_name, "cpu%ld%c", &cpu, &tail) != 1)
            continue;

        char path[256];
        long pkg, core;
        snprintf(path, sizeof(path),
                 "/sys/devices/system/cpu/%s/topology/physical_package_id",
                 de->d_name);
        if (read_sysfs_long(path, &pkg) != 0) {
            undetermined = 1;
            continue;
        }
        snprintf(path, sizeof(path),
                 "/sys/devices/system/cpu/%s/topology/core_id", de->d_name);
        if (read_sysfs_long(path, &core) != 0) {
            undetermined = 1;
            continue;
        }

        int dup = 0;
        for (size_t i = 0; i < n; i++) {
            if (pairs[i].pkg == pkg && pairs[i].core == core) {
                dup = 1;
                break;
            }
        }
        if (dup)
            continue;
        if (n == cap) {
            size_t ncap = cap ? cap * 2 : 64;
            struct pkcore *np = realloc(pairs, ncap * sizeof(*np));
            if (!np) {
                free(pairs);
                closedir(d);
                return -ENOTSUP; /* advisory: never fail hard here */
            }
            pairs = np;
            cap = ncap;
        }
        pairs[n].pkg = pkg;
        pairs[n].core = core;
        n++;
    }
    closedir(d);
    free(pairs);

    /* Partial exposure counts as undeterminable: a half-read topology must
     * not surface as an authoritative Optional[Int] value upstream. */
    if (undetermined || n == 0 || n > 2147483647L)
        return -ENOTSUP;
    *out = (int)n;
    return 0;
}
#else
#error "unsupported platform for s2-cpu"
#endif

int mjs_cpu_affinity_set_current(const uint64_t *mask, unsigned nwords) {
    if (mask == NULL || nwords == 0)
        return -EINVAL;
    if ((size_t)nwords > SIZE_MAX / sizeof(uint64_t))
        return -EINVAL; /* would overflow the byte count below */

#ifdef __linux__
    size_t nbits = (size_t)nwords * 64;
    cpu_set_t *set = CPU_ALLOC(nbits);
    if (!set)
        return -ENOMEM;
    size_t setsize = CPU_ALLOC_SIZE(nbits);
    CPU_ZERO_S(setsize, set);
    for (unsigned w = 0; w < nwords; w++) {
        uint64_t bits = mask[w];
        while (bits) {
            unsigned b = (unsigned)__builtin_ctzll(bits);
            bits &= bits - 1;
            CPU_SET_S((size_t)w * 64 + b, setsize, set);
        }
    }
    /* pid 0 == calling thread ONLY (spec L914-921). */
    int rc = sched_setaffinity(0, setsize, set);
    int saved = errno;
    CPU_FREE(set);
    return rc == 0 ? 0 : -saved;
#elif defined(__APPLE__)
    /* Darwin exposes affinity only as a coarse policy tag; an empty mask
     * selects nothing and is rejected like the Linux kernel would. */
    int any = 0;
    for (unsigned w = 0; w < nwords && !any; w++)
        any = mask[w] != 0;
    if (!any)
        return -EINVAL;

    thread_affinity_policy_data_t pol;
    pol.affinity_tag = 1;
    mach_port_t self = mach_thread_self();
    kern_return_t kr =
        thread_policy_set(self, THREAD_AFFINITY_POLICY, (thread_policy_t)&pol,
                          THREAD_AFFINITY_POLICY_COUNT);
    mach_port_deallocate(mach_task_self(), self);

    switch (kr) {
    case KERN_SUCCESS:
        return 0;
    case KERN_NOT_SUPPORTED:
        return -ENOTSUP; /* common: affinity unsupported (SYS-7 visible) */
    case KERN_INVALID_ARGUMENT:
    case KERN_INVALID_POLICY:
        return -EINVAL;
    default:
        return -EIO;
    }
#else
#error "unsupported platform for s2-cpu"
#endif
}

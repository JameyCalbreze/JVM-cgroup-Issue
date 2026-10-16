/* openlog.c - log every open of a cgroup/meminfo path, to stderr.
 * Used instead of strace (strace needs root to install on this host).
 * Build: gcc -shared -fPIC -o libopenlog.so openlog.c -ldl
 * Use:   LD_PRELOAD=/abs/path/libopenlog.so <cmd>
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>

static void note(const char *fn, const char *path) {
    if (path && (strstr(path, "cgroup") || strstr(path, "meminfo"))) {
        dprintf(2, "[openlog] %s(%s)\n", fn, path);
    }
}

typedef int (*open_fn)(const char *, int, ...);
typedef int (*openat_fn)(int, const char *, int, ...);
typedef FILE *(*fopen_fn)(const char *, const char *);

int open(const char *path, int flags, ...) {
    static open_fn real;
    if (!real) real = (open_fn)dlsym(RTLD_NEXT, "open");
    va_list ap; va_start(ap, flags);
    mode_t mode = va_arg(ap, mode_t);
    va_end(ap);
    note("open", path);
    return real(path, flags, mode);
}

int open64(const char *path, int flags, ...) {
    static open_fn real;
    if (!real) real = (open_fn)dlsym(RTLD_NEXT, "open64");
    va_list ap; va_start(ap, flags);
    mode_t mode = va_arg(ap, mode_t);
    va_end(ap);
    note("open64", path);
    return real(path, flags, mode);
}

int openat(int dirfd, const char *path, int flags, ...) {
    static openat_fn real;
    if (!real) real = (openat_fn)dlsym(RTLD_NEXT, "openat");
    va_list ap; va_start(ap, flags);
    mode_t mode = va_arg(ap, mode_t);
    va_end(ap);
    note("openat", path);
    return real(dirfd, path, flags, mode);
}

int openat64(int dirfd, const char *path, int flags, ...) {
    static openat_fn real;
    if (!real) real = (openat_fn)dlsym(RTLD_NEXT, "openat64");
    va_list ap; va_start(ap, flags);
    mode_t mode = va_arg(ap, mode_t);
    va_end(ap);
    note("openat64", path);
    return real(dirfd, path, flags, mode);
}

FILE *fopen(const char *path, const char *mode) {
    static fopen_fn real;
    if (!real) real = (fopen_fn)dlsym(RTLD_NEXT, "fopen");
    note("fopen", path);
    return real(path, mode);
}

FILE *fopen64(const char *path, const char *mode) {
    static fopen_fn real;
    if (!real) real = (fopen_fn)dlsym(RTLD_NEXT, "fopen64");
    note("fopen64", path);
    return real(path, mode);
}

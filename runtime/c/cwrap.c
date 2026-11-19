/* Fixed-argument wrappers for the C library's varargs functions.
 *
 * The runtime calls a varargs function only here (docs/runtime-port.md): the Auk dialect it is
 * being ported to (docs/lowlevel.md, section 9) has no varargs, and an `extern fn` declares a
 * fixed C prototype, so each wrapper below is one such prototype. Every wrapper passes exactly
 * the arguments its name and signature say; add a wrapper here rather than calling a varargs
 * function anywhere else. Numbers that need no C library (integers, hex) are formatted without
 * printf (str.c, auk__fmt_*). */
#include <fcntl.h>
#include <stdio.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/types.h>

#include "auk_rt.h"

/* open(path, flags, mode): mode is used only with O_CREAT (pass 0 otherwise). The fd, or -1
 * with errno set. */
int auk__c_open(const char *path, int flags, int mode) {
    return open(path, flags, (mode_t)mode);
}

/* shm_open(name, flags, mode) (varargs on macOS, fixed on Linux). */
int auk__c_shm_open(const char *name, int flags, int mode) {
    return shm_open(name, flags, (mode_t)mode);
}

/* fcntl(fd, cmd, arg) for the commands that take an int (F_SETFD, F_SETFL, ...). */
int auk__c_fcntl(int fd, int cmd, int arg) {
    return fcntl(fd, cmd, arg);
}

/* ioctl(fd, request, arg) for the requests that take a pointer (TIOCGWINSZ, ...). */
int auk__c_ioctl_ptr(int fd, unsigned long request, void *arg) {
    return ioctl(fd, request, arg);
}

/* snprintf(buf, cap, "%.*e", prec, v): the length the whole text has (buf may be NULL when cap
 * is 0). */
int auk__c_fmt_e(char *buf, size_t cap, int prec, double v) {
    return snprintf(buf, cap, "%.*e", prec, v);
}

/* snprintf(buf, cap, "%.*f", prec, v), likewise. */
int auk__c_fmt_f(char *buf, size_t cap, int prec, double v) {
    return snprintf(buf, cap, "%.*f", prec, v);
}

/* snprintf(buf, cap, "%g", v), likewise. */
int auk__c_fmt_g(char *buf, size_t cap, double v) {
    return snprintf(buf, cap, "%g", v);
}

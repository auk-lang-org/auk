/* The calls of varargs.auk made by C: the runner compares the two programs' output. */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

static void out(const char *p, int n) {
    write(1, p, (size_t)n);
    write(1, "\n", 1);
}

int main(void) {
    char p[512];
    size_t cap = 512;
    out(p, snprintf(p, cap, "%d %d %d %u %d %u", (int8_t)-5, (int16_t)-300, (int32_t)-70000, (uint8_t)200,
                    (uint16_t)65535, (uint32_t)4000000000u));
    out(p, snprintf(p, cap, "%lld %llu %zu %ld %x %c %d %d", (long long)-9000000000LL, (unsigned long long)-1,
                    (size_t)42, -7L, 0xbeef, 65, 1, 0));
    out(p, snprintf(p, cap, "%.3f %e %g %.*f %.*e %g %g", 3.14159, 0.000123, 1e21, 2, 2.71828, 3, -1234.5,
                    (float)1.5, (float)-0.25));
    const char *s = "auk";
    out(p, snprintf(p, cap, "[%s|%5s|%-5s|%.2s] %p", s, "hi", s, "abcdef", (void *)(uintptr_t)0x1234));
    out(p, snprintf(p, cap,
                    "%d %.1f %d %.1f %d %.1f %d %.1f %d %.1f %d %.1f %d %.1f %d %.1f %d %.1f %d %.1f %d %lld %s",
                    1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5, 5, 5.5, 6, 6.5, 7, 7.5, 8, 8.5, 9, 9.5, 10, 10.5, (int8_t)-11,
                    (long long)1 << 40, "end"));
    int n = snprintf(NULL, 0, "%d-%s-%.3f", 12345, "xyz", 0.5);
    out(p, snprintf(p, cap, "len %d", n));
    printf("printf %d %s %.2f %lu\n", 7, "ok", 0.125, (unsigned long)1 << 63);
    fflush(NULL);
    char path[512];
    snprintf(path, sizeof path, "/tmp/auk-varargs-c-%d", (int)getpid());
    mode_t old = umask(0);
    int fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0640);
    umask(old);
    if (fd < 0) return 1;
    struct stat st;
    if (fstat(fd, &st) != 0) return 2;
    int mode = st.st_mode & 0777;
    int a = fcntl(fd, F_SETFD, FD_CLOEXEC);
    int cloexec = fcntl(fd, F_GETFD);
    int fl = fcntl(fd, F_GETFL);
    int b = fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    int nonblock = (fcntl(fd, F_GETFL) & O_NONBLOCK) != 0;
    close(fd);
    unlink(path);
    out(p, snprintf(p, cap, "open %o setfd %d cloexec %d setfl %d nonblock %d", mode, a, cloexec, b, nonblock));
    return 0;
}

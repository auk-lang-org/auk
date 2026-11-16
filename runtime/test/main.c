/* Test runner for the runtime's C unit tests. */
#include "harness.h"

#include <errno.h>
#include <setjmp.h>
#include <stdarg.h>
#include <sys/wait.h>
#include <unistd.h>

typedef struct {
    const char *name;
    th_fn fn;
} Entry;

static Entry entries[512];
static int nentries;
static jmp_buf jb;
static char failmsg[4096];

void th_register(const char *name, th_fn fn) {
    if (nentries == (int)(sizeof entries / sizeof entries[0])) abort();
    entries[nentries++] = (Entry){name, fn};
}

void th_fail(const char *file, int line, const char *fmt, ...) {
    int n = snprintf(failmsg, sizeof failmsg, "%s:%d: ", file, line);
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(failmsg + n, sizeof failmsg - (size_t)n, fmt, ap);
    va_end(ap);
    longjmp(jb, 1);
}

void th_check_str(const char *file, int line, const char *expr, DuckStr *s, const char *want) {
    bool ok = strcmp(duck_str_cstr(s), want) == 0 && (size_t)duck_str_byte_len(s) == strlen(want);
    if (!ok) {
        char got[1024];
        snprintf(got, sizeof got, "%s", duck_str_cstr(s));
        duck_release(s);
        th_fail(file, line, "%s: got \"%s\", want \"%s\"", expr, got, want);
    }
    duck_release(s);
}

int th_child(void (*fn)(void *), void *ctx, char *out, size_t outn) {
    fflush(stdout);
    fflush(stderr);
    int fds[2];
    if (pipe(fds) < 0) abort();
    pid_t pid = fork();
    if (pid < 0) abort();
    if (pid == 0) {
        close(fds[0]);
        dup2(fds[1], 1);
        dup2(fds[1], 2);
        close(fds[1]);
        fn(ctx);
        fflush(stdout);
        fflush(stderr);
        _exit(0);
    }
    close(fds[1]);
    size_t len = 0;
    char buf[4096];
    for (;;) {
        ssize_t r = read(fds[0], buf, sizeof buf);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) break;
        for (ssize_t i = 0; i < r; i++)
            if (out && len + 1 < outn) out[len++] = buf[i];
    }
    if (out && outn) out[len] = 0;
    close(fds[0]);
    int status;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
    }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    return 128 + WTERMSIG(status);
}

void th_expect_panic(const char *file, int line, void (*fn)(void *), void *ctx, const char *needle) {
    char out[4096];
    int code = th_child(fn, ctx, out, sizeof out);
    if (code != 101) th_fail(file, line, "expected exit 101 (panic), got %d; output:\n%s", code, out);
    if (!strstr(out, "panic: ")) th_fail(file, line, "no 'panic:' in output:\n%s", out);
    if (needle && !strstr(out, needle)) th_fail(file, line, "panic output lacks \"%s\":\n%s", needle, out);
}

static char tmpdir[512];

const char *th_tmpdir(void) {
    if (!tmpdir[0]) {
        const char *base = getenv("TMPDIR");
        snprintf(tmpdir, sizeof tmpdir, "%s/duckrt-XXXXXX", base && *base ? base : "/tmp");
        if (!mkdtemp(tmpdir)) {
            perror("mkdtemp");
            abort();
        }
    }
    return tmpdir;
}

int main(int argc, char **argv) {
    const char *filter = argc > 1 ? argv[1] : NULL;
    int passed = 0, failed = 0;
    for (int i = 0; i < nentries; i++) {
        if (filter && !strstr(entries[i].name, filter)) continue;
        int64_t live0 = duck_live_objects();
        failmsg[0] = 0;
        if (setjmp(jb) == 0) {
            entries[i].fn();
            int64_t live1 = duck_live_objects();
            if (live1 != live0)
                snprintf(failmsg, sizeof failmsg, "leak check: %lld live objects before, %lld after", (long long)live0,
                         (long long)live1);
        }
        if (failmsg[0]) {
            printf("FAIL %s\n    %s\n", entries[i].name, failmsg);
            failed++;
        } else {
            printf("ok %s\n", entries[i].name);
            passed++;
        }
        fflush(stdout);
    }
    if (tmpdir[0]) {
        char cmd[600];
        snprintf(cmd, sizeof cmd, "rm -rf '%s'", tmpdir);
        if (system(cmd) != 0) fprintf(stderr, "warning: could not remove %s\n", tmpdir);
    }
    printf("%d passed, %d failed\n", passed, failed);
    return failed ? 1 : 0;
}

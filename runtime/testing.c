/* Contracts, holes, assert, peek, the test registry/runner and program entry. */
#include "duck_internal.h"

#include <errno.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

void duck_requires_fail(const char *loc, const char *cond_text) { duck_panic(loc, "requires failed: %s", cond_text); }
void duck_ensures_fail(const char *loc, const char *cond_text) { duck_panic(loc, "ensures failed: %s", cond_text); }
void duck_hole(const char *loc, const char *expected) { duck_panic(loc, "unfilled hole (expected %s)", expected); }
void duck_assert_fail(const char *loc, const char *cond_text) { duck_panic(loc, "assertion failed: %s", cond_text); }
void duck_assert_fail_cmp(const char *loc, const char *cond_text, const DuckStr *left, const DuckStr *right) {
    duck_panic(loc, "assertion failed: %s\n  left: %s\n  right: %s", cond_text, duck_str_cstr(left),
               duck_str_cstr(right));
}

void duck_peek(const char *loc, const char *src_text, const DuckStr *shown) {
    fflush(stdout);
    flockfile(stderr);
    fprintf(stderr, "[%s] %s = %s\n", loc, src_text, duck_str_cstr(shown));
    funlockfile(stderr);
    if (duck_trace_live) duck__trace_peek(loc, src_text, shown);
}

/* ---- tests -------------------------------------------------------------- */

typedef struct {
    const char *name;
    DuckTestFn fn;
} TestEntry;

static TestEntry *tests;
static int64_t ntests, captests;

void duck_test_register(const char *name, DuckTestFn fn) {
    if (ntests == captests) {
        captests = captests ? captests * 2 : 16;
        tests = duck__xrealloc(tests, (size_t)captests * sizeof *tests);
    }
    tests[ntests++] = (TestEntry){name, fn};
}

static void print_indented(const char *p, size_t n) {
    size_t i = 0;
    while (i < n) {
        size_t j = i;
        while (j < n && p[j] != '\n') j++;
        printf("    %.*s\n", (int)(j - i), p + i);
        i = j + 1;
    }
}

/* Print a test's trace tail (tail mode) under its FAIL line. */
static void print_trace(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return;
    DuckStrBuf b = DUCK_SB_INIT;
    char buf[4096];
    size_t r;
    while ((r = fread(buf, 1, sizeof buf, f)) > 0) duck_sb_bytes(&b, buf, (int64_t)r);
    fclose(f);
    if (b.len) {
        printf("    trace (last events, oldest first):\n");
        print_indented(b.buf, (size_t)b.len);
    }
    duck_sb_free(&b);
}

int duck_test_main(int argc, char **argv) {
    duck_env_set_args(argc, argv);
    const char *filter = argc > 1 ? argv[1] : NULL;
    int64_t passed = 0, failed = 0;
    bool tail = duck__trace_tail_mode();
    bool traced = tail || duck__trace_dir();
    char tail_path[1024] = {0};
    if (tail) {
        const char *tmp = getenv("TMPDIR");
        snprintf(tail_path, sizeof tail_path, "%s/duck-trace-%lld.jsonl", tmp && *tmp ? tmp : "/tmp", (long long)getpid());
    }
    for (int64_t t = 0; t < ntests; t++) {
        if (filter && !strstr(tests[t].name, filter)) continue;
        fflush(stdout);
        fflush(stderr);
        int fds[2];
        if (pipe(fds) < 0) duck_panic("duck test", "pipe: %s", strerror(errno));
        pid_t pid = fork();
        if (pid < 0) duck_panic("duck test", "fork: %s", strerror(errno));
        if (pid == 0) {
            close(fds[0]);
            dup2(fds[1], 1);
            dup2(fds[1], 2);
            close(fds[1]);
            if (traced) duck__trace_test_begin(tests[t].name, tail ? tail_path : NULL);
            DuckErr *e = tests[t].fn();
            if (e) {
                DuckStr *s = duck_err_show(e);
                fflush(stdout);
                fprintf(stderr, "error: %s\n", duck_str_cstr(s));
                fflush(stderr);
                duck__trace_flush();
                _exit(1);
            }
            duck__trace_flush();
            if (duck_leak_check() != 0) _exit(1);
            fflush(stdout);
            fflush(stderr);
            _exit(0);
        }
        close(fds[1]);
        DuckStrBuf out = DUCK_SB_INIT;
        char buf[4096];
        for (;;) {
            ssize_t r = read(fds[0], buf, sizeof buf);
            if (r < 0 && errno == EINTR) continue;
            if (r <= 0) break;
            duck_sb_bytes(&out, buf, r);
        }
        close(fds[0]);
        int status = 0;
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
        }
        bool ok = WIFEXITED(status) && WEXITSTATUS(status) == 0;
        if (traced) duck__trace_test_end(tests[t].name, ok, tail ? tail_path : NULL);
        if (ok) {
            passed++;
            printf("ok %s\n", tests[t].name);
        } else {
            failed++;
            printf("FAIL %s\n", tests[t].name);
            if (out.len) print_indented(out.buf, (size_t)out.len);
            if (WIFSIGNALED(status)) printf("    (killed by signal %d)\n", WTERMSIG(status));
            if (tail) print_trace(tail_path);
        }
        if (tail) unlink(tail_path);
        duck_sb_free(&out);
    }
    printf("%lld passed, %lld failed\n", (long long)passed, (long long)failed);
    fflush(stdout);
    return failed ? 1 : 0;
}

/* ---- program entry ---------------------------------------------------- */

int duck_main_wrapper(int argc, char **argv, DuckMainFn user_main) {
    duck_env_set_args(argc, argv);
    DuckRes_int r = user_main(duck_env_args());
    fflush(stdout);
    if (!r.ok) {
        DuckStr *s = duck_err_show(r.err);
        fprintf(stderr, "error: %s\n", duck_str_cstr(s));
        duck_release(s);
        duck_release(r.err);
        fflush(stderr);
        if (duck_leak_check() != 0) return 102;
        return 1;
    }
    if (duck_leak_check() != 0) return 102;
    return (int)r.val;
}

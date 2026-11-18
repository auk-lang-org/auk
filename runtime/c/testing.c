/* Contracts, holes, assert, peek, the test registry and runner, and the program entry. */
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include "auk_rt.h"

AUK_API _Noreturn void auk_requires_fail(const char *loc, const char *cond_text) {
    auk__panic3(loc, "requires failed: ", cond_text, NULL);
}

AUK_API _Noreturn void auk_ensures_fail(const char *loc, const char *cond_text) {
    auk__panic3(loc, "ensures failed: ", cond_text, NULL);
}

AUK_API _Noreturn void auk_hole(const char *loc, const char *expected) {
    auk__panic3(loc, "unfilled hole (expected ", expected, ")");
}

AUK_API _Noreturn void auk_assert_fail(const char *loc, const char *cond_text) {
    auk__panic3(loc, "assertion failed: ", cond_text, NULL);
}

AUK_API _Noreturn void auk_assert_fail_cmp(const char *loc, const char *cond_text, const AukStr *left, const AukStr *right) {
    AukStrBuf m = {0};
    auk__sb_put_cstr(&m, "assertion failed: ");
    auk__sb_put_cstr(&m, cond_text);
    auk__sb_put_cstr(&m, "\n  left: ");
    auk_sb_str(&m, left);
    auk__sb_put_cstr(&m, "\n  right: ");
    auk_sb_str(&m, right);
    auk__panic_sb(loc, &m);
}

AUK_API void auk_peek(const char *loc, const char *src_text, const AukStr *shown) {
    fflush(stdout);
    flockfile(stderr);
    fprintf(stderr, "[%s] %s = ", loc, src_text);
    fwrite(auk_str_cstr(shown), 1, (size_t)auk_str_byte_len(shown), stderr);
    fputc('\n', stderr);
    funlockfile(stderr);
    if (atomic_load_explicit(&auk_trace_live, memory_order_relaxed)) {
        auk__trace_peek(loc, src_text, shown);
    }
}

/* ---- tests ------------------------------------------------------------------------------- */

typedef struct TestEntry {
    const char *name; /* a static string of the generated program */
    AukTestFn fn;
} TestEntry;

static pthread_mutex_t tests_lock = PTHREAD_MUTEX_INITIALIZER;
static TestEntry *tests;
static int64_t ntests;
static int64_t captests;

AUK_API void auk_test_register(const char *name, AukTestFn fn) {
    pthread_mutex_lock(&tests_lock);
    if (ntests == captests) {
        captests = captests == 0 ? 16 : captests * 2;
        tests = auk__xrealloc(tests, (size_t)captests * sizeof(TestEntry));
    }
    tests[ntests].name = name;
    tests[ntests].fn = fn;
    ntests++;
    pthread_mutex_unlock(&tests_lock);
}

/* Each line of p[0..n) as `    <line>\n` (a line ends at a NUL byte too). */
static void print_indented(const uint8_t *p, size_t n) {
    size_t i = 0;
    while (i < n) {
        size_t j = i;
        while (j < n && p[j] != '\n') {
            j++;
        }
        size_t len = j - i;
        const void *nul = memchr(p + i, 0, len);
        if (nul != NULL) {
            len = (size_t)((const uint8_t *)nul - (p + i));
        }
        fputs("    ", stdout);
        fwrite(p + i, 1, len, stdout);
        fputc('\n', stdout);
        i = j + 1;
    }
}

/* Read all of fd into a malloc'd buffer (*n bytes). */
static uint8_t *read_fd(int fd, size_t *n) {
    size_t cap = 4096;
    size_t len = 0;
    uint8_t *b = auk__xmalloc(cap);
    for (;;) {
        if (len == cap) {
            cap *= 2;
            b = auk__xrealloc(b, cap);
        }
        ssize_t r = read(fd, b + len, cap - len);
        if (r < 0 && errno == EINTR) {
            continue;
        }
        if (r <= 0) {
            break;
        }
        len += (size_t)r;
    }
    *n = len;
    return b;
}

/* Print a test's trace tail (tail mode) under its FAIL line. */
static void print_trace(const char *path) {
    FILE *f = fopen(path, "rb");
    if (f == NULL) {
        return;
    }
    size_t n;
    uint8_t *b = read_fd(fileno(f), &n);
    fclose(f);
    if (n != 0) {
        fputs("    trace (last events, oldest first):\n", stdout);
        print_indented(b, n);
    }
    free(b);
}

static _Noreturn void sys_fail(const char *what) {
    auk__panic3("auk test", what, ": ", strerror(errno));
}

typedef struct TestRun {
    AukTestFn fn;
    AukErr *err;
} TestRun;

static void run_test(void *p) {
    TestRun *r = p;
    r->err = r->fn();
}

AUK_API int auk_test_main(int argc, char **argv) {
    auk_env_set_args(argc, argv);
    const char *filter = argc > 1 ? argv[1] : NULL;
    int64_t passed = 0;
    int64_t failed = 0;
    bool tail = auk__trace_tail_mode();
    bool traced = tail || auk__trace_dir() != NULL;
    char tail_path[1024] = {0};
    if (tail) {
        const char *tmp = getenv("TMPDIR");
        snprintf(tail_path, sizeof tail_path, "%s/auk-trace-%d.jsonl", tmp != NULL && tmp[0] != 0 ? tmp : "/tmp", (int)getpid());
    }
    const char *tail_ptr = tail ? tail_path : NULL;
    pthread_mutex_lock(&tests_lock);
    int64_t n = ntests;
    TestEntry *list = auk__xmalloc((size_t)(n + 1) * sizeof(TestEntry));
    memcpy(list, tests, (size_t)n * sizeof(TestEntry));
    pthread_mutex_unlock(&tests_lock);
    for (int64_t k = 0; k < n; k++) {
        TestEntry *t = &list[k];
        if (filter != NULL && filter[0] != 0 && strstr(t->name, filter) == NULL) {
            continue;
        }
        fflush(stdout);
        fflush(stderr);
        int fds[2];
        if (pipe(fds) < 0) {
            sys_fail("pipe");
        }
        pid_t pid = fork();
        if (pid < 0) {
            sys_fail("fork");
        }
        if (pid == 0) {
            close(fds[0]);
            dup2(fds[1], 1);
            dup2(fds[1], 2);
            close(fds[1]);
            if (traced) {
                auk__trace_test_begin(t->name, tail_ptr);
            }
            TestRun tr = {t->fn, NULL};
            auk__run_on_big_stack(run_test, &tr);
            AukErr *e = tr.err;
            if (e != NULL) {
                AukStr *s = auk_err_show(e);
                fflush(stdout);
                fputs("error: ", stderr);
                fwrite(auk_str_cstr(s), 1, (size_t)auk_str_byte_len(s), stderr);
                fputc('\n', stderr);
                fflush(stderr);
                auk__trace_flush();
                _exit(1);
            }
            auk__trace_flush();
            if (auk_leak_check() != 0) {
                _exit(1);
            }
            fflush(stdout);
            fflush(stderr);
            _exit(0);
        }
        close(fds[1]);
        size_t olen;
        uint8_t *output = read_fd(fds[0], &olen);
        close(fds[0]);
        int status = 0;
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
        }
        bool ok = WIFEXITED(status) && WEXITSTATUS(status) == 0;
        if (traced) {
            auk__trace_test_end(t->name, ok, tail_ptr);
        }
        if (ok) {
            passed++;
            printf("ok %s\n", t->name);
        } else {
            failed++;
            printf("FAIL %s\n", t->name);
            if (olen != 0) {
                print_indented(output, olen);
            }
            if (WIFSIGNALED(status)) {
                printf("    (killed by signal %d)\n", WTERMSIG(status));
            }
            if (tail) {
                print_trace(tail_path);
            }
        }
        free(output);
        if (tail) {
            unlink(tail_path);
        }
    }
    free(list);
    printf("%lld passed, %lld failed\n", (long long)passed, (long long)failed);
    fflush(stdout);
    return failed != 0 ? 1 : 0;
}

/* ---- program entry ----------------------------------------------------------------------- */

typedef struct MainRun {
    AukMainFn f;
    AukArr *args;
    AukRes_int r;
} MainRun;

static void run_main(void *p) {
    MainRun *m = p;
    m->r = m->f(m->args);
}

AUK_API int auk_main_wrapper(int argc, char **argv, AukMainFn user_main) {
    /* started by a `gui.open` of this same program to own its windows (gui_host) */
    if (getenv("AUK_GUI_HOST") != NULL) {
        return auk__gui_host_main();
    }
    auk_env_set_args(argc, argv);
    /* on a thread with a big stack, where an overflow is a panic */
    MainRun m = {user_main, auk_env_args(), {0}};
    auk__run_on_big_stack(run_main, &m);
    AukRes_int r = m.r;
    fflush(stdout);
    if (!r.ok) {
        AukStr *s = auk_err_show(r.err);
        fputs("error: ", stderr);
        fwrite(auk_str_cstr(s), 1, (size_t)auk_str_byte_len(s), stderr);
        fputc('\n', stderr);
        auk_release(s);
        auk_release(r.err);
        fflush(stderr);
        return auk_leak_check() != 0 ? 102 : 1;
    }
    if (auk_leak_check() != 0) {
        return 102;
    }
    return (int)r.val;
}

/* The runner and the shared helpers (see test.h). Usage: auk_rt_tests [name-filter] */
#include "test.h"

#include <errno.h>
#include <fcntl.h>
#include <ftw.h>
#include <netdb.h>
#include <poll.h>
#include <setjmp.h>
#include <stdarg.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

bool t_in_child = false;

static jmp_buf t_jump;
static bool t_running = false;

/* ---- failing ------------------------------------------------------------------------------ */

_Noreturn void t_fail(const char *file, int line, const char *fmt, ...) {
    va_list ap;
    fflush(stdout);
    fprintf(stderr, "    %s:%d: ", file, line);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fprintf(stderr, "\n");
    fflush(stderr);
    if (t_in_child) _exit(98);
    if (t_running) longjmp(t_jump, 1);
    exit(1);
}

void t_check_text(const char *file, int line, const char *got, const char *want) {
    if (strcmp(got, want) != 0) t_fail(file, line, "got \"%s\", want \"%s\"", got, want);
}

void t_check_has(const char *file, int line, const char *got, const char *needle) {
    if (strstr(got, needle) == NULL) t_fail(file, line, "\"%s\" lacks \"%s\"", got, needle);
}

void t_check_str(const char *file, int line, AukStr *owned, const char *want) {
    int64_t blen = auk_str_byte_len(owned);
    char *got = t_copy(auk_str_cstr(owned), (size_t)blen);
    rel(owned);
    if ((size_t)blen != strlen(want) || memcmp(got, want, (size_t)blen) != 0)
        t_fail(file, line, "got \"%s\", want \"%s\"", got, want);
}

/* ---- scratch memory --------------------------------------------------------------------- */

static char **kept;
static size_t nkept, capkept;

char *t_keep(char *p) {
    if (nkept == capkept) {
        capkept = capkept == 0 ? 16 : capkept * 2;
        kept = realloc(kept, capkept * sizeof *kept);
    }
    kept[nkept++] = p;
    return p;
}

char *t_copy(const char *p, size_t n) {
    char *c = malloc(n + 1);
    if (n > 0) memcpy(c, p, n);
    c[n] = 0;
    return t_keep(c);
}

char *t_fmt(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    char *p = malloc((size_t)n + 1);
    va_start(ap, fmt);
    vsnprintf(p, (size_t)n + 1, fmt, ap);
    va_end(ap);
    return t_keep(p);
}

void t_free_kept(void) {
    for (size_t i = 0; i < nkept; i++) free(kept[i]);
    free(kept);
    kept = NULL;
    nkept = capkept = 0;
}

/* ---- runtime helpers -------------------------------------------------------------------- */

AukStr *s(const char *t) { return auk_str_lit(t); }
void rel(void *p) { auk_release(p); }
void *ret(void *p) { return auk_retain(p); }
const char *text(const AukStr *p) { return auk_str_cstr(p); }
AukErr *err_msg(const char *msg) { return auk__err_bytes(msg, strlen(msg)); }

char *err_text(AukErr *e) {
    AukStr *m = auk_err_show(e);
    char *t = t_copy(auk_str_cstr(m), (size_t)auk_str_byte_len(m));
    rel(m);
    rel(e);
    return t;
}

AukArr *ints(const int64_t *xs, int64_t n) {
    AukArr *a = auk_arr_new(&auk_ops_int, 0);
    for (int64_t i = 0; i < n; i++) auk_arr_push(&a, &xs[i]);
    return a;
}

const int64_t *int_elems(const AukArr *a) {
    return auk_arr_len(a) == 0 ? NULL : (const int64_t *)auk_arr_data(a);
}

void cprint(const char *t) { fputs(t, stdout); }

void sb_push(AukStrBuf *b, const char *t) { auk_sb_bytes(b, t, (int64_t)strlen(t)); }

/* ---- child processes ------------------------------------------------------------------ */

int child(ChildFn f, void *ctx, char **out) {
    int fds[2];
    fflush(NULL);
    if (pipe(fds) != 0) t_fail(__FILE__, __LINE__, "pipe failed");
    pid_t pid = fork();
    if (pid < 0) t_fail(__FILE__, __LINE__, "fork failed");
    if (pid == 0) {
        close(fds[0]);
        dup2(fds[1], 1);
        dup2(fds[1], 2);
        close(fds[1]);
        t_in_child = true;
        f(ctx);
        fflush(stdout);
        fflush(stderr);
        _exit(0);
    }
    close(fds[1]);
    char *buf = NULL;
    size_t n = 0, cap = 0;
    for (;;) {
        if (cap - n < 4096) {
            cap = cap == 0 ? 8192 : cap * 2;
            buf = realloc(buf, cap);
        }
        ssize_t r = read(fds[0], buf + n, cap - n - 1);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) break;
        n += (size_t)r;
    }
    close(fds[0]);
    if (buf == NULL) buf = malloc(1);
    buf[n] = 0;
    *out = t_keep(buf);
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

void t_expect_panic(const char *file, int line, ChildFn f, void *ctx, const char *needle) {
    char *out;
    int code = child(f, ctx, &out);
    if (code != 101) t_fail(file, line, "expected exit 101 (panic), got %d; output:\n%s", code, out);
    if (strstr(out, "panic: ") == NULL) t_fail(file, line, "no 'panic:' in output:\n%s", out);
    if (strstr(out, needle) == NULL) t_fail(file, line, "panic output lacks \"%s\":\n%s", needle, out);
}

/* ---- scratch directories ------------------------------------------------------------------ */

enum { MAX_DIRS = 8 };
static char *dirs[MAX_DIRS];
static int ndirs;

char *tmpdir_new(void) {
    const char *base = getenv("TMPDIR");
    if (base == NULL || base[0] == 0) base = "/tmp";
    size_t bl = strlen(base);
    while (bl > 1 && base[bl - 1] == '/') bl--;
    char *tmpl = t_fmt("%.*s/aukrt-XXXXXX", (int)bl, base);
    if (ndirs == MAX_DIRS) t_fail(__FILE__, __LINE__, "too many scratch directories");
    if (mkdtemp(tmpl) == NULL) t_fail(__FILE__, __LINE__, "mkdtemp failed");
    dirs[ndirs++] = tmpl;
    return tmpl;
}

static int rm_one(const char *path, const struct stat *st, int type, struct FTW *ftw) {
    (void)st;
    (void)type;
    (void)ftw;
    remove(path);
    return 0;
}

/* Remove the scratch directories of the test that just ended. */
static void remove_dirs(void) {
    for (int i = 0; i < ndirs; i++) nftw(dirs[i], rm_one, 16, FTW_DEPTH | FTW_PHYS);
    ndirs = 0;
}

AukStr *tmpdir_path(const char *dir, const char *name) { return s(t_fmt("%s/%s", dir, name)); }

/* ---- network ------------------------------------------------------------------------------- */

static bool probe(const struct addrinfo *ai) {
    int fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
    if (fd < 0) return false;
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    bool ok = false;
    if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) {
        ok = true;
    } else if (errno == EINPROGRESS) {
        struct pollfd p = {fd, POLLOUT, 0};
        if (poll(&p, 1, 3000) == 1) {
            int err = 0;
            socklen_t len = sizeof err;
            ok = getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0 && err == 0;
        }
    }
    close(fd);
    return ok;
}

bool net_tests(void) {
    const char *v = getenv("AUK_NET_TESTS");
    if (v != NULL) return strcmp(v, "1") == 0;
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof hints);
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo("example.com", "443", &hints, &res) != 0) return false;
    bool ok = false;
    for (struct addrinfo *ai = res; ai != NULL && !ok; ai = ai->ai_next) ok = probe(ai);
    freeaddrinfo(res);
    return ok;
}

/* ---- the runner -------------------------------------------------------------------------- */

static int passed, failed;

static void run_one(const TestCase *t) {
    int64_t live0 = auk_live_objects();
    bool ok = false;
    t_running = true;
    if (setjmp(t_jump) == 0) {
        t->fn();
        int64_t live1 = auk_live_objects();
        if (live1 != live0) {
            fflush(stdout);
            fprintf(stderr, "    leak check: %lld live objects before, %lld after\n", (long long)live0,
                    (long long)live1);
        } else {
            ok = true;
        }
    }
    t_running = false;
    remove_dirs();
    t_free_kept();
    fflush(stderr);
    printf("%s %s\n", ok ? "ok" : "FAIL", t->name);
    fflush(stdout);
    if (ok)
        passed++;
    else
        failed++;
}

int main(int argc, char **argv) {
    const char *filter = argc > 1 ? argv[1] : NULL;
    const TestCase *groups[] = {arr_tests, core_tests, io_tests, map_tests, net_tests_list, str_tests};
    for (size_t g = 0; g < sizeof groups / sizeof groups[0]; g++) {
        for (const TestCase *t = groups[g]; t->name != NULL; t++) {
            if (filter != NULL && strstr(t->name, filter) == NULL) continue;
            run_one(t);
        }
    }
    printf("%d passed, %d failed\n", passed, failed);
    return failed == 0 ? 0 : 1;
}

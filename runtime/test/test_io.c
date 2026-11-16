/* Console I/O (stdin, eprint, exit), filesystem extras, binary files and secure random. */
#include "harness.h"

#include <errno.h>
#include <sys/stat.h>
#include <unistd.h>

/* A path inside the run's scratch directory (owned). */
static DuckStr *tpath(const char *name) {
    char buf[1024];
    snprintf(buf, sizeof buf, "%s/%s", th_tmpdir(), name);
    return duck_str_lit(buf);
}

/* ---- stdin ------------------------------------------------------------ */

/* Feed `text` to this (child) process's stdin through a pipe. */
static void feed_stdin(const char *text) {
    int fds[2];
    if (pipe(fds) < 0) abort();
    size_t n = strlen(text);
    if (write(fds[1], text, n) != (ssize_t)n) abort();
    close(fds[1]);
    dup2(fds[0], 0);
    close(fds[0]);
    clearerr(stdin);
}

static void stdin_lines_child(void *p) {
    (void)p;
    feed_stdin("one\r\ntwo\n\nlast");
    DuckOpt_str a = duck_env_read_line();
    DuckOpt_str b = duck_env_read_line();
    printf("[%s][%s]", duck_str_cstr(a.val), duck_str_cstr(b.val));
    duck_release(a.val);
    duck_release(b.val);
    DuckArr *rest = duck_env_lines(); /* "", "last" */
    printf("%lld", (long long)duck_arr_len(rest));
    duck_release(rest);
    DuckOpt_str eof = duck_env_read_line();
    printf(" eof=%d", !eof.some);
    DuckArr *none = duck_env_lines();
    printf(" %lld", (long long)duck_arr_len(none));
    duck_release(none);
    if (duck_live_objects() != 0) printf(" LEAK");
}

static void stdin_all_child(void *p) {
    (void)p;
    feed_stdin("x\n");
    DuckOpt_str a = duck_env_read_line();
    duck_release(a.val);
    feed_stdin("h\xC3\xA9\nllo");
    DuckRes_str r = duck_env_read_all();
    printf("ok=%d [%s]", r.ok, r.ok ? duck_str_cstr(r.val) : "");
    duck_release(r.val);
    feed_stdin("bad \xFF\n");
    DuckRes_str bad = duck_env_read_all();
    DuckStr *msg = bad.ok ? NULL : duck_err_show(bad.err);
    printf(" | ok=%d %s", bad.ok, msg ? duck_str_cstr(msg) : "");
    duck_release(msg);
    duck_release(bad.err);
    feed_stdin("a\xFF" "b\n");
    DuckOpt_str lossy = duck_env_read_line();
    printf(" | %s", duck_str_cstr(lossy.val));
    duck_release(lossy.val);
}

TEST(stdin_read_line_lines_and_all) {
    char out[512];
    CHECK_INT(th_child(stdin_lines_child, NULL, out, sizeof out), 0);
    CHECK(strcmp(out, "[one][two]2 eof=1 0") == 0);
    CHECK_INT(th_child(stdin_all_child, NULL, out, sizeof out), 0);
    CHECK(strstr(out, "ok=1 [h\xC3\xA9\nllo]") == out);
    CHECK(strstr(out, "| ok=0 env.read_all: stdin: invalid UTF-8"));
    CHECK(strstr(out, "| a\xEF\xBF\xBD" "b"));
}

/* ---- eprint / exit ---------------------------------------------------- */

static void eprint_child(void *p) {
    (void)p;
    /* stderr goes to a pipe of its own, so the parent can tell the streams apart */
    int fds[2];
    if (pipe(fds) < 0) abort();
    dup2(fds[1], 2);
    close(fds[1]);
    DuckStr *s = S("to stderr");
    duck_print_lit("to stdout");
    duck_eprint(s);
    duck_release(s);
    fflush(stderr);
    char buf[64] = {0};
    ssize_t n = read(fds[0], buf, sizeof buf - 1);
    printf("err=%.*s", (int)(n > 0 ? n : 0), buf);
}

TEST(eprint_goes_to_stderr) {
    char out[256];
    CHECK_INT(th_child(eprint_child, NULL, out, sizeof out), 0);
    CHECK(strcmp(out, "to stdout\nerr=to stderr\n") == 0);
}

static void exit_child(void *p) {
    printf("unflushed");
    duck_proc_exit(*(int64_t *)p, "t.duck:1:1");
}

static DuckStr *exit_global;
static void exit_cleanup(void) {
    duck_release(exit_global);
    exit_global = NULL;
}
static void exit_leak_child(void *p) {
    setenv("DUCK_LEAK_CHECK", "1", 1);
    exit_global = S("global"); /* released by the cleanup */
    duck_set_cleanup(exit_cleanup);
    DuckStr *leaked = p ? S("leaked") : NULL;
    (void)leaked;
    duck_proc_exit(3, "t.duck:1:1");
}

TEST(proc_exit_flushes_and_checks_leaks) {
    char out[512];
    int64_t code = 7;
    CHECK_INT(th_child(exit_child, &code, out, sizeof out), 7);
    CHECK(strcmp(out, "unflushed") == 0);
    code = 0;
    CHECK_INT(th_child(exit_child, &code, out, sizeof out), 0);
    code = 256;
    EXPECT_PANIC(exit_child, &code, "proc.exit(256): code out of range 0..255\n  at t.duck:1:1");
    code = -1;
    EXPECT_PANIC(exit_child, &code, "out of range");
    CHECK_INT(th_child(exit_leak_child, NULL, out, sizeof out), 3);
    CHECK(strcmp(out, "") == 0);
    CHECK_INT(th_child(exit_leak_child, out, out, sizeof out), 102);
    CHECK(strstr(out, "leak: 1 runtime object(s) still live at exit"));
}

/* ---- fs extras -------------------------------------------------------- */

static void check_ok(DuckRes_unit r, const char *what) {
    if (!r.ok) {
        DuckStr *m = duck_err_show(r.err);
        char buf[512];
        snprintf(buf, sizeof buf, "%s", duck_str_cstr(m));
        duck_release(m);
        duck_release(r.err);
        th_fail(__FILE__, __LINE__, "%s failed: %s", what, buf);
    }
}

/* The Err message of r (owned str), releasing the Err. */
static DuckStr *err_text(DuckErr *e) {
    DuckStr *m = duck_err_show(e);
    duck_release(e);
    return m;
}

TEST(fs_dirs_list_rename_remove) {
    DuckStr *root = tpath("fsx");
    DuckStr *deep = tpath("fsx/a/b/c");
    DuckStr *f1 = tpath("fsx/b.txt");
    DuckStr *f2 = tpath("fsx/a.txt");
    DuckStr *f3 = tpath("fsx/z.txt");
    DuckStr *missing = tpath("fsx/missing");
    CHECK(!duck_fs_exists(root));
    check_ok(duck_fs_mkdir(deep), "mkdir -p");
    check_ok(duck_fs_mkdir(deep), "mkdir existing");
    CHECK(duck_fs_is_dir(deep) && duck_fs_exists(deep));
    DuckStr *x = S("x"), *yn = S("y\n"), *empty = S("");
    check_ok(duck_fs_append(f1, x), "append new");
    check_ok(duck_fs_append(f1, yn), "append more");
    DuckRes_str rd = duck_fs_read(f1);
    CHECK(rd.ok);
    CHECK_STR(rd.val, "xy\n");
    CHECK(duck_fs_exists(f1) && !duck_fs_is_dir(f1));
    check_ok(duck_fs_write(f2, empty), "write");

    DuckRes_unit bad = duck_fs_mkdir(f1); /* a file is in the way */
    CHECK(!bad.ok);
    CHECK(strstr(duck_str_cstr(bad.err->msg), "fs.mkdir"));
    duck_release(bad.err);

    DuckRes_arr ls = duck_fs_list(root);
    CHECK(ls.ok);
    DuckStr *shown = duck_arr_show(ls.val);
    CHECK_STR(shown, "[\"a\", \"a.txt\", \"b.txt\"]");
    duck_release(ls.val);

    check_ok(duck_fs_rename(f1, f3), "rename");
    CHECK(!duck_fs_exists(f1) && duck_fs_exists(f3));
    DuckRes_unit rn = duck_fs_rename(f1, f3);
    CHECK(!rn.ok);
    DuckStr *m = err_text(rn.err);
    CHECK(strstr(duck_str_cstr(m), "fs.rename ") && strstr(duck_str_cstr(m), " -> "));
    duck_release(m);

    DuckRes_unit rm = duck_fs_remove(root); /* not empty */
    CHECK(!rm.ok);
    duck_release(rm.err);
    check_ok(duck_fs_remove(f3), "remove file");
    check_ok(duck_fs_remove(deep), "remove empty dir");
    CHECK(!duck_fs_exists(f3) && !duck_fs_exists(deep));
    rm = duck_fs_remove(missing);
    CHECK(!rm.ok && rm.err->code == ENOENT);
    duck_release(rm.err);

    DuckRes_arr none = duck_fs_list(missing);
    CHECK(!none.ok);
    m = err_text(none.err);
    CHECK(strstr(duck_str_cstr(m), "fs.list ") && strstr(duck_str_cstr(m), "missing"));
    duck_release(m);

    DuckStr *nested = tpath("fsx/no/such/f");
    DuckRes_unit ap = duck_fs_append(nested, x);
    CHECK(!ap.ok);
    duck_release(ap.err);
    duck_release(nested);
    duck_release(x);
    duck_release(yn);
    duck_release(empty);

    duck_release(root);
    duck_release(deep);
    duck_release(f1);
    duck_release(f2);
    duck_release(f3);
    duck_release(missing);
}

TEST(fs_temp_dir_is_fresh) {
    DuckRes_str a = duck_fs_temp_dir();
    DuckRes_str b = duck_fs_temp_dir();
    CHECK(a.ok && b.ok);
    CHECK(!duck_str_eq(a.val, b.val));
    CHECK(duck_fs_is_dir(a.val) && duck_fs_is_dir(b.val));
    struct stat st;
    CHECK(stat(duck_str_cstr(a.val), &st) == 0 && (st.st_mode & 0777) == 0700);
    DuckRes_arr ls = duck_fs_list(a.val);
    CHECK(ls.ok && duck_arr_len(ls.val) == 0);
    duck_release(ls.val);
    check_ok(duck_fs_remove(a.val), "remove a");
    check_ok(duck_fs_remove(b.val), "remove b");
    duck_release(a.val);
    duck_release(b.val);
}

TEST(fs_bytes_round_trip) {
    DuckStr *p = tpath("bytes.bin");
    DuckArr *a = duck_arr_new(&duck_ops_int, 256);
    for (int64_t i = 0; i < 256; i++) {
        int64_t v = (i * 7 + 3) % 256;
        duck_arr_push(&a, &v);
    }
    check_ok(duck_fs_write_bytes(p, a), "write_bytes");
    DuckRes_arr r = duck_fs_read_bytes(p);
    CHECK(r.ok);
    CHECK(duck_arr_eq(r.val, a));
    duck_release(r.val);

    /* out of range: an Err, and the file is left alone */
    int64_t big = 256;
    duck_arr_push(&a, &big);
    DuckRes_unit w = duck_fs_write_bytes(p, a);
    CHECK(!w.ok);
    DuckStr *m = err_text(w.err);
    CHECK(strstr(duck_str_cstr(m), "byte 256 at index 256 is out of range 0..255"));
    duck_release(m);
    r = duck_fs_read_bytes(p);
    CHECK(r.ok && duck_arr_len(r.val) == 256);
    duck_release(r.val);
    int64_t neg = -1;
    DuckArr *b = duck_arr_new(&duck_ops_int, 1);
    duck_arr_push(&b, &neg);
    w = duck_fs_write_bytes(p, b);
    CHECK(!w.ok);
    duck_release(w.err);
    duck_release(b);

    DuckArr *empty = duck_arr_new(&duck_ops_int, 0);
    check_ok(duck_fs_write_bytes(p, empty), "write empty");
    r = duck_fs_read_bytes(p);
    CHECK(r.ok && duck_arr_len(r.val) == 0);
    duck_release(r.val);
    duck_release(empty);

    DuckStr *missing = tpath("nope.bin");
    r = duck_fs_read_bytes(missing);
    CHECK(!r.ok && r.err->code == ENOENT);
    duck_release(r.err);
    duck_release(missing);
    duck_release(a);
    duck_release(p);
}

/* ---- secure random ------------------------------------------------------ */

static void rand_bytes_neg(void *p) {
    (void)p;
    duck_rand_bytes(-1, "r.duck:2:3");
}

TEST(rand_bytes_and_seed) {
    DuckArr *a = duck_rand_bytes(32, "t");
    DuckArr *b = duck_rand_bytes(32, "t");
    CHECK_INT(duck_arr_len(a), 32);
    const int64_t *x = duck_arr_data(a);
    for (int i = 0; i < 32; i++) CHECK(x[i] >= 0 && x[i] <= 255);
    CHECK(!duck_arr_eq(a, b)); /* 2^-256 */
    duck_release(a);
    duck_release(b);
    DuckArr *z = duck_rand_bytes(0, "t");
    CHECK_INT(duck_arr_len(z), 0);
    duck_release(z);
    DuckArr *big = duck_rand_bytes(4096, "t"); /* more than getentropy's 256-byte limit */
    int seen[256] = {0}, distinct = 0;
    const int64_t *y = duck_arr_data(big);
    for (int i = 0; i < 4096; i++)
        if (!seen[y[i]]++) distinct++;
    CHECK(distinct > 200);
    duck_release(big);
    EXPECT_PANIC(rand_bytes_neg, NULL, "rand.bytes(-1): negative count\n  at r.duck:2:3");

    /* a seed makes rand.int/rand.float repeatable */
    duck_rand_seed(42);
    int64_t s1[8];
    for (int i = 0; i < 8; i++) s1[i] = duck_rand_int(0, 1000000);
    double f1 = duck_rand_float();
    duck_rand_seed(42);
    for (int i = 0; i < 8; i++) CHECK_INT(duck_rand_int(0, 1000000), s1[i]);
    CHECK(duck_rand_float() == f1);
    duck_rand_seed(43);
    bool differ = false;
    for (int i = 0; i < 8; i++) differ |= duck_rand_int(0, 1000000) != s1[i];
    CHECK(differ);
    /* ... but never the CSPRNG */
    duck_rand_seed(42);
    a = duck_rand_bytes(16, "t");
    duck_rand_seed(42);
    b = duck_rand_bytes(16, "t");
    CHECK(!duck_arr_eq(a, b));
    duck_release(a);
    duck_release(b);
}

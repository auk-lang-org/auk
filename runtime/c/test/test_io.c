/* Console I/O (stdin, eprint, exit), filesystem extras, binary files and secure random. */
#include "test.h"

#include <errno.h>
#include <sys/stat.h>
#include <unistd.h>

/* ---- stdin -------------------------------------------------------------------------------- */

/* Feed n bytes to this (child) process's stdin through a pipe. */
static void feed_stdin(const char *t, size_t n) {
    int fds[2];
    CHECK(pipe(fds) == 0);
    CHECK(write(fds[1], t, n) == (ssize_t)n);
    close(fds[1]);
    dup2(fds[0], 0);
    close(fds[0]);
    clearerr(stdin);
}
#define FEED(lit) feed_stdin((lit), sizeof(lit) - 1)

static void stdin_lines(void *ctx) {
    int64_t live0 = *(int64_t *)ctx;
    FEED("one\r\ntwo\n\nlast");
    AukOpt_str a = auk_env_read_line();
    AukOpt_str b = auk_env_read_line();
    printf("[%s][%s]", text(a.val), text(b.val));
    rel(a.val);
    rel(b.val);
    AukArr *rest = auk_env_lines(); /* "", "last" */
    printf("%lld", (long long)auk_arr_len(rest));
    rel(rest);
    AukOpt_str eof = auk_env_read_line();
    printf(" eof=%d", !eof.some);
    AukArr *none = auk_env_lines();
    printf(" %lld", (long long)auk_arr_len(none));
    rel(none);
    if (auk_live_objects() != live0) cprint(" LEAK");
}

static void stdin_all(void *ctx) {
    (void)ctx;
    FEED("x\n");
    AukOpt_str a = auk_env_read_line();
    rel(a.val);
    FEED("hé\nllo");
    AukRes_str r = auk_env_read_all();
    printf("ok=%d [%s]", r.ok, r.ok ? text(r.val) : "");
    rel(r.val);
    FEED("bad \xFF\n");
    AukRes_str bad = auk_env_read_all();
    printf(" | ok=%d %s", bad.ok, bad.ok ? "" : err_text(bad.err));
    FEED("a\xFF" "b\n");
    AukOpt_str lossy = auk_env_read_line();
    printf(" | %s", text(lossy.val));
    rel(lossy.val);
}

static void stdin_read_line_lines_and_all(void) {
    int64_t live0 = auk_live_objects();
    char *out;
    int code = child(stdin_lines, &live0, &out);
    CHECK_INT(code, 0);
    CHECK_TEXT(out, "[one][two]2 eof=1 0");
    code = child(stdin_all, NULL, &out);
    CHECK_INT(code, 0);
    if (strncmp(out, "ok=1 [hé\nllo]", strlen("ok=1 [hé\nllo]")) != 0)
        t_fail(__FILE__, __LINE__, "unexpected output: %s", out);
    CHECK_HAS(out, "| ok=0 env.read_all: stdin: invalid UTF-8");
    CHECK_HAS(out, "| a\xEF\xBF\xBD" "b"); /* a U+FFFD b */
}

/* ---- eprint / exit ------------------------------------------------------------------------ */

static void eprint_child(void *ctx) {
    (void)ctx;
    /* stderr goes to a pipe of its own, so the parent can tell the streams apart */
    int fds[2];
    CHECK(pipe(fds) == 0);
    dup2(fds[1], 2);
    close(fds[1]);
    AukStr *x = s("to stderr");
    auk_print_lit("to stdout");
    auk_eprint(x);
    rel(x);
    fflush(stderr);
    char buf[64];
    ssize_t n = read(fds[0], buf, sizeof buf - 1);
    buf[n < 0 ? 0 : n] = 0;
    printf("err=%s", buf);
}

static void eprint_goes_to_stderr(void) {
    char *out;
    int code = child(eprint_child, NULL, &out);
    CHECK_INT(code, 0);
    CHECK_TEXT(out, "to stdout\nerr=to stderr\n");
}

static void exit_child(void *ctx) {
    cprint("unflushed");
    auk_proc_exit(*(int64_t *)ctx, "t.auk:1:1");
}

static AukStr *exit_global;
static void exit_cleanup(void) {
    rel(exit_global);
    exit_global = NULL;
}
static void exit_leak_child(void *ctx) {
    bool leak = *(bool *)ctx;
    setenv("AUK_LEAK_CHECK", "1", 1);
    /* count only this child's objects, not what the forked parent's earlier tests left live */
    auk_leak_baseline();
    exit_global = s("global"); /* released by the cleanup */
    auk_set_cleanup(exit_cleanup);
    AukStr *leaked = leak ? s("leaked") : NULL;
    (void)leaked;
    auk_proc_exit(3, "t.auk:1:1");
}

static void proc_exit_flushes_and_checks_leaks(void) {
    char *out;
    int64_t c7 = 7, c0 = 0, c256 = 256, cneg = -1;
    int code = child(exit_child, &c7, &out);
    CHECK_INT(code, 7);
    CHECK_TEXT(out, "unflushed");
    code = child(exit_child, &c0, &out);
    CHECK_INT(code, 0);
    EXPECT_PANIC(exit_child, &c256, "proc.exit(256): code out of range 0..255\n  at t.auk:1:1");
    EXPECT_PANIC(exit_child, &cneg, "out of range");
    bool no = false, yes = true;
    code = child(exit_leak_child, &no, &out);
    if (code != 3) t_fail(__FILE__, __LINE__, "exit %d; output:\n%s", code, out);
    CHECK_TEXT(out, "");
    code = child(exit_leak_child, &yes, &out);
    if (code != 102) t_fail(__FILE__, __LINE__, "exit %d; output:\n%s", code, out);
    CHECK_HAS(out, "leak: 1 runtime object(s) still live at exit");
}

/* ---- fs extras ---------------------------------------------------------------------------- */

static void check_ok(const char *file, int line, AukRes_unit r, const char *what) {
    if (!r.ok) t_fail(file, line, "%s failed: %s", what, err_text(r.err));
}
#define CHECK_OK(r, what) check_ok(__FILE__, __LINE__, (r), (what))

static void fs_dirs_list_rename_remove(void) {
    char *tmp = tmpdir_new();
    AukStr *root = tmpdir_path(tmp, "fsx");
    AukStr *deep = tmpdir_path(tmp, "fsx/a/b/c");
    AukStr *f1 = tmpdir_path(tmp, "fsx/b.txt");
    AukStr *f2 = tmpdir_path(tmp, "fsx/a.txt");
    AukStr *f3 = tmpdir_path(tmp, "fsx/z.txt");
    AukStr *missing = tmpdir_path(tmp, "fsx/missing");
    CHECK(!auk_fs_exists(root));
    CHECK_OK(auk_fs_mkdir(deep), "mkdir -p");
    CHECK_OK(auk_fs_mkdir(deep), "mkdir existing");
    CHECK(auk_fs_is_dir(deep) && auk_fs_exists(deep));
    AukStr *x = s("x"), *yn = s("y\n"), *empty = s("");
    CHECK_OK(auk_fs_append(f1, x), "append new");
    CHECK_OK(auk_fs_append(f1, yn), "append more");
    AukRes_str rd = auk_fs_read(f1);
    CHECK(rd.ok);
    CHECK_STR(rd.val, "xy\n");
    CHECK(auk_fs_exists(f1) && !auk_fs_is_dir(f1));
    CHECK_OK(auk_fs_write(f2, empty), "write");

    AukRes_unit bad = auk_fs_mkdir(f1); /* a file is in the way */
    CHECK(!bad.ok);
    CHECK_HAS(text(bad.err->msg), "fs.mkdir");
    rel(bad.err);

    AukRes_arr ls = auk_fs_list(root);
    CHECK(ls.ok);
    CHECK_STR(auk_arr_show(ls.val), "[\"a\", \"a.txt\", \"b.txt\"]");
    rel(ls.val);

    CHECK_OK(auk_fs_rename(f1, f3), "rename");
    CHECK(!auk_fs_exists(f1) && auk_fs_exists(f3));
    AukRes_unit rn = auk_fs_rename(f1, f3);
    CHECK(!rn.ok);
    char *m = err_text(rn.err);
    CHECK_HAS(m, "fs.rename ");
    CHECK_HAS(m, " -> ");

    AukRes_unit rm = auk_fs_remove(root); /* not empty */
    CHECK(!rm.ok);
    rel(rm.err);
    CHECK_OK(auk_fs_remove(f3), "remove file");
    CHECK_OK(auk_fs_remove(deep), "remove empty dir");
    CHECK(!auk_fs_exists(f3) && !auk_fs_exists(deep));
    rm = auk_fs_remove(missing);
    CHECK(!rm.ok && rm.err->code == ENOENT);
    rel(rm.err);

    AukRes_arr none = auk_fs_list(missing);
    CHECK(!none.ok);
    m = err_text(none.err);
    CHECK_HAS(m, "fs.list ");
    CHECK_HAS(m, "missing");

    AukStr *nested = tmpdir_path(tmp, "fsx/no/such/f");
    AukRes_unit ap = auk_fs_append(nested, x);
    CHECK(!ap.ok);
    rel(ap.err);
    AukStr *all[] = {nested, x, yn, empty, root, deep, f1, f2, f3, missing};
    for (size_t i = 0; i < sizeof all / sizeof all[0]; i++) rel(all[i]);
}

static void fs_temp_dir_is_fresh(void) {
    AukRes_str a = auk_fs_temp_dir();
    AukRes_str b = auk_fs_temp_dir();
    CHECK(a.ok && b.ok);
    CHECK(!auk_str_eq(a.val, b.val));
    CHECK(auk_fs_is_dir(a.val) && auk_fs_is_dir(b.val));
    struct stat st;
    CHECK(stat(text(a.val), &st) == 0);
    CHECK_INT(st.st_mode & 0777, 0700);
    AukRes_arr ls = auk_fs_list(a.val);
    CHECK(ls.ok && auk_arr_len(ls.val) == 0);
    rel(ls.val);
    CHECK_OK(auk_fs_remove(a.val), "remove a");
    CHECK_OK(auk_fs_remove(b.val), "remove b");
    rel(a.val);
    rel(b.val);
}

static void fs_bytes_round_trip(void) {
    char *tmp = tmpdir_new();
    AukStr *p = tmpdir_path(tmp, "bytes.bin");
    AukArr *a = auk_arr_new(&auk_ops_int, 256);
    for (int64_t i = 0; i < 256; i++) PUSH(int64_t, &a, (i * 7 + 3) % 256);
    CHECK_OK(auk_fs_write_bytes(p, a), "write_bytes");
    AukRes_arr r = auk_fs_read_bytes(p);
    CHECK(r.ok);
    CHECK(auk_arr_eq(r.val, a));
    rel(r.val);

    /* out of range: an Err, and the file is left alone */
    PUSH(int64_t, &a, 256);
    AukRes_unit w = auk_fs_write_bytes(p, a);
    CHECK(!w.ok);
    CHECK_HAS(err_text(w.err), "byte 256 at index 256 is out of range 0..255");
    r = auk_fs_read_bytes(p);
    CHECK(r.ok && auk_arr_len(r.val) == 256);
    rel(r.val);
    AukArr *b = auk_arr_new(&auk_ops_int, 1);
    PUSH(int64_t, &b, -1);
    w = auk_fs_write_bytes(p, b);
    CHECK(!w.ok);
    rel(w.err);
    rel(b);

    AukArr *empty = auk_arr_new(&auk_ops_int, 0);
    CHECK_OK(auk_fs_write_bytes(p, empty), "write empty");
    r = auk_fs_read_bytes(p);
    CHECK(r.ok && auk_arr_len(r.val) == 0);
    rel(r.val);
    rel(empty);

    AukStr *missing = tmpdir_path(tmp, "nope.bin");
    r = auk_fs_read_bytes(missing);
    CHECK(!r.ok && r.err->code == ENOENT);
    rel(r.err);
    rel(missing);
    rel(a);
    rel(p);
}

/* ---- secure random ------------------------------------------------------------------------ */

static void p_rand_bytes(void *c) {
    (void)c;
    auk_rand_bytes(-1, "r.auk:2:3");
}

static void rand_bytes_and_seed(void) {
    const char *t = "t";
    AukArr *a = auk_rand_bytes(32, t);
    AukArr *b = auk_rand_bytes(32, t);
    CHECK_INT(auk_arr_len(a), 32);
    for (int i = 0; i < 32; i++) CHECK(int_elems(a)[i] >= 0 && int_elems(a)[i] <= 255);
    CHECK(!auk_arr_eq(a, b)); /* 2^-256 */
    rel(a);
    rel(b);
    AukArr *z = auk_rand_bytes(0, t);
    CHECK_INT(auk_arr_len(z), 0);
    rel(z);
    AukArr *big = auk_rand_bytes(4096, t); /* more than getentropy's 256-byte limit */
    bool seen[256] = {false};
    int distinct = 0;
    for (int i = 0; i < 4096; i++) {
        int64_t y = int_elems(big)[i];
        if (!seen[y]) {
            seen[y] = true;
            distinct++;
        }
    }
    CHECK(distinct > 200);
    rel(big);
    EXPECT_PANIC(p_rand_bytes, NULL, "rand.bytes(-1): negative count\n  at r.auk:2:3");

    /* a seed makes rand.int/rand.float repeatable */
    auk_rand_seed(42);
    int64_t s1[8];
    for (int i = 0; i < 8; i++) s1[i] = auk_rand_int(0, 1000000);
    double f1 = auk_rand_float();
    auk_rand_seed(42);
    for (int i = 0; i < 8; i++) CHECK_INT(auk_rand_int(0, 1000000), s1[i]);
    CHECK(auk_rand_float() == f1);
    auk_rand_seed(43);
    bool differ = false;
    for (int i = 0; i < 8; i++) differ |= auk_rand_int(0, 1000000) != s1[i];
    CHECK(differ);
    /* ... but never the CSPRNG */
    auk_rand_seed(42);
    a = auk_rand_bytes(16, t);
    auk_rand_seed(42);
    b = auk_rand_bytes(16, t);
    CHECK(!auk_arr_eq(a, b));
    rel(a);
    rel(b);
}

const TestCase io_tests[] = {
    {"stdin_read_line_lines_and_all", stdin_read_line_lines_and_all},
    {"eprint_goes_to_stderr", eprint_goes_to_stderr},
    {"proc_exit_flushes_and_checks_leaks", proc_exit_flushes_and_checks_leaks},
    {"fs_dirs_list_rename_remove", fs_dirs_list_rename_remove},
    {"fs_temp_dir_is_fresh", fs_temp_dir_is_fresh},
    {"fs_bytes_round_trip", fs_bytes_round_trip},
    {"rand_bytes_and_seed", rand_bytes_and_seed},
    {NULL, NULL},
};

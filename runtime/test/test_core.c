/* Arithmetic, Err, Value, closures, tasks, core library and hooks. */
#include "harness.h"

#include <arpa/inet.h>
#include <math.h>
#include <netinet/in.h>
#include <pthread.h>
#include <sys/socket.h>
#include <unistd.h>

/* ---- arithmetic ------------------------------------------------------ */

static void add_ovf(void *p) { (void)p, duck_add(INT64_MAX, 1, "math.duck:1:9"); }
static void sub_ovf(void *p) { (void)p, duck_sub(INT64_MIN, 1, "math.duck:2:9"); }
static void mul_ovf(void *p) { (void)p, duck_mul(INT64_MAX / 2 + 1, 2, "x"); }
static void div_zero(void *p) { (void)p, duck_div(1, 0, "math.duck:4:9"); }
static void mod_zero(void *p) { (void)p, duck_mod(1, 0, "x"); }
static void div_ovf(void *p) { (void)p, duck_div(INT64_MIN, -1, "x"); }
static void neg_ovf(void *p) { (void)p, duck_neg(INT64_MIN, "x"); }
static void pow_ovf(void *p) { (void)p, duck_pow(2, 63, "x"); }
static void pow_neg(void *p) { (void)p, duck_pow(2, -1, "x"); }
static void f2i_nan(void *p) { (void)p, duck_float_to_int(NAN, "x"); }
static void f2i_big(void *p) { (void)p, duck_float_to_int(1e19, "x"); }

TEST(arith_checked) {
    CHECK_INT(duck_add(2, 3, "t"), 5);
    CHECK_INT(duck_sub(2, 3, "t"), -1);
    CHECK_INT(duck_mul(-4, 3, "t"), -12);
    CHECK_INT(duck_div(7, 2, "t"), 3);
    CHECK_INT(duck_div(-7, 2, "t"), -3);
    CHECK_INT(duck_mod(-7, 2, "t"), -1);
    CHECK_INT(duck_mod(INT64_MIN, -1, "t"), 0);
    CHECK_INT(duck_pow(3, 4, "t"), 81);
    CHECK_INT(duck_pow(-2, 63, "t"), INT64_MIN);
    CHECK_INT(duck_pow(7, 0, "t"), 1);
    CHECK_INT(duck_pow(0, 0, "t"), 1);
    CHECK_INT(duck_wadd(INT64_MAX, 1), INT64_MIN);
    CHECK_INT(duck_wsub(INT64_MIN, 1), INT64_MAX);
    CHECK_INT(duck_wmul(INT64_MAX, 2), -2);
    CHECK_INT(duck_float_to_int(-2.9, "t"), -2);
    CHECK(duck_fround(2.5) == 3.0 && duck_fround(-2.5) == -3.0);
    CHECK(duck_fsqrt(16.0) == 4.0 && duck_ffloor(-1.5) == -2.0 && duck_fceil(1.2) == 2.0);
    CHECK(duck_fpow(2.0, 10.0) == 1024.0);
    CHECK(duck_float_cmp(NAN, 1.0) > 0 && duck_float_cmp(1.0, 2.0) < 0);
}

TEST(arith_panics_exit_101) {
    EXPECT_PANIC(add_ovf, NULL, "panic: integer overflow in `+`\n  at math.duck:1:9\n");
    EXPECT_PANIC(sub_ovf, NULL, "integer overflow in `-`");
    EXPECT_PANIC(mul_ovf, NULL, "integer overflow in `*`");
    EXPECT_PANIC(div_zero, NULL, "panic: division by zero\n  at math.duck:4:9");
    EXPECT_PANIC(mod_zero, NULL, "division by zero");
    EXPECT_PANIC(div_ovf, NULL, "integer overflow in `/`");
    EXPECT_PANIC(neg_ovf, NULL, "integer overflow");
    EXPECT_PANIC(pow_ovf, NULL, "integer overflow in `**`");
    EXPECT_PANIC(pow_neg, NULL, "negative exponent");
    EXPECT_PANIC(f2i_nan, NULL, "int(NaN)");
    EXPECT_PANIC(f2i_big, NULL, "out of range");
}

/* ---- Err ------------------------------------------------------------- */

typedef struct {
    int64_t at;
    DuckStr *why;
} BadToken; /* a typed error payload with an RC field */

static void bt_retain(void *p) { duck_retain(((BadToken *)p)->why); }
static void bt_release(void *p) { duck_release(((BadToken *)p)->why); }
static DuckStr *bt_show(const void *p) {
    const BadToken *b = p;
    DuckStrBuf sb = DUCK_SB_INIT;
    duck_sb_printf(&sb, "BadToken(%lld, ", (long long)b->at);
    duck_sb_str_own(&sb, duck_str_quote(b->why));
    duck_sb_lit(&sb, ")");
    return duck_sb_finish(&sb);
}
static const DuckElemOps bt_ops = {sizeof(BadToken), bt_retain, bt_release, NULL, NULL, NULL, bt_show};
enum { TYPE_BADTOKEN = 17, TYPE_OTHER = 18 };

TEST(err_chain_and_payload) {
    DuckErr *root = duck_err_fmt("connection refused");
    root->code = 61;
    DuckStr *m1 = S("fetching config");
    DuckErr *mid = duck_err_wrap(m1, root);
    DuckStr *m2 = S("startup failed");
    DuckErr *top = duck_err_wrap(m2, mid);
    duck_release(root);
    duck_release(mid);
    duck_release(m1);
    duck_release(m2);
    CHECK_STR(duck_err_show(top), "startup failed: fetching config: connection refused");
    CHECK_INT(top->cause->cause->code, 61);
    duck_release(top);

    BadToken bt = {7, S("unexpected '}'")};
    DuckErr *e = duck_err_typed(TYPE_BADTOKEN, &bt, &bt_ops, NULL);
    duck_release(bt.why); /* the error holds its own reference */
    CHECK_STR(duck_err_show(e), "BadToken(7, \"unexpected '}'\")");
    const BadToken *got = duck_err_payload(e, TYPE_BADTOKEN);
    CHECK(got && got->at == 7 && duck_str_eq_lit(got->why, "unexpected '}'"));
    CHECK(duck_err_payload(e, TYPE_OTHER) == NULL);
    DuckStr *ctx = S("parsing a.json");
    DuckErr *w = duck_err_wrap(ctx, e);
    duck_release(ctx);
    duck_release(e);
    CHECK(duck_err_payload(w->cause, TYPE_BADTOKEN) != NULL);
    CHECK_STR(duck_err_show(w), "parsing a.json: BadToken(7, \"unexpected '}'\")");
    duck_release(w);

    /* a long chain frees without recursion problems */
    DuckErr *chain = duck_err_fmt("base");
    for (int i = 0; i < 100000; i++) {
        DuckErr *n = duck_err_wrap(NULL, chain);
        duck_release(chain);
        chain = n;
    }
    duck_release(chain);
}

static void unwrap_err_panics(void *p) {
    (void)p;
    duck_unwrap_err("u.duck:1:1", duck_err_fmt("boom"));
}
static void unwrap_none_panics(void *p) { (void)p, duck_unwrap_none("u.duck:2:2"); }

TEST(err_unwrap_panics) {
    EXPECT_PANIC(unwrap_err_panics, NULL, "boom");
    EXPECT_PANIC(unwrap_none_panics, NULL, "unwrapped `none`\n  at u.duck:2:2");
}

/* ---- Value ----------------------------------------------------------- */

TEST(value_tree) {
    DuckMap *m = duck_value_map_new();
    DuckStr *name = S("duck");
    DuckValue vs = duck_value_str(name);
    duck_value_map_put(&m, "name", vs);
    duck_value_release(vs);
    duck_value_map_put(&m, "age", duck_value_int(3));
    duck_value_map_put(&m, "w", duck_value_float(1.5));
    duck_value_map_put(&m, "ok", duck_value_bool(true));
    duck_value_map_put(&m, "nil", duck_value_null());
    DuckArr *l = duck_value_list_new();
    DuckValue one = duck_value_int(1), two = duck_value_float(2.0);
    duck_arr_push(&l, &one);
    duck_arr_push(&l, &two);
    DuckValue vl = duck_value_list(l);
    duck_value_map_put(&m, "xs", vl);
    duck_value_release(vl);
    DuckValue root = duck_value_map(m);
    CHECK_STR(duck_value_show(root),
              "{\"name\": \"duck\", \"age\": 3, \"w\": 1.5, \"ok\": true, \"nil\": Null, \"xs\": [1, 2.0]}");
    DuckValue copy = duck_value_map(duck_map_copy(m));
    duck_release(copy.u.map); /* duck_value_map retained it */
    CHECK(duck_value_eq(root, copy));
    CHECK(!duck_value_eq(duck_value_int(1), duck_value_float(1.0)));
    CHECK(duck_value_as_float(duck_value_int(2), "t") == 2.0);
    DuckStr *k = S("age");
    DuckValue *age = duck_map_at(duck_value_as_map(root, "t"), &k, "t");
    CHECK_INT(duck_value_as_int(*age, "t"), 3);
    CHECK(strcmp(duck_value_tag_name(DUCK_V_LIST), "List") == 0);
    duck_release(k);
    duck_value_release(copy);
    duck_value_release(root);
    duck_release(m);
    duck_release(l);
    duck_release(name);
}

static void value_mismatch(void *p) {
    (void)p;
    duck_value_as_int(duck_value_bool(true), "v.duck:1:1");
}
TEST(value_accessor_panics) { EXPECT_PANIC(value_mismatch, NULL, "expected Int, got Bool"); }

/* ---- closures & boxes ------------------------------------------------ */

typedef struct {
    DuckEnv base;
    DuckStr *greeting;
    int64_t n;
} GreetEnv;

static int drops;
static void greet_drop(DuckObj *o) {
    drops++;
    duck_release(((GreetEnv *)o)->greeting);
}
static DuckStr *greet_fn(DuckEnv *env, DuckStr *who) {
    GreetEnv *e = (GreetEnv *)env;
    DuckStrBuf b = DUCK_SB_INIT;
    duck_sb_str(&b, e->greeting);
    duck_sb_lit(&b, " ");
    duck_sb_str(&b, who);
    duck_sb_printf(&b, " x%lld", (long long)e->n);
    return duck_sb_finish(&b);
}
typedef DuckStr *(*GreetFn)(DuckEnv *, DuckStr *);

TEST(closures_env_rc) {
    drops = 0;
    GreetEnv *env = duck_obj_alloc(sizeof(GreetEnv), greet_drop);
    env->greeting = S("hi");
    env->n = 2;
    DuckClosure c = {(void *)greet_fn, &env->base};
    DuckArr *fs = duck_arr_new(&duck_ops_closure, 0);
    duck_arr_push(&fs, &c);
    duck_closure_release(c); /* the array holds it now */
    DuckClosure c2 = DUCK_ARR_AT(DuckClosure, fs, 0, "t");
    DuckStr *who = S("duck");
    CHECK_STR(DUCK_CLOSURE_CALL(c2, GreetFn, who), "hi duck x2");
    duck_release(who);
    CHECK_INT(drops, 0);
    duck_release(fs);
    CHECK_INT(drops, 1);
}

/* ---- tasks ------------------------------------------------------------- */

typedef struct {
    int64_t ms;
    DuckStr *tag;
} SleepArgs;

static void sleep_thunk(void *args, void *result) {
    SleepArgs *a = args;
    duck_time_sleep(a->ms);
    DuckStrBuf b = DUCK_SB_INIT;
    duck_sb_str(&b, a->tag);
    duck_sb_lit(&b, " done");
    *(DuckStr **)result = duck_sb_finish(&b);
    duck_release(a->tag); /* the thunk owns its args */
}

TEST(tasks_run_concurrently) {
    int64_t t0 = duck_time_now();
    SleepArgs a1 = {200, S("a")}, a2 = {200, S("b")};
    DuckTask *ts[2];
    ts[0] = duck_task_spawn(sleep_thunk, &a1, sizeof a1, sizeof(DuckStr *), &duck_ops_str);
    ts[1] = duck_task_spawn(sleep_thunk, &a2, sizeof a2, sizeof(DuckStr *), &duck_ops_str);
    DuckStr *outs[2] = {NULL, NULL};
    duck_task_await_all(ts, 2, outs);
    int64_t dt = duck_time_now() - t0;
    CHECK(dt >= 195);
    if (dt >= 350) th_fail(__FILE__, __LINE__, "two 200ms tasks took %lldms", (long long)dt);
    CHECK_STR(outs[0], "a done");
    CHECK_STR(outs[1], "b done");
    /* awaiting again hands out another reference */
    DuckStr *again = NULL;
    duck_task_await(ts[0], &again);
    CHECK_STR(again, "a done");
    duck_release(ts[0]);
    duck_release(ts[1]);
}

static void sum_thunk(void *args, void *result) {
    int64_t n = *(int64_t *)args, s = 0;
    for (int64_t i = 1; i <= n; i++) s = duck_add(s, i, "t");
    *(int64_t *)result = s;
}

TEST(tasks_many_and_unawaited) {
    DuckTask *ts[16];
    for (int64_t i = 0; i < 16; i++) {
        int64_t n = 1000 * (i + 1);
        ts[i] = duck_task_spawn(sum_thunk, &n, sizeof n, sizeof(int64_t), NULL);
    }
    for (int64_t i = 0; i < 16; i++) {
        int64_t r = 0, n = 1000 * (i + 1);
        duck_task_await(ts[i], &r);
        CHECK_INT(r, n * (n + 1) / 2);
        duck_release(ts[i]);
    }
    /* releasing a never-awaited task joins it and releases its result */
    SleepArgs a = {10, S("x")};
    DuckTask *t = duck_task_spawn(sleep_thunk, &a, sizeof a, sizeof(DuckStr *), &duck_ops_str);
    duck_release(t);
}

typedef struct {
    DuckArr *xs;
} PushArgs;

static void shared_push_thunk(void *args, void *result) {
    PushArgs *a = args;
    for (int64_t i = 0; i < 1000; i++) duck_arr_push(&a->xs, &i); /* COW: copies once */
    *(int64_t *)result = duck_arr_len(a->xs);
    duck_release(a->xs);
}

TEST(tasks_atomic_refcounts) {
    DuckArr *xs = duck_arr_new(&duck_ops_int, 0);
    DuckTask *ts[8];
    for (int i = 0; i < 8; i++) {
        PushArgs a = {duck_retain(xs)};
        ts[i] = duck_task_spawn(shared_push_thunk, &a, sizeof a, sizeof(int64_t), NULL);
    }
    int64_t outs[8];
    duck_task_await_all(ts, 8, outs);
    for (int i = 0; i < 8; i++) {
        CHECK_INT(outs[i], 1000);
        duck_release(ts[i]);
    }
    CHECK_INT(duck_arr_len(xs), 0);
    CHECK_INT(duck_refcount(xs), 1);
    duck_release(xs);
}

/* ---- fs ------------------------------------------------------------------ */

TEST(fs_round_trip) {
    char path[600];
    snprintf(path, sizeof path, "%s/hello.txt", th_tmpdir());
    DuckStr *p = S(path), *content = S("line one\nd\xC3\xBC" "ck\r\nlast");
    DuckRes_unit w = duck_fs_write(p, content);
    CHECK(w.ok);
    DuckRes_str r = duck_fs_read(p);
    CHECK(r.ok && duck_str_eq(r.val, content));
    CHECK_INT(duck_str_len(r.val), 19);
    duck_release(r.val);
    DuckRes_arr ls = duck_fs_lines(p);
    CHECK(ls.ok);
    DuckStr *sep = S("|");
    CHECK_STR(duck_arr_join(ls.val, sep), "line one|d\xC3\xBC" "ck|last");
    duck_release(sep);
    duck_release(ls.val);
    duck_release(p);
    duck_release(content);

    DuckStr *missing = S("/definitely/not/here.txt");
    r = duck_fs_read(missing);
    CHECK(!r.ok);
    DuckStr *msg = duck_err_show(r.err);
    CHECK(strstr(duck_str_cstr(msg), "fs.read /definitely/not/here.txt: ") != NULL);
    CHECK(r.err->code != 0);
    duck_release(msg);
    duck_release(r.err);
    ls = duck_fs_lines(missing);
    CHECK(!ls.ok);
    duck_release(ls.err);
    w = duck_fs_write(missing, missing);
    CHECK(!w.ok);
    duck_release(w.err);
    duck_release(missing);

    /* invalid UTF-8 on disk is an Err, not a corrupt str */
    snprintf(path, sizeof path, "%s/bad.bin", th_tmpdir());
    FILE *f = fopen(path, "wb");
    fwrite("ok\xFF", 1, 3, f);
    fclose(f);
    p = S(path);
    r = duck_fs_read(p);
    CHECK(!r.ok);
    msg = duck_err_show(r.err);
    CHECK(strstr(duck_str_cstr(msg), "invalid UTF-8 at byte 2") != NULL);
    duck_release(msg);
    duck_release(r.err);
    duck_release(p);
}

/* ---- proc -------------------------------------------------------------- */

TEST(proc_run) {
    DuckStr *echo = S("echo");
    DuckArr *args = duck_arr_new(&duck_ops_str, 0);
    DuckStr *a1 = S("hello"), *a2 = S("d\xC3\xBC" "ck world");
    duck_arr_push(&args, &a1);
    duck_arr_push(&args, &a2);
    DuckRes_str r = duck_proc_run(echo, args);
    CHECK(r.ok);
    CHECK_STR(r.val, "hello d\xC3\xBC" "ck world\n");
    duck_release(args), duck_release(a1), duck_release(a2), duck_release(echo);

    DuckStr *f = S("false");
    DuckArr *none = duck_arr_new(&duck_ops_str, 0);
    r = duck_proc_run(f, none);
    CHECK(!r.ok);
    CHECK_INT(r.err->code, 1);
    CHECK_STR(duck_err_show(r.err), "proc.run false: exited with status 1");
    duck_release(r.err);
    duck_release(f);

    DuckStr *nope = S("duck-no-such-command-xyz");
    r = duck_proc_run(nope, none);
    CHECK(!r.ok);
    duck_release(r.err);
    duck_release(nope);
    duck_release(none);
}

/* ---- net ----------------------------------------------------------------- */

typedef struct {
    int listen_fd;
} Server;

static void *echo_server(void *p) {
    Server *s = p;
    int fd = accept(s->listen_fd, NULL, NULL);
    if (fd < 0) return NULL;
    char buf[256];
    ssize_t n = recv(fd, buf, sizeof buf, 0);
    if (n > 0) {
        send(fd, "echo:", 5, 0);
        send(fd, buf, (size_t)n, 0);
    }
    close(fd);
    return NULL;
}

TEST(net_tcp_echo) {
    int lfd = socket(AF_INET, SOCK_STREAM, 0);
    CHECK(lfd >= 0);
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    CHECK(bind(lfd, (struct sockaddr *)&addr, sizeof addr) == 0);
    CHECK(listen(lfd, 4) == 0);
    socklen_t len = sizeof addr;
    CHECK(getsockname(lfd, (struct sockaddr *)&addr, &len) == 0);
    int port = ntohs(addr.sin_port);
    Server srv = {lfd};
    pthread_t th;
    pthread_create(&th, NULL, echo_server, &srv);

    DuckStr *host = S("127.0.0.1");
    DuckRes_conn c = duck_net_tcp(host, port);
    CHECK(c.ok);
    DuckStr *msg = S("ping \xF0\x9F\xA6\x86");
    DuckArr *bytes = duck_str_bytes(msg);
    DuckRes_unit w = duck_conn_write(c.val, bytes);
    CHECK(w.ok);
    DuckArr *all = duck_arr_new(&duck_ops_int, 0);
    for (;;) {
        DuckRes_arr r = duck_conn_read(c.val, 4);
        CHECK(r.ok);
        int64_t n = duck_arr_len(r.val);
        duck_arr_extend(&all, r.val);
        duck_release(r.val);
        if (n == 0) break; /* peer closed */
    }
    DuckRes_str s = duck_str_from_utf8(all);
    CHECK(s.ok);
    CHECK_STR(s.val, "echo:ping \xF0\x9F\xA6\x86");
    duck_conn_close(c.val);
    DuckRes_arr after = duck_conn_read(c.val, 10);
    CHECK(!after.ok);
    duck_release(after.err);
    duck_release(c.val);
    duck_release(all), duck_release(bytes), duck_release(msg);
    pthread_join(th, NULL);
    close(lfd);

    /* nothing listening on the port any more: connection refused */
    c = duck_net_tcp(host, port);
    CHECK(!c.ok);
    duck_release(c.err);
    DuckStr *bad = S("no-such-host.invalid");
    c = duck_net_tcp(bad, 80);
    CHECK(!c.ok);
    duck_release(c.err);
    duck_release(bad);

    /* TLS to the closed port fails cleanly too (more in test_net.c) */
    c = duck_net_tls(host, port);
    CHECK(!c.ok);
    duck_release(c.err);
    duck_release(host);
}

/* ---- time, rand, env ----------------------------------------------------- */

TEST(time_rand_env) {
    int64_t t0 = duck_time_now();
    CHECK(t0 > 1600000000000LL);
    duck_time_sleep(20);
    CHECK(duck_time_now() - t0 >= 19);
    bool seen[7] = {0};
    for (int i = 0; i < 2000; i++) {
        int64_t r = duck_rand_int(1, 6);
        CHECK(r >= 1 && r <= 6);
        seen[r] = true;
    }
    for (int i = 1; i <= 6; i++) CHECK(seen[i]);
    CHECK_INT(duck_rand_int(5, 5), 5);
    (void)duck_rand_int(INT64_MIN, INT64_MAX);
    double f = duck_rand_float();
    CHECK(f >= 0 && f < 1);

    setenv("DUCK_TEST_VAR", "qu\xC3\xA4" "ck", 1);
    DuckStr *k = S("DUCK_TEST_VAR"), *k2 = S("DUCK_TEST_UNSET_VAR");
    DuckOpt_str v = duck_env_get(k);
    CHECK(v.some);
    CHECK_STR(v.val, "qu\xC3\xA4" "ck");
    CHECK(!duck_env_get(k2).some);
    duck_release(k), duck_release(k2);

    char *argv[] = {"prog", "a", "b", NULL};
    duck_env_set_args(3, argv);
    DuckArr *args = duck_env_args();
    CHECK_INT(duck_arr_len(args), 3);
    CHECK(duck_str_eq_lit(DUCK_ARR_AT(DuckStr *, args, 2, "t"), "b"));
    duck_release(args); /* immortal: harmless */
}

static void rand_bad(void *p) { (void)p, duck_rand_int(3, 1); }
TEST(rand_bad_range_panics) { EXPECT_PANIC(rand_bad, NULL, "lo > hi"); }

/* ---- hooks ----------------------------------------------------------------- */

static void req_fail(void *p) { (void)p, duck_requires_fail("isqrt.duck:2:12", "n >= 0"); }
static void ens_fail(void *p) { (void)p, duck_ensures_fail("isqrt.duck:3:11", "result * result <= n"); }
static void hole(void *p) { (void)p, duck_hole("isqrt.duck:4:3", "int"); }
static void assert_cmp(void *p) {
    (void)p;
    DuckStr *l = S("1"), *r = S("2");
    duck_assert_fail_cmp("t.duck:9:3", "a == b", l, r);
}
static void peek_child(void *p) {
    (void)p;
    DuckStr *v = duck_str_from_int(84);
    duck_peek("main.duck:7", "x * 2", v);
    duck_release(v);
}

TEST(hooks_contracts_holes_peek) {
    EXPECT_PANIC(req_fail, NULL, "panic: requires failed: n >= 0\n  at isqrt.duck:2:12\n");
    EXPECT_PANIC(ens_fail, NULL, "ensures failed: result * result <= n");
    EXPECT_PANIC(hole, NULL, "unfilled hole (expected int)\n  at isqrt.duck:4:3");
    EXPECT_PANIC(assert_cmp, NULL, "assertion failed: a == b\n  left: 1\n  right: 2");
    char out[256];
    CHECK_INT(th_child(peek_child, NULL, out, sizeof out), 0);
    CHECK(strcmp(out, "[main.duck:7] x * 2 = 84\n") == 0);
}

/* ---- duck_test_main ------------------------------------------------------ */

static DuckErr *t_pass(void) {
    printf("this output is hidden\n");
    return NULL;
}
static DuckErr *t_panic(void) {
    printf("before the panic\n");
    duck_add(INT64_MAX, 1, "tests.duck:5:7");
    return NULL;
}
static DuckErr *t_err(void) { return duck_err_fmt("fail() called"); }

static void run_test_main(void *p) {
    (void)p;
    duck_test_register("passes", t_pass);
    duck_test_register("overflows", t_panic);
    duck_test_register("returns an error", t_err);
    char *argv[] = {"tests", NULL};
    int code = duck_test_main(1, argv);
    fflush(stdout);
    _exit(code == 1 ? 42 : 43);
}

static void run_test_main_filtered(void *p) {
    (void)p;
    duck_test_register("passes", t_pass);
    duck_test_register("overflows", t_panic);
    char *argv[] = {"tests", "pass", NULL};
    _exit(duck_test_main(2, argv) == 0 ? 42 : 43);
}

TEST(test_runner) {
    char out[4096];
    CHECK_INT(th_child(run_test_main, NULL, out, sizeof out), 42);
    const char *want = "ok passes\n"
                       "FAIL overflows\n"
                       "    before the panic\n"
                       "    panic: integer overflow in `+`\n"
                       "      at tests.duck:5:7\n"
                       "FAIL returns an error\n"
                       "    error: fail() called\n"
                       "1 passed, 2 failed\n";
    if (strcmp(out, want) != 0) th_fail(__FILE__, __LINE__, "runner output:\n%s", out);
    CHECK_INT(th_child(run_test_main_filtered, NULL, out, sizeof out), 42);
    CHECK(strcmp(out, "ok passes\n1 passed, 0 failed\n") == 0);
}

/* ---- duck_main_wrapper --------------------------------------------------- */

static DuckRes_int main_ok(DuckArr *args) {
    printf("argc=%lld\n", (long long)duck_arr_len(args));
    return DUCK_OK(DuckRes_int, 7);
}
static DuckRes_int main_err(DuckArr *args) {
    (void)args;
    DuckErr *cause = duck_err_fmt("no such file");
    DuckStr *m = S("loading config");
    DuckErr *e = duck_err_wrap(m, cause);
    duck_release(m);
    duck_release(cause);
    return DUCK_ERR(DuckRes_int, e);
}
static void wrap_ok(void *p) {
    (void)p;
    char *argv[] = {"prog", "x", NULL};
    _exit(duck_main_wrapper(2, argv, main_ok));
}
static void wrap_err(void *p) {
    (void)p;
    char *argv[] = {"prog", NULL};
    _exit(duck_main_wrapper(1, argv, main_err));
}

TEST(main_wrapper) {
    char out[512];
    CHECK_INT(th_child(wrap_ok, NULL, out, sizeof out), 7);
    CHECK(strcmp(out, "argc=2\n") == 0);
    CHECK_INT(th_child(wrap_err, NULL, out, sizeof out), 1);
    CHECK(strcmp(out, "error: loading config: no such file\n") == 0);
}

static void print_child(void *p) {
    (void)p;
    DuckStr *s = S("h\xC3\xA9llo");
    duck_print(s);
    duck_print_lit("bye");
    duck_release(s);
}
TEST(print_lines) {
    char out[64];
    CHECK_INT(th_child(print_child, NULL, out, sizeof out), 0);
    CHECK(strcmp(out, "h\xC3\xA9llo\nbye\n") == 0);
}

/* Compiler-emitted globals (string literals) are made immortal; the cleanup hook and the
 * DUCK_LEAK_CHECK leak check used by `duck test` and duck_main_wrapper. */
static int cleanup_calls;
static DuckStr *cleanup_global;
static void cleanup_fn(void) {
    cleanup_calls++;
    duck_release(cleanup_global);
    cleanup_global = NULL;
}

TEST(immortal_and_leak_check) {
    int64_t live = duck_live_objects();
    DuckStr *lit = duck_str_lit("forever");
    duck_make_immortal(lit);
    CHECK_INT(duck_live_objects(), live);
    duck_retain(lit);
    duck_release(lit);
    duck_release(lit);
    CHECK(duck_str_eq_lit(lit, "forever"));
    duck_make_immortal(NULL);

    /* without DUCK_LEAK_CHECK the check is a no-op */
    unsetenv("DUCK_LEAK_CHECK");
    cleanup_global = duck_str_lit("global");
    duck_set_cleanup(cleanup_fn);
    CHECK_INT(duck_leak_check(), 0);
    CHECK_INT(cleanup_calls, 0);
    /* with it: the cleanup runs first, then live objects are counted */
    setenv("DUCK_LEAK_CHECK", "1", 1);
    CHECK_INT(duck_leak_check() - live, 0);
    CHECK_INT(cleanup_calls, 1);
    CHECK(cleanup_global == NULL);
    unsetenv("DUCK_LEAK_CHECK");
    duck_set_cleanup(NULL);
}

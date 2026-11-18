/* Arithmetic, Err, Value, closures, tasks, core library and hooks. */
#include "test.h"

#include <arpa/inet.h>
#include <math.h>
#include <netinet/in.h>
#include <pthread.h>
#include <sys/socket.h>
#include <unistd.h>

static const char *T = "t";

/* ---- arithmetic ------------------------------------------------------------------------- */

static void arith_checked(void) {
    CHECK_INT(auk_add(2, 3, T), 5);
    CHECK_INT(auk_sub(2, 3, T), -1);
    CHECK_INT(auk_mul(-4, 3, T), -12);
    CHECK_INT(auk_div(7, 2, T), 3);
    CHECK_INT(auk_div(-7, 2, T), -3);
    CHECK_INT(auk_mod(-7, 2, T), -1);
    CHECK_INT(auk_mod(INT64_MIN, -1, T), 0);
    CHECK_INT(auk_pow(3, 4, T), 81);
    CHECK_INT(auk_pow(-2, 63, T), INT64_MIN);
    CHECK_INT(auk_pow(7, 0, T), 1);
    CHECK_INT(auk_pow(0, 0, T), 1);
    CHECK_INT(auk_wadd(INT64_MAX, 1), INT64_MIN);
    CHECK_INT(auk_wsub(INT64_MIN, 1), INT64_MAX);
    CHECK_INT(auk_wmul(INT64_MAX, 2), -2);
    CHECK_INT(auk_float_to_int(-2.9, T), -2);
    CHECK(auk_fround(2.5) == 3.0 && auk_fround(-2.5) == -3.0);
    CHECK(auk_fsqrt(16.0) == 4.0 && auk_ffloor(-1.5) == -2.0 && auk_fceil(1.2) == 2.0);
    CHECK(auk_fpow(2.0, 10.0) == 1024.0);
    CHECK(auk_fsin(0.0) == 0.0 && auk_fcos(0.0) == 1.0 && fabs(auk_fatan2(1.0, 1.0) - M_PI_4) < 1e-15);
    CHECK(auk_fexp(0.0) == 1.0 && auk_fln(1.0) == 0.0 && auk_flog10(1000.0) == 3.0 && auk_flog2(8.0) == 3.0);
    CHECK(fabs(auk_ftan(0.5) - tan(0.5)) < 1e-15 && auk_fasin(1.0) == M_PI_2 && auk_facos(1.0) == 0.0 &&
          auk_fatan(0.0) == 0.0);
    double one_half = 1.5;
    int64_t bits;
    memcpy(&bits, &one_half, sizeof bits);
    CHECK_INT(auk_fbits(1.5), bits);
    CHECK(auk_ffrom_bits(auk_fbits(-0.1)) == -0.1);
    CHECK_INT(auk_fbits32(0.5), 0x3f000000);
    CHECK(auk_ffrom_bits32(0x3f000000) == 0.5 && auk_ffrom_bits32(0xbf800000) == -1.0);
    CHECK(auk_float_cmp(NAN, 1.0) > 0 && auk_float_cmp(1.0, 2.0) < 0);
}

static void p_add(void *c) { (void)c; auk_add(INT64_MAX, 1, "math.auk:1:9"); }
static void p_sub(void *c) { (void)c; auk_sub(INT64_MIN, 1, "math.auk:2:9"); }
static void p_mul(void *c) { (void)c; auk_mul(INT64_MAX / 2 + 1, 2, "x"); }
static void p_div0(void *c) { (void)c; auk_div(1, 0, "math.auk:4:9"); }
static void p_mod0(void *c) { (void)c; auk_mod(1, 0, "x"); }
static void p_div_ovf(void *c) { (void)c; auk_div(INT64_MIN, -1, "x"); }
static void p_neg(void *c) { (void)c; auk_neg(INT64_MIN, "x"); }
static void p_pow(void *c) { (void)c; auk_pow(2, 63, "x"); }
static void p_pow_neg(void *c) { (void)c; auk_pow(2, -1, "x"); }
static void p_nan(void *c) { (void)c; auk_float_to_int(NAN, "x"); }
static void p_big(void *c) { (void)c; auk_float_to_int(1e19, "x"); }

static void arith_panics_exit_101(void) {
    EXPECT_PANIC(p_add, NULL, "panic: integer overflow in `+`\n  at math.auk:1:9\n");
    EXPECT_PANIC(p_sub, NULL, "integer overflow in `-`");
    EXPECT_PANIC(p_mul, NULL, "integer overflow in `*`");
    EXPECT_PANIC(p_div0, NULL, "panic: division by zero\n  at math.auk:4:9");
    EXPECT_PANIC(p_mod0, NULL, "division by zero");
    EXPECT_PANIC(p_div_ovf, NULL, "integer overflow in `/`");
    EXPECT_PANIC(p_neg, NULL, "integer overflow");
    EXPECT_PANIC(p_pow, NULL, "integer overflow in `**`");
    EXPECT_PANIC(p_pow_neg, NULL, "negative exponent");
    EXPECT_PANIC(p_nan, NULL, "int(NaN)");
    EXPECT_PANIC(p_big, NULL, "out of range");
}

/* ---- Err ---------------------------------------------------------------------------------- */

/* A typed error payload with an RC field. */
typedef struct BadToken {
    int64_t at;
    AukStr *why;
} BadToken;

static void bt_retain(void *p) { auk_retain(((BadToken *)p)->why); }
static void bt_release(void *p) { auk_release(((BadToken *)p)->why); }
static AukStr *bt_show(const void *p) {
    const BadToken *b = p;
    AukStrBuf sb = {0};
    char head[64];
    snprintf(head, sizeof head, "BadToken(%lld, ", (long long)b->at);
    sb_push(&sb, head);
    auk_sb_str_own(&sb, auk_str_quote(b->why));
    auk_sb_lit(&sb, ")");
    return auk_sb_finish(&sb);
}
static const AukElemOps BT_OPS = {sizeof(BadToken), bt_retain, bt_release, NULL, NULL, NULL, bt_show, NULL};
enum { TYPE_BADTOKEN = 17, TYPE_OTHER = 18 };

static void err_chain_and_payload(void) {
    AukErr *root = err_msg("connection refused");
    root->code = 61;
    AukStr *m1 = s("fetching config");
    AukErr *mid = auk_err_wrap(m1, root);
    AukStr *m2 = s("startup failed");
    AukErr *top = auk_err_wrap(m2, mid);
    rel(root);
    rel(mid);
    rel(m1);
    rel(m2);
    CHECK_STR(auk_err_show(top), "startup failed: fetching config: connection refused");
    CHECK_INT(top->cause->cause->code, 61);
    rel(top);

    BadToken bt = {7, s("unexpected '}'")};
    AukErr *e = auk_err_typed(TYPE_BADTOKEN, &bt, &BT_OPS, NULL);
    rel(bt.why); /* the error holds its own reference */
    CHECK_STR(auk_err_show(e), "BadToken(7, \"unexpected '}'\")");
    const BadToken *got = auk_err_payload(e, TYPE_BADTOKEN);
    CHECK(got != NULL && got->at == 7 && auk_str_eq_lit(got->why, "unexpected '}'"));
    CHECK(auk_err_payload(e, TYPE_OTHER) == NULL);
    AukStr *ctx = s("parsing a.json");
    AukErr *w = auk_err_wrap(ctx, e);
    rel(ctx);
    rel(e);
    CHECK(auk_err_payload(w->cause, TYPE_BADTOKEN) != NULL);
    CHECK_STR(auk_err_show(w), "parsing a.json: BadToken(7, \"unexpected '}'\")");
    rel(w);

    /* a long chain frees without recursion problems */
    AukErr *chain = err_msg("base");
    for (int i = 0; i < 100000; i++) {
        AukErr *n = auk_err_wrap(NULL, chain);
        rel(chain);
        chain = n;
    }
    rel(chain);
}

static void p_unwrap_err(void *c) { (void)c; auk_unwrap_err("u.auk:1:1", err_msg("boom")); }
static void p_unwrap_none(void *c) { (void)c; auk_unwrap_none("u.auk:2:2"); }

static void err_unwrap_panics(void) {
    EXPECT_PANIC(p_unwrap_err, NULL, "boom");
    EXPECT_PANIC(p_unwrap_none, NULL, "unwrapped `none`\n  at u.auk:2:2");
}

/* ---- Value -------------------------------------------------------------------------------- */

static void value_tree(void) {
    AukMap *m = auk_value_map_new();
    AukStr *name = s("auk");
    AukValue vs = auk_value_str(name);
    auk_value_map_put(&m, "name", vs);
    auk_value_release(vs);
    auk_value_map_put(&m, "age", auk_value_int(3));
    auk_value_map_put(&m, "w", auk_value_float(1.5));
    auk_value_map_put(&m, "ok", auk_value_bool(true));
    auk_value_map_put(&m, "nil", auk_value_null());
    AukArr *l = auk_value_list_new();
    AukValue one = auk_value_int(1), two = auk_value_float(2.0);
    auk_arr_push(&l, &one);
    auk_arr_push(&l, &two);
    AukValue vl = auk_value_list(l);
    auk_value_map_put(&m, "xs", vl);
    auk_value_release(vl);
    AukValue root = auk_value_map(m);
    CHECK_STR(auk_value_show(root),
              "{\"name\": \"auk\", \"age\": 3, \"w\": 1.5, \"ok\": true, \"nil\": Null, \"xs\": [1, 2.0]}");
    AukValue copy = auk_value_map(auk_map_copy(m));
    rel(copy.u.map); /* auk_value_map retained it */
    CHECK(auk_value_eq(root, copy));
    CHECK(!auk_value_eq(auk_value_int(1), auk_value_float(1.0)));
    CHECK(auk_value_as_float(auk_value_int(2), T) == 2.0);
    AukStr *k = s("age");
    const AukValue *age = auk_map_at(auk_value_as_map(root, T), &k, T);
    CHECK_INT(auk_value_as_int(*age, T), 3);
    CHECK_TEXT(auk_value_tag_name(AUK_V_LIST), "List");
    rel(k);
    auk_value_release(copy);
    auk_value_release(root);
    rel(m);
    rel(l);
    rel(name);
}

static void p_as_int(void *c) { (void)c; auk_value_as_int(auk_value_bool(true), "v.auk:1:1"); }

static void value_accessor_panics(void) { EXPECT_PANIC(p_as_int, NULL, "expected Int, got Bool"); }

/* ---- closures & boxes ------------------------------------------------------------------- */

typedef struct GreetEnv {
    AukObj base;
    AukStr *greeting;
    int64_t n;
} GreetEnv;

static int drops;
static void greet_drop(AukObj *o) {
    drops++;
    auk_release(((GreetEnv *)o)->greeting);
}
typedef AukStr *(*GreetFn)(AukObj *env, AukStr *who);
static AukStr *greet_fn(AukObj *env, AukStr *who) {
    GreetEnv *e = (GreetEnv *)env;
    AukStrBuf b = {0};
    auk_sb_str(&b, e->greeting);
    auk_sb_lit(&b, " ");
    auk_sb_str(&b, who);
    char tail[32];
    snprintf(tail, sizeof tail, " x%lld", (long long)e->n);
    sb_push(&b, tail);
    return auk_sb_finish(&b);
}

static void closures_env_rc(void) {
    drops = 0;
    GreetEnv *env = auk_obj_alloc(sizeof(GreetEnv), greet_drop, NULL);
    env->greeting = s("hi");
    env->n = 2;
    AukClosure c = {(void *)greet_fn, &env->base};
    AukArr *fs = auk_arr_new(&auk_ops_closure, 0);
    auk_arr_push(&fs, &c);
    auk_closure_release(c); /* the array holds it now */
    AukClosure c2 = AT(AukClosure, fs, 0);
    AukStr *who = s("auk");
    GreetFn f = (GreetFn)c2.fn;
    CHECK_STR(f(c2.env, who), "hi auk x2");
    rel(who);
    CHECK_INT(drops, 0);
    rel(fs);
    CHECK_INT(drops, 1);
}

/* ---- tasks -------------------------------------------------------------------------------- */

typedef struct SleepArgs {
    int64_t ms;
    AukStr *tag;
    int64_t *span; /* where to record when the sleep started and ended (or NULL) */
} SleepArgs;

static void sleep_thunk(void *args, void *result) {
    SleepArgs *a = args;
    if (a->span) a->span[0] = auk_time_now();
    auk_time_sleep(a->ms);
    if (a->span) a->span[1] = auk_time_now();
    AukStrBuf b = {0};
    auk_sb_str(&b, a->tag);
    auk_sb_lit(&b, " done");
    *(AukStr **)result = auk_sb_finish(&b);
    auk_release(a->tag); /* the thunk owns its args */
}

static void tasks_run_concurrently(void) {
    int64_t t0 = auk_time_now();
    static int64_t span1[2], span2[2];
    SleepArgs a1 = {200, s("a"), span1};
    SleepArgs a2 = {200, s("b"), span2};
    size_t sz = sizeof(SleepArgs), ps = sizeof(AukStr *);
    AukTask *ts[2] = {
        auk_task_spawn(sleep_thunk, &a1, sz, ps, &auk_ops_str, NULL, NULL, NULL),
        auk_task_spawn(sleep_thunk, &a2, sz, ps, &auk_ops_str, NULL, NULL, NULL),
    };
    AukStr *outs[2] = {NULL, NULL};
    auk_task_await_all(ts, 2, outs);
    int64_t dt = auk_time_now() - t0;
    CHECK(dt >= 195);
    /* concurrent: each sleep started before the other ended (not a wall-clock bound, which a
       loaded CI machine breaks) */
    if (!(span1[0] < span2[1] && span2[0] < span1[1])) {
        t_fail(__FILE__, __LINE__, "the two sleeps didn't overlap: [%lld, %lld] and [%lld, %lld] (ms from start)",
               (long long)(span1[0] - t0), (long long)(span1[1] - t0), (long long)(span2[0] - t0),
               (long long)(span2[1] - t0));
    }
    CHECK_STR(outs[0], "a done");
    CHECK_STR(outs[1], "b done");
    /* awaiting again hands out another reference */
    AukStr *again = NULL;
    auk_task_await(ts[0], &again);
    CHECK_STR(again, "a done");
    rel(ts[0]);
    rel(ts[1]);
}

static void sum_thunk(void *args, void *result) {
    int64_t n = *(const int64_t *)args;
    int64_t sum = 0;
    for (int64_t i = 1; i <= n; i++) sum = auk_add(sum, i, "t");
    *(int64_t *)result = sum;
}

static void tasks_many_and_unawaited(void) {
    AukTask *ts[16];
    for (int i = 0; i < 16; i++) {
        int64_t n = 1000 * (i + 1);
        ts[i] = auk_task_spawn(sum_thunk, &n, sizeof n, sizeof(int64_t), NULL, NULL, NULL, NULL);
    }
    for (int i = 0; i < 16; i++) {
        int64_t r = 0, n = 1000 * (i + 1);
        auk_task_await(ts[i], &r);
        CHECK_INT(r, n * (n + 1) / 2);
        rel(ts[i]);
    }
    /* releasing a never-awaited task joins it and releases its result */
    SleepArgs a = {10, s("x")};
    AukTask *t = auk_task_spawn(sleep_thunk, &a, sizeof a, sizeof(AukStr *), &auk_ops_str, NULL, NULL, NULL);
    rel(t);
}

typedef struct PushArgs {
    AukArr *xs;
} PushArgs;

static void shared_push_thunk(void *args, void *result) {
    PushArgs *a = args;
    for (int64_t i = 0; i < 1000; i++) auk_arr_push(&a->xs, &i); /* COW: copies once */
    *(int64_t *)result = auk_arr_len(a->xs);
    auk_release(a->xs);
}

static void tasks_atomic_refcounts(void) {
    AukArr *xs = auk_arr_new(&auk_ops_int, 0);
    AukTask *ts[8];
    for (int i = 0; i < 8; i++) {
        PushArgs a = {ret(xs)};
        ts[i] = auk_task_spawn(shared_push_thunk, &a, sizeof a, sizeof(int64_t), NULL, NULL, NULL, NULL);
    }
    int64_t outs[8] = {0};
    auk_task_await_all(ts, 8, outs);
    for (int i = 0; i < 8; i++) {
        CHECK_INT(outs[i], 1000);
        rel(ts[i]);
    }
    CHECK_INT(auk_arr_len(xs), 0);
    CHECK_INT(auk_refcount(xs), 1);
    rel(xs);
}

/* ---- fs ------------------------------------------------------------------------------------ */

static void fs_round_trip(void) {
    char *tmp = tmpdir_new();
    AukStr *p = tmpdir_path(tmp, "hello.txt");
    AukStr *content = s("line one\ndück\r\nlast");
    AukRes_unit w = auk_fs_write(p, content);
    CHECK(w.ok);
    AukRes_str r = auk_fs_read(p);
    CHECK(r.ok && auk_str_eq(r.val, content));
    CHECK_INT(auk_str_len(r.val), 19);
    rel(r.val);
    AukRes_arr ls = auk_fs_lines(p);
    CHECK(ls.ok);
    AukStr *sep = s("|");
    CHECK_STR(auk_arr_join(ls.val, sep), "line one|dück|last");
    rel(sep);
    rel(ls.val);
    rel(p);
    rel(content);

    AukStr *missing = s("/definitely/not/here.txt");
    r = auk_fs_read(missing);
    CHECK(!r.ok);
    CHECK(r.err->code != 0);
    CHECK_HAS(err_text(r.err), "fs.read /definitely/not/here.txt: ");
    ls = auk_fs_lines(missing);
    CHECK(!ls.ok);
    rel(ls.err);
    w = auk_fs_write(missing, missing);
    CHECK(!w.ok);
    rel(w.err);
    rel(missing);

    /* invalid UTF-8 on disk is an Err, not a corrupt str */
    FILE *f = fopen(t_fmt("%s/bad.bin", tmp), "wb");
    CHECK(f != NULL);
    fwrite("ok\xFF", 1, 3, f);
    fclose(f);
    p = tmpdir_path(tmp, "bad.bin");
    r = auk_fs_read(p);
    CHECK(!r.ok);
    CHECK_HAS(err_text(r.err), "invalid UTF-8 at byte 2");
    rel(p);
}

/* ---- proc -------------------------------------------------------------------------------- */

static void proc_run(void) {
    AukStr *echo = s("echo");
    AukArr *args = auk_arr_new(&auk_ops_str, 0);
    AukStr *a1 = s("hello"), *a2 = s("dück world");
    auk_arr_push(&args, &a1);
    auk_arr_push(&args, &a2);
    AukRes_str r = auk_proc_run(echo, args);
    CHECK(r.ok);
    CHECK_STR(r.val, "hello dück world\n");
    rel(args);
    rel(a1);
    rel(a2);
    rel(echo);

    AukStr *f = s("false");
    AukArr *none = auk_arr_new(&auk_ops_str, 0);
    r = auk_proc_run(f, none);
    CHECK(!r.ok);
    CHECK_INT(r.err->code, 1);
    CHECK_STR(auk_err_show(r.err), "proc.run false: exited with status 1");
    rel(r.err);
    rel(f);

    AukStr *nope = s("auk-no-such-command-xyz");
    r = auk_proc_run(nope, none);
    CHECK(!r.ok);
    rel(r.err);
    rel(nope);
    rel(none);
}

/* ---- net --------------------------------------------------------------------------------- */

/* Accept one connection on fd; reply "echo:" + whatever the first read got. */
static void *echo_server(void *arg) {
    int lfd = *(int *)arg;
    int c = accept(lfd, NULL, NULL);
    if (c < 0) return NULL;
    char buf[256];
    ssize_t n = read(c, buf, sizeof buf);
    if (n > 0) {
        if (write(c, "echo:", 5) == 5 && write(c, buf, (size_t)n) == n) {
        }
    }
    close(c);
    return NULL;
}

static void net_tcp_echo(void) {
    int lfd = socket(AF_INET, SOCK_STREAM, 0);
    CHECK(lfd >= 0);
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    sa.sin_port = 0;
    CHECK(bind(lfd, (struct sockaddr *)&sa, sizeof sa) == 0);
    CHECK(listen(lfd, 4) == 0);
    socklen_t len = sizeof sa;
    CHECK(getsockname(lfd, (struct sockaddr *)&sa, &len) == 0);
    int64_t port = ntohs(sa.sin_port);
    pthread_t th;
    CHECK(pthread_create(&th, NULL, echo_server, &lfd) == 0);

    AukStr *host = s("127.0.0.1");
    AukRes_conn c = auk_net_tcp(host, port);
    CHECK(c.ok);
    AukStr *msg = s("ping 🦆");
    AukArr *bytes = auk_str_bytes(msg);
    AukRes_unit w = auk_conn_write(c.val, bytes);
    CHECK(w.ok);
    AukArr *all = auk_arr_new(&auk_ops_int, 0);
    for (;;) {
        AukRes_arr r = auk_conn_read(c.val, 4);
        CHECK(r.ok);
        int64_t n = auk_arr_len(r.val);
        auk_arr_extend(&all, r.val);
        rel(r.val);
        if (n == 0) break; /* peer closed */
    }
    AukRes_str st = auk_str_from_utf8(all);
    CHECK(st.ok);
    CHECK_STR(st.val, "echo:ping 🦆");
    auk_conn_close(c.val);
    AukRes_arr after = auk_conn_read(c.val, 10);
    CHECK(!after.ok);
    rel(after.err);
    rel(c.val);
    rel(all);
    rel(bytes);
    rel(msg);
    pthread_join(th, NULL);
    close(lfd);

    /* nothing listening on the port any more: connection refused */
    c = auk_net_tcp(host, port);
    CHECK(!c.ok);
    rel(c.err);
    AukStr *bad = s("no-such-host.invalid");
    c = auk_net_tcp(bad, 80);
    CHECK(!c.ok);
    rel(c.err);
    rel(bad);

    /* TLS to the closed port fails cleanly too (more in test_net.c) */
    c = auk_net_tls(host, port);
    CHECK(!c.ok);
    rel(c.err);
    rel(host);
}

/* ---- time, rand, env -------------------------------------------------------------------- */

static void time_rand_env(void) {
    int64_t t0 = auk_time_now();
    CHECK(t0 > 1600000000000);
    auk_time_sleep(20);
    CHECK(auk_time_now() - t0 >= 19);
    bool seen[7] = {false};
    for (int i = 0; i < 2000; i++) {
        int64_t r = auk_rand_int(1, 6);
        CHECK(r >= 1 && r <= 6);
        seen[r] = true;
    }
    for (int i = 1; i <= 6; i++) CHECK(seen[i]);
    CHECK_INT(auk_rand_int(5, 5), 5);
    (void)auk_rand_int(INT64_MIN, INT64_MAX);
    double f = auk_rand_float();
    CHECK(f >= 0.0 && f < 1.0);

    setenv("AUK_TEST_VAR", "quäck", 1);
    AukStr *k = s("AUK_TEST_VAR"), *k2 = s("AUK_TEST_UNSET_VAR");
    AukOpt_str v = auk_env_get(k);
    CHECK(v.some);
    CHECK_STR(v.val, "quäck");
    CHECK(!auk_env_get(k2).some);
    rel(k);
    rel(k2);

    static char *argv[] = {"prog", "a", "b", NULL};
    auk_env_set_args(3, argv);
    AukArr *args = auk_env_args();
    CHECK_INT(auk_arr_len(args), 3);
    CHECK(auk_str_eq_lit(AT(AukStr *, args, 2), "b"));
    rel(args); /* immortal: harmless */
}

static void p_rand(void *c) { (void)c; auk_rand_int(3, 1); }

static void rand_bad_range_panics(void) { EXPECT_PANIC(p_rand, NULL, "lo > hi"); }

/* ---- hooks -------------------------------------------------------------------------------- */

static void p_requires(void *c) { (void)c; auk_requires_fail("isqrt.auk:2:12", "n >= 0"); }
static void p_ensures(void *c) { (void)c; auk_ensures_fail("isqrt.auk:3:11", "result * result <= n"); }
static void p_hole(void *c) { (void)c; auk_hole("isqrt.auk:4:3", "int"); }
static void p_assert_cmp(void *c) {
    (void)c;
    AukStr *l = s("1"), *r = s("2");
    auk_assert_fail_cmp("t.auk:9:3", "a == b", l, r);
}
static void do_peek(void *c) {
    (void)c;
    AukStr *v = auk_str_from_int(84);
    auk_peek("main.auk:7", "x * 2", v);
    rel(v);
}

static void hooks_contracts_holes_peek(void) {
    EXPECT_PANIC(p_requires, NULL, "panic: requires failed: n >= 0\n  at isqrt.auk:2:12\n");
    EXPECT_PANIC(p_ensures, NULL, "ensures failed: result * result <= n");
    EXPECT_PANIC(p_hole, NULL, "unfilled hole (expected int)\n  at isqrt.auk:4:3");
    EXPECT_PANIC(p_assert_cmp, NULL, "assertion failed: a == b\n  left: 1\n  right: 2");
    char *out;
    int code = child(do_peek, NULL, &out);
    CHECK_INT(code, 0);
    CHECK_TEXT(out, "[main.auk:7] x * 2 = 84\n");
}

/* ---- auk_test_main ------------------------------------------------------------------------ */

static AukErr *t_pass(void) {
    cprint("this output is hidden\n");
    return NULL;
}
static AukErr *t_panic(void) {
    cprint("before the panic\n");
    auk_add(INT64_MAX, 1, "tests.auk:5:7");
    return NULL;
}
static AukErr *t_err(void) { return err_msg("fail() called"); }

static void runner_all(void *c) {
    (void)c;
    static char *argv[] = {"tests", NULL};
    auk_test_register("passes", t_pass);
    auk_test_register("overflows", t_panic);
    auk_test_register("returns an error", t_err);
    int code = auk_test_main(1, argv);
    fflush(stdout);
    _exit(code == 1 ? 42 : 43);
}
static void runner_filtered(void *c) {
    (void)c;
    static char *argv[] = {"tests", "pass", NULL};
    auk_test_register("passes", t_pass);
    auk_test_register("overflows", t_panic);
    _exit(auk_test_main(2, argv) == 0 ? 42 : 43);
}

static void test_runner(void) {
    char *out;
    int code = child(runner_all, NULL, &out);
    if (code != 42) t_fail(__FILE__, __LINE__, "exit %d; output:\n%s", code, out);
    CHECK_TEXT(out, "ok passes\n"
                    "FAIL overflows\n    before the panic\n    panic: integer overflow in `+`\n      at tests.auk:5:7\n"
                    "FAIL returns an error\n    error: fail() called\n"
                    "1 passed, 2 failed\n");
    code = child(runner_filtered, NULL, &out);
    if (code != 42) t_fail(__FILE__, __LINE__, "exit %d; output:\n%s", code, out);
    CHECK_TEXT(out, "ok passes\n1 passed, 0 failed\n");
}

/* ---- auk_main_wrapper --------------------------------------------------------------------- */

static AukRes_int main_ok(AukArr *args) {
    printf("argc=%lld\n", (long long)auk_arr_len(args));
    AukRes_int r = {true, 7, NULL};
    return r;
}
static AukRes_int main_err(AukArr *args) {
    (void)args;
    AukErr *cause = err_msg("no such file");
    AukStr *m = s("loading config");
    AukErr *e = auk_err_wrap(m, cause);
    rel(m);
    rel(cause);
    AukRes_int r = {false, 0, e};
    return r;
}
static void wrap_ok(void *c) {
    (void)c;
    static char *argv[] = {"prog", "x", NULL};
    _exit(auk_main_wrapper(2, argv, main_ok));
}
static void wrap_err(void *c) {
    (void)c;
    static char *argv[] = {"prog", NULL};
    _exit(auk_main_wrapper(1, argv, main_err));
}

static void main_wrapper(void) {
    char *out;
    int code = child(wrap_ok, NULL, &out);
    CHECK_INT(code, 7);
    CHECK_TEXT(out, "argc=2\n");
    code = child(wrap_err, NULL, &out);
    CHECK_INT(code, 1);
    CHECK_TEXT(out, "error: loading config: no such file\n");
}

static void do_print(void *c) {
    (void)c;
    AukStr *x = s("héllo");
    auk_print(x);
    auk_print_lit("bye");
    rel(x);
}

static void print_lines(void) {
    char *out;
    int code = child(do_print, NULL, &out);
    CHECK_INT(code, 0);
    CHECK_TEXT(out, "héllo\nbye\n");
}

/* Compiler-emitted globals (string literals) are made immortal; the cleanup hook and the
 * AUK_LEAK_CHECK leak check used by `auk test` and auk_main_wrapper. */
static int cleanup_calls;
static AukStr *cleanup_global;
static void cleanup_fn(void) {
    cleanup_calls++;
    rel(cleanup_global);
    cleanup_global = NULL;
}

static void immortal_and_leak_check(void) {
    int64_t live = auk_live_objects();
    AukStr *lit = s("forever");
    auk_make_immortal(lit);
    CHECK_INT(auk_live_objects(), live);
    auk_retain(lit);
    rel(lit);
    rel(lit);
    CHECK(auk_str_eq_lit(lit, "forever"));
    auk_make_immortal(NULL);

    /* without AUK_LEAK_CHECK the check is a no-op */
    unsetenv("AUK_LEAK_CHECK");
    cleanup_global = s("global");
    auk_set_cleanup(cleanup_fn);
    CHECK_INT(auk_leak_check(), 0);
    CHECK_INT(cleanup_calls, 0);
    /* with it: the cleanup runs first, then live objects are counted */
    setenv("AUK_LEAK_CHECK", "1", 1);
    CHECK_INT(auk_leak_check() - live, 0);
    CHECK_INT(cleanup_calls, 1);
    CHECK(cleanup_global == NULL);
    unsetenv("AUK_LEAK_CHECK");
    auk_set_cleanup(NULL);
}

const TestCase core_tests[] = {
    {"arith_checked", arith_checked},
    {"arith_panics_exit_101", arith_panics_exit_101},
    {"err_chain_and_payload", err_chain_and_payload},
    {"err_unwrap_panics", err_unwrap_panics},
    {"value_tree", value_tree},
    {"value_accessor_panics", value_accessor_panics},
    {"closures_env_rc", closures_env_rc},
    {"tasks_run_concurrently", tasks_run_concurrently},
    {"tasks_many_and_unawaited", tasks_many_and_unawaited},
    {"tasks_atomic_refcounts", tasks_atomic_refcounts},
    {"fs_round_trip", fs_round_trip},
    {"proc_run", proc_run},
    {"net_tcp_echo", net_tcp_echo},
    {"time_rand_env", time_rand_env},
    {"rand_bad_range_panics", rand_bad_range_panics},
    {"hooks_contracts_holes_peek", hooks_contracts_holes_peek},
    {"test_runner", test_runner},
    {"main_wrapper", main_wrapper},
    {"print_lines", print_lines},
    {"immortal_and_leak_check", immortal_and_leak_check},
    {NULL, NULL},
};

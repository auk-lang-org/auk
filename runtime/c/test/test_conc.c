/* Concurrency stress tests: tasks (spawn, await, cancel, links), channels with several senders
 * and receivers, per-task heaps and their sweep, reference counts on handles shared across
 * threads, and the trace and debugger engines' locks. They check results like the other tests,
 * but are mostly there for `TSAN=1 sh runtime/c/test/run.sh conc` (ThreadSanitizer): each one
 * makes threads meet in the runtime's shared state as often as it can in a short run. */
#include "test.h"

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

/* A task's arguments in a fresh heap, as generated code makes them: build(args) runs with the
 * heap current, so everything it allocates or retains is the task's. */
static void *heap_for(void (*build)(void *args), void *args) {
    void *h = auk_heap_new();
    void *old = auk_heap_switch(h);
    build(args);
    auk_heap_switch(old);
    return h;
}

/* Run f(env) under a recovery point; the panic's message (kept), or NULL when none. */
static char *caught(AukThunk f, void *env, void *out) {
    AukErr *e = auk_catch(f, env, out);
    return e == NULL ? NULL : err_text(e);
}

/* ---- tasks: spawn, await, cancel, links ------------------------------------------------- */

typedef struct WorkArgs {
    int64_t kind; /* 0 compute, 1 crash, 2 run until cancelled, 3 start kids then crash */
    int64_t n;
    AukStr *tag;
} WorkArgs;

static void work_build(void *p) {
    WorkArgs *a = p;
    a->tag = s("w");
}

static void work_drop(void *p) {
    auk_release(((WorkArgs *)p)->tag);
}

/* Allocate garbage in the current heap: a list of strings, some of it left for the sweep. */
static AukArr *garbage(int64_t n) {
    AukArr *xs = auk_arr_new(&auk_ops_str, 0);
    for (int64_t i = 0; i < n; i++) {
        AukStrBuf b = {0};
        sb_push(&b, "item ");
        auk_sb_int(&b, i);
        AukStr *x = auk_sb_finish(&b);
        auk_arr_push(&xs, &x);
    }
    return xs;
}

static void spin_thunk(void *args, void *result) {
    WorkArgs *a = args;
    /* until cancelled: a cancel check at a "back-edge" and a sleep (a blocking call) */
    for (;;) {
        if (atomic_load(&auk_cancel_pending) != 0) auk_cancel_check("spin.auk:1:1");
        auk_time_sleep(1);
        AukArr *g = garbage(4);
        auk_release(g);
    }
    (void)a;
    (void)result;
}

static void work_thunk(void *args, void *result) {
    WorkArgs *a = args;
    switch (a->kind) {
    case 0: {
        AukArr *g = garbage(a->n);
        AukStrBuf b = {0};
        auk_sb_str(&b, a->tag);
        auk_sb_int(&b, auk_arr_len(g));
        *(AukStr **)result = auk_sb_finish(&b);
        auk_release(g);
        break;
    }
    case 1: {
        AukArr *g = garbage(a->n); /* left behind: the sweep frees it */
        (void)g;
        auk_div(1, 0, "crash.auk:1:1");
        break;
    }
    case 2:
        spin_thunk(args, result);
        break;
    default: {
        /* two linked kids, never awaited: this task's crash cancels them, and its heap's
         * ledger gives back the references the abandoned frames held */
        for (int i = 0; i < 2; i++) {
            WorkArgs k = {2, 0, NULL};
            void *h = heap_for(work_build, &k);
            auk_task_spawn(work_thunk, &k, sizeof k, sizeof(AukStr *), &auk_ops_str, h, work_drop, NULL);
        }
        auk_time_sleep(2);
        auk_div(1, 0, "parent.auk:1:1");
    }
    }
    auk_release(a->tag);
}

typedef struct AwaitEnv {
    AukTask *t;
} AwaitEnv;

static void await_thunk(void *env, void *out) {
    auk_task_await(((AwaitEnv *)env)->t, out);
}

/* Another thread cancelling and polling tasks while they run and finish. */
typedef struct Poker {
    AukTask **ts;
    int n;
    _Atomic bool stop;
} Poker;

static void *poker(void *p) {
    Poker *k = p;
    while (!atomic_load(&k->stop)) {
        for (int i = 0; i < k->n; i++) {
            if (i % 4 == 2) auk_task_cancel(k->ts[i]);
            (void)auk_task_done(k->ts[i]);
        }
    }
    return NULL;
}

static void conc_tasks_spawn_await_cancel(void) {
    enum { N = 12 };
    for (int round = 0; round < 6; round++) {
        AukTask *ts[N];
        for (int i = 0; i < N; i++) {
            WorkArgs a = {i % 4, 50 + i, NULL};
            void *h = heap_for(work_build, &a);
            ts[i] = auk_task_spawn(work_thunk, &a, sizeof a, sizeof(AukStr *), &auk_ops_str, h, work_drop, NULL);
        }
        Poker k = {ts, N, false};
        pthread_t th;
        pthread_create(&th, NULL, poker, &k);
        /* the first to finish, while the others are still running */
        AukStr *first = NULL;
        AukErr *ferr = NULL;
        int64_t w = auk_task_await_any(ts, N, &first, &ferr, "any.auk:1:1");
        CHECK(w >= 0 && w < N);
        if (ferr != NULL) rel(ferr);
        if (first != NULL) rel(first);
        for (int i = 0; i < N; i++) {
            if (i % 4 == 2) auk_task_cancel(ts[i]);
            AukStr *r = NULL;
            AwaitEnv env = {ts[i]};
            char *msg = caught(await_thunk, &env, &r);
            switch (i % 4) {
            case 0:
                CHECK(msg == NULL);
                CHECK_STR(r, t_fmt("w%d", 50 + i));
                break;
            case 1:
            case 3:
                CHECK(msg != NULL);
                CHECK_HAS(msg, "division by zero");
                break;
            default:
                CHECK(msg != NULL);
                CHECK_HAS(msg, "cancelled");
            }
        }
        atomic_store(&k.stop, true);
        pthread_join(th, NULL);
        for (int i = 0; i < N; i++) rel(ts[i]);
    }
    CHECK_INT(atomic_load(&auk_cancel_pending), 0);
}

/* A swept heap whose objects hold each other: the strings were allocated after the lists that
 * hold them (so they come first on the heap's list and are swept first), and freeing a list
 * releases its strings, which must still be there to release. */
static void heap_sweep_containers(void) {
    int64_t live0 = auk_live_objects();
    void *h = auk_heap_new();
    void *old = auk_heap_switch(h);
    AukArr *inner = garbage(20);
    AukArr *outer = auk_arr_new(&auk_ops_arr, 0);
    auk_arr_push(&outer, &inner);
    auk_heap_switch(old);
    auk__heap_sweep(h);
    CHECK_INT(auk_live_objects(), live0);
}

/* ---- tasks released (and their heaps swept) on other threads ----------------------------- */

typedef struct ReapArgs {
    AukTask *victim;
} ReapArgs;

/* Await (or not) a task started elsewhere and release it here: the victim's heap is swept on
 * this thread while other tasks allocate in theirs. */
static void reap_thunk(void *args, void *result) {
    ReapArgs *a = args;
    AukStr *r = NULL;
    AwaitEnv env = {a->victim};
    AukErr *e = auk_catch(await_thunk, &env, &r);
    *(int64_t *)result = e == NULL ? 1 : 2;
    if (e != NULL) auk_release(e);
    if (r != NULL) auk_release(r);
    auk_release(a->victim);
}

static void conc_heap_sweep_elsewhere(void) {
    enum { N = 16 };
    AukTask *victims[N];
    AukTask *reapers[N];
    for (int i = 0; i < N; i++) {
        WorkArgs a = {i % 2, 200, NULL};
        void *h = heap_for(work_build, &a);
        victims[i] = auk_task_spawn(work_thunk, &a, sizeof a, sizeof(AukStr *), &auk_ops_str, h, work_drop, NULL);
    }
    for (int i = 0; i < N; i++) {
        ReapArgs r = {victims[i]}; /* the reaper owns the victim now */
        reapers[i] = auk_task_spawn(reap_thunk, &r, sizeof r, sizeof(int64_t), NULL, NULL, NULL, NULL);
    }
    int64_t outs[N] = {0};
    auk_task_await_all(reapers, N, outs);
    for (int i = 0; i < N; i++) {
        CHECK_INT(outs[i], i % 2 == 0 ? 1 : 2);
        rel(reapers[i]);
    }
}

/* ---- channels ------------------------------------------------------------------------------ */

typedef struct ChanArgs {
    AukChan *c;
    int64_t id;
    int64_t n;
    int64_t crash_at; /* a sender that crashes after this many sends (-1: never) */
    int64_t wait_ms;  /* a receiver using recv_for(wait_ms) (-1: recv) */
} ChanArgs;

/* the channel reference a task gets in its arguments (on its heap's ledger) */
static void chan_build(void *p) {
    auk_retain(((ChanArgs *)p)->c);
}

static void chan_drop(void *p) {
    auk_release(((ChanArgs *)p)->c);
}

static void send_thunk(void *args, void *result) {
    ChanArgs *a = args;
    for (int64_t i = 0; i < a->n; i++) {
        if (i == a->crash_at) auk_div(1, 0, "sender.auk:1:1");
        AukStrBuf b = {0};
        auk_sb_int(&b, a->id * 100000 + i);
        AukStr *x = auk_sb_finish(&b);
        auk_chan_send(a->c, &x, "send.auk:1:1");
        auk_release(x);
    }
    *(int64_t *)result = a->n;
    auk_release(a->c);
}

/* Receive until the channel is closed and empty: the count and the sum of the numbers. */
typedef struct RecvOut {
    int64_t count;
    int64_t sum;
} RecvOut;

static void recv_thunk(void *args, void *result) {
    ChanArgs *a = args;
    RecvOut o = {0, 0};
    for (;;) {
        AukStr *x = NULL;
        bool got;
        if (a->wait_ms >= 0) {
            got = auk_chan_recv_for(a->c, a->wait_ms, &x);
            if (!got) {
                /* nothing in time: closed and empty ends it, otherwise wait again */
                AukStr *y = NULL;
                if (!auk_chan_recv_for(a->c, 0, &y)) {
                    AukStr *z = NULL;
                    got = auk_chan_recv(a->c, &z);
                    if (!got) break;
                    x = z;
                } else {
                    x = y;
                    got = true;
                }
            }
        } else {
            got = auk_chan_recv(a->c, &x);
            if (!got) break;
        }
        o.count++;
        o.sum += atoll(auk_str_cstr(x));
        auk_release(x);
    }
    *(RecvOut *)result = o;
    auk_release(a->c);
}

static void conc_chan_many_senders_receivers(void) {
    enum { S = 4, R = 4, PER = 300 };
    AukArr *proto = auk_arr_new(&auk_ops_str, 0);
    AukChan *c = auk_chan_new(proto);
    rel(proto);
    AukTask *senders[S + 1];
    AukTask *receivers[R];
    for (int i = 0; i < R; i++) {
        ChanArgs a = {c, i, 0, -1, i % 2 == 0 ? -1 : 1};
        void *h = heap_for(chan_build, &a);
        receivers[i] = auk_task_spawn(recv_thunk, &a, sizeof a, sizeof(RecvOut), NULL, h, chan_drop, NULL);
    }
    int64_t want_sum = 0;
    for (int i = 0; i < S; i++) {
        ChanArgs a = {c, i + 1, PER, -1, -1};
        void *h = heap_for(chan_build, &a);
        senders[i] = auk_task_spawn(send_thunk, &a, sizeof a, sizeof(int64_t), NULL, h, chan_drop, NULL);
        for (int64_t k = 0; k < PER; k++) want_sum += (i + 1) * 100000 + k;
    }
    /* a sender that crashes halfway: its reference to the channel comes back through the
     * sweep of its heap's ledger */
    {
        ChanArgs a = {c, 9, PER, PER / 2, -1};
        void *h = heap_for(chan_build, &a);
        senders[S] = auk_task_spawn(send_thunk, &a, sizeof a, sizeof(int64_t), NULL, h, chan_drop, NULL);
        for (int64_t k = 0; k < PER / 2; k++) want_sum += 9 * 100000 + k;
    }
    for (int i = 0; i < S; i++) {
        int64_t n = 0;
        auk_task_await(senders[i], &n);
        CHECK_INT(n, PER);
    }
    int64_t dummy;
    AwaitEnv env = {senders[S]};
    char *msg = caught(await_thunk, &env, &dummy);
    CHECK(msg != NULL);
    auk_chan_close(c);
    RecvOut total = {0, 0};
    for (int i = 0; i < R; i++) {
        RecvOut o = {0, 0};
        auk_task_await(receivers[i], &o);
        total.count += o.count;
        total.sum += o.sum;
    }
    CHECK_INT(total.count, S * PER + PER / 2);
    CHECK_INT(total.sum, want_sum);
    for (int i = 0; i <= S; i++) rel(senders[i]);
    for (int i = 0; i < R; i++) rel(receivers[i]);
    CHECK_INT(auk_refcount(c), 1);
    rel(c);
}

/* ---- reference counts on shared handles and untracked objects ---------------------------- */

typedef struct RcArgs {
    AukChan *c;   /* a handle: retains go on each task's ledger */
    AukStr *str;  /* an untracked string shared by reference (a task without a heap) */
} RcArgs;

static void rc_thunk(void *args, void *result) {
    RcArgs *a = args;
    for (int i = 0; i < 2000; i++) {
        auk_retain(a->c);
        auk_retain(a->str);
        auk_release(a->str);
        auk_release(a->c);
    }
    *(int64_t *)result = auk_str_len(a->str);
}

static void conc_rc_shared_handles(void) {
    enum { N = 8 };
    AukArr *proto = auk_arr_new(&auk_ops_int, 0);
    AukChan *c = auk_chan_new(proto);
    rel(proto);
    AukStr *str = s("shared");
    AukTask *ts[N];
    for (int i = 0; i < N; i++) {
        RcArgs a = {c, str};
        /* half with heaps of their own (ledgers), half on the untracked heap */
        void *h = i % 2 == 0 ? auk_heap_new() : NULL;
        ts[i] = auk_task_spawn(rc_thunk, &a, sizeof a, sizeof(int64_t), NULL, h, NULL, NULL);
    }
    int64_t outs[N];
    auk_task_await_all(ts, N, outs);
    for (int i = 0; i < N; i++) {
        CHECK_INT(outs[i], 6);
        rel(ts[i]);
    }
    CHECK_INT(auk_refcount(c), 1);
    CHECK_INT(auk_refcount(str), 1);
    rel(c);
    rel(str);
}

/* ---- the trace's lock ---------------------------------------------------------------------- */

static void trace_thunk(void *args, void *result) {
    int64_t id = *(int64_t *)args;
    for (int i = 0; i < 200; i++) {
        if (auk_trace_begin()) {
            AukStr *argv[1] = {s("1")};
            auk_trace_call(id % 2 == 0 ? "even.f" : "odd.f", "t.auk:1:1", 1, argv);
        }
        AukStr *v = s("v");
        auk_peek("t.auk:2:2", "x", v);
        auk_release(v);
        if (auk_trace_exit()) auk_trace_ret(id % 2 == 0 ? "even.f" : "odd.f", s("2"));
    }
    if (id == 0) auk_div(1, 0, "t.auk:3:3"); /* a caught panic: an event and a flush */
    *(int64_t *)result = id;
}

static void trace_child(void *ctx) {
    const char *path = ctx;
    setenv("AUK_TRACE", path, 1);
    setenv("AUK_TRACE_LIMIT", "1000000", 1);
    auk_trace_init(false);
    enum { N = 6 };
    AukTask *ts[N];
    for (int64_t i = 0; i < N; i++) ts[i] = auk_task_spawn(trace_thunk, &i, sizeof i, sizeof(int64_t), NULL, NULL, NULL, NULL);
    for (int i = 0; i < N; i++) {
        int64_t r;
        AwaitEnv env = {ts[i]};
        char *m = caught(await_thunk, &env, &r);
        CHECK((m != NULL) == (i == 0));
        rel(ts[i]);
    }
    auk__trace_flush();
}

static void conc_trace_threads(void) {
    char *dir = tmpdir_new();
    char *path = t_fmt("%s/trace.jsonl", dir);
    char *out;
    int code = child(trace_child, path, &out);
    if (code != 0) t_fail(__FILE__, __LINE__, "child exited %d:\n%s", code, out);
    FILE *f = fopen(path, "r");
    CHECK(f != NULL);
    int64_t calls = 0, rets = 0, panics = 0;
    char line[512];
    while (fgets(line, sizeof line, f) != NULL) {
        if (strstr(line, "\"ev\":\"call\"") != NULL) calls++;
        if (strstr(line, "\"ev\":\"ret\"") != NULL) rets++;
        if (strstr(line, "\"ev\":\"panic\"") != NULL) panics++;
    }
    fclose(f);
    CHECK_INT(calls, 6 * 200);
    CHECK_INT(rets, 6 * 200);
    CHECK_INT(panics, 2); /* in the task, and again where it is awaited */
}

/* ---- the debugger's lock: all-stop with threads running, sleeping and stopping ------------ */

/* Debug info for one function `f` with one site per line 1..4 (see parse_info in dbg.c). */
static const char DBG_INFO[] = "p t.auk\nf f\ns 0 0 1 1 \ns 0 0 2 1 \ns 0 0 3 1 \ns 0 0 4 1 \n";

/* set when the front end is done: the workers run until then, so a pause always finds one */
static _Atomic bool fe_done;

static void dbg_worker(void *args, void *result) {
    int64_t n = 0;
    for (int64_t i = 0; !atomic_load(&fe_done); i++) {
        n++;
        AukDbgFrame f = {0, NULL, 0};
        auk_dbg_enter(&f);
        for (int64_t site = 0; site < 4; site++) {
            /* generated code's one aligned 8-byte store (dbg.c reads it relaxed) */
            __atomic_store_n(&f.site, site, __ATOMIC_RELAXED);
            if (atomic_load(&auk_dbg_armed) != 0) auk_dbg_hook(&f);
            /* a blocking call: the thread may be "running" while another one is stopped */
            if (site == 2 && i % 8 == 0) auk_time_sleep(1);
        }
        auk_dbg_leave(&f);
    }
    *(int64_t *)result = n;
}

/* Read one line from fd into buf (NUL-terminated, without the newline); false at EOF. */
static bool read_line(int fd, char *buf, size_t cap) {
    size_t n = 0;
    for (;;) {
        char ch;
        ssize_t r = read(fd, &ch, 1);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return false;
        if (ch == '\n') break;
        if (n + 1 < cap) buf[n++] = ch;
    }
    buf[n] = 0;
    return true;
}

static void say(int fd, const char *cmd) {
    size_t n = strlen(cmd);
    if (write(fd, cmd, n) != (ssize_t)n || write(fd, "\n", 1) != 1) t_fail(__FILE__, __LINE__, "write to the program failed");
}

/* A "stopped" event was read (and skipped) while waiting for something else: the program is
 * stopped now, and a `pause` would be ignored. */
static bool stop_seen;

/* Wait for an event containing want (skipping others, noting a stop among them). */
static void expect_ev(int fd, const char *want) {
    char line[8192];
    for (;;) {
        if (!read_line(fd, line, sizeof line)) t_fail(__FILE__, __LINE__, "connection closed waiting for %s", want);
        bool stopped = strstr(line, "\"ev\":\"stopped\"") != NULL;
        if (strstr(line, want) != NULL) {
            if (stopped) stop_seen = false;
            return;
        }
        if (stopped) stop_seen = true;
    }
}

typedef struct FrontEnd {
    int listener;
    int rounds;
} FrontEnd;

/* The front end: run, then pause / inspect every thread / continue, round after round, with
 * a breakpoint for part of it; then hang up (the program runs on). */
static void *front_end(void *p) {
    FrontEnd *fe = p;
    int fd = accept(fe->listener, NULL, NULL);
    if (fd < 0) t_fail(__FILE__, __LINE__, "accept failed");
    expect_ev(fd, "\"ready\"");
    say(fd, "run");
    expect_ev(fd, "\"ok\"");
    for (int r = 0; r < fe->rounds; r++) {
        if (r == fe->rounds / 2) {
            say(fd, "@1 break t.auk:3");
            expect_ev(fd, "\"seq\":1");
        }
        if (r == fe->rounds * 3 / 4) {
            say(fd, "@2 delete");
            expect_ev(fd, "\"seq\":2");
        }
        if (!stop_seen) {
            say(fd, "pause");
            expect_ev(fd, "\"stopped\"");
        }
        say(fd, "@3 threads");
        expect_ev(fd, "\"seq\":3");
        for (int t = 1; t <= 6; t++) {
            char cmd[64];
            snprintf(cmd, sizeof cmd, "@4 stack %d", t);
            say(fd, cmd);
            expect_ev(fd, "\"seq\":4");
        }
        say(fd, r % 3 == 0 ? "step" : "continue");
        stop_seen = false;
    }
    atomic_store(&fe_done, true);
    close(fd);
    return NULL;
}

static void dbg_child(void *ctx) {
    const char *path = ctx;
    int l = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof addr.sun_path, "%s", path);
    if (l < 0 || bind(l, (struct sockaddr *)&addr, sizeof addr) != 0 || listen(l, 1) != 0)
        t_fail(__FILE__, __LINE__, "listen on %s failed", path);
    FrontEnd fe = {l, 30};
    pthread_t th;
    pthread_create(&th, NULL, front_end, &fe);
    setenv("AUK_DEBUG", path, 1);
    auk_dbg_init(DBG_INFO, NULL, NULL);
    enum { N = 4 };
    AukTask *ts[N];
    for (int i = 0; i < N; i++) {
        ts[i] = auk_task_spawn(dbg_worker, NULL, 0, sizeof(int64_t), NULL, NULL, NULL, NULL);
    }
    int64_t mine = 0;
    dbg_worker(NULL, &mine);
    pthread_join(th, NULL);
    for (int i = 0; i < N; i++) {
        int64_t r = 0;
        auk_task_await(ts[i], &r);
        CHECK(r > 0);
        rel(ts[i]);
    }
    close(l);
}

static void conc_dbg_all_stop(void) {
    char *dir = tmpdir_new();
    char *path = t_fmt("%s/d.sock", dir);
    char *out;
    int code = child(dbg_child, path, &out);
    if (code != 0) t_fail(__FILE__, __LINE__, "child exited %d:\n%s", code, out);
}

const TestCase conc_tests[] = {
    {"conc_tasks_spawn_await_cancel", conc_tasks_spawn_await_cancel},
    {"heap_sweep_containers", heap_sweep_containers},
    {"conc_heap_sweep_elsewhere", conc_heap_sweep_elsewhere},
    {"conc_chan_many_senders_receivers", conc_chan_many_senders_receivers},
    {"conc_rc_shared_handles", conc_rc_shared_handles},
    {"conc_trace_threads", conc_trace_threads},
    {"conc_dbg_all_stop", conc_dbg_all_stop},
    {NULL, NULL},
};

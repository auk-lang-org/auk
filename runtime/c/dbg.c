/* The debugger engine (`auk run --debug`): breakpoints, stepping, pausing, stack and locals.
 *
 * Only programs compiled with --debug call into this file. Every instrumented Auk function keeps
 * a frame record (AukDbgFrame) on its stack: auk_dbg_enter/auk_dbg_leave link it into the thread's
 * debugger stack, each named local's address is stored in its slot when the local is bound, and
 * each statement stores its site id in `site` and calls auk_dbg_hook while auk_dbg_armed is set.
 * main calls auk_dbg_init with the debug info (sites, functions, locals, types) and a table of
 * show functions, one per local type.
 *
 * A front end (`auk debug`, `auk dap`) attaches through a Unix socket named by AUK_DEBUG: the
 * program connects, sends {"ev":"ready"} and waits for `run`. Without AUK_DEBUG the program runs
 * as usual (auk_dbg_armed stays 0).
 *
 * Protocol: commands are text lines, optionally prefixed with `@<seq> ` (echoed as "seq":N in
 * the reply):
 *   run                         start the program (after setting breakpoints)
 *   break <file>:<line>         line breakpoint (moves to the next line with code)
 *   break <function>            function breakpoint (`f`, or `mod.f`)
 *   break <place> if <cond>     only where the Auk expression cond is true
 *   delete [id]                 remove one breakpoint, or all
 *   catch all|uncaught|none     stop on panics (default uncaught: not under a recovery point)
 *   pause                       stop every thread at its next statement
 *   kill                        end the program
 * While stopped:
 *   continue | step | next | finish     resume (step into / over / out of, on the focus thread)
 *   stack [thread]              the frames, innermost first
 *   vars [frame] [thread]       the frame's locals in scope, shown
 *   threads                     every thread with its innermost frame
 *   kids <frame> <thread> <local> [i...]   the parts of a local (or of part i, j...)
 *   eval <frame> <thread> <expr>           an Auk expression's value there (an assignment
 *                               `x = v` changes a var local; src/dbg_eval.rs compiles it)
 * Events are JSON lines: ready, ok, error, break, stopped, stack, vars, kids, value, threads,
 * exited. When one thread stops, every other thread stops at its next statement (all-stop); a
 * thread blocked in a call (sleep, recv, I/O) stops when it returns. */
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include "auk_rt.h"

/* Non-zero while the debugger wants to see statements: generated code calls auk_dbg_hook only
 * then. */
AUK_API _Atomic int64_t auk_dbg_armed;

/* ---- text helpers ------------------------------------------------------------------------ */

/* A growable NUL-terminated text. */
typedef struct DText {
    char *p;
    size_t n;
    size_t cap;
} DText;

static void dt_add(DText *t, const char *s, size_t n) {
    if (t->n + n + 1 > t->cap) {
        size_t cap = t->cap == 0 ? 128 : t->cap * 2;
        while (cap < t->n + n + 1) {
            cap *= 2;
        }
        t->p = auk__xrealloc(t->p, cap);
        t->cap = cap;
    }
    memcpy(t->p + t->n, s, n);
    t->n += n;
    t->p[t->n] = 0;
}

static void dt_str(DText *t, const char *s) {
    dt_add(t, s, strlen(s));
}

static void dt_int(DText *t, int64_t v) {
    char b[24];
    snprintf(b, sizeof b, "%lld", (long long)v);
    dt_str(t, b);
}

/* A JSON string of s[0..n) (UTF-8). */
static void dt_json(DText *t, const char *s, size_t n) {
    dt_str(t, "\"");
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c == '"') {
            dt_str(t, "\\\"");
        } else if (c == '\\') {
            dt_str(t, "\\\\");
        } else if (c == '\n') {
            dt_str(t, "\\n");
        } else if (c == '\r') {
            dt_str(t, "\\r");
        } else if (c == '\t') {
            dt_str(t, "\\t");
        } else if (c < 0x20) {
            char u[8];
            snprintf(u, sizeof u, "\\u%04x", c);
            dt_str(t, u);
        } else {
            dt_add(t, (const char *)&c, 1);
        }
    }
    dt_str(t, "\"");
}

static void dt_jsonc(DText *t, const char *s) {
    dt_json(t, s, strlen(s));
}

/* s JSON-escaped without the quotes (malloc'd). */
static char *esc(const char *s) {
    DText t = {0};
    dt_jsonc(&t, s);
    char *r = auk__xmalloc(t.n - 1);
    memcpy(r, t.p + 1, t.n - 2);
    r[t.n - 2] = 0;
    free(t.p);
    return r;
}

static char *dup_n(const char *s, size_t n) {
    char *r = auk__xmalloc(n + 1);
    memcpy(r, s, n);
    r[n] = 0;
    return r;
}

static char *dup_s(const char *s) {
    return dup_n(s, strlen(s));
}

static bool is_space(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f';
}

static const char *skip_space(const char *s) {
    while (*s != 0 && is_space(*s)) {
        s++;
    }
    return s;
}

/* text after its first n whitespace-separated words. */
static const char *after_words(const char *text, int n) {
    const char *t = skip_space(text);
    for (int i = 0; i < n; i++) {
        while (*t != 0 && !is_space(*t)) {
            t++;
        }
        t = skip_space(t);
    }
    return t;
}

/* The whitespace-separated words of s (malloc'd array of malloc'd strings, *n of them). */
static char **split_words(const char *s, int *n) {
    char **w = NULL;
    int k = 0;
    int cap = 0;
    const char *p = skip_space(s);
    while (*p != 0) {
        const char *e = p;
        while (*e != 0 && !is_space(*e)) {
            e++;
        }
        if (k == cap) {
            cap = cap == 0 ? 8 : cap * 2;
            w = auk__xrealloc(w, (size_t)cap * sizeof(char *));
        }
        w[k++] = dup_n(p, (size_t)(e - p));
        p = skip_space(e);
    }
    *n = k;
    return w;
}

static void free_words(char **w, int n) {
    for (int i = 0; i < n; i++) {
        free(w[i]);
    }
    free(w);
}

/* A whole decimal number (an optional sign, then digits). */
static bool parse_i64(const char *s, int64_t *out) {
    if (s == NULL || *s == 0) {
        return false;
    }
    char *end = NULL;
    errno = 0;
    long long v = strtoll(s, &end, 10);
    if (*end != 0 || errno != 0 || is_space(*s)) {
        return false;
    }
    *out = v;
    return true;
}

/* s cut to at most max bytes at a UTF-8 boundary, with "…" when cut (malloc'd). */
static char *cut_text(const char *s, size_t n, size_t max) {
    if (n <= max) {
        return dup_n(s, n);
    }
    size_t end = max;
    while (end > 0 && ((unsigned char)s[end] & 0xC0) == 0x80) {
        end--;
    }
    char *r = auk__xmalloc(end + 4);
    memcpy(r, s, end);
    memcpy(r + end, "\xE2\x80\xA6", 4);
    return r;
}

/* ---- debug info -------------------------------------------------------------------------- */

/* `void kids(void *value, void *ctx)`: reports each part through auk_dbg_kid. */
typedef void (*KidsFn)(void *value, void *ctx);

typedef struct Site {
    uint32_t func;
    uint32_t file;
    uint32_t line;
    uint32_t col;
    uint32_t *vis;
    int64_t nvis;
} Site;

typedef struct Local {
    char *name;
    uint32_t ty;
} Local;

typedef struct FnInfo {
    char *name;
    Local *locals;
    int64_t nlocals;
    int64_t caplocals;
} FnInfo;

typedef struct Info {
    char **files;
    int64_t nfiles;
    char **types;
    int64_t ntypes;
    FnInfo *fns;
    int64_t nfns;
    Site *sites;
    int64_t nsites;
    const AukShowFn *shows;
    /* the children function of each type (NULL: a type without parts) */
    const KidsFn *kids;
    /* breakpoints set at each site (a count: several breakpoints may share one) */
    _Atomic uint32_t *bp;
} Info;

static Info *dbg_info;
static _Atomic bool dbg_attached;
static _Atomic int64_t dbg_next_thread = 1;

static _Thread_local AukDbgFrame *dbg_top;
static _Thread_local int64_t dbg_depth;
static _Thread_local int64_t dbg_tid;
/* Set while this thread changes its frame chain (dbg_top, a frame's parent): see frame_op. */
static _Thread_local _Atomic int dbg_in_op;

enum { STEP_NONE, STEP_IN, STEP_OVER, STEP_OUT };

/* A step in progress on this thread; it lapses at the next stop (any thread's): epoch. */
typedef struct Step {
    int kind;
    uint64_t epoch;
    int64_t depth;
    uint32_t line;
    int64_t site;
} Step;

static _Thread_local Step dbg_step;

enum { CATCH_ALL, CATCH_UNCAUGHT, CATCH_NONE };

typedef struct Bp {
    int64_t id;
    uint32_t *sites;
    int64_t nsites;
    /* stop only where this Auk expression is true (NULL: always) */
    char *cond;
} Bp;

/* A thread the debugger knows: its id and where its frame pointer lives. */
typedef struct ThreadRef {
    int64_t id;
    AukDbgFrame **top;
    /* the thread's frame_op flag (below) */
    _Atomic int *in_op;
} ThreadRef;

/* A command for the stopped focus thread. */
typedef struct Cmd {
    bool has_seq;
    int64_t seq;
    char *text;
} Cmd;

static pthread_mutex_t st_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t st_cv = PTHREAD_COND_INITIALIZER;
static bool st_running;
static bool st_stopped;
/* st_stopped for readers without the lock (frame_op); written with it */
static _Atomic bool st_halt;
static int64_t st_focus;
/* bumped at every stop (steps lapse) and every resume (parked threads wake) */
static uint64_t st_epoch;
static bool st_pause_req;
/* A `pause` that came while stopped, behind this many commands not yet served (queued, or the
 * one the focus thread is serving): commands run in order, so if one of those resumes, the
 * pause applies after it (a "continue" then "pause" must stop again); if none does, the program
 * was stopped all along and the pause is a no-op. */
static int64_t st_pause_after;
/* the focus thread is serving a command it took off the queue */
static bool st_serving;
static bool st_stepping;
static int st_catch_mode = CATCH_UNCAUGHT;
static Bp *st_bps;
static int64_t st_nbps;
static int64_t st_capbps;
static int64_t st_next_bp = 1;
static Cmd *st_queue;
static int64_t st_qhead;
static int64_t st_qlen;
static int64_t st_qcap;
static ThreadRef *st_threads;
static int64_t st_nthreads;
static int64_t st_capthreads;

static pthread_mutex_t dbg_out_lock = PTHREAD_MUTEX_INITIALIZER;
static int dbg_out_fd = -1;

/* Recompute auk_dbg_armed from the state (st_lock held). */
static void rearm(void) {
    bool on = !st_running || st_stopped || st_pause_req || st_stepping || st_nbps != 0;
    atomic_store(&auk_dbg_armed, on ? 1 : 0);
}

/* Wait (st_lock held) until no thread is stopped. */
static void wait_not_stopped(void) {
    while (st_stopped) {
        uint64_t g = st_epoch;
        while (st_stopped && st_epoch == g) {
            pthread_cond_wait(&st_cv, &st_lock);
        }
    }
}

/* Removes the thread from the debugger's list when it ends. */
static pthread_key_t reg_key;
static pthread_once_t reg_once = PTHREAD_ONCE_INIT;

static void unregister(void *v) {
    int64_t id = (int64_t)(intptr_t)v;
    pthread_mutex_lock(&st_lock);
    int64_t k = 0;
    for (int64_t i = 0; i < st_nthreads; i++) {
        if (st_threads[i].id != id) {
            st_threads[k++] = st_threads[i];
        }
    }
    st_nthreads = k;
    pthread_mutex_unlock(&st_lock);
}

static void make_reg_key(void) {
    pthread_key_create(&reg_key, unregister);
}

/* This thread's debugger id (registering it on first use). */
static int64_t tid(void) {
    if (dbg_tid != 0) {
        return dbg_tid;
    }
    int64_t id = atomic_fetch_add(&dbg_next_thread, 1);
    dbg_tid = id;
    pthread_once(&reg_once, make_reg_key);
    pthread_setspecific(reg_key, (void *)(intptr_t)id);
    pthread_mutex_lock(&st_lock);
    if (st_nthreads == st_capthreads) {
        st_capthreads = st_capthreads == 0 ? 8 : st_capthreads * 2;
        st_threads = auk__xrealloc(st_threads, (size_t)st_capthreads * sizeof(ThreadRef));
    }
    st_threads[st_nthreads].id = id;
    st_threads[st_nthreads].top = &dbg_top;
    st_threads[st_nthreads].in_op = &dbg_in_op;
    st_nthreads++;
    pthread_mutex_unlock(&st_lock);
    return id;
}

/* A thread's frame chain is read by the stopped focus thread (`stack`, `vars`, `threads`) while
 * the other threads are parked in the hook. But a thread that was blocked in a call when the
 * world stopped is still running: when the call returns it pushes and pops frames until its
 * next statement parks it, and a popped frame is dead stack memory. So a thread changes its
 * chain only inside frame_op_begin/end: it raises its in_op flag, and while the world is stopped
 * it lowers it and parks instead. The focus thread sets st_halt and then waits for a thread's
 * flag to be down (settle) before reading its chain. Both sides store, then load the other's
 * flag, sequentially consistent (Dekker): either the thread sees st_halt and parks, or the
 * reader sees the flag up and waits for the change to finish. A thread the debugger never
 * registered (dbg_tid 0) is never read, and the busy thread (serving commands, evaluating) must
 * not park on itself.
 *
 * Not covered: the site and locals a thread returning from a blocking call writes before its
 * next statement parks it. The site is one aligned 8-byte store, read relaxed (frame_site); a
 * local shown at that moment may be half-updated. */
static void frame_op_begin(void) {
    if (dbg_tid == 0) {
        return;
    }
    for (;;) {
        atomic_store(&dbg_in_op, 1);
        if (!atomic_load(&st_halt) || auk__dbg_busy()) {
            return;
        }
        atomic_store(&dbg_in_op, 0);
        pthread_mutex_lock(&st_lock);
        wait_not_stopped();
        pthread_mutex_unlock(&st_lock);
    }
}

static void frame_op_end(void) {
    if (dbg_tid != 0) {
        atomic_store_explicit(&dbg_in_op, 0, memory_order_release);
    }
}

/* Wait until thread r is not changing its frame chain (st_halt set: it won't start again). */
static void settle(const ThreadRef *r) {
    while (atomic_load(r->in_op) != 0) {
        sched_yield();
    }
}

/* A frame's current site: generated code stores it (one aligned 8-byte store) at each
 * statement, and the thread may be running (see frame_op), so it is read in one load. */
static int64_t frame_site(AukDbgFrame *f) {
    return __atomic_load_n(&f->site, __ATOMIC_RELAXED);
}

/* ---- the connection ---------------------------------------------------------------------- */

static void dbg_emit(const char *line) {
    pthread_mutex_lock(&dbg_out_lock);
    if (dbg_out_fd >= 0) {
        size_t n = strlen(line);
        char *b = auk__xmalloc(n + 1);
        memcpy(b, line, n);
        b[n] = '\n';
        size_t off = 0;
        while (off < n + 1) {
            /* send, not write: a front end that hung up must not kill the program with
             * SIGPIPE (auk__send_flags, or SO_NOSIGPIPE set at connect); the reader sees the
             * hang-up and lets it run on */
            ssize_t w = send(dbg_out_fd, b + off, n + 1 - off, auk__send_flags);
            if (w < 0 && errno == EINTR) {
                continue;
            }
            if (w <= 0) {
                close(dbg_out_fd);
                dbg_out_fd = -1;
                break;
            }
            off += (size_t)w;
        }
        free(b);
    }
    pthread_mutex_unlock(&dbg_out_lock);
}

static void reply(const Cmd *c, const char *ev, const char *rest) {
    DText t = {0};
    dt_str(&t, "{\"ev\":\"");
    dt_str(&t, ev);
    dt_str(&t, "\"");
    if (c != NULL && c->has_seq) {
        dt_str(&t, ",\"seq\":");
        dt_int(&t, c->seq);
    }
    dt_str(&t, rest);
    dt_str(&t, "}");
    dbg_emit(t.p);
    free(t.p);
}

static void reply_error(const Cmd *c, const char *msg) {
    char *e = esc(msg);
    DText t = {0};
    dt_str(&t, ",\"msg\":\"");
    dt_str(&t, e);
    dt_str(&t, "\"");
    reply(c, "error", t.p);
    free(t.p);
    free(e);
}

/* ---- evaluating Auk expressions ---------------------------------------------------------- */

static AukDbgEvalHook eval_hook;

typedef struct Eval {
    uint32_t site;
    char *expr;
    bool ok;
    AukDbgCompiled c;
    char *err;
} Eval;

static pthread_mutex_t evals_lock = PTHREAD_MUTEX_INITIALIZER;
static Eval *evals;
static int64_t nevals;
static int64_t capevals;

void auk_dbg_set_eval_hook(AukDbgEvalHook h) {
    eval_hook = h;
}

typedef struct EvalEnv {
    AukStr *(*run)(void *const *slots);
    void *const *args;
} EvalEnv;

static void eval_tramp(void *env, void *out) {
    EvalEnv *e = env;
    *(AukStr **)out = e->run(e->args);
}

/* expr trimmed of surrounding whitespace (malloc'd). */
static char *trimmed(const char *s) {
    s = skip_space(s);
    size_t n = strlen(s);
    while (n > 0 && is_space(s[n - 1])) {
        n--;
    }
    return dup_n(s, n);
}

/* Evaluate an Auk expression in frame f: true with the value shown and its type in *value and
 * *ty, or false with *err (all malloc'd). */
static bool eval_at(AukDbgFrame *f, const char *expr, char **value, char **ty, char **err) {
    if (eval_hook == NULL) {
        *err = dup_s("this program can't evaluate expressions");
        return false;
    }
    uint32_t func = (uint32_t)f->func;
    uint32_t site = (uint32_t)f->site;
    char *key = trimmed(expr);
    Eval *found = NULL;
    pthread_mutex_lock(&evals_lock);
    for (int64_t i = 0; i < nevals; i++) {
        if (evals[i].site == site && strcmp(evals[i].expr, key) == 0) {
            found = &evals[i];
            break;
        }
    }
    pthread_mutex_unlock(&evals_lock);
    Eval e;
    if (found != NULL) {
        e = *found;
        free(key);
    } else {
        memset(&e, 0, sizeof e);
        e.site = site;
        e.expr = key;
        e.ok = eval_hook(func, site, key, &e.c, &e.err);
        pthread_mutex_lock(&evals_lock);
        if (nevals == capevals) {
            capevals = capevals == 0 ? 16 : capevals * 2;
            evals = auk__xrealloc(evals, (size_t)capevals * sizeof(Eval));
        }
        evals[nevals++] = e;
        pthread_mutex_unlock(&evals_lock);
    }
    if (!e.ok) {
        *err = dup_s(e.err);
        return false;
    }
    void **args = auk__xmalloc((size_t)(e.c.nslots + 1) * sizeof(void *));
    for (int64_t i = 0; i < e.c.nslots; i++) {
        void *p = f->slots[e.c.slots[i]];
        if (p == NULL) {
            free(args);
            *err = dup_s("a variable it uses has no value yet");
            return false;
        }
        args[i] = p;
    }
    EvalEnv env = {e.c.run, args};
    AukStr *out = NULL;
    int64_t left = auk__show_left();
    auk__set_show_left(1024);
    AukPanic *p = auk__catch_call(eval_tramp, &env, &out);
    auk__set_show_left(left);
    free(args);
    if (p != NULL) {
        DText t = {0};
        dt_str(&t, "panic: ");
        dt_str(&t, p->msg);
        auk__panic_free(p);
        *err = t.p;
        return false;
    }
    *value = cut_text(auk_str_cstr(out), (size_t)auk_str_byte_len(out), 1000);
    auk_release(out);
    *ty = dup_s(e.c.ty);
    return true;
}

/* ---- frames, locals and parts ------------------------------------------------------------ */

/* {"fn":..,"file":..,"line":..,"col":..} of a frame into t; false for no frame. */
static bool frame_json(DText *t, AukDbgFrame *f) {
    if (f == NULL || dbg_info == NULL) {
        return false;
    }
    Info *info = dbg_info;
    int64_t func = f->func;
    int64_t site = frame_site(f);
    dt_str(t, "{\"fn\":");
    dt_jsonc(t, func >= 0 && func < info->nfns ? info->fns[func].name : "?");
    if (site >= 0 && site < info->nsites) {
        Site *s = &info->sites[site];
        dt_str(t, ",\"file\":");
        dt_jsonc(t, info->files[s->file]);
        dt_str(t, ",\"line\":");
        dt_int(t, s->line);
        dt_str(t, ",\"col\":");
        dt_int(t, s->col);
    }
    dt_str(t, "}");
    return true;
}

/* A value of type ty at p, shown (cut to about 1000 bytes; malloc'd). */
static char *show_value(uint32_t ty, void *p) {
    enum { MAX = 1000 };
    int64_t left = auk__show_left();
    auk__set_show_left(MAX + 24);
    AukStr *s = dbg_info->shows[ty](p);
    auk__set_show_left(left);
    char *r = cut_text(auk_str_cstr(s), (size_t)auk_str_byte_len(s), MAX);
    auk_release(s);
    return r;
}

/* At most this many parts of one value are listed. */
enum { KIDS_MAX = 1000 };

/* The walk of a value's parts: down path (a part index per level), then listing the parts of
 * the value reached. */
typedef struct KidCtx {
    uint32_t *path;
    int64_t npath;
    int64_t depth;
    uint32_t counter;
    bool listing;
    /* listing only counts (in more) */
    bool count_only;
    bool found;
    bool done;
    DText out;
    int64_t nout;
    int64_t more;
} KidCtx;

static void item_json(DText *t, const char *name, uint32_t ty, void *p);

/* Does this value have parts (a variant with fields, a non-empty list...)? */
static bool has_parts(uint32_t ty, void *p) {
    KidsFn k = dbg_info->kids[ty];
    if (k == NULL) {
        return false;
    }
    KidCtx c;
    memset(&c, 0, sizeof c);
    c.listing = true;
    c.count_only = true;
    c.found = true;
    k(p, &c);
    free(c.out.p);
    return c.more > 0;
}

/* {"name","type","value"[,"kids":true]} of a value of type ty at p. */
static void item_json(DText *t, const char *name, uint32_t ty, void *p) {
    char *value = show_value(ty, p);
    dt_str(t, "{\"name\":");
    dt_jsonc(t, name);
    dt_str(t, ",\"type\":");
    dt_jsonc(t, ty < dbg_info->ntypes ? dbg_info->types[ty] : "?");
    dt_str(t, ",\"value\":");
    dt_jsonc(t, value);
    if (has_parts(ty, p)) {
        dt_str(t, ",\"kids\":true");
    }
    dt_str(t, "}");
    free(value);
}

/* Where a part's name comes from (computed only when it is listed). */
enum { NAME_TEXT, NAME_INDEX, NAME_KEY };

typedef struct PartName {
    int kind;
    const char *text;
    int64_t index;
    const AukMap *map;
    void *key;
} PartName;

static char *part_name(const PartName *n) {
    if (n->kind == NAME_TEXT) {
        return dup_s(n->text);
    }
    if (n->kind == NAME_INDEX) {
        char b[24];
        snprintf(b, sizeof b, "%lld", (long long)n->index);
        return dup_s(b);
    }
    if (n->map->kops->show == NULL) {
        return dup_s("?");
    }
    AukStr *s = n->map->kops->show(n->key);
    char *r = dup_n(auk_str_cstr(s), (size_t)auk_str_byte_len(s));
    auk_release(s);
    return r;
}

/* One part (index counter) of the value being walked. */
static void kid(KidCtx *c, const PartName *name, uint32_t ty, void *p) {
    if (c->done) {
        return;
    }
    if (c->listing) {
        if (c->count_only || c->nout >= KIDS_MAX) {
            c->more++;
            /* one part is enough to know there are some */
            c->done = c->count_only;
        } else {
            char *nm = part_name(name);
            DText item = {0};
            item_json(&item, nm, ty, p);
            if (c->nout != 0) {
                dt_str(&c->out, ",");
            }
            dt_str(&c->out, item.p);
            c->nout++;
            free(item.p);
            free(nm);
        }
        return;
    }
    uint32_t i = c->counter++;
    if (i != c->path[c->depth]) {
        return;
    }
    /* the part on the path: walk into it (only one path, so the walk ends after it) */
    KidsFn k = dbg_info->kids[ty];
    if (k == NULL) {
        c->done = true;
        return;
    }
    if (c->depth + 1 == c->npath) {
        c->listing = true;
        c->found = true;
    } else {
        c->depth++;
        c->counter = 0;
    }
    k(p, c);
    c->listing = false;
    c->done = true;
}

/* Generated children functions report a named part. */
AUK_API void auk_dbg_kid(void *ctx, const char *name, int64_t ty, void *p) {
    PartName n = {NAME_TEXT, name, 0, NULL, NULL};
    kid(ctx, &n, (uint32_t)ty, p);
}

/* The elements of a list (elem bytes each). */
AUK_API void auk_dbg_kid_arr(void *ctx, void *list, int64_t ty, int64_t elem) {
    const AukArr *a = list;
    KidCtx *c = ctx;
    if (a == NULL || c->done) {
        return;
    }
    if (!c->listing) {
        /* walking through: straight to the element on the path */
        int64_t i = c->path[c->depth];
        if (i < a->len) {
            c->counter = (uint32_t)i;
            PartName n = {NAME_INDEX, NULL, i, NULL, NULL};
            kid(c, &n, (uint32_t)ty, a->data + i * elem);
        } else {
            c->done = true;
        }
        return;
    }
    int64_t shown = 0;
    if (!c->count_only) {
        int64_t room = KIDS_MAX - c->nout;
        shown = a->len < room ? a->len : (room > 0 ? room : 0);
    }
    for (int64_t i = 0; i < shown; i++) {
        PartName n = {NAME_INDEX, NULL, i, NULL, NULL};
        kid(c, &n, (uint32_t)ty, a->data + i * elem);
    }
    c->more += a->len - shown;
}

/* The entries of a map: each value, named by its key shown. */
AUK_API void auk_dbg_kid_map(void *ctx, void *map, int64_t ty) {
    const AukMap *m = map;
    if (m == NULL) {
        return;
    }
    int64_t it = 0;
    void *k = NULL;
    void *v = NULL;
    while (auk_map_next(m, &it, &k, &v)) {
        PartName n = {NAME_KEY, NULL, 0, m, k};
        kid(ctx, &n, (uint32_t)ty, v);
    }
}

/* A local in scope at a frame's current statement. */
typedef struct LocalRef {
    const char *name;
    uint32_t ty;
    void *p;
} LocalRef;

/* The locals in scope at a frame's current statement, in binding order (malloc'd, *n of them).
 * A shadowed name gives only its latest binding. */
static LocalRef *locals_of(AukDbgFrame *f, int64_t *n) {
    *n = 0;
    Info *info = dbg_info;
    int64_t site = frame_site(f);
    if (info == NULL || f->func < 0 || f->func >= info->nfns || site < 0 || site >= info->nsites) {
        return NULL;
    }
    FnInfo *fi = &info->fns[f->func];
    Site *s = &info->sites[site];
    LocalRef *out = auk__xmalloc((size_t)(s->nvis + 1) * sizeof(LocalRef));
    int64_t k = 0;
    for (int64_t i = s->nvis - 1; i >= 0; i--) {
        uint32_t slot = s->vis[i];
        if (slot >= fi->nlocals) {
            continue;
        }
        const char *name = fi->locals[slot].name;
        bool seen = strcmp(name, "_") == 0;
        for (int64_t j = 0; j < k && !seen; j++) {
            seen = strcmp(out[j].name, name) == 0;
        }
        void *p = f->slots[slot];
        if (seen || p == NULL) {
            continue;
        }
        out[k].name = name;
        out[k].ty = fi->locals[slot].ty;
        out[k].p = p;
        k++;
    }
    /* back into binding order */
    for (int64_t i = 0; i < k / 2; i++) {
        LocalRef t = out[i];
        out[i] = out[k - 1 - i];
        out[k - 1 - i] = t;
    }
    *n = k;
    return out;
}

/* ,"kids":[...] (and "more":N) for the parts of the value at p reached by path into t; false
 * with *err. */
static bool kids_json(DText *t, uint32_t ty, void *p, uint32_t *path, int64_t npath, const char **err) {
    KidsFn k = dbg_info->kids[ty];
    if (k == NULL) {
        *err = "the value has no parts";
        return false;
    }
    KidCtx c;
    memset(&c, 0, sizeof c);
    c.path = path;
    c.npath = npath;
    c.listing = npath == 0;
    c.found = npath == 0;
    k(p, &c);
    if (!c.found) {
        free(c.out.p);
        *err = "no such part";
        return false;
    }
    dt_str(t, ",\"kids\":[");
    if (c.out.p != NULL) {
        dt_str(t, c.out.p);
    }
    dt_str(t, "]");
    if (c.more > 0) {
        dt_str(t, ",\"more\":");
        dt_int(t, c.more);
    }
    free(c.out.p);
    return true;
}

/* The innermost frame of thread t (stopped: its frames don't change); false if there is no
 * such thread. */
static bool thread_top(int64_t t, int64_t me, AukDbgFrame **out) {
    if (t == me) {
        *out = dbg_top;
        return true;
    }
    pthread_mutex_lock(&st_lock);
    bool found = false;
    for (int64_t i = 0; i < st_nthreads; i++) {
        if (st_threads[i].id == t) {
            settle(&st_threads[i]);
            *out = *st_threads[i].top;
            found = true;
            break;
        }
    }
    pthread_mutex_unlock(&st_lock);
    return found;
}

/* Frame n (0 = innermost) of thread t, or NULL with *err (malloc'd). */
static AukDbgFrame *frame_at(int64_t t, int64_t n, int64_t me, char **err) {
    AukDbgFrame *f;
    char b[64];
    if (!thread_top(t, me, &f)) {
        snprintf(b, sizeof b, "no thread %lld", (long long)t);
        *err = dup_s(b);
        return NULL;
    }
    for (int64_t i = 0; i < n && f != NULL; i++) {
        f = f->parent;
    }
    if (f == NULL) {
        snprintf(b, sizeof b, "no frame %lld", (long long)n);
        *err = dup_s(b);
    }
    return f;
}

/* ---- stopping ---------------------------------------------------------------------------- */

/* Has this thread's step finished at site (st_lock held)? */
static bool step_done(int64_t site) {
    Step s = dbg_step;
    if (s.kind == STEP_NONE || s.epoch != st_epoch || !st_stepping) {
        return false;
    }
    uint32_t line = site >= 0 && site < dbg_info->nsites ? dbg_info->sites[site].line : 0;
    /* a new line, or the same statement again (the next loop iteration) */
    bool moved = line != s.line || site <= s.site;
    switch (s.kind) {
    case STEP_IN:
        return dbg_depth != s.depth || moved;
    case STEP_OVER:
        return dbg_depth < s.depth || (dbg_depth == s.depth && moved);
    case STEP_OUT:
        return dbg_depth < s.depth;
    default:
        return false;
    }
}

static int64_t word_int(char **w, int nw, int i, int64_t dflt) {
    int64_t v;
    return i < nw && parse_i64(w[i], &v) ? v : dflt;
}

/* Serve one command of the stopped focus thread: true with *kind for a resume. */
static bool serve(const Cmd *cmd, int64_t me, int *kind) {
    int nw;
    char **w = split_words(cmd->text, &nw);
    bool resume = false;
    const char *c0 = w[0];
    if (strcmp(c0, "continue") == 0 || strcmp(c0, "c") == 0) {
        *kind = STEP_NONE;
        resume = true;
    } else if (strcmp(c0, "step") == 0 || strcmp(c0, "s") == 0) {
        *kind = STEP_IN;
        resume = true;
    } else if (strcmp(c0, "next") == 0 || strcmp(c0, "n") == 0) {
        *kind = STEP_OVER;
        resume = true;
    } else if (strcmp(c0, "finish") == 0) {
        *kind = STEP_OUT;
        resume = true;
    } else if (strcmp(c0, "stack") == 0 || strcmp(c0, "bt") == 0) {
        int64_t t = word_int(w, nw, 1, me);
        AukDbgFrame *top;
        if (thread_top(t, me, &top)) {
            DText r = {0};
            dt_str(&r, ",\"thread\":");
            dt_int(&r, t);
            dt_str(&r, ",\"frames\":[");
            bool first = true;
            for (AukDbgFrame *f = top; f != NULL; f = f->parent) {
                DText j = {0};
                if (!frame_json(&j, f)) {
                    break;
                }
                if (!first) {
                    dt_str(&r, ",");
                }
                first = false;
                dt_str(&r, j.p);
                free(j.p);
            }
            dt_str(&r, "]");
            reply(cmd, "stack", r.p);
            free(r.p);
        } else {
            char b[64];
            snprintf(b, sizeof b, "no thread %lld", (long long)t);
            reply_error(cmd, b);
        }
    } else if (strcmp(c0, "vars") == 0 || strcmp(c0, "locals") == 0) {
        int64_t n = word_int(w, nw, 1, 0);
        int64_t t = word_int(w, nw, 2, me);
        char *err = NULL;
        AukDbgFrame *f = frame_at(t, n, me, &err);
        if (f != NULL) {
            DText r = {0};
            dt_str(&r, ",\"thread\":");
            dt_int(&r, t);
            dt_str(&r, ",\"frame\":");
            dt_int(&r, n);
            dt_str(&r, ",\"vars\":[");
            int64_t nl;
            LocalRef *ls = locals_of(f, &nl);
            for (int64_t i = 0; i < nl; i++) {
                if (i != 0) {
                    dt_str(&r, ",");
                }
                item_json(&r, ls[i].name, ls[i].ty, ls[i].p);
            }
            free(ls);
            dt_str(&r, "]");
            reply(cmd, "vars", r.p);
            free(r.p);
        } else {
            reply_error(cmd, err);
            free(err);
        }
    } else if (strcmp(c0, "kids") == 0) {
        /* kids <frame> <thread> <local> [i...]: the parts of a local, or of its part i, j... */
        int64_t n = word_int(w, nw, 1, 0);
        int64_t t = word_int(w, nw, 2, me);
        uint32_t *path = auk__xmalloc((size_t)(nw + 1) * sizeof(uint32_t));
        int64_t np = 0;
        for (int i = 4; i < nw; i++) {
            int64_t v;
            if (parse_i64(w[i], &v) && v >= 0 && v <= UINT32_MAX && w[i][0] != '-' && w[i][0] != '+') {
                path[np++] = (uint32_t)v;
            }
        }
        char *err = NULL;
        AukDbgFrame *f = frame_at(t, n, me, &err);
        if (f == NULL) {
            reply_error(cmd, err);
            free(err);
        } else if (nw < 4) {
            reply_error(cmd, "kids: which local?");
        } else {
            int64_t nl;
            LocalRef *ls = locals_of(f, &nl);
            LocalRef *hit = NULL;
            for (int64_t i = 0; i < nl && hit == NULL; i++) {
                if (strcmp(ls[i].name, w[3]) == 0) {
                    hit = &ls[i];
                }
            }
            if (hit == NULL) {
                DText m = {0};
                dt_str(&m, "no local `");
                dt_str(&m, w[3]);
                dt_str(&m, "` here");
                reply_error(cmd, m.p);
                free(m.p);
            } else {
                DText r = {0};
                const char *why = NULL;
                if (kids_json(&r, hit->ty, hit->p, path, np, &why)) {
                    reply(cmd, "kids", r.p);
                } else {
                    reply_error(cmd, why);
                }
                free(r.p);
            }
            free(ls);
        }
        free(path);
    } else if (strcmp(c0, "eval") == 0 || strcmp(c0, "e") == 0) {
        /* eval <frame> <thread> <expression> */
        int64_t n = word_int(w, nw, 1, 0);
        int64_t t = word_int(w, nw, 2, me);
        const char *expr = after_words(cmd->text, 3);
        if (expr[0] == 0) {
            reply(cmd, "error", ",\"msg\":\"eval: which expression?\"");
        } else {
            char *err = NULL;
            char *value = NULL;
            char *ty = NULL;
            AukDbgFrame *f = frame_at(t, n, me, &err);
            if (f != NULL && eval_at(f, expr, &value, &ty, &err)) {
                DText r = {0};
                dt_str(&r, ",\"value\":");
                dt_jsonc(&r, value);
                dt_str(&r, ",\"type\":");
                dt_jsonc(&r, ty);
                reply(cmd, "value", r.p);
                free(r.p);
            } else {
                reply_error(cmd, err);
            }
            free(err);
            free(value);
            free(ty);
        }
    } else if (strcmp(c0, "threads") == 0) {
        pthread_mutex_lock(&st_lock);
        int64_t nt = st_nthreads;
        ThreadRef *ts = auk__xmalloc((size_t)(nt + 1) * sizeof(ThreadRef));
        memcpy(ts, st_threads, (size_t)nt * sizeof(ThreadRef));
        AukDbgFrame **tops = auk__xmalloc((size_t)(nt + 1) * sizeof(AukDbgFrame *));
        for (int64_t i = 0; i < nt; i++) {
            settle(&ts[i]);
            tops[i] = *ts[i].top;
        }
        pthread_mutex_unlock(&st_lock);
        DText r = {0};
        dt_str(&r, ",\"threads\":[");
        for (int64_t i = 0; i < nt; i++) {
            if (i != 0) {
                dt_str(&r, ",");
            }
            dt_str(&r, "{\"id\":");
            dt_int(&r, ts[i].id);
            dt_str(&r, ",\"frame\":");
            if (!frame_json(&r, tops[i])) {
                dt_str(&r, "null");
            }
            dt_str(&r, "}");
        }
        dt_str(&r, "]");
        reply(cmd, "threads", r.p);
        free(r.p);
        free(ts);
        free(tops);
    } else {
        DText m = {0};
        dt_str(&m, "unknown command `");
        dt_str(&m, c0);
        dt_str(&m, "`");
        reply_error(cmd, m.p);
        free(m.p);
    }
    free_words(w, nw);
    return resume;
}

/* Stop the world on this thread (st_lock held, released on return), report it, and serve
 * commands until a resume. extra: more fields for the event (or NULL). */
static void stop(int64_t me, const char *reason, const char *extra) {
    st_stopped = true;
    atomic_store(&st_halt, true);
    st_stepping = false;
    st_focus = me;
    st_epoch++;
    rearm();
    DText ev = {0};
    dt_str(&ev, "{\"ev\":\"stopped\",\"reason\":\"");
    dt_str(&ev, reason);
    dt_str(&ev, "\",\"thread\":");
    dt_int(&ev, me);
    if (strcmp(reason, "breakpoint") == 0 && dbg_top != NULL) {
        uint32_t site = (uint32_t)dbg_top->site;
        dt_str(&ev, ",\"bps\":[");
        bool first = true;
        for (int64_t i = 0; i < st_nbps; i++) {
            for (int64_t j = 0; j < st_bps[i].nsites; j++) {
                if (st_bps[i].sites[j] == site) {
                    if (!first) {
                        dt_str(&ev, ",");
                    }
                    first = false;
                    dt_int(&ev, st_bps[i].id);
                    break;
                }
            }
        }
        dt_str(&ev, "]");
    }
    DText fr = {0};
    if (frame_json(&fr, dbg_top)) {
        dt_str(&ev, ",\"frame\":");
        dt_str(&ev, fr.p);
    }
    free(fr.p);
    if (extra != NULL) {
        dt_str(&ev, extra);
    }
    dt_str(&ev, "}");
    dbg_emit(ev.p);
    free(ev.p);
    /* serve commands until one resumes */
    for (;;) {
        while (st_qlen == 0 && st_stopped) {
            pthread_cond_wait(&st_cv, &st_lock);
        }
        if (!st_stopped) {
            /* detached */
            pthread_mutex_unlock(&st_lock);
            return;
        }
        Cmd cmd = st_queue[st_qhead];
        st_qhead = (st_qhead + 1) % st_qcap;
        st_qlen--;
        st_serving = true;
        pthread_mutex_unlock(&st_lock);
        bool was = auk__dbg_set_busy(true);
        int kind = STEP_NONE;
        bool resume = serve(&cmd, me, &kind);
        auk__dbg_set_busy(was);
        pthread_mutex_lock(&st_lock);
        st_serving = false;
        if (st_pause_after > 0) {
            st_pause_after--;
            if (resume) {
                st_pause_req = true;
                st_pause_after = 0;
            }
        }
        if (resume) {
            if (kind != STEP_NONE) {
                int64_t site = dbg_top == NULL ? -1 : dbg_top->site;
                uint32_t line = site >= 0 && site < dbg_info->nsites ? dbg_info->sites[site].line : 0;
                st_stepping = true;
                dbg_step.kind = kind;
                dbg_step.epoch = st_epoch + 1;
                dbg_step.depth = dbg_depth;
                dbg_step.line = line;
                dbg_step.site = site;
            }
            st_stopped = false;
            atomic_store(&st_halt, false);
            st_epoch++;
            rearm();
            pthread_cond_broadcast(&st_cv);
            pthread_mutex_unlock(&st_lock);
            reply(&cmd, "ok", "");
            free(cmd.text);
            return;
        }
        free(cmd.text);
    }
}

/* ---- generated code's entry points ------------------------------------------------------- */

AUK_API void auk_dbg_enter(AukDbgFrame *f) {
    if (dbg_tid == 0 && atomic_load_explicit(&dbg_attached, memory_order_relaxed)) {
        tid();
    }
    frame_op_begin();
    f->parent = dbg_top;
    dbg_top = f;
    frame_op_end();
    dbg_depth++;
}

AUK_API void auk_dbg_leave(AukDbgFrame *f) {
    frame_op_begin();
    dbg_top = f->parent;
    frame_op_end();
    dbg_depth--;
}

/* Does a breakpoint at site have a condition that holds (or none)? Runs Auk code, without the
 * lock. *extra gets a "cond_error" field when a condition fails to evaluate. */
static bool bp_hit(AukDbgFrame *f, int64_t site, char **extra) {
    /* the conditions of the breakpoints at site, in order (NULL: none) */
    pthread_mutex_lock(&st_lock);
    int64_t nc = 0;
    char **conds = auk__xmalloc((size_t)(st_nbps + 1) * sizeof(char *));
    for (int64_t i = 0; i < st_nbps; i++) {
        for (int64_t j = 0; j < st_bps[i].nsites; j++) {
            if (st_bps[i].sites[j] == (uint32_t)site) {
                conds[nc++] = st_bps[i].cond == NULL ? NULL : dup_s(st_bps[i].cond);
                break;
            }
        }
    }
    pthread_mutex_unlock(&st_lock);
    bool hit = false;
    for (int64_t i = 0; i < nc && !hit; i++) {
        if (conds[i] == NULL) {
            hit = true;
            break;
        }
        bool was = auk__dbg_set_busy(true);
        char *v = NULL;
        char *ty = NULL;
        char *err = NULL;
        bool ok = eval_at(f, conds[i], &v, &ty, &err);
        auk__dbg_set_busy(was);
        if (ok && strcmp(v, "true") == 0) {
            hit = true;
        } else if (!ok) {
            DText m = {0};
            dt_str(&m, conds[i]);
            dt_str(&m, ": ");
            dt_str(&m, err);
            DText o = {0};
            dt_str(&o, ",\"cond_error\":");
            dt_jsonc(&o, m.p);
            free(m.p);
            *extra = o.p;
            hit = true;
        }
        free(v);
        free(ty);
        free(err);
    }
    for (int64_t i = 0; i < nc; i++) {
        free(conds[i]);
    }
    free(conds);
    return hit;
}

/* A statement of an instrumented function, while armed: stop here? */
AUK_API void auk_dbg_hook(AukDbgFrame *f) {
    if (!atomic_load_explicit(&dbg_attached, memory_order_relaxed) || auk__dbg_busy() || dbg_info == NULL) {
        return;
    }
    int64_t site = f->site;
    int64_t me = tid();
    pthread_mutex_lock(&st_lock);
    /* another thread has stopped: wait until it resumes */
    wait_not_stopped();
    char *extra = NULL;
    const char *reason;
    if (st_pause_req) {
        st_pause_req = false;
        reason = "pause";
    } else if (site >= 0 && site < dbg_info->nsites && atomic_load_explicit(&dbg_info->bp[site], memory_order_relaxed) > 0) {
        pthread_mutex_unlock(&st_lock);
        bool hit = bp_hit(f, site, &extra);
        pthread_mutex_lock(&st_lock);
        wait_not_stopped();
        if (hit) {
            reason = "breakpoint";
        } else if (step_done(site)) {
            reason = "step";
        } else {
            pthread_mutex_unlock(&st_lock);
            return;
        }
    } else if (step_done(site)) {
        reason = "step";
    } else {
        pthread_mutex_unlock(&st_lock);
        return;
    }
    stop(me, reason, extra);
    free(extra);
}

/* A panic on this thread (rc.c): stop first, if the debugger wants panics. caught: it will jump
 * to a recovery point (`catch`, a task's own). */
void auk__dbg_on_panic(const char *loc, const char *msg, size_t n, bool caught) {
    if (!atomic_load_explicit(&dbg_attached, memory_order_relaxed) || auk__dbg_busy() || dbg_info == NULL) {
        return;
    }
    int64_t me = tid();
    pthread_mutex_lock(&st_lock);
    bool want = st_catch_mode == CATCH_ALL || (st_catch_mode == CATCH_UNCAUGHT && !caught);
    if (!want || !st_running) {
        pthread_mutex_unlock(&st_lock);
        return;
    }
    wait_not_stopped();
    DText extra = {0};
    dt_str(&extra, ",\"msg\":");
    dt_json(&extra, msg, n);
    dt_str(&extra, ",\"loc\":");
    dt_jsonc(&extra, loc);
    if (caught) {
        dt_str(&extra, ",\"caught\":true");
    }
    stop(me, "panic", extra.p);
    free(extra.p);
}

/* The debugger stack of a recovery point (`catch`, a task), restored when a panic jumps back
 * past frames that never got to leave. */
void auk__dbg_save(void **top, int64_t *depth) {
    *top = dbg_top;
    *depth = dbg_depth;
}

void auk__dbg_restore(void *top, int64_t depth) {
    frame_op_begin();
    dbg_top = top;
    frame_op_end();
    dbg_depth = depth;
}

/* ---- breakpoints and the reader ---------------------------------------------------------- */

static bool ends_with(const char *s, const char *suffix) {
    size_t n = strlen(s);
    size_t k = strlen(suffix);
    return k <= n && memcmp(s + n - k, suffix, k) == 0;
}

/* The sites of a breakpoint spec (file:line or a function name), with its file and resolved
 * line; NULL with *err (malloc'd). */
static uint32_t *resolve(const char *spec, int64_t *nsites, const char **file_out, uint32_t *line_out, char **err) {
    Info *info = dbg_info;
    const char *colon = strrchr(spec, ':');
    int64_t line;
    if (colon != NULL && parse_i64(colon + 1, &line) && colon[1] != '-' && colon[1] != '+' && line >= 0 &&
        line <= UINT32_MAX) {
        char *file = dup_n(spec, (size_t)(colon - spec));
        char real[PATH_MAX];
        const char *want = realpath(file, real) != NULL ? real : file;
        DText slash = {0};
        dt_str(&slash, "/");
        dt_str(&slash, file);
        bool *in = auk__xcalloc((size_t)info->nfiles + 1, sizeof(bool));
        bool any = false;
        for (int64_t i = 0; i < info->nfiles; i++) {
            const char *f = info->files[i];
            in[i] = strcmp(f, want) == 0 || ends_with(f, slash.p) || strcmp(f, file) == 0;
            any = any || in[i];
        }
        free(slash.p);
        DText m = {0};
        if (!any) {
            dt_str(&m, "no code in `");
            dt_str(&m, file);
            dt_str(&m, "`");
            *err = m.p;
            free(in);
            free(file);
            return NULL;
        }
        int64_t best = -1;
        for (int64_t i = 0; i < info->nsites; i++) {
            Site *s = &info->sites[i];
            if (in[s->file] && s->line >= line && (best < 0 || s->line < best)) {
                best = s->line;
            }
        }
        if (best < 0) {
            dt_str(&m, "no code at or after ");
            dt_str(&m, file);
            dt_str(&m, ":");
            dt_int(&m, line);
            *err = m.p;
            free(in);
            free(file);
            return NULL;
        }
        /* the first statement on that line in each function (instance) */
        uint32_t *sites = auk__xmalloc((size_t)info->nsites * sizeof(uint32_t));
        uint32_t *fns = auk__xmalloc((size_t)info->nsites * sizeof(uint32_t));
        int64_t k = 0;
        for (int64_t i = 0; i < info->nsites; i++) {
            Site *s = &info->sites[i];
            if (!in[s->file] || s->line != best) {
                continue;
            }
            bool seen = false;
            for (int64_t j = 0; j < k && !seen; j++) {
                seen = fns[j] == s->func;
            }
            if (!seen) {
                fns[k] = s->func;
                sites[k] = (uint32_t)i;
                k++;
            }
        }
        free(fns);
        free(in);
        free(file);
        *nsites = k;
        *file_out = info->files[info->sites[sites[0]].file];
        *line_out = (uint32_t)best;
        return sites;
    }
    DText dot = {0};
    dt_str(&dot, ".");
    dt_str(&dot, spec);
    uint32_t *sites = auk__xmalloc((size_t)(info->nfns + 1) * sizeof(uint32_t));
    int64_t k = 0;
    for (int64_t fi = 0; fi < info->nfns; fi++) {
        const char *name = info->fns[fi].name;
        if (strcmp(name, spec) != 0 && !ends_with(name, dot.p)) {
            continue;
        }
        for (int64_t i = 0; i < info->nsites; i++) {
            if (info->sites[i].func == fi) {
                sites[k++] = (uint32_t)i;
                break;
            }
        }
    }
    free(dot.p);
    if (k == 0) {
        free(sites);
        DText m = {0};
        dt_str(&m, "no function `");
        dt_str(&m, spec);
        dt_str(&m, "`");
        *err = m.p;
        return NULL;
    }
    Site *s = &info->sites[sites[0]];
    *nsites = k;
    *file_out = info->files[s->file];
    *line_out = s->line;
    return sites;
}

/* `break <spec> [if <condition>]` (st_lock held). */
static void cmd_break(const Cmd *c) {
    const char *rest = after_words(c->text, 1);
    const char *at = strstr(rest, " if ");
    char *spec;
    char *cond = NULL;
    if (at != NULL) {
        char *sp = dup_n(rest, (size_t)(at - rest));
        spec = trimmed(sp);
        free(sp);
        cond = trimmed(at + 4);
        if (cond[0] == 0) {
            free(cond);
            cond = NULL;
        }
    } else {
        spec = trimmed(rest);
    }
    int64_t n = 0;
    const char *file = NULL;
    uint32_t line = 0;
    char *err = NULL;
    uint32_t *sites = resolve(spec, &n, &file, &line, &err);
    free(spec);
    if (sites == NULL) {
        pthread_mutex_unlock(&st_lock);
        reply_error(c, err);
        free(err);
        free(cond);
        pthread_mutex_lock(&st_lock);
        return;
    }
    for (int64_t i = 0; i < n; i++) {
        atomic_fetch_add(&dbg_info->bp[sites[i]], 1);
    }
    int64_t id = st_next_bp++;
    if (st_nbps == st_capbps) {
        st_capbps = st_capbps == 0 ? 8 : st_capbps * 2;
        st_bps = auk__xrealloc(st_bps, (size_t)st_capbps * sizeof(Bp));
    }
    st_bps[st_nbps].id = id;
    st_bps[st_nbps].sites = sites;
    st_bps[st_nbps].nsites = n;
    st_bps[st_nbps].cond = cond;
    st_nbps++;
    rearm();
    DText r = {0};
    dt_str(&r, ",\"id\":");
    dt_int(&r, id);
    dt_str(&r, ",\"file\":");
    dt_jsonc(&r, file);
    dt_str(&r, ",\"line\":");
    dt_int(&r, line);
    if (cond != NULL) {
        dt_str(&r, ",\"cond\":");
        dt_jsonc(&r, cond);
    }
    pthread_mutex_unlock(&st_lock);
    reply(c, "break", r.p);
    pthread_mutex_lock(&st_lock);
    free(r.p);
}

/* `delete [id]` (st_lock held). */
static void cmd_delete(int64_t id, bool all) {
    int64_t k = 0;
    for (int64_t i = 0; i < st_nbps; i++) {
        Bp *b = &st_bps[i];
        if (all || b->id == id) {
            for (int64_t j = 0; j < b->nsites; j++) {
                atomic_fetch_sub(&dbg_info->bp[b->sites[j]], 1);
            }
            free(b->sites);
            free(b->cond);
        } else {
            st_bps[k++] = *b;
        }
    }
    st_nbps = k;
    rearm();
}

static void queue_push(Cmd c) {
    if (st_qlen == st_qcap) {
        int64_t cap = st_qcap == 0 ? 8 : st_qcap * 2;
        Cmd *q = auk__xmalloc((size_t)cap * sizeof(Cmd));
        for (int64_t i = 0; i < st_qlen; i++) {
            q[i] = st_queue[(st_qhead + i) % st_qcap];
        }
        free(st_queue);
        st_queue = q;
        st_qcap = cap;
        st_qhead = 0;
    }
    st_queue[(st_qhead + st_qlen) % st_qcap] = c;
    st_qlen++;
}

/* One line from the connection: commands that don't need a stopped thread run here; the
 * others go to the focus thread's queue. */
static void handle_line(const char *line) {
    char *text = trimmed(line);
    Cmd c = {false, 0, NULL};
    if (text[0] == '@') {
        const char *e = text + 1;
        while (*e != 0 && !is_space(*e)) {
            e++;
        }
        char *num = dup_n(text + 1, (size_t)(e - text - 1));
        int64_t v;
        if (parse_i64(num, &v)) {
            c.has_seq = true;
            c.seq = v;
            char *rest = dup_s(after_words(text, 1));
            free(text);
            text = rest;
        }
        free(num);
    }
    int nw;
    char **w = split_words(text, &nw);
    if (nw == 0) {
        free_words(w, nw);
        free(text);
        return;
    }
    c.text = text;
    const char *c0 = w[0];
    pthread_mutex_lock(&st_lock);
    if (strcmp(c0, "run") == 0) {
        st_running = true;
        rearm();
        pthread_cond_broadcast(&st_cv);
        pthread_mutex_unlock(&st_lock);
        reply(&c, "ok", "");
    } else if (strcmp(c0, "break") == 0 || strcmp(c0, "b") == 0) {
        cmd_break(&c);
        pthread_mutex_unlock(&st_lock);
    } else if (strcmp(c0, "delete") == 0 || strcmp(c0, "d") == 0) {
        int64_t id = 0;
        bool one = nw > 1 && parse_i64(w[1], &id);
        cmd_delete(id, !one);
        pthread_mutex_unlock(&st_lock);
        reply(&c, "ok", "");
    } else if (strcmp(c0, "catch") == 0) {
        const char *m = nw > 1 ? w[1] : "";
        st_catch_mode = strcmp(m, "all") == 0 ? CATCH_ALL : strcmp(m, "none") == 0 ? CATCH_NONE : CATCH_UNCAUGHT;
        pthread_mutex_unlock(&st_lock);
        reply(&c, "ok", "");
    } else if (strcmp(c0, "pause") == 0) {
        if (!st_stopped) {
            st_pause_req = true;
            rearm();
        } else if (st_qlen > 0 || st_serving) {
            st_pause_after = st_qlen + (st_serving ? 1 : 0);
        }
        pthread_mutex_unlock(&st_lock);
        reply(&c, "ok", "");
    } else if (strcmp(c0, "kill") == 0) {
        pthread_mutex_unlock(&st_lock);
        reply(&c, "ok", "");
        fflush(stdout);
        _exit(137);
    } else if (st_stopped) {
        queue_push(c);
        c.text = NULL; /* the queue owns it */
        pthread_cond_broadcast(&st_cv);
        pthread_mutex_unlock(&st_lock);
    } else {
        pthread_mutex_unlock(&st_lock);
        reply(&c, "error", ",\"msg\":\"the program is running\"");
    }
    free_words(w, nw);
    free(c.text);
}

/* The connection's reader thread. */
static void *dbg_reader(void *arg) {
    int fd = (int)(intptr_t)arg;
    DText line = {0};
    char buf[4096];
    for (;;) {
        ssize_t r = read(fd, buf, sizeof buf);
        if (r < 0 && errno == EINTR) {
            continue;
        }
        if (r <= 0) {
            break;
        }
        for (ssize_t i = 0; i < r; i++) {
            if (buf[i] == '\n') {
                if (line.n > 0 && line.p[line.n - 1] == '\r') {
                    line.p[--line.n] = 0;
                }
                handle_line(line.n == 0 ? "" : line.p);
                line.n = 0;
            } else {
                dt_add(&line, buf + i, 1);
            }
        }
    }
    if (line.n > 0) {
        handle_line(line.p);
    }
    free(line.p);
    /* the front end went away: let the program run on */
    atomic_store(&dbg_attached, false);
    pthread_mutex_lock(&st_lock);
    st_running = true;
    st_stopped = false;
    atomic_store(&st_halt, false);
    st_pause_req = false;
    st_pause_after = 0;
    st_stepping = false;
    st_epoch++;
    atomic_store(&auk_dbg_armed, 0);
    pthread_cond_broadcast(&st_cv);
    pthread_mutex_unlock(&st_lock);
    return NULL;
}

static void dbg_at_exit(void) {
    if (atomic_load_explicit(&dbg_attached, memory_order_relaxed)) {
        dbg_emit("{\"ev\":\"exited\"}");
    }
}

/* ---- debug info -------------------------------------------------------------------------- */

static void push_str(char ***a, int64_t *n, const char *s) {
    *a = auk__xrealloc(*a, (size_t)(*n + 1) * sizeof(char *));
    (*a)[(*n)++] = dup_s(s);
}

static uint32_t to_u32(const char *s) {
    int64_t v;
    return parse_i64(s, &v) && v >= 0 && v <= UINT32_MAX && s[0] != '+' ? (uint32_t)v : 0;
}

/* Parse the debug info text (see dbg_tables in src/build.rs). */
static Info *parse_info(const char *text, const AukShowFn *shows, const KidsFn *kids) {
    Info *info = auk__xcalloc(1, sizeof(Info));
    info->shows = shows;
    info->kids = kids;
    int64_t capsites = 0;
    const char *p = text;
    while (*p != 0) {
        const char *e = strchr(p, '\n');
        size_t n = e == NULL ? strlen(p) : (size_t)(e - p);
        char *line = dup_n(p, n);
        if (n > 0 && line[n - 1] == '\r') {
            line[n - 1] = 0;
        }
        char *sp = strchr(line, ' ');
        if (sp != NULL) {
            *sp = 0;
            const char *k = line;
            const char *rest = sp + 1;
            if (strcmp(k, "p") == 0) {
                push_str(&info->files, &info->nfiles, rest);
            } else if (strcmp(k, "t") == 0) {
                push_str(&info->types, &info->ntypes, rest);
            } else if (strcmp(k, "f") == 0) {
                info->fns = auk__xrealloc(info->fns, (size_t)(info->nfns + 1) * sizeof(FnInfo));
                FnInfo *f = &info->fns[info->nfns++];
                memset(f, 0, sizeof *f);
                f->name = dup_s(rest);
            } else if (strcmp(k, "v") == 0 && info->nfns > 0) {
                const char *sp2 = strchr(rest, ' ');
                char *t = sp2 == NULL ? dup_s(rest) : dup_n(rest, (size_t)(sp2 - rest));
                const char *name = sp2 == NULL ? "?" : sp2 + 1;
                FnInfo *f = &info->fns[info->nfns - 1];
                if (f->nlocals == f->caplocals) {
                    f->caplocals = f->caplocals == 0 ? 8 : f->caplocals * 2;
                    f->locals = auk__xrealloc(f->locals, (size_t)f->caplocals * sizeof(Local));
                }
                f->locals[f->nlocals].name = dup_s(name);
                f->locals[f->nlocals].ty = to_u32(t);
                f->nlocals++;
                free(t);
            } else if (strcmp(k, "s") == 0) {
                /* func file line col vis,vis,... (split on single spaces) */
                char *fields[5] = {NULL, NULL, NULL, NULL, NULL};
                char *q = (char *)rest;
                for (int i = 0; i < 5 && q != NULL; i++) {
                    fields[i] = q;
                    char *s2 = strchr(q, ' ');
                    if (s2 != NULL) {
                        *s2 = 0;
                        q = s2 + 1;
                    } else {
                        q = NULL;
                    }
                }
                if (info->nsites == capsites) {
                    capsites = capsites == 0 ? 64 : capsites * 2;
                    info->sites = auk__xrealloc(info->sites, (size_t)capsites * sizeof(Site));
                }
                Site *s = &info->sites[info->nsites++];
                memset(s, 0, sizeof *s);
                s->func = fields[0] != NULL ? to_u32(fields[0]) : 0;
                s->file = fields[1] != NULL ? to_u32(fields[1]) : 0;
                s->line = fields[2] != NULL ? to_u32(fields[2]) : 0;
                s->col = fields[3] != NULL ? to_u32(fields[3]) : 0;
                if (fields[4] != NULL) {
                    size_t len = strlen(fields[4]);
                    s->vis = auk__xmalloc((len + 2) * sizeof(uint32_t));
                    char *v = fields[4];
                    while (v != NULL) {
                        char *comma = strchr(v, ',');
                        if (comma != NULL) {
                            *comma = 0;
                        }
                        int64_t x;
                        if (parse_i64(v, &x) && x >= 0 && x <= UINT32_MAX && v[0] != '+') {
                            s->vis[s->nvis++] = (uint32_t)x;
                        }
                        v = comma == NULL ? NULL : comma + 1;
                    }
                }
            }
        }
        free(line);
        if (e == NULL) {
            break;
        }
        p = e + 1;
    }
    info->bp = auk__xcalloc((size_t)info->nsites + 1, sizeof(_Atomic uint32_t));
    return info;
}

/* Start the debugger (generated main, before anything else runs): attach to the front end named
 * by AUK_DEBUG and wait for `run`. */
AUK_API void auk_dbg_init(const char *text, const AukShowFn *shows, const void *kids) {
    const char *path = getenv("AUK_DEBUG");
    if (path == NULL) {
        return;
    }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof addr.sun_path) {
        fprintf(stderr, "auk: debugger at %s: %s\n", path, strerror(ENAMETOOLONG));
        if (fd >= 0) {
            close(fd);
        }
        return;
    }
    memcpy(addr.sun_path, path, strlen(path) + 1);
    if (fd < 0 || connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) {
        int e = errno;
        fprintf(stderr, "auk: debugger at %s: %s\n", path, strerror(e));
        if (fd >= 0) {
            close(fd);
        }
        return;
    }
    auk__wire_no_sigpipe(fd);
    /* under a debugger, output shows up as it is written (it goes to a pipe) */
    setvbuf(stdout, NULL, _IOLBF, 0);
    dbg_info = parse_info(text, shows, kids);
    int rd = dup(fd);
    if (rd < 0) {
        close(fd);
        return;
    }
    pthread_mutex_lock(&dbg_out_lock);
    dbg_out_fd = fd;
    pthread_mutex_unlock(&dbg_out_lock);
    atomic_store(&dbg_attached, true);
    atexit(dbg_at_exit);
    tid();
    pthread_mutex_lock(&st_lock);
    rearm();
    pthread_mutex_unlock(&st_lock);
    pthread_t th;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_create(&th, &attr, dbg_reader, (void *)(intptr_t)rd);
    pthread_attr_destroy(&attr);
    DText ready = {0};
    dt_str(&ready, "{\"ev\":\"ready\",\"pid\":");
    dt_int(&ready, getpid());
    dt_str(&ready, "}");
    dbg_emit(ready.p);
    free(ready.p);
    pthread_mutex_lock(&st_lock);
    while (!st_running) {
        pthread_cond_wait(&st_cv, &st_lock);
    }
    pthread_mutex_unlock(&st_lock);
}

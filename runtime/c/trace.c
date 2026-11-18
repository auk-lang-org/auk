/* Execution traces (`auk run --trace`, `auk test --trace`): a JSON Lines log of every traced
 * function call and return, error, `peek` and panic.
 *
 * Only programs compiled with tracing call into this file (the compiler wraps each traced
 * function in an auk_trace_begin/auk_trace_call/auk_trace_exit/auk_trace_ret shim and makes main
 * call auk_trace_init); every other program only pays for the auk_trace_live test in auk_peek
 * and the panic path.
 *
 * Configuration (environment, read by auk_trace_init):
 *   AUK_TRACE=<file> | -    run: the event stream's file, `-` = stderr.
 *                           test: a directory (one `<test name>.jsonl` per test), or `-`: each
 *                           test keeps its last AUK_TRACE_TAIL events in memory and the runner
 *                           prints them under the test's FAIL line.
 *   AUK_TRACE_LIMIT=<n>     events written before a final {"ev":"truncated"} (default 10000).
 *   AUK_TRACE_TAIL=<n>      events kept for a failing test in `-` mode (default 20).
 *
 * Output is buffered here (not in a FILE) so a crash handler can still write it out with
 * write(2): a SIGSEGV from a stack overflow ends the trace with {"ev":"signal"}. The
 * process-wide state is guarded by trace_lock; the signal handler reads it without locking,
 * best effort. */
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "auk_rt.h"

/* Is tracing on? Read by generated code and by auk_peek and the panic path. */
AUK_API _Atomic bool auk_trace_live;

/* The call site of the next traced call: generated code stores it through
 * auk__trace_site_slot. */
static _Thread_local const char *trace_site;
static _Thread_local int64_t trace_depth;
/* > 0 while the tracer itself runs Auk code (a user `show`): nothing is traced */
static _Thread_local int trace_mute;
/* the call site of the call being traced (taken from trace_site by auk_trace_begin) */
static _Thread_local const char *trace_call_site;

/* The show budget of one traced value: enough for its first VALUE_MAX chars. */
enum { SHOW_BUDGET = 256, VALUE_MAX = 200 };

enum { T_OFF = 0, T_STREAM = 1, T_TAIL = 2 };

static int trace_mode = T_OFF;
static bool trace_configured;
static bool trace_test_binary;
static const char *trace_cfg;
static int64_t trace_limit = 10000;
static int64_t tail_n = 20;
static int64_t trace_count;
static pthread_mutex_t trace_lock = PTHREAD_MUTEX_INITIALIZER;

/* T_STREAM: buffered output to out_fd */
static int out_fd = -1;
static bool out_unbuffered;
enum { OBUF_SIZE = 1 << 16 };
static uint8_t obuf[OBUF_SIZE];
static size_t olen;

/* T_TAIL: a ring of the last tail_n events, dumped to out_fd on exit */
static uint8_t **ring;
static size_t *ring_len;
static size_t *ring_cap;

AUK_API const char **auk__trace_site_slot(void) {
    return &trace_site;
}

static bool trace_on(void) {
    return atomic_load_explicit(&auk_trace_live, memory_order_relaxed);
}

/* ---- line building ----------------------------------------------------------------------- */

typedef struct Line {
    uint8_t *p;
    size_t n;
    size_t cap;
} Line;

/* Each thread's event buffer: taken by new_line, given back by emit. */
static _Thread_local Line scratch;

static Line new_line(void) {
    Line l = scratch;
    scratch.p = NULL;
    scratch.cap = 0;
    l.n = 0;
    return l;
}

static void put(Line *l, const void *s, size_t n) {
    if (l->n + n > l->cap) {
        size_t cap = l->cap == 0 ? 256 : l->cap * 2;
        while (cap < l->n + n) {
            cap *= 2;
        }
        l->p = auk__xrealloc(l->p, cap);
        l->cap = cap;
    }
    memcpy(l->p + l->n, s, n);
    l->n += n;
}

static void puts_(Line *l, const char *s) {
    put(l, s, strlen(s));
}

/* Decimal text of v into b (24 bytes; no allocation: used by the signal handler); returns
 * where it starts, *n its length. */
static const char *fmt_i64(char *b, int64_t v, size_t *n) {
    int i = 24;
    uint64_t u = v < 0 ? (uint64_t)0 - (uint64_t)v : (uint64_t)v;
    do {
        b[--i] = (char)('0' + u % 10);
        u /= 10;
    } while (u != 0);
    if (v < 0) {
        b[--i] = '-';
    }
    *n = (size_t)(24 - i);
    return b + i;
}

static void put_int(Line *l, int64_t v) {
    char b[24];
    size_t n;
    const char *s = fmt_i64(b, v, &n);
    put(l, s, n);
}

/* A JSON string of s[0..n) (UTF-8), cut after max chars (0: no limit) with `...` (or always,
 * with cut). */
static void put_json(Line *l, const uint8_t *s, size_t n, size_t max, bool cut) {
    static const char hex[] = "0123456789abcdef";
    puts_(l, "\"");
    size_t chars = 0;
    for (size_t i = 0; i < n; i++) {
        uint8_t c = s[i];
        if ((c & 0xC0) != 0x80) {
            if (max != 0 && chars == max) {
                cut = true;
                break;
            }
            chars++;
        }
        switch (c) {
        case '"':
            puts_(l, "\\\"");
            break;
        case '\\':
            puts_(l, "\\\\");
            break;
        case '\n':
            puts_(l, "\\n");
            break;
        case '\r':
            puts_(l, "\\r");
            break;
        case '\t':
            puts_(l, "\\t");
            break;
        default:
            if (c < 0x20 || c == 0x7f) {
                char u[6] = {'\\', 'u', '0', '0', hex[c >> 4], hex[c & 15]};
                put(l, u, 6);
            } else {
                put(l, &c, 1);
            }
        }
    }
    if (cut) {
        puts_(l, "...");
    }
    puts_(l, "\"");
}

/* A JSON string of a C string (NULL: ""). */
static void put_cjson(Line *l, const char *s) {
    put_json(l, (const uint8_t *)(s == NULL ? "" : s), s == NULL ? 0 : strlen(s), 0, false);
}

static void put_value(Line *l, const AukStr *s) {
    int64_t n = auk_str_byte_len(s);
    /* a show that used up its budget was cut short even if it is under VALUE_MAX chars */
    put_json(l, (const uint8_t *)auk_str_cstr(s), (size_t)n, VALUE_MAX, n >= SHOW_BUDGET);
}

/* ---- output ------------------------------------------------------------------------------ */

static void write_all(int fd, const void *p, size_t n) {
    const uint8_t *b = p;
    while (n > 0) {
        ssize_t w = write(fd, b, n);
        if (w < 0 && errno == EINTR) {
            continue;
        }
        if (w <= 0) {
            return;
        }
        b += w;
        n -= (size_t)w;
    }
}

static void write_str(int fd, const char *s) {
    write_all(fd, s, strlen(s));
}

static void out_flush_locked(void) {
    if (out_fd >= 0 && olen != 0) {
        write_all(out_fd, obuf, olen);
    }
    olen = 0;
}

static void out_bytes_locked(const void *p, size_t n) {
    if (olen + n > OBUF_SIZE) {
        out_flush_locked();
    }
    if (n > OBUF_SIZE) {
        write_all(out_fd, p, n);
        return;
    }
    memcpy(obuf + olen, p, n);
    olen += n;
}

/* Record one event line (without its newline); last: the final event (a panic), recorded even
 * past the limit. */
static void emit_ev(Line l, bool last) {
    put(&l, "\n", 1);
    pthread_mutex_lock(&trace_lock);
    if (trace_mode == T_STREAM && last) {
        out_bytes_locked(l.p, l.n);
    } else if (trace_mode == T_STREAM && trace_on()) {
        out_bytes_locked(l.p, l.n);
        trace_count++;
        if (trace_count >= trace_limit) {
            Line t = {0};
            puts_(&t, "{\"ev\":\"truncated\",\"limit\":");
            put_int(&t, trace_limit);
            puts_(&t, "}\n");
            out_bytes_locked(t.p, t.n);
            free(t.p);
            atomic_store_explicit(&auk_trace_live, false, memory_order_relaxed);
        }
        if (out_unbuffered) {
            out_flush_locked();
        }
    } else if (trace_mode == T_TAIL) {
        int64_t k = trace_count % tail_n;
        if (ring_cap[k] < l.n) {
            ring[k] = auk__xrealloc(ring[k], l.n);
            ring_cap[k] = l.n;
        }
        memcpy(ring[k], l.p, l.n);
        ring_len[k] = l.n;
        trace_count++;
    }
    pthread_mutex_unlock(&trace_lock);
    /* the line's buffer is reused by this thread's next event */
    if (scratch.p == NULL) {
        scratch = l;
    } else {
        free(l.p);
    }
}

static void emit(Line l) {
    emit_ev(l, false);
}

static void head(Line *l, const char *ev) {
    puts_(l, "{\"ev\":\"");
    puts_(l, ev);
    puts_(l, "\"");
}

static void field(Line *l, const char *name) {
    puts_(l, ",\"");
    puts_(l, name);
    puts_(l, "\":");
}

static void end_depth(Line *l, int64_t d) {
    field(l, "depth");
    put_int(l, d);
    puts_(l, "}");
}

/* Write everything recorded so far (T_TAIL: the ring, oldest first). Async-signal-safe enough
 * for the crash handler: it only uses write(2) on memory that already exists. */
static void dump_locked(void) {
    if (trace_mode == T_STREAM) {
        out_flush_locked();
    } else if (trace_mode == T_TAIL && out_fd >= 0) {
        int64_t n = trace_count < tail_n ? trace_count : tail_n;
        if (trace_count > n) {
            char b[24];
            size_t k;
            const char *s = fmt_i64(b, trace_count - n, &k);
            write_str(out_fd, "{\"ev\":\"truncated\",\"skipped\":");
            write_all(out_fd, s, k);
            write_str(out_fd, "}\n");
        }
        for (int64_t i = trace_count - n; i < trace_count; i++) {
            int64_t k = i % tail_n;
            if (ring[k] != NULL) {
                write_all(out_fd, ring[k], ring_len[k]);
            }
        }
        trace_count = 0;
    }
}

/* ---- crash handler ----------------------------------------------------------------------- */

static void on_signal(int sig) {
    /* no lock: the crashing thread may hold it; this is best effort */
    dump_locked();
    if (out_fd >= 0) {
        char b[24];
        size_t k;
        const char *s = fmt_i64(b, sig, &k);
        write_str(out_fd, "{\"ev\":\"signal\",\"signal\":");
        write_all(out_fd, s, k);
        write_str(out_fd, "}\n");
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

static void install_handlers(void) {
    static bool done;
    if (done) {
        return;
    }
    done = true;
    stack_t ss;
    memset(&ss, 0, sizeof ss);
    ss.ss_size = 1 << 16;
    ss.ss_sp = malloc(ss.ss_size);
    if (ss.ss_sp != NULL) {
        sigaltstack(&ss, NULL);
    }
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_signal;
    sa.sa_flags = SA_ONSTACK | SA_RESETHAND;
    sigemptyset(&sa.sa_mask);
    int sigs[5] = {SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGABRT};
    for (int i = 0; i < 5; i++) {
        sigaction(sigs[i], &sa, NULL);
    }
}

/* ---- configuration ----------------------------------------------------------------------- */

static int64_t env_int(const char *name, int64_t dflt) {
    const char *v = getenv(name);
    if (v == NULL || v[0] == 0) {
        return dflt;
    }
    char *end = NULL;
    long long n = strtoll(v, &end, 10);
    return *end != 0 || n <= 0 ? dflt : n;
}

static void flush_at_exit(void) {
    auk__trace_flush();
}

static void start_stream(int fd, bool unbuffered) {
    static bool registered;
    if (!registered) {
        atexit(flush_at_exit);
    }
    registered = true;
    out_fd = fd;
    out_unbuffered = unbuffered;
    trace_mode = T_STREAM;
    trace_count = 0;
    atomic_store_explicit(&auk_trace_live, true, memory_order_relaxed);
    install_handlers();
}

static void cannot_write(const char *path) {
    int e = errno;
    fprintf(stderr, "auk: cannot write the trace to %s: %s\n", path, strerror(e));
}

AUK_API void auk_trace_init(bool tests) {
    trace_configured = true;
    trace_test_binary = tests;
    trace_cfg = getenv("AUK_TRACE");
    if (trace_cfg != NULL && trace_cfg[0] == 0) {
        trace_cfg = NULL;
    }
    trace_limit = env_int("AUK_TRACE_LIMIT", 10000);
    tail_n = env_int("AUK_TRACE_TAIL", 20);
    if (tests || trace_cfg == NULL) {
        return;
    }
    if (strcmp(trace_cfg, "-") == 0) {
        start_stream(2, true);
        return;
    }
    int fd = open(trace_cfg, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) {
        cannot_write(trace_cfg);
        return;
    }
    start_stream(fd, false);
}

bool auk__trace_tail_mode(void) {
    return trace_configured && trace_test_binary && trace_cfg != NULL && strcmp(trace_cfg, "-") == 0;
}

const char *auk__trace_dir(void) {
    if (trace_configured && trace_test_binary && trace_cfg != NULL && strcmp(trace_cfg, "-") != 0) {
        return trace_cfg;
    }
    return NULL;
}

/* The trace file of a test in directory mode: <dir>/<name with [^A-Za-z0-9_-] as _>.jsonl
 * (malloc'd). */
static char *test_file(const char *dir, const char *name) {
    size_t nd = strlen(dir);
    size_t nn = strlen(name);
    char *p = auk__xmalloc(nd + nn + 8);
    memcpy(p, dir, nd);
    p[nd] = '/';
    for (size_t i = 0; i < nn; i++) {
        char c = name[i];
        bool keep = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_';
        p[nd + 1 + i] = keep ? c : '_';
    }
    memcpy(p + nd + 1 + nn, ".jsonl", 7);
    return p;
}

void auk__trace_test_begin(const char *name, const char *tail_path) {
    if (!trace_configured || !trace_test_binary || trace_cfg == NULL) {
        return;
    }
    if (tail_path != NULL) {
        int fd = open(tail_path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
        if (fd < 0) {
            return;
        }
        out_fd = fd;
        ring = auk__xcalloc((size_t)tail_n, sizeof(uint8_t *));
        ring_len = auk__xcalloc((size_t)tail_n, sizeof(size_t));
        ring_cap = auk__xcalloc((size_t)tail_n, sizeof(size_t));
        trace_mode = T_TAIL;
        trace_count = 0;
        atomic_store_explicit(&auk_trace_live, true, memory_order_relaxed);
        install_handlers();
        return;
    }
    mkdir(trace_cfg, 0755);
    char *path = test_file(trace_cfg, name);
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) {
        cannot_write(path);
    }
    free(path);
    if (fd >= 0) {
        start_stream(fd, false);
    }
}

/* After the test's child exited: its outcome as the trace's last event. In directory mode it is
 * appended to the test's file; in tail mode the caller prints the file (when the test failed). */
void auk__trace_test_end(const char *name, bool ok, const char *tail_path) {
    char *path = tail_path == NULL ? test_file(trace_cfg, name) : NULL;
    int fd = open(path != NULL ? path : tail_path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0644);
    free(path);
    if (fd < 0) {
        return;
    }
    Line l = {0};
    head(&l, "test");
    field(&l, "name");
    put_cjson(&l, name);
    field(&l, "result");
    puts_(&l, ok ? "\"ok\"}\n" : "\"FAIL\"}\n");
    write_all(fd, l.p, l.n);
    free(l.p);
    close(fd);
}

void auk__trace_flush(void) {
    if (trace_mode == T_OFF) {
        return;
    }
    pthread_mutex_lock(&trace_lock);
    dump_locked();
    pthread_mutex_unlock(&trace_lock);
}

/* ---- events ------------------------------------------------------------------------------ */

AUK_API bool auk_trace_begin(void) {
    if (!trace_on() || trace_mute != 0) {
        return false;
    }
    trace_mute++;
    trace_call_site = trace_site;
    trace_site = NULL;
    auk__set_show_left(SHOW_BUDGET);
    return true;
}

AUK_API void auk_trace_call(const char *fn, const char *loc, int n, AukStr **args) {
    auk__set_show_left(-1);
    Line l = new_line();
    head(&l, "call");
    field(&l, "fn");
    put_cjson(&l, fn);
    field(&l, "loc");
    put_cjson(&l, trace_call_site == NULL ? loc : trace_call_site);
    field(&l, "args");
    puts_(&l, "[");
    for (int i = 0; i < n; i++) {
        if (i != 0) {
            puts_(&l, ",");
        }
        put_value(&l, args[i]);
        auk_release(args[i]);
    }
    puts_(&l, "]");
    end_depth(&l, trace_depth);
    emit(l);
    trace_depth++;
    trace_mute--;
}

AUK_API bool auk_trace_exit(void) {
    trace_depth--;
    if (!trace_on() || trace_mute != 0) {
        return false;
    }
    trace_mute++;
    auk__set_show_left(SHOW_BUDGET);
    return true;
}

AUK_API void auk_trace_ret(const char *fn, AukStr *shown) {
    auk__set_show_left(-1);
    Line l = new_line();
    head(&l, "ret");
    field(&l, "fn");
    put_cjson(&l, fn);
    field(&l, "value");
    if (shown != NULL) {
        put_value(&l, shown);
        auk_release(shown);
    } else {
        puts_(&l, "\"()\"");
    }
    end_depth(&l, trace_depth);
    emit(l);
    trace_mute--;
}

AUK_API void auk_trace_err(const char *fn, const AukErr *e) {
    AukStr *s = auk_err_show(e);
    auk__set_show_left(-1);
    Line l = new_line();
    head(&l, "err");
    field(&l, "fn");
    put_cjson(&l, fn);
    field(&l, "error");
    put_value(&l, s);
    auk_release(s);
    end_depth(&l, trace_depth);
    emit(l);
    trace_mute--;
}

void auk__trace_peek(const char *loc, const char *src_text, const AukStr *shown) {
    if (!trace_on() || trace_mute != 0) {
        return;
    }
    Line l = new_line();
    head(&l, "peek");
    field(&l, "loc");
    put_cjson(&l, loc);
    field(&l, "expr");
    put_cjson(&l, src_text);
    field(&l, "value");
    put_value(&l, shown);
    end_depth(&l, trace_depth);
    emit(l);
}

/* A panic: records it and writes out the trace (the process is about to _exit). caught: the
 * panic jumps to a recovery point (`catch`, a task thread) instead of ending the process; the
 * event gets "caught":true. The message ends at its first NUL. */
void auk__trace_on_panic(const char *loc, const char *msg, size_t n, bool caught) {
    if (trace_mode == T_OFF) {
        return;
    }
    const char *nul = memchr(msg, 0, n);
    if (nul != NULL) {
        n = (size_t)(nul - msg);
    }
    Line l = new_line();
    head(&l, "panic");
    field(&l, "msg");
    put_json(&l, (const uint8_t *)msg, n, 0, false);
    field(&l, "loc");
    if (loc == NULL) {
        puts_(&l, "\"<unknown>\"");
    } else {
        put_cjson(&l, loc);
    }
    if (caught) {
        puts_(&l, ",\"caught\":true");
    }
    end_depth(&l, trace_depth);
    emit_ev(l, true);
    auk__trace_flush();
}

/* This thread's call depth and mute count, saved at a recovery point (`catch`, a task) and put
 * back when a panic jumps past traced frames that never got to exit. */
void auk__trace_save(int64_t *depth, int *mute) {
    *depth = trace_depth;
    *mute = trace_mute;
}

void auk__trace_restore(int64_t depth, int mute) {
    trace_depth = depth;
    trace_mute = mute;
}

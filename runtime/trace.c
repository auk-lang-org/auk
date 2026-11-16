/* Execution traces (`duck run --trace`, `duck test --trace`): a JSON Lines log of every traced
 * function call and return, error, `peek` and panic.
 *
 * Only programs compiled with tracing call into this file (the compiler wraps each traced
 * function in a `duck_trace_begin`/`duck_trace_call`/`duck_trace_exit`/`duck_trace_ret` shim and
 * makes `main` call `duck_trace_init`); every other program only pays for the `duck_trace_live`
 * test in `duck_peek` and `duck_panic`.
 *
 * Configuration (environment, read by `duck_trace_init`):
 *   DUCK_TRACE=<file> | -    run: the event stream's file, `-` = stderr.
 *                            test: a directory (one `<test name>.jsonl` per test), or `-`:
 *                            each test keeps its last DUCK_TRACE_TAIL events in memory and the
 *                            runner prints them under the test's FAIL line.
 *   DUCK_TRACE_LIMIT=<n>     events written before a final {"ev":"truncated"} (default 10000).
 *   DUCK_TRACE_TAIL=<n>      events kept for a failing test in `-` mode (default 20).
 *
 * Output is buffered here (not in a FILE) so a crash handler can still write it out with
 * write(2): a SIGSEGV from a stack overflow ends the trace with {"ev":"signal"}. */
#include "duck_internal.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>

bool duck_trace_live;
_Thread_local const char *duck_trace_site;
_Thread_local int64_t duck__show_left = -1;

/* The show budget of one traced value: enough for its first VALUE_MAX chars. */
enum { SHOW_BUDGET = 256 };

static _Thread_local int64_t depth;
/* > 0 while the tracer itself runs Duck code (a user `show`): nothing is traced. */
static _Thread_local int mute;
/* The call site of the call being traced (taken from duck_trace_site by duck_trace_begin). */
static _Thread_local const char *site;

enum { T_OFF, T_STREAM, T_TAIL };
static int mode;
static bool configured, test_binary;
static const char *cfg;
static int64_t limit = 10000, tail_n = 20, count;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

/* T_STREAM: buffered output to fd */
static int out_fd = -1;
static bool out_unbuffered;
static char obuf[1 << 16];
static size_t olen;

/* T_TAIL: a ring of the last tail_n events, dumped to fd on exit */
static char **ring;
static size_t *ring_len, *ring_cap;

/* ---- a growable line buffer ---- */

typedef struct {
    char *p;
    size_t n, cap;
} Line;

/* Each thread's event buffer: taken by new_line, given back by emit. */
static _Thread_local Line scratch;
static Line new_line(void) {
    Line l = scratch;
    scratch = (Line){0};
    l.n = 0;
    return l;
}

static void put(Line *l, const char *s, size_t n) {
    if (l->n + n + 1 > l->cap) {
        size_t c = l->cap ? l->cap : 256;
        while (l->n + n + 1 > c) c *= 2;
        l->p = duck__xrealloc(l->p, c);
        l->cap = c;
    }
    memcpy(l->p + l->n, s, n);
    l->n += n;
    l->p[l->n] = 0;
}

static void puts_(Line *l, const char *s) { put(l, s, strlen(s)); }

static void put_int(Line *l, int64_t v) {
    char b[32];
    int n = snprintf(b, sizeof b, "%lld", (long long)v);
    put(l, b, (size_t)n);
}

/* A JSON string of s (n bytes of UTF-8), cut after `max` chars (0 = no limit) with `...`
 * (or always, with `cut`). */
static void put_json(Line *l, const char *s, size_t n, size_t max, bool cut) {
    put(l, "\"", 1);
    size_t chars = 0;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        if ((c & 0xC0) != 0x80) {
            if (max && chars == max) {
                cut = true;
                break;
            }
            chars++;
        }
        switch (c) {
        case '"': puts_(l, "\\\""); break;
        case '\\': puts_(l, "\\\\"); break;
        case '\n': puts_(l, "\\n"); break;
        case '\r': puts_(l, "\\r"); break;
        case '\t': puts_(l, "\\t"); break;
        default:
            if (c < 0x20 || c == 0x7f) {
                char b[8];
                snprintf(b, sizeof b, "\\u%04x", c);
                puts_(l, b);
            } else {
                put(l, (const char *)&s[i], 1);
            }
        }
    }
    if (cut) puts_(l, "...");
    put(l, "\"", 1);
}

static void put_cjson(Line *l, const char *s) { put_json(l, s ? s : "", s ? strlen(s) : 0, 0, false); }

/* A shown value: at most 200 chars. */
enum { VALUE_MAX = 200 };
static void put_value(Line *l, const DuckStr *s) {
    size_t n = s ? (size_t)s->len_bytes : 0;
    /* a show that used up its budget was cut short even if it is under VALUE_MAX chars */
    put_json(l, s ? s->data : "", n, VALUE_MAX, n >= SHOW_BUDGET);
}

/* ---- output ---- */

static void write_all(int fd, const char *p, size_t n) {
    while (n > 0) {
        ssize_t w = write(fd, p, n);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return;
        p += w;
        n -= (size_t)w;
    }
}

static void out_flush_locked(void) {
    if (out_fd >= 0 && olen) write_all(out_fd, obuf, olen);
    olen = 0;
}

static void out_bytes_locked(const char *p, size_t n) {
    if (olen + n > sizeof obuf) out_flush_locked();
    if (n > sizeof obuf) {
        write_all(out_fd, p, n);
        return;
    }
    memcpy(obuf + olen, p, n);
    olen += n;
}

/* Record one event line (without its newline); `last`: the final event (a panic), recorded
 * even past the limit. */
static void emit_ev(Line *l, bool last) {
    put(l, "\n", 1);
    pthread_mutex_lock(&lock);
    if (mode == T_STREAM && last) {
        out_bytes_locked(l->p, l->n);
    } else if (mode == T_STREAM && duck_trace_live) {
        out_bytes_locked(l->p, l->n);
        if (++count >= limit) {
            char b[80];
            int n = snprintf(b, sizeof b, "{\"ev\":\"truncated\",\"limit\":%lld}\n", (long long)limit);
            out_bytes_locked(b, (size_t)n);
            duck_trace_live = false;
        }
        if (out_unbuffered) out_flush_locked();
    } else if (mode == T_TAIL) {
        size_t k = (size_t)(count % tail_n);
        if (ring_cap[k] < l->n) {
            ring[k] = duck__xrealloc(ring[k], l->n);
            ring_cap[k] = l->n;
        }
        memcpy(ring[k], l->p, l->n);
        ring_len[k] = l->n;
        count++;
    }
    pthread_mutex_unlock(&lock);
    /* the line's buffer is reused by this thread's next event */
    l->n = 0;
    scratch = *l;
}

static void emit(Line *l) { emit_ev(l, false); }

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
    if (mode == T_STREAM) {
        out_flush_locked();
    } else if (mode == T_TAIL && out_fd >= 0) {
        int64_t n = count < tail_n ? count : tail_n;
        if (count > n) {
            char b[80];
            int m = snprintf(b, sizeof b, "{\"ev\":\"truncated\",\"skipped\":%lld}\n", (long long)(count - n));
            write_all(out_fd, b, (size_t)m);
        }
        for (int64_t i = count - n; i < count; i++) {
            size_t k = (size_t)(i % tail_n);
            if (ring[k]) write_all(out_fd, ring[k], ring_len[k]);
        }
        count = 0;
    }
}

/* ---- crash handler ---- */

static void on_signal(int sig) {
    /* no lock: the crashing thread may hold it; this is best effort */
    char b[64];
    int n = snprintf(b, sizeof b, "{\"ev\":\"signal\",\"signal\":%d}\n", sig);
    dump_locked();
    if (out_fd >= 0) write_all(out_fd, b, (size_t)n);
    signal(sig, SIG_DFL);
    raise(sig);
}

static void install_handlers(void) {
    static bool done;
    if (done) return;
    done = true;
    stack_t ss;
    ss.ss_size = 1 << 16;
    ss.ss_sp = malloc(ss.ss_size);
    ss.ss_flags = 0;
    if (ss.ss_sp) sigaltstack(&ss, NULL);
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_signal;
    sa.sa_flags = SA_ONSTACK | SA_RESETHAND;
    sigemptyset(&sa.sa_mask);
    int sigs[] = {SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGABRT};
    for (size_t i = 0; i < sizeof sigs / sizeof *sigs; i++) sigaction(sigs[i], &sa, NULL);
}

/* ---- configuration ---- */

static int64_t env_int(const char *name, int64_t dflt) {
    const char *v = getenv(name);
    if (!v || !*v) return dflt;
    char *end;
    long long n = strtoll(v, &end, 10);
    return (*end || n <= 0) ? dflt : (int64_t)n;
}

static void flush_at_exit(void) { duck__trace_flush(); }

static void start_stream(int fd, bool unbuffered) {
    static bool registered;
    if (!registered) atexit(flush_at_exit);
    registered = true;
    out_fd = fd;
    out_unbuffered = unbuffered;
    mode = T_STREAM;
    count = 0;
    duck_trace_live = true;
    install_handlers();
}

void duck_trace_init(bool tests) {
    configured = true;
    test_binary = tests;
    cfg = getenv("DUCK_TRACE");
    if (cfg && !*cfg) cfg = NULL;
    limit = env_int("DUCK_TRACE_LIMIT", 10000);
    tail_n = env_int("DUCK_TRACE_TAIL", 20);
    if (tests || !cfg) return;
    if (strcmp(cfg, "-") == 0) {
        start_stream(2, true);
        return;
    }
    int fd = open(cfg, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) {
        fprintf(stderr, "duck: cannot write the trace to %s: %s\n", cfg, strerror(errno));
        return;
    }
    start_stream(fd, false);
}

bool duck__trace_tail_mode(void) { return configured && test_binary && cfg && strcmp(cfg, "-") == 0; }

const char *duck__trace_dir(void) { return configured && test_binary && cfg && strcmp(cfg, "-") != 0 ? cfg : NULL; }

/* The trace file of a test in directory mode: <dir>/<name with [^A-Za-z0-9_-] as _>.jsonl */
static char *test_file(const char *dir, const char *name) {
    size_t n = strlen(name);
    size_t dn = strlen(dir);
    char *p = duck__xmalloc(dn + n + 8);
    memcpy(p, dir, dn);
    char *q = p + dn;
    *q++ = '/';
    for (size_t i = 0; i < n; i++) {
        char c = name[i];
        bool keep = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_';
        *q++ = keep ? c : '_';
    }
    strcpy(q, ".jsonl");
    return p;
}

void duck__trace_test_begin(const char *name, const char *tail_path) {
    if (!configured || !test_binary || !cfg) return;
    if (tail_path) {
        int fd = open(tail_path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
        if (fd < 0) return;
        out_fd = fd;
        ring = duck__xcalloc((size_t)tail_n, sizeof *ring);
        ring_len = duck__xcalloc((size_t)tail_n, sizeof *ring_len);
        ring_cap = duck__xcalloc((size_t)tail_n, sizeof *ring_cap);
        mode = T_TAIL;
        count = 0;
        duck_trace_live = true;
        install_handlers();
        return;
    }
    mkdir(cfg, 0755);
    char *path = test_file(cfg, name);
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) fprintf(stderr, "duck: cannot write the trace to %s: %s\n", path, strerror(errno));
    free(path);
    if (fd >= 0) start_stream(fd, false);
}

/* After the test's child exited: its outcome as the trace's last event. In directory mode it is
 * appended to the test's file; in tail mode the caller prints the file (when the test failed). */
void duck__trace_test_end(const char *name, bool ok, const char *tail_path) {
    char *path = tail_path ? NULL : test_file(cfg, name);
    int fd = open(tail_path ? tail_path : path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0644);
    free(path);
    if (fd < 0) return;
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

void duck__trace_flush(void) {
    if (mode == T_OFF) return;
    pthread_mutex_lock(&lock);
    dump_locked();
    pthread_mutex_unlock(&lock);
}

/* ---- events ---- */

bool duck_trace_begin(void) {
    if (!duck_trace_live || mute) return false;
    mute++;
    site = duck_trace_site;
    duck_trace_site = NULL;
    duck__show_left = SHOW_BUDGET;
    return true;
}

void duck_trace_call(const char *fn, const char *loc, int n, DuckStr **args) {
    duck__show_left = -1;
    Line l = new_line();
    head(&l, "call");
    field(&l, "fn");
    put_cjson(&l, fn);
    field(&l, "loc");
    put_cjson(&l, site ? site : loc);
    field(&l, "args");
    put(&l, "[", 1);
    for (int i = 0; i < n; i++) {
        if (i) put(&l, ",", 1);
        put_value(&l, args[i]);
        duck_release(args[i]);
    }
    put(&l, "]", 1);
    end_depth(&l, depth);
    emit(&l);
    depth++;
    mute--;
}

bool duck_trace_exit(void) {
    depth--;
    if (!duck_trace_live || mute) return false;
    mute++;
    duck__show_left = SHOW_BUDGET;
    return true;
}

void duck_trace_ret(const char *fn, DuckStr *shown) {
    duck__show_left = -1;
    Line l = new_line();
    head(&l, "ret");
    field(&l, "fn");
    put_cjson(&l, fn);
    field(&l, "value");
    if (shown) {
        put_value(&l, shown);
        duck_release(shown);
    } else {
        puts_(&l, "\"()\"");
    }
    end_depth(&l, depth);
    emit(&l);
    mute--;
}

void duck_trace_err(const char *fn, const DuckErr *e) {
    DuckStr *s = duck_err_show(e);
    duck__show_left = -1;
    Line l = new_line();
    head(&l, "err");
    field(&l, "fn");
    put_cjson(&l, fn);
    field(&l, "error");
    put_value(&l, s);
    duck_release(s);
    end_depth(&l, depth);
    emit(&l);
    mute--;
}

void duck__trace_peek(const char *loc, const char *src_text, const DuckStr *shown) {
    if (!duck_trace_live || mute) return;
    Line l = new_line();
    head(&l, "peek");
    field(&l, "loc");
    put_cjson(&l, loc);
    field(&l, "expr");
    put_cjson(&l, src_text);
    field(&l, "value");
    put_value(&l, shown);
    end_depth(&l, depth);
    emit(&l);
}

void duck__trace_panic(const char *loc, const char *msg) {
    if (mode == T_OFF) return;
    {
        Line l = new_line();
        head(&l, "panic");
        field(&l, "msg");
        put_cjson(&l, msg);
        field(&l, "loc");
        put_cjson(&l, loc ? loc : "<unknown>");
        end_depth(&l, depth);
        emit_ev(&l, true);
    }
    duck__trace_flush();
}

/* Core library: print, fs, net, time, rand, env (with stdin), proc. */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <pthread.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#if defined(__linux__)
#include <sys/random.h>
#endif

#include "auk_rt.h"

extern char **environ;

/* ---- small helpers ----------------------------------------------------------------------- */

/* An Err with the builder's text (consumed) and code. */
static AukErr *err_code_sb(AukStrBuf *b, int code) {
    AukErr *e = auk__err_sb(b);
    e->code = code;
    return e;
}

static AukRes_unit unit_ok(void) {
    AukRes_unit r = {0};
    r.ok = true;
    return r;
}

static AukRes_unit unit_err(AukErr *e) {
    AukRes_unit r = {0};
    r.err = e;
    return r;
}

static AukRes_str str_err(AukErr *e) {
    AukRes_str r = {0};
    r.err = e;
    return r;
}

static AukRes_arr arr_ok(AukArr *a) {
    AukRes_arr r = {0};
    r.ok = true;
    r.val = a;
    return r;
}

static AukRes_arr arr_err(AukErr *e) {
    AukRes_arr r = {0};
    r.err = e;
    return r;
}

/* An [int] as bytes (malloc'd, *n of them), or NULL with the first index and value outside
 * 0..255 in *bad_i and *bad_x. */
static uint8_t *arr_to_bytes(const AukArr *a, int64_t *n, int64_t *bad_i, int64_t *bad_x) {
    int64_t len = auk_arr_len(a);
    const int64_t *xs = len > 0 ? (const int64_t *)a->data : NULL;
    uint8_t *buf = auk__xmalloc((size_t)len + 1);
    for (int64_t i = 0; i < len; i++) {
        if (xs[i] < 0 || xs[i] > 255) {
            free(buf);
            *bad_i = i;
            *bad_x = xs[i];
            return NULL;
        }
        buf[i] = (uint8_t)xs[i];
    }
    *n = len;
    return buf;
}

/* A growable byte buffer. */
typedef struct Bytes {
    uint8_t *p;
    int64_t n;
    int64_t cap;
} Bytes;

static void bytes_add(Bytes *b, const uint8_t *p, int64_t n) {
    if (b->n + n > b->cap) {
        int64_t cap = b->cap == 0 ? 65536 : b->cap;
        while (cap < b->n + n) {
            cap *= 2;
        }
        b->p = auk__xrealloc(b->p, (size_t)cap);
        b->cap = cap;
    }
    memcpy(b->p + b->n, p, (size_t)n);
    b->n += n;
}

/* Read all of f into b; returns 0 or an errno. */
static int slurp(FILE *f, Bytes *b) {
    uint8_t *buf = auk__xmalloc(65536);
    for (;;) {
        size_t n = fread(buf, 1, 65536, f);
        if (n == 0) {
            break;
        }
        bytes_add(b, buf, (int64_t)n);
    }
    free(buf);
    if (ferror(f)) {
        return errno != 0 ? errno : EIO;
    }
    return 0;
}

/* ---- print ------------------------------------------------------------------------------- */

static void write_line(FILE *f, const void *p, size_t n) {
    flockfile(f);
    fwrite(p, 1, n, f);
    fputc('\n', f);
    funlockfile(f);
}

AUK_API void auk_print(const AukStr *s) {
    write_line(stdout, auk_str_cstr(s), (size_t)auk_str_byte_len(s));
}

AUK_API void auk_print_lit(const char *cstr) {
    write_line(stdout, cstr == NULL ? "" : cstr, cstr == NULL ? 0 : strlen(cstr));
}

AUK_API void auk_eprint(const AukStr *s) {
    fflush(stdout);
    write_line(stderr, auk_str_cstr(s), (size_t)auk_str_byte_len(s));
}

/* fs: runtime/src/core_fs.auk; auk__bytes_to_arr: core_util.auk */

/* ---- net --------------------------------------------------------------------------------- */

/* Flags for send(2) on a connected socket: no SIGPIPE where the platform has MSG_NOSIGNAL;
 * elsewhere the socket carries SO_NOSIGPIPE. */
#if defined(MSG_NOSIGNAL)
const int auk__send_flags = MSG_NOSIGNAL;
#else
const int auk__send_flags = 0;
#endif

static bool conn_open(const AukConn *c) {
    return c != NULL && (c->fd >= 0 || c->tls != NULL);
}

/* Socket options every connected socket gets. */
static void conn_sockopts(int fd) {
#if defined(SO_NOSIGPIPE)
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
    auk__c_fcntl(fd, F_SETFD, FD_CLOEXEC);
}

/* Resolve host:port and connect a TCP socket (with the connected-socket options set): the fd,
 * or -1 with the reason in *why (static text) and an errno in *err (0 for a DNS failure). */
int auk__tcp_connect(const char *host, const char *port, const char **why, int *err) {
    struct addrinfo hints;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo *res = NULL;
    int gai = getaddrinfo(host, port, &hints, &res);
    if (gai != 0) {
        *why = gai_strerror(gai);
        *err = 0;
        return -1;
    }
    int fd = -1;
    int e = 0;
    for (struct addrinfo *ai = res; ai != NULL; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) {
            e = errno;
            continue;
        }
        int rc;
        do {
            rc = connect(fd, ai->ai_addr, ai->ai_addrlen);
        } while (rc < 0 && errno == EINTR);
        if (rc == 0) {
            break;
        }
        e = errno;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0) {
        *why = strerror(e);
        *err = e;
        return -1;
    }
    conn_sockopts(fd);
    return fd;
}

/* A new open AukConn over fd. */
AukConn *auk__conn_new(int fd) {
    AukConn *c = auk__alloc(sizeof(AukConn), AUK_K_CONN);
    c->fd = fd;
    return c;
}

static AukRes_conn conn_err(AukErr *e) {
    AukRes_conn r = {0};
    r.err = e;
    return r;
}

/* "<what> <host>:<port>: " into m. */
static void host_port(AukStrBuf *m, const char *what, const AukStr *host, int64_t port) {
    auk__sb_put_cstr(m, what);
    auk__sb_put_cstr(m, " ");
    auk__sb_put_cstr(m, auk_str_cstr(host));
    auk__sb_put_cstr(m, ":");
    auk_sb_int(m, port);
    auk__sb_put_cstr(m, ": ");
}

AUK_API AukRes_conn auk_net_tcp(const AukStr *host, int64_t port) {
    AukStrBuf m = {0};
    host_port(&m, "net.tcp", host, port);
    if (port < 0 || port > 65535) {
        auk__sb_put_cstr(&m, "invalid port");
        return conn_err(auk__err_sb(&m));
    }
    char ports[24];
    auk__fmt_i64(ports, port);
    const char *why;
    int code;
    int fd = auk__tcp_connect(auk_str_cstr(host), ports, &why, &code);
    if (fd < 0) {
        auk__sb_put_cstr(&m, why);
        return conn_err(code != 0 ? err_code_sb(&m, code) : auk__err_sb(&m));
    }
    auk_sb_free(&m);
    AukRes_conn r = {0};
    r.ok = true;
    r.val = auk__conn_new(fd);
    return r;
}

void auk__listener_free(AukListener *l) {
    auk_listener_close(l);
    auk__free_obj(l);
}

static AukRes_listener listener_err(AukErr *e) {
    AukRes_listener r = {0};
    r.err = e;
    return r;
}

AUK_API AukRes_listener auk_net_listen(const AukStr *host, int64_t port) {
    const char *h = auk_str_cstr(host);
    AukStrBuf m = {0};
    host_port(&m, "net.listen", host, port);
    if (port < 0 || port > 65535) {
        auk__sb_put_cstr(&m, "invalid port");
        return listener_err(auk__err_sb(&m));
    }
    char ports[24];
    auk__fmt_i64(ports, port);
    struct addrinfo hints;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_PASSIVE;
    struct addrinfo *res = NULL;
    int gai = getaddrinfo(h[0] != 0 ? h : NULL, ports, &hints, &res);
    if (gai != 0) {
        auk__sb_put_cstr(&m, gai_strerror(gai));
        return listener_err(auk__err_sb(&m));
    }
    int fd = -1;
    int err = 0;
    for (struct addrinfo *ai = res; ai != NULL; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) {
            err = errno;
            continue;
        }
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        if (bind(fd, ai->ai_addr, ai->ai_addrlen) == 0 && listen(fd, 128) == 0) {
            break;
        }
        err = errno;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0) {
        auk__sb_put_cstr(&m, strerror(err));
        return listener_err(err_code_sb(&m, err));
    }
    auk_sb_free(&m);
    auk__c_fcntl(fd, F_SETFD, FD_CLOEXEC);
    struct sockaddr_storage ss;
    socklen_t len = sizeof ss;
    int64_t bound = port;
    if (getsockname(fd, (struct sockaddr *)&ss, &len) == 0) {
        if (ss.ss_family == AF_INET) {
            bound = ntohs(((struct sockaddr_in *)&ss)->sin_port);
        } else if (ss.ss_family == AF_INET6) {
            bound = ntohs(((struct sockaddr_in6 *)&ss)->sin6_port);
        }
    }
    AukListener *l = auk__alloc(sizeof(AukListener), AUK_K_LISTENER);
    l->fd = fd;
    l->port = bound;
    AukRes_listener r = {0};
    r.ok = true;
    r.val = l;
    return r;
}

AUK_API AukRes_conn auk_listener_accept(AukListener *l) {
    if (l == NULL || l->fd < 0) {
        return conn_err(auk_err_new_cstr("net accept: listener is closed"));
    }
    int fd;
    do {
        auk__wait_fd(l->fd, false);
        fd = accept(l->fd, NULL, NULL);
    } while (fd < 0 && (errno == EINTR || errno == ECONNABORTED));
    if (fd < 0) {
        return conn_err(auk__err_errno("net accept", NULL, errno));
    }
    conn_sockopts(fd);
    AukRes_conn r = {0};
    r.ok = true;
    r.val = auk__conn_new(fd);
    return r;
}

AUK_API int64_t auk_listener_port(const AukListener *l) {
    return l == NULL ? 0 : l->port;
}

AUK_API void auk_listener_close(AukListener *l) {
    if (l != NULL && l->fd >= 0) {
        close(l->fd);
        l->fd = -1;
    }
}

AUK_API AukRes_arr auk_conn_read(AukConn *c, int64_t max) {
    if (!conn_open(c)) {
        return arr_err(auk_err_new_cstr("net read: connection is closed"));
    }
    if (max <= 0) {
        return arr_err(auk_err_new_cstr("net read: max must be positive"));
    }
    if (max > (1 << 24)) {
        max = 1 << 24;
    }
    if (c->tls != NULL) {
        return auk__tls_read(c->tls, max);
    }
    uint8_t *buf = auk__xmalloc((size_t)max);
    ssize_t n;
    do {
        auk__wait_fd(c->fd, false);
        n = recv(c->fd, buf, (size_t)max, 0);
    } while (n < 0 && errno == EINTR);
    if (n < 0) {
        int err = errno;
        free(buf);
        return arr_err(auk__err_errno("net read", NULL, err));
    }
    AukArr *a = auk__bytes_to_arr(buf, n);
    free(buf);
    return arr_ok(a);
}

AUK_API AukRes_unit auk_conn_write(AukConn *c, const AukArr *bytes) {
    if (!conn_open(c)) {
        return unit_err(auk_err_new_cstr("net write: connection is closed"));
    }
    int64_t n;
    int64_t bad_i;
    int64_t bad_x;
    uint8_t *buf = arr_to_bytes(bytes, &n, &bad_i, &bad_x);
    if (buf == NULL) {
        AukStrBuf m = {0};
        auk__sb_put_cstr(&m, "net write: byte ");
        auk_sb_int(&m, bad_x);
        auk__sb_put_cstr(&m, " out of range 0..255");
        return unit_err(auk__err_sb(&m));
    }
    if (c->tls != NULL) {
        AukRes_unit r = auk__tls_write(c->tls, buf, n);
        free(buf);
        return r;
    }
    int64_t off = 0;
    while (off < n) {
        auk__wait_fd(c->fd, true);
        ssize_t w = send(c->fd, buf + off, (size_t)(n - off), auk__send_flags);
        if (w < 0) {
            int err = errno;
            if (err == EINTR) {
                continue;
            }
            free(buf);
            return unit_err(auk__err_errno("net write", NULL, err));
        }
        off += w;
    }
    free(buf);
    return unit_ok();
}

AUK_API void auk_conn_close(AukConn *c) {
    if (c != NULL && c->tls != NULL) {
        auk__tls_free(c->tls); /* before the socket closes: it may send close_notify */
        c->tls = NULL;
    }
    if (c != NULL && c->fd >= 0) {
        close(c->fd);
        c->fd = -1;
    }
}

void auk__conn_free(AukConn *c) {
    auk_conn_close(c);
    auk__free_obj(c);
}

/* ---- time -------------------------------------------------------------------------------- */

AUK_API int64_t auk_time_now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

AUK_API void auk_time_sleep(int64_t ms) {
    if (ms > 0) {
        auk__sleep_ms(ms);
    }
}

/* ---- rand (xoshiro256**, seeded from the OS CSPRNG) -------------------------------------- */

/* Fill buf from the OS CSPRNG; false if none is available. */
static bool os_random(uint8_t *buf, size_t n) {
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
    if (n > 0) {
        arc4random_buf(buf, n);
    }
    return true;
#else
    size_t p = 0;
#if defined(__linux__)
    while (p < n) {
        ssize_t r = getrandom(buf + p, n - p, 0);
        if (r < 0) {
            if (errno == EINTR) {
                continue;
            }
            break; /* ENOSYS (old kernel): fall back to /dev/urandom */
        }
        p += (size_t)r;
    }
    if (p == n) {
        return true;
    }
#endif
    int fd = auk__c_open("/dev/urandom", O_RDONLY | O_CLOEXEC, 0);
    if (fd < 0) {
        return false;
    }
    while (p < n) {
        ssize_t r = read(fd, buf + p, n - p);
        if (r < 0 && errno == EINTR) {
            continue;
        }
        if (r <= 0) {
            break;
        }
        p += (size_t)r;
    }
    close(fd);
    return p == n;
#endif
}

static pthread_mutex_t rand_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t rand_s[4];
static bool rand_seeded;

static uint64_t rotl(uint64_t x, int k) {
    return (x << k) | (x >> (64 - k));
}

static uint64_t rand_next(void) {
    pthread_mutex_lock(&rand_lock);
    if (!rand_seeded) {
        uint8_t b[32];
        if (os_random(b, sizeof b)) {
            memcpy(rand_s, b, sizeof b);
        } else {
            uint64_t t = (uint64_t)auk_time_now() ^ ((uint64_t)getpid() << 32);
            for (int i = 0; i < 4; i++) {
                rand_s[i] = auk_hash_int((int64_t)(t + (uint64_t)i));
            }
        }
        if ((rand_s[0] | rand_s[1] | rand_s[2] | rand_s[3]) == 0) {
            rand_s[0] = 1;
        }
        rand_seeded = true;
    }
    uint64_t *s = rand_s;
    uint64_t r = rotl(s[1] * 5, 7) * 9;
    uint64_t t = s[1] << 17;
    s[2] ^= s[0];
    s[3] ^= s[1];
    s[1] ^= s[2];
    s[0] ^= s[3];
    s[2] ^= t;
    s[3] = rotl(s[3], 45);
    pthread_mutex_unlock(&rand_lock);
    return r;
}

AUK_API int64_t auk_rand_int(int64_t lo, int64_t hi) {
    if (lo > hi) {
        AukStrBuf m = {0};
        auk__sb_put_cstr(&m, "rand.int(");
        auk_sb_int(&m, lo);
        auk__sb_put_cstr(&m, ", ");
        auk_sb_int(&m, hi);
        auk__sb_put_cstr(&m, "): lo > hi");
        auk__panic_sb("rand.int", &m);
    }
    uint64_t span = (uint64_t)hi - (uint64_t)lo + 1; /* 0 means the full 2^64 range */
    if (span == 0) {
        return (int64_t)rand_next();
    }
    uint64_t limit = UINT64_MAX - UINT64_MAX % span;
    uint64_t x;
    do {
        x = rand_next();
    } while (x >= limit);
    return (int64_t)((uint64_t)lo + x % span);
}

AUK_API double auk_rand_float(void) {
    return (double)(rand_next() >> 11) * (1.0 / 9007199254740992.0); /* 0x1.0p-53 */
}

AUK_API void auk_rand_seed(int64_t seed) {
    uint64_t x = (uint64_t)seed;
    pthread_mutex_lock(&rand_lock);
    for (int i = 0; i < 4; i++) {
        /* splitmix64 */
        x += 0x9E3779B97F4A7C15ULL;
        uint64_t z = x;
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
        rand_s[i] = z ^ (z >> 31);
    }
    if ((rand_s[0] | rand_s[1] | rand_s[2] | rand_s[3]) == 0) {
        rand_s[0] = 1;
    }
    rand_seeded = true;
    pthread_mutex_unlock(&rand_lock);
}

AUK_API AukArr *auk_rand_bytes(int64_t n, const char *loc) {
    if (n < 0) {
        AukStrBuf m = {0};
        auk__sb_put_cstr(&m, "rand.bytes(");
        auk_sb_int(&m, n);
        auk__sb_put_cstr(&m, "): negative count");
        auk__panic_sb(loc, &m);
    }
    uint8_t *buf = auk__xmalloc((size_t)n + 1);
    if (!os_random(buf, (size_t)n)) {
        auk__panic3(loc, "rand.bytes: no OS random source available", NULL, NULL);
    }
    AukArr *a = auk__bytes_to_arr(buf, n);
    free(buf);
    return a;
}

/* ---- env --------------------------------------------------------------------------------- */

static pthread_mutex_t args_lock = PTHREAD_MUTEX_INITIALIZER;
static AukArr *args;

AUK_API AukOpt_str auk_env_get(const AukStr *key) {
    AukOpt_str r = {0};
    const char *v = getenv(auk_str_cstr(key));
    if (v == NULL) {
        return r;
    }
    r.some = true;
    r.val = auk_str_lit(v);
    return r;
}

AUK_API void auk_env_set_args(int argc, char **argv) {
    AukArr *a = auk_arr_new(&auk_ops_str, argc);
    for (int i = 0; i < argc; i++) {
        AukStr *s = auk_str_lit(argv[i]);
        auk_arr_push(&a, &s);
        auk_release(s);
        auk__make_immortal(s);
    }
    auk__make_immortal(a);
    /* a previous array is immortal and simply abandoned */
    pthread_mutex_lock(&args_lock);
    args = a;
    pthread_mutex_unlock(&args_lock);
}

AUK_API AukArr *auk_env_args(void) {
    pthread_mutex_lock(&args_lock);
    if (args == NULL) {
        args = auk_arr_new(&auk_ops_str, 0);
        auk__make_immortal(args);
    }
    AukArr *a = args;
    pthread_mutex_unlock(&args_lock);
    return a;
}

/* Whether file descriptor fd (0 stdin, 1 stdout, 2 stderr) is a terminal. */
AUK_API bool auk_env_is_terminal(int64_t fd) {
    return fd >= 0 && fd <= 2 && isatty((int)fd) == 1;
}

/* The terminal's width in columns: from stdout, stderr or stdin (the first that is a terminal),
 * else $COLUMNS, else none. */
AUK_API AukOpt_int auk_env_columns(void) {
    AukOpt_int r = {0};
    int fds[3] = {1, 2, 0};
    for (int i = 0; i < 3; i++) {
        struct winsize ws;
        if (auk__c_ioctl_ptr(fds[i], TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0) {
            r.some = true;
            r.val = ws.ws_col;
            return r;
        }
    }
    const char *v = getenv("COLUMNS");
    if (v != NULL) {
        /* a whole number, surrounding whitespace allowed */
        while (*v == ' ' || (*v >= '\t' && *v <= '\r')) {
            v++;
        }
        char *end = NULL;
        errno = 0;
        long long n = strtoll(v, &end, 10);
        if (end != v && errno == 0) {
            while (*end == ' ' || (*end >= '\t' && *end <= '\r')) {
                end++;
            }
            if (*end == 0 && n > 0) {
                r.some = true;
                r.val = n;
            }
        }
    }
    return r;
}

/* stdin: read through stdio (one buffer shared by read_line, read_all and lines). Stdout is
 * flushed first, so a prompt printed without a newline-terminated flush still shows. */

AUK_API AukOpt_str auk_env_read_line(void) {
    AukOpt_str r = {0};
    fflush(stdout);
    char *line = NULL;
    size_t cap = 0;
    ssize_t n = getline(&line, &cap, stdin);
    if (n < 0) {
        free(line);
        return r;
    }
    if (n > 0 && line[n - 1] == '\n') {
        n--;
    }
    if (n > 0 && line[n - 1] == '\r') {
        n--;
    }
    r.some = true;
    r.val = auk_str_from_bytes(line, n); /* invalid UTF-8 becomes U+FFFD */
    free(line);
    return r;
}

AUK_API AukRes_str auk_env_read_all(void) {
    fflush(stdout);
    Bytes b = {0};
    int err = slurp(stdin, &b);
    if (err != 0) {
        free(b.p);
        clearerr(stdin);
        return str_err(auk__err_errno("env.read_all: stdin", NULL, err));
    }
    AukRes_str r = auk_str_try_from_bytes((const char *)b.p, b.n);
    free(b.p);
    if (!r.ok) {
        AukErr *e = auk_err_new_cstr("env.read_all: stdin");
        e->cause = r.err; /* moves the reference */
        r.err = e;
    }
    return r;
}

AUK_API AukArr *auk_env_lines(void) {
    fflush(stdout);
    Bytes b = {0};
    if (slurp(stdin, &b) != 0) {
        clearerr(stdin); /* keep what was read before the error */
    }
    AukStr *s = auk_str_from_bytes((const char *)b.p, b.n);
    free(b.p);
    AukArr *a = auk_str_lines(s);
    auk_release(s);
    return a;
}

/* ---- proc -------------------------------------------------------------------------------- */

AUK_API AukRes_str auk_proc_run(const AukStr *cmd, const AukArr *args_in) {
    int64_t n = auk_arr_len(args_in);
    char **argv = auk__xmalloc((size_t)(n + 2) * sizeof(char *));
    argv[0] = (char *)auk_str_cstr(cmd);
    for (int64_t i = 0; i < n; i++) {
        argv[i + 1] = (char *)auk_str_cstr(((AukStr *const *)args_in->data)[i]);
    }
    argv[n + 1] = NULL;
    int fds[2];
    if (pipe(fds) < 0) {
        free(argv);
        return str_err(auk__err_errno("proc.run", cmd, errno));
    }
    auk__c_fcntl(fds[0], F_SETFD, FD_CLOEXEC);
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, fds[1], 1);
    posix_spawn_file_actions_addclose(&fa, fds[1]);
    pid_t pid = 0;
    fflush(stdout);
    int rc = posix_spawnp(&pid, auk_str_cstr(cmd), &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    free(argv);
    close(fds[1]);
    if (rc != 0) {
        close(fds[0]);
        return str_err(auk__err_errno("proc.run", cmd, rc));
    }
    Bytes b = {0};
    uint8_t *buf = auk__xmalloc(65536);
    for (;;) {
        auk__wait_fd(fds[0], false);
        ssize_t r = read(fds[0], buf, 65536);
        if (r < 0 && errno == EINTR) {
            continue;
        }
        if (r <= 0) {
            break;
        }
        bytes_add(&b, buf, r);
    }
    free(buf);
    close(fds[0]);
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) {
            status = -1;
            break;
        }
    }
    AukStr *out = auk_str_from_bytes((const char *)b.p, b.n);
    free(b.p);
    if (status == -1 || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        AukStrBuf m = {0};
        auk__sb_put_cstr(&m, "proc.run ");
        auk__sb_put_cstr(&m, auk_str_cstr(cmd));
        AukErr *e;
        if (status != -1 && WIFEXITED(status)) {
            int st = WEXITSTATUS(status);
            auk__sb_put_cstr(&m, ": exited with status ");
            auk_sb_int(&m, st);
            e = err_code_sb(&m, st);
        } else if (status != -1 && WIFSIGNALED(status)) {
            int sig = WTERMSIG(status);
            auk__sb_put_cstr(&m, ": killed by signal ");
            auk_sb_int(&m, sig);
            e = err_code_sb(&m, 128 + sig);
        } else {
            auk__sb_put_cstr(&m, ": could not wait for the process");
            e = auk__err_sb(&m);
        }
        auk_release(out);
        return str_err(e);
    }
    AukRes_str r = {0};
    r.ok = true;
    r.val = out;
    return r;
}

AUK_API _Noreturn void auk_proc_exit(int64_t code, const char *loc) {
    if (code < 0 || code > 255) {
        AukStrBuf m = {0};
        auk__sb_put_cstr(&m, "proc.exit(");
        auk_sb_int(&m, code);
        auk__sb_put_cstr(&m, "): code out of range 0..255");
        auk__panic_sb(loc, &m);
    }
    fflush(stdout);
    fflush(stderr);
    auk__trace_flush();
    if (auk_leak_check() != 0) {
        _exit(102);
    }
    /* _exit, like a panic: async tasks may still be running on other threads */
    _exit((int)code);
}

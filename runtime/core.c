/* Core library: print, fs, net, time, rand, env (with stdin), proc. */
#include "duck_internal.h"

#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#if defined(__linux__)
#include <sys/random.h>
#endif

extern char **environ;

/* ---- print ------------------------------------------------------------ */

static void write_line(FILE *f, const char *p, int64_t n) {
    flockfile(f);
    fwrite(p, 1, (size_t)n, f);
    putc_unlocked('\n', f);
    funlockfile(f);
}

void duck_print(const DuckStr *s) { write_line(stdout, duck_str_cstr(s), duck_str_byte_len(s)); }
void duck_print_lit(const char *cstr) { write_line(stdout, cstr, (int64_t)strlen(cstr)); }
void duck_eprint(const DuckStr *s) {
    fflush(stdout);
    write_line(stderr, duck_str_cstr(s), duck_str_byte_len(s));
}

/* ---- fs ----------------------------------------------------------------- */

DuckRes_str duck_fs_read(const DuckStr *path) {
    FILE *f = fopen(duck_str_cstr(path), "rb");
    if (!f) return DUCK_ERR(DuckRes_str, duck__err_errno("fs.read", path, errno));
    DuckStrBuf b = DUCK_SB_INIT;
    char buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) duck_sb_bytes(&b, buf, (int64_t)n);
    int err = ferror(f) ? errno : 0;
    fclose(f);
    if (err) {
        duck_sb_free(&b);
        return DUCK_ERR(DuckRes_str, duck__err_errno("fs.read", path, err));
    }
    DuckRes_str r = duck_str_try_from_bytes(b.buf ? b.buf : "", b.len);
    duck_sb_free(&b);
    if (!r.ok) { /* "fs.read <path>: invalid UTF-8 at byte N" */
        DuckErr *e = duck_err_fmt("fs.read %s", duck_str_cstr(path));
        e->cause = r.err; /* moves the reference */
        r.err = e;
    }
    return r;
}

DuckRes_unit duck_fs_write(const DuckStr *path, const DuckStr *content) {
    FILE *f = fopen(duck_str_cstr(path), "wb");
    if (!f) return DUCK_ERR(DuckRes_unit, duck__err_errno("fs.write", path, errno));
    size_t n = (size_t)duck_str_byte_len(content);
    int err = 0;
    if (fwrite(duck_str_cstr(content), 1, n, f) != n) err = errno ? errno : EIO;
    if (fclose(f) != 0 && !err) err = errno;
    if (err) return DUCK_ERR(DuckRes_unit, duck__err_errno("fs.write", path, err));
    return DUCK_OK(DuckRes_unit, DUCK_UNIT);
}

DuckRes_arr duck_fs_lines(const DuckStr *path) {
    DuckRes_str r = duck_fs_read(path);
    if (!r.ok) return DUCK_ERR(DuckRes_arr, r.err);
    DuckArr *lines = duck_str_lines(r.val);
    duck_release(r.val);
    return DUCK_OK(DuckRes_arr, lines);
}

static bool stat_is(const DuckStr *path, bool want_dir) {
    struct stat st;
    if (stat(duck_str_cstr(path), &st) != 0) return false;
    return !want_dir || S_ISDIR(st.st_mode);
}

bool duck_fs_exists(const DuckStr *path) { return stat_is(path, false); }
bool duck_fs_is_dir(const DuckStr *path) { return stat_is(path, true); }

static int cmp_cstr(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }

DuckRes_arr duck_fs_list(const DuckStr *dir) {
    DIR *d = opendir(duck_str_cstr(dir));
    if (!d) return DUCK_ERR(DuckRes_arr, duck__err_errno("fs.list", dir, errno));
    char **names = NULL;
    size_t n = 0, cap = 0;
    struct dirent *ent;
    errno = 0;
    while ((ent = readdir(d)) != NULL) {
        const char *nm = ent->d_name;
        if (strcmp(nm, ".") == 0 || strcmp(nm, "..") == 0) continue;
        if (n == cap) {
            cap = cap ? cap * 2 : 16;
            names = duck__xrealloc(names, cap * sizeof *names);
        }
        size_t len = strlen(nm);
        names[n] = duck__xmalloc(len + 1);
        memcpy(names[n++], nm, len + 1);
    }
    int err = errno;
    closedir(d);
    DuckArr *a = NULL;
    if (!err) {
        if (n) qsort(names, n, sizeof *names, cmp_cstr);
        a = duck_arr_new(&duck_ops_str, (int64_t)n);
        for (size_t i = 0; i < n; i++) {
            DuckStr *s = duck_str_lit(names[i]);
            duck_arr_push(&a, &s);
            duck_release(s);
        }
    }
    for (size_t i = 0; i < n; i++) free(names[i]);
    free(names);
    if (err) return DUCK_ERR(DuckRes_arr, duck__err_errno("fs.list", dir, err));
    return DUCK_OK(DuckRes_arr, a);
}

DuckRes_unit duck_fs_mkdir(const DuckStr *path) {
    const char *p = duck_str_cstr(path);
    size_t len = strlen(p);
    if (len == 0) return DUCK_ERR(DuckRes_unit, duck__err_errno("fs.mkdir", path, ENOENT));
    char *buf = duck__xmalloc(len + 1);
    memcpy(buf, p, len + 1);
    int err = 0;
    /* Create each prefix that ends before a '/', then the whole path. */
    for (size_t i = 1; i <= len && !err; i++) {
        if (i < len && buf[i] != '/') continue;
        char saved = buf[i];
        buf[i] = 0;
        if (mkdir(buf, 0777) != 0) {
            struct stat st;
            if (errno != EEXIST) err = errno;
            else if (stat(buf, &st) != 0) err = errno;
            else if (!S_ISDIR(st.st_mode)) err = ENOTDIR;
        }
        buf[i] = saved;
    }
    free(buf);
    if (err) return DUCK_ERR(DuckRes_unit, duck__err_errno("fs.mkdir", path, err));
    return DUCK_OK(DuckRes_unit, DUCK_UNIT);
}

DuckRes_unit duck_fs_remove(const DuckStr *path) {
    const char *p = duck_str_cstr(path);
    struct stat st;
    int rc = lstat(p, &st);
    if (rc == 0) rc = S_ISDIR(st.st_mode) ? rmdir(p) : unlink(p);
    if (rc != 0) return DUCK_ERR(DuckRes_unit, duck__err_errno("fs.remove", path, errno));
    return DUCK_OK(DuckRes_unit, DUCK_UNIT);
}

DuckRes_unit duck_fs_rename(const DuckStr *from, const DuckStr *to) {
    if (rename(duck_str_cstr(from), duck_str_cstr(to)) != 0) {
        DuckErr *e = duck_err_fmt("fs.rename %s -> %s: %s", duck_str_cstr(from), duck_str_cstr(to), strerror(errno));
        e->code = errno;
        return DUCK_ERR(DuckRes_unit, e);
    }
    return DUCK_OK(DuckRes_unit, DUCK_UNIT);
}

static DuckRes_unit write_file(const char *what, const char *mode, const DuckStr *path, const void *p, size_t n) {
    FILE *f = fopen(duck_str_cstr(path), mode);
    if (!f) return DUCK_ERR(DuckRes_unit, duck__err_errno(what, path, errno));
    int err = 0;
    if (n && fwrite(p, 1, n, f) != n) err = errno ? errno : EIO;
    if (fclose(f) != 0 && !err) err = errno;
    if (err) return DUCK_ERR(DuckRes_unit, duck__err_errno(what, path, err));
    return DUCK_OK(DuckRes_unit, DUCK_UNIT);
}

DuckRes_unit duck_fs_append(const DuckStr *path, const DuckStr *text) {
    return write_file("fs.append", "ab", path, duck_str_cstr(text), (size_t)duck_str_byte_len(text));
}

DuckRes_str duck_fs_temp_dir(void) {
    const char *base = getenv("TMPDIR");
    if (!base || !*base) base = "/tmp";
    size_t bl = strlen(base);
    while (bl > 1 && base[bl - 1] == '/') bl--;
    char *tmpl = duck__xmalloc(bl + 16);
    snprintf(tmpl, bl + 16, "%.*s/duck-XXXXXX", (int)bl, base);
    if (!mkdtemp(tmpl)) { /* mode 0700, a fresh name */
        int err = errno;
        DuckErr *e = duck_err_fmt("fs.temp_dir %s: %s", tmpl, strerror(err));
        e->code = err;
        free(tmpl);
        return DUCK_ERR(DuckRes_str, e);
    }
    DuckStr *s = duck_str_lit(tmpl);
    free(tmpl);
    return DUCK_OK(DuckRes_str, s);
}

/* Read all of f into b; returns 0 or an errno. */
static int slurp(FILE *f, DuckStrBuf *b) {
    char buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) duck_sb_bytes(b, buf, (int64_t)n);
    return ferror(f) ? (errno ? errno : EIO) : 0;
}

DuckRes_arr duck_fs_read_bytes(const DuckStr *path) {
    FILE *f = fopen(duck_str_cstr(path), "rb");
    if (!f) return DUCK_ERR(DuckRes_arr, duck__err_errno("fs.read_bytes", path, errno));
    DuckStrBuf b = DUCK_SB_INIT;
    int err = slurp(f, &b);
    fclose(f);
    if (err) {
        duck_sb_free(&b);
        return DUCK_ERR(DuckRes_arr, duck__err_errno("fs.read_bytes", path, err));
    }
    DuckArr *a = duck_arr_new(&duck_ops_int, b.len);
    int64_t *d = duck_arr_make_unique(&a);
    for (int64_t i = 0; i < b.len; i++) d[i] = (unsigned char)b.buf[i];
    a->len = b.len;
    duck_sb_free(&b);
    return DUCK_OK(DuckRes_arr, a);
}

DuckRes_unit duck_fs_write_bytes(const DuckStr *path, const DuckArr *bytes) {
    int64_t n = duck_arr_len(bytes);
    const int64_t *xs = duck_arr_data(bytes);
    unsigned char *buf = duck__xmalloc((size_t)n);
    for (int64_t i = 0; i < n; i++) {
        if (xs[i] < 0 || xs[i] > 255) { /* checked before the file is touched */
            free(buf);
            return DUCK_ERR(DuckRes_unit, duck_err_fmt("fs.write_bytes %s: byte %lld at index %lld is out of range 0..255",
                                                       duck_str_cstr(path), (long long)xs[i], (long long)i));
        }
        buf[i] = (unsigned char)xs[i];
    }
    DuckRes_unit r = write_file("fs.write_bytes", "wb", path, buf, (size_t)n);
    free(buf);
    return r;
}

/* ---- net ---------------------------------------------------------------- */

void duck__conn_free(DuckConn *c) {
    duck_conn_close(c);
    duck__free_obj(c);
}

static bool conn_open(const DuckConn *c) { return c && (c->fd >= 0 || c->tls); }

/* Socket options every connected socket gets. */
static void conn_sockopts(int fd) {
#ifdef SO_NOSIGPIPE
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
    fcntl(fd, F_SETFD, FD_CLOEXEC);
}

DuckRes_conn duck_net_tcp(const DuckStr *host, int64_t port) {
    if (port < 0 || port > 65535)
        return DUCK_ERR(DuckRes_conn, duck_err_fmt("net.tcp %s:%lld: invalid port", duck_str_cstr(host), (long long)port));
    char ports[16];
    snprintf(ports, sizeof ports, "%lld", (long long)port);
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    int gai = getaddrinfo(duck_str_cstr(host), ports, &hints, &res);
    if (gai != 0)
        return DUCK_ERR(DuckRes_conn, duck_err_fmt("net.tcp %s:%s: %s", duck_str_cstr(host), ports, gai_strerror(gai)));
    int fd = -1, err = 0;
    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) {
            err = errno;
            continue;
        }
        int rc;
        do rc = connect(fd, ai->ai_addr, ai->ai_addrlen);
        while (rc < 0 && errno == EINTR);
        if (rc == 0) break;
        err = errno;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0) {
        DuckErr *e = duck_err_fmt("net.tcp %s:%s: %s", duck_str_cstr(host), ports, strerror(err));
        e->code = err;
        return DUCK_ERR(DuckRes_conn, e);
    }
    conn_sockopts(fd);
    DuckConn *c = duck__alloc(sizeof(DuckConn), DUCK_K_CONN);
    c->fd = fd;
    return DUCK_OK(DuckRes_conn, c);
}

void duck__listener_free(DuckListener *l) {
    duck_listener_close(l);
    duck__free_obj(l);
}

DuckRes_listener duck_net_listen(const DuckStr *host, int64_t port) {
    const char *h = duck_str_cstr(host);
    if (port < 0 || port > 65535)
        return DUCK_ERR(DuckRes_listener, duck_err_fmt("net.listen %s:%lld: invalid port", h, (long long)port));
    char ports[16];
    snprintf(ports, sizeof ports, "%lld", (long long)port);
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_PASSIVE;
    int gai = getaddrinfo(*h ? h : NULL, ports, &hints, &res);
    if (gai != 0)
        return DUCK_ERR(DuckRes_listener, duck_err_fmt("net.listen %s:%s: %s", h, ports, gai_strerror(gai)));
    int fd = -1, err = 0;
    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) {
            err = errno;
            continue;
        }
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        if (bind(fd, ai->ai_addr, ai->ai_addrlen) == 0 && listen(fd, 128) == 0) break;
        err = errno;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0) {
        DuckErr *e = duck_err_fmt("net.listen %s:%s: %s", h, ports, strerror(err));
        e->code = err;
        return DUCK_ERR(DuckRes_listener, e);
    }
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    struct sockaddr_storage ss;
    socklen_t len = sizeof ss;
    int64_t bound = port;
    if (getsockname(fd, (struct sockaddr *)&ss, &len) == 0) {
        if (ss.ss_family == AF_INET) bound = ntohs(((struct sockaddr_in *)&ss)->sin_port);
        else if (ss.ss_family == AF_INET6) bound = ntohs(((struct sockaddr_in6 *)&ss)->sin6_port);
    }
    DuckListener *l = duck__alloc(sizeof(DuckListener), DUCK_K_LISTENER);
    l->fd = fd;
    l->port = bound;
    return DUCK_OK(DuckRes_listener, l);
}

DuckRes_conn duck_listener_accept(DuckListener *l) {
    if (!l || l->fd < 0) return DUCK_ERR(DuckRes_conn, duck_err_fmt("net accept: listener is closed"));
    int fd;
    do fd = accept(l->fd, NULL, NULL);
    while (fd < 0 && (errno == EINTR || errno == ECONNABORTED));
    if (fd < 0) return DUCK_ERR(DuckRes_conn, duck__err_errno("net accept", NULL, errno));
    conn_sockopts(fd);
    DuckConn *c = duck__alloc(sizeof(DuckConn), DUCK_K_CONN);
    c->fd = fd;
    return DUCK_OK(DuckRes_conn, c);
}

int64_t duck_listener_port(const DuckListener *l) { return l ? l->port : 0; }

void duck_listener_close(DuckListener *l) {
    if (l && l->fd >= 0) {
        close(l->fd);
        l->fd = -1;
    }
}

DuckRes_arr duck_conn_read(DuckConn *c, int64_t max) {
    if (!conn_open(c)) return DUCK_ERR(DuckRes_arr, duck_err_fmt("net read: connection is closed"));
    if (max <= 0) return DUCK_ERR(DuckRes_arr, duck_err_fmt("net read: max must be positive"));
    if (max > 1 << 24) max = 1 << 24;
    if (c->tls) return duck__tls_read(c->tls, max);
    unsigned char *buf = duck__xmalloc((size_t)max);
    ssize_t n;
    do n = recv(c->fd, buf, (size_t)max, 0);
    while (n < 0 && errno == EINTR);
    if (n < 0) {
        int err = errno;
        free(buf);
        return DUCK_ERR(DuckRes_arr, duck__err_errno("net read", NULL, err));
    }
    DuckArr *a = duck_arr_new(&duck_ops_int, n);
    int64_t *d = duck_arr_make_unique(&a);
    for (ssize_t i = 0; i < n; i++) d[i] = buf[i];
    a->len = n;
    free(buf);
    return DUCK_OK(DuckRes_arr, a);
}

DuckRes_unit duck_conn_write(DuckConn *c, const DuckArr *bytes) {
    if (!conn_open(c)) return DUCK_ERR(DuckRes_unit, duck_err_fmt("net write: connection is closed"));
    int64_t n = duck_arr_len(bytes);
    const int64_t *xs = duck_arr_data(bytes);
    unsigned char *buf = duck__xmalloc((size_t)n);
    for (int64_t i = 0; i < n; i++) {
        if (xs[i] < 0 || xs[i] > 255) {
            free(buf);
            return DUCK_ERR(DuckRes_unit, duck_err_fmt("net write: byte %lld out of range 0..255", (long long)xs[i]));
        }
        buf[i] = (unsigned char)xs[i];
    }
    if (c->tls) {
        DuckRes_unit r = duck__tls_write(c->tls, buf, n);
        free(buf);
        return r;
    }
    int64_t off = 0;
    while (off < n) {
#ifdef MSG_NOSIGNAL
        ssize_t w = send(c->fd, buf + off, (size_t)(n - off), MSG_NOSIGNAL);
#else
        ssize_t w = send(c->fd, buf + off, (size_t)(n - off), 0);
#endif
        if (w < 0) {
            if (errno == EINTR) continue;
            int err = errno;
            free(buf);
            return DUCK_ERR(DuckRes_unit, duck__err_errno("net write", NULL, err));
        }
        off += w;
    }
    free(buf);
    return DUCK_OK(DuckRes_unit, DUCK_UNIT);
}

void duck_conn_close(DuckConn *c) {
    if (c && c->tls) {
        duck__tls_free(c->tls); /* before the socket closes: it may send close_notify */
        c->tls = NULL;
    }
    if (c && c->fd >= 0) {
        close(c->fd);
        c->fd = -1;
    }
}

/* ---- time --------------------------------------------------------------- */

int64_t duck_time_now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

void duck_time_sleep(int64_t ms) {
    if (ms <= 0) return;
    struct timespec ts = {(time_t)(ms / 1000), (long)(ms % 1000) * 1000000L};
    while (nanosleep(&ts, &ts) < 0 && errno == EINTR) {
    }
}

/* ---- rand (xoshiro256**, seeded from the OS CSPRNG) --------------------- */

/* Fill buf from the OS CSPRNG; false if none is available. */
static bool os_random(void *buf, size_t n) {
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
    arc4random_buf(buf, n);
    return true;
#else
    unsigned char *p = buf;
#if defined(__linux__)
    while (n > 0) {
        ssize_t r = getrandom(p, n, 0);
        if (r < 0) {
            if (errno == EINTR) continue;
            break; /* ENOSYS (old kernel): fall back to /dev/urandom */
        }
        p += r;
        n -= (size_t)r;
    }
    if (n == 0) return true;
#endif
    int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return false;
    while (n > 0) {
        ssize_t r = read(fd, p, n);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) break;
        p += r;
        n -= (size_t)r;
    }
    close(fd);
    return n == 0;
#endif
}

static pthread_mutex_t rand_mu = PTHREAD_MUTEX_INITIALIZER;
static uint64_t rand_s[4];
static bool rand_seeded;

static uint64_t rotl(uint64_t x, int k) { return (x << k) | (x >> (64 - k)); }

static uint64_t rand_next(void) {
    pthread_mutex_lock(&rand_mu);
    if (!rand_seeded) {
        if (!os_random(rand_s, sizeof rand_s)) {
            uint64_t t = (uint64_t)duck_time_now() ^ ((uint64_t)getpid() << 32);
            for (int i = 0; i < 4; i++) rand_s[i] = duck_hash_int((int64_t)(t + (uint64_t)i));
        }
        if (!(rand_s[0] | rand_s[1] | rand_s[2] | rand_s[3])) rand_s[0] = 1;
        rand_seeded = true;
    }
    uint64_t *s = rand_s;
    uint64_t r = rotl(s[1] * 5, 7) * 9, t = s[1] << 17;
    s[2] ^= s[0];
    s[3] ^= s[1];
    s[1] ^= s[2];
    s[0] ^= s[3];
    s[2] ^= t;
    s[3] = rotl(s[3], 45);
    pthread_mutex_unlock(&rand_mu);
    return r;
}

int64_t duck_rand_int(int64_t lo, int64_t hi) {
    if (lo > hi) duck_panic("rand.int", "rand.int(%lld, %lld): lo > hi", (long long)lo, (long long)hi);
    uint64_t span = (uint64_t)hi - (uint64_t)lo + 1; /* 0 means the full 2^64 range */
    if (span == 0) return (int64_t)rand_next();
    uint64_t limit = UINT64_MAX - UINT64_MAX % span, x;
    do x = rand_next();
    while (x >= limit);
    return (int64_t)((uint64_t)lo + x % span);
}

double duck_rand_float(void) { return (double)(rand_next() >> 11) * 0x1.0p-53; }

void duck_rand_seed(int64_t seed) {
    uint64_t x = (uint64_t)seed;
    pthread_mutex_lock(&rand_mu);
    for (int i = 0; i < 4; i++) { /* splitmix64 */
        uint64_t z = (x += 0x9E3779B97F4A7C15ull);
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
        rand_s[i] = z ^ (z >> 31);
    }
    if (!(rand_s[0] | rand_s[1] | rand_s[2] | rand_s[3])) rand_s[0] = 1;
    rand_seeded = true;
    pthread_mutex_unlock(&rand_mu);
}

DuckArr *duck_rand_bytes(int64_t n, const char *loc) {
    if (n < 0) duck_panic(loc, "rand.bytes(%lld): negative count", (long long)n);
    unsigned char *buf = duck__xmalloc((size_t)n);
    if (!os_random(buf, (size_t)n)) {
        free(buf);
        duck_panic(loc, "rand.bytes: no OS random source available");
    }
    DuckArr *a = duck_arr_new(&duck_ops_int, n);
    int64_t *d = duck_arr_make_unique(&a);
    for (int64_t i = 0; i < n; i++) d[i] = buf[i];
    a->len = n;
    free(buf);
    return a;
}

/* ---- env ---------------------------------------------------------------- */

static DuckArr *g_args;
static pthread_mutex_t args_mu = PTHREAD_MUTEX_INITIALIZER;

DuckOpt_str duck_env_get(const DuckStr *key) {
    const char *v = getenv(duck_str_cstr(key));
    if (!v) return DUCK_NONE(DuckOpt_str);
    return DUCK_SOME(DuckOpt_str, duck_str_lit(v));
}

void duck_env_set_args(int argc, char **argv) {
    DuckArr *a = duck_arr_new(&duck_ops_str, argc);
    for (int i = 0; i < argc; i++) {
        DuckStr *s = duck_str_lit(argv[i]);
        duck_arr_push(&a, &s);
        duck_release(s);
        duck__make_immortal(s);
    }
    duck__make_immortal(a);
    pthread_mutex_lock(&args_mu);
    g_args = a; /* a previous array is immortal and simply abandoned */
    pthread_mutex_unlock(&args_mu);
}

DuckArr *duck_env_args(void) {
    pthread_mutex_lock(&args_mu);
    if (!g_args) {
        g_args = duck_arr_new(&duck_ops_str, 0);
        duck__make_immortal(g_args);
    }
    DuckArr *a = g_args;
    pthread_mutex_unlock(&args_mu);
    return a;
}

/* stdin: read through stdio (one buffer shared by read_line, read_all and lines). Stdout is
 * flushed first, so a prompt printed without a newline-terminated flush still shows. */

DuckOpt_str duck_env_read_line(void) {
    fflush(stdout);
    char *line = NULL;
    size_t cap = 0;
    ssize_t n = getline(&line, &cap, stdin);
    if (n < 0) {
        free(line);
        return DUCK_NONE(DuckOpt_str);
    }
    if (n > 0 && line[n - 1] == '\n') n--;
    if (n > 0 && line[n - 1] == '\r') n--;
    DuckStr *s = duck_str_from_bytes(line, n); /* invalid UTF-8 becomes U+FFFD */
    free(line);
    return DUCK_SOME(DuckOpt_str, s);
}

DuckRes_str duck_env_read_all(void) {
    fflush(stdout);
    DuckStrBuf b = DUCK_SB_INIT;
    int err = slurp(stdin, &b);
    if (err) {
        clearerr(stdin);
        duck_sb_free(&b);
        return DUCK_ERR(DuckRes_str, duck__err_errno("env.read_all: stdin", NULL, err));
    }
    DuckRes_str r = duck_str_try_from_bytes(b.buf ? b.buf : "", b.len);
    duck_sb_free(&b);
    if (!r.ok) {
        DuckErr *e = duck_err_fmt("env.read_all: stdin");
        e->cause = r.err; /* moves the reference */
        r.err = e;
    }
    return r;
}

DuckArr *duck_env_lines(void) {
    fflush(stdout);
    DuckStrBuf b = DUCK_SB_INIT;
    if (slurp(stdin, &b)) clearerr(stdin); /* keep what was read before the error */
    DuckStr *s = duck_str_from_bytes(b.buf ? b.buf : "", b.len);
    duck_sb_free(&b);
    DuckArr *a = duck_str_lines(s);
    duck_release(s);
    return a;
}

/* ---- proc --------------------------------------------------------------- */

DuckRes_str duck_proc_run(const DuckStr *cmd, const DuckArr *args) {
    int64_t n = duck_arr_len(args);
    char **argv = duck__xcalloc((size_t)n + 2, sizeof(char *));
    argv[0] = (char *)duck_str_cstr(cmd);
    DuckStr *const *as = duck_arr_data(args);
    for (int64_t i = 0; i < n; i++) argv[i + 1] = (char *)duck_str_cstr(as[i]);
    int fds[2];
    if (pipe(fds) < 0) {
        free(argv);
        return DUCK_ERR(DuckRes_str, duck__err_errno("proc.run", cmd, errno));
    }
    fcntl(fds[0], F_SETFD, FD_CLOEXEC);
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, fds[1], 1);
    posix_spawn_file_actions_addclose(&fa, fds[1]);
    pid_t pid;
    fflush(stdout);
    int rc = posix_spawnp(&pid, duck_str_cstr(cmd), &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    free(argv);
    close(fds[1]);
    if (rc != 0) {
        close(fds[0]);
        return DUCK_ERR(DuckRes_str, duck__err_errno("proc.run", cmd, rc));
    }
    DuckStrBuf b = DUCK_SB_INIT;
    char buf[65536];
    for (;;) {
        ssize_t r = read(fds[0], buf, sizeof buf);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) break;
        duck_sb_bytes(&b, buf, r);
    }
    close(fds[0]);
    int status;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) {
            status = -1;
            break;
        }
    }
    DuckStr *out = duck_str_from_bytes(b.buf ? b.buf : "", b.len);
    duck_sb_free(&b);
    if (status == -1 || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        DuckErr *e;
        if (status != -1 && WIFEXITED(status)) {
            e = duck_err_fmt("proc.run %s: exited with status %d", duck_str_cstr(cmd), WEXITSTATUS(status));
            e->code = WEXITSTATUS(status);
        } else if (status != -1 && WIFSIGNALED(status)) {
            e = duck_err_fmt("proc.run %s: killed by signal %d", duck_str_cstr(cmd), WTERMSIG(status));
            e->code = 128 + WTERMSIG(status);
        } else {
            e = duck_err_fmt("proc.run %s: could not wait for the process", duck_str_cstr(cmd));
        }
        duck_release(out);
        return DUCK_ERR(DuckRes_str, e);
    }
    return DUCK_OK(DuckRes_str, out);
}

void duck_proc_exit(int64_t code, const char *loc) {
    if (code < 0 || code > 255) duck_panic(loc, "proc.exit(%lld): code out of range 0..255", (long long)code);
    fflush(stdout);
    fflush(stderr);
    duck__trace_flush();
    if (duck_leak_check() != 0) _exit(102);
    /* _exit, like a panic: async tasks may still be running on other threads. */
    _exit((int)code);
}

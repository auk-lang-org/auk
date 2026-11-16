/* TLS client sessions for `net.tls` (see duck_net_tls in duck.h).
 *
 * Duck never implements cryptography itself; it drives the platform's TLS stack. The backend is
 * picked at compile time, so the runtime always builds without any TLS library installed:
 *
 *  - macOS: Apple's Network.framework (an nw_connection with the default TLS options), wrapped
 *    synchronously with dispatch semaphores to fit the blocking Conn API (a Duck task is a
 *    thread). Chosen over SecureTransport, which is deprecated and stops at TLS 1.2. The
 *    certificate check is Security.framework's SecTrustEvaluateWithError with an SSL policy
 *    for the host. The driver links `-framework Network -framework Security
 *    -framework CoreFoundation`.
 *  - other Unix (or macOS with -DDUCK_TLS_OPENSSL): OpenSSL 3 / 1.1 (libssl), loaded with
 *    dlopen on first use, so nothing is needed at build time. No libssl at run time means
 *    Err("tls unavailable in this build: libssl not found").
 *  - anything else: Err("tls unavailable in this build").
 *
 * Verification is always on and cannot be turned off: the server's chain is checked against
 * the system trust store and its certificate against `host` (SNI is sent too). A failure is
 * an Err "net.tls <host>:<port>: certificate verification failed: <reason>".
 */
#include "duck_internal.h"

#include <errno.h>

#if defined(__APPLE__) && !defined(DUCK_TLS_OPENSSL) && defined(__BLOCKS__)
#if defined(__has_include)
#if __has_include(<Network/Network.h>)
#define DUCK_TLS_NW 1
#endif
#endif
#elif defined(__unix__) || defined(__APPLE__)
#define DUCK_TLS_DL 1
#endif

#if defined(DUCK_TLS_NW) || defined(DUCK_TLS_DL)
static bool valid_port(int64_t port) { return port > 0 && port <= 65535; }
#endif

/* =====================================================================
 * macOS: Network.framework
 * ===================================================================== */
#if defined(DUCK_TLS_NW)
#include <Network/Network.h>
#include <Security/Security.h>

typedef struct {
    nw_connection_t conn;
    dispatch_queue_t q;
    dispatch_semaphore_t ready; /* the first ready / waiting / failed state */
    dispatch_semaphore_t gone;  /* the cancelled state */
    /* written on q only */
    bool reported, ok;
    int domain, code;
    char why[256]; /* why the trust evaluation failed */
    char *host;
    /* the caller's thread only */
    bool eof;
    bool pending; /* an error that arrived with the last data, reported by the next read */
    int pend_domain, pend_code;
} NwTls;

/* Signal s from a callback; the retain keeps s alive though the waiter may release it at once. */
static void post(dispatch_semaphore_t s) {
    dispatch_retain(s);
    dispatch_semaphore_signal(s);
    dispatch_release(s);
}

/* The text of a TLS OSStatus (Security/SecureTransport.h); *verify says whether it is about
 * the server's certificate. */
static const char *tls_status(int code, bool *verify) {
    *verify = true;
    switch (code) {
    case -9807: return "invalid certificate chain";
    case -9808: return "bad certificate";
    case -9812: return "certificate chain ends in an unknown root";
    case -9813: return "certificate is not trusted (self-signed or no trusted root)";
    case -9814: return "certificate has expired";
    case -9815: return "certificate is not yet valid";
    case -9825: return "the server rejected the certificate";
    case -9843: return "certificate does not match the host name";
    case -67843: return "certificate is not trusted";
    case -67818: return "certificate has expired";
    case -67602: return "certificate does not match the host name";
    }
    *verify = false;
    switch (code) {
    case -9800: return "protocol error";
    case -9801: return "no cipher suite in common";
    case -9805: return "the server closed the connection";
    case -9806: return "the connection closed during the handshake";
    case -9816: return "the server closed the connection without close_notify";
    case -9824: return "the server's TLS version is not supported";
    case -9836: return "the server's TLS version is not supported";
    case -9802: return "fatal alert from the server";
    }
    return NULL;
}

/* "<prefix>: <reason>" for an nw_error (domain, code). */
static DuckErr *nw_err(const char *prefix, int domain, int code) {
    DuckErr *e;
    if (domain == nw_error_domain_posix) {
        e = duck_err_fmt("%s: %s", prefix, strerror(code));
        e->code = code;
    } else if (domain == nw_error_domain_dns) {
        e = duck_err_fmt("%s: cannot resolve the host (DNS error %d)", prefix, code);
    } else if (domain == nw_error_domain_tls) {
        bool verify;
        const char *what = tls_status(code, &verify);
        if (what && verify) e = duck_err_fmt("%s: certificate verification failed: %s", prefix, what);
        else if (what) e = duck_err_fmt("%s: TLS error: %s", prefix, what);
        else e = duck_err_fmt("%s: TLS error (OSStatus %d)", prefix, code);
    } else {
        e = duck_err_fmt("%s: connection failed", prefix);
    }
    return e;
}

static void nw_tls_free(NwTls *t) {
    nw_connection_cancel(t->conn);
    dispatch_semaphore_wait(t->gone, DISPATCH_TIME_FOREVER);
    nw_release(t->conn);
    free(t->host);
    dispatch_release(t->q);
    dispatch_release(t->ready);
    dispatch_release(t->gone);
    free(t);
}

DuckRes_conn duck_net_tls(const DuckStr *host, int64_t port) {
    const char *h = duck_str_cstr(host);
    if (!valid_port(port)) return DUCK_ERR(DuckRes_conn, duck_err_fmt("net.tls %s:%lld: invalid port", h, (long long)port));
    if (!*h) return DUCK_ERR(DuckRes_conn, duck_err_fmt("net.tls :%lld: empty host", (long long)port));
    char ports[16];
    snprintf(ports, sizeof ports, "%lld", (long long)port);
    NwTls *t = duck__xcalloc(1, sizeof *t);
    t->q = dispatch_queue_create("duck.net.tls", DISPATCH_QUEUE_SERIAL);
    t->ready = dispatch_semaphore_create(0);
    t->gone = dispatch_semaphore_create(0);
    t->host = strdup(h);
    nw_endpoint_t ep = nw_endpoint_create_host(h, ports);
    /* The endpoint's host is sent as SNI. The verify block runs the system's own evaluation
     * (Security.framework: the system trust store plus an SSL server policy pinned to `host`),
     * the same check the default does, but it lets us report why a certificate was refused
     * (the default sometimes surfaces only a connection reset). */
    nw_parameters_t params = nw_parameters_create_secure_tcp(^(nw_protocol_options_t tls) {
        sec_protocol_options_t sec = nw_tls_copy_sec_protocol_options(tls);
        sec_protocol_options_set_verify_block(sec, ^(sec_protocol_metadata_t md, sec_trust_t trust_ref, sec_protocol_verify_complete_t complete) {
            (void)md;
            SecTrustRef trust = sec_trust_copy_ref(trust_ref);
            CFStringRef name = CFStringCreateWithCString(NULL, t->host, kCFStringEncodingUTF8);
            SecPolicyRef policy = SecPolicyCreateSSL(true, name);
            CFErrorRef err = NULL;
            bool ok = name && policy && SecTrustSetPolicies(trust, policy) == errSecSuccess && SecTrustEvaluateWithError(trust, &err);
            if (!ok) {
                snprintf(t->why, sizeof t->why, "the system trust evaluation failed");
                CFStringRef d = err ? CFErrorCopyDescription(err) : NULL;
                if (d) {
                    CFStringGetCString(d, t->why, sizeof t->why, kCFStringEncodingUTF8);
                    CFRelease(d);
                }
            }
            if (err) CFRelease(err);
            if (policy) CFRelease(policy);
            if (name) CFRelease(name);
            CFRelease(trust);
            complete(ok);
        }, t->q);
        nw_release(sec);
    }, ^(nw_protocol_options_t tcp) {
        nw_tcp_options_set_connection_timeout(tcp, 30);
    });
    t->conn = nw_connection_create(ep, params);
    nw_release(ep);
    nw_release(params);
    nw_connection_set_queue(t->conn, t->q);
    nw_connection_set_state_changed_handler(t->conn, ^(nw_connection_state_t st, nw_error_t err) {
        if (st == nw_connection_state_cancelled) {
            post(t->gone);
            return;
        }
        bool done = st == nw_connection_state_ready || st == nw_connection_state_waiting || st == nw_connection_state_failed;
        if (!done || t->reported) return;
        t->reported = true;
        t->ok = st == nw_connection_state_ready;
        if (err) {
            t->domain = (int)nw_error_get_error_domain(err);
            t->code = nw_error_get_error_code(err);
        }
        post(t->ready);
    });
    nw_connection_start(t->conn);
    dispatch_semaphore_wait(t->ready, dispatch_time(DISPATCH_TIME_NOW, 60 * (int64_t)NSEC_PER_SEC));
    /* read the outcome on the queue (and mark it reported, which settles a timeout) */
    __block bool reported, ok;
    __block int domain, code;
    char why[sizeof t->why], *whyp = why; /* a block can't capture an array */
    dispatch_sync(t->q, ^{
        memcpy(whyp, t->why, sizeof t->why);
        reported = t->reported;
        ok = t->ok;
        domain = t->domain;
        code = t->code;
        t->reported = true;
    });
    if (!ok) {
        nw_tls_free(t);
        char prefix[300];
        snprintf(prefix, sizeof prefix, "net.tls %s:%s", h, ports);
        if (why[0]) return DUCK_ERR(DuckRes_conn, duck_err_fmt("%s: certificate verification failed: %s", prefix, why));
        if (!reported) return DUCK_ERR(DuckRes_conn, duck_err_fmt("%s: timed out", prefix));
        return DUCK_ERR(DuckRes_conn, nw_err(prefix, domain, code));
    }
    DuckConn *c = duck__alloc(sizeof(DuckConn), DUCK_K_CONN);
    c->fd = -1;
    c->tls = t;
    return DUCK_OK(DuckRes_conn, c);
}

/* Errors that just mean the peer has closed the stream. */
static bool nw_is_eof(int domain, int code) {
    return (domain == nw_error_domain_posix && code == ENODATA) || (domain == nw_error_domain_tls && (code == -9805 || code == -9816));
}

DuckRes_arr duck__tls_read(void *p, int64_t max) {
    NwTls *t = p;
    if (t->pending) {
        t->pending = false;
        t->eof = true;
        return DUCK_ERR(DuckRes_arr, nw_err("net read", t->pend_domain, t->pend_code));
    }
    if (t->eof) return DUCK_OK(DuckRes_arr, duck_arr_new(&duck_ops_int, 0));
    __block unsigned char *buf = NULL;
    __block size_t n = 0;
    __block bool fin = false, failed = false;
    __block int domain = 0, code = 0;
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    nw_connection_receive(t->conn, 1, (uint32_t)max, ^(dispatch_data_t content, nw_content_context_t ctx, bool complete, nw_error_t err) {
        (void)ctx;
        if (content) {
            n = dispatch_data_get_size(content);
            buf = duck__xmalloc(n ? n : 1);
            dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t off, const void *bytes, size_t len) {
                (void)region;
                memcpy(buf + off, bytes, len);
                return true;
            });
        }
        fin = complete;
        if (err) {
            failed = true;
            domain = (int)nw_error_get_error_domain(err);
            code = nw_error_get_error_code(err);
        }
        post(s);
    });
    dispatch_semaphore_wait(s, DISPATCH_TIME_FOREVER);
    dispatch_release(s);
    if (failed && !nw_is_eof(domain, code)) {
        if (n == 0) {
            free(buf);
            t->eof = true;
            return DUCK_ERR(DuckRes_arr, nw_err("net read", domain, code));
        }
        t->pending = true;
        t->pend_domain = domain;
        t->pend_code = code;
    } else if (fin || failed || n == 0) {
        t->eof = true;
    }
    DuckArr *a = duck_arr_new(&duck_ops_int, (int64_t)n);
    int64_t *d = duck_arr_make_unique(&a);
    for (size_t i = 0; i < n; i++) d[i] = buf[i];
    a->len = (int64_t)n;
    free(buf);
    return DUCK_OK(DuckRes_arr, a);
}

DuckRes_unit duck__tls_write(void *p, const unsigned char *buf, int64_t n) {
    NwTls *t = p;
    if (n == 0) return DUCK_OK(DuckRes_unit, DUCK_UNIT);
    /* DISPATCH_DATA_DESTRUCTOR_DEFAULT copies buf */
    dispatch_data_t data = dispatch_data_create(buf, (size_t)n, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    __block bool failed = false;
    __block int domain = 0, code = 0;
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    nw_connection_send(t->conn, data, NW_CONNECTION_DEFAULT_STREAM_CONTEXT, false, ^(nw_error_t err) {
        if (err) {
            failed = true;
            domain = (int)nw_error_get_error_domain(err);
            code = nw_error_get_error_code(err);
        }
        post(s);
    });
    dispatch_semaphore_wait(s, DISPATCH_TIME_FOREVER);
    dispatch_release(s);
    dispatch_release(data);
    if (failed) return DUCK_ERR(DuckRes_unit, nw_err("net write", domain, code));
    return DUCK_OK(DuckRes_unit, DUCK_UNIT);
}

void duck__tls_free(void *p) { nw_tls_free(p); }

/* =====================================================================
 * Unix: OpenSSL through dlopen
 * ===================================================================== */
#elif defined(DUCK_TLS_DL)
#include <dlfcn.h>
#include <pthread.h>
#include <signal.h>
#include <time.h>

typedef struct ssl_st SSL;
typedef struct ssl_ctx_st SSL_CTX;
typedef struct ssl_method_st SSL_METHOD;

/* The libssl (and, through its dependencies, libcrypto) entry points used here. */
static struct {
    const SSL_METHOD *(*TLS_client_method)(void);
    SSL_CTX *(*SSL_CTX_new)(const SSL_METHOD *);
    void (*SSL_CTX_free)(SSL_CTX *);
    int (*SSL_CTX_set_default_verify_paths)(SSL_CTX *);
    void (*SSL_CTX_set_verify)(SSL_CTX *, int, void *);
    long (*SSL_CTX_ctrl)(SSL_CTX *, int, long, void *);
    SSL *(*SSL_new)(SSL_CTX *);
    void (*SSL_free)(SSL *);
    int (*SSL_set_fd)(SSL *, int);
    long (*SSL_ctrl)(SSL *, int, long, void *);
    int (*SSL_set1_host)(SSL *, const char *);
    int (*SSL_connect)(SSL *);
    int (*SSL_read)(SSL *, void *, int);
    int (*SSL_write)(SSL *, const void *, int);
    int (*SSL_shutdown)(SSL *);
    int (*SSL_get_error)(const SSL *, int);
    long (*SSL_get_verify_result)(const SSL *);
    const char *(*X509_verify_cert_error_string)(long);
    unsigned long (*ERR_get_error)(void);
    void (*ERR_error_string_n)(unsigned long, char *, size_t);
    void (*ERR_clear_error)(void);
    uint64_t (*SSL_CTX_set_options)(SSL_CTX *, uint64_t); /* optional (OpenSSL 3+) */
} ossl;
static bool ossl_ok;
static pthread_once_t ossl_once = PTHREAD_ONCE_INIT;

enum {
    SSL_VERIFY_PEER_ = 1,
    SSL_ERROR_SSL_ = 1,
    SSL_ERROR_SYSCALL_ = 5,
    SSL_ERROR_ZERO_RETURN_ = 6,
    SSL_CTRL_SET_TLSEXT_HOSTNAME_ = 55,
    SSL_CTRL_SET_MIN_PROTO_VERSION_ = 123,
    TLS1_2_VERSION_ = 0x0303,
};
#define SSL_OP_IGNORE_UNEXPECTED_EOF_ ((uint64_t)1 << 7)

static void ossl_load(void) {
    static const char *const names[] = {
        "libssl.so.3", "libssl.so.1.1", "libssl.so",
#ifdef __APPLE__
        "/opt/homebrew/opt/openssl/lib/libssl.dylib", "/usr/local/opt/openssl/lib/libssl.dylib",
#endif
    };
    void *h = NULL;
    for (size_t i = 0; i < sizeof names / sizeof names[0] && !h; i++) h = dlopen(names[i], RTLD_NOW | RTLD_LOCAL);
    if (!h) return;
#define SYM(f)                                         \
    ossl.f = (__typeof__(ossl.f))dlsym(h, #f);         \
    if (!ossl.f) return;
    SYM(TLS_client_method) SYM(SSL_CTX_new) SYM(SSL_CTX_free) SYM(SSL_CTX_set_default_verify_paths)
    SYM(SSL_CTX_set_verify) SYM(SSL_CTX_ctrl) SYM(SSL_new) SYM(SSL_free) SYM(SSL_set_fd) SYM(SSL_ctrl)
    SYM(SSL_set1_host) SYM(SSL_connect) SYM(SSL_read) SYM(SSL_write) SYM(SSL_shutdown) SYM(SSL_get_error)
    SYM(SSL_get_verify_result) SYM(X509_verify_cert_error_string) SYM(ERR_get_error) SYM(ERR_error_string_n)
    SYM(ERR_clear_error)
#undef SYM
    ossl.SSL_CTX_set_options = (__typeof__(ossl.SSL_CTX_set_options))dlsym(h, "SSL_CTX_set_options");
    ossl_ok = true;
}

typedef struct {
    SSL_CTX *ctx;
    SSL *ssl;
    bool eof;
} OsslTls;

/* libssl writes with write(2), so a peer reset would raise SIGPIPE (macOS sockets carry
 * SO_NOSIGPIPE instead). Block it around writes and drop one that this write raised. */
typedef struct {
    sigset_t old;
    bool was_pending;
} PipeGuard;

static void pipe_block(PipeGuard *g) {
    sigset_t pipe, pend;
    sigemptyset(&pipe);
    sigaddset(&pipe, SIGPIPE);
    sigpending(&pend);
    g->was_pending = sigismember(&pend, SIGPIPE);
    pthread_sigmask(SIG_BLOCK, &pipe, &g->old);
}

static void pipe_unblock(PipeGuard *g) {
#if defined(__linux__)
    sigset_t pipe, pend;
    sigemptyset(&pipe);
    sigaddset(&pipe, SIGPIPE);
    sigpending(&pend);
    if (!g->was_pending && sigismember(&pend, SIGPIPE)) {
        struct timespec zero = {0, 0};
        while (sigtimedwait(&pipe, NULL, &zero) < 0 && errno == EINTR) {
        }
    }
#endif
    pthread_sigmask(SIG_SETMASK, &g->old, NULL);
}

/* "<prefix>: <the OpenSSL error queue's first entry, or errno>". */
static DuckErr *ossl_err(const char *prefix, int saved_errno) {
    unsigned long e = ossl.ERR_get_error();
    if (e) {
        char buf[256];
        ossl.ERR_error_string_n(e, buf, sizeof buf);
        return duck_err_fmt("%s: TLS error: %s", prefix, buf);
    }
    if (saved_errno) return duck__err_errno(prefix, NULL, saved_errno);
    return duck_err_fmt("%s: TLS error", prefix);
}

static void ossl_tls_free(OsslTls *t) {
    if (t->ssl) {
        PipeGuard g;
        pipe_block(&g);
        ossl.SSL_shutdown(t->ssl); /* best-effort close_notify */
        pipe_unblock(&g);
        ossl.SSL_free(t->ssl);
    }
    if (t->ctx) ossl.SSL_CTX_free(t->ctx);
    free(t);
}

/* Is h an IPv4/IPv6 literal (no SNI for those)? */
static bool is_ip_literal(const char *h) {
    bool dots_digits = true;
    for (const char *p = h; *p; p++) {
        if (*p == ':') return true;
        if (*p != '.' && (*p < '0' || *p > '9')) dots_digits = false;
    }
    return dots_digits;
}

DuckRes_conn duck_net_tls(const DuckStr *host, int64_t port) {
    const char *h = duck_str_cstr(host);
    if (!valid_port(port)) return DUCK_ERR(DuckRes_conn, duck_err_fmt("net.tls %s:%lld: invalid port", h, (long long)port));
    pthread_once(&ossl_once, ossl_load);
    if (!ossl_ok) return DUCK_ERR(DuckRes_conn, duck_err_fmt("tls unavailable in this build: libssl not found"));
    DuckRes_conn r = duck_net_tcp(host, port);
    if (!r.ok) return r;
    DuckConn *c = r.val;
    char prefix[300];
    snprintf(prefix, sizeof prefix, "net.tls %s:%lld", h, (long long)port);
    OsslTls *t = duck__xcalloc(1, sizeof *t);
    ossl.ERR_clear_error();
    t->ctx = ossl.SSL_CTX_new(ossl.TLS_client_method());
    if (!t->ctx || ossl.SSL_CTX_set_default_verify_paths(t->ctx) != 1) goto fail;
    ossl.SSL_CTX_set_verify(t->ctx, SSL_VERIFY_PEER_, NULL);
    ossl.SSL_CTX_ctrl(t->ctx, SSL_CTRL_SET_MIN_PROTO_VERSION_, TLS1_2_VERSION_, NULL);
    if (ossl.SSL_CTX_set_options) ossl.SSL_CTX_set_options(t->ctx, SSL_OP_IGNORE_UNEXPECTED_EOF_);
    t->ssl = ossl.SSL_new(t->ctx);
    if (!t->ssl || ossl.SSL_set_fd(t->ssl, c->fd) != 1) goto fail;
    if (!is_ip_literal(h)) ossl.SSL_ctrl(t->ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME_, 0, (void *)h);
    if (ossl.SSL_set1_host(t->ssl, h) != 1) goto fail;
    PipeGuard g;
    pipe_block(&g);
    int rc;
    do {
        errno = 0;
        rc = ossl.SSL_connect(t->ssl);
    } while (rc != 1 && ossl.SSL_get_error(t->ssl, rc) == SSL_ERROR_SYSCALL_ && errno == EINTR);
    int saved = errno;
    pipe_unblock(&g);
    if (rc != 1) {
        long v = ossl.SSL_get_verify_result(t->ssl);
        DuckErr *e = v != 0 ? duck_err_fmt("%s: certificate verification failed: %s", prefix, ossl.X509_verify_cert_error_string(v))
                            : ossl_err(prefix, saved);
        ossl_tls_free(t);
        duck_release(c);
        return DUCK_ERR(DuckRes_conn, e);
    }
    c->tls = t;
    return DUCK_OK(DuckRes_conn, c);
fail: {
    DuckErr *e = ossl_err(prefix, 0);
    ossl_tls_free(t);
    duck_release(c);
    return DUCK_ERR(DuckRes_conn, e);
}
}

DuckRes_arr duck__tls_read(void *p, int64_t max) {
    OsslTls *t = p;
    unsigned char *buf = duck__xmalloc((size_t)max);
    int n = 0;
    while (!t->eof) {
        ossl.ERR_clear_error();
        errno = 0;
        n = ossl.SSL_read(t->ssl, buf, (int)max);
        if (n > 0) break;
        int err = ossl.SSL_get_error(t->ssl, n), saved = errno;
        if (err == SSL_ERROR_SYSCALL_ && saved == EINTR) continue;
        n = 0;
        if (err == SSL_ERROR_ZERO_RETURN_ || (err == SSL_ERROR_SYSCALL_ && saved == 0)) {
            t->eof = true;
            break;
        }
        free(buf);
        return DUCK_ERR(DuckRes_arr, ossl_err("net read", err == SSL_ERROR_SYSCALL_ ? saved : 0));
    }
    DuckArr *a = duck_arr_new(&duck_ops_int, n);
    int64_t *d = duck_arr_make_unique(&a);
    for (int i = 0; i < n; i++) d[i] = buf[i];
    a->len = n;
    free(buf);
    return DUCK_OK(DuckRes_arr, a);
}

DuckRes_unit duck__tls_write(void *p, const unsigned char *buf, int64_t n) {
    OsslTls *t = p;
    PipeGuard g;
    pipe_block(&g);
    int64_t off = 0;
    DuckErr *e = NULL;
    while (off < n) {
        int chunk = n - off > (1 << 30) ? 1 << 30 : (int)(n - off);
        ossl.ERR_clear_error();
        errno = 0;
        int w = ossl.SSL_write(t->ssl, buf + off, chunk);
        if (w > 0) {
            off += w;
            continue;
        }
        int err = ossl.SSL_get_error(t->ssl, w), saved = errno;
        if (err == SSL_ERROR_SYSCALL_ && saved == EINTR) continue;
        e = ossl_err("net write", err == SSL_ERROR_SYSCALL_ ? saved : 0);
        break;
    }
    pipe_unblock(&g);
    if (e) return DUCK_ERR(DuckRes_unit, e);
    return DUCK_OK(DuckRes_unit, DUCK_UNIT);
}

void duck__tls_free(void *p) { ossl_tls_free(p); }

/* =====================================================================
 * No TLS backend
 * ===================================================================== */
#else
DuckRes_conn duck_net_tls(const DuckStr *host, int64_t port) {
    (void)host;
    (void)port;
    return DUCK_ERR(DuckRes_conn, duck_err_fmt("tls unavailable in this build"));
}
DuckRes_arr duck__tls_read(void *p, int64_t max) {
    (void)p;
    (void)max;
    return DUCK_ERR(DuckRes_arr, duck_err_fmt("tls unavailable in this build"));
}
DuckRes_unit duck__tls_write(void *p, const unsigned char *buf, int64_t n) {
    (void)p;
    (void)buf;
    (void)n;
    return DUCK_ERR(DuckRes_unit, duck_err_fmt("tls unavailable in this build"));
}
void duck__tls_free(void *p) { (void)p; }
#endif

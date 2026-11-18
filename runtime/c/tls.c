/* TLS client sessions for `net.tls`.
 *
 * Auk never implements cryptography itself; it drives the platform's TLS stack:
 *  - macOS: Network.framework (an nw_connection with TLS 1.2 or later), wrapped synchronously
 *    with dispatch semaphores to fit the blocking connection API (a task is a thread). Waits
 *    wake every 50 ms so a cancelled task still ends. The certificate check is the system's own
 *    trust evaluation (Security.framework, an SSL policy for the host), run in a verify block so
 *    the reason for a refusal can be reported. A connection reset before the server's
 *    certificate arrived is retried once as a TLS 1.2 fallback (see auk_net_tls).
 *  - elsewhere: OpenSSL 3 or 1.1 (libssl), loaded with dlopen on first use, so nothing is needed
 *    at build time. Without libssl at run time, net.tls is an Err ("tls unavailable: libssl not
 *    found").
 *
 * Verification is always on and cannot be turned off: the server's chain is checked against
 * the system trust store and its certificate against host (SNI is sent for DNS names). A
 * failure is an Err "net.tls <host>:<port>: certificate verification failed: <reason>". */
/* auk: own translation unit (system framework headers) */
#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "auk_rt.h"

/* "net.tls <host>:<port>" into m. */
static void tls_prefix(AukStrBuf *m, const char *host, int64_t port) {
    auk__sb_put_cstr(m, "net.tls ");
    auk__sb_put_cstr(m, host);
    auk__sb_put_cstr(m, ":");
    auk_sb_int(m, port);
}

/* An Err "<prefix><a><b>" (prefix consumed), with code (0: none). */
static AukErr *prefixed(AukStrBuf *prefix, const char *a, const char *b, int code) {
    auk__sb_put_cstr(prefix, a);
    if (b != NULL) {
        auk__sb_put_cstr(prefix, b);
    }
    AukErr *e = auk__err_sb(prefix);
    e->code = code;
    return e;
}

static AukRes_conn tls_conn_err(AukErr *e) {
    AukRes_conn r = {0};
    r.err = e;
    return r;
}

/* Is host a name a certificate can be checked against: an IP address, or a DNS name (labels of
 * letters, digits, '-' and '_', 1 to 63 long, not starting or ending with '-'; at most 253 in
 * all; one trailing dot allowed)? */
static bool valid_host(const char *h) {
    unsigned char addr[16];
    if (inet_pton(AF_INET, h, addr) == 1 || inet_pton(AF_INET6, h, addr) == 1) {
        return true;
    }
    size_t n = strlen(h);
    if (n > 0 && h[n - 1] == '.') {
        n--;
    }
    if (n == 0 || n > 253) {
        return false;
    }
    size_t label = 0;
    for (size_t i = 0; i <= n; i++) {
        char c = i < n ? h[i] : '.';
        if (c == '.') {
            if (label == 0 || label > 63 || h[i - 1] == '-') {
                return false;
            }
            label = 0;
            continue;
        }
        bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-';
        if (!ok || (label == 0 && c == '-')) {
            return false;
        }
        label++;
    }
    return true;
}

/* The checks every backend shares: an Err, or NULL to go on. */
static AukErr *check_args(const char *h, int64_t port) {
    if (!(port > 0 && port <= 65535)) {
        AukStrBuf m = {0};
        tls_prefix(&m, h, port);
        return prefixed(&m, ": invalid port", NULL, 0);
    }
    if (h[0] == 0) {
        AukStrBuf m = {0};
        tls_prefix(&m, h, port);
        return prefixed(&m, ": empty host", NULL, 0);
    }
    if (!valid_host(h)) {
        AukStrBuf m = {0};
        tls_prefix(&m, h, port);
        return prefixed(&m, ": invalid host name", NULL, 0);
    }
    return NULL;
}

#if defined(__APPLE__)
/* =====================================================================
 * macOS: Network.framework
 * ===================================================================== */
#include <Network/Network.h>
#include <Security/Security.h>

typedef struct NwTls {
    nw_connection_t conn;
    dispatch_queue_t q;
    dispatch_semaphore_t ready; /* the first ready / waiting / failed state */
    dispatch_semaphore_t gone;  /* the cancelled state */
    /* written on q only */
    bool reported;
    bool ok;
    bool saw_cert; /* the verify block ran: the server got as far as its certificate */
    int domain;
    int code;
    char why[256]; /* why the trust evaluation failed */
    char *host;
    /* the caller's thread only */
    bool eof;
    bool pending; /* an error that arrived with the last data, reported by the next read */
    int pend_domain;
    int pend_code;
} NwTls;

/* Signal s from a callback; the retain keeps s alive though the waiter may release it. */
static void nw_post(dispatch_semaphore_t s) {
    dispatch_retain(s);
    dispatch_semaphore_signal(s);
    dispatch_release(s);
}

/* Wait for s, waking every 50 ms on a task thread to check for cancellation; false if the
 * task was cancelled (the caller cleans up, then calls auk__check_cancel). */
static bool nw_wait(dispatch_semaphore_t s) {
    if (!auk__on_task()) {
        dispatch_semaphore_wait(s, DISPATCH_TIME_FOREVER);
        return true;
    }
    for (;;) {
        if (dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, 50 * (int64_t)NSEC_PER_MSEC)) == 0) {
            return true;
        }
        if (auk__task_cancelled()) {
            return false;
        }
    }
}

/* The reason of a certificate refusal (a Security.framework error code), or NULL. */
static const char *cert_reason(int code) {
    switch (code) {
    case errSecCertificateExpired:
        return "certificate has expired";
    case errSecCertificateNotValidYet:
        return "certificate is not yet valid";
    case errSecCertificateRevoked:
        return "certificate has been revoked";
    case errSecHostNameMismatch:
        return "certificate does not match the host name";
    case errSecNotTrusted:
    case errSecCreateChainFailed:
        return "certificate is not trusted (self-signed or no trusted root)";
    case errSecInvalidExtendedKeyUsage:
        return "certificate is not valid for a TLS server";
    default:
        return NULL;
    }
}

/* The text of a TLS OSStatus (SecureTransport codes); *verify: about the certificate. */
static const char *tls_status(int code, bool *verify) {
    *verify = true;
    switch (code) {
    case -9807:
        return "invalid certificate chain";
    case -9808:
        return "bad certificate";
    case -9812:
        return "certificate chain ends in an unknown root";
    case -9813:
        return "certificate is not trusted (self-signed or no trusted root)";
    case -9814:
        return "certificate has expired";
    case -9815:
        return "certificate is not yet valid";
    case -9843:
        return "certificate does not match the host name";
    default:
        break;
    }
    *verify = false;
    switch (code) {
    case -9800:
        return "protocol error";
    case -9801:
        return "no cipher suite in common";
    case -9802:
        return "fatal alert from the server";
    case -9805:
        return "the server closed the connection";
    case -9806:
        return "the connection closed during the handshake";
    case -9816:
        return "the server closed the connection without close_notify";
    case -9824:
    case -9836:
        return "the server's TLS version is not supported";
    default:
        return NULL;
    }
}

/* An Err "<prefix>: <reason>" for an nw_error (domain, code); prefix consumed. */
static AukErr *nw_err(AukStrBuf *prefix, int domain, int code) {
    if (domain == nw_error_domain_posix) {
        return prefixed(prefix, ": ", strerror(code), code);
    }
    if (domain == nw_error_domain_dns) {
        auk__sb_put_cstr(prefix, ": cannot resolve the host (DNS error ");
        auk_sb_int(prefix, code);
        return prefixed(prefix, ")", NULL, 0);
    }
    if (domain == nw_error_domain_tls) {
        bool verify;
        const char *what = tls_status(code, &verify);
        if (what != NULL && verify) {
            return prefixed(prefix, ": certificate verification failed: ", what, 0);
        }
        if (what != NULL) {
            return prefixed(prefix, ": TLS error: ", what, 0);
        }
        auk__sb_put_cstr(prefix, ": TLS error (OSStatus ");
        auk_sb_int(prefix, code);
        return prefixed(prefix, ")", NULL, 0);
    }
    return prefixed(prefix, ": connection failed", NULL, 0);
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

/* Resolve host:port first, so a name that doesn't resolve fails as plain TCP does. */
static AukErr *resolve_first(const char *h, const char *ports, int64_t port) {
    struct addrinfo hints;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo *res = NULL;
    int gai = getaddrinfo(h, ports, &hints, &res);
    if (gai != 0) {
        AukStrBuf m = {0};
        tls_prefix(&m, h, port);
        return prefixed(&m, ": ", gai_strerror(gai), 0);
    }
    freeaddrinfo(res);
    return NULL;
}

/* The outcome of a handshake, read on the connection's queue. */
typedef struct NwOutcome {
    bool ok;
    bool saw_cert;
    int domain;
    int code;
    char why[256];
} NwOutcome;

/* Connect to h:ports and run the handshake (waiting for its outcome, cancellably). fallback: the
 * TLS 1.2 retry (see auk_net_tls). */
static NwTls *nw_connect(const char *h, const char *ports, bool fallback, NwOutcome *out) {
    NwTls *t = auk__xcalloc(1, sizeof(NwTls));
    t->q = dispatch_queue_create("auk.net.tls", DISPATCH_QUEUE_SERIAL);
    t->ready = dispatch_semaphore_create(0);
    t->gone = dispatch_semaphore_create(0);
    t->host = auk__xmalloc(strlen(h) + 1);
    memcpy(t->host, h, strlen(h) + 1);
    nw_endpoint_t ep = nw_endpoint_create_host(h, ports);
    /* The endpoint's host is sent as SNI. The verify block runs the system's own evaluation
     * (the system trust store plus an SSL server policy pinned to host), the same check the
     * default does, but it lets us report why a certificate was refused. */
    nw_parameters_t params = nw_parameters_create_secure_tcp(
        ^(nw_protocol_options_t tls) {
          sec_protocol_options_t sec = nw_tls_copy_sec_protocol_options(tls);
          sec_protocol_options_set_min_tls_protocol_version(sec, tls_protocol_version_TLSv12);
          if (fallback) {
              sec_protocol_options_set_max_tls_protocol_version(sec, tls_protocol_version_TLSv12);
              /* TLS_FALLBACK_SCSV (RFC 7507): a server that does speak TLS 1.3 refuses this
               * hello, so forged resets can't downgrade a connection to it */
              sec_protocol_options_set_tls_is_fallback_attempt(sec, true);
          }
          sec_protocol_options_set_verify_block(
              sec,
              ^(sec_protocol_metadata_t md, sec_trust_t trust_ref, sec_protocol_verify_complete_t complete) {
                (void)md;
                t->saw_cert = true;
                SecTrustRef trust = sec_trust_copy_ref(trust_ref);
                CFStringRef name = CFStringCreateWithCString(NULL, t->host, kCFStringEncodingUTF8);
                SecPolicyRef policy = SecPolicyCreateSSL(true, name);
                CFErrorRef err = NULL;
                bool ok = name != NULL && policy != NULL && SecTrustSetPolicies(trust, policy) == errSecSuccess &&
                          SecTrustEvaluateWithError(trust, &err);
                if (!ok) {
                    const char *r = err != NULL ? cert_reason((int)CFErrorGetCode(err)) : NULL;
                    if (r != NULL) {
                        snprintf(t->why, sizeof t->why, "%s", r);
                    } else {
                        snprintf(t->why, sizeof t->why, "the system trust evaluation failed");
                        CFStringRef d = err != NULL ? CFErrorCopyDescription(err) : NULL;
                        if (d != NULL) {
                            CFStringGetCString(d, t->why, sizeof t->why, kCFStringEncodingUTF8);
                            CFRelease(d);
                        }
                    }
                }
                if (err != NULL) {
                    CFRelease(err);
                }
                if (policy != NULL) {
                    CFRelease(policy);
                }
                if (name != NULL) {
                    CFRelease(name);
                }
                CFRelease(trust);
                complete(ok);
              },
              t->q);
          nw_release(sec);
        },
        ^(nw_protocol_options_t tcp) {
          nw_tcp_options_set_connection_timeout(tcp, 30);
        });
    t->conn = nw_connection_create(ep, params);
    nw_release(ep);
    nw_release(params);
    nw_connection_set_queue(t->conn, t->q);
    nw_connection_set_state_changed_handler(t->conn, ^(nw_connection_state_t st, nw_error_t err) {
      if (st == nw_connection_state_cancelled) {
          nw_post(t->gone);
          return;
      }
      bool done = st == nw_connection_state_ready || st == nw_connection_state_waiting || st == nw_connection_state_failed;
      if (!done || t->reported) {
          return;
      }
      t->reported = true;
      t->ok = st == nw_connection_state_ready;
      if (err != NULL) {
          t->domain = (int)nw_error_get_error_domain(err);
          t->code = nw_error_get_error_code(err);
      }
      nw_post(t->ready);
    });
    nw_connection_start(t->conn);
    if (!nw_wait(t->ready)) {
        nw_tls_free(t);
        auk__check_cancel("a blocking call");
    }
    /* read the outcome on the queue */
    dispatch_sync(t->q, ^{
      memcpy(out->why, t->why, sizeof t->why);
      out->ok = t->ok;
      out->saw_cert = t->saw_cert;
      out->domain = t->domain;
      out->code = t->code;
    });
    return t;
}

AUK_API AukRes_conn auk_net_tls(const AukStr *host, int64_t port) {
    const char *h = auk_str_cstr(host);
    AukErr *bad = check_args(h, port);
    if (bad != NULL) {
        return tls_conn_err(bad);
    }
    char ports[24];
    snprintf(ports, sizeof ports, "%lld", (long long)port);
    bad = resolve_first(h, ports, port);
    if (bad != NULL) {
        return tls_conn_err(bad);
    }
    NwOutcome o;
    NwTls *t = nw_connect(h, ports, false, &o);
    /* Network.framework's TLS 1.3 hello offers a post-quantum key share (X25519MLKEM768) and
     * is about 1.5 KB, two TCP segments; some servers and middleboxes reset such a connection,
     * some of the time (badssl.com's hosts: about half the attempts; OpenSSL offering the same
     * group sees the same resets, with X25519 alone none). Network.framework has no setting for
     * the key shares, so a reset before the server's certificate arrived is retried once as a
     * TLS 1.2 hello (no key share, one segment), marked as a fallback. */
    if (!o.ok && !o.saw_cert && o.domain == nw_error_domain_posix && o.code == ECONNRESET) {
        nw_tls_free(t);
        t = nw_connect(h, ports, true, &o);
    }
    if (!o.ok) {
        nw_tls_free(t);
        AukStrBuf m = {0};
        tls_prefix(&m, h, port);
        if (o.why[0] != 0) {
            return tls_conn_err(prefixed(&m, ": certificate verification failed: ", o.why, 0));
        }
        return tls_conn_err(nw_err(&m, o.domain, o.code));
    }
    AukConn *c = auk__conn_new(-1);
    c->tls = t;
    AukRes_conn r = {0};
    r.ok = true;
    r.val = c;
    return r;
}

/* Errors that just mean the peer has closed the stream. */
static bool nw_is_eof(int domain, int code) {
    return (domain == nw_error_domain_posix && code == ENODATA) || (domain == nw_error_domain_tls && (code == -9805 || code == -9816));
}

/* One receive or send in flight: shared by the waiting thread and the completion block (two
 * references), so a cancelled wait can walk away from it. */
typedef struct NwOp {
    _Atomic int refs;
    dispatch_semaphore_t done;
    uint8_t *buf;
    size_t n;
    bool fin;
    bool failed;
    int domain;
    int code;
} NwOp;

static NwOp *nw_op_new(void) {
    NwOp *op = auk__xcalloc(1, sizeof(NwOp));
    atomic_store(&op->refs, 2);
    op->done = dispatch_semaphore_create(0);
    return op;
}

static void nw_op_drop(NwOp *op) {
    if (atomic_fetch_sub(&op->refs, 1) == 1) {
        dispatch_release(op->done);
        free(op->buf);
        free(op);
    }
}

AukRes_arr auk__tls_read(void *p, int64_t max) {
    NwTls *t = p;
    AukRes_arr r = {0};
    if (t->pending) {
        t->pending = false;
        t->eof = true;
        AukStrBuf m = {0};
        auk__sb_put_cstr(&m, "net read");
        r.err = nw_err(&m, t->pend_domain, t->pend_code);
        return r;
    }
    if (t->eof) {
        r.ok = true;
        r.val = auk__bytes_to_arr(NULL, 0);
        return r;
    }
    NwOp *op = nw_op_new();
    nw_connection_receive(t->conn, 1, (uint32_t)max, ^(dispatch_data_t content, nw_content_context_t ctx, bool complete, nw_error_t err) {
      (void)ctx;
      if (content != NULL) {
          op->n = dispatch_data_get_size(content);
          op->buf = auk__xmalloc(op->n != 0 ? op->n : 1);
          dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t off, const void *bytes, size_t len) {
            (void)region;
            memcpy(op->buf + off, bytes, len);
            return true;
          });
      }
      op->fin = complete;
      if (err != NULL) {
          op->failed = true;
          op->domain = (int)nw_error_get_error_domain(err);
          op->code = nw_error_get_error_code(err);
      }
      nw_post(op->done);
      nw_op_drop(op);
    });
    if (!nw_wait(op->done)) {
        nw_op_drop(op);
        auk__check_cancel("a blocking call");
    }
    if (op->failed && !nw_is_eof(op->domain, op->code)) {
        if (op->n == 0) {
            t->eof = true;
            if (op->domain == nw_error_domain_posix && op->code != 0) {
                r.err = auk__err_errno("net read", NULL, op->code);
            } else {
                AukStrBuf m = {0};
                auk__sb_put_cstr(&m, "net read");
                r.err = nw_err(&m, op->domain, op->code);
            }
            nw_op_drop(op);
            return r;
        }
        t->pending = true;
        t->pend_domain = op->domain;
        t->pend_code = op->code;
    } else if (op->fin || op->failed || op->n == 0) {
        t->eof = true;
    }
    r.ok = true;
    r.val = auk__bytes_to_arr(op->buf, (int64_t)op->n);
    nw_op_drop(op);
    return r;
}

AukRes_unit auk__tls_write(void *p, const uint8_t *buf, int64_t n) {
    NwTls *t = p;
    AukRes_unit r = {0};
    if (n <= 0) {
        r.ok = true;
        return r;
    }
    /* DISPATCH_DATA_DESTRUCTOR_DEFAULT copies buf */
    dispatch_data_t data = dispatch_data_create(buf, (size_t)n, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    NwOp *op = nw_op_new();
    nw_connection_send(t->conn, data, NW_CONNECTION_DEFAULT_STREAM_CONTEXT, false, ^(nw_error_t err) {
      if (err != NULL) {
          op->failed = true;
          op->domain = (int)nw_error_get_error_domain(err);
          op->code = nw_error_get_error_code(err);
      }
      nw_post(op->done);
      nw_op_drop(op);
    });
    dispatch_release(data);
    if (!nw_wait(op->done)) {
        nw_op_drop(op);
        auk__check_cancel("a blocking call");
    }
    if (op->failed) {
        if (op->domain == nw_error_domain_posix && op->code != 0) {
            r.err = auk__err_errno("net write", NULL, op->code);
        } else {
            AukStrBuf m = {0};
            auk__sb_put_cstr(&m, "net write");
            r.err = nw_err(&m, op->domain, op->code);
        }
    } else {
        r.ok = true;
    }
    nw_op_drop(op);
    return r;
}

/* Closes the session (the framework sends close_notify) and frees it. */
void auk__tls_free(void *p) {
    if (p != NULL) {
        nw_tls_free(p);
    }
}

#else
/* =====================================================================
 * Elsewhere: OpenSSL through dlopen
 * ===================================================================== */
#include <dlfcn.h>
#include <pthread.h>

typedef struct ssl_st SSL;
typedef struct ssl_ctx_st SSL_CTX;
typedef struct ssl_method_st SSL_METHOD;

/* The libssl (and, through its dependencies, libcrypto) entry points used here. */
typedef struct SslApi {
    const SSL_METHOD *(*TLS_client_method)(void);
    SSL_CTX *(*SSL_CTX_new)(const SSL_METHOD *m);
    int (*SSL_CTX_set_default_verify_paths)(SSL_CTX *ctx);
    void (*SSL_CTX_set_verify)(SSL_CTX *ctx, int mode, void *cb);
    long (*SSL_CTX_ctrl)(SSL_CTX *ctx, int cmd, long larg, void *parg);
    SSL *(*SSL_new)(SSL_CTX *ctx);
    void (*SSL_free)(SSL *s);
    int (*SSL_set_fd)(SSL *s, int fd);
    long (*SSL_ctrl)(SSL *s, int cmd, long larg, void *parg);
    int (*SSL_set1_host)(SSL *s, const char *host);
    int (*SSL_connect)(SSL *s);
    int (*SSL_read)(SSL *s, void *buf, int n);
    int (*SSL_write)(SSL *s, const void *buf, int n);
    int (*SSL_shutdown)(SSL *s);
    int (*SSL_get_error)(const SSL *s, int ret);
    long (*SSL_get_verify_result)(const SSL *s);
    const char *(*X509_verify_cert_error_string)(long n);
    unsigned long (*ERR_get_error)(void);
    void (*ERR_error_string_n)(unsigned long e, char *buf, size_t len);
    void (*ERR_clear_error)(void);
} SslApi;

static SslApi ssl;
static SSL_CTX *ssl_ctx;
static const char *ssl_unavailable;
static pthread_once_t ssl_once = PTHREAD_ONCE_INIT;

enum {
    SSL_VERIFY_PEER = 1,
    SSL_CTRL_SET_MIN_PROTO_VERSION = 123,
    SSL_CTRL_SET_TLSEXT_HOSTNAME = 55,
    TLSEXT_NAMETYPE_host_name = 0,
    TLS1_2_VERSION = 0x0303,
    SSL_ERROR_SSL = 1,
    SSL_ERROR_WANT_READ = 2,
    SSL_ERROR_WANT_WRITE = 3,
    SSL_ERROR_SYSCALL = 5,
    SSL_ERROR_ZERO_RETURN = 6,
    X509_V_OK = 0,
    X509_V_ERR_CERT_NOT_YET_VALID = 9,
    X509_V_ERR_CERT_HAS_EXPIRED = 10,
    X509_V_ERR_DEPTH_ZERO_SELF_SIGNED_CERT = 18,
    X509_V_ERR_SELF_SIGNED_CERT_IN_CHAIN = 19,
    X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT_LOCALLY = 20,
    X509_V_ERR_CERT_REVOKED = 23,
    X509_V_ERR_INVALID_PURPOSE = 26,
    X509_V_ERR_HOSTNAME_MISMATCH = 62,
    X509_V_ERR_IP_ADDRESS_MISMATCH = 64,
};

static void *sym(void *lib, const char *name, bool *ok) {
    void *p = dlsym(lib, name);
    if (p == NULL) {
        *ok = false;
    }
    return p;
}

static void ssl_load(void) {
    const char *names[] = {"libssl.so.3", "libssl.so.1.1", "libssl.so", "libssl.3.dylib", NULL};
    void *lib = NULL;
    for (int i = 0; names[i] != NULL && lib == NULL; i++) {
        lib = dlopen(names[i], RTLD_NOW | RTLD_LOCAL);
    }
    if (lib == NULL) {
        ssl_unavailable = "tls unavailable: libssl not found";
        return;
    }
    bool ok = true;
    ssl.TLS_client_method = sym(lib, "TLS_client_method", &ok);
    ssl.SSL_CTX_new = sym(lib, "SSL_CTX_new", &ok);
    ssl.SSL_CTX_set_default_verify_paths = sym(lib, "SSL_CTX_set_default_verify_paths", &ok);
    ssl.SSL_CTX_set_verify = sym(lib, "SSL_CTX_set_verify", &ok);
    ssl.SSL_CTX_ctrl = sym(lib, "SSL_CTX_ctrl", &ok);
    ssl.SSL_new = sym(lib, "SSL_new", &ok);
    ssl.SSL_free = sym(lib, "SSL_free", &ok);
    ssl.SSL_set_fd = sym(lib, "SSL_set_fd", &ok);
    ssl.SSL_ctrl = sym(lib, "SSL_ctrl", &ok);
    ssl.SSL_set1_host = sym(lib, "SSL_set1_host", &ok);
    ssl.SSL_connect = sym(lib, "SSL_connect", &ok);
    ssl.SSL_read = sym(lib, "SSL_read", &ok);
    ssl.SSL_write = sym(lib, "SSL_write", &ok);
    ssl.SSL_shutdown = sym(lib, "SSL_shutdown", &ok);
    ssl.SSL_get_error = sym(lib, "SSL_get_error", &ok);
    ssl.SSL_get_verify_result = sym(lib, "SSL_get_verify_result", &ok);
    ssl.X509_verify_cert_error_string = sym(lib, "X509_verify_cert_error_string", &ok);
    ssl.ERR_get_error = sym(lib, "ERR_get_error", &ok);
    ssl.ERR_error_string_n = sym(lib, "ERR_error_string_n", &ok);
    ssl.ERR_clear_error = sym(lib, "ERR_clear_error", &ok);
    if (!ok) {
        ssl_unavailable = "tls unavailable: libssl is missing functions (OpenSSL 1.1 or later is needed)";
        return;
    }
    ssl_ctx = ssl.SSL_CTX_new(ssl.TLS_client_method());
    if (ssl_ctx == NULL || ssl.SSL_CTX_set_default_verify_paths(ssl_ctx) != 1) {
        ssl_unavailable = "tls unavailable: cannot set up OpenSSL";
        return;
    }
    ssl.SSL_CTX_set_verify(ssl_ctx, SSL_VERIFY_PEER, NULL);
    ssl.SSL_CTX_ctrl(ssl_ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_2_VERSION, NULL);
}

static const char *x509_reason(long v) {
    switch (v) {
    case X509_V_ERR_CERT_HAS_EXPIRED:
        return "certificate has expired";
    case X509_V_ERR_CERT_NOT_YET_VALID:
        return "certificate is not yet valid";
    case X509_V_ERR_CERT_REVOKED:
        return "certificate has been revoked";
    case X509_V_ERR_DEPTH_ZERO_SELF_SIGNED_CERT:
    case X509_V_ERR_SELF_SIGNED_CERT_IN_CHAIN:
    case X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT_LOCALLY:
        return "certificate is not trusted (self-signed or no trusted root)";
    case X509_V_ERR_HOSTNAME_MISMATCH:
    case X509_V_ERR_IP_ADDRESS_MISMATCH:
        return "certificate does not match the host name";
    case X509_V_ERR_INVALID_PURPOSE:
        return "certificate is not valid for a TLS server";
    default:
        return ssl.X509_verify_cert_error_string(v);
    }
}

typedef struct SslTls {
    SSL *s;
    int fd;
    bool eof;
} SslTls;

/* An Err for a failed SSL call (ret, from SSL_get_error) after "<prefix>"; prefix consumed. */
static AukErr *ssl_err(AukStrBuf *prefix, SSL *s, int ret, int saved_errno) {
    int e = ssl.SSL_get_error(s, ret);
    if (e == SSL_ERROR_SYSCALL && saved_errno != 0) {
        return prefixed(prefix, ": ", strerror(saved_errno), saved_errno);
    }
    if (e == SSL_ERROR_SYSCALL || e == SSL_ERROR_ZERO_RETURN) {
        return prefixed(prefix, ": TLS error: the connection closed during the handshake", NULL, 0);
    }
    long v = ssl.SSL_get_verify_result(s);
    if (v != X509_V_OK) {
        return prefixed(prefix, ": certificate verification failed: ", x509_reason(v), 0);
    }
    unsigned long code = ssl.ERR_get_error();
    char buf[256] = "protocol error";
    if (code != 0) {
        ssl.ERR_error_string_n(code, buf, sizeof buf);
    }
    return prefixed(prefix, ": TLS error: ", buf, 0);
}

/* Run op (connect, read or write) on t until it stops wanting I/O; its result, or -1 with
 * *saved the errno. */
static int ssl_drive(SslTls *t, int which, void *buf, int n, int *saved) {
    for (;;) {
        ssl.ERR_clear_error();
        errno = 0;
        int r = which == 0 ? ssl.SSL_connect(t->s) : which == 1 ? ssl.SSL_read(t->s, buf, n) : ssl.SSL_write(t->s, buf, n);
        *saved = errno;
        if (r > 0) {
            return r;
        }
        int e = ssl.SSL_get_error(t->s, r);
        if (e == SSL_ERROR_WANT_READ) {
            auk__wait_fd(t->fd, false);
        } else if (e == SSL_ERROR_WANT_WRITE) {
            auk__wait_fd(t->fd, true);
        } else if (e == SSL_ERROR_SYSCALL && *saved == EINTR) {
            continue;
        } else {
            return r;
        }
    }
}

AUK_API AukRes_conn auk_net_tls(const AukStr *host, int64_t port) {
    const char *h = auk_str_cstr(host);
    AukErr *bad = check_args(h, port);
    if (bad != NULL) {
        return tls_conn_err(bad);
    }
    pthread_once(&ssl_once, ssl_load);
    if (ssl_unavailable != NULL) {
        AukStrBuf m = {0};
        tls_prefix(&m, h, port);
        return tls_conn_err(prefixed(&m, ": ", ssl_unavailable, 0));
    }
    char ports[24];
    snprintf(ports, sizeof ports, "%lld", (long long)port);
    const char *why;
    int code;
    int fd = auk__tcp_connect(h, ports, &why, &code);
    if (fd < 0) {
        AukStrBuf m = {0};
        tls_prefix(&m, h, port);
        return tls_conn_err(prefixed(&m, ": ", why, code));
    }
    SslTls *t = auk__xcalloc(1, sizeof(SslTls));
    t->fd = fd;
    t->s = ssl.SSL_new(ssl_ctx);
    ssl.SSL_set_fd(t->s, fd);
    unsigned char addr[16];
    bool ip = inet_pton(AF_INET, h, addr) == 1 || inet_pton(AF_INET6, h, addr) == 1;
    if (!ip) {
        /* SNI for DNS names only */
        ssl.SSL_ctrl(t->s, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_host_name, (void *)h);
    }
    ssl.SSL_set1_host(t->s, h);
    int saved = 0;
    int r = ssl_drive(t, 0, NULL, 0, &saved);
    if (r <= 0) {
        AukStrBuf m = {0};
        tls_prefix(&m, h, port);
        AukErr *e = ssl_err(&m, t->s, r, saved);
        ssl.SSL_free(t->s);
        close(fd);
        free(t);
        return tls_conn_err(e);
    }
    AukConn *c = auk__conn_new(fd);
    c->tls = t;
    AukRes_conn res = {0};
    res.ok = true;
    res.val = c;
    return res;
}

AukRes_arr auk__tls_read(void *p, int64_t max) {
    SslTls *t = p;
    AukRes_arr res = {0};
    if (t->eof) {
        res.ok = true;
        res.val = auk__bytes_to_arr(NULL, 0);
        return res;
    }
    uint8_t *buf = auk__xmalloc((size_t)max);
    int saved = 0;
    int r = ssl_drive(t, 1, buf, (int)max, &saved);
    if (r <= 0) {
        int e = ssl.SSL_get_error(t->s, r);
        if (e == SSL_ERROR_ZERO_RETURN || (e == SSL_ERROR_SYSCALL && saved == 0)) {
            /* close_notify, or the peer closed the stream without one: EOF */
            t->eof = true;
            res.ok = true;
            res.val = auk__bytes_to_arr(NULL, 0);
        } else if (e == SSL_ERROR_SYSCALL) {
            res.err = auk__err_errno("net read", NULL, saved);
        } else {
            AukStrBuf m = {0};
            auk__sb_put_cstr(&m, "net read");
            res.err = ssl_err(&m, t->s, r, saved);
        }
        free(buf);
        return res;
    }
    res.ok = true;
    res.val = auk__bytes_to_arr(buf, r);
    free(buf);
    return res;
}

AukRes_unit auk__tls_write(void *p, const uint8_t *buf, int64_t n) {
    SslTls *t = p;
    AukRes_unit res = {0};
    int64_t off = 0;
    while (off < n) {
        int chunk = n - off > (1 << 30) ? (1 << 30) : (int)(n - off);
        int saved = 0;
        int r = ssl_drive(t, 2, (void *)(buf + off), chunk, &saved);
        if (r <= 0) {
            if (ssl.SSL_get_error(t->s, r) == SSL_ERROR_SYSCALL && saved != 0) {
                res.err = auk__err_errno("net write", NULL, saved);
            } else {
                AukStrBuf m = {0};
                auk__sb_put_cstr(&m, "net write");
                res.err = ssl_err(&m, t->s, r, saved);
            }
            return res;
        }
        off += r;
    }
    res.ok = true;
    return res;
}

/* Closes the session (best-effort close_notify; the caller then closes the socket) and frees
 * it. */
void auk__tls_free(void *p) {
    SslTls *t = p;
    if (t == NULL) {
        return;
    }
    ssl.SSL_shutdown(t->s);
    ssl.SSL_free(t->s);
    free(t);
}
#endif

/* net.listen / accept, and net.tls (runtime/c/tls.c).
 *
 * The TLS tests against real hosts run only when the network is usable: AUK_NET_TESTS=1 forces
 * them, AUK_NET_TESTS=0 skips them, and unset they run if example.com:443 answers within 3
 * seconds. The rest need no network. */
#include "test.h"

#include <pthread.h>

/* Bytes of an owned array as text (kept), then release the array. */
static char *arr_text(AukArr *a) {
    int64_t n = auk_arr_len(a);
    char *t = t_keep(malloc((size_t)n + 1));
    for (int64_t i = 0; i < n; i++) t[i] = (char)int_elems(a)[i];
    t[n] = 0;
    rel(a);
    return t;
}

static AukArr *bytes_of(const char *t) {
    AukStr *x = s(t);
    AukArr *a = auk_str_bytes(x);
    rel(x);
    return a;
}

/* ---- listen / accept ---------------------------------------------------------------------- */

/* The client side: connect, send "ping", read until EOF (no CHECKs: it runs on a thread). */
typedef struct Client {
    int64_t port;
    bool ok;   /* reached EOF */
    char got[256];
    size_t n;
} Client;

static void *client_main(void *arg) {
    Client *cl = arg;
    AukStr *host = s("127.0.0.1");
    AukRes_conn c = auk_net_tcp(host, cl->port);
    rel(host);
    if (!c.ok) {
        rel(c.err);
        return NULL;
    }
    AukArr *msg = bytes_of("ping");
    AukRes_unit w = auk_conn_write(c.val, msg);
    rel(msg);
    if (w.ok) {
        for (;;) {
            AukRes_arr r = auk_conn_read(c.val, 16);
            if (!r.ok) {
                rel(r.err);
                break;
            }
            int64_t n = auk_arr_len(r.val);
            for (int64_t i = 0; i < n && cl->n < sizeof cl->got - 1; i++) cl->got[cl->n++] = (char)int_elems(r.val)[i];
            rel(r.val);
            if (n == 0) {
                cl->ok = true;
                break;
            }
        }
    } else {
        rel(w.err);
    }
    cl->got[cl->n] = 0;
    rel(c.val);
    return NULL;
}

static void net_listen_accept_echo(void) {
    AukStr *host = s("127.0.0.1");
    AukRes_listener l = auk_net_listen(host, 0);
    CHECK(l.ok);
    int64_t port = auk_listener_port(l.val);
    CHECK(port > 0 && port <= 65535);
    Client cl;
    memset(&cl, 0, sizeof cl);
    cl.port = port;
    pthread_t th;
    CHECK(pthread_create(&th, NULL, client_main, &cl) == 0);
    AukRes_conn c = auk_listener_accept(l.val);
    CHECK(c.ok);
    AukRes_arr r = auk_conn_read(c.val, 4);
    CHECK(r.ok);
    CHECK_TEXT(arr_text(r.val), "ping");
    AukArr *reply = bytes_of("echo:ping");
    CHECK(auk_conn_write(c.val, reply).ok);
    rel(reply);
    auk_conn_close(c.val);
    rel(c.val);
    pthread_join(th, NULL);
    CHECK(cl.ok);
    CHECK_TEXT(cl.got, "echo:ping");

    /* the port is taken while the listener is open */
    AukRes_listener again = auk_net_listen(host, port);
    CHECK(!again.ok);
    CHECK_HAS(err_text(again.err), "net.listen 127.0.0.1:");

    auk_listener_close(l.val);
    CHECK(auk_listener_port(l.val) == port);
    c = auk_listener_accept(l.val);
    CHECK(!c.ok);
    CHECK_HAS(err_text(c.err), "listener is closed");
    rel(l.val);

    l = auk_net_listen(host, 70000);
    CHECK(!l.ok);
    CHECK_HAS(err_text(l.err), "invalid port");
    rel(host);

    /* "" listens on every interface */
    AukStr *any = s("");
    l = auk_net_listen(any, 0);
    CHECK(l.ok);
    CHECK(auk_listener_port(l.val) > 0);
    rel(l.val); /* closes */
    rel(any);
}

/* ---- tls without the network ------------------------------------------------------------ */

static void *plain_server(void *arg) {
    AukListener *l = arg;
    AukRes_conn c = auk_listener_accept(l);
    if (!c.ok) {
        rel(c.err);
        return NULL;
    }
    AukArr *junk = bytes_of("HTTP/1.0 400 Bad Request\r\n\r\nnot tls\n");
    AukRes_arr r = auk_conn_read(c.val, 512); /* the ClientHello */
    if (r.ok)
        rel(r.val);
    else
        rel(r.err);
    AukRes_unit w = auk_conn_write(c.val, junk);
    if (!w.ok) rel(w.err);
    rel(junk);
    rel(c.val);
    return NULL;
}

static void net_tls_local_failures(void) {
    AukStr *host = s("127.0.0.1");
    AukRes_conn c = auk_net_tls(host, 0);
    CHECK(!c.ok);
    CHECK_HAS(err_text(c.err), "invalid port");

    /* a plain-TCP server: the handshake fails with an Err (no hang, no crash) */
    AukRes_listener l = auk_net_listen(host, 0);
    CHECK(l.ok);
    pthread_t th;
    CHECK(pthread_create(&th, NULL, plain_server, l.val) == 0);
    c = auk_net_tls(host, auk_listener_port(l.val));
    CHECK(!c.ok);
    char *m = err_text(c.err);
    if (strstr(m, "127.0.0.1:") == NULL && strstr(m, "tls unavailable") == NULL)
        t_fail(__FILE__, __LINE__, "unexpected error: %s", m);
    pthread_join(th, NULL);
    rel(l.val);
    rel(host);
}

/* ---- tls against real hosts ------------------------------------------------------------------ */

/* net.tls to host must fail certificate verification, every time: three attempts. (The
 * badssl.com servers reset about half of the connections that offer Network.framework's
 * post-quantum TLS 1.3 key share, before sending their certificate; tls.c retries those as
 * TLS 1.2, and this checks that no reset gets through.) */
static void expect_bad_cert(const char *file, int line, const char *host_name) {
    AukStr *host = s(host_name);
    for (int i = 0; i < 3; i++) {
        AukRes_conn c = auk_net_tls(host, 443);
        if (c.ok) {
            rel(c.val);
            rel(host);
            t_fail(file, line, "net.tls %s: connected despite a bad certificate", host_name);
        }
        char *m = err_text(c.err);
        if (strstr(m, "certificate verification failed") == NULL) {
            rel(host);
            t_fail(file, line, "net.tls %s (attempt %d): want a certificate error, got: %s", host_name, i + 1, m);
        }
    }
    rel(host);
}
#define EXPECT_BAD_CERT(h) expect_bad_cert(__FILE__, __LINE__, (h))

static void net_tls_real_hosts(void) {
    if (!net_tests()) {
        fprintf(stderr, "note: net_tls_real_hosts skipped (set AUK_NET_TESTS=1 to reach real hosts)\n");
        return;
    }
    AukStr *host = s("example.com");
    AukRes_conn c = auk_net_tls(host, 443);
    if (!c.ok) {
        char *m = err_text(c.err);
        rel(host);
        t_fail(__FILE__, __LINE__, "net.tls example.com: %s", m);
    }
    AukArr *req = bytes_of("GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n");
    CHECK(auk_conn_write(c.val, req).ok);
    rel(req);
    AukArr *all = auk_arr_new(&auk_ops_int, 0);
    for (;;) {
        AukRes_arr r = auk_conn_read(c.val, 4096);
        CHECK(r.ok);
        int64_t n = auk_arr_len(r.val);
        auk_arr_extend(&all, r.val);
        rel(r.val);
        if (n == 0) break;
    }
    AukRes_arr more = auk_conn_read(c.val, 10); /* still empty after the end */
    CHECK(more.ok && auk_arr_len(more.val) == 0);
    rel(more.val);
    char *t = arr_text(all);
    if (strncmp(t, "HTTP/1.1 200", 12) != 0) t_fail(__FILE__, __LINE__, "%.64s", t);
    auk_conn_close(c.val);
    AukRes_arr after = auk_conn_read(c.val, 10);
    CHECK(!after.ok);
    rel(after.err);
    rel(c.val);
    rel(host);

    EXPECT_BAD_CERT("expired.badssl.com");
    EXPECT_BAD_CERT("wrong.host.badssl.com");
    EXPECT_BAD_CERT("self-signed.badssl.com");
    EXPECT_BAD_CERT("untrusted-root.badssl.com");
}

const TestCase net_tests_list[] = {
    {"net_listen_accept_echo", net_listen_accept_echo},
    {"net_tls_local_failures", net_tls_local_failures},
    {"net_tls_real_hosts", net_tls_real_hosts},
    {NULL, NULL},
};

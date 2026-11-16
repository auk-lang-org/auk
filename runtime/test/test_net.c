/* net.listen / accept, and net.tls (runtime/tls.c).
 *
 * The TLS tests against real hosts run only when DUCK_NET_TESTS=1 (tests/runtime.rs sets it
 * when the network is reachable); the rest need no network. */
#include "harness.h"

#include <pthread.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <unistd.h>

/* Bytes of an owned array as a C string (into buf), then release the array. */
static const char *arr_text(DuckArr *a, char *buf, size_t n) {
    int64_t len = duck_arr_len(a);
    const int64_t *d = duck_arr_data(a);
    size_t i = 0;
    for (; i + 1 < n && (int64_t)i < len; i++) buf[i] = (char)d[i];
    buf[i] = 0;
    duck_release(a);
    return buf;
}

/* Does the (owned) error's text contain needle? Releases the error. */
static bool err_has(DuckErr *e, const char *needle, char *out, size_t n) {
    DuckStr *s = duck_err_show(e);
    snprintf(out, n, "%s", duck_str_cstr(s));
    bool r = strstr(duck_str_cstr(s), needle) != NULL;
    duck_release(s);
    duck_release(e);
    return r;
}

static DuckArr *bytes_of(const char *text) {
    DuckStr *s = duck_str_lit(text);
    DuckArr *a = duck_str_bytes(s);
    duck_release(s);
    return a;
}

/* ---- listen / accept ----------------------------------------------------- */

typedef struct {
    int64_t port;
    char got[64];
    bool ok;
} Client;

static void *client_main(void *p) {
    Client *cl = p;
    DuckStr *host = duck_str_lit("127.0.0.1");
    DuckRes_conn c = duck_net_tcp(host, cl->port);
    duck_release(host);
    if (!c.ok) {
        duck_release(c.err);
        return NULL;
    }
    DuckArr *msg = bytes_of("ping");
    DuckRes_unit w = duck_conn_write(c.val, msg);
    duck_release(msg);
    size_t len = 0;
    while (w.ok) {
        DuckRes_arr r = duck_conn_read(c.val, 16);
        if (!r.ok) {
            duck_release(r.err);
            break;
        }
        int64_t n = duck_arr_len(r.val);
        const int64_t *d = duck_arr_data(r.val);
        for (int64_t i = 0; i < n && len + 1 < sizeof cl->got; i++) cl->got[len++] = (char)d[i];
        duck_release(r.val);
        if (n == 0) {
            cl->ok = true;
            break;
        }
    }
    cl->got[len] = 0;
    duck_release(c.val);
    return NULL;
}

TEST(net_listen_accept_echo) {
    DuckStr *host = S("127.0.0.1");
    DuckRes_listener l = duck_net_listen(host, 0);
    CHECK(l.ok);
    int64_t port = duck_listener_port(l.val);
    CHECK(port > 0 && port <= 65535);
    Client cl = {.port = port};
    pthread_t th;
    pthread_create(&th, NULL, client_main, &cl);
    DuckRes_conn c = duck_listener_accept(l.val);
    CHECK(c.ok);
    DuckRes_arr r = duck_conn_read(c.val, 4);
    CHECK(r.ok);
    char buf[64];
    CHECK(strcmp(arr_text(r.val, buf, sizeof buf), "ping") == 0);
    DuckArr *reply = bytes_of("echo:ping");
    CHECK(duck_conn_write(c.val, reply).ok);
    duck_release(reply);
    duck_conn_close(c.val);
    duck_release(c.val);
    pthread_join(th, NULL);
    CHECK(cl.ok);
    CHECK(strcmp(cl.got, "echo:ping") == 0);

    /* the port is taken while the listener is open */
    DuckRes_listener again = duck_net_listen(host, port);
    CHECK(!again.ok);
    CHECK(err_has(again.err, "net.listen 127.0.0.1:", buf, sizeof buf));

    duck_listener_close(l.val);
    CHECK(duck_listener_port(l.val) == port);
    c = duck_listener_accept(l.val);
    CHECK(!c.ok);
    CHECK(err_has(c.err, "listener is closed", buf, sizeof buf));
    duck_release(l.val);

    l = duck_net_listen(host, 70000);
    CHECK(!l.ok);
    CHECK(err_has(l.err, "invalid port", buf, sizeof buf));
    duck_release(host);

    /* "" listens on every interface */
    DuckStr *any = S("");
    l = duck_net_listen(any, 0);
    CHECK(l.ok);
    CHECK(duck_listener_port(l.val) > 0);
    duck_release(l.val); /* closes */
    duck_release(any);
}

/* ---- tls without the network --------------------------------------------- */

static void *plain_server(void *p) {
    DuckListener *l = p;
    DuckRes_conn c = duck_listener_accept(l);
    if (!c.ok) {
        duck_release(c.err);
        return NULL;
    }
    DuckArr *junk = bytes_of("HTTP/1.0 400 Bad Request\r\n\r\nnot tls\n");
    DuckRes_arr r = duck_conn_read(c.val, 512); /* the ClientHello */
    if (r.ok) duck_release(r.val);
    else duck_release(r.err);
    DuckRes_unit w = duck_conn_write(c.val, junk);
    if (!w.ok) duck_release(w.err);
    duck_release(junk);
    duck_release(c.val);
    return NULL;
}

TEST(net_tls_local_failures) {
    char buf[512];
    DuckStr *host = S("127.0.0.1");
    DuckRes_conn c = duck_net_tls(host, 0);
    CHECK(!c.ok);
    CHECK(err_has(c.err, "invalid port", buf, sizeof buf));

    /* a plain-TCP server: the handshake fails with an Err (no hang, no crash) */
    DuckRes_listener l = duck_net_listen(host, 0);
    CHECK(l.ok);
    pthread_t th;
    pthread_create(&th, NULL, plain_server, l.val);
    c = duck_net_tls(host, duck_listener_port(l.val));
    CHECK(!c.ok);
    CHECK(err_has(c.err, "127.0.0.1:", buf, sizeof buf) || strstr(buf, "tls unavailable"));
    pthread_join(th, NULL);
    duck_release(l.val);
    duck_release(host);
}

/* ---- tls against real hosts (DUCK_NET_TESTS=1) --------------------------- */

static bool net_tests(const char *name) {
    const char *v = getenv("DUCK_NET_TESTS");
    if (v && strcmp(v, "1") == 0) return true;
    printf("note: %s skipped (set DUCK_NET_TESTS=1 to reach real hosts)\n", name);
    return false;
}

/* net.tls to host must fail certificate verification. Retries a couple of times: the
 * badssl.com servers sometimes reset a connection before sending their certificate. */
static void expect_bad_cert(const char *host_name) {
    char buf[512] = "";
    DuckStr *host = duck_str_lit(host_name);
    bool cert = false;
    for (int i = 0; i < 4 && !cert; i++) {
        DuckRes_conn c = duck_net_tls(host, 443);
        if (c.ok) {
            duck_release(c.val);
            duck_release(host);
            th_fail(__FILE__, __LINE__, "net.tls %s: connected despite a bad certificate", host_name);
        }
        cert = err_has(c.err, "certificate verification failed", buf, sizeof buf);
    }
    duck_release(host);
    if (!cert) th_fail(__FILE__, __LINE__, "net.tls %s: want a certificate error, got: %s", host_name, buf);
}

TEST(net_tls_real_hosts) {
    if (!net_tests("net_tls_real_hosts")) return;
    DuckStr *host = S("example.com");
    DuckRes_conn c = duck_net_tls(host, 443);
    if (!c.ok) {
        char buf[512];
        err_has(c.err, "", buf, sizeof buf);
        duck_release(host);
        th_fail(__FILE__, __LINE__, "net.tls example.com: %s", buf);
    }
    DuckArr *req = bytes_of("GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n");
    CHECK(duck_conn_write(c.val, req).ok);
    duck_release(req);
    DuckArr *all = duck_arr_new(&duck_ops_int, 0);
    for (;;) {
        DuckRes_arr r = duck_conn_read(c.val, 4096);
        CHECK(r.ok);
        int64_t n = duck_arr_len(r.val);
        duck_arr_extend(&all, r.val);
        duck_release(r.val);
        if (n == 0) break;
    }
    DuckRes_arr more = duck_conn_read(c.val, 10); /* still empty after the end */
    CHECK(more.ok && duck_arr_len(more.val) == 0);
    duck_release(more.val);
    char buf[64];
    CHECK(strncmp(arr_text(all, buf, sizeof buf), "HTTP/1.1 200", 12) == 0);
    duck_conn_close(c.val);
    DuckRes_arr after = duck_conn_read(c.val, 10);
    CHECK(!after.ok);
    duck_release(after.err);
    duck_release(c.val);
    duck_release(host);

    expect_bad_cert("expired.badssl.com");
    expect_bad_cert("wrong.host.badssl.com");
    expect_bad_cert("self-signed.badssl.com");
    expect_bad_cert("untrusted-root.badssl.com");
}

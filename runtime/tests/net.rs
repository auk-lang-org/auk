//! net.listen / accept, and net.tls (runtime/src/tls.rs).
//!
//! The TLS tests against real hosts run only when the network is usable: `DUCK_NET_TESTS=1`
//! forces them, `DUCK_NET_TESTS=0` skips them, and unset they run if example.com:443 answers
//! within 3 seconds. The rest need no network.
mod common;

use common::*;
use duck_rt::arr::*;
use duck_rt::core::*;
use duck_rt::rc::*;
use duck_rt::tls::duck_net_tls;
use duck_rt::*;

/// Bytes of an owned array as text, then release the array.
fn arr_text(a: *mut DuckArr) -> String {
    let b: Vec<u8> = int_elems(a).iter().map(|&x| x as u8).collect();
    rel(a);
    String::from_utf8_lossy(&b).into_owned()
}

fn bytes_of(t: &str) -> *mut DuckArr {
    let s = s(t);
    let a = unsafe { duck_rt::str::duck_str_bytes(s) };
    rel(s);
    a
}

// ---- listen / accept -----------------------------------------------------

/// The client side: connect, send "ping", read until EOF. Returns (reached EOF, text read).
fn client_main(port: i64) -> (bool, String) {
    unsafe {
        let host = s("127.0.0.1");
        let c = duck_net_tcp(host, port);
        rel(host);
        if !c.ok {
            rel(c.err);
            return (false, String::new());
        }
        let msg = bytes_of("ping");
        let w = duck_conn_write(c.val, msg);
        rel(msg);
        let (mut ok, mut got) = (false, Vec::new());
        if w.ok {
            loop {
                let r = duck_conn_read(c.val, 16);
                if !r.ok {
                    rel(r.err);
                    break;
                }
                let n = duck_arr_len(r.val);
                got.extend(int_elems(r.val).iter().map(|&x| x as u8));
                rel(r.val);
                if n == 0 {
                    ok = true;
                    break;
                }
            }
        } else {
            rel(w.err);
        }
        rel(c.val);
        (ok, String::from_utf8_lossy(&got).into_owned())
    }
}

#[test]
fn net_listen_accept_echo() {
    run(|| unsafe {
        let host = s("127.0.0.1");
        let l = duck_net_listen(host, 0);
        assert!(l.ok);
        let port = duck_listener_port(l.val);
        assert!(port > 0 && port <= 65535);
        let th = std::thread::spawn(move || client_main(port));
        let c = duck_listener_accept(l.val);
        assert!(c.ok);
        let r = duck_conn_read(c.val, 4);
        assert!(r.ok);
        assert_eq!(arr_text(r.val), "ping");
        let reply = bytes_of("echo:ping");
        assert!(duck_conn_write(c.val, reply).ok);
        rel(reply);
        duck_conn_close(c.val);
        rel(c.val);
        let (ok, got) = th.join().unwrap();
        assert!(ok);
        assert_eq!(got, "echo:ping");

        // the port is taken while the listener is open
        let again = duck_net_listen(host, port);
        assert!(!again.ok);
        let m = err_text(again.err);
        assert!(m.contains("net.listen 127.0.0.1:"), "{m}");

        duck_listener_close(l.val);
        assert!(duck_listener_port(l.val) == port);
        let c = duck_listener_accept(l.val);
        assert!(!c.ok);
        let m = err_text(c.err);
        assert!(m.contains("listener is closed"), "{m}");
        rel(l.val);

        let l = duck_net_listen(host, 70000);
        assert!(!l.ok);
        let m = err_text(l.err);
        assert!(m.contains("invalid port"), "{m}");
        rel(host);

        // "" listens on every interface
        let any = s("");
        let l = duck_net_listen(any, 0);
        assert!(l.ok);
        assert!(duck_listener_port(l.val) > 0);
        rel(l.val); // closes
        rel(any);
    });
}

// ---- tls without the network ---------------------------------------------

struct SendPtr(*mut DuckListener);
unsafe impl Send for SendPtr {}

fn plain_server(l: SendPtr) {
    unsafe {
        let c = duck_listener_accept(l.0);
        if !c.ok {
            rel(c.err);
            return;
        }
        let junk = bytes_of("HTTP/1.0 400 Bad Request\r\n\r\nnot tls\n");
        let r = duck_conn_read(c.val, 512); // the ClientHello
        if r.ok {
            rel(r.val);
        } else {
            rel(r.err);
        }
        let w = duck_conn_write(c.val, junk);
        if !w.ok {
            rel(w.err);
        }
        rel(junk);
        rel(c.val);
    }
}

#[test]
fn net_tls_local_failures() {
    run(|| unsafe {
        let host = s("127.0.0.1");
        let c = duck_net_tls(host, 0);
        assert!(!c.ok);
        let m = err_text(c.err);
        assert!(m.contains("invalid port"), "{m}");

        // a plain-TCP server: the handshake fails with an Err (no hang, no crash)
        let l = duck_net_listen(host, 0);
        assert!(l.ok);
        let lp = SendPtr(l.val);
        let th = std::thread::spawn(move || plain_server(lp));
        let c = duck_net_tls(host, duck_listener_port(l.val));
        assert!(!c.ok);
        let m = err_text(c.err);
        assert!(m.contains("127.0.0.1:") || m.contains("tls unavailable"), "{m}");
        th.join().unwrap();
        rel(l.val);
        rel(host);
    });
}

// ---- tls against real hosts ------------------------------------------------

/// net.tls to host must fail certificate verification. Retries a couple of times: the
/// badssl.com servers sometimes reset a connection before sending their certificate.
#[track_caller]
fn expect_bad_cert(host_name: &str) {
    let host = s(host_name);
    let mut cert = false;
    let mut last = String::new();
    for _ in 0..4 {
        let c = unsafe { duck_net_tls(host, 443) };
        if c.ok {
            rel(c.val);
            rel(host);
            panic!("net.tls {host_name}: connected despite a bad certificate");
        }
        last = err_text(c.err);
        cert = last.contains("certificate verification failed");
        if cert {
            break;
        }
    }
    rel(host);
    assert!(cert, "net.tls {host_name}: want a certificate error, got: {last}");
}

#[test]
fn net_tls_real_hosts() {
    if !net_tests() {
        eprintln!("note: net_tls_real_hosts skipped (set DUCK_NET_TESTS=1 to reach real hosts)");
        return;
    }
    run(|| unsafe {
        let host = s("example.com");
        let c = duck_net_tls(host, 443);
        if !c.ok {
            let m = err_text(c.err);
            rel(host);
            panic!("net.tls example.com: {m}");
        }
        let req = bytes_of("GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n");
        assert!(duck_conn_write(c.val, req).ok);
        rel(req);
        let mut all = duck_arr_new(&duck_ops_int, 0);
        loop {
            let r = duck_conn_read(c.val, 4096);
            assert!(r.ok);
            let n = duck_arr_len(r.val);
            duck_arr_extend(&mut all, r.val);
            rel(r.val);
            if n == 0 {
                break;
            }
        }
        let more = duck_conn_read(c.val, 10); // still empty after the end
        assert!(more.ok && duck_arr_len(more.val) == 0);
        rel(more.val);
        let t = arr_text(all);
        assert!(t.starts_with("HTTP/1.1 200"), "{}", &t[..t.len().min(64)]);
        duck_conn_close(c.val);
        let after = duck_conn_read(c.val, 10);
        assert!(!after.ok);
        rel(after.err);
        rel(c.val);
        rel(host);

        expect_bad_cert("expired.badssl.com");
        expect_bad_cert("wrong.host.badssl.com");
        expect_bad_cert("self-signed.badssl.com");
        expect_bad_cert("untrusted-root.badssl.com");
    });
}

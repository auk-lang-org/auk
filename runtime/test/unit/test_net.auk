/// net.listen / accept, and net.tls (runtime/src/tls*.auk) (was runtime/c/test/test_net.c).
///
/// The TLS tests against real hosts run only when the network is usable: AUK_NET_TESTS=1 forces
/// them, AUK_NET_TESTS=0 skips them, and unset they run if example.com:443 answers within 3
/// seconds. The rest need no network.

/// Bytes of an owned array as text (kept), then release the array.
fn arr_text(a: raw.Ptr<abi.Arr>): raw.Ptr<u8> uses raw, ffi {
  let n = rt.auk_arr_len(a)
  let t = ut.scratch(usize(n) + 1)
  let xs = ut.int_elems(a)
  var i: i64 = 0
  while i < n {
    t.at(i) = u8(xs.at(i))
    i += 1
  }
  ut.rel(raw.cast(a))
  t
}

fn bytes_of(t: raw.Ptr<u8>): raw.Ptr<abi.Arr> uses raw, ffi {
  let x = ut.s(t)
  let a = rt.auk_str_bytes(x)
  ut.rel(raw.cast(x))
  a
}

// ---- listen / accept ---------------------------------------------------------------------------

/// The client side: connect, send "ping", read until EOF (no checks: it runs on a thread).
raw struct Client {
  port: i64,
  /// reached EOF
  ok: bool,
  got: [u8; 256],
  n: usize,
}

fn client_main(arg: raw.Ptr<()>): raw.Ptr<()> uses raw, ffi {
  let cl: raw.Ptr<Client> = raw.cast(arg)
  let got: raw.Ptr<u8> = raw.cast(raw.field_addr(cl, .got))
  let host = ut.s("127.0.0.1")
  let c = rt.auk_net_tcp(host, cl.port)
  ut.rel(raw.cast(host))
  if !c.ok {
    ut.rel(raw.cast(c.err))
    return raw.null()
  }
  let msg = bytes_of("ping")
  let w = rt.auk_conn_write(c.val, msg)
  ut.rel(raw.cast(msg))
  if w.ok {
    while true {
      let r = rt.auk_conn_read(c.val, 16)
      if !r.ok {
        ut.rel(raw.cast(r.err))
        break
      }
      let n = rt.auk_arr_len(r.val)
      let xs = ut.int_elems(r.val)
      var i: i64 = 0
      while i < n && cl.n < 255 {
        got.at(cl.n) = u8(xs.at(i))
        cl.n += 1
        i += 1
      }
      ut.rel(raw.cast(r.val))
      if n == 0 {
        cl.ok = true
        break
      }
    }
  } else {
    ut.rel(raw.cast(w.err))
  }
  got.at(cl.n) = 0
  ut.rel(raw.cast(c.val))
  raw.null()
}

fn net_listen_accept_echo() uses raw, ffi {
  let host = ut.s("127.0.0.1")
  var l = rt.auk_net_listen(host, 0)
  ut.check(l.ok, "l.ok")
  let port = rt.auk_listener_port(l.val)
  ut.check(port > 0 && port <= 65535, "port > 0 && port <= 65535")
  var cl = Client { port: port }
  var th = cfacts.PthreadT {}
  ut.check(rt.pthread_create(raw.addr_of(&th), raw.null(), raw.fn_of(client_main), raw.cast(raw.addr_of(&cl))) == 0, "pthread_create(...) == 0")
  var c = rt.auk_listener_accept(l.val)
  ut.check(c.ok, "c.ok")
  let r = rt.auk_conn_read(c.val, 4)
  ut.check(r.ok, "r.ok")
  ut.text_eq(arr_text(r.val), "ping", "arr_text(r.val)")
  let reply = bytes_of("echo:ping")
  ut.check(rt.auk_conn_write(c.val, reply).ok, "auk_conn_write(c.val, reply).ok")
  ut.rel(raw.cast(reply))
  rt.auk_conn_close(c.val)
  ut.rel(raw.cast(c.val))
  let _ = rt.pthread_join(th.w0, raw.null())
  ut.check(cl.ok, "cl.ok")
  ut.text_eq(raw.cast(raw.field_addr(raw.addr_of(&cl), .got)), "echo:ping", "cl.got")

  // the port is taken while the listener is open
  let again = rt.auk_net_listen(host, port)
  ut.check(!again.ok, "!again.ok")
  ut.has(ut.err_text(again.err), "net.listen 127.0.0.1:", "err_text(again.err)")

  rt.auk_listener_close(l.val)
  ut.check(rt.auk_listener_port(l.val) == port, "auk_listener_port(l.val) == port")
  c = rt.auk_listener_accept(l.val)
  ut.check(!c.ok, "!c.ok")
  ut.has(ut.err_text(c.err), "listener is closed", "err_text(c.err)")
  ut.rel(raw.cast(l.val))

  l = rt.auk_net_listen(host, 70000)
  ut.check(!l.ok, "!l.ok")
  ut.has(ut.err_text(l.err), "invalid port", "err_text(l.err)")
  ut.rel(raw.cast(host))

  // "" listens on every interface
  let any = ut.s("")
  l = rt.auk_net_listen(any, 0)
  ut.check(l.ok, "l.ok")
  ut.check(rt.auk_listener_port(l.val) > 0, "auk_listener_port(l.val) > 0")
  ut.rel(raw.cast(l.val)) // closes
  ut.rel(raw.cast(any))
}

// ---- tls without the network -------------------------------------------------------------------

fn plain_server(arg: raw.Ptr<()>): raw.Ptr<()> uses raw, ffi {
  let c = rt.auk_listener_accept(raw.cast(arg))
  if !c.ok {
    ut.rel(raw.cast(c.err))
    return raw.null()
  }
  let junk = bytes_of("HTTP/1.0 400 Bad Request\r\n\r\nnot tls\n")
  let r = rt.auk_conn_read(c.val, 512) // the ClientHello
  if r.ok {
    ut.rel(raw.cast(r.val))
  } else {
    ut.rel(raw.cast(r.err))
  }
  let w = rt.auk_conn_write(c.val, junk)
  if !w.ok {
    ut.rel(raw.cast(w.err))
  }
  ut.rel(raw.cast(junk))
  ut.rel(raw.cast(c.val))
  raw.null()
}

fn net_tls_local_failures() uses raw, ffi {
  let host = ut.s("127.0.0.1")
  var c = rt.auk_net_tls(host, 0)
  ut.check(!c.ok, "!c.ok")
  ut.has(ut.err_text(c.err), "invalid port", "err_text(c.err)")

  // a plain-TCP server: the handshake fails with an Err (no hang, no crash)
  let l = rt.auk_net_listen(host, 0)
  ut.check(l.ok, "l.ok")
  var th = cfacts.PthreadT {}
  ut.check(rt.pthread_create(raw.addr_of(&th), raw.null(), raw.fn_of(plain_server), raw.cast(l.val)) == 0, "pthread_create(...) == 0")
  c = rt.auk_net_tls(host, rt.auk_listener_port(l.val))
  ut.check(!c.ok, "!c.ok")
  let m = ut.err_text(c.err)
  if rt.strstr(m, "127.0.0.1:").is_null() && rt.strstr(m, "tls unavailable").is_null() {
    let f = ut.scratch(rt.strlen(m) + 64)
    let _ = rt.snprintf(f, rt.strlen(m) + 64, "unexpected error: %s", m)
    ut.fail(f)
  }
  let _ = rt.pthread_join(th.w0, raw.null())
  ut.rel(raw.cast(l.val))
  ut.rel(raw.cast(host))
}

// ---- tls against real hosts -----------------------------------------------------------------------

/// net.tls to host must fail certificate verification, every time: three attempts. (The
/// badssl.com servers reset about half of the connections that offer Network.framework's
/// post-quantum TLS 1.3 key share, before sending their certificate; the TLS module retries
/// those as TLS 1.2, and this checks that no reset gets through.)
fn expect_bad_cert(host_name: raw.Ptr<u8>) uses raw, ffi {
  let host = ut.s(host_name)
  var i = 0
  while i < 3 {
    let c = rt.auk_net_tls(host, 443)
    if c.ok {
      ut.rel(raw.cast(c.val))
      ut.rel(raw.cast(host))
      let f = ut.scratch(256)
      let _ = rt.snprintf(f, 256, "net.tls %s: connected despite a bad certificate", host_name)
      ut.fail(f)
    }
    let m = ut.err_text(c.err)
    if rt.strstr(m, "certificate verification failed").is_null() {
      ut.rel(raw.cast(host))
      let n = rt.strlen(m) + 256
      let f = ut.scratch(n)
      let _ = rt.snprintf(f, n, "net.tls %s (attempt %d): want a certificate error, got: %s", host_name, i32(i + 1), m)
      ut.fail(f)
    }
    i += 1
  }
  ut.rel(raw.cast(host))
}

fn net_tls_real_hosts() uses raw, ffi {
  if !ut.net_tests() {
    let _ = rt.fprintf(cfacts.stderr(), "note: net_tls_real_hosts skipped (set AUK_NET_TESTS=1 to reach real hosts)\n")
    return
  }
  let host = ut.s("example.com")
  let c = rt.auk_net_tls(host, 443)
  if !c.ok {
    let m = ut.err_text(c.err)
    ut.rel(raw.cast(host))
    let n = rt.strlen(m) + 64
    let f = ut.scratch(n)
    let _ = rt.snprintf(f, n, "net.tls example.com: %s", m)
    ut.fail(f)
  }
  let req = bytes_of("GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n")
  ut.check(rt.auk_conn_write(c.val, req).ok, "auk_conn_write(c.val, req).ok")
  ut.rel(raw.cast(req))
  var all = rt.auk_arr_new(rt.OPS_INT, 0)
  while true {
    let r = rt.auk_conn_read(c.val, 4096)
    ut.check(r.ok, "r.ok")
    let n = rt.auk_arr_len(r.val)
    rt.auk_arr_extend(raw.addr_of(&all), r.val)
    ut.rel(raw.cast(r.val))
    if n == 0 {
      break
    }
  }
  let more = rt.auk_conn_read(c.val, 10) // still empty after the end
  ut.check(more.ok && rt.auk_arr_len(more.val) == 0, "more.ok && auk_arr_len(more.val) == 0")
  ut.rel(raw.cast(more.val))
  let t = arr_text(all)
  if rt.strncmp(t, "HTTP/1.1 200", 12) != 0 {
    let f = ut.scratch(128)
    let _ = rt.snprintf(f, 128, "%.64s", t)
    ut.fail(f)
  }
  rt.auk_conn_close(c.val)
  let after = rt.auk_conn_read(c.val, 10)
  ut.check(!after.ok, "!after.ok")
  ut.rel(raw.cast(after.err))
  ut.rel(raw.cast(c.val))
  ut.rel(raw.cast(host))

  expect_bad_cert("expired.badssl.com")
  expect_bad_cert("wrong.host.badssl.com")
  expect_bad_cert("self-signed.badssl.com")
  expect_bad_cert("untrusted-root.badssl.com")
}

/// The tests, in the C file's order.
pub fn all() uses raw, ffi {
  ut.run("net_listen_accept_echo", raw.fn_of(net_listen_accept_echo))
  ut.run("net_tls_local_failures", raw.fn_of(net_tls_local_failures))
  ut.run("net_tls_real_hosts", raw.fn_of(net_tls_real_hosts))
}

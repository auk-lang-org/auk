/// tests/net.rs: networking end to end: `net.listen`/`accept` (an Auk echo test and
/// `examples/echo.auk` driven by a client of the runner's), and `net.tls`: a local
/// `openssl s_server` with a self-signed certificate must be refused, and
/// `http.get("https://example.com")` must return 200.
///
/// Tests that reach real hosts follow `AUK_NET_TESTS`: `1` runs them (and fails when offline),
/// `0` skips them, and unset runs them only if example.com:443 answers within a few seconds.
/// The local TLS test needs the `openssl` command and is skipped without it.
///
/// The client of `examples/echo.auk` half-closes its connection (Rust's `shutdown(Write)`),
/// which core's `net.Conn` can't, so it is a socket of its own through `ffi`.

pub fn tests(): [t.Test] uses env, fs, ffi, time, net = [
  t.test("auk_echo_server_and_client_tasks", auk_echo_server_and_client_tasks),
  t.test("echo_example_serves_one_connection", echo_example_serves_one_connection),
  t.test("tls_refuses_a_self_signed_local_server", tls_refuses_a_self_signed_local_server),
  t.test("tls_get_from_a_real_host", tls_get_from_a_real_host),
  t.test("http_get_over_https_returns_200", http_get_over_https_returns_200),
]

fn auk_cmd(): cmd.Cmd uses env, ffi = t.auk().setenv("AUK_LEAK_CHECK", "1")

fn scratch(name: str): str uses env, fs, ffi = t.scratch("net/{name}")

async fn probe(done: Chan<bool>): int uses net {
  match net.tcp("example.com", 443) {
    ok(c) => {
      var c = c
      c.close()
      done.send(true)
    }
    err(_) => done.send(false)
  }
  0
}

/// Should tests reach real hosts? See the module docs.
fn net_tests(name: str): bool uses env, net {
  let on = match env.get("AUK_NET_TESTS") {
    some("1") => true
    some(_) => false
    none => {
      let done: Chan<bool> = chan()
      let task = probe(done)
      let up = done.recv_for(3000) else false
      if !task.done() { task.cancel() }
      up
    }
  }
  if !on { eprint("note: {name} skipped (offline or AUK_NET_TESTS=0; AUK_NET_TESTS=1 forces it)") }
  on
}

// ---- listen / accept ----

let ECHO_TEST = r"""
  /// Echo one message back, then close.
  async fn serve(l: net.Listener): str! uses net {
    var c = l.accept()?
    var got: [int] = []
    while got.len() < 4 {
      let more = c.read(64)?
      if more.len() == 0 { break }
      got = got + more
    }
    c.write(got)?
    c.close()
    str.from_utf8(got)
  }

  /// Send "raft" and read until the server closes.
  async fn client(port: int): str! uses net {
    var c = net.tcp("127.0.0.1", port)?
    c.write("raft".bytes())?
    var out: [int] = []
    var buf = c.read(64)?
    while buf.len() > 0 {
      out = out + buf
      buf = c.read(64)?
    }
    c.close()
    str.from_utf8(out)
  }

  test "echo over a listener" {
    var l = net.listen("127.0.0.1", 0)?
    assert l.port() > 0
    let (s, c) = await (serve(l), client(l.port()))
    assert s? == "raft"
    assert c? == "raft"
    l.close()
    assert l.accept() is err(_)
  }

  test "listen errors" {
    assert net.listen("127.0.0.1", 70000) is err(_)
    var a = net.listen("127.0.0.1", 0)?
    assert net.listen("127.0.0.1", a.port()) is err(_)
    a.close()
  }
  """

fn auk_echo_server_and_client_tasks() uses env, fs, ffi, time {
  let d = scratch("echo_test")
  let p = paths.join(d, "echo_test.auk")
  t.write(p, ECHO_TEST)
  let o = auk_cmd().arg("test").arg(p).output()
  t.check(o.success(), "{o.stdout}\n{o.stderr}")
  t.check(
    o.stdout.ends_with("2 passed, 0 failed\n") && !o.stdout.contains("leak"),
    "{o.stdout}\n{o.stderr}",
  )
}

/// The first line the child writes to stderr (without its newline), waiting up to `ms`.
fn stderr_line(c: var sys.Child, ms: int): str? uses ffi, time {
  let deadline = time.now() + ms
  loop {
    match c.ebuf.find_index(b => b == 10) {
      some(i) => {
        let line = sys.lossy(c.ebuf[0..i])
        c.ebuf = c.ebuf[i + 1..c.ebuf.len()]
        return line
      }
      none => {}
    }
    let left = deadline - time.now()
    if c.err < 0 || left <= 0 { return none }
    let _ = sys.pump(&c, min(left, 200))
  }
}

fn echo_example_serves_one_connection() uses env, ffi, time {
  // examples/echo.auk is compiled against examples/.raft (installed by the runner's setup)
  var child = auk_cmd().args(["run", "examples/echo.auk"]).start()
  // the server announces its port on stderr
  var seen: [str] = []
  let port = loop {
    let line = match stderr_line(&child, 60000) {
      some(l) => l
      none => {
        let o = cmd.wait(&child, 5000)
        t.fail("echo exited ({o.describe()}) before listening; its stderr:\n{seen.join("\n")}")
        return
      }
    }
    match line.strip_prefix("echo: listening on 127.0.0.1:") {
      some(rest) => break int.parse(rest.trim())!
      none => seen.push(line)
    }
  }
  let s = match tcp_connect(port) {
    some(fd) => fd
    none => t.bail("cannot connect to 127.0.0.1:{port}")
  }
  for msg in ["hello, auk\n", "raft 🦆"] {
    t.check(sys.fd_write(s, msg.bytes()), "write")
    var got: [int] = []
    while got.len() < msg.byte_len() {
      let more = match sys.fd_read(s, 20000) {
        some(b) => b
        none => t.bail("read timed out")
      }
      if more.len() == 0 { t.fail("connection closed early") }
      got = got + more
    }
    assert str.from_utf8(got)! == msg
  }
  let _ = c_shutdown(s, 1)
  var rest: [int] = []
  loop {
    let more = match sys.fd_read(s, 20000) {
      some(b) => b
      none => t.bail("read timed out")
    }
    if more.len() == 0 { break }
    rest = rest + more
  }
  sys.fd_close(s)
  assert rest.len() == 0
  let o = cmd.wait(&child, 20000)
  t.check(o.success(), "echo exited with {o.describe()}")
  let lines = o.stderr.lines()
  t.check(lines.all(l => !l.contains("leak")), lines.show())
}

/// A TCP connection to 127.0.0.1:`port` (a file descriptor).
fn tcp_connect(port: int): int? uses ffi {
  let fd = c_socket(2, 1, 0)
  if fd < 0 { return none }
  let addr = ffi.alloc(16)
  for i in 0..16 { ffi.write_u8(addr, i, 0) }
  if sys.linux() {
    ffi.write_u8(addr, 0, 2)  // sin_family (u16, little-endian) AF_INET
  } else {
    ffi.write_u8(addr, 0, 16)  // sin_len
    ffi.write_u8(addr, 1, 2)   // AF_INET
  }
  ffi.write_u8(addr, 2, (port >> 8) & 255)
  ffi.write_u8(addr, 3, port & 255)
  for i, b in [127, 0, 0, 1] { ffi.write_u8(addr, 4 + i, b) }
  let r = c_connect(fd, addr, 16)
  ffi.free(addr)
  if r != 0 {
    sys.fd_close(fd)
    return none
  }
  fd
}

extern fn c_socket(d: int, t: int, p: int): int = "int socket(int, int, int)"

extern fn c_connect(
  fd: int,
  addr: ffi.Ptr,
  n: int,
): int = "int connect(int, const void *, unsigned int)"

extern fn c_shutdown(fd: int, how: int): int = "int shutdown(int, int)"

// ---- tls ----

/// An Auk program that connects with `net.tls(args[1], args[2])` and prints the first line of
/// the reply to a GET.
let TLS_GET = r"""
  fn main(args: [str]): ()! uses net {
    var c = net.tls(args[1], int.parse(args[2])?)?
    c.write("GET / HTTP/1.0\r\nHost: {args[1]}\r\n\r\n".bytes())?
    let reply = str.from_utf8(c.read(4096)?)?
    print(reply.lines().first() else "")
    c.close()
  }
  """

fn tls_refuses_a_self_signed_local_server() uses env, fs, ffi, time, net {
  if cmd.new("openssl").arg("version").try_output() is err(_) {
    eprint("note: tls_refuses_a_self_signed_local_server skipped (no `openssl` command)")
    return
  }
  let d = scratch("tls_self_signed")
  let o = cmd
    .new("openssl")
    .args([
      "req",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-keyout",
      "key.pem",
      "-out",
      "cert.pem",
      "-days",
      "2",
    ])
    .args(["-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"])
    .cwd(d)
    .output()
  t.check(o.success(), "openssl req: {o.stderr}")
  var l = net.listen("127.0.0.1", 0)!
  let port = l.port()
  l.close()
  var server = cmd
    .new("openssl")
    .args(["s_server", "-quiet", "-www", "-cert", "cert.pem", "-key", "key.pem", "-accept"])
    .arg("127.0.0.1:{port}")
    .cwd(d)
    .start()
  let start = time.now()
  loop {
    match net.tcp("127.0.0.1", port) {
      ok(c) => {
        var c = c
        c.close()
        break
      }
      err(_) => {}
    }
    if time.now() - start >= 10000 {
      sys.kill(&server)
      t.fail("openssl s_server did not start")
    }
    let _ = sys.pump(&server, 50)
  }
  let p = paths.join(d, "main.auk")
  t.write(p, TLS_GET)
  let o = auk_cmd().arg("run").arg(p).args(["127.0.0.1", "{port}"]).output()
  sys.kill(&server)
  let _ = cmd.wait(&server, 5000)
  t.check(o.code == some(1), "a self-signed certificate must be refused:\n{o.stdout}\n{o.stderr}")
  t.check(
    o.stderr.starts_with("error: net.tls 127.0.0.1:{port}: certificate verification failed: ") ||
      o.stderr.contains("tls unavailable"),
    o.stderr,
  )
  assert o.stdout == ""
}

fn tls_get_from_a_real_host() uses env, fs, ffi, time, net {
  if !net_tests("tls_get_from_a_real_host") { return }
  let d = scratch("tls_real")
  let p = paths.join(d, "main.auk")
  t.write(p, TLS_GET)
  let o = auk_cmd().arg("run").arg(p).args(["example.com", "443"]).output()
  t.check(o.success(), "{o.stdout}\n{o.stderr}")
  t.check(o.stdout.starts_with("HTTP/1.0 200") || o.stdout.starts_with("HTTP/1.1 200"), o.stdout)
  // a certificate for another name: refused (retried: badssl.com sometimes resets first)
  var last = ""
  for _ in 0..4 {
    let o = auk_cmd().arg("run").arg(p).args(["wrong.host.badssl.com", "443"]).output()
    t.check(o.code == some(1), o.describe())
    last = o.stderr
    if last.contains("certificate verification failed") { return }
  }
  t.fail("want a certificate error, got: {last}")
}

fn http_get_over_https_returns_200() uses env, ffi, time, net {
  if !net_tests("http_get_over_https_returns_200") { return }
  let o = auk_cmd().args(["run", "examples/fetch.auk", "https://example.com"]).output()
  t.check(o.success(), "{o.stdout}\n{o.stderr}")
  t.check(
    o.stdout.starts_with("✓ 200 ") && o.stdout.trim_end().ends_with("ms https://example.com"),
    o.stdout,
  )
}

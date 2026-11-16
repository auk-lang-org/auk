//! Networking end to end: `net.listen`/`accept` (a Duck echo test and `examples/echo.duck`
//! driven by a std::net client), and `net.tls`: a local `openssl s_server` with a self-signed
//! certificate must be refused, and `http.get("https://example.com")` must return 200.
//!
//! Tests that reach real hosts follow `DUCK_NET_TESTS`: `1` runs them (and fails when
//! offline), `0` skips them, and unset runs them only if example.com:443 answers within a few
//! seconds. The local TLS test needs the `openssl` command and is skipped without it.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream, ToSocketAddrs};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::sync::Once;
use std::time::{Duration, Instant};
use std::{env, fs, thread};

fn duck_cmd() -> Command {
    let mut c = Command::new(env!("CARGO_BIN_EXE_duck"));
    c.env_remove("DUCK_CFLAGS").env("DUCK_LEAK_CHECK", "1");
    c
}

fn text(o: &Output) -> (String, String) {
    (String::from_utf8_lossy(&o.stdout).into_owned(), String::from_utf8_lossy(&o.stderr).into_owned())
}

fn scratch(name: &str) -> PathBuf {
    let d = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("net").join(name);
    let _ = fs::remove_dir_all(&d);
    fs::create_dir_all(&d).unwrap();
    d
}

/// Should tests reach real hosts? See the module docs.
fn net_tests(name: &str) -> bool {
    let on = match env::var("DUCK_NET_TESTS").as_deref() {
        Ok("1") => true,
        Ok(_) => false,
        Err(_) => ("example.com", 443)
            .to_socket_addrs()
            .is_ok_and(|mut a| a.any(|a| TcpStream::connect_timeout(&a, Duration::from_secs(3)).is_ok())),
    };
    if !on {
        eprintln!("note: {name} skipped (offline or DUCK_NET_TESTS=0; DUCK_NET_TESTS=1 forces it)");
    }
    on
}

/// `quack install` in examples/ (as tests/run.rs does), once.
fn setup() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let dir = "examples";
        let run = || Command::new(env!("CARGO_BIN_EXE_quack")).arg("install").current_dir(dir).output().unwrap();
        if !run().status.success() {
            let _ = fs::remove_file(Path::new(dir).join("quack.lock"));
            let _ = fs::remove_dir_all(Path::new(dir).join(".quack"));
            let out = run();
            assert!(out.status.success(), "quack install failed:\n{}", String::from_utf8_lossy(&out.stderr));
        }
    });
}

/// Kills the child on drop (a server the test started).
struct Kill(Child);
impl Drop for Kill {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

// ---- listen / accept ----

const ECHO_TEST: &str = r#"/// Echo one message back, then close.
async fn serve(l: net.Listener): str! uses net {
  var c = l.accept()?
  var got: [int] = []
  while got.len() < 5 {
    let more = c.read(64)?
    if more.len() == 0 { break }
    got = got + more
  }
  c.write(got)?
  c.close()
  str.from_utf8(got)
}

/// Send "quack" and read until the server closes.
async fn client(port: int): str! uses net {
  var c = net.tcp("127.0.0.1", port)?
  c.write("quack".bytes())?
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
  assert s? == "quack"
  assert c? == "quack"
  l.close()
  assert l.accept() is err(_)
}

test "listen errors" {
  assert net.listen("127.0.0.1", 70000) is err(_)
  var a = net.listen("127.0.0.1", 0)?
  assert net.listen("127.0.0.1", a.port()) is err(_)
  a.close()
}
"#;

#[test]
fn duck_echo_server_and_client_tasks() {
    let d = scratch("echo_test");
    let p = d.join("echo_test.duck");
    fs::write(&p, ECHO_TEST).unwrap();
    let c = d.join("prog.c");
    let o = duck_cmd().arg("test").arg(&p).env("DUCK_KEEP_C", &c).output().unwrap();
    let (out, err) = text(&o);
    assert!(o.status.success(), "{out}\n{err}");
    assert!(out.ends_with("2 passed, 0 failed\n") && !out.contains("leak"), "{out}\n{err}");
    // the generated C (with net.Listener results) is warning-free
    let clang = env::var("CLANG").unwrap_or_else(|_| "clang".into());
    let rt = Path::new(env!("CARGO_MANIFEST_DIR")).join("runtime");
    let o = Command::new(&clang).args(["-std=c11", "-Wall", "-Wno-unused", "-Werror", "-fsyntax-only", "-I"]).arg(rt).arg(&c).output().unwrap();
    assert!(o.status.success(), "warnings in the generated C:\n{}", text(&o).1);
}

#[test]
fn echo_example_serves_one_connection() {
    let mut child = Kill(
        duck_cmd()
            .args(["run", "examples/echo.duck"])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap(),
    );
    // the server announces its port on stderr
    let mut lines = BufReader::new(child.0.stderr.take().unwrap()).lines();
    let port: u16 = loop {
        let line = lines.next().expect("echo exited before listening").unwrap();
        if let Some(rest) = line.strip_prefix("echo: listening on 127.0.0.1:") {
            break rest.trim().parse().unwrap();
        }
    };
    let mut s = TcpStream::connect(("127.0.0.1", port)).unwrap();
    s.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
    for msg in ["hello, duck\n", "quack 🦆"] {
        s.write_all(msg.as_bytes()).unwrap();
        let mut got = vec![0u8; msg.len()];
        s.read_exact(&mut got).unwrap();
        assert_eq!(String::from_utf8(got).unwrap(), msg);
    }
    s.shutdown(Shutdown::Write).unwrap();
    let mut rest = Vec::new();
    s.read_to_end(&mut rest).unwrap();
    assert!(rest.is_empty());
    let status = child.0.wait().unwrap();
    assert!(status.success(), "echo exited with {status}");
    let rest: Vec<String> = lines.map_while(Result::ok).collect();
    assert!(rest.iter().all(|l| !l.contains("leak")), "{rest:?}");
}

// ---- tls ----

/// A Duck program that connects with `net.tls(args[1], args[2])` and prints the first line
/// of the reply to a GET.
const TLS_GET: &str = r#"fn main(args: [str]): ()! uses net {
  var c = net.tls(args[1], int.parse(args[2])?)?
  c.write("GET / HTTP/1.0\r\nHost: {args[1]}\r\n\r\n".bytes())?
  let reply = str.from_utf8(c.read(4096)?)?
  print(reply.lines().first() else "")
  c.close()
}
"#;

#[test]
fn tls_refuses_a_self_signed_local_server() {
    if Command::new("openssl").arg("version").output().is_err() {
        eprintln!("note: tls_refuses_a_self_signed_local_server skipped (no `openssl` command)");
        return;
    }
    let d = scratch("tls_self_signed");
    let o = Command::new("openssl")
        .args(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "key.pem", "-out", "cert.pem", "-days", "2"])
        .args(["-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"])
        .current_dir(&d)
        .output()
        .unwrap();
    assert!(o.status.success(), "openssl req: {}", text(&o).1);
    let port = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let _server = Kill(
        Command::new("openssl")
            .args(["s_server", "-quiet", "-www", "-cert", "cert.pem", "-key", "key.pem", "-accept"])
            .arg(format!("127.0.0.1:{port}"))
            .current_dir(&d)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    );
    let start = Instant::now();
    while TcpStream::connect(("127.0.0.1", port)).is_err() {
        assert!(start.elapsed() < Duration::from_secs(10), "openssl s_server did not start");
        thread::sleep(Duration::from_millis(50));
    }
    let p = d.join("main.duck");
    fs::write(&p, TLS_GET).unwrap();
    let o = duck_cmd().arg("run").arg(&p).args(["127.0.0.1", &port.to_string()]).output().unwrap();
    let (out, err) = text(&o);
    assert_eq!(o.status.code(), Some(1), "a self-signed certificate must be refused:\n{out}\n{err}");
    assert!(err.starts_with(&format!("error: net.tls 127.0.0.1:{port}: certificate verification failed: ")) || err.contains("tls unavailable"), "{err}");
    assert_eq!(out, "");
}

#[test]
fn tls_get_from_a_real_host() {
    if !net_tests("tls_get_from_a_real_host") {
        return;
    }
    let d = scratch("tls_real");
    let p = d.join("main.duck");
    fs::write(&p, TLS_GET).unwrap();
    let o = duck_cmd().arg("run").arg(&p).args(["example.com", "443"]).output().unwrap();
    let (out, err) = text(&o);
    assert!(o.status.success(), "{out}\n{err}");
    assert!(out.starts_with("HTTP/1.0 200") || out.starts_with("HTTP/1.1 200"), "{out}");
    // a certificate for another name: refused (retried: badssl.com sometimes resets first)
    let mut last = String::new();
    for _ in 0..4 {
        let o = duck_cmd().arg("run").arg(&p).args(["wrong.host.badssl.com", "443"]).output().unwrap();
        assert_eq!(o.status.code(), Some(1), "{:?}", text(&o));
        last = text(&o).1;
        if last.contains("certificate verification failed") {
            return;
        }
    }
    panic!("want a certificate error, got: {last}");
}

#[test]
fn http_get_over_https_returns_200() {
    if !net_tests("http_get_over_https_returns_200") {
        return;
    }
    setup();
    let o = duck_cmd().args(["run", "examples/fetch.duck", "https://example.com"]).output().unwrap();
    let (out, err) = text(&o);
    assert!(o.status.success(), "{out}\n{err}");
    assert!(out.starts_with("✓ 200 ") && out.trim_end().ends_with("ms https://example.com"), "{out}");
}

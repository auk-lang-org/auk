//! The debugger: `duck run --debug` attached to a front end over `DUCK_DEBUG`'s Unix socket
//! (runtime/src/dbg.rs, the frame records and statement hooks in lower.rs). Every event read
//! here must parse as JSON (src/json.rs).

#[allow(dead_code)]
#[path = "../src/json.rs"]
mod json;

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::Duration;

use json::Json;

fn duck_cmd() -> Command {
    let mut c = Command::new(env!("CARGO_BIN_EXE_duck"));
    for v in ["DUCK_LEAK_CHECK", "DUCK_TRACE", "DUCK_DEBUG"] {
        c.env_remove(v);
    }
    c
}

fn scratch(name: &str) -> PathBuf {
    // Unix socket paths are short (104 bytes on macOS): keep the directory name small
    let d = std::env::temp_dir().join(format!("dkdbg{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&d);
    fs::create_dir_all(&d).unwrap();
    d
}

/// A debugged program and its connection.
struct Session {
    child: Option<Child>,
    rd: BufReader<UnixStream>,
    wr: UnixStream,
    seq: i64,
    /// Events read while waiting for something else.
    pending: Vec<Json>,
}

impl Session {
    fn start(name: &str, src: &str) -> Session {
        let dir = scratch(name);
        let file = dir.join("prog.duck");
        fs::write(&file, src).unwrap();
        let sock = dir.join("s");
        let l = UnixListener::bind(&sock).unwrap();
        let child = duck_cmd().arg("run").arg("--debug").arg(&file).env("DUCK_DEBUG", &sock).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().unwrap();
        let (conn, _) = l.accept().unwrap();
        conn.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        let wr = conn.try_clone().unwrap();
        let mut s = Session { child: Some(child), rd: BufReader::new(conn), wr, seq: 0, pending: Vec::new() };
        let ready = s.read();
        assert_eq!(ready.get("ev").as_str(), Some("ready"));
        s
    }

    fn read(&mut self) -> Json {
        let mut line = String::new();
        let n = self.rd.read_line(&mut line).unwrap();
        assert!(n > 0, "the program closed the connection");
        let e = json::parse(line.trim()).unwrap_or_else(|err| panic!("not JSON ({err}): {line}"));
        assert!(e.get("ev").as_str().is_some(), "no `ev`: {line}");
        e
    }

    /// Send a command; its reply.
    fn cmd(&mut self, c: &str) -> Json {
        self.seq += 1;
        writeln!(self.wr, "@{} {c}", self.seq).unwrap();
        loop {
            let e = self.read();
            if e.get("seq").as_i64() == Some(self.seq) {
                return e;
            }
            self.pending.push(e);
        }
    }

    /// The next event named `ev`.
    fn wait(&mut self, ev: &str) -> Json {
        if let Some(i) = self.pending.iter().position(|e| e.get("ev").as_str() == Some(ev)) {
            return self.pending.remove(i);
        }
        loop {
            let e = self.read();
            if e.get("ev").as_str() == Some(ev) {
                return e;
            }
            self.pending.push(e);
        }
    }

    /// Resume with `c` and wait for the next stop: (reason, function, line).
    fn go(&mut self, c: &str) -> (String, String, i64) {
        assert_eq!(self.cmd(c).get("ev").as_str(), Some("ok"), "{c}");
        let s = self.wait("stopped");
        let f = s.get("frame");
        (s.get("reason").as_str().unwrap().to_string(), f.get("fn").as_str().unwrap_or("").to_string(), f.get("line").as_i64().unwrap_or(0))
    }

    /// The locals of frame `n`: "name=value" each.
    fn vars(&mut self, n: usize) -> Vec<String> {
        let r = self.cmd(&format!("vars {n}"));
        assert_eq!(r.get("ev").as_str(), Some("vars"), "{r:?}");
        r.get("vars").as_arr().iter().map(|v| format!("{}={}", v.get("name").as_str().unwrap(), v.get("value").as_str().unwrap())).collect()
    }

    fn finish(mut self) -> (i32, String) {
        let out = self.child.take().unwrap().wait_with_output().unwrap();
        (out.status.code().unwrap_or(-1), String::from_utf8_lossy(&out.stdout).into_owned())
    }
}

const PROG: &str = r#"struct Point { x: int, y: int }

fn add(p: Point, d: int): Point {
    let nx = p.x + d
    let ny = p.y + d
    Point { x: nx, y: ny }
}

fn fact(n: int): int {
    if n <= 1 {
        return 1
    }
    n * fact(n - 1)
}

fn main() {
    var total = 0
    for i in 0..3 {
        total += i
    }
    let p = add(Point { x: 1, y: 2 }, total)
    let x = 1
    let x = x + fact(3)
    print("{p.x} {x}")
}
"#;

#[test]
fn breakpoints_stack_and_locals() {
    let mut s = Session::start("basic", PROG);
    let b = s.cmd("break prog.duck:5");
    assert_eq!((b.get("ev").as_str(), b.get("line").as_i64()), (Some("break"), Some(5)));
    // a blank line moves to the next line with code; a function breakpoint stops at its first
    assert_eq!(s.cmd("break prog.duck:2").get("line").as_i64(), Some(4));
    assert_eq!(s.cmd("delete 2").get("ev").as_str(), Some("ok"));
    assert_eq!(s.cmd("break fact").get("line").as_i64(), Some(10));
    assert_eq!(s.cmd("break nowhere").get("ev").as_str(), Some("error"));
    assert_eq!(s.go("run"), ("breakpoint".into(), "prog.add".into(), 5));
    assert_eq!(s.vars(0), ["p=Point { x: 1, y: 2 }", "d=3", "nx=4"]);
    // the caller's frame and its locals
    let st = s.cmd("stack");
    let frames = st.get("frames").as_arr();
    let fl: Vec<(String, i64)> = frames.iter().map(|f| (f.get("fn").as_str().unwrap().to_string(), f.get("line").as_i64().unwrap())).collect();
    assert_eq!(fl, [("prog.add".to_string(), 5), ("prog.main".to_string(), 21)]);
    assert_eq!(s.vars(1), ["total=3"]);
    // recursion: one frame per call
    assert_eq!(s.go("continue"), ("breakpoint".into(), "prog.fact".into(), 10));
    assert_eq!(s.go("continue"), ("breakpoint".into(), "prog.fact".into(), 10));
    assert_eq!(s.cmd("stack").get("frames").as_arr().len(), 3);
    assert_eq!(s.vars(0), ["n=2"]);
    assert_eq!(s.cmd("delete").get("ev").as_str(), Some("ok"));
    assert_eq!(s.cmd("continue").get("ev").as_str(), Some("ok"));
    s.wait("exited");
    assert_eq!(s.finish(), (0, "4 7\n".into()));
}

#[test]
fn stepping() {
    let mut s = Session::start("step", PROG);
    s.cmd("break prog.duck:21");
    assert_eq!(s.go("run"), ("breakpoint".into(), "prog.main".into(), 21));
    // into add, over its lines, out to main
    assert_eq!(s.go("step"), ("step".into(), "prog.add".into(), 4));
    assert_eq!(s.go("next"), ("step".into(), "prog.add".into(), 5));
    assert_eq!(s.go("finish"), ("step".into(), "prog.main".into(), 22));
    // over a call: stays in main; shadowed names show their latest binding
    assert_eq!(s.go("next"), ("step".into(), "prog.main".into(), 23));
    assert_eq!(s.go("next"), ("step".into(), "prog.main".into(), 24));
    assert!(s.vars(0).contains(&"x=7".to_string()), "{:?}", s.vars(0));
    s.cmd("continue");
    s.wait("exited");
    assert_eq!(s.finish().0, 0);
}

#[test]
fn loops_stop_every_iteration() {
    let mut s = Session::start("loop", PROG);
    s.cmd("break prog.duck:19");
    assert_eq!(s.go("run").2, 19);
    let mut seen = vec![s.vars(0)];
    for _ in 0..2 {
        assert_eq!(s.go("continue").2, 19);
        seen.push(s.vars(0));
    }
    assert_eq!(seen, [["total=0", "i=0"], ["total=0", "i=1"], ["total=1", "i=2"]]);
    s.cmd("delete");
    s.cmd("continue");
    s.wait("exited");
}

#[test]
fn panics_tasks_and_pause() {
    let src = r#"async fn work(k: int): int {
    var s = 0
    for i in 0..k {
        s += i
    }
    s
}

fn spin(): int {
    var n = 0
    while true {
        n += 1
        if n < 0 { return n }
    }
    n
}

fn boom(xs: [int]): int {
    let m = xs.map(x => x * 2)
    m[10]
}

fn main() {
    let r = catch boom([1])
    let (a, b) = await (work(3), work(4))
    print("{a} {b}")
    print("{spin()}")
}
"#;
    let mut s = Session::start("tasks", src);
    // a caught panic stops only with `catch all`
    s.cmd("catch all");
    s.cmd("break prog.duck:4");
    let p = s.cmd("run");
    assert_eq!(p.get("ev").as_str(), Some("ok"));
    let st = s.wait("stopped");
    assert_eq!(st.get("reason").as_str(), Some("panic"));
    assert_eq!(st.get("msg").as_str(), Some("index 10 out of range for length 1"));
    assert_eq!(st.get("caught"), &json::Json::Bool(true));
    assert_eq!(s.vars(0), ["xs=[1]", "m=[2]"]);
    // a task's thread; every other thread stops too
    let (reason, f, line) = s.go("continue");
    assert_eq!((reason.as_str(), f.as_str(), line), ("breakpoint", "prog.work", 4));
    let th = s.cmd("threads");
    assert!(th.get("threads").as_arr().len() >= 2, "{th:?}");
    s.cmd("delete");
    // pause a busy loop
    assert_eq!(s.cmd("continue").get("ev").as_str(), Some("ok"));
    std::thread::sleep(Duration::from_millis(300));
    s.cmd("pause");
    let st = s.wait("stopped");
    assert_eq!(st.get("reason").as_str(), Some("pause"));
    assert_eq!(st.get("frame").get("fn").as_str(), Some("prog.spin"));
    s.cmd("kill");
    let (code, out) = s.finish();
    assert_eq!((code, out.as_str()), (137, "3 6\n"));
}

#[test]
fn an_uncaught_panic_stops_before_the_process_ends() {
    let mut s = Session::start("panic", "fn f(n: int): int {\n    100 / n\n}\n\nfn main() {\n    let k = 0\n    print(\"{f(k)}\")\n}\n");
    s.cmd("run");
    let st = s.wait("stopped");
    assert_eq!((st.get("reason").as_str(), st.get("frame").get("line").as_i64()), (Some("panic"), Some(2)));
    assert_eq!(s.vars(1), ["k=0"]);
    s.cmd("continue");
    assert_eq!(s.finish().0, 101);
}

#[test]
fn detached_and_flagless_programs() {
    let dir = scratch("plain");
    let f = dir.join("prog.duck");
    fs::write(&f, PROG).unwrap();
    // --debug without a front end runs as usual
    let o = duck_cmd().arg("run").arg("--debug").arg(&f).output().unwrap();
    assert_eq!(String::from_utf8_lossy(&o.stdout), "4 7\n");
    // no instrumentation without the flag
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let ir = |args: &[&str]| String::from_utf8(duck_cmd().arg("ir").args(args).current_dir(root).output().unwrap().stdout).unwrap();
    for f in ["examples/tour.duck", "examples/life.duck"] {
        let plain = ir(&[f]);
        assert!(!plain.contains("duck_dbg"), "{f}");
        let dbg = ir(&["--debug", f]);
        assert!(dbg.contains("duck_dbg_hook(") && dbg.contains("duck_dbg_init("), "{f}");
    }
}

// ---- duck debug ----

fn prog_file(name: &str, src: &str) -> PathBuf {
    let f = scratch(name).join("prog.duck");
    fs::write(&f, src).unwrap();
    f
}

fn debug_cmd(args: &[&str], f: &Path) -> (i32, String) {
    let o = duck_cmd().arg("debug").args(args).arg(f).stdin(Stdio::null()).output().unwrap();
    (o.status.code().unwrap_or(-1), format!("{}{}", String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr)))
}

#[test]
fn batch_text_report() {
    let f = prog_file("batch", PROG);
    // stdin is not a terminal: batch mode
    let (code, out) = debug_cmd(&["-b", "prog.duck:5", "-b", "fact", "-p", "n,nx", "--max-stops", "3"], &f);
    assert_eq!(code, 137, "{out}");
    let want = "\
#1 breakpoint at prog.duck:5 in prog.add
  nx = 4
  called from prog.main (prog.duck:21)
#2 breakpoint at prog.duck:10 in prog.fact
  n = 3
  called from prog.main (prog.duck:23)
#3 breakpoint at prog.duck:10 in prog.fact
  n = 2
  called from prog.fact (prog.duck:13) < prog.main (prog.duck:23)
ended after 3 stops (--max-stops)
exit 137
";
    // paths are shown relative to the working directory: compare from the first stop's file name
    let out = out.replace(&format!("{}/", fs::canonicalize(f.parent().unwrap()).unwrap().display()), "");
    assert_eq!(out, want);
    // no breakpoints: runs to the end
    let (code, out) = debug_cmd(&[], &f);
    assert_eq!((code, out.as_str()), (0, "stdout:\n4 7\nexit 0\n"));
}

#[test]
fn batch_json_panic_and_timeout() {
    let f = prog_file("json", "fn f(n: int): int {\n    100 / n\n}\n\nfn main() {\n    print(\"hi\")\n    let k = 0\n    print(\"{f(k)}\")\n}\n");
    let (code, out) = debug_cmd(&["--json"], &f);
    assert_eq!(code, 101, "{out}");
    let r = json::parse(out.trim()).unwrap_or_else(|e| panic!("{e}: {out}"));
    let s = &r.get("stops").as_arr()[0];
    assert_eq!((s.get("reason").as_str(), s.get("line").as_i64(), s.at(&["locals", "n"]).as_str()), (Some("panic"), Some(2), Some("0")));
    assert!(s.get("msg").as_str().is_some_and(|m| m.contains("division by zero")), "{out}");
    assert_eq!(s.get("stack").as_arr().len(), 2);
    assert_eq!(r.get("stdout").as_str(), Some("hi\n"));
    // an endless loop: where it is when the time runs out
    let f = prog_file("spin", "fn main() {\n    var n = 0\n    while true {\n        n += 1\n    }\n}\n");
    let (code, out) = debug_cmd(&["--json", "--timeout", "0.5"], &f);
    assert_eq!(code, 137, "{out}");
    let r = json::parse(out.trim()).unwrap();
    let s = &r.get("stops").as_arr()[0];
    assert_eq!(s.get("reason").as_str(), Some("timeout"), "{out}");
    assert!(s.at(&["locals", "n"]).as_str().is_some(), "{out}");
    // a program that doesn't compile: its errors and the compiler's exit code
    let f = prog_file("bad", "fn main() {\n    let x: int = \"a\"\n}\n");
    let (code, out) = debug_cmd(&[], &f);
    assert!(code != 0 && out.contains("E0200"), "{out}");
}

#[test]
fn interactive_prompt() {
    let f = prog_file("repl", PROG);
    let mut c = duck_cmd().arg("debug").arg("--repl").arg(&f).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().unwrap();
    // typed ahead: what is typed while the program runs waits for the next stop
    c.stdin.take().unwrap().write_all(b"b add\nr\nn\n\np nx\nup\nbt\nfinish\np total\nnope\nd\nc\n").unwrap();
    let o = c.wait_with_output().unwrap();
    let out = String::from_utf8_lossy(&o.stdout).replace(&format!("{}/", fs::canonicalize(f.parent().unwrap()).unwrap().display()), "");
    for want in [
        "breakpoint 1 at prog.duck:4",
        "breakpoint 1 in prog.add (prog.duck:4)\n4\t    let nx = p.x + d",
        "6\t    Point { x: nx, y: ny }",
        "nx: int = 4",
        "#1 prog.main (prog.duck:21)",
        " #0 prog.add (prog.duck:6)\n*#1 prog.main (prog.duck:21)",
        "total: int = 3",
        "unknown command `nope`",
        "4 7\n",
        "program exited with code 0",
    ] {
        assert!(out.contains(want), "missing {want:?} in:\n{out}");
    }
    assert_eq!(o.status.code(), Some(0));
}

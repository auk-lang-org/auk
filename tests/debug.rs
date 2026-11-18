//! The debugger: `auk run --debug` attached to a front end over `AUK_DEBUG`'s Unix socket
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

fn auk_cmd() -> Command {
    let mut c = Command::new(env!("CARGO_BIN_EXE_auk"));
    for v in ["AUK_LEAK_CHECK", "AUK_TRACE", "AUK_DEBUG"] {
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
        let file = dir.join("prog.auk");
        fs::write(&file, src).unwrap();
        let sock = dir.join("s");
        let l = UnixListener::bind(&sock).unwrap();
        let child = auk_cmd().arg("run").arg("--debug").arg(&file).env("AUK_DEBUG", &sock).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().unwrap();
        // the program connects once it compiles (a test program that doesn't would hang here)
        l.set_nonblocking(true).unwrap();
        let mut child = child;
        let conn = loop {
            match l.accept() {
                Ok((c, _)) => break c,
                Err(_) => {
                    if let Some(st) = child.try_wait().unwrap() {
                        let mut e = String::new();
                        std::io::Read::read_to_string(child.stderr.as_mut().unwrap(), &mut e).unwrap();
                        panic!("the program ended ({st}) without connecting:\n{e}");
                    }
                    std::thread::sleep(Duration::from_millis(10));
                }
            }
        };
        conn.set_nonblocking(false).unwrap();
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
    let b = s.cmd("break prog.auk:5");
    assert_eq!((b.get("ev").as_str(), b.get("line").as_i64()), (Some("break"), Some(5)));
    // a blank line moves to the next line with code; a function breakpoint stops at its first
    assert_eq!(s.cmd("break prog.auk:2").get("line").as_i64(), Some(4));
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
    s.cmd("break prog.auk:21");
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
    s.cmd("break prog.auk:19");
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
    s.cmd("break prog.auk:4");
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
    let f = dir.join("prog.auk");
    fs::write(&f, PROG).unwrap();
    // --debug without a front end runs as usual
    let o = auk_cmd().arg("run").arg("--debug").arg(&f).output().unwrap();
    assert_eq!(String::from_utf8_lossy(&o.stdout), "4 7\n");
    // no instrumentation without the flag
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let ir = |args: &[&str]| String::from_utf8(auk_cmd().arg("ir").args(args).current_dir(root).output().unwrap().stdout).unwrap();
    for f in ["examples/tour.auk", "examples/life.auk"] {
        let plain = ir(&[f]);
        assert!(!plain.contains("auk_dbg"), "{f}");
        let dbg = ir(&["--debug", f]);
        assert!(dbg.contains("auk_dbg_hook(") && dbg.contains("auk_dbg_init("), "{f}");
    }
}

// ---- auk debug ----

fn prog_file(name: &str, src: &str) -> PathBuf {
    let f = scratch(name).join("prog.auk");
    fs::write(&f, src).unwrap();
    f
}

fn debug_cmd(args: &[&str], f: &Path) -> (i32, String) {
    let o = auk_cmd().arg("debug").args(args).arg(f).stdin(Stdio::null()).output().unwrap();
    (o.status.code().unwrap_or(-1), format!("{}{}", String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr)))
}

#[test]
fn batch_text_report() {
    let f = prog_file("batch", PROG);
    // stdin is not a terminal: batch mode
    let (code, out) = debug_cmd(&["-b", "prog.auk:5", "-b", "fact", "-p", "n,nx", "--max-stops", "3"], &f);
    assert_eq!(code, 137, "{out}");
    let want = "\
#1 breakpoint at prog.auk:5 in prog.add
  nx = 4
  called from prog.main (prog.auk:21)
#2 breakpoint at prog.auk:10 in prog.fact
  n = 3
  called from prog.main (prog.auk:23)
#3 breakpoint at prog.auk:10 in prog.fact
  n = 2
  called from prog.fact (prog.auk:13) < prog.main (prog.auk:23)
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
    let mut c = auk_cmd().arg("debug").arg("--repl").arg(&f).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().unwrap();
    // typed ahead: what is typed while the program runs waits for the next stop
    c.stdin.take().unwrap().write_all(b"b add\nr\nn\n\np nx\nup\nbt\nfinish\np total\nnope\nd\nc\n").unwrap();
    let o = c.wait_with_output().unwrap();
    let out = String::from_utf8_lossy(&o.stdout).replace(&format!("{}/", fs::canonicalize(f.parent().unwrap()).unwrap().display()), "");
    for want in [
        "breakpoint 1 at prog.auk:4",
        "breakpoint 1 in prog.add (prog.auk:4)\n4\t    let nx = p.x + d",
        "6\t    Point { x: nx, y: ny }",
        "nx: int = 4",
        "#1 prog.main (prog.auk:21)",
        " #0 prog.add (prog.auk:6)\n*#1 prog.main (prog.auk:21)",
        "total: int = 3",
        "unknown command `nope`",
        "4 7\n",
        "program exited with code 0",
    ] {
        assert!(out.contains(want), "missing {want:?} in:\n{out}");
    }
    assert_eq!(o.status.code(), Some(0));
}

// ---- parts of values, `auk dap` ----

const SCENE: &str = r#"struct Point { x: int, y: int }
enum Shape { Circle(c: Point, r: float), Square(Point, float), Empty }
struct Scene { name: str, shapes: [Shape], tags: {str: int}, best: Point?, pair: (int, str) }

fn main() {
    let s = Scene { name: "demo", shapes: [Circle(Point { x: 1, y: 2 }, 3.0), Square(Point { x: 0, y: 0 }, 1.5), Empty], tags: {"a": 1, "b": 2}, best: Point { x: 9, y: 9 }, pair: (7, "seven") }
    let big = 0..1500
    print(s.name)
}
"#;

#[test]
fn parts_of_values() {
    let mut s = Session::start("kids", SCENE);
    s.cmd("break prog.auk:8");
    assert_eq!(s.go("run").2, 8);
    let kids = |s: &mut Session, c: &str| -> Vec<String> {
        let r = s.cmd(&format!("kids 0 1 {c}"));
        r.get("kids").as_arr().iter().map(|k| format!("{}={}{}", k.get("name").as_str().unwrap(), k.get("value").as_str().unwrap(), if k.get("kids") == &Json::Bool(true) { "+" } else { "" })).collect()
    };
    let v = s.cmd("vars");
    assert_eq!(v.get("vars").as_arr()[0].get("kids"), &Json::Bool(true));
    assert_eq!(kids(&mut s, "s")[0], "name=\"demo\"");
    assert_eq!(kids(&mut s, "s 1"), ["0=Circle(Point { x: 1, y: 2 }, 3.0)+", "1=Square(Point { x: 0, y: 0 }, 1.5)+", "2=Empty"]);
    assert_eq!(kids(&mut s, "s 1 0"), ["c=Point { x: 1, y: 2 }+", "r=3.0"]);
    assert_eq!(kids(&mut s, "s 1 1"), ["0=Point { x: 0, y: 0 }+", "1=1.5"]);
    assert_eq!(kids(&mut s, "s 1 0 0"), ["x=1", "y=2"]);
    assert_eq!(kids(&mut s, "s 2"), ["\"a\"=1", "\"b\"=2"]);
    assert_eq!(kids(&mut s, "s 3"), ["some=Point { x: 9, y: 9 }+"]);
    assert_eq!(kids(&mut s, "s 4"), ["0=7", "1=\"seven\""]);
    // long lists: the first 1000, and how many more
    let r = s.cmd("kids 0 1 big");
    assert_eq!((r.get("kids").as_arr().len(), r.get("more").as_i64()), (1000, Some(500)));
    // an element past the first 1000 can still be reached by its index (an int has no parts)
    assert_eq!(s.cmd("kids 0 1 big 1234").get("msg").as_str(), Some("no such part"));
    for bad in ["s 1 7", "s 0", "nope"] {
        assert_eq!(s.cmd(&format!("kids 0 1 {bad}")).get("ev").as_str(), Some("error"), "{bad}");
    }
    s.cmd("kill");
}

/// A DAP client of `auk dap`.
struct Dap {
    child: Child,
    out: BufReader<std::process::ChildStdout>,
    seq: i64,
    seen: Vec<Json>,
}

impl Dap {
    fn start() -> Dap {
        let mut child = auk_cmd().arg("dap").stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::inherit()).spawn().unwrap();
        let out = BufReader::new(child.stdout.take().unwrap());
        Dap { child, out, seq: 0, seen: Vec::new() }
    }

    fn read(&mut self) -> Json {
        let mut len = 0;
        loop {
            let mut l = String::new();
            assert!(self.out.read_line(&mut l).unwrap() > 0, "auk dap closed");
            let l = l.trim();
            if l.is_empty() {
                break;
            }
            if let Some(n) = l.strip_prefix("Content-Length:") {
                len = n.trim().parse().unwrap();
            }
        }
        let mut b = vec![0u8; len];
        std::io::Read::read_exact(&mut self.out, &mut b).unwrap();
        json::parse(std::str::from_utf8(&b).unwrap()).unwrap()
    }

    fn req(&mut self, cmd: &str, args: Json) -> Json {
        self.seq += 1;
        let m = json::obj([("seq", self.seq.into()), ("type", "request".into()), ("command", cmd.into()), ("arguments", args)]).to_string();
        let stdin = self.child.stdin.as_mut().unwrap();
        write!(stdin, "Content-Length: {}\r\n\r\n{m}", m.len()).unwrap();
        stdin.flush().unwrap();
        loop {
            let r = self.read();
            if r.get("type").as_str() == Some("response") && r.get("request_seq").as_i64() == Some(self.seq) {
                return r;
            }
            self.seen.push(r);
        }
    }

    fn event(&mut self, name: &str) -> Json {
        if let Some(i) = self.seen.iter().position(|e| e.get("event").as_str() == Some(name)) {
            return self.seen.remove(i);
        }
        loop {
            let e = self.read();
            if e.get("event").as_str() == Some(name) {
                return e;
            }
            self.seen.push(e);
        }
    }

    /// The top frame's id and its locals as "name=value".
    fn top(&mut self) -> (i64, Vec<(String, i64)>) {
        let st = self.req("stackTrace", json::obj([("threadId", 1i64.into())]));
        let fid = st.at(&["body", "stackFrames"]).as_arr()[0].get("id").as_i64().unwrap();
        let sc = self.req("scopes", json::obj([("frameId", fid.into())]));
        let r = sc.at(&["body", "scopes"]).as_arr()[0].get("variablesReference").as_i64().unwrap();
        (fid, self.vars(r))
    }

    fn vars(&mut self, r: i64) -> Vec<(String, i64)> {
        let v = self.req("variables", json::obj([("variablesReference", r.into())]));
        v.at(&["body", "variables"]).as_arr().iter().map(|x| (format!("{}={}", x.get("name").as_str().unwrap(), x.get("value").as_str().unwrap()), x.get("variablesReference").as_i64().unwrap())).collect()
    }
}

#[test]
fn dap_session() {
    let f = prog_file("dap", SCENE);
    let path = f.display().to_string();
    let mut d = Dap::start();
    let init = d.req("initialize", json::obj([("adapterID", "auk".into())]));
    assert_eq!(init.at(&["body", "supportsConfigurationDoneRequest"]), &Json::Bool(true));
    let r = d.req("launch", json::obj([("program", path.as_str().into()), ("stopOnEntry", true.into())]));
    assert_eq!(r.get("success"), &Json::Bool(true), "{r:?}");
    d.event("initialized");
    let bps = d.req("setBreakpoints", json::obj([("source", json::obj([("path", path.as_str().into())])), ("breakpoints", Json::Arr(vec![json::obj([("line", 7i64.into())]), json::obj([("line", 99i64.into())])]))]));
    let b = bps.at(&["body", "breakpoints"]).as_arr();
    assert_eq!((b[0].get("verified"), b[0].get("line").as_i64(), b[1].get("verified")), (&Json::Bool(true), Some(7), &Json::Bool(false)));
    d.req("setExceptionBreakpoints", json::obj([("filters", Json::Arr(vec!["uncaught".into()]))]));
    d.req("configurationDone", Json::Null);
    let st = d.event("stopped");
    assert_eq!(st.at(&["body", "reason"]).as_str(), Some("entry"));
    d.req("continue", json::obj([("threadId", 1i64.into())]));
    let st = d.event("stopped");
    assert_eq!(st.at(&["body", "reason"]).as_str(), Some("breakpoint"));
    let (fid, locals) = d.top();
    assert_eq!(locals.len(), 1);
    assert!(locals[0].0.starts_with("s=Scene { name: \"demo\""), "{locals:?}");
    // expand s.shapes[0].c
    let s = d.vars(locals[0].1);
    let shapes = s.iter().find(|(n, _)| n.starts_with("shapes=")).unwrap().1;
    let circle = d.vars(shapes)[0].1;
    let c = d.vars(circle);
    assert_eq!(c[0].0, "c=Point { x: 1, y: 2 }");
    assert_eq!(d.vars(c[0].1).into_iter().map(|x| x.0).collect::<Vec<_>>(), ["x=1", "y=2"]);
    // hover a path
    let ev = d.req("evaluate", json::obj([("expression", "s.shapes[1].0.x".into()), ("frameId", fid.into()), ("context", "hover".into())]));
    assert_eq!(ev.at(&["body", "result"]).as_str(), Some("0"), "{ev:?}");
    assert_eq!(d.req("evaluate", json::obj([("expression", "s.nope".into()), ("frameId", fid.into())])).get("success"), &Json::Bool(false));
    d.req("next", json::obj([("threadId", 1i64.into())]));
    assert_eq!(d.event("stopped").at(&["body", "reason"]).as_str(), Some("step"));
    d.req("setBreakpoints", json::obj([("source", json::obj([("path", path.as_str().into())])), ("breakpoints", Json::Arr(vec![]))]));
    d.req("continue", json::obj([("threadId", 1i64.into())]));
    let out = d.event("output");
    assert_eq!(out.at(&["body", "output"]).as_str(), Some("demo\n"));
    assert_eq!(d.event("exited").at(&["body", "exitCode"]).as_i64(), Some(0));
    d.event("terminated");
    d.req("disconnect", Json::Null);
    assert!(d.child.wait().unwrap().success());
}

#[test]
fn dap_panics_and_compile_errors() {
    let f = prog_file("dappanic", "fn main() {\n    let xs = [1, 2]\n    print(\"{xs[5]}\")\n}\n");
    let mut d = Dap::start();
    d.req("initialize", Json::Null);
    d.req("launch", json::obj([("program", f.display().to_string().into())]));
    d.event("initialized");
    d.req("setExceptionBreakpoints", json::obj([("filters", Json::Arr(vec!["uncaught".into()]))]));
    d.req("configurationDone", Json::Null);
    let st = d.event("stopped");
    assert_eq!(st.at(&["body", "reason"]).as_str(), Some("exception"));
    assert!(st.at(&["body", "text"]).as_str().unwrap().contains("out of range"), "{st:?}");
    d.req("terminate", Json::Null);
    d.event("terminated");
    d.req("disconnect", Json::Null);
    d.child.wait().unwrap();
    // a program that doesn't compile: its errors in the console, a failed launch
    let f = prog_file("dapbad", "fn main() {\n    let x: int = \"a\"\n}\n");
    let mut d = Dap::start();
    d.req("initialize", Json::Null);
    let r = d.req("launch", json::obj([("program", f.display().to_string().into())]));
    assert_eq!(r.get("success"), &Json::Bool(false));
    let out = d.seen.iter().find(|e| e.get("event").as_str() == Some("output")).cloned().unwrap_or_else(|| d.event("output"));
    assert!(out.at(&["body", "output"]).as_str().unwrap().contains("E0200"), "{out:?}");
    d.req("disconnect", Json::Null);
    d.child.wait().unwrap();
}

// ---- native debug info (`auk build -g`) ----

fn have(tool: &str) -> bool {
    Command::new("which").arg(tool).output().is_ok_and(|o| o.status.success())
}

#[test]
fn native_line_tables() {
    // PROG with inputs the optimizer can't fold away (the loop bound comes from the arguments)
    // and every computed value used, on the same lines
    let prog = PROG.replace("fn main() {", "fn main(args: [str]) {").replace("for i in 0..3 {", "for i in 0..args.len() + 2 {").replace(r#"print("{p.x} {x}")"#, r#"print("{p.x} {p.y} {x}")"#);
    let f = prog_file("native", &prog);
    let dir = f.parent().unwrap();
    let out = dir.join("prog");
    let o = auk_cmd().arg("build").arg("-g").arg(&f).arg("-o").arg(&out).output().unwrap();
    assert!(o.status.success(), "{}", String::from_utf8_lossy(&o.stderr));
    assert_eq!(String::from_utf8_lossy(&Command::new(&out).output().unwrap().stdout), "4 5 7\n");
    if !cfg!(target_os = "macos") || !have("lldb") || !have("dwarfdump") {
        eprintln!("skipped: needs macOS with lldb and dwarfdump");
        return;
    }
    let dsym = dir.join("prog.dSYM");
    assert!(dsym.is_dir(), "no .dSYM");
    // a compile unit for the program, with its functions by their Auk names and a line table
    let info = String::from_utf8_lossy(&Command::new("dwarfdump").arg("--debug-info").arg(&dsym).output().unwrap().stdout).into_owned();
    assert!(info.contains("(\"auk ") && info.contains("(\"prog.fact\")") && info.contains("(\"prog.main\")"), "{info:.2000}");
    // lldb: line and function breakpoints, the backtrace in Auk terms
    let o = Command::new("lldb")
        .current_dir(dir)
        .args(["-b", "-o", "b prog.auk:5", "-o", "b prog.fact", "-o", "run", "-o", "bt 2", "-o", "c", "-o", "bt 2", "-o", "kill"])
        .arg(&out)
        .output()
        .unwrap();
    let t = String::from_utf8_lossy(&o.stdout);
    // the line breakpoint is in `add`, which an optimized build may have inlined into its caller
    // (`where = prog`dk_main_shim + 220 [inlined] prog.add + 16 at prog.auk:5:5`)
    let bp1 = t.lines().find(|l| l.starts_with("Breakpoint 1: where = prog`")).unwrap_or_else(|| panic!("no breakpoint 1 in:\n{t}"));
    assert!(bp1.contains("prog`prog.add") || bp1.contains("[inlined] prog.add"), "{bp1}");
    for want in [
        "at prog.auk:5:5",
        "Breakpoint 2: where = prog`prog.fact",
        "frame #0: 0x",
        "prog`prog.add at prog.auk:5:5",
        "prog`prog.main at prog.auk:21:5",
        "prog`prog.fact at prog.auk:10:5",
    ] {
        assert!(t.contains(want), "missing {want:?} in:\n{t}");
    }
    // without -g: no debug info
    let o = auk_cmd().arg("build").arg(&f).arg("-o").arg(dir.join("plain")).output().unwrap();
    assert!(o.status.success());
    assert!(!dir.join("plain.dSYM").exists());
}

// ---- expressions at a stop, conditional breakpoints ----

const EVAL: &str = r#"struct Point { x: int, y: int }

fn dist2(p: Point): int = p.x * p.x + p.y * p.y

fn fact(n: int): int {
    if n <= 1 {
        return 1
    }
    n * fact(n - 1)
}

fn main() {
    let pts = [Point { x: 1, y: 2 }, Point { x: 3, y: 4 }]
    var total = 0
    for i in 0..5 {
        total += i
    }
    print("{total} {fact(5)} {pts.len()}")
}
"#;

#[test]
fn expressions_and_conditions() {
    let mut s = Session::start("eval", EVAL);
    let b = s.cmd("break prog.auk:16 if i == 3");
    assert_eq!(b.get("cond").as_str(), Some("i == 3"));
    s.cmd("break fact if n == 2");
    // stops only where the condition holds
    assert_eq!(s.go("run"), ("breakpoint".into(), "prog.main".into(), 16));
    let ev = |s: &mut Session, e: &str| -> Result<String, String> {
        let r = s.cmd(&format!("eval 0 1 {e}"));
        match r.get("ev").as_str() {
            Some("value") => Ok(format!("{}: {}", r.get("value").as_str().unwrap(), r.get("type").as_str().unwrap())),
            _ => Err(r.get("msg").as_str().unwrap_or("").to_string()),
        }
    };
    assert_eq!(ev(&mut s, "i").as_deref(), Ok("3: int"));
    assert_eq!(ev(&mut s, "i * 10 + total").as_deref(), Ok("33: int"));
    assert_eq!(ev(&mut s, "dist2(pts[1])").as_deref(), Ok("25: int"));
    assert_eq!(ev(&mut s, "pts.map(p => p.x)").as_deref(), Ok("[1, 3]: [int]"));
    assert_eq!(ev(&mut s, "pts[0]").as_deref(), Ok("Point { x: 1, y: 2 }: Point"));
    assert_eq!(ev(&mut s, "nope"), Err("unknown name `nope`".into()));
    assert!(ev(&mut s, "1 +").is_err());
    // a panic in the expression is an error; the program lives on
    assert_eq!(ev(&mut s, "pts[7]"), Err("panic: index 7 out of range for length 2".into()));
    // an assignment changes the frame's variable
    assert_eq!(ev(&mut s, "total = total + 100").as_deref(), Ok("(): ()"));
    assert_eq!(ev(&mut s, "total").as_deref(), Ok("103: int"));
    assert_eq!(s.go("continue"), ("breakpoint".into(), "prog.fact".into(), 6));
    assert_eq!(s.vars(0), ["n=2"]);
    // a caller's frame
    assert_eq!(s.cmd("eval 1 1 n + 1").get("value").as_str(), Some("4"));
    s.cmd("delete");
    // a condition that doesn't compile stops, and says why
    s.cmd("break fact if n <");
    let (reason, ..) = s.go("continue");
    assert_eq!(reason, "breakpoint");
    s.cmd("delete");
    s.cmd("continue");
    s.wait("exited");
    // 103 at i == 3, then + 3 + 4
    assert_eq!(s.finish(), (0, "110 120 2\n".into()));
}

#[test]
fn expressions_in_auk_debug() {
    let f = prog_file("evalcli", EVAL);
    let (code, out) = debug_cmd(&["-b", "prog.auk:16 if i % 2 == 1", "-p", "total,pts[1].x", "-e", "dist2(pts[0]) + i"], &f);
    assert_eq!(code, 0, "{out}");
    let want = "\
#1 breakpoint at prog.auk:16 in prog.main
  total = 0
  pts[1].x = 3
  dist2(pts[0]) + i = 6
#2 breakpoint at prog.auk:16 in prog.main
  total = 3
  pts[1].x = 3
  dist2(pts[0]) + i = 8
";
    assert!(out.replace(&format!("{}/", fs::canonicalize(f.parent().unwrap()).unwrap().display()), "").starts_with(want), "{out}");
    // the prompt: `p <expression>`, `p x = v`, `b <line> if <cond>`
    let mut c = auk_cmd().arg("debug").arg("--repl").arg(&f).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().unwrap();
    c.stdin.take().unwrap().write_all(b"b 16 if i == 2\nr\np i * 100\np total = 1000\np total\nd\nc\n").unwrap();
    let o = c.wait_with_output().unwrap();
    let out = String::from_utf8_lossy(&o.stdout).replace(&format!("{}/", fs::canonicalize(f.parent().unwrap()).unwrap().display()), "");
    for want in ["breakpoint 1 at prog.auk:16 if i == 2", "i * 100: int = 200", "total: int = 1000", "1009 120 2"] {
        assert!(out.contains(want), "missing {want:?} in:\n{out}");
    }
}

#[test]
fn dap_expressions() {
    let f = prog_file("dapeval", EVAL);
    let path = f.display().to_string();
    let mut d = Dap::start();
    let init = d.req("initialize", Json::Null);
    assert_eq!(init.at(&["body", "supportsConditionalBreakpoints"]), &Json::Bool(true));
    d.req("launch", json::obj([("program", path.as_str().into())]));
    d.event("initialized");
    let bp = json::obj([("line", 16i64.into()), ("condition", "i == 4".into())]);
    d.req("setBreakpoints", json::obj([("source", json::obj([("path", path.as_str().into())])), ("breakpoints", Json::Arr(vec![bp]))]));
    d.req("configurationDone", Json::Null);
    d.event("stopped");
    let (fid, locals) = d.top();
    assert!(locals.iter().any(|(n, _)| n == "i=4"), "{locals:?}");
    let ev = |d: &mut Dap, e: &str| d.req("evaluate", json::obj([("expression", e.into()), ("frameId", fid.into()), ("context", "watch".into())]));
    assert_eq!(ev(&mut d, "pts.map(p => dist2(p))").at(&["body", "result"]).as_str(), Some("[5, 25]"));
    // a path keeps its parts expandable
    assert!(ev(&mut d, "pts[1]").at(&["body", "variablesReference"]).as_i64().unwrap() > 0);
    assert_eq!(ev(&mut d, "nope").get("success"), &Json::Bool(false));
    // setVariable on a frame's local
    let st = d.req("stackTrace", json::obj([("threadId", 1i64.into())]));
    let fid = st.at(&["body", "stackFrames"]).as_arr()[0].get("id").as_i64().unwrap();
    let sc = d.req("scopes", json::obj([("frameId", fid.into())]));
    let r = sc.at(&["body", "scopes"]).as_arr()[0].get("variablesReference").as_i64().unwrap();
    let set = d.req("setVariable", json::obj([("variablesReference", r.into()), ("name", "total".into()), ("value", "50".into())]));
    assert_eq!(set.at(&["body", "value"]).as_str(), Some("50"), "{set:?}");
    d.req("setBreakpoints", json::obj([("source", json::obj([("path", path.as_str().into())])), ("breakpoints", Json::Arr(vec![]))]));
    d.req("continue", json::obj([("threadId", 1i64.into())]));
    assert_eq!(d.event("output").at(&["body", "output"]).as_str(), Some("54 120 2\n"));
    d.event("terminated");
    d.req("disconnect", Json::Null);
    d.child.wait().unwrap();
}

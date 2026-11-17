//! `duck mcp` end to end: spawn the server and speak newline-delimited JSON-RPC 2.0 over its
//! stdio, the way an AI agent's MCP client does.

#[allow(dead_code)]
#[path = "../src/json.rs"]
mod json;

use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{Receiver, channel};
use std::thread;
use std::time::Duration;

use json::{Json, obj};

const TOOLS: &[&str] = &["duck_spec", "duck_check", "duck_run", "duck_test", "duck_debug", "duck_fmt", "duck_explain", "duck_holes"];

struct Client {
    child: Child,
    /// `None` once closed.
    stdin: Option<ChildStdin>,
    rx: Receiver<String>,
    next_id: i64,
}

impl Client {
    /// Start the server and complete the initialize handshake.
    fn start() -> Client {
        let mut c = Client::spawn();
        let r = c.request("initialize", obj([
            ("protocolVersion", "2025-11-25".into()),
            ("capabilities", obj([])),
            ("clientInfo", obj([("name", "duck-tests".into()), ("version", "1".into())])),
        ]));
        let result = r.get("result");
        assert_eq!(result.get("protocolVersion").as_str(), Some("2025-11-25"), "{r}");
        assert!(matches!(result.at(&["capabilities", "tools"]), Json::Obj(_)), "{r}");
        assert_eq!(result.at(&["serverInfo", "name"]).as_str(), Some("duck"));
        assert!(result.at(&["serverInfo", "version"]).as_str().is_some_and(|v| !v.is_empty()));
        c.send(&obj([("jsonrpc", "2.0".into()), ("method", "notifications/initialized".into())]));
        c
    }

    fn spawn() -> Client {
        let mut child = Command::new(env!("CARGO_BIN_EXE_duck"))
            .arg("mcp")
            .current_dir(env!("CARGO_MANIFEST_DIR"))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let stdin = child.stdin.take().unwrap();
        let stdout = BufReader::new(child.stdout.take().unwrap());
        let (tx, rx) = channel();
        thread::spawn(move || {
            for line in stdout.lines() {
                let Ok(line) = line else { break };
                if tx.send(line).is_err() {
                    break;
                }
            }
        });
        Client { child, stdin: Some(stdin), rx, next_id: 1 }
    }

    fn send(&mut self, msg: &Json) {
        self.write_line(&msg.to_string());
    }

    fn write_line(&mut self, line: &str) {
        let w = self.stdin.as_mut().unwrap();
        writeln!(w, "{line}").unwrap();
        w.flush().unwrap();
    }

    /// The next message: exactly one line of JSON.
    fn recv(&self) -> Json {
        let line = self.rx.recv_timeout(Duration::from_secs(120)).expect("no reply from duck mcp");
        assert!(!line.contains('\n'));
        json::parse(&line).unwrap_or_else(|e| panic!("not JSON ({e}): {line}"))
    }

    fn request(&mut self, method: &str, params: Json) -> Json {
        let id = self.next_id;
        self.next_id += 1;
        self.send(&obj([("jsonrpc", "2.0".into()), ("id", id.into()), ("method", method.into()), ("params", params)]));
        let r = self.recv();
        assert_eq!(r.get("jsonrpc").as_str(), Some("2.0"), "{r}");
        assert_eq!(r.get("id").as_i64(), Some(id), "{r}");
        r
    }

    /// Call a tool; returns (text, isError).
    fn call(&mut self, name: &str, args: Json) -> (String, bool) {
        let r = self.request("tools/call", obj([("name", name.into()), ("arguments", args)]));
        let result = r.get("result");
        let content = result.get("content").as_arr();
        assert_eq!(content.len(), 1, "{r}");
        assert_eq!(content[0].get("type").as_str(), Some("text"), "{r}");
        let Json::Bool(is_error) = *result.get("isError") else { panic!("no isError: {r}") };
        (content[0].get("text").as_str().unwrap().to_string(), is_error)
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[test]
fn initialize_and_list_tools() {
    let mut c = Client::start();
    assert_eq!(c.request("ping", obj([])).get("result"), &obj([]));
    let r = c.request("tools/list", obj([]));
    let tools = r.at(&["result", "tools"]).as_arr();
    let names: Vec<&str> = tools.iter().filter_map(|t| t.get("name").as_str()).collect();
    assert_eq!(names, TOOLS);
    for t in tools {
        let name = t.get("name").as_str().unwrap();
        assert!(t.get("description").as_str().is_some_and(|d| d.len() > 40), "{name}: short description");
        let schema = t.get("inputSchema");
        assert_eq!(schema.get("type").as_str(), Some("object"), "{name}");
        let Json::Obj(props) = schema.get("properties") else { panic!("{name}: no properties") };
        for (p, s) in props {
            let ty = s.get("type").as_str();
            assert!(matches!(ty, Some("string" | "number" | "array" | "boolean" | "object")), "{name}.{p}: type {ty:?}");
            assert!(s.get("description").as_str().is_some(), "{name}.{p}: no description");
        }
        for req in schema.get("required").as_arr() {
            let req = req.as_str().unwrap();
            assert!(props.iter().any(|(p, _)| p == req), "{name}: required `{req}` is not a property");
        }
    }
    // tools that execute code say so
    for t in tools {
        let name = t.get("name").as_str().unwrap();
        if name == "duck_run" || name == "duck_test" {
            assert!(t.get("description").as_str().unwrap().contains("executes code"), "{name}");
        }
    }
}

#[test]
fn check_source_with_a_type_error() {
    let mut c = Client::start();
    let src = "fn label(n: int): str = n\n\nfn main() {\n  print(label(1))\n}\n";
    let (text, is_error) = c.call("duck_check", obj([("source", src.into())]));
    assert!(!is_error, "{text}");
    let report = json::parse(&text).unwrap();
    assert_eq!(report.get("file").as_str(), Some("<source>"));
    assert_eq!(report.get("ok"), &Json::Bool(false));
    let d = &report.get("diagnostics").as_arr()[0];
    assert_eq!(d.get("code").as_str(), Some("E0200"), "{text}");
    assert_eq!(d.get("line").as_i64(), Some(1));
    let fix = &d.get("fixes").as_arr()[0];
    assert_eq!(fix.get("text").as_str(), Some("int"), "{text}");
    assert_eq!((fix.get("line").as_i64(), fix.get("col").as_i64(), fix.get("end_col").as_i64()), (Some(1), Some(19), Some(22)));
}

#[test]
fn check_a_clean_example() {
    let mut c = Client::start();
    let (text, is_error) = c.call("duck_check", obj([("path", "examples/hello.duck".into())]));
    assert!(!is_error, "{text}");
    let report = json::parse(&text).unwrap();
    assert_eq!(report.get("ok"), &Json::Bool(true), "{text}");
    assert!(report.get("diagnostics").as_arr().is_empty());
}

#[test]
fn run_hello() {
    let mut c = Client::start();
    let (text, is_error) = c.call("duck_run", obj([("path", "examples/hello.duck".into())]));
    assert!(!is_error, "{text}");
    let r = json::parse(&text).unwrap();
    assert_eq!(r.get("stdout").as_str(), Some("Hello from Duck!\n"));
    assert_eq!(r.get("stderr").as_str(), Some(""));
    assert_eq!(r.get("exit_code").as_i64(), Some(0));
    assert_eq!(r.get("timed_out"), &Json::Bool(false));
}

#[test]
fn test_calc() {
    let mut c = Client::start();
    let (text, is_error) = c.call("duck_test", obj([("path", "examples/calc.duck".into())]));
    assert!(!is_error, "{text}");
    assert!(text.contains("passed, 0 failed"), "{text}");
}

#[test]
fn run_and_test_with_a_trace() {
    let mut c = Client::start();
    let (text, is_error) = c.call("duck_run", obj([("path", "examples/fib.duck".into()), ("trace", Json::Bool(true))]));
    assert!(!is_error, "{text}");
    let r = json::parse(&text).unwrap();
    assert_eq!(r.get("stdout").as_str().unwrap().lines().count(), 10);
    let events = r.get("trace").as_arr();
    assert_eq!(events[0].get("ev").as_str(), Some("call"), "{text}");
    assert_eq!(events[0].get("fn").as_str(), Some("fib.main"));
    let first_fib = events.iter().find(|e| e.get("fn").as_str() == Some("fib.fib")).unwrap();
    assert_eq!(first_fib.get("args").as_arr()[0].as_str(), Some("0"));
    assert_eq!(first_fib.get("loc").as_str(), Some("examples/fib.duck:9:11"));
    assert!(events.iter().all(|e| e.get("ev").as_str().is_some()));
    // without `trace` there is no trace
    let (text, _) = c.call("duck_run", obj([("path", "examples/fib.duck".into())]));
    assert!(json::parse(&text).unwrap().get("trace").is_null());
    // a failing test shows its trace
    let d = std::path::PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("mcp-trace");
    std::fs::create_dir_all(&d).unwrap();
    let f = d.join("t.duck");
    std::fs::write(&f, "fn twice(n: int): int = n + n + 1\ntest \"twice\" { assert twice(2) == 4 }\n").unwrap();
    let path = f.display().to_string();
    let (text, is_error) = c.call("duck_test", obj([("path", path.clone().into()), ("trace", Json::Bool(true))]));
    assert!(is_error, "{text}");
    assert!(text.contains("FAIL twice"), "{text}");
    assert!(text.contains(r#"{"ev":"ret","fn":"t.twice","value":"5","depth":0}"#), "{text}");
    let (text, _) = c.call("duck_test", obj([("path", path.into())]));
    assert!(!text.contains(r#"{"ev":"#), "{text}");
}

#[test]
fn explain_and_spec() {
    let mut c = Client::start();
    let (text, is_error) = c.call("duck_explain", obj([("code", "E0400".into())]));
    assert!(!is_error, "{text}");
    assert!(text.starts_with("E0400"), "{text}");
    let (text, is_error) = c.call("duck_explain", obj([("code", "E9999".into())]));
    assert!(is_error, "{text}");
    assert!(text.contains("not a Duck error code"), "{text}");
    let (text, is_error) = c.call("duck_spec", obj([]));
    assert!(!is_error);
    assert!(text.starts_with("# Duck"), "{}", &text[..text.len().min(100)]);
    assert!(text.len() > 1000);
}

#[test]
fn fmt_messy_source() {
    let mut c = Client::start();
    let (text, is_error) = c.call("duck_fmt", obj([("source", "fn main(){print( 1+2 )}".into())]));
    assert!(!is_error, "{text}");
    assert_eq!(text, "fn main() { print(1 + 2) }\n");
    // a syntax error is reported against the source, not a temp file
    let (text, is_error) = c.call("duck_fmt", obj([("source", "fn main( {".into())]));
    assert!(is_error, "{text}");
}

#[test]
fn errors() {
    let mut c = Client::start();
    for tool in ["duck_check", "duck_run", "duck_test", "duck_debug", "duck_fmt", "duck_holes"] {
        let (text, is_error) = c.call(tool, obj([("path", "examples/no_such_file.duck".into())]));
        assert!(is_error, "{tool}: {text}");
        assert!(text.contains("no such file"), "{tool}: {text}");
    }
    // path and source together, or neither
    let (text, is_error) = c.call("duck_check", obj([("path", "examples/hello.duck".into()), ("source", "".into())]));
    assert!(is_error && text.contains("exactly one"), "{text}");
    let (_, is_error) = c.call("duck_check", obj([]));
    assert!(is_error);
    // protocol errors
    let r = c.request("no/such/method", obj([]));
    assert_eq!(r.at(&["error", "code"]).as_i64(), Some(-32601), "{r}");
    let r = c.request("tools/call", obj([("name", "duck_nope".into()), ("arguments", obj([]))]));
    assert_eq!(r.at(&["error", "code"]).as_i64(), Some(-32602), "{r}");
    c.send(&Json::Str("not json-rpc".into()));
    assert_eq!(c.recv().at(&["error", "code"]).as_i64(), Some(-32600));
    c.write_line("{oops");
    assert_eq!(c.recv().at(&["error", "code"]).as_i64(), Some(-32700));
    // still serving
    assert!(c.request("ping", obj([])).get("error").is_null());
}

#[test]
fn debug_reports_stops() {
    let mut c = Client::start();
    let args = obj([
        ("path", "examples/fib.duck".into()),
        ("breakpoints", Json::Arr(vec!["examples/fib.duck:5".into()])),
        ("max_stops", 2i64.into()),
    ]);
    let (text, is_error) = c.call("duck_debug", args);
    assert!(!is_error, "{text}");
    let r = json::parse(text.trim()).unwrap();
    let stops = r.get("stops").as_arr();
    assert_eq!(stops.len(), 2, "{text}");
    assert_eq!(stops[0].get("fn").as_str(), Some("fib.fib"), "{text}");
    assert!(stops[0].at(&["locals", "n"]).as_str().is_some(), "{text}");
    assert!(r.get("note").as_str().is_some_and(|n| n.contains("max-stops")), "{text}");
    // a missing file is an error result
    let (text, is_error) = c.call("duck_debug", obj([("path", "tests/fixtures/no_such.duck".into())]));
    assert!(is_error, "{text}");
}

#[test]
fn holes_when_available() {
    let has_holes = Command::new(env!("CARGO_BIN_EXE_duck"))
        .arg("help")
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).lines().any(|l| l.trim_start().starts_with("holes")))
        .unwrap();
    let mut c = Client::start();
    let (text, is_error) = c.call("duck_holes", obj([("path", "examples/hello.duck".into())]));
    if has_holes {
        assert!(!is_error, "{text}");
        assert!(json::parse(text.trim()).is_ok(), "not JSON: {text}");
    } else {
        assert!(is_error);
        assert!(text.contains("not available in this build"), "{text}");
    }
}

#[test]
fn closing_stdin_exits() {
    let mut c = Client::start();
    c.stdin = None;
    let status = (0..400)
        .find_map(|_| {
            thread::sleep(Duration::from_millis(25));
            c.child.try_wait().unwrap()
        })
        .expect("duck mcp did not exit when stdin closed");
    assert!(status.success());
}

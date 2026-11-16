//! `duck lsp` end to end: spawn the server, speak framed JSON-RPC over its stdio, and check
//! diagnostics, code actions, hover, go-to-definition, formatting, symbols and shutdown.

#[allow(dead_code)]
#[path = "../src/json.rs"]
mod json;

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{Receiver, channel};
use std::thread;
use std::time::Duration;

use json::{Json, obj};

struct Client {
    child: Child,
    stdin: ChildStdin,
    rx: Receiver<Json>,
    next_id: i64,
    /// Notifications received while waiting for a response.
    pending: Vec<Json>,
}

fn read_frame(r: &mut impl BufRead) -> Option<String> {
    let mut len = 0;
    loop {
        let mut line = String::new();
        if r.read_line(&mut line).ok()? == 0 {
            return None;
        }
        let line = line.trim_end();
        if line.is_empty() {
            break;
        }
        if let Some(v) = line.strip_prefix("Content-Length:") {
            len = v.trim().parse().ok()?;
        }
    }
    let mut buf = vec![0; len];
    r.read_exact(&mut buf).ok()?;
    String::from_utf8(buf).ok()
}

impl Client {
    fn start() -> Client {
        let mut child = Command::new(env!("CARGO_BIN_EXE_duck"))
            .arg("lsp")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let stdin = child.stdin.take().unwrap();
        let mut stdout = BufReader::new(child.stdout.take().unwrap());
        let (tx, rx) = channel();
        thread::spawn(move || {
            while let Some(body) = read_frame(&mut stdout) {
                let msg = json::parse(&body).unwrap_or_else(|e| panic!("server sent bad JSON ({e}): {body}"));
                if tx.send(msg).is_err() {
                    break;
                }
            }
        });
        Client { child, stdin, rx, next_id: 1, pending: Vec::new() }
    }

    fn send(&mut self, msg: Json) {
        let body = msg.to_string();
        write!(self.stdin, "Content-Length: {}\r\n\r\n{body}", body.len()).unwrap();
        self.stdin.flush().unwrap();
    }

    fn recv(&mut self) -> Json {
        self.rx.recv_timeout(Duration::from_secs(20)).expect("no message from the server")
    }

    fn notify(&mut self, method: &str, params: Json) {
        self.send(obj([("jsonrpc", "2.0".into()), ("method", method.into()), ("params", params)]));
    }

    /// Send a request and wait for its response (returns the whole response object).
    fn request_raw(&mut self, method: &str, params: Json) -> Json {
        let id = self.next_id;
        self.next_id += 1;
        self.send(obj([("jsonrpc", "2.0".into()), ("id", id.into()), ("method", method.into()), ("params", params)]));
        loop {
            let msg = self.recv();
            if msg.get("id").as_i64() == Some(id) && msg.get("method").is_null() {
                return msg;
            }
            self.pending.push(msg);
        }
    }

    fn request(&mut self, method: &str, params: Json) -> Json {
        let r = self.request_raw(method, params);
        assert!(r.get("error").is_null(), "{method} failed: {r}");
        r.get("result").clone()
    }

    /// The next `publishDiagnostics` for `uri`.
    fn diagnostics(&mut self, uri: &str) -> Vec<Json> {
        let is_for = |m: &Json| m.get("method").as_str() == Some("textDocument/publishDiagnostics") && m.at(&["params", "uri"]).as_str() == Some(uri);
        if let Some(i) = self.pending.iter().position(is_for) {
            return self.pending.remove(i).at(&["params", "diagnostics"]).as_arr().to_vec();
        }
        loop {
            let m = self.recv();
            if is_for(&m) {
                return m.at(&["params", "diagnostics"]).as_arr().to_vec();
            }
            self.pending.push(m);
        }
    }
}

fn pos(line: u32, character: u32) -> Json {
    obj([("line", line.into()), ("character", character.into())])
}

fn range(l1: u32, c1: u32, l2: u32, c2: u32) -> Json {
    obj([("start", pos(l1, c1)), ("end", pos(l2, c2))])
}

fn doc_pos(uri: &str, line: u32, character: u32) -> Json {
    obj([("textDocument", obj([("uri", uri.into())])), ("position", pos(line, character))])
}

fn uri_of(p: &Path) -> String {
    let mut out = String::from("file://");
    for b in p.display().to_string().bytes() {
        if b.is_ascii_alphanumeric() || b"-._~/".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// A fresh project directory: `quack.toml`, `src/util.duck`, and `src/main.duck` (empty: the
/// editor's buffer is what counts).
fn project(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("duck-lsp-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(dir.join("src")).unwrap();
    fs::write(dir.join("quack.toml"), "[package]\nname = \"app\"\nversion = \"0.1.0\"\n").unwrap();
    fs::write(dir.join("src/util.duck"), "/// Doubles n.\npub fn double(n: int): int = n * 2\n").unwrap();
    fs::write(dir.join("src/main.duck"), "").unwrap();
    dir.canonicalize().unwrap()
}

const BROKEN: &str = r#"/// Adds two numbers.
fn add(a: int, b: int): int = a + b

fn bump(n: var int) { n += 1 }

fn main() {
  let total = add(1, 2)
  let pair: (str, int) = ("🦆", "a")
  var y = 1
  bump(y)
  print("{total} {pair.0} {util.double(total)} {y}")
}
"#;

const FIXED: &str = r#"/// Adds two numbers.
fn add(a: int, b: int): int = a + b

fn bump(n: var int) { n += 1 }

fn main() {
  let total = add(1, 2)
  let pair: (str, int) = ("🦆", 2)
  var y = 1
  bump(&y)
  print("{total} {pair.0} {util.double(total)} {y}")
}
"#;

fn hover_value(c: &mut Client, uri: &str, line: u32, ch: u32) -> String {
    let h = c.request("textDocument/hover", doc_pos(uri, line, ch));
    h.at(&["contents", "value"]).as_str().unwrap_or_else(|| panic!("no hover at {line}:{ch}: {h}")).to_string()
}

#[test]
fn lsp_session() {
    let dir = project("session");
    let main = dir.join("src/main.duck");
    let uri = uri_of(&main);
    let mut c = Client::start();

    // initialize
    let init = c.request("initialize", obj([("processId", Json::Null), ("rootUri", uri_of(&dir).into()), ("capabilities", obj([]))]));
    let caps = init.get("capabilities");
    assert_eq!(caps.at(&["textDocumentSync", "change"]).as_i64(), Some(1), "{init}");
    for cap in ["hoverProvider", "definitionProvider", "documentFormattingProvider", "documentSymbolProvider"] {
        assert_eq!(caps.get(cap), &Json::Bool(true), "{cap}");
    }
    assert!(!caps.get("codeActionProvider").is_null());
    assert_eq!(init.at(&["serverInfo", "name"]).as_str(), Some("duck"));
    c.notify("initialized", obj([]));

    // didOpen with two errors: the diagnostics, with UTF-16 ranges (the duck is two code units)
    let item = obj([("uri", uri.as_str().into()), ("languageId", "duck".into()), ("version", 1i64.into()), ("text", BROKEN.into())]);
    c.notify("textDocument/didOpen", obj([("textDocument", item)]));
    let ds = c.diagnostics(&uri);
    assert_eq!(ds.len(), 2, "{ds:?}");
    assert_eq!(ds[0].get("code").as_str(), Some("E0200"));
    assert_eq!(ds[0].get("message").as_str(), Some("expected `int`, found `str`"));
    assert_eq!(ds[0].get("severity").as_i64(), Some(1));
    assert_eq!(ds[0].get("range"), &range(7, 32, 7, 35));
    assert_eq!(ds[1].get("code").as_str(), Some("E0310"));
    assert_eq!(ds[1].get("range"), &range(9, 7, 9, 8));
    let rel = ds[1].get("relatedInformation").as_arr();
    assert_eq!(rel.len(), 1);
    assert_eq!(rel[0].get("message").as_str(), Some("`bump` may change it; write `&y` to let it change the caller's variable"));
    assert_eq!(rel[0].at(&["location", "uri"]).as_str(), Some(uri.as_str()));

    // a code action for the missing `&`
    let ctx = obj([("diagnostics", Json::Arr(vec![ds[1].clone()]))]);
    let params = obj([("textDocument", obj([("uri", uri.as_str().into())])), ("range", range(9, 7, 9, 7)), ("context", ctx)]);
    let actions = c.request("textDocument/codeAction", params);
    let actions = actions.as_arr();
    assert_eq!(actions.len(), 1, "{actions:?}");
    let a = &actions[0];
    assert_eq!(a.get("title").as_str(), Some("Insert `&`"));
    assert_eq!(a.get("kind").as_str(), Some("quickfix"));
    let edits = a.at(&["edit", "changes"]).get(&uri).as_arr();
    assert_eq!(edits, [obj([("range", range(9, 7, 9, 7)), ("newText", "&".into())])]);
    // no action where there is no fix-it
    let params = obj([("textDocument", obj([("uri", uri.as_str().into())])), ("range", range(7, 33, 7, 33)), ("context", obj([]))]);
    assert_eq!(c.request("textDocument/codeAction", params), Json::Arr(Vec::new()));

    // hover still works in the broken program, wherever the code type-checked
    assert_eq!(hover_value(&mut c, &uri, 6, 7), "```duck\nlet total: int\n```");
    assert_eq!(hover_value(&mut c, &uri, 6, 15), "```duck\nfn add(a: int, b: int): int\n```\n\nAdds two numbers.");
    assert_eq!(hover_value(&mut c, &uri, 7, 7), "```duck\nlet pair: (str, int)\n```");
    assert_eq!(hover_value(&mut c, &uri, 10, 33), "```duck\npub fn double(n: int): int\n```\n\nDoubles n.");

    // didChange fixing both errors: empty diagnostics
    let change = obj([
        ("textDocument", obj([("uri", uri.as_str().into()), ("version", 2i64.into())])),
        ("contentChanges", Json::Arr(vec![obj([("text", FIXED.into())])])),
    ]);
    c.notify("textDocument/didChange", change);
    assert_eq!(c.diagnostics(&uri), Vec::<Json>::new());

    // hover: a `let` binding, a use of it, a function call, a field, a parameter
    assert_eq!(hover_value(&mut c, &uri, 6, 7), "```duck\nlet total: int\n```");
    assert_eq!(hover_value(&mut c, &uri, 10, 11), "```duck\nlet total: int\n```");
    assert_eq!(hover_value(&mut c, &uri, 6, 15), "```duck\nfn add(a: int, b: int): int\n```\n\nAdds two numbers.");
    assert_eq!(hover_value(&mut c, &uri, 7, 7), "```duck\nlet pair: (str, int)\n```");
    assert_eq!(hover_value(&mut c, &uri, 3, 9), "```duck\nvar n: int\n```");
    assert_eq!(hover_value(&mut c, &uri, 10, 33), "```duck\npub fn double(n: int): int\n```\n\nDoubles n.");
    // the whole call expression `add(1, 2)`: its type
    assert_eq!(hover_value(&mut c, &uri, 6, 23), "```duck\nint\n```");
    assert!(c.request("textDocument/hover", doc_pos(&uri, 4, 0)).is_null());

    // definition: a function in another module of the project, a local function, a local
    let util = uri_of(&dir.join("src/util.duck"));
    let def = c.request("textDocument/definition", doc_pos(&uri, 10, 33));
    assert_eq!(def, obj([("uri", util.as_str().into()), ("range", range(1, 7, 1, 13))]));
    let def = c.request("textDocument/definition", doc_pos(&uri, 6, 15));
    assert_eq!(def, obj([("uri", uri.as_str().into()), ("range", range(1, 3, 1, 6))]));
    let def = c.request("textDocument/definition", doc_pos(&uri, 10, 11));
    assert_eq!(def, obj([("uri", uri.as_str().into()), ("range", range(6, 6, 6, 11))]));
    // the module name itself
    let def = c.request("textDocument/definition", doc_pos(&uri, 10, 28));
    assert_eq!(def.get("uri").as_str(), Some(util.as_str()));

    // formatting: a messy buffer comes back as one whole-document edit to the canonical text
    let messy = FIXED.replace("fn add(a: int, b: int): int = a + b", "fn add( a:int,b:int ):int=a+b").replace("  var y = 1", "      var y = 1");
    let change = obj([
        ("textDocument", obj([("uri", uri.as_str().into()), ("version", 3i64.into())])),
        ("contentChanges", Json::Arr(vec![obj([("text", messy.as_str().into())])])),
    ]);
    c.notify("textDocument/didChange", change);
    assert_eq!(c.diagnostics(&uri), Vec::<Json>::new());
    let opts = obj([("tabSize", 2u32.into()), ("insertSpaces", true.into())]);
    let edits = c.request("textDocument/formatting", obj([("textDocument", obj([("uri", uri.as_str().into())])), ("options", opts)]));
    let edits = edits.as_arr();
    assert_eq!(edits.len(), 1, "{edits:?}");
    assert_eq!(edits[0].get("newText").as_str(), Some(FIXED));
    assert_eq!(edits[0].at(&["range", "start"]), &pos(0, 0));
    assert_eq!(edits[0].at(&["range", "end"]), &pos(13, 0));

    // document symbols
    let syms = c.request("textDocument/documentSymbol", obj([("textDocument", obj([("uri", uri.as_str().into())]))]));
    let names: Vec<&str> = syms.as_arr().iter().filter_map(|s| s.get("name").as_str()).collect();
    assert_eq!(names, ["add", "bump", "main"]);

    // unknown requests get MethodNotFound
    let r = c.request_raw("textDocument/rename", doc_pos(&uri, 0, 0));
    assert_eq!(r.at(&["error", "code"]).as_i64(), Some(-32601));

    // shutdown / exit
    assert!(c.request("shutdown", Json::Null).is_null());
    c.notify("exit", Json::Null);
    let status = c.child.wait().unwrap();
    assert_eq!(status.code(), Some(0));
    let _ = fs::remove_dir_all(&dir);
}

/// Diagnostics in another module of the project are published to that module's file, and a
/// parse error is reported with its code; go-to-definition still works syntactically.
#[test]
fn lsp_other_files_and_parse_errors() {
    let dir = project("other");
    fs::write(dir.join("src/util.duck"), "pub fn double(n: int): int = n * \"2\"\n").unwrap();
    let uri = uri_of(&dir.join("src/main.duck"));
    let util = uri_of(&dir.join("src/util.duck"));
    let mut c = Client::start();
    c.request("initialize", obj([("capabilities", obj([]))]));
    c.notify("initialized", obj([]));
    let text = "fn main() {\n  print(\"{util.double(1)}\")\n}\n";
    let item = obj([("uri", uri.as_str().into()), ("languageId", "duck".into()), ("version", 1i64.into()), ("text", text.into())]);
    c.notify("textDocument/didOpen", obj([("textDocument", item)]));
    assert_eq!(c.diagnostics(&uri), Vec::<Json>::new());
    let ds = c.diagnostics(&util);
    assert_eq!(ds.len(), 1, "{ds:?}");
    assert_eq!(ds[0].get("code").as_str(), Some("E0260"));
    // the program doesn't check, so the definition is found by name
    let def = c.request("textDocument/definition", doc_pos(&uri, 1, 16));
    assert_eq!(def, obj([("uri", util.as_str().into()), ("range", range(0, 7, 0, 13))]));

    // a parse error in the buffer
    let change = obj([
        ("textDocument", obj([("uri", uri.as_str().into()), ("version", 2i64.into())])),
        ("contentChanges", Json::Arr(vec![obj([("text", "fn main() {\n  let x = 1;\n}\n".into())])])),
    ]);
    c.notify("textDocument/didChange", change);
    let ds = c.diagnostics(&uri);
    assert_eq!(ds.len(), 1, "{ds:?}");
    assert_eq!(ds[0].get("code").as_str(), Some("E0011"));
    assert_eq!(ds[0].get("range"), &range(1, 11, 1, 12));
    // its fix-it removes the semicolon; util.duck's errors are cleared (no longer checked)
    assert_eq!(c.diagnostics(&util), Vec::<Json>::new());
    let params = obj([("textDocument", obj([("uri", uri.as_str().into())])), ("range", range(1, 11, 1, 12)), ("context", obj([]))]);
    let actions = c.request("textDocument/codeAction", params);
    let a = &actions.as_arr()[0];
    assert_eq!(a.get("title").as_str(), Some("Remove the text"));
    assert_eq!(a.at(&["edit", "changes"]).get(&uri).as_arr(), [obj([("range", range(1, 11, 1, 12)), ("newText", "".into())])]);

    c.request("shutdown", Json::Null);
    c.notify("exit", Json::Null);
    assert_eq!(c.child.wait().unwrap().code(), Some(0));
    let _ = fs::remove_dir_all(&dir);
}

/// Definitions and hovers for struct and enum types, fields and variants, in the file and in an
/// installed dependency (`.quack/geo`).
#[test]
fn lsp_types_fields_variants_and_deps() {
    let dir = project("deps");
    fs::write(dir.join("quack.toml"), "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[deps]\ngeo = \"^0.1\"\n").unwrap();
    let geo_dir = dir.join(".quack/geo");
    fs::create_dir_all(geo_dir.join("src")).unwrap();
    fs::write(geo_dir.join("quack.toml"), "[package]\nname = \"geo\"\nversion = \"0.1.0\"\n").unwrap();
    let lib = "/// A point.
pub struct Point { x: float, y: float }

pub enum Shape { Circle(r: float), Square(s: float) }

pub fn area(s: Shape): float = match s {
  Circle(r) => 3.0 * r * r
  Square(w) => w * w
}
";
    fs::write(geo_dir.join("src/lib.duck"), lib).unwrap();
    let text = r#"struct Item { name: str, qty: int }

fn total(xs: [Item]): int = xs.map(i => i.qty).sum()

fn main() {
  let it = Item { name: "a", qty: 2 }
  let p = geo.Point { x: 1.0, y: 2.0 }
  let s = geo.Shape.Circle(1.0)
  match s {
    Circle(r) => print("{r}")
    _ => print("other")
  }
  print("{total([it])} {p.x} {geo.area(s)} {it.name}")
  print([("a", 1)].first()?.1)
}
"#;
    let uri = uri_of(&dir.join("src/main.duck"));
    let geo = uri_of(&geo_dir.join("src/lib.duck"));
    let mut c = Client::start();
    c.request("initialize", obj([("capabilities", obj([]))]));
    let item = obj([("uri", uri.as_str().into()), ("languageId", "duck".into()), ("version", 1i64.into()), ("text", text.into())]);
    c.notify("textDocument/didOpen", obj([("textDocument", item)]));
    assert_eq!(c.diagnostics(&uri), Vec::<Json>::new());

    let mut def = |line: u32, ch: u32| c.request("textDocument/definition", doc_pos(&uri, line, ch));
    let here = |l1, c1, l2, c2| obj([("uri", uri.as_str().into()), ("range", range(l1, c1, l2, c2))]);
    let there = |l1, c1, l2, c2| obj([("uri", geo.as_str().into()), ("range", range(l1, c1, l2, c2))]);
    assert_eq!(def(2, 15), here(0, 7, 0, 11), "type in a signature");
    assert_eq!(def(2, 43), here(0, 25, 0, 28), "field read");
    assert_eq!(def(5, 12), here(0, 7, 0, 11), "struct literal type");
    assert_eq!(def(5, 19), here(0, 14, 0, 18), "struct literal field");
    assert_eq!(def(12, 46), here(5, 6, 5, 8), "local");
    assert_eq!(def(6, 15), there(1, 11, 1, 16), "dependency struct");
    assert_eq!(def(7, 21), there(3, 17, 3, 23), "dependency variant constructor");
    assert_eq!(def(9, 5), there(3, 17, 3, 23), "variant pattern");
    assert_eq!(def(12, 35), there(5, 7, 5, 11), "dependency function");
    assert_eq!(def(12, 26), there(1, 19, 1, 20), "dependency field");

    assert_eq!(hover_value(&mut c, &uri, 12, 26), "```duck\nx: float\n```");
    assert_eq!(hover_value(&mut c, &uri, 6, 15), "```duck\npub struct Point\n```\n\nA point.");
    assert_eq!(hover_value(&mut c, &uri, 9, 5), "```duck\nShape.Circle(r: float)\n```");
    assert_eq!(hover_value(&mut c, &uri, 7, 21), "```duck\nShape.Circle(r: float)\n```");
    assert_eq!(hover_value(&mut c, &uri, 2, 40), "```duck\nlet i: Item\n```");
    assert_eq!(hover_value(&mut c, &uri, 12, 35), "```duck\npub fn area(s: Shape): float\n```");
    assert_eq!(hover_value(&mut c, &uri, 12, 31), "```duck\nmodule geo\n```");
    assert_eq!(hover_value(&mut c, &uri, 13, 28), "```duck\nint?\n```", "`?.1` of a tuple");
    assert!(c.request("textDocument/definition", doc_pos(&uri, 13, 28)).is_null(), "a tuple element has no definition");

    c.request("shutdown", Json::Null);
    c.notify("exit", Json::Null);
    assert_eq!(c.child.wait().unwrap().code(), Some(0));
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn lsp_hover_shows_units() {
    let dir = project("units");
    let text = "fn speed(d: float<m>, t: float<s>): float<m/s> = d / t\n\nfn main() {\n  let v = speed(3.0<m>, 2.0<s>)\n  print(\"{v}\")\n}\n";
    let uri = uri_of(&dir.join("src/main.duck"));
    let mut c = Client::start();
    c.request("initialize", obj([("capabilities", obj([]))]));
    let item = obj([("uri", uri.as_str().into()), ("languageId", "duck".into()), ("version", 1i64.into()), ("text", text.into())]);
    c.notify("textDocument/didOpen", obj([("textDocument", item)]));
    assert_eq!(c.diagnostics(&uri), Vec::<Json>::new());
    assert_eq!(hover_value(&mut c, &uri, 3, 6), "```duck\nlet v: float<m/s>\n```");
    assert_eq!(hover_value(&mut c, &uri, 3, 11), "```duck\nfn speed(d: float<m>, t: float<s>): float<m/s>\n```");
    c.request("shutdown", Json::Null);
    c.notify("exit", Json::Null);
    assert_eq!(c.child.wait().unwrap().code(), Some(0));
    let _ = fs::remove_dir_all(&dir);
}

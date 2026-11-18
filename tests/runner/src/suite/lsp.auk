/// tests/lsp.rs: `auk lsp` end to end: spawn the server, speak framed JSON-RPC over its stdio,
/// and check diagnostics, code actions, hover, go-to-definition, formatting, symbols and
/// shutdown.

pub fn tests(): [t.Test] uses env, fs, ffi, time = [
  t.test("lsp_session", lsp_session),
  t.test("lsp_other_files_and_parse_errors", lsp_other_files_and_parse_errors),
  t.test("lsp_types_fields_variants_and_deps", lsp_types_fields_variants_and_deps),
  t.test("lsp_hover_shows_units", lsp_hover_shows_units),
]

/// How long to wait for a message from the server (Rust: 20 s).
let RECV_MS = 20000

struct Client {
  child: sys.Child,
  next_id: int,
  /// Notifications received while waiting for a response.
  pending: [json.Json],
}

/// One framed message's body, or none at end of output (or after the timeout).
fn read_frame(c: var sys.Child): str? uses ffi, time {
  var len = 0
  loop {
    let line = sys.read_line(&c, RECV_MS)?
    let line = line.trim_end()
    if line == "" { break }
    match line.strip_prefix("Content-Length:") {
      some(v) => len = int.parse(v.trim()) else return none
      none => {}
    }
  }
  let buf = sys.read_exact(&c, len, RECV_MS)?
  str.from_utf8(buf) else return none
}

fn start(): Client uses env, ffi, time {
  Client { child: t.auk().arg("lsp").start(), next_id: 1, pending: [] }
}

fn send(c: var Client, msg: json.Json) uses ffi, time {
  let body = msg.text()
  t.check(
    sys.write(&c.child, "Content-Length: {body.byte_len()}\r\n\r\n{body}".bytes(), RECV_MS),
    "writing to the server failed",
  )
}

fn recv(c: var Client): json.Json uses ffi, time {
  let body = match read_frame(&c.child) {
    some(b) => b
    none => t.bail("no message from the server")
  }
  match json.parse(body) {
    ok(m) => m
    err(Bad(e)) => t.bail("server sent bad JSON ({e}): {body}")
  }
}

fn notify(c: var Client, method: str, params: json.Json) uses ffi, time {
  c.send(json.obj([("jsonrpc", json.of("2.0")), ("method", json.of(method)), ("params", params)]))
}

/// Send a request and wait for its response (returns the whole response object).
fn request_raw(c: var Client, method: str, params: json.Json): json.Json uses ffi, time {
  let id = c.next_id
  c.next_id += 1
  c.send(
    json.obj([
      ("jsonrpc", json.of("2.0")),
      ("id", json.of(id)),
      ("method", json.of(method)),
      ("params", params),
    ]),
  )
  loop {
    let msg = c.recv()
    if msg.get("id").as_i64() == some(id) && msg.get("method").is_null() { return msg }
    c.pending.push(msg)
  }
}

fn request(c: var Client, method: str, params: json.Json): json.Json uses ffi, time {
  let r = c.request_raw(method, params)
  t.check(r.get("error").is_null(), "{method} failed: {r.text()}")
  r.get("result")
}

fn is_diag_for(m: json.Json, uri: str): bool = m.get("method").as_str() ==
  some("textDocument/publishDiagnostics") &&
  m.at(["params", "uri"]).as_str() == some(uri)

/// The next `publishDiagnostics` for `uri`.
fn diagnostics(c: var Client, uri: str): [json.Json] uses ffi, time {
  match c.pending.find_index(m => is_diag_for(m, uri)) {
    some(i) => return c.pending.remove(i).at(["params", "diagnostics"]).as_arr()
    none => {}
  }
  loop {
    let m = c.recv()
    if is_diag_for(m, uri) { return m.at(["params", "diagnostics"]).as_arr() }
    c.pending.push(m)
  }
}

/// Wait for the server to exit: its exit code.
fn wait(c: var Client): int? uses ffi, time = cmd.wait(&c.child, RECV_MS).code

fn pos(line: int, character: int): json.Json =
  json.obj([("line", json.of(line)), ("character", json.of(character))])

fn range(l1: int, c1: int, l2: int, c2: int): json.Json =
  json.obj([("start", pos(l1, c1)), ("end", pos(l2, c2))])

fn doc_pos(uri: str, line: int, character: int): json.Json = json.obj([
  ("textDocument", json.obj([("uri", json.of(uri))])),
  ("position", pos(line, character)),
])

fn uri_of(p: str): str {
  var out = "file://"
  let keep = "-._~/".bytes()
  for b in p.bytes() {
    let alnum = (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122)
    if alnum || keep.contains(b) { out = out + str(char(b)!) } else { out = out + "%{b:02X}" }
  }
  out
}

/// A fresh project directory: `raft.toml`, `src/util.auk`, and `src/main.auk` (empty: the
/// editor's buffer is what counts).
fn project(name: str): str uses fs, ffi {
  let dir = t.temp("auk-lsp-{name}")
  t.write(paths.join(dir, "raft.toml"), "[package]\nname = \"app\"\nversion = \"0.1.0\"\n")
  t.write(paths.join(dir, "src/util.auk"), "/// Doubles n.\npub fn double(n: int): int = n * 2\n")
  t.write(paths.join(dir, "src/main.auk"), "")
  paths.canonicalize(dir)!
}

let BROKEN = r"""
  /// Adds two numbers.
  fn add(a: int, b: int): int = a + b

  fn bump(n: var int) { n += 1 }

  fn main() {
    let total = add(1, 2)
    let pair: (str, int) = ("🦆", "a")
    var y = 1
    bump(y)
    print("{total} {pair.0} {util.double(total)} {y}")
  }
  """

let FIXED = r"""
  /// Adds two numbers.
  fn add(a: int, b: int): int = a + b

  fn bump(n: var int) { n += 1 }

  fn main() {
    let total = add(1, 2)
    let pair: (str, int) = ("🦆", 2)
    var y = 1
    bump(&y)
    print("{total} {pair.0} {util.double(total)} {y}")
  }
  """

fn hover_value(c: var Client, uri: str, line: int, ch: int): str uses ffi, time {
  let h = c.request("textDocument/hover", doc_pos(uri, line, ch))
  let v = match h.at(["contents", "value"]).as_str() {
    some(v) => v
    none => t.bail("no hover at {line}:{ch}: {h.text()}")
  }
  // links to files keep only the file name: `[util.auk:2](file:///tmp/…/util.auk#L2)` → `(util.auk#L2)`
  var out = ""
  var rest = v
  loop {
    let i = rest.find("](file://") else break
    out = out + rest[0..i + 2]
    let url = rest[i + 2..rest.len()]
    let end = url.find(")") else url.len()
    let head = url[0..end]
    var slash = -1
    for j, ch in head.chars() { if ch == '/' { slash = j } }
    out = out + url[slash + 1..end]
    rest = url[end..url.len()]
  }
  out + rest
}

fn change(uri: str, version: int, text: str): json.Json = json.obj([
  ("textDocument", json.obj([("uri", json.of(uri)), ("version", json.of(version))])),
  ("contentChanges", json.of([json.obj([("text", json.of(text))])])),
])

fn open_item(uri: str, text: str): json.Json = json.obj([
  (
    "textDocument",
    json.obj([
      ("uri", json.of(uri)),
      ("languageId", json.of("auk")),
      ("version", json.of(1)),
      ("text", json.of(text)),
    ]),
  ),
])

fn lsp_session() uses env, fs, ffi, time {
  let dir = project("session")
  let main = paths.join(dir, "src/main.auk")
  let uri = uri_of(main)
  var c = start()

  // initialize
  let init = c.request(
    "initialize",
    json.obj([
      ("processId", json.Json.Null),
      ("rootUri", json.of(uri_of(dir))),
      ("capabilities", json.obj([])),
    ]),
  )
  let caps = init.get("capabilities")
  t.check(caps.at(["textDocumentSync", "change"]).as_i64() == some(1), init.text())
  for cap in [
    "hoverProvider",
    "definitionProvider",
    "documentFormattingProvider",
    "documentSymbolProvider",
  ] {
    t.check(caps.get(cap) == json.Json.Bool(true), cap)
  }
  assert !caps.get("codeActionProvider").is_null()
  assert init.at(["serverInfo", "name"]).as_str() == some("auk")
  c.notify("initialized", json.obj([]))

  // didOpen with two errors: the diagnostics, with UTF-16 ranges (the auk is two code units)
  c.notify("textDocument/didOpen", open_item(uri, BROKEN))
  let ds = c.diagnostics(uri)
  t.check(ds.len() == 2, json.of(ds).text())
  assert ds[0].get("code").as_str() == some("E0200")
  assert ds[0].get("message").as_str() == some("expected `int`, found `str`")
  assert ds[0].get("severity").as_i64() == some(1)
  assert ds[0].get("range") == range(7, 32, 7, 35)
  assert ds[1].get("code").as_str() == some("E0310")
  assert ds[1].get("range") == range(9, 7, 9, 8)
  let rel = ds[1].get("relatedInformation").as_arr()
  assert rel.len() == 1
  assert rel[0].get("message").as_str() ==
    some("`bump` may change it; write `&y` to let it change the caller's variable")
  assert rel[0].at(["location", "uri"]).as_str() == some(uri)

  // a code action for the missing `&`
  let ctx = json.obj([("diagnostics", json.of([ds[1]]))])
  let params = json.obj([
    ("textDocument", json.obj([("uri", json.of(uri))])),
    ("range", range(9, 7, 9, 7)),
    ("context", ctx),
  ])
  let actions = c.request("textDocument/codeAction", params).as_arr()
  t.check(actions.len() == 1, json.of(actions).text())
  let a = actions[0]
  assert a.get("title").as_str() == some("Insert `&`")
  assert a.get("kind").as_str() == some("quickfix")
  let edits = a.at(["edit", "changes"]).get(uri).as_arr()
  assert edits == [json.obj([("range", range(9, 7, 9, 7)), ("newText", json.of("&"))])]
  // no action where there is no fix-it
  let params = json.obj([
    ("textDocument", json.obj([("uri", json.of(uri))])),
    ("range", range(7, 33, 7, 33)),
    ("context", json.obj([])),
  ])
  assert c.request("textDocument/codeAction", params) == json.Json.Arr([])

  // hover still works in the broken program, wherever the code type-checked
  assert hover_value(&c, uri, 6, 7) == "```auk\nlet total: int\n```"
  assert hover_value(&c, uri, 6, 15) ==
    "```auk\nfn add(a: int, b: int): int\n```\n\nAdds two numbers."
  assert hover_value(&c, uri, 7, 7) == "```auk\nlet pair: (str, int)\n```"
  assert hover_value(&c, uri, 10, 33) ==
    "```auk\npub fn double(n: int): int\n```\n\nDefined in `app.util` (this package) — [util.auk:2](util.auk#L2)\n\nDoubles n."

  // didChange fixing both errors: empty diagnostics
  c.notify("textDocument/didChange", change(uri, 2, FIXED))
  assert c.diagnostics(uri) == []

  // hover: a `let` binding, a use of it, a function call, a field, a parameter
  assert hover_value(&c, uri, 6, 7) == "```auk\nlet total: int\n```"
  assert hover_value(&c, uri, 10, 11) == "```auk\nlet total: int\n```"
  assert hover_value(&c, uri, 6, 15) ==
    "```auk\nfn add(a: int, b: int): int\n```\n\nAdds two numbers."
  assert hover_value(&c, uri, 7, 7) == "```auk\nlet pair: (str, int)\n```"
  assert hover_value(&c, uri, 3, 9) == "```auk\nvar n: int\n```"
  assert hover_value(&c, uri, 10, 33) ==
    "```auk\npub fn double(n: int): int\n```\n\nDefined in `app.util` (this package) — [util.auk:2](util.auk#L2)\n\nDoubles n."
  // the whole call expression `add(1, 2)`: its type
  assert hover_value(&c, uri, 6, 23) == "```auk\nint\n```"
  // a core function: where it comes from, without a link (the prelude is compiled in)
  let h = hover_value(&c, uri, 10, 3)
  t.check(h.contains("(core library)") && !h.contains("]("), h)
  assert c.request("textDocument/hover", doc_pos(uri, 4, 0)).is_null()

  // definition: a function in another module of the project, a local function, a local
  let util = uri_of(paths.join(dir, "src/util.auk"))
  let def = c.request("textDocument/definition", doc_pos(uri, 10, 33))
  assert def == json.obj([("uri", json.of(util)), ("range", range(1, 7, 1, 13))])
  let def = c.request("textDocument/definition", doc_pos(uri, 6, 15))
  assert def == json.obj([("uri", json.of(uri)), ("range", range(1, 3, 1, 6))])
  let def = c.request("textDocument/definition", doc_pos(uri, 10, 11))
  assert def == json.obj([("uri", json.of(uri)), ("range", range(6, 6, 6, 11))])
  // the module name itself
  let def = c.request("textDocument/definition", doc_pos(uri, 10, 28))
  assert def.get("uri").as_str() == some(util)

  // formatting: a messy buffer comes back as one whole-document edit to the canonical text
  let messy = FIXED.replace(
    "fn add(a: int, b: int): int = a + b",
    "fn add( a:int,b:int ):int=a+b",
  ).replace("  var y = 1", "      var y = 1")
  c.notify("textDocument/didChange", change(uri, 3, messy))
  assert c.diagnostics(uri) == []
  let opts = json.obj([("tabSize", json.of(2)), ("insertSpaces", json.of(true))])
  let edits = c.request(
    "textDocument/formatting",
    json.obj([("textDocument", json.obj([("uri", json.of(uri))])), ("options", opts)]),
  ).as_arr()
  t.check(edits.len() == 1, json.of(edits).text())
  assert edits[0].get("newText").as_str() == some(FIXED)
  assert edits[0].at(["range", "start"]) == pos(0, 0)
  assert edits[0].at(["range", "end"]) == pos(13, 0)

  // document symbols
  let syms = c.request(
    "textDocument/documentSymbol",
    json.obj([("textDocument", json.obj([("uri", json.of(uri))]))]),
  )
  var names: [str] = []
  for s in syms.as_arr() {
    match s.get("name").as_str() {
      some(n) => names.push(n)
      none => {}
    }
  }
  assert names == ["add", "bump", "main"]

  // unknown requests get MethodNotFound
  let r = c.request_raw("textDocument/rename", doc_pos(uri, 0, 0))
  assert r.at(["error", "code"]).as_i64() == some(-32601)

  // shutdown / exit
  assert c.request("shutdown", json.Json.Null).is_null()
  c.notify("exit", json.Json.Null)
  assert c.wait() == some(0)
  t.rm_rf(dir)
}

/// Diagnostics in another module of the project are published to that module's file, and a
/// parse error is reported with its code; go-to-definition still works syntactically.
fn lsp_other_files_and_parse_errors() uses env, fs, ffi, time {
  let dir = project("other")
  t.write(paths.join(dir, "src/util.auk"), "pub fn double(n: int): int = n * \"2\"\n")
  let uri = uri_of(paths.join(dir, "src/main.auk"))
  let util = uri_of(paths.join(dir, "src/util.auk"))
  var c = start()
  let _ = c.request("initialize", json.obj([("capabilities", json.obj([]))]))
  c.notify("initialized", json.obj([]))
  let text = "fn main() {{\n  print(\"{{util.double(1)}}\")\n}}\n"
  c.notify("textDocument/didOpen", open_item(uri, text))
  assert c.diagnostics(uri) == []
  let ds = c.diagnostics(util)
  t.check(ds.len() == 1, json.of(ds).text())
  assert ds[0].get("code").as_str() == some("E0260")
  // the program doesn't check, so the definition is found by name
  let def = c.request("textDocument/definition", doc_pos(uri, 1, 16))
  assert def == json.obj([("uri", json.of(util)), ("range", range(0, 7, 0, 13))])

  // a parse error in the buffer
  c.notify("textDocument/didChange", change(uri, 2, "fn main() {{\n  let x = 1;\n}}\n"))
  let ds = c.diagnostics(uri)
  t.check(ds.len() == 1, json.of(ds).text())
  assert ds[0].get("code").as_str() == some("E0011")
  assert ds[0].get("range") == range(1, 11, 1, 12)
  // its fix-it removes the semicolon; util.auk's errors are cleared (no longer checked)
  assert c.diagnostics(util) == []
  let params = json.obj([
    ("textDocument", json.obj([("uri", json.of(uri))])),
    ("range", range(1, 11, 1, 12)),
    ("context", json.obj([])),
  ])
  let actions = c.request("textDocument/codeAction", params)
  let a = actions.as_arr()[0]
  assert a.get("title").as_str() == some("Remove the text")
  assert a.at(["edit", "changes"]).get(uri).as_arr() ==
    [json.obj([("range", range(1, 11, 1, 12)), ("newText", json.of(""))])]

  let _ = c.request("shutdown", json.Json.Null)
  c.notify("exit", json.Json.Null)
  assert c.wait() == some(0)
  t.rm_rf(dir)
}

/// Definitions and hovers for struct and enum types, fields and variants, in the file and in an
/// installed dependency (`.raft/geo`).
fn lsp_types_fields_variants_and_deps() uses env, fs, ffi, time {
  let dir = project("deps")
  t.write(
    paths.join(dir, "raft.toml"),
    "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[deps]\ngeo = \"^0.1\"\n",
  )
  let geo_dir = paths.join(dir, ".raft/geo")
  t.write(paths.join(geo_dir, "raft.toml"), "[package]\nname = \"geo\"\nversion = \"0.1.0\"\n")
  let lib = r"""
    /// A point.
    pub struct Point { x: float, y: float }

    pub enum Shape { Circle(r: float), Square(s: float) }

    pub fn area(s: Shape): float = match s {
      Circle(r) => 3.0 * r * r
      Square(w) => w * w
    }
    """
  t.write(paths.join(geo_dir, "src/lib.auk"), lib)
  let text = r"""
    struct Item { name: str, qty: int }

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
    """
  let uri = uri_of(paths.join(dir, "src/main.auk"))
  let geo = uri_of(paths.join(geo_dir, "src/lib.auk"))
  var c = start()
  let _ = c.request("initialize", json.obj([("capabilities", json.obj([]))]))
  c.notify("textDocument/didOpen", open_item(uri, text))
  assert c.diagnostics(uri) == []

  let here = (l1: int, c1: int, l2: int, c2: int) => json.obj([
    ("uri", json.of(uri)),
    ("range", range(l1, c1, l2, c2)),
  ])
  let there = (l1: int, c1: int, l2: int, c2: int) => json.obj([
    ("uri", json.of(geo)),
    ("range", range(l1, c1, l2, c2)),
  ])
  for (l, ch, want, what) in [
    (2, 15, here(0, 7, 0, 11), "type in a signature"),
    (2, 43, here(0, 25, 0, 28), "field read"),
    (5, 12, here(0, 7, 0, 11), "struct literal type"),
    (5, 19, here(0, 14, 0, 18), "struct literal field"),
    (12, 46, here(5, 6, 5, 8), "local"),
    (6, 15, there(1, 11, 1, 16), "dependency struct"),
    (7, 21, there(3, 17, 3, 23), "dependency variant constructor"),
    (9, 5, there(3, 17, 3, 23), "variant pattern"),
    (12, 35, there(5, 7, 5, 11), "dependency function"),
    (12, 26, there(1, 19, 1, 20), "dependency field"),
  ] {
    let got = c.request("textDocument/definition", doc_pos(uri, l, ch))
    t.check(got == want, "{what}: {got.text()} != {want.text()}")
  }

  assert hover_value(&c, uri, 12, 26) ==
    "```auk\nx: float\n```\n\nDefined in `geo` (library `geo`) — [lib.auk:2](lib.auk#L2)"
  assert hover_value(&c, uri, 6, 15) ==
    "```auk\npub struct Point\n```\n\nDefined in `geo` (library `geo`) — [lib.auk:2](lib.auk#L2)\n\nA point."
  assert hover_value(&c, uri, 9, 5) ==
    "```auk\nShape.Circle(r: float)\n```\n\nDefined in `geo` (library `geo`) — [lib.auk:4](lib.auk#L4)"
  assert hover_value(&c, uri, 7, 21) ==
    "```auk\nShape.Circle(r: float)\n```\n\nDefined in `geo` (library `geo`) — [lib.auk:4](lib.auk#L4)"
  assert hover_value(&c, uri, 2, 40) == "```auk\nlet i: Item\n```"
  assert hover_value(&c, uri, 12, 35) ==
    "```auk\npub fn area(s: Shape): float\n```\n\nDefined in `geo` (library `geo`) — [lib.auk:6](lib.auk#L6)"
  assert hover_value(&c, uri, 12, 31) ==
    "```auk\nmodule geo\n```\n\nDefined in `geo` (library `geo`) — [lib.auk:1](lib.auk#L1)"
  t.check(hover_value(&c, uri, 13, 28) == "```auk\nint?\n```", "`?.1` of a tuple")
  t.check(
    c.request("textDocument/definition", doc_pos(uri, 13, 28)).is_null(),
    "a tuple element has no definition",
  )

  let _ = c.request("shutdown", json.Json.Null)
  c.notify("exit", json.Json.Null)
  assert c.wait() == some(0)
  t.rm_rf(dir)
}

fn lsp_hover_shows_units() uses env, fs, ffi, time {
  let dir = project("units")
  let text = "fn speed(d: float<m>, t: float<s>): float<m/s> = d / t\n\nfn main() {{\n  let v = speed(3.0<m>, 2.0<s>)\n  print(\"{{v}}\")\n}}\n"
  let uri = uri_of(paths.join(dir, "src/main.auk"))
  var c = start()
  let _ = c.request("initialize", json.obj([("capabilities", json.obj([]))]))
  c.notify("textDocument/didOpen", open_item(uri, text))
  assert c.diagnostics(uri) == []
  assert hover_value(&c, uri, 3, 6) == "```auk\nlet v: float<m/s>\n```"
  assert hover_value(&c, uri, 3, 11) ==
    "```auk\nfn speed(d: float<m>, t: float<s>): float<m/s>\n```"
  let _ = c.request("shutdown", json.Json.Null)
  c.notify("exit", json.Json.Null)
  assert c.wait() == some(0)
  t.rm_rf(dir)
}

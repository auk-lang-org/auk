/// `auk lsp` (src/lsp.rs): a Language Server Protocol server over stdio (JSON-RPC with
/// `Content-Length` framing), built on the compiler front end.
///
/// - **Diagnostics**: every open/change/save re-runs resolve + check on the in-memory text, in
///   the file's project context (the nearest `raft.toml`, its `src/` modules and `.raft/`
///   dependencies, read from disk), and publishes the errors with code, range and notes (as
///   related information). Errors in other files of the program are published to those files.
/// - **Code actions**: each diagnostic's fix-its become one quick fix (a `WorkspaceEdit`).
/// - **Hover**: the type of the innermost expression or pattern under the cursor (from the
///   `TypedProgram` side tables), a function's signature and `///` docs, a type's docs, and
///   where it is defined when that is another file (core, a library, or this package).
/// - **Go to definition**: locals, constants, functions (the first clause of a clause group),
///   structs, enums, shapes, variants and fields, across modules and dependencies. When the
///   program doesn't type-check, names and paths are looked up syntactically in the module tree.
/// - **Formatting** (`auk fmt`) and **document symbols**.
///
/// Positions: Auk spans are 1-based lines and 1-based columns counted in chars; LSP positions
/// are 0-based lines and 0-based UTF-16 code-unit offsets. `to_lsp` / `from_lsp` convert.
///
/// Differences from Rust: the server keeps the loader's `Sources` (the prelude); a position is
/// an `(int, int)`; `Hit` holds the nodes (reference-counted, so no copies) instead of
/// references; `catch_unwind` is `catch`; Rust's `byte_offset` is `char_offset` (the edit is
/// spliced as chars, the same text); `uri_to_path` keeps invalid UTF-8 percent-escapes
/// undecoded instead of writing U+FFFD.

/// The version the server reports (Cargo.toml's).
pub let VERSION = "0.1.0"

/// Serve on stdin/stdout until `exit`. Returns the process exit code.
pub fn run(cx: resolve.Sources): int uses fs, env, ffi {
  var server = Server { cx, docs: {}, others: {}, diags: {}, shutdown: false, exit: false }
  loop {
    let body = match read_message() {
      ok(some(b)) => b
      ok(none) => return 1 // the client went away without `exit`
      err(Io(e)) => {
        eprint("auk lsp: {e}")
        return 1
      }
    }
    let replies = match json.parse(body) {
      ok(msg) => server.handle(msg)
      err(Bad(e)) => [error_reply(json.Json.Null, -32700, e)]
    }
    for r in replies {
      if !write_message(r) { return 1 }
    }
    if server.exit { return if server.shutdown { 0 } else { 1 } }
  }
}

// ---- framing ----

/// Read one `Content-Length`-framed message body; none at end of input.
pub fn read_message(): str?!stdio.Fail uses env, ffi {
  var len: int? = none
  loop {
    let line = env.read_line() else return none
    let l = line.trim_end()
    if l == "" {
      if len is some(_) { break }
      continue
    }
    match l.find(":") {
      some(i) => if l[0..i].trim().lower() == "content-length" {
        len = match int.parse(l[i + 1..l.len()].trim()) {
          ok(n) => if n >= 0 { some(n) } else { none }
          err(_) => none
        }
      }
      none => {}
    }
  }
  stdio.read_exact(len else 0)?
}

pub fn write_message(msg: json.Json): bool uses ffi {
  let body = msg.text()
  stdio.write_out("Content-Length: {body.byte_len()}\r\n\r\n{body}")
}

fn reply(id: json.Json, result: json.Json): json.Json =
  json.obj([("jsonrpc", json.of("2.0")), ("id", id), ("result", result)])

fn error_reply(id: json.Json, code: int, msg: str): json.Json =
  json.obj([("jsonrpc", json.of("2.0")), ("id", id), ("error", json.obj([("code", json.of(code)), ("message", json.of(msg))]))])

fn notification(method: str, params: json.Json): json.Json =
  json.obj([("jsonrpc", json.of("2.0")), ("method", json.of(method)), ("params", params)])

// ---- positions and URIs ----

/// The text of 0-based line `line` (without its newline).
fn line_text(src: str, line: int): str {
  let l = src.split("\n").get(line) else ""
  l.strip_suffix("\r") else l
}

/// UTF-16 code units of a char.
fn utf16_len(c: char): int = if int(c) > 0xFFFF { 2 } else { 1 }

/// A 1-based (line, char column) to an LSP (line, UTF-16 offset). Columns past the end of the
/// line count one unit per missing char.
pub fn to_lsp(src: str, line: int, col: int): (int, int) {
  let line0 = max(line - 1, 0)
  let n = max(col - 1, 0)
  let text = line_text(src, line0)
  var units = 0
  var seen = 0
  for c in text.chars().take(n) {
    units += utf16_len(c)
    seen += 1
  }
  (line0, units + (n - seen))
}

/// An LSP (line, UTF-16 offset) to a 1-based (line, char column). An offset inside a surrogate
/// pair lands on that char.
pub fn from_lsp(src: str, line: int, character: int): (int, int) {
  let text = line_text(src, line)
  var units = 0
  var chars = 0
  for c in text.chars() {
    if units >= character || units + utf16_len(c) > character { return (line + 1, chars + 1) }
    units += utf16_len(c)
    chars += 1
  }
  (line + 1, chars + (character - units) + 1)
}

fn position(p: (int, int)): json.Json = json.obj([("line", json.of(p.0)), ("character", json.of(p.1))])

fn range(src: str, s: diag.Span): json.Json =
  json.obj([("start", position(to_lsp(src, s.line, s.col))), ("end", position(to_lsp(src, s.end_line, s.end_col)))])

/// Rust's `as_i64().unwrap_or(0) as u32` (a negative number wraps).
fn u32_of(j: json.Json): int {
  let n = j.as_i64() else 0
  n & 0xFFFFFFFF
}

fn json_pos(j: json.Json): (int, int) = (u32_of(j.get("line")), u32_of(j.get("character")))

/// `(a, b) < (c, d)`.
fn pos_lt(a: (int, int), b: (int, int)): bool = a.0 < b.0 || (a.0 == b.0 && a.1 < b.1)

fn pos_le(a: (int, int), b: (int, int)): bool = !pos_lt(b, a)

fn hex_val(b: int): int =
  if b >= 48 && b <= 57 { b - 48 } else if b >= 65 && b <= 70 { b - 55 } else if b >= 97 && b <= 102 { b - 87 } else { -1 }

/// `file:///a/b%20c.auk` -> `/a/b c.auk`.
pub fn uri_to_path(uri: str): str {
  let raw = uri.strip_prefix("file://") else uri
  let bytes = raw.bytes()
  var out: [int] = []
  var i = 0
  while i < bytes.len() {
    // Rust's `u8::from_str_radix` of the next two bytes: two hex digits, or `+` and one
    if bytes[i] == 37 && i + 3 <= bytes.len() {
      let h = hex_val(bytes[i + 1])
      let l = hex_val(bytes[i + 2])
      let v = if h >= 0 && l >= 0 { h * 16 + l } else if bytes[i + 1] == 43 && l >= 0 { l } else { -1 }
      if v >= 0 {
        out.push(v)
        i += 3
        continue
      }
    }
    out.push(bytes[i])
    i += 1
  }
  str.from_utf8(out) else raw
}

/// A file path to a `file://` URI (percent-encoding everything but unreserved chars and `/`).
pub fn path_to_uri(path: str): str {
  var out = ["file://"]
  for b in path.bytes() {
    let c = char(b) else '?'
    if b < 128 && (c.is_digit() || c.is_alpha() || "-._~/".contains(c)) {
      out.push(str(c))
    } else {
      out.push("%{b:02X}")
    }
  }
  out.join("")
}

/// The URI of a file named in a diagnostic or definition (none for the compiled-in prelude).
fn file_uri(file: str): str? uses ffi {
  if file == "" || file.starts_with("<prelude>") { return none }
  let abs = paths.canonicalize(file) else file
  path_to_uri(abs)
}

fn span_contains(s: diag.Span, pos: (int, int)): bool = pos_le((s.line, s.col), pos) && pos_le(pos, (s.end_line, s.end_col))

// ---- the server ----

struct Server {
  /// The prelude and OS the loader needs.
  cx: resolve.Sources,
  docs: {str: Doc},
  /// Per open document: the other files it published diagnostics to (to clear them later),
  /// sorted.
  others: {str: [str]},
  /// Diagnostics by URI (for code actions), with the file text they were computed on.
  diags: {str: [diag.Diag]},
  shutdown: bool,
  exit: bool,
}

struct Doc {
  text: str,
  /// The analysis of `text`.
  model: Model,
}

struct Model {
  /// The typed program; partial when the program has errors (`check.check_partial`), so
  /// hover still works in code that type-checked.
  typed: typed.TypedProgram?,
  /// Otherwise the module tree, when it loads (for syntactic go-to-definition).
  prog: resolve.Program?,
}

fn no_model(): Model = Model { typed: none, prog: none }

fn program(m: Model): resolve.Program? = match m.typed {
  some(t) => t.program
  none => m.prog
}

/// The path to analyze a document as (canonical, so project modules found from it agree).
fn doc_path(uri: str): str uses ffi {
  let p = uri_to_path(uri)
  paths.canonicalize(p) else p
}

/// Load and check the program rooted at `path` with the given root text.
fn analyze(cx: resolve.Sources, path: str, text: str): (Model, [diag.FileDiag]) uses fs, ffi {
  match catch analyze_inner(cx, path, text) {
    ok(r) => r
    err(_) => {
      eprint("auk lsp: the checker panicked on {path}")
      (no_model(), [])
    }
  }
}

fn analyze_inner(cx: resolve.Sources, path: str, text: str): (Model, [diag.FileDiag]) uses fs, ffi {
  match resolve.load_in_package(cx, path, text) {
    err(Many(ds)) => (no_model(), ds)
    ok(prog) => {
      let (tp, ds0) = check.check_partial(prog)
      // warnings are only shown alongside errors (as `check::check` does)
      let ds = if ds0.all(d => d.diag.is_warning()) { [] } else { ds0 }
      let p = if tp is none {
        match resolve.load_in_package(cx, path, text) {
          ok(x) => some(x)
          err(_) => none
        }
      } else {
        none
      }
      (Model { typed: tp, prog: p }, ds)
    }
  }
}

fn uri_param(params: json.Json): str = params.at(["textDocument", "uri"]).as_str() else ""

fn handle(s: var Server, msg: json.Json): [json.Json] uses fs, ffi {
  let method = msg.get("method").as_str() else ""
  let params = msg.get("params")
  let id = msg.get("id")
  let is_request = !id.is_null()
  if method == "" { return [] } // a response to something we never send
  if s.shutdown && is_request && method != "exit" { return [error_reply(id, -32600, "the server is shut down")] }
  let result: json.Json? = match method {
    "initialize" => initialize_result()
    "shutdown" => {
      s.shutdown = true
      json.Json.Null
    }
    "exit" => {
      s.exit = true
      return []
    }
    "textDocument/didOpen" => {
      let uri = uri_param(params)
      let text = params.at(["textDocument", "text"]).as_str() else ""
      return s.update(uri, text)
    }
    "textDocument/didChange" => {
      let uri = uri_param(params)
      let doc = s.docs.get(uri) else return []
      var text = doc.text
      for ch in params.get("contentChanges").as_arr() {
        let new = ch.get("text").as_str() else ""
        let r = ch.get("range")
        if r.is_null() {
          text = new
        } else {
          let a = char_offset(text, json_pos(r.get("start")))
          let b = char_offset(text, json_pos(r.get("end")))
          text = text[0..a] + new + text[max(a, b)..text.len()]
        }
      }
      return s.update(uri, text)
    }
    "textDocument/didSave" => {
      let uri = uri_param(params)
      let text = match params.get("text").as_str() {
        some(t) => t
        none => match s.docs.get(uri) {
          some(d) => d.text
          none => return []
        }
      }
      return s.update(uri, text)
    }
    "textDocument/didClose" => {
      let uri = uri_param(params)
      let _ = s.docs.remove(uri)
      var out = [publish(uri, [])]
      for o in (s.others.remove(uri) else []) {
        if !s.docs.contains(o) {
          let _ = s.diags.remove(o)
          out.push(publish(o, []))
        }
      }
      let _ = s.diags.remove(uri)
      return out
    }
    "textDocument/hover" => s.with_doc(params, false) else json.Json.Null
    "textDocument/definition" => s.with_doc(params, true) else json.Json.Null
    "textDocument/formatting" => s.formatting(params)
    "textDocument/documentSymbol" => s.symbols(params)
    "textDocument/codeAction" => s.code_actions(params)
    _ => none
  }
  if !is_request { return [] }
  match result {
    some(r) => [reply(id, r)]
    none => [error_reply(id, -32601, "unknown method `{method}`")]
  }
}

/// Store the new text, re-analyze, and publish diagnostics (for this file and any other file of
/// the program that has errors).
fn update(s: var Server, uri: str, text: str): [json.Json] uses fs, ffi {
  let path = doc_path(uri)
  let root_file = path
  let (model, diags) = analyze(s.cx, path, text)
  var by_uri: {str: [diag.Diag]} = {}
  by_uri[uri] = []
  for fd in diags {
    let target = if fd.file == root_file { some(uri) } else { file_uri(fd.file) }
    match target {
      some(u) => {
        if !by_uri.contains(u) { by_uri[u] = [] }
        by_uri[u].push(fd.diag)
      }
      none => {}
    }
  }
  s.docs[uri] = Doc { text, model }
  var out: [json.Json] = []
  let old = s.others.remove(uri) else []
  var now: [str] = []
  for u in resolve.sorted_keys(by_uri) {
    let ds = by_uri[u]
    if u != uri {
      // another file's errors: don't override that file's own analysis when it is open
      if s.docs.contains(u) { continue }
      now.push(u)
    }
    let src = s.text_of(u) else continue
    out.push(publish(u, ds.map(d => diagnostic(u, src, d))))
    s.diags[u] = ds
  }
  for o in old {
    if !now.contains(o) && !s.docs.contains(o) {
      let _ = s.diags.remove(o)
      out.push(publish(o, []))
    }
  }
  s.others[uri] = now
  out
}

/// The current text of a file: the open buffer, or the file on disk.
fn text_of(s: Server, uri: str): str? uses fs {
  match s.docs.get(uri) {
    some(d) => d.text
    none => match fs.read(uri_to_path(uri)) {
      ok(t) => t
      err(_) => none
    }
  }
}

/// Hover (`definition` false) or go to definition at the request's position.
fn with_doc(s: Server, params: json.Json, definition: bool): json.Json? uses ffi {
  let uri = params.at(["textDocument", "uri"]).as_str()?
  let doc = s.docs.get(uri)?
  let (line, ch) = json_pos(params.get("position"))
  let pos = from_lsp(doc.text, line, ch)
  let r = if definition { catch definition_at(doc, pos) } else { catch hover(doc, pos) }
  match r {
    ok(j) => j
    err(_) => none
  }
}

fn format_text(text: str): str? = match fmt.format(text) {
  ok(out) => out
  err(_) => none
}

fn formatting(s: Server, params: json.Json): json.Json {
  let doc = match params.at(["textDocument", "uri"]).as_str() {
    some(u) => s.docs.get(u) else return json.Json.Null
    none => return json.Json.Null
  }
  let out = match catch format_text(doc.text) {
    ok(some(o)) => o
    _ => return json.Json.Null
  }
  if out == doc.text { return json.Json.Arr([]) }
  let lines = doc.text.split("\n").len()
  let whole = json.obj([("start", position((0, 0))), ("end", position((lines, 0)))])
  json.Json.Arr([json.obj([("range", whole), ("newText", json.of(out))])])
}

fn parse_text(text: str): ast.Module? = match parser.parse(text, false) {
  ok(m) => m
  err(_) => none
}

fn sym(src: str, name: str, detail: str, kind: int, span: diag.Span, sel: diag.Span, children: [json.Json]): json.Json =
  json.obj([
    ("name", json.of(name)),
    ("detail", json.of(detail)),
    ("kind", json.of(kind)),
    ("range", range(src, span)),
    ("selectionRange", range(src, sel)),
    ("children", json.Json.Arr(children)),
  ])

fn symbols(s: Server, params: json.Json): json.Json {
  let doc = match params.at(["textDocument", "uri"]).as_str() {
    some(u) => s.docs.get(u) else return json.Json.Null
    none => return json.Json.Null
  }
  let m = match catch parse_text(doc.text) {
    ok(some(x)) => x
    _ => return json.Json.Arr([])
  }
  let src = doc.text
  var out: [json.Json] = []
  for item in m.items {
    match item {
      Fn(g) => {
        let first = match g.header {
          some(h) => some(h)
          none => g.clauses.first()
        }
        let c = first else continue
        let last = match g.clauses.last() {
          some(l) => l.span
          none => c.span
        }
        let detail = if g.clauses.len() > 1 { "{g.clauses.len()} clauses" } else { "" }
        out.push(sym(src, g.name, detail, 12, c.span.to(last), c.name.span, []))
      }
      Struct(d) => {
        let fields = d.fields.map(f => sym(src, f.name.name, "", 8, f.span, f.name.span, []))
        out.push(sym(src, d.name.name, "", 23, d.span, d.name.span, fields))
      }
      Enum(d) => {
        let vs = d.variants.map(v => sym(src, v.name.name, "", 22, v.span, v.name.span, []))
        out.push(sym(src, d.name.name, "", 10, d.span, d.name.span, vs))
      }
      Shape(d) => {
        let ms = d.methods.map(c => sym(src, c.name.name, "", 6, c.span, c.name.span, []))
        out.push(sym(src, d.name.name, "", 11, d.span, d.name.span, ms))
      }
      Test(t) => out.push(sym(src, "test {check_expr.debug_str(t.name)}", "", 12, t.span, t.span, []))
      Let(c) | Imprint(c) => out.push(sym(src, c.name.name, "", 14, c.span, c.name.span, []))
      ExternType(t) => out.push(sym(src, t.name.name, "", 23, t.span, t.name.span, []))
      Global(g) => out.push(sym(src, g.name.name, "", 13, g.span, g.name.span, []))
      RawType(t) => out.push(sym(src, t.name.name, "", 23, t.span, t.name.span, []))
      RawAssert(_) => {}
    }
  }
  json.Json.Arr(out)
}

/// One quick fix per diagnostic with fix-its, for the diagnostics overlapping the range.
fn code_actions(s: Server, params: json.Json): json.Json uses fs {
  let uri = params.at(["textDocument", "uri"]).as_str() else return json.Json.Null
  let src = s.text_of(uri) else return json.Json.Null
  let a = json_pos(params.at(["range", "start"]))
  let b = json_pos(params.at(["range", "end"]))
  var out: [json.Json] = []
  for d in (s.diags.get(uri) else []) {
    if d.fixes.len() == 0 { continue }
    let st = to_lsp(src, d.span.line, d.span.col)
    let e = to_lsp(src, d.span.end_line, d.span.end_col)
    if pos_lt(e, a) || pos_lt(b, st) { continue }
    let edits = d.fixes.map(f => json.obj([("range", range(src, f.span)), ("newText", json.of(f.text))]))
    out.push(json.obj([
      ("title", json.of(fix_title(d))),
      ("kind", json.of("quickfix")),
      ("diagnostics", json.Json.Arr([diagnostic(uri, src, d)])),
      ("isPreferred", json.of(true)),
      ("edit", json.obj([("changes", json.Json.Obj([(uri, json.Json.Arr(edits))]))])),
    ]))
  }
  json.Json.Arr(out)
}

fn initialize_result(): json.Json =
  json.obj([
    ("capabilities", json.obj([
      ("textDocumentSync", json.obj([("openClose", json.of(true)), ("change", json.of(1)), ("save", json.obj([("includeText", json.of(true))]))])),
      ("hoverProvider", json.of(true)),
      ("definitionProvider", json.of(true)),
      ("documentFormattingProvider", json.of(true)),
      ("documentSymbolProvider", json.of(true)),
      ("codeActionProvider", json.obj([("codeActionKinds", json.Json.Arr([json.of("quickfix")]))])),
    ])),
    ("serverInfo", json.obj([("name", json.of("auk")), ("version", json.of(VERSION))])),
  ])

/// The char offset of an LSP position in `text` (clamped to the text): Rust's `byte_offset`,
/// counted in chars.
fn char_offset(text: str, pos: (int, int)): int {
  let (line, ch) = pos
  let cs = text.chars()
  var start = 0
  for _ in 0..line {
    var i = start
    while i < cs.len() && cs[i] != '\n' { i += 1 }
    if i >= cs.len() { return cs.len() }
    start = i + 1
  }
  var units = 0
  var i = start
  while i < cs.len() {
    if units >= ch || cs[i] == '\n' { return i }
    units += utf16_len(cs[i])
    i += 1
  }
  cs.len()
}

fn publish(uri: str, diags: [json.Json]): json.Json =
  notification("textDocument/publishDiagnostics", json.obj([("uri", json.of(uri)), ("diagnostics", json.Json.Arr(diags))]))

fn diagnostic(uri: str, src: str, d: diag.Diag): json.Json {
  let r = range(src, d.span)
  var fields = [
    ("range", r),
    ("severity", json.of(1)),
    ("code", json.of(d.code)),
    ("source", json.of("auk")),
    ("message", json.of(d.message)),
  ]
  if d.notes.len() > 0 {
    let loc = json.obj([("uri", json.of(uri)), ("range", r)])
    let rel = d.notes.map(n => json.obj([("location", loc), ("message", json.of(n))]))
    fields.push(("relatedInformation", json.Json.Arr(rel)))
  }
  json.Json.Obj(fields)
}

/// "Insert `?`", "Replace with `str`", "Remove the text", or (several edits) the note that
/// explains them.
fn fix_title(d: diag.Diag): str {
  if d.fixes.len() == 1 {
    let f = d.fixes[0]
    let empty = f.span.line == f.span.end_line && f.span.col == f.span.end_col
    if f.text == "" { return "Remove the text" }
    return if empty { "Insert `{f.text}`" } else { "Replace with `{f.text}`" }
  }
  match d.notes.last() {
    some(n) => "Fix: {n}"
    none => "Fix: {d.message}"
  }
}

// ---- finding the node under the cursor ----

/// What the cursor is on.
enum Hit {
  /// An expression, with its parent expression (a `Call`/`Pipe` whose callee it may be).
  Expr(e: ast.Expr, parent: ast.Expr?),
  /// The member name of `x.f`, `x.f(a)` or `x?.f`, with the parent of the `x.f` expression.
  Member(e: ast.Expr, name: ast.Ident, parent: ast.Expr?),
  /// A field name in a struct literal.
  LitField(e: ast.Expr, name: ast.Ident),
  Pat(p: ast.Pat),
  /// A field name in a struct pattern.
  PatField(p: ast.Pat, name: ast.Ident),
  /// Segment `i` of a type or struct path.
  TypePath(path: [ast.Ident], i: int),
  /// The name of a function clause: item index, clause index (`none` for the header).
  FnDecl(item: int, clause: int?),
  /// Another declaration's name (its own definition).
  Decl(span: diag.Span),
}

struct Finder { pos: (int, int), hit: Hit? }

fn at(f: var Finder, s: diag.Span, h: Hit): bool {
  let inside = span_contains(s, f.pos)
  if inside { f.hit = h }
  inside
}

fn find_item_node(f: var Finder, i: int, item: ast.Item) {
  match item {
    Fn(g) => {
      match g.header {
        some(h) => f.clause(h, some((i, none)))
        none => {}
      }
      for ci, c in g.clauses { f.clause(c, some((i, some(ci)))) }
    }
    Struct(d) => {
      let _ = f.at(d.name.span, Hit.Decl(d.name.span))
      for fd in d.fields {
        let _ = f.at(fd.name.span, Hit.Decl(fd.name.span))
        f.ty(fd.ty)
      }
    }
    Enum(d) => {
      let _ = f.at(d.name.span, Hit.Decl(d.name.span))
      for v in d.variants {
        let _ = f.at(v.name.span, Hit.Decl(v.name.span))
        for vf in v.fields { f.ty(vf.ty) }
      }
    }
    Shape(d) => {
      let _ = f.at(d.name.span, Hit.Decl(d.name.span))
      for c in d.methods { f.clause(c, none) }
    }
    Test(t) => for st in t.body.stmts { f.expr(st, none) }
    Let(c) | Imprint(c) => {
      let _ = f.at(c.name.span, Hit.Decl(c.name.span))
      match c.ty {
        some(t) => f.ty(t)
        none => {}
      }
      f.expr(c.value, none)
    }
    ExternType(t) => {
      let _ = f.at(t.name.span, Hit.Decl(t.name.span))
    }
    Global(g) => {
      let _ = f.at(g.name.span, Hit.Decl(g.name.span))
      match g.ty {
        some(t) => f.ty(t)
        none => {}
      }
    }
    RawType(t) => {
      let _ = f.at(t.name.span, Hit.Decl(t.name.span))
      f.ty(t.ty)
    }
    RawAssert(_) => {}
  }
}

fn clause(f: var Finder, c: ast.FnClause, which: (int, int?)?) {
  let h = match which {
    some(w) => Hit.FnDecl(w.0, w.1)
    none => Hit.Decl(c.name.span)
  }
  let _ = f.at(c.name.span, h)
  for g in c.generics {
    for t in g.bounds { f.ty(t) }
  }
  for p in c.params {
    f.pat(p.pat)
    match p.ty {
      some(t) => f.ty(t)
      none => {}
    }
  }
  match c.ret {
    some(t) => f.ty(t)
    none => {}
  }
  for e in c.pre + c.post { f.expr(e, none) }
  match c.guard {
    some(e) => f.expr(e, none)
    none => {}
  }
  match c.body {
    some(Expr(e)) => f.expr(e, none)
    some(Block(b)) => for st in b.stmts { f.expr(st, none) }
    _ => {}
  }
}

fn path(f: var Finder, path: [ast.Ident]) {
  for i, seg in path {
    let _ = f.at(seg.span, Hit.TypePath(path, i))
  }
}

fn ty(f: var Finder, t: ast.Type) {
  if !span_contains(t.span, f.pos) { return }
  match t.kind {
    Named(p, args) => {
      f.path(p)
      for a in args { f.ty(a) }
    }
    List(x) | Optional(x) | Any(x) | Array(x, _) => f.ty(x)
    Measured(base, _) => f.ty(base)
    Map(k, v) => {
      f.ty(k)
      f.ty(v)
    }
    Tuple(ts) => for x in ts { f.ty(x) }
    Fallible(ok_, er) => {
      f.ty(ok_)
      match er {
        some(e) => f.ty(e)
        none => {}
      }
    }
    Fn(params, ret) => {
      for x in params { f.ty(x) }
      f.ty(ret)
    }
    Var(x) => f.ty(x)
  }
}

fn pat(f: var Finder, p: ast.Pat) {
  if !f.at(p.span, Hit.Pat(p)) { return }
  match p.kind {
    Wild | Bind(_) | Lit(_, _) | None => {}
    Tuple(ps) => for x in ps { f.pat(x) }
    List(head, rest, tail) => {
      for x in head { f.pat(x) }
      match rest {
        some(r) => match r.pat {
          some(x) => f.pat(x)
          none => {}
        }
        none => {}
      }
      for x in tail { f.pat(x) }
    }
    // the variant name stands for the whole pattern (the table is keyed on it)
    Variant(_, args) => for x in (args else []) { f.pat(x) }
    Struct(sp, fields, _) => {
      f.path(sp)
      for fp in fields {
        let _ = f.at(fp.name.span, Hit.PatField(p, fp.name))
        match fp.pat {
          some(x) => f.pat(x)
          none => {}
        }
      }
    }
    Map(es) => for kv in es { f.pat(kv.1) }
    StrPrefix(_, rest) => f.pat(rest)
    Some(x) | Ok(x) | Err(x) => f.pat(x)
    Or(ps) => for x in ps { f.pat(x) }
  }
}

fn opt_expr(f: var Finder, e: ast.Expr?, me: ast.Expr?) {
  match e {
    some(x) => f.expr(x, me)
    none => {}
  }
}

fn stmts(f: var Finder, b: ast.Block, me: ast.Expr?) {
  for st in b.stmts { f.expr(st, me) }
}

fn expr(f: var Finder, e: ast.Expr, parent: ast.Expr?) {
  if !f.at(e.span, Hit.Expr(e, parent)) { return }
  let me = some(e)
  match e.kind {
    Lit(_) | Name(_) | Hole | Continue | FieldSel(_) => {}
    TypeArgs(x, _) => f.expr(x, me)
    Measured(x, _) => f.expr(x, me)
    Interp(ps) => for p in ps {
      match p {
        Expr(x, _) => f.expr(x, me)
        _ => {}
      }
    }
    Field(x, name) => {
      f.expr(x, me)
      let _ = f.at(name.span, Hit.Member(e, name, parent))
    }
    TupleField(x, _) => f.expr(x, me)
    Unary(_, x) => f.expr(x, me)
    Is(x, p) => {
      f.expr(x, me)
      f.pat(p)
    }
    Try(x) | Unwrap(x) | Await(x) | AwaitAny(x) | Catch(x) | Ref(x) | Assert(x) | Peek(x) => f.expr(x, me)
    Call(callee, args) => {
      f.expr(callee, me)
      for a in args { f.expr(a, me) }
    }
    MethodCall(recv, name, args) => {
      f.expr(recv, me)
      let _ = f.at(name.span, Hit.Member(e, name, parent))
      for a in args { f.expr(a, me) }
    }
    Pipe(lhs, callee, args) => {
      f.expr(lhs, me)
      f.expr(callee, me)
      for a in args { f.expr(a, me) }
    }
    Index(x, i) => {
      f.expr(x, me)
      f.expr(i, me)
    }
    Slice(x, lo, hi, _) => {
      f.expr(x, me)
      f.expr(lo, me)
      f.expr(hi, me)
    }
    Binary(_, l, r) => {
      f.expr(l, me)
      f.expr(r, me)
    }
    Range(lo, hi, _) => {
      f.expr(lo, me)
      f.expr(hi, me)
    }
    OptChain(x, name, args) => {
      f.expr(x, me)
      let _ = f.at(name.span, Hit.Member(e, name, parent))
      for a in (args else []) { f.expr(a, me) }
    }
    Else(x, arm) => {
      f.expr(x, me)
      match arm.binder {
        some(b) => {
          let _ = f.at(b.span, Hit.Decl(b.span))
        }
        none => {}
      }
      f.expr(arm.body, me)
    }
    Closure(params, body) => {
      for p in params {
        f.pat(p.pat)
        match p.ty {
          some(t) => f.ty(t)
          none => {}
        }
      }
      f.expr(body, me)
    }
    If(cond, then, els) => {
      f.expr(cond, me)
      f.stmts(then, me)
      f.opt_expr(els, me)
    }
    Match(scrut, arms) => {
      f.expr(scrut, me)
      for a in arms {
        f.pat(a.pat)
        f.opt_expr(a.guard, me)
        f.expr(a.body, me)
      }
    }
    Loop(b) | Block(b) => f.stmts(b, me)
    While(cond, body) => {
      f.expr(cond, me)
      f.stmts(body, me)
    }
    For(index, p, iter, body) => {
      match index {
        some(i) => f.pat(i)
        none => {}
      }
      f.pat(p)
      f.expr(iter, me)
      f.stmts(body, me)
    }
    Let(_, p, t, value, els) => {
      f.pat(p)
      match t {
        some(x) => f.ty(x)
        none => {}
      }
      f.expr(value, me)
      match els {
        some(a) => {
          match a.binder {
            some(b) => {
              let _ = f.at(b.span, Hit.Decl(b.span))
            }
            none => {}
          }
          f.expr(a.body, me)
        }
        none => {}
      }
    }
    Assign(_, target, value) => {
      f.expr(target, me)
      f.expr(value, me)
    }
    Return(x) | Break(x) => f.opt_expr(x, me)
    Struct(sp, fields, base) => {
      f.path(sp)
      for fi in fields {
        let _ = f.at(fi.name.span, Hit.LitField(e, fi.name))
        f.opt_expr(fi.value, me)
      }
      f.opt_expr(base, me)
    }
    List(xs) | Tuple(xs) => for x in xs { f.expr(x, me) }
    Map(es) => for kv in es {
      f.expr(kv.0, me)
      f.expr(kv.1, me)
    }
  }
}

/// The innermost node of module `m` at `pos` (1-based line, char column).
fn find(prog: resolve.Program, m: int, pos: (int, int)): Hit? {
  var f = Finder { pos, hit: none }
  for i, item in prog.mods[m].ast.items { f.find_item_node(i, item) }
  f.hit
}

/// `a.b.c` as a list of names, if `e` is a plain path.
fn as_path(e: ast.Expr): [str]? = match e.kind {
  Name(n) => [n]
  Field(x, name) => as_path(x)? + [name.name]
  _ => none
}

// ---- go to definition ----

/// A place in a file of the program: (module, span).
fn definition_at(doc: Doc, pos: (int, int)): json.Json? uses ffi {
  let prog = doc.model.program()?
  let m = prog.focus
  let hit = find(prog, m, pos)?
  let typed_loc = match doc.model.typed {
    some(tp) => typed_definition(tp, m, hit)
    none => none
  }
  let (dm, span) = match typed_loc {
    some(l) => l
    none => syntactic_definition(prog, m, hit)?
  }
  let file = prog.mods[dm].file
  let src = if dm == m { doc.text } else { prog.mods[dm].src }
  let u = if dm == m { path_to_uri(file) } else { file_uri(file)? }
  json.obj([("uri", json.of(u)), ("range", range(src, span))])
}

fn fn_loc(tp: typed.TypedProgram, f: int): (int, diag.Span) = (tp.fns[f].module, tp.fns[f].span)

fn variant_loc(tp: typed.TypedProgram, def: int, index: int): (int, diag.Span)? {
  let d = tp.defs.types[def]
  let v = tp.defs.variants(def).get(index)?
  (d.module, name_span(v.span, v.name))
}

/// The part of a declaration's span that is its name (fields and variants record the whole
/// declaration, which starts with the name).
fn name_span(s: diag.Span, name: str): diag.Span = diag.Span { end_line: s.line, end_col: s.col + name.len(), ..s }

fn field_loc(tp: typed.TypedProgram, def: int, name: str): (int, diag.Span)? {
  let d = tp.defs.types[def]
  let fd = tp.defs.fields(def).find(x => x.name == name)?
  (d.module, name_span(fd.span, name))
}

fn callee_loc(tp: typed.TypedProgram, c: typed.Callee): (int, diag.Span)? = match c {
  Fn(func, _) => fn_loc(tp, func)
  Variant(v) => variant_loc(tp, v.def, v.index)
  Shape(shape, _, _) | Vtable(shape, _) => {
    let sh = tp.defs.shapes[shape]
    (sh.module, sh.span)
  }
  Closure => none
}

fn name_loc(tp: typed.TypedProgram, m: int, n: typed.NameRef): (int, diag.Span)? = match n {
  Local(l) => (m, tp.tables[m].locals[l].span)
  Const(c) => (tp.consts[c].module, tp.consts[c].span)
  Fn(func, _) => fn_loc(tp, func)
  Variant(v) => variant_loc(tp, v.def, v.index)
  None => none
  Global(g) => (tp.globals[g].module, tp.globals[g].span)
}

/// The call node whose callee is `e`, if any.
fn call_of(e: ast.Expr, parent: ast.Expr?): ast.Expr? {
  let p = parent?
  match p.kind {
    Call(callee, _) | Pipe(_, callee, _) => if callee.id == e.id { p } else { none }
    _ => none
  }
}

/// The call recorded for `e`, or for the call whose callee `e` is.
fn call_at(t: typed.Tables, e: ast.Expr, parent: ast.Expr?): typed.Call? = match t.calls.get(e.id) {
  some(c) => c
  none => t.calls.get((call_of(e, parent)?).id)
}

fn typed_definition(tp: typed.TypedProgram, m: int, hit: Hit): (int, diag.Span)? {
  let t = tp.tables[m]
  match hit {
    Expr(e, parent) => {
      match t.names.get(e.id) {
        some(n) => return name_loc(tp, m, n)
        none => {}
      }
      match call_of(e, parent) {
        some(c) => match t.calls.get(c.id) {
          some(call) => return callee_loc(tp, call.callee)
          none => {}
        }
        none => {}
      }
      match e.kind {
        Field(_, name) => typed_definition(tp, m, Hit.Member(e, name, parent))
        _ => none
      }
    }
    Member(e, name, parent) => {
      match t.names.get(e.id) {
        some(n) => return name_loc(tp, m, n)
        none => {}
      }
      match call_at(t, e, parent) {
        some(c) => return callee_loc(tp, c.callee)
        none => {}
      }
      match t.fields.get(e.id) {
        some(fd) => return field_loc(tp, fd.0, name.name)
        none => {}
      }
      none
    }
    LitField(e, name) => field_loc(tp, (t.struct_lits.get(e.id)?).def, name.name)
    PatField(p, name) => field_loc(tp, (t.struct_pats.get(p.id)?).def, name.name)
    Pat(p) => {
      match t.binds.get(p.id) {
        some(l) => return (m, t.locals[l].span)
        none => {}
      }
      match t.variants.get(p.id) {
        some(v) => return variant_loc(tp, v.def, v.index)
        none => {}
      }
      match t.struct_pats.get(p.id) {
        some(sp) => {
          let d = tp.defs.types[sp.def]
          return (d.module, d.span)
        }
        none => {}
      }
      none
    }
    TypePath(_, _) | FnDecl(_, _) | Decl(_) => none
  }
}

fn syntactic_definition(prog: resolve.Program, m: int, hit: Hit): (int, diag.Span)? = match hit {
  Expr(e, _) => find_item(prog, m, as_path(e)?)
  Member(e, name, _) => match e.kind {
    Field(_, _) => find_item(prog, m, as_path(e)?)
    MethodCall(recv, _, _) => {
      var p = match as_path(recv) {
        some(x) => if module_path(prog, m, x) is some(_) { x } else { [] }
        none => []
      }
      p.push(name.name)
      find_item(prog, m, p)
    }
    _ => find_item(prog, m, [name.name])
  }
  Pat(p) => match p.kind {
    Variant(vp, _) => find_item(prog, m, vp.map(i => i.name))
    _ => none
  }
  TypePath(tpath, i) => find_item(prog, m, tpath.take(i + 1).map(x => x.name))
  FnDecl(item, clause) => match prog.mods[m].ast.items[item] {
    Fn(g) => {
      let c = match clause {
        some(ci) => g.clauses[ci]
        none => g.header?
      }
      (m, c.name.span)
    }
    _ => none
  }
  Decl(s) => (m, s)
  LitField(_, _) | PatField(_, _) => none
}

/// The module a path of module names leads to from module `m`.
fn module_path(prog: resolve.Program, m: int, path: [str]): int? {
  let first = path.first()?
  var mm = prog.first_segment(m, first)?
  for seg in path.skip(1) { mm = prog.child(mm, seg)? }
  mm
}

/// An item named `name` declared in module `m` (functions, types, shapes, constants, then
/// enum variants).
fn item_in(prog: resolve.Program, m: int, name: str): diag.Span? {
  let items = prog.mods[m].ast.items
  for item in items {
    match item {
      Fn(g) => if g.name == name {
        match g.header {
          some(h) => return h.name.span
          none => match g.clauses.first() {
            some(c) => return c.name.span
            none => {}
          }
        }
      }
      Struct(d) => if d.name.name == name { return d.name.span }
      Enum(d) => if d.name.name == name { return d.name.span }
      Shape(d) => if d.name.name == name { return d.name.span }
      ExternType(d) => if d.name.name == name { return d.name.span }
      RawType(d) => if d.name.name == name { return d.name.span }
      Let(c) | Imprint(c) => if c.name.name == name { return c.name.span }
      _ => {}
    }
  }
  for item in items {
    match item {
      Enum(d) => match d.variants.find(v => v.name.name == name) {
        some(v) => return v.name.span
        none => {}
      }
      _ => {}
    }
  }
  none
}

/// A variant `v` of an enum named `ty` declared in module `m`.
fn variant_in(prog: resolve.Program, m: int, ty: str, v: str): diag.Span? {
  for item in prog.mods[m].ast.items {
    match item {
      Enum(d) => if d.name.name == ty {
        match d.variants.find(x => x.name.name == v) {
          some(x) => return x.name.span
          none => {}
        }
      }
      _ => {}
    }
  }
  none
}

fn module_start(mm: int): (int, diag.Span) = (mm, diag.Span { line: 1, col: 1, end_line: 1, end_col: 1 })

/// Look a path up without types: a name in the module, then core, then a module of that name,
/// then (for dot calls, whose target depends on the receiver's type) any module of the package
/// and then the whole program; `m.x` / `T.Variant` / `m.T.Variant` by their paths.
fn find_item(prog: resolve.Program, m: int, path: [str]): (int, diag.Span)? {
  if path.len() == 0 { return none }
  if path.len() == 1 {
    let name = path[0]
    match item_in(prog, m, name) {
      some(s) => return (m, s)
      none => {}
    }
    match item_in(prog, prog.core_root, name) {
      some(s) => return (prog.core_root, s)
      none => {}
    }
    match prog.first_segment(m, name) {
      some(mm) => if prog.mods[mm].file != "" { return module_start(mm) }
      none => {}
    }
    let pkg = prog.mods[m].pkg
    for x in 0..prog.mods.len() {
      if prog.mods[x].pkg == pkg {
        match item_in(prog, x, name) {
          some(s) => return (x, s)
          none => {}
        }
      }
    }
    for x in 0..prog.mods.len() {
      if prog.mods[x].pkg != pkg {
        match item_in(prog, x, name) {
          some(s) => return (x, s)
          none => {}
        }
      }
    }
    return none
  }
  let last = path[path.len() - 1]
  let init = path.take(path.len() - 1)
  match module_path(prog, m, init) {
    some(mm) => {
      match item_in(prog, mm, last) {
        some(s) => return (mm, s)
        none => {}
      }
      match prog.child(mm, last) {
        some(c) => if prog.mods[c].file != "" { return module_start(c) }
        none => {}
      }
    }
    none => {}
  }
  // `T.Variant` or `m.T.Variant`
  let ty = init[init.len() - 1]
  let scope = if init.len() == 1 { some(m) } else { module_path(prog, m, init.take(init.len() - 1)) }
  var scopes: [int] = []
  match scope {
    some(x) => scopes.push(x)
    none => {}
  }
  scopes.push(prog.core_root)
  for mm in scopes {
    match variant_in(prog, mm, ty, last) {
      some(s) => return (mm, s)
      none => {}
    }
  }
  none
}

// ---- hover ----

fn hover(doc: Doc, pos: (int, int)): json.Json? uses ffi {
  let tp = doc.model.typed?
  let m = tp.program.focus
  let hit = find(tp.program, m, pos)?
  let (code, docs) = hover_text(tp, m, hit)?
  var value = ["```auk\n{code}\n```"]
  match hover_origin(tp, m, hit) {
    some(loc) => match origin_text(tp.program, m, loc) {
      some(o) => value.push("\n\n" + o)
      none => {}
    }
    none => {}
  }
  match docs {
    some(d) => if d.trim() != "" { value.push("\n\n" + d.trim()) }
    none => {}
  }
  json.obj([("contents", json.obj([("kind", json.of("markdown")), ("value", json.of(value.join("")))]))])
}

/// Where the thing under the cursor is defined, for the hover's "Defined in" line.
fn hover_origin(tp: typed.TypedProgram, m: int, hit: Hit): (int, diag.Span)? = match hit {
  TypePath(tpath, i) => find_item(tp.program, m, tpath.take(i + 1).map(x => x.name))
  FnDecl(_, _) | Decl(_) => none
  Expr(e, _) | Member(e, _, _) => match typed_definition(tp, m, hit) {
    some(l) => l
    none => {
      // a module path (`util`, `audio.out`): the module itself
      if tp.tables[m].types.contains(e.id) { return none }
      module_start(module_path(tp.program, m, as_path(e)?)?)
    }
  }
  _ => typed_definition(tp, m, hit)
}

/// "Defined in `core.list` (core library)", "Defined in `audio.out` (library `audio`) —
/// [out.auk:12](…)"; nothing for what is defined in the file itself.
fn origin_text(prog: resolve.Program, m: int, loc: (int, diag.Span)): str? uses ffi {
  let (dm, span) = loc
  if dm == m { return none }
  let md = prog.mods[dm]
  let pkg = prog.pkgs[md.pkg]
  let whose = if pkg.is_core {
    "core library"
  } else if md.pkg == prog.mods[m].pkg {
    "this package"
  } else {
    "library `{pkg.name}`"
  }
  var s = "Defined in `{prog.name(dm)}` ({whose})"
  match file_uri(md.file) {
    some(uri) => {
      let base = paths.file_name(md.file)
      s += " — [{base}:{span.line}]({uri}#L{span.line})"
    }
    none => {}
  }
  s
}

/// `pub async fn name<A: Show>(a: int, xs: var [A]): str uses fs`.
pub fn signature(tp: typed.TypedProgram, f: int): str {
  let fi = tp.fns[f]
  var gs: [str] = []
  for g in fi.generics {
    let p = tp.defs.params[g]
    if p.implicit { continue }
    let bounds = p.bounds.map(s => tp.defs.shapes[s].name)
    gs.push(if bounds.len() == 0 { p.name } else { "{p.name}: {bounds.join(" + ")}" })
  }
  let ps = fi.params.map(p => param_text(tp, p))
  let pub_ = if fi.public { "pub " } else { "" }
  let async_ = if fi.is_async { "async " } else { "" }
  let gen = if gs.len() == 0 { "" } else { "<{gs.join(", ")}>" }
  var s = "{pub_}{async_}fn {fi.name}{gen}({ps.join(", ")})"
  if !fi.ret.is_unit() { s += ": {tp.defs.show(fi.ret)}" }
  if fi.effects.len() > 0 { s += " uses {fi.effects.join(", ")}" }
  s
}

fn param_text(tp: typed.TypedProgram, p: typed.ParamInfo): str {
  let name = p.name else "_"
  let v = if p.var_ { "var " } else { "" }
  "{name}: {v}{tp.defs.show(p.ty)}"
}

fn variant_text(tp: typed.TypedProgram, def: int, index: int): str? {
  let d = tp.defs.types[def]
  let v = tp.defs.variants(def).get(index)?
  var s = "{d.name}.{v.name}"
  if v.fields.len() > 0 {
    let fs = v.fields.map(nt => match nt.0 {
      some(n) => "{n}: {tp.defs.show(nt.1)}"
      none => tp.defs.show(nt.1)
    })
    s += "({fs.join(", ")})"
  }
  s
}

fn name_hover(tp: typed.TypedProgram, m: int, n: typed.NameRef): (str, str?)? = match n {
  Global(g) => {
    let gl = tp.globals[g]
    ("{ast.global_kw(gl.kind)} {gl.name}: {tp.defs.show(gl.ty)}", none)
  }
  Local(li) => {
    let l = tp.tables[m].locals[li]
    let kw = if l.mutable { "var" } else { "let" }
    ("{kw} {l.name}: {tp.defs.show(l.ty)}", none)
  }
  Const(ci) => {
    let c = tp.consts[ci]
    let doc = match tp.program.mods[c.module].ast.items[c.item] {
      Let(d) | Imprint(d) => d.doc
      _ => none
    }
    let kw = if c.imprint { "imprint" } else { "let" }
    ("{kw} {c.name}: {tp.defs.show(c.ty)}", doc)
  }
  Fn(func, _) => (signature(tp, func), tp.fns[func].doc)
  Variant(v) => (variant_text(tp, v.def, v.index)?, none)
  None => ("none", none)
}

fn callee_hover(tp: typed.TypedProgram, c: typed.Callee): (str, str?)? = match c {
  Fn(func, _) => (signature(tp, func), tp.fns[func].doc)
  Variant(v) => (variant_text(tp, v.def, v.index)?, none)
  Shape(shape, method, _) | Vtable(shape, method) => {
    let s = tp.defs.shapes[shape]
    let me = s.methods.get(method)?
    let ps = me.params.map(t => tp.defs.show(t))
    ("fn {me.name}({ps.join(", ")}): {tp.defs.show(me.ret)}  // shape {s.name}", none)
  }
  Closure => none
}

fn type_def_hover(tp: typed.TypedProgram, def: int): (str, str?) {
  let d = tp.defs.types[def]
  let kw = match d.kind {
    Struct(_) => "struct"
    Enum(_) => "enum"
    Opaque(_) => "extern type"
  }
  let params = d.params.map(p => tp.defs.params[p].name)
  let g = if params.len() == 0 { "" } else { "<{params.join(", ")}>" }
  let pub_ = if d.public { "pub " } else { "" }
  ("{pub_}{kw} {d.name}{g}", d.doc)
}

/// Rust's `Ident::tuple_index().is_none()`: not all ASCII digits (or a number past `u32`).
fn no_tuple_index(name: str): bool {
  if name == "" || !name.chars().all(c => c.is_digit()) { return true }
  match int.parse(name) {
    ok(n) => n > 0xFFFFFFFF
    err(_) => true
  }
}

fn module_hover(tp: typed.TypedProgram, mm: int): (str, str?) = ("module {tp.program.name(mm)}", tp.program.mods[mm].ast.doc)

/// Whether a function is the clause group `item` and has clause `clause` (or the header).
fn is_decl_of(k: typed.FnKind, item: int, clause: int?): bool = match k {
  Auk(i, clauses, header) => i == item && match clause {
    some(ci) => clauses.contains(ci)
    none => header
  }
  _ => false
}

fn hover_text(tp: typed.TypedProgram, m: int, hit: Hit): (str, str?)? {
  let t = tp.tables[m]
  match hit {
    Expr(e, parent) => {
      match t.names.get(e.id) {
        some(n) => return name_hover(tp, m, n)
        none => {}
      }
      match call_of(e, parent) {
        some(c) => match t.calls.get(c.id) {
          some(call) => return callee_hover(tp, call.callee)
          none => {}
        }
        none => {}
      }
      if !t.types.contains(e.id) {
        match as_path(e) {
          some(p) => match module_path(tp.program, m, p) {
            some(mm) => return module_hover(tp, mm)
            none => {}
          }
          none => {}
        }
      }
      (tp.defs.show(t.types.get(e.id)?), none)
    }
    Member(e, name, parent) => {
      match t.names.get(e.id) {
        some(n) => return name_hover(tp, m, n)
        none => {}
      }
      match call_at(t, e, parent) {
        some(c) => return callee_hover(tp, c.callee)
        none => {}
      }
      // `x?.0` names no field: its hover is the chain's type, like `x.0`'s
      if t.fields.contains(e.id) || (e.kind is ast.ExprKind.OptChain(_, _, _) && no_tuple_index(name.name)) {
        return ("{name.name}: {tp.defs.show(t.types.get(e.id)?)}", none)
      }
      match as_path(e) {
        some(p) => match module_path(tp.program, m, p) {
          some(mm) => return module_hover(tp, mm)
          none => {}
        }
        none => {}
      }
      (tp.defs.show(t.types.get(e.id)?), none)
    }
    LitField(e, name) => {
      let def = (t.struct_lits.get(e.id)?).def
      let fd = tp.defs.fields(def).find(x => x.name == name.name)?
      ("{fd.name}: {tp.defs.show(fd.ty)}", none)
    }
    PatField(p, name) => {
      let def = (t.struct_pats.get(p.id)?).def
      let fd = tp.defs.fields(def).find(x => x.name == name.name)?
      ("{fd.name}: {tp.defs.show(fd.ty)}", none)
    }
    Pat(p) => {
      match t.binds.get(p.id) {
        some(l) => return name_hover(tp, m, typed.NameRef.Local(l))
        none => {}
      }
      match t.variants.get(p.id) {
        some(v) => return (variant_text(tp, v.def, v.index)?, none)
        none => {}
      }
      (tp.defs.show(t.types.get(p.id)?), none)
    }
    TypePath(tpath, i) => {
      let names = tpath.take(i + 1).map(x => x.name)
      let last = names[names.len() - 1]
      let (dm, span) = find_item(tp.program, m, names)?
      match tp.defs.types.find_index(d => d.module == dm && d.span.line == span.line && d.name == last) {
        some(def) => return type_def_hover(tp, def)
        none => {}
      }
      match tp.defs.shapes.find(s => s.module == dm && s.name == last) {
        some(s) => return ("shape {s.name}", none)
        none => {}
      }
      none
    }
    FnDecl(item, clause) => {
      let f = tp.fns.find_index(fi => fi.module == m && is_decl_of(fi.kind, item, clause))?
      (signature(tp, f), tp.fns[f].doc)
    }
    Decl(_) => none
  }
}

test "utf16 positions" {
  let src = "let a = 1\nlet s = \"é🦆x\" + y\n"
  // ASCII: identical apart from the base
  assert to_lsp(src, 1, 5) == (0, 4)
  assert from_lsp(src, 0, 4) == (1, 5)
  // line 2: `é` is one UTF-16 unit, `🦆` two
  let col_x = 1 + "let s = \"é🦆".len() // char column of `x`
  assert to_lsp(src, 2, col_x) == (1, 12)
  assert from_lsp(src, 1, 12) == (2, col_x)
  assert to_lsp(src, 2, col_x - 1) == (1, 10) // the auk
  assert from_lsp(src, 1, 11) == (2, col_x - 1) // inside the surrogate pair
  // past the end of a line, and the empty last line
  assert to_lsp(src, 1, 13) == (0, 12)
  assert from_lsp(src, 0, 12) == (1, 13)
  assert to_lsp(src, 3, 1) == (2, 0)
  // round trip every char boundary
  for i, _ in line_text(src, 1).chars() {
    let col = i + 1
    let (l, u) = to_lsp(src, 2, col)
    assert from_lsp(src, l, u) == (2, col)
  }
  // CRLF line endings don't count the `\r`
  assert to_lsp("ab\r\ncd", 2, 3) == (1, 2)
  assert char_offset("ab\r\né🦆d", (1, 3)) == "ab\r\né🦆".len()
}

test "uris" {
  assert uri_to_path("file:///tmp/a%20b/c.auk") == "/tmp/a b/c.auk"
  assert path_to_uri("/tmp/a b/é.auk") == "file:///tmp/a%20b/%C3%A9.auk"
  assert uri_to_path(path_to_uri("/x/é y.auk")) == "/x/é y.auk"
}

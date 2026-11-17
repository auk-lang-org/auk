//! `duck lsp`: a Language Server Protocol server over stdio (JSON-RPC with `Content-Length`
//! framing), built on the compiler front end.
//!
//! - **Diagnostics**: every open/change/save re-runs resolve + check on the in-memory text, in
//!   the file's project context (the nearest `quack.toml`, its `src/` modules and `.quack/`
//!   dependencies, read from disk), and publishes the errors with code, range and notes (as
//!   related information). Errors in other files of the program are published to those files.
//! - **Code actions**: each diagnostic's fix-its become one quick fix (a `WorkspaceEdit`).
//! - **Hover**: the type of the innermost expression or pattern under the cursor (from the
//!   `TypedProgram` side tables), a function's signature and `///` docs, a type's docs, and
//!   where it is defined when that is another file (core, a library, or this package).
//! - **Go to definition**: locals, constants, functions (the first clause of a clause group),
//!   structs, enums, shapes, variants and fields, across modules and dependencies. When the
//!   program doesn't type-check, names and paths are looked up syntactically in the module tree.
//! - **Formatting** (`duck fmt`) and **document symbols**.
//!
//! Positions: Duck spans are 1-based lines and 1-based columns counted in chars; LSP positions
//! are 0-based lines and 0-based UTF-16 code-unit offsets. `to_lsp` / `from_lsp` convert.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::io::{self, BufRead, Write};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::{Path, PathBuf};

use super::ast::{Expr, ExprKind as K, FieldPat, FnBody, FnClause, Ident, InterpPart, Item, Pat, PatKind, Type, TypeKind};
use super::diag::{Diag, FileDiag, Span};
use super::json::{self, Json, obj};
use super::resolve::{self, ModId, Program};
use super::typed::{Callee, FnKind, NameRef, TypedProgram};
use super::types::{DefId, Ty, TypeDefKind};
use super::{check, fmt, parser};

/// Serve on stdin/stdout until `exit`. Returns the process exit code.
pub fn run() -> i32 {
    let stdin = io::stdin();
    let mut input = stdin.lock();
    let mut output = io::stdout().lock();
    let mut server = Server::default();
    loop {
        let body = match read_message(&mut input) {
            Ok(Some(b)) => b,
            Ok(None) => return 1, // the client went away without `exit`
            Err(e) => {
                eprintln!("duck lsp: {e}");
                return 1;
            }
        };
        let replies = match json::parse(&body) {
            Ok(msg) => server.handle(&msg),
            Err(e) => vec![error_reply(Json::Null, -32700, &e)],
        };
        for r in replies {
            if write_message(&mut output, &r).is_err() {
                return 1;
            }
        }
        if server.exit {
            return if server.shutdown { 0 } else { 1 };
        }
    }
}

// ---- framing ----

/// Read one `Content-Length`-framed message body; `None` at end of input.
pub fn read_message(r: &mut impl BufRead) -> io::Result<Option<String>> {
    let mut len = None;
    loop {
        let mut line = String::new();
        if r.read_line(&mut line)? == 0 {
            return Ok(None);
        }
        let line = line.trim_end();
        if line.is_empty() {
            if len.is_some() {
                break;
            }
            continue;
        }
        if let Some((k, v)) = line.split_once(':')
            && k.trim().eq_ignore_ascii_case("content-length")
        {
            len = v.trim().parse::<usize>().ok();
        }
    }
    let mut buf = vec![0; len.unwrap_or(0)];
    r.read_exact(&mut buf)?;
    String::from_utf8(buf).map(Some).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
}

pub fn write_message(w: &mut impl Write, msg: &Json) -> io::Result<()> {
    let body = msg.to_string();
    write!(w, "Content-Length: {}\r\n\r\n{body}", body.len())?;
    w.flush()
}

fn reply(id: Json, result: Json) -> Json {
    obj([("jsonrpc", "2.0".into()), ("id", id), ("result", result)])
}

fn error_reply(id: Json, code: i64, msg: &str) -> Json {
    obj([("jsonrpc", "2.0".into()), ("id", id), ("error", obj([("code", code.into()), ("message", msg.into())]))])
}

fn notification(method: &str, params: Json) -> Json {
    obj([("jsonrpc", "2.0".into()), ("method", method.into()), ("params", params)])
}

// ---- positions and URIs ----

/// The text of 0-based line `line` (without its newline).
fn line_text(src: &str, line: usize) -> &str {
    let l = src.split('\n').nth(line).unwrap_or("");
    l.strip_suffix('\r').unwrap_or(l)
}

/// A 1-based (line, char column) to an LSP (line, UTF-16 offset). Columns past the end of the
/// line count one unit per missing char.
pub fn to_lsp(src: &str, line: u32, col: u32) -> (u32, u32) {
    let line0 = line.saturating_sub(1);
    let n = col.saturating_sub(1) as usize;
    let text = line_text(src, line0 as usize);
    let mut units = 0;
    let mut seen = 0;
    for c in text.chars().take(n) {
        units += c.len_utf16() as u32;
        seen += 1;
    }
    (line0, units + (n - seen) as u32)
}

/// An LSP (line, UTF-16 offset) to a 1-based (line, char column). An offset inside a surrogate
/// pair lands on that char.
pub fn from_lsp(src: &str, line: u32, character: u32) -> (u32, u32) {
    let text = line_text(src, line as usize);
    let mut units = 0;
    let mut chars = 0;
    for c in text.chars() {
        if units >= character || units + c.len_utf16() as u32 > character {
            return (line + 1, chars + 1);
        }
        units += c.len_utf16() as u32;
        chars += 1;
    }
    (line + 1, chars + (character - units) + 1)
}

fn position(p: (u32, u32)) -> Json {
    obj([("line", p.0.into()), ("character", p.1.into())])
}

fn range(src: &str, s: Span) -> Json {
    obj([("start", position(to_lsp(src, s.line, s.col))), ("end", position(to_lsp(src, s.end_line, s.end_col)))])
}

fn json_pos(j: &Json) -> (u32, u32) {
    (j.get("line").as_i64().unwrap_or(0) as u32, j.get("character").as_i64().unwrap_or(0) as u32)
}

/// `file:///a/b%20c.duck` -> `/a/b c.duck`.
pub fn uri_to_path(uri: &str) -> PathBuf {
    let raw = uri.strip_prefix("file://").unwrap_or(uri);
    let bytes = raw.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && let Some(b) = raw.get(i + 1..i + 3).and_then(|h| u8::from_str_radix(h, 16).ok())
        {
            out.push(b);
            i += 3;
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    PathBuf::from(String::from_utf8_lossy(&out).into_owned())
}

/// A file path to a `file://` URI (percent-encoding everything but unreserved chars and `/`).
pub fn path_to_uri(path: &str) -> String {
    let mut out = String::from("file://");
    for b in path.bytes() {
        if b.is_ascii_alphanumeric() || b"-._~/".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// The URI of a file named in a diagnostic or definition (none for the compiled-in prelude).
fn file_uri(file: &str) -> Option<String> {
    if file.is_empty() || file.starts_with("<prelude>") {
        return None;
    }
    let p = Path::new(file);
    let abs = p.canonicalize().unwrap_or_else(|_| p.to_path_buf());
    Some(path_to_uri(&abs.display().to_string()))
}

fn span_contains(s: Span, pos: (u32, u32)) -> bool {
    (s.line, s.col) <= pos && pos <= (s.end_line, s.end_col)
}

// ---- the server ----

#[derive(Default)]
struct Server {
    docs: HashMap<String, Doc>,
    /// Per open document: the other files it published diagnostics to (to clear them later).
    others: HashMap<String, BTreeSet<String>>,
    /// Diagnostics by URI (for code actions), with the file text they were computed on.
    diags: HashMap<String, Vec<Diag>>,
    shutdown: bool,
    exit: bool,
}

struct Doc {
    text: String,
    /// The analysis of `text`.
    model: Model,
}

#[derive(Default)]
struct Model {
    /// The typed program; partial when the program has errors (`check::check_partial`), so
    /// hover still works in code that type-checked.
    typed: Option<TypedProgram>,
    /// Otherwise the module tree, when it loads (for syntactic go-to-definition).
    prog: Option<Program>,
}

impl Model {
    fn program(&self) -> Option<&Program> {
        self.typed.as_ref().map(|t| &t.program).or(self.prog.as_ref())
    }
}

/// The path to analyze a document as (canonical, so project modules found from it agree).
fn doc_path(uri: &str) -> PathBuf {
    let p = uri_to_path(uri);
    p.canonicalize().unwrap_or(p)
}

/// Load and check the program rooted at `path` with the given root text.
fn analyze(path: &Path, text: &str) -> (Model, Vec<FileDiag>) {
    let run = || match resolve::load_in_package(path, text.to_string()) {
        Err(ds) => (Model::default(), ds),
        Ok(prog) => {
            let (tp, ds) = check::check_partial(prog);
            // warnings are only shown alongside errors (as `check::check` does)
            let ds = if ds.iter().all(|d| d.diag.is_warning()) { Vec::new() } else { ds };
            let prog = if tp.is_none() { resolve::load_in_package(path, text.to_string()).ok() } else { None };
            (Model { typed: tp, prog }, ds)
        }
    };
    catch_unwind(AssertUnwindSafe(run)).unwrap_or_else(|_| {
        eprintln!("duck lsp: the checker panicked on {}", path.display());
        (Model::default(), Vec::new())
    })
}

impl Server {
    fn handle(&mut self, msg: &Json) -> Vec<Json> {
        let method = msg.get("method").as_str().unwrap_or("");
        let params = msg.get("params");
        let id = msg.get("id").clone();
        let is_request = !id.is_null();
        if method.is_empty() {
            return Vec::new(); // a response to something we never send
        }
        if self.shutdown && is_request && method != "exit" {
            return vec![error_reply(id, -32600, "the server is shut down")];
        }
        let result = match method {
            "initialize" => Some(initialize_result()),
            "shutdown" => {
                self.shutdown = true;
                Some(Json::Null)
            }
            "exit" => {
                self.exit = true;
                return Vec::new();
            }
            "textDocument/didOpen" => {
                let uri = params.at(&["textDocument", "uri"]).as_str().unwrap_or("").to_string();
                let text = params.at(&["textDocument", "text"]).as_str().unwrap_or("").to_string();
                return self.update(uri, text);
            }
            "textDocument/didChange" => {
                let uri = params.at(&["textDocument", "uri"]).as_str().unwrap_or("").to_string();
                let Some(doc) = self.docs.get(&uri) else { return Vec::new() };
                let mut text = doc.text.clone();
                for ch in params.get("contentChanges").as_arr() {
                    let new = ch.get("text").as_str().unwrap_or("");
                    match ch.get("range") {
                        Json::Null => text = new.to_string(),
                        r => {
                            let a = byte_offset(&text, json_pos(r.get("start")));
                            let b = byte_offset(&text, json_pos(r.get("end")));
                            text.replace_range(a..b.max(a), new);
                        }
                    }
                }
                return self.update(uri, text);
            }
            "textDocument/didSave" => {
                let uri = params.at(&["textDocument", "uri"]).as_str().unwrap_or("").to_string();
                let text = match params.get("text").as_str() {
                    Some(t) => t.to_string(),
                    None => match self.docs.get(&uri) {
                        Some(d) => d.text.clone(),
                        None => return Vec::new(),
                    },
                };
                return self.update(uri, text);
            }
            "textDocument/didClose" => {
                let uri = params.at(&["textDocument", "uri"]).as_str().unwrap_or("").to_string();
                self.docs.remove(&uri);
                let mut out = vec![publish(&uri, Vec::new())];
                for o in self.others.remove(&uri).unwrap_or_default() {
                    if !self.docs.contains_key(&o) {
                        self.diags.remove(&o);
                        out.push(publish(&o, Vec::new()));
                    }
                }
                self.diags.remove(&uri);
                return out;
            }
            "textDocument/hover" => Some(self.with_doc(params, hover).unwrap_or(Json::Null)),
            "textDocument/definition" => Some(self.with_doc(params, definition).unwrap_or(Json::Null)),
            "textDocument/formatting" => Some(self.formatting(params)),
            "textDocument/documentSymbol" => Some(self.symbols(params)),
            "textDocument/codeAction" => Some(self.code_actions(params)),
            _ => None,
        };
        match (is_request, result) {
            (true, Some(r)) => vec![reply(id, r)],
            (true, None) => vec![error_reply(id, -32601, &format!("unknown method `{method}`"))],
            (false, _) => Vec::new(),
        }
    }

    /// Store the new text, re-analyze, and publish diagnostics (for this file and any other
    /// file of the program that has errors).
    fn update(&mut self, uri: String, text: String) -> Vec<Json> {
        let path = doc_path(&uri);
        let root_file = path.display().to_string();
        let (model, diags) = analyze(&path, &text);
        let mut by_uri: BTreeMap<String, Vec<Diag>> = BTreeMap::new();
        by_uri.insert(uri.clone(), Vec::new());
        for FileDiag { file, diag } in diags {
            let target = if file == root_file { Some(uri.clone()) } else { file_uri(&file) };
            if let Some(u) = target {
                by_uri.entry(u).or_default().push(diag);
            }
        }
        self.docs.insert(uri.clone(), Doc { text, model });
        let mut out = Vec::new();
        let old = self.others.remove(&uri).unwrap_or_default();
        let mut now = BTreeSet::new();
        for (u, ds) in by_uri {
            if u != uri {
                // another file's errors: don't override that file's own analysis when it is open
                if self.docs.contains_key(&u) {
                    continue;
                }
                now.insert(u.clone());
            }
            let Some(src) = self.text_of(&u) else { continue };
            let json: Vec<Json> = ds.iter().map(|d| diagnostic(&u, &src, d)).collect();
            out.push(publish(&u, json));
            self.diags.insert(u, ds);
        }
        for o in old.difference(&now) {
            if !self.docs.contains_key(o) {
                self.diags.remove(o);
                out.push(publish(o, Vec::new()));
            }
        }
        self.others.insert(uri, now);
        out
    }

    /// The current text of a file: the open buffer, or the file on disk.
    fn text_of(&self, uri: &str) -> Option<String> {
        match self.docs.get(uri) {
            Some(d) => Some(d.text.clone()),
            None => std::fs::read_to_string(uri_to_path(uri)).ok(),
        }
    }

    fn with_doc(&self, params: &Json, f: impl FnOnce(&Doc, (u32, u32)) -> Option<Json>) -> Option<Json> {
        let uri = params.at(&["textDocument", "uri"]).as_str()?;
        let doc = self.docs.get(uri)?;
        let (line, ch) = json_pos(params.get("position"));
        let pos = from_lsp(&doc.text, line, ch);
        catch_unwind(AssertUnwindSafe(|| f(doc, pos))).ok().flatten()
    }

    fn formatting(&self, params: &Json) -> Json {
        let Some(doc) = params.at(&["textDocument", "uri"]).as_str().and_then(|u| self.docs.get(u)) else { return Json::Null };
        let Ok(Ok(out)) = catch_unwind(|| fmt::format(&doc.text)) else { return Json::Null };
        if out == doc.text {
            return Json::Arr(Vec::new());
        }
        let lines = doc.text.split('\n').count() as u32;
        let whole = obj([("start", position((0, 0))), ("end", position((lines, 0)))]);
        Json::Arr(vec![obj([("range", whole), ("newText", out.into())])])
    }

    fn symbols(&self, params: &Json) -> Json {
        let Some(doc) = params.at(&["textDocument", "uri"]).as_str().and_then(|u| self.docs.get(u)) else { return Json::Null };
        let Ok(Ok(m)) = catch_unwind(|| parser::parse(&doc.text)) else { return Json::Arr(Vec::new()) };
        let src = &doc.text;
        let sym = |name: &str, detail: String, kind: u32, span: Span, sel: Span, children: Vec<Json>| {
            obj([
                ("name", name.into()),
                ("detail", detail.into()),
                ("kind", kind.into()),
                ("range", range(src, span)),
                ("selectionRange", range(src, sel)),
                ("children", Json::Arr(children)),
            ])
        };
        let mut out = Vec::new();
        for item in &m.items {
            match item {
                Item::Fn(g) => {
                    let first = g.header.as_deref().or(g.clauses.first());
                    let Some(c) = first else { continue };
                    let last = g.clauses.last().map(|c| c.span).unwrap_or(c.span);
                    let detail = if g.clauses.len() > 1 { format!("{} clauses", g.clauses.len()) } else { String::new() };
                    out.push(sym(&g.name, detail, 12, c.span.to(last), c.name.span, Vec::new()));
                }
                Item::Struct(d) => {
                    let fields = d.fields.iter().map(|f| sym(&f.name.name, String::new(), 8, f.span, f.name.span, Vec::new())).collect();
                    out.push(sym(&d.name.name, String::new(), 23, d.span, d.name.span, fields));
                }
                Item::Enum(d) => {
                    let vs = d.variants.iter().map(|v| sym(&v.name.name, String::new(), 22, v.span, v.name.span, Vec::new())).collect();
                    out.push(sym(&d.name.name, String::new(), 10, d.span, d.name.span, vs));
                }
                Item::Shape(d) => {
                    let ms = d.methods.iter().map(|c| sym(&c.name.name, String::new(), 6, c.span, c.name.span, Vec::new())).collect();
                    out.push(sym(&d.name.name, String::new(), 11, d.span, d.name.span, ms));
                }
                Item::Test(t) => out.push(sym(&format!("test {:?}", t.name), String::new(), 12, t.span, t.span, Vec::new())),
                Item::Let(c) | Item::Imprint(c) => out.push(sym(&c.name.name, String::new(), 14, c.span, c.name.span, Vec::new())),
                Item::ExternType(t) => out.push(sym(&t.name.name, String::new(), 23, t.span, t.name.span, Vec::new())),
            }
        }
        Json::Arr(out)
    }

    /// One quick fix per diagnostic with fix-its, for the diagnostics overlapping the range.
    fn code_actions(&self, params: &Json) -> Json {
        let Some(uri) = params.at(&["textDocument", "uri"]).as_str() else { return Json::Null };
        let Some(src) = self.text_of(uri) else { return Json::Null };
        let (a, b) = (json_pos(params.at(&["range", "start"])), json_pos(params.at(&["range", "end"])));
        let mut out = Vec::new();
        for d in self.diags.get(uri).into_iter().flatten() {
            if d.fixes.is_empty() {
                continue;
            }
            let (s, e) = (to_lsp(&src, d.span.line, d.span.col), to_lsp(&src, d.span.end_line, d.span.end_col));
            if e < a || b < s {
                continue;
            }
            let edits: Vec<Json> = d.fixes.iter().map(|f| obj([("range", range(&src, f.span)), ("newText", f.text.as_str().into())])).collect();
            out.push(obj([
                ("title", fix_title(d).into()),
                ("kind", "quickfix".into()),
                ("diagnostics", Json::Arr(vec![diagnostic(uri, &src, d)])),
                ("isPreferred", true.into()),
                ("edit", obj([("changes", Json::Obj(vec![(uri.to_string(), Json::Arr(edits))]))])),
            ]));
        }
        Json::Arr(out)
    }
}

fn initialize_result() -> Json {
    obj([
        (
            "capabilities",
            obj([
                ("textDocumentSync", obj([("openClose", true.into()), ("change", 1u32.into()), ("save", obj([("includeText", true.into())]))])),
                ("hoverProvider", true.into()),
                ("definitionProvider", true.into()),
                ("documentFormattingProvider", true.into()),
                ("documentSymbolProvider", true.into()),
                ("codeActionProvider", obj([("codeActionKinds", Json::Arr(vec!["quickfix".into()]))])),
            ]),
        ),
        ("serverInfo", obj([("name", "duck".into()), ("version", env!("CARGO_PKG_VERSION").into())])),
    ])
}

/// The byte offset of an LSP position in `text` (clamped to the text).
fn byte_offset(text: &str, (line, ch): (u32, u32)) -> usize {
    let mut start = 0;
    for _ in 0..line {
        match text[start..].find('\n') {
            Some(i) => start += i + 1,
            None => return text.len(),
        }
    }
    let mut units = 0;
    for (i, c) in text[start..].char_indices() {
        if units >= ch || c == '\n' {
            return start + i;
        }
        units += c.len_utf16() as u32;
    }
    text.len()
}

fn publish(uri: &str, diags: Vec<Json>) -> Json {
    notification("textDocument/publishDiagnostics", obj([("uri", uri.into()), ("diagnostics", Json::Arr(diags))]))
}

fn diagnostic(uri: &str, src: &str, d: &Diag) -> Json {
    let r = range(src, d.span);
    let mut fields = vec![
        ("range".to_string(), r.clone()),
        ("severity".to_string(), 1u32.into()),
        ("code".to_string(), d.code.into()),
        ("source".to_string(), "duck".into()),
        ("message".to_string(), d.message.as_str().into()),
    ];
    if !d.notes.is_empty() {
        let loc = obj([("uri", uri.into()), ("range", r)]);
        let rel = d.notes.iter().map(|n| obj([("location", loc.clone()), ("message", n.as_str().into())])).collect();
        fields.push(("relatedInformation".to_string(), Json::Arr(rel)));
    }
    Json::Obj(fields)
}

/// "Insert `?`", "Replace with `str`", "Remove the text", or (several edits) the note that
/// explains them.
fn fix_title(d: &Diag) -> String {
    match d.fixes.as_slice() {
        [f] => {
            let empty = f.span.line == f.span.end_line && f.span.col == f.span.end_col;
            match (f.text.is_empty(), empty) {
                (true, _) => "Remove the text".to_string(),
                (false, true) => format!("Insert `{}`", f.text),
                (false, false) => format!("Replace with `{}`", f.text),
            }
        }
        _ => match d.notes.last() {
            Some(n) => format!("Fix: {n}"),
            None => format!("Fix: {}", d.message),
        },
    }
}

// ---- finding the node under the cursor ----

/// What the cursor is on.
#[derive(Clone, Copy)]
enum Hit<'a> {
    /// An expression, with its parent expression (a `Call`/`Pipe` whose callee it may be).
    Expr(&'a Expr, Option<&'a Expr>),
    /// The member name of `x.f`, `x.f(a)` or `x?.f`, with the parent of the `x.f` expression.
    Member(&'a Expr, &'a Ident, Option<&'a Expr>),
    /// A field name in a struct literal.
    LitField(&'a Expr, &'a Ident),
    Pat(&'a Pat),
    /// A field name in a struct pattern.
    PatField(&'a Pat, &'a Ident),
    /// Segment `i` of a type or struct path.
    TypePath(&'a [Ident], usize),
    /// The name of a function clause: item index, clause index (`None` for the header).
    FnDecl(usize, Option<usize>),
    /// Another declaration's name (its own definition).
    Decl(Span),
}

struct Finder<'a> {
    pos: (u32, u32),
    hit: Option<Hit<'a>>,
}

impl<'a> Finder<'a> {
    fn at(&mut self, s: Span, h: Hit<'a>) -> bool {
        let inside = span_contains(s, self.pos);
        if inside {
            self.hit = Some(h);
        }
        inside
    }

    fn item(&mut self, i: usize, item: &'a Item) {
        match item {
            Item::Fn(g) => {
                if let Some(h) = &g.header {
                    self.clause(h, Some((i, None)));
                }
                for (ci, c) in g.clauses.iter().enumerate() {
                    self.clause(c, Some((i, Some(ci))));
                }
            }
            Item::Struct(d) => {
                self.at(d.name.span, Hit::Decl(d.name.span));
                for f in &d.fields {
                    self.at(f.name.span, Hit::Decl(f.name.span));
                    self.ty(&f.ty);
                }
            }
            Item::Enum(d) => {
                self.at(d.name.span, Hit::Decl(d.name.span));
                for v in &d.variants {
                    self.at(v.name.span, Hit::Decl(v.name.span));
                    v.fields.iter().for_each(|f| self.ty(&f.ty));
                }
            }
            Item::Shape(d) => {
                self.at(d.name.span, Hit::Decl(d.name.span));
                d.methods.iter().for_each(|c| self.clause(c, None));
            }
            Item::Test(t) => t.body.stmts.iter().for_each(|s| self.expr(s, None)),
            Item::Let(c) | Item::Imprint(c) => {
                self.at(c.name.span, Hit::Decl(c.name.span));
                if let Some(t) = &c.ty {
                    self.ty(t);
                }
                self.expr(&c.value, None);
            }
            Item::ExternType(t) => {
                self.at(t.name.span, Hit::Decl(t.name.span));
            }
        }
    }

    fn clause(&mut self, c: &'a FnClause, which: Option<(usize, Option<usize>)>) {
        let h = which.map(|(i, ci)| Hit::FnDecl(i, ci)).unwrap_or(Hit::Decl(c.name.span));
        self.at(c.name.span, h);
        for g in &c.generics {
            g.bounds.iter().for_each(|t| self.ty(t));
        }
        for p in &c.params {
            self.pat(&p.pat);
            if let Some(t) = &p.ty {
                self.ty(t);
            }
        }
        if let Some(t) = &c.ret {
            self.ty(t);
        }
        for e in c.requires.iter().chain(&c.ensures).chain(&c.guard) {
            self.expr(e, None);
        }
        match &c.body {
            Some(FnBody::Expr(e)) => self.expr(e, None),
            Some(FnBody::Block(b)) => b.stmts.iter().for_each(|s| self.expr(s, None)),
            _ => {}
        }
    }

    fn path(&mut self, path: &'a [Ident]) {
        for (i, seg) in path.iter().enumerate() {
            self.at(seg.span, Hit::TypePath(path, i));
        }
    }

    fn ty(&mut self, t: &'a Type) {
        if !span_contains(t.span, self.pos) {
            return;
        }
        match &t.kind {
            TypeKind::Named { path, args } => {
                self.path(path);
                args.iter().for_each(|a| self.ty(a));
            }
            TypeKind::List(x) | TypeKind::Optional(x) | TypeKind::Any(x) => self.ty(x),
            TypeKind::Measured { base, .. } => self.ty(base),
            TypeKind::Map(k, v) => {
                self.ty(k);
                self.ty(v);
            }
            TypeKind::Tuple(ts) => ts.iter().for_each(|x| self.ty(x)),
            TypeKind::Fallible { ok, err } => {
                self.ty(ok);
                if let Some(e) = err {
                    self.ty(e);
                }
            }
            TypeKind::Fn { params, ret } => {
                params.iter().for_each(|x| self.ty(x));
                self.ty(ret);
            }
        }
    }

    fn pat(&mut self, p: &'a Pat) {
        if !self.at(p.span, Hit::Pat(p)) {
            return;
        }
        match &p.kind {
            PatKind::Wild | PatKind::Bind(_) | PatKind::Lit { .. } | PatKind::None => {}
            PatKind::Tuple(ps) => ps.iter().for_each(|x| self.pat(x)),
            PatKind::List { head, rest, tail } => {
                head.iter().for_each(|x| self.pat(x));
                if let Some(r) = rest.as_ref().and_then(|r| r.pat.as_ref()) {
                    self.pat(r);
                }
                tail.iter().for_each(|x| self.pat(x));
            }
            // the variant name stands for the whole pattern (the table is keyed on it)
            PatKind::Variant { args, .. } => args.iter().flatten().for_each(|x| self.pat(x)),
            PatKind::Struct { path, fields, .. } => {
                self.path(path);
                for FieldPat { name, pat } in fields {
                    self.at(name.span, Hit::PatField(p, name));
                    if let Some(x) = pat {
                        self.pat(x);
                    }
                }
            }
            PatKind::Map(es) => es.iter().for_each(|(_, x)| self.pat(x)),
            PatKind::StrPrefix { rest, .. } => self.pat(rest),
            PatKind::Some(x) | PatKind::Ok(x) | PatKind::Err(x) => self.pat(x),
        }
    }

    fn expr(&mut self, e: &'a Expr, parent: Option<&'a Expr>) {
        if !self.at(e.span, Hit::Expr(e, parent)) {
            return;
        }
        let me = Some(e);
        match &e.kind {
            K::Lit(_) | K::Name(_) | K::Hole | K::Continue => {}
            K::Measured { expr, .. } => self.expr(expr, me),
            K::Interp(ps) => {
                for p in ps {
                    if let InterpPart::Expr { expr, .. } = p {
                        self.expr(expr, me);
                    }
                }
            }
            K::Field { expr, name } => {
                self.expr(expr, me);
                self.at(name.span, Hit::Member(e, name, parent));
            }
            K::TupleField { expr, .. } | K::Unary { expr, .. } => self.expr(expr, me),
            K::Is { expr, pat } => {
                self.expr(expr, me);
                self.pat(pat);
            }
            K::Try(x) | K::Unwrap(x) | K::Await(x) | K::AwaitAny(x) | K::Catch(x) | K::Ref(x) | K::Assert(x) | K::Peek(x) => self.expr(x, me),
            K::Call { callee, args } => {
                self.expr(callee, me);
                args.iter().for_each(|a| self.expr(a, me));
            }
            K::MethodCall { recv, name, args } => {
                self.expr(recv, me);
                self.at(name.span, Hit::Member(e, name, parent));
                args.iter().for_each(|a| self.expr(a, me));
            }
            K::Pipe { lhs, callee, args } => {
                self.expr(lhs, me);
                self.expr(callee, me);
                args.iter().for_each(|a| self.expr(a, me));
            }
            K::Index { expr, index } => {
                self.expr(expr, me);
                self.expr(index, me);
            }
            K::Slice { expr, lo, hi, .. } => {
                self.expr(expr, me);
                self.expr(lo, me);
                self.expr(hi, me);
            }
            K::Binary { lhs, rhs, .. } => {
                self.expr(lhs, me);
                self.expr(rhs, me);
            }
            K::Range { lo, hi, .. } => {
                self.expr(lo, me);
                self.expr(hi, me);
            }
            K::OptChain { expr, name, args } => {
                self.expr(expr, me);
                self.at(name.span, Hit::Member(e, name, parent));
                args.iter().flatten().for_each(|a| self.expr(a, me));
            }
            K::Else { expr, arm } => {
                self.expr(expr, me);
                if let Some(b) = &arm.binder {
                    self.at(b.span, Hit::Decl(b.span));
                }
                self.expr(&arm.body, me);
            }
            K::Closure { params, body } => {
                for p in params {
                    self.pat(&p.pat);
                    if let Some(t) = &p.ty {
                        self.ty(t);
                    }
                }
                self.expr(body, me);
            }
            K::If { cond, then, els } => {
                self.expr(cond, me);
                then.stmts.iter().for_each(|s| self.expr(s, me));
                if let Some(x) = els {
                    self.expr(x, me);
                }
            }
            K::Match { scrut, arms } => {
                self.expr(scrut, me);
                for a in arms {
                    self.pat(&a.pat);
                    if let Some(g) = &a.guard {
                        self.expr(g, me);
                    }
                    self.expr(&a.body, me);
                }
            }
            K::Loop(b) | K::Block(b) => b.stmts.iter().for_each(|s| self.expr(s, me)),
            K::While { cond, body } => {
                self.expr(cond, me);
                body.stmts.iter().for_each(|s| self.expr(s, me));
            }
            K::For { index, pat, iter, body } => {
                if let Some(i) = index {
                    self.pat(i);
                }
                self.pat(pat);
                self.expr(iter, me);
                body.stmts.iter().for_each(|s| self.expr(s, me));
            }
            K::Let { pat, ty, value, els, .. } => {
                self.pat(pat);
                if let Some(t) = ty {
                    self.ty(t);
                }
                self.expr(value, me);
                if let Some(a) = els {
                    if let Some(b) = &a.binder {
                        self.at(b.span, Hit::Decl(b.span));
                    }
                    self.expr(&a.body, me);
                }
            }
            K::Assign { target, value, .. } => {
                self.expr(target, me);
                self.expr(value, me);
            }
            K::Return(x) | K::Break(x) => {
                if let Some(x) = x {
                    self.expr(x, me);
                }
            }
            K::Struct { path, fields, base } => {
                self.path(path);
                for f in fields {
                    self.at(f.name.span, Hit::LitField(e, &f.name));
                    if let Some(v) = &f.value {
                        self.expr(v, me);
                    }
                }
                if let Some(b) = base {
                    self.expr(b, me);
                }
            }
            K::List(xs) | K::Tuple(xs) => xs.iter().for_each(|x| self.expr(x, me)),
            K::Map(es) => {
                for (k, v) in es {
                    self.expr(k, me);
                    self.expr(v, me);
                }
            }
        }
    }
}

/// The innermost node of module `m` at `pos` (1-based line, char column).
fn find(prog: &Program, m: ModId, pos: (u32, u32)) -> Option<Hit<'_>> {
    let mut f = Finder { pos, hit: None };
    for (i, item) in prog.mods[m].ast.items.iter().enumerate() {
        f.item(i, item);
    }
    f.hit
}

/// `a.b.c` as a list of names, if `e` is a plain path.
fn as_path(e: &Expr) -> Option<Vec<&str>> {
    match &e.kind {
        K::Name(n) => Some(vec![n.as_str()]),
        K::Field { expr, name } => {
            let mut p = as_path(expr)?;
            p.push(&name.name);
            Some(p)
        }
        _ => None,
    }
}

// ---- go to definition ----

/// A place in a file of the program.
type Loc = (ModId, Span);

fn definition(doc: &Doc, pos: (u32, u32)) -> Option<Json> {
    let prog = doc.model.program()?;
    let m = prog.focus;
    let hit = find(prog, m, pos)?;
    let (dm, span) = doc.model.typed.as_ref().and_then(|tp| typed_definition(tp, m, hit)).or_else(|| syntactic_definition(prog, m, hit))?;
    let file = &prog.mods[dm].file;
    let (uri, src) = if dm == m {
        (None, doc.text.clone())
    } else {
        (Some(file_uri(file)?), prog.mods[dm].src.clone())
    };
    let uri = uri.unwrap_or_else(|| path_to_uri(file));
    Some(obj([("uri", uri.into()), ("range", range(&src, span))]))
}

fn fn_loc(tp: &TypedProgram, f: usize) -> Loc {
    (tp.fns[f].module, tp.fns[f].span)
}

fn variant_loc(tp: &TypedProgram, def: DefId, index: usize) -> Option<Loc> {
    let d = &tp.defs.types[def];
    let v = tp.defs.variants(def).get(index)?;
    Some((d.module, name_span(v.span, &v.name)))
}

/// The part of a declaration's span that is its name (fields and variants record the whole
/// declaration, which starts with the name).
fn name_span(s: Span, name: &str) -> Span {
    Span { end_line: s.line, end_col: s.col + name.chars().count() as u32, ..s }
}

fn field_loc(tp: &TypedProgram, def: DefId, name: &str) -> Option<Loc> {
    let d = &tp.defs.types[def];
    Some((d.module, name_span(tp.defs.fields(def).iter().find(|f| f.name == name)?.span, name)))
}

fn callee_loc(tp: &TypedProgram, c: &Callee) -> Option<Loc> {
    match c {
        Callee::Fn { func, .. } => Some(fn_loc(tp, *func)),
        Callee::Variant(v) => variant_loc(tp, v.def, v.index),
        Callee::Shape { shape, .. } | Callee::Vtable { shape, .. } => {
            let s = &tp.defs.shapes[*shape];
            Some((s.module, s.span))
        }
        Callee::Closure => None,
    }
}

fn name_loc(tp: &TypedProgram, m: ModId, n: &NameRef) -> Option<Loc> {
    match n {
        NameRef::Local(l) => Some((m, tp.tables[m].locals[*l].span)),
        NameRef::Const(c) => Some((tp.consts[*c].module, tp.consts[*c].span)),
        NameRef::Fn { func, .. } => Some(fn_loc(tp, *func)),
        NameRef::Variant(v) => variant_loc(tp, v.def, v.index),
        NameRef::None => None,
    }
}

/// The call node whose callee is `e`, if any.
fn call_of<'a>(e: &Expr, parent: Option<&'a Expr>) -> Option<&'a Expr> {
    let p = parent?;
    match &p.kind {
        K::Call { callee, .. } | K::Pipe { callee, .. } if callee.id == e.id => Some(p),
        _ => None,
    }
}

fn typed_definition(tp: &TypedProgram, m: ModId, hit: Hit) -> Option<Loc> {
    let t = &tp.tables[m];
    match hit {
        Hit::Expr(e, parent) => {
            if let Some(n) = t.names.get(&e.id) {
                return name_loc(tp, m, n);
            }
            if let Some(c) = call_of(e, parent).and_then(|c| t.calls.get(&c.id)) {
                return callee_loc(tp, &c.callee);
            }
            match &e.kind {
                K::Field { name, .. } => typed_definition(tp, m, Hit::Member(e, name, parent)),
                _ => None,
            }
        }
        Hit::Member(e, name, parent) => {
            if let Some(n) = t.names.get(&e.id) {
                return name_loc(tp, m, n);
            }
            if let Some(c) = t.calls.get(&e.id).or_else(|| t.calls.get(&call_of(e, parent)?.id)) {
                return callee_loc(tp, &c.callee);
            }
            if let Some(&(def, _)) = t.fields.get(&e.id) {
                return field_loc(tp, def, &name.name);
            }
            None
        }
        Hit::LitField(e, name) => field_loc(tp, t.struct_lits.get(&e.id)?.def, &name.name),
        Hit::PatField(p, name) => field_loc(tp, t.struct_pats.get(&p.id)?.def, &name.name),
        Hit::Pat(p) => {
            if let Some(l) = t.binds.get(&p.id) {
                return Some((m, t.locals[*l].span));
            }
            if let Some(v) = t.variants.get(&p.id) {
                return variant_loc(tp, v.def, v.index);
            }
            if let Some(sp) = t.struct_pats.get(&p.id) {
                let d = &tp.defs.types[sp.def];
                return Some((d.module, d.span));
            }
            None
        }
        Hit::TypePath(..) | Hit::FnDecl(..) | Hit::Decl(_) => None,
    }
}

fn syntactic_definition(prog: &Program, m: ModId, hit: Hit) -> Option<Loc> {
    match hit {
        Hit::Expr(e, _) => find_item(prog, m, &as_path(e)?),
        Hit::Member(e, name, _) => match &e.kind {
            K::Field { .. } => find_item(prog, m, &as_path(e)?),
            K::MethodCall { recv, .. } => {
                let mut p = as_path(recv).filter(|p| module_path(prog, m, p).is_some()).unwrap_or_default();
                p.push(&name.name);
                find_item(prog, m, &p)
            }
            _ => find_item(prog, m, &[&name.name]),
        },
        Hit::Pat(p) => match &p.kind {
            PatKind::Variant { path, .. } => find_item(prog, m, &path.iter().map(|i| i.name.as_str()).collect::<Vec<_>>()),
            _ => None,
        },
        Hit::TypePath(path, i) => find_item(prog, m, &path[..=i].iter().map(|i| i.name.as_str()).collect::<Vec<_>>()),
        Hit::FnDecl(item, clause) => {
            let Item::Fn(g) = &prog.mods[m].ast.items[item] else { return None };
            let c = match clause {
                Some(ci) => &g.clauses[ci],
                None => g.header.as_deref()?,
            };
            Some((m, c.name.span))
        }
        Hit::Decl(s) => Some((m, s)),
        Hit::LitField(..) | Hit::PatField(..) => None,
    }
}

/// The module a path of module names leads to from module `m`.
fn module_path(prog: &Program, m: ModId, path: &[&str]) -> Option<ModId> {
    let (first, rest) = path.split_first()?;
    rest.iter().try_fold(prog.first_segment(m, first)?, |mm, seg| prog.child(mm, seg))
}

/// An item named `name` declared in module `m` (functions, types, shapes, constants, then
/// enum variants).
fn item_in(prog: &Program, m: ModId, name: &str) -> Option<Span> {
    let items = &prog.mods[m].ast.items;
    let direct = items.iter().find_map(|item| match item {
        Item::Fn(g) if g.name == name => g.header.as_deref().or(g.clauses.first()).map(|c| c.name.span),
        Item::Struct(d) if d.name.name == name => Some(d.name.span),
        Item::Enum(d) if d.name.name == name => Some(d.name.span),
        Item::Shape(d) if d.name.name == name => Some(d.name.span),
        Item::ExternType(d) if d.name.name == name => Some(d.name.span),
        Item::Let(c) | Item::Imprint(c) if c.name.name == name => Some(c.name.span),
        _ => None,
    });
    direct.or_else(|| {
        items.iter().find_map(|item| match item {
            Item::Enum(d) => d.variants.iter().find(|v| v.name.name == name).map(|v| v.name.span),
            _ => None,
        })
    })
}

/// A variant `v` of an enum named `ty` declared in module `m`.
fn variant_in(prog: &Program, m: ModId, ty: &str, v: &str) -> Option<Span> {
    prog.mods[m].ast.items.iter().find_map(|item| match item {
        Item::Enum(d) if d.name.name == ty => d.variants.iter().find(|x| x.name.name == v).map(|x| x.name.span),
        _ => None,
    })
}

/// Look a path up without types: a name in the module, then core, then a module of that name,
/// then (for dot calls, whose target depends on the receiver's type) any module of the package
/// and then the whole program; `m.x` / `T.Variant` / `m.T.Variant` by their paths.
fn find_item(prog: &Program, m: ModId, path: &[&str]) -> Option<Loc> {
    let module_start = |mm: ModId| (mm, Span { line: 1, col: 1, end_line: 1, end_col: 1 });
    match path {
        [] => None,
        [name] => {
            if let Some(s) = item_in(prog, m, name) {
                return Some((m, s));
            }
            if let Some(s) = item_in(prog, prog.core_root, name) {
                return Some((prog.core_root, s));
            }
            if let Some(mm) = prog.first_segment(m, name).filter(|&mm| !prog.mods[mm].file.is_empty()) {
                return Some(module_start(mm));
            }
            let pkg = prog.mods[m].pkg;
            let same_pkg = (0..prog.mods.len()).filter(|&x| prog.mods[x].pkg == pkg);
            let rest = (0..prog.mods.len()).filter(|&x| prog.mods[x].pkg != pkg);
            same_pkg.chain(rest).find_map(|x| item_in(prog, x, name).map(|s| (x, s)))
        }
        [.., last] => {
            let init = &path[..path.len() - 1];
            if let Some(mm) = module_path(prog, m, init) {
                if let Some(s) = item_in(prog, mm, last) {
                    return Some((mm, s));
                }
                if let Some(c) = prog.child(mm, last).filter(|&c| !prog.mods[c].file.is_empty()) {
                    return Some(module_start(c));
                }
            }
            // `T.Variant` or `m.T.Variant`
            let ty = init[init.len() - 1];
            let scope = if init.len() == 1 { Some(m) } else { module_path(prog, m, &init[..init.len() - 1]) };
            for mm in scope.into_iter().chain([prog.core_root]) {
                if let Some(s) = variant_in(prog, mm, ty, last) {
                    return Some((mm, s));
                }
            }
            None
        }
    }
}

// ---- hover ----

fn hover(doc: &Doc, pos: (u32, u32)) -> Option<Json> {
    let tp = doc.model.typed.as_ref()?;
    let m = tp.program.focus;
    let hit = find(&tp.program, m, pos)?;
    let (code, docs) = hover_text(tp, m, hit)?;
    let mut value = format!("```duck\n{code}\n```");
    if let Some(o) = hover_origin(tp, m, hit).and_then(|loc| origin_text(&tp.program, m, loc)) {
        value += "\n\n";
        value += &o;
    }
    if let Some(d) = docs.filter(|d| !d.trim().is_empty()) {
        value += "\n\n";
        value += d.trim();
    }
    Some(obj([("contents", obj([("kind", "markdown".into()), ("value", value.into())]))]))
}

/// Where the thing under the cursor is defined, for the hover's "Defined in" line.
fn hover_origin(tp: &TypedProgram, m: ModId, hit: Hit) -> Option<Loc> {
    let module_start = |mm: ModId| (mm, Span { line: 1, col: 1, end_line: 1, end_col: 1 });
    match hit {
        Hit::TypePath(path, i) => find_item(&tp.program, m, &path[..=i].iter().map(|x| x.name.as_str()).collect::<Vec<_>>()),
        Hit::FnDecl(..) | Hit::Decl(_) => None,
        Hit::Expr(e, _) | Hit::Member(e, _, _) => typed_definition(tp, m, hit).or_else(|| {
            // a module path (`util`, `audio.out`): the module itself
            if tp.tables[m].types.contains_key(&e.id) {
                return None;
            }
            module_path(&tp.program, m, &as_path(e)?).map(module_start)
        }),
        _ => typed_definition(tp, m, hit),
    }
}

/// "Defined in `core.list` (core library)", "Defined in `audio.out` (library `audio`) — [out.duck:12](…)";
/// nothing for what is defined in the file itself.
fn origin_text(prog: &Program, m: ModId, (dm, span): Loc) -> Option<String> {
    if dm == m {
        return None;
    }
    let md = &prog.mods[dm];
    let pkg = &prog.pkgs[md.pkg];
    let whose = if pkg.is_core {
        "core library".to_string()
    } else if md.pkg == prog.mods[m].pkg {
        "this package".to_string()
    } else {
        format!("library `{}`", pkg.name)
    };
    let mut s = format!("Defined in `{}` ({whose})", prog.name(dm));
    if let Some(uri) = file_uri(&md.file) {
        let base = Path::new(&md.file).file_name().map(|f| f.to_string_lossy().to_string()).unwrap_or_default();
        s += &format!(" — [{base}:{}]({uri}#L{})", span.line, span.line);
    }
    Some(s)
}

/// `pub async fn name<A: Show>(a: int, xs: var [A]): str uses fs`.
pub fn signature(tp: &TypedProgram, f: usize) -> String {
    let fi = &tp.fns[f];
    let show = |t: &Ty| tp.defs.show(t);
    let gs: Vec<String> = fi
        .generics
        .iter()
        .map(|&g| &tp.defs.params[g])
        .filter(|p| !p.implicit)
        .map(|p| {
            let bounds: Vec<&str> = p.bounds.iter().map(|&s| tp.defs.shapes[s].name.as_str()).collect();
            if bounds.is_empty() { p.name.clone() } else { format!("{}: {}", p.name, bounds.join(" + ")) }
        })
        .collect();
    let ps: Vec<String> = fi
        .params
        .iter()
        .map(|p| format!("{}: {}{}", p.name.as_deref().unwrap_or("_"), if p.var { "var " } else { "" }, show(&p.ty)))
        .collect();
    let mut s = format!(
        "{}{}fn {}{}({})",
        if fi.public { "pub " } else { "" },
        if fi.is_async { "async " } else { "" },
        fi.name,
        if gs.is_empty() { String::new() } else { format!("<{}>", gs.join(", ")) },
        ps.join(", ")
    );
    if !fi.ret.is_unit() {
        s += &format!(": {}", show(&fi.ret));
    }
    if !fi.uses.is_empty() {
        s += &format!(" uses {}", fi.uses.join(", "));
    }
    s
}

fn variant_text(tp: &TypedProgram, def: DefId, index: usize) -> Option<String> {
    let d = &tp.defs.types[def];
    let v = tp.defs.variants(def).get(index)?;
    let mut s = format!("{}.{}", d.name, v.name);
    if !v.fields.is_empty() {
        let fs: Vec<String> = v
            .fields
            .iter()
            .map(|(n, t)| match n {
                Some(n) => format!("{n}: {}", tp.defs.show(t)),
                None => tp.defs.show(t),
            })
            .collect();
        s += &format!("({})", fs.join(", "));
    }
    Some(s)
}

fn name_hover(tp: &TypedProgram, m: ModId, n: &NameRef) -> Option<(String, Option<String>)> {
    match n {
        NameRef::Local(l) => {
            let l = &tp.tables[m].locals[*l];
            Some((format!("{} {}: {}", if l.mutable { "var" } else { "let" }, l.name, tp.defs.show(&l.ty)), None))
        }
        NameRef::Const(c) => {
            let c = &tp.consts[*c];
            let doc = match &tp.program.mods[c.module].ast.items[c.item] {
                Item::Let(d) | Item::Imprint(d) => d.doc.clone(),
                _ => None,
            };
            Some((format!("{} {}: {}", if c.imprint { "imprint" } else { "let" }, c.name, tp.defs.show(&c.ty)), doc))
        }
        NameRef::Fn { func, .. } => Some((signature(tp, *func), tp.fns[*func].doc.clone())),
        NameRef::Variant(v) => Some((variant_text(tp, v.def, v.index)?, None)),
        NameRef::None => Some(("none".into(), None)),
    }
}

fn callee_hover(tp: &TypedProgram, c: &Callee) -> Option<(String, Option<String>)> {
    match c {
        Callee::Fn { func, .. } => Some((signature(tp, *func), tp.fns[*func].doc.clone())),
        Callee::Variant(v) => Some((variant_text(tp, v.def, v.index)?, None)),
        Callee::Shape { shape, method, .. } | Callee::Vtable { shape, method } => {
            let s = &tp.defs.shapes[*shape];
            let me = s.methods.get(*method)?;
            let ps: Vec<String> = me.params.iter().map(|t| tp.defs.show(t)).collect();
            Some((format!("fn {}({}): {}  // shape {}", me.name, ps.join(", "), tp.defs.show(&me.ret), s.name), None))
        }
        Callee::Closure => None,
    }
}

fn type_def_hover(tp: &TypedProgram, def: DefId) -> (String, Option<String>) {
    let d = &tp.defs.types[def];
    let kw = match d.kind {
        TypeDefKind::Struct { .. } => "struct",
        TypeDefKind::Enum { .. } => "enum",
        TypeDefKind::Opaque { .. } => "extern type",
    };
    let params: Vec<&str> = d.params.iter().map(|&p| tp.defs.params[p].name.as_str()).collect();
    let g = if params.is_empty() { String::new() } else { format!("<{}>", params.join(", ")) };
    (format!("{}{kw} {}{g}", if d.public { "pub " } else { "" }, d.name), d.doc.clone())
}

fn hover_text(tp: &TypedProgram, m: ModId, hit: Hit) -> Option<(String, Option<String>)> {
    let t = &tp.tables[m];
    let ty = |id| t.types.get(&id).map(|ty| tp.defs.show(ty));
    match hit {
        Hit::Expr(e, parent) => {
            if let Some(n) = t.names.get(&e.id) {
                return name_hover(tp, m, n);
            }
            if let Some(c) = call_of(e, parent).and_then(|c| t.calls.get(&c.id)) {
                return callee_hover(tp, &c.callee);
            }
            if !t.types.contains_key(&e.id)
                && let Some(path) = as_path(e)
                && let Some(mm) = module_path(&tp.program, m, &path)
            {
                return Some((format!("module {}", tp.program.name(mm)), tp.program.mods[mm].ast.doc.clone()));
            }
            Some((ty(e.id)?, None))
        }
        Hit::Member(e, name, parent) => {
            if let Some(n) = t.names.get(&e.id) {
                return name_hover(tp, m, n);
            }
            if let Some(c) = t.calls.get(&e.id).or_else(|| t.calls.get(&call_of(e, parent)?.id)) {
                return callee_hover(tp, &c.callee);
            }
            // `x?.0` names no field: its hover is the chain's type, like `x.0`'s
            if t.fields.contains_key(&e.id) || matches!(e.kind, K::OptChain { .. }) && name.tuple_index().is_none() {
                return Some((format!("{}: {}", name.name, ty(e.id)?), None));
            }
            if let Some(path) = as_path(e)
                && let Some(mm) = module_path(&tp.program, m, &path)
            {
                return Some((format!("module {}", tp.program.name(mm)), tp.program.mods[mm].ast.doc.clone()));
            }
            Some((ty(e.id)?, None))
        }
        Hit::LitField(e, name) => {
            let def = t.struct_lits.get(&e.id)?.def;
            let f = tp.defs.fields(def).iter().find(|f| f.name == name.name)?;
            Some((format!("{}: {}", f.name, tp.defs.show(&f.ty)), None))
        }
        Hit::PatField(p, name) => {
            let def = t.struct_pats.get(&p.id)?.def;
            let f = tp.defs.fields(def).iter().find(|f| f.name == name.name)?;
            Some((format!("{}: {}", f.name, tp.defs.show(&f.ty)), None))
        }
        Hit::Pat(p) => {
            if let Some(l) = t.binds.get(&p.id) {
                return name_hover(tp, m, &NameRef::Local(*l));
            }
            if let Some(v) = t.variants.get(&p.id) {
                return Some((variant_text(tp, v.def, v.index)?, None));
            }
            Some((ty(p.id)?, None))
        }
        Hit::TypePath(path, i) => {
            let names: Vec<&str> = path[..=i].iter().map(|x| x.name.as_str()).collect();
            let (dm, span) = find_item(&tp.program, m, &names)?;
            if let Some(def) = tp.defs.types.iter().position(|d| d.module == dm && d.span.line == span.line && d.name == names[names.len() - 1]) {
                return Some(type_def_hover(tp, def));
            }
            if let Some(s) = tp.defs.shapes.iter().find(|s| s.module == dm && s.name == names[names.len() - 1]) {
                return Some((format!("shape {}", s.name), None));
            }
            None
        }
        Hit::FnDecl(item, clause) => {
            let f = tp.fns.iter().position(|f| {
                f.module == m
                    && matches!(&f.kind, FnKind::Duck { item: i, clauses, header } if *i == item && match clause {
                        Some(ci) => clauses.contains(&ci),
                        None => *header,
                    })
            })?;
            Some((signature(tp, f), tp.fns[f].doc.clone()))
        }
        Hit::Decl(_) => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn utf16_positions() {
        let src = "let a = 1\nlet s = \"é🦆x\" + y\n";
        // ASCII: identical apart from the base
        assert_eq!(to_lsp(src, 1, 5), (0, 4));
        assert_eq!(from_lsp(src, 0, 4), (1, 5));
        // line 2: `é` is one UTF-16 unit, `🦆` two
        let col_x = 1 + "let s = \"é🦆".chars().count() as u32; // char column of `x`
        assert_eq!(to_lsp(src, 2, col_x), (1, 12));
        assert_eq!(from_lsp(src, 1, 12), (2, col_x));
        assert_eq!(to_lsp(src, 2, col_x - 1), (1, 10)); // the duck
        assert_eq!(from_lsp(src, 1, 11), (2, col_x - 1)); // inside the surrogate pair
        // past the end of a line, and the empty last line
        assert_eq!(to_lsp(src, 1, 13), (0, 12));
        assert_eq!(from_lsp(src, 0, 12), (1, 13));
        assert_eq!(to_lsp(src, 3, 1), (2, 0));
        // round trip every char boundary
        for (i, _) in line_text(src, 1).chars().enumerate() {
            let col = i as u32 + 1;
            let (l, u) = to_lsp(src, 2, col);
            assert_eq!(from_lsp(src, l, u), (2, col));
        }
        // CRLF line endings don't count the `\r`
        assert_eq!(to_lsp("ab\r\ncd", 2, 3), (1, 2));
        assert_eq!(byte_offset("ab\r\né🦆d", (1, 3)), "ab\r\né🦆".len());
    }

    #[test]
    fn uris() {
        assert_eq!(uri_to_path("file:///tmp/a%20b/c.duck"), PathBuf::from("/tmp/a b/c.duck"));
        assert_eq!(path_to_uri("/tmp/a b/é.duck"), "file:///tmp/a%20b/%C3%A9.duck");
        assert_eq!(uri_to_path(&path_to_uri("/x/é y.duck")), PathBuf::from("/x/é y.duck"));
    }

    #[test]
    fn framing() {
        let mut out = Vec::new();
        write_message(&mut out, &obj([("a", "é".into())])).unwrap();
        assert_eq!(String::from_utf8(out.clone()).unwrap(), "Content-Length: 10\r\n\r\n{\"a\":\"é\"}");
        let mut r = io::BufReader::new(&out[..]);
        assert_eq!(read_message(&mut r).unwrap().as_deref(), Some("{\"a\":\"é\"}"));
        assert_eq!(read_message(&mut r).unwrap(), None);
    }
}

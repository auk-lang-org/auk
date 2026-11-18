/// Source spans and diagnostics (the parts of src/diag.rs the front end needs).

/// 1-based line and column (in chars) of the first char, and of the char just past the end.
pub struct Span { line: int, col: int, end_line: int, end_col: int }

/// The empty span at 0:0 (Rust's `Span::default()`).
pub let NONE = Span { line: 0, col: 0, end_line: 0, end_col: 0 }

/// From the start of `s` to the end of `o`.
pub fn to(s: Span, o: Span): Span = Span { end_line: o.end_line, end_col: o.end_col, ..s }

/// The empty span just past the end of `s` (where an insertion goes).
pub fn after(s: Span): Span = Span { line: s.end_line, col: s.end_col, ..s }

/// `line:col`, as diagnostics print a position.
pub fn show_at(s: Span): str = "{s.line}:{s.col}"

/// A suggested edit: replace the text in `span` with `text` (an empty span inserts).
pub struct Fix { span: Span, text: str }

pub struct Diag { code: str, span: Span, message: str, notes: [str], fixes: [Fix] }

/// A diagnostic in a particular file (a program spans many files: the root, its project's other
/// modules, dependencies and the core prelude).
pub struct FileDiag { file: str, diag: Diag }

/// What loading and checking a program fail with (`T!E` needs an enum).
pub enum FileFails { Many(ds: [FileDiag]) }

/// What the lexer and parser fail with (`T!E` needs an enum).
pub enum Fail { Bad(d: Diag) }

pub fn new(code: str, span: Span, message: str): Diag =
  Diag { code, span, message, notes: [], fixes: [] }

pub fn note(d: Diag, n: str): Diag {
  var d2 = d
  d2.notes.push(n)
  d2
}

pub fn fix(d: Diag, span: Span, text: str): Diag {
  var d2 = d
  d2.fixes.push(Fix { span, text })
  d2
}

// ---- severity and the JSON report (src/diag.rs) ----

/// Codes reported as warnings: they don't fail a check.
pub let WARNINGS = ["E0411"]

/// A warning (see `WARNINGS`) rather than an error.
pub fn is_warning(d: Diag): bool = WARNINGS.contains(d.code)

/// "error" or "warning".
pub fn severity(d: Diag): str = if d.is_warning() { "warning" } else { "error" }

/// The command that explains this diagnostic's code (see `explain.rs`).
pub fn explain(d: Diag): str = "auk explain {d.code}"

fn json(d: Diag): str {
  let s = d.span
  let notes = d.notes.map(n => json_str(n))
  let fixes = d.fixes.map(f => "{{\"line\":{f.span.line},\"col\":{f.span.col},\"end_line\":{f.span.end_line},\"end_col\":{f.span.end_col},\"text\":{json_str(f.text)}}}")
  "{{\"code\":\"{d.code}\",\"severity\":\"{d.severity()}\",\"line\":{s.line},\"col\":{s.col},\"end_line\":{s.end_line},\"end_col\":{s.end_col},\"message\":{json_str(d.message)},\"notes\":[{notes.join(",")}],\"fixes\":[{fixes.join(",")}],\"explain\":\"{d.explain()}\"}}"
}

/// The `check --json` report: `{file, ok, diagnostics:[{code, severity, line, col, end_line,
/// end_col, message, notes, fixes:[{line, col, end_line, end_col, text}], explain}]}`.
pub fn json_report(path: str, diags: [Diag]): str {
  let ds = diags.map(d => json(d))
  let ok = diags.all(d => d.is_warning())
  "{{\"file\":{json_str(path)},\"ok\":{ok},\"diagnostics\":[{ds.join(",")}]}}"
}

/// Like `json_report`, for diagnostics that may be in other files of the program: a diagnostic
/// outside `path` gets an extra leading `"file"` key (its fixes apply to that file).
pub fn json_report_files(path: str, diags: [FileDiag]): str {
  var ds: [str] = []
  for d in diags {
    let j = json(d.diag)
    if d.file == path {
      ds.push(j)
    } else {
      ds.push("{{\"file\":{json_str(d.file)}," + j[1..j.len()])
    }
  }
  let ok = diags.all(d => d.diag.is_warning())
  "{{\"file\":{json_str(path)},\"ok\":{ok},\"diagnostics\":[{ds.join(",")}]}}"
}

/// A JSON string literal, escaped as Rust's `json_str`: `"` `\` newline and tab by name, other
/// control chars (`\r` included) as `\u00XX`.
pub fn json_str(s: str): str {
  var out: [str] = ["\""]
  for c in s.chars() {
    match c {
      '"' => out.push("\\\"")
      '\\' => out.push("\\\\")
      '\n' => out.push("\\n")
      '\t' => out.push("\\t")
      _ => if int(c) < 0x20 { out.push("\\u{int(c):04x}") } else { out.push(str(c)) }
    }
  }
  out.push("\"")
  out.join("")
}

test "json report" {
  let d = new("E0200", Span { line: 1, col: 2, end_line: 1, end_col: 5 }, "a \"b\"\n\r").note("n").fix(Span { line: 1, col: 2, end_line: 1, end_col: 2 }, "x")
  assert json_report_files("f.auk", [FileDiag { file: "f.auk", diag: d }]) ==
    "{{\"file\":\"f.auk\",\"ok\":false,\"diagnostics\":[{{\"code\":\"E0200\",\"severity\":\"error\",\"line\":1,\"col\":2,\"end_line\":1,\"end_col\":5,\"message\":\"a \\\"b\\\"\\n\\u000d\",\"notes\":[\"n\"],\"fixes\":[{{\"line\":1,\"col\":2,\"end_line\":1,\"end_col\":2,\"text\":\"x\"}}],\"explain\":\"auk explain E0200\"}}]}}"
  assert json_report_files("f.auk", [FileDiag { file: "g.auk", diag: new("E0411", NONE, "w") }]).starts_with("{{\"file\":\"f.auk\",\"ok\":true,\"diagnostics\":[{{\"file\":\"g.auk\",\"code\":\"E0411\",\"severity\":\"warning\"")
}

/// `file:line:col: error[E0012]: msg`, then the source line with a caret underline across the
/// span (to the end of the line for a multi-line span), then notes, fixes and a pointer to
/// `auk explain`.
pub fn render(d: Diag, path: str, src: str): str {
  let s = d.span
  let ls = src.lines()
  let text = if s.line >= 1 && s.line <= ls.len() { ls[s.line - 1] } else { "" }
  let last = text.len() + 1
  let end = if s.end_line == s.line { min(s.end_col, max(last, s.col + 1)) } else { last }
  let carets = "^".repeat(max(end - s.col, 1))
  let ws = " ".repeat("{s.line}".len())
  let pad = " ".repeat(max(s.col - 1, 0))
  var out = [
    "{path}:{s.line}:{s.col}: {d.severity()}[{d.code}]: {d.message}\n",
    "{ws} |\n{s.line} | {text}\n{ws} | {pad}{carets}\n",
  ]
  for n in d.notes { out.push("{ws} = note: {n}\n") }
  for f in d.fixes {
    let at = show_at(f.span)
    let what = if f.text == "" {
      "remove the text at {at}"
    } else if f.span.col == f.span.end_col && f.span.line == f.span.end_line {
      "insert `{f.text}` at {at}"
    } else {
      "replace the text at {at} with `{f.text}`"
    }
    out.push("{ws} = fix: {what}\n")
  }
  out.push("{ws} = help: run `{d.explain()}` for details\n")
  out.join("")
}

test "render underlines the span" {
  let sp = Span { line: 2, col: 5, end_line: 2, end_col: 8 }
  let d = new("E0020", sp, "expected `)`, found `let`")
    .note("a note")
    .fix(Span { line: 2, col: 5, end_line: 2, end_col: 5 }, ")")
  assert d.render("a.auk", "fn f() {{\n  f(let)\n}}\n") ==
    "a.auk:2:5: error[E0020]: expected `)`, found `let`\n  |\n2 |   f(let)\n  |     ^^^\n  = note: a note\n  = fix: insert `)` at 2:5\n  = help: run `auk explain E0020` for details\n"
  let w = new("E0411", Span { line: 1, col: 15, end_line: 1, end_col: 17 }, "unused")
  assert w.render("a.auk", "fn f(): int uses fs = 1\n").starts_with("a.auk:1:15: warning[E0411]: ")
}

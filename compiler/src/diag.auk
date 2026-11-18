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

// ---- the code table (src/diag.rs `CODES`) ----

/// Every diagnostic code with a one-line title (for `auk explain`).
/// E0001–E0099 are lexing and parsing errors; E0100–E0399 are name resolution and type errors
/// (check.rs); E0400–E0499 are patterns and effects (patterns.rs, effects.rs), and E0420, an
/// imprint whose compile-time evaluation panicked (build.rs).
pub let CODES: [(str, str)] = [
  ("E0001", "unexpected character"),
  ("E0002", "unterminated string literal"),
  ("E0003", "unterminated block comment"),
  ("E0004", "malformed number literal"),
  ("E0005", "integer literal too large"),
  ("E0006", "unknown escape sequence"),
  ("E0007", "malformed char literal"),
  ("E0008", "malformed string interpolation"),
  ("E0009", "unmatched `}}` in a string"),
  ("E0010", "triple-quoted string line indented less than its closing quotes"),
  ("E0011", "semicolons are not used"),
  ("E0012", "unclosed bracket"),
  ("E0013", "unmatched closing bracket"),
  ("E0020", "unexpected token"),
  ("E0021", "expected an expression"),
  ("E0022", "expected a pattern"),
  ("E0023", "expected a type"),
  ("E0024", "expected an item"),
  ("E0025", "expected the end of the statement"),
  ("E0026", "comparison operators cannot be chained"),
  ("E0027", "invalid assignment target"),
  ("E0028", "misplaced `&`"),
  ("E0029", "struct literal or `else` in a control-flow head needs parentheses"),
  ("E0030", "invalid `|>` step"),
  ("E0031", "function header line without clauses"),
  ("E0032", "`let` is a statement, not an expression"),
  ("E0033", "invalid list pattern"),
  ("E0034", "invalid map pattern"),
  ("E0035", "return types use `:`, not `->`"),
  ("E0036", "`extern` in a package without the `ffi` effect"),
  ("E0037", "malformed unit of measure"),
  ("E0038", "bitwise operator mixed with a comparison without parentheses"),
  ("E0039", "`??` used as a default operator (use `else`)"),
  ("E0040", "an `extern` declaration doesn't fit its C prototype"),
  // ---- E0100-E0199: modules, names and declarations (resolve.rs, check.rs) ----
  ("E0100", "dependency or file not found"),
  ("E0101", "module name collides with a dependency"),
  ("E0102", "unknown name"),
  ("E0103", "no function for this receiver type (dot call)"),
  ("E0104", "unknown type"),
  ("E0105", "shape used where a type is expected, or a type where a shape is expected"),
  ("E0106", "wrong number of type arguments"),
  ("E0107", "duplicate definition"),
  ("E0108", "clauses disagree on a parameter type"),
  ("E0109", "parameter type can't be determined"),
  ("E0110", "clauses disagree on the return type"),
  ("E0111", "function defined twice (non-contiguous clauses or duplicate overload)"),
  ("E0112", "the error type of `T!E` must be an enum"),
  ("E0113", "malformed shape"),
  ("E0114", "unknown compiler intrinsic"),
  ("E0115", "constant depends on itself"),
  ("E0116", "a local named like a module or dependency is used as a path"),
  ("E0117", "a bare variant name would be core's `Value` variant where another enum is meant"),
  ("E0120", "private item"),
  ("E0121", "private field"),
  // ---- E0200-E0299: types ----
  ("E0200", "mismatched types"),
  ("E0201", "a `T!`/`T?` value used where a plain value is expected (missing `?`)"),
  ("E0202", "no overload takes this first argument type"),
  ("E0203", "called value is not a function"),
  ("E0204", "closure parameter count mismatch"),
  ("E0205", "`if` without `else` used as a value"),
  ("E0207", "not iterable"),
  ("E0210", "integer literal out of range"),
  ("E0221", "unknown field"),
  ("E0222", "field access on an optional (use `?.`)"),
  ("E0223", "bad tuple index"),
  ("E0224", "missing fields in a struct literal"),
  ("E0225", "unknown or duplicate field in a struct literal or pattern"),
  ("E0240", "the `else` of a refutable `let` must diverge"),
  ("E0241", "bad `fail` argument"),
  ("E0242", "`fail` outside a function returning `T!`"),
  ("E0243", "`?` in a function that doesn't return `T!` or `T?`"),
  ("E0244", "`break` or `continue` outside a loop"),
  ("E0245", "bad `break` value"),
  ("E0246", "`return`, `?` or `fail` in a guard or constant"),
  ("E0247", "`?` can't convert this error type"),
  ("E0248", "`?` on `T!` in a function returning `T?`"),
  ("E0249", "`?` on `T?` in a function returning `T!`"),
  ("E0250", "`?` on a value that is not `T!`, `T?` or a list of them"),
  ("E0251", "`!` on a value that is not `T?` or `T!`"),
  ("E0252", "`?.` on `T!` (optional chaining is for `T?` only)"),
  ("E0253", "`?.` on a non-optional value"),
  ("E0254", "`else e =>` on an optional"),
  ("E0255", "`else` on a value that can't fail"),
  ("E0260", "operator not applicable to these types"),
  ("E0261", "operator not defined for a user type (missing `add`/`sub`/...)"),
  ("E0262", "pattern doesn't match the value's type"),
  ("E0263", "an `is` pattern can't bind names"),
  ("E0264", "wrong number of fields in a variant pattern"),
  ("E0265", "name bound twice in a pattern"),
  ("E0266", "struct pattern doesn't mention every field"),
  ("E0267", "the alternatives of an or-pattern bind different names or types"),
  ("E0270", "not indexable"),
  ("E0280", "format precision on a type without one"),
  ("E0281", "zero-padding format on a non-number"),
  ("E0282", "malformed format spec"),
  ("E0283", "a hex, octal or binary format on a non-int"),
  ("E0290", "mismatched units in an operator"),
  ("E0291", "mismatched units of measure"),
  ("E0292", "the unit of a power or root can't be computed"),
  ("E0293", "bitwise operator on a value with a unit"),
  // ---- E0300-E0399: calls, mutability, async, shapes, inference, entry ----
  ("E0300", "wrong number of arguments"),
  ("E0301", "ambiguous overload"),
  ("E0302", "wrong number of values for a variant"),
  ("E0310", "missing `&` for a `var` parameter"),
  ("E0311", "`&` on an argument for a non-`var` parameter"),
  ("E0320", "assignment to something immutable"),
  ("E0322", "strings are immutable"),
  ("E0323", "closure assigns to a captured variable"),
  ("E0331", "`await` on something that is not a task"),
  ("E0332", "unawaited `async fn` call"),
  ("E0333", "un-awaited `async fn` call used as its result"),
  ("E0334", "the error of a `T!` value is ignored"),
  ("E0335", "`return` inside `catch`"),
  ("E0336", "an `async fn` with a `var` parameter started as a task"),
  ("E0350", "type doesn't fit a shape"),
  ("E0360", "type can't be inferred"),
  ("E0370", "unsupported `main` signature"),
  // ---- E0400-E0499: patterns (patterns.rs) and effects (effects.rs) ----
  ("E0400", "patterns don't cover every case"),
  ("E0401", "unreachable clause or arm"),
  ("E0402", "`let ... else` whose pattern always matches"),
  ("E0403", "pattern that might not match where one must always match"),
  ("E0410", "effect used but not declared"),
  ("E0411", "effect declared but not used"),
  ("E0412", "constant initializer with an effect"),
  ("E0413", "effect not allowed by the package's raft.toml"),
  ("E0414", "unknown effect"),
  ("E0415", "conversion to `any Shape` exceeds the shape method's effects"),
  ("E0420", "imprint panicked at compile time"),
]

/// The one-line title of `code`, if it is registered.
pub fn title(code: str): str? = CODES.find(c => c.0 == code)?.1

test "codes" {
  for i, c in CODES {
    assert c.0.len() == 5 && c.0.starts_with("E") && (int.parse(c.0[1..5]) else 999) < 500
    assert c.1 != ""
    assert CODES.skip(i + 1).all(d => d.0 != c.0)
  }
  assert title("E0011") == some("semicolons are not used")
  assert title("E9999") == none
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
  // Rust: `src.lines().nth(line.saturating_sub(1))`, so line 0 shows the first line
  let text = if s.line <= ls.len() && ls.len() > 0 { ls[max(s.line - 1, 0)] } else { "" }
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
  // a diagnostic at 0:0 (no position) quotes the first line, as Rust's does
  assert new("E0360", NONE, "x").render("a.auk", "fn f() {{}}\n") ==
    "a.auk:0:0: error[E0360]: x\n  |\n0 | fn f() {{}}\n  | ^\n  = help: run `auk explain E0360` for details\n"
  let w = new("E0411", Span { line: 1, col: 15, end_line: 1, end_col: 17 }, "unused")
  assert w.render("a.auk", "fn f(): int uses fs = 1\n").starts_with("a.auk:1:15: warning[E0411]: ")
}

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

//! Diagnostics with stable codes, spans, notes and fix-it edits, rendered as text or JSON.

use std::fmt;

/// A source range: 1-based line and column (counted in chars) of the first char, and of the
/// position just past the last char (`end_col` is exclusive).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Span {
    pub line: u32,
    pub col: u32,
    pub end_line: u32,
    pub end_col: u32,
}

impl Span {
    /// From the start of `self` to the end of `other`.
    pub fn to(self, other: Span) -> Span {
        Span { end_line: other.end_line, end_col: other.end_col, ..self }
    }

    /// The empty span just past the end of `self` (where an insertion goes).
    pub fn after(self) -> Span {
        Span { line: self.end_line, col: self.end_col, ..self }
    }
}

impl fmt::Display for Span {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{}:{}", self.line, self.col)
    }
}

/// A suggested edit: replace the text in `span` with `text` (an empty span inserts).
#[derive(Debug, Clone, PartialEq)]
pub struct Fix {
    pub span: Span,
    pub text: String,
}

/// One error. `code` must be listed in `CODES`.
#[derive(Debug, Clone, PartialEq)]
pub struct Diag {
    pub code: &'static str,
    pub span: Span,
    pub message: String,
    pub notes: Vec<String>,
    pub fixes: Vec<Fix>,
}

/// A diagnostic in a particular file (a program spans many files: the root, its project's other
/// modules, dependencies and the core prelude).
#[derive(Debug, Clone, PartialEq)]
pub struct FileDiag {
    pub file: String,
    pub diag: Diag,
}

/// Every diagnostic code with a one-line title (for `auk explain`).
/// E0001–E0099 are lexing and parsing errors; E0100–E0399 are name resolution and type errors
/// (check.rs); E0400–E0499 are patterns and effects (patterns.rs, effects.rs), and E0420, an
/// imprint whose compile-time evaluation panicked (build.rs).
pub const CODES: &[(&str, &str)] = &[
    ("E0001", "unexpected character"),
    ("E0002", "unterminated string literal"),
    ("E0003", "unterminated block comment"),
    ("E0004", "malformed number literal"),
    ("E0005", "integer literal too large"),
    ("E0006", "unknown escape sequence"),
    ("E0007", "malformed char literal"),
    ("E0008", "malformed string interpolation"),
    ("E0009", "unmatched `}` in a string"),
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
    ("E0270", "not indexable"),
    ("E0280", "format precision on a type without one"),
    ("E0281", "zero-padding format on a non-number"),
    ("E0282", "malformed format spec"),
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
];

/// Codes reported as warnings: they are rendered as `warning[..]`, have severity "warning" in
/// JSON, and don't fail `auk check`.
pub const WARNINGS: &[&str] = &["E0411"];

/// The one-line title of `code`, if it is registered.
pub fn title(code: &str) -> Option<&'static str> {
    CODES.iter().find(|(c, _)| *c == code).map(|(_, t)| *t)
}

impl Diag {
    pub fn new(code: &'static str, span: Span, message: impl Into<String>) -> Diag {
        debug_assert!(title(code).is_some(), "unregistered diagnostic code {code}");
        Diag { code, span, message: message.into(), notes: Vec::new(), fixes: Vec::new() }
    }

    pub fn note(mut self, note: impl Into<String>) -> Diag {
        self.notes.push(note.into());
        self
    }

    pub fn fix(mut self, span: Span, text: impl Into<String>) -> Diag {
        self.fixes.push(Fix { span, text: text.into() });
        self
    }

    /// A warning (see `WARNINGS`) rather than an error.
    pub fn is_warning(&self) -> bool {
        WARNINGS.contains(&self.code)
    }

    /// "error" or "warning".
    pub fn severity(&self) -> &'static str {
        if self.is_warning() { "warning" } else { "error" }
    }

    /// `file:line:col: error[E0012]: msg`, then the source line with a caret underline across the
    /// span (to the end of the line for a multi-line span), then notes, fixes and a pointer to
    /// `auk explain`.
    pub fn render(&self, path: &str, src: &str) -> String {
        let Span { line, col, end_line, end_col } = self.span;
        let text = src.lines().nth((line as usize).saturating_sub(1)).unwrap_or("");
        let last = text.chars().count() as u32 + 1;
        let end = if end_line == line { end_col.min(last.max(col + 1)) } else { last };
        let carets = "^".repeat(end.saturating_sub(col).max(1) as usize);
        let w = line.to_string().len();
        let pad = " ".repeat(col.saturating_sub(1) as usize);
        let mut out = format!(
            "{path}:{line}:{col}: {}[{}]: {}\n{:w$} |\n{line} | {text}\n{:w$} | {pad}{carets}\n",
            self.severity(),
            self.code,
            self.message,
            "",
            ""
        );
        for n in &self.notes {
            out += &format!("{:w$} = note: {n}\n", "");
        }
        for f in &self.fixes {
            let what = match (f.text.is_empty(), f.span.col == f.span.end_col && f.span.line == f.span.end_line) {
                (true, _) => format!("remove the text at {}", f.span),
                (false, true) => format!("insert `{}` at {}", f.text, f.span),
                (false, false) => format!("replace the text at {} with `{}`", f.span, f.text),
            };
            out += &format!("{:w$} = fix: {what}\n", "");
        }
        out += &format!("{:w$} = help: run `{}` for details\n", "", self.explain());
        out
    }

    /// The command that explains this diagnostic's code (see `explain.rs`).
    pub fn explain(&self) -> String {
        format!("auk explain {}", self.code)
    }

    fn json(&self) -> String {
        let s = self.span;
        let notes: Vec<String> = self.notes.iter().map(|n| json_str(n)).collect();
        let fixes: Vec<String> = self
            .fixes
            .iter()
            .map(|f| {
                let s = f.span;
                format!(
                    r#"{{"line":{},"col":{},"end_line":{},"end_col":{},"text":{}}}"#,
                    s.line,
                    s.col,
                    s.end_line,
                    s.end_col,
                    json_str(&f.text)
                )
            })
            .collect();
        format!(
            r#"{{"code":"{}","severity":"{}","line":{},"col":{},"end_line":{},"end_col":{},"message":{},"notes":[{}],"fixes":[{}],"explain":"{}"}}"#,
            self.code,
            self.severity(),
            s.line,
            s.col,
            s.end_line,
            s.end_col,
            json_str(&self.message),
            notes.join(","),
            fixes.join(","),
            self.explain()
        )
    }
}

/// The `check --json` report: `{file, ok, diagnostics:[{code, severity, line, col, end_line,
/// end_col, message, notes, fixes:[{line, col, end_line, end_col, text}], explain}]}`, where
/// `explain` is the command that explains the code (`auk explain E0011`).
pub fn json_report(path: &str, diags: &[Diag]) -> String {
    let ds: Vec<String> = diags.iter().map(Diag::json).collect();
    let ok = diags.iter().all(Diag::is_warning);
    format!(r#"{{"file":{},"ok":{ok},"diagnostics":[{}]}}"#, json_str(path), ds.join(","))
}

/// Like `json_report`, for diagnostics that may be in other files of the program: a diagnostic
/// outside `path` gets an extra leading `"file"` key (its fixes apply to that file).
pub fn json_report_files(path: &str, diags: &[FileDiag]) -> String {
    let ds: Vec<String> = diags
        .iter()
        .map(|d| {
            let j = d.diag.json();
            if d.file == path { j } else { format!(r#"{{"file":{},{}"#, json_str(&d.file), &j[1..]) }
        })
        .collect();
    let ok = diags.iter().all(|d| d.diag.is_warning());
    format!(r#"{{"file":{},"ok":{ok},"diagnostics":[{}]}}"#, json_str(path), ds.join(","))
}

fn json_str(s: &str) -> String {
    let mut out = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sp(line: u32, col: u32, end_col: u32) -> Span {
        Span { line, col, end_line: line, end_col }
    }

    #[test]
    fn codes_are_unique_and_in_range() {
        for (i, (c, t)) in CODES.iter().enumerate() {
            assert!(c.len() == 5 && c.starts_with('E') && c[1..].parse::<u32>().is_ok_and(|n| n < 500), "{c}");
            assert!(!t.is_empty());
            assert!(CODES[i + 1..].iter().all(|(d, _)| d != c), "duplicate {c}");
        }
    }

    #[test]
    fn render_underlines_the_span() {
        let d = Diag::new("E0020", sp(2, 5, 8), "expected `)`, found `let`").note("a note").fix(sp(2, 5, 5), ")");
        let out = d.render("a.auk", "fn f() {\n  f(let)\n}\n");
        assert_eq!(
            out,
            "a.auk:2:5: error[E0020]: expected `)`, found `let`\n  |\n2 |   f(let)\n  |     ^^^\n  = note: a note\n  = fix: insert `)` at 2:5\n  = help: run `auk explain E0020` for details\n"
        );
    }

    #[test]
    fn json_shape() {
        let d = Diag::new("E0011", sp(1, 10, 11), "no \"semicolons\"").fix(sp(1, 10, 11), "");
        assert_eq!(
            json_report("x.auk", &[d]),
            r#"{"file":"x.auk","ok":false,"diagnostics":[{"code":"E0011","severity":"error","line":1,"col":10,"end_line":1,"end_col":11,"message":"no \"semicolons\"","notes":[],"fixes":[{"line":1,"col":10,"end_line":1,"end_col":11,"text":""}],"explain":"auk explain E0011"}]}"#
        );
        assert_eq!(json_report("x.auk", &[]), r#"{"file":"x.auk","ok":true,"diagnostics":[]}"#);
    }

    #[test]
    fn warnings_render_and_stay_ok() {
        let d = Diag::new("E0411", sp(1, 15, 17), "`f` declares the effect `fs` but doesn't use it");
        assert!(d.render("a.auk", "fn f(): int uses fs = 1\n").starts_with("a.auk:1:15: warning[E0411]: "));
        let j = json_report("x.auk", &[d]);
        assert!(j.contains(r#""ok":true"#) && j.contains(r#""severity":"warning""#), "{j}");
        assert!(WARNINGS.iter().all(|w| title(w).is_some()));
    }
}

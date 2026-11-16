//! `duck fmt`: the canonical, zero-config formatter.
//!
//! The formatter parses the file, then prints the AST through a Prettier-style document printer
//! (`doc.rs`) with a 100-column limit. Things the AST does not keep come from the source:
//! literals are copied verbatim (so escapes, raw and triple-quoted strings and `1_000` survive),
//! comments are re-attached by position, and single blank lines and a few layout choices (a
//! one-line block, an expanded struct literal) are preserved. Parentheses are printed where
//! precedence needs them, and kept where the user wrote them around an operand.
//!
//! Style: 2-space indent, no semicolons, spaces around binary operators, `{ x }` for one-line
//! bodies, trailing commas only on multi-line lists, chains and pipes broken before `.`/`|>`,
//! one blank line between items (none between the clauses of one function), trailing comments
//! aligned.

mod doc;
#[cfg(test)]
mod tests;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::{fs, io};

use super::ast::*;
use super::diag::{Diag, Span};
use super::lexer::lex;
use super::parser::parse;
use super::token::{Tok, Token};
use doc::{Doc, Fit, broken, concat, group, if_break, indent, nil, text};

/// The maximum line width.
pub const WIDTH: usize = 100;

/// Format a Duck source file. Fails with the parse diagnostics if it does not parse.
pub fn format(src: &str) -> Result<String, Vec<Diag>> {
    let module = parse(src)?;
    let toks = lex(src).map_err(|d| vec![d])?.toks;
    let mut f = Fmt::new(src, toks);
    let d = f.module(&module);
    let out = doc::align_suffixes(&doc::render(&d, WIDTH));
    let mut out = out.trim_end().to_string();
    if !out.is_empty() {
        out.push('\n');
    }
    Ok(out)
}

/// Why a file could not be formatted.
#[derive(Debug)]
pub enum Error {
    /// The input does not parse.
    Parse(Vec<Diag>),
    /// A formatter bug: the output would not parse or would mean something else.
    Internal(String),
}

/// `format`, then check that the output parses to the same AST (ignoring spans and node ids).
pub fn format_checked(src: &str) -> Result<String, Error> {
    let before = parse(src).map_err(Error::Parse)?;
    let out = format(src).map_err(Error::Parse)?;
    let after = parse(&out).map_err(|ds| {
        let msgs: Vec<String> = ds.iter().map(|d| d.render("<formatted>", &out)).collect();
        Error::Internal(format!("the formatted output does not parse:\n{}", msgs.concat()))
    })?;
    if ast_shape(&before) != ast_shape(&after) {
        return Err(Error::Internal("formatting would change the meaning of the program".into()));
    }
    Ok(out)
}

/// The AST's debug form with every span and node id removed: equal shapes mean the same
/// program (docs included).
pub fn ast_shape(m: &Module) -> String {
    let s = format!("{m:?}");
    let mut out = String::with_capacity(s.len());
    let mut rest = s.as_str();
    loop {
        let span = rest.find("span: Span {");
        let id = rest.find("id: ").filter(|&i| rest[i + 4..].starts_with(|c: char| c.is_ascii_digit()));
        let at = match (span, id) {
            (Some(a), Some(b)) => a.min(b),
            (Some(a), None) | (None, Some(a)) => a,
            (None, None) => break,
        };
        out += &rest[..at];
        rest = &rest[at..];
        let skip = if rest.starts_with("span") { rest.find('}').unwrap() + 1 } else { 4 + rest[4..].find(|c: char| !c.is_ascii_digit()).unwrap_or(rest.len() - 4) };
        rest = &rest[skip..];
        rest = rest.strip_prefix(", ").unwrap_or(rest);
    }
    out + rest
}

// ---- command line ----

/// `duck fmt [--check] <file|dir|->...`. Returns the exit code.
pub fn run(args: &[String]) -> i32 {
    let check = args.iter().any(|a| a == "--check");
    let paths: Vec<&String> = args.iter().filter(|a| *a != "--check").collect();
    if paths.is_empty() {
        eprintln!("usage: duck fmt [--check] <file|dir|->...");
        return 2;
    }
    let mut code = 0;
    for p in paths {
        if p == "-" {
            code = code.max(stdin(check));
            continue;
        }
        let mut files = Vec::new();
        if let Err(e) = collect(Path::new(p), &mut files) {
            eprintln!("error: cannot read {p}: {e}");
            code = 1;
            continue;
        }
        for f in files {
            code = code.max(file(&f, check));
        }
    }
    code
}

fn stdin(check: bool) -> i32 {
    let mut src = String::new();
    if let Err(e) = io::Read::read_to_string(&mut io::stdin(), &mut src) {
        eprintln!("error: cannot read stdin: {e}");
        return 1;
    }
    match format_checked(&src) {
        Ok(out) if check => {
            if out != src {
                println!("<stdin>");
                return 1;
            }
            0
        }
        Ok(out) => {
            print!("{out}");
            0
        }
        Err(e) => report("<stdin>", &src, e),
    }
}

fn file(path: &Path, check: bool) -> i32 {
    let name = path.display().to_string();
    let src = match fs::read_to_string(path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("error: cannot read {name}: {e}");
            return 1;
        }
    };
    let out = match format_checked(&src) {
        Ok(out) => out,
        Err(e) => return report(&name, &src, e),
    };
    if out == src {
        return 0;
    }
    if check {
        println!("{name}");
        return 1;
    }
    if let Err(e) = fs::write(path, out) {
        eprintln!("error: cannot write {name}: {e}");
        return 1;
    }
    0
}

fn report(name: &str, src: &str, e: Error) -> i32 {
    match e {
        Error::Parse(ds) => ds.iter().for_each(|d| eprint!("{}", d.render(name, src))),
        Error::Internal(msg) => eprintln!("error: {name}: {msg} (this is a duck fmt bug; the file was left unchanged)"),
    }
    1
}

/// A file as given, or every `.duck` file under a directory (skipping hidden directories and
/// `target`), sorted.
fn collect(p: &Path, out: &mut Vec<PathBuf>) -> io::Result<()> {
    if !p.is_dir() {
        fs::metadata(p)?;
        out.push(p.to_path_buf());
        return Ok(());
    }
    let mut entries: Vec<PathBuf> = fs::read_dir(p)?.map(|e| e.map(|e| e.path())).collect::<io::Result<_>>()?;
    entries.sort();
    for e in entries {
        let name = e.file_name().and_then(|n| n.to_str()).unwrap_or("");
        if e.is_dir() {
            if !name.starts_with('.') && name != "target" {
                collect(&e, out)?;
            }
        } else if e.extension().is_some_and(|x| x == "duck") {
            out.push(e);
        }
    }
    Ok(())
}

// ---- source positions and comments ----

/// (line, col), 1-based, cols in chars, like `Span`.
type Pos = (u32, u32);

fn start(s: Span) -> Pos {
    (s.line, s.col)
}

fn end(s: Span) -> Pos {
    (s.end_line, s.end_col)
}

#[derive(Debug, Clone)]
struct Comment {
    start: Pos,
    end: Pos,
    text: String,
    /// Only whitespace precedes it on its line.
    own_line: bool,
}

/// One element of a list-like construct (statements, items, arms, fields, arguments...) with
/// the comments around it.
struct Elem {
    /// Comments after code on the line before the element: printed at the end of that line.
    pre: Vec<String>,
    /// A blank line separated it from the previous element in the source.
    blank: bool,
    /// Own-line comments above it, each followed by a line break.
    lead: Vec<Doc>,
    doc: Doc,
    /// Comments at the end of its last line.
    trail: Vec<String>,
    end_line: u32,
}

impl Elem {
    fn plain(&self) -> bool {
        self.pre.is_empty() && self.lead.is_empty() && self.trail.is_empty()
    }
}

/// What goes between the elements of a list.
#[derive(Clone, Copy, PartialEq)]
enum Sep {
    /// `,` after each element, and after the last one when broken.
    Comma,
    /// `,` only when flat (match arms, shape methods).
    FlatComma,
    /// Nothing (statements, items).
    None,
}

struct Fmt {
    chars: Vec<char>,
    line_start: Vec<usize>,
    /// The tokens without `Newline`s.
    toks: Vec<Token>,
    tok_at: HashMap<Pos, usize>,
    tok_end: HashMap<Pos, usize>,
    /// The index of the matching bracket, or `usize::MAX`.
    mate: Vec<usize>,
    comments: Vec<Comment>,
    /// Comments before this index have been printed.
    next: usize,
}

impl Fmt {
    fn new(src: &str, toks: Vec<Token>) -> Fmt {
        let chars: Vec<char> = src.chars().collect();
        let mut line_start = vec![0];
        line_start.extend(chars.iter().enumerate().filter(|(_, c)| **c == '\n').map(|(i, _)| i + 1));
        let toks: Vec<Token> = toks.into_iter().filter(|t| t.tok != Tok::Newline).collect();
        let mut f = Fmt {
            chars,
            line_start,
            toks,
            tok_at: HashMap::new(),
            tok_end: HashMap::new(),
            mate: Vec::new(),
            comments: Vec::new(),
            next: 0,
        };
        let mut stack = Vec::new();
        f.mate = vec![usize::MAX; f.toks.len()];
        let mut prev = 0;
        for i in 0..f.toks.len() {
            let sp = f.toks[i].span;
            if f.toks[i].tok != Tok::Eof {
                f.tok_at.insert(start(sp), i);
                f.tok_end.insert(end(sp), i);
            }
            match f.toks[i].tok {
                Tok::LParen | Tok::LBracket | Tok::LBrace => stack.push(i),
                Tok::RParen | Tok::RBracket | Tok::RBrace => {
                    if let Some(o) = stack.pop() {
                        f.mate[o] = i;
                        f.mate[i] = o;
                    }
                }
                _ => {}
            }
            let s = f.off(start(sp));
            f.scan_comments(prev, s);
            prev = prev.max(f.off(end(sp)));
        }
        f
    }

    fn off(&self, p: Pos) -> usize {
        self.line_start[(p.0 - 1) as usize] + (p.1 - 1) as usize
    }

    fn pos(&self, off: usize) -> Pos {
        let l = self.line_start.partition_point(|&s| s <= off);
        (l as u32, (off - self.line_start[l - 1]) as u32 + 1)
    }

    /// Collect the comments in the gap `chars[a..b]` between two tokens.
    fn scan_comments(&mut self, a: usize, b: usize) {
        let mut i = a;
        while i < b {
            let at = |k: usize| self.chars.get(k).copied();
            let j = if at(i) == Some('/') && at(i + 1) == Some('/') {
                let mut j = i;
                while j < b && self.chars[j] != '\n' {
                    j += 1;
                }
                j
            } else if at(i) == Some('/') && at(i + 1) == Some('*') {
                let (mut j, mut depth) = (i + 2, 1);
                while j < b && depth > 0 {
                    if at(j) == Some('/') && at(j + 1) == Some('*') {
                        depth += 1;
                        j += 2;
                    } else if at(j) == Some('*') && at(j + 1) == Some('/') {
                        depth -= 1;
                        j += 2;
                    } else {
                        j += 1;
                    }
                }
                j
            } else {
                i += 1;
                continue;
            };
            let (s, e) = (self.pos(i), self.pos(j));
            let line_start = self.line_start[(s.0 - 1) as usize];
            let own_line = self.chars[line_start..i].iter().all(|c| c.is_whitespace());
            let text: String = self.chars[i..j].iter().collect();
            self.comments.push(Comment { start: s, end: e, text: text.trim_end().to_string(), own_line });
            i = j;
        }
    }

    fn text_of(&self, sp: Span) -> String {
        self.chars[self.off(start(sp))..self.off(end(sp))].iter().collect()
    }

    fn line_is_blank(&self, l: u32) -> bool {
        let a = self.line_start[(l - 1) as usize];
        let b = self.line_start.get(l as usize).copied().unwrap_or(self.chars.len());
        self.chars[a..b].iter().all(|c| c.is_whitespace())
    }

    /// Is there an empty line strictly between lines `a` and `b`?
    fn blank_between(&self, a: u32, b: u32) -> bool {
        (a + 1..b).any(|l| self.line_is_blank(l))
    }

    /// The unprinted comments that start before `p`.
    fn take_before(&mut self, p: Pos) -> Vec<Comment> {
        let mut out = Vec::new();
        while self.next < self.comments.len() && self.comments[self.next].start < p {
            out.push(self.comments[self.next].clone());
            self.next += 1;
        }
        out
    }

    /// After an element that ends at `e`: the unprinted comments inside it (a comment the
    /// layout had no place for) and those on its last line before `limit`.
    fn take_trailing(&mut self, e: Pos, limit: Pos) -> Vec<String> {
        let mut out = Vec::new();
        while let Some(c) = self.comments.get(self.next)
            && (c.start < e || (c.start.0 == e.0 && c.start < limit))
            // `a, /* c */ b`: that comment belongs to `b`
            && !(c.start >= e && c.text.starts_with("/*") && c.end.0 == limit.0 && c.end <= limit)
        {
            out.push(c.text.clone());
            self.next += 1;
        }
        out
    }

    /// Are there unprinted comments in `[a, b)`?
    fn comments_in(&self, a: Pos, b: Pos) -> bool {
        self.comments[self.next..].iter().any(|c| c.start >= a && c.start < b)
    }

    /// Own-line comments as docs, each followed by a line break (and a kept blank line).
    fn lead_docs(&self, cs: &[Comment], next_line: u32) -> Vec<Doc> {
        let mut v = Vec::new();
        for (k, c) in cs.iter().enumerate() {
            v.push(text(&c.text));
            let nl = cs.get(k + 1).map(|c| c.start.0).unwrap_or(next_line);
            if self.blank_between(c.end.0, nl) {
                v.push(Doc::Blank);
            }
            v.push(Doc::HardLine);
        }
        v
    }

    /// Build the elements of a list whose `n` items have the spans `span(i)`, opened on line
    /// `open_line` and closed at `close`. Returns them and the comments left before `close`.
    fn seq(
        &mut self,
        n: usize,
        open_line: u32,
        close: Pos,
        span: &dyn Fn(usize) -> Span,
        build: &mut dyn FnMut(&mut Fmt, usize) -> Doc,
    ) -> (Vec<Elem>, Vec<Comment>) {
        let mut elems = Vec::with_capacity(n);
        let mut prev_line = open_line;
        for i in 0..n {
            let sp = span(i);
            let mut lead = self.take_before(start(sp));
            // `/* c */ x`: a block comment just before the element on its line stays inline
            let mut inline = Vec::new();
            while let Some(c) = lead.last()
                && c.text.starts_with("/*")
                && c.start.0 == sp.line
                && c.end.0 == sp.line
            {
                inline.insert(0, text(format!("{} ", c.text)));
                lead.pop();
            }
            let k = lead.iter().take_while(|c| !c.own_line).count();
            let pre = lead[..k].iter().map(|c| c.text.clone()).collect();
            let own = &lead[k..];
            let first = own.first().map(|c| c.start.0).unwrap_or(sp.line);
            let blank = i > 0 && self.blank_between(prev_line, first);
            let lead = self.lead_docs(own, sp.line);
            inline.push(build(self, i));
            let doc = concat(inline);
            let limit = if i + 1 < n { start(span(i + 1)) } else { close };
            let trail = self.take_trailing(end(sp), limit);
            prev_line = sp.end_line;
            elems.push(Elem { pre, blank, lead, doc, trail, end_line: sp.end_line });
        }
        let dangling = self.take_before(close);
        (elems, dangling)
    }

    /// Lay out elements: `open` before the first, `brk` before the others, `sep` after each.
    /// The caller adds the brackets and the closing break.
    fn layout(&self, elems: Vec<Elem>, dangling: Vec<Comment>, open: Doc, brk: Doc, sep: Sep, vertical: bool) -> Doc {
        let n = elems.len();
        let mut v = Vec::new();
        let mut prev_line = None;
        for (i, e) in elems.into_iter().enumerate() {
            v.extend(e.pre.into_iter().map(Doc::LineSuffix));
            if e.blank {
                v.push(if vertical { Doc::Blank } else { if_break(Doc::Blank, nil()) });
            }
            v.push(if i == 0 { open.clone() } else { brk.clone() });
            v.extend(e.lead);
            v.push(e.doc);
            match sep {
                Sep::Comma if i + 1 < n => v.push(text(",")),
                Sep::Comma => v.push(if_break(text(","), nil())),
                Sep::FlatComma if i + 1 < n => v.push(if_break(nil(), text(","))),
                _ => {}
            }
            v.extend(e.trail.into_iter().map(Doc::LineSuffix));
            prev_line = Some(e.end_line);
        }
        for c in dangling {
            if !c.own_line && prev_line.is_some() {
                v.push(Doc::LineSuffix(c.text));
                continue;
            }
            if prev_line.is_some_and(|l| self.blank_between(l, c.start.0)) {
                v.push(Doc::Blank);
            }
            v.push(Doc::HardLine);
            v.push(text(c.text));
            prev_line = Some(c.end.0);
        }
        concat(v)
    }

    /// `open` elements `close` as a group: flat `{ a, b }` / `(a, b)` or one element per line.
    #[allow(clippy::too_many_arguments)]
    fn bracketed(&self, open: &str, close: &str, elems: Vec<Elem>, dangling: Vec<Comment>, spaced: bool, sep: Sep, force: bool) -> Doc {
        if elems.is_empty() && dangling.is_empty() {
            return text(format!("{open}{close}"));
        }
        let brk = if spaced { Doc::Line } else { Doc::SoftLine };
        let body = self.layout(elems, dangling, brk.clone(), Doc::Line, sep, false);
        let d = concat(vec![text(open), indent(body), brk, text(close)]);
        if force { broken(d) } else { group(d) }
    }

    /// Does the source have user-written grouping parentheses right around `sp`?
    fn user_parens(&self, sp: Span) -> bool {
        let (Some(&i), Some(&j)) = (self.tok_at.get(&start(sp)), self.tok_end.get(&end(sp))) else { return false };
        if i < 2 || j + 1 >= self.toks.len() {
            return false;
        }
        let call = matches!(
            self.toks[i - 2].tok,
            Tok::Ident(_)
                | Tok::RParen
                | Tok::RBracket
                | Tok::Int(_)
                | Tok::Float(_)
                | Tok::Char(_)
                | Tok::Str(_)
                | Tok::True
                | Tok::False
                | Tok::Question
                | Tok::QuestionQuestion
        );
        self.toks[i - 1].tok == Tok::LParen && self.toks[j + 1].tok == Tok::RParen && self.mate[i - 1] == j + 1 && !call
    }

    /// The end of the `)` that closes the first `(` after the token at `p`.
    fn close_paren_after(&self, p: Pos) -> Pos {
        let i = self.tok_at[&p];
        let open = (i..self.toks.len()).find(|&k| self.toks[k].tok == Tok::LParen);
        match open.map(|o| self.mate[o]).filter(|&m| m != usize::MAX) {
            Some(m) => end(self.toks[m].span),
            None => p,
        }
    }

    // ---- items ----

    fn module(&mut self, m: &Module) -> Doc {
        // Items, with each fn clause as its own unit; `group` numbers clause groups.
        enum Unit<'a> {
            Clause(&'a FnClause),
            Item(&'a Item),
        }
        let mut units: Vec<(Unit, usize)> = Vec::new();
        for (g, item) in m.items.iter().enumerate() {
            match item {
                Item::Fn(fg) => {
                    units.extend(fg.header.iter().map(|h| (Unit::Clause(h), g)));
                    units.extend(fg.clauses.iter().map(|c| (Unit::Clause(c), g)));
                }
                _ => units.push((Unit::Item(item), g)),
            }
        }
        let span = |u: &Unit| match u {
            Unit::Clause(c) => c.span,
            Unit::Item(i) => item_span(i),
        };
        let mut v = Vec::new();
        // (group, last source line, prints on one line)
        let mut prev: Option<(usize, u32, bool)> = None;
        for (u, g) in &units {
            let sp = span(u);
            let lead = self.take_before(start(sp));
            let k = lead.iter().take_while(|c| !c.own_line && prev.is_some()).count();
            v.extend(lead[..k].iter().map(|c| Doc::LineSuffix(c.text.clone())));
            let doc = match u {
                Unit::Clause(c) => self.clause(c, false),
                Unit::Item(i) => self.item(i),
            };
            let one_line = !doc::render(&doc, WIDTH).contains('\n');
            if let Some((pg, pl, prev_one)) = prev {
                // Items are separated by a blank line, except the clauses of one function, and
                // one-line items the source keeps together (`enum` tables, small helpers).
                let first = lead[k..].first().map(|c| c.start.0).unwrap_or(sp.line);
                let together = pg == *g || (prev_one && one_line && !self.blank_between(pl, first));
                if !together {
                    v.push(Doc::Blank);
                }
                v.push(Doc::HardLine);
            }
            v.extend(self.lead_docs(&lead[k..], sp.line));
            v.push(doc);
            let trail = self.take_trailing(end(sp), (sp.end_line + 1, 0));
            v.extend(trail.into_iter().map(Doc::LineSuffix));
            prev = Some((*g, sp.end_line, one_line));
        }
        let rest = self.take_before((u32::MAX, 0));
        let mut prev_line = prev.map(|p| p.1);
        for c in rest {
            if let Some(l) = prev_line {
                if !c.own_line {
                    v.push(Doc::LineSuffix(c.text));
                    continue;
                }
                if self.blank_between(l, c.start.0) {
                    v.push(Doc::Blank);
                }
                v.push(Doc::HardLine);
            }
            v.push(text(c.text));
            prev_line = Some(c.end.0);
        }
        concat(v)
    }

    fn item(&mut self, item: &Item) -> Doc {
        match item {
            Item::Fn(_) => unreachable!("clauses are units"),
            Item::Struct(d) => {
                let head = format!("{}struct {}{} ", vis(d.public), d.name.name, generics(&d.generics));
                let (elems, dangling) = self.seq(
                    d.fields.len(),
                    d.span.line,
                    end(d.span),
                    &|i| d.fields[i].span,
                    &mut |f, i| text(format!("{}: {}", d.fields[i].name.name, f.ty(&d.fields[i].ty))),
                );
                let force = d.span.line != d.span.end_line;
                concat(vec![text(head), self.bracketed("{", "}", elems, dangling, true, Sep::Comma, force)])
            }
            Item::Enum(d) => {
                let head = format!("{}enum {}{} ", vis(d.public), d.name.name, generics(&d.generics));
                let (elems, dangling) = self.seq(d.variants.len(), d.span.line, end(d.span), &|i| d.variants[i].span, &mut |f, i| {
                    let v = &d.variants[i];
                    if v.fields.is_empty() {
                        return text(&v.name.name);
                    }
                    let fs: Vec<String> = v
                        .fields
                        .iter()
                        .map(|vf| match &vf.name {
                            Some(n) => format!("{}: {}", n.name, f.ty(&vf.ty)),
                            None => f.ty(&vf.ty),
                        })
                        .collect();
                    text(format!("{}({})", v.name.name, fs.join(", ")))
                });
                let force = d.span.line != d.span.end_line;
                concat(vec![text(head), self.bracketed("{", "}", elems, dangling, true, Sep::Comma, force)])
            }
            Item::Shape(d) => {
                let head = format!("{}shape {}{} ", vis(d.public), d.name.name, generics(&d.generics));
                let (elems, dangling) =
                    self.seq(d.methods.len(), d.span.line, end(d.span), &|i| d.methods[i].span, &mut |f, i| f.clause(&d.methods[i], true));
                let force = d.span.line != d.span.end_line;
                concat(vec![text(head), self.bracketed("{", "}", elems, dangling, true, Sep::FlatComma, force)])
            }
            Item::Test(t) => {
                let i = self.tok_at[&start(t.span)];
                let name = self.text_of(self.toks[i + 1].span);
                concat(vec![text(format!("test {name} ")), self.block(&t.body, false)])
            }
            Item::ExternType(t) => {
                let c_type = self.text_of(self.toks[self.tok_end[&end(t.span)]].span);
                text(format!("{}extern type {} = {c_type}", vis(t.public), t.name.name))
            }
            Item::Let(c) | Item::Imprint(c) => {
                let kw = if matches!(item, Item::Let(_)) { "let" } else { "imprint" };
                let ty = c.ty.as_ref().map(|t| format!(": {}", self.ty(t))).unwrap_or_default();
                let head = text(format!("{}{kw} {}{ty}", vis(c.public), c.name.name));
                let value = self.assign_rhs("=", &c.value, Cx::inner(), Rhs::Body);
                concat(vec![head, value])
            }
        }
    }

    /// A fn clause, header line or shape method.
    fn clause(&mut self, c: &FnClause, method: bool) -> Doc {
        let mut head = String::new();
        if !method {
            head += vis(c.public);
        }
        if matches!(c.body, Some(FnBody::Extern(_))) {
            head += "extern ";
        }
        if c.is_async {
            head += "async ";
        }
        head += &format!("fn {}{}", c.name.name, generics(&c.generics));
        let close = self.close_paren_after(start(c.name.span));
        let (elems, dangling) = self.seq(c.params.len(), c.name.span.line, close, &|i| c.params[i].span, &mut |f, i| text(f.param(&c.params[i])));
        let params = self.bracketed("(", ")", elems, dangling, false, Sep::Comma, false);
        let mut sig = String::new();
        if let Some(t) = &c.ret {
            sig += &format!(": {}", self.ty(t));
        }
        if !c.uses.is_empty() {
            sig += " uses ";
            sig += &c.uses.iter().map(|u| u.name.as_str()).collect::<Vec<_>>().join(", ");
        }
        let mut v = vec![text(head), params, text(sig)];
        let contracts = !c.requires.is_empty() || !c.ensures.is_empty();
        for (kw, es) in [("requires", &c.requires), ("ensures", &c.ensures)] {
            for e in es {
                let d = self.expr(e, Cx::head());
                v.push(indent(concat(vec![Doc::HardLine, text(format!("{kw} ")), d])));
            }
        }
        if let Some(g) = &c.guard {
            v.push(text(" when "));
            v.push(self.expr(g, Cx::head()));
        }
        match &c.body {
            None => {}
            Some(FnBody::Block(b)) => {
                v.push(if contracts { Doc::HardLine } else { text(" ") });
                v.push(self.block(b, false));
            }
            Some(FnBody::Expr(e)) => v.push(self.assign_rhs("=", e, Cx::inner(), Rhs::Body)),
            Some(FnBody::Extern(_)) => {
                let sym = self.text_of(self.toks[self.tok_end[&end(c.span)]].span);
                v.push(text(format!(" = {sym}")));
            }
        }
        concat(v)
    }

    fn param(&self, p: &Param) -> String {
        let pat = self.pat(&p.pat, false);
        match &p.ty {
            None => pat,
            Some(t) => format!("{pat}: {}{}", if p.var { "var " } else { "" }, self.ty(t)),
        }
    }

    // ---- types and patterns (never broken) ----

    fn ty(&self, t: &Type) -> String {
        match &t.kind {
            TypeKind::Named { path, args } if args.is_empty() => path_str(path),
            TypeKind::Named { path, args } => format!("{}<{}>", path_str(path), self.tys(args)),
            TypeKind::List(t) => format!("[{}]", self.ty(t)),
            TypeKind::Map(k, v) => format!("{{{}: {}}}", self.ty(k), self.ty(v)),
            TypeKind::Tuple(ts) => format!("({})", self.tys(ts)),
            TypeKind::Optional(t) => format!("{}?", self.ty_operand(t)),
            TypeKind::Fallible { ok, err: None } => format!("{}!", self.ty_operand(ok)),
            TypeKind::Fallible { ok, err: Some(e) } => format!("{}!{}", self.ty_operand(ok), self.ty(e)),
            TypeKind::Any(t) => format!("any {}", self.ty(t)),
            TypeKind::Fn { params, ret } => format!("({}) => {}", self.tys(params), self.ty(ret)),
            TypeKind::Measured { base, units } => format!("{}<{units}>", self.ty(base)),
        }
    }

    /// A type before a `?` or `!` suffix: a function type needs parentheses.
    fn ty_operand(&self, t: &Type) -> String {
        match t.kind {
            TypeKind::Fn { .. } => format!("({})", self.ty(t)),
            _ => self.ty(t),
        }
    }

    fn tys(&self, ts: &[Type]) -> String {
        ts.iter().map(|t| self.ty(t)).collect::<Vec<_>>().join(", ")
    }

    /// A pattern; `head` means it is in a control-flow head, where a struct pattern needs
    /// parentheses.
    fn pat(&self, p: &Pat, head: bool) -> String {
        let pats = |ps: &[Pat]| ps.iter().map(|p| self.pat(p, false)).collect::<Vec<_>>().join(", ");
        match &p.kind {
            PatKind::Wild => "_".into(),
            PatKind::Bind(n) => n.clone(),
            PatKind::Lit { lit: Lit::Bool(b), .. } => b.to_string(),
            PatKind::Lit { neg, .. } => {
                let s = self.text_of(p.span);
                if *neg { format!("-{}", s.trim_start_matches('-').trim_start()) } else { s }
            }
            PatKind::Tuple(ps) if ps.len() == 1 => format!("({},)", pats(ps)),
            PatKind::Tuple(ps) => format!("({})", pats(ps)),
            PatKind::List { head: h, rest, tail } => {
                let mut parts: Vec<String> = h.iter().map(|p| self.pat(p, false)).collect();
                if let Some(r) = rest {
                    parts.push(match &r.pat {
                        Some(p) => format!("..{}", self.pat(p, false)),
                        None => "..".into(),
                    });
                }
                parts.extend(tail.iter().map(|p| self.pat(p, false)));
                format!("[{}]", parts.join(", "))
            }
            PatKind::Variant { path, args: None } => path_str(path),
            PatKind::Variant { path, args: Some(a) } => format!("{}({})", path_str(path), pats(a)),
            PatKind::Struct { path, fields, rest } => {
                let mut parts: Vec<String> = fields
                    .iter()
                    .map(|f| match &f.pat {
                        Some(p) => format!("{}: {}", f.name.name, self.pat(p, false)),
                        None => f.name.name.clone(),
                    })
                    .collect();
                if *rest {
                    parts.push("..".into());
                }
                let s = if parts.is_empty() { format!("{} {{}}", path_str(path)) } else { format!("{} {{ {} }}", path_str(path), parts.join(", ")) };
                if head { format!("({s})") } else { s }
            }
            PatKind::Map(es) => {
                let keys = self.map_pattern_keys(p.span, es.len());
                let parts: Vec<String> = keys.iter().zip(es).map(|(k, (_, v))| format!("{k}: {}", self.pat(v, false))).collect();
                format!("{{{}}}", parts.join(", "))
            }
            PatKind::StrPrefix { rest, .. } => {
                let i = self.tok_at[&start(p.span)];
                format!("{} + {}", self.text_of(self.toks[i].span), self.pat(rest, false))
            }
            PatKind::Some(p) => format!("some({})", self.pat(p, false)),
            PatKind::None => "none".into(),
            PatKind::Ok(p) => format!("ok({})", self.pat(p, false)),
            PatKind::Err(p) => format!("err({})", self.pat(p, false)),
        }
    }

    /// The source text of the `n` literal keys of the map pattern at `sp` (keys have no spans).
    fn map_pattern_keys(&self, sp: Span, n: usize) -> Vec<String> {
        let open = self.tok_at[&start(sp)];
        let close = self.mate[open];
        let mut keys = Vec::with_capacity(n);
        let mut k = open + 1;
        while k < close && keys.len() < n {
            let key = if self.toks[k].tok == Tok::Minus {
                k += 1;
                format!("-{}", self.text_of(self.toks[k].span))
            } else {
                self.text_of(self.toks[k].span)
            };
            keys.push(key);
            // skip to the next top-level comma
            let mut depth = 0;
            while k < close {
                match self.toks[k].tok {
                    Tok::LParen | Tok::LBracket | Tok::LBrace => depth += 1,
                    Tok::RParen | Tok::RBracket | Tok::RBrace => depth -= 1,
                    Tok::Comma if depth == 0 => break,
                    _ => {}
                }
                k += 1;
            }
            k += 1;
        }
        keys
    }

    // ---- blocks and statements ----

    /// A block as a group: `{ x }` when it had one statement on one line and fits.
    fn block(&mut self, b: &Block, force: bool) -> Doc {
        group(self.block_raw(b, force))
    }

    /// A block without its own group (an if-chain shares one group across its blocks).
    fn block_raw(&mut self, b: &Block, force: bool) -> Doc {
        let (elems, dangling) = self.seq(b.stmts.len(), b.span.line, end(b.span), &|i| b.stmts[i].span, &mut |f, i| f.expr(&b.stmts[i], Cx::stmt()));
        if elems.is_empty() && dangling.is_empty() {
            return text("{}");
        }
        let one_line = elems.len() == 1 && elems[0].plain() && dangling.is_empty() && b.span.line == b.span.end_line && !force;
        if one_line {
            let d = elems.into_iter().next().unwrap().doc;
            return concat(vec![text("{"), indent(concat(vec![Doc::Line, d])), Doc::Line, text("}")]);
        }
        let body = self.layout(elems, dangling, Doc::HardLine, Doc::HardLine, Sep::None, true);
        concat(vec![text("{"), indent(body), Doc::HardLine, text("}")])
    }

    /// ` = value` (or ` => body`): kept on one line when it fits, else broken after the
    /// operator if that makes it fit, else laid out naturally.
    fn assign_rhs(&mut self, op: &str, value: &Expr, cx: Cx, kind: Rhs) -> Doc {
        let v = self.expr(value, cx);
        let flat = concat(vec![text(format!(" {op} ")), v.clone()]);
        let breakable = match kind {
            Rhs::Body => !matches!(
                value.kind,
                ExprKind::Block(_) | ExprKind::If { .. } | ExprKind::Match { .. } | ExprKind::Loop(_) | ExprKind::While { .. } | ExprKind::For { .. } | ExprKind::Closure { .. }
            ),
            Rhs::Let => matches!(
                value.kind,
                ExprKind::Binary { .. }
                    | ExprKind::Is { .. }
                    | ExprKind::Range { .. }
                    | ExprKind::Lit(_)
                    | ExprKind::Measured { .. }
                    | ExprKind::Interp(_)
                    | ExprKind::Unary { .. }
                    | ExprKind::Name(_)
                    | ExprKind::Field { .. }
            ),
        };
        if !breakable {
            return flat;
        }
        let after = concat(vec![text(format!(" {op}")), indent(concat(vec![Doc::HardLine, v]))]);
        let mut opts = vec![(flat.clone(), Fit::Flat)];
        if flat.hard() {
            opts.push((flat.clone(), Fit::FirstLine));
        }
        opts.push((after, Fit::AllLines));
        opts.push((flat, Fit::Always));
        Doc::Choice(opts)
    }

    // ---- expressions ----

    fn expr(&mut self, e: &Expr, cx: Cx) -> Doc {
        let paren = needs_parens(e, cx) || (cx.operand && (level(e) < POSTFIX || greedy(e)) && self.user_parens(e.span));
        if paren {
            let inner = self.expr_inner(e, Cx::inner());
            return concat(vec![text("("), inner, text(")")]);
        }
        self.expr_inner(e, cx)
    }

    fn expr_inner(&mut self, e: &Expr, cx: Cx) -> Doc {
        use ExprKind as K;
        match &e.kind {
            K::Lit(Lit::Bool(b)) => text(b.to_string()),
            K::Lit(_) | K::Interp(_) => text(self.text_of(e.span)),
            K::Measured { expr, units } => text(format!("{}<{units}>", self.text_of(expr.span))),
            K::Name(n) => text(n),
            K::Hole => text("??"),
            K::Try(x) | K::Unwrap(x) if is_pipe_level(x) => self.pipe(e, cx),
            K::Pipe { .. } => self.pipe(e, cx),
            K::Field { .. }
            | K::TupleField { .. }
            | K::Call { .. }
            | K::MethodCall { .. }
            | K::Index { .. }
            | K::Slice { .. }
            | K::Try(_)
            | K::Unwrap(_)
            | K::OptChain { .. } => self.chain(e, cx),
            K::Unary { op, expr } => {
                let d = self.expr(expr, cx.operand(UNARY, cx.last));
                concat(vec![text(op.symbol()), d])
            }
            K::Binary { .. } => self.binary(e, cx),
            K::Range { lo, hi, inclusive } => {
                let lo = self.expr(lo, cx.operand(BOR, false));
                let hi = self.expr(hi, cx.operand(BOR, cx.last));
                concat(vec![lo, text(if *inclusive { "..=" } else { ".." }), hi])
            }
            K::Is { expr, pat } => {
                let d = self.expr(expr, cx.operand(IS, false));
                concat(vec![d, text(" is "), text(self.pat(pat, cx.head))])
            }
            K::Else { expr, arm } => {
                let d = self.expr(expr, cx.operand(PIPE, false));
                let arm = self.else_arm(arm, cx.last);
                concat(vec![d, Doc::Tail(Box::new(concat(vec![text(" else "), arm])))])
            }
            K::Await(x) | K::Catch(x) => {
                // the operand is a postfix chain without `?`, `!` or `?.` (or another `await`/`catch`)
                let ok = matches!(x.kind, K::Await(_) | K::Catch(_)) || (level(x) == POSTFIX && !greedy(x) && !has_try_spine(x));
                let d = if ok { self.expr(x, cx.operand(AWAIT, false)) } else { concat(vec![text("("), self.expr(x, Cx::inner()), text(")")]) };
                concat(vec![text(if matches!(e.kind, K::Catch(_)) { "catch " } else { "await " }), d])
            }
            K::Ref(x) => {
                let d = self.expr(x, cx.operand(AWAIT, false));
                concat(vec![text("&"), d])
            }
            K::Closure { params, body } => {
                let ps = match params.as_slice() {
                    [p] if p.ty.is_none() && !p.var && matches!(p.pat.kind, PatKind::Bind(_) | PatKind::Wild) => self.pat(&p.pat, false),
                    _ => format!("({})", params.iter().map(|p| self.param(p)).collect::<Vec<_>>().join(", ")),
                };
                let bcx = Cx { min: 0, last: cx.last, force: cx.force, ..Cx::default() };
                let b = self.expr(body, bcx);
                concat(vec![text(format!("{ps} => ")), b])
            }
            K::If { .. } => self.if_chain(e, cx.force),
            K::Match { scrut, arms } => self.match_expr(e, scrut, arms, cx.force),
            K::Loop(b) => concat(vec![text("loop "), self.block(b, cx.force)]),
            K::While { cond, body } => {
                let c = self.expr(cond, Cx::head());
                concat(vec![text("while "), c, text(" "), self.block(body, cx.force)])
            }
            K::For { index, pat, iter, body } => {
                let i = index.as_ref().map(|i| format!("{}, ", self.pat(i, true))).unwrap_or_default();
                let head = format!("for {i}{} in ", self.pat(pat, true));
                let it = self.expr(iter, Cx::head());
                concat(vec![text(head), it, text(" "), self.block(body, cx.force)])
            }
            K::Block(b) => self.block(b, cx.force),
            K::Let { mutable, pat, ty, value, els } => {
                let ty = ty.as_ref().map(|t| format!(": {}", self.ty(t))).unwrap_or_default();
                let head = text(format!("{} {}{ty}", if *mutable { "var" } else { "let" }, self.pat(pat, false)));
                let vcx = Cx { min: PIPE, last: els.is_none(), ..Cx::default() };
                let mut v = vec![head, self.assign_rhs("=", value, vcx, Rhs::Let)];
                if let Some(arm) = els {
                    let arm = self.else_arm(arm, true);
                    v.push(Doc::Tail(Box::new(concat(vec![text(" else "), arm]))));
                }
                concat(v)
            }
            K::Assign { op, target, value } => {
                let t = self.expr(target, Cx::inner());
                let op = format!("{}=", op.map(|o| o.symbol()).unwrap_or(""));
                let v = self.assign_rhs(&op, value, Cx::inner(), Rhs::Let);
                concat(vec![t, v])
            }
            K::Assert(x) => {
                let d = self.expr(x, Cx { min: 1, last: cx.last, ..Cx::default() });
                concat(vec![text("assert "), d])
            }
            K::Return(v) | K::Break(v) => {
                let kw = if matches!(e.kind, K::Return(_)) { "return" } else { "break" };
                match v {
                    None => text(kw),
                    Some(v) => {
                        let d = self.expr(v, Cx { min: 1, last: cx.last, ..Cx::default() });
                        concat(vec![text(format!("{kw} ")), d])
                    }
                }
            }
            K::Continue => text("continue"),
            K::Peek(x) => {
                let d = if peek_operand_ok(x) {
                    self.expr(x, Cx { min: 1, last: cx.last, ..Cx::default() })
                } else {
                    concat(vec![text("("), self.expr(x, Cx::inner()), text(")")])
                };
                concat(vec![text("peek "), d])
            }
            K::Struct { path, fields, base } => {
                let n = fields.len() + base.is_some() as usize;
                let span = |i: usize| match fields.get(i) {
                    Some(f) => f.value.as_ref().map(|v| f.name.span.to(v.span)).unwrap_or(f.name.span),
                    None => base.as_ref().unwrap().span,
                };
                let (elems, dangling) = self.seq(n, e.span.line, end(e.span), &span, &mut |f, i| match fields.get(i) {
                    Some(fi) => match &fi.value {
                        Some(v) => concat(vec![text(format!("{}: ", fi.name.name)), f.expr(v, Cx::inner())]),
                        None => text(&fi.name.name),
                    },
                    None => concat(vec![text(".."), f.expr(base.as_ref().unwrap(), Cx::inner())]),
                });
                let expanded = n > 0 && span(0).line > e.span.line;
                let lit = self.bracketed("{", "}", elems, dangling, true, Sep::Comma, cx.force || expanded);
                concat(vec![text(format!("{} ", path_str(path))), lit])
            }
            K::List(xs) => {
                let (elems, dangling) = self.seq(xs.len(), e.span.line, end(e.span), &|i| xs[i].span, &mut |f, i| f.expr(&xs[i], Cx::inner()));
                let expanded = xs.first().is_some_and(|x| x.span.line > e.span.line);
                self.bracketed("[", "]", elems, dangling, false, Sep::Comma, cx.force || expanded)
            }
            K::Map(es) => {
                let (elems, dangling) = self.seq(es.len(), e.span.line, end(e.span), &|i| es[i].0.span.to(es[i].1.span), &mut |f, i| {
                    let k = f.expr(&es[i].0, Cx::inner());
                    let v = f.expr(&es[i].1, Cx::inner());
                    concat(vec![k, text(": "), v])
                });
                let expanded = es.first().is_some_and(|x| x.0.span.line > e.span.line);
                self.bracketed("{", "}", elems, dangling, false, Sep::Comma, cx.force || expanded)
            }
            K::Tuple(xs) => {
                let (elems, dangling) = self.seq(xs.len(), e.span.line, end(e.span), &|i| xs[i].span, &mut |f, i| f.expr(&xs[i], Cx::inner()));
                self.bracketed("(", ")", elems, dangling, false, Sep::Comma, false)
            }
        }
    }

    fn else_arm(&mut self, arm: &ElseArm, last: bool) -> Doc {
        let cx = Cx { min: 1, last, ..Cx::default() };
        match &arm.binder {
            Some(b) => concat(vec![text(format!("{} => ", b.name)), self.expr(&arm.body, cx)]),
            // `else x => y` would read `x` as the error binder
            None if matches!(arm.body.kind, ExprKind::Closure { .. }) => concat(vec![text("("), self.expr(&arm.body, Cx::inner()), text(")")]),
            None => self.expr(&arm.body, cx),
        }
    }

    /// A chain of same-precedence binary operators, broken after the operators.
    fn binary(&mut self, e: &Expr, cx: Cx) -> Doc {
        let ExprKind::Binary { op, .. } = &e.kind else { unreachable!() };
        let lvl = bin_level(*op);
        if *op == BinOp::Pow {
            let ExprKind::Binary { lhs, rhs, .. } = &e.kind else { unreachable!() };
            let l = self.expr(lhs, cx.operand(UNARY, false));
            let r = self.expr(rhs, cx.operand(lvl, cx.last));
            return concat(vec![l, text(" ** "), r]);
        }
        // Flatten the left spine: ((a + b) - c) => a, + b, - c.
        let mut rights = Vec::new();
        let mut cur = e;
        while let ExprKind::Binary { op, lhs, rhs } = &cur.kind
            && bin_level(*op) == lvl
            && (std::ptr::eq(cur, e) || (lvl != CMP && !self.user_parens(cur.span)))
        {
            rights.push((*op, &**rhs));
            cur = lhs;
        }
        rights.reverse();
        let left_min = if lvl == CMP { CMP + 1 } else { lvl };
        let first = self.cmp_operand(cur, lvl, cx.operand(left_min, false));
        let n = rights.len();
        let mut tail = Vec::new();
        let mut hugged = vec![first.clone()];
        let mut last_hard = false;
        for (i, (op, r)) in rights.into_iter().enumerate() {
            let d = self.cmp_operand(r, lvl, cx.operand(lvl + 1, i + 1 == n && cx.last));
            last_hard = d.hard() && (huggable(r) || matches!(r.kind, ExprKind::Struct { .. } | ExprKind::List(_) | ExprKind::Map(_)));
            tail.push(text(format!(" {}", op.symbol())));
            tail.push(Doc::Line);
            tail.push(d.clone());
            hugged.push(text(format!(" {} ", op.symbol())));
            hugged.push(d);
        }
        let normal = group(concat(vec![first, indent(concat(tail))]));
        if !last_hard {
            return normal;
        }
        // `a == [` ... `]`: a multi-line bracketed last operand stays on the operator's line
        Doc::Choice(vec![(concat(hugged), Fit::FirstLine), (normal, Fit::Always)])
    }

    /// An operand of a binary operator at level `lvl`. A comparison's `&` `^` `|` operand always
    /// gets parentheses (E0038), even when the parser's span for it doesn't show the user's.
    fn cmp_operand(&mut self, x: &Expr, lvl: u8, cx: Cx) -> Doc {
        if lvl == CMP && matches!(x.kind, ExprKind::Binary { op, .. } if matches!(bin_level(op), BOR | BXOR | BAND)) {
            return concat(vec![text("("), self.expr(x, Cx::inner()), text(")")]);
        }
        self.expr(x, cx)
    }

    /// `x |> f(a) |> g()?`: broken before each `|>` when it doesn't fit.
    fn pipe(&mut self, e: &Expr, cx: Cx) -> Doc {
        // steps innermost first
        let mut steps: Vec<(&Expr, &[Expr], Span, String)> = Vec::new();
        let mut cur = e;
        loop {
            let mut suffix = String::new();
            while let ExprKind::Try(x) | ExprKind::Unwrap(x) = &cur.kind
                && is_pipe_level(x)
            {
                suffix.insert(0, if matches!(cur.kind, ExprKind::Try(_)) { '?' } else { '!' });
                cur = x;
            }
            let ExprKind::Pipe { lhs, callee, args } = &cur.kind else { unreachable!() };
            steps.push((callee, args, cur.span, suffix));
            cur = lhs;
            if !is_pipe_level(cur) || self.user_parens(cur.span) {
                break;
            }
        }
        steps.reverse();
        // a pipe of several steps written one step per line stays that way
        let kept = steps.len() > 1 && steps.iter().any(|s| s.0.span.line > cur.span.end_line);
        let root = self.expr(cur, cx.operand(PIPE + 1, false));
        let mut segs = Vec::new();
        for (callee, args, sp, suffix) in steps {
            let c = text(callee_path(callee));
            let a = if args.is_empty() && !self.has_call_parens(sp) { nil() } else { self.args(args, sp) };
            segs.push(concat(vec![text("|> "), c, a, text(suffix)]));
        }
        let flat = concat(std::iter::once(root.clone()).chain(segs.iter().flat_map(|s| [text(" "), s.clone()])).collect());
        let brk = concat(vec![root, indent(concat(segs.into_iter().flat_map(|s| [Doc::HardLine, s]).collect()))]);
        if kept {
            return brk;
        }
        let mut opts = vec![(flat.clone(), Fit::Flat)];
        if flat.hard() {
            opts.push((flat, Fit::FirstLine));
        }
        opts.push((brk, Fit::Always));
        Doc::Choice(opts)
    }

    /// Did the pipe step ending at `sp` have parentheses (`x |> f()` vs `x |> f`)?
    fn has_call_parens(&self, sp: Span) -> bool {
        self.tok_end.get(&end(sp)).is_some_and(|&i| self.toks[i].tok == Tok::RParen)
    }

    /// A postfix chain `a.b(x).c[i]?`: broken before each `.method(...)` when it has two or
    /// more method calls and doesn't fit.
    fn chain(&mut self, e: &Expr, cx: Cx) -> Doc {
        use ExprKind as K;
        let mut segs: Vec<&Expr> = Vec::new();
        let mut cur = e;
        let root = loop {
            let recv: &Expr = match &cur.kind {
                K::Field { expr, .. } | K::TupleField { expr, .. } | K::Index { expr, .. } | K::Slice { expr, .. } => expr,
                K::MethodCall { recv, .. } => recv,
                K::Call { callee, .. } => callee,
                K::Try(x) | K::Unwrap(x) if !is_pipe_level(x) => x,
                K::OptChain { expr, .. } => expr,
                _ => break cur,
            };
            segs.push(cur);
            let postfix = level(recv) == POSTFIX && !greedy(recv) && !recv_needs_parens(recv, cur) && !self.user_parens(recv.span);
            if !postfix {
                break recv;
            }
            cur = recv;
        };
        segs.reverse();
        let first = segs[0];
        // `await x?` is `(await x)?`, so an `await` receiver of `?`, `!` or `?.` needs no parens
        let rmin = if matches!(first.kind, K::Try(_) | K::Unwrap(_) | K::OptChain { .. }) { AWAIT } else { POSTFIX };
        let rcx = cx.operand(rmin, false);
        let root_doc = if recv_needs_parens(root, first) {
            concat(vec![text("("), self.expr(root, Cx::inner()), text(")")])
        } else {
            self.expr(root, rcx)
        };
        let mut parts: Vec<(bool, Doc)> = Vec::new();
        // a chain of several calls written one call per line stays that way
        let mut kept = false;
        for s in &segs {
            if let K::MethodCall { recv, name, .. } = &s.kind {
                kept |= name.span.line > recv.span.end_line;
            }
        }
        for s in segs {
            let d = match &s.kind {
                K::Field { name, .. } => text(format!(".{}", name.name)),
                K::TupleField { index, .. } => text(format!(".{index}")),
                K::MethodCall { name, args, .. } => concat(vec![text(format!(".{}", name.name)), self.args(args, s.span)]),
                K::Call { args, .. } => self.args(args, s.span),
                K::Index { index, .. } => concat(vec![text("["), self.expr(index, Cx::inner()), text("]")]),
                K::Slice { lo, hi, inclusive, .. } => {
                    let lo = self.expr(lo, Cx::inner().operand(BOR, false));
                    let hi = self.expr(hi, Cx::inner().operand(BOR, true));
                    concat(vec![text("["), lo, text(if *inclusive { "..=" } else { ".." }), hi, text("]")])
                }
                K::Try(_) => text("?"),
                K::Unwrap(_) => text("!"),
                K::OptChain { name, args, .. } => match args {
                    None => text(format!("?.{}", name.name)),
                    Some(a) => concat(vec![text(format!("?.{}", name.name)), self.args(a, s.span)]),
                },
                _ => unreachable!(),
            };
            parts.push((matches!(s.kind, K::MethodCall { .. }), d));
        }
        let calls = parts.iter().filter(|(m, _)| *m).count();
        if calls < 3 && !kept {
            return concat(std::iter::once(root_doc).chain(parts.into_iter().map(|(_, d)| d)).collect());
        }
        // head = root + segments before the first method call; then one group per call
        let mut head = vec![root_doc];
        let mut groups: Vec<Vec<Doc>> = Vec::new();
        for (m, d) in parts {
            if m {
                groups.push(vec![d]);
            } else if let Some(g) = groups.last_mut() {
                g.push(d);
            } else {
                head.push(d);
            }
        }
        let flat = concat(head.iter().cloned().chain(groups.iter().flatten().cloned()).collect());
        let brk = concat(vec![concat(head), indent(concat(groups.into_iter().flat_map(|g| [Doc::HardLine, concat(g)]).collect()))]);
        if kept {
            return brk;
        }
        let mut opts = vec![(flat.clone(), Fit::Flat)];
        if flat.hard() {
            opts.push((flat, Fit::FirstLine));
        }
        opts.push((brk, Fit::Always));
        Doc::Choice(opts)
    }

    /// Call arguments `(a, b)` ending at `close`; the last one is hugged (`f(x => {` ...
    /// `})`) when it is a closure with a block body or a struct, list or map literal.
    fn args(&mut self, args: &[Expr], sp: Span) -> Doc {
        let close = end(sp);
        // `f("a long string")`: breaking would not make it fit
        if let [a] = args
            && matches!(a.kind, ExprKind::Lit(Lit::Str(_)) | ExprKind::Interp(_))
            && !self.comments_in(start(sp), close)
        {
            return concat(vec![text("("), self.expr(a, Cx::inner()), text(")")]);
        }
        let quiet = !self.comments_in((sp.line, sp.col), close);
        let (elems, dangling) = self.seq(args.len(), sp.line, close, &|i| args[i].span, &mut |f, i| f.expr(&args[i], Cx::inner()));
        let hug = quiet && args.last().is_some_and(huggable);
        if !hug {
            return self.bracketed("(", ")", elems, dangling, false, Sep::Comma, false);
        }
        let n = args.len();
        let mut flat_parts: Vec<Doc> = elems.iter().take(n - 1).map(|e| e.doc.clone()).collect();
        if flat_parts.iter().any(Doc::hard) {
            return self.bracketed("(", ")", elems, dangling, false, Sep::Comma, false);
        }
        let last = self.expr(&args[n - 1], Cx { force: true, ..Cx::inner() });
        flat_parts.push(last);
        let mut hugged = vec![text("(")];
        for (i, d) in flat_parts.into_iter().enumerate() {
            if i > 0 {
                hugged.push(text(", "));
            }
            hugged.push(d);
        }
        hugged.push(text(")"));
        let plain = self.bracketed("(", ")", elems, dangling, false, Sep::Comma, false);
        let expanded = match &plain {
            Doc::Group(d, _) => broken((**d).clone()),
            d => d.clone(),
        };
        Doc::Choice(vec![(plain, Fit::Flat), (concat(hugged), Fit::FirstLine), (expanded, Fit::Always)])
    }

    /// `if a { x } else if b { y } else { z }`: one group, so the blocks break together.
    fn if_chain(&mut self, e: &Expr, force: bool) -> Doc {
        let mut v = Vec::new();
        let mut cur = e;
        loop {
            let ExprKind::If { cond, then, els } = &cur.kind else { unreachable!() };
            v.push(text("if "));
            v.push(self.expr(cond, Cx::head()));
            v.push(text(" "));
            v.push(self.block_raw(then, force));
            match els.as_deref() {
                None => break,
                Some(x @ Expr { kind: ExprKind::If { .. }, .. }) => {
                    v.push(text(" else "));
                    cur = x;
                }
                Some(Expr { kind: ExprKind::Block(b), .. }) => {
                    v.push(text(" else "));
                    v.push(self.block_raw(b, force));
                    break;
                }
                Some(_) => unreachable!("else is a block or an if"),
            }
        }
        group(concat(v))
    }

    fn match_expr(&mut self, e: &Expr, scrut: &Expr, arms: &[Arm], force: bool) -> Doc {
        let s = self.expr(scrut, Cx::head());
        let (elems, dangling) = self.seq(arms.len(), e.span.line, end(e.span), &|i| arms[i].span, &mut |f, i| {
            let a = &arms[i];
            let mut v = vec![text(f.pat(&a.pat, false))];
            if let Some(g) = &a.guard {
                v.push(text(" when "));
                v.push(f.expr(g, Cx { min: 1, guard: true, ..Cx::default() }));
            }
            v.push(f.assign_rhs("=>", &a.body, Cx::stmt(), Rhs::Body));
            concat(v)
        });
        let force = force || e.span.line != e.span.end_line;
        let body = self.bracketed("{", "}", elems, dangling, true, Sep::FlatComma, force);
        concat(vec![text("match "), s, text(" "), body])
    }
}

/// How a right-hand side may break after its operator.
#[derive(Clone, Copy, PartialEq)]
enum Rhs {
    /// A fn `=` body, const value or match-arm body: anything but block-like expressions.
    Body,
    /// A `let` or assignment value: only operator expressions and plain values.
    Let,
}

// ---- precedence ----

/// Binding levels, loosest first. An operand whose level is below what its position needs gets
/// parentheses.
const STMT: u8 = 0;
const ELSE: u8 = 1;
const PIPE: u8 = 2;
const OR: u8 = 3;
const AND: u8 = 4;
const IS: u8 = 5;
const CMP: u8 = 6;
const RANGE: u8 = 7;
const BOR: u8 = 8;
const BXOR: u8 = 9;
const BAND: u8 = 10;
const SHIFT: u8 = 11;
const ADD: u8 = 12;
const MUL: u8 = 13;
const POW: u8 = 14;
const UNARY: u8 = 15;
const AWAIT: u8 = 16;
const POSTFIX: u8 = 17;

/// The context an expression is printed in.
#[derive(Clone, Copy, Default)]
struct Cx {
    /// The loosest level allowed without parentheses.
    min: u8,
    /// Nothing of the enclosing expression follows, so a greedy form (`x => ...`, `return x`)
    /// is fine.
    last: bool,
    /// In an `if`/`while`/`for`/`match` head or a contract: no struct literals or `else`.
    head: bool,
    /// In a match-arm guard: no closures.
    guard: bool,
    /// An operand of an operator: user-written parentheses are kept.
    operand: bool,
    /// Lay out the outermost bracketed construct broken (for a hugged last argument).
    force: bool,
}

impl Cx {
    fn stmt() -> Cx {
        Cx { min: STMT, last: true, ..Cx::default() }
    }

    fn inner() -> Cx {
        Cx { min: ELSE, last: true, ..Cx::default() }
    }

    fn head() -> Cx {
        Cx { min: ELSE, last: false, head: true, ..Cx::default() }
    }

    /// An operand position: head and guard restrictions carry over (no brackets in between).
    fn operand(self, min: u8, last: bool) -> Cx {
        Cx { min, last, head: self.head, guard: self.guard, operand: true, force: false }
    }
}

fn bin_level(op: BinOp) -> u8 {
    use BinOp::*;
    match op {
        Or => OR,
        And => AND,
        Eq | Ne | Lt | Le | Gt | Ge => CMP,
        Add | Sub | AddWrap | SubWrap => ADD,
        Mul | Div | Rem | MulWrap => MUL,
        Pow => POW,
        BitOr => BOR,
        BitXor => BXOR,
        BitAnd => BAND,
        Shl | Shr => SHIFT,
    }
}

fn level(e: &Expr) -> u8 {
    use ExprKind as K;
    match &e.kind {
        K::Let { .. } | K::Assign { .. } | K::Assert(_) => STMT,
        K::Else { .. } => ELSE,
        K::Pipe { .. } => PIPE,
        K::Try(x) | K::Unwrap(x) if is_pipe_level(x) => PIPE,
        K::Binary { op, .. } => bin_level(*op),
        K::Is { .. } => IS,
        K::Range { .. } => RANGE,
        K::Unary { .. } | K::Ref(_) => UNARY,
        K::Await(_) | K::Catch(_) => AWAIT,
        _ => POSTFIX,
    }
}

/// Forms that extend as far right as they can, so nothing may follow them.
fn greedy(e: &Expr) -> bool {
    matches!(e.kind, ExprKind::Closure { .. } | ExprKind::Return(_) | ExprKind::Break(_) | ExprKind::Peek(_))
}

fn is_pipe_level(e: &Expr) -> bool {
    match &e.kind {
        ExprKind::Pipe { .. } => true,
        ExprKind::Try(x) | ExprKind::Unwrap(x) => is_pipe_level(x),
        _ => false,
    }
}

fn needs_parens(e: &Expr, cx: Cx) -> bool {
    let k = &e.kind;
    level(e) < cx.min
        || (greedy(e) && !cx.last)
        || (cx.head && matches!(k, ExprKind::Struct { .. } | ExprKind::Else { .. }))
        || (cx.guard && matches!(k, ExprKind::Closure { .. }))
        // `if c { a } else b`: the `else` would join the `if`
        || (!cx.last && matches!(k, ExprKind::If { els: None, .. }))
}

/// Does `recv` need parentheses as the receiver of the postfix `seg`? `x?.f` would lex as
/// `?.`, and `await x.f` would await `x.f`.
fn recv_needs_parens(recv: &Expr, seg: &Expr) -> bool {
    use ExprKind as K;
    let dotted = matches!(seg.kind, K::Field { .. } | K::MethodCall { .. } | K::TupleField { .. } | K::OptChain { .. });
    match &recv.kind {
        K::Try(_) | K::Hole => dotted,
        K::Await(_) | K::Catch(_) => !matches!(seg.kind, K::Try(_) | K::Unwrap(_) | K::OptChain { .. }),
        _ => false,
    }
}

/// Does the postfix chain of `e` contain `?`, `!` or `?.` (an `await` operand can't)?
fn has_try_spine(e: &Expr) -> bool {
    use ExprKind as K;
    match &e.kind {
        K::Field { expr, .. } | K::TupleField { expr, .. } | K::Index { expr, .. } | K::Slice { expr, .. } => has_try_spine(expr),
        K::MethodCall { recv, .. } => has_try_spine(recv),
        K::Call { callee, .. } => has_try_spine(callee),
        K::Try(_) | K::Unwrap(_) | K::OptChain { .. } => true,
        _ => false,
    }
}

/// Can `peek e` start with `e` as printed (`peek -x` would be the name `peek` minus `x`)?
fn peek_operand_ok(e: &Expr) -> bool {
    use ExprKind as K;
    match &e.kind {
        K::Binary { lhs: x, .. }
        | K::Is { expr: x, .. }
        | K::Range { lo: x, .. }
        | K::Else { expr: x, .. }
        | K::Pipe { lhs: x, .. }
        | K::Field { expr: x, .. }
        | K::TupleField { expr: x, .. }
        | K::Index { expr: x, .. }
        | K::Slice { expr: x, .. }
        | K::MethodCall { recv: x, .. }
        | K::Call { callee: x, .. }
        | K::Try(x)
        | K::Unwrap(x)
        | K::OptChain { expr: x, .. } => peek_operand_ok(x),
        K::Lit(_) | K::Measured { .. } | K::Interp(_) | K::Name(_) | K::If { .. } | K::Match { .. } | K::Await(_) | K::Catch(_) | K::Tuple(_) | K::List(_) | K::Struct { .. } => true,
        K::Closure { .. } => true,
        _ => false,
    }
}

/// A last argument that can be hugged: `f(x => {`, `f(Point {`, `f([`.
fn huggable(e: &Expr) -> bool {
    use ExprKind as K;
    match &e.kind {
        K::Closure { body, .. } => matches!(&body.kind, K::Block(b) if !b.stmts.is_empty())
            || matches!(&body.kind, K::Match { .. } | K::Struct { .. })
            || huggable_lit(body),
        _ => huggable_lit(e),
    }
}

fn huggable_lit(e: &Expr) -> bool {
    match &e.kind {
        ExprKind::Struct { fields, base, .. } => !fields.is_empty() || base.is_some(),
        ExprKind::List(xs) => !xs.is_empty(),
        ExprKind::Map(es) => !es.is_empty(),
        _ => false,
    }
}

fn callee_path(e: &Expr) -> String {
    match &e.kind {
        ExprKind::Name(n) => n.clone(),
        ExprKind::Field { expr, name } => format!("{}.{}", callee_path(expr), name.name),
        _ => unreachable!("a pipe step is a name or path"),
    }
}

fn item_span(i: &Item) -> Span {
    match i {
        Item::Fn(g) => g.header.as_ref().map(|h| h.span).unwrap_or(g.clauses[0].span),
        Item::Struct(d) => d.span,
        Item::Enum(d) => d.span,
        Item::Shape(d) => d.span,
        Item::Test(d) => d.span,
        Item::Let(d) | Item::Imprint(d) => d.span,
        Item::ExternType(d) => d.span,
    }
}

fn vis(public: bool) -> &'static str {
    if public { "pub " } else { "" }
}

fn path_str(p: &[Ident]) -> String {
    p.iter().map(|i| i.name.as_str()).collect::<Vec<_>>().join(".")
}

fn generics(gs: &[Generic]) -> String {
    if gs.is_empty() {
        return String::new();
    }
    let parts: Vec<String> = gs
        .iter()
        .map(|g| {
            let bounds: Vec<String> = g.bounds.iter().map(type_str).collect();
            if bounds.is_empty() { g.name.name.clone() } else { format!("{}: {}", g.name.name, bounds.join(" + ")) }
        })
        .collect();
    format!("<{}>", parts.join(", "))
}

fn type_str(t: &Type) -> String {
    type_dump(t)
}

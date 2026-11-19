/// `auk fmt`: the canonical, zero-config formatter (src/fmt/mod.rs).
///
/// The formatter parses the file, then prints the AST through a Prettier-style document printer
/// (`fmt/doc.auk`) with a 100-column limit. Things the AST does not keep come from the source:
/// literals are copied verbatim (so escapes, raw and triple-quoted strings and `1_000` survive),
/// comments are re-attached by position, and single blank lines and a few layout choices (a
/// one-line block, an expanded struct literal) are preserved. Parentheses are printed where
/// precedence needs them, and kept where the user wrote them around an operand.
///
/// Style: 2-space indent, no semicolons, spaces around binary operators, `{ x }` for one-line
/// bodies, trailing commas only on multi-line lists, chains and pipes broken before `.`/`|>`,
/// one blank line between items (none between the clauses of one function), trailing comments
/// aligned.
///
/// Differences in shape from the Rust: a source position `(line, col)` is one `int` (`at`), so
/// positions compare and key maps as ints; `ast_shape` compares the `auk dump ast` text (spans and
/// node ids removed) instead of Rust's `Debug` text; Rust's `Fmt` methods that only read are
/// functions of a `Fmt`, those that mutate (taking comments) take a `var Fmt`.

/// The maximum line width.
pub let WIDTH = 100

// Rust's `use doc::{Doc, Fit, broken, concat, group, if_break, indent, nil, text}`.
fn text(s: str): fmt.doc.Doc = fmt.doc.Text(s)

fn concat(v: [fmt.doc.Doc]): fmt.doc.Doc = fmt.doc.Concat(v)

fn indent(d: fmt.doc.Doc): fmt.doc.Doc = fmt.doc.Indent(d)

fn group(d: fmt.doc.Doc): fmt.doc.Doc = fmt.doc.group(d)

fn broken(d: fmt.doc.Doc): fmt.doc.Doc = fmt.doc.Group(d, true)

fn if_break(b: fmt.doc.Doc, f: fmt.doc.Doc): fmt.doc.Doc = fmt.doc.IfBreak(b, f)

fn nil(): fmt.doc.Doc = fmt.doc.Concat([])

/// Format an Auk source file. Fails with the parse diagnostics if it does not parse.
pub fn format(src: str): str!parser.Fails {
  let m = parser.parse(src, false)?
  let toks = match lexer.lex(src) {
    ok(lx) => lx.toks
    err(Bad(d)) => fail(parser.Many([d]))
  }
  var f = new_fmt(src, toks)
  let d = f.module(m)
  let lines = fmt.doc.align_lines(fmt.doc.render_lines(d, WIDTH))
  var out = lines.join("\n").trim_end()
  if out != "" { out += "\n" }
  out
}

/// Why a file could not be formatted.
pub enum Error {
  /// The input does not parse.
  Parse(ds: [diag.Diag]),
  /// A formatter bug: the output would not parse or would mean something else.
  Internal(msg: str),
}

/// `format`, then check that the output parses to the same AST (ignoring spans and node ids).
pub fn format_checked(src: str): str!Error {
  let before = match parser.parse(src, false) {
    ok(m) => m
    err(Many(ds)) => fail(Parse(ds))
  }
  let out = match format(src) {
    ok(o) => o
    err(Many(ds)) => fail(Parse(ds))
  }
  let after = match parser.parse(out, false) {
    ok(m) => m
    err(Many(ds)) => {
      let msgs = ds.map(d => d.render("<formatted>", out))
      fail(Internal("the formatted output does not parse:\n" + msgs.join("")))
    }
  }
  if ast_shape(before) != ast_shape(after) {
    fail(Internal("formatting would change the meaning of the program"))
  }
  out
}

/// The AST's dump (`auk dump ast`) with every span and node id removed: equal shapes mean the
/// same program (docs included).
pub fn ast_shape(m: ast.Module): str {
  var lines: [str] = []
  dump.module(&lines, m)
  var out: [str] = []
  for l in lines { out.push(strip_spans(l)) }
  out.join("\n")
}

/// A dump line without its node ids (`#12`) and spans (`3:4-3:9`); quoted strings are kept.
fn strip_spans(l: str): str {
  if !l.contains("#") && !l.contains(":") { return l }
  let cs = l.chars()
  let n = cs.len()
  var out: [char] = []
  var i = 0
  while i < n {
    let c = cs[i]
    if c == '"' {
      out.push(c)
      i += 1
      while i < n && cs[i] != '"' {
        if cs[i] == '\\' && i + 1 < n {
          out.push(cs[i])
          i += 1
        }
        out.push(cs[i])
        i += 1
      }
      if i < n {
        out.push(cs[i])
        i += 1
      }
    } else if c == '#' && i + 1 < n && cs[i + 1].is_digit() {
      i += 1
      while i < n && cs[i].is_digit() { i += 1 }
    } else if c.is_digit() && (i == 0 || !cs[i - 1].is_alpha() && !cs[i - 1].is_digit()) {
      var j = i
      var colons = 0
      var dashes = 0
      while j < n && (cs[j].is_digit() || cs[j] == ':' || cs[j] == '-') {
        if cs[j] == ':' { colons += 1 }
        if cs[j] == '-' { dashes += 1 }
        j += 1
      }
      if colons != 2 || dashes != 1 {
        for k in i..j { out.push(cs[k]) }
      }
      i = j
    } else {
      out.push(c)
      i += 1
    }
  }
  str(out)
}

// ---- command line ----

/// `auk fmt [--check] <file|dir|->...`. Returns the exit code.
pub fn run(args: [str]): int uses fs, env {
  let check = args.contains("--check")
  let ps = args.filter(a => a != "--check")
  if ps.len() == 0 {
    eprint("usage: auk fmt [--check] <file|dir|->...")
    return 2
  }
  var code = 0
  for p in ps {
    if p == "-" {
      code = max(code, stdin(check))
      continue
    }
    var files: [str] = []
    match collect(p, &files) {
      ok(_) => {}
      err(e) => {
        eprint("error: cannot read {p}: {e}")
        code = 1
        continue
      }
    }
    for fl in files { code = max(code, file(fl, check)) }
  }
  code
}

/// `print!`: `s` without a line break added (`s` is empty or ends with one).
fn print_raw(s: str) {
  if s != "" { print(s.strip_suffix("\n") else s) }
}

fn stdin(check: bool): int uses env {
  let src = match env.read_all() {
    ok(s) => s
    err(e) => {
      eprint("error: cannot read stdin: {e}")
      return 1
    }
  }
  match format_checked(src) {
    ok(out) => {
      if check {
        if out != src {
          print("<stdin>")
          return 1
        }
        return 0
      }
      print_raw(out)
      0
    }
    err(e) => report("<stdin>", src, e)
  }
}

fn file(path: str, check: bool): int uses fs {
  let src = match paths.read(path) {
    ok(s) => s
    err(e) => {
      eprint("error: cannot read {path}: {e}")
      return 1
    }
  }
  let out = match format_checked(src) {
    ok(o) => o
    err(e) => return report(path, src, e)
  }
  if out == src { return 0 }
  if check {
    print(path)
    return 1
  }
  match fs.write(path, out) {
    ok(_) => 0
    err(e) => {
      eprint("error: cannot write {path}: {paths.io_error(e.show())}")
      1
    }
  }
}

fn report(name: str, src: str, e: Error): int {
  match e {
    Parse(ds) => {
      let s = ds.map(d => d.render(name, src)).join("")
      eprint(s.strip_suffix("\n") else s)
    }
    Internal(msg) =>
      eprint("error: {name}: {msg} (this is an auk fmt bug; the file was left unchanged)")
  }
  1
}

/// A file as given, or every `.auk` file under a directory (skipping hidden directories and
/// `target`), sorted.
pub fn collect(p: str, out: var [str]): ()! uses fs {
  if !fs.is_dir(p) {
    if !fs.exists(p) { fail("No such file or directory (os error 2)") }
    out.push(p)
    return
  }
  let names = match fs.list(p) {
    ok(ns) => ns
    err(e) => fail(paths.io_error(e.show()))
  }
  for name in names.sort() {
    let e = paths.join(p, name)
    if fs.is_dir(e) {
      if !name.starts_with(".") && name != "target" { collect(e, &out)? }
    } else if paths.extension(e) == some("auk") {
      out.push(e)
    }
  }
}

// ---- source positions and comments ----

/// (line, col), 1-based, cols in chars, like `Span`, as one int: `line << 32 | col`, so
/// positions compare like Rust's `(u32, u32)` tuples.
fn at(line: int, col: int): int = line * 4294967296 + col

fn line_of(p: int): int = p / 4294967296

fn col_of(p: int): int = p % 4294967296

fn start(s: diag.Span): int = at(s.line, s.col)

fn end(s: diag.Span): int = at(s.end_line, s.end_col)

struct Comment {
  start: int,
  end: int,
  text: str,
  /// Only whitespace precedes it on its line.
  own_line: bool,
}

/// One element of a list-like construct (statements, items, arms, fields, arguments...) with
/// the comments around it.
struct Elem {
  /// Comments after code on the line before the element: printed at the end of that line.
  pre: [str],
  /// A blank line separated it from the previous element in the source.
  blank: bool,
  /// Own-line comments above it, each followed by a line break.
  lead: [fmt.doc.Doc],
  doc: fmt.doc.Doc,
  /// Comments at the end of its last line.
  trail: [str],
  end_line: int,
}

fn plain(e: Elem): bool = e.pre.len() == 0 && e.lead.len() == 0 && e.trail.len() == 0

/// What goes between the elements of a list.
enum Sep {
  /// `,` after each element, and after the last one when broken.
  Comma,
  /// `,` only when flat (match arms, shape methods).
  FlatComma,
  /// Nothing (statements, items).
  None,
}

struct Fmt {
  chars: [char],
  line_start: [int],
  /// The tokens without `Newline`s.
  toks: [token.Token],
  tok_at: {int: int},
  tok_end: {int: int},
  /// The index of the matching bracket, or -1.
  mate: [int],
  comments: [Comment],
  /// Comments before this index have been printed.
  next: int,
}

fn new_fmt(src: str, toks: [token.Token]): Fmt {
  let chars = src.chars()
  var line_start = [0]
  for i, c in chars {
    if c == '\n' { line_start.push(i + 1) }
  }
  var ts: [token.Token] = []
  for t in toks {
    if !(t.tok is Newline) { ts.push(t) }
  }
  var mate: [int] = []
  for _ in 0..ts.len() { mate.push(-1) }
  var f = Fmt { chars, line_start, toks: ts, tok_at: {}, tok_end: {}, mate, comments: [], next: 0 }
  var stack: [int] = []
  var prev = 0
  for i in 0..f.toks.len() {
    let sp = f.toks[i].span
    let eof = f.toks[i].tok is Eof
    if !eof {
      f.tok_at[start(sp)] = i
      f.tok_end[end(sp)] = i
    }
    match f.toks[i].tok {
      LParen | LBracket | LBrace => stack.push(i)
      RParen | RBracket | RBrace => match stack.pop() {
        some(o) => {
          f.mate[o] = i
          f.mate[i] = o
        }
        none => {}
      }
      _ => {}
    }
    let s = f.off(start(sp))
    f.scan_comments(prev, s)
    prev = max(prev, f.off(end(sp)))
  }
  f
}

fn off(f: Fmt, p: int): int = f.line_start[line_of(p) - 1] + col_of(p) - 1

fn pos(f: Fmt, o: int): int {
  // the number of line starts <= o
  var lo = 0
  var hi = f.line_start.len()
  while lo < hi {
    let mid = (lo + hi) / 2
    if f.line_start[mid] <= o { lo = mid + 1 } else { hi = mid }
  }
  at(lo, o - f.line_start[lo - 1] + 1)
}

/// The char at `k`, or `\0` past the end.
fn ch(f: Fmt, k: int): char = if k < f.chars.len() { f.chars[k] } else { '\0' }

/// Collect the comments in the gap `chars[a..b]` between two tokens.
fn scan_comments(f: var Fmt, a: int, b: int) {
  var i = a
  while i < b {
    var j = i
    if f.ch(i) == '/' && f.ch(i + 1) == '/' {
      while j < b && f.chars[j] != '\n' { j += 1 }
    } else if f.ch(i) == '/' && f.ch(i + 1) == '*' {
      j = i + 2
      var depth = 1
      while j < b && depth > 0 {
        if f.ch(j) == '/' && f.ch(j + 1) == '*' {
          depth += 1
          j += 2
        } else if f.ch(j) == '*' && f.ch(j + 1) == '/' {
          depth -= 1
          j += 2
        } else {
          j += 1
        }
      }
    } else {
      i += 1
      continue
    }
    let s = f.pos(i)
    let e = f.pos(j)
    var own_line = true
    for k in f.line_start[line_of(s) - 1]..i {
      if !lexer.is_whitespace(f.chars[k]) {
        own_line = false
        break
      }
    }
    let t = str(f.chars[i..j]).trim_end()
    f.comments.push(Comment { start: s, end: e, text: t, own_line })
    i = j
  }
}

fn text_of(f: Fmt, sp: diag.Span): str = str(f.chars[f.off(start(sp))..f.off(end(sp))])

fn line_is_blank(f: Fmt, l: int): bool {
  let a = f.line_start[l - 1]
  let b = if l < f.line_start.len() { f.line_start[l] } else { f.chars.len() }
  for k in a..b {
    if !lexer.is_whitespace(f.chars[k]) { return false }
  }
  true
}

/// Is there an empty line strictly between lines `a` and `b`?
fn blank_between(f: Fmt, a: int, b: int): bool {
  for l in a + 1..b {
    if f.line_is_blank(l) { return true }
  }
  false
}

/// The unprinted comments that start before `p`.
fn take_before(f: var Fmt, p: int): [Comment] {
  var out: [Comment] = []
  while f.next < f.comments.len() && f.comments[f.next].start < p {
    out.push(f.comments[f.next])
    f.next += 1
  }
  out
}

/// After an element that ends at `e`: the unprinted comments inside it (a comment the
/// layout had no place for) and those on its last line before `limit`.
fn take_trailing(f: var Fmt, e: int, limit: int): [str] {
  var out: [str] = []
  while f.next < f.comments.len() {
    let c = f.comments[f.next]
    if !(c.start < e || (line_of(c.start) == line_of(e) && c.start < limit)) { break }
    // `a, /* c */ b`: that comment belongs to `b`
    if c.start >= e &&
      c.text.starts_with("/*") &&
      line_of(c.end) == line_of(limit) &&
      c.end <= limit {
      break
    }
    out.push(c.text)
    f.next += 1
  }
  out
}

/// Are there unprinted comments in `[a, b)`?
fn comments_in(f: Fmt, a: int, b: int): bool {
  for k in f.next..f.comments.len() {
    let s = f.comments[k].start
    if s >= a && s < b { return true }
  }
  false
}

/// Own-line comments as docs, each followed by a line break (and a kept blank line).
fn lead_docs(f: Fmt, cs: [Comment], next_line: int): [fmt.doc.Doc] {
  var v: [fmt.doc.Doc] = []
  for k, c in cs {
    v.push(text(c.text))
    let nl = if k + 1 < cs.len() { line_of(cs[k + 1].start) } else { next_line }
    if f.blank_between(line_of(c.end), nl) { v.push(fmt.doc.Blank) }
    v.push(fmt.doc.HardLine)
  }
  v
}

/// Build the elements of a list whose `n` items have the spans `span(i)`, opened on line
/// `open_line` and closed at `close`. Returns them and the comments left before `close`.
fn seq(
  f: var Fmt,
  n: int,
  open_line: int,
  close: int,
  span: (int) => diag.Span,
  build: (var Fmt, int) => fmt.doc.Doc,
): ([Elem], [Comment]) {
  var elems: [Elem] = []
  var prev_line = open_line
  for i in 0..n {
    let sp = span(i)
    var lead = f.take_before(start(sp))
    // `/* c */ x`: a block comment just before the element on its line stays inline
    var inline: [fmt.doc.Doc] = []
    while lead.len() > 0 {
      let c = lead[lead.len() - 1]
      if !(c.text.starts_with("/*") && line_of(c.start) == sp.line && line_of(c.end) == sp.line) {
        break
      }
      inline.insert(0, text("{c.text} "))
      lead.pop()
    }
    var k = 0
    while k < lead.len() && !lead[k].own_line { k += 1 }
    let pre = lead.take(k).map(c => c.text)
    let own = lead.skip(k)
    let first = if own.len() > 0 { line_of(own[0].start) } else { sp.line }
    let blank = i > 0 && f.blank_between(prev_line, first)
    let lead_d = f.lead_docs(own, sp.line)
    inline.push(build(&f, i))
    let d = concat(inline)
    let limit = if i + 1 < n { start(span(i + 1)) } else { close }
    let trail = f.take_trailing(end(sp), limit)
    prev_line = sp.end_line
    elems.push(Elem { pre, blank, lead: lead_d, doc: d, trail, end_line: sp.end_line })
  }
  let dangling = f.take_before(close)
  (elems, dangling)
}

/// Lay out elements: `open` before the first, `brk` before the others, `sep` after each.
/// The caller adds the brackets and the closing break.
fn layout(
  f: Fmt,
  elems: [Elem],
  dangling: [Comment],
  open: fmt.doc.Doc,
  brk: fmt.doc.Doc,
  sep: Sep,
  vertical: bool,
): fmt.doc.Doc {
  let n = elems.len()
  var v: [fmt.doc.Doc] = []
  var prev_line: int? = none
  for i, e in elems {
    for c in e.pre { v.push(fmt.doc.LineSuffix(c)) }
    if e.blank { v.push(if vertical { fmt.doc.Blank } else { if_break(fmt.doc.Blank, nil()) }) }
    v.push(if i == 0 { open } else { brk })
    for d in e.lead { v.push(d) }
    v.push(e.doc)
    match sep {
      Comma => if i + 1 < n { v.push(text(",")) } else { v.push(if_break(text(","), nil())) }
      FlatComma => if i + 1 < n { v.push(if_break(nil(), text(","))) }
      None => {}
    }
    for c in e.trail { v.push(fmt.doc.LineSuffix(c)) }
    prev_line = e.end_line
  }
  for c in dangling {
    if !c.own_line && prev_line != none {
      v.push(fmt.doc.LineSuffix(c.text))
      continue
    }
    match prev_line {
      some(l) => if f.blank_between(l, line_of(c.start)) { v.push(fmt.doc.Blank) }
      none => {}
    }
    v.push(fmt.doc.HardLine)
    v.push(text(c.text))
    prev_line = line_of(c.end)
  }
  concat(v)
}

/// `open` elements `close` as a group: flat `{ a, b }` / `(a, b)` or one element per line.
fn bracketed(
  f: Fmt,
  open: str,
  close: str,
  elems: [Elem],
  dangling: [Comment],
  spaced: bool,
  sep: Sep,
  force: bool,
): fmt.doc.Doc {
  if elems.len() == 0 && dangling.len() == 0 { return text(open + close) }
  let brk = if spaced { fmt.doc.Line } else { fmt.doc.SoftLine }
  let body = f.layout(elems, dangling, brk, fmt.doc.Line, sep, false)
  let d = concat([text(open), indent(body), brk, text(close)])
  if force { broken(d) } else { group(d) }
}

/// Does the source have user-written grouping parentheses right around `sp`?
fn user_parens(f: Fmt, sp: diag.Span): bool {
  let i = f.tok_at.get(start(sp)) else return false
  let j = f.tok_end.get(end(sp)) else return false
  if i < 2 || j + 1 >= f.toks.len() { return false }
  let call = match f.toks[i - 2].tok {
    Ident(_) | RParen | RBracket | Int(_) | Float(_) | Char(_) | Str(_) | True | False | Question | QuestionQuestion => true
    _ => false
  }
  f.toks[i - 1].tok is LParen && f.toks[j + 1].tok is RParen && f.mate[i - 1] == j + 1 && !call
}

/// The end of the `)` that closes the first `(` after the token at `p`.
fn close_paren_after(f: Fmt, p: int): int {
  var k = f.tok_at[p]
  while k < f.toks.len() && !(f.toks[k].tok is LParen) { k += 1 }
  if k < f.toks.len() && f.mate[k] >= 0 { end(f.toks[f.mate[k]].span) } else { p }
}

// ---- items ----

/// An item, with each fn clause as its own unit.
enum Unit {
  UClause(c: ast.FnClause),
  UItem(i: ast.Item),
}

fn module(f: var Fmt, m: ast.Module): fmt.doc.Doc {
  // `g` numbers clause groups
  var us: [(Unit, int)] = []
  for g, it in m.items {
    match it {
      Fn(fg) => {
        match fg.header {
          some(h) => us.push((UClause(h), g))
          none => {}
        }
        for c in fg.clauses { us.push((UClause(c), g)) }
      }
      _ => us.push((UItem(it), g))
    }
  }
  var v: [fmt.doc.Doc] = []
  // the previous unit: group, last source line, prints on one line
  var has_prev = false
  var pg = 0
  var pl = 0
  var prev_one = false
  for u in us {
    let g = u.1
    let sp = match u.0 {
      UClause(c) => c.span
      UItem(i) => item_span(i)
    }
    let lead = f.take_before(start(sp))
    var k = 0
    while k < lead.len() && !lead[k].own_line && has_prev { k += 1 }
    for c in lead.take(k) { v.push(fmt.doc.LineSuffix(c.text)) }
    let d = match u.0 {
      UClause(c) => f.clause(c, false)
      UItem(i) => f.item(i)
    }
    let one_line = fmt.doc.render_lines(d, WIDTH).len() == 1
    if has_prev {
      // Items are separated by a blank line, except the clauses of one function, and
      // one-line items the source keeps together (`enum` tables, small helpers).
      let first = if k < lead.len() { line_of(lead[k].start) } else { sp.line }
      let together = pg == g || (prev_one && one_line && !f.blank_between(pl, first))
      if !together { v.push(fmt.doc.Blank) }
      v.push(fmt.doc.HardLine)
    }
    for x in f.lead_docs(lead.skip(k), sp.line) { v.push(x) }
    v.push(d)
    let trail = f.take_trailing(end(sp), at(sp.end_line + 1, 0))
    for t in trail { v.push(fmt.doc.LineSuffix(t)) }
    has_prev = true
    pg = g
    pl = sp.end_line
    prev_one = one_line
  }
  let rest = f.take_before(at(0x7fffffff, 0))
  var prev_line: int? = if has_prev { pl } else { none }
  for c in rest {
    match prev_line {
      some(l) => {
        if !c.own_line {
          v.push(fmt.doc.LineSuffix(c.text))
          continue
        }
        if f.blank_between(l, line_of(c.start)) { v.push(fmt.doc.Blank) }
        v.push(fmt.doc.HardLine)
      }
      none => {}
    }
    v.push(text(c.text))
    prev_line = line_of(c.end)
  }
  concat(v)
}

fn item(f: var Fmt, it: ast.Item): fmt.doc.Doc {
  match it {
    Fn(_) => nil()  // clauses are units
    Struct(d) => {
      let kw = match d.raw {
        1 => "raw struct"
        2 => "raw union"
        _ => "struct"
      }
      let head = "{vis(d.public)}{kw} {d.name.name}{generics(d.generics)} "
      let (elems, dangling) = f.seq(
        d.fields.len(),
        d.span.line,
        end(d.span),
        i => d.fields[i].span,
        (g, i) => text("{d.fields[i].name.name}: {ty(d.fields[i].ty)}"),
      )
      let force = d.span.line != d.span.end_line
      concat([text(head), f.bracketed("{{", "}}", elems, dangling, true, Sep.Comma, force)])
    }
    Enum(d) => {
      let head = "{vis(d.public)}enum {d.name.name}{generics(d.generics)} "
      let (elems, dangling) = f.seq(
        d.variants.len(),
        d.span.line,
        end(d.span),
        i => d.variants[i].span,
        (g, i) => variant_doc(d.variants[i]),
      )
      let force = d.span.line != d.span.end_line
      concat([text(head), f.bracketed("{{", "}}", elems, dangling, true, Sep.Comma, force)])
    }
    Shape(d) => {
      let head = "{vis(d.public)}shape {d.name.name}{generics(d.generics)} "
      let (elems, dangling) = f.seq(
        d.methods.len(),
        d.span.line,
        end(d.span),
        i => d.methods[i].span,
        (g, i) => g.clause(d.methods[i], true),
      )
      let force = d.span.line != d.span.end_line
      concat([text(head), f.bracketed("{{", "}}", elems, dangling, true, Sep.FlatComma, force)])
    }
    Test(t) => {
      let i = f.tok_at[start(t.span)]
      let name = f.text_of(f.toks[i + 1].span)
      concat([text("test {name} "), f.block(t.body, false)])
    }
    ExternType(t) => {
      let c_type = f.text_of(f.toks[f.tok_end[end(t.span)]].span)
      text("{vis(t.public)}extern type {t.name.name} = {c_type}")
    }
    Global(g) => {
      let t = match g.ty {
        some(x) => ": {ty(x)}"
        none => ""
      }
      let head = text("{vis(g.public)}{ast.global_kw(g.kind)} {g.name.name}{t}")
      concat([head, f.assign_rhs("=", g.value, cx_inner(), Rhs.Body)])
    }
    RawAssert(a) => concat([text("raw assert "), f.expr(a.expr, cx_inner())])
    Let(c) | Imprint(c) => {
      let kw = if it is Let(_) { "let" } else { "imprint" }
      let t = match c.ty {
        some(x) => ": {ty(x)}"
        none => ""
      }
      let head = text("{vis(c.public)}{kw} {c.name.name}{t}")
      let value = f.assign_rhs("=", c.value, cx_inner(), Rhs.Body)
      concat([head, value])
    }
  }
}

fn variant_doc(v: ast.Variant): fmt.doc.Doc {
  if v.fields.len() == 0 { return text(v.name.name) }
  var fs: [str] = []
  for vf in v.fields {
    match vf.name {
      some(n) => fs.push("{n.name}: {ty(vf.ty)}")
      none => fs.push(ty(vf.ty))
    }
  }
  text("{v.name.name}({fs.join(", ")})")
}

/// A fn clause, header line or shape method.
fn clause(f: var Fmt, c: ast.FnClause, method: bool): fmt.doc.Doc {
  var head = ""
  if !method { head += vis(c.public) }
  if c.export == 1 { head += "export " }
  if c.export == 2 { head += "inline export " }
  if c.body is some(Extern(_)) { head += "extern " }
  if c.is_async { head += "async " }
  head += "fn {c.name.name}{generics(c.generics)}"
  let close = f.close_paren_after(start(c.name.span))
  let (elems, dangling) = f.seq(
    c.params.len(),
    c.name.span.line,
    close,
    i => c.params[i].span,
    (g, i) => text(g.param(c.params[i])),
  )
  let params = f.bracketed("(", ")", elems, dangling, false, Sep.Comma, false)
  var sig = ""
  match c.ret {
    some(t) => sig += ": {ty(t)}"
    none => {}
  }
  if c.effects.len() > 0 { sig += " uses " + c.effects.map(u => u.name).join(", ") }
  var v = [text(head), params, text(sig)]
  let contracts = c.pre.len() > 0 || c.post.len() > 0
  for e in c.pre {
    let d = f.expr(e, cx_head())
    v.push(indent(concat([fmt.doc.HardLine, text("requires "), d])))
  }
  for e in c.post {
    let d = f.expr(e, cx_head())
    v.push(indent(concat([fmt.doc.HardLine, text("ensures "), d])))
  }
  match c.guard {
    some(g) => {
      v.push(text(" when "))
      v.push(f.expr(g, cx_head()))
    }
    none => {}
  }
  match c.body {
    none => {}
    some(Block(b)) => {
      v.push(if contracts { fmt.doc.HardLine } else { text(" ") })
      v.push(f.block(b, false))
    }
    some(Expr(e)) => v.push(f.assign_rhs("=", e, cx_inner(), Rhs.Body))
    some(Extern(_)) => {
      let sym = f.text_of(f.toks[f.tok_end[end(c.span)]].span)
      v.push(text(" = {sym}"))
    }
  }
  concat(v)
}

fn param(f: Fmt, p: ast.Param): str {
  let s = f.pat(p.pat, false)
  match p.ty {
    none => s
    some(t) => "{s}: {if p.var_ { "var " } else { "" }}{ty(t)}"
  }
}

// ---- types and patterns (never broken) ----

fn ty(t: ast.Type): str = match t.kind {
  Named(path, args) => if args.len() == 0 {
    path_str(path)
  } else {
    "{path_str(path)}<{tys(args)}>"
  }
  List(x) => "[{ty(x)}]"
  Map(k, v) => "{{{ty(k)}: {ty(v)}}}"
  Tuple(ts) => "({tys(ts)})"
  Optional(x) => "{ty_operand(x)}?"
  Fallible(ok, none) => "{ty_operand(ok)}!"
  Fallible(ok, some(e)) => "{ty_operand(ok)}!{ty(e)}"
  Any(x) => "any {ty(x)}"
  Fn(params, ret) => "({tys(params)}) => {ty(ret)}"
  Measured(base, u) => "{ty(base)}<{units.text(u)}>"
  Var(x) => "var {ty(x)}"
  Array(x, n) => if n < 0 { "[{ty(x)}; ..]" } else { "[{ty(x)}; {n}]" }
}

/// A type before a `?` or `!` suffix: a function type needs parentheses.
fn ty_operand(t: ast.Type): str = match t.kind {
  Fn(_, _) => "({ty(t)})"
  _ => ty(t)
}

fn tys(ts: [ast.Type]): str = ts.map(t => ty(t)).join(", ")

/// A pattern; `head` means it is in a control-flow head, where a struct pattern needs
/// parentheses.
fn pat(f: Fmt, p: ast.Pat, head: bool): str = match p.kind {
  Wild => "_"
  Bind(n) => n
  Lit(Bool(b), _) => if b { "true" } else { "false" }
  Lit(_, neg) => {
    let s = f.text_of(p.span)
    if neg {
      var t = s
      while t.starts_with("-") { t = t.strip_prefix("-") else t }
      "-" + t.trim_start()
    } else {
      s
    }
  }
  Tuple(ps) => if ps.len() == 1 { "({f.pats(ps)},)" } else { "({f.pats(ps)})" }
  List(h, rest, tail) => {
    var parts: [str] = []
    for x in h { parts.push(f.pat(x, false)) }
    match rest {
      some(r) => match r.pat {
        some(x) => parts.push("..{f.pat(x, false)}")
        none => parts.push("..")
      }
      none => {}
    }
    for x in tail { parts.push(f.pat(x, false)) }
    "[{parts.join(", ")}]"
  }
  Variant(path, none) => path_str(path)
  Variant(path, some(a)) => "{path_str(path)}({f.pats(a)})"
  Struct(path, fields, rest) => {
    var parts: [str] = []
    for fp in fields {
      match fp.pat {
        some(x) => parts.push("{fp.name.name}: {f.pat(x, false)}")
        none => parts.push(fp.name.name)
      }
    }
    if rest { parts.push("..") }
    let s = if parts.len() == 0 {
      "{path_str(path)} {{}}"
    } else {
      "{path_str(path)} {{ {parts.join(", ")} }}"
    }
    if head { "({s})" } else { s }
  }
  Map(es) => {
    let keys = f.map_pattern_keys(p.span, es.len())
    var parts: [str] = []
    for k, key in keys { parts.push("{key}: {f.pat(es[k].1, false)}") }
    "{{{parts.join(", ")}}}"
  }
  StrPrefix(_, rest) => {
    let i = f.tok_at[start(p.span)]
    "{f.text_of(f.toks[i].span)} + {f.pat(rest, false)}"
  }
  Some(x) => "some({f.pat(x, false)})"
  None => "none"
  Ok(x) => "ok({f.pat(x, false)})"
  Err(x) => "err({f.pat(x, false)})"
  Or(ps) => {
    var parts: [str] = []
    for q in ps { parts.push(f.pat(q, head)) }
    parts.join(" | ")
  }
}

fn pats(f: Fmt, ps: [ast.Pat]): str {
  var parts: [str] = []
  for p in ps { parts.push(f.pat(p, false)) }
  parts.join(", ")
}

/// The source text of the `n` literal keys of the map pattern at `sp` (keys have no spans).
fn map_pattern_keys(f: Fmt, sp: diag.Span, n: int): [str] {
  let open = f.tok_at[start(sp)]
  let close = f.mate[open]
  var keys: [str] = []
  var k = open + 1
  while k < close && keys.len() < n {
    if f.toks[k].tok is Minus {
      k += 1
      keys.push("-{f.text_of(f.toks[k].span)}")
    } else {
      keys.push(f.text_of(f.toks[k].span))
    }
    // skip to the next top-level comma
    var depth = 0
    while k < close {
      match f.toks[k].tok {
        LParen | LBracket | LBrace => depth += 1
        RParen | RBracket | RBrace => depth -= 1
        Comma => if depth == 0 { break }
        _ => {}
      }
      k += 1
    }
    k += 1
  }
  keys
}

// ---- blocks and statements ----

/// A block as a group: `{ x }` when it had one statement on one line and fits.
fn block(f: var Fmt, b: ast.Block, force: bool): fmt.doc.Doc = group(f.block_raw(b, force))

/// A block without its own group (an if-chain shares one group across its blocks).
fn block_raw(f: var Fmt, b: ast.Block, force: bool): fmt.doc.Doc {
  let (elems, dangling) = f.seq(
    b.stmts.len(),
    b.span.line,
    end(b.span),
    i => b.stmts[i].span,
    (g, i) => g.expr(b.stmts[i], cx_stmt()),
  )
  if elems.len() == 0 && dangling.len() == 0 { return text("{{}}") }
  let one_line = elems.len() == 1 &&
    elems[0].plain() &&
    dangling.len() == 0 &&
    b.span.line == b.span.end_line &&
    !force
  if one_line {
    return concat([
      text("{{"),
      indent(concat([fmt.doc.Line, elems[0].doc])),
      fmt.doc.Line,
      text("}}"),
    ])
  }
  let body = f.layout(elems, dangling, fmt.doc.HardLine, fmt.doc.HardLine, Sep.None, true)
  concat([text("{{"), indent(body), fmt.doc.HardLine, text("}}")])
}

/// ` = value` (or ` => body`): kept on one line when it fits, else broken after the
/// operator if that makes it fit, else laid out naturally.
fn assign_rhs(f: var Fmt, op: str, value: ast.Expr, cx: Cx, kind: Rhs): fmt.doc.Doc {
  let v = f.expr(value, cx)
  let flat = concat([text(" {op} "), v])
  let breakable = match kind {
    Body => match value.kind {
      Block(_) | If(_, _, _) | Match(_, _) | Loop(_) | While(_, _) | For(_, _, _, _) | Closure(_, _) => false
      _ => true
    }
    Let => match value.kind {
      Binary(_, _, _) | Is(_, _) | Range(_, _, _) | Lit(_) | Measured(_, _) | Interp(_) | Unary(_, _) | Name(_) | Field(_, _) => true
      _ => false
    }
  }
  if !breakable { return flat }
  let after = concat([text(" {op}"), indent(concat([fmt.doc.HardLine, v]))])
  var opts = [(flat, fmt.doc.Fit.Flat)]
  if flat.hard() { opts.push((flat, fmt.doc.Fit.FirstLine)) }
  opts.push((after, fmt.doc.Fit.AllLines))
  opts.push((flat, fmt.doc.Fit.Always))
  fmt.doc.Choice(opts)
}

// ---- expressions ----

fn expr(f: var Fmt, e: ast.Expr, cx: Cx): fmt.doc.Doc {
  let paren = needs_parens(e, cx) ||
    (cx.operand && (level(e) < POSTFIX || greedy(e)) && f.user_parens(e.span))
  if paren {
    let inner = f.expr_inner(e, cx_inner())
    return concat([text("("), inner, text(")")])
  }
  f.expr_inner(e, cx)
}

fn expr_inner(f: var Fmt, e: ast.Expr, cx: Cx): fmt.doc.Doc {
  match e.kind {
    Lit(Bool(b)) => text(if b { "true" } else { "false" })
    Lit(_) | Interp(_) => text(f.text_of(e.span))
    Measured(x, u) => text("{f.text_of(x.span)}<{units.text(u)}>")
    Name(n) => text(n)
    Hole => text("??")
    Try(x) | Unwrap(x) when is_pipe_level(x) => f.pipe(e, cx)
    Pipe(_, _, _) => f.pipe(e, cx)
    Field(_, _) | TupleField(_, _) | Call(_, _) | MethodCall(_, _, _) | Index(_, _) | Slice(_, _, _, _) | Try(_) | Unwrap(_) | OptChain(_, _, _) => f.chain(
      e,
      cx,
    )
    Unary(op, x) => {
      let d = f.expr(x, cx.operand(UNARY, cx.last))
      concat([text(ast.unop_symbol(op)), d])
    }
    Binary(_, _, _) => f.binary(e, cx)
    Range(lo, hi, inclusive) => {
      let l = f.expr(lo, cx.operand(BOR, false))
      let h = f.expr(hi, cx.operand(BOR, cx.last))
      concat([l, text(if inclusive { "..=" } else { ".." }), h])
    }
    Is(x, p) => {
      let d = f.expr(x, cx.operand(IS, false))
      concat([d, text(" is "), text(f.pat(p, cx.head))])
    }
    Else(x, arm) => {
      let d = f.expr(x, cx.operand(PIPE, false))
      let a = f.else_arm(arm, cx.last)
      concat([d, fmt.doc.Tail(concat([text(" else "), a]))])
    }
    Await(x) | Catch(x) | AwaitAny(x) => {
      // the operand is a postfix chain without `?`, `!` or `?.` (or another `await`/`catch`)
      let nested = (x.kind is Await(_) || x.kind is Catch(_)) && !(e.kind is AwaitAny(_))
      let ok = nested || (level(x) == POSTFIX && !greedy(x) && !has_try_spine(x))
      let d = if ok {
        f.expr(x, cx.operand(AWAIT, false))
      } else {
        concat([text("("), f.expr(x, cx_inner()), text(")")])
      }
      let kw = match e.kind {
        Catch(_) => "catch "
        AwaitAny(_) => "await any "
        _ => "await "
      }
      concat([text(kw), d])
    }
    Ref(x) => {
      let d = f.expr(x, cx.operand(AWAIT, false))
      concat([text("&"), d])
    }
    Closure(params, body) => {
      var ps = ""
      let one = params.len() == 1 && params[0].ty is none && !params[0].var_
      if one && (params[0].pat.kind is Bind(_) || params[0].pat.kind is Wild) {
        ps = f.pat(params[0].pat, false)
      } else {
        var parts: [str] = []
        for p in params { parts.push(f.param(p)) }
        ps = "({parts.join(", ")})"
      }
      let bcx = Cx { min: 0, last: cx.last, force: cx.force, ..CX0 }
      let b = f.expr(body, bcx)
      concat([text("{ps} => "), b])
    }
    If(_, _, _) => f.if_chain(e, cx.force)
    Match(scrut, arms) => f.match_expr(e, scrut, arms, cx.force)
    Loop(b) => concat([text("loop "), f.block(b, cx.force)])
    While(cond, body) => {
      let c = f.expr(cond, cx_head())
      concat([text("while "), c, text(" "), f.block(body, cx.force)])
    }
    For(index, p, iter, body) => {
      let i = match index {
        some(x) => "{f.pat(x, true)}, "
        none => ""
      }
      let head = "for {i}{f.pat(p, true)} in "
      let it = f.expr(iter, cx_head())
      concat([text(head), it, text(" "), f.block(body, cx.force)])
    }
    Block(b) => f.block(b, cx.force)
    Let(mutable, p, t, value, els) => {
      let ts = match t {
        some(x) => ": {ty(x)}"
        none => ""
      }
      let head = text("{if mutable { "var" } else { "let" }} {f.pat(p, false)}{ts}")
      let vcx = Cx { min: PIPE, last: els is none, ..CX0 }
      var v = [head, f.assign_rhs("=", value, vcx, Rhs.Let)]
      match els {
        some(arm) => {
          let a = f.else_arm(arm, true)
          v.push(fmt.doc.Tail(concat([text(" else "), a])))
        }
        none => {}
      }
      concat(v)
    }
    Assign(op, target, value) => {
      let t = f.expr(target, cx_inner())
      let o = match op {
        some(x) => "{x.symbol()}="
        none => "="
      }
      let v = f.assign_rhs(o, value, cx_inner(), Rhs.Let)
      concat([t, v])
    }
    Assert(x) => {
      let d = f.expr(x, Cx { min: 1, last: cx.last, ..CX0 })
      concat([text("assert "), d])
    }
    Return(v) | Break(v) => {
      let kw = if e.kind is Return(_) { "return" } else { "break" }
      match v {
        none => text(kw)
        some(x) => {
          let d = f.expr(x, Cx { min: 1, last: cx.last, ..CX0 })
          concat([text("{kw} "), d])
        }
      }
    }
    Continue => text("continue")
    TypeArgs(x, ts) => match x.kind {
      MethodCall(recv, name, xs) => concat([
        text("{f.text_of(recv.span)}.{name.name}<{tys(ts)}>"),
        f.args(xs, x.span),
      ])
      _ => text(f.text_of(e.span))
    }
    FieldSel(n) => text(".{n.name}")
    Peek(x) => {
      let d = if peek_operand_ok(x) {
        f.expr(x, Cx { min: 1, last: cx.last, ..CX0 })
      } else {
        concat([text("("), f.expr(x, cx_inner()), text(")")])
      }
      concat([text("peek "), d])
    }
    Struct(path, fields, base) => {
      let n = fields.len() + if base is none { 0 } else { 1 }
      let (elems, dangling) = f.seq(
        n,
        e.span.line,
        end(e.span),
        i => field_span(fields, base, i),
        (g, i) => g.field_init(fields, base, i),
      )
      let expanded = n > 0 && field_span(fields, base, 0).line > e.span.line
      let lit = f.bracketed("{{", "}}", elems, dangling, true, Sep.Comma, cx.force || expanded)
      concat([text("{path_str(path)} "), lit])
    }
    List(xs) => {
      let (elems, dangling) = f.seq(
        xs.len(),
        e.span.line,
        end(e.span),
        i => xs[i].span,
        (g, i) => g.expr(xs[i], cx_inner()),
      )
      let expanded = xs.len() > 0 && xs[0].span.line > e.span.line
      f.bracketed("[", "]", elems, dangling, false, Sep.Comma, cx.force || expanded)
    }
    Map(es) => {
      let (elems, dangling) = f.seq(
        es.len(),
        e.span.line,
        end(e.span),
        i => es[i].0.span.to(es[i].1.span),
        (g, i) => {
          let k = g.expr(es[i].0, cx_inner())
          let v = g.expr(es[i].1, cx_inner())
          concat([k, text(": "), v])
        },
      )
      let expanded = es.len() > 0 && es[0].0.span.line > e.span.line
      f.bracketed("{{", "}}", elems, dangling, false, Sep.Comma, cx.force || expanded)
    }
    Tuple(xs) => {
      let (elems, dangling) = f.seq(
        xs.len(),
        e.span.line,
        end(e.span),
        i => xs[i].span,
        (g, i) => g.expr(xs[i], cx_inner()),
      )
      f.bracketed("(", ")", elems, dangling, false, Sep.Comma, false)
    }
  }
}

/// The span of the `i`-th element of a struct literal (the fields, then `..base`).
fn field_span(fields: [ast.FieldInit], base: ast.Expr?, i: int): diag.Span {
  if i < fields.len() {
    let fi = fields[i]
    return match fi.value {
      some(v) => fi.name.span.to(v.span)
      none => fi.name.span
    }
  }
  match base {
    some(b) => b.span
    none => diag.NONE
  }
}

/// The `i`-th element of a struct literal.
fn field_init(f: var Fmt, fields: [ast.FieldInit], base: ast.Expr?, i: int): fmt.doc.Doc {
  if i < fields.len() {
    let fi = fields[i]
    return match fi.value {
      some(v) => concat([text("{fi.name.name}: "), f.expr(v, cx_inner())])
      none => text(fi.name.name)
    }
  }
  match base {
    some(b) => concat([text(".."), f.expr(b, cx_inner())])
    none => nil()
  }
}

fn else_arm(f: var Fmt, arm: ast.ElseArm, last: bool): fmt.doc.Doc {
  let cx = Cx { min: 1, last, ..CX0 }
  match arm.binder {
    some(b) => concat([text("{b.name} => "), f.expr(arm.body, cx)])
    // `else x => y` would read `x` as the error binder
    none => if arm.body.kind is Closure(_, _) {
      concat([text("("), f.expr(arm.body, cx_inner()), text(")")])
    } else {
      f.expr(arm.body, cx)
    }
  }
}

/// A chain of same-precedence binary operators, broken after the operators.
fn binary(f: var Fmt, e: ast.Expr, cx: Cx): fmt.doc.Doc {
  let op = match e.kind {
    Binary(o, _, _) => o
    _ => ast.BinOp.Add
  }
  let lvl = bin_level(op)
  match e.kind {
    Binary(Pow, lhs, rhs) => {
      let l = f.expr(lhs, cx.operand(UNARY, false))
      let r = f.expr(rhs, cx.operand(lvl, cx.last))
      return concat([l, text(" ** "), r])
    }
    _ => {}
  }
  // Flatten the left spine: ((a + b) - c) => a, + b, - c.
  var rights: [(ast.BinOp, ast.Expr)] = []
  var cur = e
  var outer = true
  loop {
    let (o, lhs, rhs) = match cur.kind {
      Binary(o, l, r) => (o, l, r)
      _ => break
    }
    if bin_level(o) != lvl || !(outer || (lvl != CMP && !f.user_parens(cur.span))) { break }
    rights.push((o, rhs))
    cur = lhs
    outer = false
  }
  rights = rights.reverse()
  let left_min = if lvl == CMP { CMP + 1 } else { lvl }
  let first = f.cmp_operand(cur, lvl, cx.operand(left_min, false))
  let n = rights.len()
  var tail: [fmt.doc.Doc] = []
  var hugged = [first]
  var last_hard = false
  for i, r in rights {
    let d = f.cmp_operand(r.1, lvl, cx.operand(lvl + 1, i + 1 == n && cx.last))
    let lit = r.1.kind is Struct(_, _, _) || r.1.kind is List(_) || r.1.kind is Map(_)
    last_hard = d.hard() && (huggable(r.1) || lit)
    tail.push(text(" {r.0.symbol()}"))
    tail.push(fmt.doc.Line)
    tail.push(d)
    hugged.push(text(" {r.0.symbol()} "))
    hugged.push(d)
  }
  let normal = group(concat([first, indent(concat(tail))]))
  if !last_hard { return normal }
  // `a == [` ... `]`: a multi-line bracketed last operand stays on the operator's line
  fmt.doc.Choice([(concat(hugged), fmt.doc.Fit.FirstLine), (normal, fmt.doc.Fit.Always)])
}

/// An operand of a binary operator at level `lvl`. A comparison's `&` `^` `|` operand always
/// gets parentheses (E0038), even when the parser's span for it doesn't show the user's.
fn cmp_operand(f: var Fmt, x: ast.Expr, lvl: int, cx: Cx): fmt.doc.Doc {
  if lvl == CMP {
    match x.kind {
      Binary(op, _, _) => {
        let l = bin_level(op)
        if l == BOR || l == BXOR || l == BAND {
          return concat([text("("), f.expr(x, cx_inner()), text(")")])
        }
      }
      _ => {}
    }
  }
  f.expr(x, cx)
}

/// `x |> f(a) |> g()?`: broken before each `|>` when it doesn't fit.
fn pipe(f: var Fmt, e: ast.Expr, cx: Cx): fmt.doc.Doc {
  // steps innermost first: callee, args, the step's span, its `?`/`!` suffix
  var steps: [(ast.Expr, [ast.Expr], diag.Span, str)] = []
  var cur = e
  loop {
    var suffix = ""
    loop {
      match cur.kind {
        Try(x) when is_pipe_level(x) => {
          suffix = "?" + suffix
          cur = x
        }
        Unwrap(x) when is_pipe_level(x) => {
          suffix = "!" + suffix
          cur = x
        }
        _ => break
      }
    }
    match cur.kind {
      Pipe(lhs, callee, args) => {
        steps.push((callee, args, cur.span, suffix))
        cur = lhs
      }
      _ => break
    }
    if !is_pipe_level(cur) || f.user_parens(cur.span) { break }
  }
  steps = steps.reverse()
  // a pipe of several steps written one step per line stays that way
  let kept = steps.len() > 1 && steps.any(s => s.0.span.line > cur.span.end_line)
  let root = f.expr(cur, cx.operand(PIPE + 1, false))
  var segs: [fmt.doc.Doc] = []
  for s in steps {
    let c = text(callee_path(s.0))
    let a = if s.1.len() == 0 && !f.has_call_parens(s.2) { nil() } else { f.args(s.1, s.2) }
    segs.push(concat([text("|> "), c, a, text(s.3)]))
  }
  var flat_v = [root]
  var brk_v: [fmt.doc.Doc] = []
  for s in segs {
    flat_v.push(text(" "))
    flat_v.push(s)
    brk_v.push(fmt.doc.HardLine)
    brk_v.push(s)
  }
  let flat = concat(flat_v)
  let brk = concat([root, indent(concat(brk_v))])
  if kept { return brk }
  var opts = [(flat, fmt.doc.Fit.Flat)]
  if flat.hard() { opts.push((flat, fmt.doc.Fit.FirstLine)) }
  opts.push((brk, fmt.doc.Fit.Always))
  fmt.doc.Choice(opts)
}

/// Did the pipe step ending at `sp` have parentheses (`x |> f()` vs `x |> f`)?
fn has_call_parens(f: Fmt, sp: diag.Span): bool = match f.tok_end.get(end(sp)) {
  some(i) => f.toks[i].tok is RParen
  none => false
}

/// A postfix chain `a.b(x).c[i]?`: broken before each `.method(...)` when it has two or
/// more method calls and doesn't fit.
fn chain(f: var Fmt, e: ast.Expr, cx: Cx): fmt.doc.Doc {
  var segs: [ast.Expr] = []
  var cur = e
  let root = loop {
    let recv = match cur.kind {
      Field(x, _) | TupleField(x, _) | Index(x, _) | Slice(x, _, _, _) => x
      MethodCall(r, _, _) => r
      Call(c, _) => c
      Try(x) | Unwrap(x) when !is_pipe_level(x) => x
      OptChain(x, _, _) => x
      _ => break cur
    }
    segs.push(cur)
    let postfix = level(recv) == POSTFIX &&
      !greedy(recv) &&
      !recv_needs_parens(recv, cur) &&
      !f.user_parens(recv.span)
    if !postfix { break recv }
    cur = recv
  }
  segs = segs.reverse()
  let first = segs[0]
  // `await x?` is `(await x)?`, so an `await` receiver of `?`, `!` or `?.` needs no parens
  let rmin = match first.kind {
    Try(_) | Unwrap(_) | OptChain(_, _, _) => AWAIT
    _ => POSTFIX
  }
  let rcx = cx.operand(rmin, false)
  let root_doc = if recv_needs_parens(root, first) {
    concat([text("("), f.expr(root, cx_inner()), text(")")])
  } else {
    f.expr(root, rcx)
  }
  var parts: [(bool, fmt.doc.Doc)] = []
  // a chain of several calls written one call per line stays that way
  var kept = false
  for s in segs {
    match s.kind {
      MethodCall(r, name, _) => if name.span.line > r.span.end_line { kept = true }
      _ => {}
    }
  }
  for s in segs {
    let d = match s.kind {
      Field(_, name) => text(".{name.name}")
      TupleField(_, index) => text(".{index}")
      MethodCall(_, name, args) => concat([text(".{name.name}"), f.args(args, s.span)])
      Call(_, args) => f.args(args, s.span)
      Index(_, index) => concat([text("["), f.expr(index, cx_inner()), text("]")])
      Slice(_, lo, hi, inclusive) => {
        let l = f.expr(lo, cx_inner().operand(BOR, false))
        let h = f.expr(hi, cx_inner().operand(BOR, true))
        concat([text("["), l, text(if inclusive { "..=" } else { ".." }), h, text("]")])
      }
      Try(_) => text("?")
      Unwrap(_) => text("!")
      OptChain(_, name, args) => match args {
        none => text("?.{name.name}")
        some(a) => concat([text("?.{name.name}"), f.args(a, s.span)])
      }
      _ => nil()
    }
    parts.push((s.kind is MethodCall(_, _, _), d))
  }
  var calls = 0
  for p in parts {
    if p.0 { calls += 1 }
  }
  if calls < 3 && !kept {
    var v = [root_doc]
    for p in parts { v.push(p.1) }
    return concat(v)
  }
  // head = root + segments before the first method call; then one group per call
  var head = [root_doc]
  var groups: [[fmt.doc.Doc]] = []
  for p in parts {
    if p.0 {
      groups.push([p.1])
    } else if groups.len() > 0 {
      groups[groups.len() - 1].push(p.1)
    } else {
      head.push(p.1)
    }
  }
  var flat_v = head
  var brk_v: [fmt.doc.Doc] = []
  for g in groups {
    for d in g { flat_v.push(d) }
    brk_v.push(fmt.doc.HardLine)
    brk_v.push(concat(g))
  }
  let flat = concat(flat_v)
  let brk = concat([concat(head), indent(concat(brk_v))])
  if kept { return brk }
  var opts = [(flat, fmt.doc.Fit.Flat)]
  if flat.hard() { opts.push((flat, fmt.doc.Fit.FirstLine)) }
  opts.push((brk, fmt.doc.Fit.Always))
  fmt.doc.Choice(opts)
}

/// Call arguments `(a, b)` ending at `close`; the last one is hugged (`f(x => {` ...
/// `})`) when it is a closure with a block body or a struct, list or map literal.
fn args(f: var Fmt, args: [ast.Expr], sp: diag.Span): fmt.doc.Doc {
  let close = end(sp)
  // `f("a long string")`: breaking would not make it fit
  if args.len() == 1 &&
    (args[0].kind is Lit(Str(_)) || args[0].kind is Interp(_)) &&
    !f.comments_in(start(sp), close) {
    return concat([text("("), f.expr(args[0], cx_inner()), text(")")])
  }
  let quiet = !f.comments_in(start(sp), close)
  let (elems, dangling) = f.seq(
    args.len(),
    sp.line,
    close,
    i => args[i].span,
    (g, i) => g.expr(args[i], cx_inner()),
  )
  let n = args.len()
  let hug = quiet && n > 0 && huggable(args[n - 1])
  if !hug { return f.bracketed("(", ")", elems, dangling, false, Sep.Comma, false) }
  var flat_parts: [fmt.doc.Doc] = []
  for k in 0..n - 1 { flat_parts.push(elems[k].doc) }
  if flat_parts.any(d => d.hard()) {
    return f.bracketed("(", ")", elems, dangling, false, Sep.Comma, false)
  }
  let last = f.expr(args[n - 1], Cx { force: true, ..cx_inner() })
  flat_parts.push(last)
  var hugged = [text("(")]
  for i, d in flat_parts {
    if i > 0 { hugged.push(text(", ")) }
    hugged.push(d)
  }
  hugged.push(text(")"))
  let plain = f.bracketed("(", ")", elems, dangling, false, Sep.Comma, false)
  let expanded = match plain {
    Group(d, _) => broken(d)
    d => d
  }
  fmt.doc.Choice([
    (plain, fmt.doc.Fit.Flat),
    (concat(hugged), fmt.doc.Fit.FirstLine),
    (expanded, fmt.doc.Fit.Always),
  ])
}

/// `if a { x } else if b { y } else { z }`: one group, so the blocks break together.
fn if_chain(f: var Fmt, e: ast.Expr, force: bool): fmt.doc.Doc {
  var v: [fmt.doc.Doc] = []
  var cur = e
  loop {
    let (cond, then, els) = match cur.kind {
      If(c, t, x) => (c, t, x)
      _ => break
    }
    v.push(text("if "))
    v.push(f.expr(cond, cx_head()))
    v.push(text(" "))
    v.push(f.block_raw(then, force))
    let x = els else break
    match x.kind {
      If(_, _, _) => {
        v.push(text(" else "))
        cur = x
      }
      Block(b) => {
        v.push(text(" else "))
        v.push(f.block_raw(b, force))
        break
      }
      // else is a block or an if
      _ => break
    }
  }
  group(concat(v))
}

fn match_expr(f: var Fmt, e: ast.Expr, scrut: ast.Expr, arms: [ast.Arm], force: bool): fmt.doc.Doc {
  let s = f.expr(scrut, cx_head())
  let (elems, dangling) = f.seq(
    arms.len(),
    e.span.line,
    end(e.span),
    i => arms[i].span,
    (g, i) => g.arm(arms[i]),
  )
  let forced = force || e.span.line != e.span.end_line
  let body = f.bracketed("{{", "}}", elems, dangling, true, Sep.FlatComma, forced)
  concat([text("match "), s, text(" "), body])
}

fn arm(f: var Fmt, a: ast.Arm): fmt.doc.Doc {
  var v = [text(f.pat(a.pat, false))]
  match a.guard {
    some(g) => {
      v.push(text(" when "))
      v.push(f.expr(g, Cx { min: 1, guard: true, ..CX0 }))
    }
    none => {}
  }
  v.push(f.assign_rhs("=>", a.body, cx_stmt(), Rhs.Body))
  concat(v)
}

/// How a right-hand side may break after its operator.
enum Rhs {
  /// A fn `=` body, const value or match-arm body: anything but block-like expressions.
  Body,
  /// A `let` or assignment value: only operator expressions and plain values.
  Let,
}

// ---- precedence ----

// Binding levels, loosest first. An operand whose level is below what its position needs gets
// parentheses.
let STMT = 0
let ELSE = 1
let PIPE = 2
let OR = 3
let AND = 4
let IS = 5
let CMP = 6
let RANGE = 7
let BOR = 8
let BXOR = 9
let BAND = 10
let SHIFT = 11
let ADD = 12
let MUL = 13
let POW = 14
let UNARY = 15
let AWAIT = 16
let POSTFIX = 17

/// The context an expression is printed in.
struct Cx {
  /// The loosest level allowed without parentheses.
  min: int,
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

/// Rust's `Cx::default()`.
let CX0 = Cx { min: 0, last: false, head: false, guard: false, operand: false, force: false }

fn cx_stmt(): Cx = Cx { min: STMT, last: true, ..CX0 }

fn cx_inner(): Cx = Cx { min: ELSE, last: true, ..CX0 }

fn cx_head(): Cx = Cx { min: ELSE, last: false, head: true, ..CX0 }

/// An operand position: head and guard restrictions carry over (no brackets in between).
fn operand(cx: Cx, min: int, last: bool): Cx =
  Cx { min, last, head: cx.head, guard: cx.guard, operand: true, force: false }

fn bin_level(op: ast.BinOp): int = match op {
  Or => OR
  And => AND
  Eq | Ne | Lt | Le | Gt | Ge => CMP
  Add | Sub | AddWrap | SubWrap => ADD
  Mul | Div | Rem | MulWrap => MUL
  Pow => POW
  BitOr => BOR
  BitXor => BXOR
  BitAnd => BAND
  Shl | Shr => SHIFT
}

fn level(e: ast.Expr): int = match e.kind {
  Let(_, _, _, _, _) | Assign(_, _, _) | Assert(_) => STMT
  Else(_, _) => ELSE
  Pipe(_, _, _) => PIPE
  Try(x) | Unwrap(x) when is_pipe_level(x) => PIPE
  Binary(op, _, _) => bin_level(op)
  Is(_, _) => IS
  Range(_, _, _) => RANGE
  Unary(_, _) | Ref(_) => UNARY
  Await(_) | Catch(_) | AwaitAny(_) => AWAIT
  _ => POSTFIX
}

/// Forms that extend as far right as they can, so nothing may follow them.
fn greedy(e: ast.Expr): bool = match e.kind {
  Closure(_, _) | Return(_) | Break(_) | Peek(_) => true
  _ => false
}

fn is_pipe_level(e: ast.Expr): bool = match e.kind {
  Pipe(_, _, _) => true
  Try(x) | Unwrap(x) => is_pipe_level(x)
  _ => false
}

fn needs_parens(e: ast.Expr, cx: Cx): bool {
  if level(e) < cx.min || (greedy(e) && !cx.last) { return true }
  match e.kind {
    Struct(_, _, _) | Else(_, _) => cx.head
    Closure(_, _) => cx.guard
    // `if c { a } else b`: the `else` would join the `if`
    If(_, _, els) => !cx.last && els is none
    _ => false
  }
}

/// Does `recv` need parentheses as the receiver of the postfix `seg`? `x?.f` would lex as
/// `?.`, and `await x.f` would await `x.f`.
fn recv_needs_parens(recv: ast.Expr, seg: ast.Expr): bool {
  let dotted = match seg.kind {
    Field(_, _) | MethodCall(_, _, _) | TupleField(_, _) | OptChain(_, _, _) => true
    _ => false
  }
  match recv.kind {
    Try(_) | Hole => dotted
    Await(_) | Catch(_) | AwaitAny(_) => match seg.kind {
      Try(_) | Unwrap(_) | OptChain(_, _, _) => false
      _ => true
    }
    _ => false
  }
}

/// Does the postfix chain of `e` contain `?`, `!` or `?.` (an `await` operand can't)?
fn has_try_spine(e: ast.Expr): bool = match e.kind {
  Field(x, _) | TupleField(x, _) | Index(x, _) | Slice(x, _, _, _) => has_try_spine(x)
  MethodCall(r, _, _) => has_try_spine(r)
  Call(c, _) => has_try_spine(c)
  Try(_) | Unwrap(_) | OptChain(_, _, _) => true
  _ => false
}

/// Can `peek e` start with `e` as printed (`peek -x` would be the name `peek` minus `x`)?
fn peek_operand_ok(e: ast.Expr): bool = match e.kind {
  Binary(_, x, _) | Is(x, _) | Range(x, _, _) | Else(x, _) | Pipe(x, _, _) | Field(x, _) | TupleField(x, _) | Index(x, _) | Slice(x, _, _, _) | MethodCall(x, _, _) | Call(x, _) | Try(x) | Unwrap(x) | OptChain(x, _, _) => peek_operand_ok(
    x,
  )
  Lit(_) | Measured(_, _) | Interp(_) | Name(_) | If(_, _, _) | Match(_, _) | Await(_) | Catch(_) | AwaitAny(_) | Tuple(_) | List(_) | Struct(_, _, _) => true
  Closure(_, _) => true
  _ => false
}

/// A last argument that can be hugged: `f(x => {`, `f(Point {`, `f([`.
fn huggable(e: ast.Expr): bool = match e.kind {
  Closure(_, body) => match body.kind {
    Block(b) => b.stmts.len() > 0
    Match(_, _) | Struct(_, _, _) => true
    _ => huggable_lit(body)
  }
  _ => huggable_lit(e)
}

fn huggable_lit(e: ast.Expr): bool = match e.kind {
  Struct(_, fields, base) => fields.len() > 0 || base != none
  List(xs) => xs.len() > 0
  Map(es) => es.len() > 0
  _ => false
}

/// A pipe step is a name or path.
fn callee_path(e: ast.Expr): str = match e.kind {
  Name(n) => n
  Field(x, name) => "{callee_path(x)}.{name.name}"
  _ => ""
}

fn item_span(i: ast.Item): diag.Span = match i {
  Fn(g) => match g.header {
    some(h) => h.span
    none => g.clauses[0].span
  }
  Struct(d) => d.span
  Enum(d) => d.span
  Shape(d) => d.span
  Test(d) => d.span
  Let(d) | Imprint(d) => d.span
  ExternType(d) => d.span
  Global(d) => d.span
  RawAssert(a) => a.span
}

fn vis(public: bool): str = if public { "pub " } else { "" }

fn path_str(p: [ast.Ident]): str = p.map(i => i.name).join(".")

fn generics(gs: [ast.Generic]): str {
  if gs.len() == 0 { return "" }
  var parts: [str] = []
  for g in gs {
    if g.bounds.len() == 0 {
      parts.push(g.name.name)
    } else {
      parts.push("{g.name.name}: {g.bounds.map(b => type_dump(b)).join(" + ")}")
    }
  }
  "<{parts.join(", ")}>"
}

/// ast.rs's `type_dump`: `ty` without the parentheses around a function type before `?`/`!`.
fn type_dump(t: ast.Type): str = match t.kind {
  Named(path, args) => if args.len() == 0 {
    path_str(path)
  } else {
    "{path_str(path)}<{args.map(a => type_dump(a)).join(", ")}>"
  }
  List(x) => "[{type_dump(x)}]"
  Map(k, v) => "{{{type_dump(k)}: {type_dump(v)}}}"
  Tuple(ts) => "({ts.map(x => type_dump(x)).join(", ")})"
  Optional(x) => "{type_dump(x)}?"
  Fallible(ok, none) => "{type_dump(ok)}!"
  Fallible(ok, some(e)) => "{type_dump(ok)}!{type_dump(e)}"
  Any(x) => "any {type_dump(x)}"
  Fn(params, ret) => "({params.map(x => type_dump(x)).join(", ")}) => {type_dump(ret)}"
  Measured(base, u) => "{type_dump(base)}<{units.text(u)}>"
  Var(x) => "var {type_dump(x)}"
  Array(x, n) => if n < 0 { "[{type_dump(x)}; ..]" } else { "[{type_dump(x)}; {n}]" }
}

/// Text and HTML templates with Jinja-style syntax: `{{ expr }}` output (HTML-escaped in `html`
/// templates), `{% if %}`/`{% elif %}`/`{% else %}`, `{% for x in xs %}` (with `loop` and an
/// `{% else %}` for empty lists), `{% set %}`, `{% include "name" %}`, `{% raw %}`, `{# comments #}`,
/// filters (`{{ name | upper }}`) and `-` whitespace control. A tag or comment alone on its line
/// takes the whole line with it, so block tags leave no blank lines. Undefined variables are
/// errors (use `| default(x)`). Data comes from any `Data` value, usually a struct or map.
/// Pure: no effects.

pub enum TplErr {
  Syntax(msg: str, line: int, col: int),      // malformed template text
  Undefined(name: str, line: int, col: int),  // a variable, key or index that isn't there
  Type(msg: str, line: int, col: int),        // an operation on the wrong kind of value
  NoPartial(name: str, line: int, col: int),  // `{% include %}` of a name not given to `render`
}

pub fn message(e: TplErr): str = match e {
  Syntax(m, l, c) => "{l}:{c}: {m}"
  Undefined(n, l, c) => "{l}:{c}: `{n}` is undefined (use `| default(...)` if it may be missing)"
  Type(m, l, c) => "{l}:{c}: {m}"
  NoPartial(n, l, c) => "{l}:{c}: no partial named \"{n}\" was passed to render"
}

/// A parsed template. Parse once, render many times.
pub struct Template { nodes: [Node], escape: bool }

struct Branch { cond: Expr, body: [Node] }

enum Node {
  Text(s: str),
  Out(e: Expr, line: int, col: int),
  If(branches: [Branch], other: [Node], line: int, col: int),
  For(key: str?, name: str, iter: Expr, body: [Node], other: [Node], line: int, col: int),
  Set(name: str, e: Expr, line: int, col: int),
  Include(name: str, line: int, col: int),
}

enum Expr {
  Lit(v: Value),
  Var(name: str),
  Attr(e: Expr, name: str),
  Index(e: Expr, k: Expr),
  Neg(e: Expr),
  Not(e: Expr),
  Bin(op: str, a: Expr, b: Expr),
  Filter(e: Expr, name: str, args: [Expr]),
  ListE(xs: [Expr]),
}

/// Parses an HTML template: every `{{ }}` output is HTML-escaped unless filtered with `raw`.
pub fn html(src: str): Template!TplErr = Template { nodes: parse_nodes(src)?, escape: true }

/// Parses a plain-text template: output is inserted as is.
pub fn text(src: str): Template!TplErr = Template { nodes: parse_nodes(src)?, escape: false }

/// Renders `t` with `data`'s fields (or keys) as variables. `data` is a struct, a map or a
/// `Value.Map` (`Null` gives no variables).
pub fn render<T: Data>(t: Template, data: T): str!TplErr = render(t, data, {})

/// As `render`, with named templates for `{% include "name" %}`.
pub fn render<T: Data>(t: Template, data: T, partials: {str: Template}): str!TplErr {
  let root = match to_value(data) {
    Map(m) => m
    Null => {}
    v => fail(Type("render needs a struct or map, got {kind(v)}", 1, 1))
  }
  var c = Ctx { scopes: [root], at: [], of: [], partials, escape: t.escape, depth: 0 }
  var out = ""
  run(t.nodes, &c, &out)?
  out
}

/// Parses and renders in one step, as an HTML template.
pub fn render_html<T: Data>(src: str, data: T): str!TplErr = render(html(src)?, data)

/// Parses and renders in one step, as a plain-text template.
pub fn render_text<T: Data>(src: str, data: T): str!TplErr = render(text(src)?, data)

/// `s` with `& < > " '` replaced by HTML entities.
pub fn escape(s: str): str {
  var out = s
  if s.contains("&") { out = out.replace("&", "&amp;") }
  if s.contains("<") { out = out.replace("<", "&lt;") }
  if s.contains(">") { out = out.replace(">", "&gt;") }
  if s.contains("\"") { out = out.replace("\"", "&quot;") }
  if s.contains("'") { out = out.replace("'", "&#39;") }
  out
}

// ---- lexing: text, {{ out }}, {% tag %}, {# comment #} ----

enum Kind { KText, KOut, KTag, KCmt }

// A piece of the template. Text is the chars `a..b` of the source until `trim_segs` has settled
// its edges and fills in `s`; for the others `s` is the trimmed inside of the tag.
struct Seg { kind: Kind, s: str, line: int, col: int, lt: bool, rt: bool, a: int, b: int }

fn text_seg(a: int, b: int, line: int, col: int): Seg =
  Seg { kind: KText, s: "", line, col, lt: false, rt: false, a, b }

fn tag_seg(kind: Kind, s: str, line: int, col: int, lt: bool, rt: bool): Seg =
  Seg { kind, s, line, col, lt, rt, a: 0, b: 0 }

let ENDRAW = "endraw".chars()

// Whether `cs` has the chars `lit` at `i`.
fn has_at(cs: [char], i: int, lit: [char]): bool {
  if i + lit.len() > cs.len() { return false }
  for k, c in lit {
    if cs[i + k] != c { return false }
  }
  true
}

fn lex(cs: [char]): [Seg]!TplErr {
  let n = cs.len()
  var segs: [Seg] = []
  var i = 0
  var line = 1
  var ls = 0  // index of the first char of `line`; the column of index k is k - ls + 1
  while i < n {
    // text up to the next `{{`, `{%` or `{#`
    let a = i
    let (bl, bc) = (line, i - ls + 1)
    var o = '\0'
    while i < n {
      let c = cs[i]
      if c == '{' && i + 1 < n {
        o = cs[i + 1]
        if o == '{' || o == '%' || o == '#' { break }
      } else if c == '\n' {
        line += 1
        ls = i + 1
      }
      i += 1
    }
    if i > a { segs.push(text_seg(a, i, bl, bc)) }
    if i >= n { break }
    let (tl, tc) = (line, i - ls + 1)
    let close = if o == '{' { '}' } else { o }
    let kind = if o == '{' { KOut } else if o == '%' { KTag } else { KCmt }
    i += 2
    let lt = i < n && cs[i] == '-'
    if lt { i += 1 }
    let st = i
    var end = -1  // where the closing marker starts
    var rt = false
    while i < n {
      let d = cs[i]
      if d == '-' && i + 2 < n && cs[i + 1] == close && cs[i + 2] == '}' {
        rt = true
        end = i
        i += 3
        break
      }
      if d == close && i + 1 < n && cs[i + 1] == '}' {
        end = i
        i += 2
        break
      }
      if kind != KCmt && (d == '"' || d == '\'') {
        // a quoted string may contain `}}` or `%}`
        i += 1
        while i < n && cs[i] != d { i += if cs[i] == '\\' && i + 1 < n { 2 } else { 1 } }
        if i < n { i += 1 }
        continue
      }
      i += 1
    }
    if end < 0 {
      let what = match kind { KOut => "{{{{", KTag => "{{%", _ => "{{#" }
      fail(Syntax("`{what}` is never closed", tl, tc))
    }
    for k in st..i {
      if cs[k] == '\n' {
        line += 1
        ls = k + 1
      }
    }
    let s = str(cs[st..end]).trim()
    if kind != KTag || s != "raw" {
      segs.push(tag_seg(kind, s, tl, tc, lt, rt))
      continue
    }
    // after `{% raw %}`: everything up to `{% endraw %}` as literal text, then the end tag
    segs.push(tag_seg(KCmt, "", tl, tc, lt, rt))
    let ra = i
    let (rl, rc) = (line, i - ls + 1)
    var closed = false
    while i < n {
      if cs[i] == '{' && i + 1 < n && cs[i + 1] == '%' {
        var k = i + 2
        let elt = k < n && cs[k] == '-'
        if elt { k += 1 }
        while k < n && is_blank(cs[k]) { k += 1 }
        if has_at(cs, k, ENDRAW) {
          k += 6
          while k < n && is_blank(cs[k]) { k += 1 }
          let ert = k < n && cs[k] == '-'
          if ert { k += 1 }
          if k + 1 < n && cs[k] == '%' && cs[k + 1] == '}' {
            segs.push(text_seg(ra, i, rl, rc))
            segs.push(tag_seg(KCmt, "", line, i - ls + 1, elt, ert))
            i = k + 2
            closed = true
            break
          }
        }
      }
      if cs[i] == '\n' {
        line += 1
        ls = i + 1
      }
      i += 1
    }
    if !closed { fail(Syntax("`{{% raw %}}` without `{{% endraw %}}`", tl, tc)) }
  }
  segs
}

fn is_blank(c: char): bool = c == ' ' || c == '\t'

fn is_text(s: Seg): bool = s.kind == KText

// Whether the text `cs[a..b]` ends in a line of only blanks (`whole`: or is only blanks).
fn blank_tail(cs: [char], a: int, b: int, whole: bool): bool {
  var k = b
  while k > a && is_blank(cs[k - 1]) { k -= 1 }
  if k > a { cs[k - 1] == '\n' } else { whole }
}

// Whether the text `cs[a..b]` starts with a line of only blanks (`whole`: or is only blanks).
fn blank_head(cs: [char], a: int, b: int, whole: bool): bool {
  var k = a
  while k < b && (is_blank(cs[k]) || cs[k] == '\r') { k += 1 }
  if k < b { cs[k] == '\n' } else { whole }
}

// A `{% %}` or `{# #}` that is the only thing on its line removes the line (judged on the
// original text, so standalone tags on consecutive lines all count); then `-` markers trim all
// whitespace on their side. Text segments get their final string here.
fn trim_segs(cs: [char], input: [Seg]): [Seg] {
  var segs = input
  let n = segs.len()
  for j in 0..n {
    let k = segs[j].kind
    // an include is output, like `{{ }}`: it keeps its line
    if k == KText || k == KOut || segs[j].s.starts_with("include ") { continue }
    let prev_ok = if j == 0 {
      true
    } else if !is_text(input[j - 1]) {
      false
    } else {
      blank_tail(cs, input[j - 1].a, input[j - 1].b, j - 1 == 0)
    }
    if !prev_ok { continue }
    let next_ok = if j == n - 1 {
      true
    } else if !is_text(input[j + 1]) {
      false
    } else {
      blank_head(cs, input[j + 1].a, input[j + 1].b, j + 1 == n - 1)
    }
    if !next_ok { continue }
    if j > 0 {
      // drop the blanks before the tag
      var b = segs[j - 1].b
      while b > segs[j - 1].a && is_blank(cs[b - 1]) { b -= 1 }
      segs[j - 1].b = b
    }
    if j < n - 1 {
      // drop the rest of the tag's line
      var a = segs[j + 1].a
      let b = segs[j + 1].b
      while a < b && cs[a] != '\n' { a += 1 }
      segs[j + 1].a = if a < b { a + 1 } else { b }
    }
  }
  for j in 0..n {
    if segs[j].lt && j > 0 && is_text(segs[j - 1]) {
      var b = segs[j - 1].b
      while b > segs[j - 1].a && cs[b - 1].is_space() { b -= 1 }
      segs[j - 1].b = b
    }
    if segs[j].rt && j < n - 1 && is_text(segs[j + 1]) {
      var a = segs[j + 1].a
      while a < segs[j + 1].b && cs[a].is_space() { a += 1 }
      segs[j + 1].a = a
    }
  }
  for j in 0..n {
    if is_text(segs[j]) && segs[j].b > segs[j].a { segs[j].s = str(cs[segs[j].a..segs[j].b]) }
  }
  segs
}

// ---- tokens inside {{ }} and {% %} ----

enum Tok { TName(s: str), TStr(s: str), TInt(i: int), TFloat(f: float), TSym(s: str), TEnd }

fn is_name_start(c: char): bool = c.is_alpha() || c == '_'
fn is_name_char(c: char): bool = c.is_alpha() || c.is_digit() || c == '_'

fn tokens(s: str, line: int, col: int): [Tok]!TplErr {
  let cs = s.chars()
  let n = cs.len()
  var ts: [Tok] = []
  var i = 0
  while i < n {
    let c = cs[i]
    if c.is_space() {
      i += 1
    } else if is_name_start(c) {
      let st = i
      while i < cs.len() && is_name_char(cs[i]) { i += 1 }
      ts.push(TName(str(cs[st..i])))
    } else if c.is_digit() {
      let st = i
      while i < cs.len() && cs[i].is_digit() { i += 1 }
      if i + 1 < cs.len() && cs[i] == '.' && cs[i + 1].is_digit() {
        i += 1
        while i < cs.len() && cs[i].is_digit() { i += 1 }
        ts.push(TFloat(float.parse(str(cs[st..i]))!))
      } else {
        let n = int.parse(
          str(cs[st..i]),
        ) else fail(Syntax("number too large: {str(cs[st..i])}", line, col))
        ts.push(TInt(n))
      }
    } else if c == '"' || c == '\'' {
      i += 1
      var b: [char] = []
      var closed = false
      while i < cs.len() {
        let d = cs[i]
        if d == c {
          closed = true
          i += 1
          break
        }
        if d == '\\' && i + 1 < cs.len() {
          i += 1
          b.push(match cs[i] { 'n' => '\n', 't' => '\t', 'r' => '\r', e => e })
        } else {
          b.push(d)
        }
        i += 1
      }
      if !closed { fail(Syntax("unclosed string literal", line, col)) }
      ts.push(TStr(str(b)))
    } else {
      if i + 1 < n && cs[i + 1] == '=' && (c == '=' || c == '!' || c == '<' || c == '>') {
        ts.push(TSym(match c { '=' => "==", '!' => "!=", '<' => "<=", _ => ">=" }))
        i += 2
      } else {
        let sym = match c {
          '(' => "("
          ')' => ")"
          '[' => "["
          ']' => "]"
          ',' => ","
          '.' => "."
          '|' => "|"
          '+' => "+"
          '-' => "-"
          '*' => "*"
          '/' => "/"
          '%' => "%"
          '<' => "<"
          '>' => ">"
          '=' => "="
          _ => fail(Syntax("unexpected `{c}`", line, col))
        }
        ts.push(TSym(sym))
        i += 1
      }
    }
  }
  ts
}

// ---- expressions ----

struct P { ts: [Tok], i: int, line: int, col: int }

fn peek(p: P): Tok = p.ts.get(p.i) else TEnd

fn next(p: var P): Tok {
  let t = peek(p)
  p.i += 1
  t
}

// The symbol or the name at the cursor, "" when it is something else.
fn sym(p: P): str = match p.ts.get(p.i) {
  some(TSym(s)) => s
  _ => ""
}

fn word(p: P): str = match p.ts.get(p.i) {
  some(TName(s)) => s
  _ => ""
}

fn is_sym(p: P, s: str): bool = match p.ts.get(p.i) {
  some(TSym(x)) => x == s
  _ => false
}

fn is_word(p: P, s: str): bool = match p.ts.get(p.i) {
  some(TName(x)) => x == s
  _ => false
}

fn show_tok(t: Tok): str = match t {
  TName(s) => "`{s}`"
  TStr(s) => "a string"
  TInt(i) => "`{i}`"
  TFloat(f) => "`{f}`"
  TSym(s) => "`{s}`"
  TEnd => "the end of the tag"
}

fn err_at(p: P, want: str): TplErr =
  Syntax("expected {want}, found {show_tok(peek(p))}", p.line, p.col)

fn expect_sym(p: var P, s: str): ()!TplErr {
  if !p.is_sym(s) { fail(err_at(p, "`{s}`")) }
  p.i += 1
}

fn name(p: var P): str!TplErr = match peek(p) {
  TName(s) => {
    p.i += 1
    s
  }
  _ => fail(err_at(p, "a name"))
}

fn expr(p: var P): Expr!TplErr {
  var a = and_e(&p)?
  while p.is_word("or") {
    p.i += 1
    a = Bin("or", a, and_e(&p)?)
  }
  a
}

fn and_e(p: var P): Expr!TplErr {
  var a = not_e(&p)?
  while p.is_word("and") {
    p.i += 1
    a = Bin("and", a, not_e(&p)?)
  }
  a
}

fn not_e(p: var P): Expr!TplErr {
  if p.is_word("not") {
    p.i += 1
    return Not(not_e(&p)?)
  }
  cmp(&p)
}

fn cmp(p: var P): Expr!TplErr {
  let a = add(&p)?
  let op = match peek(p) {
    TSym("==") => "=="
    TSym("!=") => "!="
    TSym("<") => "<"
    TSym("<=") => "<="
    TSym(">") => ">"
    TSym(">=") => ">="
    TName("in") => "in"
    TName("not") => "not in"
    _ => return a
  }
  p.i += 1
  if op == "not in" {
    if !p.is_word("in") { fail(err_at(p, "`in` after `not`")) }
    p.i += 1
  }
  Bin(op, a, add(&p)?)
}

fn add(p: var P): Expr!TplErr {
  var a = mul(&p)?
  loop {
    let op = sym(p)
    if op != "+" && op != "-" { break }
    p.i += 1
    a = Bin(op, a, mul(&p)?)
  }
  a
}

fn mul(p: var P): Expr!TplErr {
  var a = unary(&p)?
  loop {
    let op = sym(p)
    if op != "*" && op != "/" && op != "%" { break }
    p.i += 1
    a = Bin(op, a, unary(&p)?)
  }
  a
}

fn unary(p: var P): Expr!TplErr {
  if p.is_sym("-") {
    p.i += 1
    return Neg(unary(&p)?)
  }
  postfix(&p)
}

fn postfix(p: var P): Expr!TplErr {
  var e = primary(&p)?
  loop {
    let op = sym(p)
    if op == "." {
      p.i += 1
      e = match peek(p) {
        TInt(i) => {
          p.i += 1
          Index(e, Lit(Int(i)))
        }
        _ => Attr(e, name(&p)?)
      }
    } else if op == "[" {
      p.i += 1
      let k = expr(&p)?
      expect_sym(&p, "]")?
      e = Index(e, k)
    } else if op == "|" {
      p.i += 1
      let f = name(&p)?
      var args: [Expr] = []
      if p.is_sym("(") {
        p.i += 1
        args = list(&p, ")")?
      }
      e = Filter(e, f, args)
    } else {
      break
    }
  }
  e
}

// Comma-separated expressions up to `close` (consumed); a trailing comma is allowed.
fn list(p: var P, close: str): [Expr]!TplErr {
  var xs: [Expr] = []
  while !p.is_sym(close) {
    xs.push(expr(&p)?)
    if !p.is_sym(",") { break }
    p.i += 1
  }
  expect_sym(&p, close)?
  xs
}

fn primary(p: var P): Expr!TplErr = match next(&p) {
  TStr(s) => Lit(Str(s))
  TInt(i) => Lit(Int(i))
  TFloat(f) => Lit(Float(f))
  TName("true") => Lit(Bool(true))
  TName("false") => Lit(Bool(false))
  TName("none") => Lit(Null)
  TName("null") => Lit(Null)
  TName(s) => Var(s)
  TSym("(") => {
    let e = expr(&p)?
    expect_sym(&p, ")")?
    e
  }
  TSym("[") => ListE(list(&p, "]")?)
  _ => {
    p.i -= 1
    fail(err_at(p, "a value"))
  }
}

fn parse_expr(s: str, line: int, col: int): Expr!TplErr {
  var p = P { ts: tokens(s, line, col)?, i: 0, line, col }
  if p.ts.len() == 0 { fail(Syntax("empty `{{{{ }}}}`", line, col)) }
  let e = expr(&p)?
  if peek(p) != TEnd { fail(err_at(p, "the end of the expression")) }
  e
}

// ---- statements ----

struct NP { segs: [Seg], i: int }

fn parse_nodes(src: str): [Node]!TplErr {
  let cs = src.chars()
  var np = NP { segs: trim_segs(cs, lex(cs)?), i: 0 }
  let (nodes, end, _) = block(&np)?
  if end != "" {
    let s = np.segs[np.i - 1]
    fail(Syntax("`{{% {end} %}}` without an opening tag", s.line, s.col))
  }
  nodes
}

// Nodes up to an `elif`/`else`/`end*` tag or the end of input. Returns the nodes, the ending
// keyword ("" at the end of input) and the rest of that tag's tokens.
fn block(np: var NP): ([Node], str, P)!TplErr {
  var out: [Node] = []
  while np.i < np.segs.len() {
    let s = np.segs[np.i]
    np.i += 1
    match s.kind {
      KText => if s.s != "" { out.push(Text(s.s)) }
      KCmt => {}
      KOut => out.push(Out(parse_expr(s.s, s.line, s.col)?, s.line, s.col))
      KTag => {
        var p = P { ts: tokens(s.s, s.line, s.col)?, i: 0, line: s.line, col: s.col }
        let kw = name(&p) else fail(Syntax("empty tag `{{% %}}`", s.line, s.col))
        match kw {
          "if" => out.push(if_node(&np, &p, s)?)
          "for" => out.push(for_node(&np, &p, s)?)
          "set" => {
            let n = name(&p)?
            expect_sym(&p, "=")?
            let e = expr(&p)?
            done(p)?
            out.push(Set(n, e, s.line, s.col))
          }
          "include" => {
            let TStr(n) = next(&p) else {
              p.i -= 1
              fail(err_at(p, "a quoted template name"))
            }
            done(p)?
            out.push(Include(n, s.line, s.col))
          }
          "elif" => return (out, kw, p)
          "else" => return (out, kw, p)
          "end" => return (out, kw, p)
          "endif" => return (out, kw, p)
          "endfor" => return (out, kw, p)
          _ => fail(
            Syntax(
              "unknown tag `{kw}` (want if, elif, else, for, set, include, raw or end)",
              s.line,
              s.col,
            ),
          )
        }
      }
    }
  }
  (out, "", P { ts: [], i: 0, line: 0, col: 0 })
}

fn done(p: P): ()!TplErr {
  if peek(p) != TEnd { fail(err_at(p, "the end of the tag")) }
}

fn closes(kw: str, opener: str): bool = kw == "end" || kw == "end" + opener

fn if_node(np: var NP, p: var P, s: Seg): Node!TplErr {
  var branches: [Branch] = []
  var cond = expr(&p)?
  done(p)?
  loop {
    let (body, kw, rest) = block(&np)?
    branches.push(Branch { cond, body })
    var r = rest
    match kw {
      "elif" => {
        cond = expr(&r)?
        done(r)?
      }
      "else" => {
        done(r)?
        let (other, kw2, r2) = block(&np)?
        if !closes(kw2, "if") { fail(unclosed("if", kw2, r2, s)) }
        done(r2)?
        return If(branches, other, s.line, s.col)
      }
      _ => {
        if !closes(kw, "if") { fail(unclosed("if", kw, r, s)) }
        done(r)?
        return If(branches, [], s.line, s.col)
      }
    }
  }
}

fn unclosed(opener: str, got: str, at: P, s: Seg): TplErr = if got == "" {
  Syntax("`{{% {opener} %}}` is never closed (add `{{% end %}}`)", s.line, s.col)
} else {
  Syntax("`{{% {got} %}}` can't close `{{% {opener} %}}` from line {s.line}", at.line, at.col)
}

fn for_node(np: var NP, p: var P, s: Seg): Node!TplErr {
  let first = name(&p)?
  var key: str? = none
  var n = first
  if p.is_sym(",") {
    p.i += 1
    key = some(first)
    n = name(&p)?
  }
  if !p.is_word("in") { fail(err_at(p, "`in`")) }
  p.i += 1
  let iter = expr(&p)?
  done(p)?
  let (body, kw, r) = block(&np)?
  if kw == "else" {
    done(r)?
    let (other, kw2, r2) = block(&np)?
    if !closes(kw2, "for") { fail(unclosed("for", kw2, r2, s)) }
    done(r2)?
    return For(key, n, iter, body, other, s.line, s.col)
  }
  if !closes(kw, "for") { fail(unclosed("for", kw, r, s)) }
  done(r)?
  For(key, n, iter, body, [], s.line, s.col)
}

// ---- rendering ----

// `scopes[0]` holds the data; each running `for` adds one scope above it, and `at`/`of` hold
// that loop's current index and length (for `loop`, which is only built when asked for).
struct Ctx {
  scopes: [{str: Value}],
  at: [int],
  of: [int],
  partials: {str: Template},
  escape: bool,
  depth: int,
}

let MAX_INCLUDE_DEPTH = 32

fn run(nodes: [Node], c: var Ctx, out: var str): ()!TplErr {
  for n in nodes {
    match n {
      Text(s) => out += s
      Out(e, line, col) => {
        let v = eval(e, c, line, col)?
        let s = show_value(v)
        out += if c.escape && !is_raw(e) { escape(s) } else { s }
      }
      If(branches, other, line, col) => {
        var taken = false
        for b in branches {
          if truthy(eval(b.cond, c, line, col)?) {
            run(b.body, &c, &out)?
            taken = true
            break
          }
        }
        if !taken { run(other, &c, &out)? }
      }
      For(key, name, iter, body, other, line, col) => {
        let seq = eval(iter, c, line, col)?
        // a list is walked in place; the rest goes through `pairs`
        let xs = match seq {
          List(xs) => xs
          _ => []
        }
        let items = if seq is List(_) { [] } else { pairs(seq, key != none, line, col)? }
        let count = xs.len() + items.len()
        if count == 0 {
          run(other, &c, &out)?
          continue
        }
        c.scopes.push({})
        c.at.push(0)
        c.of.push(count)
        let top = c.scopes.len() - 1
        for i in 0..count {
          // the loop's variables; a variable named `loop` is hidden by the loop's own `loop`
          var sc: {str: Value} = {}
          match key {
            some(kn) => if kn != "loop" { sc[kn] = if i < xs.len() { Int(i) } else { items[i].0 } }
            none => {}
          }
          if name != "loop" { sc[name] = if i < xs.len() { xs[i] } else { items[i].1 } }
          c.scopes[top] = sc
          c.at[top - 1] = i
          run(body, &c, &out)?
        }
        c.scopes.pop()
        c.at.pop()
        c.of.pop()
      }
      Set(name, e, line, col) => {
        let v = eval(e, c, line, col)?
        let top = c.scopes.len() - 1
        c.scopes[top][name] = v
      }
      Include(name, line, col) => {
        let t = c.partials.get(name) else fail(NoPartial(name, line, col))
        if c.depth >= MAX_INCLUDE_DEPTH {
          fail(
            Type(
              "includes nested more than {MAX_INCLUDE_DEPTH} deep (a partial including itself?)",
              line,
              col,
            ),
          )
        }
        c.depth += 1
        run(t.nodes, &c, &out)?
        c.depth -= 1
      }
    }
  }
}

// The `loop` variable of a `for` at index `i` of `count`.
fn loop_info(i: int, count: int): Value = Map({
  "index": Int(i + 1),
  "index0": Int(i),
  "first": Bool(i == 0),
  "last": Bool(i == count - 1),
  "length": Int(count),
})

fn is_raw(e: Expr): bool = match e {
  Filter(_, "raw", _) => true
  Filter(_, "safe", _) => true
  _ => false
}

// What a `for` iterates: list items (key = index) or map entries (key = the key; one loop
// variable gets the key, two get key and value).
fn pairs(v: Value, two: bool, line: int, col: int): [(Value, Value)]!TplErr = match v {
  List(xs) => xs.enum().map((i, x) => (Int(i), x))  // (`run` walks lists itself)
  Map(m) => {
    var ps: [(Value, Value)] = []
    for k, x in m { ps.push(if two { (Str(k), x) } else { (Null, Str(k)) }) }
    ps
  }
  Null => []
  _ => fail(Type("can't loop over {kind(v)}", line, col))
}

fn kind(v: Value): str = match v {
  Null => "none"
  Bool(_) => "a bool"
  Int(_) => "an int"
  Float(_) => "a float"
  Str(_) => "a string"
  List(_) => "a list"
  Map(_) => "a map"
}

fn truthy(v: Value): bool = match v {
  Null => false
  Bool(b) => b
  Int(i) => i != 0
  Float(f) => f != 0.0
  Str(s) => s != ""
  List(xs) => xs.len() > 0
  Map(m) => m.len() > 0
}

/// How a value prints in `{{ }}`: strings as is, `none` as nothing, lists and maps as JSON.
fn show_value(v: Value): str = match v {
  Null => ""
  Bool(b) => "{b}"
  Int(i) => "{i}"
  Float(f) => "{f}"
  Str(s) => s
  _ => json(v)
}

fn lookup(c: Ctx, n: str): Value? {
  var i = c.scopes.len() - 1
  while i >= 0 {
    match c.scopes[i].get(n) {
      some(v) => return some(v)
      none => {}
    }
    if i > 0 && n == "loop" { return some(loop_info(c.at[i - 1], c.of[i - 1])) }
    i -= 1
  }
  none
}

// A field of a value: `e` is the whole `b.n` expression.
fn field(v: Value, b: Expr, n: str, e: Expr, line: int, col: int): Value!TplErr = match v {
  Map(m) => m.get(n) else fail(Undefined(path(e), line, col))
  _ => fail(Type("`{path(b)}` is {kind(v)}, so it has no field `{n}`", line, col))
}

// A readable name for an expression, for errors: `user.name`, `xs[0]`.
fn path(e: Expr): str = match e {
  Var(n) => n
  Attr(b, n) => path(b) + "." + n
  Index(b, Lit(Int(i))) => path(b) + "[{i}]"
  Index(b, Lit(Str(s))) => path(b) + "[\"{s}\"]"
  Index(b, _) => path(b) + "[...]"
  Filter(b, f, _) => path(b) + " | " + f
  _ => "expression"
}

fn eval(e: Expr, c: Ctx, line: int, col: int): Value!TplErr = match e {
  Lit(v) => v
  Var(n) => lookup(c, n) else fail(Undefined(n, line, col))
  Attr(Var("loop"), n) => {
    // `loop.index` and the like, straight from the innermost loop's counters
    let top = c.scopes.len() - 1
    if top > 0 && c.scopes[top].get("loop") == none {
      let i = c.at[top - 1]
      match n {
        "index" => Int(i + 1)
        "index0" => Int(i)
        "first" => Bool(i == 0)
        "last" => Bool(i == c.of[top - 1] - 1)
        "length" => Int(c.of[top - 1])
        _ => fail(Undefined(path(e), line, col))
      }
    } else {
      let v = lookup(c, "loop") else fail(Undefined("loop", line, col))
      field(v, Var("loop"), n, e, line, col)?
    }
  }
  Attr(b, n) => field(eval(b, c, line, col)?, b, n, e, line, col)?
  Index(b, k) => index(eval(b, c, line, col)?, eval(k, c, line, col)?, e, line, col)?
  Neg(x) => match eval(x, c, line, col)? {
    Int(i) => Int(-i)
    Float(f) => Float(-f)
    v => fail(Type("can't negate {kind(v)}", line, col))
  }
  Not(x) => Bool(!truthy(eval(x, c, line, col)?))
  Bin("and", a, b) => {
    let x = eval(a, c, line, col)?
    if !truthy(x) { x } else { eval(b, c, line, col)? }
  }
  Bin("or", a, b) => {
    let x = eval(a, c, line, col)?
    if truthy(x) { x } else { eval(b, c, line, col)? }
  }
  Bin(op, a, b) => binary(op, eval(a, c, line, col)?, eval(b, c, line, col)?, line, col)?
  Filter(b, "default", args) => {
    let fallback = if args.len() > 0 { eval(args[0], c, line, col)? } else { Str("") }
    match eval(b, c, line, col) {
      ok(Null) => fallback
      ok(v) => v
      err(Undefined(_, _, _)) => fallback
      err(x) => fail(x)
    }
  }
  Filter(b, f, args) => {
    let v = eval(b, c, line, col)?
    var vs: [Value] = []
    for a in args { vs.push(eval(a, c, line, col)?) }
    filter(f, v, vs, line, col)?
  }
  ListE(xs) => {
    var vs: [Value] = []
    for x in xs { vs.push(eval(x, c, line, col)?) }
    List(vs)
  }
}

fn index(v: Value, k: Value, e: Expr, line: int, col: int): Value!TplErr = match (v, k) {
  (List(xs), Int(i)) => {
    let j = if i < 0 { xs.len() + i } else { i }
    xs.get(j) else fail(Undefined(path(e), line, col))
  }
  (Str(s), Int(i)) => {
    let j = if i < 0 { s.len() + i } else { i }
    if j < 0 || j >= s.len() { fail(Undefined(path(e), line, col)) }
    Str(str([s[j]]))
  }
  (Map(m), Str(key)) => m.get(key) else fail(Undefined(path(e), line, col))
  _ => fail(Type("can't index {kind(v)} with {kind(k)}", line, col))
}

fn num(v: Value): float? = match v {
  Int(i) => some(float(i))
  Float(f) => some(f)
  _ => none
}

fn equal(a: Value, b: Value): bool = match (a, b) {
  (Int(x), Float(y)) => float(x) == y
  (Float(x), Int(y)) => x == float(y)
  _ => a == b
}

fn binary(op: str, a: Value, b: Value, line: int, col: int): Value!TplErr {
  let bad = () => Type("can't apply `{op}` to {kind(a)} and {kind(b)}", line, col)
  match op {
    "==" => return Bool(equal(a, b))
    "!=" => return Bool(!equal(a, b))
    "in" => return Bool(contains(b, a, line, col)?)
    "not in" => return Bool(!contains(b, a, line, col)?)
    _ => {}
  }
  if op == "<" || op == "<=" || op == ">" || op == ">=" {
    let c = match (a, b) {
      (Str(x), Str(y)) => if x < y { -1 } else if x > y { 1 } else { 0 }
      _ => {
        let x = num(a) else fail(bad())
        let y = num(b) else fail(bad())
        if x < y { -1 } else if x > y { 1 } else { 0 }
      }
    }
    return Bool(match op { "<" => c < 0, "<=" => c <= 0, ">" => c > 0, _ => c >= 0 })
  }
  match (op, a, b) {
    ("+", Str(x), Str(y)) => Str(x + y)
    ("+", List(x), List(y)) => List(x + y)
    (_, Int(x), Int(y)) => match op {
      "+" => Int(x + y)
      "-" => Int(x - y)
      "*" => Int(x * y)
      _ => {
        if y == 0 { fail(Type("division by zero", line, col)) }
        if op == "/" { Int(x / y) } else { Int(x % y) }
      }
    }
    _ => {
      let x = num(a) else fail(bad())
      let y = num(b) else fail(bad())
      match op {
        "+" => Float(x + y)
        "-" => Float(x - y)
        "*" => Float(x * y)
        "/" => Float(x / y)
        _ => fail(bad())
      }
    }
  }
}

fn contains(hay: Value, needle: Value, line: int, col: int): bool!TplErr = match (hay, needle) {
  (Str(s), Str(n)) => s.contains(n)
  (List(xs), _) => xs.any(x => equal(x, needle))
  (Map(m), Str(k)) => m.get(k) != none
  _ => fail(Type("can't test whether {kind(hay)} contains {kind(needle)}", line, col))
}

fn arg_int(
  f: str,
  args: [Value],
  i: int,
  dflt: int?,
  line: int,
  col: int,
): int!TplErr = match args.get(i) {
  some(Int(n)) => n
  none => dflt else fail(Type("`{f}` needs argument {i + 1}", line, col))
  some(v) => fail(Type("`{f}` wants an int, got {kind(v)}", line, col))
}

fn arg_str(
  f: str,
  args: [Value],
  i: int,
  dflt: str?,
  line: int,
  col: int,
): str!TplErr = match args.get(i) {
  some(Str(s)) => s
  none => dflt else fail(Type("`{f}` needs argument {i + 1}", line, col))
  some(v) => fail(Type("`{f}` wants a string, got {kind(v)}", line, col))
}

fn filter(f: str, v: Value, args: [Value], line: int, col: int): Value!TplErr {
  let bad = () => Type("filter `{f}` doesn't apply to {kind(v)}", line, col)
  match (f, v) {
    ("raw", _) => v
    ("safe", _) => v
    ("escape", _) => Str(escape(show_value(v)))
    ("e", _) => Str(escape(show_value(v)))
    ("str", _) => Str(show_value(v))
    ("json", _) => Str(json(v))
    ("upper", Str(s)) => Str(s.upper())
    ("lower", Str(s)) => Str(s.lower())
    ("trim", Str(s)) => Str(s.trim())
    ("capitalize", Str(s)) => Str(capitalize(s))
    ("title", Str(s)) => Str(s.split(" ").map(capitalize).join(" "))
    ("length", _) => Int(length(v) else fail(bad()))
    ("len", _) => Int(length(v) else fail(bad()))
    ("count", _) => Int(length(v) else fail(bad()))
    ("first", List(xs)) => xs.first() else Null
    ("last", List(xs)) => xs.last() else Null
    ("first", Str(s)) => if s == "" { Null } else { Str(str([s[0]])) }
    ("last", Str(s)) => if s == "" { Null } else { Str(str([s[s.len() - 1]])) }
    ("reverse", List(xs)) => List(xs.reverse())
    ("reverse", Str(s)) => Str(str(s.chars().reverse()))
    ("sort", List(xs)) => List(sort_values(xs, args.get(0), line, col)?)
    ("join", List(xs)) => Str(xs.map(show_value).join(arg_str(f, args, 0, some(""), line, col)?))
    ("keys", Map(m)) => List(m.keys().map(k => Str(k)))
    ("values", Map(m)) => List(m.values())
    ("items", Map(m)) => {
      var ps: [Value] = []
      for k, x in m { ps.push(List([Str(k), x])) }
      List(ps)
    }
    ("split", Str(s)) => {
      let parts = match args.get(0) {
        some(Str(sep)) => s.split(sep)
        _ => s.split()
      }
      List(parts.map(p => Str(p)))
    }
    ("replace", Str(s)) =>
      Str(s.replace(arg_str(f, args, 0, none, line, col)?, arg_str(f, args, 1, none, line, col)?))
    ("truncate", Str(s)) => {
      let n = arg_int(f, args, 0, none, line, col)?
      let end = arg_str(f, args, 1, some("…"), line, col)?
      if s.len() <= n { v } else { Str(s[0..(n - end.len()).max0()] + end) }
    }
    ("int", Int(_)) => v
    ("int", Float(x)) => Int(int(x))
    ("int", Str(s)) => Int(int.parse(s.trim()) else fail(Type("`{s}` isn't an int", line, col)))
    ("float", Int(i)) => Float(float(i))
    ("float", Float(_)) => v
    ("float", Str(s)) =>
      Float(float.parse(s.trim()) else fail(Type("`{s}` isn't a number", line, col)))
    ("abs", Int(i)) => Int(if i < 0 { -i } else { i })
    ("abs", Float(x)) => Float(x.abs())
    ("round", Int(_)) => v
    ("round", Float(x)) => {
      let places = arg_int(f, args, 0, some(0), line, col)?
      if places <= 0 {
        Int(int(x.round()))
      } else {
        let k = 10.0 ** float(places)
        Float((x * k).round() / k)
      }
    }
    ("urlencode", _) => Str(urlencode(show_value(v)))
    ("default", _) => v
    _ => if KNOWN.contains(f) {
      fail(bad())
    } else {
      fail(Type("unknown filter `{f}` (filters: {KNOWN.join(", ")})", line, col))
    }
  }
}

let KNOWN = [
  "abs",
  "capitalize",
  "count",
  "default",
  "e",
  "escape",
  "first",
  "float",
  "int",
  "items",
  "join",
  "json",
  "keys",
  "last",
  "len",
  "length",
  "lower",
  "raw",
  "replace",
  "reverse",
  "round",
  "safe",
  "sort",
  "split",
  "str",
  "title",
  "trim",
  "truncate",
  "upper",
  "urlencode",
  "values",
]

fn max0(n: int): int = if n < 0 { 0 } else { n }

fn length(v: Value): int? = match v {
  Str(s) => some(s.len())
  List(xs) => some(xs.len())
  Map(m) => some(m.len())
  _ => none
}

fn capitalize(w: str): str = if w == "" { w } else { str([w[0].upper()]) + w[1..w.len()].lower() }

fn sort_key(v: Value): (int, float, str) = match v {
  Null => (0, 0.0, "")
  Bool(b) => (1, if b { 1.0 } else { 0.0 }, "")
  Int(i) => (2, float(i), "")
  Float(f) => (2, f, "")
  Str(s) => (3, 0.0, s)
  _ => (4, 0.0, json(v))
}

// Sorted by value, or by field `key` of each map item.
fn sort_values(xs: [Value], key: Value?, line: int, col: int): [Value]!TplErr = match key {
  none => xs.sort_by(sort_key)
  some(Str(k)) => {
    for x in xs {
      match x {
        Map(m) => if m.get(k) == none { fail(Undefined("item.{k}", line, col)) }
        _ => fail(Type("sort by `{k}` needs maps, got {kind(x)}", line, col))
      }
    }
    xs.sort_by(x => match x {
      Map(m) => sort_key(m[k])
      _ => sort_key(x)
    })
  }
  some(v) => fail(Type("`sort` wants a field name, got {kind(v)}", line, col))
}

fn hex2(n: int): str {
  let d = "0123456789ABCDEF"
  str([d[n / 16], d[n % 16]])
}

fn urlencode(s: str): str {
  var out: [str] = []
  for b in s.bytes() {
    let c = char(b) else ' '
    let safe =
      (b < 128) && (c.is_alpha() || c.is_digit() || c == '-' || c == '_' || c == '.' || c == '~')
    out.push(if safe { str([c]) } else { "%" + hex2(b) })
  }
  out.join("")
}

fn json_str(s: str): str {
  var out: [str] = ["\""]
  for c in s.chars() {
    out.push(
      match c {
        '"' => "\\\""
        '\\' => "\\\\"
        '\n' => "\\n"
        '\r' => "\\r"
        '\t' => "\\t"
        // keep `</script>` and HTML comments from closing an inline <script>
        '<' => "\\u003c"
        '>' => "\\u003e"
        '&' => "\\u0026"
        _ => if int(c) < 32 { "\\u00" + hex2(int(c)) } else { str([c]) }
      },
    )
  }
  out.push("\"")
  out.join("")
}

/// `v` as compact JSON, safe to embed in an HTML `<script>` (`<`, `>` and `&` are escaped).
pub fn json(v: Value): str = match v {
  Null => "null"
  Bool(b) => "{b}"
  Int(i) => "{i}"
  Float(f) => if f != f || f - f != 0.0 { "null" } else { "{f}" }
  Str(s) => json_str(s)
  List(xs) => "[" + xs.map(json).join(",") + "]"
  Map(m) => {
    var ps: [str] = []
    for k, x in m { ps.push(json_str(k) + ":" + json(x)) }
    "{{" + ps.join(",") + "}}"
  }
}

// ---- tests ----

struct User { name: str, admin: bool, tags: [str], email: str? }

test "output and escaping" {
  let u = User { name: "<Ann & \"Bo\">", admin: true, tags: ["a", "b"], email: none }
  assert render_html(r"Hi {{ name }}!", u)? == "Hi &lt;Ann &amp; &quot;Bo&quot;&gt;!"
  assert render_text(r"Hi {{ name }}!", u)? == "Hi <Ann & \"Bo\">!"
  assert render_html(r"{{ name | raw }}", u)? == "<Ann & \"Bo\">"
  assert render_html(r"{{ tags }} {{ email }}|", u)? == "[&quot;a&quot;,&quot;b&quot;] |"
  let math = r"{{ 1 + 2 * 3 }} {{ 7 / 2 }} {{ 7.0 / 2 }} {{ (-3) | abs }} {{ -3 | abs }}"
  assert render_text(math, {"x": 1})? == "7 3 3.5 3 -3"
  assert render_text(r"""{{ "}}" }}""", {"x": 1})? == r"}}"
  assert render_text(r"{{ 'it\'s' }}", {"x": 1})? == "it's"
  assert escape("a<b>'c'") == "a&lt;b&gt;&#39;c&#39;"
}

test "attributes, indexes and undefined" {
  let d = {"user": Map({"name": Str("Ann"), "langs": List([Str("auk"), Str("c")])})}
  let src = r"{{ user.name }} {{ user.langs[1] }} {{ user.langs.0 }} {{ user['name'] }} {{ user.langs[-1] }}"
  assert render_text(src, d)? == "Ann c auk Ann c"
  match render_text("a\n  " + r"{{ user.email }}", d) {
    err(Undefined(n, l, c)) => assert (n, l, c) == ("user.email", 2, 3)
    r => fail("expected Undefined, got {r}")
  }
  match render_text(r"{{ nope }}", d) {
    err(e) =>
      assert message(e) == "1:1: `nope` is undefined (use `| default(...)` if it may be missing)"
    ok(_) => fail("rendered")
  }
  let dflt = r"{{ user.email | default('none') }}/{{ x | default }}/{{ none | default(1) }}"
  assert render_text(dflt, d)? == "none//1"
  match render_text(r"{{ user.name.first }}", d) {
    err(Type(m, _, _)) => assert m == "`user.name` is a string, so it has no field `first`"
    r => fail("expected Type, got {r}")
  }
}

test "if, elif, else" {
  let t = text(r"{% if n > 10 %}big{% elif n > 5 and not small %}mid{% else %}small{% endif %}")?
  assert render(t, {"n": Int(20), "small": Bool(false)})? == "big"
  assert render(t, {"n": Int(7), "small": Bool(false)})? == "mid"
  assert render(t, {"n": Int(7), "small": Bool(true)})? == "small"
  assert render_text(r"{% if xs %}y{% else %}n{% end %}", {"xs": List([])})? == "n"
  let d = {"s": Str("abc"), "xs": List([Int(1)])}
  assert render_text(r"{% if 'b' in s and 3 not in xs %}y{% end %}", d)? == "y"
  assert render_text(r"{{ a or 'dflt' }} {{ b and 'yes' }}", {"a": Str(""), "b": Int(1)})? ==
    "dflt yes"
}

test "for loops" {
  let d = {"xs": List([Str("a"), Str("b"), Str("c")]), "m": Map({"k": Int(1), "j": Int(2)})}
  let t = r"{% for x in xs %}{{ loop.index }}{{ x }}{% if not loop.last %},{% end %}{% endfor %}"
  assert render_text(t, d)? == "1a,2b,3c"
  assert render_text(r"{% for k, v in m %}{{ k }}={{ v }};{% end %}", d)? == "k=1;j=2;"
  assert render_text(r"{% for k in m %}{{ k }}{% end %}", d)? == "kj"
  assert render_text(r"{% for i, x in xs %}{{ i }}{% end %}", d)? == "012"
  assert render_text(r"{% for x in m.nothing | default([]) %}x{% else %}empty{% end %}", d)? ==
    "empty"
  let nested =
    r"{% for x in xs %}{% for y in xs %}{{ loop.index0 }}{% end %}{{ loop.index }}{% end %}"
  assert render_text(nested, d)? == "012101220123"
  // the loop variable doesn't leak, and set inside a loop is scoped to it
  match render_text(r"{% for x in xs %}{% end %}{{ x }}", d) {
    err(Undefined("x", _, _)) => {}
    r => fail("{r}")
  }
  assert render_text(r"{% set n = 1 %}{% for x in xs %}{% set n = 2 %}{% end %}{{ n }}", d)? == "1"
}

test "standalone lines and whitespace control" {
  let src = r"""
    <ul>
      {% for x in xs %}
      <li>{{ x }}</li>
      {% end %}
    </ul>
    """
  assert render_html(src, {"xs": List([Int(1), Int(2)])})? ==
    "<ul>\n  <li>1</li>\n  <li>2</li>\n</ul>\n"
  let nested = r"""
    <ul>
      {% for x in xs %}
        {% if x > 1 %}
        <li>{{ x }}</li>
        {% endif %}
      {% endfor %}
    </ul>
    """
  assert render_html(nested, {"xs": List([Int(1), Int(2)])})? == "<ul>\n    <li>2</li>\n</ul>\n"
  let rows = r"""
    <ul>
      {% for x in xs %}
      {% include "li" %}
      {% endfor %}
    </ul>
    """
  let li = html(r"<li>{{ x }}</li>")?
  assert render(html(rows)?, {"xs": List([Int(1), Int(2)])}, {"li": li})? ==
    "<ul>\n  <li>1</li>\n  <li>2</li>\n</ul>\n"
  assert render_text(r"{# c #}" + "\nA\n  " + r"{# c2 #}" + "  \nB", {"x": 1})? == "A\nB"
  assert render_text(r"a  {%- if true -%}  b  {%- end %}", {"x": 1})? == "ab"
  assert render_text(r"x {{- 1 -}}" + "\n y", {"x": 1})? == "x1y"
  // tags sharing a line with text stay inline
  assert render_text(r"a {% if true %}b{% end %} c" + "\n", {"x": 1})? == "a b c\n"
}

test "raw and include" {
  assert render_text(r"{% raw %}{{ x }} {% if %}{% endraw %}", {"x": 1})? == r"{{ x }} {% if %}"
  let item = html(r"<li>{{ x.name }}</li>")?
  let page = html(r"""{% for x in items %}{% include "item" %}{% end %}""")?
  let d = {"items": List([Map({"name": Str("a&b")})])}
  assert render(page, d, {"item": item})? == "<li>a&amp;b</li>"
  match render(page, d) {
    err(NoPartial("item", 1, 21)) => {}
    r => fail("{r}")
  }
  let rec = text(r"""x{% include "r" %}""")?
  match render(rec, {"a": 1}, {"r": rec}) {
    err(Type(m, _, _)) => assert m.contains("nested more than")
    r => fail("{r}")
  }
}

test "filters" {
  let d = {
    "s": Str("  hello world "),
    "xs": List([Int(3), Int(1), Int(2)]),
    "ps": List([Map({"n": Str("b")}), Map({"n": Str("a")})]),
    "f": Float(3.14159),
  }
  let t1 = r"{{ s | trim | upper }}|{{ s | trim | title }}|{{ s | length }}"
  assert render_text(t1, d)? == "HELLO WORLD|Hello World|14"
  let t2 = r"{{ xs | sort | join(', ') }} {{ xs | first }} {{ xs | last }} {{ xs | reverse }}"
  assert render_text(t2, d)? == "1, 2, 3 3 2 [2,1,3]"
  assert render_text(r"{% for p in ps | sort('n') %}{{ p.n }}{% end %}", d)? == "ab"
  let t3 = r"{{ f | round(2) }} {{ f | round }} {{ '42' | int + 1 }} {{ 'a b' | urlencode }}"
  assert render_text(t3, d)? == "3.14 3 43 a%20b"
  let t4 =
    r"{{ 'abcdefgh' | truncate(5) }} {{ 'abc' | truncate(5) }} {{ 'a-b' | replace('-', '+') }}"
  assert render_text(t4, d)? == "abcd… abc a+b"
  assert render_text(r"{{ 'a,b' | split(',') | length }}", d)? == "2"
  let t5 = r"<script>let d = {{ ps | json | raw }}</script>"
  assert render_html(t5, d)? == r"""<script>let d = [{"n":"b"},{"n":"a"}]</script>"""
  assert json(Str("</script>")) == "\"\\u003c/script\\u003e\""
  match render_text(r"{{ s | shout }}", d) {
    err(Type(m, _, _)) => assert m.starts_with("unknown filter `shout`")
    r => fail("{r}")
  }
  match render_text(r"{{ xs | upper }}", d) {
    err(Type(m, _, _)) => assert m == "filter `upper` doesn't apply to a list"
    r => fail("{r}")
  }
}

test "syntax errors" {
  let cases = [
    (r"{{ x ", r"1:1: `{{` is never closed"),
    ("a\n" + r"{% if x %}b", r"2:1: `{% if %}` is never closed (add `{% end %}`)"),
    (r"{% for x in xs %}{% endif %}", r"1:18: `{% endif %}` can't close `{% for %}` from line 1"),
    (r"{% end %}", r"1:1: `{% end %}` without an opening tag"),
    (r"{% frob %}", "1:1: unknown tag `frob` (want if, elif, else, for, set, include, raw or end)"),
    (r"{{ a b }}", "1:1: expected the end of the expression, found `b`"),
    (r"{{ (a }}", "1:1: expected `)`, found the end of the tag"),
    (r"{{ }}", r"1:1: empty `{{ }}`"),
    (r"{{ a ? b }}", "1:1: unexpected `?`"),
    (r"{% for x of xs %}{% end %}", "1:1: expected `in`, found `of`"),
    (r"{% raw %}abc", r"1:1: `{% raw %}` without `{% endraw %}`"),
  ]
  for (src, want) in cases {
    match text(src) {
      err(e) => assert (src, message(e)) == (src, want)
      ok(_) => fail("parsed: {src}")
    }
  }
  match render_text(r"{{ x }}", [1, 2]) {
    err(Type(m, _, _)) => assert m == "render needs a struct or map, got a list"
    r => fail("{r}")
  }
}

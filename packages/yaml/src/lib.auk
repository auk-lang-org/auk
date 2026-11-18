/// A YAML 1.2 subset <-> the core `Value` tree. Pure: no effects.
/// Block and flow collections, plain/single/double-quoted scalars, literal `|` and folded `>`
/// blocks, comments, multiple documents and anchors/aliases. Plain scalars resolve with the
/// YAML 1.2 core schema (null, bool, int, float, else string). Not supported: tags (`!x`),
/// complex keys (`? `, collections as keys) and merge keys (`<<`).

/// Why `parse` failed. Every variant carries the 1-based line and column (counted in chars).
pub enum YamlErr {
  Syntax(why: str, line: int, col: int),         // `why` says what was wrong or expected
  Eof(want: str, line: int, col: int),           // the text ended inside a quote or `[`/`{`
  Tab(line: int, col: int),                      // a tab used for indentation
  BadEscape(text: str, line: int, col: int),     // e.g. `\q` or `\xZZ` in a "string"
  UnknownAlias(name: str, line: int, col: int),  // `*name` before any `&name`
  DuplicateKey(key: str, line: int, col: int),   // a key twice in one mapping
  Unsupported(what: str, line: int, col: int),   // tags, complex keys, merge keys
  ManyDocs(count: int, line: int, col: int),     // `parse` found more than one document
  TooDeep(line: int, col: int),                  // nested deeper than MAX_DEPTH
}

/// The deepest nesting of collections `parse` accepts.
imprint MAX_DEPTH = 512

/// A one-line description of a parse error, e.g. `3:1: tabs can't be used for indentation`.
pub fn message(e: YamlErr): str
fn message(Syntax(why, l, k)): str = "{l}:{k}: {why}"
fn message(Eof(w, l, k)): str = "{l}:{k}: expected {w}, found end of input"
fn message(Tab(l, k)): str = "{l}:{k}: tabs can't be used for indentation (use spaces)"
fn message(BadEscape(t, l, k)): str = "{l}:{k}: bad escape '{t}'"
fn message(UnknownAlias(n, l, k)): str = "{l}:{k}: unknown alias '*{n}' (define '&{n}' first)"
fn message(DuplicateKey(key, l, k)): str = "{l}:{k}: duplicate key '{key}'"
fn message(Unsupported(w, l, k)): str = "{l}:{k}: {w} aren't supported"
fn message(ManyDocs(n, l, k)): str =
  "{l}:{k}: expected one document, found {n} (use yaml.parse_all)"
fn message(TooDeep(l, k)): str = "{l}:{k}: nested deeper than {MAX_DEPTH}"

// ---- cursor ----

struct P {
  cs: [char],
  i: int,
  line: int,  // 1-based line of i
  ls: int,    // index where that line starts
  flow: int,  // how many `[`/`{` we are inside
  depth: int,
  anchors: {str: Value},
}

// The char at i (+k), or '\0' past the end (the input has no '\0': it's rejected up front).
fn ch(p: P): char = if p.i < p.cs.len() { p.cs[p.i] } else { '\0' }
fn ch_at(p: P, k: int): char = if p.i + k < p.cs.len() { p.cs[p.i + k] } else { '\0' }
fn eof(p: P): bool = p.i >= p.cs.len()
fn col(p: P): int = p.i - p.ls

// Consumes one char, keeping the line count.
fn bump(p: var P) {
  if ch(p) == '\n' {
    p.i += 1
    p.line += 1
    p.ls = p.i
  } else {
    p.i += 1
  }
}

fn here(p: P, why: str): YamlErr = Syntax(why, p.line, col(p) + 1)

// Space, tab, line end or end of input.
fn sep(c: char): bool = c == ' ' || c == '\t' || c == '\n' || c == '\0'
fn flow_ind(c: char): bool = r",[]{}".contains(c)
fn indicator(c: char): bool = r"-?:,[]{}#&*!|>'%@`".contains(c) || c == '"'

fn skip_space(p: var P) {
  while ch(p) == ' ' || ch(p) == '\t' { p.i += 1 }
}

// After skip_space: nothing but a comment before the line ends.
fn rest_empty(p: var P): bool {
  p.skip_space()
  let c = ch(p)
  c == '#' || c == '\n' || c == '\0'
}

fn skip_comment(p: var P) {
  if ch(p) == '#' {
    while ch(p) != '\n' && !eof(p) { p.i += 1 }
  }
}

// Skips spaces, comments and line breaks up to the next content char (or the end).
fn skip_to_content(p: var P): ()!YamlErr {
  loop {
    p.skip_space()
    p.skip_comment()
    if ch(p) != '\n' { break }
    p.bump()
    p.check_indent()?
  }
}

// At a line start in block context: a tab in the indentation before content is an error.
fn check_indent(p: P): ()!YamlErr {
  if p.flow > 0 { return }
  var j = p.i
  while j < p.cs.len() && p.cs[j] == ' ' { j += 1 }
  if j >= p.cs.len() || p.cs[j] != '\t' { return }
  var k = j
  while k < p.cs.len() && (p.cs[k] == ' ' || p.cs[k] == '\t') { k += 1 }
  if k < p.cs.len() && p.cs[k] != '\n' && p.cs[k] != '#' { fail(Tab(p.line, j - p.ls + 1)) }
}

// `---` or `...` at the start of a line, followed by a separator.
fn is_marker(p: P, m: str): bool =
  col(p) == 0 && ch(p) == m[0] && ch_at(p, 1) == m[0] && ch_at(p, 2) == m[0] && sep(ch_at(p, 3))

fn at_marker(p: P): bool = is_marker(p, "---") || is_marker(p, "...")

// A block sequence entry: '-' and then a separator.
fn is_dash(p: P): bool = ch(p) == '-' && sep(ch_at(p, 1))

// Can a plain scalar start here? Indicators can't start one, except `-?:` before a safe char.
fn plain_start(p: P, flow: bool): bool {
  let c = ch(p)
  if sep(c) { return false }
  if !indicator(c) { return true }
  let next = ch_at(p, 1)
  "-?:".contains(c) && !sep(next) && !(flow && flow_ind(next))
}

fn enter(p: var P): ()!YamlErr {
  p.depth += 1
  if p.depth > MAX_DEPTH { fail(TooDeep(p.line, col(p) + 1)) }
}

// The chars in [from, to), clipped to the input.
fn text(p: P, from: int, to: int): str =
  core.str(p.cs[from..if to > p.cs.len() { p.cs.len() } else { to }])

// ---- documents ----

/// Parses a stream of YAML documents (separated by `---`, optionally ended by `...`), one
/// `Value` each. An empty stream gives `[]`; an empty document gives `Null`.
pub fn parse_all(s: str): [Value]!YamlErr = (documents(s)?).map((v, _) => v)

/// Parses a single YAML document: maps become `Map` (keys in document order), sequences
/// `List`, and plain scalars `Null`/`Bool`/`Int`/`Float`/`Str` by the YAML 1.2 core schema.
/// Empty input is `Null`; more than one document is a `ManyDocs` error (see `parse_all`).
pub fn parse(s: str): Value!YamlErr {
  let docs = documents(s)?
  match docs {
    [] => Null
    [(v, _)] => v
    [_, (_, (l, k)), ..] => fail(ManyDocs(docs.len(), l, k))
  }
}

// Each document with the line and column where it starts.
fn documents(s: str): [(Value, (int, int))]!YamlErr {
  var p = start(s)?
  var docs: [(Value, (int, int))] = []
  var directives = false
  loop {
    p.skip_to_content()?
    if p.eof() { break }
    let at = (p.line, col(p) + 1)
    if col(p) == 0 && ch(p) == '%' {
      if p.text(p.i, p.i + 4) == "%TAG" { fail(Unsupported("tags", p.line, 1)) }
      while ch(p) != '\n' && !p.eof() { p.i += 1 }  // `%YAML 1.2` and reserved directives
      directives = true
      continue
    }
    if is_marker(p, "...") {
      p.i += 3
      if !p.rest_empty() { fail(here(p, "unexpected text after '...'")) }
      continue
    }
    let v = if is_marker(p, "---") {
      p.i += 3
      p.value_after(-1, false, false)?
    } else {
      if directives { fail(here(p, "expected '---' after directives")) }
      p.block_at(-1)?
    }
    directives = false
    docs.push((v, at))
    p.skip_to_content()?
    if !p.eof() && !at_marker(p) { fail(here(p, "expected the end of the document")) }
  }
  docs
}

fn start(s: str): P!YamlErr {
  var cs = s.replace("\r\n", "\n").replace("\r", "\n").chars()
  if cs.len() > 0 && cs[0] == '\u{FEFF}' { cs = cs.skip(1) }
  let p = P { cs, i: 0, line: 1, ls: 0, flow: 0, depth: 0, anchors: {} }
  // control chars other than tab and line feed are not allowed anywhere
  var q = p
  while !q.eof() {
    let c = ch(q)
    if (int(c) < 0x20 && c != '\t' && c != '\n') || int(c) == 0x7f {
      fail(here(q, "control character U+{hex2(int(c))} (escape it in a \"string\")"))
    }
    q.bump()
  }
  p.check_indent()?
  p
}

fn hex2(n: int): str = "{"0123456789ABCDEF"[n / 16]}{"0123456789ABCDEF"[n % 16]}"

// ---- block structure ----

// The node after an indicator (`key:`, `- ` or `---`) on the current line, or on the lines
// below it. `n` is the indent of the enclosing collection (-1 at the top). `seq_ok`: a `- `
// at indent `n` may start the value (`key:\n- a`). `compact`: a block collection may start
// on this line (`- a: 1`, `- - x`).
fn value_after(p: var P, n: int, seq_ok: bool, compact: bool): Value!YamlErr {
  p.skip_space()
  var anchor: str? = none
  if ch(p) == '&' {
    anchor = some(p.anchor_name()?)
    p.skip_space()
  }
  if ch(p) == '!' { fail(Unsupported("tags", p.line, col(p) + 1)) }
  let v = if p.rest_empty() {
    p.skip_to_content()?
    if p.eof() || at_marker(p) {
      Null
    } else if col(p) > n {
      p.block_at(n)?
    } else if col(p) == n && seq_ok && is_dash(p) {
      p.seq(n)?
    } else {
      Null
    }
  } else if compact && is_dash(p) {
    p.seq(col(p))?
  } else if compact && anchor is none && p.is_key() {
    p.map(col(p))?
  } else {
    p.inline(n)?
  }
  match anchor {
    some(a) => p.anchors[a] = v
    none => {}
  }
  v
}

// A node that starts a line (only indentation before it), deeper than `n`.
fn block_at(p: var P, n: int): Value!YamlErr {
  let c = ch(p)
  if c == '&' || c == '!' { return p.value_after(n, false, false)? }
  if is_dash(p) { return p.seq(col(p))? }
  if c == '?' && sep(ch_at(p, 1)) { fail(Unsupported("complex keys ('? ')", p.line, col(p) + 1)) }
  if p.is_key() { return p.map(col(p))? }
  p.inline(n)?
}

// Does a `key:` start here? Looks ahead without consuming.
fn is_key(p: P): bool {
  var q = p
  let c = ch(q)
  if c == '"' || c == '\'' {
    if q.quoted() is err(_) || q.line != p.line { return false }
  } else if plain_start(q, false) {
    q.plain_line(false)
  } else {
    return false
  }
  q.skip_space()
  ch(q) == ':' && sep(ch_at(q, 1))
}

// A block mapping whose keys are at column m.
fn map(p: var P, m: int): Value!YamlErr {
  p.enter()?
  var out: {str: Value} = {}
  loop {
    let (kl, kc) = (p.line, col(p) + 1)
    let quoted = ch(p) == '"' || ch(p) == '\''
    let key = if quoted { p.quoted()? } else { p.plain_line(false) }
    p.skip_space()
    if ch(p) != ':' { fail(here(p, "expected ':' after a key")) }
    p.bump()
    if !quoted && key == "<<" { fail(Unsupported("merge keys ('<<')", kl, kc)) }
    if out.get(key) is some(_) { fail(DuplicateKey(key, kl, kc)) }
    out[key] = p.value_after(m, true, false)?
    p.skip_to_content()?
    if p.eof() || at_marker(p) || col(p) < m { break }
    if col(p) > m { fail(here(p, "bad indentation (expected column {m + 1})")) }
    if ch(p) == '?' && sep(ch_at(p, 1)) {
      fail(Unsupported("complex keys ('? ')", p.line, col(p) + 1))
    }
    if !p.is_key() { fail(here(p, "expected a 'key:' at this indentation")) }
  }
  p.depth -= 1
  Map(out)
}

// A block sequence whose dashes are at column s.
fn seq(p: var P, s: int): Value!YamlErr {
  p.enter()?
  var out: [Value] = []
  loop {
    p.bump()  // the '-'
    out.push(p.value_after(s, false, true)?)
    p.skip_to_content()?
    if p.eof() || at_marker(p) || col(p) < s { break }
    if col(p) > s { fail(here(p, "bad indentation (expected column {s + 1})")) }
    if !is_dash(p) { break }
  }
  p.depth -= 1
  List(out)
}

// A scalar, flow collection or alias that starts mid-line; `n` as in value_after.
fn inline(p: var P, n: int): Value!YamlErr {
  let c = ch(p)
  let v = if c == '|' || c == '>' {
    return p.block_scalar(n)?
  } else if c == '[' || c == '{' {
    let fv = p.flow_collection()?
    p.skip_space()
    if ch(p) == ':' {
      fail(Unsupported("complex keys (a collection as a key)", p.line, col(p) + 1))
    }
    fv
  } else if c == '*' {
    p.alias()?
  } else if c == '"' || c == '\'' {
    Str(p.quoted()?)
  } else if is_dash(p) {
    fail(here(p, "a block sequence isn't allowed here"))
  } else if c == '!' {
    fail(Unsupported("tags", p.line, col(p) + 1))
  } else if c == '?' && sep(ch_at(p, 1)) {
    fail(Unsupported("complex keys ('? ')", p.line, col(p) + 1))
  } else if p.is_key() {
    fail(here(p, "a mapping isn't allowed here (put it on the next line, indented)"))
  } else if plain_start(p, false) {
    p.plain_block(n)
  } else {
    fail(here(p, "unexpected '{c}'"))
  }
  p.skip_space()
  if ch(p) == ':' { fail(here(p, "mapping values aren't allowed here")) }
  if ch(p) != '#' && ch(p) != '\n' && ch(p) != '\0' {
    fail(here(p, "unexpected text after the value"))
  }
  v
}

// ---- plain scalars ----

// One line of a plain scalar, up to `: `, ` #` or the line end (and `,[]{}` in flow
// context); trailing spaces are dropped.
fn plain_line(p: var P, flow: bool): str {
  let start = p.i
  var end = p.i
  loop {
    let c = ch(p)
    if c == '\n' || c == '\0' { break }
    let next = ch_at(p, 1)
    if c == ':' && (sep(next) || (flow && flow_ind(next))) { break }
    if c == '#' && p.i > start && (p.cs[p.i - 1] == ' ' || p.cs[p.i - 1] == '\t') { break }
    if flow && flow_ind(c) { break }
    p.i += 1
    if c != ' ' && c != '\t' { end = p.i }
  }
  p.text(start, end)
}

// A plain scalar in block context: continuation lines must be indented deeper than `n`.
// Line breaks fold to a space, and each empty line between becomes a "\n".
fn plain_block(p: var P, n: int): Value {
  var buf = p.plain_line(false)
  loop {
    var q = p
    q.skip_space()
    if ch(q) != '\n' { break }
    var empties = 0
    q.bump()
    loop {
      while ch(q) == ' ' { q.i += 1 }
      let ind = col(q)
      q.skip_space()
      if ch(q) != '\n' {
        q.i = q.ls + ind  // back to the end of the indentation
        break
      }
      empties += 1
      q.bump()
    }
    if q.eof() || col(q) <= n || at_marker(q) { break }
    q.skip_space()
    if ch(q) == '#' { break }
    let more = q.plain_line(false)
    if more == "" { break }
    buf = buf + fold_break(empties) + more
    p = q
  }
  resolve(buf)
}

fn fold_break(0): str = " "
fn fold_break(empties: int): str = "\n".repeat(empties)

// A plain scalar inside `[]`/`{}`: it may span lines, whatever their indentation.
fn plain_flow(p: var P): str {
  var buf = p.plain_line(true)
  loop {
    var q = p
    q.skip_space()
    if ch(q) != '\n' { break }
    var empties = 0
    q.bump()
    q.skip_space()
    while ch(q) == '\n' {
      empties += 1
      q.bump()
      q.skip_space()
    }
    let c = ch(q)
    if q.eof() ||
      c == '#' ||
      flow_ind(c) ||
      (c == ':' && (sep(ch_at(q, 1)) || flow_ind(ch_at(q, 1)))) {
      break
    }
    let more = q.plain_line(true)
    if more == "" { break }
    buf = buf + fold_break(empties) + more
    p = q
  }
  buf
}

/// How a plain scalar resolves under the YAML 1.2 core schema: `null`/`~`/empty, `true`/`false`
/// (also capitalized or upper-case), decimal, `0o` octal and `0x` hex integers, floats
/// (`1.5`, `-2e3`, `.5`, `.inf`, `-.inf`, `.nan`), and anything else a `Str`.
pub fn resolve(t: str): Value {
  if ["", "~", "null", "Null", "NULL"].contains(t) { return Null }
  if ["true", "True", "TRUE"].contains(t) { return Bool(true) }
  if ["false", "False", "FALSE"].contains(t) { return Bool(false) }
  if [".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF"].contains(t) { return Float(INF) }
  if ["-.inf", "-.Inf", "-.INF"].contains(t) { return Float(-INF) }
  if [".nan", ".NaN", ".NAN"].contains(t) { return Float(NAN) }
  let cs = t.chars()
  let body = if cs[0] == '-' || cs[0] == '+' { cs.skip(1) } else { cs }
  if body.len() > 0 && body.all(c => c.is_digit()) {
    let digits = core.str(body)
    let n = int.parse(digits) else return float_or_str(t)
    return Int(if cs[0] == '-' { -n } else { n })
  }
  if t.starts_with("0o") && t.len() > 2 && cs.skip(2).all(c => c >= '0' && c <= '7') {
    return radix(cs.skip(2), 8, t)
  }
  if t.starts_with("0x") && t.len() > 2 && cs.skip(2).all(c => hex_val(c) is some(_)) {
    return radix(cs.skip(2), 16, t)
  }
  float_or_str(t)
}

let INF = 1.0 / 0.0
let NAN = 0.0 / 0.0

fn radix(ds: [char], base: int, t: str): Value {
  var n = 0
  for d in ds {
    if n > (0x7fffffffffffffff - 15) / base { return Str(t) }  // doesn't fit in an int
    n = n * base + (hex_val(d) else 0)
  }
  Int(n)
}

fn hex_val(c: char): int? {
  let i = "0123456789abcdefABCDEF".chars().find_index(d => d == c)?
  if i < 16 { i } else { i - 6 }
}

// [-+]? ( \.[0-9]+ | [0-9]+ ( \.[0-9]* )? ) ( [eE] [-+]? [0-9]+ )?
fn float_or_str(t: str): Value {
  let cs = t.chars()
  var i = 0
  if i < cs.len() && (cs[i] == '-' || cs[i] == '+') { i += 1 }
  let int_start = i
  while i < cs.len() && cs[i].is_digit() { i += 1 }
  let int_digits = i - int_start
  var frac_digits = 0
  if i < cs.len() && cs[i] == '.' {
    i += 1
    let f = i
    while i < cs.len() && cs[i].is_digit() { i += 1 }
    frac_digits = i - f
  }
  if int_digits == 0 && frac_digits == 0 { return Str(t) }
  if i < cs.len() && (cs[i] == 'e' || cs[i] == 'E') {
    i += 1
    if i < cs.len() && (cs[i] == '-' || cs[i] == '+') { i += 1 }
    let e = i
    while i < cs.len() && cs[i].is_digit() { i += 1 }
    if i == e { return Str(t) }
  }
  if i != cs.len() { return Str(t) }
  // float.parse wants digits on both sides of the '.'
  let sign = if cs[0] == '-' { "-" } else { "" }
  let unsigned = if cs[0] == '-' || cs[0] == '+' { t[1..t.len()] } else { t }
  let lead = if unsigned.starts_with(".") { "0" + unsigned } else { unsigned }
  let norm = lead.replace(".e", ".0e").replace(".E", ".0E")
  let fixed = if norm.ends_with(".") { norm + "0" } else { norm }
  match float.parse(sign + fixed) {
    ok(f) => Float(f)
    err(_) => Str(t)
  }
}

// ---- quoted scalars ----

// A "double" or 'single' quoted scalar (p is on the quote). Line breaks fold as in plain
// scalars; trailing spaces before a break are dropped.
fn quoted(p: var P): str!YamlErr {
  let q = ch(p)
  let (l0, c0) = (p.line, col(p) + 1)
  p.bump()
  var out: [char] = []
  loop {
    let c = ch(p)
    if p.eof() { fail(Eof("a closing {q}", l0, c0)) }
    if c == q {
      if q == '\'' && ch_at(p, 1) == '\'' {
        out.push('\'')
        p.i += 2
        continue
      }
      p.bump()
      break
    }
    if c == '\\' && q == '"' {
      if ch_at(p, 1) == '\n' {
        // an escaped line break: join the lines with nothing between
        p.bump()
        p.bump()
        p.skip_space()
      } else {
        out.push(p.escape()?)
      }
      continue
    }
    if c == ' ' || c == '\t' {
      var j = p.i
      while j < p.cs.len() && (p.cs[j] == ' ' || p.cs[j] == '\t') { j += 1 }
      if j < p.cs.len() && p.cs[j] == '\n' {
        p.i = j  // trailing spaces before a break are dropped
      } else {
        for k in p.i..j { out.push(p.cs[k]) }
        p.i = j
      }
      continue
    }
    if c == '\n' {
      p.bump()
      p.skip_space()
      var empties = 0
      while ch(p) == '\n' {
        empties += 1
        p.bump()
        p.skip_space()
      }
      if p.flow == 0 && at_marker(p) { fail(Eof("a closing {q}", l0, c0)) }
      for c2 in fold_break(empties).chars() { out.push(c2) }
      continue
    }
    out.push(c)
    p.i += 1
  }
  core.str(out)
}

// One escape in a "string" (p is on the backslash).
fn escape(p: var P): char!YamlErr {
  let (l, k) = (p.line, col(p) + 1)
  let e = ch_at(p, 1)
  p.i += 2
  let simple = match e {
    '0' => some('\0')
    'a' => some('\u{7}')
    'b' => some('\u{8}')
    't' => some('\t')
    '\t' => some('\t')
    'n' => some('\n')
    'v' => some('\u{b}')
    'f' => some('\u{c}')
    'r' => some('\r')
    'e' => some('\u{1b}')
    ' ' => some(' ')
    '"' => some('"')
    '/' => some('/')
    '\\' => some('\\')
    'N' => some('\u{85}')
    '_' => some('\u{a0}')
    'L' => some('\u{2028}')
    'P' => some('\u{2029}')
    _ => none
  }
  match simple {
    some(c) => return c
    none => {}
  }
  let digits = match e {
    'x' => 2
    'u' => 4
    'U' => 8
    _ => fail(BadEscape("\\{e}", l, k))
  }
  var n = 0
  for j in 0..digits {
    let d = hex_val(ch_at(p, j)) else fail(BadEscape("\\{e}{p.text(p.i, p.i + j)}", l, k))
    n = n * 16 + d
  }
  p.i += digits
  char(n) else fail(BadEscape("\\{e}{p.text(p.i - digits, p.i)}", l, k))
}

// ---- block scalars ----

// A literal `|` or folded `>` block scalar (p is on the indicator), inside a collection at
// indent `n`.
fn block_scalar(p: var P, n: int): Value!YamlErr {
  let literal = ch(p) == '|'
  p.bump()
  var chomp = 0  // -1 strip, 0 clip, 1 keep
  var explicit = 0
  for _ in 0..2 {
    let c = ch(p)
    if c == '-' && chomp == 0 {
      chomp = -1
      p.i += 1
    } else if c == '+' && chomp == 0 {
      chomp = 1
      p.i += 1
    } else if c >= '1' && c <= '9' && explicit == 0 {
      explicit = int(c) - 48
      p.i += 1
    }
  }
  if !sep(ch(p)) || !p.rest_empty() { fail(here(p, "bad block scalar header")) }
  p.skip_comment()
  if p.eof() { return Str("") }
  p.bump()
  let base = if n < 0 { 0 } else { n + 1 }
  let indent = if explicit > 0 { if n < 0 { 0 } else { n } + explicit } else { p.detect(base) }
  var lines: [str] = []
  var last_nl = false
  loop {
    if p.eof() { break }
    let start = p.i
    var k = 0
    while k < indent && ch(p) == ' ' {
      p.i += 1
      k += 1
    }
    if k < indent {
      p.skip_space()
      if ch(p) == '\n' {
        lines.push("")
        p.bump()
        last_nl = true
        continue
      }
      if p.eof() { break }
      p.i = start  // less indented: the block is over
      break
    }
    p.i = start
    if indent == 0 && at_marker(p) { break }
    p.i = start + indent
    let from = p.i
    while ch(p) != '\n' && !p.eof() { p.i += 1 }
    lines.push(p.text(from, p.i))
    last_nl = ch(p) == '\n'
    if last_nl { p.bump() }
  }
  // trailing empty lines belong to the chomping, not the content
  var body = lines
  var trailing = 0
  while body.len() > 0 && body.last() == some("") {
    body.pop()
    trailing += 1
  }
  if body.len() == 0 { return Str(if chomp == 1 { "\n".repeat(trailing) } else { "" }) }
  let content = if literal { body.join("\n") } else { fold_lines(body) }
  let ends = if trailing > 0 || last_nl { "\n" } else { "" }
  Str(
    match chomp {
      -1 => content
      0 => content + ends
      _ => content + ends + "\n".repeat(trailing)
    },
  )
}

// The indentation of the first non-empty line below (at least `min`; less means the block
// is empty).
fn detect(p: P, min: int): int {
  var j = p.i
  loop {
    var k = 0
    while j + k < p.cs.len() && p.cs[j + k] == ' ' { k += 1 }
    if j + k >= p.cs.len() { return min }
    if p.cs[j + k] != '\n' { return if k < min { min } else { k } }
    j = j + k + 1
  }
}

// Folding for `>`: a break between two normal lines is a space, empty lines between are kept
// as "\n" each, and lines starting with a space or tab ("more indented") keep their breaks.
fn fold_lines(lines: [str]): str {
  var out = ""
  var empties = 0
  var started = false
  var prev_more = false
  for line in lines {
    if line == "" {
      empties += 1
      continue
    }
    let more = line.starts_with(" ") || line.starts_with("\t")
    if !started {
      out = "\n".repeat(empties)
    } else if !more && !prev_more {
      out = out + fold_break(empties)
    } else {
      out = out + "\n".repeat(empties + 1)
    }
    out = out + line
    started = true
    prev_more = more
    empties = 0
  }
  out
}

// ---- anchors and aliases ----

fn anchor_name(p: var P): str!YamlErr {
  p.i += 1  // '&' or '*'
  let start = p.i
  while !sep(ch(p)) && !flow_ind(ch(p)) { p.i += 1 }
  if p.i == start { fail(here(p, "expected an anchor name")) }
  p.text(start, p.i)
}

fn alias(p: var P): Value!YamlErr {
  let (l, k) = (p.line, col(p) + 1)
  let name = p.anchor_name()?
  p.anchors.get(name) else fail(UnknownAlias(name, l, k))
}

// ---- flow collections ----

fn skip_flow_ws(p: var P) {
  loop {
    p.skip_space()
    p.skip_comment()
    if ch(p) != '\n' { break }
    p.bump()
  }
}

fn flow_collection(p: var P): Value!YamlErr {
  p.flow += 1
  p.enter()?
  let v = if ch(p) == '[' { p.flow_seq()? } else { p.flow_map()? }
  p.flow -= 1
  p.depth -= 1
  v
}

// A node inside `[]`/`{}`, with its text when it is a scalar (keys need the text).
fn flow_value(p: var P): (Value, str?)!YamlErr {
  p.skip_flow_ws()
  var anchor: str? = none
  if ch(p) == '&' {
    anchor = some(p.anchor_name()?)
    p.skip_flow_ws()
  }
  let c = ch(p)
  let (v, key) = if c == '!' {
    fail(Unsupported("tags", p.line, col(p) + 1))
  } else if c == '[' || c == '{' {
    (p.flow_collection()?, none)
  } else if c == '"' || c == '\'' {
    let s = p.quoted()?
    (Str(s), some(s))
  } else if c == '*' {
    (p.alias()?, none)
  } else if anchor is some(_) && (c == ',' || c == ']' || c == '}') {
    (Null, none)
  } else if p.eof() {
    fail(Eof("a value", p.line, col(p) + 1))
  } else if c == '?' && sep(ch_at(p, 1)) {
    fail(Unsupported("complex keys ('? ')", p.line, col(p) + 1))
  } else if plain_start(p, true) {
    let t = p.plain_flow()
    (resolve(t), some(t))
  } else {
    fail(here(p, "expected a value, found '{c}'"))
  }
  match anchor {
    some(a) => p.anchors[a] = v
    none => {}
  }
  (v, key)
}

// After a key in a flow collection: is this the `:` before its value? A quoted key may be
// followed directly by the value (`{"a":1}`, as in JSON).
fn flow_colon(p: P, quoted: bool): bool =
  ch(p) == ':' && (quoted || sep(ch_at(p, 1)) || flow_ind(ch_at(p, 1)))

fn flow_seq(p: var P): Value!YamlErr {
  let (l0, c0) = (p.line, col(p) + 1)
  p.bump()  // '['
  var out: [Value] = []
  loop {
    p.skip_flow_ws()
    if ch(p) == ']' {
      p.bump()
      break
    }
    if p.eof() { fail(Eof("']' for the '[' at {l0}:{c0}", p.line, col(p) + 1)) }
    let quoted = ch(p) == '"' || ch(p) == '\''
    let (kl, kc) = (p.line, col(p) + 1)
    let (v, key) = p.flow_value()?
    p.skip_flow_ws()
    if flow_colon(p, quoted) {
      // a single-pair mapping: [a: 1, b: 2]
      let k = key else fail(Unsupported("complex keys (a collection as a key)", kl, kc))
      p.bump()
      p.skip_flow_ws()
      let value = if ch(p) == ',' || ch(p) == ']' { Null } else { (p.flow_value()?).0 }
      out.push(Map({k: value}))
      p.skip_flow_ws()
    } else {
      out.push(v)
    }
    if ch(p) == ',' {
      p.bump()
      continue
    }
    if ch(p) == ']' {
      p.bump()
      break
    }
    if p.eof() { fail(Eof("']' for the '[' at {l0}:{c0}", p.line, col(p) + 1)) }
    fail(here(p, "expected ',' or ']'"))
  }
  List(out)
}

fn flow_map(p: var P): Value!YamlErr {
  let (l0, c0) = (p.line, col(p) + 1)
  p.bump()  // '{'
  var out: {str: Value} = {}
  loop {
    p.skip_flow_ws()
    if ch(p) == '}' {
      p.bump()
      break
    }
    if p.eof() { fail(Eof("'}}' for the '{{' at {l0}:{c0}", p.line, col(p) + 1)) }
    let quoted = ch(p) == '"' || ch(p) == '\''
    let (kl, kc) = (p.line, col(p) + 1)
    let (_, key) = p.flow_value()?
    let k = key else fail(Unsupported("complex keys (a collection as a key)", kl, kc))
    if !quoted && k == "<<" { fail(Unsupported("merge keys ('<<')", kl, kc)) }
    p.skip_flow_ws()
    let value = if flow_colon(p, quoted) {
      p.bump()
      p.skip_flow_ws()
      if ch(p) == ',' || ch(p) == '}' { Null } else { (p.flow_value()?).0 }
    } else {
      Null
    }
    if out.get(k) is some(_) { fail(DuplicateKey(k, kl, kc)) }
    out[k] = value
    p.skip_flow_ws()
    if ch(p) == ',' {
      p.bump()
      continue
    }
    if ch(p) == '}' {
      p.bump()
      break
    }
    if p.eof() { fail(Eof("'}}' for the '{{' at {l0}:{c0}", p.line, col(p) + 1)) }
    fail(here(p, "expected ',' or '}}'"))
  }
  Map(out)
}

// ---- writing ----

/// YAML text in block style: maps as `key: value` lines, lists as `- item` lines (indented
/// two spaces per level; a map or list inside a list starts on the dash's line). Empty
/// collections are `{}` and `[]`. Strings are plain when that reads back as the same string,
/// literal blocks (`|`, `|-`, `|+`) when they span lines, and "double-quoted" otherwise.
/// Floats keep a `.` or exponent; NaN and the infinities are `.nan`, `.inf` and `-.inf`.
pub fn str(v: Value): str {
  var out: [str] = []
  match v {
    Map(m) when m.len() > 0 => emit_map(m, 0, &out)
    List(xs) when xs.len() > 0 => emit_list(xs, 0, &out)
    Str(s) when literal_ok(s) => {
      out.push(literal_header(s))
      push_literal(s, 2, &out)
    }
    _ => out.push(scalar(v))
  }
  out.join("\n") + "\n"
}

fn pad(n: int): str = " ".repeat(n)

fn emit_map(m: {str: Value}, ind: int, out: var [str]) {
  for k, v in m {
    let key = pad(ind) + key_str(k) + ":"
    match v {
      Map(mm) when mm.len() > 0 => {
        out.push(key)
        emit_map(mm, ind + 2, &out)
      }
      List(xs) when xs.len() > 0 => {
        out.push(key)
        emit_list(xs, ind + 2, &out)
      }
      Str(s) when literal_ok(s) => {
        out.push(key + " " + literal_header(s))
        push_literal(s, ind + 2, &out)
      }
      _ => out.push(key + " " + scalar(v))
    }
  }
}

fn emit_list(xs: [Value], ind: int, out: var [str]) {
  for v in xs {
    match v {
      Map(m) when m.len() > 0 => {
        var sub: [str] = []
        emit_map(m, ind + 2, &sub)
        dash_first(sub, ind, &out)
      }
      List(ys) when ys.len() > 0 => {
        var sub: [str] = []
        emit_list(ys, ind + 2, &sub)
        dash_first(sub, ind, &out)
      }
      Str(s) when literal_ok(s) => {
        out.push(pad(ind) + "- " + literal_header(s))
        push_literal(s, ind + 2, &out)
      }
      _ => out.push(pad(ind) + "- " + scalar(v))
    }
  }
}

// A nested collection inside a list starts on the dash's line: `- a: 1` / `- - x`.
fn dash_first(sub: [str], ind: int, out: var [str]) {
  for i, line in sub {
    if i == 0 { out.push(pad(ind) + "- " + line[ind + 2..line.len()]) } else { out.push(line) }
  }
}

fn scalar(Null): str = "null"
fn scalar(Bool(b)): str = if b { "true" } else { "false" }
fn scalar(Int(i)): str = "{i}"
fn scalar(Float(f)): str = float_str(f)
fn scalar(Str(s)): str = if plain_ok(s) { s } else { quote(s) }
fn scalar(List(_)): str = "[]"
fn scalar(Map(_)): str = "{{}}"

fn float_str(f: float): str when f != f = ".nan"
fn float_str(f: float): str when f - f != 0.0 = if f > 0.0 { ".inf" } else { "-.inf" }
fn float_str(f: float): str = "{f}"  // shortest exact form, always with `.` or `e`

fn key_str(k: str): str = if plain_ok(k) { k } else { quote(k) }

// Can `s` be written as a plain scalar and read back as the same string?
fn plain_ok(s: str): bool {
  if s == "" || resolve(s) != Str(s) { return false }
  let cs = s.chars()
  if indicator(cs[0]) || sep(cs[0]) || sep(cs[cs.len() - 1]) { return false }
  if s.contains(": ") || s.contains(" #") || s.ends_with(":") || s.starts_with("...") {
    return false
  }
  cs.all(c => int(c) >= 0x20 && int(c) != 0x7f && !"\u{85}\u{2028}\u{2029}\u{feff}".contains(c))
}

// Multi-line text without other control chars or trailing spaces, whose first line doesn't
// start with a space (that would change the detected indentation), fits a literal block.
fn literal_ok(s: str): bool {
  if !s.contains("\n") || s.starts_with(" ") || s.starts_with("\n") { return false }
  // trailing spaces would be invisible (and editors strip them)
  if s.trim() == "" || s.contains(" \n") || s.contains("\t\n") { return false }
  s.chars().all(c => c == '\n' || c == '\t' || (int(c) >= 0x20 && int(c) != 0x7f))
}

fn literal_header(s: str): str {
  let trailing = s.chars().reverse().take_while(c => c == '\n').len()
  match trailing {
    0 => "|-"
    1 => "|"
    _ => "|+"
  }
}

fn push_literal(s: str, ind: int, out: var [str]) {
  var lines = s.split("\n")
  // `a\n` splits as ["a", ""]: the last "" is the final line break, not a line
  if s.ends_with("\n") { lines.pop() }
  for line in lines {
    out.push(if line == "" { "" } else { pad(ind) + line })
  }
}

fn quote(s: str): str = "\"" + s.chars().map(c => esc(c)).join("") + "\""

fn esc('"'): str = "\\\""
fn esc('\\'): str = "\\\\"
fn esc('\n'): str = "\\n"
fn esc('\r'): str = "\\r"
fn esc('\t'): str = "\\t"
fn esc('\0'): str = "\\0"
fn esc('\u{85}'): str = "\\N"
fn esc('\u{2028}'): str = "\\L"
fn esc('\u{2029}'): str = "\\P"
fn esc(c: char): str when int(c) < 0x20 || int(c) == 0x7f || c == '\u{feff}' = "\\u{hex4(int(c))}"
fn esc(c: char): str = "{c}"

fn hex4(n: int): str = hex2(n / 256) + hex2(n % 256)

// ---- typed ----

/// `parse` followed by the derived `from_value`; the type comes from the annotation
/// (`let c: Config = yaml.decode(s)?`).
pub fn decode<T: Data>(s: str): T! = from_value(parse(s)?)

/// The derived `to_value` followed by `str`.
pub fn encode<T: Data>(x: T): str = str(to_value(x))

// ---- tests ----

fn m(pairs: [(str, Value)]): Value {
  var out: {str: Value} = {}
  for (k, v) in pairs { out[k] = v }
  Map(out)
}

fn strs(xs: [str]): Value = List(xs.map(s => Str(s)))

test "block maps and lists, comments, core-schema scalars" {
  let doc = """
    # a config file
    name: auk   # trailing comment
    version: 1.2
    count: 42
    hex: 0x1F
    octal: 0o17
    exp: -1.5e3
    enabled: true
    nothing: ~
    empty:
    list:
      - a
      - b c
    same_indent:
    - one
    - two
    url: http://example.com:8080/x?y=1#z
    """
  assert parse(doc)? ==
    m([
      ("name", Str("auk")),
      ("version", Float(1.2)),
      ("count", Int(42)),
      ("hex", Int(31)),
      ("octal", Int(15)),
      ("exp", Float(-1500.0)),
      ("enabled", Bool(true)),
      ("nothing", Null),
      ("empty", Null),
      ("list", strs(["a", "b c"])),
      ("same_indent", strs(["one", "two"])),
      ("url", Str("http://example.com:8080/x?y=1#z")),
    ])
  for (t, v) in [
    ("null", Null),
    ("NULL", Null),
    ("True", Bool(true)),
    ("FALSE", Bool(false)),
    ("+12", Int(12)),
    ("-0", Int(0)),
    ("007", Int(7)),
    (".5", Float(0.5)),
    ("1.", Float(1.0)),
    ("-.inf", Float(-1.0 / 0.0)),
    ("1_000", Str("1_000")),
    ("yes", Str("yes")),
    ("0x", Str("0x")),
    ("1e", Str("1e")),
    ("12:30", Str("12:30")),
  ] {
    assert resolve(t) == v
  }
  let {"x": Float(nan)} = parse("x: .nan")? else fail("no NaN")
  assert nan != nan
}

test "nested and compact collections" {
  let doc = r"""
    a:
      b:
        c: 1
      d: [1, 2, {k: v}]
    e:
      - x: 1
        y: 2
      - - p
        - q
      -
        z: 3
      -
    """
  assert parse(doc)? ==
    m([
      ("a", m([("b", m([("c", Int(1))])), ("d", List([Int(1), Int(2), m([("k", Str("v"))])]))])),
      ("e", List([m([("x", Int(1)), ("y", Int(2))]), strs(["p", "q"]), m([("z", Int(3))]), Null])),
    ])
  assert parse("- a\n - b")? == strs(["a - b"])  // a continuation line, not an entry
}

test "flow collections" {
  assert parse(r"""[a, 'b', "c", [1, 2], {}, [], ]""")? ==
    List([Str("a"), Str("b"), Str("c"), List([Int(1), Int(2)]), Map({}), List([])])
  assert parse(r"""{a: 1, "b":2, c: , d}""")? ==
    m([("a", Int(1)), ("b", Int(2)), ("c", Null), ("d", Null)])
  assert parse("x: [a\n  b, c,\n  d ]\ny: {{k: v,\n  k2: [1,\n 2]}}")? ==
    m([("x", strs(["a b", "c", "d"])), ("y", m([("k", Str("v")), ("k2", List([Int(1), Int(2)]))]))])
  assert parse("[a: 1, b]")? == List([m([("a", Int(1))]), Str("b")])
  assert parse("[a:b, http://x]")? == strs(["a:b", "http://x"])
  assert parse("{{a: [1, # comment\n 2]}}")? == m([("a", List([Int(1), Int(2)]))])
}

test "quoted scalars and escapes" {
  assert parse(r"""a: "tab\there \"q\" \u00e9 \x41 \U0001F986 \N\_\/\\" """)? ==
    m([("a", Str("tab\there \"q\" é A 🦆 \u{85}\u{a0}/\\"))])
  assert parse("a: 'it''s \\n'")? == m([("a", Str("it's \\n"))])
  assert parse("a: \"multi\n  line   \n\n  quoted\"\nb: 'one\n  two'")? ==
    m([("a", Str("multi line\nquoted")), ("b", Str("one two"))])
  assert parse("a: \"x\\\n  y\"")? == m([("a", Str("xy"))])
  assert parse("\"quoted key\": 1\n'it''s': 2")? == m([("quoted key", Int(1)), ("it's", Int(2))])
  assert parse("\"1\": \"true\"")? == m([("1", Str("true"))])
}

test "literal and folded block scalars" {
  let doc = """
    literal: |
      line one
        indented
      line three

    folded: >
      a b
      c

      d
       more
      e
    strip: |-
      x
    keep: |+
      y


    explicit: |2
        two spaces kept
    folded_strip: >-
      folded
      text
    after: 1
    """
  assert parse(doc)? ==
    m([
      ("literal", Str("line one\n  indented\nline three\n")),
      ("folded", Str("a b c\nd\n more\ne\n")),
      ("strip", Str("x")),
      ("keep", Str("y\n\n\n")),
      ("explicit", Str("  two spaces kept\n")),
      ("folded_strip", Str("folded text")),
      ("after", Int(1)),
    ])
  assert parse("a: |\n  x")? == m([("a", Str("x"))])  // no final line break at the end of input
  assert parse("a: |\nb: 1")? == m([("a", Str("")), ("b", Int(1))])
  assert parse("- |1\n  explicit\n- >\n folded\n")? == strs([" explicit\n", "folded\n"])
  assert parse("--- |\n  top\n")? == Str("top\n")
}

test "multi-line plain scalars" {
  assert parse("plain: this is\n  a long\n\n  plain value\nnext: 1")? ==
    m([("plain", Str("this is a long\nplain value")), ("next", Int(1))])
  assert parse("top level\nscalar # comment")? == Str("top level scalar")
}

test "anchors and aliases" {
  let doc = """
    base: &b
      name: a
      size: 1
    copy: *b
    n: &n 3
    list: [*n, &w x, *w]
    """
  let base = m([("name", Str("a")), ("size", Int(1))])
  assert parse(doc)? ==
    m([("base", base), ("copy", base), ("n", Int(3)), ("list", List([Int(3), Str("x"), Str("x")]))])
  assert parse("- &a\n  - 1\n- *a")? == List([List([Int(1)]), List([Int(1)])])
  assert parse("a: &x 1\nb: *x\nc: &x 2\nd: *x")? ==
    m([("a", Int(1)), ("b", Int(1)), ("c", Int(2)), ("d", Int(2))])
}

test "documents" {
  let s = "%YAML 1.2\n---\na: 1\n...\n---\n- x\n--- plain doc\n--- |\n  lit\n---\n"
  assert parse_all(s)? == [m([("a", Int(1))]), strs(["x"]), Str("plain doc"), Str("lit\n"), Null]
  assert parse_all("")? == []
  assert parse_all("# only a comment\n")? == []
  assert parse("")? == Null
  assert parse("---\nonly: one\n")? == m([("only", Str("one"))])
  assert parse("a: 1\n---\nb: 2\n") is err(ManyDocs(2, 2, 1))
  assert parse("\u{FEFF}a: 1\r\nb: 2\r\n")? == m([("a", Int(1)), ("b", Int(2))])
}

test "errors carry line and column" {
  assert parse("a:\n\t- b") is err(Tab(2, 1))
  assert parse("a:\n  b: 1\n \t c: 2") is err(Tab(3, 2))
  assert parse("a:\t1\nb:\n  -\tx")? == m([("a", Int(1)), ("b", strs(["x"]))])  // tabs as separators are fine
  assert parse("a: b\n  c: d") is err(Syntax(_, 2, 4))
  assert parse("a: b: c") is err(Syntax(_, 1, 4))
  assert parse("- a\nb: 1") is err(Syntax(_, 2, 1))
  assert parse("a: 1\na: 2") is err(DuplicateKey("a", 2, 1))
  assert parse(r"{a: 1, a: 2}") is err(DuplicateKey("a", 1, 8))
  assert parse("a: [1, 2\n") is err(Eof(_, 2, 1))
  assert parse("a: \"open\n") is err(Eof(_, 1, 4))
  assert parse("a: *nope") is err(UnknownAlias("nope", 1, 4))
  assert parse("a: \"bad \\q\"") is err(BadEscape("\\q", 1, 9))
  assert parse("a: \"\\xZZ\"") is err(BadEscape(_, 1, 5))
  assert parse("a:\n  - b\n  c: 1") is err(Syntax(_, 3, 3))
  assert parse("a: [1] x") is err(Syntax(_, 1, 8))
  assert parse("a: 1\u{1}") is err(Syntax(_, 1, 5))
  assert parse("a: |x\n  y") is err(Syntax(_, 1, 5))
  assert parse("%YAML 1.2\na: 1") is err(Syntax(_, 2, 1))
  assert message(Tab(2, 1)) == "2:1: tabs can't be used for indentation (use spaces)"
  assert message(DuplicateKey("a", 2, 1)) == "2:1: duplicate key 'a'"
}

test "unsupported features are clear errors" {
  assert parse("a: !!str 1") is err(Unsupported("tags", 1, 4))
  assert parse("%TAG ! tag:x,2000:\n---\na: 1") is err(Unsupported("tags", 1, 1))
  assert parse("- !local x") is err(Unsupported("tags", 1, 3))
  assert parse("? complex\n: value") is err(Unsupported(_, 1, 1))
  assert parse("[a, b]: c") is err(Unsupported(_, 1, 7))
  assert parse(r"{[a]: b}") is err(Unsupported(_, 1, 2))
  assert parse("base: &b {{a: 1}}\nmerged:\n  <<: *b") is err(Unsupported(_, 3, 3))
  assert parse("\"<<\": 1")? == m([("<<", Int(1))])  // only a plain << is a merge key
  assert message(Unsupported("tags", 1, 4)) == "1:4: tags aren't supported"
}

test "nesting is limited to MAX_DEPTH" {
  assert parse("[".repeat(600) + "]".repeat(600)) is err(TooDeep(_, _))
  var deep = ""
  for i in 0..600 { deep = deep + " ".repeat(i) + "a:\n" }
  assert parse(deep) is err(TooDeep(_, _))
  let ok_depth = "[".repeat(100) + "]".repeat(100)
  assert parse(ok_depth) is ok(_)
}

test "str: block style" {
  let v = m([
    ("name", Str("auk")),
    ("n", Int(-3)),
    ("pi", Float(3.25)),
    ("big", Float(1e300)),
    ("inf", Float(1.0 / 0.0)),
    ("on", Bool(true)),
    ("none", Null),
    ("tags", strs(["a", "b"])),
    ("empty", List([])),
    ("obj", Map({})),
    ("nested", m([("deep", m([("x", Int(1))]))])),
    ("people", List([m([("name", Str("ann")), ("age", Int(30))]), m([("name", Str("bob"))])])),
    ("grid", List([List([Int(1), Int(2)]), List([])])),
    ("text", Str("line one\n  two\n")),
    ("odd keys", m([("a: b", Str("true")), ("", Str("-x")), ("x", Str(" pad"))])),
  ])
  let want = r"""
    name: auk
    n: -3
    pi: 3.25
    big: 1e300
    inf: .inf
    on: true
    none: null
    tags:
      - a
      - b
    empty: []
    obj: {}
    nested:
      deep:
        x: 1
    people:
      - name: ann
        age: 30
      - name: bob
    grid:
      - - 1
        - 2
      - []
    text: |
      line one
        two
    odd keys:
      "a: b": "true"
      "": "-x"
      x: " pad"
    """
  assert str(v) == want
  assert parse(str(v))? == v
  assert str(Str("hi")) == "hi\n"
  assert str(Str("a\nb")) == "|-\n  a\n  b\n"
  assert str(List([])) == "[]\n"
  assert str(Float(0.0 / 0.0)) == ".nan\n"
}

test "str round-trips awkward strings" {
  let tricky = [
    "",
    " lead",
    "trail ",
    "a: b",
    "a #b",
    "#x",
    "- x",
    "-x",
    "?",
    ":",
    "true",
    "null",
    "1",
    "1.5",
    "0x1f",
    ".inf",
    "~",
    "a\nb",
    "a\nb\n",
    "a\n\n",
    "\n",
    " x\ny",
    "tab\there",
    "quote\"s",
    "back\\slash",
    "ctl\u{1}\u{7f}",
    "é ☺ \u{2028}",
    "...",
    "--- x",
    "[a]",
    "{{a}}",
    "a,b",
    "*a",
    "&a",
    "!t",
    "|",
    "'q'",
    "%p",
    "line\n\n\nmore\n\n",
    "trailing space \nline",
  ]
  assert parse(str(strs(tricky)))? == strs(tricky)
  var keyed: {str: Value} = {}
  for s in tricky { keyed[s] = Str(s) }
  assert parse(str(Map(keyed)))? == Map(keyed)
}

struct Server { host: str, port: int, tls: bool }
struct Config { name: str, servers: [Server], tags: [str], limit: float? }

test "decode and encode" {
  let doc = """
    name: api
    servers:
      - host: a.example.com
        port: 443
        tls: true
      - {{host: localhost, port: 8080, tls: false}}
    tags: [prod, eu]
    limit: 2.5
    """
  let c: Config = decode(doc)?
  assert c.name == "api" && c.servers.len() == 2 && c.servers[1].port == 8080
  assert c.tags == ["prod", "eu"] && c.limit == some(2.5)
  let back: Config = decode(encode(c))?
  assert back == c
  let bad: Config! = decode("name: api\nservers: 3")
  assert bad is err(_)
}

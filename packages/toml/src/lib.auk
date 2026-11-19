/// TOML 1.0 text <-> the core `Value` tree. Pure: no effects.
/// Dates and times have no `Value` variant, so they parse to `Str` (RFC 3339 form).

/// Why `parse` failed. Every variant carries the 1-based line and column (counted in chars).
pub enum TomlErr {
  Unexpected(found: char, want: str, line: int, col: int),  // `want` describes what fits here
  Eof(want: str, line: int, col: int),                      // the text ended too early
  BadNumber(text: str, line: int, col: int),                // e.g. `01`, `1__0`, `0x`, `1.`
  BadDateTime(text: str, line: int, col: int),              // e.g. `1979-13-01`, `07:32`
  BadEscape(text: str, line: int, col: int),                // e.g. `\x`, `\uD800`
  ControlChar(line: int, col: int),                         // a raw control char in a string or comment
  DuplicateKey(key: str, line: int, col: int),              // a key or table defined twice
  NotATable(key: str, line: int, col: int),                 // a key path runs through a value or closed table
  TooDeep(line: int, col: int),                             // arrays/inline tables nested deeper than MAX_DEPTH
}

/// The deepest nesting of arrays and inline tables `parse` accepts.
imprint MAX_DEPTH = 512

/// A one-line description of a parse error, e.g. `3:7: expected '=', found ':'`.
pub fn message(e: TomlErr): str
fn message(Unexpected(c, w, l, k)): str = "{l}:{k}: expected {w}, found {shown(c)}"
fn message(Eof(w, l, k)): str = "{l}:{k}: expected {w}, found end of input"
fn message(BadNumber(t, l, k)): str = "{l}:{k}: bad number '{t}'"
fn message(BadDateTime(t, l, k)): str = "{l}:{k}: bad date or time '{t}'"
fn message(BadEscape(t, l, k)): str = "{l}:{k}: bad escape '{t}'"
fn message(ControlChar(l, k)): str = "{l}:{k}: control character (escape it)"
fn message(DuplicateKey(key, l, k)): str = "{l}:{k}: '{key}' is already defined"
fn message(NotATable(key, l, k)): str = "{l}:{k}: '{key}' is not a table that can be extended here"
fn message(TooDeep(l, k)): str = "{l}:{k}: nested deeper than {MAX_DEPTH}"

fn shown('\n'): str = "a newline"
fn shown(c: char): str when bad_control(c) || c == '\t' =
  "U+00{hex_digit(int(c) / 16)}{hex_digit(int(c) % 16)}"
fn shown(c: char): str = "'{c}'"

// ---- cursor ----

struct P { cs: [char], i: int }

fn peek(p: P): char? = p.cs.get(p.i)
fn at(p: P, c: char): bool = p.i < p.cs.len() && p.cs[p.i] == c
fn at_off(p: P, k: int, c: char): bool = p.i + k < p.cs.len() && p.cs[p.i + k] == c
fn eof(p: P): bool = p.i >= p.cs.len()
fn digit(c: char): bool = c >= '0' && c <= '9'

fn bare(c: char): bool =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || digit(c) || c == '_' || c == '-'

// Any control char except tab (U+0000..U+001F and U+007F).
fn bad_control(c: char): bool = (int(c) < 0x20 && c != '\t') || int(c) == 0x7f

fn skip_ws(p: var P) {
  let n = p.cs.len()
  var i = p.i
  while i < n && (p.cs[i] == ' ' || p.cs[i] == '\t') { i += 1 }
  p.i = i
}

// 1-based position of index i; only computed on the error path.
fn line(cs: [char], i: int): int = cs.take(i).filter(c => c == '\n').len() + 1
fn col(cs: [char], i: int): int = cs.take(i).reverse().take_while(c => c != '\n').len() + 1

fn want(p: P, w: str): TomlErr {
  let (l, k) = (line(p.cs, p.i), col(p.cs, p.i))
  match p.peek() {
    some(c) => Unexpected(c, w, l, k)
    none => Eof(w, l, k)
  }
}

fn control(p: P): TomlErr = ControlChar(line(p.cs, p.i), col(p.cs, p.i))

fn expect(p: var P, c: char, w: str): ()!TomlErr {
  if !p.at(c) { fail(p.want(w)) }
  p.i += 1
}

// Consumes a newline (LF or CRLF); false if there is none.
fn newline(p: var P): bool {
  if p.at('\n') {
    p.i += 1
    return true
  }
  if p.at('\r') && p.at_off(1, '\n') {
    p.i += 2
    return true
  }
  false
}

// Skips a `#` comment, if any, up to (not including) the line break.
fn comment(p: var P): ()!TomlErr {
  if !p.at('#') { return }
  let n = p.cs.len()
  var i = p.i + 1
  while i < n && p.cs[i] != '\n' {
    let c = p.cs[i]
    if c == '\r' && i + 1 < n && p.cs[i + 1] == '\n' { break }
    if bad_control(c) {
      p.i = i
      fail(p.control())
    }
    i += 1
  }
  p.i = i
}

// The rest of a line: spaces, an optional comment, then a newline or the end of input.
fn end_line(p: var P): ()!TomlErr {
  p.skip_ws()
  p.comment()?
  if !p.eof() && !p.newline() { fail(p.want("a newline")) }
}

// Spaces, comments and newlines (between array elements).
fn blank(p: var P): ()!TomlErr {
  loop {
    p.skip_ws()
    p.comment()?
    if !p.newline() { break }
  }
}

// ---- the document being built ----

// What a table node is, which decides how it may be extended.
enum Kind {
  Implicit,                    // a table created by a header's prefix (`[a.b]` creates `a`)
  Header,                      // a table defined by its own `[header]`, or an element of an array of tables
  Dotted,                      // a table created by a dotted key (`a.b = 1` creates `a`)
  Aot(first: int, last: int),  // an array of tables: its first and last element nodes
}

// The tables seen so far, as nodes numbered in the order they appear (0 is the root). `tabs[n]`
// maps each key of table n, in first-seen order, to a node number, or to `-(i + 1)` for the plain
// value `vals[i]` (a value, static array or inline table: closed). The elements of an array of
// tables are chained through `next` (-1 ends the chain). The tree is built at the end.
struct Doc { tabs: [{str: int}], kind: [Kind], next: [int], vals: [Value] }

struct Key { name: str, at: int }

fn new_doc(): Doc = Doc { tabs: [{}], kind: [Header], next: [-1], vals: [] }

// A new node of kind k.
fn node(d: var Doc, k: Kind): int {
  d.tabs.push({})
  d.kind.push(k)
  d.next.push(-1)
  d.kind.len() - 1
}

// A new table of kind k as key `name` of table `parent`.
fn child(d: var Doc, parent: int, name: str, k: Kind): int {
  let id = d.node(k)
  d.tabs[parent][name] = id
  id
}

// `a.b.c` for messages: the header's keys, then the first n of `keys`.
fn dotted(base: [Key], keys: [Key], n: int): str =
  (base + keys.take(n)).map(k => key_str(k.name)).join(".")

fn dup(p: P, path: str, at: int): TomlErr = DuplicateKey(path, line(p.cs, at), col(p.cs, at))

fn not_table(p: P, path: str, at: int): TomlErr = NotATable(path, line(p.cs, at), col(p.cs, at))

// A header's prefix (all its keys but the last): creates implicit tables and steps into the last
// element of arrays of tables. Returns the table the last key belongs in.
fn walk(d: var Doc, p: P, keys: [Key]): int!TomlErr {
  var cur = 0
  for j in 0..keys.len() - 1 {
    let name = keys[j].name
    let r = d.tabs[cur].get(name) else {
      cur = d.child(cur, name, Implicit)
      continue
    }
    if r < 0 { fail(p.not_table(dotted([], keys, j + 1), keys[j].at)) }
    cur = match d.kind[r] {
      Aot(_, last) => last
      _ => r
    }
  }
  cur
}

// `[a.b]`: returns the table's node.
fn table(d: var Doc, p: P, keys: [Key]): int!TomlErr {
  let cur = d.walk(p, keys)?
  let name = keys[keys.len() - 1].name
  let r = d.tabs[cur].get(name) else return d.child(cur, name, Header)
  if r < 0 || !(d.kind[r] is Implicit) { fail(p.dup(dotted([], keys, keys.len()), keys[0].at)) }
  d.kind[r] = Header
  r
}

// `[[a.b]]`: appends a table and returns its node.
fn array_table(d: var Doc, p: P, keys: [Key]): int!TomlErr {
  let cur = d.walk(p, keys)?
  let name = keys[keys.len() - 1].name
  let el = d.node(Header)
  let r = d.tabs[cur].get(name) else {
    let _ = d.child(cur, name, Aot(el, el))
    return el
  }
  let Aot(first, last) = if r < 0 { Header } else { d.kind[r] } else {
    fail(p.dup(dotted([], keys, keys.len()), keys[0].at))
  }
  d.next[last] = el
  d.kind[r] = Aot(first, el)
  el
}

// `a.b.c = v` inside table `tab` (whose header was `base`): dotted keys may only extend tables
// they created.
fn set(d: var Doc, p: P, tab: int, base: [Key], keys: [Key], v: Value): ()!TomlErr {
  var cur = tab
  let last = keys.len() - 1
  for j in 0..last {
    let name = keys[j].name
    let r = d.tabs[cur].get(name) else {
      cur = d.child(cur, name, Dotted)
      continue
    }
    if r < 0 || !(d.kind[r] is Dotted) { fail(p.not_table(dotted(base, keys, j + 1), keys[j].at)) }
    cur = r
  }
  let name = keys[last].name
  if d.tabs[cur].get(name) is some(_) { fail(p.dup(dotted(base, keys, last + 1), keys[0].at)) }
  d.vals.push(v)
  d.tabs[cur][name] = -d.vals.len()
}

// The tree below node n. Keys keep their first-seen order.
fn build(d: Doc, n: int): Value {
  let Aot(first, _) = d.kind[n] else return d.build_table(n)
  var xs: [Value] = []
  var el = first
  while el >= 0 {
    xs.push(d.build_table(el))
    el = d.next[el]
  }
  List(xs)
}

fn build_table(d: Doc, n: int): Value {
  var m: {str: Value} = {}
  for k, r in d.tabs[n] {
    m[k] = if r < 0 { d.vals[-r - 1] } else { d.build(r) }
  }
  Map(m)
}

// ---- parser ----

/// Parse a TOML 1.0 document into a `Map`. Tables and inline tables become `Map` (keys in
/// document order), arrays and arrays of tables become `List`, integers `Int`, floats `Float`
/// (`inf`/`nan` included), and dates and times `Str` in RFC 3339 form (`1979-05-27T07:32:00Z`;
/// a space or `t` separator becomes `T` and `z` becomes `Z`, otherwise the text is unchanged).
pub fn parse(s: str): Value!TomlErr {
  var p = P { cs: s.chars(), i: 0 }
  if p.at('\u{feff}') { p.i += 1 }  // byte order mark
  var d = new_doc()
  var cur = 0           // the table that key/value pairs go into
  var base: [Key] = []  // its header's keys
  loop {
    p.skip_ws()
    if p.eof() { break }
    if p.at('[') {
      (cur, base) = header(&p, &d)?
    } else if !p.at('#') && !p.at('\n') && !p.at('\r') {
      keyval(&p, &d, cur, base)?
    }
    p.end_line()?
  }
  d.build(0)
}

// `[a.b]` or `[[a.b]]`; returns the table that following key/value pairs go into, and its keys.
fn header(p: var P, d: var Doc): (int, [Key])!TomlErr {
  p.i += 1
  let arr = p.at('[')
  if arr { p.i += 1 }
  p.skip_ws()
  let keys = p.key()?
  p.skip_ws()
  p.expect(']', if arr { "']]'" } else { "']'" })?
  if arr {
    p.expect(']', "']]'")?
    return (d.array_table(p, keys)?, keys)
  }
  (d.table(p, keys)?, keys)
}

fn keyval(p: var P, d: var Doc, tab: int, base: [Key]): ()!TomlErr {
  let keys = p.key()?
  p.skip_ws()
  p.expect('=', "'='")?
  p.skip_ws()
  let v = p.value(0)?
  d.set(p, tab, base, keys, v)
}

// A dotted key: simple keys separated by `.` (spaces allowed around the dots).
fn key(p: var P): [Key]!TomlErr {
  var ks = [p.simple_key()?]
  loop {
    let save = p.i
    p.skip_ws()
    if !p.at('.') {
      p.i = save
      break ks
    }
    p.i += 1
    p.skip_ws()
    ks.push(p.simple_key()?)
  }
}

fn simple_key(p: var P): Key!TomlErr {
  let at = p.i
  if p.at('"') { return Key { name: p.basic()?, at } }
  if p.at('\'') { return Key { name: p.literal()?, at } }
  let n = p.cs.len()
  var i = at
  while i < n && bare(p.cs[i]) { i += 1 }
  p.i = i
  if i == at { fail(p.want("a key")) }
  Key { name: core.str(p.cs[at..i]), at }
}

// depth = how many arrays/inline tables enclose this value
fn value(p: var P, depth: int): Value!TomlErr {
  if p.i >= p.cs.len() { fail(p.want("a value")) }
  let c = p.cs[p.i]
  if c == '"' {
    return Str(if p.at_off(1, '"') && p.at_off(2, '"') { p.multi('"')? } else { p.basic()? })
  }
  if digit(c) || c == '+' || c == '-' || c == 'i' || c == 'n' { return p.scalar() }
  match c {
    '[' | '{' when depth >= MAX_DEPTH => fail(TooDeep(line(p.cs, p.i), col(p.cs, p.i)))
    '[' => array(&p, depth + 1)
    '{' => inline_table(&p, depth + 1)
    '\'' => Str(if p.at_off(1, '\'') && p.at_off(2, '\'') { p.multi('\'')? } else { p.literal()? })
    't' => p.word("true", Bool(true))
    'f' => p.word("false", Bool(false))
    _ => fail(p.want("a value"))
  }
}

fn word(p: var P, w: str, v: Value): Value!TomlErr {
  for k in 0..w.len() {
    if !p.at(w[k]) { fail(p.want("a value")) }
    p.i += 1
  }
  v
}

fn array(p: var P, depth: int): Value!TomlErr {
  p.i += 1  // [
  var xs: [Value] = []
  loop {
    p.blank()?
    if p.at(']') {
      p.i += 1
      break List(xs)
    }
    xs.push(p.value(depth)?)
    p.blank()?
    if p.at(',') {
      p.i += 1
    } else if p.at(']') {
      p.i += 1
      break List(xs)
    } else {
      fail(p.want("',' or ']'"))
    }
  }
}

// `{ a = 1, b.c = 2 }`: one line, no trailing comma, closed once written.
fn inline_table(p: var P, depth: int): Value!TomlErr {
  p.i += 1  // {
  p.skip_ws()
  if p.at('}') {
    p.i += 1
    return Map({})
  }
  var d = new_doc()
  loop {
    p.skip_ws()
    let keys = p.key()?
    p.skip_ws()
    p.expect('=', "'='")?
    p.skip_ws()
    let v = p.value(depth)?
    d.set(p, 0, [], keys, v)?
    p.skip_ws()
    if p.at(',') {
      p.i += 1
    } else if p.at('}') {
      p.i += 1
      break d.build(0)
    } else {
      fail(p.want("',' or '}}'"))
    }
  }
}

// ---- strings ----

// "basic": p is on the opening quote. Runs of plain chars are copied a slice at a time.
fn basic(p: var P): str!TomlErr {
  let n = p.cs.len()
  var i = p.i + 1
  var from = i
  var out = ""
  loop {
    if i >= n {
      p.i = i
      fail(p.want("'\"'"))
    }
    let c = p.cs[i]
    if c == '"' {
      if i > from { out += core.str(p.cs[from..i]) }
      p.i = i + 1
      break out
    }
    if c == '\\' {
      if i > from { out += core.str(p.cs[from..i]) }
      p.i = i
      out += p.escape()?
      i = p.i
      from = i
    } else if bad_control(c) {
      p.i = i
      fail(p.control())
    } else {
      i += 1
    }
  }
}

// 'literal': p is on the opening quote.
fn literal(p: var P): str!TomlErr {
  let n = p.cs.len()
  let from = p.i + 1
  var i = from
  loop {
    if i >= n {
      p.i = i
      fail(p.want("\"'\""))
    }
    let c = p.cs[i]
    if c == '\'' {
      p.i = i + 1
      break core.str(p.cs[from..i])
    }
    if bad_control(c) {
      p.i = i
      fail(p.control())
    }
    i += 1
  }
}

// """multi-line basic""" (q = '"') or '''multi-line literal''' (q = '\''). A newline right after
// the opening delimiter is dropped, CRLF becomes LF, and up to two quotes may precede the closing
// delimiter. In basic ones a `\` at the end of a line removes the line break and following blanks.
fn multi(p: var P, q: char): str!TomlErr {
  p.i += 3
  p.newline()
  let n = p.cs.len()
  var i = p.i
  var from = i  // out + cs[from..i] is the text so far
  var out = ""
  loop {
    if i >= n {
      p.i = i
      fail(p.want("{q}{q}{q}"))
    }
    let c = p.cs[i]
    if c == q {
      if i + 2 < n && p.cs[i + 1] == q && p.cs[i + 2] == q {
        var k = 3
        while k < 5 && i + k < n && p.cs[i + k] == q { k += 1 }
        if i + k - 3 > from { out += core.str(p.cs[from..i + k - 3]) }
        p.i = i + k
        break out
      }
      i += 1
    } else if c == '\n' {
      i += 1
    } else if c == '\r' && i + 1 < n && p.cs[i + 1] == '\n' {
      if i > from { out += core.str(p.cs[from..i]) }
      out += "\n"
      i += 2
      from = i
    } else if c == '\\' && q == '"' {
      if i > from { out += core.str(p.cs[from..i]) }
      p.i = i
      if p.line_end_backslash() {
        p.i += 1
        loop {
          if p.at(' ') || p.at('\t') {
            p.i += 1
          } else if !p.newline() {
            break
          }
        }
      } else {
        out += p.escape()?
      }
      i = p.i
      from = i
    } else if bad_control(c) {
      p.i = i
      fail(p.control())
    } else {
      i += 1
    }
  }
}

// p is on a `\` followed only by blanks up to the end of the line.
fn line_end_backslash(p: P): bool {
  var j = p.i + 1
  while j < p.cs.len() && (p.cs[j] == ' ' || p.cs[j] == '\t') { j += 1 }
  j < p.cs.len() &&
    (p.cs[j] == '\n' || (p.cs[j] == '\r' && j + 1 < p.cs.len() && p.cs[j + 1] == '\n'))
}

// p is on the backslash.
fn escape(p: var P): str!TomlErr {
  let start = p.i
  p.i += 1
  let c = p.peek() else fail(p.want("an escape"))
  p.i += 1
  match c {
    'b' => "\u{8}"
    't' => "\t"
    'n' => "\n"
    'f' => "\u{c}"
    'r' => "\r"
    '"' => "\""
    '\\' => "\\"
    'u' => "{p.hex_escape(start, 4)?}"
    'U' => "{p.hex_escape(start, 8)?}"
    _ => fail(BadEscape("\\{c}", line(p.cs, start), col(p.cs, start)))
  }
}

// `\uXXXX` / `\UXXXXXXXX`: a Unicode scalar value (no surrogates).
fn hex_escape(p: var P, start: int, n: int): char!TomlErr {
  var v = 0
  for _ in 0..n {
    let c = p.peek() else fail(p.want("a hex digit"))
    let d = hex_val(c) else fail(p.want("a hex digit"))
    v = v * 16 + d
    p.i += 1
  }
  char(v) else fail(BadEscape(core.str(p.cs[start..p.i]), line(p.cs, start), col(p.cs, start)))
}

fn hex_val(c: char): int? {
  if digit(c) { return int(c) - int('0') }
  if c >= 'a' && c <= 'f' { return int(c) - int('a') + 10 }
  if c >= 'A' && c <= 'F' { return int(c) - int('A') + 10 }
  none
}

// ---- numbers, dates and times ----

let INF = 1.0 / 0.0
let NAN = 0.0 / 0.0

fn token_char(c: char): bool = bare(c) || c == '+' || c == '.' || c == ':'

fn token(p: var P) {
  while p.i < p.cs.len() && token_char(p.cs[p.i]) { p.i += 1 }
}

// A number, date or time; p is on its first char.
fn scalar(p: var P): Value!TomlErr {
  let start = p.i
  match p.plain_number() {
    some(v) => return v
    none => {}
  }
  p.token()
  // a date, a space, and a time: `1979-05-27 07:32:00Z`
  let spaced = p.at(' ') && p.i + 1 < p.cs.len() && digit(p.cs[p.i + 1])
  if spaced && p.i - start == 10 && date_ok(p.cs[start..p.i]) {
    p.i += 1
    p.token()
  }
  let cs = p.cs[start..p.i]
  if datetime_like(cs) {
    let v = datetime(cs) else fail(BadDateTime(core.str(cs), line(p.cs, start), col(p.cs, start)))
    return v
  }
  number(cs) else fail(BadNumber(core.str(cs), line(p.cs, start), col(p.cs, start)))
}

// The usual numbers, read in one pass: when the whole token is `[+-] digits` (at most 18 of them)
// or `[+-] digits . digits`, with no leading zero, takes it and gives its value; otherwise leaves
// p alone and gives none (`number` then decides).
fn plain_number(p: var P): Value? {
  let n = p.cs.len()
  let start = p.i
  var i = start
  let neg = p.cs[i] == '-'
  if neg || p.cs[i] == '+' { i += 1 }
  let from = i
  var acc = 0  // the value of the digits, while there are at most 18 (so it can't overflow)
  while i < n && digit(p.cs[i]) {
    if i - from < 18 { acc = acc * 10 + int(p.cs[i]) - int('0') }
    i += 1
  }
  let digits = i - from
  if digits == 0 || (digits > 1 && p.cs[from] == '0') { return none }
  if i == n || !token_char(p.cs[i]) {
    if digits > 18 { return none }
    p.i = i
    return Int(if neg { -acc } else { acc })
  }
  if p.cs[i] != '.' { return none }
  i += 1
  let frac = i
  while i < n && digit(p.cs[i]) { i += 1 }
  if i == frac || (i < n && token_char(p.cs[i])) { return none }
  let f = float.parse(core.str(p.cs[start..i])) else return none
  p.i = i
  Float(f)
}

fn number(cs: [char]): Value? {
  let t = core.str(cs)
  if t == "inf" || t == "+inf" { return Float(INF) }
  if t == "-inf" { return Float(-INF) }
  if t == "nan" || t == "+nan" || t == "-nan" { return Float(NAN) }
  if t.starts_with("0x") { return radix(cs.skip(2), 16) }
  if t.starts_with("0o") { return radix(cs.skip(2), 8) }
  if t.starts_with("0b") { return radix(cs.skip(2), 2) }
  decimal(cs)
}

// Digits accepted by `ok`, with single `_`s only between digits.
fn grouped(ds: [char], ok: (char) => bool): bool {
  if ds.len() == 0 || ds[0] == '_' || ds[ds.len() - 1] == '_' { return false }
  for i, c in ds {
    if c == '_' {
      if ds[i - 1] == '_' { return false }
    } else if !ok(c) {
      return false
    }
  }
  true
}

// 0x / 0o / 0b digits (no sign); must fit in a 64-bit int.
fn radix(ds: [char], base: int): Value? {
  if !grouped(ds, c => (hex_val(c) else 99) < base) { return none }
  var n = 0
  for c in ds {
    if c == '_' { continue }
    let d = hex_val(c)?
    if n > (9_223_372_036_854_775_807 - d) / base { return none }
    n = n * base + d
  }
  Int(n)
}

// [+-] int-part [. digits] [e [+-] digits]; no leading zeros in the int part.
fn decimal(cs: [char]): Value? {
  let unsigned = if cs.len() > 0 && (cs[0] == '+' || cs[0] == '-') { cs.skip(1) } else { cs }
  let ie = unsigned.find_index(c => c == '.' || c == 'e' || c == 'E') else unsigned.len()
  let ip = unsigned.take(ie)
  if !grouped(ip, c => digit(c)) || (ip.len() > 1 && ip[0] == '0') { return none }
  var j = ie
  var is_float = false
  if j < unsigned.len() && unsigned[j] == '.' {
    let after = unsigned.skip(j + 1)
    let fe = after.find_index(c => c == 'e' || c == 'E') else after.len()
    if !grouped(after.take(fe), c => digit(c)) { return none }
    j = j + 1 + fe
    is_float = true
  }
  if j < unsigned.len() {
    var ep = unsigned.skip(j + 1)  // just past the e / E
    if ep.len() > 0 && (ep[0] == '+' || ep[0] == '-') { ep = ep.skip(1) }
    if !grouped(ep, c => digit(c)) { return none }
    is_float = true
  }
  let clean = core.str(cs.filter(c => c != '_'))
  if is_float { return Float(float.parse(clean) else return none) }
  Int(int.parse(clean) else return none)
}

// `dddd-` (a date) or `dd:` (a local time).
fn datetime_like(cs: [char]): bool = date_start(cs) || time_start(cs)
fn date_start(cs: [char]): bool = cs.len() >= 5 && cs.take(4).all(c => digit(c)) && cs[4] == '-'
fn time_start(cs: [char]): bool = cs.len() >= 3 && digit(cs[0]) && digit(cs[1]) && cs[2] == ':'

// A local date, local time, local date-time or offset date-time, as an RFC 3339 `Str`.
fn datetime(cs: [char]): Value? {
  if cs[2] == ':' {
    if !time_ok(cs) { return none }
    return Str(core.str(cs))
  }
  if cs.len() < 10 || !date_ok(cs.take(10)) { return none }
  let date = core.str(cs.take(10))
  if cs.len() == 10 { return Str(date) }
  if cs[10] != 'T' && cs[10] != 't' && cs[10] != ' ' { return none }
  var clock = cs.skip(11)
  var zone = ""
  let n = clock.len()
  if n > 0 && (clock[n - 1] == 'Z' || clock[n - 1] == 'z') {
    clock = clock.take(n - 1)
    zone = "Z"
  } else if n >= 6 && (clock[n - 6] == '+' || clock[n - 6] == '-') {
    let off = clock.skip(n - 6)
    let h = two(off, 1)?
    let m = two(off, 4)?
    if h > 23 || off[3] != ':' || m > 59 { return none }
    clock = clock.take(n - 6)
    zone = core.str(off)
  }
  if !time_ok(clock) { return none }
  Str(date + "T" + core.str(clock) + zone)
}

// The two-digit number at cs[i..i+2].
fn two(cs: [char], i: int): int? {
  if i + 2 > cs.len() || !digit(cs[i]) || !digit(cs[i + 1]) { return none }
  (int(cs[i]) - int('0')) * 10 + int(cs[i + 1]) - int('0')
}

// YYYY-MM-DD with a real day of that month.
fn date_ok(cs: [char]): bool {
  if cs.len() != 10 || cs[4] != '-' || cs[7] != '-' || !cs.take(4).all(c => digit(c)) {
    return false
  }
  let y = int.parse(core.str(cs.take(4))) else return false
  let m = two(cs, 5) else return false
  let d = two(cs, 8) else return false
  m >= 1 && m <= 12 && d >= 1 && d <= days_in(y, m)
}

fn days_in(y: int, 2): int = if (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 { 29 } else { 28 }
fn days_in(_: int, m: int): int = if m == 4 || m == 6 || m == 9 || m == 11 { 30 } else { 31 }

// HH:MM:SS with an optional fraction; second 60 is a leap second.
fn time_ok(cs: [char]): bool {
  if cs.len() < 8 || cs[2] != ':' || cs[5] != ':' { return false }
  let h = two(cs, 0) else return false
  let m = two(cs, 3) else return false
  let s = two(cs, 6) else return false
  if h > 23 || m > 59 || s > 60 { return false }
  cs.len() == 8 || (cs[8] == '.' && cs.len() > 9 && cs.skip(9).all(c => digit(c)))
}

// ---- writer ----

/// TOML text for a `Map`: plain values first, then `[tables]`, then `[[arrays of tables]]` (a
/// non-empty list whose items are all maps); keys in map order, quoted only when not bare. A
/// `Null` map entry is left out (TOML has no null). Fails when the root isn't a `Map` or a
/// `Null` sits inside an array. Floats always keep a `.` or exponent; NaN and infinities are
/// written `nan`, `inf` and `-inf`.
pub fn str(v: Value): str! {
  let Map(m) = v else fail("toml: the root must be a Map, not {v}")
  var out = ""
  body(m, "", &out)?
  out
}

// path = the table's dotted header keys ("" for the root)
fn body(m: {str: Value}, path: str, out: var str): ()! {
  var subs = false  // any tables or arrays of tables?
  for k, v in m {
    if v is Null { continue }
    if plain(v) {
      out += key_str(k)
      out += " = "
      lit(v, &out)?
      out += "\n"
    } else {
      subs = true
    }
  }
  if !subs { return }
  for k, v in m {
    match v {
      Map(sub) => table_out(sub, sub_path(path, k), &out)?
      _ => {}
    }
  }
  for k, v in m {
    match v {
      List(xs) when aot(xs) => {
        let header = "[[" + sub_path(path, k) + "]]\n"
        for x in xs {
          let Map(sub) = x else continue
          out.blank_line()
          out += header
          body(sub, sub_path(path, k), &out)?
        }
      }
      _ => {}
    }
  }
}

fn sub_path(path: str, k: str): str = if path == "" { key_str(k) } else { path + "." + key_str(k) }

// A sub-table: its header can be left out when it holds only other tables.
fn table_out(m: {str: Value}, path: str, out: var str): ()! {
  var plains = false
  var empty = true
  for _, v in m {
    if v is Null { continue }
    empty = false
    if plain(v) {
      plains = true
      break
    }
  }
  if plains || empty {
    out.blank_line()
    out += "["
    out += path
    out += "]\n"
  }
  body(m, path, &out)
}

fn blank_line(out: var str) {
  if out != "" { out += "\n" }
}

fn aot(xs: [Value]): bool = xs.len() > 0 && xs.all(x => x is Map(_))

// Written as `key = value` (not as a [table] or [[array of tables]]).
fn plain(Map(_)): bool = false
fn plain(List(xs)): bool = !aot(xs)
fn plain(_: Value): bool = true

fn key_str(k: str): str = if bare_key(k) { k } else { quoted(k) }

// Non-empty and all bare chars. (Only an all-ASCII string has as many bytes as chars, and
// indexing one is cheap.)
fn bare_key(k: str): bool {
  let n = k.len()
  if n == 0 || k.byte_len() != n { return false }
  for i in 0..n {
    if !bare(k[i]) { return false }
  }
  true
}

// Appends an inline value.
fn lit(Null, _: var str): ()! = fail("toml: null can't be written inside an array")
fn lit(Bool(b), out: var str): ()! { out += if b { "true" } else { "false" } }
fn lit(Int(n), out: var str): ()! { out += "{n}" }
fn lit(Float(f), out: var str): ()! { out += float_str(f) }
fn lit(Str(s), out: var str): ()! { quote(s, &out) }
fn lit(List(xs), out: var str): ()! {
  out += "["
  for i, x in xs {
    if i > 0 { out += ", " }
    lit(x, &out)?
  }
  out += "]"
}
fn lit(Map(m), out: var str): ()! {
  var first = true
  for k, v in m {
    if v is Null { continue }
    out += if first { r"{ " } else { ", " }
    first = false
    out += key_str(k)
    out += " = "
    lit(v, &out)?
  }
  out += if first { r"{}" } else { r" }" }
}

fn float_str(f: float): str when f != f = "nan"
fn float_str(f: float): str when f - f != 0.0 = if f > 0.0 { "inf" } else { "-inf" }
fn float_str(f: float): str = short(f) else "{f}"  // shortest exact form, always with `.` or `e`

// What "{f}" gives, found cheaply, when f is a decimal of at most 15 digits with at most 6 of
// them after the point (`12.0`, `0.25`, `-1234.5678`); none for anything else. Such a decimal is
// the only one that short that reads back as f, so it is the shortest exact form.
fn short(f: float): str? {
  let a = if f < 0.0 { -f } else { f }
  if !(a >= 0.001 && a < 1e15) { return none }
  var scale = 1.0
  for d in 0..7 {
    let x = a * scale
    if x >= 1e15 { return none }
    let k = int(x + 0.5)
    if float(k) / scale == a {  // k / 10^d, rounded to the nearest float, is f
      let ds = "{k}"
      let sign = if f < 0.0 { "-" } else { "" }
      if d == 0 { return "{sign}{ds}.0" }
      let n = ds.len()
      if n <= d { return "{sign}0.{"0".repeat(d - n)}{ds}" }
      return "{sign}{ds[0..n - d]}.{ds[n - d..n]}"
    }
    scale *= 10.0
  }
  none
}

fn quoted(s: str): str {
  var out = ""
  quote(s, &out)
  out
}

// Appends s in quotes; runs of chars that need no escape are copied a slice at a time.
fn quote(s: str, out: var str) {
  let cs = s.chars()
  let n = cs.len()
  var from = 0
  out += "\""
  for i, c in cs {
    if c == '"' || c == '\\' || c == '\t' || bad_control(c) {
      if i > from { out += core.str(cs[from..i]) }
      out += esc(c)
      from = i + 1
    }
  }
  if from == 0 {
    out += s
  } else if n > from {
    out += core.str(cs[from..n])
  }
  out += "\""
}

fn esc('"'): str = "\\\""
fn esc('\\'): str = "\\\\"
fn esc('\n'): str = "\\n"
fn esc('\r'): str = "\\r"
fn esc('\t'): str = "\\t"
fn esc(c: char): str when bad_control(c) = "\\u00{hex_digit(int(c) / 16)}{hex_digit(int(c) % 16)}"
fn esc(c: char): str = "{c}"

fn hex_digit(n: int): char = "0123456789ABCDEF"[n]

// ---- typed decode / encode ----

/// Parse TOML text and convert it with the compiler-derived `from_value`; the target type comes
/// from the annotation: `let c: Config = toml.decode(fs.read("app.toml")?)?`.
pub fn decode<T: Data>(s: str): T! = from_value(parse(s)?)

/// Convert a value with the derived `to_value` and write it with `str` (so `x` must convert to a
/// `Map`: a struct or a `{str: T}` map).
pub fn encode<T: Data>(x: T): str! = str(to_value(x))

// ---- tests ----

fn m(pairs: {str: Value}): Value = Map(pairs)

test "keys: bare, quoted, dotted, empty" {
  let doc = r"""
key = "value"
bare_key = "value"
bare-key = "value"
1234 = "value"
"127.0.0.1" = "value"
"character encoding" = "value"
"ʎǝʞ" = "value"
'key2' = "value"
'quoted "value"' = "value"
"" = "blank"
"""
  let v = parse(doc)?
  let Map(t) = v else fail("not a map")
  assert t.keys() == [
    "key",
    "bare_key",
    "bare-key",
    "1234",
    "127.0.0.1",
    "character encoding",
    "ʎǝʞ",
    "key2",
    "quoted \"value\"",
    "",
  ]
  assert parse(r"""
name = "Orange"
physical.color = "orange"
physical.shape = "round"
site."google.com" = true
3.14159 = "pi"
fruit . flavor = "banana"
""")? ==
    m({
      "name": Str("Orange"),
      "physical": m({"color": Str("orange"), "shape": Str("round")}),
      "site": m({"google.com": Bool(true)}),
      "3": m({"14159": Str("pi")}),
      "fruit": m({"flavor": Str("banana")}),
    })
}

fn get(v: Value, k: str): Value {
  let Map(t) = v else return Null
  t.get(k) else Null
}

test "strings: basic and multi-line basic" {
  let v = parse(r"""
str = "I'm a string. \"You can quote me\". Name\tJos\u00E9\nLocation\tSF."
esc = "\b\f\r\\\U0001F986"
""")?
  assert get(v, "str") == Str("I'm a string. \"You can quote me\". Name\tJosé\nLocation\tSF.")
  assert get(v, "esc") == Str("\u{8}\u{c}\r\\🦆")
  let q = "\"\"\""
  let fox = "The quick brown fox jumps over the lazy dog."
  let str3 = parse(
    "str3 = {q}\\\n       The quick brown \\\n       fox jumps over \\\n" +
      "       the lazy dog.\\\n       {q}",
  )?
  assert get(str3, "str3") == Str(fox)
  let w = parse(
    "roses = {q}\nRoses are red\r\nViolets are blue{q}\n" +
      "str2 = {q}\nThe quick brown \\\n\n\n  fox jumps over \\  \n    the lazy dog.{q}\n" +
      "str4 = {q}Here are two quotation marks: \"\". Simple enough.{q}\n" +
      "str5 = {q}Here are three quotation marks: \"\"\\\".{q}\n" +
      "str7 = {q}\"This,\" she said, \"is just a pointless statement.{q}\"\n",
  )?
  assert get(w, "roses") == Str("Roses are red\nViolets are blue")
  assert get(w, "str2") == Str("The quick brown fox jumps over the lazy dog.")
  assert get(w, "str4") == Str("Here are two quotation marks: \"\". Simple enough.")
  assert get(w, "str5") == Str("Here are three quotation marks: \"\"\".")
  assert get(w, "str7") == Str("\"This,\" she said, \"is just a pointless statement.\"")
}

test "strings: literal and multi-line literal" {
  let v = parse(r"""
winpath  = 'C:\Users\nodejs\templates'
winpath2 = '\\ServerX\admin$\system32\'
quoted   = 'Tom "Dubs" Preston-Werner'
regex    = '<\i\c*\s*>'
regex2 = '''I [dw]on't need \d{2} apples'''
lines  = '''
The first newline is
trimmed in raw strings.
   All other whitespace
   is preserved.
'''
apos15 = "Here are fifteen apostrophes: '''''''''''''''"
str = ''''That,' she said, 'is still pointless.''''
""")?
  assert get(v, "winpath") == Str(r"C:\Users\nodejs\templates")
  assert get(v, "winpath2") == Str(r"\\ServerX\admin$\system32\")
  assert get(v, "quoted") == Str("Tom \"Dubs\" Preston-Werner")
  assert get(v, "regex") == Str(r"<\i\c*\s*>")
  assert get(v, "regex2") == Str(r"I [dw]on't need \d{2} apples")
  assert get(v, "lines") ==
    Str("The first newline is\ntrimmed in raw strings.\n   All other whitespace\n   is preserved.\n")
  assert get(v, "apos15") == Str("Here are fifteen apostrophes: '''''''''''''''")
  assert get(v, "str") == Str("'That,' she said, 'is still pointless.'")
  let q15 = "\"\"\"\"\"\"\"\"\"\"\"\"\"\"\""
  assert get(parse("quot15 = '''Here are fifteen quotation marks: {q15}'''")?, "quot15") ==
    Str("Here are fifteen quotation marks: {q15}")
}

test "integers" {
  let v = parse(r"""
int1 = +99
int2 = 42
int3 = 0
int4 = -17
int5 = 1_000
int6 = 5_349_221
int7 = 53_49_221
int8 = 1_2_3_4_5
hex1 = 0xDEADBEEF
hex2 = 0xdeadbeef
hex3 = 0xdead_beef
oct1 = 0o01234567
oct2 = 0o755
bin1 = 0b11010110
max = 9223372036854775807
min = -9223372036854775808
hmax = 0x7fffffffffffffff
zero = -0
""")?
  let Map(t) = v else fail("not a map")
  assert t.values() == [
    Int(99),
    Int(42),
    Int(0),
    Int(-17),
    Int(1000),
    Int(5349221),
    Int(5349221),
    Int(12345),
    Int(3735928559),
    Int(3735928559),
    Int(3735928559),
    Int(342391),
    Int(493),
    Int(214),
    Int(9_223_372_036_854_775_807),
    Int(-9_223_372_036_854_775_807 - 1),
    Int(9_223_372_036_854_775_807),
    Int(0),
  ]
}

test "bad integers" {
  for t in [
    "01",
    "-01",
    "1__0",
    "1_",
    "0x",
    "0xg",
    "0x_1",
    "0b2",
    "0o8",
    "+0x1",
    "0X1",
    "9223372036854775808",
    "0x8000000000000000",
    "1-2",
  ] {
    let r = parse("a = {t}")
    assert r is err(BadNumber(_, 1, 5))
    let err(BadNumber(text, _, _)) = r else fail("expected BadNumber for {t}")
    assert text == t
  }
  assert parse("a = 1 2") is err(Unexpected('2', "a newline", 1, 7))
  assert parse("a = _1") is err(Unexpected('_', "a value", 1, 5))
}

test "floats" {
  let v = parse(r"""
flt1 = +1.0
flt2 = 3.1415
flt3 = -0.01
flt4 = 5e+22
flt5 = 1e06
flt6 = -2E-2
flt7 = 6.626e-34
flt8 = 224_617.445_991_228
flt9 = 0.0
flt10 = -0e0
sf1 = inf
sf2 = +inf
sf3 = -inf
""")?
  let Map(t) = v else fail("not a map")
  assert t.values() == [
    Float(1.0),
    Float(3.1415),
    Float(-0.01),
    Float(5e22),
    Float(1e6),
    Float(-0.02),
    Float(6.626e-34),
    Float(224617.445991228),
    Float(0.0),
    Float(-0.0),
    Float(1.0 / 0.0),
    Float(1.0 / 0.0),
    Float(-1.0 / 0.0),
  ]
  for s in ["nan", "+nan", "-nan"] {
    let Float(f) = get(parse("x = {s}")?, "x") else fail("not a float")
    assert f != f
  }
  for t in ["7.", "3.e+20", "1.2_", "1e_5", "01.5", "1.5.3", "1e", "1e+", "1._5", "infinity"] {
    assert parse("a = {t}") is err(BadNumber(_, 1, 5))
  }
  assert parse("a = .7") is err(Unexpected('.', "a value", 1, 5))
}

test "booleans" {
  assert parse("t = true\nf = false")? == Map({"t": Bool(true), "f": Bool(false)})
  assert parse("a = True") is err(Unexpected('T', "a value", 1, 5))
  assert parse("a = tru") is err(Eof("a value", 1, 8))
  assert parse("a = truex") is err(Unexpected('x', "a newline", 1, 9))
}

test "dates and times become RFC 3339 strings" {
  let v = parse(r"""
odt1 = 1979-05-27T07:32:00Z
odt2 = 1979-05-27T00:32:00-07:00
odt3 = 1979-05-27T00:32:00.999999-07:00
odt4 = 1979-05-27 07:32:00Z
odt5 = 1979-05-27t07:32:00z
ldt1 = 1979-05-27T07:32:00
ldt2 = 1979-05-27T00:32:00.999999
ld1 = 1979-05-27 # a comment
ld2 = 2000-02-29
lt1 = 07:32:00
lt2 = 00:32:00.999999
leap = 1990-12-31T23:59:60Z
arr = [1979-05-27, 07:32:00]
""")?
  let Map(t) = v else fail("not a map")
  assert t.values() == [
    Str("1979-05-27T07:32:00Z"),
    Str("1979-05-27T00:32:00-07:00"),
    Str("1979-05-27T00:32:00.999999-07:00"),
    Str("1979-05-27T07:32:00Z"),
    Str("1979-05-27T07:32:00Z"),
    Str("1979-05-27T07:32:00"),
    Str("1979-05-27T00:32:00.999999"),
    Str("1979-05-27"),
    Str("2000-02-29"),
    Str("07:32:00"),
    Str("00:32:00.999999"),
    Str("1990-12-31T23:59:60Z"),
    List([Str("1979-05-27"), Str("07:32:00")]),
  ]
  for t in [
    "1979-13-27",
    "1979-02-30",
    "1900-02-29",
    "1979-5-27",
    "07:32",
    "24:00:00",
    "07:60:00",
    "07:32:00.",
    "1979-05-27T07:32",
    "1979-05-27T07:32:00+25:00",
    "1979-05-27T07:32:00+07",
    "1979-05-27X07:32:00",
  ] {
    let r = parse("d = {t}")
    assert r is err(BadDateTime(_, 1, 5))
  }
  assert parse("d = 1979-05-27 07:32") is err(BadDateTime("1979-05-27 07:32", 1, 5))
}

test "arrays" {
  let v = parse(r"""
integers = [ 1, 2, 3 ]
colors = [ "red", "yellow", "green" ]
nested_arrays_of_ints = [ [ 1, 2 ], [3, 4, 5] ]
nested_mixed_array = [ [ 1, 2 ], ["a", "b", "c"] ]
numbers = [ 0.1, 0.2, 0.5, 1, 2, 5 ]
contributors = [
  "Foo Bar <foo@example.com>",
  { name = "Baz Qux", email = "bazqux@example.com", url = "https://example.com/bazqux" }
]
integers2 = [
  1, 2, 3
]
integers3 = [
  1,
  2, # this is ok
]
empty = [ ]
comments = [ # one
  # two
  1 # three
  , # four
] # five
""")?
  assert get(v, "integers") == List([Int(1), Int(2), Int(3)])
  assert get(v, "colors") == List([Str("red"), Str("yellow"), Str("green")])
  assert get(v, "nested_arrays_of_ints") ==
    List([List([Int(1), Int(2)]), List([Int(3), Int(4), Int(5)])])
  assert get(v, "nested_mixed_array") ==
    List([List([Int(1), Int(2)]), List([Str("a"), Str("b"), Str("c")])])
  assert get(v, "numbers") == List([Float(0.1), Float(0.2), Float(0.5), Int(1), Int(2), Int(5)])
  assert get(v, "contributors") ==
    List([
      Str("Foo Bar <foo@example.com>"),
      Map({
        "name": Str("Baz Qux"),
        "email": Str("bazqux@example.com"),
        "url": Str("https://example.com/bazqux"),
      }),
    ])
  assert get(v, "integers2") == List([Int(1), Int(2), Int(3)])
  assert get(v, "integers3") == List([Int(1), Int(2)])
  assert get(v, "empty") == List([])
  assert get(v, "comments") == List([Int(1)])
  let q = "\"\"\""
  assert get(parse("s = [ \"all\", 'strings', {q}are the same{q}, '''type''' ]")?, "s") ==
    List([Str("all"), Str("strings"), Str("are the same"), Str("type")])
  assert parse("a = [1 2]") is err(Unexpected('2', "',' or ']'", 1, 8))
  assert parse("a = [1,,2]") is err(Unexpected(',', "a value", 1, 8))
  assert parse("a = [,]") is err(Unexpected(',', "a value", 1, 6))
  assert parse("a = [1,") is err(Eof("a value", 1, 8))
}

test "tables" {
  let v = parse(r"""
[table-1]
key1 = "some string"
key2 = 123

[table-2]
key1 = "another string"
key2 = 456

[dog."tater.man"]
type.name = "pug"

[a.b.c]            # this is best practice
[ d.e.f ]          # same as [d.e.f]
[ g .  h  . i ]    # same as [g.h.i]
[ j . "ʞ" . 'l' ]  # same as [j."ʞ".'l']

# [x] you
# [x.y] don't
# [x.y.z] need these
[x.y.z.w] # for this to work
[x] # defining a super-table afterward is ok
""")?
  assert v ==
    Map({
      "table-1": Map({"key1": Str("some string"), "key2": Int(123)}),
      "table-2": Map({"key1": Str("another string"), "key2": Int(456)}),
      "dog": Map({"tater.man": Map({"type": Map({"name": Str("pug")})})}),
      "a": Map({"b": Map({"c": Map({})})}),
      "d": Map({"e": Map({"f": Map({})})}),
      "g": Map({"h": Map({"i": Map({})})}),
      "j": Map({"ʞ": Map({"l": Map({})})}),
      "x": Map({"y": Map({"z": Map({"w": Map({})})})}),
    })
  let w = parse(r"""
# Top-level table begins.
name = "Fido"
breed = "pug"

# Top-level table ends.
[owner]
name = "Regina Dogman"
member_since = 1999-08-04
""")?
  assert w ==
    Map({
      "name": Str("Fido"),
      "breed": Str("pug"),
      "owner": Map({"name": Str("Regina Dogman"), "member_since": Str("1999-08-04")}),
    })
}

test "dotted keys and sub-tables" {
  let v = parse(r"""
fruit.apple.color = "red"
fruit.apple.taste.sweet = true
apple.type = "fruit"
orange.type = "fruit"
apple.skin = "thin"
orange.skin = "thick"

[fruit.apple.texture]  # you can add sub-tables
smooth = true
""")?
  assert v ==
    Map({
      "fruit": Map({
        "apple": Map({
          "color": Str("red"),
          "taste": Map({"sweet": Bool(true)}),
          "texture": Map({"smooth": Bool(true)}),
        }),
      }),
      "apple": Map({"type": Str("fruit"), "skin": Str("thin")}),
      "orange": Map({"type": Str("fruit"), "skin": Str("thick")}),
    })
}

test "inline tables" {
  let v = parse(r"""
name = { first = "Tom", last = "Preston-Werner" }
point = { x = 1, y = 2 }
animal = { type.name = "pug" }
empty = {}
nested = { a = { b = [ { c = 1 } ] } }
points = [ { x = 1, y = 2, z = 3 },
           { x = 7, y = 8, z = 9 },
           { x = 2, y = 4, z = 8 } ]
""")?
  assert get(v, "name") == Map({"first": Str("Tom"), "last": Str("Preston-Werner")})
  assert get(v, "point") == Map({"x": Int(1), "y": Int(2)})
  assert get(v, "animal") == Map({"type": Map({"name": Str("pug")})})
  assert get(v, "empty") == Map({})
  assert get(v, "nested") == Map({"a": Map({"b": List([Map({"c": Int(1)})])})})
  let List(ps) = get(v, "points") else fail("not a list")
  assert ps.len() == 3 && ps[1] == Map({"x": Int(7), "y": Int(8), "z": Int(9)})
  assert parse(r"a = { b = 1, }") is err(Unexpected('}', "a key", 1, 14))
  assert parse("a = {{ b = 1\n}}") is err(Unexpected('\n', "',' or '}}'", 1, 12))
  assert parse(r"a = { b = 1, b = 2 }") is err(DuplicateKey("b", 1, 14))
  assert parse(r"a = { b = 1, b.c = 2 }") is err(NotATable("b", 1, 14))
  assert parse("[product]\ntype = {{ name = \"Nail\" }}\ntype.edible = false") is err(NotATable("product.type", 3, 1))
  assert parse("[product]\ntype.name = \"Nail\"\ntype = {{ edible = false }}") is err(DuplicateKey("product.type", 3, 1))
  assert parse("a = {{b = 1}}\n[a]") is err(DuplicateKey("a", 2, 2))
  assert parse("a = {{b = 1}}\n[a.c]") is err(NotATable("a", 2, 2))
}

test "arrays of tables" {
  let v = parse(r"""
[[products]]
name = "Hammer"
sku = 738594937

[[products]]  # empty table within the array

[[products]]
name = "Nail"
sku = 284758393

color = "gray"
""")?
  assert v ==
    Map({
      "products": List([
        Map({"name": Str("Hammer"), "sku": Int(738594937)}),
        Map({}),
        Map({"name": Str("Nail"), "sku": Int(284758393), "color": Str("gray")}),
      ]),
    })
}

let FRUITS = r"""
[[fruits]]
name = "apple"

[fruits.physical]  # subtable
color = "red"
shape = "round"

[[fruits.varieties]]  # nested array of tables
name = "red delicious"

[[fruits.varieties]]
name = "granny smith"


[[fruits]]
name = "banana"

[[fruits.varieties]]
name = "plantain"
"""

test "the fruits example" {
  assert parse(FRUITS)? ==
    Map({
      "fruits": List([
        Map({
          "name": Str("apple"),
          "physical": Map({"color": Str("red"), "shape": Str("round")}),
          "varieties": List([
            Map({"name": Str("red delicious")}),
            Map({"name": Str("granny smith")}),
          ]),
        }),
        Map({"name": Str("banana"), "varieties": List([Map({"name": Str("plantain")})])}),
      ]),
    })
}

test "redefinitions are errors" {
  assert parse("[fruit]\napple = \"red\"\n\n[fruit]\norange = \"orange\"") is err(DuplicateKey("fruit", 4, 2))
  assert parse("[fruit]\napple = \"red\"\n\n[fruit.apple]\ntexture = \"smooth\"") is err(DuplicateKey("fruit.apple", 4, 2))
  assert parse("[fruit]\napple.color = \"red\"\n[fruit.apple]") is err(DuplicateKey("fruit.apple", 3, 2))
  assert parse("[fruit]\napple.taste.sweet = true\n[fruit.apple.taste]") is err(DuplicateKey("fruit.apple.taste", 3, 2))
  assert parse("[fruit.physical]\ncolor = \"red\"\n\n[[fruit]]\nname = \"apple\"") is err(DuplicateKey("fruit", 4, 3))
  assert parse("fruits = []\n\n[[fruits]]") is err(DuplicateKey("fruits", 3, 3))
  assert parse("[[fruits]]\nname = \"apple\"\n[[fruits.varieties]]\nname = \"x\"\n[fruits.varieties]") is err(DuplicateKey("fruits.varieties", 5, 2))
  assert parse("[[fruits]]\n[fruits.physical]\n[[fruits.physical]]") is err(DuplicateKey("fruits.physical", 3, 3))
  assert parse("a = 1\na = 2") is err(DuplicateKey("a", 2, 1))
  assert parse("a.b = 1\na.b.c = 2") is err(NotATable("a.b", 2, 3))
  assert parse("a = 1\n[a.b]") is err(NotATable("a", 2, 2))
  assert parse("[a.b]\n[a]\nb.c = 1") is err(NotATable("a.b", 3, 1))
  assert parse("[a.b.c]\nz = 9\n[a]\nb.c.t = 1") is err(NotATable("a.b", 4, 1))
  assert parse("[a]\n[a]") is err(DuplicateKey("a", 2, 2))
}

test "syntax errors with positions" {
  assert parse("a: 1") is err(Unexpected(':', "'='", 1, 2))
  assert parse("a = ") is err(Eof("a value", 1, 5))
  assert parse("= 1") is err(Unexpected('=', "a key", 1, 1))
  assert parse("a = \"abc") is err(Eof("'\"'", 1, 9))
  assert parse("a = 'abc") is err(Eof("\"'\"", 1, 9))
  assert parse("a = \"\"\"abc") is err(Eof("\"\"\"", 1, 11))
  assert parse("a = \"\\x\"") is err(BadEscape("\\x", 1, 6))
  assert parse("a = \"\\uD800\"") is err(BadEscape("\\uD800", 1, 6))
  assert parse("a = \"\\u12\"") is err(Unexpected('"', "a hex digit", 1, 10))
  assert parse("a = \"a\nb\"") is err(ControlChar(1, 7))
  assert parse("a = 'a\u{7f}'") is err(ControlChar(1, 7))
  assert parse("# comment\u{1}") is err(ControlChar(1, 10))
  assert parse("[a") is err(Eof("']'", 1, 3))
  assert parse("[[a]") is err(Eof("']]'", 1, 5))
  assert parse("[[a] ]") is err(Unexpected(' ', "']]'", 1, 5))
  assert parse("[a] b = 1") is err(Unexpected('b', "a newline", 1, 5))
  assert parse("a = 1 b = 2") is err(Unexpected('b', "a newline", 1, 7))
  assert parse("a = 1\r") is err(Unexpected('\r', "a newline", 1, 6))
  assert parse("a = 1\r\nb = ?") is err(Unexpected('?', "a value", 2, 5))
  assert parse("a\n= 1") is err(Unexpected('\n', "'='", 1, 2))
  assert parse("[]") is err(Unexpected(']', "a key", 1, 2))
}

test "whitespace, comments and line endings" {
  assert parse("")? == Map({})
  assert parse("\n\n  # only a comment\r\n\t\n")? == Map({})
  assert parse("\u{feff}a = 1")? == Map({"a": Int(1)})
  assert parse("  a\t=\t1  # trailing\r\nb=2")? == Map({"a": Int(1), "b": Int(2)})
  assert parse("a = \"# not a comment\" # a comment")? == Map({"a": Str("# not a comment")})
}

test "nesting limit" {
  var fine = ""
  for _ in 0..MAX_DEPTH { fine += "[" }
  for _ in 0..MAX_DEPTH { fine += "]" }
  assert parse("a = " + fine)? is Map(_)
  var deep = ""
  for _ in 0..5_000 { deep += "[" }
  let err(TooDeep(l, k)) = parse("a = " + deep) else fail("expected TooDeep")
  assert (l, k) == (1, 5 + MAX_DEPTH)
}

test "long input" {
  var lines: [str] = []
  for i in 0..5_000 { lines.push("k{i} = {i}") }
  for i in 0..2_000 { lines.push("[[item]]\nid = {i}\ntags = [\"a\", \"b\"]") }
  let v = parse(lines.join("\n"))?
  assert get(v, "k4999") == Int(4999)
  let List(items) = get(v, "item") else fail("not a list")
  assert items.len() == 2_000
  assert get(items[1_999], "id") == Int(1_999)
  assert parse(str(v)?)? == v
}

test "messages" {
  assert message(Unexpected(':', "'='", 3, 7)) == "3:7: expected '=', found ':'"
  assert message(Unexpected('\n', "'='", 1, 2)) == "1:2: expected '=', found a newline"
  assert message(Unexpected('\r', "a newline", 1, 6)) == "1:6: expected a newline, found U+000D"
  assert message(Eof("a value", 1, 5)) == "1:5: expected a value, found end of input"
  assert message(BadNumber("01", 1, 5)) == "1:5: bad number '01'"
  assert message(DuplicateKey("fruit", 4, 2)) == "4:2: 'fruit' is already defined"
  let err(e) = parse("[a]\nx = 1\n[a]") else fail("expected an error")
  assert message(e) == "3:2: 'a' is already defined"
}

test "writer" {
  let v = Map({
    "a": Int(1),
    "t": Map({"c": Bool(true), "d": List([Int(1), Str("x")])}),
    "b": Str("x\"y\\z\n\u{1}"),
    "arr": List([Map({"n": Int(1)}), Map({"n": Int(2), "s": Map({"k": Float(1.5)})})]),
    "f": Float(1.0),
  })
  assert str(v)? == r"""
a = 1
b = "x\"y\\z\n\u0001"
f = 1.0

[t]
c = true
d = [1, "x"]

[[arr]]
n = 1

[[arr]]
n = 2

[arr.s]
k = 1.5
"""
  assert str(Map({"a": Map({"b": Map({"c": Int(1)})})}))? == "[a.b]\nc = 1\n"
  assert str(Map({"e": Map({})}))? == "[e]\n"
  assert str(Map({}))? == ""
  assert str(Map({"a b": Int(1), "": Int(2), "é": Int(3), "ok_key-1": Int(4)}))? ==
    "\"a b\" = 1\n\"\" = 2\n\"é\" = 3\nok_key-1 = 4\n"
  assert str(Map({"i": Float(1.0 / 0.0), "j": Float(-1.0 / 0.0), "n": Float(0.0 / 0.0)}))? ==
    "i = inf\nj = -inf\nn = nan\n"
  assert str(Map({"x": List([Int(1), Map({"y": Int(2), "z": Null})]), "e": List([])}))? ==
    "x = [1, {{ y = 2 }}]\ne = []\n"
  assert str(Map({"a": Null, "b": Int(1)}))? == "b = 1\n"
  assert str(Map({"a": List([Null])})) is err(_)
  assert str(Int(1)) is err(_)
  assert str(List([])) is err(_)
}

test "round trips" {
  let fruits = parse(FRUITS)?
  assert parse(str(fruits)?)? == fruits
  let values = [
    Map({}),
    Map({"s": Str("tab\tquote\"back\\slash\u{7f}é🦆"), "n": Int(-5), "f": Float(-2.5e-8)}),
    Map({"deep": Map({"er": Map({"x": List([List([]), List([Map({})])])})})}),
    Map({"aot": List([Map({}), Map({"t": Map({"u": Bool(false)})})]), "after": Int(1)}),
    Map({"mixed": List([Int(1), Float(2.0), Str("3"), Map({"four": Int(4)})])}),
  ]
  for v in values {
    assert parse(str(v)?)? == v
  }
}

// used by the decode/encode tests
struct Server { host: str, port: int, tags: [str] }
struct Config { title: str, debug: bool, ratio: float, server: Server }

test "decode and encode" {
  let c: Config = decode(r"""
title = "demo"
debug = true
ratio = 1   # an integer fills a float field

[server]
host = "localhost"
port = 8080
tags = ["a", "b"]
""")?
  assert c == Config {
    title: "demo",
    debug: true,
    ratio: 1.0,
    server: Server { host: "localhost", port: 8080, tags: ["a", "b"] },
  }
  let back: Config = decode(encode(c)?)?
  assert back == c
  let bad: Config! = decode("title = 1")
  assert bad is err(_)
  let syntax: Config! = decode("title = ")
  assert syntax is err(_)
  let m: {str: int} = decode("a = 1\nb = 2")?
  assert m == {"a": 1, "b": 2}
  assert encode(5) is err(_)
}

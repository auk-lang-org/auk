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
  while p.at(' ') || p.at('\t') { p.i += 1 }
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
  p.i += 1
  while p.i < p.cs.len() && p.cs[p.i] != '\n' {
    if p.at('\r') && p.at_off(1, '\n') { break }
    if bad_control(p.cs[p.i]) { fail(p.control()) }
    p.i += 1
  }
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

// One step of a concrete path: a key, or an index into an array of tables.
enum Seg { K(k: str), I(i: int) }

// What a path holds so far, which decides how it may be extended.
enum Kind {
  Implicit,     // a table created by a header's prefix (`[a.b]` creates `a`)
  Header,       // a table defined by its own `[header]`
  Dotted,       // a table created by a dotted key (`a.b = 1` creates `a`)
  Leaf,         // a value, static array or inline table: closed
  Aot(n: int),  // an array of tables with n elements
}

// A value (or, with none, an empty table) at a concrete path. The tree is built at the end.
struct Entry { path: [Seg], v: Value? }

struct Doc { kinds: {str: Kind}, entries: [Entry] }

struct Key { name: str, at: int }

// An unambiguous map key for a path: each key is length-prefixed.
fn pkey(path: [Seg]): str = path.map(s => seg_key(s)).join("")
fn seg_key(K(k)): str = "{k.len()}:{k}"
fn seg_key(I(i)): str = "#{i}"

// `a.b.c`, for messages (array indices left out).
fn dotted(path: [Seg]): str {
  var ks: [str] = []
  for s in path {
    match s {
      K(k) => ks.push(key_str(k))
      I(_) => {}
    }
  }
  ks.join(".")
}

fn kind(d: Doc, path: [Seg]): Kind? = d.kinds.get(pkey(path))

fn add(d: var Doc, path: [Seg], k: Kind, v: Value?) {
  d.kinds[pkey(path)] = k
  d.entries.push(Entry { path, v })
}

fn dup(p: P, path: [Seg], at: int): TomlErr =
  DuplicateKey(dotted(path), line(p.cs, at), col(p.cs, at))

fn not_table(p: P, path: [Seg], at: int): TomlErr =
  NotATable(dotted(path), line(p.cs, at), col(p.cs, at))

// A header's prefix: creates implicit tables and steps into the last element of arrays of tables.
fn walk(d: var Doc, p: P, keys: [Key]): [Seg]!TomlErr {
  var cur: [Seg] = []
  for k in keys {
    cur.push(K(k.name))
    match d.kind(cur) {
      none => d.add(cur, Implicit, none)
      some(Aot(n)) => cur.push(I(n - 1))
      some(Leaf) => fail(p.not_table(cur, k.at))
      some(_) => {}
    }
  }
  cur
}

// `[a.b]`: returns the table's path.
fn table(d: var Doc, p: P, keys: [Key]): [Seg]!TomlErr {
  var cur = d.walk(p, keys.take(keys.len() - 1))?
  cur.push(K(keys[keys.len() - 1].name))
  match d.kind(cur) {
    none => d.add(cur, Header, none)
    some(Implicit) => {
      d.kinds[pkey(cur)] = Header
    }
    some(_) => fail(p.dup(cur, keys[0].at))
  }
  cur
}

// `[[a.b]]`: appends a table and returns its path.
fn array_table(d: var Doc, p: P, keys: [Key]): [Seg]!TomlErr {
  var cur = d.walk(p, keys.take(keys.len() - 1))?
  cur.push(K(keys[keys.len() - 1].name))
  let n = match d.kind(cur) {
    none => 0
    some(Aot(n)) => n
    some(_) => fail(p.dup(cur, keys[0].at))
  }
  d.kinds[pkey(cur)] = Aot(n + 1)
  cur.push(I(n))
  d.entries.push(Entry { path: cur, v: none })
  cur
}

// `a.b.c = v` inside the table at `base`: dotted keys may only extend tables they created.
fn set(d: var Doc, p: P, base: [Seg], keys: [Key], v: Value): ()!TomlErr {
  var cur = base
  for k in keys.take(keys.len() - 1) {
    cur.push(K(k.name))
    match d.kind(cur) {
      none => d.add(cur, Dotted, none)
      some(Dotted) => {}
      some(_) => fail(p.not_table(cur, k.at))
    }
  }
  cur.push(K(keys[keys.len() - 1].name))
  if d.kind(cur) is some(_) { fail(p.dup(cur, keys[0].at)) }
  d.add(cur, Leaf, some(v))
}

// The tree from the entries (all relative to one node). Keys keep their first-seen order.
fn build(es: [Entry]): Value {
  for e in es {
    match e {
      Entry { path: [], v: some(v) } => return v
      _ => {}
    }
  }
  let kids = es.filter(e => e.path.len() > 0)
  if kids.len() == 0 { return Map({}) }
  let groups = kids.group_by(e => e.path[0])
  if kids[0].path[0] is I(_) { return List(groups.values().map(g => build(strip(g)))) }
  var m: {str: Value} = {}
  for seg, g in groups {
    match seg {
      K(k) => {
        m[k] = build(strip(g))
      }
      I(_) => {}
    }
  }
  Map(m)
}

fn strip(es: [Entry]): [Entry] = es.map(e => Entry { path: e.path.skip(1), v: e.v })

// ---- parser ----

/// Parse a TOML 1.0 document into a `Map`. Tables and inline tables become `Map` (keys in
/// document order), arrays and arrays of tables become `List`, integers `Int`, floats `Float`
/// (`inf`/`nan` included), and dates and times `Str` in RFC 3339 form (`1979-05-27T07:32:00Z`;
/// a space or `t` separator becomes `T` and `z` becomes `Z`, otherwise the text is unchanged).
pub fn parse(s: str): Value!TomlErr {
  var p = P { cs: s.chars(), i: 0 }
  if p.at('\u{feff}') { p.i += 1 }  // byte order mark
  var d = Doc { kinds: {}, entries: [] }
  var cur: [Seg] = []
  loop {
    p.skip_ws()
    if p.eof() { break }
    if p.at('[') {
      cur = header(&p, &d)?
    } else if !p.at('#') && !p.at('\n') && !p.at('\r') {
      keyval(&p, &d, cur)?
    }
    p.end_line()?
  }
  build(d.entries)
}

// `[a.b]` or `[[a.b]]`; returns the path that following key/value pairs go into.
fn header(p: var P, d: var Doc): [Seg]!TomlErr {
  p.i += 1
  let arr = p.at('[')
  if arr { p.i += 1 }
  p.skip_ws()
  let keys = p.key()?
  p.skip_ws()
  p.expect(']', if arr { "']]'" } else { "']'" })?
  if arr {
    p.expect(']', "']]'")?
    return d.array_table(p, keys)
  }
  d.table(p, keys)
}

fn keyval(p: var P, d: var Doc, base: [Seg]): ()!TomlErr {
  let keys = p.key()?
  p.skip_ws()
  p.expect('=', "'='")?
  p.skip_ws()
  let v = p.value(0)?
  d.set(p, base, keys, v)
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
  while p.i < p.cs.len() && bare(p.cs[p.i]) { p.i += 1 }
  if p.i == at { fail(p.want("a key")) }
  Key { name: core.str(p.cs[at..p.i]), at }
}

// depth = how many arrays/inline tables enclose this value
fn value(p: var P, depth: int): Value!TomlErr {
  match p.peek() {
    some(c) when (c == '[' || c == '{') && depth >= MAX_DEPTH => {
      fail(TooDeep(line(p.cs, p.i), col(p.cs, p.i)))
    }
    some('"') when p.at_off(1, '"') && p.at_off(2, '"') => Str(p.multi('"')?)
    some('"') => Str(p.basic()?)
    some('\'') when p.at_off(1, '\'') && p.at_off(2, '\'') => Str(p.multi('\'')?)
    some('\'') => Str(p.literal()?)
    some('[') => array(&p, depth + 1)
    some('{') => inline_table(&p, depth + 1)
    some('t') => p.word("true", Bool(true))
    some('f') => p.word("false", Bool(false))
    some(c) when c == '+' || c == '-' || c == 'i' || c == 'n' || digit(c) => p.scalar()
    _ => fail(p.want("a value"))
  }
}

fn word(p: var P, w: str, v: Value): Value!TomlErr {
  for c in w.chars() {
    if !p.at(c) { fail(p.want("a value")) }
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
  var d = Doc { kinds: {}, entries: [] }
  p.skip_ws()
  if p.at('}') {
    p.i += 1
    return Map({})
  }
  loop {
    p.skip_ws()
    let keys = p.key()?
    p.skip_ws()
    p.expect('=', "'='")?
    p.skip_ws()
    let v = p.value(depth)?
    d.set(p, [], keys, v)?
    p.skip_ws()
    if p.at(',') {
      p.i += 1
    } else if p.at('}') {
      p.i += 1
      break build(d.entries)
    } else {
      fail(p.want("',' or '}}'"))
    }
  }
}

// ---- strings ----

// "basic": p is on the opening quote.
fn basic(p: var P): str!TomlErr {
  p.i += 1
  var out: [char] = []
  loop {
    let c = p.peek() else fail(p.want("'\"'"))
    if c == '"' {
      p.i += 1
      break core.str(out)
    }
    if c == '\\' {
      out.push(p.escape()?)
    } else if bad_control(c) {
      fail(p.control())
    } else {
      out.push(c)
      p.i += 1
    }
  }
}

// 'literal': p is on the opening quote.
fn literal(p: var P): str!TomlErr {
  p.i += 1
  let from = p.i
  loop {
    let c = p.peek() else fail(p.want("\"'\""))
    if c == '\'' {
      p.i += 1
      break core.str(p.cs[from..p.i - 1])
    }
    if bad_control(c) { fail(p.control()) }
    p.i += 1
  }
}

// """multi-line basic""" (q = '"') or '''multi-line literal''' (q = '\''). A newline right after
// the opening delimiter is dropped, CRLF becomes LF, and up to two quotes may precede the closing
// delimiter. In basic ones a `\` at the end of a line removes the line break and following blanks.
fn multi(p: var P, q: char): str!TomlErr {
  p.i += 3
  p.newline()
  var out: [char] = []
  loop {
    let c = p.peek() else fail(p.want("{q}{q}{q}"))
    if c == q && p.at_off(1, q) && p.at_off(2, q) {
      var n = 3
      while n < 5 && p.at_off(n, q) { n += 1 }
      for _ in 3..n { out.push(q) }
      p.i += n
      break
    }
    if p.newline() {
      out.push('\n')
    } else if c == '\\' && q == '"' {
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
        out.push(p.escape()?)
      }
    } else if bad_control(c) {
      fail(p.control())
    } else {
      out.push(c)
      p.i += 1
    }
  }
  core.str(out)
}

// p is on a `\` followed only by blanks up to the end of the line.
fn line_end_backslash(p: P): bool {
  var j = p.i + 1
  while j < p.cs.len() && (p.cs[j] == ' ' || p.cs[j] == '\t') { j += 1 }
  j < p.cs.len() &&
    (p.cs[j] == '\n' || (p.cs[j] == '\r' && j + 1 < p.cs.len() && p.cs[j + 1] == '\n'))
}

// p is on the backslash.
fn escape(p: var P): char!TomlErr {
  let start = p.i
  p.i += 1
  let c = p.peek() else fail(p.want("an escape"))
  p.i += 1
  match c {
    'b' => '\u{8}'
    't' => '\t'
    'n' => '\n'
    'f' => '\u{c}'
    'r' => '\r'
    '"' => '"'
    '\\' => '\\'
    'u' => p.hex_escape(start, 4)?
    'U' => p.hex_escape(start, 8)?
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
  let i = "0123456789abcdefABCDEF".chars().find_index(d => d == c)?
  if i < 16 { i } else { i - 6 }
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
  var out: [str] = []
  body(m, [], &out)?
  out.join("")
}

fn body(m: {str: Value}, path: [str], out: var [str]): ()! {
  let ks = m.keys().filter(k => m[k] != Null)
  for k in ks.filter(k => plain(m[k])) {
    out.push(key_str(k) + " = " + lit(m[k])? + "\n")
  }
  for k in ks {
    match m[k] {
      Map(sub) => table_out(sub, path + [k], &out)?
      _ => {}
    }
  }
  for k in ks {
    match m[k] {
      List(xs) when aot(xs) => {
        for x in xs {
          let Map(sub) = x else continue
          out.blank_line()
          out.push("[[" + dotted_keys(path + [k]) + "]]\n")
          body(sub, path + [k], &out)?
        }
      }
      _ => {}
    }
  }
}

// A sub-table: its header can be left out when it holds only other tables.
fn table_out(m: {str: Value}, path: [str], out: var [str]): ()! {
  let vals = m.values().filter(v => v != Null)
  if vals.any(v => plain(v)) || vals.len() == 0 {
    out.blank_line()
    out.push("[" + dotted_keys(path) + "]\n")
  }
  body(m, path, &out)
}

fn blank_line(out: var [str]) {
  if out.len() > 0 { out.push("\n") }
}

fn aot(xs: [Value]): bool = xs.len() > 0 && xs.all(x => x is Map(_))

// Written as `key = value` (not as a [table] or [[array of tables]]).
fn plain(Map(_)): bool = false
fn plain(List(xs)): bool = !aot(xs)
fn plain(_: Value): bool = true

fn dotted_keys(path: [str]): str = path.map(k => key_str(k)).join(".")

fn key_str(k: str): str = if k.len() > 0 && k.chars().all(c => bare(c)) { k } else { quote(k) }

// An inline value.
fn lit(Null): str! = fail("toml: null can't be written inside an array")
fn lit(Bool(b)): str! = if b { "true" } else { "false" }
fn lit(Int(n)): str! = "{n}"
fn lit(Float(f)): str! = float_str(f)
fn lit(Str(s)): str! = quote(s)
fn lit(List(xs)): str! = "[" + (xs.map(x => lit(x))?).join(", ") + "]"
fn lit(Map(m)): str! {
  let ks = m.keys().filter(k => m[k] != Null)
  if ks.len() == 0 { return r"{}" }
  var parts: [str] = []
  for k in ks { parts.push(key_str(k) + " = " + lit(m[k])?) }
  r"{ " + parts.join(", ") + r" }"
}

fn float_str(f: float): str when f != f = "nan"
fn float_str(f: float): str when f - f != 0.0 = if f > 0.0 { "inf" } else { "-inf" }
fn float_str(f: float): str = "{f}"  // shortest exact form, always with `.` or `e`

fn quote(s: str): str = "\"" + s.chars().map(c => esc(c)).join("") + "\""

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

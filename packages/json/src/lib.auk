/// JSON text <-> the core `Value` tree (RFC 8259). Pure: no effects.

/// Why `parse` failed. Every variant carries the 1-based line and column (counted in chars).
pub enum JsonErr {
  Unexpected(found: char, line: int, col: int),  // a char that can't appear here
  Eof(line: int, col: int),                      // the text ended mid-value
  BadNumber(text: str, line: int, col: int),     // e.g. `01`, `1.`, `-`, `1e`
  BadEscape(text: str, line: int, col: int),     // e.g. `\x`, or a lone surrogate `\ud83d`
  ControlChar(line: int, col: int),              // a raw U+0000..U+001F inside a string
  TooDeep(line: int, col: int),                  // arrays/objects nested deeper than MAX_DEPTH
}

/// The deepest nesting `parse` accepts; deeper input is a `TooDeep` error, not a stack overflow.
imprint MAX_DEPTH = 512

/// A one-line description of a parse error, e.g. `2:11: unexpected '}'`.
pub fn message(e: JsonErr): str
fn message(Unexpected(c, l, k)): str = "{l}:{k}: unexpected '{c}'"
fn message(Eof(l, k)): str = "{l}:{k}: unexpected end of input"
fn message(BadNumber(t, l, k)): str = "{l}:{k}: bad number '{t}'"
fn message(BadEscape(t, l, k)): str = "{l}:{k}: bad escape '{t}'"
fn message(ControlChar(l, k)): str = "{l}:{k}: control character in string (escape it)"
fn message(TooDeep(l, k)): str = "{l}:{k}: nested deeper than {MAX_DEPTH}"

// ---- parser: a cursor over the chars; loops for anything long, recursion only per nesting level ----

struct P { cs: [char], i: int }

/// Parse JSON text (RFC 8259) into a `Value`. Integers become `Int` (or `Float` if they don't fit
/// in 64 bits); a number with a fraction or exponent becomes `Float`. A repeated object key keeps
/// its last value. Surrounding whitespace is allowed; anything else after the value is an error.
pub fn parse(s: str): Value!JsonErr {
  var p = P { cs: s.chars(), i: 0 }
  let v = value(&p, 0)?
  p.skip_ws()
  if p.i < p.cs.len() { fail(p.unexpected()) }
  v
}

fn at(p: P, c: char): bool = p.i < p.cs.len() && p.cs[p.i] == c
fn digit(c: char): bool = c >= '0' && c <= '9'

fn skip_ws(p: var P) {
  let n = p.cs.len()
  var i = p.i
  while i < n {
    let c = p.cs[i]
    if c != ' ' && c != '\n' && c != '\t' && c != '\r' { break }
    i += 1
  }
  p.i = i
}

// 1-based position of index i; only computed on the error path.
fn line(cs: [char], i: int): int = cs.take(i).filter(c => c == '\n').len() + 1
fn col(cs: [char], i: int): int = cs.take(i).reverse().take_while(c => c != '\n').len() + 1

fn text(cs: [char], from: int, to: int): str {
  let end = if to < cs.len() { to } else { cs.len() }  // bad_number may ask for one past the end
  core.str(cs[from..end])
}

fn too_deep(p: P): JsonErr = TooDeep(line(p.cs, p.i), col(p.cs, p.i))

fn unexpected(p: P): JsonErr {
  let (l, k) = (line(p.cs, p.i), col(p.cs, p.i))
  match p.cs.get(p.i) {
    some(c) => Unexpected(c, l, k)
    none => Eof(l, k)
  }
}

// depth = how many arrays/objects enclose this value
fn value(p: var P, depth: int): Value!JsonErr {
  p.skip_ws()
  if p.i >= p.cs.len() { fail(p.unexpected()) }
  let c = p.cs[p.i]
  if c == '"' { return Str(string(&p)?) }
  if c == '{' || c == '[' {
    if depth >= MAX_DEPTH { fail(p.too_deep()) }
    return if c == '{' { object(&p, depth + 1) } else { array(&p, depth + 1) }
  }
  if c == '-' || digit(c) { return number(&p) }
  match c {
    't' => word(&p, "true", Bool(true))
    'f' => word(&p, "false", Bool(false))
    'n' => word(&p, "null", Null)
    _ => fail(p.unexpected())
  }
}

fn word(p: var P, w: str, v: Value): Value!JsonErr {
  for k in 0..w.len() {
    if !p.at(w[k]) { fail(p.unexpected()) }
    p.i += 1
  }
  v
}

fn array(p: var P, depth: int): Value!JsonErr {
  p.i += 1  // [
  var xs: [Value] = []
  p.skip_ws()
  if p.at(']') {
    p.i += 1
    return List(xs)
  }
  loop {
    xs.push(value(&p, depth)?)
    p.skip_ws()
    if p.at(',') {
      p.i += 1
    } else if p.at(']') {
      p.i += 1
      break List(xs)
    } else {
      fail(p.unexpected())
    }
  }
}

fn object(p: var P, depth: int): Value!JsonErr {
  p.i += 1  // {
  var m: {str: Value} = {}
  p.skip_ws()
  if p.at('}') {
    p.i += 1
    return Map(m)
  }
  loop {
    p.skip_ws()
    if !p.at('"') { fail(p.unexpected()) }
    let k = string(&p)?
    p.skip_ws()
    if !p.at(':') { fail(p.unexpected()) }
    p.i += 1
    m[k] = value(&p, depth)?
    p.skip_ws()
    if p.at(',') {
      p.i += 1
    } else if p.at('}') {
      p.i += 1
      break Map(m)
    } else {
      fail(p.unexpected())
    }
  }
}

// p is on the opening quote; leaves p just past the closing quote. Runs of plain chars are
// copied a slice at a time; a string with no escapes is one slice.
fn string(p: var P): str!JsonErr {
  let n = p.cs.len()
  var i = p.i + 1
  var from = i
  var out = ""
  loop {
    if i >= n {
      p.i = i
      fail(p.unexpected())
    }
    let c = p.cs[i]
    if c == '"' {
      p.i = i + 1
      if i > from { out += core.str(p.cs[from..i]) }
      break out
    }
    if c == '\\' {
      if i > from { out += core.str(p.cs[from..i]) }
      p.i = i
      out += escape(&p)?
      i = p.i
      from = i
    } else if control(c) {
      fail(ControlChar(line(p.cs, i), col(p.cs, i)))
    } else {
      i += 1
    }
  }
}

// p is on the backslash.
fn escape(p: var P): str!JsonErr {
  let start = p.i
  p.i += 1
  if p.i >= p.cs.len() { fail(p.unexpected()) }
  let c = p.cs[p.i]
  p.i += 1
  match c {
    '"' => "\""
    '\\' => "\\"
    '/' => "/"
    'b' => "\u{8}"
    'f' => "\u{c}"
    'n' => "\n"
    'r' => "\r"
    't' => "\t"
    'u' => unicode(&p, start)?
    _ => fail(BadEscape("\\{c}", line(p.cs, start), col(p.cs, start)))
  }
}

// p is just past `\u`; start is the backslash. Joins a UTF-16 surrogate pair into one code point.
fn unicode(p: var P, start: int): str!JsonErr {
  let hi = hex4(&p)?
  if hi < 0xD800 || hi > 0xDFFF { return "{char(hi)!}" }  // not a surrogate, so a valid char
  // a low surrogate first, or nothing after the high one
  if hi > 0xDBFF || !p.at('\\') { fail(p.bad_escape(start, p.i)) }
  let end = p.i
  p.i += 1
  if !p.at('u') { fail(p.bad_escape(start, end)) }
  p.i += 1
  let lo = hex4(&p)?
  if lo < 0xDC00 || lo > 0xDFFF { fail(p.bad_escape(start, p.i)) }
  "{char(0x10000 + (hi - 0xD800) * 0x400 + (lo - 0xDC00))!}"  // always <= U+10FFFF
}

// the escape text cs[start..end], positioned at its backslash
fn bad_escape(p: P, start: int, end: int): JsonErr =
  BadEscape(p.cs.text(start, end), line(p.cs, start), col(p.cs, start))

fn hex4(p: var P): int!JsonErr {
  var n = 0
  for _ in 0..4 {
    if p.i >= p.cs.len() { fail(p.unexpected()) }
    let d = hex_val(p.cs[p.i]) else fail(p.unexpected())
    n = n * 16 + d
    p.i += 1
  }
  n
}

fn hex_val(c: char): int? {
  if digit(c) { return int(c) - int('0') }
  if c >= 'a' && c <= 'f' { return int(c) - int('a') + 10 }
  if c >= 'A' && c <= 'F' { return int(c) - int('A') + 10 }
  none
}

// U+0000..U+001F
fn control(c: char): bool = int(c) < 0x20

// p is on `-` or a digit. Grammar: -? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?
fn number(p: var P): Value!JsonErr {
  let n = p.cs.len()
  let start = p.i
  var i = start
  let neg = p.cs[i] == '-'
  if neg { i += 1 }
  let from = i
  var acc = 0  // the int part's value, while it has at most 18 digits (so it can't overflow)
  if i < n && p.cs[i] == '0' {
    i += 1
    if i < n && digit(p.cs[i]) {  // leading zero
      p.i = i
      fail(p.bad_number(start))
    }
  } else {
    while i < n && digit(p.cs[i]) {
      if i - from < 18 { acc = acc * 10 + int(p.cs[i]) - int('0') }
      i += 1
    }
    if i == from {
      p.i = i
      fail(p.bad_number(start))
    }
  }
  let int_digits = i - from
  var frac = false
  if i < n && p.cs[i] == '.' {
    p.i = i + 1
    p.digits(start)?
    i = p.i
    frac = true
  }
  if i < n && (p.cs[i] == 'e' || p.cs[i] == 'E') {
    i += 1
    if i < n && (p.cs[i] == '+' || p.cs[i] == '-') { i += 1 }
    p.i = i
    p.digits(start)?
    i = p.i
    frac = true
  }
  p.i = i
  if !frac && int_digits <= 18 { return Int(if neg { -acc } else { acc }) }
  let t = core.str(p.cs[start..i])
  if !frac {
    let v = int.parse(t) else return Float(float.parse(t) else fail(p.bad_number(start)))
    return Int(v)  // else wider than 64 bits: kept as a Float
  }
  Float(float.parse(t) else fail(p.bad_number(start)))
}

// one or more digits
fn digits(p: var P, start: int): ()!JsonErr {
  let n = p.cs.len()
  let from = p.i
  var i = from
  while i < n && digit(p.cs[i]) { i += 1 }
  p.i = i
  if i == from { fail(p.bad_number(start)) }
}

// the number so far plus the offending char, positioned at the number's start
fn bad_number(p: P, start: int): JsonErr =
  BadNumber(p.cs.text(start, p.i + 1), line(p.cs, start), col(p.cs, start))

// ---- writer ----

/// Compact JSON text: no whitespace, object keys in sorted order. A `Float` always keeps a `.` or
/// exponent so it reads back as a `Float`; NaN and infinities (which JSON can't express) become `null`.
pub fn str(v: Value): str {
  var out = ""
  emit(v, &out, "", "")
  out
}

/// Indented JSON text: 2 spaces per level, `"key": value`, object keys in sorted order.
/// Empty arrays and objects stay on one line (`[]`, `{}`).
pub fn pretty(v: Value): str {
  var out = ""
  emit(v, &out, "\n", "  ")
  out
}

// nl = what starts a line at the current indent ("" for compact output, else "\n" + the indent);
// step = "" for compact output, "  " for pretty
fn emit(Null, out: var str, _: str, _: str) { out += "null" }
fn emit(Bool(b), out: var str, _: str, _: str) { out += if b { "true" } else { "false" } }
fn emit(Int(n), out: var str, _: str, _: str) { out += "{n}" }
fn emit(Float(f), out: var str, _: str, _: str) { out += num(f) }
fn emit(Str(s), out: var str, _: str, _: str) { quote(s, &out) }
fn emit(List(xs), out: var str, nl: str, step: str) {
  if xs.len() == 0 {
    out += "[]"
    return
  }
  let inner = nl + step
  out += "["
  for i, x in xs {
    if i > 0 { out += "," }
    out += inner
    emit(x, &out, inner, step)
  }
  out += nl
  out += "]"
}
fn emit(Map(m), out: var str, nl: str, step: str) {
  if m.len() == 0 {
    out += r"{}"
    return
  }
  let inner = nl + step
  let colon = if step == "" { ":" } else { ": " }
  out += r"{"
  for i, k in m.keys().sort() {
    if i > 0 { out += "," }
    out += inner
    quote(k, &out)
    out += colon
    emit(m[k], &out, inner, step)
  }
  out += nl
  out += r"}"
}

fn num(f: float): str when f - f != 0.0 = "null"  // NaN or ±inf
fn num(f: float): str = short(f) else "{f}"       // shortest exact form, e.g. "1.0", "0.1"

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

// Appends s in quotes; runs of chars that need no escape are copied a slice at a time.
fn quote(s: str, out: var str) {
  let cs = s.chars()
  let n = cs.len()
  var from = 0
  out += "\""
  for i, c in cs {
    if c == '"' || c == '\\' || control(c) {
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
fn esc(c: char): str when control(c) = "\\u00{hex_digit(int(c) / 16)}{hex_digit(int(c) % 16)}"
fn esc(c: char): str = "{c}"

fn hex_digit(n: int): char = "0123456789abcdef"[n]

// ---- typed decode / encode ----

/// Parse JSON text and convert it with the compiler-derived `from_value`. The target type comes
/// from the annotation at the call site: `let ts: [Todo] = json.decode(s)?`. Fails with the
/// parse error (a `JsonErr`, converted to `Err`) or the `from_value` error on a shape mismatch.
pub fn decode<T: Data>(s: str): T! = from_value(parse(s)?)

/// Convert any value with the derived `to_value` and write it as compact JSON (see `str`).
pub fn encode<T: Data>(x: T): str = str(to_value(x))

// ---- tests ----

test "literals and whitespace" {
  assert parse("null")? == Null
  assert parse("true")? == Bool(true)
  assert parse("false")? == Bool(false)
  assert parse(" \t\r\n 42 \n")? == Int(42)
  assert parse("\"\"")? == Str("")
  assert parse("nul") is err(Eof(1, 4))
  assert parse("nulL") is err(Unexpected('L', 1, 4))
  assert parse("True") is err(Unexpected('T', 1, 1))
}

test "numbers" {
  assert parse("0")? == Int(0)
  assert parse("-0")? == Int(0)
  assert parse("123")? == Int(123)
  assert parse("-7")? == Int(-7)
  assert parse("9223372036854775807")? == Int(9_223_372_036_854_775_807)
  assert parse("9223372036854775808")? is Float(_)  // too wide for int
  assert parse("1.5")? == Float(1.5)
  assert parse("-0.25")? == Float(-0.25)
  assert parse("1e3")? == Float(1000.0)
  assert parse("1E+2")? == Float(100.0)
  assert parse("2.5e-3")? == Float(0.0025)
  assert parse("10.0")? == Float(10.0)  // a fraction makes it a Float
  assert parse("[1,2.0]")? == List([Int(1), Float(2.0)])
}

test "bad numbers" {
  assert parse("01") is err(BadNumber("01", 1, 1))
  assert parse("-01") is err(BadNumber("-01", 1, 1))
  assert parse("1.") is err(BadNumber("1.", 1, 1))
  assert parse("1.x") is err(BadNumber("1.x", 1, 1))
  assert parse("-") is err(BadNumber("-", 1, 1))
  assert parse("-a") is err(BadNumber("-a", 1, 1))
  assert parse("1e") is err(BadNumber("1e", 1, 1))
  assert parse("1e+") is err(BadNumber("1e+", 1, 1))
  assert parse("[1, 2.e5]") is err(BadNumber("2.e", 1, 5))
  assert parse(".5") is err(Unexpected('.', 1, 1))
  assert parse("+1") is err(Unexpected('+', 1, 1))
  assert parse("0x1f") is err(Unexpected('x', 1, 2))
}

test "strings and escapes" {
  assert parse("\"hello, world\"")? == Str("hello, world")
  assert parse("\"\\\" \\\\ \\/ \\n \\r \\t\"")? == Str("\" \\ / \n \r \t")
  assert parse("\"\\b\\f\"")? == Str("\u{8}\u{c}")
  assert parse("\"\\u0041\\u00e9\\u20AC\"")? == Str("Aé€")
  assert parse("\"\\u0000\"")? == Str("\0")
  assert parse("\"\\ud83d\\ude00\"")? == Str("😀")    // surrogate pair
  assert parse("\"\\uD83D\\uDE00!\"")? == Str("😀!")  // upper-case hex
  assert parse("\"é😀 raw\"")? == Str("é😀 raw")       // non-ASCII passes through
  assert parse("\"a\\u0022b\"")? == Str("a\"b")
}

test "bad strings" {
  assert parse("\"abc") is err(Eof(1, 5))
  assert parse("\"abc\\") is err(Eof(1, 6))
  assert parse("\"\\x\"") is err(BadEscape("\\x", 1, 2))
  assert parse("\"\\u12g4\"") is err(Unexpected('g', 1, 6))
  assert parse("\"\\u12\"") is err(Unexpected('"', 1, 6))
  assert parse("\"\\ud83d\"") is err(BadEscape("\\ud83d", 1, 2))                // lone high
  assert parse("\"\\ude00\"") is err(BadEscape("\\ude00", 1, 2))                // lone low
  assert parse("\"\\ud83d\\n\"") is err(BadEscape("\\ud83d", 1, 2))             // high + other escape
  assert parse("\"\\ud83d\\u0041\"") is err(BadEscape("\\ud83d\\u0041", 1, 2))  // high + non-low
  assert parse("\"a\nb\"") is err(ControlChar(1, 3))                            // raw newline
  assert parse("\"a\tb\"") is err(ControlChar(1, 3))                            // raw tab
}

test "arrays and objects" {
  assert parse("[]")? == List([])
  assert parse("[ ]")? == List([])
  assert parse(r"{}")? == Map({})
  assert parse(r" { } ")? == Map({})
  assert parse("[1, \"a\", true, null, [], [[2]]]")? ==
    List([Int(1), Str("a"), Bool(true), Null, List([]), List([List([Int(2)])])])
  assert parse(r"""{"a": 1, "b": {"c": [null]}, "": "empty key"}""")? ==
    Map({"a": Int(1), "b": Map({"c": List([Null])}), "": Str("empty key")})
  assert parse(r"""{"k": 1, "k": 2}""")? == Map({"k": Int(2)})  // last duplicate wins
  assert parse(r"""
    {
      "list" : [ 1 ,2 ] ,
      "obj":{"x":true}
    }
  """)? == Map({"list": List([Int(1), Int(2)]), "obj": Map({"x": Bool(true)})})
}

test "structural errors" {
  assert parse("") is err(Eof(1, 1))
  assert parse("   ") is err(Eof(1, 4))
  assert parse("[1,") is err(Eof(1, 4))
  assert parse("[1,]") is err(Unexpected(']', 1, 4))   // trailing comma
  assert parse("[1 2]") is err(Unexpected('2', 1, 4))  // missing comma
  assert parse("]") is err(Unexpected(']', 1, 1))
  assert parse("1 2") is err(Unexpected('2', 1, 3))             // trailing data
  assert parse(r"""{"a" 1}""") is err(Unexpected('1', 1, 6))    // missing colon
  assert parse(r"""{"a": 1,}""") is err(Unexpected('}', 1, 9))  // trailing comma
  assert parse(r"""{a: 1}""") is err(Unexpected('a', 1, 2))     // unquoted key
  assert parse(r"""{1: 1}""") is err(Unexpected('1', 1, 2))     // non-string key
  assert parse(r"""{"a": 1""") is err(Eof(1, 8))
  assert parse("[1, 2,\n  x]") is err(Unexpected('x', 2, 3))
  assert parse(r"""{
  "a": tru
}""") is err(Unexpected('\n', 2, 11))
  assert parse("[1]\r\n\r\n  }}") is err(Unexpected('}', 3, 3))  // CRLF counts as one line
}

test "nesting limit" {
  var fine = ""
  for _ in 0..MAX_DEPTH { fine += "[" }
  for _ in 0..MAX_DEPTH { fine += "]" }
  assert parse(fine)? is List(_)
  var deep = ""
  for _ in 0..10_000 { deep += "[" }
  let err(TooDeep(l, k)) = parse(deep) else fail("expected TooDeep")
  assert (l, k) == (1, MAX_DEPTH + 1)
}

test "long input does not overflow" {
  var parts: [str] = []
  for i in 0..100_000 { parts.push("{i}") }
  let List(xs) = parse("[" + parts.join(", ") + "]")? else fail("expected a list")
  assert xs.len() == 100_000
  assert xs[99_999] == Int(99_999)
  let long = parts.join("")
  assert parse("\"" + long + "\"")? == Str(long)
}

test "compact output" {
  assert str(Null) == "null"
  assert str(Bool(false)) == "false"
  assert str(Int(-12)) == "-12"
  assert str(List([])) == "[]"
  assert str(Map({})) == r"{}"
  assert str(List([Int(1), Str("a"), Bool(true), Null])) == "[1,\"a\",true,null]"
  assert str(Map({"b": Int(2), "a": List([Map({})])})) == r"""{"a":[{}],"b":2}"""
  assert str(Str("a\"b\\c/\n\r\t")) == "\"a\\\"b\\\\c/\\n\\r\\t\""
  assert str(Str("\u{1}\u{8}\u{1f}")) == "\"\\u0001\\u0008\\u001f\""
  assert str(Str("é😀")) == "\"é😀\""
}

test "float output" {
  assert str(Float(1.0)) == "1.0"
  assert str(Float(2.5)) == "2.5"
  assert str(Float(-0.5)) == "-0.5"
  assert str(Float(0.0 / 0.0)) == "null"
  assert str(Float(1.0 / 0.0)) == "null"
  assert str(Float(-1.0 / 0.0)) == "null"
  for f in [0.1, 1.0, 1e300, -2.5e-8, 123456789.0] {
    assert parse(str(Float(f)))? == Float(f)
  }
}

test "pretty output" {
  assert pretty(Int(1)) == "1"
  assert pretty(List([])) == "[]"
  let v = Map({
    "name": Str("auk"),
    "tags": List([Str("a"), Int(1)]),
    "empty": Map({}),
    "none": List([]),
    "nested": Map({"x": Null}),
  })
  assert pretty(v) == r"""{
  "empty": {},
  "name": "auk",
  "nested": {
    "x": null
  },
  "none": [],
  "tags": [
    "a",
    1
  ]
}"""
}

test "round trips" {
  let values = [
    Null,
    List([Int(1), Int(-2), Float(3.5), Str("x"), Bool(false)]),
    Map({"a": Map({"b": List([Map({"c": Str("é")})])}), "z": List([])}),
    Map({"esc": Str("\"\\\n/\u{1}😀"), "n": Float(-1.5e-7), "": Null}),
  ]
  for v in values {
    assert parse(str(v))? == v
    assert parse(pretty(v))? == v
  }
  assert str(parse(r"""{"b":1,"a":[true,null]}""")?) == r"""{"a":[true,null],"b":1}"""
}

test "messages" {
  assert message(Unexpected('}', 2, 11)) == r"2:11: unexpected '}'"
  assert message(Eof(1, 4)) == "1:4: unexpected end of input"
  assert message(BadNumber("01", 1, 1)) == "1:1: bad number '01'"
  assert message(TooDeep(1, 513)) == "1:513: nested deeper than 512"
}

// used by the decode/encode tests
struct Todo { id: int, title: str, done: bool }
enum Status { Open, Closed(reason: str) }

test "decode and encode" {
  let t: Todo = decode(r"""{"id": 1, "title": "milk", "done": false}""")?
  assert t == Todo { id: 1, title: "milk", done: false }
  assert encode(t) == r"""{"done":false,"id":1,"title":"milk"}"""
  let ts: [Todo] = decode(encode([t, Todo { id: 2, done: true, ..t }]))?
  assert ts.len() == 2 && ts[1].done && ts[1].title == "milk"
  let s: Status = decode("\"Open\"")?
  assert s == Open
  assert encode(Closed("dup")) == r"""{"reason":"dup","tag":"Closed"}"""
  let c: Status = decode(encode(Closed("dup")))?
  assert c == Closed("dup")
  let n: int = decode(" 7 ")?
  assert n == 7
}

test "decode errors" {
  let syntax: Todo! = decode(r"""{"id": 1,""")
  assert syntax is err(_)
  let wrong_type: Todo! = decode(r"""{"id": "one", "title": "x", "done": false}""")
  assert wrong_type is err(_)
  let missing: Todo! = decode(r"""{"id": 1}""")
  assert missing is err(_)
  let not_obj: Todo! = decode("[]")
  assert not_obj is err(_)
}

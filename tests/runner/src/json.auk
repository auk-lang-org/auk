/// A minimal JSON value with a parser and a serializer (src/json.rs), for the language server
/// (`compiler lsp`) and the MCP server (`compiler mcp`). Numbers are floats (JSON-RPC ids and LSP
/// positions are small integers); objects keep their key order.
///
/// Differences from Rust: the `From` conversions are the `of` overloads; `Display` is `text`;
/// parse errors are `Fail.Bad(msg)` (`T!E` needs an enum) with Rust's messages and byte offsets;
/// the parser works on the text's bytes as Rust's does, building strings from byte runs.

pub enum Json {
  Null,
  Bool(b: bool),
  Num(n: float),
  Str(s: str),
  Arr(xs: [Json]),
  Obj(kvs: [(str, Json)]),
}

/// A parse error: "invalid JSON at byte N: what".
pub enum Fail { Bad(msg: str) }

/// Build an object from `(key, value)` pairs.
pub fn obj(pairs: [(str, Json)]): Json = Json.Obj(pairs)

pub fn of(s: str): Json = Json.Str(s)

pub fn of(b: bool): Json = Json.Bool(b)

pub fn of(n: int): Json = Json.Num(float(n))

pub fn of(xs: [Json]): Json = Json.Arr(xs)

/// The value of `key` in an object (`Null` if missing or not an object).
pub fn get(j: Json, key: str): Json = match j {
  Obj(kvs) => match kvs.find(kv => kv.0 == key) {
    some(kv) => kv.1
    none => Json.Null
  }
  _ => Json.Null
}

/// Follow a chain of object keys.
pub fn at(j: Json, path: [str]): Json = path.reduce(j, (x, k) => x.get(k))

pub fn as_str(j: Json): str? = match j {
  Str(s) => s
  _ => none
}

pub fn as_i64(j: Json): int? = match j {
  Num(n) => if n == floor(n) && is_finite(n) { int(n) } else { none }
  _ => none
}

pub fn as_arr(j: Json): [Json] = match j {
  Arr(xs) => xs
  _ => []
}

pub fn is_null(j: Json): bool = j is Json.Null

fn is_finite(n: float): bool = n - n == 0.0

fn write(j: Json, out: var [str]) {
  match j {
    Null => out.push("null")
    Bool(b) => out.push(if b { "true" } else { "false" })
    Num(n) => if !is_finite(n) {
      out.push("null")
    } else if n == floor(n) && abs(n) < 1e15 {
      out.push("{int(n)}")
    } else {
      out.push("{n}")
    }
    Str(s) => write_str(s, &out)
    Arr(xs) => {
      out.push("[")
      for i, x in xs {
        if i > 0 { out.push(",") }
        write(x, &out)
      }
      out.push("]")
    }
    Obj(kvs) => {
      out.push("{{")
      for i, kv in kvs {
        if i > 0 { out.push(",") }
        write_str(kv.0, &out)
        out.push(":")
        write(kv.1, &out)
      }
      out.push("}}")
    }
  }
}

/// Compact serialization (Rust's `Display`).
pub fn text(j: Json): str {
  var out: [str] = []
  write(j, &out)
  out.join("")
}

fn write_str(s: str, out: var [str]) {
  out.push("\"")
  for c in s.chars() {
    match c {
      '"' => out.push("\\\"")
      '\\' => out.push("\\\\")
      '\n' => out.push("\\n")
      '\r' => out.push("\\r")
      '\t' => out.push("\\t")
      _ => if int(c) < 0x20 { out.push("\\u{int(c):04x}") } else { out.push(str(c)) }
    }
  }
  out.push("\"")
}

/// Parse one JSON value (surrounding whitespace allowed). The error says what and where (byte
/// offset).
pub fn parse(text: str): Json!Fail {
  var p = Parser { s: text.bytes(), i: 0, depth: 0 }
  let v = p.value()?
  p.ws()
  if p.i != p.s.len() { fail(p.err("trailing characters")) }
  v
}

struct Parser { s: [int], i: int, depth: int }

fn err(p: Parser, what: str): Fail = Fail.Bad("invalid JSON at byte {p.i}: {what}")

fn ws(p: var Parser) {
  while p.i < p.s.len() && [32, 9, 10, 13].contains(p.s[p.i]) { p.i += 1 }
}

/// The byte at the cursor, or -1 at the end.
fn peek(p: Parser): int = p.s.get(p.i) else -1

fn eat(p: var Parser, c: char): bool {
  if p.peek() == int(c) {
    p.i += 1
    return true
  }
  false
}

fn lit(p: var Parser, word: str, v: Json): Json!Fail {
  let w = word.bytes()
  if p.i + w.len() <= p.s.len() && p.s[p.i..p.i + w.len()] == w {
    p.i += w.len()
    return v
  }
  fail(p.err("unexpected word"))
}

fn value(p: var Parser): Json!Fail {
  p.ws()
  let c = p.peek()
  if c == -1 { fail(p.err("unexpected end")) }
  if c == int('n') { return p.lit("null", Json.Null) }
  if c == int('t') { return p.lit("true", Json.Bool(true)) }
  if c == int('f') { return p.lit("false", Json.Bool(false)) }
  if c == int('"') { return Json.Str(p.string()?) }
  if c == int('[') {
    // `nested`: skip the bracket and parse the contents, with a nesting limit
    p.depth += 1
    if p.depth > 512 { fail(p.err("nested too deeply")) }
    p.i += 1
    let r = p.array()
    p.depth -= 1
    return r
  }
  if c == int('{') {
    p.depth += 1
    if p.depth > 512 { fail(p.err("nested too deeply")) }
    p.i += 1
    let r = p.object()
    p.depth -= 1
    return r
  }
  if c == int('-') || (c >= int('0') && c <= int('9')) { return p.number() }
  fail(p.err("unexpected character"))
}

fn array(p: var Parser): Json!Fail {
  var xs: [Json] = []
  p.ws()
  if p.eat(']') { return Json.Arr(xs) }
  loop {
    xs.push(p.value()?)
    p.ws()
    if p.eat(']') { return Json.Arr(xs) }
    if !p.eat(',') { fail(p.err("expected `,` or `]`")) }
  }
}

fn object(p: var Parser): Json!Fail {
  var kvs: [(str, Json)] = []
  p.ws()
  if p.eat('}') { return Json.Obj(kvs) }
  loop {
    p.ws()
    if p.peek() != int('"') { fail(p.err("expected a string key")) }
    let k = p.string()?
    p.ws()
    if !p.eat(':') { fail(p.err("expected `:`")) }
    kvs.push((k, p.value()?))
    p.ws()
    if p.eat('}') { return Json.Obj(kvs) }
    if !p.eat(',') { fail(p.err("expected `,` or `}}`")) }
  }
}

/// Skip a run of ASCII digits; how many.
fn digits(p: var Parser): int {
  let s = p.i
  while p.peek() >= int('0') && p.peek() <= int('9') { p.i += 1 }
  p.i - s
}

fn number(p: var Parser): Json!Fail {
  let start = p.i
  let _ = p.eat('-')
  if p.peek() == int('0') {
    p.i += 1
  } else if p.digits() == 0 {
    fail(p.err("expected a digit"))
  }
  if p.eat('.') && p.digits() == 0 { fail(p.err("expected a digit after `.`")) }
  if p.eat('e') || p.eat('E') {
    if !p.eat('+') { let _ = p.eat('-') }
    if p.digits() == 0 { fail(p.err("expected an exponent")) }
  }
  let text = str.from_utf8(p.s[start..p.i]) else ""
  match float.parse(text) {
    ok(n) => Json.Num(n)
    err(_) => fail(p.err("bad number"))
  }
}

fn hex4(p: var Parser): int!Fail {
  if p.i + 4 > p.s.len() { fail(p.err("short \\u escape")) }
  let h = str.from_utf8(p.s[p.i..p.i + 4]) else ""
  // Rust's `u32::from_str_radix`: hex digits, with an optional leading `+`
  var ok = true
  for i, c in h.chars() {
    if !(c.is_digit(16) || (i == 0 && c == '+')) { ok = false }
  }
  let n = if ok { int.parse(h.strip_prefix("+") else h, 16) else -1 } else { -1 }
  if n < 0 { fail(p.err("bad \\u escape")) }
  p.i += 4
  n
}

fn string(p: var Parser): str!Fail {
  p.i += 1 // the opening quote
  var out: [str] = []
  loop {
    // copy a run of plain bytes (valid UTF-8, since the input is a `str`)
    let start = p.i
    while p.i < p.s.len() && p.s[p.i] != int('"') && p.s[p.i] != int('\\') && p.s[p.i] >= 0x20 { p.i += 1 }
    if p.i > start { out.push(str.from_utf8(p.s[start..p.i]) else "") }
    let c = p.peek()
    if c == -1 { fail(p.err("unterminated string")) }
    if c == int('"') {
      p.i += 1
      return out.join("")
    }
    if c != int('\\') { fail(p.err("control character in string")) }
    p.i += 1
    let e = p.peek()
    if e == -1 { fail(p.err("unterminated escape")) }
    p.i += 1
    let esc = char(e) else '?'
    match esc {
      '"' => out.push("\"")
      '\\' => out.push("\\")
      '/' => out.push("/")
      'b' => out.push("\u{8}")
      'f' => out.push("\u{c}")
      'n' => out.push("\n")
      'r' => out.push("\r")
      't' => out.push("\t")
      'u' => {
        let hi = p.hex4()?
        var cp = hi
        if hi >= 0xD800 && hi < 0xDC00 {
          // a surrogate pair: `\ud83e\udd86`
          if !(p.eat('\\') && p.eat('u')) { fail(p.err("unpaired surrogate")) }
          let lo = p.hex4()?
          if !(lo >= 0xDC00 && lo < 0xE000) { fail(p.err("bad low surrogate")) }
          cp = 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)
        }
        let ch = valid_char(cp) else { fail(p.err("bad code point")) }
        out.push(str(ch))
      }
      _ => fail(p.err("unknown escape"))
    }
  }
}

/// Rust's `char::from_u32`: none for surrogates and past U+10FFFF.
fn valid_char(cp: int): char? {
  if cp >= 0xD800 && cp < 0xE000 { return none }
  char(cp)
}

test "scalars" {
  assert parse(" null ")! == Json.Null
  assert parse("true")! == Json.Bool(true)
  assert parse("false")! == Json.Bool(false)
  assert parse("nul") is err(_)
  assert parse("") is err(_)
  assert parse("1 2") is err(_)
}

test "numbers" {
  assert parse("0")! == Json.Num(0.0)
  assert parse("-12")! == Json.Num(-12.0)
  assert parse("3.25")! == Json.Num(3.25)
  assert parse("1e3")! == Json.Num(1000.0)
  assert parse("-2.5E-2")! == Json.Num(-0.025)
  assert parse("42")!.as_i64() == some(42)
  assert parse("4.5")!.as_i64() == none
  for bad in ["-", "1.", ".5", "1e", "+1", "0x10"] { assert parse(bad) is err(_) }
  assert Json.Num(7.0).text() == "7"
  assert Json.Num(-0.5).text() == "-0.5"
}

test "string escapes" {
  assert parse("\"a\\\"b\\\\c\\/d\\n\\t\\r\\b\\f\"")! == Json.Str("a\"b\\c/d\n\t\r\u{8}\u{c}")
  assert parse("\"é中\"")! == Json.Str("é中")
  // a surrogate pair, and raw UTF-8
  assert parse("\"\\ud83e\\udd86 🦆\"")! == Json.Str("🦆 🦆")
  assert parse("\"\\ud83e\"") is err(_)
  assert parse("\"\\q\"") is err(_)
  assert parse("\"a\nb\"") is err(_)
  assert parse("\"open") is err(_)
  let s = "quote \" back \\ nl \n ctl \u{1} auk 🦆"
  assert Json.Str(s).text() == "\"quote \\\" back \\\\ nl \\n ctl \\u0001 auk 🦆\""
  assert parse(Json.Str(s).text())! == Json.Str(s)
  match parse("[1,]") {
    err(Bad(m)) => assert m == "invalid JSON at byte 3: unexpected character"
    ok(_) => assert false
  }
}

test "nesting" {
  let v = parse("{{\"a\": [1, {{\"b\": [true, null]}}, []], \"c\": {{}}, \"d\": \"x\"}}")!
  assert v.at(["a"]).as_arr().len() == 3
  assert v.get("a").as_arr()[1].get("b").as_arr()[0] == Json.Bool(true)
  assert v.get("d").as_str() == some("x")
  assert v.get("missing").is_null()
  assert v.text() == "{{\"a\":[1,{{\"b\":[true,null]}},[]],\"c\":{{}},\"d\":\"x\"}}"
  assert parse("[1,]") is err(_)
  assert parse("{{\"a\" 1}}") is err(_)
  assert parse("[[[") is err(_)
  let deep = "[".repeat(1000) + "]".repeat(1000)
  assert parse(deep) is err(_)
  assert obj([("k", of(1)), ("s", of("v"))]).text() == "{{\"k\":1,\"s\":\"v\"}}"
}

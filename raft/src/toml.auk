/// The TOML subset used by `raft.toml` and `raft.lock` (src/bin/raft/toml.rs): `[table]` and
/// `[[array]]` headers, `key = value` with basic strings, arrays and inline tables, and `#`
/// comments.
///
/// Differences in shape from the Rust: errors are plain `T!` whose message is Rust's `String`
/// error; an inline table's entries are `[Entry]` (Rust's `Vec<(String, Value)>`); the parser's
/// methods take a `var Parser`. (packages/toml parses full TOML with other messages, so raft keeps
/// its own subset.)

/// A value: a string, an array, or an inline table.
pub enum Value {
  Str(s: str),
  List(xs: [Value]),
  Table(es: [Entry]),
}

/// One `key = value` of a table.
pub struct Entry {
  key: str,
  value: Value,
}

pub fn as_str(v: Value): str? {
  match v {
    Str(s) => s
    _ => none
  }
}

/// The value as an array of strings.
pub fn as_strs(v: Value): [str]? {
  match v {
    List(xs) => {
      var out: [str] = []
      for x in xs { out.push(as_str(x)?) }
      out
    }
    _ => none
  }
}

/// A `[name]` table or one `[[name]]` element. The first table of a document is the root (`name` empty).
pub struct Table {
  name: str,
  array: bool,
  entries: [Entry],
}

pub fn new_table(name: str, array: bool): Table = Table { name, array, entries: [] }

pub fn get(t: Table, key: str): Value? = t.entries.find(e => e.key == key)?.value

/// Parse a document (Rust's `Doc` is `[Table]`). Errors read `line N: message`.
pub fn parse(src: str): [Table]! {
  var p = Parser { s: src.chars(), i: 0, line: 1 }
  var doc = [new_table("", false)]
  loop {
    p.skip_blank()
    match p.peek() {
      none => return doc
      some('[') => {
        p.i += 1
        let array = p.eat('[')
        p.skip_ws()
        let name = p.key()?
        p.skip_ws()
        if !p.eat(']') || (array && !p.eat(']')) {
          return p.err("expected `]` after table name")
        }
        if !array && doc.any(t => t.name == name) {
          return p.err("duplicate table [{name}]")
        }
        doc.push(new_table(name, array))
      }
      some(_) => {
        let key = p.key()?
        p.skip_ws()
        if !p.eat('=') {
          return p.err("expected `=` after `{key}`")
        }
        p.skip_ws()
        let value = p.value()?
        let n = doc.len() - 1
        if get(doc[n], key) is some(_) {
          return p.err("duplicate key `{key}`")
        }
        doc[n].entries.push(Entry { key, value })
      }
    }
    p.end_line()?
  }
}

struct Parser {
  s: [char],
  i: int,
  line: int,
}

fn peek(p: Parser): char? = p.s.get(p.i)

fn eat(p: var Parser, c: char): bool {
  let hit = p.peek() == some(c)
  if hit { p.i += 1 }
  hit
}

fn err<T>(p: Parser, msg: str): T! = fail("line {p.line}: {msg}")

/// Skip spaces and tabs.
fn skip_ws(p: var Parser) {
  while p.peek() == some(' ') || p.peek() == some('\t') { p.i += 1 }
}

/// Skip whitespace, newlines and comments.
fn skip_blank(p: var Parser) {
  loop {
    p.skip_ws()
    match p.peek() {
      some('\n') => p.line += 1
      some('\r') => {}
      some('#') => {
        while !(p.peek() == none || p.peek() == some('\n')) { p.i += 1 }
        continue
      }
      _ => return
    }
    p.i += 1
  }
}

/// After an item: optional comment, then a newline or end of input.
fn end_line(p: var Parser): ()! {
  p.skip_ws()
  match p.peek() {
    none | some('\n') | some('\r') | some('#') => {}
    some(c) => return p.err("unexpected `{c}`")
  }
}

fn is_key_char(c: char): bool = (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') ||
  c == '_' ||
  c == '-' ||
  c == '.'

/// A bare (`A-Za-z0-9_-`) or quoted key.
fn key(p: var Parser): str! {
  if p.peek() == some('"') {
    return p.string()
  }
  let start = p.i
  while is_key_char(p.peek() else ' ') { p.i += 1 }
  if start == p.i {
    return p.err("expected a key")
  }
  str(p.s[start..p.i])
}

fn value(p: var Parser): Value! {
  match p.peek() {
    some('"') => Str(p.string()?)
    some('[') => {
      p.i += 1
      var xs: [Value] = []
      loop {
        p.skip_blank()
        if p.eat(']') {
          return List(xs)
        }
        xs.push(p.value()?)
        p.skip_blank()
        if !p.eat(',') && p.peek() != some(']') {
          return p.err("expected `,` or `]` in array")
        }
      }
    }
    some('{') => {
      p.i += 1
      var entries: [Entry] = []
      p.skip_ws()
      if p.eat('}') {
        return Table(entries)
      }
      loop {
        p.skip_ws()
        let key = p.key()?
        p.skip_ws()
        if !p.eat('=') {
          return p.err("expected `=` after `{key}`")
        }
        p.skip_ws()
        if entries.any(e => e.key == key) {
          return p.err("duplicate key `{key}`")
        }
        entries.push(Entry { key, value: p.value()? })
        p.skip_ws()
        if p.eat('}') {
          return Table(entries)
        }
        if !p.eat(',') {
          return p.err("expected `,` or `}}` in inline table")
        }
      }
    }
    _ => p.err("expected a value (raft.toml supports strings, arrays and inline tables)")
  }
}

/// A `"basic string"` with `\" \\ \n \t \r \uXXXX` escapes.
fn string(p: var Parser): str! {
  p.i += 1
  var out: [char] = []
  loop {
    let c = p.peek() else return p.err("unterminated string")
    p.i += 1
    match c {
      '"' => return str(out)
      '\n' => return p.err("unterminated string")
      '\\' => {
        let e = p.peek()
        p.i += 1
        out.push(
          match e {
            some('"') => '"'
            some('\\') => '\\'
            some('n') => '\n'
            some('t') => '\t'
            some('r') => '\r'
            some('u') => {
              let hex = str(p.s.skip(p.i).take(4))
              p.i += 4
              // `u32::from_str_radix` also takes a leading `+`
              let digits = hex.strip_prefix("+") else hex
              let code = if hex.len() == 4 &&
                digits != "" &&
                digits.chars().all(h => h.is_digit(16)) {
                int.parse(digits, 16) else -1
              } else {
                -1
              }
              match char(code) {
                some(c) => c
                none => return p.err("bad \\u escape")
              }
            }
            _ => return p.err("bad escape in string")
          },
        )
      }
      c => out.push(c)
    }
  }
}

/// Rust's `char::is_control`: the Cc category (U+0000–U+001F, U+007F–U+009F).
fn is_control(c: char): bool = int(c) < 0x20 || (int(c) >= 0x7f && int(c) <= 0x9f)

/// Render a value in the form `parse` reads back.
pub fn value_str(v: Value): str {
  match v {
    Str(s) => {
      var out = "\""
      for c in s.chars() {
        if c == '"' {
          out += "\\\""
        } else if c == '\\' {
          out += "\\\\"
        } else if c == '\n' {
          out += "\\n"
        } else if c == '\t' {
          out += "\\t"
        } else if c == '\r' {
          out += "\\r"
        } else if is_control(c) {
          out += "\\u{int(c):04x}"
        } else {
          out += str(c)
        }
      }
      out += "\""
      out
    }
    List(xs) => "[{xs.map(value_str).join(", ")}]"
    Table(es) => {
      if es.len() == 0 { return "{{}}" }
      let parts = es.map(e => "{key_str(e.key)} = {value_str(e.value)}")
      "{{ {parts.join(", ")} }}"
    }
  }
}

fn key_str(k: str): str {
  let bare = k != "" && k.chars().all(c => c != '.' && is_key_char(c))
  if bare { k } else { value_str(Str(k)) }
}

/// Render a document, one blank line between tables.
pub fn write(doc: [Table]): str {
  var out = ""
  for t in doc {
    if t.name == "" && t.entries.len() == 0 { continue }
    if out != "" { out += "\n" }
    if t.name != "" {
      let (l, r) = if t.array { ("[[", "]]") } else { ("[", "]") }
      out += "{l}{t.name}{r}\n"
    }
    for e in t.entries { out += "{key_str(e.key)} = {value_str(e.value)}\n" }
  }
  out
}

let MANIFEST = """
  # a comment
  [package]
  name = "weather"   # trailing comment
  version = "0.1.0"
  effects = ["net", "fs"]

  [deps]
  http = "^0.1"
  geo  = {{ path = "../geo" }}
  "quoted key" = "a \\"b\\" \\\\ é"
  multi = [
    "x",   # comment inside an array
    "y",
  ]

  [[package]]
  name = "a"

  [[package]]
  name = "b"
  """

test "parse manifest" {
  let doc = parse(MANIFEST)?
  assert doc.map(t => t.name) == ["", "package", "deps", "package", "package"]
  assert as_str(get(doc[1], "name")!) == some("weather")
  assert as_strs(get(doc[1], "effects")!) == some(["net", "fs"])
  let geo = Table([Entry { key: "path", value: Str("../geo") }])
  assert get(doc[2], "geo") == some(geo)
  assert as_str(get(doc[2], "quoted key")!) == some("a \"b\" \\ é")
  assert as_strs(get(doc[2], "multi")!) == some(["x", "y"])
  assert doc[3].array && doc[4].array
}

test "round trip" {
  let doc = parse(MANIFEST)?
  let text = write(doc)
  assert parse(text)? == doc
  assert write(parse(text)?) == text
  assert text.contains("geo = {{ path = \"../geo\" }}\n")
}

fn parse_err(s: str): str {
  match parse(s) {
    ok(_) => ""
    err(e) => "{e}"
  }
}

test "errors" {
  assert parse_err("a = 1") ==
    "line 1: expected a value (raft.toml supports strings, arrays and inline tables)"
  assert parse_err("\n\na = \"x") == "line 3: unterminated string"
  assert parse_err("a = \"x\"\na = \"y\"") == "line 2: duplicate key `a`"
  assert parse_err("[t]\n[t]") == "line 2: duplicate table [t]"
  assert parse_err("a = \"x\" b") == "line 1: unexpected `b`"
}

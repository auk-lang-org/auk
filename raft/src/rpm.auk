/// Talking to an rpm registry (rpm.auk-lang.org, the default): its JSON API under `/api/v1`.
/// `GET /api/v1/packages/<name>` lists a package's versions; `GET .../<version>/download` gives
/// one version's files, base64-encoded, with the checksum; `POST /api/v1/packages` publishes a
/// version from the same list of files. rpm's checksum is raft's: sha256 of the files as a
/// bundle (bundle.auk), so a download is checked before it is unpacked.
///
/// raft has no dependencies (the seed builds it), so the JSON reader and writer and base64 are
/// small ones of its own.

/// One published version of a package.
pub struct Release {
  version: semver.Version,
  checksum: str,
  yanked: bool,
}

/// What a registry URL says about a package.
pub enum Answer {
  /// An rpm registry's published versions.
  Found(rs: [Release]),
  /// An rpm registry without the package.
  Missing,
  /// Not an rpm answer: the URL may be a plain bundle host.
  NotRpm,
}

pub fn releases(reg: str, name: str): Answer uses net {
  let r = fetch.request(fetch.join(reg, "api/v1/packages/{name}")) else return NotRpm()
  let (status, headers, body) = r
  let json_reply = (headers.get("content-type") else "").starts_with("application/json")
  if status == 404 && json_reply { return Missing() }
  if status != 200 || !json_reply { return NotRpm() }
  let text = str.from_utf8(body) else return NotRpm()
  let v = parse(text) else return NotRpm()
  let vs = match field(v, "versions") {
    some(Arr(xs)) => xs
    _ => return NotRpm()
  }
  var out: [Release] = []
  for x in vs {
    let version = semver.parse_version(text_of(field(x, "version")) else continue) else continue
    let checksum = text_of(field(x, "checksum")) else continue
    let yanked = field(x, "yanked") == some(Bool(true))
    out.push(Release { version, checksum, yanked })
  }
  Found(out)
}

/// The version to install from `rs`: the locked one when it is still published and fits `want`
/// (even if yanked, so locked projects keep working), else the newest unyanked one that fits,
/// else the newest unyanked one (which the caller then reports as not matching).
pub fn choose(rs: [Release], want: semver.Req?, locked: str?): Release? {
  let fits = (r: Release) => match want {
    some(q) => semver.matches(q, r.version)
    none => true
  }
  match locked {
    some(l) => match rs.find(r => semver.show(r.version) == l && fits(r)) {
      some(r) => return r
      none => {}
    }
    none => {}
  }
  var best: Release? = none
  var any: Release? = none
  for r in rs {
    if r.yanked { continue }
    if newer(r, any) { any = r }
    if fits(r) && newer(r, best) { best = r }
  }
  if best != none { best } else { any }
}

fn newer(r: Release, than: Release?): bool = match than {
  some(t) => semver.cmp(r.version, t.version) > 0
  none => true
}

/// Download version `r` of `name` as a bundle, checked against rpm's checksum.
pub fn download(reg: str, name: str, r: Release): [int]! uses net {
  let url = fetch.join(reg, "api/v1/packages/{name}/{semver.show(r.version)}/download")
  let body = fetch.get(url)?
  let text = str.from_utf8(body) else fail("the reply is not UTF-8")
  let v = parse(text)?
  let entries = match field(v, "files") {
    some(Arr(xs)) => xs
    _ => fail("the reply has no files")
  }
  var files: [(str, [int])] = []
  for e in entries {
    let path = text_of(field(e, "path")) else fail("a file has no path")
    let b64 = text_of(field(e, "base64")) else fail("{path} has no contents")
    files.push((path, base64(b64)?))
  }
  let data = bundle.encode(files.sort_by(f => f.0))
  let sum = "sha256:{sha256.hex(data)}"
  if sum != r.checksum {
    fail("checksum mismatch: the registry lists {r.checksum}, the files hash to {sum}")
  }
  data
}

/// What the registry answered to a publish.
pub struct Published {
  name: str,
  version: str,
  checksum: str,
}

/// Publish `files` (relative path, contents) as a new version, as the account `token` belongs
/// to. The registry reads the name and version from the `raft.toml` among them.
pub fn publish(reg: str, token: str, files: [(str, [int])]): Published! uses net {
  var body = "{{\"files\":[".bytes()
  for i, (path, bytes) in files {
    if i > 0 { body.push(44) }
    body += "{{\"path\":{quote(path)},\"base64\":\"".bytes()
    body += to_base64(bytes)
    body += "\"}}".bytes()
  }
  body += "]}}".bytes()
  let headers = [("Authorization", "Bearer {token}"), ("Content-Type", "application/json")]
  let (status, _, reply) = fetch.post(fetch.join(reg, "api/v1/packages"), headers, body)?
  let not_rpm = "HTTP {status}, and not an rpm answer"
  let v = parse(str.from_utf8(reply) else fail(not_rpm)) else fail(not_rpm)
  match text_of(field(v, "error")) {
    some(e) => fail(e)
    none => {}
  }
  if status != 200 && status != 201 { fail(not_rpm) }
  Published {
    name: text_of(field(v, "name")) else fail(not_rpm),
    version: text_of(field(v, "version")) else fail(not_rpm),
    checksum: text_of(field(v, "checksum")) else fail(not_rpm),
  }
}

/// `s` as a JSON string.
fn quote(s: str): str {
  let hex = "0123456789abcdef".chars()
  var out = "\""
  for c in s.chars() {
    let n = int(c)
    if c == '"' || c == '\\' {
      out += "\\{c}"
    } else if n < 32 {
      out += "\\u00{hex[n >> 4]}{hex[n & 15]}"
    } else {
      out += "{c}"
    }
  }
  out + "\""
}

/// Bytes as standard base64 (padded), in ASCII.
pub fn to_base64(bs: [int]): [int] {
  let abc = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".bytes()
  var out: [int] = []
  var i = 0
  while i < bs.len() {
    let left = bs.len() - i
    let n = (bs[i] << 16) |
      if left > 1 { bs[i + 1] } else { 0 } << 8 |
      if left > 2 { bs[i + 2] } else { 0 }
    out.push(abc[n >> 18])
    out.push(abc[(n >> 12) & 63])
    out.push(if left > 1 { abc[(n >> 6) & 63] } else { 61 })
    out.push(if left > 2 { abc[n & 63] } else { 61 })
    i += 3
  }
  out
}

/// A JSON value. Numbers keep their text: raft only reads strings, booleans, arrays and objects.
pub enum Json {
  Null,
  Bool(b: bool),
  Num(n: str),
  Text(s: str),
  Arr(xs: [Json]),
  Obj(es: [(str, Json)]),
}

/// `key` of an object.
fn field(v: Json, key: str): Json? = match v {
  Obj(es) => es.find(e => e.0 == key)?.1
  _ => none
}

fn text_of(v: Json?): str? = match v {
  some(Text(s)) => s
  _ => none
}

struct P {
  s: [char],
  i: int,
}

pub fn parse(text: str): Json! {
  var p = P { s: text.chars(), i: 0 }
  let v = p.value()?
  p.ws()
  if p.i != p.s.len() { fail("JSON: unexpected text at {p.i}") }
  v
}

fn ws(p: var P) {
  while p.i < p.s.len() && [' ', '\n', '\r', '\t'].contains(p.s[p.i]) { p.i += 1 }
}

fn word(p: var P, w: str, v: Json): Json! {
  let cs = w.chars()
  if p.s.skip(p.i).take(cs.len()) != cs { fail("JSON: bad value at {p.i}") }
  p.i += cs.len()
  v
}

fn value(p: var P): Json! {
  p.ws()
  let c = p.s.get(p.i) else fail("JSON: unexpected end")
  match c {
    '{' => {
      p.i += 1
      var es: [(str, Json)] = []
      p.ws()
      if p.s.get(p.i) == some('}') {
        p.i += 1
        return Obj(es)
      }
      loop {
        p.ws()
        if p.s.get(p.i) != some('"') { fail("JSON: expected a key at {p.i}") }
        let k = p.string()?
        p.ws()
        if p.s.get(p.i) != some(':') { fail("JSON: expected `:` at {p.i}") }
        p.i += 1
        es.push((k, p.value()?))
        p.ws()
        match p.s.get(p.i) {
          some(',') => p.i += 1
          some('}') => {
            p.i += 1
            return Obj(es)
          }
          _ => fail("JSON: expected `,` or `}}` at {p.i}")
        }
      }
    }
    '[' => {
      p.i += 1
      var xs: [Json] = []
      p.ws()
      if p.s.get(p.i) == some(']') {
        p.i += 1
        return Arr(xs)
      }
      loop {
        xs.push(p.value()?)
        p.ws()
        match p.s.get(p.i) {
          some(',') => p.i += 1
          some(']') => {
            p.i += 1
            return Arr(xs)
          }
          _ => fail("JSON: expected `,` or `]` at {p.i}")
        }
      }
    }
    '"' => Text(p.string()?)
    't' => p.word("true", Bool(true))
    'f' => p.word("false", Bool(false))
    'n' => p.word("null", Null())
    _ => {
      let start = p.i
      while p.i < p.s.len() &&
        (p.s[p.i].is_digit() || ['-', '+', '.', 'e', 'E'].contains(p.s[p.i])) {
        p.i += 1
      }
      if p.i == start { fail("JSON: unexpected `{c}` at {p.i}") }
      Num(str(p.s[start..p.i]))
    }
  }
}

fn string(p: var P): str! {
  p.i += 1
  var out: [char] = []
  loop {
    let c = p.s.get(p.i) else fail("JSON: unterminated string")
    p.i += 1
    match c {
      '"' => return str(out)
      '\\' => {
        let e = p.s.get(p.i) else fail("JSON: unterminated string")
        p.i += 1
        match e {
          '"' => out.push('"')
          '\\' => out.push('\\')
          '/' => out.push('/')
          'b' => out.push(char(8)!)
          'f' => out.push(char(12)!)
          'n' => out.push('\n')
          'r' => out.push('\r')
          't' => out.push('\t')
          'u' => {
            var code = p.hex4()?
            // a surrogate pair
            if code >= 0xd800 &&
              code < 0xdc00 &&
              p.s.get(p.i) == some('\\') &&
              p.s.get(p.i + 1) == some('u') {
              p.i += 2
              let lo = p.hex4()?
              code = 0x10000 + ((code - 0xd800) << 10) + (lo - 0xdc00)
            }
            out.push(char(code) else '\u{fffd}')
          }
          _ => fail("JSON: bad escape at {p.i}")
        }
      }
      c => out.push(c)
    }
  }
}

fn hex4(p: var P): int! {
  let h = str(p.s.skip(p.i).take(4))
  if h.len() != 4 || !h.chars().all(c => c.is_digit(16)) { fail("JSON: bad \\u escape at {p.i}") }
  p.i += 4
  int.parse(h, 16)?
}

/// Standard base64 (with or without `=` padding) to bytes.
pub fn base64(s: str): [int]! {
  var out: [int] = []
  var acc = 0
  var bits = 0
  for c in s.chars() {
    if c == '=' { break }
    let n = int(c)
    let d = if n >= 65 && n <= 90 {
      n - 65
    } else if n >= 97 && n <= 122 {
      n - 71
    } else if n >= 48 && n <= 57 {
      n + 4
    } else if c == '+' {
      62
    } else if c == '/' {
      63
    } else {
      fail("bad base64")
    }
    acc = ((acc << 6) | d) & 0xffffff
    bits += 6
    if bits >= 8 {
      bits -= 8
      out.push((acc >> bits) & 0xff)
    }
  }
  out
}

test "json" {
  let v = parse("{{\"a\": [1, -2.5e3, true, null], \"b\": \"x\\\"\\u00e9\\ud83e\\udd86\", \"c\": {{}}}}")?
  assert field(v, "a") == some(Arr([Num("1"), Num("-2.5e3"), Bool(true), Null()]))
  assert text_of(field(v, "b")) == some("x\"é🦆")
  assert field(v, "c") == some(Obj([]))
  assert parse("[1,]") is err(_)
  assert parse("{{}} x") is err(_)
}

test "base64" {
  assert base64("")? == []
  assert base64("TWFu")? == "Man".bytes()
  assert base64("TWE=")? == "Ma".bytes()
  assert base64("TQ==")? == "M".bytes()
  assert base64("AP8=")? == [0, 255]
  assert base64("a*b") is err(_)
  for text in ["", "M", "Ma", "Man", "Many"] {
    assert base64(str.from_utf8(to_base64(text.bytes()))?)? == text.bytes()
  }
  assert to_base64([0, 255]) == "AP8=".bytes()
}

test "quote" {
  assert quote("src/a.auk") == "\"src/a.auk\""
  assert parse(quote("a\"b\\c\n\u{1}é"))? == Text("a\"b\\c\n\u{1}é")
}

fn pick_in(rs: [Release], want: str?, locked: str?): str? {
  let q = match want {
    some(w) => semver.parse_req(w)
    none => none
  }
  let c = choose(rs, q, locked)?
  semver.show(c.version)
}

test "choose" {
  let r = (v: str, y: bool) => Release {
    version: semver.parse_version(v)!,
    checksum: "",
    yanked: y,
  }
  let rs = [r("0.1.0", false), r("0.2.0", false), r("0.2.1", true), r("1.0.0", false)]
  let pick = (want: str?, locked: str?) => pick_in(rs, want, locked)
  assert pick(none, none) == some("1.0.0")
  assert pick(some("^0.2"), none) == some("0.2.0")
  assert pick(some("^0.2"), some("0.2.1")) == some("0.2.1")
  assert pick(some("^0.2"), some("0.1.0")) == some("0.2.0")
  assert pick(some("^3.0"), none) == some("1.0.0")
  assert choose([r("1.0.0", true)], none, none) == none
}

/// Downloading over HTTP(S) with core `net` (raft has no dependencies, since the seed builds it
/// before anything is installed, so this is a small client of its own rather than packages/http:
/// GET, and POST for `raft publish`).
/// Bodies are bytes (ints 0..255), framed by chunked encoding, `Content-Length` or close; up to
/// 5 redirects are followed. TLS always verifies the server (core `net.tls`).

/// A URL raft fetches from: `http://` or `https://`.
pub fn is_url(s: str): bool = s.starts_with("https://") || s.starts_with("http://")

/// `base` and `name` joined with one `/`.
pub fn join(base: str, name: str): str = if base.ends_with("/") {
  base + name
} else {
  "{base}/{name}"
}

/// A parsed http(s) URL: `target` is the path and query (starting with `/`), no fragment.
struct Url {
  tls: bool,
  host: str,
  port: int,
  target: str,
}

fn parse(s: str): Url! {
  let (tls, rest) = match s.strip_prefix("https://") {
    some(r) => (true, r)
    none => match s.strip_prefix("http://") {
      some(r) => (false, r)
      none => fail("not an http or https URL")
    }
  }
  let rest = match rest.split("#") {
    [r, ..] => r
    _ => rest
  }
  let (auth, target) = match rest.find("/") {
    some(i) => (rest[0..i], rest[i..rest.len()])
    none => match rest.find("?") {
      some(i) => (rest[0..i], "/" + rest[i..rest.len()])
      none => (rest, "/")
    }
  }
  if auth.contains("@") { fail("credentials in URLs are not supported") }
  let default = if tls { 443 } else { 80 }
  let (host, port) = if auth.starts_with("[") {
    let close = auth.find("]") else fail("bad host")
    let h = auth[1..close]
    let p = auth[close + 1..auth.len()]
    if p == "" {
      (h, default)
    } else {
      let ps = p.strip_prefix(":") else fail("bad host")
      (h, port_of(ps, default)?)
    }
  } else {
    match auth.split(":") {
      [h] => (h, default)
      [h, p] => (h, port_of(p, default)?)
      _ => fail("bad host")
    }
  }
  if host == "" { fail("missing host") }
  Url { tls, host: host.lower(), port, target }
}

fn port_of(p: str, default: int): int! {
  if p == "" { return default }
  if !p.chars().all(c => c.is_digit()) { fail("bad port `{p}`") }
  let n = int.parse(p) else fail("bad port `{p}`")
  if n < 1 || n > 65535 { fail("port out of range: {n}") }
  n
}

fn show(u: Url): str {
  let h = if u.host.contains(":") { "[{u.host}]" } else { u.host }
  let default = if u.tls { 443 } else { 80 }
  let auth = if u.port == default { h } else { "{h}:{u.port}" }
  "{if u.tls { "https" } else { "http" }}://{auth}{u.target}"
}

/// A redirect's `Location` against the URL it came from: absolute, `//host/..`, `/path`, or
/// relative to the current directory.
fn resolve(base: Url, loc: str): str {
  if is_url(loc) { return loc }
  let scheme = if base.tls { "https:" } else { "http:" }
  if loc.starts_with("//") { return scheme + loc }
  let root = show(Url { target: "", ..base })
  if loc.starts_with("/") { return root + loc }
  let path = match base.target.split("?") {
    [p, ..] => p
    _ => base.target
  }
  let parts = path.split("/")
  let dir = parts.take(parts.len() - 1).join("/") + "/"
  root + dir + loc
}

/// GET `url`, following redirects; the body of the final 200 response.
pub fn get(url: str): [int]! uses net {
  let (status, _, body) = request(url)?
  if status != 200 { fail("HTTP {status}") }
  body
}

/// GET `url`, following redirects: the final response's (status, lower-cased headers, body).
pub fn request(url: str): (int, {str: str}, [int])! uses net {
  var cur = url
  for _ in 0..6 {
    let u = parse(cur)?
    let (status, headers, body) = once(u)?
    if [301, 302, 303, 307, 308].contains(status) {
      let loc = headers.get("location") else fail("{status} redirect without a Location")
      cur = resolve(u, loc)
      continue
    }
    return (status, headers, body)
  }
  fail("too many redirects")
}

/// POST `body` to `url` with `headers` added: the response's (status, lower-cased headers,
/// body). Redirects are not followed, so the headers (a token) go to `url` only.
pub fn post(url: str, headers: [(str, str)], body: [int]): (int, {str: str}, [int])! uses net {
  send(parse(url)?, "POST", headers, body)
}

/// Whether what is sent to `url` stays private: https, or http to this machine.
pub fn private(url: str): bool {
  match parse(url) {
    ok(u) => u.tls || ["localhost", "127.0.0.1", "::1"].contains(u.host)
    err(_) => false
  }
}

/// One GET on its own connection.
fn once(u: Url): (int, {str: str}, [int])! uses net = send(u, "GET", [], [])

/// One request on its own connection, read until the server closes it.
fn send(u: Url, method: str, extra: [(str, str)], body: [int]): (int, {str: str}, [int])! uses net {
  let h = if u.host.contains(":") { "[{u.host}]" } else { u.host }
  let default = if u.tls { 443 } else { 80 }
  let host = if u.port == default { h } else { "{h}:{u.port}" }
  var req = "{method} {u.target} HTTP/1.1\r\nHost: {host}\r\nUser-Agent: raft\r\nAccept: */*\r\nConnection: close\r\n"
  for (k, v) in extra { req += "{k}: {v}\r\n" }
  if method != "GET" { req += "Content-Length: {body.len()}\r\n" }
  var data = "{req}\r\n".bytes()
  data += body
  var c = if u.tls { net.tls(u.host, u.port)? } else { net.tcp(u.host, u.port)? }
  var buf: [int] = []
  let r = exchange(&c, data, &buf)
  c.close()
  r?
  decode(buf)
}

fn exchange(c: var net.Conn, data: [int], buf: var [int]): ()! uses net {
  c.write(data)?
  loop {
    let got = c.read(65536)?
    if got.len() == 0 { break }
    for b in got { buf.push(b) }
  }
}

/// (status, lower-cased headers, body) of a whole response; 1xx responses are skipped.
fn decode(bs: [int]): (int, {str: str}, [int])! {
  let end = index_of(bs, [13, 10, 13, 10], 0) else fail("bad response: no end of headers")
  let head = str.from_utf8(bs[0..end]) else fail("bad response: headers are not UTF-8")
  let lines = head.split("\r\n")
  let status = match lines[0].split(" ") {
    [v, code, ..] when v.starts_with("HTTP/1.") &&
      code.len() == 3 &&
      code.chars().all(c => c.is_digit()) => int.parse(code)?
    _ => fail("bad response: status line `{lines[0]}`")
  }
  var headers: {str: str} = {}
  for line in lines.skip(1) {
    match line.find(":") {
      some(i) => {
        let k = line[0..i].trim().lower()
        let v = line[i + 1..line.len()].trim()
        headers[k] = match headers.get(k) {
          some(old) => "{old}, {v}"
          none => v
        }
      }
      none => fail("bad response: header line `{line}`")
    }
  }
  let rest = bs[end + 4..bs.len()]
  if status < 200 { return decode(rest) }
  let body = match headers.get("transfer-encoding") {
    some(te) when te.lower().ends_with("chunked") => dechunk(rest)?
    some(_) => rest
    none => match headers.get("content-length") {
      some(n) => {
        let len = int.parse(n.trim()) else fail("bad response: Content-Length `{n}`")
        if rest.len() < len { fail("body truncated: got {rest.len()} of {len} bytes") }
        rest[0..len]
      }
      none => rest
    }
  }
  (status, headers, body)
}

/// `size-in-hex[;ext]\r\n data \r\n ... 0\r\n ...` (trailers ignored).
fn dechunk(bs: [int]): [int]! {
  var out: [int] = []
  var pos = 0
  loop {
    let eol = index_of(bs, [13, 10], pos) else fail("chunked body truncated")
    var n = 0
    var i = pos
    while i < eol && bs[i] != 59 && bs[i] != 32 && bs[i] != 9 {
      let d = hex(bs[i])
      if d < 0 || i - pos >= 15 { fail("bad chunk size") }
      n = n * 16 + d
      i += 1
    }
    if i == pos { fail("bad chunk size") }
    if n == 0 { return out }
    let start = eol + 2
    let stop = start + n
    if stop + 2 > bs.len() { fail("chunked body truncated") }
    for j in start..stop { out.push(bs[j]) }
    pos = stop + 2
  }
}

fn hex(b: int): int = if b >= 48 && b <= 57 {
  b - 48
} else if b >= 97 && b <= 102 {
  b - 87
} else if b >= 65 && b <= 70 {
  b - 55
} else {
  -1
}

/// The first index at or after `from` where `pat` occurs in `bs`.
fn index_of(bs: [int], pat: [int], from: int): int? {
  var i = from
  while i + pat.len() <= bs.len() {
    var j = 0
    while j < pat.len() && bs[i + j] == pat[j] { j += 1 }
    if j == pat.len() { return i }
    i += 1
  }
  none
}

test "parse URLs" {
  assert parse("https://pkgs.example.org/auk/json.raft")? ==
    Url { tls: true, host: "pkgs.example.org", port: 443, target: "/auk/json.raft" }
  assert parse("http://127.0.0.1:8080")? ==
    Url { tls: false, host: "127.0.0.1", port: 8080, target: "/" }
  assert parse("http://[::1]:9/x?y#z")? == Url { tls: false, host: "::1", port: 9, target: "/x?y" }
  assert parse("ftp://a/b") is err(_)
  assert parse("https://u:p@a/b") is err(_)
  assert parse("http://a:99999/") is err(_)
}

test "private" {
  assert private("https://rpm.auk-lang.org") &&
    private("http://127.0.0.1:8080") &&
    private("http://[::1]:9/x")
  assert !private("http://rpm.auk-lang.org") && !private("rpm.auk-lang.org")
}

test "redirect locations" {
  let u = parse("https://a.io/pkgs/json.raft")?
  assert resolve(u, "https://b.io/x") == "https://b.io/x"
  assert resolve(u, "//c.io/y") == "https://c.io/y"
  assert resolve(u, "/z") == "https://a.io/z"
  assert resolve(u, "v2/json.raft") == "https://a.io/pkgs/v2/json.raft"
}

test "decode framing" {
  let plain = "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabcdef".bytes()
  assert (decode(plain)?).2 == "abc".bytes()
  let chunked = "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2;x\r\nde\r\n0\r\n\r\n".bytes()
  assert (decode(chunked)?).2 == "abcde".bytes()
  let moved = decode("HTTP/1.1 302 Found\r\nLocation: /b\r\n\r\n".bytes())?
  assert moved.0 == 302 && moved.1.get("location") == some("/b")
}

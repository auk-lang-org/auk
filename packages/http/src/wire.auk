/// HTTP/1.1 wire format (module `http.wire`): serialize a request, parse a response.
/// Pure functions over strings and bytes (`[int]`, 0–255); errors are plain `Err`
/// messages that lib.auk wraps in `HttpErr`.

/// Serializes a request: request line, `Host`, `User-Agent: auk-http/0.1`, the caller's
/// headers (sorted by name), `Content-Length` (in UTF-8 bytes; sent when the body is
/// non-empty or the method is POST/PUT/PATCH) and `Connection: close`. The caller may
/// override `Host` and `User-Agent`; their `Content-Length`, `Transfer-Encoding` and
/// `Connection` are ignored because this client owns message framing.
pub fn encode(method: str, target: str, host: str, headers: {str: str}, body: str): str! {
  if method == "" || method.contains(" ") || has_crlf(method) { fail("bad method: {method}") }
  var has_host = false
  var has_agent = false
  var theirs = ""  // the caller's header lines
  for k in headers.keys().sort() {
    let v = headers[k]
    if k == "" || k.contains(":") || k.contains(" ") || has_crlf(k) || has_crlf(v) {
      fail("bad header: {k}")
    }
    let name = k.lower()
    if name == "host" {
      has_host = true
    } else if name == "user-agent" {
      has_agent = true
    }
    if !framing(name) { theirs.push_line(k, v) }
  }
  var out = method
  out += " "
  out += target
  out += " HTTP/1.1\r\n"
  if !has_host { out.push_line("Host", host) }
  if !has_agent { out += "User-Agent: auk-http/0.1\r\n" }
  out += theirs
  let n = body.byte_len()
  if n > 0 || sends_body(method) { out.push_line("Content-Length", str(n)) }
  out += "Connection: close\r\n\r\n"
  out += body
  out
}

// Appends the header line `name: value` and its CRLF.
fn push_line(out: var str, name: str, value: str) {
  out += name
  out += ": "
  out += value
  out += "\r\n"
}

fn has_crlf(s: str): bool = s.contains("\r") || s.contains("\n")

fn framing("content-length"): bool = true
fn framing("transfer-encoding"): bool = true
fn framing("connection"): bool = true
fn framing(_: str): bool = false

fn sends_body("POST"): bool = true
fn sends_body("PUT"): bool = true
fn sends_body("PATCH"): bool = true
fn sends_body(_: str): bool = false

/// Parses a whole response, as read until the server closed the connection.
/// Returns (status, headers, body). Header names are lower-cased and repeats are joined
/// with ", ". The body is framed by `Transfer-Encoding: chunked`, else `Content-Length`,
/// else everything up to close. Interim 1xx responses are skipped; HEAD responses
/// (`head_req`), 1xx, 204 and 304 have no body.
pub fn decode(bs: [int], head_req: bool): (int, {str: str}, str)! = decode_from(bs, 0, head_req)

// The response that starts at bs[from].
fn decode_from(bs: [int], from: int, head_req: bool): (int, {str: str}, str)! {
  let end = head_end(bs, from) else fail("no end of headers")
  let head = str.from_utf8(bs[from..end]) else fail("headers are not UTF-8")
  let [status_line, ..fields] = head.split("\r\n") else fail("empty response")
  let status = parse_status(status_line)?
  let headers = parse_headers(fields)?
  if status < 200 && status != 101 { return decode_from(bs, end + 4, head_req) }
  let raw = body_bytes(status, headers, bs, end + 4, head_req)?
  let body = str.from_utf8(raw) else fail("body is not UTF-8")
  (status, headers, body)
}

// `HTTP/1.x code [reason]`: the code is the second word.
fn parse_status(line: str): int! {
  let i = line.find(" ") else fail("bad status line: {line}")
  if !line.starts_with("HTTP/1.") { fail("bad status line: {line}") }
  let rest = line[i + 1..line.len()]
  match rest.find(" ") {
    some(j) => status_code(rest[0..j])?
    none => status_code(rest)?
  }
}

fn status_code(code: str): int! {
  if code.len() != 3 || !code.chars().all(c => c.is_digit()) { fail("bad status code: {code}") }
  let n = int.parse(code) else fail("bad status code: {code}")
  if n < 100 { fail("bad status code: {code}") }
  n
}

fn parse_headers(lines: [str]): {str: str}! {
  var hs: {str: str} = {}
  for line in lines {
    let i = line.find(":") else fail("bad header line: {line}")
    let name = line[0..i]
    // A name with surrounding space also rejects obsolete line folding.
    if name == "" || name != name.trim() { fail("bad header line: {line}") }
    let k = name.lower()
    let v = line[i + 1..line.len()].trim()
    hs[k] = match hs.get(k) { some(old) => old + ", " + v, none => v }
  }
  hs
}

// The body bytes of a response whose head ends just before bs[at].
fn body_bytes(_: int, _: {str: str}, _: [int], _: int, true): [int]! = []
fn body_bytes(204, _: {str: str}, _: [int], _: int, _: bool): [int]! = []
fn body_bytes(304, _: {str: str}, _: [int], _: int, _: bool): [int]! = []
fn body_bytes(s: int, _: {str: str}, _: [int], _: int, _: bool): [int]! when s < 200 = []
fn body_bytes(_: int, hs: {str: str}, bs: [int], at: int, _: bool): [int]! = framed(hs, bs, at)

// Transfer-Encoding beats Content-Length (RFC 9112 §6.3); a non-chunked encoding reads to close.
fn framed(hs: {str: str}, bs: [int], at: int): [int]! = match hs.get("transfer-encoding") {
  some(te) => if te.lower().ends_with("chunked") { dechunk(bs, at) } else { bs[at..bs.len()] }
  none => match hs.get("content-length") {
    some(n) => fixed(n, bs, at)
    none => bs[at..bs.len()]
  }
}

fn fixed(len: str, bs: [int], at: int): [int]! {
  if len == "" || !len.chars().all(c => c.is_digit()) { fail("bad Content-Length: {len}") }
  let n = int.parse(len) else fail("bad Content-Length: {len}")
  let got = bs.len() - at
  if got < n { fail("body truncated: got {got} of {n} bytes") }
  bs[at..at + n]
}

// Decodes `size-in-hex[;ext]\r\n data \r\n ... 0\r\n [trailers] \r\n`, from bs[at] on. Trailers
// are ignored.
fn dechunk(bs: [int], at: int): [int]! = match chunks(bs, at, -1)? {
  Whole(body, _) => body
  _ => fail("chunked body truncated")
}

// The chunks of a chunked body starting at `from`, or how far they got. `max` bounds the body
// size (-1: no bound).
enum Chunks {
  Partial,                      // more bytes are needed
  TooBig,                       // the body would exceed `max`
  Whole(body: [int], at: int),  // `at` is just past the last-chunk line `0\r\n`
}

fn chunks(bs: [int], from: int, max: int): Chunks! {
  var out: [int] = []
  var pos = from
  loop {
    let eol = crlf(bs, pos) else return Partial
    let size = chunk_size(bs, pos, eol)?
    if size == 0 { break Whole(out, eol + 2) }
    if max >= 0 && out.len() + size > max { return TooBig }
    let start = eol + 2
    let stop = start + size
    if stop + 2 > bs.len() { return Partial }
    if bs[stop] != 13 || bs[stop + 1] != 10 { fail(NOT_CRLF) }
    out += bs[start..stop]  // in place: linear
    pos = stop + 2
  }
}

fn chunk_size(bs: [int], from: int, to: int): int! {
  var n = 0
  var i = from
  while i < to && !size_end(bs[i]) {
    let d = hex(bs[i])
    if d < 0 { fail("bad chunk size") }
    if i - from >= 15 { fail("chunk size too large") }  // 15 hex digits fit in an int
    n = n * 16 + d
    i += 1
  }
  if i == from { fail("missing chunk size") }
  n
}

// ';' starts a chunk extension; space or tab may precede it.
fn size_end(59): bool = true
fn size_end(32): bool = true
fn size_end(9): bool = true
fn size_end(_: int): bool = false

// The value of an ASCII hex digit byte, or -1.
fn hex(b: int): int when b >= 48 && b <= 57 = b - 48
fn hex(b: int): int when b >= 97 && b <= 102 = b - 87
fn hex(b: int): int when b >= 65 && b <= 70 = b - 55
fn hex(_: int): int = -1

// First index >= from of a CRLF in `bs`.
fn crlf(bs: [int], from: int): int? {
  let last = bs.len() - 1
  var i = from
  while i < last {
    if bs[i] == 13 && bs[i + 1] == 10 { return i }
    i += 1
  }
  none
}

// First index >= from of the empty line (CRLF CRLF) that ends a head.
fn head_end(bs: [int], from: int): int? {
  let last = bs.len() - 3
  var i = from
  while i < last {
    if bs[i] == 13 && bs[i + 1] == 10 && bs[i + 2] == 13 && bs[i + 3] == 10 { return i }
    i += 1
  }
  none
}

// ---- the server side: parse a request, serialize a response ----

/// The most header bytes a request may have (431 beyond it).
pub let MAX_HEAD = 65536
/// The most body bytes a request may have (413 beyond it).
pub let MAX_BODY = 16777216

/// Why a request can't be served; `status(e)` is the response code to send.
pub enum ReqErr {
  BadRequest(why: str),      // 400
  TooLarge,                  // 413: the body is over MAX_BODY
  HeadTooLarge,              // 431: the head is over MAX_HEAD
  NotImplemented(why: str),  // 501: a transfer coding other than chunked
  BadVersion(version: str),  // 505: not HTTP/1.0 or HTTP/1.1
}

/// The response status for a request error.
pub fn status(e: ReqErr): int
fn status(BadRequest(_)): int = 400
fn status(TooLarge): int = 413
fn status(HeadTooLarge): int = 431
fn status(NotImplemented(_)): int = 501
fn status(BadVersion(_)): int = 505

/// A one-line description of a request error.
pub fn message(e: ReqErr): str
fn message(BadRequest(why)): str = "bad request: {why}"
fn message(TooLarge): str = "request body larger than {MAX_BODY} bytes"
fn message(HeadTooLarge): str = "request headers larger than {MAX_HEAD} bytes"
fn message(NotImplemented(why)): str = "not implemented: {why}"
fn message(BadVersion(v)): str = "unsupported HTTP version: {v}"

/// The result of decoding the bytes of a request read so far.
pub enum Got {
  /// Incomplete: read until there are at least `need` bytes, then decode again. `cont` is true
  /// when the head is complete and asks for `Expect: 100-continue`.
  More(need: int, cont: bool),
  /// A whole request. `target` is in origin form (`/path?query`, or `*`); header names are
  /// lower-case (repeats joined with ", ").
  Done(method: str, target: str, headers: {str: str}, body: str),
}

/// Decodes a request: request line, headers, then a body framed by `Transfer-Encoding: chunked`
/// or `Content-Length` (neither: no body). Chunked trailers are ignored, as are any bytes after
/// the request (there is no pipelining: every response closes the connection). HTTP/1.1
/// requests must carry `Host`. An absolute-form target (`http://h/p`) is reduced to `/p`.
pub fn decode_request(bs: [int]): Got!ReqErr {
  var p = progress()
  decode_request(bs, &p)
}

/// How far decoding a request that arrives in pieces got. Start with `progress()` and pass the
/// same one to `decode_request(bs, &p)` after every read, with `bs` the bytes read so far (which
/// must only grow): it resumes where it stopped instead of starting over, so reading a request
/// is linear in its size. Results are those of `decode_request(bs)`.
pub struct Progress { s: Scan }

/// A fresh `Progress`, for a request not yet read.
pub fn progress(): Progress = Progress { s: Scan { scan: 0, head: none, chunk: none } }

/// `decode_request(bs)`, resuming from `p` (see `Progress`).
pub fn decode_request(bs: [int], p: var Progress): Got!ReqErr {
  let h = match p.s.head {
    some(h) => h
    none => {
      let h = request_head(bs, &p.s)?
      if h.at < 0 { return More(bs.len() + 1, false) }
      p.s.head = some(h)
      h
    }
  }
  match request_body(h.headers, bs, h.at, &p.s)? {
    Need(n) => More(n, h.cont)
    Have(raw) => {
      let body = str.from_utf8(raw) else fail(BadRequest("body is not UTF-8"))
      Done(h.method, h.target, h.headers, body)
    }
  }
}

// What `decode_request` keeps between calls.
struct Scan {
  scan: int,         // no head end (CRLF CRLF) starts before this
  head: Head?,       // the parsed head, once it is complete and valid
  chunk: Chunking?,  // a chunked body's progress
}

// A parsed request head; the body starts at bs[at].
struct Head { method: str, target: str, headers: {str: str}, cont: bool, at: int }

// How far a chunked body got.
struct Chunking {
  pos: int,        // the start of the next chunk-size (or trailer) line
  eol_from: int,   // no CRLF ends that line before this
  body: [int],     // the chunk data so far
  trailers: bool,  // past the last chunk: skipping trailer lines
}

// Parses the head, if it is complete (else a Head with `at` -1).
fn request_head(bs: [int], s: var Scan): Head!ReqErr {
  let end = head_end(bs, s.scan) else {
    s.scan = max(s.scan, bs.len() - 3)
    if bs.len() > MAX_HEAD { fail(HeadTooLarge) }
    return Head { method: "", target: "", headers: {}, cont: false, at: -1 }
  }
  if end > MAX_HEAD { fail(HeadTooLarge) }
  let head = str.from_utf8(bs[0..end]) else fail(BadRequest("headers are not UTF-8"))
  let [line, ..fields] = head.split("\r\n") else fail(BadRequest("empty request"))
  let (method, target, version) = request_line(line)?
  let headers = parse_headers(fields) else e => fail(BadRequest("{e}"))
  if version == "HTTP/1.1" && headers.get("host") is none {
    fail(BadRequest("missing Host header"))
  }
  let cont = (headers.get("expect") else "").lower() == "100-continue"
  Head { method, target, headers, cont, at: end + 4 }
}

fn request_line(line: str): (str, str, str)!ReqErr {
  let [method, target, version] = line.split(" ") else fail(BadRequest("bad request line: {line}"))
  if !is_token(method) {
    fail(BadRequest("bad method: {method}"))
  }
  if version != "HTTP/1.1" && version != "HTTP/1.0" {
    if version.starts_with("HTTP/") { fail(BadVersion(version)) }
    fail(BadRequest("bad request line: {line}"))
  }
  (method, origin_form(target)?, version)
}

// A non-empty run of RFC 9110 token chars.
fn is_token(s: str): bool {
  for c in s.chars() {
    if !is_tchar(c) { return false }
  }
  s != ""
}

fn is_tchar(c: char): bool = (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  c.is_digit() ||
  match c {
    '!' | '#' | '$' | '%' | '&' | '\'' | '*' | '+' | '-' | '.' | '^' | '_' | '`' | '|' | '~' => true
    _ => false
  }

// Checks the target with `url.parse` (strict RFC 3986) and returns it as `/path?query`.
fn origin_form("*"): str!ReqErr = "*"
fn origin_form(t: str): str!ReqErr when t.starts_with("/") {
  let u = url.parse("http://h" + t) else e => fail(BadRequest("bad target ({url.message(e)})"))
  if u.fragment is some(_) { fail(BadRequest("fragment in target")) }
  url.target(u)
}
fn origin_form(t: str): str!ReqErr {
  let u = url.parse(t) else e => fail(BadRequest("bad target ({url.message(e)})"))
  if !(u.scheme == "http" || u.scheme == "https") || u.host is none || u.fragment is some(_) {
    fail(BadRequest("bad target: {t}"))
  }
  url.target(u)
}

enum Body { Need(n: int), Have(bs: [int]) }

// Transfer-Encoding beats Content-Length (RFC 9112 §6.3); a request without either has no body.
fn request_body(hs: {str: str}, bs: [int], at: int, s: var Scan): Body!ReqErr {
  match hs.get("transfer-encoding") {
    some(te) => {
      let codings = te.lower().split(",").map(c => c.trim())
      if codings.last() != some("chunked") {
        fail(NotImplemented("Transfer-Encoding: {te}"))
      }
      var c = s.chunk else Chunking { pos: at, eol_from: at, body: [], trailers: false }
      s.chunk = none  // so `c.body` is not shared and grows in place
      let r = chunked_request(bs, &c)
      s.chunk = some(c)
      r?
    }
    none => match hs.get("content-length") {
      some(len) => {
        if len == "" || len.len() > 18 || !len.chars().all(c => c.is_digit()) {
          fail(BadRequest("bad Content-Length: {len}"))
        }
        let n = int.parse(len) else fail(BadRequest("bad Content-Length: {len}"))
        if n > MAX_BODY { fail(TooLarge) }
        if bs.len() < at + n { Need(at + n) } else { Have(bs[at..at + n]) }
      }
      none => Have([])
    }
  }
}

// Decodes a chunked body (`chunks` with a MAX_BODY bound, then the trailer lines), resuming
// from `c`: each byte is looked at about once however many reads the body takes.
fn chunked_request(bs: [int], c: var Chunking): Body!ReqErr {
  loop {
    let eol = crlf(bs, c.eol_from) else {
      c.eol_from = max(c.eol_from, bs.len() - 1)
      return Need(bs.len() + 1)
    }
    if c.trailers {
      if eol == c.pos { return Have(c.body) }
      c.pos = eol + 2
      c.eol_from = c.pos
      continue
    }
    let size = chunk_size(bs, c.pos, eol) else e => fail(BadRequest("{e}"))
    if size == 0 {
      c.trailers = true
      c.pos = eol + 2
      c.eol_from = c.pos
      continue
    }
    if c.body.len() + size > MAX_BODY { fail(TooLarge) }
    let start = eol + 2
    let stop = start + size
    if stop + 2 > bs.len() {
      c.eol_from = eol  // the size line is done; wait for its data
      return Need(bs.len() + 1)
    }
    if bs[stop] != 13 || bs[stop + 1] != 10 { fail(BadRequest(NOT_CRLF)) }
    c.body += bs[start..stop]  // in place: linear
    c.pos = stop + 2
    c.eol_from = c.pos
  }
}

let NOT_CRLF = "chunk not followed by CRLF"

/// Serializes a response: status line, the caller's headers (in map order), `Content-Length`
/// and `Connection: close`. 1xx, 204 and 304 responses have no body and no `Content-Length`;
/// for a HEAD request (`head_req`) the length is sent but the body is not. The caller's
/// `Content-Length`, `Transfer-Encoding` and `Connection` are ignored (the server owns framing).
pub fn encode_response(status: int, headers: {str: str}, body: str, head_req: bool): str! {
  if status < 100 || status > 999 { fail("bad status: {status}") }
  var out = head_start(status, headers)?
  let bodiless = status < 200 || status == 204 || status == 304
  if !bodiless { out.push_line("Content-Length", str(body.byte_len())) }
  out += "Connection: close\r\n\r\n"
  if !(bodiless || head_req) { out += body }
  out
}

// The status line and the caller's header lines (without the framing ones).
fn head_start(status: int, headers: {str: str}): str! {
  var out = "HTTP/1.1 "
  out += str(status)
  out += " "
  out += reason(status)
  out += "\r\n"
  for k, v in headers {
    if !is_token(k) || has_crlf(v) { fail("bad header: {k}") }
    if !framing(k.lower()) { out.push_line(k, v) }
  }
  out
}

/// The head of a streamed response: no length, so the body runs until the connection closes.
pub fn encode_stream_head(status: int, headers: {str: str}): str! {
  if status < 200 || status > 999 { fail("bad status: {status}") }
  var out = head_start(status, headers)?
  out += "Connection: close\r\n\r\n"
  out
}

/// The standard reason phrase for a status code ("" for an unknown one).
pub fn reason(status: int): str
fn reason(100): str = "Continue"
fn reason(101): str = "Switching Protocols"
fn reason(200): str = "OK"
fn reason(201): str = "Created"
fn reason(202): str = "Accepted"
fn reason(204): str = "No Content"
fn reason(206): str = "Partial Content"
fn reason(301): str = "Moved Permanently"
fn reason(302): str = "Found"
fn reason(303): str = "See Other"
fn reason(304): str = "Not Modified"
fn reason(307): str = "Temporary Redirect"
fn reason(308): str = "Permanent Redirect"
fn reason(400): str = "Bad Request"
fn reason(401): str = "Unauthorized"
fn reason(403): str = "Forbidden"
fn reason(404): str = "Not Found"
fn reason(405): str = "Method Not Allowed"
fn reason(409): str = "Conflict"
fn reason(410): str = "Gone"
fn reason(411): str = "Length Required"
fn reason(413): str = "Content Too Large"
fn reason(415): str = "Unsupported Media Type"
fn reason(422): str = "Unprocessable Content"
fn reason(429): str = "Too Many Requests"
fn reason(431): str = "Request Header Fields Too Large"
fn reason(500): str = "Internal Server Error"
fn reason(501): str = "Not Implemented"
fn reason(502): str = "Bad Gateway"
fn reason(503): str = "Service Unavailable"
fn reason(504): str = "Gateway Timeout"
fn reason(505): str = "HTTP Version Not Supported"
fn reason(_: int): str = ""

test "encode: GET has Host, User-Agent and Connection, no Content-Length" {
  assert encode("GET", "/a?b=1", "x.com", {}, "")? ==
    "GET /a?b=1 HTTP/1.1\r\nHost: x.com\r\nUser-Agent: auk-http/0.1\r\nConnection: close\r\n\r\n"
}

test "encode: Content-Length counts UTF-8 bytes" {
  assert encode("POST", "/p", "x.com:8080", {"Content-Type": "text/plain"}, "héllo")? ==
    "POST /p HTTP/1.1\r\nHost: x.com:8080\r\nUser-Agent: auk-http/0.1\r\nContent-Type: text/plain\r\nContent-Length: 6\r\nConnection: close\r\n\r\nhéllo"
  assert encode("PUT", "/", "h", {}, "")? ==
    "PUT / HTTP/1.1\r\nHost: h\r\nUser-Agent: auk-http/0.1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
}

test "encode: caller headers sorted, overrides honored, framing headers ignored" {
  let hs = {
    "user-agent": "me/1",
    "Content-Length": "99",
    "Connection": "keep-alive",
    "X-B": "2",
    "X-A": "1",
  }
  assert encode("GET", "/", "h", hs, "")? ==
    "GET / HTTP/1.1\r\nHost: h\r\nX-A: 1\r\nX-B: 2\r\nuser-agent: me/1\r\nConnection: close\r\n\r\n"
  assert encode("GET", "/", "h", {"HOST": "other"}, "")? ==
    "GET / HTTP/1.1\r\nUser-Agent: auk-http/0.1\r\nHOST: other\r\nConnection: close\r\n\r\n"
}

test "encode: rejects injection and bad names" {
  assert encode("GET", "/", "h", {"X": "a\r\nEvil: 1"}, "") is err(_)
  assert encode("GET", "/", "h", {"X\n": "a"}, "") is err(_)
  assert encode("GET", "/", "h", {"Bad Name": "a"}, "") is err(_)
  assert encode("GET", "/", "h", {"A:B": "a"}, "") is err(_)
  assert encode("GET", "/", "h", {"": "a"}, "") is err(_)
  assert encode("GE T", "/", "h", {}, "") is err(_)
  assert encode("", "/", "h", {}, "") is err(_)
}

fn dec(s: str): (int, {str: str}, str)! = decode(s.bytes(), false)

test "decode: Content-Length body, extra bytes ignored" {
  let (status, headers, body) = dec("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhelloEXTRA")?
  assert status == 200
  assert headers == {"content-type": "text/plain", "content-length": "5"}
  assert body == "hello"
  assert dec("HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nhéllo")? ==
    (200, {"content-length": "6"}, "héllo")
  assert dec("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")? == (200, {"content-length": "0"}, "")
}

test "decode: case-insensitive, repeated and colon-bearing headers" {
  let (_, hs, _) = dec("HTTP/1.1 302 Found\r\nLOCATION:  http://a/b?x=1 \r\nSet-Cookie: a=1\r\nset-cookie: b=2\r\nContent-length: 0\r\n\r\n")?
  assert hs == {"location": "http://a/b?x=1", "set-cookie": "a=1, b=2", "content-length": "0"}
}

test "decode: chunked body with extensions and trailers" {
  let r = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" +
    "4\r\nWiki\r\n6;name=x\r\npedia \r\nE\r\nin \r\n\r\nchunks.\r\n0\r\nExpires: never\r\n\r\n"
  let (_, _, body) = dec(r)?
  assert body == "Wikipedia in \r\n\r\nchunks."
}

test "decode: chunked wins over Content-Length; hex is case-insensitive" {
  let r = "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nTRANSFER-ENCODING: Chunked\r\n\r\n" +
    "a\r\n0123456789\r\nA \r\nabcdefghij\r\n0\r\n\r\n"
  let (_, _, body) = dec(r)?
  assert body == "0123456789abcdefghij"
}

test "decode: malformed chunked bodies" {
  let h = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
  assert dec(h + "4\r\nWiki\r\n") is err(_)            // no terminating chunk
  assert dec(h + "zz\r\nWiki\r\n0\r\n\r\n") is err(_)  // bad hex
  assert dec(h + "3\r\nWiki\r\n0\r\n\r\n") is err(_)   // data longer than size
  assert dec(h + "a\r\nWiki") is err(_)                // truncated data
  assert dec(h + "\r\nWiki\r\n0\r\n\r\n") is err(_)    // missing size
  assert dec(h + "fffffffffffffffff\r\n") is err(_)    // size overflows
  assert dec(h) is err(_)                              // empty
}

test "decode: read until close" {
  assert dec("HTTP/1.0 200 OK\r\nServer: x\r\n\r\nall of\r\nit")? ==
    (200, {"server": "x"}, "all of\r\nit")
  assert dec("HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\nraw")? ==
    (200, {"transfer-encoding": "gzip"}, "raw")
}

test "decode: bodiless responses and interim 1xx" {
  assert dec("HTTP/1.1 204\r\n\r\nignored")? == (204, {}, "")
  assert dec("HTTP/1.1 304 Not Modified\r\nContent-Length: 9\r\n\r\n")? ==
    (304, {"content-length": "9"}, "")
  assert decode("HTTP/1.1 200 OK\r\nContent-Length: 50\r\n\r\n".bytes(), true)? ==
    (200, {"content-length": "50"}, "")
  assert dec("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 201 Created\r\nContent-Length: 2\r\n\r\nok")? ==
    (201, {"content-length": "2"}, "ok")
}

test "decode: malformed responses" {
  assert dec("") is err(_)
  assert dec("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n") is err(_)  // head never ends
  assert dec("garbage\r\n\r\n") is err(_)
  assert dec("HTTP/2 200\r\n\r\n") is err(_)
  assert dec("HTTP/1.1 abc OK\r\n\r\n") is err(_)
  assert dec("HTTP/1.1 99 Low\r\n\r\n") is err(_)
  assert dec("HTTP/1.1 2000 Big\r\n\r\n") is err(_)
  assert dec("HTTP/1.1 200 OK\r\nNoColon\r\n\r\n") is err(_)
  assert dec("HTTP/1.1 200 OK\r\nA: 1\r\n Folded: x\r\n\r\n") is err(_)
  assert dec("HTTP/1.1 200 OK\r\nContent-Length: abc\r\n\r\n") is err(_)
  assert dec("HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n") is err(_)
  assert dec("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort") is err(_)
  assert decode("HTTP/1.1 200 OK\r\n\r\n".bytes() + [255, 254], false) is err(_)
}

test "decode_request with progress: same results at every read boundary" {
  let reqs = [
    "POST /up HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\nExpect: 100-continue\r\n\r\n" +
      "4\r\nWiki\r\n6;x=y\r\npedia \r\nA \r\n in chunks\r\n0\r\nX-T: 1\r\n\r\nEXTRA",
    "PUT /x HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\n\r\nhello",
    "GET / HTTP/1.0\r\n\r\n",
    "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabcd\r\n0\r\n\r\n",
    "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\nzz\r\n",
    "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n1000001\r\n",
    "GET / HTTP/1.1\r\nNoColon\r\n\r\n",
  ]
  for s in reqs {
    let bs = s.bytes()
    // one byte per read, and every other split into two reads
    var p = progress()
    for n in 0..bs.len() + 1 {
      let got = decode_request(bs[0..n], &p)
      assert got == decode_request(bs[0..n])
      if !(got is ok(More(_, _))) { break }
    }
    for cut in 0..bs.len() + 1 {
      var q = progress()
      let _ = decode_request(bs[0..cut], &q)
      assert decode_request(bs, &q) == decode_request(bs)
    }
  }
}

test "decode_request with progress: resumes instead of re-reading what it has decoded" {
  let head = "POST /up HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n"
  let first = "5\r\nhello\r\n"
  var p = progress()
  assert decode_request((head + first + "6\r\n wo").bytes(), &p) is ok(More(_, false))
  // Bytes already decoded are not looked at again: blanking them changes nothing.
  var bs = (head + first + "6\r\n world\r\n0\r\n\r\n").bytes()
  for i in head.len()..head.len() + first.len() { bs[i] = 0 }
  let Done(_, _, _, body) = decode_request(bs, &p)? else fail("incomplete")
  assert body == "hello world"
  assert decode_request(bs) is err(BadRequest(_))
}

test "decode_request with progress: a large chunked upload in small reads" {
  let head = "POST /up HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n".bytes()
  var chunk = "3e8\r\n".bytes()
  for i in 0..1000 { chunk.push(97 + i % 26) }
  chunk += [13, 10]
  var bs = head
  for _ in 0..1024 { bs += chunk }  // about 1 MB of body
  bs += "0\r\n\r\n".bytes()
  var buf: [int] = []
  var p = progress()
  var at = 0
  var decodes = 0
  let body = loop {
    let stop = min(at + 1000, bs.len())
    buf += bs[at..stop]
    at = stop
    decodes += 1
    match decode_request(buf, &p)? {
      Done(_, _, _, b) => break b
      More(n, _) => assert n == buf.len() + 1
    }
  }
  assert body.len() == 1024000
  assert decodes == bs.len() / 1000 + 1
}

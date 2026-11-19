/// HTTP/1.1 client over core `net` (TCP for http://, TLS for https://), and a server in
/// `http.server`. One request per connection (`Connection: close`); up to 5 redirects are
/// followed. Client I/O lives only in `send`/`exchange`; URL handling (`http.uri`, on the `url`
/// package), the wire format (`http.wire`) and redirect logic are pure and tested without a
/// network.

/// A response. Header names are lower-case (repeats joined with ", "); see `header`.
pub struct Resp { status: int, headers: {str: str}, body: str }

/// A request. `url` is absolute http(s); `headers` may use any case.
pub struct Req { method: str, url: str, headers: {str: str}, body: str }

/// Why a request failed. Connection and I/O errors from core `net` pass through unchanged.
pub enum HttpErr {
  BadUrl(why: str),
  BadRequest(why: str),
  BadResponse(why: str),
  TooManyRedirects(url: str),
}

/// Parses the response body as JSON, so `r.json()` works.
pub fn json(r: Resp): Value! = json.parse(r.body)?

/// Looks up a response header by name, ignoring case.
pub fn header(r: Resp, name: str): str? = r.headers.get(name.lower())

/// Sends a request and follows up to 5 redirects (301/302/303/307/308; 303 switches to GET).
pub async fn request(r: Req): Resp! uses net {
  var cur = r
  for _ in 0..=5 {
    let resp = await send(cur)?
    if !redirects(resp.status) { return resp }
    cur = follow(cur, resp)?
  }
  fail(TooManyRedirects(r.url))
}

/// GET the absolute http(s) URL `to`.
pub async fn get(to: str): Resp! uses net {
  await request(Req { method: "GET", url: to, headers: {}, body: "" })
}

/// POST a text body (`Content-Type: text/plain; charset=utf-8`) to `to`.
pub async fn post(to: str, body: str): Resp! uses net {
  await request(Req {
    method: "POST",
    url: to,
    headers: {"Content-Type": "text/plain; charset=utf-8"},
    body,
  })
}

/// POST `v` as JSON (`Content-Type: application/json`) to `to`.
pub async fn post_json(to: str, v: Value): Resp! uses net {
  await request(Req {
    method: "POST",
    url: to,
    headers: {"Content-Type": "application/json"},
    body: json.str(v),
  })
}

// The I/O edge: one connection, one request, read until the server closes.
async fn send(r: Req): Resp! uses net {
  let u = http.uri.parse(r.url) else e => fail(BadUrl("{e}"))
  let out = http.wire.encode(
    r.method,
    u.target,
    http.uri.authority(u),
    r.headers,
    r.body,
  ) else e => fail(BadRequest("{e}"))
  var c = if u.tls { net.tls(u.host, u.port)? } else { net.tcp(u.host, u.port)? }
  let raw = await exchange(&c, out.bytes())
  c.close()
  let bytes = raw?
  let (status, headers, body) = http.wire.decode(
    bytes,
    r.method == "HEAD",
  ) else e => fail(BadResponse("{e}"))
  Resp { status, headers, body }
}

async fn exchange(c: var net.Conn, data: [int]): [int]! uses net {
  c.write(data)?
  var buf: [int] = []
  loop {
    let got = c.read(65536)?
    if got.len() == 0 { break buf }
    buf += got
  }
}

fn redirects(301): bool = true
fn redirects(302): bool = true
fn redirects(303): bool = true
fn redirects(307): bool = true
fn redirects(308): bool = true
fn redirects(_: int): bool = false

// The request to send after a redirect response. 303 becomes GET (HEAD stays HEAD) without
// a body; credentials are dropped when the redirect leaves the origin.
fn follow(r: Req, resp: Resp): Req!HttpErr {
  let loc = resp.header("location") else fail(BadResponse("{resp.status} without Location"))
  let base = http.uri.parse(r.url) else e => fail(BadUrl("{e}"))
  let next = http.uri.resolve(base, loc) else e => fail(BadUrl("{e}"))
  let same_origin = next.tls == base.tls && next.host == base.host && next.port == base.port
  let see_other = resp.status == 303
  Req {
    method: method_after(resp.status, r.method),
    url: http.uri.format(next),
    headers: keep_headers(r.headers, see_other, same_origin),
    body: if see_other { "" } else { r.body },
  }
}

fn method_after(303, "HEAD"): str = "HEAD"
fn method_after(303, _: str): str = "GET"
fn method_after(_: int, m: str): str = m

fn keep_headers(hs: {str: str}, see_other: bool, same_origin: bool): {str: str} {
  var out: {str: str} = {}
  for k, v in hs {
    let n = k.lower()
    let gone = (see_other && n == "content-type") ||
      (!same_origin && (n == "authorization" || n == "cookie"))
    if !gone { out[k] = v }
  }
  out
}

fn moved(status: int, loc: str): Resp = Resp { status, headers: {"location": loc}, body: "" }

test "redirect statuses" {
  assert [301, 302, 303, 307, 308].all(s => redirects(s))
  assert ![200, 204, 300, 304, 305, 404, 500].any(s => redirects(s))
}

test "follow: 303 switches to GET and drops the body" {
  let r = Req {
    method: "POST",
    url: "https://a.com/form",
    headers: {"Content-Type": "text/plain", "X-Id": "7"},
    body: "hi",
  }
  assert follow(r, moved(303, "/done"))? ==
    Req { method: "GET", url: "https://a.com/done", headers: {"X-Id": "7"}, body: "" }
  let h = Req { method: "HEAD", url: "http://a.com/", headers: {}, body: "" }
  let n = follow(h, moved(303, "/x"))?
  assert n.method == "HEAD"
}

test "follow: 301/302/307/308 keep method and body" {
  let r = Req {
    method: "PUT",
    url: "http://a.com/v1/item?id=1",
    headers: {"Content-Type": "text/plain"},
    body: "x",
  }
  for s in [301, 302, 307, 308] {
    assert follow(r, moved(s, "../v2/item"))? == Req { url: "http://a.com/v2/item", ..r }
  }
}

test "follow: credentials stay on the same origin only" {
  let r = Req {
    method: "GET",
    url: "https://a.com/",
    headers: {"Authorization": "Bearer t", "cookie": "s=1", "Accept": "*/*"},
    body: "",
  }
  let same = follow(r, moved(302, "https://a.com/next"))?
  assert same.headers == r.headers
  for loc in ["https://b.com/", "http://a.com/", "https://a.com:8443/"] {
    let other = follow(r, moved(302, loc))?
    assert other.headers == {"Accept": "*/*"}
  }
}

test "follow: bad redirects" {
  let r = Req { method: "GET", url: "https://a.com/", headers: {}, body: "" }
  assert follow(r, Resp { status: 302, headers: {}, body: "" }) is err(BadResponse(_))
  assert follow(r, moved(301, "ftp://a.com/f")) is err(BadUrl(_))
  assert follow(r, moved(301, "")) is err(BadUrl(_))
}

test "header lookup ignores case" {
  let r = Resp { status: 200, headers: {"content-type": "text/html"}, body: "" }
  assert r.header("Content-Type") is some("text/html")
  assert r.header("x-missing") is none
}

test "json body" {
  let r = Resp { status: 200, headers: {}, body: "[true, null]" }
  assert r.json()? == List([Bool(true), Null])
  let bad = Resp { body: "nope", ..r }
  assert bad.json() is err(_)
}

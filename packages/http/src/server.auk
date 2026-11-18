/// HTTP/1.1 server (module `http.server`) over core `net.listen`. `serve` answers one connection
/// at a time; `serve_live` gives each connection a task of its own and can stream responses
/// (`Reply.Stream`, for Server-Sent Events). One request per connection (every response carries
/// `Connection: close`). Parsing and
/// formatting live in `http.wire`; this module is the accept loop, the request type and small
/// helpers for building responses and routing with Auk's clause patterns.

/// A request as the handler sees it. `target` is the origin form (`/a/b?x=1`, or `*`); `path`
/// and `query` are its two halves, still percent-encoded (`query` is "" without a `?`).
/// Header names are lower-case, and repeated headers are joined with ", ".
pub struct Req {
  method: str,
  target: str,
  path: str,
  query: str,
  headers: {str: str},
  body: str,
}

/// A listening server; `port(s)` tells which port it got when asked for port 0.
pub struct Server { listener: net.Listener }

/// Listens on `host` (`""` for every interface) and `port` (0 picks a free one).
pub fn listen(host: str, port: int): Server! uses net = Server { listener: net.listen(host, port)? }

/// The port the server is bound to.
pub fn port(s: Server): int uses net = s.listener.port()

/// Stops listening.
pub fn close(s: var Server) uses net { s.listener.close() }

/// Serves forever on `host`:`port`, one connection at a time. Only an `accept` failure returns.
pub async fn serve(host: str, port: int, handler: (Req) => http.Resp): ()! uses net {
  var s = listen(host, port)?
  let r = await serve(s, handler)
  s.close()
  r?
}

/// Serves forever on a server from `listen`.
pub async fn serve(s: Server, handler: (Req) => http.Resp): ()! uses net {
  loop { await serve_one(s, handler)? }
}

/// Serves `n` connections on `host`:`port`, then stops listening and returns (for tests).
pub async fn serve_n(host: str, port: int, n: int, handler: (Req) => http.Resp): ()! uses net {
  var s = listen(host, port)?
  let r = await serve_n(s, n, handler)
  s.close()
  r?
}

/// Serves `n` connections on a server from `listen`, then returns; `s` stays open.
pub async fn serve_n(s: Server, n: int, handler: (Req) => http.Resp): ()! uses net {
  for _ in 0..n { await serve_one(s, handler)? }
}

// ---- concurrent connections and streams ----

/// What a `serve_live` handler answers: a whole response, or a stream. A stream sends `status`
/// and `headers`, then each string sent on `chunks` as it comes, until `chunks` is closed (or the
/// client goes away: then the server closes `chunks`, so a sender can tell).
pub enum Reply {
  Whole(resp: http.Resp),
  Stream(status: int, headers: {str: str}, chunks: Chan<str>),
}

/// At most this many connections are served at once by `serve_live` (more wait to be accepted).
pub let MAX_CONNS = 256

/// Serves forever on `host`:`port`, each connection in a task of its own: a slow client, a long
/// stream or a handler that panics holds up nobody else (a panic only drops its connection).
pub async fn serve_live(host: str, port: int, handler: (Req) => Reply): ()! uses net {
  var s = listen(host, port)?
  let r = await serve_live(s, handler)
  s.close()
  r?
}

/// `serve_live` on a server from `listen`.
pub async fn serve_live(s: Server, handler: (Req) => Reply): ()! uses net {
  var open: [Task<()>] = []
  loop {
    let c = s.listener.accept()?
    open = open.filter(t => !t.done())
    if open.len() >= MAX_CONNS {
      let (i, _) = await any open
      let _ = open.remove(i)
    }
    open.push(connection(c, handler))
  }
}

/// Serves `n` connections concurrently on a server from `listen`, then waits for them to finish
/// (for tests).
pub async fn serve_live_n(s: Server, n: int, handler: (Req) => Reply): ()! uses net {
  var open: [Task<()>] = []
  for _ in 0..n {
    let c = s.listener.accept()?
    open.push(connection(c, handler))
  }
  for t in open {
    let _ = await any [t]
  }
}

// One connection, as a task: a panic in the handler drops just this connection.
async fn connection(c: net.Conn, handler: (Req) => Reply) uses net {
  var conn = c
  let _ = catch await answer_live(&conn, handler)
  conn.close()
}

async fn answer_live(c: var net.Conn, handler: (Req) => Reply): ()! uses net {
  let r = await read_request(&c)? else return
  match handler(r) {
    Whole(resp) => c.write(encode(r, resp).bytes())?
    Stream(status, headers, chunks) => {
      let head = http.wire.encode_stream_head(status, headers) else e => {
        c.write(encode(r, text(500, "bad response: {e}")).bytes())?
        return
      }
      // the client gone: close `chunks`, so whoever sends on it can tell
      let sent = catch {
        c.write(head.bytes())?
        for chunk in chunks {
          c.write(chunk.bytes())?
        }
      }
      chunks.close()
      sent?
    }
  }
}

// Reads one request (answering `Expect: 100-continue`); none if the client closed first or sent
// something unparseable (then it has had its 4xx).
async fn read_request(c: var net.Conn): Req?! uses net {
  var buf: [int] = []
  var need = 1
  var continued = false
  loop {
    if buf.len() >= need {
      match http.wire.decode_request(buf) {
        ok(Done(method, target, headers, body)) =>
          return some(request(method, target, headers, body))
        ok(More(n, cont)) => {
          need = n
          if cont && !continued {
            c.write("HTTP/1.1 100 Continue\r\n\r\n".bytes())?
            continued = true
          }
        }
        err(e) => {
          c.write(failure(e).bytes())?
          return none
        }
      }
    }
    let got = c.read(65536)?
    if got.len() == 0 { return none }
    for b in got { buf.push(b) }
  }
}

// A response, serialized for request `r` (a bad status or header becomes a 500).
fn encode(r: Req, resp: http.Resp): str {
  let head = r.method == "HEAD"
  http.wire.encode_response(resp.status, resp.headers, resp.body, head) else e => {
    let bad = text(500, "bad response: {e}")
    http.wire.encode_response(bad.status, bad.headers, bad.body, head)!
  }
}

// Accepts one connection and answers it. A failure on the connection itself (the client went
// away, a write failed) is dropped so the server keeps going; an `accept` failure is returned.
async fn serve_one(s: Server, handler: (Req) => http.Resp): ()! uses net {
  var c = s.listener.accept()?
  let r = await answer(&c, handler)
  c.close()
  if r is err(_) { return }
}

// Reads one request, calls the handler (or picks an error response) and writes the response.
async fn answer(c: var net.Conn, handler: (Req) => http.Resp): ()! uses net {
  var buf: [int] = []
  var need = 1
  var continued = false
  let out = loop {
    if buf.len() >= need {
      match http.wire.decode_request(buf) {
        ok(Done(method, target, headers, body)) =>
          break respond(request(method, target, headers, body), handler)
        ok(More(n, cont)) => {
          need = n
          if cont && !continued {
            c.write("HTTP/1.1 100 Continue\r\n\r\n".bytes())?
            continued = true
          }
        }
        err(e) => break failure(e)
      }
    }
    let got = c.read(65536)?
    if got.len() == 0 { return }  // the client closed before sending a whole request
    for b in got { buf.push(b) }
  }
  c.write(out.bytes())?
}

/// Builds the `Req` for a decoded request.
pub fn request(method: str, target: str, headers: {str: str}, body: str): Req {
  let (path, query) = match target.find("?") {
    some(i) => (target[0..i], target[i + 1..target.len()])
    none => (target, "")
  }
  Req { method, target, path, query, headers, body }
}

// Calls the handler and serializes its response; a response that can't be written (a bad
// status or header) becomes a 500.
fn respond(r: Req, handler: (Req) => http.Resp): str {
  let resp = handler(r)
  let head = r.method == "HEAD"
  http.wire.encode_response(resp.status, resp.headers, resp.body, head) else e => {
    let bad = text(500, "bad response: {e}")
    http.wire.encode_response(bad.status, bad.headers, bad.body, head)!
  }
}

// The response for a request that couldn't be parsed.
fn failure(e: http.wire.ReqErr): str {
  let r = text(http.wire.status(e), http.wire.message(e))
  http.wire.encode_response(r.status, r.headers, r.body, false)!
}

// ---- building responses ----

/// A plain-text response (`Content-Type: text/plain; charset=utf-8`).
pub fn text(status: int, body: str): http.Resp =
  http.Resp { status, headers: {"content-type": "text/plain; charset=utf-8"}, body }

/// An HTML response (`Content-Type: text/html; charset=utf-8`).
pub fn html(status: int, body: str): http.Resp =
  http.Resp { status, headers: {"content-type": "text/html; charset=utf-8"}, body }

/// `x` as a JSON response (`Content-Type: application/json`).
pub fn reply<T: Data>(status: int, x: T): http.Resp =
  http.Resp { status, headers: {"content-type": "application/json"}, body: json.encode(x) }

/// A redirect to `location` (use 301, 302, 303, 307 or 308).
pub fn redirect(status: int, location: str): http.Resp =
  http.Resp { status, headers: {"location": location}, body: "" }

/// `404 not found` as plain text.
pub fn not_found(): http.Resp = text(404, "not found")

// ---- reading requests ----

/// Looks up a request header by name, ignoring case (`req.header("Content-Type")`).
pub fn header(r: Req, name: str): str? = r.headers.get(name.lower())

/// Parses the request body as JSON (`req.json()`).
pub fn json(r: Req): Value! = json.parse(r.body)?

/// Decodes the body as `T` (`let u: User = req.decode()?`).
// COMPILER BUG: `= json.decode(r.body)?` in tail position infers json.decode's T as `T!`
// (E0350); without the `?` the types already match.
pub fn decode<T: Data>(r: Req): T! = json.decode(r.body)

/// The decoded query pairs, in order (`+` is a space).
pub fn params(r: Req): [(str, str)] = url.parse_query(r.query)

/// The first value of query parameter `key`.
pub fn param(r: Req, key: str): str? {
  let (_, v) = r.params().find((k, _) => k == key)?
  v
}

// ---- routing ----

/// Turns a routing function into a handler: `router(route)` calls `route(req.method, req.path,
/// req)`, so routes are clauses matched on the method and path:
/// `fn route("GET", "/users/" + id, r: Req): http.Resp`. A HEAD request is routed as "GET"
/// (`req.method` stays "HEAD", and the server sends no body).
pub fn router(route: (str, str, Req) => http.Resp): (Req) => http.Resp = r => route(
  if r.method == "HEAD" { "GET" } else { r.method },
  r.path,
  r,
)

// ---- tests ----

fn dec(s: str): http.wire.Got!http.wire.ReqErr = http.wire.decode_request(s.bytes())

fn req(s: str): Req! = match dec(s) {
  ok(Done(m, t, hs, b)) => request(m, t, hs, b)
  ok(More(_, _)) => fail("incomplete")
  err(e) => fail(http.wire.message(e))
}

test "decode_request: request line, headers, Content-Length body" {
  let r = req("POST /users?id=7&x=a+b HTTP/1.1\r\nHost: a\r\nContent-Type: text/plain\r\nX-A: 1\r\nx-a: 2\r\nContent-Length: 6\r\n\r\nhélloEXTRA")?
  assert r == Req {
    method: "POST",
    target: "/users?id=7&x=a+b",
    path: "/users",
    query: "id=7&x=a+b",
    headers: {"host": "a", "content-type": "text/plain", "x-a": "1, 2", "content-length": "6"},
    body: "héllo",
  }
  assert r.header("Content-Type") is some("text/plain")
  assert r.param("x") is some("a b")
  assert r.param("nope") is none
  assert r.params() == [("id", "7"), ("x", "a b")]
  let g = req("GET / HTTP/1.0\r\n\r\n")?
  assert (g.method, g.path, g.query, g.body) == ("GET", "/", "", "")
  assert (req("OPTIONS * HTTP/1.1\r\nHost: a\r\n\r\n")?).target == "*"
  assert (req("GET http://a.com/p?q=1 HTTP/1.1\r\nHost: a.com\r\n\r\n")?).target == "/p?q=1"
  assert (req("GET //x/y HTTP/1.1\r\nHost: a\r\n\r\n")?).path == "//x/y"
}

test "decode_request: chunked bodies, with extensions and trailers" {
  let h =
    "POST /up HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: gzip, chunked\r\nContent-Length: 99\r\n\r\n"
  let body = "4\r\nWiki\r\n6;x=y\r\npedia \r\n3\r\nin!\r\n0\r\nX-T: 1\r\n\r\n"
  assert (req(h + body)?).body == "Wikipedia in!"
  assert (req(h + "0\r\n\r\n")?).body == ""
  assert dec(h + "4\r\nWiki\r\n") is ok(More(_, false))
  assert dec(h + "4\r\nWiki\r\n0\r\n") is ok(More(_, false))
  assert dec(h + "4\r\nWiki\r\n0\r\nX-T: 1\r\n") is ok(More(_, false))
  assert dec(h + "zz\r\n") is err(BadRequest(_))
  assert dec(h + "3\r\nWiki\r\n0\r\n\r\n") is err(BadRequest(_))
  assert dec(h + "1000001\r\n") is err(TooLarge)
}

test "decode_request: incomplete requests ask for more" {
  assert dec("") is ok(More(1, false))
  assert dec("GET / HTTP/1.1\r\nHost: a\r\n") is ok(More(_, false))
  let h = "PUT /x HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\n\r\n"
  let More(n, _) = dec(h + "ab")? else fail("complete")
  assert n == h.len() + 5
  assert dec("PUT /x HTTP/1.1\r\nHost: a\r\nExpect: 100-Continue\r\nContent-Length: 5\r\n\r\n") is ok(More(_, true))
}

test "decode_request: bad requests and their statuses" {
  let bad = [
    ("GET\r\n\r\n", 400),
    ("GET / HTTP/1.1 x\r\nHost: a\r\n\r\n", 400),
    ("GET  / HTTP/1.1\r\nHost: a\r\n\r\n", 400),
    ("G(T / HTTP/1.1\r\nHost: a\r\n\r\n", 400),
    ("GET / HTTP/1.1\r\n\r\n", 400),
    ("GET / HTTP/1.1\r\nHost: a\r\nNoColon\r\n\r\n", 400),
    ("GET / HTTP/1.1\r\nHost: a\r\n Folded: x\r\n\r\n", 400),
    ("GET /a b HTTP/1.1\r\nHost: a\r\n\r\n", 400),
    ("GET /é HTTP/1.1\r\nHost: a\r\n\r\n", 400),
    ("GET /%zz HTTP/1.1\r\nHost: a\r\n\r\n", 400),
    ("GET /#f HTTP/1.1\r\nHost: a\r\n\r\n", 400),
    ("GET x HTTP/1.1\r\nHost: a\r\n\r\n", 400),
    ("GET ftp://a/ HTTP/1.1\r\nHost: a\r\n\r\n", 400),
    ("GET / HTTP/2.0\r\nHost: a\r\n\r\n", 505),
    ("GET / FTP/1.1\r\nHost: a\r\n\r\n", 400),
    ("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: -1\r\n\r\n", 400),
    ("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 1, 2\r\n\r\n", 400),
    ("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 99999999999\r\n\r\n", 413),
    ("POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: gzip\r\n\r\n", 501),
  ]
  for (s, code) in bad {
    match dec(s) {
      err(e) => assert http.wire.status(e) == code
      ok(_) => fail("accepted: {s}")
    }
  }
  assert http.wire.decode_request([71, 69, 84, 32, 47, 255, 13, 10, 13, 10]) is err(BadRequest(_))
  let big = "GET / HTTP/1.1\r\nX: " + "a".repeat(http.wire.MAX_HEAD)
  assert dec(big) is err(HeadTooLarge)
  assert dec(big + "\r\n\r\n") is err(HeadTooLarge)
  assert http.wire.message(TooLarge) == "request body larger than 16777216 bytes"
}

test "encode_response: framing, HEAD and bodiless statuses" {
  let enc = (s: int, hs: {str: str}, b: str, head: bool) => http.wire.encode_response(
    s,
    hs,
    b,
    head,
  )!
  assert enc(200, {"Content-Type": "text/plain", "X-B": "1"}, "héllo", false) ==
    "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nX-B: 1\r\nContent-Length: 6\r\nConnection: close\r\n\r\nhéllo"
  assert enc(200, {}, "abc", true) ==
    "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\n"
  assert enc(204, {}, "ignored", false) == "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"
  assert enc(304, {"ETag": "\"x\""}, "", false) ==
    "HTTP/1.1 304 Not Modified\r\nETag: \"x\"\r\nConnection: close\r\n\r\n"
  assert enc(299, {"content-length": "9", "Connection": "keep-alive"}, "", false) ==
    "HTTP/1.1 299 \r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
  assert http.wire.encode_response(200, {"X": "a\r\nEvil: 1"}, "", false) is err(_)
  assert http.wire.encode_response(200, {"Bad Name": "a"}, "", false) is err(_)
  assert http.wire.encode_response(200, {"": "a"}, "", false) is err(_)
  assert http.wire.encode_response(99, {}, "", false) is err(_)
  assert http.wire.encode_response(1000, {}, "", false) is err(_)
}

test "responses: helpers, error pages and bad handler output" {
  assert text(201, "ok") ==
    http.Resp { status: 201, headers: {"content-type": "text/plain; charset=utf-8"}, body: "ok" }
  assert reply(200, {"a": [1, 2]}).body == r"""{"a":[1,2]}"""
  assert redirect(303, "/next").headers == {"location": "/next"}
  assert not_found().status == 404
  assert html(200, "<p>").headers["content-type"] == "text/html; charset=utf-8"
  assert failure(BadVersion("HTTP/2.0")).starts_with("HTTP/1.1 505 HTTP Version Not Supported\r\n")
  let r = request("GET", "/", {}, "")
  let out = respond(r, _ => http.Resp { status: 200, headers: {"X": "a\nb"}, body: "" })
  assert out.starts_with("HTTP/1.1 500 Internal Server Error\r\n")
  assert out.ends_with("bad response: bad header: X")
  let head = respond(request("HEAD", "/", {}, ""), _ => text(200, "four"))
  assert head.ends_with("Content-Length: 4\r\nConnection: close\r\n\r\n")
}

struct User { name: str, age: int }

fn route("GET", "/health", _: Req): http.Resp = text(200, "up")
fn route("GET", "/users/" + id, _: Req): http.Resp = match int.parse(id) {
  ok(n) => reply(200, User { name: "user{n}", age: n })
  err(_) => text(400, "bad id: {id}")
}
fn route("POST", "/users", r: Req): http.Resp = match r.decode() {
  ok(User { name, age }) => reply(201, {"created": name, "age": str(age)})
  err(e) => text(422, "{e}")
}
fn route("GET", "/search", r: Req): http.Resp = text(200, r.param("q") else "")
fn route(_: str, "/health", _: Req): http.Resp = text(405, "method not allowed")
fn route(_: str, _: str, _: Req): http.Resp = not_found()

test "router: clauses on method and path" {
  let h = router(route)
  assert h(request("GET", "/health", {}, "")).body == "up"
  assert h(request("HEAD", "/health", {}, "")).body == "up"
  assert h(request("DELETE", "/health", {}, "")).status == 405
  assert h(request("GET", "/users/7", {}, "")).body == r"""{"age":7,"name":"user7"}"""
  assert h(request("GET", "/users/x", {}, "")).status == 400
  let made = h(request("POST", "/users", {}, r"""{"name": "ann", "age": 30}"""))
  assert (made.status, made.body) == (201, r"""{"age":"30","created":"ann"}""")
  assert h(request("POST", "/users", {}, r"""{"name": 1}""")).status == 422
  assert h(request("GET", "/search?q=auk+lang", {}, "")).body == "auk lang"
  assert h(request("GET", "/nope", {}, "")).status == 404
}

async fn get_body(u: str): str! uses net {
  let r = await http.get(u)?
  "{r.status} {r.body}"
}

async fn post_body(u: str, body: str): str! uses net {
  let r = await http.post(u, body)?
  "{r.status} {r.body}"
}

// Raw bytes in, raw response out: for requests the client won't send.
async fn raw(port: int, req: str): str! uses net {
  var c = net.tcp("127.0.0.1", port)?
  c.write(req.bytes())?
  var buf: [int] = []
  loop {
    let got = c.read(65536)?
    if got.len() == 0 { break }
    for b in got { buf.push(b) }
  }
  c.close()
  str.from_utf8(buf)?
}

// Reads a whole response from a raw connection, after sending `req`.
async fn slow_stream(port: int): str! uses net =
  await raw(port, "GET /stream HTTP/1.1\r\nHost: x\r\n\r\n")

fn live_route(r: Req, streams: Chan<Chan<str>>): Reply = match r.path {
  "/stream" => {
    // the test writes to this stream from outside, while other requests are served
    let chunks: Chan<str> = chan()
    streams.send(chunks)
    Stream(200, {"content-type": "text/event-stream"}, chunks)
  }
  "/boom" => {
    let xs: [int] = []
    Whole(text(200, "{xs[3]}"))
  }
  _ => Whole(text(200, "quick"))
}

test "serve_live: a stream doesn't block other connections; a panic drops only its own" {
  var s = listen("127.0.0.1", 0)?
  let p = s.port()
  let streams: Chan<Chan<str>> = chan()
  let server = serve_live_n(s, 3, r => live_route(r, streams))
  let streamed = slow_stream(p)
  let chunks = streams.recv() else return fail("no stream")
  chunks.send("data: one\n\n")
  // the stream is open and waiting; other connections are answered meanwhile
  assert (await get_body("http://127.0.0.1:{p}/quick"))? == "200 quick"
  assert (await raw(p, "GET /boom HTTP/1.1\r\nHost: x\r\n\r\n"))? == ""
  chunks.send("data: two\n\n")
  chunks.close()
  let out = (await streamed)?
  assert out.starts_with("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nConnection: close\r\n\r\n")
  assert out.ends_with("data: one\n\ndata: two\n\n")
  await server?
  s.close()
}

test "integration: serve_n answers http.get and http.post on 127.0.0.1" {
  var s = listen("127.0.0.1", 0)?
  let p = s.port()
  assert p > 0
  let base = "http://127.0.0.1:{p}"
  let (served, a) = await (serve_n(s, 1, router(route)), get_body(base + "/users/3"))
  served?
  assert a? == "200 " + r"""{"age":3,"name":"user3"}"""
  let (served2, b) = await (
    serve_n(s, 1, r => text(200, "{r.method} {r.target} {r.body}")),
    post_body(base + "/echo?x=1", "héllo"),
  )
  served2?
  assert b? == "200 POST /echo?x=1 héllo"
  let chunked = "POST /c HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" +
    "3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n"
  let (served3, c) = await (serve_n(s, 1, r => text(200, r.body)), raw(p, chunked))
  served3?
  assert c? ==
    "HTTP/1.1 200 OK\r\ncontent-type: text/plain; charset=utf-8\r\nContent-Length: 5\r\nConnection: close\r\n\r\nabcde"
  let (served4, d) = await (serve_n(s, 1, _ => text(200, "never")), raw(p, "BAD\r\n\r\n"))
  served4?
  assert (d?).starts_with("HTTP/1.1 400 Bad Request\r\n")
  s.close()
}

# http

An HTTP/1.1 client and server built on core `net`. The client uses `net.tcp` for `http://` and `net.tls` for `https://`. It makes one request per connection, follows up to 5 redirects, and reads `Content-Length`, chunked and read-until-close bodies. The server (`http.server`) runs on `net.listen`: it serves one connection at a time, handles one request per connection, and routes with Auk's clause patterns.

**Effects:** `net`. **Dependencies:** `json` and `url` (which brings in `encoding`); none of them use effects. To call `json.*` yourself, as below, add it as a direct dependency too: `raft add json`.

## Client
```
fn main(): int! uses net {
  let r = await http.get("https://api.example.com/users/1")?
  if r.status != 200 { fail("status {r.status}") }
  let user = r.json()?
  print("{r.header("content-type") else "?"}: {json.str(user)}")
  let made = await http.post_json("https://api.example.com/users", Map({"name": Str("ann")}))?
  print("created: {made.status}")
  0
}
```

- `struct Resp { status: int, headers: {str: str}, body: str }`: header names are lower-case; repeated headers are joined with `", "`.
- `struct Req { method: str, url: str, headers: {str: str}, body: str }`
- `enum HttpErr { BadUrl(why), BadRequest(why), BadResponse(why), TooManyRedirects(url) }`: errors from core `net` pass through as they are.
- `async fn request(r: Req): Resp! uses net`: sends `r` and follows 301/302/303/307/308 up to 5 times. A 303 becomes GET with no body. `Authorization` and `Cookie` are dropped when a redirect leaves the origin.
- `async fn get(to: str): Resp! uses net`
- `async fn post(to: str, body: str): Resp! uses net`: sends `Content-Type: text/plain; charset=utf-8`.
- `async fn post_json(to: str, v: Value): Resp! uses net`: sends `Content-Type: application/json`.
- `fn json(r: Resp): Value!`: parses the body (`r.json()`).
- `fn header(r: Resp, name: str): str?`: looks up a header, ignoring case (`r.header("Content-Type")`).

Every request sends `Host`, `User-Agent: auk-http/0.1` and `Connection: close`. It also sends `Content-Length` when there is a body or the method is POST, PUT or PATCH. You can override `Host` and `User-Agent`. Any framing headers you set are ignored. Header values containing CR or LF are rejected.

### URLs are strict RFC 3986 (via `url`)
URL parsing and redirect resolution use the `url` package: `http.uri.parse` is `url.parse` plus an http/https check, and redirects resolve with `url.resolve`. Build query strings with `url.build_query` or `url.with_params`. The rules:
- **Some characters must be percent-encoded.** Raw non-ASCII, spaces, control characters and `` "<>\^`{|} `` in a URL are a `BadUrl` error, so encode them first, for example `"https://a.com/" + encoding.percent_encode("café")`. http 0.1 used to send non-ASCII and `"<>{}|` through unchanged.
- A `%` must be followed by two hex digits.
- The scheme is case-insensitive (`HTTP://a.com` works).
- Dot segments in a redirect `Location` are removed exactly as RFC 3986 §5.2 says.
- URLs with credentials (`user:pw@host`) and port 0 are rejected.

## Server
```
struct Todo { title: str, done: bool }

fn route("GET", "/", _: http.server.Req): http.Resp = http.server.text(200, "hello from auk\n")
fn route("GET", "/hello/" + name, r: http.server.Req): http.Resp {
  let greeting = r.param("greeting") else "hi"
  http.server.text(200, "{greeting}, {name}!\n")
}
fn route("POST", "/todos", r: http.server.Req): http.Resp = match r.decode() {
  ok(Todo { title, done }) => http.server.reply(201, Todo { title, done })
  err(e) => http.server.text(400, "{e}\n")
}
fn route(_: str, _: str, _: http.server.Req): http.Resp = http.server.not_found()

fn main(args: [str]): ()! uses net {
  let port = if args.len() > 1 { int.parse(args[1])? } else { 8080 }
  var s = http.server.listen("127.0.0.1", port)?
  eprint("listening on http://127.0.0.1:{s.port()}")
  await http.server.serve(s, http.server.router(route))?
}
```
To try it, run `raft new demo`, set `effects = ["net"]`, run `raft add http`, put the code above in `src/main.auk`, and start it with `auk run src/main.auk`. Then:
```
$ curl "localhost:8080/hello/ann?greeting=hey+there"
hey there, ann!
$ curl -d '{"title":"x","done":true}' localhost:8080/todos
{"done":true,"title":"x"}
```

### API (`http.server`)
- `struct Req { method, target, path, query, headers: {str: str}, body }`: `target` is the origin form (`/a/b?x=1`, or `*`), and `path` and `query` are its two halves, still percent-encoded (`query` is `""` when there is no `?`). Header names are lower-case, and repeated headers are joined with `", "`. An absolute-form target (`http://h/p`) arrives as `/p`.
- `struct Server`, `listen(host, port): Server! uses net` (`""` means every interface; port 0 picks a free port), `port(s): int`, `close(var s)`.
- `async fn serve(host, port, handler: (Req) => http.Resp): ()!` and `serve(s: Server, handler)` run forever. They return only if `accept` fails.
- `async fn serve_live(host, port, handler: (Req) => Reply): ()!` and `serve_live(s: Server, handler)` give each connection a task of its own, with at most `MAX_CONNS` (256) at once. A slow client or a long stream holds up nobody else, and a handler that panics only drops its own connection. `serve_live_n(s, n, handler)` serves `n` connections and then waits for them, for tests.
- `enum Reply { Whole(resp: http.Resp), Stream(status, headers, chunks: Chan<str>) }` is what a `serve_live` handler returns. A stream sends its head (no length), then each string sent on `chunks` as it arrives, until `chunks` is closed. If the client goes away, the server closes `chunks`, so a sender can tell: its next `send` panics. That's what Server-Sent Events need (`content-type: text/event-stream`, messages like `"data: hi\n\n"`).
- `async fn serve_n(host, port, n, handler)` and `serve_n(s: Server, n, handler)` serve `n` connections and then return; the first form also closes its listener. These are meant for tests. Run the server and a client together with `await (serve_n(s, 1, h), http.get(u))`.
- Responses: `text(status, body)`, `html(status, body)`, `reply<T: Data>(status, x)` (a JSON body), `redirect(status, location)` and `not_found()`. Any `http.Resp` works.
- Requests: `header(r, name): str?` (ignores case), `json(r): Value!`, `decode<T: Data>(r): T!` (a JSON body), `params(r): [(str, str)]` and `param(r, key): str?` (decoded query).
- `router(route: (str, str, Req) => http.Resp): (Req) => http.Resp` calls `route(method, path, req)`, so routes are clauses with string patterns: `fn route("GET", "/users/" + id, r: Req)`. A HEAD request is routed as `"GET"`.
- `request(method, target, headers, body): Req` builds a `Req`, for testing handlers without a socket.

The server works like this:
- **Bodies.** It reads `Content-Length` and chunked request bodies (chunk extensions and trailers are ignored), and answers `Expect: 100-continue`.
- **Closing.** Every response carries `Content-Length` and `Connection: close`, and the server then closes the connection. There is no keep-alive or pipelining.
- **HEAD and bodiless statuses.** A HEAD response gets its `Content-Length` but no body. 1xx, 204 and 304 responses have neither.
- **Malformed requests.** These get an error response and never reach the handler:
  - 400 for bad syntax, a missing `Host` on HTTP/1.1, a target that isn't strict RFC 3986, or a body that isn't UTF-8
  - 413 for a body over 16 MiB (`http.wire.MAX_BODY`)
  - 431 for headers over 64 KiB (`http.wire.MAX_HEAD`)
  - 501 for a transfer coding other than chunked
  - 505 for an HTTP version other than 1.0 or 1.1
- **Bad handler output.** A response with a bad status or header becomes a 500.
- **Dropped connections.** A client that disconnects or sends nothing is dropped, and the loop goes on.

## Pure layers
These are public, so you can test or reuse them:
- `http.uri`: `struct Url { tls, host, port, target }`, `parse(s): Url!`, `from_url(u: url.Url): Url!`, `resolve(base: Url, loc: str): Url!`, `format(u): str`, `authority(u): str`.
- `http.wire`, the client side: `encode(method, target, host, headers, body): str!` and `decode(bytes: [int], head_req: bool): (int, {str: str}, str)!`.
- `http.wire`, the server side:
  - `decode_request(bytes): Got!ReqErr`, where `Got { More(need, cont), Done(method, target, headers, body) }`
  - `struct Progress`, `progress(): Progress` and `decode_request(bytes, &p): Got!ReqErr` handle a request that arrives in pieces. Pass the same `Progress` after every read, with `bytes` holding everything read so far (it may only grow). Each call picks up where the last one stopped, so reading a request takes time linear in its size, not quadratic. The results are the same as `decode_request(bytes)`. `http.server` reads every request this way (see `src/server.auk`).
  - `encode_response(status, headers, body, head_req): str!`
  - `ReqErr { BadRequest(why), TooLarge, HeadTooLarge, NotImplemented(why), BadVersion(version) }`, with `status(e)` and `message(e)`
  - `reason(status): str`

## Limits in 0.1
- Bodies must be UTF-8 text.
- There is no keep-alive, compression or proxy support.
- URLs can't carry credentials.
- The server runs one connection at a time. A slow client holds up the others, and there are no timeouts yet: core has no `timeout` (see design/package-list.md §6, gap 8).
- A handler that panics stops the server.
- There is no server-side TLS.

# url

URLs and URI references (RFC 3986): parse, format, resolve a reference against a base (with dot-segment removal), and read or build query strings. Components stay percent-encoded exactly as written; the query and path helpers decode them (through `encoding`). Errors are a typed `UrlErr` with the char index of the problem.

**Effects:** none. Depends on `encoding` (no effects).

```duck
let u = url.parse("https://api.example.com/v1/search?q=duck+lang&page=2")?
print(u.host else "")                        // api.example.com
print(u.param("q") else "")                  // duck lang
let next = url.resolve(u, "../v2/items?id=7")?
print("{next}")                              // https://api.example.com/v2/items?id=7
let q = u.with_params([("q", "a&b"), ("page", "3")])
print(url.target(q))                         // /v1/search?q=a%26b&page=3
match url.parse("http://a.com/a b") {
  err(e) => print(url.message(e))            // bad char ' ' at 14
  ok(_) => {}
}
```

## API
- `struct Url { scheme: str, user: str?, host: str?, port: int?, path: str, query: str?, fragment: str? }`
  - `scheme` is "" in a relative reference.
  - `host` is none when there is no authority (`mailto:x`) and `some("")` for `file:///x`; IPv6 hosts are stored without brackets.
  - Absent parts are `none`, which differs from empty ones (`a?` has `query: some("")`). The scheme and host are lower-cased; everything else is kept as written.
- `enum UrlErr { BadChar(at: int, c: char), BadEscape(at: int), BadScheme(at: int), BadPort(at: int), BadHost(at: int), NotAbsolute }` and `message(e: UrlErr): str`.
- `parse(s: str): Url!UrlErr`: an absolute URL or a relative reference. It is strict: spaces, control chars, non-ASCII and `"<>\^`{|}` must be percent-encoded first (`encoding.percent_encode`), and a `%` needs two hex digits. Ports go up to 65535.
- `show(u: Url): str`: the text form, so `"{u}"` and `str(u)` work. `parse` then `show` gives back the input, except that the scheme and host are lower-cased.
- `resolve(base: Url, rel: str): Url!UrlErr`: RFC 3986 §5.2 reference resolution, including all the §5.4 examples. `base` must be absolute.
- `remove_dots(path: str): str`: RFC 3986 §5.2.4 (`/a/b/../c/./d` is `/a/c/d`).
- `is_absolute(u)`, `default_port(scheme): int?` (http/ws 80, https/wss 443, ftp 21), `port_or_default(u): int?`.
- `host_port(u): str`: the `Host` header value, with the port only when it isn't the default. `target(u): str`: the request target (`/path?query`, `/` for an empty path).
- Queries (`application/x-www-form-urlencoded`):
  - `parse_query(q: str): [(str, str)]`: decoded pairs in order. `+` is a space, `flag` without `=` gets `""`, empty pieces are skipped, and a malformed `%` escape is kept literally.
  - `build_query(pairs): str`: the reverse. Spaces become `+`, and everything but `A-Z a-z 0-9 - . _ ~` is percent-encoded.
  - `params(u): [(str, str)]`, `param(u, key): str?` (the first value), `with_params(u, pairs): Url` (no query if `pairs` is empty).
- `segments(u): [str]`: the decoded path segments (`/a/b%20c/` gives `["a", "b c", ""]`).

Not in 0.1: internationalized domain names (punycode), IRIs (non-ASCII must be encoded), and WHATWG-style lenient parsing (backslashes, tabs, and so on).

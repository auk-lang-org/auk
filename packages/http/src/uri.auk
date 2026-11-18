/// URL handling for http (module `http.uri`): a thin http/https check on top of the `url`
/// package. `parse` validates with `url.parse` (strict RFC 3986), `resolve` uses `url.resolve`
/// (RFC 3986 §5.2), and `format` gives the absolute URL back. All pure.
// Errors here are plain `Err` messages; lib.auk wraps them in `HttpErr.BadUrl`.

/// A parsed URL. `host` is lower-case and unbracketed (IPv6 `::1`, not `[::1]`);
/// `target` is the path plus query, always starting with "/"; the fragment is dropped.
pub struct Url { tls: bool, host: str, port: int, target: str }

/// Parses an absolute `http://` or `https://` URL (the scheme in any case). The scheme picks
/// TLS and the default port (80 or 443). The text must be valid RFC 3986: spaces, control
/// chars, non-ASCII and any of ``"<>\^`{|}`` must be percent-encoded first
/// (`encoding.percent_encode`).
pub fn parse(s: str): Url! {
  let u = url.parse(s) else e => fail("bad URL ({url.message(e)}): {s}")
  from_url(u)?
}

/// Checks a `url.Url` for http use: an http or https scheme, a non-empty host, no userinfo,
/// a port in 1..65535. The fragment is dropped.
pub fn from_url(u: url.Url): Url! {
  let tls = is_tls(u.scheme)?
  let host = u.host else fail("missing host: {u}")
  if host == "" { fail("missing host: {u}") }
  if u.user is some(_) { fail("credentials in URLs are not supported") }
  let port = url.port_or_default(u) else 0
  if port < 1 || port > 65535 { fail("port out of range: {port}") }
  Url { tls, host, port, target: url.target(u) }
}

fn is_tls("http"): bool! = false
fn is_tls("https"): bool! = true
fn is_tls(s: str): bool! = fail("unsupported URL scheme (want http or https): {s}")

fn default_port(true): int = 443
fn default_port(false): int = 80

fn scheme(true): str = "https"
fn scheme(false): str = "http"

/// The `Host` header value: brackets around IPv6, and the port only when it isn't the default.
pub fn authority(u: Url): str {
  let h = if u.host.contains(":") { "[{u.host}]" } else { u.host }
  if u.port == default_port(u.tls) { h } else { "{h}:{u.port}" }
}

/// Formats a Url as an absolute URL string.
pub fn format(u: Url): str = scheme(u.tls) + "://" + authority(u) + u.target

/// Resolves a redirect `Location` (absolute, `//host/...`, `/path`, `?query` or relative)
/// against the URL it came from, with `url.resolve`; the result must be http(s) again.
pub fn resolve(base: Url, loc: str): Url! {
  if loc == "" { fail("empty Location") }
  let b = url.parse(format(base)) else e => fail("bad base URL ({url.message(e)})")
  let next = url.resolve(b, loc) else e => fail("bad Location ({url.message(e)}): {loc}")
  from_url(next)?
}

test "parse: scheme, host, port, target" {
  assert parse("http://example.com")? ==
    Url { tls: false, host: "example.com", port: 80, target: "/" }
  assert parse("https://Example.COM/a/b?x=1&y=2#top")? ==
    Url { tls: true, host: "example.com", port: 443, target: "/a/b?x=1&y=2" }
  assert parse("http://localhost:8080/api/v1/")? ==
    Url { tls: false, host: "localhost", port: 8080, target: "/api/v1/" }
  assert parse("https://a.io:8443")? == Url { tls: true, host: "a.io", port: 8443, target: "/" }
  assert parse("http://a.io?q=/x")? == Url { tls: false, host: "a.io", port: 80, target: "/?q=/x" }
  assert parse("http://a.io:/p")? == Url { tls: false, host: "a.io", port: 80, target: "/p" }
  assert parse("http://[::1]:9000/x")? == Url { tls: false, host: "::1", port: 9000, target: "/x" }
  assert parse("https://[FE80::1]")? == Url { tls: true, host: "fe80::1", port: 443, target: "/" }
  // url.parse lower-cases the scheme, so upper-case schemes are accepted now.
  assert parse("HTTP://a.com/")? == Url { tls: false, host: "a.com", port: 80, target: "/" }
  assert parse("http://a.com/caf%C3%A9?q=%22x%22")? ==
    Url { tls: false, host: "a.com", port: 80, target: "/caf%C3%A9?q=%22x%22" }
}

test "parse: rejects bad URLs" {
  assert parse("ftp://a.com/") is err(_)
  assert parse("example.com/x") is err(_)
  assert parse("http:a.com") is err(_)
  assert parse("http://") is err(_)
  assert parse("http:///path") is err(_)
  assert parse("http://:80/") is err(_)
  assert parse("http://a.com:0/") is err(_)
  assert parse("http://a.com:65536/") is err(_)
  assert parse("http://a.com:8o/") is err(_)
  assert parse("http://a.com:-1/") is err(_)
  assert parse("http://a:1:2/") is err(_)
  assert parse("http://user:pw@a.com/") is err(_)
  assert parse("http://[::1/") is err(_)
  assert parse("http://[::1]x/") is err(_)
  assert parse("http://a.com/a b") is err(_)
  assert parse("http://a.com/x\r\nHost: evil") is err(_)
  // Strict RFC 3986 (since 0.1 moved onto `url`): encode these first.
  assert parse("http://a.com/café") is err(_)
  assert parse("http://a.com/?q=\"x\"") is err(_)
  for c in ["<", ">", "{", "}", "|", "^", "`", "\\"] {
    assert parse("http://a.com/" + c) is err(_)
  }
  assert parse("http://a.com/%zz") is err(_)
}

test "authority and format" {
  assert authority(parse("http://a.com:80/")?) == "a.com"
  assert authority(parse("https://a.com:80/")?) == "a.com:80"
  assert authority(parse("http://[::1]:81")?) == "[::1]:81"
  assert format(parse("https://A.com:443/p?q=1#f")?) == "https://a.com/p?q=1"
  assert format(parse("http://a.com:8080")?) == "http://a.com:8080/"
}

test "resolve redirect locations" {
  let base = parse("https://a.com/docs/guide/intro?x=1")?
  assert format(resolve(base, "http://b.org/z")?) == "http://b.org/z"
  assert format(resolve(base, "//c.net/p")?) == "https://c.net/p"
  assert format(resolve(base, "/top?y=2#frag")?) == "https://a.com/top?y=2"
  assert format(resolve(base, "next")?) == "https://a.com/docs/guide/next"
  assert format(resolve(base, "./next?a=b:c")?) == "https://a.com/docs/guide/next?a=b:c"
  assert format(resolve(base, "../api/./v2")?) == "https://a.com/docs/api/v2"
  assert format(resolve(base, "..")?) == "https://a.com/docs/"
  assert format(resolve(base, "../../../../x")?) == "https://a.com/x"
  assert format(resolve(base, "?page=2")?) == "https://a.com/docs/guide/intro?page=2"
  assert format(resolve(base, "#frag")?) == "https://a.com/docs/guide/intro?x=1"
  assert format(resolve(parse("http://a.com")?, "b")?) == "http://a.com/b"
  assert format(resolve(parse("http://[::1]:81/a/b")?, "c")?) == "http://[::1]:81/a/c"
  assert resolve(base, "") is err(_)
  assert resolve(base, "ftp://x/") is err(_)
  assert resolve(base, "/a b") is err(_)
  assert resolve(base, "/é") is err(_)
  assert resolve(base, "mailto:x@a.com") is err(_)
}

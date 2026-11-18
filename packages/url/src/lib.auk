/// URLs and URI references (RFC 3986): parse, format, resolve a reference against a base (with
/// dot-segment removal), and read or build query strings. Pure: no effects. Percent-decoding
/// comes from the `encoding` package.

/// A URI reference. Components stay percent-encoded, as written; `params`, `param` and
/// `segments` decode them. An absent part is `none`, which differs from an empty one (`a?` has
/// `query: some("")`). The scheme and host are lower-cased; an IPv6 host has no brackets.
pub struct Url {
  scheme: str,  // "" in a relative reference
  user: str?,   // userinfo, before '@'
  host: str?,   // none = no authority (`mailto:x`); some("") for `file:///x`
  port: int?,   // none when absent or empty (`host:`)
  path: str,
  query: str?,     // after '?', without it
  fragment: str?,  // after '#', without it
}

/// Why a URL didn't parse. Every `at` is a 0-based char index into the input.
pub enum UrlErr {
  BadChar(at: int, c: char),  // a char not allowed in this part (encode it with `%XX`)
  BadEscape(at: int),         // '%' not followed by two hex digits
  BadScheme(at: int),         // the text before the first ':' isn't a scheme
  BadPort(at: int),           // not digits, or above 65535
  BadHost(at: int),           // e.g. an unclosed or malformed `[IPv6]`
  NotAbsolute,                // `resolve` needs a base with a scheme
}

/// A one-line description of an error, e.g. `bad char ' ' at 18`.
pub fn message(e: UrlErr): str
fn message(BadChar(at, c)): str = "bad char '{c}' at {at}"
fn message(BadEscape(at)): str = "bad percent escape at {at}"
fn message(BadScheme(at)): str = "bad scheme at {at}"
fn message(BadPort(at)): str = "bad port at {at}"
fn message(BadHost(at)): str = "bad host at {at}"
fn message(NotAbsolute): str = "base URL has no scheme"

// ---- parsing (RFC 3986 §3 and Appendix B) ----

/// Parse an absolute URL or a relative reference. Strict RFC 3986: spaces, control chars,
/// non-ASCII and chars like `"<>\^`{|}` must be percent-encoded (`encoding.percent_encode`).
pub fn parse(s: str): Url!UrlErr {
  let cs = s.chars()
  let n = cs.len()
  // fragment and query split first: '#' then '?'
  let hash = cs.find_index(c => c == '#') else n
  let qmark = cs.take(hash).find_index(c => c == '?') else hash
  // a scheme is the text before a ':' that comes before any '/', '?' or '#'
  let stop = cs.take(qmark).find_index(c => c == '/') else qmark
  var i = 0
  var scheme = ""
  match cs.take(stop).find_index(c => c == ':') {
    some(colon) => {
      if !is_scheme(cs.take(colon)) { fail(BadScheme(0)) }
      scheme = str(cs.take(colon)).lower()
      i = colon + 1
    }
    none => {}
  }
  var user: str? = none
  var host: str? = none
  var port: int? = none
  if i + 1 < qmark && cs[i] == '/' && cs[i + 1] == '/' {
    let start = i + 2
    let end =
      start + (cs.skip(start).take(qmark - start).find_index(c => c == '/') else qmark - start)
    let auth = authority(cs, start, end)?
    user = auth.0
    host = some(auth.1)
    port = auth.2
    i = end
  }
  check(cs, i, qmark, "/:@")?
  let path = text(cs, i, qmark)
  var query: str? = none
  if qmark < hash {
    check(cs, qmark + 1, hash, "/?:@")?
    query = some(text(cs, qmark + 1, hash))
  }
  var fragment: str? = none
  if hash < n {
    check(cs, hash + 1, n, "/?:@")?
    fragment = some(text(cs, hash + 1, n))
  }
  Url { scheme, user, host, port, path, query, fragment }
}

fn text(cs: [char], from: int, to: int): str = str(cs.skip(from).take(to - from))

// ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )
fn is_scheme(cs: [char]): bool =
  cs.len() > 0 && is_alpha(cs[0]) && cs.all(c => is_alpha(c) || is_num(c) || "+-.".contains(c))

fn is_alpha(c: char): bool = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
fn is_num(c: char): bool = c >= '0' && c <= '9'
fn is_sub_delim(c: char): bool = "!$&'()*+,;=".contains(c)

// Every char in cs[from..to] is unreserved, a sub-delim, in `extra`, or a valid `%XX`.
fn check(cs: [char], from: int, to: int, extra: str): ()!UrlErr {
  var i = from
  while i < to {
    let c = cs[i]
    if c == '%' {
      if i + 2 >= to { fail(BadEscape(i)) }
      if encoding.hex_val(cs[i + 1]) is none || encoding.hex_val(cs[i + 2]) is none {
        fail(BadEscape(i))
      }
      i += 3
    } else {
      if !(encoding.is_unreserved(c) || is_sub_delim(c) || extra.contains(c)) || int(c) > 127 {
        fail(BadChar(i, c))
      }
      i += 1
    }
  }
}

// authority = [ userinfo "@" ] host [ ":" port ], in cs[from..to]
fn authority(cs: [char], from: int, to: int): (str?, str, int?)!UrlErr {
  let seg = cs.skip(from).take(to - from)
  var hs = from
  var user: str? = none
  match seg.reverse().find_index(c => c == '@') {
    some(back) => {
      let at = to - 1 - back
      check(cs, from, at, ":")?
      user = some(text(cs, from, at))
      hs = at + 1
    }
    none => {}
  }
  var he = to  // host end
  var host = ""
  if hs < to && cs[hs] == '[' {
    let close = cs.skip(hs).take(to - hs).find_index(c => c == ']') else fail(BadHost(hs))
    he = hs + close + 1
    let inner = cs.skip(hs + 1).take(close - 1)
    if inner.len() == 0 ||
      !inner.all(c => encoding.hex_val(c) is some(_) || c == ':' || c == '.') ||
      !inner.contains(':') {
      fail(BadHost(hs))
    }
    host = str(inner).lower()
    if he < to && cs[he] != ':' { fail(BadHost(he)) }
  } else {
    he = hs + (cs.skip(hs).take(to - hs).find_index(c => c == ':') else to - hs)
    check(cs, hs, he, "")?
    host = text(cs, hs, he).lower()
  }
  var port: int? = none
  if he < to {
    // cs[he] is ':'
    let digits = cs.skip(he + 1).take(to - he - 1)
    if !digits.all(c => is_num(c)) { fail(BadPort(he + 1)) }
    if digits.len() > 0 {
      let p = int.parse(str(digits)) else fail(BadPort(he + 1))
      if p > 65535 { fail(BadPort(he + 1)) }
      port = some(p)
    }
  }
  (user, host, port)
}

// ---- formatting (RFC 3986 §5.3) ----

/// The URL as text, so `"{u}"` and `str(u)` print it. If there is a host and the path doesn't
/// start with '/', one is added.
pub fn show(u: Url): str {
  let scheme = if u.scheme == "" { "" } else { u.scheme + ":" }
  let auth = match u.host {
    some(h) => {
      let user = match u.user {
        some(ui) => ui + "@"
        none => ""
      }
      let port = match u.port {
        some(p) => ":{p}"
        none => ""
      }
      let slash = if u.path != "" && !u.path.starts_with("/") { "/" } else { "" }
      "//" + user + bracket(h) + port + slash
    }
    none => ""
  }
  scheme + auth + u.path + part("?", u.query) + part("#", u.fragment)
}

fn part(sep: str, x: str?): str = match x {
  some(v) => sep + v
  none => ""
}

// IPv6 hosts are written in brackets.
fn bracket(h: str): str = if h.contains(":") { "[" + h + "]" } else { h }

/// Does `u` have a scheme (and so can be a base for `resolve`)?
pub fn is_absolute(u: Url): bool = u.scheme != ""

/// The well-known port of a scheme: http/ws 80, https/wss 443, ftp 21.
pub fn default_port(scheme: str): int? = match scheme {
  "http" => some(80)
  "ws" => some(80)
  "https" => some(443)
  "wss" => some(443)
  "ftp" => some(21)
  _ => none
}

/// The explicit port, else the scheme's default.
pub fn port_or_default(u: Url): int? = match u.port {
  some(p) => some(p)
  none => default_port(u.scheme)
}

/// The authority as written in a `Host` header: brackets around IPv6, and the port only when
/// it isn't the scheme's default. Empty when there is no host.
pub fn host_port(u: Url): str {
  let h = u.host else return ""
  let host = bracket(h)
  match u.port {
    some(p) when default_port(u.scheme) != some(p) => "{host}:{p}"
    _ => host
  }
}

/// The path and query, as in an HTTP request line: `/a/b?x=1` (`/` when the path is empty).
pub fn target(u: Url): str {
  let p = if u.path == "" { "/" } else { u.path }
  match u.query {
    some(q) => p + "?" + q
    none => p
  }
}

// ---- reference resolution (RFC 3986 §5.2) ----

/// Resolve a reference (absolute, `//host`, `/path`, `?query`, `#frag` or relative) against an
/// absolute base, removing `.` and `..` segments: `resolve(base, "../x")`.
pub fn resolve(base: Url, rel: str): Url!UrlErr {
  if !base.is_absolute() { fail(NotAbsolute) }
  let r = parse(rel)?
  if r.scheme != "" { return Url { path: remove_dots(r.path), ..r } }
  if r.host is some(_) { return Url { scheme: base.scheme, path: remove_dots(r.path), ..r } }
  let (path, query) = if r.path == "" {
    (base.path, if r.query is some(_) { r.query } else { base.query })
  } else if r.path.starts_with("/") {
    (remove_dots(r.path), r.query)
  } else {
    (remove_dots(merge(base, r.path)), r.query)
  }
  Url { path, query, fragment: r.fragment, ..base }
}

// §5.2.3
fn merge(base: Url, rel: str): str {
  if base.host is some(_) && base.path == "" { return "/" + rel }
  let segs = base.path.split("/")
  segs.take(segs.len() - 1).map(s => s + "/").join("") + rel
}

/// Remove `.` and `..` segments from a path (RFC 3986 §5.2.4): `/a/b/../c/./d` is `/a/c/d`.
pub fn remove_dots(path: str): str {
  var input = path
  var out: [str] = []  // output segments, each with its leading '/' (or none at the start)
  while input != "" {
    if input.starts_with("../") {
      input = drop(input, 3)
    } else if input.starts_with("./") {
      input = drop(input, 2)
    } else if input.starts_with("/./") {
      input = drop(input, 2)
    } else if input == "/." {
      input = "/"
    } else if input.starts_with("/../") {
      input = drop(input, 3)
      out.pop()
    } else if input == "/.." {
      input = "/"
      out.pop()
    } else if input == "." || input == ".." {
      input = ""
    } else {
      // move the first segment (with its leading '/', if any) to the output
      let start = if input.starts_with("/") { 1 } else { 0 }
      let rest = drop(input, start)
      let len = start + (rest.find("/") else rest.len())
      out.push(input[0..len])
      input = drop(input, len)
    }
  }
  out.join("")
}

fn drop(s: str, n: int): str = s[n..s.len()]

// ---- queries and paths ----

/// Decode one form-encoded component: `+` is a space, then `%XX`. A malformed escape is kept
/// as written rather than failing (as browsers do).
fn form_decode(s: str): str {
  let t = s.replace("+", " ")
  encoding.percent_decode(t) else t
}

/// Parse a query string (`a=1&b=x%20y&flag`) into decoded pairs, in order. `+` is a space, a key
/// without `=` gets "", and empty pieces (`a=1&&b=2`) are skipped.
pub fn parse_query(q: str): [(str, str)] {
  var out: [(str, str)] = []
  for piece in q.split("&") {
    if piece == "" { continue }
    match piece.find("=") {
      some(i) => out.push((form_decode(piece[0..i]), form_decode(piece[i + 1..piece.len()])))
      none => out.push((form_decode(piece), ""))
    }
  }
  out
}

/// Build a query string (`application/x-www-form-urlencoded`): each key and value
/// percent-encoded, spaces as `+`, joined with `&`.
pub fn build_query(pairs: [(str, str)]): str =
  pairs.map((k, v) => form_encode(k) + "=" + form_encode(v)).join("&")

fn form_encode(s: str): str = encoding.percent_encode(s).replace("%20", "+")

/// The decoded query pairs of `u` (none if it has no query).
pub fn params(u: Url): [(str, str)] = parse_query(u.query else "")

/// The first value of query parameter `key`.
pub fn param(u: Url, key: str): str? = u.params().find((k, _) => k == key)?.1

/// `u` with its query replaced by `pairs` (no query at all if `pairs` is empty).
pub fn with_params(u: Url, pairs: [(str, str)]): Url =
  Url { query: if pairs.len() == 0 { none } else { some(build_query(pairs)) }, ..u }

/// The decoded path segments: `/a/b%20c/` is `["a", "b c", ""]`; an empty path or `/` is `[]`.
pub fn segments(u: Url): [str] {
  let p = if u.path.starts_with("/") { drop(u.path, 1) } else { u.path }
  if p == "" { return [] }
  p.split("/").map(s => encoding.percent_decode(s) else s)
}

// ---- tests ----

test "parse: full URL" {
  let u = parse("HTTPS://user:pw@Example.COM:8443/a/b%20c?x=1&y=2#top")?
  assert u == Url {
    scheme: "https",
    user: some("user:pw"),
    host: some("example.com"),
    port: some(8443),
    path: "/a/b%20c",
    query: some("x=1&y=2"),
    fragment: some("top"),
  }
  assert "{u}" == "https://user:pw@example.com:8443/a/b%20c?x=1&y=2#top"
}

test "parse: the shapes of RFC 3986 §1.1.2" {
  let ftp = parse("ftp://ftp.is.co.za/rfc/rfc1808.txt")?
  assert ftp.host is some("ftp.is.co.za") && ftp.path == "/rfc/rfc1808.txt"
  let ldap = parse("ldap://[2001:db8::7]/c=GB?objectClass?one")?
  assert ldap.host is some("2001:db8::7") &&
    ldap.path == "/c=GB" &&
    ldap.query is some("objectClass?one")
  let mail = parse("mailto:John.Doe@example.com")?
  assert mail.scheme == "mailto" && mail.host is none && mail.path == "John.Doe@example.com"
  let news = parse("news:comp.infosystems.www.servers.unix")?
  assert news.host is none && news.path == "comp.infosystems.www.servers.unix"
  let tel = parse("tel:+1-816-555-1212")?
  assert tel.path == "+1-816-555-1212"
  let telnet = parse("telnet://192.0.2.16:80/")?
  assert telnet.host is some("192.0.2.16") && telnet.port is some(80) && telnet.path == "/"
  let urn = parse("urn:oasis:names:specification:docbook:dtd:xml:4.1.2")?
  assert urn.scheme == "urn" && urn.path == "oasis:names:specification:docbook:dtd:xml:4.1.2"
  for s in [
    "ftp://ftp.is.co.za/rfc/rfc1808.txt",
    "ldap://[2001:db8::7]/c=GB?objectClass?one",
    "mailto:John.Doe@example.com",
    "tel:+1-816-555-1212",
    "telnet://192.0.2.16:80/",
    "urn:oasis:names:specification:docbook:dtd:xml:4.1.2",
  ] {
    assert "{parse(s)?}" == s
  }
}

test "parse: empty vs absent parts" {
  let a = parse("http://h/p?")?
  assert a.query is some("") && a.fragment is none
  assert "{a}" == "http://h/p?"
  let b = parse("http://h#")?
  assert b.path == "" && b.query is none && b.fragment is some("")
  let f = parse("file:///etc/hosts")?
  assert f.host is some("") && f.path == "/etc/hosts"
  assert "{f}" == "file:///etc/hosts"
  let p = parse("http://h:/x")?
  assert p.port is none
  assert parse("")? ==
    Url { scheme: "", user: none, host: none, port: none, path: "", query: none, fragment: none }
}

test "parse: relative references" {
  let r = parse("../a/b?q#f")?
  assert r.scheme == "" && r.host is none && r.path == "../a/b" && !r.is_absolute()
  let n = parse("//cdn.example.com/lib.js")?
  assert n.scheme == "" && n.host is some("cdn.example.com") && n.path == "/lib.js"
  assert (parse("?only")?).query is some("only")
  assert (parse("#only")?).fragment is some("only")
  assert (parse("a/b:c")?).path == "a/b:c"  // ':' after the first '/' is not a scheme
}

test "parse: errors" {
  assert parse("http://a.com/a b") is err(BadChar(14, ' '))
  assert parse("http://a.com/é") is err(BadChar(13, 'é'))
  assert parse("http://a.com/x\r\nHost: evil") is err(BadChar(14, '\r'))
  assert parse("http://a.com/%zz") is err(BadEscape(13))
  assert parse("http://a.com/%4") is err(BadEscape(13))
  assert parse("http://a.com/?q=<b>") is err(BadChar(16, '<'))
  assert parse("1http://x") is err(BadScheme(0))
  assert parse(":x") is err(BadScheme(0))
  assert parse("http://a.com:8o/") is err(BadPort(13))
  assert parse("http://a.com:65536/") is err(BadPort(13))
  assert parse("http://a:1:2/") is err(BadPort(9))
  assert parse("http://[::1/") is err(BadHost(7))
  assert parse("http://[::1]x/") is err(BadHost(12))
  assert parse("http://[]/") is err(BadHost(7))
  assert parse("http://[zz]/") is err(BadHost(7))
  assert parse("http://a b/") is err(BadChar(8, ' '))
  assert message(BadChar(14, ' ')) == "bad char ' ' at 14"
  assert message(NotAbsolute) == "base URL has no scheme"
}

test "IPv6 and ports" {
  let u = parse("http://[FE80::1]:8080/x")?
  assert u.host is some("fe80::1") && u.port is some(8080)
  assert "{u}" == "http://[fe80::1]:8080/x"
  assert host_port(u) == "[fe80::1]:8080"
  assert host_port(parse("https://a.com:443/")?) == "a.com"
  assert host_port(parse("http://a.com:8080")?) == "a.com:8080"
  assert port_or_default(parse("https://a.com/")?) is some(443)
  assert port_or_default(parse("http://a.com:81/")?) is some(81)
  assert port_or_default(parse("gopher://a.com/")?) is none
  assert target(parse("http://a.com")?) == "/"
  assert target(parse("http://a.com/p?q=1#f")?) == "/p?q=1"
}

let BASE = "http://a/b/c/d;p?q"

fn res(rel: str): str = "{resolve(parse(BASE)!, rel)!}"

test "resolve: RFC 3986 §5.4.1 normal examples" {
  assert res("g:h") == "g:h"
  assert res("g") == "http://a/b/c/g"
  assert res("./g") == "http://a/b/c/g"
  assert res("g/") == "http://a/b/c/g/"
  assert res("/g") == "http://a/g"
  assert res("//g") == "http://g"
  assert res("?y") == "http://a/b/c/d;p?y"
  assert res("g?y") == "http://a/b/c/g?y"
  assert res("#s") == "http://a/b/c/d;p?q#s"
  assert res("g#s") == "http://a/b/c/g#s"
  assert res("g?y#s") == "http://a/b/c/g?y#s"
  assert res(";x") == "http://a/b/c/;x"
  assert res("g;x") == "http://a/b/c/g;x"
  assert res("g;x?y#s") == "http://a/b/c/g;x?y#s"
  assert res("") == "http://a/b/c/d;p?q"
  assert res(".") == "http://a/b/c/"
  assert res("./") == "http://a/b/c/"
  assert res("..") == "http://a/b/"
  assert res("../") == "http://a/b/"
  assert res("../g") == "http://a/b/g"
  assert res("../..") == "http://a/"
  assert res("../../") == "http://a/"
  assert res("../../g") == "http://a/g"
}

test "resolve: RFC 3986 §5.4.2 abnormal examples" {
  assert res("../../../g") == "http://a/g"
  assert res("../../../../g") == "http://a/g"
  assert res("/./g") == "http://a/g"
  assert res("/../g") == "http://a/g"
  assert res("g.") == "http://a/b/c/g."
  assert res(".g") == "http://a/b/c/.g"
  assert res("g..") == "http://a/b/c/g.."
  assert res("..g") == "http://a/b/c/..g"
  assert res("./../g") == "http://a/b/g"
  assert res("./g/.") == "http://a/b/c/g/"
  assert res("g/./h") == "http://a/b/c/g/h"
  assert res("g/../h") == "http://a/b/c/h"
  assert res("g;x=1/./y") == "http://a/b/c/g;x=1/y"
  assert res("g;x=1/../y") == "http://a/b/c/y"
  assert res("g?y/./x") == "http://a/b/c/g?y/./x"
  assert res("g?y/../x") == "http://a/b/c/g?y/../x"
  assert res("g#s/./x") == "http://a/b/c/g#s/./x"
  assert res("g#s/../x") == "http://a/b/c/g#s/../x"
  assert res("http:g") == "http:g"  // strict parsers keep the scheme
}

test "resolve: edge cases" {
  let host_only = parse("http://a.com")?
  assert "{resolve(host_only, "b")?}" == "http://a.com/b"
  assert "{resolve(host_only, "?x")?}" == "http://a.com?x"
  assert resolve(parse("../rel")?, "x") is err(NotAbsolute)
  assert resolve(host_only, "a b") is err(BadChar(1, ' '))
  assert remove_dots("/a/b/c/./../../g") == "/a/g"
  assert remove_dots("mid/content=5/../6") == "mid/6"
  assert remove_dots("") == ""
  assert remove_dots("/") == "/"
}

test "query strings" {
  assert parse_query("") == []
  assert parse_query("a=1&b=x%20y&c=p+q&flag&&e=") ==
    [("a", "1"), ("b", "x y"), ("c", "p q"), ("flag", ""), ("e", "")]
  assert parse_query("k=v=w") == [("k", "v=w")]
  assert parse_query("bad=%zz&ü=%C3%BC") == [("bad", "%zz"), ("ü", "ü")]
  assert parse_query("a=1&a=2") == [("a", "1"), ("a", "2")]
  assert build_query([("q", "auk typing"), ("lang", "en&fr"), ("e", "")]) ==
    "q=auk+typing&lang=en%26fr&e="
  assert build_query([]) == ""
  let pairs = [("a b", "c+d"), ("ü", "/?#&=")]
  assert parse_query(build_query(pairs)) == pairs
}

test "params on a Url" {
  let u = parse("https://a.com/search?q=auk+lang&page=2&q=again")?
  assert u.params() == [("q", "auk lang"), ("page", "2"), ("q", "again")]
  assert u.param("q") is some("auk lang")
  assert u.param("page") is some("2")
  assert u.param("missing") is none
  assert (parse("https://a.com/")?).params() == []
  let v = u.with_params([("q", "a&b"), ("n", "1")])
  assert "{v}" == "https://a.com/search?q=a%26b&n=1"
  assert "{u.with_params([])}" == "https://a.com/search"
}

test "path segments" {
  assert (parse("http://a/x/b%20c/")?).segments() == ["x", "b c", ""]
  assert (parse("http://a/")?).segments() == []
  assert (parse("http://a")?).segments() == []
  assert (parse("rel/p")?).segments() == ["rel", "p"]
}

test "build a Url by hand" {
  let u = Url {
    scheme: "https",
    user: none,
    host: some("api.example.com"),
    port: none,
    path: "v1/items",
    query: some(build_query([("id", "7")])),
    fragment: none,
  }
  assert "{u}" == "https://api.example.com/v1/items?id=7"
  assert (parse("{u}")?).path == "/v1/items"
}

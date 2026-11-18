/// Binary-to-text encodings: base64 (RFC 4648 standard and URL-safe), hex, and percent-encoding
/// (RFC 3986). Pure: no effects. Bytes are `[int]` (0..255), as in core `net` and `fs`.

/// Why decoding failed. Every `at` is a 0-based char index into the input.
pub enum EncErr {
  BadChar(at: int, c: char),  // a char outside the alphabet
  BadLength(len: int),        // a length the encoding can't produce (e.g. odd hex)
  BadPadding(at: int),        // a misplaced or missing '='
  TrailingBits(at: int),      // the last base64 char has non-zero unused bits (not canonical)
  BadEscape(at: int),         // '%' not followed by two hex digits
  BadUtf8,                    // the decoded bytes aren't valid UTF-8
}

/// A one-line description of a decoding error, e.g. `bad char '!' at 3`.
pub fn message(e: EncErr): str
fn message(BadChar(at, c)): str = "bad char '{c}' at {at}"
fn message(BadLength(n)): str = "bad length {n}"
fn message(BadPadding(at)): str = "bad padding at {at}"
fn message(TrailingBits(at)): str = "non-zero trailing bits at {at}"
fn message(BadEscape(at)): str = "bad percent escape at {at}"
fn message(BadUtf8): str = "decoded bytes are not valid UTF-8"

fn is_bytes(bs: [int]): bool = bs.all(b => b >= 0 && b <= 255)

// ---- base64 ----

let STD = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".chars()
let URL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".chars()

/// Standard base64 (RFC 4648 §4) with `=` padding: `base64("hi".bytes()) == "aGk="`.
pub fn base64(bs: [int]): str = encode64(bs, false, true)

/// URL-safe base64 (RFC 4648 §5: `-` and `_` instead of `+` and `/`) without padding, as used by
/// JWTs: `base64url([251, 255]) == "-_8"`.
pub fn base64url(bs: [int]): str = encode64(bs, true, false)

/// Base64 with a choice of alphabet (`url`: URL-safe) and of `=` padding.
pub fn encode64(bs: [int], url: bool, pad: bool): str
  requires is_bytes(bs)
{
  let abc = if url { URL } else { STD }
  var out: [char] = []
  var i = 0
  while i + 2 < bs.len() {
    let n = (bs[i] << 16) | (bs[i + 1] << 8) | bs[i + 2]
    out.push(abc[n >> 18])
    out.push(abc[(n >> 12) & 63])
    out.push(abc[(n >> 6) & 63])
    out.push(abc[n & 63])
    i += 3
  }
  let rest = bs.len() - i
  if rest == 1 {
    let n = bs[i] << 16
    out.push(abc[n >> 18])
    out.push(abc[(n >> 12) & 63])
    if pad {
      out.push('=')
      out.push('=')
    }
  } else if rest == 2 {
    let n = (bs[i] << 16) | (bs[i + 1] << 8)
    out.push(abc[n >> 18])
    out.push(abc[(n >> 12) & 63])
    out.push(abc[(n >> 6) & 63])
    if pad { out.push('=') }
  }
  str(out)
}

/// Decode standard base64. Strict: no whitespace, no URL-safe chars, and the unused bits of the
/// last char must be zero. Padding is optional, but if present it must be exactly right.
pub fn from_base64(s: str): [int]!EncErr = decode64(s, false)

/// Decode URL-safe base64 (`-` and `_`), with the same rules as `from_base64`.
pub fn from_base64url(s: str): [int]!EncErr = decode64(s, true)

// The 6-bit value of a base64 char, or -1.
fn val64(c: char, url: bool): int {
  if c >= 'A' && c <= 'Z' { return int(c) - int('A') }
  if c >= 'a' && c <= 'z' { return int(c) - int('a') + 26 }
  if c >= '0' && c <= '9' { return int(c) - int('0') + 52 }
  match (c, url) {
    ('+', false) => 62
    ('/', false) => 63
    ('-', true) => 62
    ('_', true) => 63
    _ => -1
  }
}

fn decode64(s: str, url: bool): [int]!EncErr {
  let cs = s.chars()
  // Split off the padding: at most two '=' at the very end.
  var n = cs.len()
  while n > 0 && cs[n - 1] == '=' { n -= 1 }
  var out: [int] = []
  var acc = 0
  var bits = 0
  for i in 0..n {
    let c = cs[i]
    let v = val64(c, url)
    if v < 0 {
      if c == '=' { fail(BadPadding(i)) }
      fail(BadChar(i, c))
    }
    acc = (acc << 6) | v
    bits += 6
    if bits >= 8 {
      bits -= 8
      out.push((acc >> bits) & 0xff)
      acc = acc & (1 << bits) - 1
    }
  }
  let pads = cs.len() - n
  if pads > 2 || (pads > 0 && cs.len() % 4 != 0) { fail(BadPadding(n)) }
  if n % 4 == 1 { fail(BadLength(cs.len())) }
  if acc != 0 { fail(TrailingBits(n - 1)) }
  out
}

// ---- hex ----

let HEX = "0123456789abcdef".chars()

/// Lower-case hex, two digits per byte: `hex([0, 171]) == "00ab"`.
pub fn hex(bs: [int]): str
  requires is_bytes(bs)
{
  var out: [char] = []
  for b in bs {
    out.push(HEX[b >> 4])
    out.push(HEX[b & 15])
  }
  str(out)
}

/// Upper-case hex: `hex_upper([0, 171]) == "00AB"`.
pub fn hex_upper(bs: [int]): str = hex(bs).upper()

/// Decode hex (either case). An odd length is `BadLength`; a non-hex char is `BadChar`.
pub fn from_hex(s: str): [int]!EncErr {
  let cs = s.chars()
  if cs.len() % 2 != 0 { fail(BadLength(cs.len())) }
  var out: [int] = []
  var i = 0
  while i < cs.len() {
    let hi = hex_val(cs[i]) else fail(BadChar(i, cs[i]))
    let lo = hex_val(cs[i + 1]) else fail(BadChar(i + 1, cs[i + 1]))
    out.push((hi << 4) | lo)
    i += 2
  }
  out
}

/// The value of one hex digit (either case).
pub fn hex_val(c: char): int? {
  if c >= '0' && c <= '9' { return int(c) - int('0') }
  if c >= 'a' && c <= 'f' { return int(c) - int('a') + 10 }
  if c >= 'A' && c <= 'F' { return int(c) - int('A') + 10 }
  none
}

// ---- percent-encoding (RFC 3986 §2.1) ----

/// RFC 3986 unreserved chars, which are never encoded: `A-Z a-z 0-9 - . _ ~`.
pub fn is_unreserved(c: char): bool =
  (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || "-._~".contains(c)

/// Percent-encode one URI component: every UTF-8 byte except the unreserved chars becomes `%XX`
/// (upper-case hex). `percent_encode("a b/ü") == "a%20b%2F%C3%BC"`.
pub fn percent_encode(s: str): str = percent_encode(s, "")

/// Like `percent_encode`, but also keeps the ASCII chars in `safe` as they are, e.g. `"/"` for a
/// path or `"!$&'()*+,;=:@/"` for RFC 3986 `pchar`s.
pub fn percent_encode(s: str, safe: str): str {
  var out: [char] = []
  for c in s.chars() {
    if is_unreserved(c) || (int(c) < 128 && safe.contains(c)) {
      out.push(c)
    } else {
      for b in str(c).bytes() {
        out.push('%')
        out.push(HEX[b >> 4].upper())
        out.push(HEX[b & 15].upper())
      }
    }
  }
  str(out)
}

/// Decode `%XX` escapes (either case) to bytes; every other char contributes its UTF-8 bytes.
/// `+` stays `+` (form decoding, where `+` is a space, is `url.parse_query`).
pub fn percent_decode_bytes(s: str): [int]!EncErr {
  let cs = s.chars()
  var out: [int] = []
  var i = 0
  while i < cs.len() {
    let c = cs[i]
    if c == '%' {
      if i + 2 >= cs.len() { fail(BadEscape(i)) }
      let hi = hex_val(cs[i + 1]) else fail(BadEscape(i))
      let lo = hex_val(cs[i + 2]) else fail(BadEscape(i))
      out.push((hi << 4) | lo)
      i += 3
    } else {
      for b in str(c).bytes() { out.push(b) }
      i += 1
    }
  }
  out
}

/// Decode `%XX` escapes and read the result as UTF-8 text.
pub fn percent_decode(s: str): str!EncErr {
  let bs = percent_decode_bytes(s)?
  str.from_utf8(bs) else fail(BadUtf8)
}

// ---- tests ----

test "base64: RFC 4648 §10 vectors" {
  let cases = [
    ("", "", ""),
    ("f", "Zg==", "Zg"),
    ("fo", "Zm8=", "Zm8"),
    ("foo", "Zm9v", "Zm9v"),
    ("foob", "Zm9vYg==", "Zm9vYg"),
    ("fooba", "Zm9vYmE=", "Zm9vYmE"),
    ("foobar", "Zm9vYmFy", "Zm9vYmFy"),
  ]
  for (plain, padded, raw) in cases {
    assert base64(plain.bytes()) == padded
    assert encode64(plain.bytes(), false, false) == raw
    assert from_base64(padded)? == plain.bytes()
    assert from_base64(raw)? == plain.bytes()
  }
}

test "base64: every byte value round-trips" {
  var all: [int] = []
  for b in 0..256 { all.push(b) }
  for n in 0..=6 {
    let bs = all.skip(n)
    assert from_base64(base64(bs))? == bs
    assert from_base64url(base64url(bs))? == bs
    assert from_base64url(encode64(bs, true, true))? == bs
  }
}

test "base64: url-safe alphabet" {
  let bs = [0xfb, 0xff, 0xbf]
  assert base64(bs) == "+/+/"
  assert base64url(bs) == "-_-_"
  assert base64url([0xfb, 0xff]) == "-_8"
  assert encode64([0xfb, 0xff], true, true) == "-_8="
  assert from_base64url("-_-_")? == bs
  assert from_base64("-_-_") is err(BadChar(0, '-'))
  assert from_base64url("+/+/") is err(BadChar(0, '+'))
  assert base64url("hello world".bytes()) == "aGVsbG8gd29ybGQ"
}

test "base64: strict decoding errors" {
  assert from_base64("Zm9v YmFy") is err(BadChar(4, ' '))
  assert from_base64("Zm9v\n") is err(BadChar(4, '\n'))
  assert from_base64("Zm!v") is err(BadChar(2, '!'))
  assert from_base64("Z") is err(BadLength(1))
  assert from_base64("Zm9vY") is err(BadLength(5))
  assert from_base64("Zg=") is err(BadPadding(2))    // padded but not a multiple of 4
  assert from_base64("Zg===") is err(BadPadding(2))  // three '='
  assert from_base64("Z===") is err(BadPadding(1))
  assert from_base64("Zg==Zg==") is err(BadPadding(2))  // padding in the middle
  assert from_base64("=") is err(BadPadding(0))
  assert from_base64("Zh==") is err(TrailingBits(1))  // 'h' leaves non-zero bits
  assert from_base64("Zm9=") is err(TrailingBits(2))
  assert from_base64("Zm8=")? == "fo".bytes()
}

test "hex" {
  assert hex([]) == ""
  assert hex([0, 1, 15, 16, 171, 255]) == "00010f10abff"
  assert hex_upper([222, 173, 190, 239]) == "DEADBEEF"
  assert from_hex("DEADbeef")? == [222, 173, 190, 239]
  assert from_hex("")? == []
  assert from_hex("abc") is err(BadLength(3))
  assert from_hex("0g") is err(BadChar(1, 'g'))
  assert from_hex("x0") is err(BadChar(0, 'x'))
  var all: [int] = []
  for b in 0..256 { all.push(b) }
  assert from_hex(hex(all))? == all
  assert hex_val('F') is some(15)
  assert hex_val('G') is none
}

test "percent encoding" {
  assert percent_encode("") == ""
  assert percent_encode("AZaz09-._~") == "AZaz09-._~"
  assert percent_encode("a b&c=d/e?f#g") == "a%20b%26c%3Dd%2Fe%3Ff%23g"
  assert percent_encode("ü€😀") == "%C3%BC%E2%82%AC%F0%9F%98%80"
  assert percent_encode("100%") == "100%25"
  assert percent_encode("/a b/c", "/") == "/a%20b/c"
  assert percent_encode("k=v;x", "=;") == "k=v;x"
  assert percent_encode("é", "é") == "%C3%A9"  // only ASCII can be kept
}

test "percent decoding" {
  assert percent_decode("a%20b%2fc")? == "a b/c"
  assert percent_decode("%C3%BC%e2%82%ac")? == "ü€"
  assert percent_decode("a+b")? == "a+b"
  assert percent_decode("ü%20")? == "ü "
  assert percent_decode("plain")? == "plain"
  assert percent_decode("%") is err(BadEscape(0))
  assert percent_decode("ab%2") is err(BadEscape(2))
  assert percent_decode("%zz") is err(BadEscape(0))
  assert percent_decode("%FF") is err(BadUtf8)
  assert percent_decode_bytes("%FF%00")? == [255, 0]
  for s in ["", "a b", "x/y?z=1&w=ü", "😀%+~"] {
    assert percent_decode(percent_encode(s))? == s
  }
}

fn untyped(s: str): [int]! = from_hex(s)?

test "messages" {
  assert message(BadChar(3, '!')) == "bad char '!' at 3"
  assert message(BadLength(5)) == "bad length 5"
  assert message(BadPadding(2)) == "bad padding at 2"
  assert message(TrailingBits(1)) == "non-zero trailing bits at 1"
  assert message(BadEscape(0)) == "bad percent escape at 0"
  assert message(BadUtf8) == "decoded bytes are not valid UTF-8"
  assert untyped("zz") is err(_)  // a typed error passes up through `?` into a plain `T!`
  assert untyped("0a")? == [10]
}

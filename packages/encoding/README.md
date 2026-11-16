# encoding

Binary-to-text encodings: base64 (RFC 4648, standard and URL-safe, with or without padding), hex, and percent-encoding (RFC 3986). Bytes are `[int]` (0..255), as in core `net` and `fs`; use `s.bytes()` and `str.from_utf8(bs)` to go between text and bytes. Decoding is strict and fails with a typed `EncErr` that says where the input went wrong.

**Effects:** none.

```duck
let token = encoding.base64("user:pass".bytes())           // "dXNlcjpwYXNz"
let raw = encoding.from_base64(token)?                     // [117, 115, ...]
print(str.from_utf8(raw)?)
let id = encoding.hex(hash.sha256("abc".bytes()))          // "ba7816bf..."
let q = encoding.percent_encode("a b&c")                   // "a%20b%26c"
match encoding.from_base64("Zm9v YmFy") {
  err(e) => print(encoding.message(e))                     // bad char ' ' at 4
  ok(_) => {}
}
```

## API
- `enum EncErr { BadChar(at: int, c: char), BadLength(len: int), BadPadding(at: int), TrailingBits(at: int), BadEscape(at: int), BadUtf8 }`: every `at` is a 0-based char index into the input.
- `message(e: EncErr): str`: e.g. `bad char '!' at 3`.

Base64:
- `base64(bs: [int]): str`: standard alphabet, `=` padded.
- `base64url(bs: [int]): str`: URL-safe alphabet (`-` `_`), no padding (JWT style).
- `encode64(bs: [int], url: bool, pad: bool): str`: any combination of alphabet and padding.
- `from_base64(s: str): [int]!EncErr` and `from_base64url(s: str): [int]!EncErr`: strict. Whitespace, chars from the other alphabet and non-zero unused bits in the last char are errors. Padding is optional, but when present it must make the length a multiple of 4.

Hex:
- `hex(bs: [int]): str` (lower case), `hex_upper(bs: [int]): str`.
- `from_hex(s: str): [int]!EncErr`: either case; an odd length is `BadLength`.
- `hex_val(c: char): int?`: the value of one hex digit.

Percent-encoding (RFC 3986 §2.1):
- `percent_encode(s: str): str`: encodes every UTF-8 byte except the unreserved chars `A-Z a-z 0-9 - . _ ~`, as upper-case `%XX`. Right for one query key, query value or path segment.
- `percent_encode(s: str, safe: str): str`: also keeps the ASCII chars in `safe` (e.g. `"/"` for a whole path).
- `percent_decode(s: str): str!EncErr`: decodes `%XX` (either case), then reads UTF-8. `+` stays `+`; form decoding (`+` is a space) is `url.parse_query`.
- `percent_decode_bytes(s: str): [int]!EncErr`: the raw bytes, for non-text payloads.
- `is_unreserved(c: char): bool`.

Encoders require every byte to be in 0..255 (a contract, checked in every build).

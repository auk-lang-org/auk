# hash

Hashes and checksums in plain Auk: SHA-256 (one-shot or streaming), HMAC-SHA-256, CRC-32, FNV-1a (64-bit), and a constant-time comparison for MACs. Bytes are `[int]` (0..255); hash text with `s.bytes()`. Tested against the NIST SHA-256 vectors, RFC 4231 (HMAC) and the standard CRC-32 check value.

**Effects:** none.

```auk
let digest = hash.sha256(fs.read_bytes("app.tar")?)      // 32 bytes
print(hash.sha256_hex("abc"))                              // ba7816bf8f01cfea...
var h = hash.new_sha256()                                  // streaming
for chunk in chunks { h.update(chunk) }
let same = h.finish()

// verify a webhook signature (hex-encoded HMAC)
let mac = hash.hmac_sha256(secret.bytes(), body.bytes())
let sent = encoding.from_hex(header)?
if !hash.equal(mac, sent) { fail("bad signature") }
```

## API
- `sha256(data: [int]): [int]`: the 32-byte digest.
- `sha256_hex(s: str): str`: the digest of the text's UTF-8 bytes as 64 lower-case hex digits; `sha256_hex(data: [int]): str` hashes bytes.
- `struct Sha256`, `new_sha256(): Sha256`, `update(s: var Sha256, data: [int])` (`s.update(chunk)`), `finish(s: Sha256): [int]`: streaming. Chunk sizes never change the digest, and `finish` leaves the state usable, so you can keep updating.
- `hmac_sha256(key: [int], msg: [int]): [int]`: RFC 2104 HMAC (keys longer than 64 bytes are hashed first).
- `crc32(data: [int]): int`: IEEE CRC-32 (zip, gzip, PNG), in 0..2^32. `crc32_update(crc, data)` continues one: `crc32_update(crc32(a), b) == crc32(a + b)`.
- `fnv1a64(data: [int]): int`: 64-bit FNV-1a, non-cryptographic (hash tables, cache keys). All 64 bits are used, so the result may be negative.
- `equal(a: [int], b: [int]): bool`: constant-time comparison; the time depends only on the lengths. Use it, not `==`, to check MACs and tokens.

For hex output of other digests use `encoding.hex`. Inputs must be bytes in 0..255 (a contract, checked in every build).

Not included in 0.1: SHA-1, SHA-512, MD5 and BLAKE. This package is not for password storage; that needs a slow, salted hash (argon2, bcrypt), planned for `crypto`.

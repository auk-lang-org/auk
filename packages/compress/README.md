# compress

DEFLATE (RFC 1951), its two common wrappers gzip (RFC 1952) and zlib (RFC 1950), and zip archives, in pure Duck. Also the CRC-32 and Adler-32 checksums those formats use. The decoder reads every block type: stored, fixed Huffman and dynamic Huffman. The encoder writes stored and fixed-Huffman blocks with LZ77 matching. Its output decodes with any standard tool (`gzip -d`, `zlib`, browsers), but it is **not zlib-level compression**: there are no dynamic Huffman blocks and no lazy matching. On text it typically comes out 15–25% larger than `gzip -9`. Errors are a typed `ZErr` with the byte offset of the problem.

**Effects:** none. **Dependencies:** none.

```duck
let gz = compress.gzip(fs.read_bytes("log.txt")?)
fs.write_bytes("log.txt.gz", gz)?
let text = str.from_utf8(compress.gunzip(fs.read_bytes("log.txt.gz")?)?)?
match compress.unzlib([0x78, 0x9c, 1, 2]) {
  err(e) => print(compress.message(e))     // compressed data is truncated
  ok(_) => {}
}
let z = compress.zip([compress.Entry { name: "notes/a.txt", data: "hi".bytes() }])
for e in compress.unzip(z)? { print("{e.name}: {e.data.len()} bytes") }
```

## API
Bytes are `[int]` (0–255), as in `fs.read_bytes` and core `net`.
- `enum ZErr { Truncated, BadHeader(at: int, why: str), BadData(at: int, why: str), BadChecksum(what: str) }`:
  - `at` is a byte offset into the input.
  - `what` is `"CRC-32"`, `"Adler-32"`, `"length"` or `"header CRC"`.
  - `message(e: ZErr): str` gives a one-line description, for example `bad deflate data at 12: distance too far back`.
- `gzip(data): [int]`: a single gzip member, with no file name, modification time 0 and OS "unknown".
- `gunzip(data): [int]!ZErr`:
  - It decodes every member and joins the results, as `gzip -d` does.
  - It reads and skips the optional header fields (extra, name and comment), and checks the header CRC when one is present.
  - It checks each member's CRC-32 and length.
  - Trailing bytes that aren't another gzip member are an error.
- `zlib(data): [int]`: a zlib stream with header `78 01` and an Adler-32 trailer.
- `unzlib(data): [int]!ZErr`: checks the header and the Adler-32. Preset dictionaries (`FDICT`) and data after the stream are errors.
- `deflate(data): [int]`: raw DEFLATE.
  - It finds LZ77 matches with hash chains over the full 32 KiB window, up to 64 candidates per position.
  - It codes each 64 KiB chunk as a fixed-Huffman block, or as a stored block when that would be smaller, so random data grows by only a few bytes.
- `store(data): [int]`: raw DEFLATE made only of stored blocks, with no compression.
- `inflate(data): [int]!ZErr`: decodes raw DEFLATE. Bytes after the final block are ignored, as zlib's raw mode does.
- `struct Entry { name: str, data: [int] }`: one file in a zip archive. A name ending in `/` is a directory, with empty `data`.
- `zip(entries): [int]`:
  - Each file is deflated, or stored when deflating doesn't shrink it.
  - Names are written as UTF-8 (flag bit 11), with Unix modes 644 for files and 755 for directories.
  - Every timestamp is 1980-01-01 00:00, so the same entries always give the same bytes.
- `unzip(data): [Entry]!ZErr`:
  - It returns entries in central-directory order, including directories.
  - It reads stored and deflated entries, with or without data descriptors, and skips extra fields and archive comments.
  - It checks each entry's CRC-32 and size.
  - Encrypted entries, other methods (bzip2, LZMA, zstd), zip64 archives and non-UTF-8 names are `BadHeader` errors.
  - Names come back as written. **Check them for `..` and a leading `/` before using them as paths.**
- `crc32(data): int`, `crc32_update(crc, data): int` (IEEE, as in gzip, zip and PNG) and `adler32(data): int`.

## Limits in 0.1
- **Output size.** The encoder makes no dynamic Huffman blocks and doesn't use lazy matching, so its output is larger than zlib's (see above).
- **Speed.** About 15 MB/s to compress and 50 MB/s to decompress on a laptop.
- **Memory.** Everything happens in memory on `[int]`, which takes 8 bytes per byte until core has a bytes type, and there is no streaming API.
- **Decompression bombs.** Nothing limits the output size. Check the input size before you inflate untrusted data.
- **Zip.** No zip64 (archives over 4 GiB or 65,535 entries), no encryption, no timestamps or permissions on read, and no multi-disk archives.
- **Not yet supported:** `Content-Encoding: gzip` in `http`, and zstd, brotli and bzip2.

/// A package bundle (`raft pack`, `<name>.raft`): the package's files in one blob, so it can be
/// served from any static http(s) host. It is exactly the data raft.lock's checksum hashes: for
/// each file, in sorted path order, its relative path, a NUL, its length as 8 big-endian bytes,
/// then its contents. So `sha256` of a bundle is the package's lock checksum.

/// Encode (relative path, bytes) pairs, already sorted by path.
pub fn encode(files: [(str, [int])]): [int] {
  var out: [int] = []
  for (rel, bytes) in files {
    out += rel.bytes()
    out.push(0)
    let n = bytes.len()
    for i in 0..8 { out.push((n >> (56 - 8 * i)) & 0xff) }
    out += bytes
  }
  out
}

/// Decode a bundle, accepting only what `raft pack` makes: `raft.toml` (required), `README.md`,
/// and files under `src/`, in strictly increasing order, with no `.`, `..` or empty components.
pub fn decode(bs: [int]): [(str, [int])]! {
  var out: [(str, [int])] = []
  var pos = 0
  while pos < bs.len() {
    var nul = pos
    while nul < bs.len() && bs[nul] != 0 { nul += 1 }
    if nul == bs.len() || nul == pos || nul - pos > 4096 { fail("bad file name") }
    let rel = str.from_utf8(bs[pos..nul]) else fail("file name is not UTF-8")
    if !allowed(rel) { fail("unexpected file `{rel}`") }
    match out.last() {
      some(prev) when prev.0 >= rel => fail("files out of order at `{rel}`")
      _ => {}
    }
    let at = nul + 1
    if at + 8 > bs.len() { fail("truncated at `{rel}`") }
    var n = 0
    for i in 0..8 { n = (n << 8) | bs[at + i] }
    let start = at + 8
    if n < 0 || start + n > bs.len() { fail("truncated at `{rel}`") }
    out.push((rel, bs[start..start + n]))
    pos = start + n
  }
  if !out.any(f => f.0 == "raft.toml") { fail("no raft.toml") }
  out
}

fn allowed(rel: str): bool {
  if rel == "raft.toml" || rel == "README.md" { return true }
  let parts = rel.split("/")
  parts.len() >= 2 && parts[0] == "src" &&
    parts.all(p => p != "" && p != "." && p != ".." && !p.contains("\\") && !p.contains(":"))
}

test "round trip" {
  let files = [("raft.toml", "a".bytes()), ("src/lib.auk", [0, 1, 255])]
  assert decode(encode(files))? == files
}

test "rejects what pack never makes" {
  let one = (rel: str) => encode([("raft.toml", []), (rel, [1])])
  assert decode(one("src/../../x")) is err(_)
  assert decode(one("src//x")) is err(_)
  assert decode(one("bin/x")) is err(_)
  assert decode(encode([("src/a.auk", [])])) is err(_)
  assert decode(encode([("src/a.auk", []), ("raft.toml", [])])) is err(_)
  let whole = encode([("raft.toml", [1, 2, 3])])
  assert decode(whole.take(whole.len() - 1)) is err(_)
}

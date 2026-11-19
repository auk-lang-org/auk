/// The compiler's version: the `[package] version` of `compiler/raft.toml`, compiled in
/// (`#embed`), so the manifest is the one place it is written. `auk -v`, the `dive` banner, the
/// LSP and MCP `serverInfo` and the DWARF producer string all read it here.

extern fn manifest(): str = "#embed ../raft.toml"

/// The version, e.g. `0.1.0`.
pub fn text(): str uses ffi = of_manifest(manifest())

/// The `[package] version` of a `raft.toml` (`""` if it has none).
fn of_manifest(toml: str): str {
  var section = ""
  for raw in toml.lines() {
    let line = raw.trim()
    if line.starts_with("[") {
      section = line
      continue
    }
    if section != "[package]" { continue }
    let eq = line.find("=") else continue
    if line[0..eq].trim() != "version" { continue }
    let val = line[eq + 1..line.len()]
    let open = val.find("\"") else continue
    let rest = val[open + 1..val.len()]
    let close = rest.find("\"") else continue
    return rest[0..close]
  }
  ""
}

test "the manifest's version" {
  assert of_manifest("[package]\nname = \"a\"\nversion = \"1.2.3\" # c\n\n[deps]\nb = \"^0.1\"\n") == "1.2.3"
  assert of_manifest("[deps]\nversion = \"9.9.9\"\n") == ""
  assert of_manifest("[package]\nname = \"a\"\n") == ""
}

test "this compiler has a version" {
  let parts = text().split(".")
  assert parts.len() == 3
  assert parts.all(p => p != "" && p.chars().all(c => c >= '0' && c <= '9'))
}

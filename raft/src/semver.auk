/// Semantic versions (`MAJOR.MINOR.PATCH`) and requirements (`^1.2`, `~1.2.3`, `=1.2.3`, `*`)
/// (src/bin/raft/semver.rs).
///
/// Differences in shape from the Rust: a component is an `int`, so one past 2^63 - 1 is invalid
/// (Rust's `u64` takes up to 2^64 - 1); `Version` orders by `cmp` (Rust derives `Ord`).

pub struct Version {
  major: int,
  minor: int,
  patch: int,
}

/// Parse exactly `MAJOR.MINOR.PATCH` (no pre-release or build suffix).
pub fn parse_version(s: str): Version? {
  match parts(s)? {
    [major, minor, patch] => Version { major, minor, patch }
    _ => none
  }
}

pub fn cmp(a: Version, b: Version): int {
  if a.major != b.major { return a.major - b.major }
  if a.minor != b.minor { return a.minor - b.minor }
  a.patch - b.patch
}

pub fn show(v: Version): str = "{v.major}.{v.minor}.{v.patch}"

/// 1 to 3 dot-separated numbers without leading zeros.
fn parts(s: str): [int]? {
  var ps: [int] = []
  for p in s.split(".") {
    let ok =
      p != "" && p.chars().all(c => c >= '0' && c <= '9') && (p == "0" || !p.starts_with("0"))
    if !ok { return none }
    ps.push(int.parse(p) else return none)
  }
  if ps.len() >= 1 && ps.len() <= 3 { ps } else { none }
}

/// A version requirement: the half-open range `lo <= v < hi` (no `hi` = unbounded).
pub struct Req {
  text: str,
  lo: Version,
  hi: Version?,
}

/// Parse `^X[.Y[.Z]]`, `~X[.Y[.Z]]`, `=X.Y.Z` or `*`. A bare `X.Y` means `^X.Y`.
pub fn parse_req(s0: str): Req? {
  let s = s0.trim()
  let text = s
  if s == "*" {
    return Req { text, lo: Version { major: 0, minor: 0, patch: 0 }, hi: none }
  }
  let c = s.chars().first()?
  let (op, rest) = if c == '^' || c == '~' || c == '=' {
    (c, s[1..s.len()].trim_start())
  } else {
    ('^', s)
  }
  let ps = parts(rest)?
  let n = ps.len()
  let (x, y, z) = (ps[0], ps.get(1) else 0, ps.get(2) else 0)
  let hi = if op == '=' {
    if n == 3 { v(x, y, z + 1) } else { return none }
  } else if op == '~' {
    if n == 1 { v(x + 1, 0, 0) } else { v(x, y + 1, 0) }
  } else if x > 0 || n == 1 {
    // Caret: the leftmost non-zero component given may not change.
    v(x + 1, 0, 0)
  } else if y > 0 || n == 2 {
    v(0, y + 1, 0)
  } else {
    v(0, 0, z + 1)
  }
  Req { text, lo: v(x, y, z), hi: some(hi) }
}

fn v(major: int, minor: int, patch: int): Version = Version { major, minor, patch }

pub fn matches(r: Req, ver: Version): bool {
  if cmp(ver, r.lo) < 0 { return false }
  match r.hi {
    none => true
    some(hi) => cmp(ver, hi) < 0
  }
}

pub fn show(r: Req): str = r.text

fn m(req: str, ver: str): bool = matches(parse_req(req)!, parse_version(ver)!)

test "versions" {
  assert parse_version("1.20.3") == some(Version { major: 1, minor: 20, patch: 3 })
  for bad in ["1.2", "1.2.3.4", "01.2.3", "1.2.x", "", "1.2.3-beta"] {
    assert parse_version(bad) == none
  }
  assert cmp(parse_version("1.10.0")!, parse_version("1.9.9")!) > 0
}

test "caret" {
  assert m("^1.2", "1.2.0") && m("^1.2", "1.9.7") && !m("^1.2", "2.0.0") && !m("^1.2", "1.1.9")
  assert m("^1.2.3", "1.2.3") && !m("^1.2.3", "1.2.2")
  assert m("^1", "1.0.0") && !m("^1", "2.0.0")
  // 0.x: the minor version is the breaking one.
  assert m("^0.3", "0.3.0") && m("^0.3", "0.3.9") && !m("^0.3", "0.4.0") && !m("^0.3", "0.2.9")
  assert m("^0.0.3", "0.0.3") && !m("^0.0.3", "0.0.4")
  assert m("^0", "0.9.0") && !m("^0", "1.0.0")
  assert m("1.2", "1.5.0") && !m("1.2", "2.0.0")
}

test "tilde exact star" {
  assert m("~1.2.3", "1.2.3") &&
    m("~1.2.3", "1.2.9") &&
    !m("~1.2.3", "1.3.0") &&
    !m("~1.2.3", "1.2.2")
  assert m("~1", "1.9.0") && !m("~1", "2.0.0")
  assert m("=1.2.3", "1.2.3") && !m("=1.2.3", "1.2.4")
  assert m("*", "0.0.1") && m("*", "99.0.0")
  for bad in ["=1.2", "^", "^1.x", ">1.0", "^1.2.3.4"] {
    assert parse_req(bad) == none
  }
}

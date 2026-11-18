/// The parts of Rust's `std::path`, `std::fs` and `std::env` raft needs, on `/`-separated `str`
/// paths (copied from compiler/src/paths.auk, which another project can't import, plus
/// `remove_all`, `copy` and `exe`).

extern fn c_realpath(
  path: str,
  resolved: ffi.Ptr,
): str? = "char *realpath(const char *, char *) +free(free)"

/// `Path::canonicalize`: the absolute path with symlinks resolved, or none (it doesn't exist).
pub fn canonicalize(p: str): str? uses ffi = c_realpath(p, ffi.null)

/// The current directory (`std::env::current_dir`).
pub fn cwd(): str uses ffi = canonicalize(".") else "."

/// `Path::join`: `b` under `a` (`b` itself when it is absolute or `a` is empty).
pub fn join(a: str, b: str): str {
  if a == "" || b.starts_with("/") { return b }
  if a.ends_with("/") { a + b } else { a + "/" + b }
}

/// The last `/` in `p`, as a char index.
fn last_slash(p: str): int? {
  let cs = p.chars()
  var i = cs.len() - 1
  while i >= 0 {
    if cs[i] == '/' { return i }
    i -= 1
  }
  none
}

/// `Path::parent`: none for `""` and `"/"`; `""` for a bare name; `"/"` for `"/x"`.
pub fn parent(p: str): str? {
  let q = trim_slashes(p)
  if q == "" || q == "/" { return none }
  match last_slash(q) {
    none => ""
    some(0) => "/"
    some(i) => trim_slashes(q[0..i])
  }
}

/// Trailing slashes dropped (keeping a lone `/`).
fn trim_slashes(p: str): str {
  var q = p
  while q.len() > 1 && q.ends_with("/") { q = q[0..q.len() - 1] }
  q
}

/// `Path::file_name`: the last component.
pub fn file_name(p: str): str {
  let q = trim_slashes(p)
  match last_slash(q) {
    some(i) => q[i + 1..q.len()]
    none => q
  }
}

/// The components of `p` (`/` separated, empty ones dropped; an absolute path starts with `/`).
pub fn components(p: str): [str] {
  var out: [str] = if p.starts_with("/") { ["/"] } else { [] }
  for s in p.split("/") {
    if s != "" && s != "." { out.push(s) }
  }
  out
}

/// `Path::starts_with`: `base` is a whole-component prefix of `p`.
pub fn is_under(p: str, base: str): bool {
  let a = components(p)
  let b = components(base)
  b.len() <= a.len() && a.take(b.len()) == b
}

/// `Path::strip_prefix`, displayed: the remaining components joined by `/`.
pub fn strip_base(p: str, base: str): str? {
  if !is_under(p, base) { return none }
  components(p).skip(components(base).len()).join("/")
}

/// `Path::is_file`.
pub fn is_file(p: str): bool uses fs = fs.exists(p) && !fs.is_dir(p)

/// A symbolic link (`fs.is_dir` and `fs.exists` follow links; `remove_all` must not).
fn is_link(p: str): bool uses ffi {
  let real = canonicalize(p) else return false
  let dir = canonicalize(parent(p) else ".") else return false
  real != join(dir, file_name(p))
}

/// An `fs` error as Rust's `io::Error` displays it: `fs.read <path>: <strerror>` ->
/// `<strerror> (os error <errno>)`.
pub fn io_error(msg: str): str {
  let parts = msg.split(": ")
  let what = parts[parts.len() - 1]
  let code = match what {
    "Operation not permitted" => 1
    "No such file or directory" => 2
    "Permission denied" => 13
    "File exists" => 17
    "Not a directory" => 20
    "Is a directory" => 21
    "Too many open files" => 24
    "No space left on device" => 28
    "Read-only file system" => 30
    _ => 0
  }
  if code == 0 { what } else { "{what} (os error {code})" }
}

/// `fs::remove_dir_all`: a directory and everything in it (a link is removed, not followed).
pub fn remove_all(p: str): ()! uses fs, ffi {
  if fs.is_dir(p) && !is_link(p) {
    for name in fs.list(p)? { remove_all(join(p, name))? }
  }
  fs.remove(p)
}

/// `fs::copy` (the contents; the new file gets default permissions).
pub fn copy(from: str, to: str): ()! uses fs {
  fs.write_bytes(to, fs.read_bytes(from)?)
}

/// The running executable's path (`std::env::current_exe`, then canonicalized): `argv[0]`, looked
/// up in `$PATH` when it has no `/`, as the shell found it.
pub fn exe(): str? uses fs, env, ffi {
  let a0 = env.args().first()?
  if a0.contains("/") { return canonicalize(a0) }
  for d in (env.get("PATH") else "").split(":") {
    let p = join(if d == "" { "." } else { d }, a0)
    if is_file(p) { return canonicalize(p) }
  }
  none
}

test "paths" {
  assert parent("/a/b/c.auk") == some("/a/b")
  assert parent("c.auk") == some("")
  assert parent("/a") == some("/")
  assert parent("/") == none
  assert join("", "raft.toml") == "raft.toml"
  assert join("/", "raft.toml") == "/raft.toml"
  assert is_under("/a/b/c", "/a/b") && !is_under("/a/bc", "/a/b")
  assert strip_base("/x/app/../geo", "/x/app") == some("../geo")
  assert strip_base("/x/app/./geo", "/x/app") == some("geo")
  assert strip_base("/y/geo", "/x/app") == none
}

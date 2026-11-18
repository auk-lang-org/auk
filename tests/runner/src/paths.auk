/// The parts of Rust's `std::path` and `std::fs` the loader needs, on `/`-separated `str`
/// paths: `Path::join`, `parent`, `file_name`, `file_stem`, `extension`, `starts_with`,
/// `strip_prefix` (as components), `canonicalize` (C `realpath`), `is_file`, and the build's
/// operating system (`cfg!(target_os)`, from C `uname`).

extern fn c_realpath(
  path: str,
  resolved: ffi.Ptr,
): str? = "char *realpath(const char *, char *) +free(free)"

extern fn c_uname(buf: ffi.Ptr): int = "int uname(void *)"

/// `Path::canonicalize`: the absolute path with symlinks resolved, or none (it doesn't exist).
pub fn canonicalize(p: str): str? uses ffi = c_realpath(p, ffi.null)

/// The current directory (`std::env::current_dir`).
pub fn cwd(): str uses ffi = canonicalize(".") else "."

/// `"macos"`, `"linux"` or the lowercased kernel name (`cfg!(target_os)` for the manifest's
/// `[link] macos`/`linux`).
pub fn os(): str uses ffi {
  let buf = ffi.alloc(4096)
  let r = c_uname(buf)
  let name = if r == 0 { ffi.cstr(buf) } else { "" }
  ffi.free(buf)
  match name {
    "Darwin" => "macos"
    "Linux" => "linux"
    n => n.lower()
  }
}

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

/// `Path::file_stem`: the file name without its last extension (`.x` keeps its dot).
pub fn file_stem(p: str): str {
  let n = file_name(p)
  match last_dot(n) {
    some(i) when i > 0 => n[0..i]
    _ => n
  }
}

/// `Path::extension`: after the file name's last dot (none for `.x` or no dot).
pub fn extension(p: str): str? {
  let n = file_name(p)
  match last_dot(n) {
    some(i) when i > 0 => n[i + 1..n.len()]
    _ => none
  }
}

fn last_dot(n: str): int? {
  let cs = n.chars()
  var i = cs.len() - 1
  while i >= 0 {
    if cs[i] == '.' { return i }
    i -= 1
  }
  none
}

/// The components of `p` (`/` separated, empty ones dropped; an absolute path starts with `/`).
pub fn components(p: str): [str] {
  var out: [str] = if p.starts_with("/") { ["/"] } else { [] }
  for s in p.split("/") {
    if s != "" && s != "." { out.push(s) }
  }
  out
}

/// `Path::starts_with`: `base` is a whole-component prefix of `p`. (Renamed: a module fn
/// `starts_with(str, str)` would shadow core's for every `s.starts_with(..)` in this module.)
pub fn is_under(p: str, base: str): bool {
  let a = components(p)
  let b = components(base)
  b.len() <= a.len() && a.take(b.len()) == b
}

/// `Path::strip_prefix` (renamed like `is_under`), as the remaining components.
pub fn strip_base(p: str, base: str): [str]? {
  if !is_under(p, base) { return none }
  components(p).skip(components(base).len())
}

/// `Path::is_file`.
pub fn is_file(p: str): bool uses fs = fs.exists(p) && !fs.is_dir(p)

/// `fs::read_to_string`, failing with the text of Rust's `io::Error` (`No such file or
/// directory (os error 2)`), which diagnostics quote.
pub fn read(p: str): str! uses fs {
  match fs.read(p) {
    ok(s) => s
    err(e) => fail(io_error(e.show()))
  }
}

/// `fs.read <path>: <strerror>` -> `<strerror> (os error <errno>)` for the errors a read hits.
pub fn io_error(msg: str): str {
  let parts = msg.split(": ")
  let what = parts[parts.len() - 1]
  let code = match what {
    "Operation not permitted" => 1
    "No such file or directory" => 2
    "Permission denied" => 13
    "Not a directory" => 20
    "Is a directory" => 21
    "Too many open files" => 24
    _ => 0
  }
  if code == 0 { what } else { "{what} (os error {code})" }
}

test "paths" {
  assert parent("/a/b/c.auk") == some("/a/b")
  assert parent("c.auk") == some("")
  assert parent("/a") == some("/")
  assert parent("/") == none
  assert file_stem("x/y.tar.auk") == "y.tar"
  assert file_stem(".auk") == ".auk"
  assert extension("x/.auk") == none
  assert join("", "raft.toml") == "raft.toml"
  assert is_under("/a/b/c", "/a/b") && !is_under("/a/bc", "/a/b")
  assert strip_base("/a/b/c/d.auk", "/a/b") == some(["c", "d.auk"])
  match read("/nonexistent/x.auk") {
    ok(_) => assert false
    err(e) => assert e.show() == "No such file or directory (os error 2)"
  }
}

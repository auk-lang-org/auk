/// `raft.toml` and `raft.lock`: loading, validation, and in-place `[deps]` edits
/// (src/bin/raft/manifest.rs).
///
/// Differences in shape from the Rust: `Manifest::load`/`parse` are `load`/`parse`; positions in a
/// line are char indices (Rust's are byte offsets; both only slice the same line); Rust's Unicode
/// `trim` is `utrim` (core's `trim` is ASCII).

/// Effects a package may declare.
pub let EFFECTS = ["fs", "net", "time", "rand", "env", "proc", "audio_out", "gui", "ffi"]

/// Core module names, which no package may take.
let CORE = [
  "fs",
  "net",
  "time",
  "rand",
  "env",
  "proc",
  "audio_out",
  "gui",
  "pixels",
  "ffi",
  "str",
  "int",
  "float",
  "bool",
  "math",
  "core",
]

/// A parsed `raft.toml`.
pub struct Manifest {
  name: str,
  version: semver.Version,
  effects: [str],
  deps: [Dep],
}

pub struct Dep {
  name: str,
  src: DepSrc,
}

/// Where a dependency comes from.
pub enum DepSrc {
  Registry(req: semver.Req),
  /// A local package directory, relative to the manifest that names it.
  Path(p: str),
}

/// Why `name` is not a valid package name, if it isn't.
pub fn bad_name(name: str): str? {
  let is_lower = (c: char) => c >= 'a' && c <= 'z'
  let ok = is_lower(name.chars().first() else ' ') &&
    name.chars().all(c => is_lower(c) || (c >= '0' && c <= '9') || c == '_')
  if !ok {
    "invalid package name `{name}`"
  } else if CORE.contains(name) {
    "package name `{name}` collides with the core module `{name}`"
  } else {
    none
  }
}

let NAME_HELP = "names are lowercase `a-z0-9_`, start with a letter, and avoid core modules"

fn bad<T>(e: res.Error): T!res.Fail = fail(res.Bad(e))

/// Read and validate `<dir>/raft.toml`.
pub fn load(dir: str): Manifest!res.Fail uses fs {
  let path = paths.join(dir, "raft.toml")
  let src = fs.read(
    path,
  ) else e => return bad(res.err("cannot read {path}: {paths.io_error(e.show())}"))
  match parse(src) {
    ok(m) => m
    err(Bad(e)) => bad(res.Error { msg: "{path}: {e.msg}", ..e })
  }
}

pub fn parse(src: str): Manifest!res.Fail {
  let doc = toml.parse(src) else e => return bad(res.err("{e}"))
  let table = (name: str) => doc.find(t => t.name == name && !t.array)
  let pkg = table("package") else return bad(res.err("missing [package] table"))
  let field = (key: str) => toml.get(pkg, key)?.as_str()
  let name = field("name") else return bad(res.err("[package] needs a string `name`"))
  match bad_name(name) {
    some(msg) => return bad(res.err(msg).help(NAME_HELP))
    none => {}
  }
  let vtext = field("version") else return bad(res.err("[package] needs a string `version`"))
  let version = semver.parse_version(
    vtext,
  ) else return bad(
    res.err("invalid version `{vtext}`").help("use MAJOR.MINOR.PATCH, e.g. \"0.1.0\""),
  )
  let effects = match toml.get(pkg, "effects") {
    none => []
    some(v) =>
      toml.as_strs(v) else return bad(res.err("[package] effects must be an array of strings"))
  }
  match effects.find(e => !EFFECTS.contains(e) && e != "raw") {
    some(e) => return bad(res.err("unknown effect `{e}`").help("effects are {EFFECTS.join(" ")}"))
    none => {}
  }
  // `raw` (docs/lowlevel.md) is only for the runtime package
  if effects.contains("raw") && name != "auk_rt" {
    return bad(res.err("`raw` is only for the runtime").help("only the package `auk_rt` (runtime/raft.toml) may list the `raw` effect"))
  }
  // [link] libs: C libraries for `extern fn` (the compiler loads or links them); `macos`
  // and `linux`: more, on that OS only
  match table("link") {
    some(link) => {
      for en in link.entries {
        let k = en.key
        if !(k == "libs" || k == "macos" || k == "linux") {
          return bad(
            res
              .err("unknown key `{k}` in [link]")
              .help("[link] has libs = [\"name\"], plus macos = [..] and linux = [..] for one OS's libraries"),
          )
        }
        let libs = toml.as_strs(
          en.value,
        ) else return bad(res.err("[link] {k} must be an array of strings"))
        let invalid = (l: str) => match outside_tools(l) {
          none => true
          some(s) => s.chars().any(is_whitespace)
        }
        match libs.find(l => l == "" || invalid(l)) {
          some(l) => return bad(
            res
              .err("invalid library name `{l}` in [link] {k}")
              .help("a library is named as in `-lname` (\"sqlite3\"), or by its path; `${{VAR}}`, `${{VAR:-default}}` and `$(tool args)` are expanded"),
          )
          none => {}
        }
        if libs.len() > 0 && !effects.contains("ffi") {
          return bad(
            res.err("[link] {k} needs the `ffi` effect").help("add \"ffi\" to effects under [package]"),
          )
        }
      }
    }
    none => {}
  }
  var deps: [Dep] = []
  let entries = match table("deps") {
    some(t) => t.entries
    none => []
  }
  for en in entries {
    let dep = en.key
    match bad_name(dep) {
      some(msg) => return bad(res.err(msg).help(NAME_HELP))
      none => {}
    }
    let src = match en.value {
      Str(r) => {
        let req = semver.parse_req(
          r,
        ) else return bad(
          res.err("invalid version requirement `{r}` for {dep}").help("use \"^1.2\", \"~1.2.3\", \"=1.2.3\" or \"*\""),
        )
        Registry(req)
      }
      Table(es) => match es {
        [toml.Entry { key: "path", value: Str(p) }] => Path(p)
        _ => return bad(
          res.err("invalid dependency {dep}").help("write {dep} = {{ path = \"../{dep}\" }}"),
        )
      }
      List(_) => return bad(
        res.err("invalid dependency {dep}").help("use a version requirement string or {{ path = \"...\" }}"),
      )
    }
    deps.push(Dep { name: dep, src })
  }
  Manifest { name, version, effects, deps }
}

/// One `[[package]]` entry of `raft.lock`.
pub struct Locked {
  name: str,
  version: str,
  /// `registry` or `path:<dir>`.
  source: str,
  effects: [str],
  checksum: str,
}

/// Read `raft.lock` (an absent file is an empty lock).
pub fn read_lock(path: str): [Locked]!res.Fail uses fs {
  let src = fs.read(path) else return []
  let bad_lock = (msg: str) => res.err("{path}: {msg}").help("delete raft.lock and run `raft install` to regenerate it")
  let doc = toml.parse(src) else e => return bad(bad_lock("{e}"))
  var out: [Locked] = []
  for t in doc {
    if !(t.name == "package" && t.array) { continue }
    let s = (k: str) => toml.get(t, k)?.as_str()
    let missing = (k: str) => bad_lock("[[package]] needs `{k}`")
    let effects = toml.get(t, "effects")?.as_strs() else return bad(missing("effects"))
    let name = s("name") else return bad(missing("name"))
    let version = s("version") else return bad(missing("version"))
    let source = s("source") else return bad(missing("source"))
    let checksum = s("checksum") else return bad(missing("checksum"))
    out.push(Locked { name, version, source, effects, checksum })
  }
  out
}

/// Render `raft.lock` (entries must already be sorted by name).
pub fn write_lock(pkgs: [Locked]): str {
  var doc = [toml.new_table("", false)]
  for p in pkgs {
    var t = toml.new_table("package", true)
    t.entries = [
      toml.Entry { key: "name", value: toml.Str(p.name) },
      toml.Entry { key: "version", value: toml.Str(p.version) },
      toml.Entry { key: "source", value: toml.Str(p.source) },
      toml.Entry { key: "effects", value: toml.List(p.effects.map(e => toml.Str(e))) },
      toml.Entry { key: "checksum", value: toml.Str(p.checksum) },
    ]
    doc.push(t)
  }
  "# Generated by raft. Do not edit; commit it.\n\n{toml.write(doc)}"
}

/// Rust's `char::is_whitespace` (Unicode White_Space).
fn is_whitespace(c: char): bool {
  let n = int(c)
  if n < 0x80 { return n == 0x20 || (n >= 0x09 && n <= 0x0d) }
  n == 0x85 ||
    n == 0xa0 ||
    n == 0x1680 ||
    (n >= 0x2000 && n <= 0x200a) ||
    n == 0x2028 ||
    n == 0x2029 ||
    n == 0x202f ||
    n == 0x205f ||
    n == 0x3000
}

/// Rust's `str::trim_start` (Unicode whitespace).
fn utrim_start(s: str): str {
  let cs = s.chars()
  var i = 0
  while i < cs.len() && is_whitespace(cs[i]) { i += 1 }
  str(cs.skip(i))
}

/// Rust's `str::trim` (Unicode whitespace).
fn utrim(s: str): str {
  let cs = s.chars()
  var i = 0
  var j = cs.len()
  while i < j && is_whitespace(cs[i]) { i += 1 }
  while j > i && is_whitespace(cs[j - 1]) { j -= 1 }
  str(cs[i..j])
}

/// Non-overlapping occurrences of `sub` in `s` (Rust's `matches(..).count()`).
fn count(s: str, sub: str): int {
  var n = 0
  var rest = s
  loop {
    let i = rest.find(sub) else return n
    n += 1
    rest = rest[i + sub.len()..rest.len()]
  }
}

/// A `[link]` entry without its `$(tool args)` parts (whose arguments have spaces); none when a
/// `$(` or `${` isn't closed.
fn outside_tools(l: str): str? {
  var out: [char] = []
  var depth = 0
  let cs = l.chars()
  var i = 0
  while i < cs.len() {
    if cs[i] == '$' && cs.get(i + 1) == some('(') {
      depth += 1
      i += 2
      continue
    }
    let c = cs[i]
    if c == '(' && depth > 0 {
      depth += 1
    } else if c == ')' && depth > 0 {
      depth -= 1
    } else if depth == 0 {
      out.push(c)
    }
    i += 1
  }
  let text = str(out)
  let braces = count(text, "${{") == count(text, "}}")
  if depth == 0 && braces { text } else { none }
}

/// Char index of a `#` comment in a line, ignoring `#` inside strings.
fn comment_start(line: str): int? {
  var in_str = false
  var esc = false
  for i, c in line.chars() {
    if esc {
      esc = false
    } else if c == '\\' && in_str {
      esc = true
    } else if c == '"' {
      in_str = !in_str
    } else if c == '#' && !in_str {
      return i
    }
  }
  none
}

/// The key a `key = value` line defines, if any.
fn line_key(line: str): str? {
  let eq = line.find("=")?
  let k = utrim(line[0..eq])
  match k.strip_prefix("\"")?.strip_suffix("\"") {
    some(inner) => inner
    none => k
  }
}

fn is_header(l: str): bool = utrim_start(l).starts_with("[")

fn bare(l: str): str = utrim(l[0..(comment_start(l) else l.len())])

/// Set (`some(value)`) or remove (`none`) dependency `name` in the `[deps]` table of a manifest's
/// text, leaving every other line untouched. Returns none when removing a dependency that isn't there.
pub fn edit_deps(src: str, name: str, value: str?): str? {
  var lines = src.lines()
  let entry = match value {
    some(v) => some("{name} = {v}")
    none => none
  }
  match lines.find_index(l => bare(l) == "[deps]") {
    some(start) => {
      var end = lines.len()
      for i in start + 1..lines.len() {
        if is_header(lines[i]) {
          end = i
          break
        }
      }
      var found: int? = none
      for i in start + 1..end {
        if line_key(bare(lines[i])) == some(name) {
          found = i
          break
        }
      }
      match (found, entry) {
        (some(i), some(e)) => {
          let comment = match comment_start(lines[i]) {
            some(c) => "   " + lines[i][c..lines[i].len()]
            none => ""
          }
          lines[i] = e + comment
        }
        (some(i), none) => {
          let _ = lines.remove(i)
        }
        (none, some(e)) => {
          var last = start
          var i = end - 1
          while i >= start {
            if utrim(lines[i]) != "" {
              last = i
              break
            }
            i -= 1
          }
          lines.insert(last + 1, e)
        }
        (none, none) => return none
      }
    }
    none => {
      let e = entry?
      match lines.last() {
        some(l) when utrim(l) != "" => lines.push("")
        _ => {}
      }
      lines.push("[deps]")
      lines.push(e)
    }
  }
  lines.join("\n") + "\n"
}

let SRC = "# my app\n[package]\nname = \"app\"\nversion = \"0.1.0\"\neffects = [] # pure\n\n[deps]\nb = \"^1.0\"  # keep me\n\n[extra]\nx = \"y\"\n"

test "edits preserve the rest" {
  let added = edit_deps(SRC, "a", some("\"^1.2\""))!
  assert added == SRC.replace("# keep me\n", "# keep me\na = \"^1.2\"\n")
  let updated = edit_deps(added, "b", some("\"^2.0\""))!
  assert updated.contains("b = \"^2.0\"   # keep me\na = \"^1.2\"\n")
  let removed = edit_deps(added, "a", none)!
  assert removed == SRC
  assert edit_deps(SRC, "zzz", none) == none
  let no_deps = "[package]\nname = \"app\"\nversion = \"0.1.0\""
  assert edit_deps(no_deps, "a", some("\"*\"")) == some("{no_deps}\n\n[deps]\na = \"*\"\n")
}

fn bad_msg(s: str): str {
  match parse(s) {
    ok(_) => ""
    err(Bad(e)) => e.msg
  }
}

test "manifest validation" {
  let m = parse(SRC)?
  assert (m.name, m.deps.len()) == ("app", 1)
  assert bad_msg("[package]\nname = \"Net\"\nversion = \"0.1.0\"") == "invalid package name `Net`"
  assert bad_msg("[package]\nname = \"net\"\nversion = \"0.1.0\"") ==
    "package name `net` collides with the core module `net`"
  assert bad_msg("[package]\nname = \"a\"\nversion = \"0.1\"") == "invalid version `0.1`"
  assert bad_msg("[package]\nname = \"a\"\nversion = \"0.1.0\"\neffects = [\"gpu\"]") ==
    "unknown effect `gpu`"
  assert bad_msg("[package]\nname = \"a\"\nversion = \"0.1.0\"\neffects = [\"raw\"]") ==
    "`raw` is only for the runtime"
  assert parse("[package]\nname = \"auk_rt\"\nversion = \"0.1.0\"\neffects = [\"raw\"]") is ok(_)
  assert bad_msg("[package]\nname = \"a\"\nversion = \"0.1.0\"\n[deps]\nb = \">1\"") ==
    "invalid version requirement `>1` for b"
  let ffi = "[package]\nname = \"a\"\nversion = \"0.1.0\"\neffects = [\"ffi\"]\n[link]\n"
  assert parse("{ffi}libs = [\"sqlite3\", \"/opt/x/libz.dylib\"]") is ok(_)
  assert bad_msg("{ffi}libs = \"z\"") == "[link] libs must be an array of strings"
  assert bad_msg("{ffi}libs = [\"\"]") == "invalid library name `` in [link] libs"
  assert parse("{ffi}macos = [\"/opt/x/libz.dylib\"]\nlinux = [\"z\"]") is ok(_)
  assert parse("{ffi}macos = [\"$(${{LLVM_CONFIG:-llvm-config}} --libdir)/libLLVM.dylib\", \"${{X}}/a\"]") is ok(_)
  assert bad_msg("{ffi}libs = [\"$(llvm-config --libdir\"]") ==
    "invalid library name `$(llvm-config --libdir` in [link] libs"
  assert bad_msg("{ffi}libs = [\"${{X\"]") == "invalid library name `${{X` in [link] libs"
  assert bad_msg("{ffi}libs = [\"a b\"]") == "invalid library name `a b` in [link] libs"
  assert bad_msg("{ffi}linux = \"z\"") == "[link] linux must be an array of strings"
  assert bad_msg("{ffi}windows = []") == "unknown key `windows` in [link]"
  assert bad_msg("{ffi}dirs = []") == "unknown key `dirs` in [link]"
  assert bad_msg("[package]\nname = \"a\"\nversion = \"0.1.0\"\n[link]\nlibs = [\"z\"]") ==
    "[link] libs needs the `ffi` effect"
}

test "lock round trip" {
  let pkgs = [
    Locked {
      name: "a",
      version: "1.2.0",
      source: "registry",
      effects: ["net"],
      checksum: "sha256:00",
    },
  ]
  let dir = fs.temp_dir()?
  let path = paths.join(dir, "raft.lock")
  fs.write(path, write_lock(pkgs))?
  match read_lock(path) {
    ok(back) => assert back == pkgs
    err(_) => assert false
  }
  fs.remove(path)?
  fs.remove(dir)?
}

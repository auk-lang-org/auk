/// Modules and names (src/resolve.rs): builds the module tree of a program and answers path
/// questions.
///
/// A program is a set of packages, each a tree of modules (one module per file):
/// - the **root package**: the file given on the command line is its root module. If the file is
///   inside a project (the nearest `raft.toml` above it), the project's `src/**/*.auk` files are
///   its other modules (`src/geo/shapes.auk` is `geo.shapes`), and the manifest's `[deps]` are
///   its dependencies. A standalone file gets core only.
/// - each **dependency** `d`: installed at `<project>/.raft/d/`; its root module is
///   `src/lib.auk` and `src/x.auk` is `d.x`. Its own `[deps]` are found in the same `.raft/`
///   (raft installs the whole tree flat).
/// - **core**: the prelude (`compiler/prelude/*.auk`): the root `core` module, always in scope, plus
///   the modules `fs net time rand env proc audio_out gui pixels str int float ffi`.
///
/// Paths (spec "Modules, packages"): a path's first segment names, in this order, a top-level
/// module of the current package, the current package itself (its root), a dependency, or a
/// core module. `m.` is always a path when `m` names one of those, except that a local value
/// shadows a core module name (`env.get(k)` with a parameter `env`; `Checker::expr_path`), and a
/// local named like any other module is an error (E0116). A local module with the same name as a
/// dependency is an error (E0101).
///
/// Name lookup *inside* a module (locals, items, core, variants, overloads) is done by the checker
/// on top of the item tables it builds; see check.rs.
///
/// Differences from Rust: the prelude texts are read from a directory when the loader starts
/// (Rust compiles them in with `include_str!`; Auk can't embed files yet), and the thread-local
/// `OVERRIDES` of `with_sources` is the `overrides` field of the `Sources` passed in. Rust's
/// `BTreeMap`s are maps whose keys are sorted where they are iterated.

/// The core prelude's modules, in order. The first is the root `core` module.
pub let PRELUDE = [
  "core",
  "fs",
  "net",
  "time",
  "rand",
  "env",
  "proc",
  "audio_out",
  "gui",
  "pixels",
  "str",
  "int",
  "float",
  "ffi",
  "raw",
]

/// What loading reads besides the files on disk: the prelude texts (module name, source), the
/// in-memory file texts that stand in for files on disk (`with_sources`), keyed by the file's name
/// as it appears in `Module.file`, and this OS (`macos`, `linux`) for `[link]`.
pub struct Sources { prelude: [(str, str)], overrides: {str: str}, os: str }

/// Read the prelude from `dir` (`compiler/prelude`).
pub fn sources(dir: str): Sources! uses fs, ffi {
  var prelude: [(str, str)] = []
  for name in PRELUDE { prelude.push((name, fs.read(paths.join(dir, "{name}.auk"))?)) }
  Sources { prelude, overrides: {}, os: paths.os() }
}

/// `cx` with the given files' texts replacing what is on disk, for loading (and so checking
/// and building) a program whose edits haven't been written yet (`auk hatch`). Keys are file
/// names as they appear in `Module.file`.
pub fn with_sources(cx: Sources, srcs: {str: str}): Sources = Sources { overrides: srcs, ..cx }

/// Read a module's file, honoring `with_sources`.
fn read_file(cx: Sources, path: str): str! uses fs {
  match cx.overrides.get(path) {
    some(s) => s
    none => paths.read(path)?
  }
}

/// The text of a file named in a diagnostic (a prelude file or a file on disk).
pub fn source_of(cx: Sources, file: str): str? uses fs {
  match file.strip_prefix("<prelude>/") {
    some(f) => match f.strip_suffix(".auk") {
      some(name) => return cx.prelude.find(p => p.0 == name)?.1
      none => {}
    }
    none => {}
  }
  match read_file(cx, file) {
    ok(s) => s
    err(_) => none
  }
}

pub struct Package {
  name: str,
  /// The project directory (with `raft.toml`), if any.
  dir: str?,
  root: int,
  /// Direct dependencies by name.
  deps: {str: int},
  /// `[package] effects` from the manifest (the ceiling that effects.rs enforces).
  effects: [str],
  /// `[link] libs` from the manifest: C libraries its `extern fn`s need (ffi-plan.md §4).
  links: [str],
  is_core: bool,
}

pub struct Module {
  pkg: int,
  /// The full path: `["http", "uri"]`, `["core", "fs"]`; the root module of a standalone file
  /// is `[<file stem>]`.
  path: [str],
  /// The file as given (for diagnostics); `<prelude>/x.auk` for core, empty for a folder
  /// without its own file.
  file: str,
  src: str,
  ast: ast.Module,
  children: {str: int},
}

pub struct Program {
  pkgs: [Package],
  mods: [Module],
  /// The root module (the file given on the command line).
  root: int,
  /// The module being looked at: `root`, except from `load_in_package`, where it is the
  /// submodule whose file was given (and `root` is its package's `lib.auk`/`main.auk`).
  focus: int,
  core_pkg: int,
  core_root: int,
}

pub fn name(p: Program, m: int): str = p.mods[m].path.join(".")

pub fn is_core(p: Program, m: int): bool = p.mods[m].pkg == p.core_pkg

/// Is module `m` in the runtime package (`name = "auk_rt"` in a raft.toml), the only one that
/// may use the `raw` dialect (docs/lowlevel.md)?
pub fn is_runtime(p: Program, m: int): bool {
  let pkg = p.pkgs[p.mods[m].pkg]
  !pkg.is_core && pkg.dir is some(_) && pkg.name == "auk_rt"
}

/// May module `m` use the `raw` dialect (the runtime package, or core's `raw` module)?
pub fn raw_ok(p: Program, m: int): bool = is_runtime(p, m) || is_core(p, m)

/// Core's `raw` module (compiler/prelude/raw.auk).
pub fn raw_module(p: Program): int? = child(p, p.core_root, "raw")

pub fn child(p: Program, m: int, name: str): int? = p.mods[m].children.get(name)

/// What a path's first segment `name` means in module `m`, if it names a module.
pub fn first_segment(p: Program, m: int, name: str): int? {
  let pkg = p.pkgs[p.mods[m].pkg]
  match child(p, pkg.root, name) {
    some(c) => return c
    none => {}
  }
  if !pkg.is_core && pkg.dir is some(_) && pkg.name == name { return pkg.root }
  match pkg.deps.get(name) {
    some(d) => return p.pkgs[d].root
    none => {}
  }
  if name == "core" { return p.core_root }
  // the runtime's dialect is visible only to the runtime package
  if name == "raw" && !raw_ok(p, m) { return none }
  child(p, p.core_root, name)
}

/// The runtime package's per-target files (docs/lowlevel.md §11): of `x.<os>-<arch>.auk`,
/// `x.<os>.auk` and `x.auk` in one directory, only the most specific one matching the target,
/// as the module `x`. (Only the runtime package names files this way; elsewhere `a.b.auk` is
/// the module `a.b`, as before.)
pub fn select_targets(files: [str], os: str, arch: str): [str] {
  // (directory, module) -> (rank, file); rank 2 `<os>-<arch>`, 1 `<os>`, 0 plain
  var best: {(str, str): (int, str)} = {}
  var order: [(str, str)] = []
  for f in files {
    let dir = paths.parent(f) else ""
    let file = paths.file_name(f)
    let stem = file.strip_suffix(".auk") else file
    let parts = stem.split(".")
    let (base, rank) = if parts.len() == 1 {
      (stem, 0)
    } else {
      let tag = parts[parts.len() - 1]
      let base = parts.take(parts.len() - 1).join(".")
      if tag == "{os}-{arch}" { (base, 2) } else if tag == os { (base, 1) } else { (base, -1) }
    }
    if rank < 0 { continue }
    let key = (dir, base)
    match best.get(key) {
      some((r, _)) => if rank > r { best[key] = (rank, f) }
      none => {
        best[key] = (rank, f)
        order.push(key)
      }
    }
  }
  order.map(k => best[k].1)
}

test "per-target files" {
  let fs = ["s/os.auk", "s/os.macos.auk", "s/os.linux.auk", "s/os.linux-arm64.auk", "s/a.auk", "s/b.linux.auk"]
  assert select_targets(fs, "macos", "arm64") == ["s/os.macos.auk", "s/a.auk"]
  assert select_targets(fs, "linux", "arm64") == ["s/os.linux-arm64.auk", "s/a.auk", "s/b.linux.auk"]
  assert select_targets(fs, "linux", "x86_64") == ["s/os.linux.auk", "s/a.auk", "s/b.linux.auk"]
  assert select_targets(fs, "freebsd", "x86_64") == ["s/os.auk", "s/a.auk"]
}

/// A per-target file's module key in its directory: `os` of `os.auk`, `os.linux.auk`,
/// `os.linux-arm64.auk` (as `select_targets` reads it), and its target tag (`""` if none).
fn variant_base(f: str): (str, str, str) {
  let stem = paths.file_name(f).strip_suffix(".auk") else paths.file_name(f)
  let parts = stem.split(".")
  if parts.len() == 1 { return (paths.parent(f) else "", stem, "") }
  (paths.parent(f) else "", parts.take(parts.len() - 1).join("."), parts[parts.len() - 1])
}

/// A parsed file of the runtime package, for `check_variants`: its `pub` items by name
/// (signature, span) and its uses of other modules' items (module key, name, span).
struct VFile { items: {str: [(str, diag.Span)]}, refs: [((str, str), str, diag.Span)] }

/// The per-target files of the runtime package must agree (docs/lowlevel.md §11): for every
/// target (macOS and Linux on arm64 and x86-64, and any other a file names), each file that
/// target compiles may use from a module with variants (`cfacts.O_CREAT`) only what that
/// target's variant of it declares `pub`, and every variant used for the same item declares
/// it with the same signature. Items only a target's own files use may exist only there (the
/// "only on <os>" parts). Every file is parsed, so this host also checks the other targets'.
/// E0422 at the use (a missing item) or at the variant that differs.
fn check_variants(l: var Loader, files: [str], host: [str], src_dir: str) uses fs {
  // the modules with more than one file
  var groups: {(str, str): [str]} = {}
  var tags: [str] = []
  for f in files {
    let (dir, base, tag) = variant_base(f)
    groups[(dir, base)] = (groups.get((dir, base)) else []) + [f]
    if tag != "" && !tags.contains(tag) { tags.push(tag) }
  }
  var mods: [((str, str), [str])] = []
  for key in groups.keys().sort() {
    if groups[key].len() < 2 { continue }
    let segs = paths.strip_base(paths.join(key.0, key.1), src_dir) else continue
    mods.push((key, segs))
  }
  if mods.len() == 0 { return }
  // every file, parsed once
  var vf: {str: VFile} = {}
  for f in files {
    let src = read_file(l.cx, f) else continue
    let toks = match lexer.lex(src) {
      ok(x) => x.toks
      err(_) => []
    }
    match parser.parse(src, false) {
      ok(a) => vf[f] = VFile { items: pub_items(a), refs: module_uses(toks, mods) }
      // the host's files report their own errors when they are loaded
      err(Many(ds)) => if !host.contains(f) { l.errs = l.errs + file_diags(f, ds) }
    }
  }
  // the targets
  var targets: [(str, str)] = []
  var oses = ["macos", "linux"]
  for t in tags {
    let os = t.split("-")[0]
    if !oses.contains(os) { oses.push(os) }
  }
  for os in oses {
    for arch in ["arm64", "x86_64"] { targets.push((os, arch)) }
  }
  for t in tags {
    let parts = t.split("-")
    if parts.len() == 2 && !targets.contains((parts[0], parts[1])) { targets.push((parts[0], parts[1])) }
  }
  // (module, name) -> the variants used for it, and by whom
  var needed: {((str, str), str): [(str, str)]} = {}
  var seen: {str: bool} = {}
  for (os, arch) in targets {
    let sel = select_targets(files, os, arch)
    for (key, _) in mods {
      let v = sel.find(f => (variant_base(f).0, variant_base(f).1) == key) else continue
      for u in sel {
        let uf = vf.get(u) else continue
        for (k, name, at) in uf.refs {
          if k != key { continue }
          let have = vf.get(v) else continue
          if have.items.contains(name) {
            let users = needed.get((key, name)) else []
            if !users.any(p => p.0 == v) { needed[(key, name)] = users + [(v, u)] }
          } else {
            let msg = "`{key.1}.{name}` isn't declared in `{paths.file_name(v)}`, the module `{key.1}` on {os}-{arch}"
            // once per use and variant (not per target that compiles both)
            let k = "{u}:{at.line}:{at.col}:{v}"
            if !seen.contains(k) {
              seen[k] = true
              l.errs.push(diag.FileDiag { file: u, diag: diag.new("E0422", at, msg).note("a module's per-target files must agree on what the rest of the package uses from it") })
            }
          }
        }
      }
    }
  }
  for kn in needed.keys().sort() {
    let (key, name) = kn
    let vs = needed[kn]
    // compare with the host's variant when it is one of them
    let ri = vs.find_index(p => host.contains(p.0)) else 0
    let (rf, ru) = vs[ri]
    let rsig = vf[rf].items[name].map(x => x.0).sort()
    for (v, u) in vs {
      if v == rf { continue }
      let items = vf[v].items[name]
      let sig = items.map(x => x.0).sort()
      if sig != rsig {
        l.errs.push(diag.FileDiag {
          file: v,
          diag: diag.new(
            "E0422",
            items[0].1,
            "`{name}` is `{sig.join("; ")}` here but `{rsig.join("; ")}` in `{paths.file_name(rf)}`, and both are used (`{paths.file_name(u)}`, `{paths.file_name(ru)}`)",
          ).note("a module's per-target files must agree on what the rest of the package uses from it"),
        })
      }
    }
  }
}

/// The `pub` items of a module by name: (signature, span) per declaration (functions may be
/// overloaded). Functions by their parameter and result types, effects and `export`; enums
/// with their variants; plain structs with their fields; a `raw struct`/`raw union` or `raw
/// type` only by kind (its layout or meaning is the platform's); constants and globals with
/// their types (not their values).
fn pub_items(a: ast.Module): {str: [(str, diag.Span)]} {
  var out: {str: [(str, diag.Span)]} = {}
  for it in a.items {
    match it {
      Fn(g) => {
        let c = g.header else g.clauses.first() else continue
        if !c.public { continue }
        let gens = if c.generics.len() == 0 { "" } else { "<{c.generics.map(x => x.name.name).join(", ")}>" }
        let ps = c.params.map(p => {
          let t = match p.ty {
            some(t) => type_sig(t)
            none => "_"
          }
          if p.var_ { "var {t}" } else { t }
        })
        let ret = match c.ret {
          some(t) => ": {type_sig(t)}"
          none => ""
        }
        let effs = if c.effects.len() == 0 { "" } else { " uses {c.effects.map(e => e.name).sort().join(", ")}" }
        let kw = ["fn", "export fn", "inline export fn"][c.export]
        add_item(&out, g.name, "{kw} {g.name}{gens}({ps.join(", ")}){ret}{effs}", c.name.span)
      }
      Struct(d) => if d.public {
        let kw = ["struct", "raw struct", "raw union"][d.raw]
        let fs = if d.raw == 0 { " {{ {d.fields.map(f => "{f.name.name}: {type_sig(f.ty)}").join(", ")} }}" } else { "" }
        add_item(&out, d.name.name, "{kw} {d.name.name}{fs}", d.name.span)
      }
      Enum(d) => if d.public {
        let vs = d.variants.map(v => if v.fields.len() == 0 {
          v.name.name
        } else {
          "{v.name.name}({v.fields.map(f => type_sig(f.ty)).join(", ")})"
        })
        add_item(&out, d.name.name, "enum {d.name.name} {{ {vs.join(", ")} }}", d.name.span)
      }
      Shape(d) => if d.public { add_item(&out, d.name.name, "shape {d.name.name}", d.name.span) }
      ExternType(d) => if d.public { add_item(&out, d.name.name, "extern type {d.name.name}", d.name.span) }
      RawType(d) => if d.public { add_item(&out, d.name.name, "raw type {d.name.name}", d.name.span) }
      Let(d) | Imprint(d) => if d.public {
        let t = match d.ty {
          some(t) => ": {type_sig(t)}"
          none => ""
        }
        add_item(&out, d.name.name, "let {d.name.name}{t}", d.name.span)
      }
      Global(d) => if d.public {
        let t = match d.ty {
          some(t) => ": {type_sig(t)}"
          none => ""
        }
        add_item(&out, d.name.name, "{ast.global_kw(d.kind)} {d.name.name}{t}", d.name.span)
      }
      _ => {}
    }
  }
  out
}

fn add_item(m: var {str: [(str, diag.Span)]}, n: str, sig: str, at: diag.Span) {
  m[n] = (m.get(n) else []) + [(sig, at)]
}

/// `m.NAME` in the tokens for each module path `m` of `mods` (not after a `.`): (module key,
/// NAME, span of NAME).
fn module_uses(toks: [token.Token], mods: [((str, str), [str])]): [((str, str), str, diag.Span)] {
  var out: [((str, str), str, diag.Span)] = []
  for i in 0..toks.len() {
    if i > 0 && toks[i - 1].tok == token.Tok.Dot { continue }
    for (key, segs) in mods {
      var j = i
      var ok = true
      for s in segs {
        if j + 1 >= toks.len() || toks[j].tok != token.Tok.Ident(s) || toks[j + 1].tok != token.Tok.Dot {
          ok = false
          break
        }
        j += 2
      }
      if !ok || j >= toks.len() { continue }
      match toks[j].tok {
        Ident(n) => out.push((key, n, toks[j].span))
        _ => {}
      }
    }
  }
  out
}

/// A type as written, spacing normalized.
fn type_sig(t: ast.Type): str = match t.kind {
  Named(path, args) => {
    let p = path.map(i => i.name).join(".")
    if args.len() == 0 { p } else { "{p}<{args.map(type_sig).join(", ")}>" }
  }
  List(x) => "[{type_sig(x)}]"
  Map(k, v) => "{{{type_sig(k)}: {type_sig(v)}}}"
  Tuple(ts) => "({ts.map(type_sig).join(", ")})"
  Optional(x) => "{type_sig(x)}?"
  Fallible(ok, e) => match e {
    some(x) => "{type_sig(ok)}!{type_sig(x)}"
    none => "{type_sig(ok)}!"
  }
  Any(x) => "any {type_sig(x)}"
  Fn(ps, r) => "({ps.map(type_sig).join(", ")}) => {type_sig(r)}"
  Measured(b, us) => "{type_sig(b)}<{us.map(u => "{u.0}^{u.1}").join(" ")}>"
  Var(x) => "var {type_sig(x)}"
  Array(x, n) => if n < 0 { "[{type_sig(x)}; ..]" } else { "[{type_sig(x)}; {n}]" }
}

/// The keys of a map in sorted order (Rust's `BTreeMap` iteration).
pub fn sorted_keys<V>(m: {str: V}): [str] = m.keys().sort()

/// A `raft.toml`, as much as the compiler needs.
pub struct Manifest {
  name: str,
  deps: [str],
  effects: [str],
  /// `[link] libs`, then `[link] macos` or `linux` (this OS's).
  links: [str],
}

/// Read the `[package]` name and effects, the `[deps]` names and `[link]` libraries. (raft
/// validates manifests fully; the compiler only needs these keys.) `os` is `cfg!(target_os)`.
pub fn parse_manifest(text: str, os: str): Manifest {
  var m = Manifest { name: "", deps: [], effects: [], links: [] }
  var section = ""
  for raw in text.lines() {
    let line = strip_comment(raw).trim()
    if line == "" { continue }
    if line.starts_with("[") {
      section = trim_chars(line, ['[', ']']).trim()
      continue
    }
    let eq = line.find("=") else continue
    let key = trim_chars(line[0..eq].trim(), ['"'])
    let val = line[eq + 1..line.len()].trim()
    match (section, key) {
      ("package", "name") => m.name = trim_chars(val, ['"'])
      ("package", "effects") => m.effects = str_list(val)
      ("link", "libs") => m.links = m.links + str_list(val)
      ("link", "macos") when os == "macos" => m.links = m.links + str_list(val)
      ("link", "linux") when os == "linux" => m.links = m.links + str_list(val)
      ("deps", _) => m.deps.push(key)
      _ => {}
    }
  }
  m
}

fn str_list(val: str): [str] =
  trim_chars(val, ['[', ']']).split(",").map(s => trim_chars(s.trim(), ['"'])).filter(s => s != "")

/// Rust's `trim_matches` with a set of chars.
fn trim_chars(s: str, cs: [char]): str {
  let chars = s.chars()
  var a = 0
  var b = chars.len()
  while a < b && cs.contains(chars[a]) { a += 1 }
  while b > a && cs.contains(chars[b - 1]) { b -= 1 }
  s[a..b]
}

fn strip_comment(line: str): str {
  var in_str = false
  for i, c in line.chars() {
    if c == '"' {
      in_str = !in_str
    } else if c == '#' && !in_str {
      return line[0..i]
    }
  }
  line
}

/// The nearest directory at or above `dir` that has a `raft.toml`.
pub fn find_project(dir: str): str? uses fs {
  var d: str? = dir
  loop {
    let x = d else return none
    if paths.is_file(paths.join(x, "raft.toml")) { return x }
    d = paths.parent(x)
  }
}

struct Loader {
  cx: Sources,
  pkgs: [Package],
  mods: [Module],
  errs: [diag.FileDiag],
  /// Installed dependencies already loaded, by name.
  loaded: {str: int},
  /// `<project>/.raft`, where every dependency of the program is installed.
  raft_dir: str?,
}

/// The span every loader diagnostic has (line 1, column 1).
let AT_START = diag.Span { line: 1, col: 1, end_line: 1, end_col: 1 }

fn err_at(file: str, code: str, msg: str): diag.FileDiag =
  diag.FileDiag { file, diag: diag.new(code, AT_START, msg) }

fn file_diags(file: str, ds: [diag.Diag]): [diag.FileDiag] =
  ds.map(d => diag.FileDiag { file, diag: d })

fn empty_ast(): ast.Module = ast.Module { doc: none, items: [] }

fn add_module(l: var Loader, pkg: int, path: [str], file: str, src: str, prelude: bool): int {
  let a = match parser.parse(src, prelude) {
    ok(m) => m
    err(Many(ds)) => {
      l.errs = l.errs + file_diags(file, ds)
      empty_ast()
    }
  }
  let id = l.mods.len()
  l.mods.push(Module { pkg, path, file, src, ast: a, children: {} })
  id
}

/// An empty module standing for a folder with no file of its own.
fn folder_module(l: var Loader, pkg: int, path: [str]): int {
  let id = l.mods.len()
  l.mods.push(Module { pkg, path, file: "", src: "", ast: empty_ast(), children: {} })
  id
}

fn load_core(l: var Loader): int {
  let pkg = l.pkgs.len()
  l.pkgs.push(Package {
    name: "core",
    dir: none,
    root: 0,
    deps: {},
    effects: [],
    links: [],
    is_core: true,
  })
  var root: int? = none
  for (name, src) in l.cx.prelude {
    let path = if name == "core" { ["core"] } else { ["core", name] }
    let m = add_module(&l, pkg, path, "<prelude>/{name}.auk", src, true)
    match root {
      none => root = m
      some(r) => l.mods[r].children[name] = m
    }
  }
  l.pkgs[pkg].root = root else 0
  pkg
}

/// Add `src/**/*.auk` under `src_dir` as submodules of `root` (skipping `skip`, and the
/// package roots `lib.auk` / `main.auk` at the top).
fn add_tree(l: var Loader, pkg: int, root: int, src_dir: str, skip: str?) uses fs, ffi {
  var files: [str] = []
  collect_auk_files(src_dir, &files)
  if l.pkgs[pkg].name == "auk_rt" {
    let host = select_targets(files, l.cx.os, paths.arch())
    check_variants(&l, files, host, src_dir)
    files = host
  }
  // `PathBuf` order: component by component
  for f in files.sort_by(f => paths.components(f)) {
    match skip {
      some(s) => if same_file(s, f) { continue }
      none => {}
    }
    var segs = paths.strip_base(f, src_dir) else continue
    let last = segs.pop() else continue
    let stem0 = trim_auk(last)
    // a per-target file of the runtime package is the module of its base name
    let stem = if l.pkgs[pkg].name == "auk_rt" {
      match stem0.split(".").first() {
        some(x) => x
        none => stem0
      }
    } else {
      stem0
    }
    if segs.len() == 0 && (stem == "lib" || stem == "main") { continue }
    segs.push(stem)
    var parent = root
    for i, seg in segs {
      let path = l.mods[root].path + segs.take(i + 1)
      let is_last = i + 1 == segs.len()
      let existing = l.mods[parent].children.get(seg)
      var m = 0
      match existing {
        some(e) when !is_last => m = e
        some(e) => {
          // a folder module created earlier for `seg/...` gets its file now
          let src = read_file(l.cx, f) else ""
          match parser.parse(src, false) {
            ok(a) => l.mods[e].ast = a
            err(Many(ds)) => l.errs = l.errs + file_diags(f, ds)
          }
          l.mods[e].file = f
          l.mods[e].src = src
          m = e
        }
        none when !is_last => m = folder_module(&l, pkg, path)
        none => match read_file(l.cx, f) {
          ok(src) => m = add_module(&l, pkg, path, f, src, false)
          err(e) => {
            l.errs.push(err_at(f, "E0100", "cannot read {f}: {e.show()}"))
            break
          }
        }
      }
      l.mods[parent].children[seg] = m
      parent = m
    }
  }
}

/// Rust's `trim_end_matches(".auk")`: every trailing `.auk` removed.
fn trim_auk(s: str): str {
  var t = s
  while t.ends_with(".auk") { t = t.strip_suffix(".auk") else t }
  t
}

/// Load the installed package `name` (and its dependencies), once.
fn load_dep(l: var Loader, name: str, wanted_by: str, from_file: str): int? uses fs, ffi {
  match l.loaded.get(name) {
    some(p) => return p
    none => {}
  }
  let dir_opt = match l.raft_dir {
    some(q) => {
      let d = paths.join(q, name)
      if paths.is_file(paths.join(d, "src/lib.auk")) { some(d) } else { none }
    }
    none => none
  }
  let dir = dir_opt else {
    let where_ = match l.raft_dir {
      some(q) => paths.parent(q) else "."
      none => "."
    }
    l.errs.push(diag.FileDiag {
      file: from_file,
      diag: diag
        .new("E0100", AT_START, "dependency `{name}` of `{wanted_by}` is not installed")
        .note("run `raft install` in {where_} (expected {name}/src/lib.auk under .raft/)"),
    })
    return none
  }
  let manifest = match fs.read(paths.join(dir, "raft.toml")) {
    ok(t) => parse_manifest(t, l.cx.os)
    err(_) => Manifest { name: "", deps: [], effects: [], links: [] }
  }
  let pkg = l.pkgs.len()
  l.pkgs.push(Package {
    name,
    dir: dir,
    root: 0,
    deps: {},
    effects: manifest.effects,
    links: manifest.links,
    is_core: false,
  })
  l.loaded[name] = pkg
  let lib = paths.join(dir, "src/lib.auk")
  let src = fs.read(lib) else ""
  let root = add_module(&l, pkg, [name], lib, src, false)
  l.pkgs[pkg].root = root
  add_tree(&l, pkg, root, paths.join(dir, "src"), lib)
  for d in manifest.deps {
    match load_dep(&l, d, name, lib) {
      some(dp) => l.pkgs[pkg].deps[d] = dp
      none => {}
    }
  }
  check_collisions(&l, pkg)
  pkg
}

/// A top-level module of `pkg` named like one of its dependencies is an error.
fn check_collisions(l: var Loader, pkg: int) {
  let root = l.pkgs[pkg].root
  let children = l.mods[root].children
  for name in sorted_keys(children) {
    let m = children[name]
    if l.pkgs[pkg].deps.contains(name) {
      let file = if l.mods[m].file == "" { l.mods[root].file } else { l.mods[m].file }
      l.errs.push(diag.FileDiag {
        file,
        diag: diag
          .new(
            "E0101",
            AT_START,
            "module `{l.mods[m].path.join(".")}` has the same name as the dependency `{name}`",
          )
          .note("`{name}.` would be ambiguous; rename the module (src/{name}.auk) or remove the dependency from raft.toml"),
      })
    }
  }
}

fn collect_auk_files(dir: str, out: var [str]) uses fs {
  let names = fs.list(dir) else return
  for n in names {
    let p = paths.join(dir, n)
    if fs.is_dir(p) {
      collect_auk_files(p, &out)
    } else if paths.extension(p) == some("auk") {
      out.push(p)
    }
  }
}

fn same_file(a: str, b: str): bool uses ffi {
  match (paths.canonicalize(a), paths.canonicalize(b)) {
    (some(x), some(y)) => x == y
    _ => a == b
  }
}

/// Build the module tree for the program rooted at `path`. Parse errors and missing
/// dependencies are reported per file; on error the caller should not type-check.
pub fn load(cx: Sources, path: str): Program!diag.FileFails uses fs, ffi {
  let src = match read_file(cx, path) {
    ok(s) => s
    err(e) => fail(diag.Many([err_at(path, "E0100", "cannot read {path}: {e.show()}")]))
  }
  load_source(cx, path, src)?
}

/// Like `load`, with the root file's text given (used by tests and `check`).
pub fn load_source(cx: Sources, path: str, src: str): Program!diag.FileFails uses fs, ffi {
  let file = path
  var l = Loader { cx, pkgs: [], mods: [], errs: [], loaded: {}, raft_dir: none }
  let core_pkg = load_core(&l)
  let core_root = l.pkgs[core_pkg].root
  let abs = paths.canonicalize(path) else path
  let project = match paths.parent(abs) {
    some(d) => find_project(d)
    none => none
  }
  let manifest: Manifest? = match project {
    some(p) => match fs.read(paths.join(p, "raft.toml")) {
      ok(t) => parse_manifest(t, cx.os)
      err(_) => none
    }
    none => none
  }
  let stem = paths.file_stem(path)
  let name = match manifest {
    some(m) when m.name != "" => m.name
    _ => if stem == "" { "main" } else { stem }
  }
  let pkg = l.pkgs.len()
  l.pkgs.push(Package {
    name,
    dir: project,
    root: 0,
    deps: {},
    effects: match manifest {
      some(m) => m.effects
      none => []
    },
    links: match manifest {
      some(m) => m.links
      none => []
    },
    is_core: false,
  })
  let root = add_module(&l, pkg, [name], file, src, false)
  l.pkgs[pkg].root = root
  match (project, manifest) {
    (some(dir), some(m)) => {
      l.raft_dir = paths.join(dir, ".raft")
      add_tree(&l, pkg, root, paths.join(dir, "src"), abs)
      for d in m.deps {
        match load_dep(&l, d, name, file) {
          some(dp) => l.pkgs[pkg].deps[d] = dp
          none => {}
        }
      }
      check_collisions(&l, pkg)
    }
    _ => {}
  }
  if l.errs.len() > 0 { fail(diag.Many(l.errs)) }
  Program { pkgs: l.pkgs, mods: l.mods, root, focus: root, core_pkg, core_root }
}

/// Like `load_source`, for looking at one file of a project (`auk check`, the language server):
/// a project file other than the package root (`src/wav.auk`) is checked as the module it is
/// (`audio.wav`), in the program rooted at the project's `src/lib.auk` or `src/main.auk`, so
/// paths through the package root (`audio.Fmt`) resolve. `Program.focus` is that module.
pub fn load_in_package(cx: Sources, path: str, src: str): Program!diag.FileFails uses fs, ffi {
  let abs = paths.canonicalize(path) else path
  let root_file = package_root(abs) else return load_source(cx, path, src)?
  let key = abs
  var srcs = cx.overrides
  srcs[key] = src
  var prog = load(with_sources(cx, srcs), root_file)?
  match prog.mods.find_index(m => m.file == key) {
    some(m) => prog.focus = m
    none => {}
  }
  prog
}

/// The project's `src/lib.auk` or `src/main.auk` when `abs` is another file under its `src/`.
fn package_root(abs: str): str? uses fs, ffi {
  let dir = paths.parent(abs) else return none
  let proj = find_project(dir) else return none
  let src_dir = paths.join(proj, "src")
  if !paths.is_under(abs, src_dir) { return none }
  let root = ["lib.auk", "main.auk"].map(f => paths.join(src_dir, f)).find(
    f => paths.is_file(f),
  ) else return none
  if same_file(root, abs) { none } else { root }
}

test "manifest keys" {
  let m = parse_manifest(
    "[package]\nname = \"web\" # c\nversion = \"0.1.0\"\neffects = [\"net\", \"fs\"]\n\n[deps]\nhttp = \"^0.1\"\ngeo = {{ path = \"../geo\" }}\n",
    "macos",
  )
  assert m.name == "web"
  assert m.effects == ["net", "fs"]
  assert m.deps == ["http", "geo"]
  // [link] libs, then this OS's
  let l = parse_manifest("[link]\nmacos = [\"m\"]\nlibs = [\"a\"]\nlinux = [\"l\"]\n", "macos")
  assert l.links.sort() == ["a", "m"]
  assert parse_manifest(
    "[link]\nmacos = [\"m\"]\nlibs = [\"a\"]\nlinux = [\"l\"]\n",
    "linux",
  ).links.sort() ==
    ["a", "l"]
}

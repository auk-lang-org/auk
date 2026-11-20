/// `raft`, the Auk package manager (src/bin/raft.rs). See docs/raft.md.
///
/// The port is line by line, with the same names and order. Differences in shape from the Rust:
/// errors are `T!res.Fail` (Rust's `Res<T>`); paths are `/`-separated `str`s (`paths.auk`); the
/// lazily built "missing" message of `load_dep` is a plain `str`; the closures of `list` are
/// functions. The default registry is rpm, https://rpm.auk-lang.org (rpm.auk).

let USAGE = """
  usage: raft <command> [args]

  commands:
    new <name> [--lib]          create <name>/ with raft.toml and src/main.auk (or src/lib.auk)
    add <pkg>[@<version>]       add a dependency, then install: the latest version (as
                                ^MAJOR.MINOR), or exactly <version>, or the newest that fits
                                a requirement (http@0.1.1, http@^0.1, http@~0.1.1)
    add <pkg> --path <dir>      add a dependency on a local package
    add <pkg> --url <url>       add a dependency on a package bundle at an http(s) URL
    remove <pkg>                drop a dependency, then re-install
    install                     resolve, check effects, copy into .raft/, write raft.lock
    list                        show the dependency tree with versions and effects
    pack [<dir>]                write the package as <dir>/<name>.raft (default: the project)
    publish [--token <token>]   publish this version of the package to the registry (an rpm
                                server); a version is permanent. The token comes from your
                                account page there (or $RPM_TOKEN)

  environment:
    RAFT_REGISTRY              package registry: an rpm server, a directory, or an http(s)
                               URL serving <name>.raft bundles
                               (default: https://rpm.auk-lang.org)
    RPM_TOKEN                  the token `raft publish` signs in with
  """

fn main(args: [str]): int uses fs, net, env, ffi {
  let result: ()!res.Fail = match args.skip(1) {
    ["new", name] => new(name, false)
    ["new", name, "--lib"] | ["new", "--lib", name] => new(name, true)
    ["add", pkg] => add(pkg, none)
    ["add", pkg, "--path", dir] | ["add", "--path", dir, pkg] => add(pkg, some(Path(dir)))
    ["add", pkg, "--url", u] | ["add", "--url", u, pkg] => add(pkg, some(Url(u)))
    ["remove", pkg] => remove(pkg)
    ["install"] => match project() {
      ok(dir) => install(dir)
      err(Bad(e)) => bad(e)
    }
    ["list"] => match project() {
      ok(dir) => list(dir)
      err(Bad(e)) => bad(e)
    }
    ["pack"] => match project() {
      ok(dir) => pack(dir, dir)
      err(Bad(e)) => bad(e)
    }
    ["pack", out] => match project() {
      ok(dir) => pack(dir, out)
      err(Bad(e)) => bad(e)
    }
    ["publish"] => publish(none)
    ["publish", "--token", token] => publish(some(token))
    ["help"] | ["--help"] | ["-h"] => {
      print(USAGE.strip_suffix("\n") else USAGE)
      return 0
    }
    _ => {
      eprint(USAGE.strip_suffix("\n") else USAGE)
      return 2
    }
  }
  match result {
    ok(_) => 0
    err(Bad(e)) => {
      eprint("error: {e.msg}")
      match e.help {
        some(help) => eprint("  help: {help}")
        none => {}
      }
      1
    }
  }
}

fn bad<T>(e: res.Error): T!res.Fail = fail(res.Bad(e))

/// Run `f` with a new private scratch directory (where fetched packages are unpacked), removing
/// it afterwards whatever the result.
fn with_work<T>(f: (str) => T!res.Fail): T!res.Fail uses fs, ffi {
  let work = fs.temp_dir() else e => return bad(
    res.err("cannot make a temporary directory: {paths.io_error(e.show())}"),
  )
  let r = f(work)
  let _ = paths.remove_all(work)
  r
}

/// The registry rpm.auk-lang.org runs, used unless `RAFT_REGISTRY` names another.
let DEFAULT_REGISTRY = "https://rpm.auk-lang.org"

/// The registry: `$RAFT_REGISTRY` (an rpm server, a directory, or a bundle host), else rpm.
fn registry(): str uses env {
  match env.get("RAFT_REGISTRY") {
    some(r) when r != "" => r
    _ => DEFAULT_REGISTRY
  }
}

/// The nearest directory, from the current one upward, holding a `raft.toml`.
fn project(): str!res.Fail uses fs, ffi {
  let cwd = paths.cwd()
  var d: str? = cwd
  loop {
    let x = d else break
    if paths.is_file(paths.join(x, "raft.toml")) { return x }
    d = paths.parent(x)
  }
  bad(
    res.err("no raft.toml in this directory or any parent").help("create a project with `raft new <name>`"),
  )
}

/// `raft new`: create a project directory, refusing to touch an existing one.
fn new(name: str, lib: bool): ()!res.Fail uses fs {
  match manifest.bad_name(name) {
    some(msg) => return bad(
      res.err(
        msg,
      ).help("names are lowercase `a-z0-9_`, start with a letter, and avoid core modules"),
    )
    none => {}
  }
  let dir = name
  if fs.exists(dir) {
    return bad(res.err("`{name}` already exists").help("choose another name or remove it first"))
  }
  write_new(
    dir,
    "raft.toml",
    "[package]\nname = \"{name}\"\nversion = \"0.1.0\"\neffects = []\n\n[deps]\n",
  )?
  write_new(dir, ".gitignore", "/.raft/\n")?
  if lib {
    write_new(dir, "src/lib.auk", "pub fn hello(): str {{\n    \"hello from {name}\"\n}}\n")?
  } else {
    write_new(dir, "src/main.auk", "fn main() {{\n    print(\"Hello from {name}!\")\n}}\n")?
  }
  print("created {name}/ ({if lib { "library" } else { "app" }})")
}

/// `new`'s `write` closure.
fn write_new(dir: str, rel: str, text: str): ()!res.Fail uses fs {
  let path = paths.join(dir, rel)
  let io = (e: Err) => res.err("cannot write {path}: {paths.io_error(e.show())}")
  fs.mkdir(paths.parent(path) else "") else e => return bad(io(e))
  fs.write(path, text) else e => return bad(io(e))
}

/// Where `raft add` takes a package from, when not the registry.
enum From {
  Path(dir: str),
  Url(u: str),
}

/// `raft add`: write the requirement into `[deps]`, then install (restoring raft.toml on failure).
/// `spec` is `<pkg>`, or for a registry package `<pkg>@<version>` (exactly that version) or
/// `<pkg>@<requirement>`.
fn add(spec: str, from: From?): ()!res.Fail uses fs, net, env, ffi {
  let (pkg, pin) = match spec.find("@") {
    some(i) => (spec[0..i], some(spec[i + 1..spec.len()]))
    none => (spec, none)
  }
  let want = match pin {
    some(w) => {
      if from != none {
        return bad(
          res.err("`{pkg}@{w}`: only a registry package takes a version").help("a path or URL dependency is whatever version is there"),
        )
      }
      let text = if semver.parse_version(w) != none { "={w}" } else { w }
      let req = semver.parse_req(
        text,
      ) else return bad(
        res.err("invalid version `{w}` for {pkg}").help("give a version (1.2.3) or a requirement (^1.2, ~1.2.3, *)"),
      )
      some(req)
    }
    none => none
  }
  let dir = project()?
  let root = manifest.load(dir)?
  if pkg == root.name {
    return bad(res.err("{pkg} cannot depend on itself"))
  }
  match manifest.bad_name(pkg) {
    some(msg) => return bad(res.err(msg))
    none => {}
  }
  let value = match from {
    some(Path(p)) => {
      let _ = load_dep(paths.join(dir, p), pkg, [root.name, pkg], "no raft.toml in {p}")?
      toml.value_str(toml.Table([toml.Entry { key: "path", value: toml.Str(p) }]))
    }
    some(Url(u)) => {
      if !fetch.is_url(u) {
        return bad(res.err("`{u}` is not an http:// or https:// URL"))
      }
      // Fetched again by install; checking first gives a clean error before raft.toml changes.
      let _ = with_work(work => fetch_pkg(u, pkg, [root.name, pkg], work))?
      toml.value_str(toml.Table([toml.Entry { key: "url", value: toml.Str(u) }]))
    }
    none => {
      let (m, _) = with_work(work => load_registry(pkg, [root.name, pkg], work, want, none))?
      match want {
        some(req) => {
          if !semver.matches(req, m.version) {
            return bad(
              res.err("no version of {pkg} in the registry matches {req.text}").help("the newest is {semver.show(m.version)}"),
            )
          }
          toml.value_str(toml.Str(req.text))
        }
        none => toml.value_str(toml.Str("^{m.version.major}.{m.version.minor}"))
      }
    }
  }
  edit_and_install(dir, pkg, some(value))
}

/// `raft remove`: drop a dependency from `[deps]`, then re-install.
fn remove(pkg: str): ()!res.Fail uses fs, net, env, ffi {
  let dir = project()?
  let root = manifest.load(dir)?
  if !root.deps.any(d => d.name == pkg) {
    return bad(
      res.err("`{pkg}` is not a dependency of {root.name}").help("dependencies are listed under [deps] in raft.toml"),
    )
  }
  edit_and_install(dir, pkg, none)
}

/// Rewrite one `[deps]` line of raft.toml and install; put the old text back if anything fails.
fn edit_and_install(dir: str, pkg: str, value: str?): ()!res.Fail uses fs, net, env, ffi {
  let path = paths.join(dir, "raft.toml")
  let old = fs.read(
    path,
  ) else e => return bad(res.err("cannot read {path}: {paths.io_error(e.show())}"))
  let text = manifest.edit_deps(
    old,
    pkg,
    value,
  ) else return bad(res.err("`{pkg}` is not in the [deps] table of raft.toml"))
  fs.write(
    path,
    text,
  ) else e => return bad(res.err("cannot write {path}: {paths.io_error(e.show())}"))
  let result = install(dir)
  if result is err(_) {
    let _ = fs.write(path, old)
  }
  result
}

/// A resolved package.
struct Pkg {
  m: manifest.Manifest,
  /// Where its files are read from.
  dir: str,
  /// `registry`, `path:<dir>` (path relative to the project when possible) or `url:<url>`.
  source: str,
  /// Names from the root down to this package, as first reached.
  chain: [str],
}

fn chain_str(chain: [str]): str = chain.join(" -> ")

/// Load the manifest in `dir` as dependency `name`, reached via `chain`.
fn load_dep(dir: str, name: str, chain: [str], missing: str): manifest.Manifest!res.Fail uses fs {
  if !paths.is_file(paths.join(dir, "raft.toml")) {
    return bad(res.err("{missing} ({chain_str(chain)})"))
  }
  let m = manifest.load(dir)?
  if m.name != name {
    return bad(res.err("{dir} names itself `{m.name}`, not `{name}` ({chain_str(chain)})"))
  }
  m
}

/// Download the bundle at `url`, unpack it into `<work>/<name>`, and load it as dependency
/// `name`: (manifest, directory).
fn fetch_pkg(
  url: str,
  name: str,
  chain: [str],
  work: str,
): (manifest.Manifest, str)!res.Fail uses fs, net {
  let data = fetch.get(
    url,
  ) else e => return bad(res.err("cannot fetch {url}: {e} ({chain_str(chain)})"))
  unpack(data, url, name, chain, work)
}

/// Unpack bundle `data` (from `url`) into `<work>/<name>` and load it as dependency `name`.
fn unpack(
  data: [int],
  url: str,
  name: str,
  chain: [str],
  work: str,
): (manifest.Manifest, str)!res.Fail uses fs {
  let chain_s = chain_str(chain)
  let files = bundle.decode(
    data,
  ) else e => return bad(
    res.err("{url} is not a raft package bundle: {e} ({chain_s})").help("make one with `raft pack`"),
  )
  let dir = paths.join(work, name)
  for (rel, bytes) in files {
    let to = paths.join(dir, rel)
    let io = (e: Err) => res.err("cannot write {to}: {paths.io_error(e.show())}")
    fs.mkdir(paths.parent(to) else "") else e => return bad(io(e))
    fs.write_bytes(to, bytes) else e => return bad(io(e))
  }
  let m = manifest.load(dir)?
  if m.name != name {
    return bad(res.err("{url} is package `{m.name}`, not `{name}` ({chain_s})"))
  }
  (m, dir)
}

/// `load_dep`, with the directory: (manifest, `dir`).
fn local_dep(
  dir: str,
  name: str,
  chain: [str],
  missing: str,
): (manifest.Manifest, str)!res.Fail uses fs {
  (load_dep(dir, name, chain, missing)?, dir)
}

/// Load registry package `name`: (manifest, directory). From an rpm server, the version that
/// fits `want` (preferring the `locked` one) is downloaded into `work`; from a bundle host,
/// `<registry>/<name>.raft`; from a directory, `<registry>/<name>/`.
fn load_registry(
  name: str,
  chain: [str],
  work: str,
  want: semver.Req?,
  locked: str?,
): (manifest.Manifest, str)!res.Fail uses fs, net, env {
  let reg = registry()
  let missing = res.err("package `{name}` not found in the registry ({chain_str(chain)})")
  let found = if fetch.is_url(reg) {
    match rpm.releases(reg, name) {
      rpm.Found(rs) => match rpm.choose(rs, want, locked) {
        some(r) => {
          let what = "{name} {semver.show(r.version)} from {reg}"
          match rpm.download(reg, name, r) {
            ok(data) => unpack(data, what, name, chain, work)
            err(e) => bad(res.err("cannot fetch {what}: {e} ({chain_str(chain)})"))
          }
        }
        none => bad(missing)
      }
      rpm.Missing() => bad(missing)
      rpm.NotRpm() => fetch_pkg(fetch.join(reg, "{name}.raft"), name, chain, work)
    }
  } else {
    local_dep(paths.join(reg, name), name, chain, "package `{name}` not found in the registry")
  }
  match found {
    ok(x) => x
    err(Bad(e)) => {
      if e.help == none {
        bad(e.help("the registry is {reg}; set RAFT_REGISTRY to use another"))
      } else {
        bad(e)
      }
    }
  }
}

/// Resolve the root's dependencies breadth-first, one version per name, checking requirements and
/// that every package's effects fit within those of the package depending on it.
///
/// A package that would be downloaded is taken from `.raft/` instead when raft.lock pins it (same
/// name and source) and the installed copy still has the locked checksum, so a locked project
/// installs offline. Downloads go under `work`.
fn resolve(
  root: manifest.Manifest,
  root_dir: str,
  lock: [manifest.Locked],
  work: str,
): [Pkg]!res.Fail uses fs, net, env {
  var pkgs: [Pkg] = []
  // (dependency, index of the package declaring it; none = root)
  var queue: [(manifest.Dep, int?)] = root.deps.map(d => (d, none))
  var head = 0
  while head < queue.len() {
    let (dep, parent) = queue[head]
    head += 1
    let (pm, pdir, pchain) = match parent {
      none => (root, root_dir, [root.name])
      some(i) => (pkgs[i].m, pkgs[i].dir, pkgs[i].chain)
    }
    var chain = pchain
    chain.push(dep.name)
    let chain_s = chain_str(chain)
    if dep.name == root.name {
      return bad(res.err("dependency cycle: {chain_s}"))
    }
    let source = match dep.src {
      Registry(_) => "registry"
      Url(u) => "url:{u}"
      Path(p) => {
        let full = paths.join(pdir, p)
        let shown = match paths.strip_base(full, root_dir) {
          some(s) => s
          none => if parent == none { p } else { full }
        }
        "path:{shown}"
      }
    }
    var version = root.version
    var effects: [str] = []
    var idx: Pkg? = none
    match pkgs.find(p => p.m.name == dep.name) {
      some(p) => {
        if p.source != source {
          return bad(
            res
              .err("{dep.name} comes from two sources: {p.source} ({chain_str(p.chain)}) and {source} ({chain_s})")
              .help("v1 allows one source and version per package; make them agree"),
          )
        }
        version = p.m.version
        effects = p.m.effects
      }
      none => {
        let installed = paths.join(root_dir, ".raft/{dep.name}")
        let remote = dep.src is Url(_) || (dep.src is Registry(_) && fetch.is_url(registry()))
        // (a locked version the requirement no longer takes is not used: raft.toml changed)
        let cached = remote &&
          match lock.find(l => l.name == dep.name && l.source == source) {
            some(l) => takes(dep.src, l.version) && ok_sum(installed) == some(l.checksum)
            none => false
          }
        let (m, dir) = match dep.src {
          _ when cached =>
            (load_dep(installed, dep.name, chain, "no raft.toml in {installed}")?, installed)
          Registry(req) => load_registry(
            dep.name,
            chain,
            work,
            some(req),
            lock.find(l => l.name == dep.name && l.source == "registry")?.version,
          )?
          Url(u) => fetch_pkg(u, dep.name, chain, work)?
          Path(p) => {
            let dir = paths.join(pdir, p)
            (load_dep(dir, dep.name, chain, "no raft.toml in {p}")?, dir)
          }
        }
        version = m.version
        effects = m.effects
        idx = some(Pkg { m, dir, source, chain })
      }
    }
    match dep.src {
      Registry(req) when !semver.matches(req, version) => {
        let help = if parent == none {
          "use {dep.name} = \"^{version.major}.{version.minor}\" in raft.toml"
        } else {
          "{pm.name} needs {dep.name} {req.text}, but the registry only has {semver.show(version)}"
        }
        return bad(
          res
            .err("{dep.name} {req.text} does not match the registry version {semver.show(version)} ({chain_s})")
            .help(help),
        )
      }
      _ => {}
    }
    match effects.find(e => !pm.effects.contains(e)) {
      some(e) => {
        let via = if chain.len() > 2 { " ({chain_s})" } else { "" }
        let allowed = toml.value_str(toml.List(pm.effects.map(x => toml.Str(x))))
        let msg = "{dep.name} {semver.show(version)}{via} needs effect `{e}`, but {pm.name}'s raft.toml only allows {allowed}"
        let help = if parent == none {
          "add \"{e}\" to [package] effects in raft.toml"
        } else {
          "{pm.name} must list \"{e}\" in its effects to depend on {dep.name}"
        }
        return bad(res.err(msg).help(help))
      }
      none => {}
    }
    match idx {
      some(pkg) => {
        let i = pkgs.len()
        for d in pkg.m.deps { queue.push((d, some(i))) }
        pkgs.push(pkg)
      }
      none => {}
    }
  }
  pkgs
}

/// Whether a dependency from `src` can be version `version`: a registry requirement must match.
fn takes(src: manifest.DepSrc, version: str): bool = match src {
  Registry(req) => match semver.parse_version(version) {
    some(v) => semver.matches(req, v)
    none => false
  }
  _ => true
}

/// The files a package ships: raft.toml, README.md if present, and everything under src/,
/// as (relative path with `/` separators, absolute path), sorted.
fn package_files(dir: str): [(str, str)]!res.Fail uses fs {
  var files = [("raft.toml", paths.join(dir, "raft.toml"))]
  if paths.is_file(paths.join(dir, "README.md")) {
    files.push(("README.md", paths.join(dir, "README.md")))
  }
  if fs.is_dir(paths.join(dir, "src")) {
    walk(
      paths.join(dir, "src"),
      "src",
      &files,
    ) else e => return bad(res.err("cannot read {dir}/src: {paths.io_error(e.show())}"))
  }
  files.sort_by(f => f.0)
}

/// `package_files`'s `walk`.
fn walk(dir: str, rel: str, out: var [(str, str)]): ()! uses fs {
  for entry in fs.list(dir)? {
    let name = "{rel}/{entry}"
    let path = paths.join(dir, entry)
    if fs.is_dir(path) {
      walk(path, name, &out)?
    } else {
      out.push((name, path))
    }
  }
}

/// The package in `dir` as a bundle (bundle.auk): each file's relative path, a NUL, its length
/// (8 bytes big-endian) and its contents.
fn bundle_of(dir: str): [int]!res.Fail uses fs {
  var files: [(str, [int])] = []
  for (rel, path) in package_files(dir)? {
    let bytes = fs.read_bytes(
      path,
    ) else e => return bad(res.err("cannot read {path}: {paths.io_error(e.show())}"))
    files.push((rel, bytes))
  }
  bundle.encode(files)
}

/// `sha256:<hex>` of the package's bundle.
fn checksum(dir: str): str!res.Fail uses fs = "sha256:{sha256.hex(bundle_of(dir)?)}"

/// `raft pack`: write the project as a bundle, `<out>/<name>.raft`, for serving from a URL.
fn pack(dir: str, out: str): ()!res.Fail uses fs {
  let m = manifest.load(dir)?
  let data = bundle_of(dir)?
  let path = paths.join(out, "{m.name}.raft")
  let io = (e: Err) => res.err("cannot write {path}: {paths.io_error(e.show())}")
  fs.mkdir(out) else e => return bad(io(e))
  fs.write_bytes(path, data) else e => return bad(io(e))
  print("packed {m.name} {semver.show(m.version)} -> {path}")
  print("  sha256:{sha256.hex(data)}")
}

/// `raft publish`: send the package's files to the registry, an rpm server, as a new version.
fn publish(token: str?): ()!res.Fail uses fs, net, env, ffi {
  let dir = project()?
  let m = manifest.load(dir)?
  let reg = registry()
  if !fetch.is_url(reg) {
    return bad(
      res.err("cannot publish to {reg}: it is a directory, not an rpm server").help("unset RAFT_REGISTRY to publish to {DEFAULT_REGISTRY}"),
    )
  }
  if !fetch.private(reg) {
    return bad(
      res.err("cannot publish to {reg}: the token would be sent unencrypted").help("use the registry's https:// address"),
    )
  }
  let token = token else env.get("RPM_TOKEN") else ""
  if token == "" {
    return bad(
      res.err("publishing needs a token").help("make one at {fetch.join(reg, "account")}, then set RPM_TOKEN or pass --token <token>"),
    )
  }
  if token.chars().any(c => int(c) <= 32 || int(c) >= 127) {
    return bad(res.err("the token has a space or an unprintable character in it"))
  }
  var files: [(str, [int])] = []
  for (rel, path) in package_files(dir)? {
    let bytes = fs.read_bytes(
      path,
    ) else e => return bad(res.err("cannot read {path}: {paths.io_error(e.show())}"))
    files.push((rel, bytes))
  }
  let what = "{m.name} {semver.show(m.version)}"
  let p = rpm.publish(
    reg,
    token,
    files,
  ) else e => return bad(res.err("cannot publish {what} to {reg}: {e}"))
  let sum = "sha256:{sha256.hex(bundle.encode(files))}"
  if p.checksum != sum {
    return bad(
      res.err("{reg} published {p.name} {p.version} with other files than these").help("its checksum is {p.checksum}, this package's is {sum}"),
    )
  }
  print("published {p.name} {p.version} -> {fetch.join(reg, "packages/{p.name}/{p.version}")}")
  print("  {sum}")
}

/// `checksum(dir).ok()` (`checksum(dir) else none` is typed `str` in a comparison).
fn ok_sum(dir: str): str? uses fs {
  match checksum(dir) {
    ok(s) => s
    err(_) => none
  }
}

/// `raft install`: resolve, verify against raft.lock, copy into `.raft/`, rewrite raft.lock,
/// and print what was added or removed. Nothing is written unless every check passes.
fn install(dir: str): ()!res.Fail uses fs, net, env, ffi = with_work(work => install_in(dir, work))

/// `install`, downloading under `work`.
fn install_in(dir: str, work: str): ()!res.Fail uses fs, net, env, ffi {
  let root = manifest.load(dir)?
  let lock_path = paths.join(dir, "raft.lock")
  let old = manifest.read_lock(lock_path)?
  let pkgs = resolve(root, dir, old, work)?  // breadth-first: direct dependencies print first
  let store = paths.join(dir, ".raft")
  var locked: [manifest.Locked] = []
  for p in pkgs {
    let (name, version) = (p.m.name, semver.show(p.m.version))
    let sum = checksum(p.dir)?
    let prev = old.find(l => l.name == name && l.version == version && l.source == p.source)
    // Registry and URL packages are pinned by raft.lock; path packages are local and may change
    // freely.
    match prev {
      some(prev) when !p.source.starts_with("path:") => {
        if sum != prev.checksum {
          let place = match p.source.strip_prefix("url:") {
            some(u) => "at {u}"
            none => "in the registry ({if fetch.is_url(registry()) { registry() } else { p.dir }})"
          }
          return bad(
            res
              .err("checksum mismatch for {name} {version} {place}")
              .help("raft.lock expects {prev.checksum}; if the change is intended, delete {name}'s entry from raft.lock and run `raft install`"),
          )
        }
        let installed = paths.join(store, name)
        if paths.is_file(paths.join(installed, "raft.toml")) {
          let have = checksum(installed)?
          if have != prev.checksum {
            return bad(
              res
                .err("checksum mismatch for {name} {version} in .raft/{name}: expected {prev.checksum}, found {have}")
                .help("the installed files were modified; delete .raft/{name} and run `raft install` to restore them"),
            )
          }
        }
      }
      _ => {}
    }
    locked.push(manifest.Locked {
      name,
      version,
      source: p.source,
      effects: p.m.effects,
      checksum: sum,
    })
  }

  locked = locked.sort_by(l => l.name)

  // Every check passed: sync .raft/ and write the lock.
  let io = (e: Err) => res.err("cannot update {store}: {paths.io_error(e.show())}")
  match fs.list(store) {
    ok(entries) => for name in entries {
      if !pkgs.any(p => p.m.name == name) {
        let path = paths.join(store, name)
        let r = if fs.is_dir(path) { paths.remove_all(path) } else { fs.remove(path) }
        r else e => return bad(io(e))
      }
    }
    err(_) => {}
  }
  // An `auk` (a run, the language server) may be reading .raft/ meanwhile: a package that is
  // already installed as it should be is left alone, and a changed one is copied next to the
  // old one and then renamed into place, so nobody sees a half-copied package.
  for p in pkgs {
    let name = p.m.name
    let dest = paths.join(store, name)
    let want = locked.find(l => l.name == name)?.checksum
    if paths.is_file(paths.join(dest, "raft.toml")) && want != none && ok_sum(dest) == want {
      continue
    }
    let fresh = paths.join(store, ".{name}.new")
    if fs.exists(fresh) {
      paths.remove_all(fresh) else e => return bad(io(e))
    }
    for (rel, src) in package_files(p.dir)? {
      let to = paths.join(fresh, rel)
      fs.mkdir(paths.parent(to) else "") else e => return bad(io(e))
      paths.copy(src, to) else e => return bad(io(e))
    }
    if fs.exists(dest) {
      let stale = paths.join(store, ".{name}.old")
      if fs.exists(stale) {
        paths.remove_all(stale) else e => return bad(io(e))
      }
      fs.rename(dest, stale) else e => return bad(io(e))
      fs.rename(fresh, dest) else e => return bad(io(e))
      paths.remove_all(stale) else e => return bad(io(e))
    } else {
      fs.rename(fresh, dest) else e => return bad(io(e))
    }
  }
  fs.write(
    lock_path,
    manifest.write_lock(locked),
  ) else e => return bad(res.err("cannot write {lock_path}: {paths.io_error(e.show())}"))

  // Report changes against the previous lock.
  var lines: [(str, str)] = []
  for p in pkgs {
    let v = semver.show(p.m.version)
    if old.any(l => l.name == p.m.name && l.version == v && l.source == p.source) {
      continue
    }
    var note = uses_note(p.m.effects)
    if p.chain.len() > 2 {
      let via = "(via {p.chain[p.chain.len() - 2]})"
      note = if note == "" { via } else { "{note} {via}" }
    }
    lines.push(("+ {p.m.name} {v}", note))
  }
  for l in old {
    if !locked.any(n => n.name == l.name) { lines.push(("- {l.name} {l.version}", "")) }
  }
  let width = lines.filter(l => l.1 != "").map(l => l.0.len()).max() else 0
  for (head, note) in lines {
    if note == "" {
      print("  {head}")
    } else {
      print("  {head}{" ".repeat(max(width - head.len(), 0))}   {note}")
    }
  }
}

/// `uses a, b` for a non-empty effect list (Rust's `uses`, a keyword here).
fn uses_note(effects: [str]): str = if effects.len() == 0 {
  ""
} else {
  "uses {effects.join(", ")}"
}

/// `list`'s `line` closure.
fn line(m: manifest.Manifest): str {
  let u = uses_note(m.effects)
  if u == "" {
    "{m.name} {semver.show(m.version)}"
  } else {
    "{m.name} {semver.show(m.version)}   {u}"
  }
}

/// `raft list`: print the installed dependency tree.
fn list(dir: str): ()!res.Fail uses fs {
  let root = manifest.load(dir)?
  let store = paths.join(dir, ".raft")
  print(line(root))
  var path = [root.name]
  tree(root.deps, store, "", &path)
}

/// `list`'s `tree`.
fn tree(deps: [manifest.Dep], store: str, prefix: str, path: var [str]): ()!res.Fail uses fs {
  for i, dep in deps {
    let last = i + 1 == deps.len()
    let installed = paths.join(store, dep.name)
    if !paths.is_file(paths.join(installed, "raft.toml")) {
      return bad(res.err("{dep.name} is not installed").help("run `raft install`"))
    }
    let m = manifest.load(installed)?
    let cycle = path.contains(m.name)
    print("{prefix}{if last { "└── " } else { "├── " }}{line(m)}{if cycle { " (cycle)" } else { "" }}")
    if !cycle {
      path.push(m.name)
      tree(m.deps, store, "{prefix}{if last { "    " } else { "│   " }}", &path)?
      let _ = path.pop()
    }
  }
}

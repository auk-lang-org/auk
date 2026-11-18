//! `raft`, the Auk package manager. See docs/raft.md.

#[path = "raft/manifest.rs"]
mod manifest;
#[path = "raft/semver.rs"]
mod semver;
#[path = "raft/sha256.rs"]
mod sha256;
#[path = "raft/toml.rs"]
mod toml;

use manifest::{Dep, DepSrc, Locked, Manifest, read_lock, write_lock};
use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::process::exit;
use std::{env, fs};

const USAGE: &str = "\
usage: raft <command> [args]

commands:
  new <name> [--lib]          create <name>/ with raft.toml and src/main.auk (or src/lib.auk)
  add <pkg> [--path <dir>]    add a dependency (latest version, as ^MAJOR.MINOR), then install
  remove <pkg>                drop a dependency, then re-install
  install                     resolve, check effects, copy into .raft/, write raft.lock
  list                        show the dependency tree with versions and effects

environment:
  RAFT_REGISTRY              package registry directory (default: Auk's packages/)";

/// A user-facing failure: `error: msg` plus an optional `  help: ...` line.
#[derive(Debug)]
pub struct Error {
    pub msg: String,
    pub help: Option<String>,
}

pub type Res<T> = Result<T, Error>;

pub fn err(msg: impl Into<String>) -> Error {
    Error { msg: msg.into(), help: None }
}

impl Error {
    pub fn help(self, help: impl Into<String>) -> Error {
        Error { help: Some(help.into()), ..self }
    }
}

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let result = match args.as_slice() {
        ["new", name] => new(name, false),
        ["new", name, "--lib"] | ["new", "--lib", name] => new(name, true),
        ["add", pkg] => add(pkg, None),
        ["add", pkg, "--path", dir] | ["add", "--path", dir, pkg] => add(pkg, Some(dir)),
        ["remove", pkg] => remove(pkg),
        ["install"] => project().and_then(|dir| install(&dir)),
        ["list"] => project().and_then(|dir| list(&dir)),
        ["help" | "--help" | "-h"] => {
            println!("{USAGE}");
            return;
        }
        _ => {
            eprintln!("{USAGE}");
            exit(2)
        }
    };
    if let Err(e) = result {
        eprintln!("error: {}", e.msg);
        if let Some(help) = e.help {
            eprintln!("  help: {help}");
        }
        exit(1);
    }
}

/// The registry directory: `$RAFT_REGISTRY`, else the `packages/` folder of the Auk installation.
fn registry() -> PathBuf {
    env::var_os("RAFT_REGISTRY")
        .map_or_else(|| PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/packages")), PathBuf::from)
}

/// The nearest directory, from the current one upward, holding a `raft.toml`.
fn project() -> Res<PathBuf> {
    let cwd = env::current_dir().map_err(|e| err(format!("cannot read the current directory: {e}")))?;
    cwd.ancestors().find(|d| d.join("raft.toml").is_file()).map(Path::to_path_buf).ok_or_else(|| {
        err("no raft.toml in this directory or any parent").help("create a project with `raft new <name>`")
    })
}

/// `raft new`: create a project directory, refusing to touch an existing one.
fn new(name: &str, lib: bool) -> Res<()> {
    if let Some(msg) = manifest::bad_name(name) {
        return Err(err(msg).help("names are lowercase `a-z0-9_`, start with a letter, and avoid core modules"));
    }
    let dir = Path::new(name);
    if dir.exists() {
        return Err(err(format!("`{name}` already exists")).help("choose another name or remove it first"));
    }
    let write = |rel: &str, text: String| {
        let path = dir.join(rel);
        fs::create_dir_all(path.parent().unwrap())
            .and_then(|()| fs::write(&path, text))
            .map_err(|e| err(format!("cannot write {}: {e}", path.display())))
    };
    write("raft.toml", format!("[package]\nname = \"{name}\"\nversion = \"0.1.0\"\neffects = []\n\n[deps]\n"))?;
    write(".gitignore", "/.raft/\n".into())?;
    if lib {
        write("src/lib.auk", format!("pub fn hello(): str {{\n    \"hello from {name}\"\n}}\n"))?;
    } else {
        write("src/main.auk", format!("fn main() {{\n    print(\"Hello from {name}!\");\n}}\n"))?;
    }
    println!("created {name}/ ({})", if lib { "library" } else { "app" });
    Ok(())
}

/// `raft add`: write the requirement into `[deps]`, then install (restoring raft.toml on failure).
fn add(pkg: &str, path: Option<&str>) -> Res<()> {
    let dir = project()?;
    let root = Manifest::load(&dir)?;
    if pkg == root.name {
        return Err(err(format!("{pkg} cannot depend on itself")));
    }
    if let Some(msg) = manifest::bad_name(pkg) {
        return Err(err(msg));
    }
    let value = match path {
        Some(p) => {
            load_dep(&dir.join(p), pkg, &[&root.name, pkg], || format!("no raft.toml in {p}"))?;
            toml::value_str(&toml::Value::Table(vec![("path".into(), toml::Value::Str(p.into()))]))
        }
        None => {
            let m = load_registry(pkg, &[&root.name, pkg])?;
            toml::value_str(&toml::Value::Str(format!("^{}.{}", m.version.major, m.version.minor)))
        }
    };
    edit_and_install(&dir, pkg, Some(&value))
}

/// `raft remove`: drop a dependency from `[deps]`, then re-install.
fn remove(pkg: &str) -> Res<()> {
    let dir = project()?;
    let root = Manifest::load(&dir)?;
    if !root.deps.iter().any(|d| d.name == pkg) {
        return Err(err(format!("`{pkg}` is not a dependency of {}", root.name))
            .help("dependencies are listed under [deps] in raft.toml"));
    }
    edit_and_install(&dir, pkg, None)
}

/// Rewrite one `[deps]` line of raft.toml and install; put the old text back if anything fails.
fn edit_and_install(dir: &Path, pkg: &str, value: Option<&str>) -> Res<()> {
    let path = dir.join("raft.toml");
    let old = fs::read_to_string(&path).map_err(|e| err(format!("cannot read {}: {e}", path.display())))?;
    let Some(text) = manifest::edit_deps(&old, pkg, value) else {
        return Err(err(format!("`{pkg}` is not in the [deps] table of raft.toml")));
    };
    fs::write(&path, text).map_err(|e| err(format!("cannot write {}: {e}", path.display())))?;
    let result = install(dir);
    if result.is_err() {
        let _ = fs::write(&path, old);
    }
    result
}

/// A resolved package.
struct Pkg {
    m: Manifest,
    /// Where its files are read from.
    dir: PathBuf,
    /// `registry` or `path:<dir>` (path relative to the project when possible).
    source: String,
    /// Names from the root down to this package, as first reached.
    chain: Vec<String>,
}

fn chain_str(chain: &[impl AsRef<str>]) -> String {
    chain.iter().map(AsRef::as_ref).collect::<Vec<_>>().join(" -> ")
}

/// Load the manifest in `dir` as dependency `name`, reached via `chain`.
fn load_dep(dir: &Path, name: &str, chain: &[&str], missing: impl Fn() -> String) -> Res<Manifest> {
    if !dir.join("raft.toml").is_file() {
        return Err(err(format!("{} ({})", missing(), chain_str(chain))));
    }
    let m = Manifest::load(dir)?;
    if m.name != name {
        return Err(err(format!("{} names itself `{}`, not `{name}` ({})", dir.display(), m.name, chain_str(chain))));
    }
    Ok(m)
}

/// Load registry package `name`.
fn load_registry(name: &str, chain: &[&str]) -> Res<Manifest> {
    let reg = registry();
    load_dep(&reg.join(name), name, chain, || format!("package `{name}` not found in the registry")).map_err(|e| {
        if e.help.is_none() {
            e.help(format!("the registry is {}; set RAFT_REGISTRY to use another", reg.display()))
        } else {
            e
        }
    })
}

/// Resolve the root's dependencies breadth-first, one version per name, checking requirements and
/// that every package's effects fit within those of the package depending on it.
fn resolve(root: &Manifest, root_dir: &Path) -> Res<Vec<Pkg>> {
    let mut pkgs: Vec<Pkg> = Vec::new();
    // (dependency, index of the package declaring it; None = root)
    let mut queue: VecDeque<(Dep, Option<usize>)> = root.deps.iter().map(|d| (d.clone(), None)).collect();
    while let Some((dep, parent)) = queue.pop_front() {
        let (pm, pdir, pchain) = match parent {
            None => (root, root_dir.to_path_buf(), vec![root.name.clone()]),
            Some(i) => (&pkgs[i].m, pkgs[i].dir.clone(), pkgs[i].chain.clone()),
        };
        let mut chain = pchain.clone();
        chain.push(dep.name.clone());
        let chain_s = chain_str(&chain);
        if dep.name == root.name {
            return Err(err(format!("dependency cycle: {chain_s}")));
        }
        let source = match &dep.src {
            DepSrc::Registry(_) => "registry".to_string(),
            DepSrc::Path(p) => {
                let full = pdir.join(p);
                let shown = full.strip_prefix(root_dir).map(Path::to_path_buf).unwrap_or_else(|_| match parent {
                    None => PathBuf::from(p),
                    Some(_) => full.clone(),
                });
                format!("path:{}", shown.display())
            }
        };
        let (version, effects, idx) = if let Some(i) = pkgs.iter().position(|p| p.m.name == dep.name) {
            let p = &pkgs[i];
            if p.source != source {
                return Err(err(format!(
                    "{} comes from two sources: {} ({}) and {source} ({chain_s})",
                    dep.name,
                    p.source,
                    chain_str(&p.chain)
                ))
                .help("v1 allows one source and version per package; make them agree"));
            }
            (p.m.version, p.m.effects.clone(), None)
        } else {
            let (m, dir) = match &dep.src {
                DepSrc::Registry(_) => {
                    let refs: Vec<&str> = chain.iter().map(String::as_str).collect();
                    (load_registry(&dep.name, &refs)?, registry().join(&dep.name))
                }
                DepSrc::Path(p) => {
                    let dir = pdir.join(p);
                    let refs: Vec<&str> = chain.iter().map(String::as_str).collect();
                    (load_dep(&dir, &dep.name, &refs, || format!("no raft.toml in {p}"))?, dir)
                }
            };
            (m.version, m.effects.clone(), Some(Pkg { m, dir, source, chain: chain.clone() }))
        };
        if let DepSrc::Registry(req) = &dep.src
            && !req.matches(version)
        {
            let help = if parent.is_none() {
                format!("use {} = \"^{}.{}\" in raft.toml", dep.name, version.major, version.minor)
            } else {
                format!("{} needs {} {req}, but the registry only has {version}", pm.name, dep.name)
            };
            return Err(
                err(format!("{} {req} does not match the registry version {version} ({chain_s})", dep.name)).help(help)
            );
        }
        if let Some(e) = effects.iter().find(|e| !pm.effects.contains(e)) {
            let via = if chain.len() > 2 { format!(" ({chain_s})") } else { String::new() };
            let msg = format!(
                "{} {version}{via} needs effect `{e}`, but {}'s raft.toml only allows {}",
                dep.name,
                pm.name,
                toml::value_str(&toml::Value::List(pm.effects.iter().map(|e| toml::Value::Str(e.clone())).collect()))
            );
            let help = if parent.is_none() {
                format!("add \"{e}\" to [package] effects in raft.toml")
            } else {
                format!("{} must list \"{e}\" in its effects to depend on {}", pm.name, dep.name)
            };
            return Err(err(msg).help(help));
        }
        if let Some(pkg) = idx {
            let i = pkgs.len();
            queue.extend(pkg.m.deps.iter().map(|d| (d.clone(), Some(i))));
            pkgs.push(pkg);
        }
    }
    Ok(pkgs)
}

/// The files a package ships: raft.toml, README.md if present, and everything under src/,
/// as (relative path with `/` separators, absolute path), sorted.
fn package_files(dir: &Path) -> Res<Vec<(String, PathBuf)>> {
    fn walk(dir: &Path, rel: &str, out: &mut Vec<(String, PathBuf)>) -> std::io::Result<()> {
        for entry in fs::read_dir(dir)? {
            let entry = entry?;
            let name = format!("{rel}/{}", entry.file_name().to_string_lossy());
            if entry.file_type()?.is_dir() {
                walk(&entry.path(), &name, out)?;
            } else {
                out.push((name, entry.path()));
            }
        }
        Ok(())
    }
    let mut files = vec![("raft.toml".to_string(), dir.join("raft.toml"))];
    if dir.join("README.md").is_file() {
        files.push(("README.md".into(), dir.join("README.md")));
    }
    if dir.join("src").is_dir() {
        walk(&dir.join("src"), "src", &mut files)
            .map_err(|e| err(format!("cannot read {}/src: {e}", dir.display())))?;
    }
    files.sort();
    Ok(files)
}

/// `sha256:<hex>` over each file's relative path, a NUL, its length (8 bytes big-endian) and its contents.
fn checksum(dir: &Path) -> Res<String> {
    let mut data = Vec::new();
    for (rel, path) in package_files(dir)? {
        let bytes = fs::read(&path).map_err(|e| err(format!("cannot read {}: {e}", path.display())))?;
        data.extend_from_slice(rel.as_bytes());
        data.push(0);
        data.extend_from_slice(&(bytes.len() as u64).to_be_bytes());
        data.extend_from_slice(&bytes);
    }
    Ok(format!("sha256:{}", sha256::hex(&data)))
}

/// `raft install`: resolve, verify against raft.lock, copy into `.raft/`, rewrite raft.lock,
/// and print what was added or removed. Nothing is written unless every check passes.
fn install(dir: &Path) -> Res<()> {
    let root = Manifest::load(dir)?;
    let pkgs = resolve(&root, dir)?; // breadth-first: direct dependencies print first
    let lock_path = dir.join("raft.lock");
    let old = read_lock(&lock_path)?;
    let store = dir.join(".raft");
    let mut locked = Vec::new();
    for p in &pkgs {
        let (name, version) = (&p.m.name, p.m.version.to_string());
        let sum = checksum(&p.dir)?;
        let prev = old.iter().find(|l| l.name == *name && l.version == version && l.source == p.source);
        // Registry packages are pinned by raft.lock; path packages are local and may change freely.
        if let Some(prev) = prev.filter(|_| p.source == "registry") {
            if sum != prev.checksum {
                return Err(err(format!("checksum mismatch for {name} {version} in the registry ({})", p.dir.display()))
                    .help(format!("raft.lock expects {}; if the change is intended, delete {name}'s entry from raft.lock and run `raft install`", prev.checksum)));
            }
            let installed = store.join(name);
            if installed.join("raft.toml").is_file() {
                let have = checksum(&installed)?;
                if have != prev.checksum {
                    return Err(err(format!("checksum mismatch for {name} {version} in .raft/{name}: expected {}, found {have}", prev.checksum))
                        .help(format!("the installed files were modified; delete .raft/{name} and run `raft install` to restore them")));
                }
            }
        }
        locked.push(Locked {
            name: name.clone(),
            version,
            source: p.source.clone(),
            effects: p.m.effects.clone(),
            checksum: sum,
        });
    }

    locked.sort_by(|a, b| a.name.cmp(&b.name));

    // Every check passed: sync .raft/ and write the lock.
    let io = |e: std::io::Error| err(format!("cannot update {}: {e}", store.display()));
    if let Ok(entries) = fs::read_dir(&store) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if !pkgs.iter().any(|p| p.m.name == name) {
                let path = entry.path();
                if path.is_dir() { fs::remove_dir_all(&path) } else { fs::remove_file(&path) }.map_err(io)?;
            }
        }
    }
    // An `auk` (a run, the language server) may be reading .raft/ meanwhile: a package that is
    // already installed as it should be is left alone, and a changed one is copied next to the
    // old one and then renamed into place, so nobody sees a half-copied package.
    for p in &pkgs {
        let name = &p.m.name;
        let dest = store.join(name);
        let want = locked.iter().find(|l| l.name == *name).map(|l| l.checksum.clone());
        if dest.join("raft.toml").is_file() && want.is_some() && checksum(&dest).ok() == want {
            continue;
        }
        let fresh = store.join(format!(".{name}.new"));
        if fresh.exists() {
            fs::remove_dir_all(&fresh).map_err(io)?;
        }
        for (rel, src) in package_files(&p.dir)? {
            let to = fresh.join(&rel);
            fs::create_dir_all(to.parent().unwrap()).and_then(|()| fs::copy(&src, &to)).map_err(io)?;
        }
        if dest.exists() {
            let stale = store.join(format!(".{name}.old"));
            if stale.exists() {
                fs::remove_dir_all(&stale).map_err(io)?;
            }
            fs::rename(&dest, &stale).map_err(io)?;
            fs::rename(&fresh, &dest).map_err(io)?;
            fs::remove_dir_all(&stale).map_err(io)?;
        } else {
            fs::rename(&fresh, &dest).map_err(io)?;
        }
    }
    fs::write(&lock_path, write_lock(&locked))
        .map_err(|e| err(format!("cannot write {}: {e}", lock_path.display())))?;

    // Report changes against the previous lock.
    let mut lines: Vec<(String, String)> = Vec::new();
    for p in &pkgs {
        let v = p.m.version.to_string();
        if old.iter().any(|l| l.name == p.m.name && l.version == v && l.source == p.source) {
            continue;
        }
        let mut note = uses(&p.m.effects);
        if p.chain.len() > 2 {
            let via = format!("(via {})", p.chain[p.chain.len() - 2]);
            note = if note.is_empty() { via } else { format!("{note} {via}") };
        }
        lines.push((format!("+ {} {v}", p.m.name), note));
    }
    for l in old.iter().filter(|l| !locked.iter().any(|n| n.name == l.name)) {
        lines.push((format!("- {} {}", l.name, l.version), String::new()));
    }
    let width = lines.iter().filter(|(_, n)| !n.is_empty()).map(|(h, _)| h.len()).max().unwrap_or(0);
    for (head, note) in lines {
        if note.is_empty() {
            println!("  {head}");
        } else {
            println!("  {head:width$}   {note}");
        }
    }
    Ok(())
}

/// `uses a, b` for a non-empty effect list.
fn uses(effects: &[String]) -> String {
    if effects.is_empty() { String::new() } else { format!("uses {}", effects.join(", ")) }
}

/// `raft list`: print the installed dependency tree.
fn list(dir: &Path) -> Res<()> {
    let root = Manifest::load(dir)?;
    let store = dir.join(".raft");
    let line = |m: &Manifest| {
        let u = uses(&m.effects);
        if u.is_empty() { format!("{} {}", m.name, m.version) } else { format!("{} {}   {u}", m.name, m.version) }
    };
    println!("{}", line(&root));
    fn tree(
        deps: &[Dep],
        store: &Path,
        prefix: &str,
        path: &mut Vec<String>,
        line: &dyn Fn(&Manifest) -> String,
    ) -> Res<()> {
        for (i, dep) in deps.iter().enumerate() {
            let last = i + 1 == deps.len();
            let installed = store.join(&dep.name);
            if !installed.join("raft.toml").is_file() {
                return Err(err(format!("{} is not installed", dep.name)).help("run `raft install`"));
            }
            let m = Manifest::load(&installed)?;
            let cycle = path.contains(&m.name);
            println!(
                "{prefix}{}{}{}",
                if last { "└── " } else { "├── " },
                line(&m),
                if cycle { " (cycle)" } else { "" }
            );
            if !cycle {
                path.push(m.name.clone());
                tree(&m.deps, store, &format!("{prefix}{}", if last { "    " } else { "│   " }), path, line)?;
                path.pop();
            }
        }
        Ok(())
    }
    tree(&root.deps, &store, "", &mut vec![root.name.clone()], &line)
}

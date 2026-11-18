//! Modules and names: builds the module tree of a program and answers path questions.
//!
//! A program is a set of packages, each a tree of modules (one module per file):
//! - the **root package**: the file given on the command line is its root module. If the file is
//!   inside a project (the nearest `raft.toml` above it), the project's `src/**/*.auk` files are
//!   its other modules (`src/geo/shapes.auk` is `geo.shapes`), and the manifest's `[deps]` are
//!   its dependencies. A standalone file gets core only.
//! - each **dependency** `d`: installed at `<project>/.raft/d/`; its root module is
//!   `src/lib.auk` and `src/x.auk` is `d.x`. Its own `[deps]` are found in the same `.raft/`
//!   (raft installs the whole tree flat).
//! - **core**: the prelude compiled into the compiler (`src/prelude/*.auk`): the root `core`
//!   module, always in scope, plus the modules `fs net time rand env proc audio_out gui pixels str int float ffi`.
//!
//! Paths (spec "Modules, packages"): a path's first segment names, in this order, a top-level
//! module of the current package, the current package itself (its root), a dependency, or a
//! core module. `m.` is always a path when `m` names one of those, except that a local value
//! shadows a core module name (`env.get(k)` with a parameter `env`; `Checker::expr_path`), and a
//! local named like any other module is an error (E0116). A local module with the same name as a
//! dependency is an error (E0101).
//!
//! Name lookup *inside* a module (locals, items, core, variants, overloads) is done by the checker
//! on top of the item tables it builds; see check.rs.

use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::path::{Path, PathBuf};

use super::ast;
use super::diag::{Diag, FileDiag, Span};
use super::parser;

pub type ModId = usize;
pub type PkgId = usize;

/// The core prelude, compiled in: (module name, source). The first is the root `core` module.
pub const PRELUDE: &[(&str, &str)] = &[
    ("core", include_str!("prelude/core.auk")),
    ("fs", include_str!("prelude/fs.auk")),
    ("net", include_str!("prelude/net.auk")),
    ("time", include_str!("prelude/time.auk")),
    ("rand", include_str!("prelude/rand.auk")),
    ("env", include_str!("prelude/env.auk")),
    ("proc", include_str!("prelude/proc.auk")),
    ("audio_out", include_str!("prelude/audio_out.auk")),
    ("gui", include_str!("prelude/gui.auk")),
    ("pixels", include_str!("prelude/pixels.auk")),
    ("str", include_str!("prelude/str.auk")),
    ("int", include_str!("prelude/int.auk")),
    ("float", include_str!("prelude/float.auk")),
    ("ffi", include_str!("prelude/ffi.auk")),
];

thread_local! {
    /// In-memory file texts that stand in for files on disk (`with_sources`), keyed by the
    /// file's name as it appears in `Module::file`.
    static OVERRIDES: RefCell<HashMap<String, String>> = RefCell::new(HashMap::new());
}

/// Run `f` with the given files' texts replacing what is on disk, for loading (and so checking
/// and building) a program whose edits haven't been written yet (`auk hatch`). Keys are file
/// names as they appear in `Module::file`.
pub fn with_sources<R>(srcs: &HashMap<String, String>, f: impl FnOnce() -> R) -> R {
    let old = OVERRIDES.with(|o| std::mem::replace(&mut *o.borrow_mut(), srcs.clone()));
    let r = f();
    OVERRIDES.with(|o| *o.borrow_mut() = old);
    r
}

/// Read a module's file, honoring `with_sources`.
fn read_file(path: &Path) -> std::io::Result<String> {
    if let Some(s) = OVERRIDES.with(|o| o.borrow().get(&path.display().to_string()).cloned()) {
        return Ok(s);
    }
    fs::read_to_string(path)
}

/// The text of a file named in a diagnostic (a prelude file or a file on disk).
pub fn source_of(file: &str) -> Option<String> {
    if let Some(name) = file.strip_prefix("<prelude>/").and_then(|f| f.strip_suffix(".auk")) {
        return PRELUDE.iter().find(|(n, _)| *n == name).map(|(_, s)| s.to_string());
    }
    read_file(Path::new(file)).ok()
}

#[derive(Debug)]
pub struct Package {
    pub name: String,
    /// The project directory (with `raft.toml`), if any.
    pub dir: Option<PathBuf>,
    pub root: ModId,
    /// Direct dependencies by name.
    pub deps: BTreeMap<String, PkgId>,
    /// `[package] effects` from the manifest (the ceiling that effects.rs enforces).
    #[allow(dead_code)]
    pub effects: Vec<String>,
    /// `[link] libs` from the manifest: C libraries its `extern fn`s need (ffi-plan.md §4).
    pub links: Vec<String>,
    pub is_core: bool,
}

#[derive(Debug)]
pub struct Module {
    pub pkg: PkgId,
    /// The full path: `["http", "uri"]`, `["core", "fs"]`; the root module of a standalone file
    /// is `[<file stem>]`.
    pub path: Vec<String>,
    /// The file as given (for diagnostics); `<prelude>/x.auk` for core, empty for a folder
    /// without its own file.
    pub file: String,
    pub src: String,
    pub ast: ast::Module,
    pub children: BTreeMap<String, ModId>,
}

#[derive(Debug)]
pub struct Program {
    pub pkgs: Vec<Package>,
    pub mods: Vec<Module>,
    /// The root module (the file given on the command line).
    pub root: ModId,
    /// The module being looked at: `root`, except from `load_in_package`, where it is the
    /// submodule whose file was given (and `root` is its package's `lib.auk`/`main.auk`).
    pub focus: ModId,
    pub core_pkg: PkgId,
    pub core_root: ModId,
}

impl Program {
    pub fn name(&self, m: ModId) -> String {
        self.mods[m].path.join(".")
    }

    pub fn is_core(&self, m: ModId) -> bool {
        self.mods[m].pkg == self.core_pkg
    }

    pub fn child(&self, m: ModId, name: &str) -> Option<ModId> {
        self.mods[m].children.get(name).copied()
    }

    /// What a path's first segment `name` means in module `m`, if it names a module.
    pub fn first_segment(&self, m: ModId, name: &str) -> Option<ModId> {
        let pkg = &self.pkgs[self.mods[m].pkg];
        if let Some(c) = self.child(pkg.root, name) {
            return Some(c);
        }
        if !pkg.is_core && pkg.dir.is_some() && pkg.name == name {
            return Some(pkg.root);
        }
        if let Some(&d) = pkg.deps.get(name) {
            return Some(self.pkgs[d].root);
        }
        if name == "core" {
            return Some(self.core_root);
        }
        self.child(self.core_root, name)
    }
}

/// A `raft.toml`, as much as the compiler needs.
#[derive(Debug, Default, Clone)]
pub struct Manifest {
    pub name: String,
    pub deps: Vec<String>,
    pub effects: Vec<String>,
    /// `[link] libs`.
    pub links: Vec<String>,
}

/// Read the `[package]` name and effects, the `[deps]` names and `[link] libs`. (raft validates manifests
/// fully; the compiler only needs these keys.)
pub fn parse_manifest(text: &str) -> Manifest {
    let mut m = Manifest::default();
    let mut section = String::new();
    for raw in text.lines() {
        let line = strip_comment(raw).trim();
        if line.is_empty() {
            continue;
        }
        if line.starts_with('[') {
            section = line.trim_matches(|c| c == '[' || c == ']').trim().to_string();
            continue;
        }
        let Some((key, val)) = line.split_once('=') else { continue };
        let (key, val) = (key.trim().trim_matches('"'), val.trim());
        match (section.as_str(), key) {
            ("package", "name") => m.name = val.trim_matches('"').to_string(),
            ("package", "effects") => m.effects = str_list(val),
            ("link", "libs") => m.links = str_list(val),
            ("deps", _) => m.deps.push(key.to_string()),
            _ => {}
        }
    }
    m
}

fn str_list(val: &str) -> Vec<String> {
    val.trim_matches(|c| c == '[' || c == ']').split(',').map(|s| s.trim().trim_matches('"').to_string()).filter(|s| !s.is_empty()).collect()
}

fn strip_comment(line: &str) -> &str {
    let mut in_str = false;
    for (i, c) in line.char_indices() {
        match c {
            '"' => in_str = !in_str,
            '#' if !in_str => return &line[..i],
            _ => {}
        }
    }
    line
}

/// The nearest directory at or above `dir` that has a `raft.toml`.
pub fn find_project(dir: &Path) -> Option<PathBuf> {
    let mut d = Some(dir);
    while let Some(x) = d {
        if x.join("raft.toml").is_file() {
            return Some(x.to_path_buf());
        }
        d = x.parent();
    }
    None
}

struct Loader {
    pkgs: Vec<Package>,
    mods: Vec<Module>,
    errs: Vec<FileDiag>,
    /// Installed dependencies already loaded, by name.
    loaded: BTreeMap<String, PkgId>,
    /// `<project>/.raft`, where every dependency of the program is installed.
    raft_dir: Option<PathBuf>,
}

fn err_at(file: &str, code: &'static str, msg: String) -> FileDiag {
    FileDiag { file: file.to_string(), diag: Diag::new(code, Span { line: 1, col: 1, end_line: 1, end_col: 1 }, msg) }
}

impl Loader {
    fn add_module(&mut self, pkg: PkgId, path: Vec<String>, file: String, src: String, prelude: bool) -> ModId {
        let parsed = if prelude { parser::parse_prelude(&src) } else { parser::parse(&src) };
        let ast = match parsed {
            Ok(m) => m,
            Err(ds) => {
                self.errs.extend(ds.into_iter().map(|diag| FileDiag { file: file.clone(), diag }));
                ast::Module { doc: None, items: Vec::new() }
            }
        };
        let id = self.mods.len();
        self.mods.push(Module { pkg, path, file, src, ast, children: BTreeMap::new() });
        id
    }

    /// An empty module standing for a folder with no file of its own.
    fn folder_module(&mut self, pkg: PkgId, path: Vec<String>) -> ModId {
        let id = self.mods.len();
        self.mods.push(Module {
            pkg,
            path,
            file: String::new(),
            src: String::new(),
            ast: ast::Module { doc: None, items: Vec::new() },
            children: BTreeMap::new(),
        });
        id
    }

    fn load_core(&mut self) -> PkgId {
        let pkg = self.pkgs.len();
        self.pkgs.push(Package { name: "core".into(), dir: None, root: 0, deps: BTreeMap::new(), effects: Vec::new(), links: Vec::new(), is_core: true });
        let mut root = None;
        for (name, src) in PRELUDE {
            let path = if *name == "core" { vec!["core".to_string()] } else { vec!["core".to_string(), name.to_string()] };
            let m = self.add_module(pkg, path, format!("<prelude>/{name}.auk"), src.to_string(), true);
            match root {
                None => root = Some(m),
                Some(r) => {
                    self.mods[r].children.insert(name.to_string(), m);
                }
            }
        }
        self.pkgs[pkg].root = root.unwrap();
        pkg
    }

    /// Add `src/**/*.auk` under `src_dir` as submodules of `root` (skipping `skip`, and the
    /// package roots `lib.auk` / `main.auk` at the top).
    fn add_tree(&mut self, pkg: PkgId, root: ModId, src_dir: &Path, skip: Option<&Path>) {
        let mut files = Vec::new();
        collect_auk_files(src_dir, &mut files);
        files.sort();
        for f in files {
            if skip.is_some_and(|s| same_file(s, &f)) {
                continue;
            }
            let Ok(rel) = f.strip_prefix(src_dir) else { continue };
            let mut segs: Vec<String> = rel.iter().map(|s| s.to_string_lossy().to_string()).collect();
            let last = segs.pop().unwrap();
            let stem = last.trim_end_matches(".auk").to_string();
            if segs.is_empty() && (stem == "lib" || stem == "main") {
                continue;
            }
            segs.push(stem);
            let mut parent = root;
            for (i, seg) in segs.iter().enumerate() {
                let mut path = self.mods[root].path.clone();
                path.extend(segs[..=i].iter().cloned());
                let is_last = i + 1 == segs.len();
                let existing = self.mods[parent].children.get(seg).copied();
                let m = match (existing, is_last) {
                    (Some(m), false) => m,
                    (Some(m), true) => {
                        // a folder module created earlier for `seg/...` gets its file now
                        let src = read_file(&f).unwrap_or_default();
                        let file = f.display().to_string();
                        match parser::parse(&src) {
                            Ok(a) => self.mods[m].ast = a,
                            Err(ds) => self.errs.extend(ds.into_iter().map(|diag| FileDiag { file: file.clone(), diag })),
                        }
                        self.mods[m].file = file;
                        self.mods[m].src = src;
                        m
                    }
                    (None, false) => self.folder_module(pkg, path),
                    (None, true) => match read_file(&f) {
                        Ok(src) => self.add_module(pkg, path, f.display().to_string(), src, false),
                        Err(e) => {
                            self.errs.push(err_at(&f.display().to_string(), "E0100", format!("cannot read {}: {e}", f.display())));
                            continue;
                        }
                    },
                };
                self.mods[parent].children.insert(seg.clone(), m);
                parent = m;
            }
        }
    }

    /// Load the installed package `name` (and its dependencies), once.
    fn load_dep(&mut self, name: &str, wanted_by: &str, from_file: &str) -> Option<PkgId> {
        if let Some(&p) = self.loaded.get(name) {
            return Some(p);
        }
        let dir = self.raft_dir.as_ref().map(|q| q.join(name));
        let Some(dir) = dir.filter(|d| d.join("src/lib.auk").is_file()) else {
            let where_ = self.raft_dir.as_ref().and_then(|q| q.parent()).map(|p| p.display().to_string()).unwrap_or_else(|| ".".into());
            self.errs.push(FileDiag {
                file: from_file.to_string(),
                diag: Diag::new(
                    "E0100",
                    Span { line: 1, col: 1, end_line: 1, end_col: 1 },
                    format!("dependency `{name}` of `{wanted_by}` is not installed"),
                )
                .note(format!("run `raft install` in {where_} (expected {name}/src/lib.auk under .raft/)")),
            });
            return None;
        };
        let manifest = fs::read_to_string(dir.join("raft.toml")).map(|t| parse_manifest(&t)).unwrap_or_default();
        let pkg = self.pkgs.len();
        self.pkgs.push(Package {
            name: name.to_string(),
            dir: Some(dir.clone()),
            root: 0,
            deps: BTreeMap::new(),
            effects: manifest.effects.clone(),
            links: manifest.links.clone(),
            is_core: false,
        });
        self.loaded.insert(name.to_string(), pkg);
        let lib = dir.join("src/lib.auk");
        let src = fs::read_to_string(&lib).unwrap_or_default();
        let root = self.add_module(pkg, vec![name.to_string()], lib.display().to_string(), src, false);
        self.pkgs[pkg].root = root;
        self.add_tree(pkg, root, &dir.join("src"), Some(&lib));
        let lib_file = lib.display().to_string();
        for d in &manifest.deps {
            if let Some(dp) = self.load_dep(d, name, &lib_file) {
                self.pkgs[pkg].deps.insert(d.clone(), dp);
            }
        }
        self.check_collisions(pkg);
        Some(pkg)
    }

    /// A top-level module of `pkg` named like one of its dependencies is an error.
    fn check_collisions(&mut self, pkg: PkgId) {
        let root = self.pkgs[pkg].root;
        for (name, &m) in &self.mods[root].children {
            if self.pkgs[pkg].deps.contains_key(name) {
                let file = if self.mods[m].file.is_empty() { self.mods[root].file.clone() } else { self.mods[m].file.clone() };
                self.errs.push(FileDiag {
                    file,
                    diag: Diag::new(
                        "E0101",
                        Span { line: 1, col: 1, end_line: 1, end_col: 1 },
                        format!("module `{}` has the same name as the dependency `{name}`", self.mods[m].path.join(".")),
                    )
                    .note(format!("`{name}.` would be ambiguous; rename the module (src/{name}.auk) or remove the dependency from raft.toml")),
                });
            }
        }
    }
}

fn collect_auk_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(rd) = fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let p = e.path();
        if p.is_dir() {
            collect_auk_files(&p, out);
        } else if p.extension().is_some_and(|x| x == "auk") {
            out.push(p);
        }
    }
}

fn same_file(a: &Path, b: &Path) -> bool {
    match (a.canonicalize(), b.canonicalize()) {
        (Ok(x), Ok(y)) => x == y,
        _ => a == b,
    }
}

/// Build the module tree for the program rooted at `path`. Parse errors and missing
/// dependencies are reported per file; on error the caller should not type-check.
pub fn load(path: &Path) -> Result<Program, Vec<FileDiag>> {
    let file = path.display().to_string();
    let src = read_file(path).map_err(|e| vec![err_at(&file, "E0100", format!("cannot read {file}: {e}"))])?;
    load_source(path, src)
}

/// Like `load`, with the root file's text given (used by tests and `check`).
pub fn load_source(path: &Path, src: String) -> Result<Program, Vec<FileDiag>> {
    let file = path.display().to_string();
    let mut l = Loader { pkgs: Vec::new(), mods: Vec::new(), errs: Vec::new(), loaded: BTreeMap::new(), raft_dir: None };
    let core_pkg = l.load_core();
    let core_root = l.pkgs[core_pkg].root;
    let abs = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
    let project = abs.parent().and_then(find_project);
    let manifest = project.as_ref().and_then(|p| fs::read_to_string(p.join("raft.toml")).ok()).map(|t| parse_manifest(&t));
    let stem = path.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_else(|| "main".into());
    let name = manifest.as_ref().map(|m| m.name.clone()).filter(|n| !n.is_empty()).unwrap_or(stem);
    let pkg = l.pkgs.len();
    l.pkgs.push(Package {
        name: name.clone(),
        dir: project.clone(),
        root: 0,
        deps: BTreeMap::new(),
        effects: manifest.as_ref().map(|m| m.effects.clone()).unwrap_or_default(),
        links: manifest.as_ref().map(|m| m.links.clone()).unwrap_or_default(),
        is_core: false,
    });
    let root = l.add_module(pkg, vec![name.clone()], file.clone(), src, false);
    l.pkgs[pkg].root = root;
    if let (Some(dir), Some(m)) = (&project, &manifest) {
        l.raft_dir = Some(dir.join(".raft"));
        l.add_tree(pkg, root, &dir.join("src"), Some(&abs));
        for d in &m.deps {
            if let Some(dp) = l.load_dep(d, &name, &file) {
                l.pkgs[pkg].deps.insert(d.clone(), dp);
            }
        }
        l.check_collisions(pkg);
    }
    if !l.errs.is_empty() {
        return Err(l.errs);
    }
    Ok(Program { pkgs: l.pkgs, mods: l.mods, root, focus: root, core_pkg, core_root })
}

/// Like `load_source`, for looking at one file of a project (`auk check`, the language server):
/// a project file other than the package root (`src/wav.auk`) is checked as the module it is
/// (`audio.wav`), in the program rooted at the project's `src/lib.auk` or `src/main.auk`, so
/// paths through the package root (`audio.Fmt`) resolve. `Program::focus` is that module.
pub fn load_in_package(path: &Path, src: String) -> Result<Program, Vec<FileDiag>> {
    let abs = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
    let root_file = abs.parent().and_then(find_project).and_then(|proj| {
        let src_dir = proj.join("src");
        if !abs.starts_with(&src_dir) {
            return None;
        }
        let root = ["lib.auk", "main.auk"].iter().map(|f| src_dir.join(f)).find(|f| f.is_file())?;
        (!same_file(&root, &abs)).then_some(root)
    });
    let Some(root_file) = root_file else { return load_source(path, src) };
    let key = abs.display().to_string();
    let mut srcs = OVERRIDES.with(|o| o.borrow().clone());
    srcs.insert(key.clone(), src);
    let mut prog = with_sources(&srcs, || load(&root_file))?;
    if let Some(m) = prog.mods.iter().position(|m| m.file == key) {
        prog.focus = m;
    }
    Ok(prog)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manifest_keys() {
        let m = parse_manifest(
            "[package]\nname = \"web\" # c\nversion = \"0.1.0\"\neffects = [\"net\", \"fs\"]\n\n[deps]\nhttp = \"^0.1\"\ngeo = { path = \"../geo\" }\n",
        );
        assert_eq!(m.name, "web");
        assert_eq!(m.effects, ["net", "fs"]);
        assert_eq!(m.deps, ["http", "geo"]);
    }

    /// Every prelude extern that touches the outside world declares its effect: the externs of
    /// the effect's own module, and any extern (in any module) bound to one of its runtime symbols.
    #[test]
    fn prelude_externs_declare_their_effects() {
        const EFFECTS: &[(&str, &[&str])] = &[
            ("fs", &["auk_fs_"]),
            ("net", &["auk_net_", "auk_conn_", "auk_listener_"]),
            ("time", &["auk_time_"]),
            ("rand", &["auk_rand_"]),
            ("env", &["auk_env_"]),
            ("proc", &["auk_proc_"]),
            ("audio_out", &["auk_audio_out_"]),
            ("gui", &["auk_gui_"]),
        ];
        let mut checked = 0;
        for (module, src) in PRELUDE {
            let m = parser::parse_prelude(src).unwrap();
            for item in &m.items {
                let ast::Item::Fn(g) = item else { continue };
                for c in &g.clauses {
                    let Some(ast::FnBody::Extern(sym)) = &c.body else { continue };
                    for (effect, prefixes) in EFFECTS {
                        if module == effect || prefixes.iter().any(|p| sym.starts_with(p)) {
                            checked += 1;
                            assert!(
                                c.uses.iter().any(|u| u.name == *effect),
                                "prelude `{module}.{}` (\"{sym}\") touches {effect} but doesn't declare `uses {effect}`",
                                g.name
                            );
                        }
                    }
                }
            }
        }
        assert!(checked >= 13, "only {checked} effectful externs found");
    }

    /// A prelude module's top `///` line, set off by a blank line, is the module doc and not the
    /// first function's.
    #[test]
    fn prelude_module_docs_stay_off_the_first_item() {
        for (name, src) in PRELUDE {
            let m = parser::parse_prelude(src).unwrap();
            assert!(m.doc.is_some(), "prelude {name} has no module doc");
            for item in &m.items {
                if let ast::Item::Fn(g) = item {
                    let doc = g.header.as_ref().and_then(|h| h.doc.clone()).or_else(|| g.clauses.iter().find_map(|c| c.doc.clone()));
                    assert!(doc.is_none() || doc != m.doc, "prelude {name}: `{}` has the module doc", g.name);
                }
            }
        }
        let doc = |module: &str, f: &str| {
            let src = PRELUDE.iter().find(|(n, _)| *n == module).unwrap().1;
            let m = parser::parse_prelude(src).unwrap();
            m.items.iter().find_map(|i| match i {
                ast::Item::Fn(g) if g.name == f => Some(g.clauses[0].doc.clone()),
                _ => None,
            })
        };
        assert_eq!(doc("fs", "read"), Some(None));
        assert_eq!(doc("rand", "int"), Some(Some("Uniform in `lo..=hi`.".to_string())));
        assert_eq!(doc("time", "now"), Some(Some("Milliseconds since the Unix epoch.".to_string())));
    }

    #[test]
    fn prelude_parses() {
        for (name, src) in PRELUDE {
            if let Err(ds) = parser::parse_prelude(src) {
                panic!("prelude {name}: {}", ds.iter().map(|d| d.render(name, src)).collect::<String>());
            }
        }
    }
}

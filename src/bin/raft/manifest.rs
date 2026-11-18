//! `raft.toml` and `raft.lock`: loading, validation, and in-place `[deps]` edits.

use super::semver::{Req, Version};
use super::toml::{self, Table, Value};
use super::{Error, Res, err};
use std::path::Path;

/// Effects a package may declare.
pub const EFFECTS: [&str; 9] = ["fs", "net", "time", "rand", "env", "proc", "audio_out", "gui", "ffi"];

/// Core module names, which no package may take.
const CORE: [&str; 16] = ["fs", "net", "time", "rand", "env", "proc", "audio_out", "gui", "pixels", "ffi", "str", "int", "float", "bool", "math", "core"];

/// A parsed `raft.toml`.
#[derive(Debug)]
pub struct Manifest {
    pub name: String,
    pub version: Version,
    pub effects: Vec<String>,
    pub deps: Vec<Dep>,
}

#[derive(Debug, Clone)]
pub struct Dep {
    pub name: String,
    pub src: DepSrc,
}

/// Where a dependency comes from.
#[derive(Debug, Clone)]
pub enum DepSrc {
    Registry(Req),
    /// A local package directory, relative to the manifest that names it.
    Path(String),
}

/// Why `name` is not a valid package name, if it isn't.
pub fn bad_name(name: &str) -> Option<String> {
    let ok = name.starts_with(|c: char| c.is_ascii_lowercase())
        && name.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_');
    if !ok {
        Some(format!("invalid package name `{name}`"))
    } else if CORE.contains(&name) {
        Some(format!("package name `{name}` collides with the core module `{name}`"))
    } else {
        None
    }
}

const NAME_HELP: &str = "names are lowercase `a-z0-9_`, start with a letter, and avoid core modules";

impl Manifest {
    /// Read and validate `<dir>/raft.toml`.
    pub fn load(dir: &Path) -> Res<Manifest> {
        let path = dir.join("raft.toml");
        let src = std::fs::read_to_string(&path).map_err(|e| err(format!("cannot read {}: {e}", path.display())))?;
        Manifest::parse(&src).map_err(|e| Error { msg: format!("{}: {}", path.display(), e.msg), ..e })
    }

    pub fn parse(src: &str) -> Res<Manifest> {
        let doc = toml::parse(src).map_err(err)?;
        let table = |name| doc.iter().find(|t| t.name == name && !t.array);
        let pkg = table("package").ok_or_else(|| err("missing [package] table"))?;
        let field =
            |key| pkg.get(key).and_then(Value::as_str).ok_or_else(|| err(format!("[package] needs a string `{key}`")));
        let name = field("name")?.to_string();
        if let Some(msg) = bad_name(&name) {
            return Err(err(msg).help(NAME_HELP));
        }
        let version = field("version")?;
        let version = Version::parse(version)
            .ok_or_else(|| err(format!("invalid version `{version}`")).help("use MAJOR.MINOR.PATCH, e.g. \"0.1.0\""))?;
        let effects = match pkg.get("effects") {
            None => Vec::new(),
            Some(v) => v.as_strs().ok_or_else(|| err("[package] effects must be an array of strings"))?,
        };
        if let Some(e) = effects.iter().find(|e| !EFFECTS.contains(&e.as_str())) {
            return Err(err(format!("unknown effect `{e}`")).help(format!("effects are {}", EFFECTS.join(" "))));
        }
        // [link] libs: C libraries for `extern fn` (the compiler loads or links them); `macos`
        // and `linux`: more, on that OS only
        if let Some(link) = table("link") {
            for (k, v) in &link.entries {
                if !matches!(k.as_str(), "libs" | "macos" | "linux") {
                    return Err(err(format!("unknown key `{k}` in [link]"))
                        .help("[link] has libs = [\"name\"], plus macos = [..] and linux = [..] for one OS's libraries"));
                }
                let libs = v.as_strs().ok_or_else(|| err(format!("[link] {k} must be an array of strings")))?;
                if let Some(l) = libs.iter().find(|l| l.is_empty() || l.chars().any(char::is_whitespace)) {
                    return Err(err(format!("invalid library name `{l}` in [link] {k}")).help("a library is named as in `-lname` (\"sqlite3\"), or by its path"));
                }
                if !libs.is_empty() && !effects.iter().any(|e| e == "ffi") {
                    return Err(err(format!("[link] {k} needs the `ffi` effect")).help("add \"ffi\" to effects under [package]"));
                }
            }
        }
        let mut deps = Vec::new();
        for (dep, v) in table("deps").map_or(&[][..], |t| &t.entries) {
            if let Some(msg) = bad_name(dep) {
                return Err(err(msg).help(NAME_HELP));
            }
            let src = match v {
                Value::Str(r) => DepSrc::Registry(Req::parse(r).ok_or_else(|| {
                    err(format!("invalid version requirement `{r}` for {dep}"))
                        .help("use \"^1.2\", \"~1.2.3\", \"=1.2.3\" or \"*\"")
                })?),
                Value::Table(es) => match es.as_slice() {
                    [(k, Value::Str(p))] if k == "path" => DepSrc::Path(p.clone()),
                    _ => {
                        return Err(err(format!("invalid dependency {dep}"))
                            .help(format!("write {dep} = {{ path = \"../{dep}\" }}")));
                    }
                },
                Value::List(_) => {
                    return Err(err(format!("invalid dependency {dep}"))
                        .help("use a version requirement string or { path = \"...\" }"));
                }
            };
            deps.push(Dep { name: dep.clone(), src });
        }
        Ok(Manifest { name, version, effects, deps })
    }
}

/// One `[[package]]` entry of `raft.lock`.
#[derive(Debug, Clone, PartialEq)]
pub struct Locked {
    pub name: String,
    pub version: String,
    /// `registry` or `path:<dir>`.
    pub source: String,
    pub effects: Vec<String>,
    pub checksum: String,
}

/// Read `raft.lock` (an absent file is an empty lock).
pub fn read_lock(path: &Path) -> Res<Vec<Locked>> {
    let Ok(src) = std::fs::read_to_string(path) else { return Ok(Vec::new()) };
    let bad = |msg: String| {
        err(format!("{}: {msg}", path.display())).help("delete raft.lock and run `raft install` to regenerate it")
    };
    let doc = toml::parse(&src).map_err(bad)?;
    let s = |t: &Table, k: &str| {
        t.get(k).and_then(Value::as_str).map(String::from).ok_or_else(|| bad(format!("[[package]] needs `{k}`")))
    };
    doc.iter()
        .filter(|t| t.name == "package" && t.array)
        .map(|t| {
            let effects =
                t.get("effects").and_then(Value::as_strs).ok_or_else(|| bad("[[package]] needs `effects`".into()))?;
            Ok(Locked {
                name: s(t, "name")?,
                version: s(t, "version")?,
                source: s(t, "source")?,
                effects,
                checksum: s(t, "checksum")?,
            })
        })
        .collect()
}

/// Render `raft.lock` (entries must already be sorted by name).
pub fn write_lock(pkgs: &[Locked]) -> String {
    let mut doc = vec![Table::new("", false)];
    for p in pkgs {
        let mut t = Table::new("package", true);
        let s = |x: &str| Value::Str(x.into());
        t.entries = vec![
            ("name".into(), s(&p.name)),
            ("version".into(), s(&p.version)),
            ("source".into(), s(&p.source)),
            ("effects".into(), Value::List(p.effects.iter().map(|e| s(e)).collect())),
            ("checksum".into(), s(&p.checksum)),
        ];
        doc.push(t);
    }
    format!("# Generated by raft. Do not edit; commit it.\n\n{}", toml::write(&doc))
}

/// Byte offset of a `#` comment in a line, ignoring `#` inside strings.
fn comment_start(line: &str) -> Option<usize> {
    let (mut in_str, mut esc) = (false, false);
    for (i, c) in line.char_indices() {
        match c {
            _ if esc => esc = false,
            '\\' if in_str => esc = true,
            '"' => in_str = !in_str,
            '#' if !in_str => return Some(i),
            _ => {}
        }
    }
    None
}

/// The key a `key = value` line defines, if any.
fn line_key(line: &str) -> Option<String> {
    let (k, _) = line.split_once('=')?;
    let k = k.trim();
    Some(k.strip_prefix('"').and_then(|k| k.strip_suffix('"')).unwrap_or(k).to_string())
}

/// Set (`Some(value)`) or remove (`None`) dependency `name` in the `[deps]` table of a manifest's
/// text, leaving every other line untouched. Returns `None` when removing a dependency that isn't there.
pub fn edit_deps(src: &str, name: &str, value: Option<&str>) -> Option<String> {
    let mut lines: Vec<String> = src.lines().map(String::from).collect();
    let header = |l: &str| l.trim_start().starts_with('[');
    let bare = |l: &str| l[..comment_start(l).unwrap_or(l.len())].trim().to_string();
    let entry = value.map(|v| format!("{name} = {v}"));
    match lines.iter().position(|l| bare(l) == "[deps]") {
        Some(start) => {
            let end = lines[start + 1..].iter().position(|l| header(l)).map_or(lines.len(), |i| start + 1 + i);
            let found = (start + 1..end).find(|&i| line_key(&bare(&lines[i])).as_deref() == Some(name));
            match (found, entry) {
                (Some(i), Some(entry)) => {
                    let comment =
                        comment_start(&lines[i]).map(|c| format!("   {}", &lines[i][c..])).unwrap_or_default();
                    lines[i] = entry + &comment;
                }
                (Some(i), None) => {
                    lines.remove(i);
                }
                (None, Some(entry)) => {
                    let last = (start..end).rev().find(|&i| !lines[i].trim().is_empty()).unwrap_or(start);
                    lines.insert(last + 1, entry);
                }
                (None, None) => return None,
            }
        }
        None => {
            let entry = entry?;
            if lines.last().is_some_and(|l| !l.trim().is_empty()) {
                lines.push(String::new());
            }
            lines.push("[deps]".into());
            lines.push(entry);
        }
    }
    Some(lines.join("\n") + "\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    const SRC: &str = "# my app\n[package]\nname = \"app\"\nversion = \"0.1.0\"\neffects = [] # pure\n\n[deps]\nb = \"^1.0\"  # keep me\n\n[extra]\nx = \"y\"\n";

    #[test]
    fn edits_preserve_the_rest() {
        let added = edit_deps(SRC, "a", Some("\"^1.2\"")).unwrap();
        assert_eq!(added, SRC.replace("# keep me\n", "# keep me\na = \"^1.2\"\n"));
        let updated = edit_deps(&added, "b", Some("\"^2.0\"")).unwrap();
        assert!(updated.contains("b = \"^2.0\"   # keep me\na = \"^1.2\"\n"), "{updated}");
        let removed = edit_deps(&added, "a", None).unwrap();
        assert_eq!(removed, SRC);
        assert_eq!(edit_deps(SRC, "zzz", None), None);
        let no_deps = "[package]\nname = \"app\"\nversion = \"0.1.0\"";
        assert_eq!(edit_deps(no_deps, "a", Some("\"*\"")).unwrap(), format!("{no_deps}\n\n[deps]\na = \"*\"\n"));
    }

    #[test]
    fn manifest_validation() {
        let m = Manifest::parse(SRC).unwrap();
        assert_eq!((m.name.as_str(), m.deps.len()), ("app", 1));
        let bad = |s: &str| Manifest::parse(s).unwrap_err().msg;
        assert_eq!(bad("[package]\nname = \"Net\"\nversion = \"0.1.0\""), "invalid package name `Net`");
        assert_eq!(
            bad("[package]\nname = \"net\"\nversion = \"0.1.0\""),
            "package name `net` collides with the core module `net`"
        );
        assert_eq!(bad("[package]\nname = \"a\"\nversion = \"0.1\""), "invalid version `0.1`");
        assert_eq!(bad("[package]\nname = \"a\"\nversion = \"0.1.0\"\neffects = [\"gpu\"]"), "unknown effect `gpu`");
        assert_eq!(
            bad("[package]\nname = \"a\"\nversion = \"0.1.0\"\n[deps]\nb = \">1\""),
            "invalid version requirement `>1` for b"
        );
        let ffi = "[package]\nname = \"a\"\nversion = \"0.1.0\"\neffects = [\"ffi\"]\n[link]\n";
        assert!(Manifest::parse(&format!("{ffi}libs = [\"sqlite3\", \"/opt/x/libz.dylib\"]")).is_ok());
        assert_eq!(bad(&format!("{ffi}libs = \"z\"")), "[link] libs must be an array of strings");
        assert_eq!(bad(&format!("{ffi}libs = [\"\"]")), "invalid library name `` in [link] libs");
        assert!(Manifest::parse(&format!("{ffi}macos = [\"/opt/x/libz.dylib\"]\nlinux = [\"z\"]")).is_ok());
        assert_eq!(bad(&format!("{ffi}linux = \"z\"")), "[link] linux must be an array of strings");
        assert_eq!(bad(&format!("{ffi}windows = []")), "unknown key `windows` in [link]");
        assert_eq!(bad(&format!("{ffi}dirs = []")), "unknown key `dirs` in [link]");
        assert_eq!(bad("[package]\nname = \"a\"\nversion = \"0.1.0\"\n[link]\nlibs = [\"z\"]"), "[link] libs needs the `ffi` effect");
    }

    #[test]
    fn lock_round_trip() {
        let pkgs = vec![Locked {
            name: "a".into(),
            version: "1.2.0".into(),
            source: "registry".into(),
            effects: vec!["net".into()],
            checksum: "sha256:00".into(),
        }];
        let dir = std::env::temp_dir().join(format!("raft-lock-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("raft.lock"), write_lock(&pkgs)).unwrap();
        assert_eq!(read_lock(&dir.join("raft.lock")).unwrap(), pkgs);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}

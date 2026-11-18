//! The error catalogue: every registered code has a page in docs/errors/, every page's wrong
//! example produces exactly its code and its fixed example checks clean (run through the real
//! binary), and `auk explain` renders, lists and suggests.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicUsize, Ordering};

/// Codes whose wrong example can't produce them from user code (the page explains why).
/// E0114: only an `extern` in the core prelude can name an intrinsic (a user `extern fn`'s
/// string is a C prototype).
const UNREACHABLE: &[&str] = &["E0114"];

/// Codes below E0100 that `auk check` reports, not the parser: they need the manifest (E0036,
/// the `ffi` effect) or the types (E0040, C prototypes).
const CHECKED: &[&str] = &["E0036", "E0040"];

/// Codes reported while building, not by `auk check`: E0420 (an imprint panicked while it was
/// computed at compile time). Their wrong example checks clean and fails `auk ir` with the
/// code; their fixed example also builds.
const BUILD_TIME: &[&str] = &["E0420"];

fn auk(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_auk")).args(args).output().unwrap()
}

fn text(b: &[u8]) -> String {
    String::from_utf8_lossy(b).to_string()
}

/// (code, title) for every registered code, from `auk explain`'s listing.
fn codes() -> Vec<(String, String)> {
    let out = auk(&["explain"]);
    assert!(out.status.success());
    let codes: Vec<(String, String)> = text(&out.stdout)
        .lines()
        .filter_map(|l| l.strip_prefix("  "))
        .filter_map(|l| l.split_once("  "))
        .map(|(c, t)| (c.to_string(), t.to_string()))
        .collect();
    assert!(codes.len() >= 100, "{codes:?}");
    codes
}

fn page(code: &str) -> String {
    fs::read_to_string(format!("docs/errors/{code}.md")).unwrap_or_else(|e| panic!("docs/errors/{code}.md: {e}"))
}

/// A page section's fenced blocks: (path, source), where the path is empty for the main file.
type Files = Vec<(String, String)>;

/// The fenced blocks under each `## ` heading.
fn sections(md: &str) -> Vec<(String, Files)> {
    let mut secs: Vec<(String, Files)> = Vec::new();
    let mut block: Option<(String, String)> = None;
    for line in md.lines() {
        if let Some((path, src)) = &mut block {
            if line.starts_with("```") {
                let b = (path.clone(), src.clone());
                secs.last_mut().expect("a code block before any section").1.push(b);
                block = None;
            } else {
                src.push_str(line);
                src.push('\n');
            }
        } else if let Some(h) = line.strip_prefix("## ") {
            secs.push((h.to_string(), Vec::new()));
        } else if let Some(info) = line.strip_prefix("```") {
            let path = info.split_whitespace().nth(1).unwrap_or("").to_string();
            block = Some((path, String::new()));
        }
    }
    assert!(block.is_none(), "unclosed code block");
    secs
}

fn section<'a>(secs: &'a [(String, Files)], name: &str) -> &'a Files {
    &secs.iter().find(|(h, _)| h == name).unwrap_or_else(|| panic!("no `## {name}` section")).1
}

/// Write `files` to a fresh directory and return the main file: `t.auk` for a lone file, or
/// `src/main.auk` of a project when any block names a path (raft.toml, other modules, ...).
fn materialize(files: &Files) -> (PathBuf, PathBuf) {
    static N: AtomicUsize = AtomicUsize::new(0);
    let dir = std::env::temp_dir().join(format!("auk-explain-{}-{}", std::process::id(), N.fetch_add(1, Ordering::SeqCst)));
    let _ = fs::remove_dir_all(&dir);
    let project = files.iter().any(|(p, _)| !p.is_empty());
    let main = dir.join(if project { "src/main.auk" } else { "t.auk" });
    for (p, src) in files {
        let path = if p.is_empty() { main.clone() } else { dir.join(p) };
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, src).unwrap();
    }
    (dir, main)
}

/// The diagnostic codes of a `--json` report, in order.
fn json_codes(json: &str) -> Vec<String> {
    json.split(r#""code":""#).skip(1).map(|s| s[..5].to_string()).collect()
}

/// The diagnostic codes `auk ir` (which builds, computing the imprints) reports on the files,
/// and its stderr.
fn build_codes(files: &Files) -> (Vec<String>, String) {
    let (dir, main) = materialize(files);
    let out = auk(&["ir", main.to_str().unwrap()]);
    let _ = fs::remove_dir_all(&dir);
    let err = text(&out.stderr);
    let codes = err.split("error[").skip(1).map(|s| s[..5].to_string()).collect();
    (codes, err)
}

/// Run `auk parse --json` (lexing and parsing codes) or `auk check --json` on the files.
fn diagnose(files: &Files, parse: bool) -> (Vec<String>, String) {
    let (dir, main) = materialize(files);
    let m = main.to_str().unwrap();
    let out = if parse { auk(&["parse", "--json", m]) } else { auk(&["check", m, "--json"]) };
    let _ = fs::remove_dir_all(&dir);
    let json = text(&out.stdout);
    (json_codes(&json), format!("{json}{}", text(&out.stderr)))
}

#[test]
fn every_code_has_a_page() {
    let codes = codes();
    let mut bad = Vec::new();
    for (code, title) in &codes {
        let md = page(code);
        let secs = sections(&md);
        let heads: Vec<&str> = secs.iter().map(|(h, _)| h.as_str()).collect();
        if !md.starts_with(&format!("# {code}: {title}\n")) {
            bad.push(format!("{code}: must start with `# {code}: {title}`"));
        }
        if heads != ["Wrong", "Fixed", "Common causes"] {
            bad.push(format!("{code}: sections are {heads:?}"));
        }
        if !md.split("## Common causes").nth(1).is_some_and(|c| c.contains("\n- ")) {
            bad.push(format!("{code}: no common causes listed"));
        }
        if md.lines().count() > 45 {
            bad.push(format!("{code}: {} lines (keep it under about 40)", md.lines().count()));
        }
    }
    // no stray pages
    for e in fs::read_dir("docs/errors").unwrap() {
        let name = e.unwrap().file_name().to_string_lossy().to_string();
        let code = name.trim_end_matches(".md");
        if !codes.iter().any(|(c, _)| c == code) {
            bad.push(format!("docs/errors/{name} is not a registered code"));
        }
    }
    assert!(bad.is_empty(), "{}", bad.join("\n"));
}

/// Each wrong example produces exactly its code (E00xx through `auk parse`, the rest through
/// `auk check`); each fixed example (the wrong one's files, with the fixed blocks replacing or
/// adding files) checks with no diagnostics at all.
#[test]
fn examples_trigger_their_code_and_fixes_check_clean() {
    let codes = codes();
    let mut bad = Vec::new();
    for (code, _) in &codes {
        let secs = sections(&page(code));
        let wrong = section(&secs, "Wrong").clone();
        let mut fixed = wrong.clone();
        for (p, src) in section(&secs, "Fixed") {
            match fixed.iter_mut().find(|(q, _)| q == p) {
                Some(f) => f.1 = src.clone(),
                None => fixed.push((p.clone(), src.clone())),
            }
        }
        assert!(wrong.iter().any(|(p, _)| p.is_empty()), "{code}: the wrong example has no main block");

        let (got, out) = diagnose(&wrong, code.as_str() < "E0100" && !CHECKED.contains(&code.as_str()));
        let want = vec![code.clone()];
        if BUILD_TIME.contains(&code.as_str()) {
            if !got.is_empty() {
                bad.push(format!("{code}: `auk check` on the wrong example gives {got:?}, want none:\n{out}"));
            }
            let (got, err) = build_codes(&wrong);
            if got != want {
                bad.push(format!("{code}: building the wrong example gives {got:?}, want {want:?}:\n{err}"));
            }
            let (got, err) = build_codes(&fixed);
            if !got.is_empty() {
                bad.push(format!("{code}: building the fixed example gives {got:?}:\n{err}"));
            }
        } else if UNREACHABLE.contains(&code.as_str()) {
            if got.contains(code) {
                bad.push(format!("{code} is listed as unreachable but its example produces it; remove it from UNREACHABLE"));
            }
        } else if got != want {
            bad.push(format!("{code}: the wrong example gives {got:?}, want {want:?}:\n{out}"));
        }

        let (got, out) = diagnose(&fixed, false);
        if !got.is_empty() || !out.contains(r#""ok":true"#) {
            bad.push(format!("{code}: the fixed example gives {got:?}:\n{out}"));
        }
    }
    assert!(bad.is_empty(), "{} problem(s):\n{}", bad.len(), bad.join("\n"));
}

#[test]
fn explain_renders_a_page() {
    let out = auk(&["explain", "E0400"]);
    assert!(out.status.success());
    let s = text(&out.stdout);
    assert!(s.starts_with("E0400: patterns don't cover every case\n======================================\n"), "{s}");
    assert!(s.contains("\nWrong\n-----\n\n    enum Shape {"), "{s}");
    assert!(s.contains("\n      Circle(r) => 3.14 * r * r\n"), "{s}");
    assert!(s.contains("\nCommon causes\n-------------\n"), "{s}");
    assert!(!s.contains("```") && !s.contains("## "), "{s}");
    // codes are accepted in any case and without the leading zeros
    for alias in ["e0400", "400", "0400"] {
        assert_eq!(text(&auk(&["explain", alias]).stdout), s, "{alias}");
    }
    // a project page shows each extra file's path
    let s = text(&auk(&["explain", "E0413"]).stdout);
    assert!(s.contains("    # raft.toml\n    [package]\n"), "{s}");
}

#[test]
fn explain_lists_every_code() {
    let out = auk(&["explain"]);
    assert!(out.status.success());
    let s = text(&out.stdout);
    assert!(s.contains("  E0011  semicolons are not used\n"), "{s}");
    assert!(s.contains("  E0415  "), "{s}");
    assert_eq!(s.lines().filter(|l| l.starts_with("  E0")).count(), codes().len());
}

#[test]
fn explain_unknown_code_suggests_closest() {
    let out = auk(&["explain", "E0206"]);
    assert_eq!(out.status.code(), Some(1));
    let e = text(&out.stderr);
    assert!(e.starts_with("error: `E0206` is not an Auk error code\n"), "{e}");
    assert!(e.contains("E0205") && e.contains("E0207"), "{e}");
    assert!(e.contains("auk explain"), "{e}");
    // a word searches the titles
    let e = text(&auk(&["explain", "semicolons"]).stderr);
    assert!(e.contains("E0011  semicolons are not used"), "{e}");
    assert_eq!(auk(&["explain", "E0001", "E0002"]).status.code(), Some(2));
}

#[test]
fn diagnostics_point_to_explain() {
    let dir = std::env::temp_dir().join(format!("auk-explain-help-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let path = dir.join("t.auk");
    fs::write(&path, "fn label(n: int): str = n\n").unwrap();
    let p = path.to_str().unwrap();
    let err = text(&auk(&["check", p]).stderr);
    assert!(err.ends_with("  = help: run `auk explain E0200` for details\n"), "{err}");
    let json = text(&auk(&["check", p, "--json"]).stdout);
    assert!(json.contains(r#""explain":"auk explain E0200"}"#), "{json}");
    fs::write(&path, "fn main() {\n  let x = 1;\n}\n").unwrap();
    let err = text(&auk(&["parse", p]).stderr);
    assert!(err.ends_with("  = help: run `auk explain E0011` for details\n"), "{err}");
    let _ = fs::remove_dir_all(&dir);
    assert!(Path::new("docs/errors/E0200.md").is_file());
}

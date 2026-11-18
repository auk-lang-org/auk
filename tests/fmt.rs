//! `auk fmt` over every corpus file (`examples/*.auk` plus `packages/*/src/*.auk`): the
//! output parses, the AST is unchanged, formatting is idempotent, no comment is lost, and the
//! corpus itself is already in canonical form.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};

fn auk(args: &[&str], stdin: Option<&str>) -> Output {
    let mut child = Command::new(env!("CARGO_BIN_EXE_auk"))
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let input = stdin.unwrap_or("").to_string();
    let mut pipe = child.stdin.take().unwrap();
    let writer = std::thread::spawn(move || pipe.write_all(input.as_bytes()));
    let out = child.wait_with_output().unwrap();
    writer.join().unwrap().unwrap();
    out
}

fn auk_files(dir: &Path) -> Vec<PathBuf> {
    let mut paths: Vec<_> = fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|e| e == "auk"))
        .collect();
    paths.sort();
    paths
}

fn corpus() -> Vec<PathBuf> {
    let mut files = auk_files(Path::new("examples"));
    let mut pkgs: Vec<_> = fs::read_dir("packages").unwrap().map(|e| e.unwrap().path().join("src")).filter(|p| p.is_dir()).collect();
    pkgs.sort();
    for p in pkgs {
        files.extend(auk_files(&p));
    }
    files
}

fn scratch(src: &str) -> PathBuf {
    static N: AtomicUsize = AtomicUsize::new(0);
    let n = N.fetch_add(1, Ordering::SeqCst);
    let path = std::env::temp_dir().join(format!("auk-fmt-{}-{n}.auk", std::process::id()));
    fs::write(&path, src).unwrap();
    path
}

/// `auk fmt -`: the formatted text.
fn format(src: &str, name: &str) -> String {
    let out = auk(&["fmt", "-"], Some(src));
    assert!(out.status.success(), "auk fmt failed on {name}:\n{}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8(out.stdout).unwrap()
}

/// `auk parse --ast` of a source text (spans and node ids are not in the dump).
fn ast(src: &str, name: &str) -> String {
    let path = scratch(src);
    let out = auk(&["parse", "--ast", path.to_str().unwrap()], None);
    let _ = fs::remove_file(&path);
    assert!(out.status.success(), "{name} does not parse:\n{}\n--- source ---\n{src}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8(out.stdout).unwrap()
}

/// The number of `//` and `/*` comments outside string and char literals.
fn count_comments(src: &str) -> usize {
    let cs: Vec<char> = src.chars().collect();
    let mut n = 0;
    code(&cs, &mut 0, &mut n, false);
    n
}

/// Scan code from `*i`, counting comments, up to the end (or the `}` closing an
/// interpolation, when `interp`).
fn code(cs: &[char], i: &mut usize, n: &mut usize, interp: bool) {
    let at = |k: usize| cs.get(k).copied();
    let mut depth = 0;
    while *i < cs.len() {
        let c = cs[*i];
        if c == '/' && at(*i + 1) == Some('/') {
            *n += 1;
            while *i < cs.len() && cs[*i] != '\n' {
                *i += 1;
            }
        } else if c == '/' && at(*i + 1) == Some('*') {
            *n += 1;
            let mut d = 0;
            loop {
                if at(*i) == Some('/') && at(*i + 1) == Some('*') {
                    d += 1;
                    *i += 2;
                } else if at(*i) == Some('*') && at(*i + 1) == Some('/') {
                    d -= 1;
                    *i += 2;
                    if d == 0 {
                        break;
                    }
                } else if *i >= cs.len() {
                    break;
                } else {
                    *i += 1;
                }
            }
        } else if c == '"' || (c == 'r' && at(*i + 1) == Some('"') && (*i == 0 || !(cs[*i - 1].is_alphanumeric() || cs[*i - 1] == '_'))) {
            string(cs, i, n);
        } else if c == '\'' {
            // a char literal: 'a', '\n', '\u{1F986}', '\''
            *i += 1;
            while *i < cs.len() && cs[*i] != '\'' {
                *i += if cs[*i] == '\\' { 2 } else { 1 };
            }
            *i += 1;
        } else {
            if interp {
                match c {
                    '{' => depth += 1,
                    '}' if depth == 0 => return,
                    '}' => depth -= 1,
                    _ => {}
                }
            }
            *i += 1;
        }
    }
}

/// Skip a string literal at `*i` (`"..."`, `"""..."""`, raw forms), scanning interpolations
/// as code.
fn string(cs: &[char], i: &mut usize, n: &mut usize) {
    let raw = cs[*i] == 'r';
    if raw {
        *i += 1;
    }
    let triple = cs[*i..].starts_with(&['"', '"', '"']);
    *i += if triple { 3 } else { 1 };
    while *i < cs.len() {
        let c = cs[*i];
        if triple && cs[*i..].starts_with(&['"', '"', '"']) {
            *i += 3;
            return;
        }
        if !triple && c == '"' {
            *i += 1;
            return;
        }
        if !raw && (c == '\\' || (c == '{' && cs.get(*i + 1) == Some(&'{'))) {
            // an escape or a literal `{{`
            *i += 2;
        } else if !raw && c == '{' {
            *i += 1;
            code(cs, i, n, true);
            *i += 1;
        } else {
            *i += 1;
        }
    }
}

#[test]
fn comment_counter() {
    assert_eq!(count_comments("// a\nfn f() = 1 /* b /* nested */ */\n/// doc"), 3);
    assert_eq!(count_comments(r#"let u = "http://x" + r"a//b" + '/'.str() + "{a["//"]}" // c"#), 1);
    assert_eq!(count_comments("let s = \"\"\"\n  // not a comment\n  \"\"\""), 0);
}

#[test]
fn corpus_formats_safely() {
    let files = corpus();
    assert!(files.len() >= 17, "corpus too small: {files:?}");
    let mut canonical = Vec::new();
    for f in &files {
        let name = f.display().to_string();
        let src = fs::read_to_string(f).unwrap();
        let once = format(&src, &name);
        // the output parses to the same AST
        assert_eq!(ast(&src, &name), ast(&once, &format!("{name} (formatted)")), "{name}: formatting changed the AST");
        // idempotent
        let twice = format(&once, &name);
        assert_eq!(once, twice, "{name}: formatting is not idempotent");
        // no comment lost or invented
        assert_eq!(count_comments(&src), count_comments(&once), "{name}: comment count changed");
        if once == src {
            canonical.push(name);
        }
    }
    println!("{} of {} corpus files are in canonical form", canonical.len(), files.len());
    // the corpus is kept fmt-clean
    assert_eq!(canonical.len(), files.len(), "not fmt-clean: run `auk fmt examples packages`");
}

#[test]
fn check_mode_and_files() {
    let ugly = "fn f( a:int ):int=a+1\n";
    let path = scratch(ugly);
    let p = path.to_str().unwrap();
    // --check lists the file, exits 1 and leaves it alone
    let out = auk(&["fmt", "--check", p], None);
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), p);
    assert_eq!(fs::read_to_string(&path).unwrap(), ugly);
    // fmt rewrites it in place; then --check is clean
    assert!(auk(&["fmt", p], None).status.success());
    assert_eq!(fs::read_to_string(&path).unwrap(), "fn f(a: int): int = a + 1\n");
    let out = auk(&["fmt", "--check", p], None);
    assert_eq!(out.status.code(), Some(0));
    assert!(out.stdout.is_empty());
    let _ = fs::remove_file(&path);
}

#[test]
fn parse_errors_leave_the_file_untouched() {
    let bad = "fn f() {\n  let x = 1;\n}\n";
    let path = scratch(bad);
    let out = auk(&["fmt", path.to_str().unwrap()], None);
    assert_eq!(out.status.code(), Some(1));
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains("E0011"), "expected the parse diagnostic, got:\n{err}");
    assert_eq!(fs::read_to_string(&path).unwrap(), bad);
    let _ = fs::remove_file(&path);
    // stdin too
    let out = auk(&["fmt", "-"], Some(bad));
    assert_eq!(out.status.code(), Some(1));
    assert!(out.stdout.is_empty());
}

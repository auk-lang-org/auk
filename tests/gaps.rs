//! Language gaps found by the self-hosting pilot (docs/pilot-report.md, self-host-plan 2d):
//! bare variants through `T?`/`T!`/`T!E`, or-patterns, `var` parameters in function types,
//! stack overflow reporting, and the small string/number helpers.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicUsize, Ordering};

fn auk(args: &[&str]) -> Output {
    let mut c = Command::new(env!("CARGO_BIN_EXE_auk"));
    c.env_remove("AUK_LEAK_CHECK");
    c.args(args).output().unwrap()
}

fn scratch() -> PathBuf {
    static N: AtomicUsize = AtomicUsize::new(0);
    let n = N.fetch_add(1, Ordering::SeqCst);
    let d = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("gaps").join(format!("{n}"));
    let _ = fs::remove_dir_all(&d);
    fs::create_dir_all(&d).unwrap();
    d
}

/// A project with `files` (path, source) under `src/`; returns the path of `src/main.auk`.
fn project(files: &[(&str, &str)]) -> PathBuf {
    let d = scratch();
    fs::write(d.join("raft.toml"), "[package]\nname = \"app\"\nversion = \"0.1.0\"\n").unwrap();
    fs::create_dir_all(d.join("src")).unwrap();
    for (p, s) in files {
        fs::write(d.join("src").join(p), s).unwrap();
    }
    d.join("src/main.auk")
}

fn file(src: &str) -> PathBuf {
    let p = scratch().join("t.auk");
    fs::write(&p, src).unwrap();
    p
}

fn s(p: &Path) -> &str {
    p.to_str().unwrap()
}

/// `auk run`: stdout, asserting success.
fn run_ok(p: &Path) -> String {
    let o = auk(&["run", s(p)]);
    let (out, err) = (String::from_utf8_lossy(&o.stdout).into_owned(), String::from_utf8_lossy(&o.stderr).into_owned());
    assert!(o.status.success(), "auk run failed:\n{out}\n{err}");
    out
}

/// `auk check`: stderr, asserting failure.
fn check_err(p: &Path) -> String {
    let o = auk(&["check", s(p)]);
    let err = String::from_utf8_lossy(&o.stderr).into_owned();
    assert!(!o.status.success(), "expected errors, got none");
    err
}

fn check_ok(p: &Path) {
    let o = auk(&["check", s(p)]);
    assert!(o.status.success(), "auk check failed:\n{}", String::from_utf8_lossy(&o.stderr));
}

// ---- 1. bare variants of another module's enum through `T?` / `T!` / `T!E` ----

const TOK: &str = "pub enum Tok { Fn, Float(f: float), Int(n: int), Eof }\npub enum Fail { Bad(m: str) }\n";

#[test]
fn bare_variants_resolve_through_optional_and_result() {
    let main = r#"
fn a(): tok.Tok? = Fn
fn b(): tok.Tok! = Float(1.5)
fn c(): tok.Tok!tok.Fail = Int(3)
fn d(x: bool): tok.Tok!tok.Fail = if x { Eof } else { fail(Bad("no")) }
fn e(x: int): tok.Tok!tok.Fail {
  if x > 0 { return Int(x) }
  match x { 0 => Fn, _ => Float(-1.0) }
}
fn f(): Value? = Int(7)
fn main() {
  let xs: [tok.Tok] = [Eof, Int(2)]
  print("{a()} {b()} {c()} {d(true)} {e(4)} {e(0)} {e(-1)} {f()} {xs}")
}
"#;
    let p = project(&[("tok.auk", TOK), ("main.auk", main)]);
    assert_eq!(run_ok(&p), "some(Fn) ok(Float(1.5)) ok(Int(3)) ok(Eof) ok(Int(4)) ok(Fn) ok(Float(-1.0)) some(7) [Eof, Int(2)]\n");
}

#[test]
fn value_variant_is_never_picked_against_the_expected_enum() {
    let p = project(&[("tok.auk", TOK), ("main.auk", "fn g(): tok.Tok = Str(\"x\")\nfn main() { print(g()) }\n")]);
    let err = check_err(&p);
    assert!(err.contains("error[E0117]: `Tok` has no variant `Str`"), "{err}");
    assert!(err.contains("write `Value.Str` for that"), "{err}");
}

#[test]
fn value_variant_without_expected_type_is_ambiguous() {
    let p = project(&[("tok.auk", TOK), ("main.auk", "fn main() {\n  let t = Float(1.5)\n  print(t)\n}\n")]);
    let err = check_err(&p);
    assert!(err.contains("error[E0117]: `Float` could be `tok.Float` (a `Tok`) or core's `Value.Float`"), "{err}");
    assert!(err.contains("fix: replace the text at 2:11 with `tok.Float`"), "{err}");
    // explicit forms are fine
    let p = project(&[("tok.auk", TOK), ("main.auk", "fn main() {\n  let t = tok.Float(1.5)\n  let v = Value.Float(2.0)\n  let w: Value = Int(3)\n  print(\"{t} {v} {w}\")\n}\n")]);
    assert_eq!(run_ok(&p), "Float(1.5) 2.0 3\n");
}

#[test]
fn value_variants_alone_still_work() {
    // no enum of this program has a variant `Int`: a bare `Int(..)` is core's `Value.Int`
    let p = file("fn main() {\n  let v = Int(3)\n  let w = List([Str(\"a\"), Null])\n  print(\"{v} {w}\")\n}\n");
    check_ok(&p);
}

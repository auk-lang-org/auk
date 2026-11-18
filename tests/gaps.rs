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

// ---- 2. or-patterns ----

/// `auk run` under the leak check: stdout, asserting success and no leaks.
fn run_leak_free(p: &Path) -> String {
    let mut c = Command::new(env!("CARGO_BIN_EXE_auk"));
    let o = c.args(["run", s(p)]).env("AUK_LEAK_CHECK", "1").output().unwrap();
    let (out, err) = (String::from_utf8_lossy(&o.stdout).into_owned(), String::from_utf8_lossy(&o.stderr).into_owned());
    assert!(o.status.success() && err.is_empty(), "auk run failed or leaked:\n{out}\n{err}");
    out
}

const OR_PROGRAM: &str = r#"enum Tok { LParen, RParen, LBracket, RBracket, Ident(s: str), Kw(s: str), Num(n: int), Eof }
enum Shape { Circle(r: float), Square(side: float), Rect(w: float, h: float), Dot }
struct P { name: str, age: int }

fn closes(t: Tok): bool = match t {
  RParen | RBracket => true
  _ => false
}

fn text(t: Tok): str = match t {
  Ident(s) | Kw(s) => s
  Num(n) => "{n}"
  LParen | RParen | LBracket |
    RBracket => "bracket"
  Eof => "eof"
}

fn size(s: Shape): float = match s {
  Circle(x) | Square(x) | Rect(x, _) => x
  Dot => 0.0
}

fn small(n: int): str = match n { 0 | 1 | 2 => "small", _ => "big" }

fn names(xs: [P]): str = match xs {
  [P { name, .. }] | [_, P { name, .. }] => name
  _ => "?"
}

fn list_rest(xs: [str]): [str] = match xs {
  ["a", ..rest] | ["b", ..rest] => rest
  _ => []
}

fn opt(x: int?): int = match x {
  some(0) | none => -1
  some(n) => n
}

fn guarded(t: Tok): str = match t {
  Ident(s) | Kw(s) when s.len() > 2 => "long {s}"
  _ => "other"
}

fn main() {
  print("{closes(RParen)} {closes(LParen)} {closes(RBracket)}")
  print("{text(Ident("x"))} {text(Kw("fn"))} {text(Num(3))} {text(LBracket)} {text(Eof)}")
  print("{size(Circle(1.0))} {size(Square(2.0))} {size(Rect(3.0, 4.0))} {size(Dot)}")
  print("{small(1)} {small(5)}")
  print(names([P { name: "ann", age: 1 }]))
  print(names([P { name: "ann", age: 1 }, P { name: "bob", age: 2 }]))
  print("{list_rest(["a", "x", "y"])} {list_rest(["b", "z"])} {list_rest(["c"])}")
  print("{opt(some(0))} {opt(none)} {opt(some(4))}")
  print("{guarded(Ident("abc"))} {guarded(Kw("ab"))} {guarded(Num(1))}")
}
"#;

#[test]
fn or_patterns_match_and_bind() {
    let p = file(OR_PROGRAM);
    assert_eq!(
        run_leak_free(&p),
        "true false true\nx fn 3 bracket eof\n1.0 2.0 3.0 0.0\nsmall big\nann\nbob\n[\"x\", \"y\"] [\"z\"] []\n-1 -1 4\nlong abc other other\n"
    );
}

#[test]
fn or_pattern_alternatives_bind_the_same_names() {
    let shape = "enum Shape { Circle(r: float), Square(side: float), Dot }\n";
    let err = check_err(&file(&format!("{shape}fn f(s: Shape): float = match s {{\n  Circle(r) | Square(side) => r\n  _ => 0.0\n}}\n")));
    assert!(err.contains("3:22: error[E0267]: `side` is bound here but not in the first alternative"), "{err}");
    assert_eq!(err.matches("error[").count(), 1, "{err}");
    let err = check_err(&file(&format!("{shape}fn f(s: Shape): float = match s {{\n  Circle(r) | Dot => r\n  _ => 0.0\n}}\n")));
    assert!(err.contains("error[E0267]: this alternative doesn't bind `r`"), "{err}");
    let err = check_err(&file("fn f(x: int, s: str): int = match (x, s) {\n  (1, n) | (n, \"a\") => 1\n  _ => 0\n}\n"));
    assert!(err.contains("2:13: error[E0267]: `n` is a `str` in the first alternative but an `int` here"), "{err}");
}

#[test]
fn or_patterns_in_exhaustiveness_and_reachability() {
    let shape = "enum Shape { Circle(r: float), Square(side: float), Rect(w: float, h: float), Dot }\n";
    // covering every variant through alternatives
    check_ok(&file(&format!("{shape}fn f(s: Shape): float = match s {{\n  Circle(r) | Rect(_, r) => r\n  Dot | Square(_) => 0.0\n}}\n")));
    let err = check_err(&file(&format!("{shape}fn f(s: Shape): int = match s {{\n  Circle(_) | Dot => 1\n}}\n")));
    assert!(err.contains("error[E0400]: this `match` doesn't cover every case: `Square(_)` and `Rect(_, _)` are not handled"), "{err}");
    let err = check_err(&file(&format!(
        "{shape}fn f(s: Shape): int = match s {{\n  Circle(_) | Dot => 1\n  Square(_) | Circle(_) => 2\n  Dot | Circle(_) => 3\n  _ => 4\n}}\n"
    )));
    assert!(err.contains("4:15: error[E0401]: this alternative is unreachable"), "{err}");
    assert!(err.contains("fix: remove the text at 4:12"), "{err}");
    assert!(err.contains("5:3: error[E0401]: this arm is unreachable"), "{err}");
    assert!(err.contains("the arm `Circle(_) | Dot` at line 3 already matches"), "{err}");
    // a guard doesn't count toward coverage
    let err = check_err(&file(&format!("{shape}fn f(s: Shape): int = match s {{\n  Circle(_) | Square(_) | Rect(_, _) | Dot when true => 1\n}}\n")));
    assert!(err.contains("E0400"), "{err}");
}

#[test]
fn or_patterns_format() {
    let p = file("fn f(n: int): int = match n {\n  0 |\n    1 => 1\n  _ => n\n}\n");
    let o = auk(&["fmt", s(&p)]);
    assert!(o.status.success());
    assert_eq!(fs::read_to_string(&p).unwrap(), "fn f(n: int): int = match n {\n  0 | 1 => 1\n  _ => n\n}\n");
}

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

// ---- 3. `var` parameters in function types ----

const VAR_FN_PROGRAM: &str = r#"struct Parser { toks: [str], pos: int, depth: int }
enum Fail { Bad(m: str) }

fn peek(p: Parser): str = p.toks.get(p.pos) else ""
fn next(p: var Parser): str {
  let t = p.peek()
  p.pos += 1
  t
}

fn item(p: var Parser): str!Fail {
  let t = p.next()
  if t == "!" { fail(Bad("bang at {p.pos - 1}")) }
  t.upper()
}

/// `close`-terminated, comma-separated items, each parsed by `f`
fn list(p: var Parser, close: str, f: (var Parser) => str!Fail): [str]!Fail {
  var out: [str] = []
  while p.peek() != close && p.peek() != "" {
    out.push(f(&p)?)
    if p.peek() == "," { p.next() }
  }
  p.next()
  out
}

fn nested(p: var Parser, f: (var Parser) => str!Fail): str!Fail {
  p.depth += 1
  let r = f(&p)
  p.depth -= 1
  r
}

fn twice(n: var int, g: (var int, int) => ()) {
  g(&n, 1)
  g(&n, 2)
}

fn main() {
  var p = Parser { toks: ["a", ",", "b", ",", "c", ")", "z"], pos: 0, depth: 0 }
  print(list(&p, ")", item))
  print(p.pos)
  var q = Parser { toks: ["x", "y", ")"], pos: 0, depth: 0 }
  print(list(&q, ")", r => "<{r.next()}>"))
  var s = Parser { toks: ["x", "!", ")"], pos: 0, depth: 0 }
  print(list(&s, ")", item) else e => ["{e}"])
  var u = Parser { toks: ["k"], pos: 0, depth: 3 }
  print(nested(&u, (r: var Parser) => "{r.depth}:{r.next()}"))
  print("{u.depth} {u.pos}")
  var n = 10
  twice(&n, (x, k) => { x += k })
  print(n)
  let h: (var int) => int = x => {
    x *= 2
    x
  }
  var m = 5
  print("{h(&m)} {m}")
  let fs: [(var int) => ()] = [x => { x += 1 }, x => { x *= 3 }]
  for f in fs { f(&m) }
  print(m)
}
"#;

#[test]
fn var_parameters_in_function_types() {
    let p = file(VAR_FN_PROGRAM);
    assert_eq!(run_leak_free(&p), "ok([\"A\", \"B\", \"C\"])\n6\nok([\"<x>\", \"<y>\"])\n[\"Bad(\\\"bang at 1\\\")\"]\nok(\"4:k\")\n3 1\n13\n10 10\n33\n");
}

#[test]
fn var_parameters_in_function_types_are_checked() {
    let err = check_err(&file("fn apply(n: var int, g: (var int) => ()) { g(n) }\n"));
    assert!(err.contains("1:46: error[E0310]: parameter 1 of `g` is `var`, so the argument needs `&`"), "{err}");
    assert!(err.contains("fix: insert `&` at 1:46"), "{err}");
    let err = check_err(&file("fn apply(n: int, g: (int) => ()) { g(&n) }\n"));
    assert!(err.contains("error[E0311]: parameter 1 of `g` is not a `var` parameter"), "{err}");
    // a `var` closure parameter needs a function type that says so (one error, not two)
    let err = check_err(&file("fn plain(g: (int) => int): int = g(1)\nfn main() { print(plain((x: var int) => x)) }\n"));
    assert!(err.contains("error[E0200]: this closure parameter is `var`, but the function type here passes a plain `int`"), "{err}");
    assert_eq!(err.matches("error[").count(), 1, "{err}");
    // a function with a `var` parameter has a `var` function type
    let err = check_err(&file("fn bump(n: var int) { n += 1 }\nfn main() { print([1].map(bump)) }\n"));
    assert!(err.contains("found `(var int) => ()`"), "{err}");
    // a closure inside still captures by value
    let err = check_err(&file("fn apply(n: var int, g: (var int) => ()) { g(&n) }\nfn main() {\n  var a = 1\n  apply(&a, x => {\n    let f = () => { x += 1 }\n    f()\n  })\n}\n"));
    assert!(err.contains("error[E0323]: a closure can't change `x`, a variable it captures"), "{err}");
    // `var` only in a function type's parameters
    let err = check_err(&file("fn f(x: (var int)) {}\n"));
    assert!(err.contains("1:10: error[E0023]: `var` is only for a parameter of a function type"), "{err}");
}

// ---- 4. stack overflow ----

const OVERFLOW: &str = r#"fn down(n: int): int = if n == 0 { 0 } else { 1 + down(n - 1) }

fn forever(n: int): int = 1 + forever(n + 1)

async fn forever_task(): int = forever(0)

fn main(args: [str]) {
  print("deep: {down(200000)}")
  if args.len() > 1 {
    let r = catch forever(0)
    print("caught: {r}")
    let r2 = catch forever(0)
    print("again: {r2}")
    let t = forever_task()
    let r3 = catch await t
    print("task: {r3}")
  } else {
    print(forever(0))
  }
}
"#;

#[test]
fn stack_overflow_is_a_panic() {
    let p = file(OVERFLOW);
    let o = auk(&["run", s(&p)]);
    assert_eq!(o.status.code(), Some(101), "{o:?}");
    assert_eq!(String::from_utf8_lossy(&o.stdout), "deep: 200000\n");
    assert_eq!(String::from_utf8_lossy(&o.stderr), "panic: stack overflow\n  at <unknown>\n");
    // under a recovery point (`catch`, a task) it is an Err, again and again
    let o = auk(&["run", s(&p), "catch"]);
    assert_eq!(o.status.code(), Some(0), "{o:?}");
    assert_eq!(
        String::from_utf8_lossy(&o.stdout),
        "deep: 200000\ncaught: err(panic: stack overflow at <unknown>)\nagain: err(panic: stack overflow at <unknown>)\ntask: err(panic: stack overflow at <unknown>)\n"
    );
}

#[test]
fn stack_overflow_in_a_built_program_names_the_function() {
    let p = file(OVERFLOW);
    let exe = p.with_file_name("overflow");
    let o = auk(&["build", s(&p), "-o", s(&exe)]);
    assert!(o.status.success(), "{o:?}");
    let o = Command::new(&exe).output().unwrap();
    assert_eq!(o.status.code(), Some(101), "{o:?}");
    assert_eq!(String::from_utf8_lossy(&o.stderr), "panic: stack overflow\n  at forever\n");
    let o = Command::new(&exe).arg("catch").output().unwrap();
    assert!(String::from_utf8_lossy(&o.stdout).contains("again: err(panic: stack overflow at forever)"), "{o:?}");
}

#[test]
fn stack_overflow_fails_one_test() {
    let p = file("fn forever(n: int): int = 1 + forever(n + 1)\ntest \"deep\" { assert forever(0) == 1 }\ntest \"fine\" { assert 1 == 1 }\n");
    let o = auk(&["test", s(&p)]);
    let out = String::from_utf8_lossy(&o.stdout);
    assert!(out.contains("FAIL deep\n    panic: stack overflow\n"), "{out}");
    assert!(out.contains("ok fine\n1 passed, 1 failed"), "{out}");
}

// ---- 5. small helpers: strings, radix, hex format, tuple assignment ----

#[test]
fn string_trimming_and_stripping() {
    let p = file(
        r#"fn main() {
  let s = "  hi there \n"
  print("[{s.trim_start()}] [{s.trim_end()}] [{s.trim()}]")
  print("{"--flag".strip_prefix("--")} {"x".strip_prefix("--")} {"main.auk".strip_suffix(".auk")} {"héllo".strip_prefix("hé")}")
  let name = "file.txt".strip_suffix(".txt") else "?"
  print(name)
  print("{min(3, 1)} {max(3, 1)} {min("b", "a")} {max(2.5, -1.0)}")
}
"#,
    );
    assert_eq!(
        run_leak_free(&p),
        "[hi there \n] [  hi there] [hi there]\nsome(\"flag\") none some(\"main\") some(\"llo\")\nfile\n1 3 a 2.5\n"
    );
}

#[test]
fn radix_parsing() {
    let p = file(
        r#"fn main() {
  print(int.parse("ff", 16))
  print(int.parse("-FF", 16))
  print(int.parse("1010_1010", 2))
  print(int.parse("zz", 36))
  print(int.parse("7fffffffffffffff", 16))
  print(int.parse("-8000000000000000", 16))
  print(int.parse("8000000000000000", 16))
  print(int.parse("12", 2))
  print(int.parse("", 16))
  print(int.parse("1", 37) else e => -1)
  print("{'f'.is_digit(16)} {'g'.is_digit(16)} {'7'.is_digit(8)} {'8'.is_digit(8)} {'Z'.is_digit(36)}")
}
"#,
    );
    assert_eq!(
        run_leak_free(&p),
        "ok(255)\nok(-255)\nok(170)\nok(1295)\nok(9223372036854775807)\nok(-9223372036854775808)\nerr(int.parse: \"8000000000000000\" is out of range)\nerr(int.parse: invalid base-2 int \"12\")\nerr(int.parse: invalid base-16 int \"\")\n-1\ntrue false true false true\n"
    );
}

#[test]
fn hex_octal_binary_formats() {
    let p = file(
        r#"fn main() {
  let n = 255
  print("{n:x} {n:X} {n:o} {n:b} {n:08x} {n:>6x}| {n:<6b}| {0:x} {-1:x}")
  print("{1.5.bits():016x}")
}
"#,
    );
    assert_eq!(run_leak_free(&p), "ff FF 377 11111111 000000ff     ff| 11111111| 0 ffffffffffffffff\n3ff8000000000000\n");
    let err = check_err(&file("fn f(x: float): str = \"{x:x}\"\n"));
    assert!(err.contains("error[E0283]: the format spec `x` shows an `int` in hex, but this is `float`"), "{err}");
    let err = check_err(&file("fn f(n: int): str = \"{n:xx}\"\n"));
    assert!(err.contains("error[E0282]: malformed format spec `xx`: unexpected `x`"), "{err}");
}


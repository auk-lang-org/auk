//! Patterns (exhaustiveness, reachability: E0400–E0403) and effects (E0410–E0415) through
//! `auk check`: exact codes, messages, spans, notes and fix-its.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicUsize, Ordering};

fn auk(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_auk")).args(args).output().unwrap()
}

fn scratch() -> PathBuf {
    static N: AtomicUsize = AtomicUsize::new(0);
    let n = N.fetch_add(1, Ordering::SeqCst);
    let dir = std::env::temp_dir().join(format!("auk-check2-{}-{n}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

#[derive(Debug, Default)]
struct D {
    code: String,
    severity: String,
    file: Option<String>,
    line: u32,
    col: u32,
    message: String,
    notes: Vec<String>,
    /// (line, col, end_line, end_col, text)
    fixes: Vec<(u32, u32, u32, u32, String)>,
}

/// `check --json` on a file: the diagnostics, and whether the exit code was 0.
fn check_path(path: &Path) -> (Vec<D>, bool) {
    let out = auk(&["check", path.to_str().unwrap(), "--json"]);
    let json = String::from_utf8(out.stdout).unwrap();
    let v = Json::parse(&json);
    let ds: Vec<D> = v
        .get("diagnostics")
        .arr()
        .iter()
        .map(|d| D {
            code: d.get("code").str(),
            severity: d.get("severity").str(),
            file: d.opt("file").map(|f| f.str()),
            line: d.get("line").num(),
            col: d.get("col").num(),
            message: d.get("message").str(),
            notes: d.get("notes").arr().iter().map(|n| n.str()).collect(),
            fixes: d
                .get("fixes")
                .arr()
                .iter()
                .map(|f| (f.get("line").num(), f.get("col").num(), f.get("end_line").num(), f.get("end_col").num(), f.get("text").str()))
                .collect(),
        })
        .collect();
    let errors = ds.iter().filter(|d| d.severity == "error").count();
    let ok = matches!(v.get("ok"), Json::Bool(true));
    assert_eq!(ok, errors == 0, "`ok` vs errors: {json}");
    assert_eq!(out.status.success(), errors == 0, "exit status vs errors: {json}");
    (ds, out.status.success())
}

fn check(src: &str) -> Vec<D> {
    let dir = scratch();
    let path = dir.join("t.auk");
    fs::write(&path, src).unwrap();
    let (ds, _) = check_path(&path);
    let _ = fs::remove_dir_all(&dir);
    ds
}

/// The single diagnostic of `src`, with this code and message.
fn one(src: &str, code: &str, message: &str) -> D {
    let mut ds = check(src);
    assert_eq!(ds.len(), 1, "expected exactly one diagnostic for:\n{src}\ngot: {ds:#?}");
    let d = ds.remove(0);
    assert_eq!((d.code.as_str(), d.message.as_str()), (code, message), "{d:#?}");
    d
}

fn clean(src: &str) {
    let ds = check(src);
    assert!(ds.is_empty(), "expected no diagnostics for:\n{src}\ngot: {ds:#?}");
}

fn at(d: &D, line: u32, col: u32) {
    assert_eq!((d.line, d.col), (line, col), "{d:#?}");
}

fn has_note(d: &D, part: &str) {
    assert!(d.notes.iter().any(|n| n.contains(part)), "no note containing {part:?}: {d:#?}");
}

fn fix(d: &D, at: (u32, u32, u32, u32), text: &str) {
    assert!(d.fixes.iter().any(|f| (f.0, f.1, f.2, f.3) == at && f.4 == text), "no fix {at:?} -> {text:?}: {d:#?}");
}

const SHAPE: &str = "enum Shape { Circle(r: float), Rect(w: float, h: float) }\n";

// ---- exhaustiveness: enums and clause groups ----

#[test]
fn clause_group_missing_variant() {
    let src = format!("{SHAPE}fn area(Circle(r)): float = 3.14 * r * r\nfn main() {{ print(area(Circle(1.0))) }}\n");
    let d = one(&src, "E0400", "the clauses of `area` don't cover every case: `area(Rect(_, _))` is not handled");
    at(&d, 2, 4);
    has_note(&d, "add a clause for each missing case");
    fix(&d, (2, 41, 2, 41), "\nfn area(Rect(w, h)): float = ??");
}

#[test]
fn match_missing_variant_inserts_arm() {
    let src = format!("{SHAPE}fn area(s: Shape): float {{\n  match s {{\n    Circle(r) => 3.14 * r * r\n  }}\n}}\nfn main() {{}}\n");
    let d = one(&src, "E0400", "this `match` doesn't cover every case: `Rect(_, _)` is not handled");
    at(&d, 3, 3);
    fix(&d, (4, 30, 4, 30), "\n    Rect(w, h) => ??");
}

#[test]
fn one_line_match_inserts_with_comma() {
    let d = one("enum K { A, B, C }\nfn f(k: K): int = match k { A => 1, B => 2 }\nfn main() {}\n", "E0400", "this `match` doesn't cover every case: `C` is not handled");
    fix(&d, (2, 43, 2, 43), ", C => ??");
}

#[test]
fn int_literals_need_a_catch_all() {
    let d = one("fn fib(0): int = 0\nfn fib(1): int = 1\nfn main() {}\n", "E0400", "the clauses of `fib` don't cover every case: `fib(_)` is not handled");
    fix(&d, (2, 19, 2, 19), "\nfn fib(_): int = ??");
}

#[test]
fn float_str_char_literals_need_a_catch_all() {
    for (ty, a, b) in [("float", "1.0", "2.5"), ("str", "\"a\"", "\"b\""), ("char", "'a'", "'b'")] {
        let src = format!("fn f(x: {ty}): int {{\n  match x {{\n    {a} => 1\n    {b} => 2\n  }}\n}}\nfn main() {{}}\n");
        let d = one(&src, "E0400", "this `match` doesn't cover every case: `_` is not handled");
        fix(&d, (4, 13 + b.len() as u32 - 3, 4, 13 + b.len() as u32 - 3), "\n    _ => ??");
    }
}

#[test]
fn bool_and_tuples() {
    let d = one(
        "fn f(a: bool, b: bool): int {\n  match (a, b) {\n    (true, true) => 1\n    (false, false) => 2\n  }\n}\nfn main() {}\n",
        "E0400",
        "this `match` doesn't cover every case: `(false, true)` and `(true, false)` are not handled",
    );
    fix(&d, (4, 24, 4, 24), "\n    (false, true) => ??\n    (true, false) => ??");
    clean("fn g(true): int = 1\nfn g(false): int = 0\nfn main() {}\n");
}

#[test]
fn struct_patterns_with_rest() {
    let d = one(
        "struct P { on: bool, n: int }\nfn f(P { on: true, .. }): int = 1\nfn main() {}\n",
        "E0400",
        "the clauses of `f` don't cover every case: `f(P { on: false, .. })` is not handled",
    );
    fix(&d, (2, 34, 2, 34), "\nfn f(P { on: false, .. }): int = ??");
    clean("struct P { on: bool, n: int }\nfn f(P { on: true, .. }): int = 1\nfn f(P { n, .. }): int = n\nfn main() {}\n");
}

#[test]
fn nested_enums() {
    let src = format!(
        "{SHAPE}fn f(x: Shape?): float {{\n  match x {{\n    some(Circle(r)) => r\n    none => 0.0\n  }}\n}}\nfn main() {{}}\n"
    );
    let d = one(&src, "E0400", "this `match` doesn't cover every case: `some(Rect(_, _))` is not handled");
    fix(&d, (5, 16, 5, 16), "\n    some(Rect(w, h)) => ??");
    let deep = "enum T { Leaf, Node(l: T, r: T) }\nfn f(Leaf): int = 0\nfn f(Node(Leaf, _)): int = 1\nfn f(Node(Node(_, _), Node(_, _))): int = 2\nfn main() {}\n";
    let d = one(deep, "E0400", "the clauses of `f` don't cover every case: `f(Node(Node(_, _), Leaf))` is not handled");
    fix(&d, (4, 44, 4, 44), "\nfn f(Node(Node(l, r), Leaf)): int = ??");
}

#[test]
fn options_and_results() {
    let d = one("fn f(x: int?): int {\n  match x {\n    some(n) => n\n  }\n}\nfn main() {}\n", "E0400", "this `match` doesn't cover every case: `none` is not handled");
    fix(&d, (3, 17, 3, 17), "\n    none => ??");
    let d = one("fn f(x: int!): int {\n  match x {\n    ok(n) => n\n  }\n}\nfn main() {}\n", "E0400", "this `match` doesn't cover every case: `err(_)` is not handled");
    fix(&d, (3, 15, 3, 15), "\n    err(e) => ??");
    clean("fn f(x: int?): int {\n  match x {\n    some(n) => n\n    none => 0\n  }\n}\nfn main() {}\n");
}

#[test]
fn typed_error_enum() {
    let d = one(
        "enum E { A, B(k: int) }\nfn f(x: int!E): int {\n  match x {\n    ok(n) => n\n    err(A) => 0\n  }\n}\nfn main() {}\n",
        "E0400",
        "this `match` doesn't cover every case: `err(B(_))` is not handled",
    );
    fix(&d, (5, 16, 5, 16), "\n    err(B(k)) => ??");
}

#[test]
fn typed_error_payload_on_plain_err_needs_catch_all() {
    let src = "enum E { A, B(k: int) }\nfn f(x: int!): int {\n  match x {\n    ok(n) => n\n    err(A) => 0\n    err(B(k)) => k\n  }\n}\nfn main() {}\n";
    let d = one(src, "E0400", "this `match` doesn't cover every case: `err(_)` is not handled");
    fix(&d, (6, 19, 6, 19), "\n    err(e) => ??");
    clean(&src.replace("    err(B(k)) => k\n", "    err(B(k)) => k\n    err(e) => 1\n"));
}

#[test]
fn value_variants() {
    let src = "fn f(v: Value): int {\n  match v {\n    Null => 0\n    Int(i) => i\n  }\n}\nfn main() {}\n";
    let d = one(src, "E0400", "this `match` doesn't cover every case: `Bool(_)`, `Float(_)`, `Str(_)` and more are not handled");
    has_note(&d, "catch-all");
    fix(&d, (4, 16, 4, 16), "\n    _ => ??");
    let d = one(
        "fn f(v: Value): int {\n  match v {\n    Null => 0\n    Bool(b) => 1\n    Int(i) => i\n    Float(x) => 2\n    Str(s) => 3\n    List(xs) => 4\n  }\n}\nfn main() {}\n",
        "E0400",
        "this `match` doesn't cover every case: `Map(_)` is not handled",
    );
    fix(&d, (8, 18, 8, 18), "\n    Map(m) => ??");
}

#[test]
fn more_than_three_missing_inserts_catch_all() {
    let d = one(
        "enum D { N, E, S, W, X }\nfn f(N): int = 0\nfn main() {}\n",
        "E0400",
        "the clauses of `f` don't cover every case: `f(E)`, `f(S)`, `f(W)` and more are not handled",
    );
    fix(&d, (2, 17, 2, 17), "\nfn f(_): int = ??");
}

// ---- lists ----

#[test]
fn lists_empty_plus_rest_is_exhaustive() {
    clean("fn len([]): int = 0\nfn len([_, ..t]: [int]): int = 1 + len(t)\nfn main() {}\n");
    clean("fn last([]): int = 0\nfn last([.., x]: [int]): int = x\nfn main() {}\n");
    clean("fn f(xs: [int]): int {\n  match xs {\n    [] => 0\n    [a] => a\n    [a, b, .._] => a + b\n  }\n}\nfn main() {}\n");
}

#[test]
fn lists_missing_lengths() {
    let d = one("fn f(xs: [int]): int {\n  match xs {\n    [] => 0\n    [a] => a\n  }\n}\nfn main() {}\n", "E0400", "this `match` doesn't cover every case: `[_, _, ..]` is not handled");
    fix(&d, (4, 13, 4, 13), "\n    [_, _, ..] => ??");
    let d = one("fn f([h, ..t]: [int]): int = h\nfn main() {}\n", "E0400", "the clauses of `f` don't cover every case: `f([])` is not handled");
    fix(&d, (1, 31, 1, 31), "\nfn f([]: [int]): int = ??");
    let d = one(
        "fn f(xs: [int]): int {\n  match xs {\n    [] => 0\n    [a, b, ..] => a\n  }\n}\nfn main() {}\n",
        "E0400",
        "this `match` doesn't cover every case: `[_]` is not handled",
    );
    fix(&d, (4, 20, 4, 20), "\n    [_] => ??");
}

#[test]
fn multi_parameter_clause_group_keeps_signature_style() {
    let d = one(
        "fn len([], acc: int): int = acc\nfn len([_, _, ..t]: [int], acc: int): int = len(t, acc + 2)\nfn main() {}\n",
        "E0400",
        "the clauses of `len` don't cover every case: `len([_], _)` is not handled",
    );
    at(&d, 1, 4);
    fix(&d, (2, 60, 2, 60), "\nfn len([_]: [int], acc: int): int = ??");
}

#[test]
fn list_arm_unreachable_after_rest() {
    let d = one(
        "fn f(xs: [int]): int {\n  match xs {\n    [] => 0\n    [.., last] => last\n    [a, b] => a\n  }\n}\nfn main() {}\n",
        "E0401",
        "this arm is unreachable",
    );
    at(&d, 5, 5);
    has_note(&d, "the arm `[.., last]` at line 4 already matches every value this one matches");
}

// ---- open maps and string prefixes ----

#[test]
fn open_maps_are_never_exhaustive() {
    let d = one("fn f({\"a\": n}: {str: int}): int = n\nfn main() {}\n", "E0400", "the clauses of `f` don't cover every case: `f(_)` is not handled");
    fix(&d, (1, 36, 1, 36), "\nfn f(_: {str: int}): int = ??");
    let d = one(
        "fn f(v: Value): int {\n  match v {\n    Map({\"a\": Int(n)}) => n\n    Null => 0\n  }\n}\nfn main() {}\n",
        "E0400",
        "this `match` doesn't cover every case: `Bool(_)`, `Int(_)`, `Float(_)` and more are not handled",
    );
    has_note(&d, "catch-all");
    clean("fn f({\"a\": n}: {str: int}): int = n\nfn f(_: {str: int}): int = 0\nfn main() {}\n");
}

#[test]
fn string_prefixes() {
    let d = one(
        "fn f(s: str): int {\n  match s {\n    \"GET \" + p => 1\n    \"GET \" + q => 2\n    _ => 3\n  }\n}\nfn main() {}\n",
        "E0401",
        "this arm is unreachable",
    );
    has_note(&d, "the arm `\"GET \" + p` at line 3");
    let d = one("fn f(\"GET \" + p): int = 1\nfn main() {}\n", "E0400", "the clauses of `f` don't cover every case: `f(_)` is not handled");
    fix(&d, (1, 26, 1, 26), "\nfn f(_): int = ??");
}

// ---- reachability and guards ----

#[test]
fn unreachable_clause_names_the_covering_one() {
    let d = one(
        "fn fib(0): int = 0\nfn fib(1): int = 1\nfn fib(n: int): int = fib(n - 1) + fib(n - 2)\nfn fib(5): int = 5\nfn main() {}\n",
        "E0401",
        "this clause of `fib` is unreachable",
    );
    at(&d, 4, 8);
    has_note(&d, "the clause `fn fib(n: int)` at line 3 already matches every call this one matches");
    fix(&d, (3, 46, 4, 19), "");
}

#[test]
fn unreachable_by_several_arms_together() {
    let d = one(
        "fn f(b: bool): int {\n  match b {\n    true => 1\n    false => 0\n    _ => 2\n  }\n}\nfn main() {}\n",
        "E0401",
        "this arm is unreachable",
    );
    at(&d, 5, 5);
    has_note(&d, "the arms before it together match every value this one matches");
    fix(&d, (4, 15, 5, 11), "");
}

#[test]
fn guards_dont_count_toward_exhaustiveness() {
    let d = one(
        "fn grade(n: int): str when n >= 90 = \"A\"\nfn grade(n: int): str when n < 90 = \"B\"\nfn main() {}\n",
        "E0400",
        "the clauses of `grade` don't cover every case: `grade(_)` is not handled",
    );
    has_note(&d, "clauses with a `when` guard don't count");
    fix(&d, (2, 40, 2, 40), "\nfn grade(n: int): str = ??");
    clean("fn grade(n: int): str when n >= 90 = \"A\"\nfn grade(_: int): str = \"B\"\nfn main() {}\n");
}

#[test]
fn guarded_arm_after_catch_all_is_unreachable() {
    let d = one(
        "fn f(n: int): int {\n  match n {\n    _ => 0\n    k when k > 1 => 1\n  }\n}\nfn main() {}\n",
        "E0401",
        "this arm is unreachable",
    );
    has_note(&d, "the arm `_` at line 3");
}

#[test]
fn guarded_arm_doesnt_make_later_arm_unreachable() {
    clean("fn f(n: int): int {\n  match n {\n    k when k > 1 => 1\n    _ => 0\n  }\n}\nfn main() {}\n");
}

// ---- let, for, closures ----

#[test]
fn let_else_that_always_matches() {
    let d = one(
        "enum One { Only(v: int) }\nfn f(t: One): int {\n  let Only(a) = t else { return 0 }\n  a\n}\nfn main() {}\n",
        "E0402",
        "the `else` of this `let` is never taken: the pattern matches every `One`",
    );
    fix(&d, (3, 18, 3, 36), "");
    clean("fn f(xs: [int]): int {\n  let [h, ..t] = xs else { return 0 }\n  h\n}\nfn main() {}\n");
}

#[test]
fn refutable_let_without_else() {
    let d = one(
        "fn f(t: (int, bool)): int {\n  let (a, true) = t\n  a\n}\nfn main() {}\n",
        "E0403",
        "this `let` pattern might not match: `(_, false)` is not handled",
    );
    at(&d, 2, 7);
    let d = one(
        &format!("{SHAPE}fn f(xs: [Shape]): float {{\n  var t = 0.0\n  for Circle(r) in xs {{ t += r }}\n  t\n}}\nfn main() {{}}\n"),
        "E0403",
        "the pattern of this `for` might not match: `Rect(_, _)` is not handled",
    );
    at(&d, 4, 7);
}

// ---- effects ----

#[test]
fn missing_effect_adds_uses() {
    let d = one(
        "fn load(p: str): str! {\n  let s = fs.read(p)?\n  s\n}\nfn main() {}\n",
        "E0410",
        "`load` uses the effect `fs` but doesn't declare it",
    );
    at(&d, 2, 11);
    has_note(&d, "call chain: `load` → `fs.read` (uses fs)");
    fix(&d, (1, 22, 1, 22), " uses fs");
}

#[test]
fn missing_effect_appends_to_list() {
    let d = one(
        "fn f(): int uses fs {\n  let s = fs.read(\"x\") else \"\"\n  s.len() + time.now()\n}\nfn main() {}\n",
        "E0410",
        "`f` uses the effect `time` but doesn't declare it",
    );
    fix(&d, (1, 20, 1, 20), ", time");
}

#[test]
fn missing_effect_without_return_type() {
    let d = one("fn main() {\n  time.sleep(1)\n}\n", "E0410", "`main` uses the effect `time` but doesn't declare it");
    fix(&d, (1, 10, 1, 10), " uses time");
    let d = one("fn main() {\n  time.sleep(rand.int(1, 2))\n}\n", "E0410", "`main` uses the effects `time`, `rand` but doesn't declare them");
    fix(&d, (1, 10, 1, 10), " uses time, rand");
}

#[test]
fn missing_effect_through_a_closure() {
    let d = one(
        "fn all(ps: [str]): [str] = ps.map(p => fs.read(p) else \"\")\nfn main() {}\n",
        "E0410",
        "`all` uses the effect `fs` but doesn't declare it",
    );
    has_note(&d, "the closure at 1:35 is part of `all`, so its effects are `all`'s");
    fix(&d, (1, 25, 1, 25), " uses fs");
}

#[test]
fn missing_effect_through_a_function_value() {
    let d = one(
        "fn load(p: str): str uses fs = fs.read(p) else \"\"\nfn all(ps: [str]): [str] = ps.map(load)\nfn main() {}\n",
        "E0410",
        "`all` uses the effect `fs` but doesn't declare it",
    );
    at(&d, 2, 35);
    has_note(&d, "call chain: `all` → `load` (uses fs)");
}

#[test]
fn missing_effect_through_a_shape_vtable() {
    let d = one(
        "shape Log { fn log(self, s: str) uses fs }\nfn report(l: any Log) { l.log(\"hi\") }\nfn main() {}\n",
        "E0410",
        "`report` uses the effect `fs` but doesn't declare it",
    );
    has_note(&d, "call chain: `report` → `Log.log (through `any Log`)` (uses fs)");
    fix(&d, (2, 22, 2, 22), " uses fs");
}

#[test]
fn conversion_to_any_shape_checks_method_effects() {
    let d = one(
        "shape Log { fn log(self, s: str) }\nstruct F { p: str }\nfn log(f: F, s: str) uses fs { fs.write(f.p, s) else () }\nfn report(l: any Log) { l.log(\"hi\") }\nfn main() { report(F { p: \"a\" }) }\n",
        "E0415",
        "converting `F` to `any Log` would let `Log.log` use `fs`, which the shape doesn't declare",
    );
    at(&d, 5, 20);
    has_note(&d, "`log` for `F` (at 3:4) uses `fs`");
    fix(&d, (1, 33, 1, 33), " uses fs");
}

#[test]
fn missing_effect_through_a_generic_instance() {
    let src = "shape Area { fn area(self): float }\nstruct Sq { s: float }\nfn area(q: Sq): float uses fs {\n  let _ = fs.read(\"x\") else \"\"\n  q.s * q.s\n}\nfn total(xs: [Area]): float = xs.map(x => x.area()).sum()\nfn main() {\n  print(total([Sq { s: 1.0 }]))\n}\n";
    let d = one(src, "E0410", "`main` uses the effect `fs` but doesn't declare it");
    at(&d, 9, 9);
    has_note(&d, "call chain: `main` → `total<Sq>` → `area` (uses fs)");
    fix(&d, (8, 10, 8, 10), " uses fs");
    clean(&src.replace("fn main() {", "fn main() uses fs {"));
}

#[test]
fn unused_effect_is_a_warning() {
    let dir = scratch();
    let path = dir.join("t.auk");
    fs::write(&path, "fn f(): int uses fs, net = 1\nfn main() uses fs, net { print(f()) }\n").unwrap();
    let (ds, ok) = check_path(&path);
    assert!(ok, "warnings must not fail the check");
    assert_eq!(ds.len(), 1, "{ds:#?}");
    let d = &ds[0];
    assert_eq!((d.code.as_str(), d.severity.as_str()), ("E0411", "warning"));
    assert_eq!(d.message, "`f` declares the effects `fs`, `net` but doesn't use them");
    fix(d, (1, 12, 1, 25), "");
    let out = auk(&["check", path.to_str().unwrap()]);
    assert!(out.status.success());
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains("t.auk:1:18: warning[E0411]: `f` declares the effects `fs`, `net` but doesn't use them"), "{err}");
    // removing one of several keeps the rest
    fs::write(&path, "fn f(): int uses fs, net = (fs.read(\"a\") else \"\").len()\nfn main() uses fs, net { print(f()) }\n").unwrap();
    let (ds, ok) = check_path(&path);
    assert!(ok);
    assert_eq!(ds.len(), 1, "{ds:#?}");
    assert_eq!(ds[0].message, "`f` declares the effect `net` but doesn't use it");
    fix(&ds[0], (1, 12, 1, 25), " uses fs");
}

#[test]
fn impure_imprint_and_constants() {
    let d = one("imprint T = fs.read(\"x\") else \"\"\nfn main() {}\n", "E0412", "`imprint T` is computed at compile time and must be pure, but its initializer uses the effect `fs`");
    at(&d, 1, 13);
    has_note(&d, "call chain: `T` → `fs.read` (uses fs)");
    one("let K = time.now()\nfn main() {}\n", "E0412", "the module constant `K` must be pure, but its initializer uses the effect `time`");
    clean("imprint SQ = [1, 2, 3].map(x => x * x)\nfn main() { print(SQ) }\n");
}

#[test]
fn tests_print_and_peek_are_free() {
    clean("fn f(x: int): int = peek x * 2\ntest \"io\" {\n  let s = fs.read(\"x\") else \"\"\n  print(s)\n  assert time.now() > 0\n}\nfn main() { print(f(1)) }\n");
}

#[test]
fn main_gets_no_implicit_permission() {
    let d = one("fn main(): ()! {\n  print(fs.read(\"a\")?)\n}\n", "E0410", "`main` uses the effect `fs` but doesn't declare it");
    fix(&d, (1, 15, 1, 15), " uses fs");
}

#[test]
fn unknown_effect_name() {
    let d = one("fn f(): int uses fss = 1\nfn main() {}\n", "E0414", "unknown effect `fss`");
    fix(&d, (1, 18, 1, 21), "fs");
}

// ---- the package ceiling ----

fn project(toml_effects: &str, main: &str) -> PathBuf {
    let dir = scratch();
    fs::write(dir.join("raft.toml"), format!("[package]\nname = \"app\"\nversion = \"0.1.0\"\neffects = {toml_effects}\n")).unwrap();
    fs::create_dir_all(dir.join("src")).unwrap();
    fs::write(dir.join("src/main.auk"), main).unwrap();
    dir
}

#[test]
fn package_ceiling() {
    let dir = project("[\"net\"]", "fn load(p: str): str! uses fs, net {\n  var c = net.tcp(\"a\", 1)?\n  c.close()\n  fs.read(p)\n}\nfn main(): ()! uses net {\n  var c = net.tcp(\"b\", 2)?\n  c.close()\n}\n");
    let (ds, ok) = check_path(&dir.join("src/main.auk"));
    assert!(!ok);
    assert_eq!(ds.len(), 1, "{ds:#?}");
    let d = &ds[0];
    assert_eq!((d.code.as_str(), d.message.as_str()), ("E0413", "`load` uses `fs`, but the package `app` allows only `net`"));
    at(d, 1, 28);
    has_note(d, "help: add \"fs\" to `effects` under [package] in");
    has_note(d, "raft.toml");
    let dir = project("[]", "fn main() uses time { time.sleep(1) }\n");
    let (ds, _) = check_path(&dir.join("src/main.auk"));
    assert_eq!(ds.len(), 1, "{ds:#?}");
    assert_eq!(ds[0].message, "`main` uses `time`, but the package `app` allows no effects");
    // a standalone file has no ceiling
    clean("fn main() uses time { time.sleep(1) }\n");
}

#[test]
fn dependency_checked_against_its_own_manifest() {
    let dir = project("[\"fs\"]", "fn main() uses fs { print(dep.load()) }\n");
    fs::write(dir.join("raft.toml"), "[package]\nname = \"app\"\nversion = \"0.1.0\"\neffects = [\"fs\"]\n\n[deps]\ndep = \"^0.1\"\n").unwrap();
    let q = dir.join(".raft/dep");
    fs::create_dir_all(q.join("src")).unwrap();
    fs::write(q.join("raft.toml"), "[package]\nname = \"dep\"\nversion = \"0.1.0\"\neffects = []\n").unwrap();
    fs::write(q.join("src/lib.auk"), "pub fn load(): str uses fs = fs.read(\"x\") else \"\"\n").unwrap();
    let (ds, ok) = check_path(&dir.join("src/main.auk"));
    assert!(!ok);
    assert_eq!(ds.len(), 1, "{ds:#?}");
    assert_eq!((ds[0].code.as_str(), ds[0].message.as_str()), ("E0413", "`load` uses `fs`, but the package `dep` allows no effects"));
    assert!(ds[0].file.as_deref().is_some_and(|f| f.ends_with(".raft/dep/src/lib.auk")), "{:?}", ds[0].file);
}

// ---- a minimal JSON reader for the `check --json` report ----

#[derive(Debug)]
enum Json {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vec<Json>),
    Obj(Vec<(String, Json)>),
}

impl Json {
    fn parse(s: &str) -> Json {
        let cs: Vec<char> = s.chars().collect();
        let mut i = 0;
        Json::value(&cs, &mut i)
    }

    fn ws(cs: &[char], i: &mut usize) {
        while *i < cs.len() && cs[*i].is_whitespace() {
            *i += 1;
        }
    }

    fn value(cs: &[char], i: &mut usize) -> Json {
        Json::ws(cs, i);
        match cs[*i] {
            '{' => {
                *i += 1;
                let mut kv = Vec::new();
                loop {
                    Json::ws(cs, i);
                    if cs[*i] == '}' {
                        *i += 1;
                        return Json::Obj(kv);
                    }
                    let Json::Str(k) = Json::value(cs, i) else { panic!("key") };
                    Json::ws(cs, i);
                    *i += 1;
                    let v = Json::value(cs, i);
                    kv.push((k, v));
                    Json::ws(cs, i);
                    if cs[*i] == ',' {
                        *i += 1;
                    }
                }
            }
            '[' => {
                *i += 1;
                let mut xs = Vec::new();
                loop {
                    Json::ws(cs, i);
                    if cs[*i] == ']' {
                        *i += 1;
                        return Json::Arr(xs);
                    }
                    xs.push(Json::value(cs, i));
                    Json::ws(cs, i);
                    if cs[*i] == ',' {
                        *i += 1;
                    }
                }
            }
            '"' => {
                *i += 1;
                let mut s = String::new();
                while cs[*i] != '"' {
                    if cs[*i] == '\\' {
                        *i += 1;
                        match cs[*i] {
                            'n' => s.push('\n'),
                            't' => s.push('\t'),
                            'u' => {
                                let h: String = cs[*i + 1..*i + 5].iter().collect();
                                s.push(char::from_u32(u32::from_str_radix(&h, 16).unwrap()).unwrap());
                                *i += 4;
                            }
                            c => s.push(c),
                        }
                    } else {
                        s.push(cs[*i]);
                    }
                    *i += 1;
                }
                *i += 1;
                Json::Str(s)
            }
            't' => {
                *i += 4;
                Json::Bool(true)
            }
            'f' => {
                *i += 5;
                Json::Bool(false)
            }
            'n' => {
                *i += 4;
                Json::Null
            }
            _ => {
                let start = *i;
                while *i < cs.len() && (cs[*i].is_ascii_digit() || "-+.eE".contains(cs[*i])) {
                    *i += 1;
                }
                Json::Num(cs[start..*i].iter().collect::<String>().parse().unwrap())
            }
        }
    }

    fn opt(&self, k: &str) -> Option<&Json> {
        match self {
            Json::Obj(kv) => kv.iter().find(|(x, _)| x == k).map(|(_, v)| v),
            _ => None,
        }
    }

    fn get(&self, k: &str) -> &Json {
        self.opt(k).unwrap_or_else(|| panic!("no key {k} in {self:?}"))
    }

    fn arr(&self) -> &[Json] {
        match self {
            Json::Arr(xs) => xs,
            _ => panic!("not an array: {self:?}"),
        }
    }

    fn str(&self) -> String {
        match self {
            Json::Str(s) => s.clone(),
            _ => panic!("not a string: {self:?}"),
        }
    }

    fn num(&self) -> u32 {
        match self {
            Json::Num(n) => *n as u32,
            _ => panic!("not a number: {self:?}"),
        }
    }
}

/// Apply one fix-it (1-based line/col, end exclusive) to `src`.
fn apply_fix(src: &str, f: &(u32, u32, u32, u32, String)) -> String {
    let offset = |line: u32, col: u32| {
        let start: usize = src.split_inclusive('\n').take(line as usize - 1).map(str::len).sum();
        start + src[start..].chars().take(col as usize - 1).map(char::len_utf8).sum::<usize>()
    };
    let (a, b) = (offset(f.0, f.1), offset(f.2, f.3));
    format!("{}{}{}", &src[..a], f.4, &src[b..])
}

#[test]
fn missing_and_unused_effects_get_one_combined_fix() {
    let src = "fn f(): str! uses net, fs, time {\n  fs.read(\"x{rand.int(1, 2)}\")\n}\nfn main() {}\n";
    let ds = check(src);
    assert_eq!(ds.len(), 2, "{ds:#?}");
    let by = |code: &str| ds.iter().find(|d| d.code == code).unwrap_or_else(|| panic!("no {code}: {ds:#?}"));
    let (e, w) = (by("E0410"), by("E0411"));
    assert_eq!((e.code.as_str(), e.message.as_str()), ("E0410", "`f` uses the effect `rand` but doesn't declare it"));
    assert_eq!((w.code.as_str(), w.message.as_str()), ("E0411", "`f` declares the effects `net`, `time` but doesn't use them"));
    // one fix, on the error, rewriting the whole list (the user's order, then the new effect)
    assert_eq!(e.fixes.len(), 1, "{e:#?}");
    fix(e, (1, 13, 1, 32), " uses fs, rand");
    assert!(w.fixes.is_empty(), "the warning must not carry a conflicting fix: {w:#?}");
    let fixed = apply_fix(src, &e.fixes[0]);
    assert_eq!(fixed, "fn f(): str! uses fs, rand {\n  fs.read(\"x{rand.int(1, 2)}\")\n}\nfn main() {}\n");
    clean(&fixed);
    // each alone still gets its own fix
    let d = one("fn f(): str! uses fs {\n  fs.read(\"x{rand.int(1, 2)}\")\n}\nfn main() {}\n", "E0410", "`f` uses the effect `rand` but doesn't declare it");
    fix(&d, (1, 21, 1, 21), ", rand");
}

// ---- regressions: cascades and pointless `?` / `else` ----

#[test]
fn closure_arity_mismatch_reports_only_e0204() {
    one(
        "fn f(xs: [int]): [int] = xs.map((a, b) => a)\nfn main() { print(f([1])) }\n",
        "E0204",
        "this closure takes 2 parameter(s), but 1 are expected here",
    );
}

#[test]
fn pointless_try_under_fallible_return() {
    // the `int!` return type must not make `?` on a plain `int` acceptable
    let d = one(
        "fn size(s: str): int! = s.len()?\nfn main() { print(size(\"a\")!) }\n",
        "E0250",
        "`?` needs a `T!`, `T?` or a list of them, but `s.len()` is `int`",
    );
    fix(&d, (1, 32, 1, 33), "");
}

#[test]
fn try_on_shadowing_fallible_fn_is_fine() {
    // `s.len()` finds this module's `len` (an `int!`) before core's, so the `?` is needed
    clean("fn len(s: str): int! = s.len()?\nfn main() { print(len(\"a\") else 0) }\n");
}

#[test]
fn irrefutable_struct_let_else_is_e0255() {
    let d = one(
        "struct Point { x: int, y: int }\nfn f(p: Point): int {\n  let Point { x, .. } = p else { return 0 }\n  x\n}\nfn main() { print(f(Point { x: 1, y: 2 })) }\n",
        "E0255",
        "this `let` always succeeds: `p` is a plain `Point` and the pattern always matches",
    );
    has_note(&d, "remove the `else` part");
}

//! Bitwise operators on `int` (`& | ^ ~ << >>` and their `&=`-style assignments): truth tables,
//! precedence and compound assignment in tests/fixtures/bitwise.duck, SHA-256 written in Duck
//! in tests/fixtures/sha256.duck (both under the leak checker), shift-range panics, and the
//! checker's and parser's diagnostics with their fix-its.

use std::path::PathBuf;
use std::process::{Command, Output};
use std::{env, fs};

fn duck_cmd() -> Command {
    let mut c = Command::new(env!("CARGO_BIN_EXE_duck"));
    c.env_remove("DUCK_CFLAGS").env("DUCK_LEAK_CHECK", "1");
    c
}

fn text(o: &Output) -> (String, String) {
    (String::from_utf8_lossy(&o.stdout).into_owned(), String::from_utf8_lossy(&o.stderr).into_owned())
}

fn scratch(name: &str, src: &str) -> PathBuf {
    let d = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("bitwise");
    fs::create_dir_all(&d).unwrap();
    let p = d.join(format!("{name}.duck"));
    fs::write(&p, src).unwrap();
    p
}

#[test]
fn operators_pass_their_tests() {
    let o = duck_cmd().args(["test", "tests/fixtures/bitwise.duck"]).output().unwrap();
    let (out, err) = text(&o);
    assert!(o.status.success(), "{out}\n{err}");
    assert_eq!(
        out,
        "ok and or xor truth tables\nok not\nok shifts\nok precedence\nok compound assignment\nok bytes\n6 passed, 0 failed\n",
        "{err}"
    );
}

#[test]
fn sha256_in_duck_matches_the_known_digests() {
    let o = duck_cmd().args(["test", "tests/fixtures/sha256.duck"]).output().unwrap();
    let (out, err) = text(&o);
    assert!(o.status.success(), "{out}\n{err}");
    assert_eq!(
        out,
        "ok sha256 of the empty string\nok sha256 of abc\nok sha256 of a two-block message\n3 passed, 0 failed\n",
        "{err}"
    );
}

#[test]
fn fixtures_are_fmt_clean() {
    let o = duck_cmd().args(["fmt", "--check", "tests/fixtures/bitwise.duck", "tests/fixtures/sha256.duck"]).output().unwrap();
    assert!(o.status.success(), "{:?}", text(&o));
}

#[test]
fn shift_amounts_outside_0_to_63_panic() {
    for (name, expr, n) in [
        ("shl64", "1 << n", "64"),
        ("shl_neg", "1 << n", "-1"),
        ("shr64", "-8 >> n", "64"),
        ("shr_big", "8 >> n", "1000"),
        ("shl_eq", "{\n    var x = 1\n    x <<= n\n    x\n  }", "65"),
    ] {
        let src = format!("fn main(args: [str]) {{\n  let n = int.parse(\"{n}\")!\n  print({expr})\n}}\n");
        let o = duck_cmd().arg("run").arg(scratch(name, &src)).output().unwrap();
        let (out, err) = text(&o);
        assert_eq!(o.status.code(), Some(101), "{name}: {out}\n{err}");
        assert!(err.starts_with(&format!("panic: shift amount {n} is outside 0..63\n")), "{name}: {err}");
        assert!(err.contains(&format!("{name}.duck:")), "{name}: the panic points at the shift: {err}");
    }
    // 0 and 63 are fine
    let src = "fn main() {\n  let n = int.parse(\"63\")!\n  print(\"{1 << n} {-1 >> n} {5 << 0} {5 >> 0}\")\n}\n";
    let o = duck_cmd().arg("run").arg(scratch("edges", src)).output().unwrap();
    let (out, err) = text(&o);
    assert!(o.status.success(), "{err}");
    assert_eq!(out, "-9223372036854775808 -1 5 5\n");
}

/// `duck check --json` on `src`.
fn check(name: &str, src: &str) -> String {
    let p = scratch(name, src);
    let o = duck_cmd().arg("check").arg(&p).arg("--json").output().unwrap();
    text(&o).0
}

#[test]
fn units_are_rejected_with_an_int_fix() {
    let out = check("unit", "fn f(n: int<B>): int = n & 0xff\n");
    assert!(out.contains(r#""code":"E0293""#), "{out}");
    assert!(out.contains("`&` works on bits, but this is `int<B>`, a value with a unit"), "{out}");
    assert!(out.contains(r#""fixes":[{"line":1,"col":24,"end_line":1,"end_col":24,"text":"int("},{"line":1,"col":25,"end_line":1,"end_col":25,"text":")"}]"#), "{out}");
    // every operator, either side, and compound assignment (no fix on an assignment target)
    for (i, body) in ["1 | n", "n ^ 1", "~n", "n << 1", "1 >> n"].iter().enumerate() {
        let out = check(&format!("unit{i}"), &format!("fn f(n: int<B>): int = {body}\n"));
        assert!(out.contains(r#""code":"E0293""#), "{body}: {out}");
    }
    let out = check("unit_assign", "fn f() {\n  var d = 3<m>\n  d <<= 1\n}\n");
    assert!(out.contains(r#""code":"E0293""#) && out.contains(r#""fixes":[]"#), "{out}");
    let out = check("unit_float", "fn f(d: float<m>): int = d & 1\n");
    assert!(out.contains(r#""code":"E0293""#) && out.contains(r#""fixes":[]"#), "{out}");
    // stripping the unit is fine
    let out = check("unit_ok", "fn f(n: int<B>): int = int(n) & 0xff\n");
    assert!(out.contains(r#""ok":true"#), "{out}");
}

#[test]
fn non_int_operands_are_rejected() {
    let out = check("bool", "fn f(a: bool, b: bool): bool = a | b\n");
    assert!(out.contains(r#""code":"E0260""#) && out.contains("for booleans use `||`"), "{out}");
    assert_eq!(out.matches(r#""code":"#).count(), 1, "one error, no cascade: {out}");
    let out = check("not_bool", "fn f(a: bool): bool = ~a\n");
    assert!(out.contains("for booleans use `!`"), "{out}");
    let out = check("float", "fn f(x: float): int = x >> 1\n");
    assert!(out.contains("can't apply `>>` to `float`"), "{out}");
    let out = check("str_assign", "fn f() {\n  var s = \"a\"\n  s |= 1\n}\n");
    assert!(out.contains("can't apply `|=` to `str`"), "{out}");
}

#[test]
fn bitwise_next_to_a_comparison_needs_parentheses() {
    let out = check("mix", "fn even(x: int): bool = x & 1 == 0\n");
    assert!(out.contains(r#""code":"E0038""#), "{out}");
    assert!(out.contains(r#""fixes":[{"line":1,"col":25,"end_line":1,"end_col":25,"text":"("},{"line":1,"col":30,"end_line":1,"end_col":30,"text":")"}]"#), "{out}");
    // applying the fix checks clean
    let out = check("mix_fixed", "fn even(x: int): bool = (x & 1) == 0\n");
    assert!(out.contains(r#""ok":true"#), "{out}");
}

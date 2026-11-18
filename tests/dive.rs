//! `auk dive`, the REPL, driven through piped stdin (`--quiet`: no banner, no prompts).

use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

mod auk_bin;

/// Run a dive session on `input`; returns its stdout (asserting a clean exit and empty stderr).
fn dive(input: &str) -> String {
    let mut child = Command::new(auk_bin::auk_bin())
        .args(["dive", "--quiet"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
    let out = child.wait_with_output().unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout).to_string();
    let stderr = String::from_utf8_lossy(&out.stderr).to_string();
    assert!(out.status.success(), "dive failed: {stderr}\n{stdout}");
    assert_eq!(stderr, "", "stdout:\n{stdout}");
    stdout
}

fn scratch(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("auk-dive-test-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&d);
    fs::create_dir_all(&d).unwrap();
    d
}

/// Show `got` in full on a mismatch (assert_eq! on long strings is hard to read).
fn same(got: &str, want: &str) {
    assert!(got == want, "--- got:\n{got}\n--- want:\n{want}\n--- end");
}

#[test]
fn scripted_session() {
    let dir = scratch("session");
    let saved = dir.join("session.auk");
    let saved = saved.display();
    let input = format!(
        r#"1 + 2 * 3
let xs = [1, 2, 3]
xs.map(x => x * 2)
fn sum_to(n: int): int {{
  var t = 0
  for i in 1..=n {{
    t += i
  }}
  t
}}
sum_to(10)
struct Point {{ x: float, y: float }}
enum Shape {{ Circle(r: float), Rect(w: float, h: float) }}
fn area(Circle(r)): float = 3.0 * r * r
fn area(Rect(w, h)): float = w * h
area(Rect(2.0, 3.5))
print("hello from a statement")
let p = Point {{ x: 1.0, y: 2.0 }}
p
"hi"
xs.len() + "a"
xs.len()
let big = 9223372036854775807
let boom = big + 1
big
:type xs.map(x => "{{x}}")
:items
:save {saved}
:reset
xs
:quit
1 + 1
"#
    );
    let want = format!(
        r#"7 : int
[2, 4, 6] : [int]
55 : int
7.0 : float
hello from a statement
Point {{ x: 1.0, y: 2.0 }} : Point
"hi" : str
dive:1:12: error[E0260]: can't apply `+` to `int` and `str`
  |
1 | xs.len() + "a"
  |            ^^^
  = note: both sides of an arithmetic operator have the same type
  = help: run `auk explain E0260` for details
3 : int
panic: integer overflow in `+`
  at dive:1:12
9223372036854775807 : int
[str]
fn sum_to(n: int): int
struct Point {{ x: float, y: float }}
enum Shape {{ Circle(r: float), Rect(w: float, h: float) }}
fn area(Circle(r)): float  (2 clauses)
saved {saved}
session cleared
dive:1:1: error[E0102]: unknown name `xs`
  |
1 | xs
  | ^^
  = help: run `auk explain E0102` for details
"#
    );
    same(&dive(&input), &want);
    let file = fs::read_to_string(dir.join("session.auk")).unwrap();
    same(
        &file,
        r#"fn sum_to(n: int): int {
  var t = 0
  for i in 1..=n {
    t += i
  }
  t
}

struct Point { x: float, y: float }

enum Shape { Circle(r: float), Rect(w: float, h: float) }

fn area(Circle(r)): float = 3.0 * r * r
fn area(Rect(w, h)): float = w * h

fn main(): ()! {
  let xs = [1, 2, 3]
  print("hello from a statement")
  let p = Point { x: 1.0, y: 2.0 }
  let big = 9223372036854775807
}
"#,
    );
    // The saved session is a program that checks, formats as is and runs.
    let fmt = Command::new(auk_bin::auk_bin()).args(["fmt", "--check"]).arg(dir.join("session.auk")).output().unwrap();
    assert!(fmt.status.success(), "{}", String::from_utf8_lossy(&fmt.stderr));
    let run = Command::new(auk_bin::auk_bin()).arg("run").arg(dir.join("session.auk")).output().unwrap();
    assert_eq!(String::from_utf8_lossy(&run.stdout), "hello from a statement\n");
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn clauses_redefinition_and_unshowable_values() {
    let input = r#"fn fib(0): int = 0
fn fib(1): int = 1
fn fib(n: int): int = fib(n - 1) + fib(n - 2)
fib(20)
fn fib(n: int): int = n * 2
fib(20)
fn g(0): int = 0
1 + 1
let inc = (x: int) => x + 1
inc
var ys = [1]
ys.push(2)
ys.push(inc(2))
ys
let total =
  ys.sum()
total
"#;
    let want = r#"6765 : int
40 : int
dive:1:4: error[E0400]: the clauses of `g` don't cover every case: `g(_)` is not handled
  |
1 | fn g(0): int = 0
  |    ^
  = note: add a clause for each missing case
  = fix: insert `
fn g(_): int = ??` at 1:17
  = help: run `auk explain E0400` for details
2 : int
<fn> : (int) => int
[1, 2, 3] : [int]
6 : int
"#;
    same(&dive(input), want);
}

#[test]
fn errors_map_to_the_input_lines_and_load_skips_main() {
    let dir = scratch("load");
    let lib = dir.join("lib.auk");
    fs::write(&lib, "fn double(x: int): int = x * 2\n\nfn main() {\n  print(double(2))\n}\n").unwrap();
    let input = format!(
        r#":load {lib}
double(21)
fn bad(x: int): int {{
  let y = x + 1
  y + "s"
}}
:items
let s = [1,
  2,

:help
"#,
        lib = lib.display()
    );
    let out = dive(&input);
    let want_head = format!(
        r#"note: skipped `main` in {lib}
loaded {lib}
42 : int
dive:3:7: error[E0260]: can't apply `+` to `int` and `str`
  |
3 |   y + "s"
  |       ^^^
  = note: both sides of an arithmetic operator have the same type
  = help: run `auk explain E0260` for details
fn double(x: int): int
dive:1:9: error[E0012]: unclosed `[`
"#,
        lib = lib.display()
    );
    assert!(out.starts_with(&want_head), "--- got:\n{out}\n--- want prefix:\n{want_head}");
    assert!(out.contains("Each input compiles and runs a small native program"), "{out}");
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn bad_flag() {
    let out = Command::new(auk_bin::auk_bin()).args(["dive", "--nope"]).stdin(Stdio::null()).output().unwrap();
    assert_eq!(out.status.code(), Some(2));
}

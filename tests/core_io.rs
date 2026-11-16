//! Core console and file I/O end to end: stdin (`env.read_line`, `env.read_all`,
//! `env.lines`), `eprint`, `proc.exit`, the `fs` extras, binary files, and `rand.bytes`,
//! `rand.shuffle`, `rand.choice` and `rand.seed`. Every program runs under `DUCK_LEAK_CHECK`.

use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};
use std::{env, fs};

fn scratch(name: &str) -> PathBuf {
    let d = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("core_io").join(name);
    let _ = fs::remove_dir_all(&d);
    fs::create_dir_all(&d).unwrap();
    d
}

fn duck_cmd() -> Command {
    let mut c = Command::new(env!("CARGO_BIN_EXE_duck"));
    c.env("DUCK_LEAK_CHECK", "1");
    c
}

/// `duck run` a program (written to its own scratch dir) with `args`, feeding it `stdin`.
fn run(name: &str, src: &str, args: &[&str], stdin: &str) -> Output {
    let d = scratch(name);
    let p = d.join("main.duck");
    fs::write(&p, src).unwrap();
    let mut child = duck_cmd()
        .arg("run")
        .arg(&p)
        .args(args)
        .current_dir(&d)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(stdin.as_bytes()).unwrap();
    child.wait_with_output().unwrap()
}

fn text(o: &Output) -> (String, String) {
    (String::from_utf8_lossy(&o.stdout).into_owned(), String::from_utf8_lossy(&o.stderr).into_owned())
}

/// Runs successfully and prints `want` (and nothing on stderr).
fn expect(name: &str, src: &str, stdin: &str, want: &str) {
    let o = run(name, src, &[], stdin);
    let (out, err) = text(&o);
    assert!(o.status.success(), "{name} failed ({:?}):\n{out}\n{err}", o.status.code());
    assert_eq!(out, want, "{name} stderr:\n{err}");
    assert_eq!(err, "", "{name}");
}

#[test]
fn stdin_lines_are_counted() {
    let src = "fn main() uses env {\n  let xs = env.lines()\n  print(\"{xs.len()} {xs}\")\n}\n";
    expect("lines", src, "a\nbb\r\n\nlast", "4 [\"a\", \"bb\", \"\", \"last\"]\n");
    expect("lines_empty", src, "", "0 []\n");
}

#[test]
fn stdin_read_line_then_the_rest() {
    let src = "fn main(): ()! uses env {\n  var n = 0\n  while n < 2 {\n    let l = env.read_line() else { break }\n    print(\"line {l.len()}: {l}\")\n    n += 1\n  }\n  print(\"rest: {(env.read_all()?).trim()}\")\n  print(env.read_line())\n  print((env.read_all()?).len())\n}\n";
    expect("read_line", src, "héllo\r\nworld\nthe\nend\n", "line 5: héllo\nline 5: world\nrest: the\nend\nnone\n0\n");
    // invalid UTF-8 (raw bytes, so not through `run`)
    let d = scratch("read_all_bad_utf8");
    fs::write(d.join("main.duck"), "fn main(): ()! uses env { print(env.read_all()?) }\n").unwrap();
    let mut c = duck_cmd()
        .arg("run")
        .arg(d.join("main.duck"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    c.stdin.take().unwrap().write_all(b"bad \xff\n").unwrap();
    let o = c.wait_with_output().unwrap();
    assert_eq!(o.status.code(), Some(1));
    assert!(text(&o).1.starts_with("error: env.read_all: stdin: invalid UTF-8"), "{}", text(&o).1);
}

#[test]
fn eprint_goes_to_stderr_only() {
    let src = "struct P { x: int }\nfn main() {\n  print(\"out\")\n  eprint(\"err {1 + 1}\")\n  eprint(P { x: 3 })\n  print(\"out2\")\n}\n";
    let o = run("eprint", src, &[], "");
    let (out, err) = text(&o);
    assert!(o.status.success(), "{err}");
    assert_eq!(out, "out\nout2\n");
    assert_eq!(err, "err 2\nP { x: 3 }\n");
}

#[test]
fn exit_codes_flush_and_pass_the_leak_check() {
    // from main, with live heap values: they're released first, so the leak check passes
    let src = "fn main(): int uses proc {\n  let xs = [\"a\", \"b\"]\n  let m = {\"k\": xs}\n  print(\"before {m}\")\n  if xs.len() == 2 { proc.exit(3) }\n  print(\"after\")\n  0\n}\n";
    let o = run("exit3", src, &[], "");
    let (out, err) = text(&o);
    assert_eq!(o.status.code(), Some(3), "{err}");
    assert_eq!(out, "before {\"k\": [\"a\", \"b\"]}\n");
    assert_eq!(err, "");
    // never-typed: it fills any type, e.g. a `let ... else`
    let src = "fn main() uses env, proc {\n  let home = env.get(\"DUCK_NO_SUCH_VAR\") else proc.exit(0)\n  print(home)\n}\n";
    let o = run("exit0", src, &[], "");
    assert_eq!(o.status.code(), Some(0));
    assert_eq!(text(&o), (String::new(), String::new()));
    let src = "fn die(n: int): int uses proc = proc.exit(n)\nfn main() uses proc {\n  eprint(\"bye\")\n  print(die(42))\n}\n";
    let o = run("exit42", src, &[], "");
    assert_eq!(o.status.code(), Some(42));
    assert_eq!(text(&o).1, "bye\n");
    let o = run("exit_range", "fn main() uses proc { proc.exit(256) }\n", &[], "");
    assert_eq!(o.status.code(), Some(101));
    assert!(text(&o).1.starts_with("panic: proc.exit(256): code out of range 0..255\n  at "), "{}", text(&o).1);
}

#[test]
fn fs_round_trip_in_a_temp_dir() {
    let src = r#"fn main(): ()! uses fs {
  let d = fs.temp_dir()?
  assert fs.is_dir(d) && (fs.list(d)?).len() == 0
  fs.mkdir("{d}/x/y/z")?
  fs.mkdir("{d}/x/y")?
  fs.write("{d}/b.txt", "one\n")?
  fs.append("{d}/b.txt", "two\n")?
  fs.append("{d}/a.txt", "new")?
  print(fs.list(d)?)
  print(fs.lines("{d}/b.txt")?)
  fs.rename("{d}/a.txt", "{d}/x/c.txt")?
  print("{fs.exists("{d}/a.txt")} {fs.exists("{d}/x/c.txt")} {fs.is_dir("{d}/x/c.txt")}")
  print(fs.remove("{d}/x") is err(_))
  print(fs.list("{d}/nope") is err(_))
  fs.remove("{d}/x/c.txt")?
  fs.remove("{d}/x/y/z")?
  fs.remove("{d}/x/y")?
  fs.remove("{d}/x")?
  fs.remove("{d}/b.txt")?
  fs.remove(d)?
  print(fs.exists(d))
}
"#;
    expect("fs", src, "", "[\"a.txt\", \"b.txt\", \"x\"]\n[\"one\", \"two\"]\nfalse true false\ntrue\ntrue\nfalse\n");
}

#[test]
fn bytes_round_trip() {
    let src = r#"fn main(): ()! uses fs {
  let d = fs.temp_dir()?
  let p = "{d}/data.bin"
  let bs = (0..256).map(i => (i * 7 + 3) % 256)
  fs.write_bytes(p, bs)?
  let back = fs.read_bytes(p)?
  print("{back.len()} {back == bs} {back.take(3)}")
  print(fs.write_bytes(p, [1, 300]) else e => print("{e}"))
  print((fs.read_bytes(p)?).len())
  fs.write_bytes(p, "hé".bytes())?
  print(fs.read(p)?)
  fs.remove(p)?
  fs.remove(d)?
}
"#;
    let o = run("bytes", src, &[], "");
    let (out, err) = text(&o);
    assert!(o.status.success(), "{out}\n{err}");
    let lines: Vec<&str> = out.lines().collect();
    assert_eq!(lines[0], "256 true [3, 10, 17]");
    assert!(lines[1].starts_with("fs.write_bytes ") && lines[1].ends_with("data.bin: byte 300 at index 1 is out of range 0..255"), "{out}");
    assert_eq!(&lines[3..], ["256", "hé"]);
}

#[test]
fn secure_and_seeded_random() {
    let src = r#"fn main() uses rand {
  let a = rand.bytes(32)
  let b = rand.bytes(32)
  print("{a.len()} {a != b} {a.all(x => x >= 0 && x <= 255)}")
  let xs = [1, 2, 3, 4, 5, 6, 7, 8]
  let s = rand.shuffle(xs)
  print("{s.sort() == xs} {xs}")
  rand.seed(7)
  let s1 = rand.shuffle(xs)
  let c1 = rand.choice(xs)
  rand.seed(7)
  print("{rand.shuffle(xs) == s1} {rand.choice(xs) == c1}")
  let none_: [str] = []
  print(rand.choice(none_))
  print(rand.choice(["only"]))
  print(rand.shuffle(none_))
}
"#;
    expect("rand", src, "", "32 true true\ntrue [1, 2, 3, 4, 5, 6, 7, 8]\ntrue true\nnone\nsome(\"only\")\n[]\n");
}

#[test]
fn new_effectful_functions_need_their_effect() {
    let d = scratch("effects");
    let cases = [
        ("list", "fn names(d: str): [str]! = fs.list(d)\nfn main() { print(names(\".\")) }\n", "fs"),
        ("stdin", "fn first(): str? = env.read_line()\nfn main() { print(first()) }\n", "env"),
        ("exit", "fn quit() { proc.exit(1) }\nfn main() { quit() }\n", "proc"),
        ("bytes", "fn token(): [int] = rand.bytes(16)\nfn main() { print(token()) }\n", "rand"),
        ("shuffle", "fn mix(xs: [int]): [int] = rand.shuffle(xs)\nfn main() { print(mix([1])) }\n", "rand"),
    ];
    for (name, src, effect) in cases {
        let p = d.join(format!("{name}.duck"));
        fs::write(&p, src).unwrap();
        let o = duck_cmd().arg("check").arg(&p).output().unwrap();
        let err = String::from_utf8_lossy(&o.stderr).into_owned() + &String::from_utf8_lossy(&o.stdout);
        assert!(!o.status.success(), "{name}: expected E0410");
        assert!(err.contains("E0410") && err.contains(&format!("uses {effect}")), "{name}:\n{err}");
    }
    // `eprint`, like `print`, needs no effect
    let p = d.join("eprint.duck");
    fs::write(&p, "fn warn(s: str) { eprint(\"warning: {s}\") }\nfn main() { warn(\"x\") }\n").unwrap();
    let o = duck_cmd().arg("check").arg(&p).output().unwrap();
    assert!(o.status.success(), "{}", String::from_utf8_lossy(&o.stderr));
}

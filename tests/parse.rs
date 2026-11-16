//! The front end via the hidden `duck parse` command: the whole corpus parses, and small
//! programs dump to the expected AST.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicUsize, Ordering};

fn duck(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_duck")).args(args).output().unwrap()
}

fn duck_files(dir: &Path) -> Vec<PathBuf> {
    let mut paths: Vec<_> = fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|e| e == "duck"))
        .collect();
    paths.sort();
    paths
}

/// `examples/*.duck` plus `packages/*/src/*.duck`.
fn corpus() -> Vec<PathBuf> {
    let mut files = duck_files(Path::new("examples"));
    let mut pkgs: Vec<_> = fs::read_dir("packages").unwrap().map(|e| e.unwrap().path().join("src")).filter(|p| p.is_dir()).collect();
    pkgs.sort();
    for p in pkgs {
        files.extend(duck_files(&p));
    }
    files
}

/// Write `src` to a scratch file and run `duck parse <args> <file>`.
fn parse_src(args: &[&str], src: &str) -> Output {
    static N: AtomicUsize = AtomicUsize::new(0);
    let n = N.fetch_add(1, Ordering::SeqCst);
    let path = std::env::temp_dir().join(format!("duck-parse-{}-{n}.duck", std::process::id()));
    fs::write(&path, src).unwrap();
    let mut all = vec!["parse"];
    all.extend(args);
    all.push(path.to_str().unwrap());
    let out = duck(&all);
    let _ = fs::remove_file(&path);
    out
}

fn ast(src: &str) -> String {
    let out = parse_src(&["--ast"], src);
    assert!(out.status.success(), "parse failed:\n{}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8(out.stdout).unwrap()
}

#[test]
fn corpus_parses() {
    let files = corpus();
    assert!(files.len() >= 17, "corpus too small: {files:?}");
    let mut failed = Vec::new();
    for f in &files {
        let out = duck(&["parse", f.to_str().unwrap()]);
        if !out.status.success() || out.stdout != b"ok\n" {
            failed.push(format!("{}:\n{}", f.display(), String::from_utf8_lossy(&out.stderr)));
        }
    }
    assert!(failed.is_empty(), "{} corpus file(s) failed to parse:\n{}", failed.len(), failed.join("\n"));
}

#[test]
fn ast_snapshots() {
    assert_eq!(
        ast("fn fib(0): int = 0\nfn fib(1): int = 1\nfn fib(n: int): int = fib(n - 1) + fib(n - 2)\n"),
        "\
(fn fib/1
  (clause (params 0) : int = 0)
  (clause (params 1) : int = 1)
  (clause (params (n: int)) : int = (+ (call fib (- n 1)) (call fib (- n 2)))))
"
    );
    assert_eq!(
        ast("struct Point { x: float, y: float }\nlet p = Point { x: 1.0, ..o }\n"),
        "(struct Point (x float) (y float))\n(let p (new Point (x 1.0) (.. o)))\n"
    );
    assert_eq!(
        ast("fn f(xs: [int]): int! uses fs {\n  let [h, ..t] = xs else { return 0 }\n  let page = await get(u)?\n  xs\n    |> map(x => x * 2)?\n}\n"),
        "\
(fn f/1
  (clause (params (xs: [int])) : int! (uses fs) (block (let (list h (.. t)) xs (else (block (return 0)))) (let page (? (await (call get u)))) (? (|> xs map (closure (x) (* x 2)))))))
"
    );
    assert_eq!(
        ast("test \"s\" {\n  assert \"{n:>5} {if a { \"x\" } else { \"y\" }}\" == \"\"\"\n    ok\n    \"\"\"\n}\n"),
        "(test \"s\" (block (assert (== (str (fmt n \">5\") \" \" (if a (block \"x\") (block \"y\"))) \"ok\\n\"))))\n"
    );
    assert_eq!(
        ast("enum E { A(x: int), B }\nfn g(e: E): int = match e {\n  A(x) when x > 0 => x, B => 0\n  _ => -1\n}\n"),
        "(enum E (A (x int)) B)\n(fn g/1\n  (clause (params (e: E)) : int = (match e ((A x) when (> x 0) => x) (B => 0) (_ => (- 1)))))\n"
    );
    // `?.N` (a tuple element) composes like `.N`
    assert_eq!(ast("fn f() = xs.first()?.1?.len()\n"), "(fn f/0\n  (clause (params) = (?. (?. (method xs first) 1) len (args))))\n");
}

#[test]
fn errors_render_with_codes() {
    let out = parse_src(&[], "fn main() {\n  let x = 1;\n}\n");
    assert!(!out.status.success());
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains(":2:12: error[E0011]: Duck does not use semicolons\n"), "{err}");
    assert!(err.contains("2 |   let x = 1;\n  |",), "{err}");
    assert!(err.contains("           ^\n"), "{err}");

    let out = parse_src(&["--json"], "fn f() -> int = 1\n");
    assert!(!out.status.success());
    let json = String::from_utf8_lossy(&out.stdout);
    assert!(json.contains(r#""ok":false,"diagnostics":[{"code":"E0035","severity":"error","line":1,"col":8,"end_line":1,"end_col":10,"#), "{json}");
    assert!(json.contains(r#""fixes":[{"line":1,"col":8,"end_line":1,"end_col":10,"text":":"}]"#), "{json}");

    let out = parse_src(&["--json"], "fn f() = 1\n");
    assert!(out.status.success());
    assert!(String::from_utf8_lossy(&out.stdout).contains(r#""ok":true,"diagnostics":[]"#));
}

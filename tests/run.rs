//! The back end end to end: programs are compiled to C, linked with the runtime and run.
//!
//! - `examples` programs with a `main` run and print their expected output (with fixtures
//!   supplied here: a text file for `wc`, a CSV for `csv_stats`, a temp dir for
//!   `todo`, a local HTTP listener for `fetch`);
//! - `auk test` passes for every example with tests (except `hatch.auk`, whose holes must fail
//!   its tests) and for every package, one file at a time and as a flat directory;
//! - leak checks (`AUK_LEAK_CHECK`), a sanitizer run, and codegen edge cases;
//! - every `tests/errors` program fails `auk check` with the code in its header;
//! - `auk spec` prints docs/spec.md.

use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::Once;
use std::{env, fs, thread};

fn auk_cmd() -> Command {
    let mut c = Command::new(env!("CARGO_BIN_EXE_auk"));
    c.env_remove("AUK_LEAK_CHECK");
    c
}

fn auk(args: &[&str]) -> Output {
    auk_cmd().args(args).output().unwrap()
}

fn text(o: &Output) -> (String, String) {
    (String::from_utf8_lossy(&o.stdout).into_owned(), String::from_utf8_lossy(&o.stderr).into_owned())
}

/// `raft install` in `dir` (regenerating a stale lock, as tests/check.rs does).
fn install(dir: &str) {
    let run = || Command::new(env!("CARGO_BIN_EXE_raft")).arg("install").current_dir(dir).output().unwrap();
    if !run().status.success() {
        let _ = fs::remove_file(Path::new(dir).join("raft.lock"));
        let _ = fs::remove_dir_all(Path::new(dir).join(".raft"));
        let out = run();
        assert!(out.status.success(), "raft install in {dir} failed:\n{}", String::from_utf8_lossy(&out.stderr));
    }
}

fn setup() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        install("examples");
        install("packages/http");
        install("packages/url");
        install("packages/log");
    });
}

fn scratch(name: &str) -> PathBuf {
    let d = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("run").join(name);
    let _ = fs::remove_dir_all(&d);
    fs::create_dir_all(&d).unwrap();
    d
}

fn abs(p: &str) -> String {
    Path::new(env!("CARGO_MANIFEST_DIR")).join(p).display().to_string()
}

fn run_ok(args: &[&str]) -> String {
    let o = auk(args);
    let (out, err) = text(&o);
    assert!(o.status.success(), "auk {args:?} failed ({:?}):\n{out}\n{err}", o.status.code());
    out
}

// ---- examples with a main ----

/// Examples with a `.out` file: deterministic programs that need no input.
#[test]
fn wc_counts_words_in_a_file() {
    setup();
    let out = run_ok(&["run", "examples/wc.auk", "tests/fixtures/words.txt"]);
    assert_eq!(
        out,
        " 1. the             5\n 2. raft            3\n 3. fox             2\n 4. dog             2\n 5. a               2\n 6. quick           1\n 7. brown           1\n 8. jumps           1\n 9. over            1\n10. lazy            1\n"
    );
    let o = auk(&["run", "examples/wc.auk"]);
    assert_eq!(o.status.code(), Some(2));
    assert_eq!(text(&o).0, "usage: wc <file>\n");
    let o = auk(&["run", "examples/wc.auk", "tests/fixtures/no-such-file.txt"]);
    assert_eq!(o.status.code(), Some(1));
    assert!(text(&o).1.starts_with("error: "), "{}", text(&o).1);
}

/// `auk run examples/grep.auk <pattern>` with `input` piped to stdin, under the leak check.
fn grep(args: &[&str], input: &str) -> Output {
    let mut c = auk_cmd()
        .args(["run", "examples/grep.auk"])
        .args(args)
        .env("AUK_LEAK_CHECK", "1")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    c.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
    c.wait_with_output().unwrap()
}

#[test]
fn grep_filters_stdin_with_line_numbers() {
    setup();
    let o = grep(&["auk"], "an auk\nno\r\n\nauks raft\nend");
    assert_eq!(o.status.code(), Some(0), "{:?}", text(&o));
    assert_eq!(text(&o), ("1: an auk\n4: auks raft\n".to_string(), String::new()));
    let o = grep(&["swan"], "an auk\n");
    assert_eq!(o.status.code(), Some(1));
    assert_eq!(text(&o), (String::new(), String::new()));
    let o = grep(&[], "");
    assert_eq!(o.status.code(), Some(2));
    assert_eq!(text(&o), (String::new(), "usage: grep <pattern>\n".to_string()));
}

#[test]
fn csv_stats_summarizes_a_column() {
    setup();
    let out = run_ok(&["run", "examples/csv_stats.auk", "tests/fixtures/stats.csv", "price"]);
    assert_eq!(out, "n=4 mean=3.65 min=0.1 max=12.75 sd=5.282\n");
    let out = run_ok(&["run", "examples/csv_stats.auk", "tests/fixtures/stats.csv", "qty"]);
    assert_eq!(out, "n=4 mean=5.25 min=1.0 max=10.0 sd=3.491\n");
    let o = auk(&["run", "examples/csv_stats.auk", "tests/fixtures/stats.csv", "nope"]);
    assert_eq!(o.status.code(), Some(1));
    assert_eq!(text(&o).1, "error: no column nope\n");
}

/// `examples/aconv.auk`: generate a tone, filter it into a FLAC file, probe it, and measure it.
#[test]
fn aconv_generates_converts_and_probes() {
    setup();
    let d = scratch("aconv");
    let flac = d.join("tone.flac");
    let f = flac.to_str().unwrap();
    let out = run_ok(&["run", "examples/aconv.auk", "-f", "lavfi", "-i", "sine=f=1000:d=0.5:r=8000", "-af", "volume=6dB,afade=t=out:d=0.1", "-metadata", "title=Beep", f]);
    assert!(out.contains("tone.flac: flac, 8000 Hz, 1 ch, 00:00:00.500,"), "{out}");
    let out = run_ok(&["run", "examples/aconv.auk", "-i", f]);
    assert!(out.contains("Stream: Audio: flac (flac), 8000 Hz, 1 channels, 16 bits") && out.contains("title           : Beep"), "{out}");
    let wav = d.join("half.wav");
    let out = run_ok(&["run", "examples/aconv.auk", "-i", f, "-t", "0.25", "-ar", "16000", "-ac", "2", "-sample_fmt", "s24", "-stats", wav.to_str().unwrap()]);
    assert!(out.contains("channel 1: peak -12.0") && out.contains("half.wav: pcm_s24le, 16000 Hz, 2 ch, 00:00:00.250"), "{out}");
    let o = auk(&["run", "examples/aconv.auk", "-i", "tests/fixtures/words.txt"]);
    assert_eq!(o.status.code(), Some(1));
    assert!(text(&o).1.contains("unsupported: unknown file format"), "{:?}", text(&o));
}

#[test]
fn todo_keeps_a_json_file() {
    setup();
    let dir = scratch("todo");
    let todo = abs("examples/todo.auk");
    let go = |args: &[&str]| {
        let o = auk_cmd().arg("run").arg(&todo).args(args).current_dir(&dir).output().unwrap();
        (o.status.code(), text(&o).0, text(&o).1)
    };
    assert_eq!(go(&["add", "buy", "milk"]).0, Some(0));
    assert_eq!(go(&["add", "walk", "the", "auk"]).0, Some(0));
    assert_eq!(go(&["done", "1"]).0, Some(0));
    assert_eq!(go(&["ls"]), (Some(0), "x 1. buy milk\n  2. walk the auk\n".into(), String::new()));
    assert_eq!(
        fs::read_to_string(dir.join("todos.json")).unwrap(),
        r#"[{"done":true,"id":1,"text":"buy milk"},{"done":false,"id":2,"text":"walk the auk"}]"#
    );
    assert_eq!(go(&["done", "9"]), (Some(1), String::new(), "error: no todo #9\n".into()));
    assert_eq!(go(&["done", "x"]), (Some(1), String::new(), "error: not a number: x\n".into()));
    assert_eq!(go(&[]), (Some(1), String::new(), "error: usage: todo add|done|ls\n".into()));
}

/// A tiny HTTP server on 127.0.0.1: `/ok` is 200, anything else 404. Serves `n` connections.
fn serve(n: usize) -> u16 {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = l.local_addr().unwrap().port();
    thread::spawn(move || {
        for s in l.incoming().take(n) {
            let Ok(mut s) = s else { continue };
            let mut req = Vec::new();
            let mut buf = [0u8; 1024];
            while !req.windows(4).any(|w| w == b"\r\n\r\n") {
                match s.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(k) => req.extend_from_slice(&buf[..k]),
                }
            }
            let line = String::from_utf8_lossy(&req).lines().next().unwrap_or("").to_string();
            let (status, body) = if line.starts_with("GET /ok ") { ("200 OK", "hello") } else { ("404 Not Found", "nope") };
            let resp = format!("HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
            let _ = s.write_all(resp.as_bytes());
        }
    });
    port
}

#[test]
fn fetch_checks_urls_concurrently() {
    setup();
    let port = serve(2);
    // a port nothing listens on
    let closed = {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        l.local_addr().unwrap().port()
    };
    let ok = format!("http://127.0.0.1:{port}/ok");
    let missing = format!("http://127.0.0.1:{port}/missing");
    let refused = format!("http://127.0.0.1:{closed}/x");
    let o = auk(&["run", "examples/fetch.auk", &ok, &missing, &refused]);
    let (out, err) = text(&o);
    assert_eq!(o.status.code(), Some(1), "{out}\n{err}");
    let lines: Vec<&str> = out.lines().collect();
    assert_eq!(lines.len(), 3, "{out}");
    assert!(lines[0].starts_with("✓ 200 ") && lines[0].ends_with(&format!("ms {ok}")), "{out}");
    assert_eq!(lines[1], format!("✗ 404 {missing}"));
    assert!(lines[2].starts_with("✗ ERR "), "{out}");
    // all good: exit 0
    let port = serve(1);
    let ok = format!("http://127.0.0.1:{port}/ok");
    let o = auk(&["run", "examples/fetch.auk", &ok]);
    assert_eq!(o.status.code(), Some(0), "{:?}", text(&o));
}

// ---- auk test ----

#[test]
fn example_tests_pass() {
    setup();
    let mut n = 0;
    for name in ["bank", "calc", "fib", "physics", "router", "tour"] {
        let out = run_ok(&["test", &format!("examples/{name}.auk")]);
        assert!(out.ends_with(" passed, 0 failed\n") && !out.contains("FAIL"), "{name}:\n{out}");
        n += 1;
    }
    assert_eq!(n, 6);
}

#[test]
fn hatch_tests_fail_on_unfilled_holes() {
    setup();
    let o = auk(&["test", "examples/hatch.auk"]);
    let (out, _) = text(&o);
    assert_eq!(o.status.code(), Some(1));
    assert!(out.ends_with("0 passed, 3 failed\n"), "{out}");
    for t in ["median", "dedup", "seconds"] {
        assert!(out.contains(&format!("FAIL {t}\n")), "{out}");
    }
    assert!(out.contains("panic: unfilled hole (expected float)\n      at examples/hatch.auk:"), "{out}");
    assert!(out.contains("panic: unfilled hole (expected [int])"), "{out}");
    assert!(out.contains("panic: unfilled hole (expected int!DurErr)"), "{out}");
}

/// `auk test` on a flat directory (no `src/lib.auk` or `src/main.auk`): every top-level file
/// with tests is its own program, run in sorted order under a header, with a combined summary.
#[test]
fn test_command_runs_each_file_of_a_flat_dir() {
    setup();
    let o = auk(&["test", "examples"]);
    let (out, err) = text(&o);
    assert_eq!(o.status.code(), Some(1), "hatch's holes must fail the run:\n{out}\n{err}");
    let headers: Vec<&str> = out.lines().filter(|l| l.starts_with("== ")).collect();
    assert_eq!(
        headers,
        ["== bank.auk", "== calc.auk", "== fib.auk", "== hatch.auk", "== physics.auk", "== router.auk", "== tour.auk", "== 7 files: 6 passed, 3 failed"],
        "{out}"
    );
    // each file's own report sits under its header; only hatch fails
    let section = |name: &str| out.split(&format!("== {name}\n")).nth(1).unwrap().split("\n== ").next().unwrap().to_string();
    for name in ["bank", "calc", "fib", "physics", "router", "tour"] {
        let sec = section(&format!("{name}.auk"));
        assert!(sec.ends_with(" passed, 0 failed") && !sec.contains("FAIL"), "{name}:\n{sec}");
    }
    let hatch = section("hatch.auk");
    assert!(hatch.contains("FAIL median\n") && hatch.ends_with("0 passed, 3 failed"), "{hatch}");
    // files without tests (hello, wc, ...) are skipped
    assert!(!out.contains("hello.auk") && !err.contains("no `test` blocks"), "{out}\n{err}");
    // a filter applies to every file
    let out = run_ok(&["test", "examples", "calc"]);
    assert!(out.contains("== calc.auk\nok calc\n1 passed, 0 failed\n"), "{out}");
    assert!(out.ends_with("== 7 files: 1 passed, 0 failed\n"), "{out}");
}

#[test]
fn package_tests_pass() {
    setup();
    // (package, minimum number of test blocks it has), so a silently skipped suite is caught.
    let pkgs = [
        ("json", 16), ("csv", 11), ("regex", 15), ("cli", 11), ("http", 32), ("encoding", 8),
        ("hash", 8), ("datetime", 19), ("url", 13), ("toml", 23), ("log", 6), ("uuid", 8),
        ("num", 15), ("text", 14), ("glob", 8), ("compress", 9), ("yaml", 14), ("xml", 11), ("sup", 7), ("splash", 24), ("audio", 17), ("graphics", 7),
    ];
    for (pkg, min) in pkgs {
        let out = run_ok(&["test", &format!("packages/{pkg}/src/lib.auk")]);
        assert!(out.ends_with(" passed, 0 failed\n") && !out.contains("FAIL"), "{pkg}:\n{out}");
        let passed: usize = out.lines().last().unwrap().split(' ').next().unwrap().parse().unwrap();
        assert!(passed >= min, "{pkg}: only {passed} tests ran, expected at least {min}");
    }
}

#[test]
fn test_command_filters_and_takes_a_project_dir() {
    setup();
    let out = run_ok(&["test", "packages/regex/src/lib.auk", "captures"]);
    assert_eq!(out, "ok captures\n1 passed, 0 failed\n");
    let out = run_ok(&["test", "packages/csv"]);
    assert!(out.ends_with("11 passed, 0 failed\n"), "{out}");
    // dependencies' tests are excluded: http depends on json
    let out = run_ok(&["test", "packages/http/src/lib.auk"]);
    assert!(!out.contains("ok literals and whitespace"), "{out}");
}

// ---- leaks and sanitizers ----

#[test]
fn no_leaks_in_corpus_tests() {
    setup();
    for f in ["examples/calc.auk", "examples/bank.auk", "examples/router.auk", "examples/tour.auk", "packages/json/src/lib.auk", "packages/regex/src/lib.auk", "packages/csv/src/lib.auk", "packages/cli/src/lib.auk", "packages/http/src/lib.auk"] {
        let o = auk_cmd().args(["test", f]).env("AUK_LEAK_CHECK", "1").output().unwrap();
        let (out, err) = text(&o);
        assert!(o.status.success(), "{f} leaks or fails:\n{out}\n{err}");
        assert!(!out.contains("leak:"), "{f}:\n{out}");
    }
}

#[test]
fn no_leaks_in_programs() {
    setup();
    for args in [
        vec!["run", "examples/inventory.auk"],
        vec!["run", "examples/life.auk"],
        vec!["run", "examples/tour.auk"],
        vec!["run", "examples/wc.auk", "tests/fixtures/words.txt"],
        vec!["run", "examples/csv_stats.auk", "tests/fixtures/stats.csv", "price"],
    ] {
        let o = auk_cmd().args(&args).env("AUK_LEAK_CHECK", "1").output().unwrap();
        assert!(o.status.success(), "{args:?}: {:?}", text(&o));
    }
}

/// Every package's tests pass with the leak checker on: each test (a forked child) frees every
/// runtime object it made.
#[test]
fn package_tests_are_leak_free() {
    setup();
    // sup's tests crash and cancel children on purpose: their heaps must be swept clean
    for pkg in ["json", "csv", "regex", "cli", "http", "encoding", "hash", "datetime", "url", "toml", "log", "uuid", "num", "text", "glob", "compress", "yaml", "xml", "sup", "splash", "audio"] {
        let o = auk_cmd().args(["test", &format!("packages/{pkg}/src/lib.auk")]).env("AUK_LEAK_CHECK", "1").output().unwrap();
        let (out, err) = text(&o);
        assert!(o.status.success() && out.ends_with(" 0 failed\n"), "{pkg} with the leak checker:\n{out}\n{err}");
        assert!(!out.contains("leak") && !err.contains("leak"), "{pkg}:\n{out}\n{err}");
    }
}

/// `auk ir` prints the MIR and `auk ir --llvm` the LLVM IR, for real programs.
#[test]
fn ir_prints_mir_and_llvm() {
    setup();
    for f in ["examples/tour.auk", "examples/fetch.auk", "examples/grep.auk", "examples/life.auk"] {
        let mir = run_ok(&["ir", f]);
        assert!(mir.contains("dk_entry(") && mir.contains("auk_main_wrapper("), "{f}");
        let ll = run_ok(&["ir", "--llvm", f]);
        assert!(ll.contains("define ") && ll.contains(" @main(") && ll.contains("call "), "{f}");
    }
}

// ---- codegen edge cases ----

/// Write a program to a scratch file and `auk run` it with the leak checker on.
fn run_src(name: &str, src: &str) -> Output {
    let d = scratch(name);
    let p = d.join(format!("{name}.auk"));
    fs::write(&p, src).unwrap();
    auk_cmd().arg("run").arg(&p).env("AUK_LEAK_CHECK", "1").current_dir(&d).output().unwrap()
}

fn expect_out(name: &str, src: &str, want: &str) {
    let o = run_src(name, src);
    let (out, err) = text(&o);
    assert!(o.status.success(), "{name} failed ({:?}):\n{out}\n{err}", o.status.code());
    assert_eq!(out, want, "{name}: stderr:\n{err}");
}

/// The counting idiom `m[k] = (m.get(k) else d) op x` is compiled as one lookup (an update in
/// place) when the key is present: the same results as the plain form, including copy-on-write
/// (a snapshot keeps its value), floats, a missing key, an overflow under `catch` that leaves the
/// map unchanged, and a default with a call (not fused).
#[test]
fn map_counting_idiom_updates_in_place() {
    setup();
    expect_out(
        "map_update",
        r#"fn bump(): int = 100

fn main() {
    var counts: {str: int} = {}
    for w in "a b a c b a".split(" ") {
        counts[w] = (counts.get(w) else 0) + 1
    }
    print(counts)
    var f: {int: float} = {}
    let k = 3
    let half = 0.5
    f[k] = (f.get(k) else 1.0) * half
    f[k] = (f.get(k) else 1.0) * half
    f[7] = (f.get(7) else 2.0) - half
    print(f)
    var m: {int: int} = {1: 10}
    let snapshot = m
    let one = 1
    m[one] = (m.get(one) else 0) + 5
    m[2] = (m.get(2) else 40) + 2
    print("{m} {snapshot}")
    var big: {int: int} = {5: 9223372036854775807}
    let r = catch {
        big[5] = (big.get(5) else 0) + 1
        0
    }
    print("{r is err(_)} {big}")
    var g: {int: int} = {}
    g[1] = (g.get(1) else bump()) + 1
    print(g)
}
"#,
        "{\"a\": 3, \"b\": 2, \"c\": 1}\n{3: 0.25, 7: 1.5}\n{1: 15, 2: 42} {1: 10}\ntrue {5: 9223372036854775807}\n{1: 101}\n",
    );
}

fn expect_panic(name: &str, src: &str, msg: &str) {
    let o = run_src(name, src);
    let (out, err) = text(&o);
    assert_eq!(o.status.code(), Some(101), "{name}: {out}\n{err}");
    assert!(err.contains(msg), "{name}: expected {msg:?} in:\n{err}");
}

/// `x else y` / `x!` as the last expression of `T!`, `T?` and plain functions, with generic
/// calls returning `T?` (`max`, `min`, `find`, `first`, `get`) and `T!` (with an `else e =>`).
#[test]
fn else_in_tail_position_infers_the_value_type() {
    let f = "tests/fixtures/else_inference.auk";
    let o = auk(&["check", f]);
    let (out, err) = text(&o);
    assert!(o.status.success() && out.is_empty() && err.is_empty(), "{out}\n{err}");
    let o = auk_cmd().args(["run", f]).env("AUK_LEAK_CHECK", "1").output().unwrap();
    let (out, err) = text(&o);
    assert!(o.status.success(), "{out}\n{err}");
    assert_eq!(out, "9 2 19 a\n5 1 4\ntrue\nnth: short\n-1 7 0  7 7\n8 8\nshort\n2 1 0 - 0 0\n", "stderr:\n{err}");
}

#[test]
fn cow_through_var_params() {
    expect_out(
        "cow",
        "fn bump(xs: var [int]) { xs.push(99) }\nstruct Acc { xs: [int], n: int }\nfn add(a: var Acc, x: int) {\n  a.xs.push(x)\n  a.n += 1\n}\nfn main() {\n  let a = [1, 2]\n  var b = a\n  bump(&b)\n  print(\"{a} {b}\")\n  var acc = Acc { xs: a, n: 0 }\n  let snapshot = acc\n  acc.add(5)\n  add(&acc, 6)\n  print(\"{acc.xs} {acc.n} {snapshot.xs} {snapshot.n} {a}\")\n  var m = {\"k\": [1]}\n  let m2 = m\n  m[\"k\"] = [2]\n  print(\"{m} {m2}\")\n}\n",
        "[1, 2] [1, 2, 99]\n[1, 2, 5, 6] 2 [1, 2] 0 [1, 2]\n{\"k\": [2]} {\"k\": [1]}\n",
    );
}

/// Element reads that are only looked at (a field of an element, a comparison, a `match` or
/// `is` on one, a call argument) are borrowed, not retained; the values stay right when a later
/// call changes the list, and a field passed next to `&` of the same variable keeps its value.
#[test]
fn borrowed_element_reads() {
    expect_out(
        "borrowed_reads",
        r#"enum Tok { Ident(s: str), LParen, Fn }
struct Token { tok: Tok, doc: str }
struct P { toks: [Token], pos: int, name: str }

fn peek(p: P): Tok = p.toks[p.pos].tok
fn at(p: P, t: Tok): bool = p.peek() == t
fn kind(p: P): str {
  match p.toks[p.pos].tok {
    Ident(s) => "ident {s}"
    LParen => "("
    _ => "other"
  }
}
fn clear(p: var P): str {
  p.toks = []
  p.name = "gone" + "!"
  "cleared"
}
fn show2(a: str, p: var P): str {
  p.name = "new" + "!"
  p.toks = []
  a
}

fn main() {
  let toks = [Token { tok: Ident("x" + "y"), doc: "d" + "1" }, Token { tok: Tok.LParen, doc: "" }, Token { tok: Tok.Fn, doc: "" }]
  var p = P { toks: toks, pos: 0, name: "p" + "1" }
  print("{p.kind()} {p.at(Tok.LParen)} {p.toks[0].tok == Ident("xy")} {p.toks[0].doc}")
  p.pos = 1
  print("{p.kind()} {p.at(Tok.LParen)} {p.toks[1].tok != Tok.Fn} {p.toks[p.pos].tok is LParen}")
  // the element is read before a call that changes the list: still the old value
  var q = p
  q.pos = 0
  print(q.toks[0].doc + q.clear())
  print("{q.toks.len()} {q.name}")
  // a field passed next to `&` of the same variable
  var r = p
  print(show2(r.name, &r))
  print(show2(r.toks.len().str(), &r))
  var s = p
  print(show2(s.toks[0].doc, &s))
  print(p.toks.map(t => t.doc).join(","))
}
"#,
        "ident xy false true d1\n( true true true\nd1cleared\n0 gone!\np1\n0\nd1\nd1,,\n",
    );
}

/// A `match` on a `str` with many literal arms is one table lookup (`auk_str_switch`); arm
/// order, guards, a non-literal arm between literals and non-ASCII literals behave as before.
#[test]
fn match_on_str_with_many_literals() {
    expect_out(
        "str_switch",
        r#"fn kw(s: str): int = match s {
  "fn" => 1
  "let" => 2
  "var" => 3
  "if" => 4
  "else" => 5
  "" => 6
  "héllo" => 7
  "match" when s.len() > 100 => 98
  "match" => 8
  "matcha" => 9
  _ => 0
}

fn guarded(s: str, n: int): str = match s {
  "a" when n > 1 => "a big"
  "a" => "a small"
  "b" => "b"
  "c" => "c"
  "d" => "d"
  "e" => "e"
  x when x.starts_with("z") => "z-ish {x}"
  "f" => "f"
  _ => "other"
}

fn main() {
  for w in ["fn", "let", "var", "if", "else", "", "héllo", "match", "matcha", "matc", "x", "fnn", "f"] {
    print("{w}: {kw(w)}")
  }
  print([guarded("a", 2), guarded("a", 0), guarded("e", 0), guarded("zed", 0), guarded("f", 0), guarded("g", 0)])
}
"#,
        "fn: 1\nlet: 2\nvar: 3\nif: 4\nelse: 5\n: 6\nhéllo: 7\nmatch: 8\nmatcha: 9\nmatc: 0\nx: 0\nfnn: 0\nf: 0\n[\"a big\", \"a small\", \"e\", \"z-ish zed\", \"f\", \"other\"]\n",
    );
}

/// `str(cs)` and `str(cs[a..b])` (built straight from the char range, no slice) give the same
/// strings as before, non-ASCII, empty, of a slice view, and the same out-of-range panic.
#[test]
fn str_of_chars_and_char_ranges() {
    expect_out(
        "str_chars",
        r#"fn main() {
  let cs = "aé🦆xyz".chars()
  let v = cs[1..5]
  print([str(cs), str(cs[0..3]), str(cs[1..=2]), str(cs[2..2]), str(v[1..3]), str(cs[3..cs.len()])])
  let r = catch str(cs[4..9])
  print("{r}".contains("slice 4..9 out of range for length 6"))
}
"#,
        "[\"aé🦆xyz\", \"aé🦆\", \"é🦆\", \"\", \"🦆x\", \"xyz\"]\ntrue\n",
    );
}

/// `s += x` (and `s = s + x`) appends in place when the string is unique: a local, a `var`
/// parameter, a struct field, a list element, a map value, in a task's heap too; a copy taken
/// before (`let snap = s`) keeps its value, and `t += t` reads itself correctly.
#[test]
fn string_append_in_place() {
    expect_out(
        "string_append_in_place",
        r#"struct Doc { title: str, lines: [str] }

fn grow(s: var str, n: int) {
  for i in 0..n { s += "{i}" }
}

async fn build(n: int): str {
  var s = ""
  for i in 0..n { s += "ab" }
  s
}

fn main() {
  var s = ""
  for i in 0..1000 { s += "é" }
  print("{s.len()} {s.bytes().len()}")
  let snap = s
  s += "x"
  print("{snap.len()} {s.len()} {snap == s}")
  var t = "ab"
  t = t + t
  t += t
  print(t)
  var d = Doc { title: "a", lines: ["x"] }
  let d0 = d
  d.title += "bc"
  d.lines[0] += "yz"
  print("{d.title} {d.lines} {d0.title} {d0.lines}")
  var u = "q"
  grow(&u, 12)
  print(u)
  var w = "abc"
  w = w + "d"
  w = "z" + w
  print("{w} {w.len()} {w[3]}")
  var m = {"k": "v"}
  m["k"] += "w"
  print(m)
  var acc = ""
  for i in 0..20000 { acc = acc + "xy" }
  print(acc.len())
  let a = build(5000)
  let b = build(3000)
  print("{(await a).len()} {(await b).len()}")
}
"#,
        "1000 2000\n1000 1001 false\nabababab\nabc [\"xyz\"] a [\"x\"]\nq01234567891011\nzabcd 5 c\n{\"k\": \"vw\"}\n40000\n10000 6000\n",
    );
}

/// `var g = xs[i]`, changes to `g`, `xs[i] = g` moves the element out instead of copying it;
/// the results are the same as a copy's: a snapshot of the list keeps its values, `g` stays usable
/// after it goes back, and a read of the list in between or a changed index variable turns the
/// move off.
#[test]
fn move_out_of_a_container() {
    expect_out(
        "move_out_of_a_container",
        r#"struct Group { name: str, clauses: [str] }

fn last_index(xs: [Group]): int = xs.len() - 1

fn main() {
  var items = [Group { name: "a", clauses: [] }, Group { name: "b", clauses: ["x"] }]
  let before = items
  for i in 0..5 {
    var g = items[items.len() - 1]
    g.clauses.push("c{i}")
    g.name += "!"
    items[items.len() - 1] = g
  }
  print(items.map(g => "{g.name} {g.clauses}"))
  print(before.map(g => "{g.name} {g.clauses}"))
  // the element is used after it goes back
  var ls: [[int]] = [[1], [2]]
  var x = ls[0]
  x.push(10)
  ls[0] = x
  x.push(20)
  print("{ls} {x}")
  // reading the container in between: no move (the read sees the old value)
  var ys: [[int]] = [[1]]
  var y = ys[0]
  y.push(2)
  print(ys)
  ys[0] = y
  print(ys)
  // a map value
  var m = {"k": [1]}
  var v = m["k"]
  v.push(2)
  m["k"] = v
  print(m)
  // a different index variable changed in between: no move
  var zs: [[int]] = [[1], [2]]
  var k = 0
  var z = zs[k]
  z.push(5)
  k = 1
  zs[k] = z
  print(zs)
  // ... or changed by a tuple assignment
  var ts: [[int]] = [[1], [2]]
  var j = 0
  var tj = ts[j]
  tj.push(3)
  (j, k) = (1, 0)
  ts[j] = tj
  print("{ts} {k}")
}
"#,
        "[\"a []\", \"b!!!!! [\\\"x\\\", \\\"c0\\\", \\\"c1\\\", \\\"c2\\\", \\\"c3\\\", \\\"c4\\\"]\"]\n[\"a []\", \"b [\\\"x\\\"]\"]\n[[1, 10], [2]] [1, 10, 20]\n[[1]]\n[[1, 2]]\n{\"k\": [1, 2]}\n[[1], [1, 5]]\n[[1], [1, 3]] 0\n",
    );
}

#[test]
fn closures_capture_values() {
    expect_out(
        "closures",
        "fn adders(): [(int) => int] {\n  var out: [(int) => int] = []\n  for k in 1..=3 {\n    let base = k * 10\n    out.push(x => x + base)\n  }\n  out\n}\nfn twice(f: (int) => int, x: int): int = f(f(x))\nfn main() {\n  print(adders().map(f => f(1)))\n  var n = 5\n  let g = x => x * n\n  n = 100\n  print(g(2))\n  let pre = \"#\"\n  print([\"a\", \"b\"].map(s => pre + s).join(\",\"))\n  print(twice(x => x + 1, 0))\n  let pairs = [(1, \"one\"), (2, \"two\")]\n  print(pairs.map((i, s) => \"{s}={i}\"))\n}\n",
        "[11, 21, 31]\n10\n#a,#b\n2\n[\"one=1\", \"two=2\"]\n",
    );
}

#[test]
fn nested_and_recursive_enums() {
    expect_out(
        "enums",
        "enum Tree { Leaf(v: int), Node(l: Tree, r: Tree) }\nenum Wrap { A(t: Tree?), B(ws: [Wrap]) }\nstruct User { name: str, boss: User? }\nfn sum(Leaf(v)): int = v\nfn sum(Node(l, r)): int = sum(l) + sum(r)\nfn depth(Leaf(_)): int = 1\nfn depth(Node(l, r)): int = 1 + if depth(l) > depth(r) { depth(l) } else { depth(r) }\nfn main() {\n  let t = Node(Leaf(1), Node(Leaf(2), Leaf(3)))\n  print(\"{sum(t)} {depth(t)} {t}\")\n  print(B([A(some(t)), A(none)]))\n  print(t == Node(Leaf(1), Node(Leaf(2), Leaf(3))))\n  let u = User { name: \"ann\", boss: some(User { name: \"bob\", boss: none }) }\n  print(u.boss?.name else \"-\")\n  print(u.boss?.boss?.name else \"-\")\n  match t {\n    Node(Leaf(a), Node(b, _)) => print(\"{a} {b}\")\n    _ => print(\"?\")\n  }\n}\n",
        "6 3 Node(Leaf(1), Node(Leaf(2), Leaf(3)))\nB([A(some(Node(Leaf(1), Node(Leaf(2), Leaf(3))))), A(none)])\ntrue\nbob\n-\n1 Leaf(2)\n",
    );
}

#[test]
fn err_payloads_match_after_conversion() {
    expect_out(
        "payloads",
        "enum E { Bad(w: str), Worse }\nfn typed(n: int): int!E {\n  if n == 0 { fail(Bad(\"zero\")) }\n  if n < 0 { fail(Worse) }\n  n\n}\nfn plain(n: int): int! = typed(n)?\nfn show(r: int!): str = match r {\n  err(Bad(why)) => \"bad {why}\"\n  err(e) => \"other {e}\"\n  ok(n) => \"ok {n}\"\n}\nfn main() {\n  print(show(plain(0)))\n  print(show(plain(-1)))\n  print(show(plain(3)))\n  print(typed(-1) is err(Worse))\n  let v = typed(0) else e => match e { Bad(w) => w.len(), Worse => -1 }\n  print(v)\n  let m = plain(0) else e => -2\n  print(m)\n}\n",
        "bad zero\nother Worse\nok 3\ntrue\n4\n-2\n",
    );
}

#[test]
fn overflow_traps() {
    expect_panic("ovf_add", "fn main() {\n  var x = 9223372036854775800\n  for _ in 0..10 { x += 1 }\n  print(x)\n}\n", "panic: integer overflow in `+`\n  at ");
    expect_panic("ovf_mul", "fn big(n: int): int = n * n\nfn main() { print(big(4_000_000_000)) }\n", "integer overflow in `*`");
    expect_panic("div0", "fn d(a: int, b: int): int = a / b\nfn main() { print(d(1, 0)) }\n", "division by zero");
    expect_out("wrap", "fn main() { print(9223372036854775807 +% 1) }\n", "-9223372036854775808\n");
}

#[test]
fn self_tail_calls_are_loops() {
    expect_out(
        "tail",
        "fn len([], acc: int): int = acc\nfn len([_, ..t]: [int], acc: int): int = len(t, acc + 1)\nfn sum(xs: [int], i: int, acc: int): int {\n  if i == xs.len() { return acc }\n  sum(xs, i + 1, acc + xs[i])\n}\nfn main() {\n  var xs: [int] = []\n  for i in 0..1_000_000 { xs.push(i) }\n  print(len(xs, 0))\n  print(sum(xs, 0, 0))\n}\n",
        "1000000\n499999500000\n",
    );
}

#[test]
fn peek_prints_source_and_value() {
    let o = run_src("peek", "fn main() {\n  let x = 21\n  let y = peek x * 2\n  peek \"s{y}\"\n  print(y)\n}\n");
    let (out, err) = text(&o);
    assert!(o.status.success(), "{err}");
    assert_eq!(out, "42\n");
    assert!(err.contains("peek.auk:3] x * 2 = 42\n"), "{err}");
    assert!(err.contains("peek.auk:4] \"s{y}\" = s42\n"), "{err}");
}

#[test]
fn contract_failures() {
    expect_panic(
        "requires",
        "fn half(n: int): int\n  requires n % 2 == 0\n{ n / 2 }\nfn main() {\n  print(half(4))\n  print(half(3))\n}\n",
        "panic: requires failed: n % 2 == 0\n  at ",
    );
    expect_panic("ensures", "fn bad(n: int): int\n  ensures result > n\n{ n }\nfn main() { print(bad(1)) }\n", "panic: ensures failed: result > n");
    expect_panic(
        "old",
        "struct A { n: int }\nfn inc(a: var A)\n  ensures a.n == old(a.n) + 1\n{ a.n += 2 }\nfn main() {\n  var a = A { n: 1 }\n  inc(&a)\n}\n",
        "ensures failed: a.n == old(a.n) + 1",
    );
    expect_panic("assert", "fn main() {\n  let xs = [1, 2]\n  assert xs == [1, 3]\n}\n", "assertion failed: xs == [1, 3]\n  left: [1, 2]\n  right: [1, 3]");
    expect_panic("unwrap", "fn main() {\n  let xs: [int] = []\n  print(xs.first()!)\n}\n", "unwrapped `none`");
}

#[test]
fn build_refuses_holes() {
    let d = scratch("holes");
    let p = d.join("h.auk");
    fs::write(&p, "fn f(): int { ?? }\nfn main() { print(f()) }\n").unwrap();
    let o = auk(&["build", p.to_str().unwrap(), "-o", d.join("h").to_str().unwrap()]);
    let (_, err) = text(&o);
    assert_eq!(o.status.code(), Some(1));
    assert!(err.contains("still has 1 unfilled hole(s)") && err.contains("h.auk:1:15: unfilled hole (expected int)"), "{err}");
    assert!(!d.join("h").exists());
    // run allows holes and panics when one is reached
    let o = auk(&["run", p.to_str().unwrap()]);
    assert_eq!(o.status.code(), Some(101));
    assert!(text(&o).1.contains("panic: unfilled hole (expected int)"));
    // a complete program builds and runs
    fs::write(&p, "fn main(args: [str]): int {\n  print(\"args: {args.len()}\")\n  3\n}\n").unwrap();
    let exe = d.join("ok");
    run_ok(&["build", p.to_str().unwrap(), "-o", exe.to_str().unwrap()]);
    let o = Command::new(&exe).arg("x").output().unwrap();
    assert_eq!(o.status.code(), Some(3));
    assert_eq!(text(&o).0, "args: 2\n");
}

#[test]
fn async_tasks_and_any_shapes() {
    expect_out(
        "async",
        "shape Area { fn area(self): float }\nstruct Sq { s: float }\nstruct Circ { r: float }\nfn area(q: Sq): float = q.s * q.s\nfn area(c: Circ): float = 3.0 * c.r * c.r\nasync fn slow(n: int): int uses time {\n  time.sleep(5)\n  n * 2\n}\nfn main() uses time {\n  let shapes: [any Area] = [Sq { s: 2.0 }, Circ { r: 1.0 }]\n  print(shapes.map(s => s.area()))\n  let (a, b) = await (slow(1), slow(2))\n  print(a + b)\n  let t = slow(10)\n  print(await t)\n  print(await [1, 2, 3].map(n => slow(n)))\n  print(await slow(7))\n}\n",
        "[4.0, 3.0]\n6\n20\n[2, 4, 6]\n14\n",
    );
}

#[test]
fn control_flow_and_formatting() {
    expect_out(
        "flow",
        "struct P { x: int, y: int, name: str }\nfn grade(n: int): str when n >= 90 = \"A\"\nfn grade(_: int): str = \"B\"\nfn main() {\n  var i = 0\n  let v = loop {\n    i += 1\n    if i * i > 50 { break i }\n  }\n  print(\"v={v} pi={3.14159:.2} [{\"ab\":>5}] [{42:05}] [{'x':^5}]\")\n  for k, n in {\"b\": 2, \"a\": 1} { print(\"{k}={n}\") }\n  let q = P { x: 9, ..P { x: 1, y: 2, name: \"p\" } }\n  print(q)\n  print(\"{grade(95)}{grade(10)}\")\n  var total = 0\n  for j in 0..10 {\n    if j % 2 == 0 { continue }\n    if j > 7 { break }\n    total += j\n  }\n  print(total)\n  let s = \"GET /users/42\"\n  match s {\n    \"GET /users/\" + id => print(\"user {id}\")\n    _ => print(\"?\")\n  }\n  print([3, 1, 2].sort().reverse())\n  print(\"a b a\".split().counts())\n}\n",
        "v=8 pi=3.14 [   ab] [00042] [  x  ]\nb=2\na=1\nP { x: 9, y: 2, name: \"p\" }\nAB\n16\nuser 42\n[3, 2, 1]\n{\"a\": 2, \"b\": 1}\n",
    );
}

/// Every kind of runtime binding in the prelude links and behaves (externs with element
/// pointers, out-parameters, `+loc`, `var` containers, `T?`/`T!` results).
#[test]
fn runtime_bindings_link() {
    expect_out(
        "externs",
        "fn main() uses rand, env, proc, time, fs {\n  let r = rand.int(1, 6)\n  print(r >= 1 && r <= 6)\n  print(rand.float() < 1.0)\n  print(env.get(\"PATH\") is some(_))\n  print(env.args().len() > 0)\n  print(proc.run(\"echo\", [\"hi\"])!.trim())\n  print(time.now() > 0)\n  print(str.from_utf8([104, 105])!)\n  print(int.parse(\"12\")! + 1)\n  print(float.parse(\"1.5\")!)\n  print(fs.write(\"x.txt\", \"a\\nb\")!)\n  print(fs.lines(\"x.txt\")!)\n  print(\"abc\".repeat(2).upper().find(\"C\"))\n  var xs = [1, 2, 3]\n  xs.insert(0, 9)\n  print(xs.remove(1))\n  print(xs.pop())\n  print(xs)\n  var m = {\"a\": 1}\n  print(m.remove(\"a\"))\n  print(m.get(\"a\"))\n  print(char(65))\n  print(3.7.floor() + abs(-2.0) + (-3).abs().float())\n  print(int(2.9) + int('a'))\n  var s = set([1, 2, 2])\n  s.insert(3)\n  print(s.to_list())\n}\n",
        "true\ntrue\ntrue\ntrue\nhi\ntrue\nhi\n13\n1.5\n()\n[\"a\", \"b\"]\nsome(2)\n1\nsome(3)\n[9, 2]\nsome(1)\nnone\nsome('A')\n8.0\n99\n[1, 2, 3]\n",
    );
}

// ---- compile-time imprints ----

const IMPRINTS: &str = r#"struct Cfg { name: str, ratio: float, tags: [str], limit: int?, nick: str? }
enum Op { Push(n: int), Pop, Jump(to: int, label: str) }
enum Tree { Leaf(v: int), Node(l: Tree, r: Tree) }
struct Emp { name: str, boss: Emp? }
fn sieve(n: int): [int] {
  var composite: [bool] = []
  for _ in 0..=n { composite.push(false) }
  var out: [int] = []
  for i in 2..=n {
    if !composite[i] {
      out.push(i)
      var j = i * i
      while j <= n {
        composite[j] = true
        j += i
      }
    }
  }
  out
}
fn build(d: int): Tree = if d == 0 { Leaf(0) } else { Node(build(d - 1), Leaf(d)) }
let BASE = 1000
imprint COUNT = PRIMES.len() + BASE
imprint PRIMES = sieve(200)
imprint SQUARES = {"one": 1, "two": 4, "three": 9}
imprint CFG = Cfg { name: "auk \"q\" é\n", ratio: 0.1, tags: ["a", "b"], limit: some(3), nick: none }
imprint OPS = [Push(1), Pop, Jump(0, "start")]
imprint TREE = build(2)
imprint EMP = Emp { name: "a", boss: some(Emp { name: "b", boss: none }) }
imprint FLOATS = [[1.5, -0.0, 1e300], []]
imprint V = to_value(CFG)
fn main() {
  print(PRIMES.take(10))
  print(PRIMES.last())
  print(COUNT)
  print(SQUARES)
  print(CFG)
  print(OPS)
  print(TREE)
  print(EMP)
  print(FLOATS)
  print(V)
  var p = PRIMES
  p.push(1)
  var e = EMP
  e.name = "z"
  var m = SQUARES
  m["four"] = 16
  print("{p.len() - PRIMES.len()} {EMP.name} {SQUARES.len()}")
}
"#;

#[test]
fn imprints_are_computed_at_compile_time() {
    expect_out(
        "imprints",
        IMPRINTS,
        "[2, 3, 5, 7, 11, 13, 17, 19, 23, 29]\nsome(199)\n1046\n{\"one\": 1, \"two\": 4, \"three\": 9}\nCfg { name: \"auk \\\"q\\\" é\\n\", ratio: 0.1, tags: [\"a\", \"b\"], limit: some(3), nick: none }\n[Push(1), Pop, Jump(0, \"start\")]\nNode(Node(Leaf(0), Leaf(1)), Leaf(2))\nEmp { name: \"a\", boss: some(Emp { name: \"b\", boss: none }) }\n[[1.5, -0.0, 1e300], []]\n{\"name\": \"auk \\\"q\\\" é\\n\", \"ratio\": 0.1, \"tags\": [\"a\", \"b\"], \"limit\": 3, \"nick\": Null}\n1 a 3\n",
    );
    // the generated program holds the values, not the computation
    let d = scratch("imprints_ir");
    let p = d.join("imprints.auk");
    fs::write(&p, IMPRINTS).unwrap();
    let ir = run_ok(&["ir", p.to_str().unwrap()]);
    assert!(ir.contains("INT64_C(193)") && ir.contains("INT64_C(199)"), "the primes are data");
    assert!(ir.contains("_PRIMES_init(void)"), "an imprint is built from its value");
    assert!(!ir.contains("_const_PRIMES(void)"), "no initializer function for an imprint");
    assert!(!ir.contains("_sieve(INT64_C(200))"), "sieve(200) isn't called at run time");
    assert!(ir.contains("INT64_C(1046)"), "an imprint using another imprint and a `let`");
}

#[test]
fn imprint_errors() {
    let compile_err = |name: &str, src: &str| -> String {
        let o = run_src(name, src);
        let (out, err) = text(&o);
        assert_eq!(o.status.code(), Some(1), "{name}: {out}\n{err}");
        err
    };
    // a panic while computing it, blamed on the imprint (also through another imprint)
    let err = compile_err(
        "imprint_panic",
        "fn fact(n: int): int = if n == 0 { 1 } else { n * fact(n - 1) }\nimprint FACTS = (0..=25).map(n => fact(n))\nimprint N = FACTS.len()\nfn main() { print(N) }\n",
    );
    assert!(err.contains("imprint_panic.auk:2:9: error[E0420]: computing `imprint FACTS` at compile time panicked: integer overflow in `*`"), "{err}");
    assert!(err.contains("note: the panic happened at ") && err.contains("imprint_panic.auk:1:"), "{err}");
    let err = compile_err("imprint_index", "let XS = [1, 2]\nfn at(i: int): int = XS[i]\nimprint A = at(5)\nfn main() { print(A) }\n");
    assert!(err.contains("error[E0420]: computing `imprint A` at compile time panicked: index 5 out of range"), "{err}");
    // a cycle through a function
    let err = compile_err("imprint_cycle", "fn f(): int = A + 1\nimprint A: int = f()\nfn main() { print(A) }\n");
    assert!(err.contains("imprint_cycle.auk:2:9: error[E0115]: the constant `A` depends on itself"), "{err}");
    // the type must be Data (reported by `auk check`)
    let d = scratch("imprint_data");
    let p = d.join("t.auk");
    fs::write(&p, "imprint F = (x: int) => x + 1\nimprint T = (1, 2)\nimprint OK = [some(1), none]\nfn main() { print(F(1)) }\n").unwrap();
    let o = auk(&["check", p.to_str().unwrap()]);
    let err = text(&o).1;
    assert_eq!(o.status.code(), Some(1));
    assert!(err.contains("t.auk:1:9: error[E0350]: `(int) => int` doesn't fit the shape `Data`, which `imprint F` needs"), "{err}");
    assert!(err.contains("t.auk:2:9: error[E0350]: `(int, int)` doesn't fit the shape `Data`"), "{err}");
    assert_eq!(err.matches("error[").count(), 2, "{err}");
}

// ---- card #510 ----

/// Writing through a boxed (recursive) field copies the box when another value shares it.
#[test]
fn cow_through_boxed_fields() {
    expect_out(
        "cow_boxed",
        "struct A { v: int, b: B }\nstruct B { v: int, c: C, xs: [int] }\nstruct C { v: int, a: A? }\nstruct Emp { name: str, pay: int, boss: Boss }\nstruct Boss { name: str, pay: int, up: Emp? }\nfn raise(e: var Emp) { e.boss.pay += 100 }\nfn main() {\n  let x = A { v: 1, b: B { v: 2, c: C { v: 3, a: none }, xs: [1] } }\n  var y = x\n  y.b.c.v += 10\n  y.b.v = 20\n  y.b.xs.push(2)\n  y.b.xs[0] = 9\n  print(\"{x.b.v} {x.b.c.v} {x.b.xs} | {y.b.v} {y.b.c.v} {y.b.xs}\")\n  let e = Emp { name: \"ann\", pay: 1, boss: Boss { name: \"bob\", pay: 10, up: none } }\n  var f = e\n  f.boss.name = \"carl\"\n  raise(&f)\n  var g = f\n  g.boss.pay = 0\n  g.boss = Boss { name: \"dee\", pay: 5, up: some(e) }\n  print(\"{e.boss.name} {e.boss.pay} | {f.boss.name} {f.boss.pay} | {g.boss.name} {g.boss.pay}\")\n}\n",
        "2 3 [1] | 20 13 [9, 2]\nbob 10 | carl 110 | dee 5\n",
    );
}

/// `ensures` on a clause group is checked for whichever clause runs; self tail calls stay loops.
#[test]
fn ensures_on_clause_groups() {
    // `sign(5)` runs the guarded clause (no `ensures`), not the last one
    let src = "fn sign(0): int\n  ensures result == 0\n{ 0 }\nfn sign(n: int): int when n > 0 { 5 }\nfn sign(n: int): int\n  ensures result == 1\n{ -1 }\nfn main() {\n  print(sign(0))\n  print(sign(5))\n  print(sign(-5))\n}\n";
    let o = run_src("ensures_clauses", src);
    let (out, err) = text(&o);
    assert_eq!(o.status.code(), Some(101), "{out}\n{err}");
    assert_eq!(out, "0\n5\n");
    assert!(err.contains("panic: ensures failed: result == 1\n  at ") && err.contains("ensures_clauses.auk:6:11"), "{err}");
    let src = "fn len([], acc: int): int\n  ensures result == acc\n{ acc }\nfn len([_, ..t]: [int], acc: int): int\n  ensures result > acc\n{ len(t, acc + 1) }\nfn count(n: int, acc: int): int\n  requires n >= 0\n  ensures result == old(acc) + n\n{\n  if n == 0 { return acc }\n  count(n - 1, acc + 1)\n}\nfn grow(xs: var [int], n: int)\n  ensures xs.len() == old(xs.len()) + n\n{\n  if n > 0 {\n    xs.push(n)\n    grow(&xs, n - 1)\n  }\n}\nfn main() {\n  var xs: [int] = []\n  for i in 0..300000 { xs.push(i) }\n  print(len(xs, 0))\n  print(len([], 5))\n  print(count(1000000, 0))\n  var ys = [1]\n  grow(&ys, 3)\n  print(ys)\n}\n";
    expect_out("ensures_tail", src, "300000\n5\n1000000\n[1, 3, 2, 1]\n");
    let d = scratch("ensures_tail_ir");
    let p = d.join("t.auk");
    fs::write(&p, src).unwrap();
    let ir = run_ok(&["ir", p.to_str().unwrap()]);
    assert_eq!(ir.matches("goto dk_tail;").count(), 3, "every self tail call is a loop");
    assert!(ir.contains("auk_ensures_fail("));
    // a header's `ensures` covers every clause
    expect_panic("ensures_header", "fn f(n: int): int\n  ensures result >= 0\nfn f(0): int = 0\nfn f(n: int): int = -n\nfn main() {\n  print(f(0))\n  print(f(3))\n}\n", "ensures failed: result >= 0");
}

/// Auto-wraps the checker records (shorthand struct fields, `if` without `else` and loops
/// falling through in `()!` / `()?` functions) need no guessing in codegen.
#[test]
fn recorded_auto_wraps() {
    expect_out(
        "auto_wraps",
        "struct P { x: int?, y: str!, name: str }\nfn check(n: int): ()! {\n  if n < 0 { fail(\"negative\") }\n}\nfn opt(n: int): ()? {\n  if n == 0 { return none }\n}\nfn run(n: int): ()! {\n  for i in 0..n { if i > 5 { fail(\"too many\") } }\n}\nfn main() {\n  let x = 3\n  let y = \"why\"\n  let name = \"p\"\n  let p = P { x, y, name }\n  print(\"{p.x} {p.y else \"-\"} {p.name}\")\n  print(\"{check(1) is ok(_)} {check(-1) is err(_)} {opt(0) is none} {opt(1) is some(_)}\")\n  print(\"{run(3) is ok(_)} {run(10) is err(_)}\")\n}\n",
        "some(3) why p\ntrue true true true\ntrue true\n",
    );
}

/// `x?.N`: optional chaining into a tuple element, on a `T?`, in a chain and with `else`
/// (a `T?` element flattens). Also `?.m()` on an intrinsic method (`len`) of the element.
#[test]
fn optional_chaining_into_tuples() {
    expect_out(
        "opt_tuple",
        r#"fn find(xs: [(str, int)], k: str): (str, int)? = xs.find((a, _) => a == k)
fn main() {
  let p: (int, str)? = some((1, "one"))
  let q: (int, str)? = none
  print("{p?.0} {p?.1} {q?.0} {q?.1}")
  let xs = [("ab", 1), ("cde", 2)]
  let ys: [(str, int)] = []
  print("{xs.first()?.0?.len()} {ys.first()?.0?.len()} {xs.last()?.0?.len() else 0}")
  print("{find(xs, "cde")?.1 else 0} {find(xs, "z")?.1 else 0}")
  let nested: ((int, int), str)? = some(((4, 5), "n"))
  print("{nested?.0?.1} {nested?.1?.len() else -1}")
  let oo: (int?, str)? = some((none, "x"))
  print("{oo?.0} {oo?.1} {oo?.0 else 9}")
  let owned: ([int], str)? = some(([1, 2, 3], "o"))
  let v = owned?.0 else []
  print("{v} {owned?.0?.len()}")
}
"#,
        "some(1) some(\"one\") none none\nsome(2) none 3\n2 0\nsome(5) 1\nnone some(\"x\") 9\n[1, 2, 3] some(3)\n",
    );
}

/// Loops in tail position of `()!` / `()?` / `T!` / `T?` functions (directly, in `match` arms
/// and `if` branches), with bare `break`, `break value`, and early `return`/`fail`. A bare
/// `break` out of a `loop` whose value is `()!` once left the result zeroed (an `err`).
#[test]
fn tail_loops_in_result_functions() {
    expect_out(
        "tail_loops",
        r#"fn l1(): ()! {
  loop { break }
}
fn l2(): ()? {
  loop { break }
}
fn l3(n: int): ()! {
  var i = 0
  loop {
    if i == n { break }
    if i > 5 { fail("big") }
    i += 1
  }
}
fn l4(n: int): ()? {
  var i = 0
  loop {
    if i > 3 { return none }
    if i == n { break }
    i += 1
  }
}
fn w1(n: int): ()! {
  var i = 0
  while i < n {
    if i > 5 { fail("big") }
    i += 1
  }
}
fn w2(n: int): ()? {
  var i = 0
  while i < n {
    if i > 5 { return none }
    i += 1
  }
}
fn f1(n: int): ()! {
  for i in 0..n { if i > 5 { fail("big") } }
}
fn f2(n: int): ()? {
  for i in 0..n { if i > 5 { return none } }
}
fn v1(n: int): int! {
  var i = 0
  loop {
    if i > 5 { fail("big") }
    if i == n { break i * 10 }
    i += 1
  }
}
fn v2(n: int): str? {
  var i = 0
  loop {
    if i > 5 { return none }
    if i == n { break "s{i}" }
    i += 1
  }
}
fn v3(n: int): int! {
  for i in 0..10 { if i == n { return i } }
  fail("none")
}
fn m1(n: int): ()! {
  match n {
    0 => loop { break },
    1 => while false {},
    2 => for _ in 0..3 {},
    _ => fail("bad"),
  }
}
fn m2(n: int): ()? {
  match n {
    0 => loop { break },
    _ => loop { if n > 3 { return none } else { break } },
  }
}
fn m3(n: int): int! {
  match n {
    0 => loop { break 7 },
    _ => loop { if n > 3 { fail("big") } else { break n } },
  }
}
fn i1(n: int): ()! {
  if n == 0 { loop { break } } else if n == 1 { for _ in 0..2 {} } else { loop { if n > 2 { fail("x") }
  break } }
}
fn i2(n: int): ()? {
  if n == 0 { loop { break } } else { while true { if n > 1 { return none }
  break } }
}
fn i3(n: int): int! {
  if n == 0 { loop { break 1 } } else { loop { if n > 1 { fail("x") }
  break 2 } }
}
fn ok(r: ()!): str {
  match r {
    ok(_) => "ok",
    err(e) => "err({e})",
  }
}
fn main() {
  print("{ok(l1())} {l2() is some(_)}")
  print("{ok(l3(2))} {ok(l3(9))} {l4(2) is some(_)} {l4(9) is none}")
  print("{ok(w1(2))} {ok(w1(9))} {w2(2) is some(_)} {w2(9) is none}")
  print("{ok(f1(2))} {ok(f1(9))} {f2(2) is some(_)} {f2(9) is none}")
  print("{v1(2) else -1} {v1(9) else -1} {v2(3) else "-"} {v2(9) else "-"} {v3(4) else -1} {v3(40) else -1}")
  print("{ok(m1(0))} {ok(m1(1))} {ok(m1(2))} {ok(m1(3))}")
  print("{m2(0) is some(_)} {m2(1) is some(_)} {m2(5) is none}")
  print("{m3(0) else -1} {m3(2) else -1} {m3(5) else -1}")
  print("{ok(i1(0))} {ok(i1(1))} {ok(i1(2))} {ok(i1(3))}")
  print("{i2(0) is some(_)} {i2(1) is some(_)} {i2(2) is none}")
  print("{i3(0) else -1} {i3(1) else -1} {i3(2) else -1}")
  let r: ()! = loop { break }
  let s: ()? = loop { break }
  print("{ok(r)} {s is some(_)}")
}
"#,
        "ok true\nok err(big) true true\nok err(big) true true\nok err(big) true true\n20 -1 s3 - 4 -1\nok ok ok err(bad)\ntrue true true\n7 2 -1\nok ok ok err(x)\ntrue true true\n1 2 -1\nok true\n",
    );
}

// ---- catch and task links ----

const CATCH_SRC: &str = r#"fn at(xs: [int], i: int): int = xs[i]
fn parse(s: str): int! {
  let n = int.parse(s) else fail("nan: {s}")
  n
}
async fn boom(n: int): int {
  let xs = [1]
  xs[n]
}
fn bump(n: var int) { n += 1 }
fn main() {
  let xs = [1, 2, 3]
  print(catch at(xs, 1))
  match catch at(xs, 9) {
    ok(v) => print("ok {v}"),
    err(e) => print("caught: {e}"),
  }
  print("{catch parse("12")} {catch parse("x")} {catch at(xs, 7) else 0}")
  var count = 0
  let r = catch {
    bump(&count)
    count += 1
    parse("5")? + at(xs, 5)
  }
  print("count {count} r {r}")
  let t = boom(0)
  let u = boom(5)
  print("{await t} {catch await u}")
  let n = catch {
    let a = catch at(xs, 100)
    print("inner {a is err(_)}")
    at(xs, 50)
  }
  print(n is err(_))
  let m: {str: int} = {}
  print(catch m["k"])
  print("alive")
}
"#;

const CATCH_OUT: &str = "ok(2)\ncaught: panic: index 9 out of range for length 3 at catch.auk:1:33\nok(12) err(nan: x) 0\ncount 2 r err(panic: index 5 out of range for length 3 at catch.auk:1:33)\n1 err(panic: index 5 out of range for length 1 at catch.auk:8:3)\ninner true\ntrue\nerr(panic: key not found: \"k\" at catch.auk:36:15)\nalive\n";

/// `catch e` turns a panic (index, missing key, one re-raised by `await`) into an `Err`, passes
/// `?`/`fail` errors through, composes with `else`, and changes the `var`s it captures; in the
/// JIT and in an `auk build` executable.
#[test]
fn catch_recovers_panics() {
    let d = scratch("catch");
    let p = d.join("catch.auk");
    fs::write(&p, CATCH_SRC).unwrap();
    let o = auk_cmd().arg("run").arg("catch.auk").current_dir(&d).output().unwrap();
    let (out, err) = text(&o);
    assert!(o.status.success(), "{out}\n{err}");
    assert_eq!(out, CATCH_OUT, "stderr:\n{err}");
    let exe = d.join("catch");
    let o = auk_cmd().args(["build", "catch.auk", "-o"]).arg(&exe).current_dir(&d).output().unwrap();
    assert!(o.status.success(), "{:?}", text(&o));
    let o = Command::new(&exe).current_dir(&d).output().unwrap();
    assert_eq!(text(&o).0, CATCH_OUT);
}

/// A `catch` that doesn't panic leaks nothing (a panic leaks what the aborted code owned).
#[test]
fn catch_without_a_panic_leaks_nothing() {
    expect_out(
        "catch_leaks",
        r#"fn parse(s: str): int! {
  let n = int.parse(s) else fail("nan: {s}")
  n
}
fn main() {
  var names: [str] = []
  for i in 0..3 {
    let r = catch {
      names.push("a{i}")
      "v{parse("{i}")?}"
    }
    print(r)
  }
  print("{catch parse("q")} {names}")
}
"#,
        "ok(\"v0\")\nok(\"v1\")\nok(\"v2\")\nerr(nan: q) [\"a0\", \"a1\", \"a2\"]\n",
    );
}

/// A task's panic ends only the task; `await` raises it again (uncaught: exit 101 with the
/// original location), and a crashed task dropped without an `await` still ends the process.
#[test]
fn task_panics_are_raised_at_await() {
    let src = "async fn boom(n: int): int {\n  let xs = [1]\n  xs[n]\n}\n";
    let o = run_src("task_await", &format!("{src}fn main() {{\n  let t = boom(4)\n  print(\"before\")\n  print(await t)\n}}\n"));
    let (out, err) = text(&o);
    assert_eq!(o.status.code(), Some(101), "{out}\n{err}");
    assert_eq!(out, "before\n");
    assert!(err.contains("panic: index 4 out of range for length 1\n  at ") && err.contains("task_await.auk:3:3"), "{err}");
    let o = run_src("task_dropped", &format!("{src}fn go() uses time {{\n  let t = boom(4)\n  time.sleep(20)\n}}\nfn main() uses time {{\n  go()\n  print(\"after\")\n}}\n"));
    let (out, err) = text(&o);
    assert_eq!(o.status.code(), Some(101), "{out}\n{err}");
    assert!(err.contains("(in a task that was never awaited)"), "{err}");
}

/// `await any` gives the first task to finish (its panic or error as the `Err`); `cancel()` stops
/// a loop or a sleep, a `catch` inside the cancelled task can't hold it, a task that crashes
/// cancels the tasks it started (the link), and a cancelled task dropped unawaited is no crash.
#[test]
fn await_any_and_cancel() {
    // no leak check: cancelling (a panic) leaks what the stopped code owned
    let d = scratch("await_any");
    fs::write(
        d.join("await_any.auk"),
        r#"async fn slow(ms: int, v: int): int uses time {
  time.sleep(ms)
  v
}
async fn crash(ms: int): int uses time {
  time.sleep(ms)
  let xs = [1]
  xs[ms]
}
async fn spin(): int {
  var n = 0
  while true {
    n += 1
  }
  n
}
async fn stubborn(): int uses time {
  loop {
    let r = catch time.sleep(10_000)
    print("held {r}")
  }
}
async fn parent(): int uses time {
  let k = slow(10_000, 1)
  time.sleep(10_000)
  await k
}
fn main() uses time {
  let t0 = time.now()
  var ts = [slow(2_000, 1), slow(10, 2), crash(100)]
  let (i, r) = await any ts
  print("{i} {r}")
  ts[i] = slow(5_000, 9)
  let (j, s) = await any ts
  print("{j} {s is err(_)}")
  let sp = spin()
  time.sleep(20)
  sp.cancel()
  print(catch await sp)
  let st = stubborn()
  time.sleep(20)
  st.cancel()
  print(catch await st)
  let p = parent()
  time.sleep(20)
  p.cancel()
  print(catch await p)
  for t in ts {
    t.cancel()
  }
  print(time.now() - t0 < 3_000)
}
"#,
    )
    .unwrap();
    let o = auk_cmd().args(["run", "await_any.auk"]).current_dir(&d).output().unwrap();
    let (out, err) = text(&o);
    assert!(o.status.success(), "{out}\n{err}");
    assert_eq!(
        out,
        "1 ok(2)\n2 true\nerr(panic: cancelled at await_any.auk:12:3)\nerr(panic: cancelled at a blocking call)\nerr(panic: cancelled at a blocking call)\ntrue\n",
        "{err}"
    );
}

/// Tasks share nothing: arguments, results and channel messages are deep copies, and a task
/// that crashes or is cancelled (holding received data, a channel, a half-built list) leaves
/// nothing behind: the whole program runs clean under the leak checker.
#[test]
fn channels_and_task_heaps() {
    expect_out(
        "chan_heaps",
        r#"struct Job { id: int, tags: [str] }

async fn worker(jobs: Chan<Job>, out: Chan<str>): int {
  var n = 0
  for j in jobs {
    out.send("job {j.id} {j.tags}")
    n += 1
  }
  n
}

async fn crasher(jobs: Chan<Job>): int {
  var seen: [str] = []
  for j in jobs {
    seen.push("got {j.id}")
    let _ = j.tags[10]
  }
  0
}

async fn waiter(jobs: Chan<Job>): int {
  for j in jobs {
    print("never {j.id}")
  }
  0
}

async fn grow(xs: [str]): [str] {
  var ys = xs
  ys.push("more")
  ys
}

fn main() uses time {
  let jobs: Chan<Job> = chan()
  let out: Chan<str> = chan()
  let w = worker(jobs, out)
  for i in 0..3 {
    jobs.send(Job { id: i, tags: ["t{i}"] })
  }
  jobs.close()
  print(await w)
  out.close()
  for s in out {
    print(s)
  }
  let base = ["a"]
  let g = grow(base)
  print("{await g} {base}")
  let cj: Chan<Job> = chan()
  var ts = [crasher(cj)]
  cj.send(Job { id: 7, tags: ["x"] })
  let (_, r) = await any ts
  print(r is err(_))
  let wj: Chan<Job> = chan()
  var ws = [waiter(wj)]
  time.sleep(20)
  ws[0].cancel()
  let (_, c) = await any ws
  print(c)
}
"#,
        "3\njob 0 [\"t0\"]\njob 1 [\"t1\"]\njob 2 [\"t2\"]\n[\"a\", \"more\"] [\"a\"]\ntrue\nerr(panic: cancelled at a channel receive)\n",
    );
}

// ---- auk run --live ----

/// Lines of a child's stderr, read on a thread, waited for with a deadline.
struct Lines(std::sync::mpsc::Receiver<String>, Vec<String>);

impl Lines {
    /// Wait for a line matching `f` (lines before it are kept in `.1`); panics after 20 s.
    fn wait(&mut self, what: &str, f: impl Fn(&str) -> bool) -> String {
        let end = std::time::Instant::now() + std::time::Duration::from_secs(20);
        loop {
            let left = end.saturating_duration_since(std::time::Instant::now());
            match self.0.recv_timeout(left) {
                Ok(l) => {
                    self.1.push(l.clone());
                    if f(&l) {
                        return l;
                    }
                }
                Err(_) => panic!("timed out waiting for {what}; stderr so far:\n{}", self.1.join("\n")),
            }
        }
    }
}

/// `auk run --live`: an edited function body is swapped in while the program keeps its state;
/// a type error keeps the old code running; a changed struct layout restarts the program.
#[test]
fn live_reload_swaps_code_and_keeps_state() {
    let d = scratch("live");
    let f = d.join("live.auk");
    let src = |msg: &str, fields: &str, init: &str| {
        format!(
            "struct S {{ n: int{fields} }}\n\nfn msg(n: int): str = {msg}\n\nfn main() uses time {{\n  var s = S {{ n: 0{init} }}\n  while s.n < 2_000 {{\n    s.n += 1\n    eprint(msg(s.n))\n    time.sleep(20)\n  }}\n}}\n"
        )
    };
    fs::write(&f, src("\"a{n}\"", "", "")).unwrap();
    let mut child = auk_cmd()
        .args(["run", "--live", "live.auk"])
        .current_dir(&d)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let err = child.stderr.take().unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    thread::spawn(move || {
        use std::io::BufRead;
        for l in std::io::BufReader::new(err).lines().map_while(Result::ok) {
            if tx.send(l).is_err() {
                break;
            }
        }
    });
    let mut lines = Lines(rx, Vec::new());
    let num = |l: &str, p: &str| l.strip_prefix(p).and_then(|n| n.parse::<i64>().ok());
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        lines.wait("a5", |l| num(l, "a").is_some_and(|n| n >= 5));
        // 1. a new body; the counter carries on
        fs::write(&f, src("\"b{n}\"", "", "")).unwrap();
        lines.wait("the reload", |l| l.contains("[live] reloaded in"));
        let b = lines.wait("a b line", |l| num(l, "b").is_some());
        assert!(num(&b, "b").unwrap() > 5, "the state was lost: {b}");
        // 2. a type error: the old code keeps running
        fs::write(&f, src("5", "", "")).unwrap();
        lines.wait("the type error", |l| l.contains("not reloaded"));
        lines.wait("b after the error", |l| num(l, "b").is_some());
        // 3. a new field: a restart from scratch
        fs::write(&f, src("\"c{n}\"", ", k: int", ", k: 1")).unwrap();
        lines.wait("the restart", |l| l.contains("changed shape and `main`'s side of the program uses it: restarting"));
        let c = lines.wait("a c line", |l| num(l, "c").is_some());
        assert!(num(&c, "c").unwrap() < 20, "not restarted: {c}");
    }));
    let _ = child.kill();
    let _ = child.wait();
    if let Err(e) = res {
        std::panic::resume_unwind(e);
    }
}

/// `auk run --live` with supervision: a type only a supervised task uses changes shape, so just
/// that task is stopped and its supervisor starts it on the new code while `main` keeps going;
/// a type `main` itself holds changes shape, so the whole program restarts.
#[test]
fn live_reload_restarts_only_the_tasks_using_a_changed_type() {
    let d = scratch("live_sup");
    fs::create_dir_all(d.join("src")).unwrap();
    fs::write(d.join("raft.toml"), "[package]\nname = \"app\"\nversion = \"0.1.0\"\neffects = [\"time\"]\n\n[deps]\nsup = \"^0.1\"\n").unwrap();
    let src = |counter: &str, init: &str, step: &str, main_ty: &str| {
        format!(
            "struct Counter {{ {counter} }}\nstruct Main {{ {main_ty} }}\n\nfn count(): ()! uses time {{\n  var c = Counter {{ {init} }}\n  while true {{\n    c.n += {step}\n    eprint(\"count {{c.n}}\")\n    time.sleep(20)\n  }}\n}}\n\nfn main(): int! uses time {{\n  let m = Main {{ a: 1 }}\n  eprint(\"main {{m.a}}\")\n  sup.run([sup.child(\"count\", () => count())], sup.one_for_one(5, 60_000))?\n  0\n}}\n"
        )
    };
    let f = d.join("src/main.auk");
    fs::write(&f, src("n: int", "n: 0", "1", "a: int")).unwrap();
    let q = Command::new(env!("CARGO_BIN_EXE_raft"))
        .arg("install")
        .current_dir(&d)
        .env("RAFT_REGISTRY", Path::new(env!("CARGO_MANIFEST_DIR")).join("packages"))
        .output()
        .unwrap();
    assert!(q.status.success(), "{:?}", text(&q));
    let mut child = auk_cmd()
        .args(["run", "--live", "src/main.auk"])
        .current_dir(&d)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let err = child.stderr.take().unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    thread::spawn(move || {
        use std::io::BufRead;
        for l in std::io::BufReader::new(err).lines().map_while(Result::ok) {
            if tx.send(l).is_err() {
                break;
            }
        }
    });
    let mut lines = Lines(rx, Vec::new());
    let num = |l: &str| l.strip_prefix("count ").and_then(|n| n.parse::<i64>().ok());
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        lines.wait("count 5", |l| num(l).is_some_and(|n| n >= 5));
        // only the counting task holds a Counter
        fs::write(&f, src("n: int, k: int", "n: 0, k: 1", "100", "a: int")).unwrap();
        lines.wait("the task stop", |l| l.contains("`Counter` changed shape: stopped 1 task(s) that use it"));
        lines.wait("the new code", |l| num(l).is_some_and(|n| n % 100 == 0 && n > 0));
        assert_eq!(lines.1.iter().filter(|l| l.starts_with("main ")).count(), 1, "main restarted:\n{}", lines.1.join("\n"));
        // main holds a Main
        fs::write(&f, src("n: int, k: int", "n: 0, k: 1", "100", "a: int, b: int").replace("Main { a: 1 }", "Main { a: 1, b: 2 }")).unwrap();
        lines.wait("the restart", |l| l.contains("`Main` changed shape and `main`'s side of the program uses it: restarting the program"));
    }));
    let _ = child.kill();
    let _ = child.wait();
    if let Err(e) = res {
        std::panic::resume_unwind(e);
    }
}

// ---- error programs, spec ----

fn error_files() -> Vec<PathBuf> {
    let mut paths: Vec<_> = fs::read_dir("tests/errors")
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|e| e == "auk"))
        .collect();
    paths.sort();
    assert!(paths.len() >= 10, "too few error programs: {paths:?}");
    paths
}

/// Every `tests/errors/X.auk` starts with `// error: E0xxx <message substring>` and must fail
/// `auk check` with exactly that code (the first error reported) and message, in both output modes.
#[test]
fn error_programs_fail_with_their_code() {
    for path in error_files() {
        let p = path.to_str().unwrap();
        let src = fs::read_to_string(&path).unwrap();
        let header = src.lines().next().and_then(|l| l.strip_prefix("// error: "));
        let Some((code, msg)) = header.and_then(|h| h.split_once(' ')) else {
            panic!("{p} must start with `// error: E0xxx <message>`");
        };
        assert!(code.len() == 5 && code.starts_with('E'), "{p}: bad code {code:?}");

        let o = auk(&["check", p]);
        let (_, err) = text(&o);
        assert_eq!(o.status.code(), Some(1), "{p} should fail to check:\n{err}");
        let first = err.lines().find(|l| l.contains(": error[")).unwrap_or_else(|| panic!("{p}: no error in:\n{err}"));
        assert!(first.contains(&format!("error[{code}]: ")), "{p}: expected {code} first, got:\n{err}");
        assert!(first.contains(msg), "{p}: expected {msg:?} in:\n{first}");

        let o = auk(&["check", p, "--json"]);
        let (json, _) = text(&o);
        assert!(!o.status.success(), "{p}: {json}");
        assert!(json.contains(r#""ok":false"#) && json.contains(&format!(r#""code":"{code}","severity":"error""#)), "{p}: {json}");
    }
}

/// `auk check` accepts every example, with an empty JSON report.
#[test]
fn examples_check_clean_as_json() {
    setup();
    for e in fs::read_dir("examples").unwrap() {
        let p = e.unwrap().path();
        if p.extension().is_none_or(|x| x != "auk") {
            continue;
        }
        let p = p.to_str().unwrap();
        let o = auk(&["check", p, "--json"]);
        let (json, _) = text(&o);
        assert!(o.status.success() && json.contains(r#""ok":true,"diagnostics":[]"#), "{p}: {json}");
    }
}

/// `auk spec` prints the embedded language reference.
#[test]
fn spec() {
    let o = auk(&["spec"]);
    assert!(o.status.success());
    assert_eq!(text(&o).0, fs::read_to_string("docs/spec.md").unwrap());
}

/// `auk` with no command, or an unknown one, prints the usage (listing every command) and exits 2.
#[test]
fn usage_lists_every_command() {
    for args in [&[][..], &["frobnicate"][..], &["check"][..]] {
        let o = auk(args);
        let (_, err) = text(&o);
        assert_eq!(o.status.code(), Some(2), "{args:?}");
        for cmd in ["run", "build", "check", "test", "fmt", "explain", "dive", "lsp", "ir", "spec", "raft"] {
            assert!(err.contains(&format!("  {cmd} ")) || err.contains(&format!("`{cmd}`")), "{args:?}: no {cmd} in:\n{err}");
        }
    }
}

// ---- gui ----

/// Core's pure `pixels` helpers (no window needed): fill, blend, blit, blit_mask, clipping.
#[test]
fn gui_pixel_helpers_draw_and_clip() {
    setup();
    let d = scratch("gui_pixels");
    let f = d.join("px.auk");
    fs::write(
        &f,
        r#"
fn hx(n: int): str = "0123456789abcdef"[n / 16 % 16..n / 16 % 16 + 1] + "0123456789abcdef"[n % 16..n % 16 + 1]

// the transparency byte only when it isn't 0 (opaque)
fn hex(f: pixels.Frame): str = f.to_list().map(p => (if p >> 24 == 0 { "" } else { hx(p >> 24 & 255) + ":" }) + hx(p >> 16 & 255) + hx(p >> 8 & 255) + hx(p & 255)).join(" ")

fn row(f: pixels.Frame, y: int): pixels.Frame {
  var r = pixels.frame(f.width(), 1, 0)
  r.blit(0, 0, f, 0, y, f.width(), 1)
  r
}

async fn total(f: pixels.Frame): int = f.to_list().map(p => p & 255).sum()

fn main() {
  var f = pixels.frame(4, 3, 0x000000)
  f.fill(1, 1, 10, 10, 0xff0000)                      // clipped at the right and bottom
  print(hex(f))
  f.blend(0, 0, 2, 1, 0x7fffffff)                      // half white over black
  print(hex(row(f, 0)))
  let src = pixels.from_list(2, 2, [0x111111, 0x222222, 0x333333, 0x444444])
  f.blit(-1, 2, src, 0, 0, 2, 2)                       // half off the left and bottom
  print(hex(row(f, 2)))
  f.blit_mask(2, 0, [255, 0, 51, 128], 2, 0x00ff00)
  print(hex(row(f, 0)) + " / " + hex(row(f, 1)))
  var same = pixels.frame(3, 1, 0x0000ff)
  let before = same
  same.set(0, 0, 0xffffff)                             // copy-on-write: `before` keeps its pixels
  print("{hex(before)} / {hex(same)}")
  // transparency: a clear frame, half-transparent white composited onto opaque blue
  var t = pixels.frame(2, 1, pixels.CLEAR)
  t.set(0, 0, pixels.argb(128, 255, 255, 255))
  print(hex(t))
  var b = pixels.frame(2, 1, 0x0000ff)
  b.composite(0, 0, t, 0, 0, 2, 1)
  print(hex(b))
  b.blit(1, 0, b, 0, 0, 1, 1)                          // from itself
  print("{hex(b)} {await total(b)}")
}
"#,
    )
    .unwrap();
    let out = run_ok(&["run", f.to_str().unwrap()]);
    assert_eq!(
        out,
        "000000 000000 000000 000000 000000 ff0000 ff0000 ff0000 000000 ff0000 ff0000 ff0000\n\
         808080 808080 000000 000000\n\
         222222 ff0000 ff0000 ff0000\n\
         808080 808080 00ff00 000000 / 000000 ff0000 cc3300 7f8000\n\
         0000ff 0000ff 0000ff / ffffff 0000ff 0000ff\n\
         7f:ffffff ff:000000\n\
         8080ff 0000ff\n\
         8080ff 8080ff 510\n"
    );
}

/// A real window through the window process: open, present a frame and a rectangle, read
/// events, close. It shows a window for a moment, so it only runs on request:
/// `cargo test --test run gui_window -- --ignored`.
#[cfg(target_os = "macos")]
#[test]
#[ignore]
fn gui_window_round_trip() {
    setup();
    let out = run_ok(&["run", "examples/gui_gradient.auk", "--for", "800"]);
    // a full frame at the start, one more per resize the system made (a display change), and a
    // partial one per mouse move over the window
    assert!(out.ends_with(" partial; 0x0 after closing\n") && out.contains(" full frames, "), "{out}");
}

#[cfg(target_os = "macos")]
#[test]
#[ignore]
fn gui_text_window() {
    setup();
    let out = run_ok(&["run", "examples/gui_text.auk", "--for", "500"]);
    assert!(out.ends_with("frames; text ok\n"), "{out}");
}

/// The pixels a program presents are what the window shows: `gui_gradient` is green at the
/// bottom left and yellow at the bottom right (`AUK_GUI_SNAP` saves the window as it closes).
#[cfg(target_os = "macos")]
#[test]
#[ignore]
fn gui_window_shows_the_frame() {
    setup();
    let snap = std::env::temp_dir().join(format!("auk-gui-snap-{}.ppm", std::process::id()));
    let _ = fs::remove_file(&snap);
    let o = auk_cmd().args(["run", "examples/gui_gradient.auk", "--for", "600"]).env("AUK_GUI_SNAP", &snap).output().unwrap();
    assert!(o.status.success(), "{}", String::from_utf8_lossy(&o.stderr));
    // the window process writes it just after the program ends
    let mut data = Vec::new();
    for _ in 0..50 {
        std::thread::sleep(std::time::Duration::from_millis(100));
        if let Ok(d) = fs::read(&snap) {
            if !d.is_empty() {
                data = d;
                break;
            }
        }
    }
    let _ = fs::remove_file(&snap);
    let mut parts = data.splitn(4, |&b| b == b'\n');
    let (_, size, _, px) = (parts.next().unwrap(), parts.next().unwrap(), parts.next().unwrap(), parts.next().unwrap());
    let size = String::from_utf8_lossy(size);
    let (w, h): (usize, usize) = size.split_once(' ').map(|(a, b)| (a.parse().unwrap(), b.parse().unwrap())).unwrap();
    let at = |x: usize, y: usize| {
        let i = (y * w + x) * 3;
        (px[i] as i32, px[i + 1] as i32, px[i + 2] as i32)
    };
    // the capture is in the display's color space (Display P3 turns sRGB (8, 243, 153) into about
    // (112, 239, 161)), so check which channels lead rather than exact values
    let (r, g, b) = at(30, h - 30);
    assert!(g > 200 && g > r + 60 && g > b + 40, "bottom left is {:?}", (r, g, b));
    let (r, g, b) = at(w - 30, h - 30);
    assert!(r > 200 && g > 200 && b + 100 < r, "bottom right is {:?}", (r, g, b));
}

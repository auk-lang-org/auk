//! Execution traces: `auk run --trace=...` and `auk test --trace=...` (runtime/src/trace.rs, the
//! wrappers in lower.rs). Every trace line read here must parse as JSON (src/json.rs).

#[allow(dead_code)]
#[path = "../src/json.rs"]
mod json;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use json::Json;

fn auk_cmd() -> Command {
    let mut c = Command::new(env!("CARGO_BIN_EXE_auk"));
    for v in ["AUK_LEAK_CHECK", "AUK_TRACE", "AUK_TRACE_LIMIT", "AUK_TRACE_TAIL"] {
        c.env_remove(v);
    }
    c
}

fn text(o: &Output) -> String {
    format!("{}{}", String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr))
}

fn scratch(name: &str) -> PathBuf {
    let d = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("trace").join(name);
    let _ = fs::remove_dir_all(&d);
    fs::create_dir_all(&d).unwrap();
    d
}

/// Parse JSON Lines; every line must be a JSON object with an `ev`.
fn events(jsonl: &str) -> Vec<Json> {
    jsonl
        .lines()
        .map(|l| {
            let e = json::parse(l).unwrap_or_else(|err| panic!("not JSON ({err}): {l}"));
            assert!(e.get("ev").as_str().is_some(), "no `ev`: {l}");
            e
        })
        .collect()
}

/// `ev fn depth` (plus the args or value or error) of each event, for exact comparisons.
fn brief(es: &[Json]) -> Vec<String> {
    es.iter()
        .map(|e| {
            let s = |k: &str| e.get(k).as_str().unwrap_or("").to_string();
            let depth = e.get("depth").as_i64().map_or(String::new(), |d| format!(" @{d}"));
            match s("ev").as_str() {
                "call" => {
                    let args: Vec<&str> = e.get("args").as_arr().iter().map(|a| a.as_str().unwrap()).collect();
                    format!("call {}({}){depth}", s("fn"), args.join(", "))
                }
                "ret" => format!("ret {} = {}{depth}", s("fn"), s("value")),
                "err" => format!("err {} ! {}{depth}", s("fn"), s("error")),
                "peek" => format!("peek {} = {}{depth}", s("expr"), s("value")),
                "panic" => format!("panic {}{depth}", s("msg")),
                ev => ev.to_string(),
            }
        })
        .collect()
}

/// Write `src` as `<name>.auk` in a scratch dir and `auk run` it with a trace file (plus
/// `flags`) and the leak checker on. Returns the output and the events.
fn run_traced(name: &str, src: &str, flags: &[&str]) -> (Output, Vec<Json>) {
    let d = scratch(name);
    let f = d.join(format!("{name}.auk"));
    fs::write(&f, src).unwrap();
    let tr = d.join("trace.jsonl");
    let o = auk_cmd()
        .arg("run")
        .arg(format!("--trace={}", tr.display()))
        .args(flags)
        .arg(format!("{name}.auk"))
        .current_dir(&d)
        .env("AUK_LEAK_CHECK", "1")
        .output()
        .unwrap();
    let es = events(&fs::read_to_string(&tr).unwrap_or_default());
    (o, es)
}

const FACT: &str = "fn fact(0): int = 1\nfn fact(n: int): int = n * fact(n - 1)\nfn main() { print(fact(3)) }\n";

#[test]
fn recursive_calls_nest_with_depths() {
    let (o, es) = run_traced("fact", FACT, &[]);
    assert!(o.status.success(), "{}", text(&o));
    assert_eq!(String::from_utf8_lossy(&o.stdout), "6\n");
    assert_eq!(
        brief(&es),
        [
            "call fact.main() @0",
            "call fact.fact(3) @1",
            "call fact.fact(2) @2",
            "call fact.fact(1) @3",
            "call fact.fact(0) @4",
            "ret fact.fact = 1 @4",
            "ret fact.fact = 1 @3",
            "ret fact.fact = 2 @2",
            "ret fact.fact = 6 @1",
            "ret fact.main = () @0",
        ]
    );
    // `loc` is the call site (main's call from the entry point has none: its definition)
    let locs: Vec<&str> = es.iter().filter_map(|e| e.get("loc").as_str()).collect();
    assert_eq!(locs, ["fact.auk:3:4", "fact.auk:3:19", "fact.auk:2:28", "fact.auk:2:28", "fact.auk:2:28"]);
}

#[test]
fn errors_propagate_through_question_marks() {
    let src = "\
enum E { Odd(n: int) }
fn half(n: int): int!E {
  if n % 2 == 1 { fail(Odd(n)) }
  n / 2
}
fn quarter(n: int): int!E = half(half(n)?)?
fn main() {
  let q = quarter(6) else e => -1
  print(q)
}
";
    let (o, es) = run_traced("errs", src, &[]);
    assert!(o.status.success(), "{}", text(&o));
    assert_eq!(
        brief(&es),
        [
            "call errs.main() @0",
            "call errs.quarter(6) @1",
            "call errs.half(6) @2",
            "ret errs.half = 3 @2",
            "call errs.half(3) @2",
            "err errs.half ! Odd(3) @2",
            "err errs.quarter ! Odd(3) @1",
            "ret errs.main = () @0",
        ]
    );
}

#[test]
fn a_panic_ends_the_trace() {
    let src = "fn pick(xs: [int], i: int): int = xs[i]\nfn go(n: int): int = pick([1, 2], n) + 1\nfn main() { print(go(5)) }\n";
    let (o, es) = run_traced("boom", src, &[]);
    assert_eq!(o.status.code(), Some(101), "{}", text(&o));
    assert_eq!(
        brief(&es),
        ["call boom.main() @0", "call boom.go(5) @1", "call boom.pick([1, 2], 5) @2", "panic index 5 out of range for length 2 @3"]
    );
    assert_eq!(es[3].get("loc").as_str(), Some("boom.auk:1:35"));
}

#[test]
fn peeks_are_events() {
    let src = "fn sq(x: int): int = x * x\nfn main() {\n  let y = peek sq(4) + 1\n  print(y)\n}\n";
    let (o, es) = run_traced("peek", src, &[]);
    assert!(o.status.success(), "{}", text(&o));
    // the human-readable peek line is still printed
    assert!(String::from_utf8_lossy(&o.stderr).contains("[peek.auk:3] sq(4) + 1 = 17"), "{}", text(&o));
    assert_eq!(brief(&es), ["call peek.main() @0", "call peek.sq(4) @1", "ret peek.sq = 16 @1", "peek sq(4) + 1 = 17 @1", "ret peek.main = () @0"]);
    assert_eq!(es[3].get("loc").as_str(), Some("peek.auk:3"));
}

#[test]
fn the_event_limit_truncates() {
    let src = "fn id(n: int): int = n\nfn main() {\n  var t = 0\n  for i in 0..20_000 { t += id(i) }\n  print(t)\n}\n";
    let (o, es) = run_traced("limit", src, &["--trace-limit", "5"]);
    assert!(o.status.success(), "{}", text(&o));
    assert_eq!(es.len(), 6);
    assert_eq!(es[5].get("ev").as_str(), Some("truncated"));
    assert_eq!(es[5].get("limit").as_i64(), Some(5));
    // the default limit is 10,000 events
    let (o, es) = run_traced("limit_default", src, &[]);
    assert!(o.status.success(), "{}", text(&o));
    assert_eq!(es.len(), 10_001);
    assert_eq!(brief(&es[10_000..]), ["truncated"]);
    // a panic past the limit is still recorded
    let src = "fn id(n: int): int = n\nfn main() {\n  for i in 0..100 { id(i) }\n  print([1][3])\n}\n";
    let (_, es) = run_traced("limit_panic", src, &["--trace-limit=10"]);
    assert_eq!(brief(&es[10..]), ["truncated", "panic index 3 out of range for length 1 @1"]);
}

#[test]
fn tail_loops_core_and_long_values() {
    let src = "\
fn count([], acc: int): int = acc
fn count([_, ..t]: [int], acc: int): int = count(t, acc + 1)
fn main() {
  var xs: [int] = []
  for i in 0..200_000 { xs.push(i) }
  print(count(xs, 0))
  print(xs.map(x => x + 1).len())
}
";
    let (o, es) = run_traced("tail", src, &[]);
    assert!(o.status.success(), "{}", text(&o));
    // a self tail call is a loop: one call/ret pair, not 200,000; core's `map` is not traced
    let b = brief(&es);
    assert_eq!(b.len(), 4, "{b:?}");
    assert_eq!(b[2], "ret tail.count = 200000 @1");
    // long values are cut to 200 chars
    let arg = es[1].get("args").as_arr()[0].as_str().unwrap();
    assert!(arg.starts_with("[0, 1, 2, 3,") && arg.ends_with("...") && arg.chars().count() == 203, "{arg}");
    // with --trace-core, core functions are traced too
    let (o, es) = run_traced("tail_core", src, &["--trace-core", "--trace-limit", "100000"]);
    assert!(o.status.success(), "{}", text(&o));
    assert!(es.iter().any(|e| e.get("fn").as_str().is_some_and(|f| f.starts_with("core."))), "{:?}", &brief(&es)[..10]);
}

#[test]
fn trace_to_stderr() {
    let d = scratch("stderr");
    fs::write(d.join("fact.auk"), FACT).unwrap();
    let o = auk_cmd().args(["run", "--trace=json", "fact.auk"]).current_dir(&d).output().unwrap();
    assert!(o.status.success());
    let es = events(&String::from_utf8_lossy(&o.stderr));
    assert_eq!(es.len(), 10);
    // flags must come before the file: after it they are the program's arguments
    let o = auk_cmd().args(["run", "fact.auk", "--trace=json"]).current_dir(&d).output().unwrap();
    assert!(o.status.success() && o.stderr.is_empty(), "{}", text(&o));
    let o = auk_cmd().args(["run", "--trace-limit", "3", "fact.auk"]).current_dir(&d).output().unwrap();
    assert_eq!(o.status.code(), Some(2));
    assert!(text(&o).contains("need --trace"), "{}", text(&o));
}

const TESTS: &str = "\
fn fact(0): int = 1
fn fact(n: int): int = n * fact(n - 1)
fn deep(n: int): int = deep(n + 1) + 1
test \"good\" { assert fact(3) == 6 }
test \"bad\" { assert fact(3) == 7 }
test \"overflow\" { assert deep(0) == 1 }
";

#[test]
fn a_failing_test_prints_its_trace() {
    let d = scratch("tests");
    fs::write(d.join("t.auk"), TESTS).unwrap();
    let o = auk_cmd().args(["test", "--trace=json", "t.auk"]).current_dir(&d).env("AUK_LEAK_CHECK", "1").output().unwrap();
    let out = String::from_utf8_lossy(&o.stdout).into_owned();
    assert_eq!(o.status.code(), Some(1), "{out}");
    assert!(out.starts_with("ok good\nFAIL bad\n"), "{out}");
    let bad = &out[out.find("FAIL bad").unwrap()..out.find("FAIL overflow").unwrap()];
    assert!(bad.contains("    trace (last events, oldest first):\n"), "{bad}");
    let lines: Vec<&str> = bad.lines().filter_map(|l| l.strip_prefix("    {")).collect();
    let es = events(&lines.iter().map(|l| format!("{{{l}\n")).collect::<String>());
    assert_eq!(
        brief(&es),
        [
            "call t.fact(3) @0",
            "call t.fact(2) @1",
            "call t.fact(1) @2",
            "call t.fact(0) @3",
            "ret t.fact = 1 @3",
            "ret t.fact = 1 @2",
            "ret t.fact = 2 @1",
            "ret t.fact = 6 @0",
            "panic assertion failed: fact(3) == 7\n  left: 6\n  right: 7 @0",
            "test",
        ]
    );
    assert_eq!(es[9].get("result").as_str(), Some("FAIL"));
    // a stack overflow: the last 20 events, then the signal
    let ov = &out[out.find("FAIL overflow").unwrap()..];
    let lines: Vec<String> = ov.lines().filter_map(|l| l.strip_prefix("    {")).map(|l| format!("{{{l}\n")).collect();
    let es = events(&lines.concat());
    let b = brief(&es);
    assert_eq!(b.len(), 23, "{b:?}");
    assert_eq!(b[0], "truncated");
    assert!(b[1].starts_with("call t.deep("), "{b:?}");
    assert_eq!(b[21..], ["signal", "test"]);
    // a passing run prints no trace
    let o = auk_cmd().args(["test", "--trace=json", "t.auk", "good"]).current_dir(&d).output().unwrap();
    assert_eq!(String::from_utf8_lossy(&o.stdout), "ok good\n1 passed, 0 failed\n");
}

#[test]
fn per_test_trace_files() {
    let d = scratch("test_dir");
    fs::write(d.join("t.auk"), TESTS).unwrap();
    let o = auk_cmd().args(["test", "--trace=traces", "--trace-limit", "50", "t.auk"]).current_dir(&d).output().unwrap();
    assert_eq!(o.status.code(), Some(1), "{}", text(&o));
    assert!(!String::from_utf8_lossy(&o.stdout).contains("\"ev\""), "traces go to the files");
    let read = |n: &str| events(&fs::read_to_string(d.join("traces").join(n)).unwrap());
    let good = brief(&read("good.jsonl"));
    assert_eq!(good.first().map(String::as_str), Some("call t.fact(3) @0"));
    assert_eq!(good.last().map(String::as_str), Some("test"));
    let ov = read("overflow.jsonl");
    assert_eq!(ov.len(), 53);
    assert_eq!(brief(&ov[50..]), ["truncated", "signal", "test"]);
    assert_eq!(ov[52].get("result").as_str(), Some("FAIL"));
}

/// Without the flag the generated program has no instrumentation at all (and the trace
/// environment doesn't change codegen); with it every function outside core is wrapped.
#[test]
fn no_instrumentation_without_the_flag() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let ir = |args: &[&str], env: bool| {
        let mut c = auk_cmd();
        c.arg("ir").args(args).current_dir(root);
        if env {
            c.env("AUK_TRACE", "-").env("AUK_TRACE_LIMIT", "5");
        }
        let o = c.output().unwrap();
        assert!(o.status.success(), "{}", text(&o));
        String::from_utf8(o.stdout).unwrap()
    };
    for f in ["examples/tour.auk", "examples/life.auk", "examples/physics.auk"] {
        let plain = ir(&[f], false);
        assert!(!plain.contains("trace"), "{f}: the untraced program mentions tracing");
        assert_eq!(ir(&[f], true), plain, "{f}: the environment changed the generated program");
        // traced: a wrapper per function, call sites, and the tracer's start in main
        let traced = ir(&["--trace", f], false);
        assert_ne!(traced, plain);
        assert!(traced.contains("    auk_trace_init(false);\n    dk_init();"), "{f}");
        assert!(traced.contains("_main_untraced(") && traced.contains("auk__trace_site_slot()") && traced.contains("auk_trace_begin()"), "{f}");
        // only the program's functions: core's (like `print`'s helpers) are not wrapped
        assert!(!traced.contains("\"core."), "{f}");
        assert!(ir(&["--trace", "--trace-core", f], false).contains("\"core."), "{f}");
    }
}

/// Traced builds keep the leak checker at zero.
#[test]
fn traced_builds_are_leak_free() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let d = scratch("clean");
    for (cmd, f) in [("test", "examples/calc.auk"), ("test", "examples/bank.auk"), ("run", "examples/tour.auk"), ("run", "examples/life.auk")] {
        let tr = d.join("trace.out");
        let o = auk_cmd()
            .arg(cmd)
            .arg(if cmd == "run" { format!("--trace={}", tr.display()) } else { "--trace=json".into() })
            .arg("--trace-core")
            .arg(f)
            .current_dir(root)
            .env("AUK_LEAK_CHECK", "1")
            .output()
            .unwrap();
        assert!(o.status.success(), "{f}: {}", text(&o));
        assert!(!text(&o).contains("leak"), "{f}: {}", text(&o));
    }
}

/// `auk hatch` feeds a failing candidate's trace back: the fake model only gives the right
/// answer when the retry prompt shows what the wrong one returned.
#[test]
fn hatch_retry_prompt_includes_the_trace() {
    let d = scratch("hatch");
    let src = "fn mid(xs: [int]): int { ?? }\ntest \"mid\" { assert mid([5, 7, 9]) == 7 }\n";
    fs::write(d.join("h.auk"), src).unwrap();
    let script = "#!/bin/sh\np=$(cat)\nn=$(ls \"$D\" | grep -c '^prompt\\.')\nprintf '%s' \"$p\" > \"$D/prompt.$n\"\n\
        if printf '%s' \"$p\" | grep -qF '{\"ev\":\"ret\",\"fn\":\"h.mid\",\"value\":\"5\"'; then\n  printf '```auk\\nxs[xs.len() / 2]\\n```\\n'\n\
        else\n  printf '```auk\\nxs[0]\\n```\\n'\nfi\n";
    fs::write(d.join("model.sh"), script).unwrap();
    let o = auk_cmd()
        .args(["hatch", "h.auk"])
        .current_dir(&d)
        .env("AUK_HATCH_CMD", format!("D='{}' sh '{}'", d.display(), d.join("model.sh").display()))
        .output()
        .unwrap();
    assert!(o.status.success(), "{}", text(&o));
    assert!(text(&o).contains("filled after 2 tries"), "{}", text(&o));
    let second = fs::read_to_string(d.join("prompt.1")).unwrap();
    assert!(second.contains("execution trace"), "{second}");
    assert!(second.contains("    {\"ev\":\"call\",\"fn\":\"h.mid\",\"loc\":\"h.auk:4:21\",\"args\":[\"[5, 7, 9]\"],\"depth\":0}\n"), "{second}");
    assert!(second.contains("    {\"ev\":\"test\",\"name\":\"mid\",\"result\":\"FAIL\"}"), "{second}");
}

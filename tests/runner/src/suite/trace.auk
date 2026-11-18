/// tests/trace.rs: execution traces: `auk run --trace=...` and `auk test --trace=...`
/// (runtime/src/trace.rs, the wrappers in lower.rs). Every trace line read here must parse as
/// JSON (json.auk, the port of src/json.rs).

pub fn tests(): [t.Test] uses env, fs, ffi, time = [
  t.test("recursive_calls_nest_with_depths", recursive_calls_nest_with_depths),
  t.test("errors_propagate_through_question_marks", errors_propagate_through_question_marks),
  t.test("a_panic_ends_the_trace", a_panic_ends_the_trace),
  t.test("peeks_are_events", peeks_are_events),
  t.test("the_event_limit_truncates", the_event_limit_truncates),
  t.test("tail_loops_core_and_long_values", tail_loops_core_and_long_values),
  t.test("trace_to_stderr", trace_to_stderr),
  t.test("a_failing_test_prints_its_trace", a_failing_test_prints_its_trace),
  t.test("per_test_trace_files", per_test_trace_files),
  t.test("no_instrumentation_without_the_flag", no_instrumentation_without_the_flag),
  t.test("traced_builds_are_leak_free", traced_builds_are_leak_free),
  t.test("hatch_retry_prompt_includes_the_trace", hatch_retry_prompt_includes_the_trace),
]

fn auk_cmd(): cmd.Cmd uses env, ffi {
  var c = t.auk()
  for v in ["AUK_LEAK_CHECK", "AUK_TRACE", "AUK_TRACE_LIMIT", "AUK_TRACE_TAIL"] {
    c = c.unsetenv(v)
  }
  c
}

fn text(o: cmd.Out): str = o.stdout + o.stderr

fn scratch(name: str): str uses env, fs, ffi = t.scratch("trace/{name}")

/// Parse JSON Lines; every line must be a JSON object with an `ev`.
fn events(jsonl: str): [json.Json] {
  jsonl.lines().map(l => {
    let e = match json.parse(l) {
      ok(e) => e
      err(Bad(m)) => t.bail("not JSON ({m}): {l}")
    }
    t.check(e.get("ev").as_str() is some(_), "no `ev`: {l}")
    e
  })
}

fn s(e: json.Json, k: str): str = e.get(k).as_str() else ""

/// `ev fn depth` (plus the args or value or error) of each event, for exact comparisons.
fn brief(es: [json.Json]): [str] {
  es.map(e => {
    let depth = match e.get("depth").as_i64() {
      some(d) => " @{d}"
      none => ""
    }
    match s(e, "ev") {
      "call" => {
        let args = e.get("args").as_arr().map(a => a.as_str()!)
        "call {s(e, "fn")}({args.join(", ")}){depth}"
      }
      "ret" => "ret {s(e, "fn")} = {s(e, "value")}{depth}"
      "err" => "err {s(e, "fn")} ! {s(e, "error")}{depth}"
      "peek" => "peek {s(e, "expr")} = {s(e, "value")}{depth}"
      "panic" => "panic {s(e, "msg")}{depth}"
      ev => ev
    }
  })
}

/// Write `src` as `<name>.auk` in a scratch dir and `auk run` it with a trace file (plus
/// `flags`) and the leak checker on. Returns the output and the events.
fn run_traced(name: str, src: str, flags: [str]): (cmd.Out, [json.Json]) uses env, fs, ffi, time {
  let d = scratch(name)
  t.write(paths.join(d, "{name}.auk"), src)
  let tr = paths.join(d, "trace.jsonl")
  let o = auk_cmd()
    .arg("run")
    .arg("--trace={tr}")
    .args(flags)
    .arg("{name}.auk")
    .cwd(d)
    .setenv("AUK_LEAK_CHECK", "1")
    .output()
  let es = events(fs.read(tr) else "")
  (o, es)
}

let FACT =
  "fn fact(0): int = 1\nfn fact(n: int): int = n * fact(n - 1)\nfn main() {{ print(fact(3)) }}\n"

fn recursive_calls_nest_with_depths() uses env, fs, ffi, time {
  let (o, es) = run_traced("fact", FACT, [])
  t.check(o.success(), text(o))
  assert o.stdout == "6\n"
  assert brief(es) == [
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
  // `loc` is the call site (main's call from the entry point has none: its definition)
  var locs: [str] = []
  for e in es {
    match e.get("loc").as_str() {
      some(l) => locs.push(l)
      none => {}
    }
  }
  assert locs ==
    ["fact.auk:3:4", "fact.auk:3:19", "fact.auk:2:28", "fact.auk:2:28", "fact.auk:2:28"]
}

fn errors_propagate_through_question_marks() uses env, fs, ffi, time {
  let src = r"""
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
    """
  let (o, es) = run_traced("errs", src, [])
  t.check(o.success(), text(o))
  assert brief(es) == [
    "call errs.main() @0",
    "call errs.quarter(6) @1",
    "call errs.half(6) @2",
    "ret errs.half = 3 @2",
    "call errs.half(3) @2",
    "err errs.half ! Odd(3) @2",
    "err errs.quarter ! Odd(3) @1",
    "ret errs.main = () @0",
  ]
}

fn a_panic_ends_the_trace() uses env, fs, ffi, time {
  let src = "fn pick(xs: [int], i: int): int = xs[i]\nfn go(n: int): int = pick([1, 2], n) + 1\nfn main() {{ print(go(5)) }}\n"
  let (o, es) = run_traced("boom", src, [])
  t.check(o.code == some(101), text(o))
  assert brief(es) == [
    "call boom.main() @0",
    "call boom.go(5) @1",
    "call boom.pick([1, 2], 5) @2",
    "panic index 5 out of range for length 2 @3",
  ]
  assert es[3].get("loc").as_str() == some("boom.auk:1:35")
}

fn peeks_are_events() uses env, fs, ffi, time {
  let src = "fn sq(x: int): int = x * x\nfn main() {{\n  let y = peek sq(4) + 1\n  print(y)\n}}\n"
  let (o, es) = run_traced("peek", src, [])
  t.check(o.success(), text(o))
  // the human-readable peek line is still printed
  t.check(o.stderr.contains("[peek.auk:3] sq(4) + 1 = 17"), text(o))
  assert brief(es) == [
    "call peek.main() @0",
    "call peek.sq(4) @1",
    "ret peek.sq = 16 @1",
    "peek sq(4) + 1 = 17 @1",
    "ret peek.main = () @0",
  ]
  assert es[3].get("loc").as_str() == some("peek.auk:3")
}

fn the_event_limit_truncates() uses env, fs, ffi, time {
  let src = "fn id(n: int): int = n\nfn main() {{\n  var t = 0\n  for i in 0..20_000 {{ t += id(i) }}\n  print(t)\n}}\n"
  let (o, es) = run_traced("limit", src, ["--trace-limit", "5"])
  t.check(o.success(), text(o))
  assert es.len() == 6
  assert es[5].get("ev").as_str() == some("truncated")
  assert es[5].get("limit").as_i64() == some(5)
  // the default limit is 10,000 events
  let (o, es) = run_traced("limit_default", src, [])
  t.check(o.success(), text(o))
  assert es.len() == 10001
  assert brief(es.skip(10000)) == ["truncated"]
  // a panic past the limit is still recorded
  let src =
    "fn id(n: int): int = n\nfn main() {{\n  for i in 0..100 {{ id(i) }}\n  print([1][3])\n}}\n"
  let (_, es) = run_traced("limit_panic", src, ["--trace-limit=10"])
  assert brief(es.skip(10)) == ["truncated", "panic index 3 out of range for length 1 @1"]
}

fn tail_loops_core_and_long_values() uses env, fs, ffi, time {
  let src = r"""
    fn count([], acc: int): int = acc
    fn count([_, ..t]: [int], acc: int): int = count(t, acc + 1)
    fn main() {
      var xs: [int] = []
      for i in 0..200_000 { xs.push(i) }
      print(count(xs, 0))
      print(xs.map(x => x + 1).len())
    }
    """
  let (o, es) = run_traced("tail", src, [])
  t.check(o.success(), text(o))
  // a self tail call is a loop: one call/ret pair, not 200,000; core's `map` is not traced
  let b = brief(es)
  t.check(b.len() == 4, "{b}")
  assert b[2] == "ret tail.count = 200000 @1"
  // long values are cut to 200 chars
  let arg = es[1].get("args").as_arr()[0].as_str()!
  t.check(arg.starts_with("[0, 1, 2, 3,") && arg.ends_with("...") && arg.len() == 203, arg)
  // with --trace-core, core functions are traced too
  let (o, es) = run_traced("tail_core", src, ["--trace-core", "--trace-limit", "100000"])
  t.check(o.success(), text(o))
  t.check(es.any(e => (e.get("fn").as_str() else "").starts_with("core.")), "{brief(es).take(10)}")
}

fn trace_to_stderr() uses env, fs, ffi, time {
  let d = scratch("stderr")
  t.write(paths.join(d, "fact.auk"), FACT)
  let o = auk_cmd().args(["run", "--trace=json", "fact.auk"]).cwd(d).output()
  assert o.success()
  let es = events(o.stderr)
  assert es.len() == 10
  // flags must come before the file: after it they are the program's arguments
  let o = auk_cmd().args(["run", "fact.auk", "--trace=json"]).cwd(d).output()
  t.check(o.success() && o.stderr == "", text(o))
  let o = auk_cmd().args(["run", "--trace-limit", "3", "fact.auk"]).cwd(d).output()
  assert o.code == some(2)
  t.check(text(o).contains("need --trace"), text(o))
}

let TESTS = "fn fact(0): int = 1\nfn fact(n: int): int = n * fact(n - 1)\nfn deep(n: int): int = deep(n + 1) + 1\ntest \"good\" {{ assert fact(3) == 6 }}\ntest \"bad\" {{ assert fact(3) == 7 }}\ntest \"overflow\" {{ assert deep(0) == 1 }}\n"

/// The trace lines of a test's FAIL block (`    {...}`), as JSON Lines.
fn trace_lines(block: str): str {
  var out = ""
  for l in block.lines() {
    match l.strip_prefix("    {{") {
      some(rest) => out = out + "{{{rest}\n"
      none => {}
    }
  }
  out
}

fn a_failing_test_prints_its_trace() uses env, fs, ffi, time {
  let d = scratch("tests")
  t.write(paths.join(d, "t.auk"), TESTS)
  let o = auk_cmd()
    .args(["test", "--trace=json", "t.auk"])
    .cwd(d)
    .setenv("AUK_LEAK_CHECK", "1")
    .output()
  let out = o.stdout
  t.check(o.code == some(1), out)
  t.check(out.starts_with("ok good\nFAIL bad\n"), out)
  let bad = out[out.find("FAIL bad")!..out.find("FAIL overflow")!]
  t.check(bad.contains("    trace (last events, oldest first):\n"), bad)
  let es = events(trace_lines(bad))
  assert brief(es) == [
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
  assert es[9].get("result").as_str() == some("FAIL")
  // a stack overflow: the last 20 events, then the panic
  let ov = out[out.find("FAIL overflow")!..out.len()]
  let es = events(trace_lines(ov))
  let b = brief(es)
  t.check(b.len() == 23, "{b}")
  assert b[0] == "truncated"
  t.check(b[1].starts_with("call t.deep("), "{b}")
  assert b.skip(21) == ["panic stack overflow", "test"]
  // a passing run prints no trace
  let o = auk_cmd().args(["test", "--trace=json", "t.auk", "good"]).cwd(d).output()
  t.eq(o.stdout, "ok good\n1 passed, 0 failed\n", "")
}

fn per_test_trace_files() uses env, fs, ffi, time {
  let d = scratch("test_dir")
  t.write(paths.join(d, "t.auk"), TESTS)
  let o = auk_cmd().args(["test", "--trace=traces", "--trace-limit", "50", "t.auk"]).cwd(d).output()
  t.check(o.code == some(1), text(o))
  t.check(!o.stdout.contains("\"ev\""), "traces go to the files")
  let read = (n: str) => events(t.read(paths.join(d, "traces/{n}")))
  let good = brief(read("good.jsonl"))
  assert good.first() == some("call t.fact(3) @0")
  assert good.last() == some("test")
  let ov = read("overflow.jsonl")
  assert ov.len() == 53
  assert brief(ov.skip(50)) == ["truncated", "panic stack overflow", "test"]
  assert ov[52].get("result").as_str() == some("FAIL")
}

/// Without the flag the generated program has no instrumentation at all (and the trace
/// environment doesn't change codegen); with it every function outside core is wrapped.
fn no_instrumentation_without_the_flag() uses env, fs, ffi, time {
  let root = t.root()
  let ir = (args: [str], with_env: bool) => {
    var c = auk_cmd().arg("ir").args(args).cwd(root)
    if with_env { c = c.setenv("AUK_TRACE", "-").setenv("AUK_TRACE_LIMIT", "5") }
    let o = c.output()
    t.check(o.success(), text(o))
    o.stdout
  }
  for f in ["examples/tour.auk", "examples/life.auk", "examples/physics.auk"] {
    let plain = ir([f], false)
    t.check(!plain.contains("trace"), "{f}: the untraced program mentions tracing")
    t.check(ir([f], true) == plain, "{f}: the environment changed the generated program")
    // traced: a wrapper per function, call sites, and the tracer's start in main
    let traced = ir(["--trace", f], false)
    assert traced != plain
    t.check(traced.contains("    auk_trace_init(false);\n    dk_init();"), f)
    t.check(
      traced.contains("_main_untraced(") &&
        traced.contains("auk__trace_site_slot()") &&
        traced.contains("auk_trace_begin()"),
      f,
    )
    // only the program's functions: core's (like `print`'s helpers) are not wrapped
    t.check(!traced.contains("\"core."), f)
    t.check(ir(["--trace", "--trace-core", f], false).contains("\"core."), f)
  }
}

/// Traced builds keep the leak checker at zero.
fn traced_builds_are_leak_free() uses env, fs, ffi, time {
  let root = t.root()
  let d = scratch("clean")
  for (c, f) in [
    ("test", "examples/calc.auk"),
    ("test", "examples/bank.auk"),
    ("run", "examples/tour.auk"),
    ("run", "examples/life.auk"),
  ] {
    let tr = paths.join(d, "trace.out")
    let o = auk_cmd()
      .arg(c)
      .arg(if c == "run" { "--trace={tr}" } else { "--trace=json" })
      .arg("--trace-core")
      .arg(f)
      .cwd(root)
      .setenv("AUK_LEAK_CHECK", "1")
      .output()
    t.check(o.success(), "{f}: {text(o)}")
    t.check(!text(o).contains("leak"), "{f}: {text(o)}")
  }
}

/// `auk hatch` feeds a failing candidate's trace back: the fake model only gives the right
/// answer when the retry prompt shows what the wrong one returned.
fn hatch_retry_prompt_includes_the_trace() uses env, fs, ffi, time {
  t.skip_if_lacks("hatch", "the retry prompt")
  let d = scratch("hatch")
  let src = "fn mid(xs: [int]): int {{ ?? }}\ntest \"mid\" {{ assert mid([5, 7, 9]) == 7 }}\n"
  t.write(paths.join(d, "h.auk"), src)
  let script = r"""
    #!/bin/sh
    p=$(cat)
    n=$(ls "$D" | grep -c '^prompt\.')
    printf '%s' "$p" > "$D/prompt.$n"
    if printf '%s' "$p" | grep -qF '{"ev":"ret","fn":"h.mid","value":"5"'; then
      printf '```auk\nxs[xs.len() / 2]\n```\n'
    else
      printf '```auk\nxs[0]\n```\n'
    fi
    """
  t.write(paths.join(d, "model.sh"), script)
  let o = auk_cmd()
    .args(["hatch", "h.auk"])
    .cwd(d)
    .setenv("AUK_HATCH_CMD", "D='{d}' sh '{paths.join(d, "model.sh")}'")
    .output()
  t.check(o.success(), text(o))
  t.check(text(o).contains("filled after 2 tries"), text(o))
  let second = t.read(paths.join(d, "prompt.1"))
  t.check(second.contains("execution trace"), second)
  t.check(
    second.contains("    {{\"ev\":\"call\",\"fn\":\"h.mid\",\"loc\":\"h.auk:4:21\",\"args\":[\"[5, 7, 9]\"],\"depth\":0}}\n"),
    second,
  )
  t.check(second.contains("    {{\"ev\":\"test\",\"name\":\"mid\",\"result\":\"FAIL\"}}"), second)
}

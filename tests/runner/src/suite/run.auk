/// tests/run.rs: the back end end to end: programs are compiled, linked with the runtime and run.
///
/// - `examples` programs with a `main` run and print their expected output (with fixtures
///   supplied here: a text file for `wc`, a CSV for `csv_stats`, a temp dir for `todo`, a local
///   HTTP listener for `fetch`);
/// - `auk test` passes for every example with tests (except `hatch.auk`, whose holes must fail
///   its tests) and for every package, one file at a time and as a flat directory;
/// - leak checks (`AUK_LEAK_CHECK`), and codegen edge cases;
/// - every `tests/errors` program fails `auk check` with the code in its header;
/// - `auk spec` prints docs/spec.md.
///
/// Rust's `setup()` (raft install in examples, http, url, log) is the runner's setup.

pub fn tests(): [t.Test] uses env, fs, ffi, time, net = [
  t.test("wc_counts_words_in_a_file", wc_counts_words_in_a_file),
  t.test("grep_filters_stdin_with_line_numbers", grep_filters_stdin_with_line_numbers),
  t.test("csv_stats_summarizes_a_column", csv_stats_summarizes_a_column),
  t.test("aconv_generates_converts_and_probes", aconv_generates_converts_and_probes),
  t.test("todo_keeps_a_json_file", todo_keeps_a_json_file),
  t.test("fetch_checks_urls_concurrently", fetch_checks_urls_concurrently),
  t.test("example_tests_pass", example_tests_pass),
  t.test("hatch_tests_fail_on_unfilled_holes", hatch_tests_fail_on_unfilled_holes),
  t.test("test_command_runs_each_file_of_a_flat_dir", test_command_runs_each_file_of_a_flat_dir),
  t.test("package_tests_pass", package_tests_pass),
  t.test(
    "test_command_filters_and_takes_a_project_dir",
    test_command_filters_and_takes_a_project_dir,
  ),
  t.test("no_leaks_in_corpus_tests", no_leaks_in_corpus_tests),
  t.test("no_leaks_in_programs", no_leaks_in_programs),
  t.test("package_tests_are_leak_free", package_tests_are_leak_free),
  t.test("ir_prints_mir_and_llvm", ir_prints_mir_and_llvm),
  t.test("map_counting_idiom_updates_in_place", map_counting_idiom_updates_in_place),
  t.test(
    "else_in_tail_position_infers_the_value_type",
    else_in_tail_position_infers_the_value_type,
  ),
  t.test("cow_through_var_params", cow_through_var_params),
  t.test("borrowed_element_reads", borrowed_element_reads),
  t.test("match_on_str_with_many_literals", match_on_str_with_many_literals),
  t.test("str_of_chars_and_char_ranges", str_of_chars_and_char_ranges),
  t.test("string_append_in_place", string_append_in_place),
  t.test("move_out_of_a_container", move_out_of_a_container),
  t.test("closures_capture_values", closures_capture_values),
  t.test("nested_and_recursive_enums", nested_and_recursive_enums),
  t.test("err_payloads_match_after_conversion", err_payloads_match_after_conversion),
  t.test("overflow_traps", overflow_traps),
  t.test("self_tail_calls_are_loops", self_tail_calls_are_loops),
  t.test("peek_prints_source_and_value", peek_prints_source_and_value),
  t.test("contract_failures", contract_failures),
  t.test("build_refuses_holes", build_refuses_holes),
  t.test("async_tasks_and_any_shapes", async_tasks_and_any_shapes),
  t.test("control_flow_and_formatting", control_flow_and_formatting),
  t.test("runtime_bindings_link", runtime_bindings_link),
  t.test("imprints_are_computed_at_compile_time", imprints_are_computed_at_compile_time),
  t.test("imprint_errors", imprint_errors),
  t.test("cow_through_boxed_fields", cow_through_boxed_fields),
  t.test("ensures_on_clause_groups", ensures_on_clause_groups),
  t.test("recorded_auto_wraps", recorded_auto_wraps),
  t.test("optional_chaining_into_tuples", optional_chaining_into_tuples),
  t.test("tail_loops_in_result_functions", tail_loops_in_result_functions),
  t.test("catch_recovers_panics", catch_recovers_panics),
  t.test("catch_without_a_panic_leaks_nothing", catch_without_a_panic_leaks_nothing),
  t.test("task_panics_are_raised_at_await", task_panics_are_raised_at_await),
  t.test("await_any_and_cancel", await_any_and_cancel),
  t.test("channels_and_task_heaps", channels_and_task_heaps),
  t.test("live_reload_swaps_code_and_keeps_state", live_reload_swaps_code_and_keeps_state),
  t.test(
    "live_reload_restarts_only_the_tasks_using_a_changed_type",
    live_reload_restarts_only_the_tasks_using_a_changed_type,
  ),
  t.test("error_programs_fail_with_their_code", error_programs_fail_with_their_code),
  t.test("examples_check_clean_as_json", examples_check_clean_as_json),
  t.test("spec", spec),
  t.test("usage_lists_every_command", usage_lists_every_command),
  t.test("gui_pixel_helpers_draw_and_clip", gui_pixel_helpers_draw_and_clip),
  t.ignored("gui_window_round_trip", gui_window_round_trip),
  t.ignored("gui_text_window", gui_text_window),
  t.ignored("gui_window_shows_the_frame", gui_window_shows_the_frame),
]

fn auk_cmd(): cmd.Cmd uses env, ffi = t.auk().unsetenv("AUK_LEAK_CHECK")

fn auk(args: [str]): cmd.Out uses env, ffi, time = auk_cmd().args(args).output()

fn scratch(name: str): str uses env, fs, ffi = t.scratch("run/{name}")

fn run_ok(args: [str]): str uses env, ffi, time {
  let o = auk(args)
  t.check(o.success(), "auk {args} failed ({o.code}):\n{o.stdout}\n{o.stderr}")
  o.stdout
}

// ---- examples with a main ----

/// Examples with a `.out` file: deterministic programs that need no input.
fn wc_counts_words_in_a_file() uses env, ffi, time {
  let out = run_ok(["run", "examples/wc.auk", "tests/fixtures/words.txt"])
  t.eq(out, r"""
     1. the             5
     2. raft            3
     3. fox             2
     4. dog             2
     5. a               2
     6. quick           1
     7. brown           1
     8. jumps           1
     9. over            1
    10. lazy            1
    """, "")
  let o = auk(["run", "examples/wc.auk"])
  assert o.code == some(2)
  assert o.stdout == "usage: wc <file>\n"
  let o = auk(["run", "examples/wc.auk", "tests/fixtures/no-such-file.txt"])
  assert o.code == some(1)
  t.check(o.stderr.starts_with("error: "), o.stderr)
}

/// `auk run examples/grep.auk <pattern>` with `input` piped to stdin, under the leak check.
fn grep(args: [str], input: str): cmd.Out uses env, ffi, time {
  auk_cmd()
    .args(["run", "examples/grep.auk"])
    .args(args)
    .setenv("AUK_LEAK_CHECK", "1")
    .stdin(input)
    .output()
}

fn grep_filters_stdin_with_line_numbers() uses env, ffi, time {
  let o = grep(["auk"], "an auk\nno\r\n\nauks raft\nend")
  t.check(o.code == some(0), o.describe())
  assert o.text() == ("1: an auk\n4: auks raft\n", "")
  let o = grep(["swan"], "an auk\n")
  assert o.code == some(1)
  assert o.text() == ("", "")
  let o = grep([], "")
  assert o.code == some(2)
  assert o.text() == ("", "usage: grep <pattern>\n")
}

fn csv_stats_summarizes_a_column() uses env, ffi, time {
  let out = run_ok(["run", "examples/csv_stats.auk", "tests/fixtures/stats.csv", "price"])
  assert out == "n=4 mean=3.65 min=0.1 max=12.75 sd=5.282\n"
  let out = run_ok(["run", "examples/csv_stats.auk", "tests/fixtures/stats.csv", "qty"])
  assert out == "n=4 mean=5.25 min=1.0 max=10.0 sd=3.491\n"
  let o = auk(["run", "examples/csv_stats.auk", "tests/fixtures/stats.csv", "nope"])
  assert o.code == some(1)
  assert o.stderr == "error: no column nope\n"
}

/// `examples/aconv.auk`: generate a tone, filter it into a FLAC file, probe it, and measure it.
fn aconv_generates_converts_and_probes() uses env, fs, ffi, time {
  let d = scratch("aconv")
  let f = paths.join(d, "tone.flac")
  let out = run_ok([
    "run",
    "examples/aconv.auk",
    "-f",
    "lavfi",
    "-i",
    "sine=f=1000:d=0.5:r=8000",
    "-af",
    "volume=6dB,afade=t=out:d=0.1",
    "-metadata",
    "title=Beep",
    f,
  ])
  t.check(out.contains("tone.flac: flac, 8000 Hz, 1 ch, 00:00:00.500,"), out)
  let out = run_ok(["run", "examples/aconv.auk", "-i", f])
  t.check(
    out.contains("Stream: Audio: flac (flac), 8000 Hz, 1 channels, 16 bits") &&
      out.contains("title           : Beep"),
    out,
  )
  let wav = paths.join(d, "half.wav")
  let out = run_ok([
    "run",
    "examples/aconv.auk",
    "-i",
    f,
    "-t",
    "0.25",
    "-ar",
    "16000",
    "-ac",
    "2",
    "-sample_fmt",
    "s24",
    "-stats",
    wav,
  ])
  t.check(
    out.contains("channel 1: peak -12.0") &&
      out.contains("half.wav: pcm_s24le, 16000 Hz, 2 ch, 00:00:00.250"),
    out,
  )
  let o = auk(["run", "examples/aconv.auk", "-i", "tests/fixtures/words.txt"])
  assert o.code == some(1)
  t.check(o.stderr.contains("unsupported: unknown file format"), o.describe())
}

fn todo_go(todo: str, dir: str, args: [str]): (int?, str, str) uses env, ffi, time {
  auk_cmd().arg("run").arg(todo).args(args).cwd(dir).output().triple()
}

fn todo_keeps_a_json_file() uses env, fs, ffi, time {
  let dir = scratch("todo")
  let todo = t.abs("examples/todo.auk")
  assert todo_go(todo, dir, ["add", "buy", "milk"]).0 == some(0)
  assert todo_go(todo, dir, ["add", "walk", "the", "auk"]).0 == some(0)
  assert todo_go(todo, dir, ["done", "1"]).0 == some(0)
  assert todo_go(todo, dir, ["ls"]) == (some(0), "x 1. buy milk\n  2. walk the auk\n", "")
  assert t.read(paths.join(dir, "todos.json")) ==
    "[{{\"done\":true,\"id\":1,\"text\":\"buy milk\"}},{{\"done\":false,\"id\":2,\"text\":\"walk the auk\"}}]"
  assert todo_go(todo, dir, ["done", "9"]) == (some(1), "", "error: no todo #9\n")
  assert todo_go(todo, dir, ["done", "x"]) == (some(1), "", "error: not a number: x\n")
  assert todo_go(todo, dir, []) == (some(1), "", "error: usage: todo add|done|ls\n")
}

/// A tiny HTTP server on 127.0.0.1: `/ok` is 200, anything else 404. Serves `n` connections.
/// Its port comes back on `port`.
async fn serve(n: int, port: Chan<int>): int uses net {
  var l = net.listen("127.0.0.1", 0)!
  port.send(l.port())
  for _ in 0..n {
    var s = match l.accept() {
      ok(s) => s
      err(_) => continue
    }
    var req: [int] = []
    while !str_of(req).contains("\r\n\r\n") {
      match s.read(1024) {
        ok(b) => if b.len() == 0 { break } else { req = req + b }
        err(_) => break
      }
    }
    let line = str_of(req).lines().first() else ""
    let (status, body) = if line.starts_with("GET /ok ") {
      ("200 OK", "hello")
    } else {
      ("404 Not Found", "nope")
    }
    let resp =
      "HTTP/1.1 {status}\r\nContent-Length: {body.len()}\r\nConnection: close\r\n\r\n{body}"
    let _ = s.write(resp.bytes())
    s.close()
  }
  l.close()
  0
}

fn str_of(b: [int]): str = sys.lossy(b)

fn fetch_checks_urls_concurrently() uses env, ffi, time, net {
  let pc: Chan<int> = chan()
  let server = serve(2, pc)
  let port = pc.recv()!
  // a port nothing listens on
  let closed = {
    var l = net.listen("127.0.0.1", 0)!
    let p = l.port()
    l.close()
    p
  }
  let ok = "http://127.0.0.1:{port}/ok"
  let missing = "http://127.0.0.1:{port}/missing"
  let refused = "http://127.0.0.1:{closed}/x"
  let o = auk(["run", "examples/fetch.auk", ok, missing, refused])
  t.check(o.code == some(1), o.describe())
  let lines = o.stdout.lines()
  t.check(lines.len() == 3, o.stdout)
  t.check(lines[0].starts_with("✓ 200 ") && lines[0].ends_with("ms {ok}"), o.stdout)
  assert lines[1] == "✗ 404 {missing}"
  t.check(lines[2].starts_with("✗ ERR "), o.stdout)
  let _ = await server
  // all good: exit 0
  let pc: Chan<int> = chan()
  let server = serve(1, pc)
  let port = pc.recv()!
  let ok = "http://127.0.0.1:{port}/ok"
  let o = auk(["run", "examples/fetch.auk", ok])
  t.check(o.code == some(0), o.describe())
  let _ = await server
}

// ---- auk test ----

fn example_tests_pass() uses env, ffi, time {
  var n = 0
  for name in ["bank", "calc", "fib", "physics", "router", "tour"] {
    let out = run_ok(["test", "examples/{name}.auk"])
    t.check(out.ends_with(" passed, 0 failed\n") && !out.contains("FAIL"), "{name}:\n{out}")
    n += 1
  }
  assert n == 6
}

fn hatch_tests_fail_on_unfilled_holes() uses env, ffi, time {
  let o = auk(["test", "examples/hatch.auk"])
  let out = o.stdout
  assert o.code == some(1)
  t.check(out.ends_with("0 passed, 3 failed\n"), out)
  for name in ["median", "dedup", "seconds"] { t.check(out.contains("FAIL {name}\n"), out) }
  t.check(out.contains("panic: unfilled hole (expected float)\n      at examples/hatch.auk:"), out)
  t.check(out.contains("panic: unfilled hole (expected [int])"), out)
  t.check(out.contains("panic: unfilled hole (expected int!DurErr)"), out)
}

/// `auk test` on a flat directory (no `src/lib.auk` or `src/main.auk`): every top-level file
/// with tests is its own program, run in sorted order under a header, with a combined summary.
fn test_command_runs_each_file_of_a_flat_dir() uses env, ffi, time {
  let o = auk(["test", "examples"])
  let (out, err) = o.text()
  t.check(o.code == some(1), "hatch's holes must fail the run:\n{out}\n{err}")
  let headers = out.lines().filter(l => l.starts_with("== "))
  t.check(
    headers == [
      "== bank.auk",
      "== calc.auk",
      "== fib.auk",
      "== hatch.auk",
      "== physics.auk",
      "== router.auk",
      "== tour.auk",
      "== 7 files: 6 passed, 3 failed",
    ],
    out,
  )
  // each file's own report sits under its header; only hatch fails
  let section = (name: str) => out.split("== {name}\n")[1].split("\n== ")[0]
  for name in ["bank", "calc", "fib", "physics", "router", "tour"] {
    let sec = section("{name}.auk")
    t.check(sec.ends_with(" passed, 0 failed") && !sec.contains("FAIL"), "{name}:\n{sec}")
  }
  let hatch = section("hatch.auk")
  t.check(hatch.contains("FAIL median\n") && hatch.ends_with("0 passed, 3 failed"), hatch)
  // files without tests (hello, wc, ...) are skipped
  t.check(!out.contains("hello.auk") && !err.contains("no `test` blocks"), "{out}\n{err}")
  // a filter applies to every file
  let out = run_ok(["test", "examples", "calc"])
  t.check(out.contains("== calc.auk\nok calc\n1 passed, 0 failed\n"), out)
  t.check(out.ends_with("== 7 files: 1 passed, 0 failed\n"), out)
}

/// The count on the summary line (`N passed, ...`).
fn passed(out: str): int = int.parse((out.lines().last() else "").split(" ")[0]) else -1

fn package_tests_pass() uses env, ffi, time {
  // (package, minimum number of test blocks it has), so a silently skipped suite is caught.
  let pkgs = [
    ("json", 16),
    ("csv", 11),
    ("regex", 15),
    ("cli", 11),
    ("http", 32),
    ("encoding", 8),
    ("hash", 8),
    ("datetime", 19),
    ("url", 13),
    ("toml", 23),
    ("log", 6),
    ("uuid", 8),
    ("num", 15),
    ("text", 14),
    ("glob", 8),
    ("compress", 9),
    ("yaml", 14),
    ("xml", 11),
    ("sup", 7),
    ("splash", 24),
    ("audio", 17),
    ("graphics", 7),
  ]
  for (pkg, min) in pkgs {
    let out = run_ok(["test", "packages/{pkg}/src/lib.auk"])
    t.check(out.ends_with(" passed, 0 failed\n") && !out.contains("FAIL"), "{pkg}:\n{out}")
    let n = passed(out)
    t.check(n >= min, "{pkg}: only {n} tests ran, expected at least {min}")
  }
}

fn test_command_filters_and_takes_a_project_dir() uses env, ffi, time {
  let out = run_ok(["test", "packages/regex/src/lib.auk", "captures"])
  assert out == "ok captures\n1 passed, 0 failed\n"
  let out = run_ok(["test", "packages/csv"])
  t.check(out.ends_with("11 passed, 0 failed\n"), out)
  // dependencies' tests are excluded: http depends on json
  let out = run_ok(["test", "packages/http/src/lib.auk"])
  t.check(!out.contains("ok literals and whitespace"), out)
}

// ---- leaks and sanitizers ----

fn no_leaks_in_corpus_tests() uses env, ffi, time {
  for f in [
    "examples/calc.auk",
    "examples/bank.auk",
    "examples/router.auk",
    "examples/tour.auk",
    "packages/json/src/lib.auk",
    "packages/regex/src/lib.auk",
    "packages/csv/src/lib.auk",
    "packages/cli/src/lib.auk",
    "packages/http/src/lib.auk",
  ] {
    let o = auk_cmd().args(["test", f]).setenv("AUK_LEAK_CHECK", "1").output()
    t.check(o.success(), "{f} leaks or fails:\n{o.stdout}\n{o.stderr}")
    t.check(!o.stdout.contains("leak:"), "{f}:\n{o.stdout}")
  }
}

fn no_leaks_in_programs() uses env, ffi, time {
  for args in [
    ["run", "examples/inventory.auk"],
    ["run", "examples/life.auk"],
    ["run", "examples/tour.auk"],
    ["run", "examples/wc.auk", "tests/fixtures/words.txt"],
    ["run", "examples/csv_stats.auk", "tests/fixtures/stats.csv", "price"],
  ] {
    let o = auk_cmd().args(args).setenv("AUK_LEAK_CHECK", "1").output()
    t.check(o.success(), "{args}: {o.describe()}")
  }
}

/// Every package's tests pass with the leak checker on: each test (a forked child) frees every
/// runtime object it made.
fn package_tests_are_leak_free() uses env, ffi, time {
  // sup's tests crash and cancel children on purpose: their heaps must be swept clean
  for pkg in [
    "json",
    "csv",
    "regex",
    "cli",
    "http",
    "encoding",
    "hash",
    "datetime",
    "url",
    "toml",
    "log",
    "uuid",
    "num",
    "text",
    "glob",
    "compress",
    "yaml",
    "xml",
    "sup",
    "splash",
    "audio",
  ] {
    let o = auk_cmd()
      .args(["test", "packages/{pkg}/src/lib.auk"])
      .setenv("AUK_LEAK_CHECK", "1")
      .output()
    let (out, err) = o.text()
    t.check(
      o.success() && out.ends_with(" 0 failed\n"),
      "{pkg} with the leak checker:\n{out}\n{err}",
    )
    t.check(!out.contains("leak") && !err.contains("leak"), "{pkg}:\n{out}\n{err}")
  }
}

/// `auk ir` prints the MIR and `auk ir --llvm` the LLVM IR, for real programs.
fn ir_prints_mir_and_llvm() uses env, ffi, time {
  for f in ["examples/tour.auk", "examples/fetch.auk", "examples/grep.auk", "examples/life.auk"] {
    let mir = run_ok(["ir", f])
    t.check(mir.contains("dk_entry(") && mir.contains("auk_main_wrapper("), f)
    let ll = run_ok(["ir", "--llvm", f])
    t.check(ll.contains("define ") && ll.contains(" @main(") && ll.contains("call "), f)
  }
}

// ---- codegen edge cases ----

/// Write a program to a scratch file and `auk run` it with the leak checker on.
fn run_src(name: str, src: str): cmd.Out uses env, fs, ffi, time {
  let d = scratch(name)
  let p = paths.join(d, "{name}.auk")
  t.write(p, src)
  auk_cmd().arg("run").arg(p).setenv("AUK_LEAK_CHECK", "1").cwd(d).output()
}

fn expect_out(name: str, src: str, want: str) uses env, fs, ffi, time {
  let o = run_src(name, src)
  t.check(o.success(), "{name} failed ({o.code}):\n{o.stdout}\n{o.stderr}")
  t.eq(o.stdout, want, "{name}: stderr:\n{o.stderr}")
}

/// The counting idiom `m[k] = (m.get(k) else d) op x` is compiled as one lookup (an update in
/// place) when the key is present: the same results as the plain form, including copy-on-write
/// (a snapshot keeps its value), floats, a missing key, an overflow under `catch` that leaves the
/// map unchanged, and a default with a call (not fused).
fn map_counting_idiom_updates_in_place() uses env, fs, ffi, time {
  expect_out("map_update", r"""
      fn bump(): int = 100

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
      """, r"""
      {"a": 3, "b": 2, "c": 1}
      {3: 0.25, 7: 1.5}
      {1: 15, 2: 42} {1: 10}
      true {5: 9223372036854775807}
      {1: 101}
      """)
}

fn expect_panic(name: str, src: str, msg: str) uses env, fs, ffi, time {
  let o = run_src(name, src)
  t.check(o.code == some(101), "{name}: {o.stdout}\n{o.stderr}")
  t.check(o.stderr.contains(msg), "{name}: expected {msg.show()} in:\n{o.stderr}")
}

/// `x else y` / `x!` as the last expression of `T!`, `T?` and plain functions, with generic
/// calls returning `T?` (`max`, `min`, `find`, `first`, `get`) and `T!` (with an `else e =>`).
fn else_in_tail_position_infers_the_value_type() uses env, ffi, time {
  let f = "tests/fixtures/else_inference.auk"
  let o = auk(["check", f])
  t.check(o.success() && o.stdout == "" && o.stderr == "", "{o.stdout}\n{o.stderr}")
  let o = auk_cmd().args(["run", f]).setenv("AUK_LEAK_CHECK", "1").output()
  t.check(o.success(), "{o.stdout}\n{o.stderr}")
  t.eq(
    o.stdout,
    "9 2 19 a\n5 1 4\ntrue\nnth: short\n-1 7 0  7 7\n8 8\nshort\n2 1 0 - 0 0\n",
    "stderr:\n{o.stderr}",
  )
}

fn cow_through_var_params() uses env, fs, ffi, time {
  expect_out("cow", r"""
      fn bump(xs: var [int]) { xs.push(99) }
      struct Acc { xs: [int], n: int }
      fn add(a: var Acc, x: int) {
        a.xs.push(x)
        a.n += 1
      }
      fn main() {
        let a = [1, 2]
        var b = a
        bump(&b)
        print("{a} {b}")
        var acc = Acc { xs: a, n: 0 }
        let snapshot = acc
        acc.add(5)
        add(&acc, 6)
        print("{acc.xs} {acc.n} {snapshot.xs} {snapshot.n} {a}")
        var m = {"k": [1]}
        let m2 = m
        m["k"] = [2]
        print("{m} {m2}")
      }
      """, r"""
      [1, 2] [1, 2, 99]
      [1, 2, 5, 6] 2 [1, 2] 0 [1, 2]
      {"k": [2]} {"k": [1]}
      """)
}

/// Element reads that are only looked at (a field of an element, a comparison, a `match` or
/// `is` on one, a call argument) are borrowed, not retained; the values stay right when a later
/// call changes the list, and a field passed next to `&` of the same variable keeps its value.
fn borrowed_element_reads() uses env, fs, ffi, time {
  expect_out("borrowed_reads", r"""
      enum Tok { Ident(s: str), LParen, Fn }
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
      """, r"""
      ident xy false true d1
      ( true true true
      d1cleared
      0 gone!
      p1
      0
      d1
      d1,,
      """)
}

/// A `match` on a `str` with many literal arms is one table lookup (`auk_str_switch`); arm
/// order, guards, a non-literal arm between literals and non-ASCII literals behave as before.
fn match_on_str_with_many_literals() uses env, fs, ffi, time {
  expect_out("str_switch", r"""
      fn kw(s: str): int = match s {
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
      """, r"""
      fn: 1
      let: 2
      var: 3
      if: 4
      else: 5
      : 6
      héllo: 7
      match: 8
      matcha: 9
      matc: 0
      x: 0
      fnn: 0
      f: 0
      ["a big", "a small", "e", "z-ish zed", "f", "other"]
      """)
}

/// `str(cs)` and `str(cs[a..b])` (built straight from the char range, no slice) give the same
/// strings as before, non-ASCII, empty, of a slice view, and the same out-of-range panic.
fn str_of_chars_and_char_ranges() uses env, fs, ffi, time {
  expect_out("str_chars", r"""
      fn main() {
        let cs = "aé🦆xyz".chars()
        let v = cs[1..5]
        print([str(cs), str(cs[0..3]), str(cs[1..=2]), str(cs[2..2]), str(v[1..3]), str(cs[3..cs.len()])])
        let r = catch str(cs[4..9])
        print("{r}".contains("slice 4..9 out of range for length 6"))
      }
      """, "[\"aé🦆xyz\", \"aé🦆\", \"é🦆\", \"\", \"🦆x\", \"xyz\"]\ntrue\n")
}

/// `s += x` (and `s = s + x`) appends in place when the string is unique: a local, a `var`
/// parameter, a struct field, a list element, a map value, in a task's heap too; a copy taken
/// before (`let snap = s`) keeps its value, and `t += t` reads itself correctly.
fn string_append_in_place() uses env, fs, ffi, time {
  expect_out("string_append_in_place", r"""
      struct Doc { title: str, lines: [str] }

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
      """, r"""
      1000 2000
      1000 1001 false
      abababab
      abc ["xyz"] a ["x"]
      q01234567891011
      zabcd 5 c
      {"k": "vw"}
      40000
      10000 6000
      """)
}

/// `var g = xs[i]`, changes to `g`, `xs[i] = g` moves the element out instead of copying it;
/// the results are the same as a copy's: a snapshot of the list keeps its values, `g` stays
/// usable after it goes back, and a read of the list in between or a changed index variable turns
/// the move off.
fn move_out_of_a_container() uses env, fs, ffi, time {
  expect_out("move_out_of_a_container", r"""
      struct Group { name: str, clauses: [str] }

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
      """, r"""
      ["a []", "b!!!!! [\"x\", \"c0\", \"c1\", \"c2\", \"c3\", \"c4\"]"]
      ["a []", "b [\"x\"]"]
      [[1, 10], [2]] [1, 10, 20]
      [[1]]
      [[1, 2]]
      {"k": [1, 2]}
      [[1], [1, 5]]
      [[1], [1, 3]] 0
      """)
}

fn closures_capture_values() uses env, fs, ffi, time {
  expect_out("closures", r"""
      fn adders(): [(int) => int] {
        var out: [(int) => int] = []
        for k in 1..=3 {
          let base = k * 10
          out.push(x => x + base)
        }
        out
      }
      fn twice(f: (int) => int, x: int): int = f(f(x))
      fn main() {
        print(adders().map(f => f(1)))
        var n = 5
        let g = x => x * n
        n = 100
        print(g(2))
        let pre = "#"
        print(["a", "b"].map(s => pre + s).join(","))
        print(twice(x => x + 1, 0))
        let pairs = [(1, "one"), (2, "two")]
        print(pairs.map((i, s) => "{s}={i}"))
      }
      """, r"""
      [11, 21, 31]
      10
      #a,#b
      2
      ["one=1", "two=2"]
      """)
}

fn nested_and_recursive_enums() uses env, fs, ffi, time {
  expect_out("enums", r"""
      enum Tree { Leaf(v: int), Node(l: Tree, r: Tree) }
      enum Wrap { A(t: Tree?), B(ws: [Wrap]) }
      struct User { name: str, boss: User? }
      fn sum(Leaf(v)): int = v
      fn sum(Node(l, r)): int = sum(l) + sum(r)
      fn depth(Leaf(_)): int = 1
      fn depth(Node(l, r)): int = 1 + if depth(l) > depth(r) { depth(l) } else { depth(r) }
      fn main() {
        let t = Node(Leaf(1), Node(Leaf(2), Leaf(3)))
        print("{sum(t)} {depth(t)} {t}")
        print(B([A(some(t)), A(none)]))
        print(t == Node(Leaf(1), Node(Leaf(2), Leaf(3))))
        let u = User { name: "ann", boss: some(User { name: "bob", boss: none }) }
        print(u.boss?.name else "-")
        print(u.boss?.boss?.name else "-")
        match t {
          Node(Leaf(a), Node(b, _)) => print("{a} {b}")
          _ => print("?")
        }
      }
      """, r"""
      6 3 Node(Leaf(1), Node(Leaf(2), Leaf(3)))
      B([A(some(Node(Leaf(1), Node(Leaf(2), Leaf(3))))), A(none)])
      true
      bob
      -
      1 Leaf(2)
      """)
}

fn err_payloads_match_after_conversion() uses env, fs, ffi, time {
  expect_out("payloads", r"""
      enum E { Bad(w: str), Worse }
      fn typed(n: int): int!E {
        if n == 0 { fail(Bad("zero")) }
        if n < 0 { fail(Worse) }
        n
      }
      fn plain(n: int): int! = typed(n)?
      fn show(r: int!): str = match r {
        err(Bad(why)) => "bad {why}"
        err(e) => "other {e}"
        ok(n) => "ok {n}"
      }
      fn main() {
        print(show(plain(0)))
        print(show(plain(-1)))
        print(show(plain(3)))
        print(typed(-1) is err(Worse))
        let v = typed(0) else e => match e { Bad(w) => w.len(), Worse => -1 }
        print(v)
        let m = plain(0) else e => -2
        print(m)
      }
      """, r"""
      bad zero
      other Worse
      ok 3
      true
      4
      -2
      """)
}

fn overflow_traps() uses env, fs, ffi, time {
  expect_panic("ovf_add", r"""
    fn main() {
      var x = 9223372036854775800
      for _ in 0..10 { x += 1 }
      print(x)
    }
    """, "panic: integer overflow in `+`\n  at ")
  expect_panic(
    "ovf_mul",
    "fn big(n: int): int = n * n\nfn main() {{ print(big(4_000_000_000)) }}\n",
    "integer overflow in `*`",
  )
  expect_panic(
    "div0",
    "fn d(a: int, b: int): int = a / b\nfn main() {{ print(d(1, 0)) }}\n",
    "division by zero",
  )
  expect_out("wrap", "fn main() {{ print(9223372036854775807 +% 1) }}\n", "-9223372036854775808\n")
}

fn self_tail_calls_are_loops() uses env, fs, ffi, time {
  expect_out("tail", r"""
      fn len([], acc: int): int = acc
      fn len([_, ..t]: [int], acc: int): int = len(t, acc + 1)
      fn sum(xs: [int], i: int, acc: int): int {
        if i == xs.len() { return acc }
        sum(xs, i + 1, acc + xs[i])
      }
      fn main() {
        var xs: [int] = []
        for i in 0..1_000_000 { xs.push(i) }
        print(len(xs, 0))
        print(sum(xs, 0, 0))
      }
      """, "1000000\n499999500000\n")
}

fn peek_prints_source_and_value() uses env, fs, ffi, time {
  let o = run_src("peek", r"""
    fn main() {
      let x = 21
      let y = peek x * 2
      peek "s{y}"
      print(y)
    }
    """)
  t.check(o.success(), o.stderr)
  assert o.stdout == "42\n"
  t.check(o.stderr.contains("peek.auk:3] x * 2 = 42\n"), o.stderr)
  t.check(o.stderr.contains("peek.auk:4] \"s{{y}}\" = s42\n"), o.stderr)
}

fn contract_failures() uses env, fs, ffi, time {
  expect_panic("requires", r"""
      fn half(n: int): int
        requires n % 2 == 0
      { n / 2 }
      fn main() {
        print(half(4))
        print(half(3))
      }
      """, "panic: requires failed: n % 2 == 0\n  at ")
  expect_panic("ensures", r"""
    fn bad(n: int): int
      ensures result > n
    { n }
    fn main() { print(bad(1)) }
    """, "panic: ensures failed: result > n")
  expect_panic("old", r"""
      struct A { n: int }
      fn inc(a: var A)
        ensures a.n == old(a.n) + 1
      { a.n += 2 }
      fn main() {
        var a = A { n: 1 }
        inc(&a)
      }
      """, "ensures failed: a.n == old(a.n) + 1")
  expect_panic("assert", r"""
    fn main() {
      let xs = [1, 2]
      assert xs == [1, 3]
    }
    """, "assertion failed: xs == [1, 3]\n  left: [1, 2]\n  right: [1, 3]")
  expect_panic("unwrap", r"""
    fn main() {
      let xs: [int] = []
      print(xs.first()!)
    }
    """, "unwrapped `none`")
}

fn build_refuses_holes() uses env, fs, ffi, time {
  let d = scratch("holes")
  let p = paths.join(d, "h.auk")
  t.write(p, "fn f(): int {{ ?? }}\nfn main() {{ print(f()) }}\n")
  let o = auk(["build", p, "-o", paths.join(d, "h")])
  let err = o.stderr
  assert o.code == some(1)
  t.check(
    err.contains("still has 1 unfilled hole(s)") &&
      err.contains("h.auk:1:15: unfilled hole (expected int)"),
    err,
  )
  assert !fs.exists(paths.join(d, "h"))
  // run allows holes and panics when one is reached
  let o = auk(["run", p])
  assert o.code == some(101)
  assert o.stderr.contains("panic: unfilled hole (expected int)")
  // a complete program builds and runs
  t.write(p, r"""
    fn main(args: [str]): int {
      print("args: {args.len()}")
      3
    }
    """)
  let exe = paths.join(d, "ok")
  let _ = run_ok(["build", p, "-o", exe])
  let o = cmd.new(exe).arg("x").output()
  assert o.code == some(3)
  assert o.stdout == "args: 2\n"
}

fn async_tasks_and_any_shapes() uses env, fs, ffi, time {
  expect_out("async", r"""
      shape Area { fn area(self): float }
      struct Sq { s: float }
      struct Circ { r: float }
      fn area(q: Sq): float = q.s * q.s
      fn area(c: Circ): float = 3.0 * c.r * c.r
      async fn slow(n: int): int uses time {
        time.sleep(5)
        n * 2
      }
      // a plain function that returns a task runs in place (only an `async fn` call starts one)
      fn start(log: var [int], n: int): Task<int> uses time {
        log.push(n)
        slow(n)
      }
      fn first<T>(xs: [T]): T = xs[0]
      fn main() uses time {
        let shapes: [any Area] = [Sq { s: 2.0 }, Circ { r: 1.0 }]
        print(shapes.map(s => s.area()))
        let (a, b) = await (slow(1), slow(2))
        print(a + b)
        let t = slow(10)
        print(await t)
        print(await [1, 2, 3].map(n => slow(n)))
        print(await slow(7))
        var log: [int] = []
        let s = start(&log, 4)
        print("{log} {await s}")
        print(await first([slow(5), slow(6)]))
      }
      """, r"""
      [4.0, 3.0]
      6
      20
      [2, 4, 6]
      14
      [4] 8
      10
      """)
}

fn control_flow_and_formatting() uses env, fs, ffi, time {
  expect_out("flow", r"""
      struct P { x: int, y: int, name: str }
      fn grade(n: int): str when n >= 90 = "A"
      fn grade(_: int): str = "B"
      fn main() {
        var i = 0
        let v = loop {
          i += 1
          if i * i > 50 { break i }
        }
        print("v={v} pi={3.14159:.2} [{"ab":>5}] [{42:05}] [{'x':^5}]")
        for k, n in {"b": 2, "a": 1} { print("{k}={n}") }
        let q = P { x: 9, ..P { x: 1, y: 2, name: "p" } }
        print(q)
        print("{grade(95)}{grade(10)}")
        var total = 0
        for j in 0..10 {
          if j % 2 == 0 { continue }
          if j > 7 { break }
          total += j
        }
        print(total)
        let s = "GET /users/42"
        match s {
          "GET /users/" + id => print("user {id}")
          _ => print("?")
        }
        print([3, 1, 2].sort().reverse())
        print("a b a".split().counts())
      }
      """, r"""
      v=8 pi=3.14 [   ab] [00042] [  x  ]
      b=2
      a=1
      P { x: 9, y: 2, name: "p" }
      AB
      16
      user 42
      [3, 2, 1]
      {"a": 2, "b": 1}
      """)
}

/// Every kind of runtime binding in the prelude links and behaves (externs with element
/// pointers, out-parameters, `+loc`, `var` containers, `T?`/`T!` results).
fn runtime_bindings_link() uses env, fs, ffi, time {
  expect_out("externs", r"""
      fn main() uses rand, env, proc, time, fs {
        let r = rand.int(1, 6)
        print(r >= 1 && r <= 6)
        print(rand.float() < 1.0)
        print(env.get("PATH") is some(_))
        print(env.args().len() > 0)
        print(proc.run("echo", ["hi"])!.trim())
        print(time.now() > 0)
        print(str.from_utf8([104, 105])!)
        print(int.parse("12")! + 1)
        print(float.parse("1.5")!)
        print(fs.write("x.txt", "a\nb")!)
        print(fs.lines("x.txt")!)
        print("abc".repeat(2).upper().find("C"))
        var xs = [1, 2, 3]
        xs.insert(0, 9)
        print(xs.remove(1))
        print(xs.pop())
        print(xs)
        var m = {"a": 1}
        print(m.remove("a"))
        print(m.get("a"))
        print(char(65))
        print(3.7.floor() + abs(-2.0) + (-3).abs().float())
        print(int(2.9) + int('a'))
        var s = set([1, 2, 2])
        s.insert(3)
        print(s.to_list())
      }
      """, r"""
      true
      true
      true
      true
      hi
      true
      hi
      13
      1.5
      ()
      ["a", "b"]
      some(2)
      1
      some(3)
      [9, 2]
      some(1)
      none
      some('A')
      8.0
      99
      [1, 2, 3]
      """)
}

// ---- compile-time imprints ----

let IMPRINTS = r"""
  struct Cfg { name: str, ratio: float, tags: [str], limit: int?, nick: str? }
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
  """

fn imprints_are_computed_at_compile_time() uses env, fs, ffi, time {
  expect_out("imprints", IMPRINTS, r"""
      [2, 3, 5, 7, 11, 13, 17, 19, 23, 29]
      some(199)
      1046
      {"one": 1, "two": 4, "three": 9}
      Cfg { name: "auk \"q\" é\n", ratio: 0.1, tags: ["a", "b"], limit: some(3), nick: none }
      [Push(1), Pop, Jump(0, "start")]
      Node(Node(Leaf(0), Leaf(1)), Leaf(2))
      Emp { name: "a", boss: some(Emp { name: "b", boss: none }) }
      [[1.5, -0.0, 1e300], []]
      {"name": "auk \"q\" é\n", "ratio": 0.1, "tags": ["a", "b"], "limit": 3, "nick": Null}
      1 a 3
      """)
  // the generated program holds the values, not the computation
  let d = scratch("imprints_ir")
  let p = paths.join(d, "imprints.auk")
  t.write(p, IMPRINTS)
  let ir = run_ok(["ir", p])
  t.check(ir.contains("INT64_C(193)") && ir.contains("INT64_C(199)"), "the primes are data")
  t.check(ir.contains("_PRIMES_init(void)"), "an imprint is built from its value")
  t.check(!ir.contains("_const_PRIMES(void)"), "no initializer function for an imprint")
  t.check(!ir.contains("_sieve(INT64_C(200))"), "sieve(200) isn't called at run time")
  t.check(ir.contains("INT64_C(1046)"), "an imprint using another imprint and a `let`")
}

fn compile_err(name: str, src: str): str uses env, fs, ffi, time {
  let o = run_src(name, src)
  t.check(o.code == some(1), "{name}: {o.stdout}\n{o.stderr}")
  o.stderr
}

fn imprint_errors() uses env, fs, ffi, time {
  // a panic while computing it, blamed on the imprint (also through another imprint)
  let err = compile_err("imprint_panic", r"""
      fn fact(n: int): int = if n == 0 { 1 } else { n * fact(n - 1) }
      imprint FACTS = (0..=25).map(n => fact(n))
      imprint N = FACTS.len()
      fn main() { print(N) }
      """)
  t.check(
    err.contains("imprint_panic.auk:2:9: error[E0420]: computing `imprint FACTS` at compile time panicked: integer overflow in `*`"),
    err,
  )
  t.check(err.contains("note: the panic happened at ") && err.contains("imprint_panic.auk:1:"), err)
  let err = compile_err("imprint_index", r"""
    let XS = [1, 2]
    fn at(i: int): int = XS[i]
    imprint A = at(5)
    fn main() { print(A) }
    """)
  t.check(
    err.contains("error[E0420]: computing `imprint A` at compile time panicked: index 5 out of range"),
    err,
  )
  // a cycle through a function
  let err = compile_err("imprint_cycle", r"""
    fn f(): int = A + 1
    imprint A: int = f()
    fn main() { print(A) }
    """)
  t.check(
    err.contains("imprint_cycle.auk:2:9: error[E0115]: the constant `A` depends on itself"),
    err,
  )
  // the type must be Data (reported by `auk check`)
  let d = scratch("imprint_data")
  let p = paths.join(d, "t.auk")
  t.write(p, r"""
    imprint F = (x: int) => x + 1
    imprint T = (1, 2)
    imprint OK = [some(1), none]
    fn main() { print(F(1)) }
    """)
  let o = auk(["check", p])
  let err = o.stderr
  assert o.code == some(1)
  t.check(
    err.contains("t.auk:1:9: error[E0350]: `(int) => int` doesn't fit the shape `Data`, which `imprint F` needs"),
    err,
  )
  t.check(err.contains("t.auk:2:9: error[E0350]: `(int, int)` doesn't fit the shape `Data`"), err)
  t.check(t.count(err, "error[") == 2, err)
}

// ---- card #510 ----

/// Writing through a boxed (recursive) field copies the box when another value shares it.
fn cow_through_boxed_fields() uses env, fs, ffi, time {
  expect_out("cow_boxed", r"""
      struct A { v: int, b: B }
      struct B { v: int, c: C, xs: [int] }
      struct C { v: int, a: A? }
      struct Emp { name: str, pay: int, boss: Boss }
      struct Boss { name: str, pay: int, up: Emp? }
      fn raise(e: var Emp) { e.boss.pay += 100 }
      fn main() {
        let x = A { v: 1, b: B { v: 2, c: C { v: 3, a: none }, xs: [1] } }
        var y = x
        y.b.c.v += 10
        y.b.v = 20
        y.b.xs.push(2)
        y.b.xs[0] = 9
        print("{x.b.v} {x.b.c.v} {x.b.xs} | {y.b.v} {y.b.c.v} {y.b.xs}")
        let e = Emp { name: "ann", pay: 1, boss: Boss { name: "bob", pay: 10, up: none } }
        var f = e
        f.boss.name = "carl"
        raise(&f)
        var g = f
        g.boss.pay = 0
        g.boss = Boss { name: "dee", pay: 5, up: some(e) }
        print("{e.boss.name} {e.boss.pay} | {f.boss.name} {f.boss.pay} | {g.boss.name} {g.boss.pay}")
      }
      """, "2 3 [1] | 20 13 [9, 2]\nbob 10 | carl 110 | dee 5\n")
}

/// `ensures` on a clause group is checked for whichever clause runs; self tail calls stay loops.
fn ensures_on_clause_groups() uses env, fs, ffi, time {
  // `sign(5)` runs the guarded clause (no `ensures`), not the last one
  let src = r"""
    fn sign(0): int
      ensures result == 0
    { 0 }
    fn sign(n: int): int when n > 0 { 5 }
    fn sign(n: int): int
      ensures result == 1
    { -1 }
    fn main() {
      print(sign(0))
      print(sign(5))
      print(sign(-5))
    }
    """
  let o = run_src("ensures_clauses", src)
  t.check(o.code == some(101), "{o.stdout}\n{o.stderr}")
  assert o.stdout == "0\n5\n"
  t.check(
    o.stderr.contains("panic: ensures failed: result == 1\n  at ") &&
      o.stderr.contains("ensures_clauses.auk:6:11"),
    o.stderr,
  )
  let src = r"""
    fn len([], acc: int): int
      ensures result == acc
    { acc }
    fn len([_, ..t]: [int], acc: int): int
      ensures result > acc
    { len(t, acc + 1) }
    fn count(n: int, acc: int): int
      requires n >= 0
      ensures result == old(acc) + n
    {
      if n == 0 { return acc }
      count(n - 1, acc + 1)
    }
    fn grow(xs: var [int], n: int)
      ensures xs.len() == old(xs.len()) + n
    {
      if n > 0 {
        xs.push(n)
        grow(&xs, n - 1)
      }
    }
    fn main() {
      var xs: [int] = []
      for i in 0..300000 { xs.push(i) }
      print(len(xs, 0))
      print(len([], 5))
      print(count(1000000, 0))
      var ys = [1]
      grow(&ys, 3)
      print(ys)
    }
    """
  expect_out("ensures_tail", src, "300000\n5\n1000000\n[1, 3, 2, 1]\n")
  let d = scratch("ensures_tail_ir")
  let p = paths.join(d, "t.auk")
  t.write(p, src)
  let ir = run_ok(["ir", p])
  t.check(t.count(ir, "goto dk_tail;") == 3, "every self tail call is a loop")
  assert ir.contains("auk_ensures_fail(")
  // a header's `ensures` covers every clause
  expect_panic("ensures_header", r"""
    fn f(n: int): int
      ensures result >= 0
    fn f(0): int = 0
    fn f(n: int): int = -n
    fn main() {
      print(f(0))
      print(f(3))
    }
    """, "ensures failed: result >= 0")
}

/// Auto-wraps the checker records (shorthand struct fields, `if` without `else` and loops
/// falling through in `()!` / `()?` functions) need no guessing in codegen.
fn recorded_auto_wraps() uses env, fs, ffi, time {
  expect_out("auto_wraps", r"""
      struct P { x: int?, y: str!, name: str }
      fn check(n: int): ()! {
        if n < 0 { fail("negative") }
      }
      fn opt(n: int): ()? {
        if n == 0 { return none }
      }
      fn run(n: int): ()! {
        for i in 0..n { if i > 5 { fail("too many") } }
      }
      fn main() {
        let x = 3
        let y = "why"
        let name = "p"
        let p = P { x, y, name }
        print("{p.x} {p.y else "-"} {p.name}")
        print("{check(1) is ok(_)} {check(-1) is err(_)} {opt(0) is none} {opt(1) is some(_)}")
        print("{run(3) is ok(_)} {run(10) is err(_)}")
      }
      """, r"""
      some(3) why p
      true true true true
      true true
      """)
}

/// `x?.N`: optional chaining into a tuple element, on a `T?`, in a chain and with `else`
/// (a `T?` element flattens). Also `?.m()` on an intrinsic method (`len`) of the element.
fn optional_chaining_into_tuples() uses env, fs, ffi, time {
  expect_out("opt_tuple", r"""
      fn find(xs: [(str, int)], k: str): (str, int)? = xs.find((a, _) => a == k)
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
      """, r"""
      some(1) some("one") none none
      some(2) none 3
      2 0
      some(5) 1
      none some("x") 9
      [1, 2, 3] some(3)
      """)
}

/// Loops in tail position of `()!` / `()?` / `T!` / `T?` functions (directly, in `match` arms
/// and `if` branches), with bare `break`, `break value`, and early `return`/`fail`. A bare
/// `break` out of a `loop` whose value is `()!` once left the result zeroed (an `err`).
fn tail_loops_in_result_functions() uses env, fs, ffi, time {
  expect_out("tail_loops", r"""
      fn l1(): ()! {
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
      """, r"""
      ok true
      ok err(big) true true
      ok err(big) true true
      ok err(big) true true
      20 -1 s3 - 4 -1
      ok ok ok err(bad)
      true true true
      7 2 -1
      ok ok ok err(x)
      true true true
      1 2 -1
      ok true
      """)
}

// ---- catch and task links ----

let CATCH_SRC = r"""
  fn at(xs: [int], i: int): int = xs[i]
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
  """

let CATCH_OUT = r"""
  ok(2)
  caught: panic: index 9 out of range for length 3 at catch.auk:1:33
  ok(12) err(nan: x) 0
  count 2 r err(panic: index 5 out of range for length 3 at catch.auk:1:33)
  1 err(panic: index 5 out of range for length 1 at catch.auk:8:3)
  inner true
  true
  err(panic: key not found: "k" at catch.auk:36:15)
  alive
  """

/// `catch e` turns a panic (index, missing key, one re-raised by `await`) into an `Err`, passes
/// `?`/`fail` errors through, composes with `else`, and changes the `var`s it captures; in the
/// JIT and in an `auk build` executable.
fn catch_recovers_panics() uses env, fs, ffi, time {
  let d = scratch("catch")
  let p = paths.join(d, "catch.auk")
  t.write(p, CATCH_SRC)
  let o = auk_cmd().arg("run").arg("catch.auk").cwd(d).output()
  t.check(o.success(), "{o.stdout}\n{o.stderr}")
  t.eq(o.stdout, CATCH_OUT, "stderr:\n{o.stderr}")
  let exe = paths.join(d, "catch")
  let o = auk_cmd().args(["build", "catch.auk", "-o"]).arg(exe).cwd(d).output()
  t.check(o.success(), o.describe())
  let o = cmd.new(exe).cwd(d).output()
  assert o.stdout == CATCH_OUT
}

/// A `catch` that doesn't panic leaks nothing (a panic leaks what the aborted code owned).
fn catch_without_a_panic_leaks_nothing() uses env, fs, ffi, time {
  expect_out("catch_leaks", r"""
      fn parse(s: str): int! {
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
      """, r"""
      ok("v0")
      ok("v1")
      ok("v2")
      err(nan: q) ["a0", "a1", "a2"]
      """)
}

/// A task's panic ends only the task; `await` raises it again (uncaught: exit 101 with the
/// original location), and a crashed task dropped without an `await` still ends the process.
fn task_panics_are_raised_at_await() uses env, fs, ffi, time {
  let src = r"""
    async fn boom(n: int): int {
      let xs = [1]
      xs[n]
    }
    """
  let o = run_src(
    "task_await",
    "{src}fn main() {{\n  let t = boom(4)\n  print(\"before\")\n  print(await t)\n}}\n",
  )
  t.check(o.code == some(101), "{o.stdout}\n{o.stderr}")
  assert o.stdout == "before\n"
  t.check(
    o.stderr.contains("panic: index 4 out of range for length 1\n  at ") &&
      o.stderr.contains("task_await.auk:3:3"),
    o.stderr,
  )
  let o = run_src(
    "task_dropped",
    "{src}fn go() uses time {{\n  let t = boom(4)\n  time.sleep(20)\n}}\nfn main() uses time {{\n  go()\n  print(\"after\")\n}}\n",
  )
  t.check(o.code == some(101), "{o.stdout}\n{o.stderr}")
  t.check(o.stderr.contains("(in a task that was never awaited)"), o.stderr)
}

/// `await any` gives the first task to finish (its panic or error as the `Err`); `cancel()`
/// stops a loop or a sleep, a `catch` inside the cancelled task can't hold it, a task that
/// crashes cancels the tasks it started (the link), and a cancelled task dropped unawaited is no
/// crash.
fn await_any_and_cancel() uses env, fs, ffi, time {
  // no leak check: cancelling (a panic) leaks what the stopped code owned
  let d = scratch("await_any")
  t.write(paths.join(d, "await_any.auk"), r"""
      async fn slow(ms: int, v: int): int uses time {
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
      """)
  let o = auk_cmd().args(["run", "await_any.auk"]).cwd(d).output()
  t.check(o.success(), "{o.stdout}\n{o.stderr}")
  t.eq(o.stdout, r"""
      1 ok(2)
      2 true
      err(panic: cancelled at await_any.auk:12:3)
      err(panic: cancelled at a blocking call)
      err(panic: cancelled at a blocking call)
      true
      """, o.stderr)
}

/// Tasks share nothing: arguments, results and channel messages are deep copies, and a task
/// that crashes or is cancelled (holding received data, a channel, a half-built list) leaves
/// nothing behind: the whole program runs clean under the leak checker.
fn channels_and_task_heaps() uses env, fs, ffi, time {
  expect_out("chan_heaps", r"""
      struct Job { id: int, tags: [str] }

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
      """, r"""
      3
      job 0 ["t0"]
      job 1 ["t1"]
      job 2 ["t2"]
      ["a", "more"] ["a"]
      true
      err(panic: cancelled at a channel receive)
      """)
}

// ---- auk run --live ----

/// The lines a child writes to stderr, waited for with a deadline (Rust's `Lines`): what came
/// before the line waited for is kept in `seen`.
struct Lines { child: sys.Child, seen: [str] }

/// Wait for a line matching `f` (lines before it are kept); fails after 20 s.
fn wait_line(ls: var Lines, what: str, f: (str) => bool): str uses ffi, time {
  let end = time.now() + 20000
  loop {
    match ls.child.ebuf.find_index(b => b == 10) {
      some(i) => {
        let l = sys.lossy(ls.child.ebuf[0..i])
        ls.child.ebuf = ls.child.ebuf[i + 1..ls.child.ebuf.len()]
        ls.seen.push(l)
        if f(l) { return l }
        continue
      }
      none => {}
    }
    let left = end - time.now()
    if left <= 0 || !sys.pump(&ls.child, min(left, 500)) && ls.child.err < 0 {
      if left <= 0 || ls.child.err < 0 {
        return t.bail("timed out waiting for {what}; stderr so far:\n{ls.seen.join("\n")}")
      }
    }
  }
}

/// The number after `p` at the start of `l`.
fn num(l: str, p: str): int? = match l.strip_prefix(p) {
  some(n) => match int.parse(n) {
    ok(v) => some(v)
    err(_) => none
  }
  none => none
}

fn live_src(msg: str, fields: str, init: str): str = "struct S {{ n: int{fields} }}\n\nfn msg(n: int): str = {msg}\n\nfn main() uses time {{\n  var s = S {{ n: 0{init} }}\n  while s.n < 2_000 {{\n    s.n += 1\n    eprint(msg(s.n))\n    time.sleep(20)\n  }}\n}}\n"

/// `auk run --live`: an edited function body is swapped in while the program keeps its state;
/// a type error keeps the old code running; a changed struct layout restarts the program.
fn live_reload_swaps_code_and_keeps_state() uses env, fs, ffi, time {
  t.skip_if_lacks("live", "live reload (`auk run --live`)")
  let d = scratch("live")
  let f = paths.join(d, "live.auk")
  t.write(f, live_src("\"a{{n}}\"", "", ""))
  let child = auk_cmd().args(["run", "--live", "live.auk"]).cwd(d).start()
  var lines = Lines { child, seen: [] }
  sys.close_stdin(&lines.child)
  let res = catch {
    let _ = wait_line(&lines, "a5", l => (num(l, "a") else 0) >= 5)
    // 1. a new body; the counter carries on
    t.write(f, live_src("\"b{{n}}\"", "", ""))
    let _ = wait_line(&lines, "the reload", l => l.contains("[live] reloaded in"))
    let b = wait_line(&lines, "a b line", l => num(l, "b") is some(_))
    t.check((num(b, "b") else 0) > 5, "the state was lost: {b}")
    // 2. a type error: the old code keeps running
    t.write(f, live_src("5", "", ""))
    let _ = wait_line(&lines, "the type error", l => l.contains("not reloaded"))
    let _ = wait_line(&lines, "b after the error", l => num(l, "b") is some(_))
    // 3. a new field: a restart from scratch
    t.write(f, live_src("\"c{{n}}\"", ", k: int", ", k: 1"))
    let _ = wait_line(
      &lines,
      "the restart",
      l => l.contains("changed shape and `main`'s side of the program uses it: restarting"),
    )
    let c = wait_line(&lines, "a c line", l => num(l, "c") is some(_))
    t.check((num(c, "c") else 99) < 20, "not restarted: {c}")
  }
  sys.kill(&lines.child)
  let _ = cmd.wait(&lines.child, 5000)
  match res {
    ok(_) => {}
    err(e) => t.fail("{e}")
  }
}

fn sup_src(counter: str, init: str, step: str, main_ty: str): str = "struct Counter {{ {counter} }}\nstruct Main {{ {main_ty} }}\n\nfn count(): ()! uses time {{\n  var c = Counter {{ {init} }}\n  while true {{\n    c.n += {step}\n    eprint(\"count {{c.n}}\")\n    time.sleep(20)\n  }}\n}}\n\nfn main(): int! uses time {{\n  let m = Main {{ a: 1 }}\n  eprint(\"main {{m.a}}\")\n  sup.run([sup.child(\"count\", () => count())], sup.one_for_one(5, 60_000))?\n  0\n}}\n"

/// `auk run --live` with supervision: a type only a supervised task uses changes shape, so just
/// that task is stopped and its supervisor starts it on the new code while `main` keeps going;
/// a type `main` itself holds changes shape, so the whole program restarts.
fn live_reload_restarts_only_the_tasks_using_a_changed_type() uses env, fs, ffi, time {
  t.skip_if_lacks("live", "live reload (`auk run --live`)")
  let d = scratch("live_sup")
  t.write(paths.join(d, "raft.toml"), r"""
    [package]
    name = "app"
    version = "0.1.0"
    effects = ["time"]

    [deps]
    sup = "^0.1"
    """)
  let f = paths.join(d, "src/main.auk")
  t.write(f, sup_src("n: int", "n: 0", "1", "a: int"))
  let q = t.raft().arg("install").cwd(d).setenv("RAFT_REGISTRY", t.abs("packages")).output()
  t.check(q.success(), q.describe())
  let child = auk_cmd().args(["run", "--live", "src/main.auk"]).cwd(d).start()
  var lines = Lines { child, seen: [] }
  sys.close_stdin(&lines.child)
  let cnt = (l: str) => num(l, "count ")
  let res = catch {
    let _ = wait_line(&lines, "count 5", l => (cnt(l) else 0) >= 5)
    // only the counting task holds a Counter
    t.write(f, sup_src("n: int, k: int", "n: 0, k: 1", "100", "a: int"))
    let _ = wait_line(
      &lines,
      "the task stop",
      l => l.contains("`Counter` changed shape: stopped 1 task(s) that use it"),
    )
    let _ = wait_line(&lines, "the new code", l => match cnt(l) {
      some(n) => n % 100 == 0 && n > 0
      none => false
    })
    let mains = lines.seen.filter(l => l.starts_with("main ")).len()
    t.check(mains == 1, "main restarted:\n{lines.seen.join("\n")}")
    // main holds a Main
    t.write(
      f,
      sup_src("n: int, k: int", "n: 0, k: 1", "100", "a: int, b: int").replace(
        "Main {{ a: 1 }}",
        "Main {{ a: 1, b: 2 }}",
      ),
    )
    let _ = wait_line(
      &lines,
      "the restart",
      l => l.contains("`Main` changed shape and `main`'s side of the program uses it: restarting the program"),
    )
  }
  sys.kill(&lines.child)
  let _ = cmd.wait(&lines.child, 5000)
  match res {
    ok(_) => {}
    err(e) => t.fail("{e}")
  }
}

// ---- error programs, spec ----

fn error_files(): [str] uses fs {
  let ps = t.auk_files("tests/errors")
  t.check(ps.len() >= 10, "too few error programs: {ps}")
  ps
}

/// Every `tests/errors/X.auk` starts with `// error: E0xxx <message substring>` and must fail
/// `auk check` with exactly that code (the first error reported) and message, in both output
/// modes.
fn error_programs_fail_with_their_code() uses env, fs, ffi, time {
  for p in error_files() {
    let src = t.read(p)
    let header = (src.lines().first() else "").strip_prefix("// error: ") else ""
    let sp = header.find(" ") else -1
    t.check(sp > 0, "{p} must start with `// error: E0xxx <message>`")
    let (code, msg) = (header[0..sp], header[sp + 1..header.len()])
    t.check(code.len() == 5 && code.starts_with("E"), "{p}: bad code {code.show()}")

    let o = auk(["check", p])
    let err = o.stderr
    t.check(o.code == some(1), "{p} should fail to check:\n{err}")
    let first = err.lines().find(
      l => l.contains(": error["),
    ) else t.bail("{p}: no error in:\n{err}")
    t.check(first.contains("error[{code}]: "), "{p}: expected {code} first, got:\n{err}")
    t.check(first.contains(msg), "{p}: expected {msg.show()} in:\n{first}")

    let o = auk(["check", p, "--json"])
    let js = o.stdout
    t.check(!o.success(), "{p}: {js}")
    t.check(
      js.contains("\"ok\":false") && js.contains("\"code\":\"{code}\",\"severity\":\"error\""),
      "{p}: {js}",
    )
  }
}

/// `auk check` accepts every example, with an empty JSON report.
fn examples_check_clean_as_json() uses env, fs, ffi, time {
  for p in t.must(fs.list("examples"), "list examples") {
    if !p.ends_with(".auk") { continue }
    let p = "examples/{p}"
    let o = auk(["check", p, "--json"])
    t.check(o.success() && o.stdout.contains("\"ok\":true,\"diagnostics\":[]"), "{p}: {o.stdout}")
  }
}

/// `auk spec` prints the embedded language reference.
fn spec() uses env, fs, ffi, time {
  let o = auk(["spec"])
  assert o.success()
  assert o.stdout == t.read("docs/spec.md")
}

/// `auk` with no command, or an unknown one, prints the usage (listing every command) and exits 2.
fn usage_lists_every_command() uses env, ffi, time {
  for args in [[], ["frobnicate"], ["check"]] {
    let o = auk(args)
    let err = o.stderr
    t.check(o.code == some(2), "{args}")
    for c in [
      "run",
      "build",
      "check",
      "test",
      "fmt",
      "explain",
      "dive",
      "lsp",
      "ir",
      "spec",
      "raft",
    ] {
      t.check(err.contains("  {c} ") || err.contains("`{c}`"), "{args}: no {c} in:\n{err}")
    }
  }
}

// ---- gui ----

/// Core's pure `pixels` helpers (no window needed): fill, blend, blit, blit_mask, clipping.
fn gui_pixel_helpers_draw_and_clip() uses env, fs, ffi, time {
  let d = scratch("gui_pixels")
  let f = paths.join(d, "px.auk")
  t.write(f, r"""

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
      """)
  let out = run_ok(["run", f])
  assert out == r"""
    000000 000000 000000 000000 000000 ff0000 ff0000 ff0000 000000 ff0000 ff0000 ff0000
    808080 808080 000000 000000
    222222 ff0000 ff0000 ff0000
    808080 808080 00ff00 000000 / 000000 ff0000 cc3300 7f8000
    0000ff 0000ff 0000ff / ffffff 0000ff 0000ff
    7f:ffffff ff:000000
    8080ff 0000ff
    8080ff 8080ff 510
    """
}

/// A real window through the window process: open, present a frame and a rectangle, read
/// events, close. It shows a window for a moment, so it only runs on request (`--ignored`).
fn gui_window_round_trip() uses env, ffi, time {
  if !t.macos() { return }
  let out = run_ok(["run", "examples/gui_gradient.auk", "--for", "800"])
  // a full frame at the start, one more per resize the system made (a display change), and a
  // partial one per mouse move over the window
  t.check(out.ends_with(" partial; 0x0 after closing\n") && out.contains(" full frames, "), out)
}

fn gui_text_window() uses env, ffi, time {
  if !t.macos() { return }
  let out = run_ok(["run", "examples/gui_text.auk", "--for", "500"])
  t.check(out.ends_with("frames; text ok\n"), out)
}

/// The pixels a program presents are what the window shows: `gui_gradient` is green at the
/// bottom left and yellow at the bottom right (`AUK_GUI_SNAP` saves the window as it closes).
fn gui_window_shows_the_frame() uses env, fs, ffi, time {
  if !t.macos() { return }
  let snap = paths.join(fs.temp_dir() else "/tmp", "auk-gui-snap-{sys.pid()}.ppm")
  let _ = fs.remove(snap)
  let o = auk_cmd()
    .args(["run", "examples/gui_gradient.auk", "--for", "600"])
    .setenv("AUK_GUI_SNAP", snap)
    .output()
  t.check(o.success(), o.stderr)
  // the window process writes it just after the program ends
  var data: [int] = []
  for _ in 0..50 {
    time.sleep(100)
    match fs.read_bytes(snap) {
      ok(d) => if d.len() > 0 {
        data = d
        break
      }
      err(_) => {}
    }
  }
  let _ = fs.remove(snap)
  // P6, "w h", 255, then the pixels
  var nl: [int] = []
  for i, b in data {
    if b == 10 && nl.len() < 3 { nl.push(i) }
  }
  t.check(nl.len() == 3, "not a PPM snapshot")
  let size = sys.lossy(data[nl[0] + 1..nl[1]]).split(" ")
  let (w, h) = (int.parse(size[0])!, int.parse(size[1])!)
  let px = data[nl[2] + 1..data.len()]
  let at = (x: int, y: int) => {
    let i = (y * w + x) * 3
    (px[i], px[i + 1], px[i + 2])
  }
  // the capture is in the display's color space (Display P3 turns sRGB (8, 243, 153) into about
  // (112, 239, 161)), so check which channels lead rather than exact values
  let (r, g, b) = at(30, h - 30)
  t.check(g > 200 && g > r + 60 && g > b + 40, "bottom left is {(r, g, b)}")
  let (r, g, b) = at(w - 30, h - 30)
  t.check(r > 200 && g > 200 && b + 100 < r, "bottom right is {(r, g, b)}")
}

/// tests/hatch.rs: `auk hatch` against a fake model: `AUK_HATCH_CMD` is a shell script that logs
/// each prompt (`prompt.0`, `prompt.1`, ...) and answers with canned code chosen by grepping the
/// prompt. No real model is called.

pub fn tests(): [t.Test] uses env, fs, ffi, time = [
  t.test("median_on_the_first_try", median_on_the_first_try),
  t.test("type_errors_are_sent_back", type_errors_are_sent_back),
  t.test("test_failures_are_sent_back", test_failures_are_sent_back),
  t.test("contracts_are_checked", contracts_are_checked),
  t.test("gives_up_after_tries", gives_up_after_tries),
  t.test("a_failing_model_command", a_failing_model_command),
  t.test("dry_run_prints_a_diff", dry_run_prints_a_diff),
  t.test("full_hatch_then_test_and_build", full_hatch_then_test_and_build),
  t.test("a_failed_hole_is_skipped", a_failed_hole_is_skipped),
  t.test("usage_errors", usage_errors),
]

let MEDIAN = "let s = xs.sort()\nlet n = s.len()\nif n % 2 == 1 {{ s[n / 2] }} else {{ (s[n / 2 - 1] + s[n / 2]) / 2.0 }}"

let DEDUP = "var out: [int] = []\nfor x in xs {{\n  if !out.contains(x) {{ out.push(x) }}\n}}\nout"

let SECONDS = r"""
  if s.len() == 0 { fail(Empty) }
  var total = 0
  var n = 0
  var have = false
  for c in s.chars() {
    if c.is_digit() {
      n = n * 10 + (int(c) - int('0'))
      have = true
    } else {
      if !have { fail(NoNumber) }
      let mult = match c {
        'h' => 3_600
        'm' => 60
        's' => 1
        _ => fail(BadUnit(c))
      }
      total += n * mult
      n = 0
      have = false
    }
  }
  if have { fail(NoNumber) }
  total
  """.trim_end()

/// A temp dir with a copy of examples/hatch.auk (plus `extra` appended): (dir, file).
fn setup(name: str, extra: str): (str, str) uses env, fs, ffi {
  let d = t.scratch("hatch/{name}")
  let src = t.read(t.abs("examples/hatch.auk"))
  let f = paths.join(d, "hatch.auk")
  t.write(f, src + extra)
  (d, f)
}

/// Write the fake model: `rules` are (shell condition on "$p", answer) pairs tried in order; the
/// answer is printed inside a ```auk fence. No rule matching = exit 1.
fn fake(dir: str, rules: [(str, str)]): str uses fs {
  var s = "#!/bin/sh\np=$(cat)\nn=$(ls \"$D\" | grep -c '^prompt\\.')\nprintf '%s' \"$p\" > \"$D/prompt.$n\"\nhas() {{ printf '%s' \"$p\" | grep -qF -- \"$1\"; }}\n"
  for i, (cond, answer) in rules {
    s = s +
      "{if i == 0 { "if" } else { "elif" }} {cond}; then\ncat <<'ANSWER'\nHere you go:\n```auk\n{answer}\n```\nANSWER\nexit 0\n"
  }
  s = s + "fi\necho 'no canned answer' >&2\nexit 1\n"
  let script = paths.join(dir, "model.sh")
  t.write(script, s)
  "D='{dir}' sh '{script}'"
}

fn hatch(dir: str, model: str, args: [str]): (cmd.Out, str) uses env, ffi, time {
  let o = t
    .auk()
    .arg("hatch")
    .args(args)
    .cwd(dir)
    .setenv("AUK_HATCH_CMD", model)
    .unsetenv("AUK_LEAK_CHECK")
    .output()
  (o, o.stdout + o.stderr)
}

fn prompts(dir: str): [str] uses fs {
  var out: [str] = []
  var i = 0
  loop {
    let p = paths.join(dir, "prompt.{i}")
    if !fs.exists(p) { break }
    out.push(t.read(p))
    i += 1
  }
  out
}

fn auk(dir: str, args: [str]): cmd.Out uses env, ffi, time =
  t.auk().args(args).cwd(dir).unsetenv("AUK_LEAK_CHECK").output()

fn median_on_the_first_try() uses env, fs, ffi, time {
  let (d, f) = setup("first", "")
  let model = fake(d, [("has 'in fn median'", MEDIAN)])
  let (o, out) = hatch(d, model, ["hatch.auk", "--hole", "1"])
  t.check(o.success(), out)
  t.check(out.contains("hole 1 (fn median, hatch.auk:6): filled after 1 try"), out)
  let src = t.read(f)
  t.check(src.contains("  requires xs.len() > 0\n{{\n  let s = xs.sort()\n"), src)
  t.check(t.count(src, "??") == 3, "the other holes stay (and the header comment's `??`):\n{src}")
  // the prompt: spec, the file, the brief and the instructions
  let ps = prompts(d)
  assert ps.len() == 1
  let p = ps[0]
  for want in [
    "# The Auk language reference",
    "## Contracts, holes, tests, debugging",
    "fn dedup(xs: [int]): [int]",
    "hole 1 at hatch.auk:6:3 in fn median",
    "expected type: float",
    "requires xs.len() > 0",
    "    xs: [float]",
    "assert median([4.0, 1.0, 3.0, 2.0]) == 2.5",
    "Reply with ONLY the code",
  ] {
    t.check(p.contains(want), "the prompt lacks {want.show()}:\n{p}")
  }
  let r = auk(d, ["test", "hatch.auk", "median"])
  t.check(r.success(), r.stdout)
}

fn type_errors_are_sent_back() uses env, fs, ffi, time {
  let (d, f) = setup("type_error", "")
  // the corrected answer is only given when the prompt carries the checker's error code
  let model = fake(d, [("has '\"code\":\"E0200\"'", MEDIAN), ("has 'in fn median'", "xs.len()")])
  let (o, out) = hatch(d, model, ["hatch.auk", "--hole", "1"])
  t.check(o.success(), out)
  t.check(out.contains("filled after 2 tries"), out)
  let ps = prompts(d)
  assert ps.len() == 2
  assert !ps[0].contains("Your previous answer")
  t.check(
    ps[1].contains("## Your previous answer\n```auk\nxs.len()\n```\nIt did not type-check"),
    ps[1],
  )
  t.check(ps[1].contains("expected `float`, found `int`"), ps[1])
  assert t.read(f).contains("let s = xs.sort()")
}

fn test_failures_are_sent_back() uses env, fs, ffi, time {
  let (d, f) = setup("test_failure", "")
  // `xs[0]` type-checks but fails the median test
  let model = fake(d, [("has 'FAIL median'", MEDIAN), ("has 'in fn median'", "xs[0]")])
  let (o, out) = hatch(d, model, ["hatch.auk", "--hole", "1"])
  t.check(o.success(), out)
  t.check(out.contains("filled after 2 tries"), out)
  let ps = prompts(d)
  assert ps.len() == 2
  t.check(ps[1].contains("type-checks, but these tests failed"), ps[1])
  t.check(ps[1].contains("assertion failed: median([3.0, 1.0, 2.0]) == 2.0"), ps[1])
  // the failing test's execution trace: what the candidate actually returned
  t.check(ps[1].contains("execution trace"), ps[1])
  t.check(
    ps[1].contains(r"""{"ev":"call","fn":"hatch.median","loc":"hatch.auk:23:10","args":["[3.0, 1.0, 2.0]"],"depth":0}"""),
    ps[1],
  )
  t.check(ps[1].contains(r"""{"ev":"ret","fn":"hatch.median","value":"3.0","depth":0}"""), ps[1])
  t.check(
    ps[1].contains(r"""{"ev":"panic","msg":"assertion failed: median([3.0, 1.0, 2.0]) == 2.0"""),
    ps[1],
  )
  t.check(!ps[0].contains("{{\"ev\":"), "the first prompt has no trace")
  assert t.read(f).contains("let s = xs.sort()")
}

fn contracts_are_checked() uses env, fs, ffi, time {
  let (d, _) = setup("contract", "")
  // returns the list twice: violates `ensures result.len() <= xs.len()` (the tests also fail)
  let model = fake(d, [("has 'ensures failed'", DEDUP), ("has 'in fn dedup'", "xs + xs")])
  let (o, out) = hatch(d, model, ["hatch.auk", "--hole", "2"])
  t.check(o.success(), out)
  t.check(out.contains("hole 2 (fn dedup, hatch.auk:11): filled after 2 tries"), out)
  assert prompts(d)[1].contains("ensures failed: result.len() <= xs.len()")
}

fn gives_up_after_tries() uses env, fs, ffi, time {
  let (d, f) = setup("give_up", "")
  let before = t.read(f)
  let model = fake(d, [("has 'in fn median'", "xs[0]")])
  let (o, out) = hatch(d, model, ["hatch.auk", "--hole", "1", "--tries", "2"])
  t.check(o.code == some(1), out)
  t.check(
    out.contains("hole 1 (fn median, hatch.auk:6): failed after 2 tries\n  last error:\n    FAIL median"),
    out,
  )
  assert prompts(d).len() == 2
  t.check(t.read(f) == before, "a failed hatch leaves the file alone")
}

fn a_failing_model_command() uses env, fs, ffi, time {
  let (d, f) = setup("bad_cmd", "")
  let before = t.read(f)
  let (o, out) = hatch(d, "echo broken >&2; exit 3", ["hatch.auk", "--hole", "1", "--tries", "1"])
  t.check(o.code == some(1), out)
  t.check(out.contains("failed after 1 try") && out.contains("broken"), out)
  assert t.read(f) == before
}

fn dry_run_prints_a_diff() uses env, fs, ffi, time {
  let (d, f) = setup("dry", "")
  let before = t.read(f)
  let model = fake(d, [("has 'in fn median'", MEDIAN)])
  let (o, out) = hatch(d, model, ["hatch.auk", "--hole", "1", "--dry-run"])
  t.check(o.success(), out)
  assert t.read(f) == before
  t.check(out.contains("--- a/hatch.auk\n+++ b/hatch.auk\n@@ -3,"), out)
  t.check(out.contains("   requires xs.len() > 0\n-{{ ?? }}\n+{{\n+  let s = xs.sort()\n"), out)
  t.check(out.contains("(dry run: no files were changed)"), out)
}

fn full_hatch_then_test_and_build() uses env, fs, ffi, time {
  let (d, f) = setup("full", "\nfn main() {{\n  print(median([2.0, 1.0]))\n}}\n")
  let model = fake(d, [
    ("has 'in fn median'", MEDIAN),
    ("has 'in fn dedup'", DEDUP),
    ("has 'in fn seconds'", SECONDS),
  ])
  let (o, out) = hatch(d, model, ["hatch.auk"])
  t.check(o.success(), out)
  for n in ["hole 1 (fn median", "hole 2 (fn dedup", "hole 3 (fn seconds"] {
    t.check(out.contains(n), out)
  }
  t.check(t.count(out, "filled after 1 try") == 3, out)
  assert prompts(d).len() == 3
  let src = t.read(f)
  t.check(!src.lines().skip(1).any(l => l.contains("??")), src)
  // formatted, tests pass, and a release build accepts it
  assert auk(d, ["fmt", "--check", "hatch.auk"]).success()
  let r = auk(d, ["test", "hatch.auk"])
  t.check(r.success() && r.stdout.contains("3 passed, 0 failed"), r.stdout)
  let b = auk(d, ["build", "hatch.auk", "-o", "hatched"])
  t.check(b.success(), b.stderr)
  let r = cmd.new(paths.join(d, "hatched")).output()
  assert r.stdout == "1.5\n"
  let h = auk(d, ["holes", "hatch.auk"])
  assert h.stdout.starts_with("no holes")
}

fn a_failed_hole_is_skipped() uses env, fs, ffi, time {
  let (d, f) = setup("skip", "")
  // median can't be filled; dedup still is, and keeps its own number
  let model = fake(d, [
    ("has 'in fn median'", "xs[0]"),
    ("has 'in fn dedup'", DEDUP),
    ("has 'in fn seconds'", SECONDS),
  ])
  let (o, out) = hatch(d, model, ["hatch.auk", "--tries", "1"])
  t.check(o.code == some(1), out)
  t.check(out.contains("hole 1 (fn median, hatch.auk:6): failed after 1 try"), out)
  t.check(out.contains("hole 2 (fn dedup") && out.contains("hole 3 (fn seconds"), out)
  t.check(t.count(out, "filled after 1 try") == 2, out)
  let src = t.read(f)
  t.check(
    src.contains("  requires xs.len() > 0\n{{ ?? }}") && src.contains("var out: [int] = []"),
    src,
  )
}

fn usage_errors() uses env, fs, ffi, time {
  let (d, _) = setup("usage", "")
  let (o, out) = hatch(d, "true", ["hatch.auk", "--hole", "9"])
  assert o.code == some(2)
  t.check(out.contains("there is no hole 9"), out)
  let (o, _) = hatch(d, "true", [])
  assert o.code == some(2)
  let help = auk(d, ["help"]).stdout
  t.check(
    help.contains("hatch <file> [--hole N] [--tries 3] [--dry-run]") &&
      help.contains("AUK_HATCH_CMD"),
    help,
  )
  t.check(help.contains("holes <file> [--json]"), help)
}

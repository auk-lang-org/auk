/// `auk hatch <file> [--hole N] [--tries 3] [--dry-run]` (src/hatch.rs): fill `??` holes with an
/// AI model. See the Rust module for the steps; this is a line-by-line port.
///
/// Differences from Rust:
/// - The model command gets its prompt on stdin from a temporary file, and its stdout and stderr
///   go to temporary files (Rust pipes them, writing stdin from a thread): `posix_spawnp` through
///   `ffi`, as core's `proc.run` takes no stdin and keeps no stderr or status.
/// - The tests of a candidate are built and run by the Rust back end until it is ported:
///   `auk __jit test <file>` (the `auk` next to the checkout's `target/release/`, `$AUK_BIN`, or
///   `auk` on PATH) with the candidate's file texts in `$AUK_SOURCES` (Rust's `with_sources`),
///   in its own process group, killed after `TEST_TIMEOUT_MS`. A build error is its exit
///   status 125 (`JIT_BUILD_FAILED`), and its output is the error, as Rust's `Err` would be.
/// - `String::from_utf8_lossy` is `lossy`; `str::trim*` (Unicode whitespace) are `utrim*`.
/// - `srcs` is a `{str: str}` (Rust's `HashMap`), `originals` a sorted list of files (its
///   `BTreeMap`); the `Result<usize, String>` of `fill` is `int!` with the last error as `Err`.

/// The model command when `AUK_HATCH_CMD` is unset.
let DEFAULT_CMD = "claude -p"

/// How long one test run may take before it is killed (an answer may loop forever).
let TEST_TIMEOUT_MS = 60000

/// How many trailing trace events of a failing test go into the retry prompt.
let TRACE_TAIL = "12"

/// `auk __jit`'s exit status when the program doesn't compile (build.rs `JIT_BUILD_FAILED`).
let JIT_BUILD_FAILED = 125

let USAGE = "usage: auk hatch <file> [--hole N] [--tries 3] [--dry-run]"

/// The language reference the prompt starts with (Rust's `SPEC`, `auk spec`).
extern fn spec(): str = "#embed ../../docs/spec.md"

struct Opts { file: str, hole: int?, tries: int, dry_run: bool }

/// Rust's `parse::<usize>()` filtered to `n > 0`: digits with an optional `+`.
fn positive(v: str?): int? {
  let s = v?
  let digits = s.strip_prefix("+") else s
  if digits == "" || !digits.chars().all(c => c.is_digit()) { return none }
  let n = int.parse(digits) else return none
  if n > 0 { n } else { none }
}

fn parse_args(args: [str]): Opts! {
  var o = Opts { file: "", hole: none, tries: 3, dry_run: false }
  var i = 0
  while i < args.len() {
    let a = args[i]
    i += 1
    if a == "--hole" || a == "--tries" {
      let v = args.get(i)
      i += 1
      let n = positive(v) else fail("{a} needs a positive number")
      if a == "--hole" { o.hole = some(n) } else { o.tries = n }
    } else if a == "--dry-run" {
      o.dry_run = true
    } else if !a.starts_with("--") && o.file == "" {
      o.file = a
    } else {
      fail("unexpected argument `{a}`")
    }
  }
  if o.file == "" { fail("missing <file>") }
  o
}

/// `auk hatch`. Returns the exit code: 0 when every hole it worked on was filled. `exe` is this
/// binary (to find the back end), `prelude` the core prelude's directory.
pub fn run(exe: str, prelude: str?, args: [str]): int uses fs, env, ffi, time {
  let o = match parse_args(args) {
    ok(o) => o
    err(e) => {
      eprint("error: {e}\n{USAGE}")
      return 2
    }
  }
  let dir = prelude else {
    eprint("error: can't find the core prelude (src/prelude/core.auk); set AUK_PRELUDE_DIR")
    return 1
  }
  let cx = match resolve.sources(dir) {
    ok(c) => c
    err(e) => {
      eprint("error: {e}")
      return 1
    }
  }
  let root = o.file
  // the current text of every file changed so far (on top of the files on disk)
  var srcs: {str: str} = {}
  let first = analyze(cx, root, srcs) else return 1
  if first.len() == 0 {
    print("no holes in {o.file}")
    return 0
  }
  match o.hole {
    some(n) => if n > first.len() {
      eprint("error: there is no hole {n} ({o.file} has {first.len()} hole(s); see `auk holes {o.file}`)")
      return 2
    }
    none => {}
  }
  var files: [str] = []
  for h in first {
    if !files.contains(h.file) { files.push(h.file) }
  }
  var originals: [(str, str)] = []
  for f in files.sort() { originals.push((f, fs.read(f) else "")) }
  let cmd = match env.get("AUK_HATCH_CMD") {
    some(c) when utrim(c) != "" => c
    _ => DEFAULT_CMD
  }
  let total = first.len()
  // the original numbers of the holes still to do; unfilled holes stay in the list, so the
  // next one to do is at index `skip` after a fresh discovery
  var todo: [int] = []
  match o.hole {
    some(n) => todo.push(n)
    none => for n in 1..=total { todo.push(n) }
  }
  var skip = match o.hole {
    some(n) => n - 1
    none => 0
  }
  var summary: [str] = []
  var all_ok = true
  let backend = auk_bin(exe)
  for number in todo {
    let hs = analyze(cx, root, srcs) else return 1
    let h = hs.get(skip) else break
    let label = "hole {number} ({h.context}, {h.file}:{h.span.line})"
    eprint("hatching {label}")
    match fill(cx, root, h, &srcs, cmd, o.tries, backend) {
      ok(n) => summary.push("{label}: filled after {n} {if n == 1 { "try" } else { "tries" }}")
      err(e) => {
        all_ok = false
        skip += 1
        let last = utrim_end(e.show()).replace("\n", "\n    ")
        summary.push("{label}: failed after {o.tries} {if o.tries == 1 { "try" } else { "tries" }}\n  last error:\n    {last}")
      }
    }
  }
  // format and write (or show) every changed file
  for (file, before) in originals {
    let changed = srcs.get(file) else continue
    let after = fmt.format(changed) else changed
    if o.dry_run {
      print_raw(diff(file, before, after))
    } else {
      match fs.write(file, after) {
        ok(_) => {}
        err(e) => {
          eprint("error: cannot write {file}: {paths.io_error(e.show())}")
          all_ok = false
        }
      }
    }
  }
  for s in summary { print(s) }
  if o.dry_run && srcs.len() > 0 { print("(dry run: no files were changed)") }
  if all_ok { 0 } else { 1 }
}

/// `print!`: `s` without a line break added (`s` is empty or ends with one).
fn print_raw(s: str) {
  if s != "" { print(s.strip_suffix("\n") else s) }
}

/// Discover the holes of the program as it is now. Errors (the program doesn't type-check even
/// with its holes) are printed.
fn analyze(cx: resolve.Sources, root: str, srcs: {str: str}): [holes.Hole]? uses fs, ffi {
  let c = resolve.with_sources(cx, srcs)
  let diags = match holes.analyze(c, root) {
    ok((hs, ds)) => {
      if ds.all(d => d.diag.is_warning()) { return hs }
      ds
    }
    err(Many(ds)) => ds
  }
  eprint("error: the program must type-check (holes are allowed) before hatching:")
  cli.print_diags(c, diags)
  none
}

/// Fill one hole: ask, splice, check, test, retry. On success `srcs` has the filled file and
/// the number of tries is returned; otherwise the last error.
fn fill(
  cx: resolve.Sources,
  root: str,
  h: holes.Hole,
  srcs: var {str: str},
  cmd: str,
  tries: int,
  backend: str,
): int! uses fs, ffi, time {
  let current = match srcs.get(h.file) {
    some(s) => s
    none => match fs.read(h.file) {
      ok(s) => s
      err(e) => fail("cannot read {h.file}: {paths.io_error(e.show())}")
    }
  }
  let base = prompt(h, current)
  var feedback = ""
  var last = "no answer"
  for attempt in 1..=tries {
    eprint("  try {attempt}/{tries}")
    let reply = match ask(cmd, base + feedback) {
      ok(r) => r
      err(e) => {
        last = e.show()
        continue
      }
    }
    let code = extract_code(reply)
    if utrim(code) == "" {
      last = "the model's answer had no code"
      feedback = retry_note(code, "was empty. Reply with the Auk code that replaces `??`.")
      continue
    }
    let new_src = splice(current, h, code)
    var cand = srcs
    cand[h.file] = new_src
    let c = resolve.with_sources(cx, cand)
    // 1. it type-checks, and the hole is gone
    let diags = match resolve.load(c, root) {
      ok(p) => check.check_all(p).1
      err(Many(ds)) => ds
    }
    let errors = diags.filter(d => !d.diag.is_warning())
    if errors.len() > 0 {
      let json = diag.json_report_files(h.file, errors)
      last = errors.map(d => d.diag.render(d.file, resolve.source_of(c, d.file) else "")).join("")
      feedback = retry_note(
        code,
        "did not type-check. Fix these errors (`auk check --json` diagnostics; positions are in the file with your answer spliced in):\n{json}",
      )
      continue
    }
    if code.contains("??") {
      last = "the answer still contains a `??` hole"
      feedback = retry_note(
        code,
        "still contains a `??` hole. Write the complete code, without holes.",
      )
      continue
    }
    // 2. the tests that call the function pass (with contracts checked)
    if h.tests.len() > 0 {
      let names = h.tests.map(t => t.name)
      match run_tests(root, names, cand, backend) {
        ok(_) => {}
        err(e) => {
          let out = e.show()
          last = out
          feedback = retry_note(
            code,
            "type-checks, but these tests failed. Each failure shows the test's output, then its execution trace: " +
              "the last events before it ended, oldest first, as JSON lines (`call` with the arguments, `ret` with the " +
              "value or `err` with the error, `peek`, `panic`; `depth` is the call nesting). Use the trace to see what " +
              "your code actually did, then fix it:\n{out}",
          )
          continue
        }
      }
    }
    srcs = cand
    return attempt
  }
  fail(last)
}

fn retry_note(code: str, what: str): str = "\n\n## Your previous answer\n```auk\n{code}\n```\nIt {what}\n\nReply again with ONLY the corrected Auk code that replaces `??`, in one ```auk fenced block.\n"

/// The prompt for one hole (feedback from earlier tries is appended to it).
pub fn prompt(h: holes.Hole, file_src: str): str uses ffi {
  let what = if h.body is some(_) {
    "the statements of the block body `{{ ?? }}` (without the surrounding braces; the last expression is the value)"
  } else {
    "a single expression"
  }
  let file = h.file
  "You are filling a hole (`??`) in a program written in Auk, a statically typed language compiled to native code.\n\n" +
    "# The Auk language reference\n\n{utrim_end(spec())}\n\n" +
    "# The file `{file}`\n\n```auk\n{file_src}```\n\n" +
    "# The hole to fill\n\n{holes.brief_text(h)}\n" +
    "# Your task\n\n" +
    "Write the Auk code that replaces the `??` at {file}:{h.span.line}:{h.span.col} ({h.context}): {what}, of type `{h.expected}`. " +
    "It must type-check, satisfy the function's contracts and make the tests above pass. " +
    "Use only what the reference and the file provide. Do not repeat the signature, do not change other code, and do not leave any `??`.\n\n" +
    "Reply with ONLY the code, in one fenced block:\n```auk\n<code that replaces ??>\n```\n"
}

/// Run the model command with the prompt on stdin; its stdout is the reply.
fn ask(cmd: str, prompt: str): str! uses fs, ffi, time {
  let base = temp_base()
  let (inp, out, errf) = ("{base}.in", "{base}.out", "{base}.err")
  match fs.write(inp, prompt) {
    ok(_) => {}
    err(e) => fail("cannot run the model command `{cmd}`: {paths.io_error(e.show())}")
  }
  let pid = match spawn(["sh", "-c", cmd], inp, out, some(errf), false) {
    ok(p) => p
    err(e) => {
      remove_files([inp, out, errf])
      fail("cannot run the model command `{cmd}`: {e}")
    }
  }
  let status = wait_child(pid, none) else -1
  let stdout = lossy(fs.read_bytes(out) else [])
  let stderr = lossy(fs.read_bytes(errf) else [])
  remove_files([inp, out, errf])
  if status != 0 {
    fail("the model command `{cmd}` failed ({show_status(status, paths.os() == "linux")}): {utrim(stderr)}")
  }
  stdout
}

fn remove_files(fs_paths: [str]) uses fs {
  for p in fs_paths { let _ = fs.remove(p) }
}

/// The code in the first ```auk (or plain ```) fence of a reply, or the whole reply.
pub fn extract_code(reply: str): str {
  let lines = reply.lines()
  let open = match lines.find_index(l => utrim(l).starts_with("```auk")) {
    some(i) => some(i)
    none => lines.find_index(l => utrim(l).starts_with("```"))
  }
  let body = match open {
    some(i) => {
      let rest = lines.skip(i + 1)
      let close = rest.find_index(l => utrim(l).starts_with("```")) else rest.len()
      rest.take(close)
    }
    none => lines
  }
  utrim_end(trim_newlines(dedent(body.join("\n"))))
}

/// Remove the common leading indentation of the non-blank lines.
fn dedent(s: str): str {
  let ls = s.lines()
  let inds = ls.filter(l => utrim(l) != "").map(l => l.len() - utrim_start(l).len())
  let ind = inds.min() else 0
  ls.map(l => if l.len() >= ind { str(l.chars().skip(ind)) } else { utrim_start(l) }).join("\n")
}

/// Rust's `trim_matches('\n')`.
fn trim_newlines(s: str): str {
  let cs = s.chars()
  var i = 0
  var j = cs.len()
  while i < j && cs[i] == '\n' { i += 1 }
  while j > i && cs[j - 1] == '\n' { j -= 1 }
  str(cs[i..j])
}

/// Replace the hole with `code`. A `{ ?? }` block becomes a block with the code on its own
/// indented lines; elsewhere, continuation lines get the hole line's indentation.
pub fn splice(src: str, h: holes.Hole, code: str): str {
  let cs = src.chars()
  let line_indent = (line: int) => str(
    cs.skip(holes.offset(cs, line, 1)).take_while(c => c == ' ' || c == '\t'),
  )
  let code = trim_newlines(code)
  match h.body {
    some(b) => {
      let base = line_indent(b.line)
      let inner = code.lines().map(l => if utrim(l) == "" { "" } else { "{base}  {l}" })
      let (a, z) = (holes.offset(cs, b.line, b.col), holes.offset(cs, b.end_line, b.end_col))
      return str(cs[0..a]) + "{{\n{inner.join("\n")}\n{base}}}" + str(cs[z..cs.len()])
    }
    none => {}
  }
  let base = line_indent(h.span.line)
  let text = code.lines().enum().map((i, l) => if i == 0 || utrim(l) == "" { l } else { base + l })
  let (a, z) = (
    holes.offset(cs, h.span.line, h.span.col),
    holes.offset(cs, h.span.end_line, h.span.end_col),
  )
  str(cs[0..a]) + text.join("\n") + str(cs[z..cs.len()])
}

/// Build the program's tests (holes allowed, contracts on, traced) and run them. Only the tests
/// named in `names` count; one that fails only by reaching another unfilled hole is ignored.
/// Fails with their failure output.
fn run_tests(root: str, names: [str], cand: {str: str}, backend: str): ()! uses fs, ffi, time {
  // built and run by the back end (`auk __jit test`, the candidate's texts in AUK_SOURCES) in
  // a child in its own process group, killed after TEST_TIMEOUT_MS
  let base = temp_base()
  let (file, srcs_file) = ("{base}.out", "{base}.srcs")
  var recs: [str] = []
  for k, v in cand { recs.push("{k}\n{v.byte_len()}\n{v}") }
  let _ = fs.write(srcs_file, recs.join(""))
  let _ = c_setenv("AUK_TRACE", "-", 1)
  let _ = c_setenv("AUK_TRACE_TAIL", TRACE_TAIL, 1)
  let _ = c_setenv("AUK_SOURCES", srcs_file, 1)
  let pid = spawn([backend, "__jit", "test", root], "/dev/null", file, none, true)
  let _ = c_unsetenv("AUK_TRACE")
  let _ = c_unsetenv("AUK_TRACE_TAIL")
  let _ = c_unsetenv("AUK_SOURCES")
  let w = match pid {
    ok(p) => wait_child(p, some(TEST_TIMEOUT_MS))
    err(e) => {
      let _ = fs.remove(srcs_file)
      fail("error: cannot run the back end `{backend}`: {e}\n")
    }
  }
  let out = lossy(fs.read_bytes(file) else [])
  let _ = fs.remove(file)
  let _ = fs.remove(srcs_file)
  let code =
    w else fail("the tests did not finish within {TEST_TIMEOUT_MS / 1000}s (an infinite loop?)")
  if code == JIT_BUILD_FAILED * 256 { fail(out) }
  // "ok NAME" / "FAIL NAME" lines, each failure followed by its indented output
  var failures = ""
  var seen = 0
  var cur: (str, str)? = none
  for l in out.lines() {
    match l.strip_prefix("ok ") {
      some(name) => {
        flush(&cur, &failures)
        if names.contains(name) { seen += 1 }
        continue
      }
      none => {}
    }
    match l.strip_prefix("FAIL ") {
      some(name) => {
        flush(&cur, &failures)
        if names.contains(name) {
          seen += 1
          cur = some((name, ""))
        }
        continue
      }
      none => {}
    }
    if l.starts_with("    ") {
      match cur {
        some((n, body)) => cur = some((n, body + l + "\n"))
        none => {}
      }
    } else {
      flush(&cur, &failures)
    }
  }
  flush(&cur, &failures)
  if failures != "" { fail(failures) }
  if seen < names.len() { fail("the tests did not run to completion:\n{out}") }
}

fn flush(cur: var (str, str)?, failures: var str) {
  match cur {
    some((name, body)) => {
      cur = none
      if !body.contains("unfilled hole") { failures = failures + "FAIL {name}\n{body}" }
    }
    none => {}
  }
}

/// A unified diff of `a` -> `b` with 3 lines of context.
pub fn diff(file: str, a: str, b: str): str {
  let (x, y) = (a.lines(), b.lines())
  if x == y { return "" }
  // common prefix and suffix, then an LCS of the middle
  var pre = 0
  while pre < x.len() && pre < y.len() && x[pre] == y[pre] { pre += 1 }
  var suf = 0
  while suf < x.len() - pre && suf < y.len() - pre && x[x.len() - 1 - suf] == y[y.len() - 1 - suf] {
    suf += 1
  }
  let (xm, ym) = (x[pre..x.len() - suf], y[pre..y.len() - suf])
  let w = ym.len() + 1
  var lcs: [int] = []
  for _ in 0..(xm.len() + 1) * w { lcs.push(0) }
  var i = xm.len() - 1
  while i >= 0 {
    var j = ym.len() - 1
    while j >= 0 {
      lcs[i * w + j] = if xm[i] == ym[j] {
        lcs[(i + 1) * w + j + 1] + 1
      } else {
        max(lcs[(i + 1) * w + j], lcs[i * w + j + 1])
      }
      j -= 1
    }
    i -= 1
  }
  // edit script over the whole files: (' ' | '-' | '+', line)
  var ops: [(char, str)] = x.take(pre).map(l => (' ', l))
  var p = 0
  var q = 0
  while p < xm.len() || q < ym.len() {
    if p < xm.len() && q < ym.len() && xm[p] == ym[q] {
      ops.push((' ', xm[p]))
      p += 1
      q += 1
    } else if p < xm.len() && (q == ym.len() || lcs[(p + 1) * w + q] >= lcs[p * w + q + 1]) {
      ops.push(('-', xm[p]))
      p += 1
    } else {
      ops.push(('+', ym[q]))
      q += 1
    }
  }
  for l in x.skip(x.len() - suf) { ops.push((' ', l)) }
  // group into hunks
  var out: [str] = ["--- a/{file}\n+++ b/{file}\n"]
  var changed: [int] = []
  for k, op in ops {
    if op.0 != ' ' { changed.push(k) }
  }
  var k = 0
  while k < changed.len() {
    let start = max(changed[k] - 3, 0)
    var end = changed[k]
    while k < changed.len() && changed[k] <= end + 7 {
      end = changed[k]
      k += 1
    }
    end = min(end + 4, ops.len())
    var a_start = 1
    var b_start = 1
    for op in ops.take(start) {
      if op.0 != '+' { a_start += 1 }
      if op.0 != '-' { b_start += 1 }
    }
    let hunk = ops[start..end]
    let a_len = hunk.filter(op => op.0 != '+').len()
    let b_len = hunk.filter(op => op.0 != '-').len()
    out.push("@@ -{a_start},{a_len} +{b_start},{b_len} @@\n")
    for op in hunk { out.push("{op.0}{op.1}\n") }
  }
  out.join("")
}

// ---- text ----

/// Rust's `char::is_whitespace` (Unicode White_Space).
fn is_ws(c: char): bool {
  let n = int(c)
  if n < 0x80 { return n == 0x20 || (n >= 0x09 && n <= 0x0d) }
  n == 0x85 ||
    n == 0xa0 ||
    n == 0x1680 ||
    (n >= 0x2000 && n <= 0x200a) ||
    n == 0x2028 ||
    n == 0x2029 ||
    n == 0x202f ||
    n == 0x205f ||
    n == 0x3000
}

/// Rust's `str::trim`.
fn utrim(s: str): str = utrim_end(utrim_start(s))

/// Rust's `str::trim_start`.
fn utrim_start(s: str): str {
  let cs = s.chars()
  var i = 0
  while i < cs.len() && is_ws(cs[i]) { i += 1 }
  if i == 0 { s } else { str(cs.skip(i)) }
}

/// Rust's `str::trim_end`.
fn utrim_end(s: str): str {
  let cs = s.chars()
  var j = cs.len()
  while j > 0 && is_ws(cs[j - 1]) { j -= 1 }
  if j == cs.len() { s } else { str(cs[0..j]) }
}

/// Rust's `String::from_utf8_lossy`: each maximal invalid subsequence becomes U+FFFD.
pub fn lossy(b: [int]): str {
  match str.from_utf8(b) {
    ok(s) => return s
    err(_) => {}
  }
  var out: [char] = []
  var i = 0
  while i < b.len() {
    let c = b[i]
    if c < 0x80 {
      out.push(char(c)!)
      i += 1
      continue
    }
    // the sequence's length and the range of its second byte
    let (n, lo, hi) = if c >= 0xc2 && c <= 0xdf {
      (2, 0x80, 0xbf)
    } else if c == 0xe0 {
      (3, 0xa0, 0xbf)
    } else if c == 0xed {
      (3, 0x80, 0x9f)
    } else if c >= 0xe1 && c <= 0xef {
      (3, 0x80, 0xbf)
    } else if c == 0xf0 {
      (4, 0x90, 0xbf)
    } else if c == 0xf4 {
      (4, 0x80, 0x8f)
    } else if c >= 0xf1 && c <= 0xf3 {
      (4, 0x80, 0xbf)
    } else {
      (0, 0, 0)
    }
    if n == 0 {
      out.push('\u{FFFD}')
      i += 1
      continue
    }
    var k = 1
    var cp = if n == 2 { c & 0x1f } else if n == 3 { c & 0x0f } else { c & 0x07 }
    while k < n && i + k < b.len() {
      let d = b[i + k]
      let (l, h) = if k == 1 { (lo, hi) } else { (0x80, 0xbf) }
      if d < l || d > h { break }
      cp = cp * 64 + (d & 0x3f)
      k += 1
    }
    if k == n {
      out.push(char(cp)!)
    } else {
      out.push('\u{FFFD}')
    }
    i += k
  }
  str(out)
}

// ---- processes ----

/// The Rust `auk` whose back end builds and runs the tests: `$AUK_BIN`, else the
/// `target/release/auk` of the checkout this binary is in, else `auk` (on PATH).
fn auk_bin(exe: str): str uses env, fs, ffi {
  match env.get("AUK_BIN") {
    some(b) when b != "" => return b
    _ => {}
  }
  var d = paths.parent(paths.canonicalize(exe) else exe)
  loop {
    let x = d else return "auk"
    let p = paths.join(x, "target/release/auk")
    if paths.is_file(p) { return p }
    d = paths.parent(x)
  }
}

/// A path prefix for this process's temporary files.
fn temp_base(): str uses fs, ffi {
  let dir = fs.temp_dir() else "/tmp"
  paths.join(dir, "auk-hatch-{c_getpid()}")
}

/// Start `argv` (found on PATH) with stdin from the file `inp`, stdout to the file `out` and
/// stderr to `err` (or to `out` too), in its own process group if `group`. Returns the pid.
fn spawn(argv: [str], inp: str, out: str, err: str?, group: bool): int! uses ffi {
  let linux = paths.os() == "linux"
  let creat = if linux { 0x40 } else { 0x200 }
  let trunc = if linux { 0x200 } else { 0x400 }
  let fa = ffi.alloc(512)
  let attr = ffi.alloc(512)
  let _ = c_fa_init(fa)
  let _ = c_fa_open(fa, 0, inp, 0, 0)
  let _ = c_fa_open(fa, 1, out, 1 | creat | trunc, 420)
  match err {
    some(e) => { let _ = c_fa_open(fa, 2, e, 1 | creat | trunc, 420) }
    none => { let _ = c_fa_dup2(fa, 1, 2) }
  }
  let _ = c_attr_init(attr)
  if group {
    let _ = c_attr_flags(attr, 2)  // POSIX_SPAWN_SETPGROUP
    let _ = c_attr_pgroup(attr, 0)
  }
  // argv: NUL-terminated copies and a NULL at the end
  let ptrs = argv.map(a => ffi.from_bytes(a.bytes() + [0]))
  let av = ffi.alloc(8 * (ptrs.len() + 1))
  for i, p in ptrs { ffi.write_ptr(av, 8 * i, p) }
  ffi.write_ptr(av, 8 * ptrs.len(), ffi.null)
  let envp = match ffi.symbol("environ") {
    some(e) => ffi.read_ptr(e, 0)
    none => ffi.null
  }
  var pid = 0
  let r = c_spawnp(&pid, argv[0], fa, attr, av, envp)
  let _ = c_fa_destroy(fa)
  let _ = c_attr_destroy(attr)
  for p in ptrs { ffi.free(p) }
  ffi.free(av)
  ffi.free(fa)
  ffi.free(attr)
  if r != 0 { fail(c_strerror(r) + " (os error {r})") }
  pid
}

/// Wait for `pid` (at most `limit` ms: then its process group is killed and the result is
/// `none`). Returns its raw wait status.
fn wait_child(pid: int, limit: int?): int? uses ffi, time {
  let start = time.now()
  loop {
    var status = 0
    let r = c_waitpid(pid, &status, if limit is some(_) { 1 } else { 0 })
    if r == pid { return status }
    if r < 0 { return -1 }
    match limit {
      some(l) => if time.now() - start > l {
        let _ = c_kill(-pid, 9)
        let _ = c_kill(pid, 9)
        let _ = c_waitpid(pid, &status, 0)
        return none
      }
      none => {}
    }
    time.sleep(10)
  }
}

/// Rust's `Display` of an `ExitStatus` (Unix) from a raw wait status.
fn show_status(st: int, linux: bool): str {
  if st < 0 { return "unknown status" }
  let sig = st & 0x7f
  if sig == 0 { return "exit status: {(st >> 8) & 0xff}" }
  let name = signal_name(sig, linux)
  let core = if (st & 0x80) != 0 { " (core dumped)" } else { "" }
  "signal: {sig}{if name == "" { "" } else { " ({name})" }}{core}"
}

fn signal_name(n: int, linux: bool): str {
  let common = ["", "SIGHUP", "SIGINT", "SIGQUIT", "SIGILL", "SIGTRAP", "SIGABRT"]
  if n < common.len() { return common[n] }
  let rest = if linux {
    [
      "SIGBUS",
      "SIGFPE",
      "SIGKILL",
      "SIGUSR1",
      "SIGSEGV",
      "SIGUSR2",
      "SIGPIPE",
      "SIGALRM",
      "SIGTERM",
      "SIGSTKFLT",
      "SIGCHLD",
      "SIGCONT",
      "SIGSTOP",
      "SIGTSTP",
      "SIGTTIN",
      "SIGTTOU",
      "SIGURG",
      "SIGXCPU",
      "SIGXFSZ",
      "SIGVTALRM",
      "SIGPROF",
      "SIGWINCH",
      "SIGIO",
      "SIGPWR",
      "SIGSYS",
    ]
  } else {
    [
      "SIGEMT",
      "SIGFPE",
      "SIGKILL",
      "SIGBUS",
      "SIGSEGV",
      "SIGSYS",
      "SIGPIPE",
      "SIGALRM",
      "SIGTERM",
      "SIGURG",
      "SIGSTOP",
      "SIGTSTP",
      "SIGCONT",
      "SIGCHLD",
      "SIGTTIN",
      "SIGTTOU",
      "SIGIO",
      "SIGXCPU",
      "SIGXFSZ",
      "SIGVTALRM",
      "SIGPROF",
      "SIGWINCH",
      "SIGINFO",
      "SIGUSR1",
      "SIGUSR2",
    ]
  }
  rest.get(n - 7) else ""
}

extern fn c_getpid(): int = "int getpid(void)"

extern fn c_setenv(
  k: str,
  v: str,
  overwrite: int,
): int = "int setenv(const char *, const char *, int)"

extern fn c_unsetenv(k: str): int = "int unsetenv(const char *)"
extern fn c_strerror(e: int): str = "char *strerror(int)"
extern fn c_fa_init(fa: ffi.Ptr): int = "int posix_spawn_file_actions_init(void *)"
extern fn c_fa_destroy(fa: ffi.Ptr): int = "int posix_spawn_file_actions_destroy(void *)"

extern fn c_fa_open(
  fa: ffi.Ptr,
  fd: int,
  path: str,
  flags: int,
  mode: int,
): int = "int posix_spawn_file_actions_addopen(void *, int, const char *, int, int)"

extern fn c_fa_dup2(
  fa: ffi.Ptr,
  fd: int,
  to: int,
): int = "int posix_spawn_file_actions_adddup2(void *, int, int)"

extern fn c_attr_init(a: ffi.Ptr): int = "int posix_spawnattr_init(void *)"
extern fn c_attr_destroy(a: ffi.Ptr): int = "int posix_spawnattr_destroy(void *)"
extern fn c_attr_flags(a: ffi.Ptr, flags: int): int = "int posix_spawnattr_setflags(void *, short)"
extern fn c_attr_pgroup(a: ffi.Ptr, g: int): int = "int posix_spawnattr_setpgroup(void *, int)"

extern fn c_spawnp(
  pid: var int,
  file: str,
  fa: ffi.Ptr,
  attr: ffi.Ptr,
  argv: ffi.Ptr,
  envp: ffi.Ptr,
): int = "int posix_spawnp(int *, const char *, void *, void *, void *, void *)"

extern fn c_waitpid(pid: int, status: var int, flags: int): int = "int waitpid(int, int *, int)"
extern fn c_kill(pid: int, sig: int): int = "int kill(int, int)"

test "extracts fenced code" {
  assert extract_code("Here:\n```auk\n  let a = 1\n  a + 1\n```\nbye") == "let a = 1\na + 1"
  assert extract_code("```\nxs.len()\n```") == "xs.len()"
  assert extract_code("  xs.len()  \n") == "xs.len()"
}

test "diffs lines" {
  let d = diff("f.auk", "a\nb\nc\n", "a\nB\nc\n")
  assert d == "--- a/f.auk\n+++ b/f.auk\n@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n"
  assert diff("f", "x\n", "x\n") == ""
}

test "parses arguments" {
  let o = parse_args(["f.auk", "--hole", "+2", "--dry-run"])!
  assert (o.file, o.hole, o.tries, o.dry_run) == ("f.auk", some(2), 3, true)
  match parse_args(["--tries", "0", "f.auk"]) {
    ok(_) => assert false
    err(e) => assert e.show() == "--tries needs a positive number"
  }
  match parse_args(["a.auk", "b.auk"]) {
    ok(_) => assert false
    err(e) => assert e.show() == "unexpected argument `b.auk`"
  }
}

test "decodes invalid UTF-8 as Rust does" {
  assert lossy([104, 0xff, 105]) == "h\u{FFFD}i"
  assert lossy([0xe2, 0x82, 0x41]) == "\u{FFFD}A"
  assert lossy([0xf0, 0x9f, 0xa6, 0x86]) == "\u{1F986}"
  assert lossy([0xed, 0xa0, 0x80]) == "\u{FFFD}\u{FFFD}\u{FFFD}"
}

test "exit statuses" {
  assert show_status(3 * 256, false) == "exit status: 3"
  assert show_status(9, true) == "signal: 9 (SIGKILL)"
  assert show_status(10 | 0x80, false) == "signal: 10 (SIGBUS) (core dumped)"
}

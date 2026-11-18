/// The integration test runner: the end-to-end tests of `tests/*.rs`, in Auk. Each file
/// `tests/<name>.rs` is the module `suite/<name>.auk` with the same tests (same names, inputs and
/// expected outputs); they drive the binaries under test (`$AUK_BIN`, `$RAFT_BIN`) and compare
/// what they print.
///
///     auk build tests/runner/src/main.auk -o target/test-runner
///     target/test-runner [-j N] [--list] [--ignored|--include-ignored] [--exact] [--no-setup]
///                        [filter...]
///
/// A filter selects the tests whose `suite::name` contains it (`--exact`: equals it). Before the
/// tests, `raft install` runs once in `examples/` and in the packages the Rust suite installs
/// (`--no-setup` skips that). Tests run in `-j` tasks at once (default: the number of CPUs),
/// each under `catch`: a panic fails that test only. A test that ends with `t.skip` counts as
/// skipped. Exit code 1 if any test failed, 2 on a usage error.

let USAGE = "usage: test-runner [-j N] [--list] [--ignored|--include-ignored] [--exact] [--no-setup] [filter...]"

fn suites(): [t.Suite] uses fs, env, ffi, time, net, proc = [
  t.Suite { name: "bitwise", tests: suite.bitwise.tests() },
  t.Suite { name: "check", tests: suite.check.tests() },
  t.Suite { name: "check2", tests: suite.check2.tests() },
  t.Suite { name: "collections", tests: suite.collections.tests() },
  t.Suite { name: "core_io", tests: suite.core_io.tests() },
  t.Suite { name: "debug", tests: suite.debug.tests() },
  t.Suite { name: "dive", tests: suite.dive.tests() },
  t.Suite { name: "explain", tests: suite.explain.tests() },
  t.Suite { name: "ffi", tests: suite.ffi.tests() },
  t.Suite { name: "fmt", tests: suite.fmt.tests() },
  t.Suite { name: "gaps", tests: suite.gaps.tests() },
  t.Suite { name: "hatch", tests: suite.hatch.tests() },
  t.Suite { name: "holes", tests: suite.holes.tests() },
  t.Suite { name: "llvm_package", tests: suite.llvm_package.tests() },
  t.Suite { name: "lsp", tests: suite.lsp.tests() },
  t.Suite { name: "mcp", tests: suite.mcp.tests() },
  t.Suite { name: "net", tests: suite.net.tests() },
  t.Suite { name: "packages_next", tests: suite.packages_next.tests() },
  t.Suite { name: "packages_p0", tests: suite.packages_p0.tests() },
  t.Suite { name: "parse", tests: suite.parse.tests() },
  t.Suite { name: "raft", tests: suite.raft.tests() },
  t.Suite { name: "run", tests: suite.run.tests() },
  t.Suite { name: "shadow", tests: suite.shadow.tests() },
  t.Suite { name: "trace", tests: suite.trace.tests() },
  t.Suite { name: "units", tests: suite.units.tests() },
]

struct Opts { jobs: int, list: bool, ignored: int, exact: bool, setup: bool, filters: [str] }

/// One finished test: its index in the selection, the failure (none if it passed), ms taken.
struct Done { i: int, failure: str?, ms: int }

fn parse_args(args: [str]): Opts! {
  var o = Opts { jobs: 0, list: false, ignored: 0, exact: false, setup: true, filters: [] }
  var i = 0
  while i < args.len() {
    match args[i] {
      "-j" | "--jobs" => {
        i += 1
        o.jobs = int.parse(args.get(i) else "")?
      }
      "--list" => o.list = true
      "--ignored" => o.ignored = 2
      "--include-ignored" => o.ignored = 1
      "--exact" => o.exact = true
      "--no-setup" => o.setup = false
      "-h" | "--help" => return fail("help")
      a when a.starts_with("-") => return fail("unknown option {a}")
      a => o.filters.push(a)
    }
    i += 1
  }
  o
}

fn main(args: [str]): int uses fs, env, ffi, time, net, proc {
  let o = match parse_args(args.skip(1)) {
    ok(o) => o
    err(_) => {
      eprint(USAGE)
      return 2
    }
  }
  match find_root() {
    some(r) => { let _ = sys.chdir(r) }
    none => {
      eprint("error: run the test runner inside the Auk repository")
      return 2
    }
  }
  sys.ignore_sigpipe()
  // the selection: (suite, test) indices
  let all = suites()
  var sel: [(int, int)] = []
  for si, s in all {
    for ti, test in s.tests {
      let name = "{s.name}::{test.name}"
      let wanted = o.filters.len() == 0 ||
        o.filters.any(f => if o.exact { name == f } else { name.contains(f) })
      let by_ignore = match o.ignored {
        0 => !test.ignored
        1 => true
        _ => test.ignored
      }
      if wanted && by_ignore { sel.push((si, ti)) }
    }
  }
  if o.list {
    for (si, ti) in sel { print("{all[si].name}::{all[si].tests[ti].name}") }
    return 0
  }
  let start = time.now()
  let tmp = t.abs("target/test-tmp/{sys.pid()}")
  sys.setenv("AUK_TEST_TMP", tmp)
  if o.setup && sel.len() > 0 { setup() }
  let jobs = if o.jobs > 0 { o.jobs } else { sys.cpus() }
  eprint("running {sel.len()} tests with {t.auk_bin()} ({jobs} at a time)")
  let todo: Chan<int> = chan()
  let done: Chan<Done> = chan()
  for i in 0..sel.len() { todo.send(i) }
  todo.close()
  var workers: [Task<int>] = []
  for _ in 0..min(jobs, max(1, sel.len())) { workers.push(worker(sel, todo, done)) }
  var failed: [(str, str)] = []
  var skipped = 0
  var passed = 0
  for _ in 0..sel.len() {
    let d = done.recv() else break
    let (si, ti) = sel[d.i]
    let name = "{all[si].name}::{all[si].tests[ti].name}"
    let secs = "{float(d.ms) / 1000.0:.1}s"
    match d.failure {
      none => {
        passed += 1
        print("ok   {name} ({secs})")
      }
      some(m) when m.starts_with(t.SKIP) => {
        skipped += 1
        print("skip {name}: {m[t.SKIP.len()..m.len()]}")
      }
      some(m) => {
        failed.push((name, m))
        print("FAIL {name} ({secs})\n{indent(m)}")
      }
    }
  }
  for w in workers { let _ = await w }
  if failed.len() > 0 {
    print("\nfailures:")
    for (name, _) in failed { print("    {name}") }
  }
  print("\n{passed} passed, {failed.len()} failed, {skipped} skipped ({float(time.now() - start) / 1000.0:.1}s)")
  if failed.len() > 0 { return 1 }
  t.rm_rf(tmp)
  0
}

async fn worker(
  sel: [(int, int)],
  todo: Chan<int>,
  done: Chan<Done>,
): int uses fs, env, ffi, time, net, proc {
  let all = suites()
  for i in todo {
    let (si, ti) = sel[i]
    let body = all[si].tests[ti].run
    let start = time.now()
    let r = catch body()
    let failure = match r {
      ok(_) => none
      err(e) => some(clean(e.show()))
    }
    done.send(Done { i, failure, ms: time.now() - start })
  }
  0
}

/// A panic's message without the `panic: unwrapped an error: ` and the location in t.auk of
/// `t.fail`.
fn clean(m: str): str {
  let m = m.strip_prefix("panic: ") else m
  match m.strip_prefix("unwrapped an error: ") {
    some(rest) => {
      let parts = rest.split(" at ")
      if parts.len() > 1 && parts[parts.len() - 1].contains("/src/t.auk:") {
        parts.take(parts.len() - 1).join(" at ")
      } else {
        rest
      }
    }
    none => m
  }
}

fn indent(s: str): str = s.lines().map(l => "    " + l).join("\n")

/// The repository: the first directory up from here with `tests/runner/raft.toml`.
fn find_root(): str? uses fs, ffi {
  var d = paths.cwd()
  loop {
    if fs.exists(paths.join(d, "tests/runner/raft.toml")) { return d }
    d = paths.parent(d) else return none
    if d == "" { return none }
  }
}

/// `raft install` in examples/ and in the packages with dependencies that tests/check.rs and
/// tests/run.rs install (their `setup`): http, url, log, splash, term (the corpus needs all of them).
fn setup() uses env, fs, ffi, time {
  for dir in ["examples", "packages/http", "packages/url", "packages/log", "packages/splash", "packages/term"] { t.install(dir) }
}

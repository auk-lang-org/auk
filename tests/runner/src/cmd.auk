/// A command to run, built by value (Rust's `std::process::Command`):
///
///     let o = t.auk().args(["check", f, "--json"]).cwd(dir).output()
///     assert o.code == some(0)
///
/// `output` captures stdout and stderr (stdin is empty unless `stdin` gave it text), `start`
/// keeps the child running with its stdin open (`sys.Child`: `write`, `read_line`, `finish`).
/// The child inherits this process's environment, changed by `setenv`/`unsetenv`. Every run
/// has a timeout (default 300 s): past it the child's process group is killed, and the
/// result's `timed_out` is set.

pub struct Cmd {
  argv: [str],
  /// Changes to the environment, in order: a value to set, none to remove.
  env: [(str, str?)],
  cwd: str?,
  stdin: [int]?,
  timeout_ms: int,
}

/// What a finished command left.
pub struct Out {
  /// The exit code, none if a signal ended it.
  code: int?,
  signal: int?,
  stdout: str,
  stderr: str,
  stdout_bytes: [int],
  timed_out: bool,
}

pub let DEFAULT_TIMEOUT_MS = 300000

pub fn new(prog: str): Cmd =
  Cmd { argv: [prog], env: [], cwd: none, stdin: none, timeout_ms: DEFAULT_TIMEOUT_MS }

pub fn arg(c: Cmd, a: str): Cmd = Cmd { argv: c.argv + [a], ..c }

pub fn args(c: Cmd, xs: [str]): Cmd = Cmd { argv: c.argv + xs, ..c }

pub fn setenv(c: Cmd, k: str, v: str): Cmd = Cmd { env: c.env + [(k, some(v))], ..c }

pub fn unsetenv(c: Cmd, k: str): Cmd = Cmd { env: c.env + [(k, none)], ..c }

pub fn cwd(c: Cmd, dir: str): Cmd = Cmd { cwd: some(dir), ..c }

/// Text for the child's stdin (piped, then closed).
pub fn stdin(c: Cmd, text: str): Cmd = Cmd { stdin: some(text.bytes()), ..c }

pub fn stdin_bytes(c: Cmd, b: [int]): Cmd = Cmd { stdin: some(b), ..c }

pub fn timeout(c: Cmd, ms: int): Cmd = Cmd { timeout_ms: ms, ..c }

/// The environment the child gets.
fn envp(c: Cmd): [str] uses ffi {
  var e = sys.environ()
  for (k, v) in c.env {
    e = e.filter(kv => !kv.starts_with(k + "="))
    match v {
      some(v) => e.push("{k}={v}")
      none => {}
    }
  }
  e
}

/// Run to completion and capture everything; panics if it can't start.
pub fn output(c: Cmd): Out uses ffi, time {
  match try_output(c) {
    ok(o) => o
    err(e) => t.bail(e.show())
  }
}

/// Run to completion and capture everything; an Err if it can't start.
pub fn try_output(c: Cmd): Out! uses ffi, time {
  let deadline = time.now() + c.timeout_ms
  var ch = sys.spawn(c.argv, envp(c), c.cwd, c.stdin is some(_))?
  match c.stdin {
    some(b) => { let _ = sys.write(&ch, b, c.timeout_ms) }
    none => {}
  }
  let x = sys.finish(&ch, max(0, deadline - time.now()))
  Out {
    code: x.code,
    signal: x.signal,
    stdout: sys.lossy(x.stdout),
    stderr: sys.lossy(x.stderr),
    stdout_bytes: x.stdout,
    timed_out: x.timed_out,
  }
}

/// Start it with stdin piped and kept open; panics if it can't start.
pub fn start(c: Cmd): sys.Child uses ffi, time {
  match sys.spawn(c.argv, envp(c), c.cwd, true) {
    ok(ch) => {
      var ch = ch
      match c.stdin {
        some(b) => { let _ = sys.write(&ch, b, c.timeout_ms) }
        none => {}
      }
      ch
    }
    err(e) => t.bail(e.show())
  }
}

/// Wait for a started child (stdin closed first), at most `ms`, and capture the rest.
pub fn wait(ch: var sys.Child, ms: int): Out uses ffi, time {
  let x = sys.finish(&ch, ms)
  Out {
    code: x.code,
    signal: x.signal,
    stdout: sys.lossy(x.stdout),
    stderr: sys.lossy(x.stderr),
    stdout_bytes: x.stdout,
    timed_out: x.timed_out,
  }
}

/// Exit code 0.
pub fn success(o: Out): bool = o.code == some(0)

/// `(code, stdout, stderr)` for comparing all three at once.
pub fn triple(o: Out): (int?, str, str) = (o.code, o.stdout, o.stderr)

/// `(stdout, stderr)`.
pub fn text(o: Out): (str, str) = (o.stdout, o.stderr)

/// A description for failure messages: the status and both streams.
pub fn describe(o: Out): str {
  let status = match (o.code, o.signal) {
    (some(c), _) => "exit {c}"
    (_, some(s)) => "signal {s}"
    _ => "no status"
  }
  "{status}{if o.timed_out { " (timed out)" } else { "" }}\n--- stdout\n{o.stdout}\n--- stderr\n{o.stderr}"
}

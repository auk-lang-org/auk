/// What a test file needs: registering tests, failing with a message, skipping, the binaries
/// under test, scratch directories, and small file helpers.
///
/// A test is a function that returns normally to pass; it fails by panicking (`assert`,
/// `t.check`, `t.fail`, an unwrapped error). `t.skip_if_lacks` ends a test as skipped. The
/// runner runs each in a task under `catch`, with the repository root as the working directory.

/// One test: its name (the Rust test's), its body, and whether it only runs when asked for
/// (`#[ignore]`).
pub struct Test { name: str, run: () => (), ignored: bool }

/// The tests of one file (`tests/<name>.rs`).
pub struct Suite { name: str, tests: [Test] }

pub fn test(name: str, run: () => ()): Test = Test { name, run, ignored: false }

pub fn ignored(name: str, run: () => ()): Test = Test { name, run, ignored: true }

/// The prefix of a failure message that means "skipped".
pub let SKIP = "skipped: "

fn boom(msg: str): ()! = sys.fail_with(msg)

/// Fail the test with `msg`.
pub fn fail(msg: str) { boom(msg)! }

/// Fail the test with `msg` where a value is expected.
pub fn bail<T>(msg: str): T {
  boom(msg)!
  loop {}
}

/// Fail with `msg` unless `cond`.
pub fn check(cond: bool, msg: str) { if !cond { fail(msg) } }

/// Fail unless `a == b`, showing both and `msg`.
pub fn eq(a: str, b: str, msg: str) {
  if a != b {
    fail("assertion failed: left == right ({msg})\n  left: {a.show()}\n right: {b.show()}")
  }
}

/// Fail unless the text contains `part`.
pub fn has(text: str, part: str) {
  if !text.contains(part) { fail("expected {part.show()} in:\n{text}") }
}

/// Fail if the text contains `part`.
pub fn lacks_text(text: str, part: str) {
  if text.contains(part) { fail("unexpected {part.show()} in:\n{text}") }
}

/// End the test as skipped.
pub fn skip(why: str) { fail(SKIP + why) }

// ---- the binaries under test ----

/// The repository root (the runner's working directory).
pub fn root(): str uses ffi = paths.cwd()

/// `root/p`.
pub fn abs(p: str): str uses ffi = paths.join(root(), p)

/// The `auk` binary to run: `$AUK_BIN`, else `target/bin/auk`.
pub fn auk_bin(): str uses env, ffi = env.get("AUK_BIN") else abs("target/bin/auk")

/// The `raft` binary to run: `$RAFT_BIN`, else `target/bin/raft`.
pub fn raft_bin(): str uses env, ffi = env.get("RAFT_BIN") else abs("target/bin/raft")

/// What a binary from `$AUK_BIN` lacks when `$AUK_BIN_LACKS` is unset: the commands the
/// self-hosted port's driver doesn't have yet: nothing since the hidden `parse` and `typed`, the
/// last ones, were ported (tests/auk_bin/mod.rs has the same list for the Rust tests).
pub let PORT_LACKS = ""

/// Whether the binary lacks `cmd` (only a binary from `$AUK_BIN` can); if so, say which test
/// skips what.
pub fn lacks(cmd: str, what: str): bool uses env, ffi {
  if env.get("AUK_BIN") is none { return false }
  let list = env.get("AUK_BIN_LACKS") else PORT_LACKS
  let lacking = list.split(",").any(c => c.trim() == cmd)
  if lacking { eprint("skipped for {auk_bin()}: {what} (needs `{cmd}`, which it lacks)") }
  lacking
}

/// End the test as skipped if the binary lacks `cmd`.
pub fn skip_if_lacks(cmd: str, what: str) uses env {
  if env.get("AUK_BIN") is none { return }
  let list = env.get("AUK_BIN_LACKS") else PORT_LACKS
  if list.split(",").any(c => c.trim() == cmd) { skip("{what} (needs `{cmd}`)") }
}

/// A command running `auk`.
pub fn auk(): cmd.Cmd uses env, ffi = cmd.new(auk_bin())

/// A command running `raft`.
pub fn raft(): cmd.Cmd uses env, ffi = cmd.new(raft_bin())

/// `auk <args>`, captured.
pub fn run_auk(args: [str]): cmd.Out uses env, ffi, time = auk().args(args).output()

/// `raft install` in `dir`; a lock that no longer matches the registry (the in-repo packages
/// are edited freely) is regenerated.
pub fn install(dir: str) uses env, fs, ffi, time {
  let go = () => raft().arg("install").cwd(dir).output()
  if !go().success() {
    let _ = fs.remove(paths.join(dir, "raft.lock"))
    rm_rf(paths.join(dir, ".raft"))
    let o = go()
    check(o.success(), "raft install in {dir} failed:\n{o.stderr}")
  }
}

// ---- scratch directories ----

/// Where this run keeps its scratch directories: `$AUK_TEST_TMP` (the runner sets it to
/// `target/test-tmp/<pid>`).
pub fn tmp_base(): str uses env, ffi = env.get("AUK_TEST_TMP") else abs("target/test-tmp/0")

/// A fresh, empty directory `<base>/<name>` (Rust's `CARGO_TARGET_TMPDIR` ones).
pub fn scratch(name: str): str uses env, fs, ffi {
  let d = paths.join(tmp_base(), name)
  rm_rf(d)
  must(fs.mkdir(d), "mkdir {d}")
  d
}

/// A fresh, empty directory under the system's temporary directory (Rust's
/// `std::env::temp_dir()` ones), unique to this run: `<tmp>/<name>-<pid>`.
pub fn temp(name: str): str uses fs, ffi {
  let base = sys.getenv("TMPDIR") else "/tmp"
  let d = paths.join(base.strip_suffix("/") else base, "{name}-{sys.pid()}")
  rm_rf(d)
  must(fs.mkdir(d), "mkdir {d}")
  d
}

/// Unwrap `r` or fail with `what` and the error.
pub fn must<T>(r: T!, what: str): T = match r {
  ok(v) => v
  err(e) => bail("{what}: {e}")
}

/// Remove `p` and everything under it (symlinks are removed, not followed).
pub fn rm_rf(p: str) uses fs {
  if fs.is_dir(p) && !is_link(p) {
    for name in (fs.list(p) else []) { rm_rf(paths.join(p, name)) }
  }
  let _ = fs.remove(p)
}

fn is_link(p: str): bool uses fs {
  // fs.is_dir follows links: a link to a directory lists the target's names, so try
  // removing it as a file first
  fs.remove(p) is ok(_)
}

/// Write `text` to `path` (creating its directory).
pub fn write(path: str, text: str) uses fs {
  match paths.parent(path) {
    some(d) => if d != "" { let _ = fs.mkdir(d) }
    none => {}
  }
  must(fs.write(path, text), "write {path}")
}

/// The text of `path`.
pub fn read(path: str): str uses fs = must(fs.read(path), "read {path}")

/// Copy the directory `from` to `to` recursively.
pub fn copy_dir(from: str, to: str) uses fs {
  must(fs.mkdir(to), "mkdir {to}")
  for name in must(fs.list(from), "list {from}") {
    let (a, b) = (paths.join(from, name), paths.join(to, name))
    if fs.is_dir(a) {
      copy_dir(a, b)
    } else {
      must(fs.write_bytes(b, must(fs.read_bytes(a), "read {a}")), "write {b}")
    }
  }
}

/// The `.auk` files directly in `dir`, sorted.
pub fn auk_files(dir: str): [str] uses fs {
  must(fs.list(dir), "list {dir}")
    .filter(n => n.ends_with(".auk"))
    .sort()
    .map(n => paths.join(dir, n))
}

/// Whether this is macOS.
pub fn macos(): bool uses ffi = paths.os() == "macos"

/// Whether `prog` is on PATH.
pub fn have(prog: str): bool uses ffi, time {
  cmd.new("sh").args(["-c", "command -v {prog}"]).output().success()
}

/// How many times `sub` occurs in `s` (without overlaps).
pub fn count(s: str, sub: str): int = s.split(sub).len() - 1

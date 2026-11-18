/// `auk debug` (src/debug.rs): the debugger's command-line front end.
///
/// It starts the program with `auk run --debug` in a child process and drives the debug engine
/// (runtime/c/dbg.c) over a private Unix socket (`AUK_DEBUG`). Two modes:
///
/// - **batch** (`--json`, `--batch`, or stdin not a terminal): set the `--break` points, run,
///   and at every stop record where it is, the locals (`--print` names, or all) and the stack,
///   then continue; at the end, the program's exit code and output. Made for scripts and agents
///   (`auk mcp`'s `auk_debug` tool): one command, no conversation.
/// - **interactive** (a terminal, or `--repl`): a gdb-style prompt. Ctrl-C pauses the program.
///
/// The program gets no stdin (the terminal belongs to the prompt).
///
/// Differences from Rust: Rust's threads (the socket reader, the program's output readers,
/// stdin, the Ctrl-C poller, the `--timeout` grace timer) are tasks sending to a `Chan<In>`
/// (Rust: an mpsc channel). Sockets, `poll`, pipes, `posix_spawnp`, `waitpid`, `isatty`,
/// `chdir` and `errno` are C through FFI (core has no Unix sockets or child processes with
/// pipes); the Ctrl-C handler is C in the runtime (`auk_dbg_catch_sigint`: C can't call Auk) and
/// polled every 50 ms as Rust polls its flag. The batch report's output is collected in files
/// of a private temporary directory rather than pipes read by threads (invalid UTF-8 becomes
/// U+FFFD; Rust's `read_to_string` would drop such a stream). The socket's name has no
/// per-process counter (Rust's `N`: one launch per process here). A Unix socket write to a
/// program that went away fails (`SIGPIPE` is ignored) as in Rust. The interactive prompt and
/// `auk dap` end with `_exit` after flushing stdout, since a task still blocked reading stdin
/// can't be joined (Rust's threads are detached). Unicode `is_alphanumeric` is the lexer's.

let USAGE_TEXT = """
usage: auk debug [options] <file.auk> [args...]
  --break, -b <file:line|fn>   stop there (repeatable); `<place> if <cond>`: only when cond holds
  --print, -p <a,b,...>        batch: show only these locals at each stop (default: all);
                               an item that isn't a name is evaluated (`p.x`, `xs[0]`)
  --eval, -e <expr>            batch: also evaluate this Auk expression at each stop
  --catch all|uncaught|none    stop on panics (default: uncaught)
  --max-stops N                batch: end the program after N stops (default 20)
  --timeout S                  batch: after S seconds, pause, report where it is, end it
  --json                       batch, with a JSON report
  --batch                      batch, with a text report (the default when stdin is not a terminal)
  --repl                       interactive (the default on a terminal)
"""

let REPL_TEXT = """
run, r                start the program          break, b <file:line|fn>   set a breakpoint
  continue, c           resume                     delete, d [id]            remove one, or all
  next, n               step over                  catch all|uncaught|none   stop on panics
  step, s               step into                  bt, where                 the stack
  finish, f             step out                   frame N, up, down         select a frame
  print, p [names|expr] locals, or an Auk expression (`p xs.len()`, `p x = 5`)
  threads, thread N     list / select threads      break <place> if <cond>   conditional
  list, l               source around the line     quit, q                   end the program
  (an empty line repeats the last command; Ctrl-C pauses a running program)
"""

fn usage(): str = USAGE_TEXT.strip_suffix("\n") else USAGE_TEXT

struct Opts {
  file: str,
  args: [str],
  breaks: [str],
  print: [str]?,
  catch_: str?,
  max_stops: int,
  timeout: float?,
  /// `--eval`: expressions shown at each stop.
  exprs: [str],
  json: bool,
  batch: bool?,
}

pub enum Fail { Msg(text: str) }

fn parse_opts(args: [str]): Opts!Fail {
  var o = Opts {
    file: "",
    args: [],
    breaks: [],
    print: none,
    catch_: none,
    max_stops: 20,
    timeout: none,
    exprs: [],
    json: false,
    batch: none,
  }
  var i = 0
  while i < args.len() {
    let a = args[i]
    i += 1
    let val = () => args.get(i)
    let needs = Fail.Msg("{a} needs a value")
    match a {
      "--break" | "-b" => {
        let v = val() else return fail(needs)
        i += 1
        o.breaks.push(v)
      }
      "--eval" | "-e" => {
        let v = val() else return fail(needs)
        i += 1
        o.exprs.push(v)
      }
      "--print" | "-p" => {
        let v = val() else return fail(needs)
        i += 1
        o.print = some(v.split(",").map(s => s.trim()).filter(s => s != ""))
      }
      "--catch" => {
        let v = val() else return fail(needs)
        i += 1
        o.catch_ = some(v)
      }
      "--max-stops" => {
        let v = val() else return fail(needs)
        i += 1
        let n = int.parse(v) else return fail(Fail.Msg("--max-stops needs a number"))
        if n < 0 { return fail(Fail.Msg("--max-stops needs a number")) }
        o.max_stops = n
      }
      "--timeout" => {
        let v = val() else return fail(needs)
        i += 1
        let t = float.parse(v) else return fail(Fail.Msg("--timeout needs a number of seconds"))
        if !(t > 0.0) { return fail(Fail.Msg("--timeout needs a number of seconds")) }
        o.timeout = some(t)
      }
      "--json" => {
        o.json = true
        o.batch = some(true)
      }
      "--batch" => o.batch = some(true)
      "--repl" => o.batch = some(false)
      s => {
        if s.starts_with("-") && o.file == "" { return fail(Fail.Msg("unknown option {s}")) }
        o.file = a
        o.args = args.skip(i)
        break
      }
    }
  }
  if o.file == "" { return fail(Fail.Msg("no program given")) }
  match o.catch_ {
    some(c) => if c != "all" && c != "uncaught" && c != "none" {
      return fail(Fail.Msg("--catch takes all, uncaught or none"))
    }
    none => {}
  }
  o
}

/// `auk debug <args>`; `arg0`: how this binary was started (for `current_exe`).
pub fn run(arg0: str, args: [str]): int uses fs, env, time, ffi {
  let o = match parse_opts(args) {
    ok(o) => o
    err(Msg(e)) => {
      eprint("auk debug: {e}\n{usage()}")
      return 2
    }
  }
  if !paths.is_file(o.file) {
    eprint("auk debug: cannot read {o.file}")
    return 2
  }
  let batch = o.batch else c_isatty(0) == 0
  if batch { batch_run(arg0, o) } else { repl(arg0, o) }
}

// ---- the session ------------------------------------------------------------------------

/// What a front end waits for: an engine event, the program's output (stderr: `true`), a
/// request (DAP), a line typed, or Ctrl-C.
pub enum In {
  Ev(e: json.Json),
  Closed,
  Out(is_err: bool, text: str),
  Req(r: json.Json),
  Line(l: str),
  Eof,
  Interrupt,
}

/// Where the program's stdout and stderr go.
pub enum Capture {
  /// Our own (interactive).
  Inherit,
  /// Collected for the report (batch).
  Collect,
  /// As `In.Out` events, as they come (DAP).
  Stream,
}

pub struct Session {
  pid: int,
  /// The connection to the engine.
  fd: int,
  /// Where every input arrives (`tx` and `rx` in Rust).
  q: Chan<In>,
  seq: int,
  pending: [In],
  /// The directory with the program's stdout and stderr files, when collected (batch).
  output: str?,
  /// Its exit code, once waited for.
  status: int?,
  /// The tasks feeding `q` (kept so they aren't joined early).
  tasks: [Task<int>],
}

/// Why a launch failed: the exit code of a program that never connected (it didn't compile)
/// and its output (Inherit: already shown).
pub enum LaunchFail { Failed(code: int, text: str) }

/// Start `auk run --debug <file>` and wait for its engine to say `ready`.
pub fn launch(exe: str, file: str, args: [str], capture: Capture): Session!LaunchFail uses fs, env, ffi {
  let _ = c_signal(13, ffi.ptr(1)) // SIGPIPE: SIG_IGN (a write to a dead program fails instead)
  let dir = temp_dir()
  let sock = paths.join(dir, "auk-dbg-{c_getpid()}-0.sock")
  let _ = fs.remove(sock)
  let l = match listen(sock) {
    ok(l) => l
    err(e) => return fail(LaunchFail.Failed(1, "auk debug: cannot listen on {sock}: {e}\n"))
  }
  let q: Chan<In> = chan()
  var tasks: [Task<int>] = []
  // the program's output: files (Collect) or pipes read by tasks (Stream)
  var outdir: str? = none
  var redirect: (str, str)? = none
  var pipes: (int, int, int, int)? = none
  match capture {
    Collect => match fs.temp_dir() {
      ok(d) => {
        let so = paths.join(d, "stdout")
        let se = paths.join(d, "stderr")
        let _ = fs.write(so, "")
        let _ = fs.write(se, "")
        outdir = some(d)
        redirect = some((so, se))
      }
      err(e) => {
        let _ = c_close(l)
        let _ = fs.remove(sock)
        return fail(LaunchFail.Failed(1, "auk debug: cannot start the program: {e}\n"))
      }
    }
    Stream => {
      let (r1, w1) = pipe()
      let (r2, w2) = pipe()
      pipes = some((r1, w1, r2, w2))
    }
    Inherit => {}
  }
  let spawned = spawn([exe, "run", "--debug", file] + args, sock, l, redirect, pipes)
  match pipes {
    some((r1, w1, r2, w2)) => {
      let _ = c_close(w1)
      let _ = c_close(w2)
      if spawned is ok(_) {
        tasks.push(read_output(r1, false, q))
        tasks.push(read_output(r2, true, q))
      } else {
        let _ = c_close(r1)
        let _ = c_close(r2)
      }
    }
    none => {}
  }
  let pid = match spawned {
    ok(p) => p
    err(e) => {
      let _ = c_close(l)
      let _ = fs.remove(sock)
      return fail(LaunchFail.Failed(1, "auk debug: cannot start the program: {e}\n"))
    }
  }
  var s = Session { pid, fd: -1, q, seq: 0, pending: [], output: outdir, status: none, tasks }
  let conn = loop {
    if poll_in(l, 5) {
      let c = c_accept(l, ffi.null, ffi.null)
      if c >= 0 { break c }
      let e = os_error()
      let _ = c_kill(pid, 9)
      let _ = c_close(l)
      return fail(LaunchFail.Failed(1, "auk debug: {e}\n"))
    }
    match try_wait(pid) {
      some(st) => {
        let _ = c_close(l)
        let _ = fs.remove(sock)
        let (so, se) = s.captured()
        var text = so + se
        for t in s.tasks { let _ = await t }
        s.tasks = []
        loop {
          let x = q.recv_for(0) else break
          match x {
            Out(_, t) => text += t
            _ => {}
          }
        }
        return fail(LaunchFail.Failed(st, text))
      }
      none => {}
    }
  }
  let _ = c_close(l)
  let _ = fs.remove(sock)
  s.fd = conn
  s.tasks.push(read_events(conn, q))
  match s.next() {
    Ev(e) => if e.get("ev").as_str() == some("ready") { return s }
    _ => {}
  }
  let _ = c_kill(pid, 9)
  fail(LaunchFail.Failed(1, "auk debug: the program did not start its debugger\n"))
}

/// `next`, Rust's `Session::next`: what comes first.
pub fn next(s: var Session): In {
  match s.pending.first() {
    some(x) => {
      s.pending = s.pending.skip(1)
      return x
    }
    none => {}
  }
  s.q.recv() else In.Closed
}

/// `next`, or none once `deadline` (ms, `time.now()`) passes.
fn next_until(s: var Session, deadline: int?): In? uses time {
  let d = deadline else return some(s.next())
  match s.pending.first() {
    some(x) => {
      s.pending = s.pending.skip(1)
      return some(x)
    }
    none => {}
  }
  s.q.recv_for(max(d - time.now(), 0))
}

/// Send a command and wait for its reply (Null if the program went away).
pub fn cmd(s: var Session, c: str): json.Json uses ffi {
  s.seq += 1
  let line = "@{s.seq} {c}\n"
  if !write_all(s.fd, line) { return json.Json.Null }
  var held: [In] = []
  let r = loop {
    let x = s.q.recv() else In.Closed
    match x {
      Ev(e) => if e.get("seq").as_i64() == some(s.seq) {
        break e
      } else {
        held.push(x)
      }
      Closed => {
        held.push(In.Closed)
        break json.Json.Null
      }
      _ => held.push(x)
    }
  }
  s.pending = s.pending + held
  r
}

/// The program's exit code (after it ends or is killed): 128 + the signal that ended it.
pub fn wait(s: var Session): int uses ffi {
  match s.status {
    some(c) => return c
    none => {}
  }
  var st = 0
  var r = c_waitpid(s.pid, &st, 0)
  var tries = 0
  while r != s.pid && tries < 1000 {
    tries += 1
    r = c_waitpid(s.pid, &st, 0)
  }
  let code = if r != s.pid { 1 } else { decode(st) }
  s.status = some(code)
  code
}

/// End the program (Rust's `Child::kill`).
pub fn kill(s: Session) uses ffi {
  if s.status == none { let _ = c_kill(s.pid, 9) }
}

/// The program's collected stdout and stderr (batch), read once.
fn captured(s: var Session): (str, str) uses fs {
  let d = s.output else return ("", "")
  s.output = none
  let so = hatch.lossy(fs.read_bytes(paths.join(d, "stdout")) else [])
  let se = hatch.lossy(fs.read_bytes(paths.join(d, "stderr")) else [])
  let _ = fs.remove(paths.join(d, "stdout"))
  let _ = fs.remove(paths.join(d, "stderr"))
  let _ = fs.remove(d)
  (so, se)
}

/// A wait status as an exit code: the code, or 128 + the signal.
fn decode(st: int): int = if (st & 0x7f) == 0 { (st >> 8) & 0xff } else { 128 + (st & 0x7f) }

/// The exit code of `pid` if it has ended (`Child::try_wait`; a signal's end is 1 here, as
/// Rust's `code().unwrap_or(1)` at its only use).
fn try_wait(pid: int): int? uses ffi {
  var st = 0
  let r = c_waitpid(pid, &st, 1) // WNOHANG
  if r != pid { return none }
  if (st & 0x7f) == 0 { (st >> 8) & 0xff } else { 1 }
}

/// Rust's `env::temp_dir()`: `$TMPDIR`, else `/tmp`.
fn temp_dir(): str uses env {
  match env.get("TMPDIR") {
    some(d) => if d != "" { d } else { "/tmp" }
    none => "/tmp"
  }
}

/// A Unix socket listening at `path`: its descriptor, or the error's text.
fn listen(path: str): int!Fail uses ffi {
  let fd = c_socket(1, 1, 0) // AF_UNIX, SOCK_STREAM
  if fd < 0 { return fail(Fail.Msg(os_error())) }
  let bytes = path.bytes()
  if bytes.len() > 103 {
    let _ = c_close(fd)
    return fail(Fail.Msg("path must be shorter than SUN_LEN"))
  }
  // struct sockaddr_un: macOS { u8 len; u8 family; char path[104] }, Linux { u16 family; .. }
  let addr = ffi.alloc(112)
  for k in 0..112 { ffi.write_u8(addr, k, 0) }
  if paths.os() == "macos" {
    ffi.write_u8(addr, 0, 2 + bytes.len() + 1)
    ffi.write_u8(addr, 1, 1)
  } else {
    ffi.write_u8(addr, 0, 1)
  }
  for k, b in bytes { ffi.write_u8(addr, 2 + k, b) }
  let r = c_bind(fd, addr, 2 + bytes.len() + 1)
  ffi.free(addr)
  if r != 0 {
    let e = os_error()
    let _ = c_close(fd)
    return fail(Fail.Msg(e))
  }
  if c_listen(fd, 128) != 0 {
    let e = os_error()
    let _ = c_close(fd)
    return fail(Fail.Msg(e))
  }
  fd
}

/// Is `fd` readable within `ms` milliseconds?
fn poll_in(fd: int, ms: int): bool uses ffi {
  // struct pollfd { int fd; short events; short revents; }
  let p = ffi.alloc(8)
  ffi.write_i32(p, 0, fd)
  ffi.write_i32(p, 4, 1) // POLLIN, revents 0
  let r = c_poll(p, 1, ms)
  ffi.free(p)
  r > 0
}

/// A pipe: (read end, write end).
fn pipe(): (int, int) uses ffi {
  let p = ffi.alloc(8)
  let _ = c_pipe(p)
  let r = (ffi.read_i32(p, 0), ffi.read_i32(p, 4))
  ffi.free(p)
  r
}

/// Write all of `s` to `fd`; false if that failed.
fn write_all(fd: int, s: str): bool uses ffi {
  if fd < 0 { return false }
  var bytes = s.bytes()
  while bytes.len() > 0 {
    let p = ffi.from_bytes(bytes)
    let n = c_write(fd, p, bytes.len())
    ffi.free(p)
    if n <= 0 { return false }
    bytes = bytes.skip(n)
  }
  true
}

/// The text of the last OS error, as Rust's `io::Error` shows it.
fn os_error(): str uses ffi {
  let f = ffi.symbol("__error") else (ffi.symbol("__errno_location") else return "unknown error")
  let e = ffi.read_i32(call_errno(f), 0)
  "{c_strerror(e)} (os error {e})"
}

/// Start `argv` with `AUK_DEBUG=sock`, stdin from `/dev/null`, in its own process group, its
/// stdout and stderr to the files `redirect` or the write ends of `pipes`. Returns the pid.
fn spawn(argv: [str], sock: str, listener: int, redirect: (str, str)?, pipes: (int, int, int, int)?): int!Fail uses env, ffi {
  let fa = ffi.alloc(1024)
  let attr = ffi.alloc(1024)
  let _ = c_fa_init(fa)
  let _ = c_fa_open(fa, 0, "/dev/null", 0, 0)
  match redirect {
    some((so, se)) => {
      let _ = c_fa_open(fa, 1, so, 1, 0) // O_WRONLY (the files exist, empty)
      let _ = c_fa_open(fa, 2, se, 1, 0)
    }
    none => {}
  }
  match pipes {
    some((r1, w1, r2, w2)) => {
      let _ = c_fa_dup2(fa, w1, 1)
      let _ = c_fa_dup2(fa, w2, 2)
      for fd in [r1, w1, r2, w2] { let _ = c_fa_close(fa, fd) }
    }
    none => {}
  }
  let _ = c_fa_close(fa, listener)
  let _ = c_attr_init(attr)
  // its own process group (Ctrl-C reaches only the debugger, which pauses the program), and
  // no blocked signals
  let _ = c_attr_flags(attr, 2 | 8) // POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK
  let _ = c_attr_pgroup(attr, 0)
  let mask = ffi.alloc(256)
  for k in 0..32 { ffi.write_i64(mask, 8 * k, 0) }
  let _ = c_attr_sigmask(attr, mask)
  // the environment with AUK_DEBUG set (for the child only)
  let old = env.get("AUK_DEBUG")
  let _ = c_setenv("AUK_DEBUG", sock, 1)
  let ptrs = argv.map(a => ffi.from_bytes(a.bytes() + [0]))
  let av = ffi.alloc(8 * (ptrs.len() + 1))
  for i, p in ptrs { ffi.write_ptr(av, 8 * i, p) }
  ffi.write_ptr(av, 8 * ptrs.len(), ffi.null)
  var pid = 0
  let r = c_spawnp(&pid, argv[0], fa, attr, av, mcp.environ())
  match old {
    some(v) => { let _ = c_setenv("AUK_DEBUG", v, 1) }
    none => { let _ = c_unsetenv("AUK_DEBUG") }
  }
  let _ = c_fa_destroy(fa)
  let _ = c_attr_destroy(attr)
  for p in ptrs { ffi.free(p) }
  ffi.free(av)
  ffi.free(fa)
  ffi.free(attr)
  ffi.free(mask)
  if r != 0 { return fail(Fail.Msg("{c_strerror(r)} (os error {r})")) }
  pid
}

/// The engine's events, one JSON object per line, then `Closed`.
async fn read_events(fd: int, q: Chan<In>): int uses ffi {
  let buf = ffi.alloc(4096)
  var acc: [int] = []
  loop {
    let n = c_read(fd, buf, 4096)
    if n <= 0 { break }
    acc = acc + ffi.bytes(buf, n)
    var start = 0
    for i, b in acc {
      if b == 10 {
        let line = str.from_utf8(acc[start..i]) else ""
        match json.parse(line) {
          ok(j) => q.send(In.Ev(j))
          err(_) => {}
        }
        start = i + 1
      }
    }
    acc = acc.skip(start)
  }
  ffi.free(buf)
  q.send(In.Closed)
  0
}

/// The program's output on a pipe, as it comes.
async fn read_output(fd: int, is_err: bool, q: Chan<In>): int uses ffi {
  let buf = ffi.alloc(4096)
  loop {
    let n = c_read(fd, buf, 4096)
    if n <= 0 { break }
    q.send(In.Out(is_err, hatch.lossy(ffi.bytes(buf, n))))
  }
  ffi.free(buf)
  let _ = c_close(fd)
  0
}

/// A path as the user would write it: relative to the working directory when inside it.
pub fn short(p: str): str uses ffi {
  let d = paths.cwd()
  match paths.strip_base(p, d) {
    some(cs) => cs.join("/")
    none => p
  }
}

/// `fn (file:line)` of a frame.
pub fn at(f: json.Json): str uses ffi {
  let name = f.get("fn").as_str() else "?"
  match f.get("file").as_str() {
    some(file) => "{name} ({short(file)}:{f.get("line").as_i64() else 0})"
    none => name
  }
}

/// Line `n` of a file (1-based).
fn source_line(file: str, n: int): str? uses fs {
  let src = fs.read(file) else return none
  mir.progen.rust_lines(src).get(max(n - 1, 0))
}

/// Locals of a `vars` reply as (name, type, value), optionally only `names`.
fn locals(r: json.Json, names: [str]?): [(str, str, str)] {
  var out: [(str, str, str)] = []
  for v in r.get("vars").as_arr() {
    let n = v.get("name").as_str() else ""
    let keep = match names {
      some(ns) => ns.contains(n)
      none => true
    }
    if keep { out.push((n, v.get("type").as_str() else "", v.get("value").as_str() else "")) }
  }
  out
}

/// Rust's `f64` Display: no `.0` on whole numbers.
fn show_float(x: float): str = if x == floor(x) && abs(x) < 1.0e15 { "{int(x)}" } else { "{x}" }

// ---- batch ------------------------------------------------------------------------------

fn batch_run(arg0: str, o: Opts): int uses fs, env, time, ffi {
  var s = match launch(mcp.current_exe(arg0), o.file, o.args, Capture.Collect) {
    ok(s) => s
    err(Failed(code, text)) => {
      posix.eprint_raw(text)
      if o.json {
        print(json.obj([("error", json.of("the program did not compile")), ("exit_code", json.of(code))]).text())
      }
      return code
    }
  }
  var errors: [str] = []
  match o.catch_ {
    some(c) => { let _ = s.cmd("catch {c}") }
    none => {}
  }
  for b in o.breaks {
    let r = s.cmd("break {b}")
    if r.get("ev").as_str() != some("break") {
      errors.push("break {b}: {r.get("msg").as_str() else "failed"}")
    }
  }
  let _ = s.cmd("run")
  var stops: [json.Json] = []
  var killed = false
  var timed_out = false
  var timer: [Task<int>] = []
  let deadline = match o.timeout {
    some(t) => some(time.now() + int(t * 1000.0))
    none => none
  }
  loop {
    let ev = match s.next_until(if timed_out { none } else { deadline }) {
      some(x) => x
      none => {
        // out of time: stop it where it is (a thread blocked in a call stops when it returns)
        timed_out = true
        let _ = s.cmd("pause")
        timer.push(later(s.q, 2000))
        continue
      }
    }
    if timed_out && ev is Eof {
      killed = true
      let _ = s.cmd("kill")
      break
    }
    match ev {
      Ev(e) => {
        let what = e.get("ev").as_str()
        if timed_out && what == some("stopped") {
          var r = record(&s, e, o.print, o.exprs)
          r = match r {
            Obj(fs) => json.Json.Obj([("reason", json.of("timeout"))] + fs.skip(1))
            x => x
          }
          stops.push(r)
          killed = true
          let _ = s.cmd("kill")
          break
        }
        if what == some("stopped") {
          stops.push(record(&s, e, o.print, o.exprs))
          if stops.len() >= o.max_stops {
            killed = true
            let _ = s.cmd("kill")
            break
          }
          let _ = s.cmd("continue")
        } else if what == some("exited") {
          break
        }
      }
      Closed | Eof => break
      _ => {}
    }
  }
  for t in timer { t.cancel() }
  let code = s.wait()
  let (out, err) = s.captured()
  if o.json {
    var fields = [("stops", json.of(stops)), ("exit_code", json.of(code))]
    if timed_out {
      fields.push(("note", json.of("ended after {show_float(o.timeout else 0.0)}s (--timeout)")))
    } else if killed {
      fields.push(("note", json.of("ended after {o.max_stops} stops (--max-stops)")))
    }
    if errors.len() > 0 { fields.push(("errors", json.of(errors.map(e => json.of(e))))) }
    fields.push(("stdout", json.of(out)))
    fields.push(("stderr", json.of(err)))
    print(json.obj(fields).text())
  } else {
    for e in errors { print("error: {e}") }
    for i, st in stops { print_stop(i + 1, st) }
    if timed_out {
      print("ended after {show_float(o.timeout else 0.0)}s (--timeout)")
    } else if killed {
      print("ended after {o.max_stops} stops (--max-stops)")
    }
    if out != "" { print("stdout:\n{out.trim_end()}") }
    if err != "" { print("stderr:\n{err.trim_end()}") }
    print("exit {code}")
  }
  code
}

/// `Eof` after `ms` milliseconds (the `--timeout` grace period).
async fn later(q: Chan<In>, ms: int): int uses time {
  time.sleep(ms)
  q.send(In.Eof)
  0
}

/// Is `n` a plain name (not an expression)?
fn is_name(n: str): bool = n != "" && n.chars().all(c => lexer.is_alphanumeric(c) || c == '_')

/// A stop as JSON: {reason, fn, file, line, [msg, loc], locals: {name: value}, stack: ["fn (file:line)"]}.
fn record(s: var Session, e: json.Json, names: [str]?, exprs: [str]): json.Json uses ffi {
  let f = e.get("frame")
  var fields: [(str, json.Json)] = [("reason", e.get("reason"))]
  match e.get("thread").as_i64() {
    some(t) => if t != 1 { fields.push(("thread", json.of(t))) }
    none => {}
  }
  fields.push(("fn", f.get("fn")))
  match f.get("file").as_str() {
    some(file) => {
      fields.push(("file", json.of(short(file))))
      fields.push(("line", f.get("line")))
    }
    none => {}
  }
  for k in ["msg", "loc"] {
    match e.get(k).as_str() {
      some(v) => fields.push((k, json.of(v)))
      none => {}
    }
  }
  match e.get("cond_error").as_str() {
    some(c) => fields.push(("cond_error", json.of(c)))
    none => {}
  }
  // `--print`: names of locals, or expressions (evaluated there)
  let vars = s.cmd("vars 0")
  let only = match names {
    some(ns) => some(ns.filter(n => is_name(n)))
    none => none
  }
  var ls: [(str, json.Json)] = locals(vars, only).map(l => (l.0, json.of(l.2)))
  let more = (names else []).filter(n => !is_name(n)) + exprs
  for x in more {
    let v = s.cmd("eval 0 {e.get("thread").as_i64() else 1} {x}")
    let shown = match v.get("ev").as_str() {
      some("value") => v.get("value").as_str() else ""
      _ => "error: {v.get("msg").as_str() else "can't evaluate"}"
    }
    ls.push((x, json.of(shown)))
  }
  fields.push(("locals", json.obj(ls)))
  let st = s.cmd("stack")
  fields.push(("stack", json.of(st.get("frames").as_arr().map(fr => json.of(at(fr))))))
  json.obj(fields)
}

fn print_stop(n: int, st: json.Json) {
  let reason = st.get("reason").as_str() else "?"
  let file = st.get("file").as_str() else "?"
  let line = st.get("line").as_i64() else 0
  let what = match st.get("msg").as_str() {
    some(m) => "panic: {m}"
    none => reason
  }
  let thread = match st.get("thread").as_i64() {
    some(t) => " [thread {t}]"
    none => ""
  }
  print("#{n} {what} at {file}:{line} in {st.get("fn").as_str() else "?"}{thread}")
  match st.get("cond_error").as_str() {
    some(c) => print("  (the breakpoint's condition failed: {c})")
    none => {}
  }
  match st.get("locals") {
    Obj(ls) => for (k, v) in ls { print("  {k} = {v.as_str() else ""}") }
    _ => {}
  }
  let stack = st.get("stack").as_arr().skip(1).filter(f => f.as_str() != none).map(f => f.as_str()!)
  if stack.len() > 0 { print("  called from {stack.join(" < ")}") }
}

// ---- interactive ------------------------------------------------------------------------

struct Repl {
  s: Session,
  started: bool,
  stopped: bool,
  thread: int,
  frame: int,
  /// The selected frame's location (file, line).
  here: (str, int)?,
  last: str,
  file: str,
}

/// Lines typed, then `Eof`.
async fn read_stdin(q: Chan<In>): int uses env {
  loop {
    let l = env.read_line() else break
    q.send(In.Line(l))
  }
  q.send(In.Eof)
  0
}

/// `Interrupt` for each Ctrl-C.
async fn watch_sigint(q: Chan<In>): int uses time, ffi {
  loop {
    time.sleep(50)
    if c_sigint_taken() { q.send(In.Interrupt) }
  }
  0
}

fn repl(arg0: str, o: Opts): int uses fs, env, time, ffi {
  let s = match launch(mcp.current_exe(arg0), o.file, o.args, Capture.Inherit) {
    ok(s) => s
    err(Failed(code, text)) => {
      posix.eprint_raw(text)
      return code
    }
  }
  // stdin and Ctrl-C feed the same queue as the engine's events
  let input = read_stdin(s.q)
  c_catch_sigint()
  let ctrl_c = watch_sigint(s.q)
  var r = Repl { s, started: false, stopped: false, thread: 1, frame: 0, here: none, last: "", file: o.file }
  match o.catch_ {
    some(c) => { let _ = r.s.cmd("catch {c}") }
    none => {}
  }
  for b in o.breaks { let _ = r.command("break {b}") }
  print("auk debug: {o.file} (`run` starts it, `help` lists commands)")
  r.prompt()
  // what is typed while the program runs waits for the next stop (as in gdb); `quit` doesn't
  var held: [In] = []
  loop {
    let input_ = match held.first() {
      some(x) => if !r.started || r.stopped {
        held = held.skip(1)
        x
      } else {
        r.s.next()
      }
      none => r.s.next()
    }
    let running = r.started && !r.stopped
    match input_ {
      Line(l) => {
        let t = l.trim()
        if running && t != "q" && t != "quit" && t != "kill" && t != "exit" {
          held.push(input_)
          continue
        }
        let l2 = if t == "" { r.last } else { t }
        if l2 == "" {
          r.prompt()
          continue
        }
        r.last = l2
        if !r.command(l2) { break }
        if !r.started || r.stopped { r.prompt() }
      }
      Eof => {
        if running {
          held.push(In.Eof)
          continue
        }
        if r.started { let _ = r.s.cmd("kill") }
        break
      }
      Interrupt => if r.started && !r.stopped {
        let _ = r.s.cmd("pause")
      } else {
        print("")
        r.prompt()
      }
      Ev(e) => if e.get("ev").as_str() == some("stopped") {
        r.on_stop(e)
        r.prompt()
      }
      Closed => break
      _ => {}
    }
  }
  let code = r.s.wait()
  print("program exited with code {code}")
  // the stdin reader may still be blocked: end here rather than join it
  stdio.flush()
  let _ = (input, ctrl_c)
  c__exit(code)
  code
}

fn prompt(r: Repl) uses ffi {
  let _ = stdio.write_out("(auk) ")
}

fn on_stop(r: var Repl, e: json.Json) uses fs, ffi {
  r.stopped = true
  r.thread = e.get("thread").as_i64() else 1
  r.frame = 0
  let f = e.get("frame")
  let thread = if r.thread != 1 { " [thread {r.thread}]" } else { "" }
  match e.get("reason").as_str() {
    some("panic") => {
      print("panic: {e.get("msg").as_str() else ""}{thread}")
      print("  in {at(f)}")
    }
    some("breakpoint") => {
      let ids = e.get("bps").as_arr().filter(b => b.as_i64() != none).map(b => "{b.as_i64()!}")
      print("breakpoint {ids.join(",")} in {at(f)}{thread}")
      match e.get("cond_error").as_str() {
        some(c) => print("  (its condition failed: {c})")
        none => {}
      }
    }
    some("pause") => print("paused in {at(f)}{thread}")
    _ => {}
  }
  r.here = match f.get("file").as_str() {
    some(p) => some((p, f.get("line").as_i64() else 0))
    none => none
  }
  r.show_line()
}

fn show_line(r: Repl) uses fs {
  match r.here {
    some((file, n)) => match source_line(file, n) {
      some(l) => print("{n}\t{l}")
      none => {}
    }
    none => {}
  }
}

/// Select frame `n` of the current thread; false when there is none.
fn select(r: var Repl, n: int): bool uses fs, ffi {
  let st = r.s.cmd("stack {r.thread}")
  let frames = st.get("frames").as_arr()
  let f = frames.get(n) else {
    print("no frame {n} ({frames.len()} frames)")
    return false
  }
  r.frame = n
  r.here = match f.get("file").as_str() {
    some(p) => some((p, f.get("line").as_i64() else 0))
    none => none
  }
  print("#{n} {at(f)}")
  r.show_line()
  true
}

fn need_stop(r: Repl): bool {
  if !r.started {
    print("the program is not running (`run` starts it)")
    false
  } else if !r.stopped {
    print("the program is running (Ctrl-C pauses it)")
    false
  } else {
    true
  }
}

/// A `u32` as Rust parses one.
fn parse_u32(s: str): int? {
  if s == "" || !s.chars().all(c => lexer.is_ascii_digit(c) || c == '+') { return none }
  let n = int.parse(s.strip_prefix("+") else s) else return none
  if n < 0 || n > 4294967295 { none } else { some(n) }
}

/// Run one command; false to quit.
fn command(r: var Repl, line: str): bool uses fs, ffi {
  let words = line.split()
  let c = words[0]
  let rest = words.skip(1)
  match c {
    "help" | "h" | "?" => print(REPL_TEXT.strip_suffix("\n") else REPL_TEXT)
    "quit" | "q" | "kill" | "exit" => {
      let _ = r.s.cmd("kill")
      return false
    }
    "run" | "r" => if r.started {
      print("already running")
    } else {
      r.started = true
      let _ = r.s.cmd("run")
    }
    "break" | "b" => {
      let spec = if rest.len() == 0 {
        match r.here {
          some((f, n)) => "{f}:{n}"
          none => {
            print("usage: break <file:line|fn>")
            return true
          }
        }
      } else {
        rest.join(" ")
      }
      // `break 12 [if c]`: a line of the current (or the program's) file
      let (place, cond) = match spec.find(" if ") {
        some(i) => (spec[0..i].trim(), spec[i..spec.len()])
        none => (spec, "")
      }
      let spec2 = match parse_u32(place) {
        some(n) => {
          let file = match r.here {
            some((f, _)) => f
            none => r.file
          }
          "{file}:{n}{cond}"
        }
        none => spec
      }
      let res = r.s.cmd("break {spec2}")
      match res.get("ev").as_str() {
        some("break") => {
          let cnd = match res.get("cond").as_str() {
            some(x) => " if {x}"
            none => ""
          }
          print("breakpoint {res.get("id").as_i64() else 0} at {short(res.get("file").as_str() else "?")}:{res.get("line").as_i64() else 0}{cnd}")
        }
        _ => print(res.get("msg").as_str() else "cannot set the breakpoint")
      }
    }
    "delete" | "d" => { let _ = r.s.cmd("delete {rest.join(" ")}") }
    "catch" => { let _ = r.s.cmd("catch {rest.first() else "uncaught"}") }
    "continue" | "c" | "next" | "n" | "step" | "s" | "finish" | "f" => {
      if !r.started {
        r.started = true
        let _ = r.s.cmd("run")
        return true
      }
      if !need_stop(r) { return true }
      let full = match c {
        "c" => "continue"
        "n" => "next"
        "s" => "step"
        "f" => "finish"
        x => x
      }
      r.stopped = false
      if r.s.cmd(full).is_null() { return false }
    }
    "bt" | "where" | "backtrace" => if need_stop(r) {
      let st = r.s.cmd("stack {r.thread}")
      for i, f in st.get("frames").as_arr() {
        let mark = if i == r.frame { "*" } else { " " }
        print("{mark}#{i} {at(f)}")
      }
    }
    "print" | "p" | "locals" | "info" => if need_stop(r) {
      let res = r.s.cmd("vars {r.frame} {r.thread}")
      let names = rest.filter(w => w != "locals")
      // not just names of locals: an Auk expression (or an assignment, `x = 5`)
      let known = locals(res, none)
      if names.len() > 0 && !names.all(n => known.any(k => k.0 == n)) {
        let text = after_word(line)
        let v = r.s.cmd("eval {r.frame} {r.thread} {text}")
        match v.get("ev").as_str() {
          some("value") => print("{text}: {v.get("type").as_str() else "?"} = {v.get("value").as_str() else ""}")
          _ => print(v.get("msg").as_str() else "can't evaluate that")
        }
        return true
      }
      let ls = locals(res, if names.len() == 0 { none } else { some(names) })
      if ls.len() == 0 { print(if names.len() == 0 { "no locals here" } else { "no such local here" }) }
      for (n, t, v) in ls { print("{n}: {t} = {v}") }
    }
    "frame" | "fr" | "up" | "down" => if need_stop(r) {
      let n = match c {
        "up" => r.frame + 1
        "down" => max(r.frame - 1, 0)
        _ => match rest.first() {
          some(x) => (parse_u32(x) else r.frame)
          none => r.frame
        }
      }
      let _ = r.select(n)
    }
    "threads" => if need_stop(r) {
      let res = r.s.cmd("threads")
      for t in res.get("threads").as_arr() {
        let id = t.get("id").as_i64() else 0
        let mark = if id == r.thread { "*" } else { " " }
        let f = t.get("frame")
        print("{mark}{id} {if f.is_null() { "(not in Auk code)" } else { at(f) }}")
      }
    }
    "thread" => if need_stop(r) {
      match rest.first() {
        some(x) => match int.parse(x) {
          ok(t) => {
            let old = r.thread
            r.thread = t
            if !r.select(0) { r.thread = old }
          }
          err(_) => print("thread {r.thread}")
        }
        none => print("thread {r.thread}")
      }
    }
    "list" | "l" => match r.here {
      some((file, n)) => match fs.read(file) {
        ok(src) => {
          let lines = mir.progen.rust_lines(src)
          let from = max(n - 5, 1)
          let to = min(n + 5, lines.len())
          var k = from
          while k <= to {
            let mark = if k == n { ">" } else { " " }
            print("{mark}{k}\t{lines[k - 1]}")
            k += 1
          }
        }
        err(_) => {}
      }
      none => print("no current line")
    }
    _ => print("unknown command `{c}` (`help` lists them)")
  }
  true
}

/// What follows the first word of `line` (Rust's `split_once(char::is_whitespace)`), trimmed.
fn after_word(line: str): str {
  let cs = line.chars()
  for i, ch in cs {
    if lexer.is_whitespace(ch) { return cs.skip(i + 1).join("").trim() }
  }
  ""
}

// ---- C ----

extern fn c_isatty(fd: int): int = "int isatty(int)"
extern fn c_getpid(): int = "int getpid(void)"
extern fn c_signal(sig: int, handler: ffi.Ptr): ffi.Ptr = "void *signal(int, void *)"
extern fn c_socket(domain: int, ty: int, proto: int): int = "int socket(int, int, int)"
extern fn c_bind(fd: int, addr: ffi.Ptr, len: int): int = "int bind(int, const void *, unsigned int)"
extern fn c_listen(fd: int, backlog: int): int = "int listen(int, int)"
extern fn c_accept(fd: int, addr: ffi.Ptr, len: ffi.Ptr): int = "int accept(int, void *, void *)"
extern fn c_poll(fds: ffi.Ptr, n: int, ms: int): int = "int poll(void *, unsigned int, int)"
extern fn c_pipe(fds: ffi.Ptr): int = "int pipe(void *)"
extern fn c_read(fd: int, buf: ffi.Ptr, n: int): int = "long read(int, void *, size_t)"
extern fn c_write(fd: int, buf: ffi.Ptr, n: int): int = "long write(int, const void *, size_t)"
extern fn c_close(fd: int): int = "int close(int)"
extern fn c_kill(pid: int, sig: int): int = "int kill(int, int)"
extern fn c_waitpid(pid: int, status: var int, flags: int): int = "int waitpid(int, int *, int)"
extern fn c_strerror(e: int): str = "char *strerror(int)"
extern fn call_errno(f: ffi.Ptr): ffi.Ptr = "void *(*)(void)"
extern fn c_setenv(k: str, v: str, overwrite: int): int = "int setenv(const char *, const char *, int)"
extern fn c_unsetenv(k: str): int = "int unsetenv(const char *)"
extern fn c__exit(code: int) = "void _exit(int)"
extern fn c_catch_sigint() = "void auk_dbg_catch_sigint(void)"
extern fn c_sigint_taken(): bool = "bool auk_dbg_sigint_taken(void)"
extern fn c_fa_init(fa: ffi.Ptr): int = "int posix_spawn_file_actions_init(void *)"
extern fn c_fa_destroy(fa: ffi.Ptr): int = "int posix_spawn_file_actions_destroy(void *)"

extern fn c_fa_open(fa: ffi.Ptr, fd: int, path: str, flags: int, mode: int): int =
  "int posix_spawn_file_actions_addopen(void *, int, const char *, int, int)"

extern fn c_fa_dup2(fa: ffi.Ptr, fd: int, to: int): int = "int posix_spawn_file_actions_adddup2(void *, int, int)"
extern fn c_fa_close(fa: ffi.Ptr, fd: int): int = "int posix_spawn_file_actions_addclose(void *, int)"
extern fn c_attr_init(a: ffi.Ptr): int = "int posix_spawnattr_init(void *)"
extern fn c_attr_destroy(a: ffi.Ptr): int = "int posix_spawnattr_destroy(void *)"
extern fn c_attr_flags(a: ffi.Ptr, flags: int): int = "int posix_spawnattr_setflags(void *, short)"
extern fn c_attr_pgroup(a: ffi.Ptr, g: int): int = "int posix_spawnattr_setpgroup(void *, int)"
extern fn c_attr_sigmask(a: ffi.Ptr, mask: ffi.Ptr): int = "int posix_spawnattr_setsigmask(void *, const void *)"

extern fn c_spawnp(pid: var int, file: str, fa: ffi.Ptr, attr: ffi.Ptr, argv: ffi.Ptr, envp: ffi.Ptr): int =
  "int posix_spawnp(int *, const char *, void *, void *, void *, void *)"

/// tests/debug.rs: the debugger: `auk run --debug` attached to a front end over `AUK_DEBUG`'s
/// Unix socket (runtime/src/dbg.rs, the frame records and statement hooks in lower.rs). Every
/// event read here must parse as JSON. Also `auk debug` (batch and prompt), `auk dap`, and
/// native debug info (`auk build -g`, lldb). (The Rust tests always run the Rust `auk`; on a
/// binary that lacks `debug`/`dap` those tests skip.)

pub fn tests(): [t.Test] uses env, fs, ffi, time = [
  t.test("breakpoints_stack_and_locals", breakpoints_stack_and_locals),
  t.test("stepping", stepping),
  t.test("loops_stop_every_iteration", loops_stop_every_iteration),
  t.test("panics_tasks_and_pause", panics_tasks_and_pause),
  t.test(
    "an_uncaught_panic_stops_before_the_process_ends",
    an_uncaught_panic_stops_before_the_process_ends,
  ),
  t.test("detached_and_flagless_programs", detached_and_flagless_programs),
  t.test("batch_text_report", batch_text_report),
  t.test("batch_json_panic_and_timeout", batch_json_panic_and_timeout),
  t.test("interactive_prompt", interactive_prompt),
  t.test("parts_of_values", parts_of_values),
  t.test("dap_session", dap_session),
  t.test("dap_panics_and_compile_errors", dap_panics_and_compile_errors),
  t.test("native_line_tables", native_line_tables),
  t.test("expressions_and_conditions", expressions_and_conditions),
  t.test("expressions_in_auk_debug", expressions_in_auk_debug),
  t.test("dap_expressions", dap_expressions),
]

/// How long a read from the program or `auk dap` may wait (Rust's 20 s read timeout).
let READ_MS = 20000

fn auk_cmd(): cmd.Cmd uses env, ffi =
  t.auk().unsetenv("AUK_LEAK_CHECK").unsetenv("AUK_TRACE").unsetenv("AUK_DEBUG")

/// Unix socket paths are short (104 bytes on macOS): keep the directory name small.
fn scratch(name: str): str uses fs, ffi = t.temp("dkdbg-{name}")

fn parse(s: str): json.Json = match json.parse(s) {
  ok(j) => j
  err(Bad(e)) => t.bail("not JSON ({e}): {s}")
}

fn jstr(j: json.Json): str = j.as_str() else ""

fn int_of(n: int): json.Json = json.of(n)

/// The directory prefix `auk debug` strips from paths (the canonical scratch dir and `/`).
fn rel(out: str, f: str): str uses ffi {
  let dir = paths.canonicalize(paths.parent(f)!) else paths.parent(f)!
  out.replace("{dir}/", "")
}

// ---- a Unix listener (the front end's end of AUK_DEBUG) ----

extern fn c_socket(d: int, ty: int, p: int): int = "int socket(int, int, int)"
extern fn c_bind(fd: int, addr: ffi.Ptr, n: int): int = "int bind(int, const void *, unsigned int)"
extern fn c_listen(fd: int, n: int): int = "int listen(int, int)"
extern fn c_accept(fd: int, a: ffi.Ptr, n: ffi.Ptr): int = "int accept(int, void *, void *)"
extern fn c_poll(fds: ffi.Ptr, n: int, ms: int): int = "int poll(void *, unsigned int, int)"

/// A listening Unix socket at `path`.
fn unix_listen(path: str): int uses ffi {
  let fd = c_socket(1, 1, 0)
  t.check(fd >= 0, "socket failed")
  let lin = sys.linux()
  let size = if lin { 110 } else { 106 }
  let addr = ffi.alloc(112)
  for i in 0..112 { ffi.write_u8(addr, i, 0) }
  if lin {
    ffi.write_u8(addr, 0, 1)
  } else {
    ffi.write_u8(addr, 0, size)
    ffi.write_u8(addr, 1, 1)
  }
  for i, b in path.bytes() { ffi.write_u8(addr, 2 + i, b) }
  let r = c_bind(fd, addr, size)
  ffi.free(addr)
  t.check(r == 0, "bind {path} failed")
  t.check(c_listen(fd, 4) == 0, "listen failed")
  fd
}

/// Accept a connection, waiting up to `ms`: its fd, or none.
fn accept(fd: int, ms: int): int? uses ffi {
  let p = ffi.alloc(8)
  ffi.write_i32(p, 0, fd)
  ffi.write_i32(p, 4, 1)
  let r = c_poll(p, 1, ms)
  ffi.free(p)
  if r <= 0 { return none }
  let c = c_accept(fd, ffi.null, ffi.null)
  if c < 0 { none } else { some(c) }
}

// ---- a debugged program and its connection ----

struct Session {
  child: sys.Child,
  listener: int,
  conn: int,
  /// Bytes read from the connection, not yet a whole line.
  buf: [int],
  seq: int,
  /// Events read while waiting for something else.
  pending: [json.Json],
}

fn start(name: str, src: str): Session uses env, fs, ffi, time {
  let dir = scratch(name)
  let file = paths.join(dir, "prog.auk")
  t.write(file, src)
  let sock = paths.join(dir, "s")
  let l = unix_listen(sock)
  var child = auk_cmd().args(["run", "--debug", file]).setenv("AUK_DEBUG", sock).start()
  // the program connects once it compiles (a test program that doesn't would hang here)
  let conn = loop {
    match accept(l, 10) {
      some(c) => break c
      none => {
        if sys.try_wait(&child) {
          let o = cmd.wait(&child, 5000)
          t.fail("the program ended ({o.code}) without connecting:\n{o.stderr}")
        }
        let _ = sys.pump(&child, 0)
      }
    }
  }
  var s = Session { child, listener: l, conn, buf: [], seq: 0, pending: [] }
  let ready = read(&s)
  assert ready.get("ev").as_str() == some("ready")
  s
}

fn read(s: var Session): json.Json uses ffi, time {
  let deadline = time.now() + READ_MS
  loop {
    match s.buf.find_index(b => b == 10) {
      some(i) => {
        let line = sys.lossy(s.buf[0..i])
        s.buf = s.buf[i + 1..s.buf.len()]
        let e = parse(line.trim())
        t.check(e.get("ev").as_str() is some(_), "no `ev`: {line}")
        return e
      }
      none => {}
    }
    let left = deadline - time.now()
    t.check(left > 0, "no event from the program within {READ_MS} ms")
    match sys.fd_read(s.conn, min(left, 200)) {
      some([]) => t.fail("the program closed the connection")
      some(bytes) => for b in bytes { s.buf.push(b) }
      none => {}
    }
    // keep the program's output flowing
    let _ = sys.pump(&s.child, 0)
  }
}

/// Send a command; its reply.
fn cmd_(s: var Session, c: str): json.Json uses ffi, time {
  s.seq += 1
  t.check(sys.fd_write(s.conn, "@{s.seq} {c}\n".bytes()), "write to the program failed")
  loop {
    let e = read(&s)
    if e.get("seq").as_i64() == some(s.seq) { return e }
    s.pending.push(e)
  }
}

/// The next event named `ev`.
fn wait(s: var Session, ev: str): json.Json uses ffi, time {
  match s.pending.find_index(e => e.get("ev").as_str() == some(ev)) {
    some(i) => return s.pending.remove(i)
    none => {}
  }
  loop {
    let e = read(&s)
    if e.get("ev").as_str() == some(ev) { return e }
    s.pending.push(e)
  }
}

/// Resume with `c` and wait for the next stop: (reason, function, line).
fn go(s: var Session, c: str): (str, str, int) uses ffi, time {
  t.check(cmd_(&s, c).get("ev").as_str() == some("ok"), c)
  let st = wait(&s, "stopped")
  let f = st.get("frame")
  (st.get("reason").as_str()!, jstr(f.get("fn")), f.get("line").as_i64() else 0)
}

/// The locals of frame `n`: "name=value" each.
fn vars(s: var Session, n: int): [str] uses ffi, time {
  let r = cmd_(&s, "vars {n}")
  t.check(r.get("ev").as_str() == some("vars"), r.text())
  r.get("vars").as_arr().map(v => "{v.get("name").as_str()!}={v.get("value").as_str()!}")
}

/// Wait for the program: (exit code or -1, stdout).
fn finish(s: var Session): (int, str) uses ffi, time {
  let o = cmd.wait(&s.child, 60000)
  sys.fd_close(s.conn)
  sys.fd_close(s.listener)
  (o.code else -1, o.stdout)
}

let PROG = r"""
  struct Point { x: int, y: int }

  fn add(p: Point, d: int): Point {
      let nx = p.x + d
      let ny = p.y + d
      Point { x: nx, y: ny }
  }

  fn fact(n: int): int {
      if n <= 1 {
          return 1
      }
      n * fact(n - 1)
  }

  fn main() {
      var total = 0
      for i in 0..3 {
          total += i
      }
      let p = add(Point { x: 1, y: 2 }, total)
      let x = 1
      let x = x + fact(3)
      print("{p.x} {x}")
  }
  """

fn breakpoints_stack_and_locals() uses env, fs, ffi, time {
  t.skip_if_lacks("debug", "breakpoints over AUK_DEBUG (`run --debug`)")
  var s = start("basic", PROG)
  let b = cmd_(&s, "break prog.auk:5")
  assert (b.get("ev").as_str(), b.get("line").as_i64()) == (some("break"), some(5))
  // a blank line moves to the next line with code; a function breakpoint stops at its first
  assert cmd_(&s, "break prog.auk:2").get("line").as_i64() == some(4)
  assert cmd_(&s, "delete 2").get("ev").as_str() == some("ok")
  assert cmd_(&s, "break fact").get("line").as_i64() == some(10)
  assert cmd_(&s, "break nowhere").get("ev").as_str() == some("error")
  assert go(&s, "run") == ("breakpoint", "prog.add", 5)
  assert vars(&s, 0) == ["p=Point {{ x: 1, y: 2 }}", "d=3", "nx=4"]
  // the caller's frame and its locals
  let st = cmd_(&s, "stack")
  let fl = st.get("frames").as_arr().map(f => (f.get("fn").as_str()!, f.get("line").as_i64()!))
  assert fl == [("prog.add", 5), ("prog.main", 21)]
  assert vars(&s, 1) == ["total=3"]
  // recursion: one frame per call
  assert go(&s, "continue") == ("breakpoint", "prog.fact", 10)
  assert go(&s, "continue") == ("breakpoint", "prog.fact", 10)
  assert cmd_(&s, "stack").get("frames").as_arr().len() == 3
  assert vars(&s, 0) == ["n=2"]
  assert cmd_(&s, "delete").get("ev").as_str() == some("ok")
  assert cmd_(&s, "continue").get("ev").as_str() == some("ok")
  let _ = wait(&s, "exited")
  assert finish(&s) == (0, "4 7\n")
}

fn stepping() uses env, fs, ffi, time {
  t.skip_if_lacks("debug", "stepping over AUK_DEBUG (`run --debug`)")
  var s = start("step", PROG)
  let _ = cmd_(&s, "break prog.auk:21")
  assert go(&s, "run") == ("breakpoint", "prog.main", 21)
  // into add, over its lines, out to main
  assert go(&s, "step") == ("step", "prog.add", 4)
  assert go(&s, "next") == ("step", "prog.add", 5)
  assert go(&s, "finish") == ("step", "prog.main", 22)
  // over a call: stays in main; shadowed names show their latest binding
  assert go(&s, "next") == ("step", "prog.main", 23)
  assert go(&s, "next") == ("step", "prog.main", 24)
  let v = vars(&s, 0)
  t.check(v.contains("x=7"), "{v}")
  let _ = cmd_(&s, "continue")
  let _ = wait(&s, "exited")
  assert finish(&s).0 == 0
}

fn loops_stop_every_iteration() uses env, fs, ffi, time {
  t.skip_if_lacks("debug", "loop breakpoints over AUK_DEBUG (`run --debug`)")
  var s = start("loop", PROG)
  let _ = cmd_(&s, "break prog.auk:19")
  assert go(&s, "run").2 == 19
  var seen = [vars(&s, 0)]
  for _ in 0..2 {
    assert go(&s, "continue").2 == 19
    seen.push(vars(&s, 0))
  }
  assert seen == [["total=0", "i=0"], ["total=0", "i=1"], ["total=1", "i=2"]]
  let _ = cmd_(&s, "delete")
  let _ = cmd_(&s, "continue")
  let _ = wait(&s, "exited")
  let _ = finish(&s)
}

fn panics_tasks_and_pause() uses env, fs, ffi, time {
  t.skip_if_lacks("debug", "panics, tasks and pause over AUK_DEBUG (`run --debug`)")
  let src = r"""
    async fn work(k: int): int {
        var s = 0
        for i in 0..k {
            s += i
        }
        s
    }

    fn spin(): int {
        var n = 0
        while true {
            n += 1
            if n < 0 { return n }
        }
        n
    }

    fn boom(xs: [int]): int {
        let m = xs.map(x => x * 2)
        m[10]
    }

    fn main() {
        let r = catch boom([1])
        let (a, b) = await (work(3), work(4))
        print("{a} {b}")
        print("{spin()}")
    }
    """
  var s = start("tasks", src)
  // a caught panic stops only with `catch all`
  let _ = cmd_(&s, "catch all")
  let _ = cmd_(&s, "break prog.auk:4")
  let p = cmd_(&s, "run")
  assert p.get("ev").as_str() == some("ok")
  let st = wait(&s, "stopped")
  assert st.get("reason").as_str() == some("panic")
  assert st.get("msg").as_str() == some("index 10 out of range for length 1")
  assert st.get("caught") == json.Json.Bool(true)
  assert vars(&s, 0) == ["xs=[1]", "m=[2]"]
  // a task's thread; every other thread stops too
  assert go(&s, "continue") == ("breakpoint", "prog.work", 4)
  let th = cmd_(&s, "threads")
  t.check(th.get("threads").as_arr().len() >= 2, th.text())
  let _ = cmd_(&s, "delete")
  // pause a busy loop
  assert cmd_(&s, "continue").get("ev").as_str() == some("ok")
  time.sleep(300)
  let _ = cmd_(&s, "pause")
  let st = wait(&s, "stopped")
  assert st.get("reason").as_str() == some("pause")
  assert st.get("frame").get("fn").as_str() == some("prog.spin")
  let _ = cmd_(&s, "kill")
  assert finish(&s) == (137, "3 6\n")
}

fn an_uncaught_panic_stops_before_the_process_ends() uses env, fs, ffi, time {
  t.skip_if_lacks("debug", "an uncaught panic over AUK_DEBUG (`run --debug`)")
  var s = start(
    "panic",
    "fn f(n: int): int {{\n    100 / n\n}}\n\nfn main() {{\n    let k = 0\n    print(\"{{f(k)}}\")\n}}\n",
  )
  let _ = cmd_(&s, "run")
  let st = wait(&s, "stopped")
  assert (st.get("reason").as_str(), st.get("frame").get("line").as_i64()) ==
    (some("panic"), some(2))
  assert vars(&s, 1) == ["k=0"]
  let _ = cmd_(&s, "continue")
  assert finish(&s).0 == 101
}

fn detached_and_flagless_programs() uses env, fs, ffi, time {
  t.skip_if_lacks("debug", "`run --debug` and `ir --debug`")
  let dir = scratch("plain")
  let f = paths.join(dir, "prog.auk")
  t.write(f, PROG)
  // --debug without a front end runs as usual
  let o = auk_cmd().args(["run", "--debug", f]).output()
  assert o.stdout == "4 7\n"
  // no instrumentation without the flag
  let root = t.root()
  for f in ["examples/tour.auk", "examples/life.auk"] {
    let plain = auk_cmd().args(["ir", f]).cwd(root).output().stdout
    t.check(!plain.contains("auk_dbg"), f)
    let dbg = auk_cmd().args(["ir", "--debug", f]).cwd(root).output().stdout
    t.check(dbg.contains("auk_dbg_hook(") && dbg.contains("auk_dbg_init("), f)
  }
}

// ---- auk debug ----

fn prog_file(name: str, src: str): str uses fs, ffi {
  let f = paths.join(scratch(name), "prog.auk")
  t.write(f, src)
  f
}

fn debug_cmd(args: [str], f: str): (int, str) uses env, ffi, time {
  let o = auk_cmd().arg("debug").args(args).arg(f).output()
  (o.code else -1, o.stdout + o.stderr)
}

fn batch_text_report() uses env, fs, ffi, time {
  t.skip_if_lacks("debug", "`auk debug` batch reports")
  let f = prog_file("batch", PROG)
  // stdin is not a terminal: batch mode
  let (code, out) = debug_cmd(
    ["-b", "prog.auk:5", "-b", "fact", "-p", "n,nx", "--max-stops", "3"],
    f,
  )
  t.check(code == 137, out)
  let want = "#1 breakpoint at prog.auk:5 in prog.add\n  nx = 4\n  called from prog.main (prog.auk:21)\n#2 breakpoint at prog.auk:10 in prog.fact\n  n = 3\n  called from prog.main (prog.auk:23)\n#3 breakpoint at prog.auk:10 in prog.fact\n  n = 2\n  called from prog.fact (prog.auk:13) < prog.main (prog.auk:23)\nended after 3 stops (--max-stops)\nexit 137\n"
  // paths are shown relative to the working directory: compare from the first stop's file name
  t.eq(rel(out, f), want, "batch report")
  // no breakpoints: runs to the end
  let (code, out) = debug_cmd([], f)
  assert (code, out) == (0, "stdout:\n4 7\nexit 0\n")
}

fn batch_json_panic_and_timeout() uses env, fs, ffi, time {
  t.skip_if_lacks("debug", "`auk debug --json`")
  let f = prog_file(
    "json",
    "fn f(n: int): int {{\n    100 / n\n}}\n\nfn main() {{\n    print(\"hi\")\n    let k = 0\n    print(\"{{f(k)}}\")\n}}\n",
  )
  let (code, out) = debug_cmd(["--json"], f)
  t.check(code == 101, out)
  let r = parse(out.trim())
  let s = r.get("stops").as_arr()[0]
  assert (s.get("reason").as_str(), s.get("line").as_i64(), s.at(["locals", "n"]).as_str()) ==
    (some("panic"), some(2), some("0"))
  t.check(jstr(s.get("msg")).contains("division by zero"), out)
  assert s.get("stack").as_arr().len() == 2
  assert r.get("stdout").as_str() == some("hi\n")
  // an endless loop: where it is when the time runs out
  let f = prog_file(
    "spin",
    "fn main() {{\n    var n = 0\n    while true {{\n        n += 1\n    }}\n}}\n",
  )
  let (code, out) = debug_cmd(["--json", "--timeout", "0.5"], f)
  t.check(code == 137, out)
  let r = parse(out.trim())
  let s = r.get("stops").as_arr()[0]
  t.check(s.get("reason").as_str() == some("timeout"), out)
  t.check(s.at(["locals", "n"]).as_str() is some(_), out)
  // a program that doesn't compile: its errors and the compiler's exit code
  let f = prog_file("bad", "fn main() {{\n    let x: int = \"a\"\n}}\n")
  let (code, out) = debug_cmd([], f)
  t.check(code != 0 && out.contains("E0200"), out)
}

fn interactive_prompt() uses env, fs, ffi, time {
  t.skip_if_lacks("debug", "the `auk debug --repl` prompt")
  let f = prog_file("repl", PROG)
  // typed ahead: what is typed while the program runs waits for the next stop
  let o = auk_cmd()
    .args(["debug", "--repl", f])
    .stdin("b add\nr\nn\n\np nx\nup\nbt\nfinish\np total\nnope\nd\nc\n")
    .output()
  let out = rel(o.stdout, f)
  for want in [
    "breakpoint 1 at prog.auk:4",
    "breakpoint 1 in prog.add (prog.auk:4)\n4\t    let nx = p.x + d",
    "6\t    Point {{ x: nx, y: ny }}",
    "nx: int = 4",
    "#1 prog.main (prog.auk:21)",
    " #0 prog.add (prog.auk:6)\n*#1 prog.main (prog.auk:21)",
    "total: int = 3",
    "unknown command `nope`",
    "4 7\n",
    "program exited with code 0",
  ] {
    t.check(out.contains(want), "missing {want.show()} in:\n{out}")
  }
  assert o.code == some(0)
}

// ---- parts of values, `auk dap` ----

let SCENE = r"""
  struct Point { x: int, y: int }
  enum Shape { Circle(c: Point, r: float), Square(Point, float), Empty }
  struct Scene { name: str, shapes: [Shape], tags: {str: int}, best: Point?, pair: (int, str) }

  fn main() {
      let s = Scene { name: "demo", shapes: [Circle(Point { x: 1, y: 2 }, 3.0), Square(Point { x: 0, y: 0 }, 1.5), Empty], tags: {"a": 1, "b": 2}, best: Point { x: 9, y: 9 }, pair: (7, "seven") }
      let big = 0..1500
      print(s.name)
  }
  """

fn kids(s: var Session, c: str): [str] uses ffi, time {
  let r = cmd_(&s, "kids 0 1 {c}")
  r
    .get("kids")
    .as_arr()
    .map(
      k => "{k.get("name").as_str()!}={k.get("value").as_str()!}{if k.get("kids") == json.Json.Bool(true) { "+" } else { "" }}",
    )
}

fn parts_of_values() uses env, fs, ffi, time {
  t.skip_if_lacks("debug", "parts of values over AUK_DEBUG (`run --debug`)")
  var s = start("kids", SCENE)
  let _ = cmd_(&s, "break prog.auk:8")
  assert go(&s, "run").2 == 8
  let v = cmd_(&s, "vars")
  assert v.get("vars").as_arr()[0].get("kids") == json.Json.Bool(true)
  assert kids(&s, "s")[0] == "name=\"demo\""
  assert kids(&s, "s 1") ==
    ["0=Circle(Point {{ x: 1, y: 2 }}, 3.0)+", "1=Square(Point {{ x: 0, y: 0 }}, 1.5)+", "2=Empty"]
  assert kids(&s, "s 1 0") == ["c=Point {{ x: 1, y: 2 }}+", "r=3.0"]
  assert kids(&s, "s 1 1") == ["0=Point {{ x: 0, y: 0 }}+", "1=1.5"]
  assert kids(&s, "s 1 0 0") == ["x=1", "y=2"]
  assert kids(&s, "s 2") == ["\"a\"=1", "\"b\"=2"]
  assert kids(&s, "s 3") == ["some=Point {{ x: 9, y: 9 }}+"]
  assert kids(&s, "s 4") == ["0=7", "1=\"seven\""]
  // long lists: the first 1000, and how many more
  let r = cmd_(&s, "kids 0 1 big")
  assert (r.get("kids").as_arr().len(), r.get("more").as_i64()) == (1000, some(500))
  // an element past the first 1000 can still be reached by its index (an int has no parts)
  assert cmd_(&s, "kids 0 1 big 1234").get("msg").as_str() == some("no such part")
  for bad in ["s 1 7", "s 0", "nope"] {
    t.check(cmd_(&s, "kids 0 1 {bad}").get("ev").as_str() == some("error"), bad)
  }
  let _ = cmd_(&s, "kill")
  // (Rust drops the session here; the killed program is reaped)
  let _ = finish(&s)
}

/// A DAP client of `auk dap`.
struct Dap { child: sys.Child, seq: int, seen: [json.Json] }

fn dap_start(): Dap uses env, ffi, time =
  Dap { child: auk_cmd().arg("dap").start(), seq: 0, seen: [] }

fn dap_read(d: var Dap): json.Json uses ffi, time {
  var len = 0
  loop {
    let l = sys.read_line(&d.child, READ_MS)
    t.check(l is some(_), "auk dap closed")
    let l = l!.trim()
    if l == "" { break }
    match l.strip_prefix("Content-Length:") {
      some(n) => len = int.parse(n.trim())!
      none => {}
    }
  }
  let b = sys.read_exact(&d.child, len, READ_MS)
  t.check(b is some(_), "auk dap closed")
  parse(str.from_utf8(b!)!)
}

fn req(d: var Dap, command: str, args: json.Json): json.Json uses ffi, time {
  d.seq += 1
  let m = json.obj([
    ("seq", json.of(d.seq)),
    ("type", json.of("request")),
    ("command", json.of(command)),
    ("arguments", args),
  ]).text()
  t.check(
    sys.write(&d.child, "Content-Length: {m.byte_len()}\r\n\r\n{m}".bytes(), READ_MS),
    "write to auk dap failed",
  )
  loop {
    let r = dap_read(&d)
    if r.get("type").as_str() == some("response") && r.get("request_seq").as_i64() == some(d.seq) {
      return r
    }
    d.seen.push(r)
  }
}

fn event(d: var Dap, name: str): json.Json uses ffi, time {
  match d.seen.find_index(e => e.get("event").as_str() == some(name)) {
    some(i) => return d.seen.remove(i)
    none => {}
  }
  loop {
    let e = dap_read(&d)
    if e.get("event").as_str() == some(name) { return e }
    d.seen.push(e)
  }
}

/// The top frame's id and its locals as ("name=value", variablesReference).
fn top(d: var Dap): (int, [(str, int)]) uses ffi, time {
  let st = req(&d, "stackTrace", json.obj([("threadId", int_of(1))]))
  let fid = st.at(["body", "stackFrames"]).as_arr()[0].get("id").as_i64()!
  let sc = req(&d, "scopes", json.obj([("frameId", int_of(fid))]))
  let r = sc.at(["body", "scopes"]).as_arr()[0].get("variablesReference").as_i64()!
  (fid, dvars(&d, r))
}

fn dvars(d: var Dap, r: int): [(str, int)] uses ffi, time {
  let v = req(&d, "variables", json.obj([("variablesReference", int_of(r))]))
  v
    .at(["body", "variables"])
    .as_arr()
    .map(
      x => (
        "{x.get("name").as_str()!}={x.get("value").as_str()!}",
        x.get("variablesReference").as_i64()!,
      ),
    )
}

fn dap_wait(d: var Dap): cmd.Out uses ffi, time = cmd.wait(&d.child, 60000)

fn source(path: str, bps: [json.Json]): json.Json =
  json.obj([("source", json.obj([("path", json.of(path))])), ("breakpoints", json.Json.Arr(bps))])

fn dap_session() uses env, fs, ffi, time {
  t.skip_if_lacks("dap", "an `auk dap` session")
  let path = prog_file("dap", SCENE)
  var d = dap_start()
  let init = req(&d, "initialize", json.obj([("adapterID", json.of("auk"))]))
  assert init.at(["body", "supportsConfigurationDoneRequest"]) == json.Json.Bool(true)
  let r = req(&d, "launch", json.obj([("program", json.of(path)), ("stopOnEntry", json.of(true))]))
  t.check(r.get("success") == json.Json.Bool(true), r.text())
  let _ = event(&d, "initialized")
  let bps = req(
    &d,
    "setBreakpoints",
    source(path, [json.obj([("line", int_of(7))]), json.obj([("line", int_of(99))])]),
  )
  let b = bps.at(["body", "breakpoints"]).as_arr()
  assert (b[0].get("verified"), b[0].get("line").as_i64(), b[1].get("verified")) ==
    (json.Json.Bool(true), some(7), json.Json.Bool(false))
  let _ = req(
    &d,
    "setExceptionBreakpoints",
    json.obj([("filters", json.Json.Arr([json.of("uncaught")]))]),
  )
  let _ = req(&d, "configurationDone", json.Json.Null)
  let st = event(&d, "stopped")
  assert st.at(["body", "reason"]).as_str() == some("entry")
  let _ = req(&d, "continue", json.obj([("threadId", int_of(1))]))
  let st = event(&d, "stopped")
  assert st.at(["body", "reason"]).as_str() == some("breakpoint")
  let (fid, locals) = top(&d)
  assert locals.len() == 1
  t.check(locals[0].0.starts_with("s=Scene {{ name: \"demo\""), "{locals}")
  // expand s.shapes[0].c
  let s = dvars(&d, locals[0].1)
  let shapes = s.find(x => x.0.starts_with("shapes="))!.1
  let circle = dvars(&d, shapes)[0].1
  let c = dvars(&d, circle)
  assert c[0].0 == "c=Point {{ x: 1, y: 2 }}"
  assert dvars(&d, c[0].1).map(x => x.0) == ["x=1", "y=2"]
  // hover a path
  let ev = req(
    &d,
    "evaluate",
    json.obj([
      ("expression", json.of("s.shapes[1].0.x")),
      ("frameId", int_of(fid)),
      ("context", json.of("hover")),
    ]),
  )
  t.check(ev.at(["body", "result"]).as_str() == some("0"), ev.text())
  assert req(
    &d,
    "evaluate",
    json.obj([("expression", json.of("s.nope")), ("frameId", int_of(fid))]),
  ).get("success") ==
    json.Json.Bool(false)
  let _ = req(&d, "next", json.obj([("threadId", int_of(1))]))
  assert event(&d, "stopped").at(["body", "reason"]).as_str() == some("step")
  let _ = req(&d, "setBreakpoints", source(path, []))
  let _ = req(&d, "continue", json.obj([("threadId", int_of(1))]))
  let out = event(&d, "output")
  assert out.at(["body", "output"]).as_str() == some("demo\n")
  assert event(&d, "exited").at(["body", "exitCode"]).as_i64() == some(0)
  let _ = event(&d, "terminated")
  let _ = req(&d, "disconnect", json.Json.Null)
  assert dap_wait(&d).success()
}

fn dap_panics_and_compile_errors() uses env, fs, ffi, time {
  t.skip_if_lacks("dap", "`auk dap` panics and compile errors")
  let f = prog_file("dappanic", "fn main() {{\n    let xs = [1, 2]\n    print(\"{{xs[5]}}\")\n}}\n")
  var d = dap_start()
  let _ = req(&d, "initialize", json.Json.Null)
  let _ = req(&d, "launch", json.obj([("program", json.of(f))]))
  let _ = event(&d, "initialized")
  let _ = req(
    &d,
    "setExceptionBreakpoints",
    json.obj([("filters", json.Json.Arr([json.of("uncaught")]))]),
  )
  let _ = req(&d, "configurationDone", json.Json.Null)
  let st = event(&d, "stopped")
  assert st.at(["body", "reason"]).as_str() == some("exception")
  t.check(jstr(st.at(["body", "text"])).contains("out of range"), st.text())
  let _ = req(&d, "terminate", json.Json.Null)
  let _ = event(&d, "terminated")
  let _ = req(&d, "disconnect", json.Json.Null)
  let _ = dap_wait(&d)
  // a program that doesn't compile: its errors in the console, a failed launch
  let f = prog_file("dapbad", "fn main() {{\n    let x: int = \"a\"\n}}\n")
  var d = dap_start()
  let _ = req(&d, "initialize", json.Json.Null)
  let r = req(&d, "launch", json.obj([("program", json.of(f))]))
  assert r.get("success") == json.Json.Bool(false)
  let out = match d.seen.find(e => e.get("event").as_str() == some("output")) {
    some(e) => e
    none => event(&d, "output")
  }
  t.check(jstr(out.at(["body", "output"])).contains("E0200"), out.text())
  let _ = req(&d, "disconnect", json.Json.Null)
  let _ = dap_wait(&d)
}

// ---- native debug info (`auk build -g`) ----

fn native_line_tables() uses env, fs, ffi, time {
  // PROG with inputs the optimizer can't fold away (the loop bound comes from the arguments)
  // and every computed value used, on the same lines
  let prog = PROG
    .replace("fn main() {{", "fn main(args: [str]) {{")
    .replace("for i in 0..3 {{", "for i in 0..args.len() + 2 {{")
    .replace("print(\"{{p.x}} {{x}}\")", "print(\"{{p.x}} {{p.y}} {{x}}\")")
  let f = prog_file("native", prog)
  let dir = paths.parent(f)!
  let out = paths.join(dir, "prog")
  let o = auk_cmd().args(["build", "-g", f, "-o", out]).output()
  t.check(o.success(), o.stderr)
  assert cmd.new(out).output().stdout == "4 5 7\n"
  // Apple's dwarfdump on macOS; elsewhere LLVM's (a `dwarfdump` there may be libdwarf's)
  let mac = t.macos()
  let dwarfdump = if mac { "dwarfdump" } else { "llvm-dwarfdump" }
  if !t.have("lldb") || !t.have(dwarfdump) {
    eprint("skipped: needs lldb and {dwarfdump}")
    return
  }
  // the DWARF: in a .dSYM next to the executable on macOS (dsymutil), in the executable elsewhere
  let dwarf = if mac { paths.join(dir, "prog.dSYM") } else { out }
  t.check(!mac || fs.is_dir(dwarf), "no .dSYM")
  // a compile unit for the program, with its functions by their Auk names and a line table
  let info = cmd.new(dwarfdump).args(["--debug-info", dwarf]).output().stdout
  t.check(
    info.contains("(\"auk ") &&
      info.contains("(\"prog.fact\")") &&
      info.contains("(\"prog.main\")"),
    info.take(2000),
  )
  // lldb: line and function breakpoints, the backtrace in Auk terms (with ASLR left on: turning
  // it off needs personality(2), which containers often deny)
  let o = cmd
    .new("lldb")
    .cwd(dir)
    .args([
      "-b",
      "-o",
      "settings set target.disable-aslr false",
      "-o",
      "b prog.auk:5",
      "-o",
      "breakpoint set -F prog.fact",
      "-o",
      "run",
      "-o",
      "bt 2",
      "-o",
      "c",
      "-o",
      "bt 2",
      "-o",
      "kill",
    ])
    .arg(out)
    .output()
  let tx = o.stdout
  // the line breakpoint is in `add`, which an optimized build may have inlined into its caller
  // (`where = prog`dk_main_shim + 220 [inlined] prog.add + 16 at prog.auk:5:5`)
  let bp1 = match tx.lines().find(l => l.starts_with("Breakpoint 1: where = prog`")) {
    some(l) => l
    none => t.bail("no breakpoint 1 in:\n{tx}")
  }
  t.check(bp1.contains("prog`prog.add") || bp1.contains("[inlined] prog.add"), bp1)
  for want in [
    "at prog.auk:5:5",
    "Breakpoint 2: where = prog`prog.fact",
    "frame #0: 0x",
    "prog`prog.add at prog.auk:5:5",
    "prog`prog.main at prog.auk:21:5",
    "prog`prog.fact at prog.auk:10:5",
  ] {
    t.check(tx.contains(want), "missing {want.show()} in:\n{tx}\nlldb's stderr:\n{o.stderr}")
  }
  // without -g: no debug info
  let o = auk_cmd().args(["build", f, "-o", paths.join(dir, "plain")]).output()
  assert o.success()
  assert !fs.exists(paths.join(dir, "plain.dSYM"))
  if !mac {
    let info = cmd.new(dwarfdump).args(["--debug-info", paths.join(dir, "plain")]).output().stdout
    t.check(!info.contains("(\"auk "), "debug info without -g")
  }
}

fn take(s: str, n: int): str = if s.len() <= n { s } else { s[0..n] }

// ---- expressions at a stop, conditional breakpoints ----

let EVAL = r"""
  struct Point { x: int, y: int }

  fn dist2(p: Point): int = p.x * p.x + p.y * p.y

  fn fact(n: int): int {
      if n <= 1 {
          return 1
      }
      n * fact(n - 1)
  }

  fn main() {
      let pts = [Point { x: 1, y: 2 }, Point { x: 3, y: 4 }]
      var total = 0
      for i in 0..5 {
          total += i
      }
      print("{total} {fact(5)} {pts.len()}")
  }
  """

/// `eval 0 1 <e>`: (true, "value: type"), or (false, the error message) (Rust's
/// `Result<String, String>`).
fn ev(s: var Session, e: str): (bool, str) uses ffi, time {
  let r = cmd_(&s, "eval 0 1 {e}")
  match r.get("ev").as_str() {
    some("value") => (true, "{r.get("value").as_str()!}: {r.get("type").as_str()!}")
    _ => (false, jstr(r.get("msg")))
  }
}

fn expressions_and_conditions() uses env, fs, ffi, time {
  t.skip_if_lacks("debug", "expressions and conditions over AUK_DEBUG (`run --debug`)")
  var s = start("eval", EVAL)
  let b = cmd_(&s, "break prog.auk:16 if i == 3")
  assert b.get("cond").as_str() == some("i == 3")
  let _ = cmd_(&s, "break fact if n == 2")
  // stops only where the condition holds
  assert go(&s, "run") == ("breakpoint", "prog.main", 16)
  assert ev(&s, "i") == (true, "3: int")
  assert ev(&s, "i * 10 + total") == (true, "33: int")
  assert ev(&s, "dist2(pts[1])") == (true, "25: int")
  assert ev(&s, "pts.map(p => p.x)") == (true, "[1, 3]: [int]")
  assert ev(&s, "pts[0]") == (true, "Point {{ x: 1, y: 2 }}: Point")
  assert ev(&s, "nope") == (false, "unknown name `nope`")
  assert !ev(&s, "1 +").0
  // a panic in the expression is an error; the program lives on
  assert ev(&s, "pts[7]") == (false, "panic: index 7 out of range for length 2")
  // an assignment changes the frame's variable
  assert ev(&s, "total = total + 100") == (true, "(): ()")
  assert ev(&s, "total") == (true, "103: int")
  assert go(&s, "continue") == ("breakpoint", "prog.fact", 6)
  assert vars(&s, 0) == ["n=2"]
  // a caller's frame
  assert cmd_(&s, "eval 1 1 n + 1").get("value").as_str() == some("4")
  let _ = cmd_(&s, "delete")
  // a condition that doesn't compile stops, and says why
  let _ = cmd_(&s, "break fact if n <")
  assert go(&s, "continue").0 == "breakpoint"
  let _ = cmd_(&s, "delete")
  let _ = cmd_(&s, "continue")
  let _ = wait(&s, "exited")
  // 103 at i == 3, then + 3 + 4
  assert finish(&s) == (0, "110 120 2\n")
}

fn expressions_in_auk_debug() uses env, fs, ffi, time {
  t.skip_if_lacks("debug", "expressions in `auk debug`")
  let f = prog_file("evalcli", EVAL)
  let (code, out) = debug_cmd(
    ["-b", "prog.auk:16 if i % 2 == 1", "-p", "total,pts[1].x", "-e", "dist2(pts[0]) + i"],
    f,
  )
  t.check(code == 0, out)
  let want = "#1 breakpoint at prog.auk:16 in prog.main\n  total = 0\n  pts[1].x = 3\n  dist2(pts[0]) + i = 6\n#2 breakpoint at prog.auk:16 in prog.main\n  total = 3\n  pts[1].x = 3\n  dist2(pts[0]) + i = 8\n"
  t.check(rel(out, f).starts_with(want), out)
  // the prompt: `p <expression>`, `p x = v`, `b <line> if <cond>`
  let o = auk_cmd()
    .args(["debug", "--repl", f])
    .stdin("b 16 if i == 2\nr\np i * 100\np total = 1000\np total\nd\nc\n")
    .output()
  let out = rel(o.stdout, f)
  for want in [
    "breakpoint 1 at prog.auk:16 if i == 2",
    "i * 100: int = 200",
    "total: int = 1000",
    "1009 120 2",
  ] {
    t.check(out.contains(want), "missing {want.show()} in:\n{out}")
  }
}

fn dap_expressions() uses env, fs, ffi, time {
  t.skip_if_lacks("dap", "`auk dap` expressions")
  let path = prog_file("dapeval", EVAL)
  var d = dap_start()
  let init = req(&d, "initialize", json.Json.Null)
  assert init.at(["body", "supportsConditionalBreakpoints"]) == json.Json.Bool(true)
  let _ = req(&d, "launch", json.obj([("program", json.of(path))]))
  let _ = event(&d, "initialized")
  let bp = json.obj([("line", int_of(16)), ("condition", json.of("i == 4"))])
  let _ = req(&d, "setBreakpoints", source(path, [bp]))
  let _ = req(&d, "configurationDone", json.Json.Null)
  let _ = event(&d, "stopped")
  let (fid, locals) = top(&d)
  t.check(locals.any(l => l.0 == "i=4"), "{locals}")
  let w = (e: str) => json.obj([
    ("expression", json.of(e)),
    ("frameId", int_of(fid)),
    ("context", json.of("watch")),
  ])
  assert req(&d, "evaluate", w("pts.map(p => dist2(p))")).at(["body", "result"]).as_str() ==
    some("[5, 25]")
  // a path keeps its parts expandable
  t.check(
    req(&d, "evaluate", w("pts[1]")).at(["body", "variablesReference"]).as_i64()! > 0,
    "pts[1] expandable",
  )
  assert req(&d, "evaluate", w("nope")).get("success") == json.Json.Bool(false)
  // setVariable on a frame's local
  let st = req(&d, "stackTrace", json.obj([("threadId", int_of(1))]))
  let fid = st.at(["body", "stackFrames"]).as_arr()[0].get("id").as_i64()!
  let sc = req(&d, "scopes", json.obj([("frameId", int_of(fid))]))
  let r = sc.at(["body", "scopes"]).as_arr()[0].get("variablesReference").as_i64()!
  let set = req(
    &d,
    "setVariable",
    json.obj([
      ("variablesReference", int_of(r)),
      ("name", json.of("total")),
      ("value", json.of("50")),
    ]),
  )
  t.check(set.at(["body", "value"]).as_str() == some("50"), set.text())
  let _ = req(&d, "setBreakpoints", source(path, []))
  let _ = req(&d, "continue", json.obj([("threadId", int_of(1))]))
  assert event(&d, "output").at(["body", "output"]).as_str() == some("54 120 2\n")
  let _ = event(&d, "terminated")
  let _ = req(&d, "disconnect", json.Json.Null)
  let _ = dap_wait(&d)
}

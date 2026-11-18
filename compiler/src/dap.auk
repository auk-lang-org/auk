/// `auk dap` (src/dap.rs): a Debug Adapter Protocol server on stdin/stdout, for VS Code and
/// other editors.
///
/// It launches the program with `auk run --debug` (`debug.launch`, output streamed as `output`
/// events) and translates DAP requests into debug engine commands (runtime/c/dbg.c).
/// Supported: launch (program, args, cwd, stopOnEntry), line and function breakpoints, panics
/// as exception breakpoints (`uncaught`, `all`), threads, stack traces, locals with expandable
/// parts (struct fields, variants, elements, entries), continue / next / stepIn / stepOut /
/// pause, `evaluate` of a local or a path into it (`p.x`, `xs.2`), terminate.
///
/// Variable references and frame ids are handles that last until the program resumes.
///
/// Differences from Rust: after `launch`, requests are read by a task (Rust: a thread) feeding
/// the session's `Chan`; the server ends with `_exit` after flushing (that task may still be
/// blocked reading stdin: it can't be joined). Frames are written with C stdio
/// (`stdio.write_out`); `launch`'s `cwd` is C `chdir`. The line breakpoints per source are a
/// map (Rust: a `HashMap`; nothing iterates it).

/// What a handle stands for.
enum Handle {
  /// Frame `frame` of thread `thread`.
  Frame(thread: int, frame: int),
  /// A part of a local: the path of part indexes from the local `name`.
  Kids(thread: int, frame: int, name: str, path: [int]),
}

struct Dap {
  seq: int,
  s: debug.Session?,
  handles: [Handle],
  /// Engine breakpoint ids per source path (DAP sets a whole file's at once), and the function
  /// breakpoints'.
  line_bps: {str: [int]},
  fn_bps: [int],
  /// The temporary breakpoint of `stopOnEntry`.
  entry_bp: int?,
  stopped: bool,
  exited: bool,
}

/// Read one DAP message (`Content-Length` framing); none at the end of input.
fn read_msg(): json.Json? uses env, ffi {
  var len: int? = none
  loop {
    let l = env.read_line() else return none
    let line = l.trim_end()
    if line == "" { break }
    match line.strip_prefix("Content-Length:") {
      some(v) => len = match int.parse(v.trim()) {
        ok(n) => if n >= 0 { some(n) } else { none }
        err(_) => none
      }
      none => {}
    }
  }
  let n = len else return none
  let body = stdio.read_exact(n) else return none
  match json.parse(body) {
    ok(j) => some(j)
    err(_) => none
  }
}

/// `auk dap`; `arg0`: how this binary was started (for `current_exe`).
pub fn run(arg0: str): int uses fs, env, ffi {
  let exe = mcp.current_exe(arg0)
  var d = Dap { seq: 0, s: none, handles: [], line_bps: {}, fn_bps: [], entry_bp: none, stopped: false, exited: false }
  // until `launch`: requests are read here; then a reader task feeds the session's queue
  while d.s is none {
    let req = read_msg() else return 0
    let cmd = req.get("command").as_str() else ""
    match cmd {
      "initialize" => {
        let filters = json.of([
          json.obj([("filter", json.of("uncaught")), ("label", json.of("Uncaught panics")), ("default", json.of(true))]),
          json.obj([
            ("filter", json.of("all")),
            ("label", json.of("All panics (also inside `catch`)")),
            ("default", json.of(false)),
          ]),
        ])
        let caps = json.obj([
          ("supportsConfigurationDoneRequest", json.of(true)),
          ("supportsFunctionBreakpoints", json.of(true)),
          ("supportsTerminateRequest", json.of(true)),
          ("supportsEvaluateForHovers", json.of(true)),
          ("supportsConditionalBreakpoints", json.of(true)),
          ("supportsSetVariable", json.of(true)),
          ("exceptionBreakpointFilters", filters),
        ])
        d.respond(req, true, some(caps), none)
      }
      "launch" => {
        let a = req.get("arguments")
        let program = a.get("program").as_str() else {
          d.respond(req, false, none, some("launch: `program` (a .auk file) is required"))
          continue
        }
        match a.get("cwd").as_str() {
          some(cwd) => if c_chdir(cwd) != 0 {
            d.respond(req, false, none, some("launch: cwd {cwd}: {os_error()}"))
            continue
          }
          none => {}
        }
        let args = a.get("args").as_arr().filter(x => x.as_str() != none).map(x => x.as_str()!)
        match debug.launch(exe, program, args, debug.Capture.Stream) {
          ok(s) => {
            d.s = some(s)
            if a.get("stopOnEntry") == json.Json.Bool(true) {
              let r = d.cmd("break main")
              d.entry_bp = r.get("id").as_i64()
            }
            d.respond(req, true, none, none)
            d.event("initialized", none)
          }
          err(Failed(code, text)) => {
            d.output("stderr", text)
            d.respond(req, false, none, some("the program did not start (exit code {code}): see the Debug Console"))
            d.event("terminated", none)
          }
        }
      }
      "disconnect" | "terminate" => {
        d.respond(req, true, none, none)
        return 0
      }
      _ => d.respond(req, false, none, some("`{cmd}` before launch"))
    }
  }
  let q = d.s!.q
  let reader = requests(q)
  loop {
    var s = d.s!
    let input = s.next()
    d.s = some(s)
    match input {
      Req(req) => if !d.request(req) { break }
      Ev(e) => d.engine_event(e)
      Out(is_err, text) => d.output(if is_err { "stderr" } else { "stdout" }, text)
      Closed => d.ended()
      Eof => {
        d.kill()
        break
      }
      _ => {}
    }
  }
  // the request reader may still be blocked on stdin: end here rather than join it
  stdio.flush()
  let _ = reader
  c__exit(0)
  0
}

/// Requests after `launch`, then `Eof`.
async fn requests(q: Chan<debug.In>): int uses env, ffi {
  loop {
    let m = read_msg() else break
    q.send(debug.In.Req(m))
  }
  q.send(debug.In.Eof)
  0
}

fn send(d: var Dap, m: json.Json) uses ffi {
  d.seq += 1
  let msg = match m {
    Obj(fs) => json.Json.Obj([("seq", json.of(d.seq))] + fs)
    x => x
  }
  let body = msg.text()
  let _ = stdio.write_out("Content-Length: {body.byte_len()}\r\n\r\n{body}")
}

fn respond(d: var Dap, req: json.Json, ok: bool, body: json.Json?, msg: str?) uses ffi {
  var fs = [
    ("type", json.of("response")),
    ("request_seq", req.get("seq")),
    ("success", json.of(ok)),
    ("command", req.get("command")),
  ]
  match msg {
    some(m) => fs.push(("message", json.of(m)))
    none => {}
  }
  match body {
    some(b) => fs.push(("body", b))
    none => {}
  }
  d.send(json.obj(fs))
}

fn event(d: var Dap, name: str, body: json.Json?) uses ffi {
  var fs = [("type", json.of("event")), ("event", json.of(name))]
  match body {
    some(b) => fs.push(("body", b))
    none => {}
  }
  d.send(json.obj(fs))
}

fn output(d: var Dap, category: str, text: str) uses ffi {
  if text != "" { d.event("output", some(json.obj([("category", json.of(category)), ("output", json.of(text))]))) }
}

fn cmd(d: var Dap, c: str): json.Json uses ffi {
  match d.s {
    some(s0) => {
      var s = s0
      d.s = none
      let r = s.cmd(c)
      d.s = some(s)
      r
    }
    none => json.Json.Null
  }
}

fn handle(d: var Dap, h: Handle): int {
  d.handles.push(h)
  d.handles.len()
}

fn handle_at(d: Dap, id: int): Handle? = d.handles.get(max(id - 1, 0))

fn resumed(d: var Dap) {
  d.stopped = false
  d.handles = []
}

fn wait(d: var Dap): int uses ffi {
  match d.s {
    some(s0) => {
      var s = s0
      d.s = none
      let code = s.wait()
      d.s = some(s)
      code
    }
    none => 0
  }
}

fn kill(d: var Dap) uses ffi {
  if !d.exited {
    let _ = d.cmd("kill")
    if d.s is some(_) { let _ = d.wait() }
  }
}

/// The program ended (its connection closed).
fn ended(d: var Dap) uses ffi {
  if d.exited { return }
  d.exited = true
  let code = d.wait()
  d.event("exited", some(json.obj([("exitCode", json.of(code))])))
  d.event("terminated", none)
}

fn engine_event(d: var Dap, e: json.Json) uses ffi {
  if e.get("ev").as_str() != some("stopped") { return }
  d.stopped = true
  d.handles = []
  let thread = e.get("thread").as_i64() else 1
  var reason = e.get("reason").as_str() else "pause"
  var fs = [("threadId", json.of(thread)), ("allThreadsStopped", json.of(true))]
  let hit = e.get("bps").as_arr().filter(b => b.as_i64() != none).map(b => b.as_i64()!)
  match d.entry_bp {
    some(id) => if hit.contains(id) {
      let _ = d.cmd("delete {id}")
      d.entry_bp = none
      reason = "entry"
    }
    none => {}
  }
  match reason {
    "panic" => {
      reason = "exception"
      fs.push(("description", json.of("Panic")))
      fs.push(("text", e.get("msg")))
    }
    "breakpoint" => {
      fs.push(("hitBreakpointIds", json.of(hit.map(h => json.of(h)))))
      match e.get("cond_error").as_str() {
        some(c) => {
          fs.push(("text", json.of("the breakpoint's condition failed: {c}")))
          d.output("console", "the breakpoint's condition failed: {c}\n")
        }
        none => {}
      }
    }
    _ => {}
  }
  d.event("stopped", some(json.obj([("reason", json.of(reason))] + fs)))
}

/// ` if <cond>` of a breakpoint's condition, or nothing.
fn cond_of(b: json.Json): str = match b.get("condition").as_str() {
  some(c) => if c.trim() != "" { " if {c.trim()}" } else { "" }
  none => ""
}

/// Serve one request; false to end.
fn request(d: var Dap, req: json.Json): bool uses ffi {
  let a = req.get("arguments")
  let cmd = req.get("command").as_str() else ""
  match cmd {
    "setBreakpoints" => {
      let path = a.at(["source", "path"]).as_str() else ""
      for id in (d.line_bps.remove(path) else []) { let _ = d.cmd("delete {id}") }
      var ids: [int] = []
      var out: [json.Json] = []
      for b in a.get("breakpoints").as_arr() {
        let line = b.get("line").as_i64() else 0
        let r = d.cmd("break {path}:{line}{cond_of(b)}")
        out.push(bp_result(r, line))
        match r.get("id").as_i64() {
          some(id) => ids.push(id)
          none => {}
        }
      }
      d.line_bps[path] = ids
      d.respond(req, true, some(json.obj([("breakpoints", json.of(out))])), none)
    }
    "setFunctionBreakpoints" => {
      for id in d.fn_bps { let _ = d.cmd("delete {id}") }
      d.fn_bps = []
      var out: [json.Json] = []
      for b in a.get("breakpoints").as_arr() {
        let name = b.get("name").as_str() else ""
        let r = d.cmd("break {name}{cond_of(b)}")
        out.push(bp_result(r, 0))
        match r.get("id").as_i64() {
          some(id) => d.fn_bps.push(id)
          none => {}
        }
      }
      d.respond(req, true, some(json.obj([("breakpoints", json.of(out))])), none)
    }
    "setExceptionBreakpoints" => {
      let fs = a.get("filters").as_arr().filter(f => f.as_str() != none).map(f => f.as_str()!)
      let mode = if fs.contains("all") { "all" } else if fs.contains("uncaught") { "uncaught" } else { "none" }
      let _ = d.cmd("catch {mode}")
      d.respond(req, true, none, none)
    }
    "configurationDone" => {
      let _ = d.cmd("run")
      d.respond(req, true, none, none)
    }
    "threads" => {
      var ts: [json.Json] = []
      if d.stopped {
        let r = d.cmd("threads")
        for t in r.get("threads").as_arr() {
          let id = t.get("id").as_i64() else 0
          let name = if id == 1 { "main" } else { "task {id}" }
          ts.push(json.obj([("id", json.of(id)), ("name", json.of(name))]))
        }
      }
      if ts.len() == 0 { ts.push(json.obj([("id", json.of(1)), ("name", json.of("main"))])) }
      d.respond(req, true, some(json.obj([("threads", json.of(ts))])), none)
    }
    "stackTrace" => {
      let thread = a.get("threadId").as_i64() else 1
      let r = d.cmd("stack {thread}")
      let start = max(a.get("startFrame").as_i64() else 0, 0)
      let all = r.get("frames").as_arr()
      let levels = match a.get("levels").as_i64() {
        some(n) => if n > 0 { n } else { all.len() }
        none => all.len()
      }
      var frames: [json.Json] = []
      for i, f in all {
        if i < start || i >= start + levels { continue }
        let id = d.handle(Handle.Frame(thread, i))
        var fs = [
          ("id", json.of(id)),
          ("name", f.get("fn")),
          ("line", json.of(f.get("line").as_i64() else 0)),
          ("column", json.of(f.get("col").as_i64() else 1)),
        ]
        match f.get("file").as_str() {
          some(p) => fs.push(("source", json.obj([("name", json.of(paths.file_name(p))), ("path", json.of(p))])))
          none => {}
        }
        frames.push(json.obj(fs))
      }
      d.respond(req, true, some(json.obj([("stackFrames", json.of(frames)), ("totalFrames", json.of(all.len()))])), none)
    }
    "scopes" => {
      let id = a.get("frameId").as_i64() else 0
      let scopes = match d.handle_at(id) {
        some(Frame(t, f)) => {
          let r = d.handle(Handle.Frame(t, f))
          [
            json.obj([
              ("name", json.of("Locals")),
              ("presentationHint", json.of("locals")),
              ("variablesReference", json.of(r)),
              ("expensive", json.of(false)),
            ]),
          ]
        }
        _ => []
      }
      d.respond(req, true, some(json.obj([("scopes", json.of(scopes))])), none)
    }
    "variables" => {
      let r = a.get("variablesReference").as_i64() else 0
      var vars: [json.Json] = []
      match d.handle_at(r) {
        some(Frame(thread, frame)) => {
          let v = d.cmd("vars {frame} {thread}")
          for x in v.get("vars").as_arr() {
            vars.push(d.variable(x, thread, frame, x.get("name").as_str() else "", []))
          }
        }
        some(Kids(thread, frame, name, path)) => {
          let ps = path.map(p => "{p}")
          let v = d.cmd("kids {frame} {thread} {name} {ps.join(" ")}")
          for i, x in v.get("kids").as_arr() { vars.push(d.variable(x, thread, frame, name, path + [i])) }
          match v.get("more").as_i64() {
            some(n) => vars.push(
              json.obj([("name", json.of("…")), ("value", json.of("{n} more")), ("variablesReference", json.of(0))]),
            )
            none => {}
          }
        }
        none => {}
      }
      d.respond(req, true, some(json.obj([("variables", json.of(vars))])), none)
    }
    "setVariable" => {
      // a local of a frame: `name = value`, evaluated there
      let r = a.get("variablesReference").as_i64() else 0
      let name = a.get("name").as_str() else ""
      let value = a.get("value").as_str() else ""
      match d.handle_at(r) {
        some(Frame(thread, frame)) => {
          let set = d.cmd("eval {frame} {thread} {name} = ({value})")
          if set.get("ev").as_str() == some("value") {
            let v = d.cmd("eval {frame} {thread} {name}")
            d.respond(req, true, some(json.obj([("value", v.get("value")), ("type", v.get("type"))])), none)
          } else {
            d.respond(req, false, none, some(set.get("msg").as_str() else "can't set it"))
          }
        }
        _ => d.respond(req, false, none, some("only a local of a frame can be set"))
      }
    }
    "evaluate" => match d.evaluate(a) {
      ok(b) => d.respond(req, true, some(b), none)
      err(Msg(e)) => d.respond(req, false, none, some(e))
    }
    "continue" | "next" | "stepIn" | "stepOut" => {
      let c = match cmd {
        "continue" => "continue"
        "next" => "next"
        "stepIn" => "step"
        _ => "finish"
      }
      let r = d.cmd(c)
      d.resumed()
      let ok = r.get("ev").as_str() == some("ok")
      let body = if cmd == "continue" { some(json.obj([("allThreadsContinued", json.of(true))])) } else { none }
      d.respond(req, ok, body, if ok { none } else { r.get("msg").as_str() })
    }
    "pause" => {
      let _ = d.cmd("pause")
      d.respond(req, true, none, none)
    }
    "disconnect" | "terminate" => {
      d.kill()
      d.respond(req, true, none, none)
      if !d.exited {
        d.exited = true
        d.event("terminated", none)
      }
      // `terminate` is followed by a `disconnect`
      return cmd != "disconnect"
    }
    _ => d.respond(req, false, none, some("`{cmd}` is not supported"))
  }
  true
}

fn bp_result(r: json.Json, line: int): json.Json = match r.get("id").as_i64() {
  some(id) => json.obj([("id", json.of(id)), ("verified", json.of(true)), ("line", json.of(r.get("line").as_i64() else line))])
  none => json.obj([("verified", json.of(false)), ("message", json.of(r.get("msg").as_str() else "no code there"))])
}

/// A DAP variable from an engine item; parts get a handle.
fn variable(d: var Dap, x: json.Json, thread: int, frame: int, name: str, path: [int]): json.Json {
  let r = if x.get("kids") == json.Json.Bool(true) { d.handle(Handle.Kids(thread, frame, name, path)) } else { 0 }
  json.obj([("name", x.get("name")), ("value", x.get("value")), ("type", x.get("type")), ("variablesReference", json.of(r))])
}

/// The frame a request names (`frameId`), else the top of thread 1.
fn frame_of(d: Dap, a: json.Json): (int, int) = match d.handle_at(a.get("frameId").as_i64() else 0) {
  some(Frame(thread, frame)) => (thread, frame)
  _ => (1, 0)
}

/// A local or a path into it (expandable), else any Auk expression, evaluated in the frame (an
/// assignment `x = 5` changes a `var` local).
fn evaluate(d: var Dap, a: json.Json): json.Json!debug.Fail uses ffi {
  if !d.stopped { return fail(debug.Fail.Msg("the program is running")) }
  let path_err = match d.eval_path(a) {
    ok(j) => return j
    err(Msg(e)) => e
  }
  let (thread, frame) = d.frame_of(a)
  let expr = (a.get("expression").as_str() else "").trim()
  if expr == "" { return fail(debug.Fail.Msg(path_err)) }
  let v = d.cmd("eval {frame} {thread} {expr}")
  match v.get("ev").as_str() {
    some("value") => json.obj([("result", v.get("value")), ("type", v.get("type")), ("variablesReference", json.of(0))])
    _ => fail(debug.Fail.Msg(v.get("msg").as_str() else "can't evaluate that"))
  }
}

/// `s` without the `"`s at either end (Rust's `trim_matches('"')`).
fn unquote(s: str): str {
  var t = s
  while t.starts_with("\"") { t = t.strip_prefix("\"")! }
  while t.ends_with("\"") { t = t.strip_suffix("\"")! }
  t
}

/// `name`, or a path into it: `p.x`, `xs.2`, `xs[2]`, `m["k"]` (a part by its name as listed).
fn eval_path(d: var Dap, a: json.Json): json.Json!debug.Fail uses ffi {
  let (thread, frame) = d.frame_of(a)
  let expr = (a.get("expression").as_str() else "").trim().replace("[", ".").replace("]", "")
  let parts = expr.split(".").map(p => p.trim()).filter(p => p != "")
  let root = parts.first() else return fail(debug.Fail.Msg("nothing to evaluate"))
  let v = d.cmd("vars {frame} {thread}")
  var item = v.get("vars").as_arr().find(x => x.get("name").as_str() == some(root)) else {
    return fail(debug.Fail.Msg("no local `{root}` here"))
  }
  var path: [int] = []
  for p in parts.skip(1) {
    let ps = path.map(x => "{x}")
    let k = d.cmd("kids {frame} {thread} {root} {ps.join(" ")}")
    let kids = k.get("kids").as_arr()
    let i = kids.find_index(x => match x.get("name").as_str() {
      some(n) => n == p || unquote(n) == unquote(p)
      none => false
    }) else return fail(debug.Fail.Msg("no part `{p}`"))
    item = kids[i]
    path.push(i)
  }
  let var_ = d.variable(item, thread, frame, root, path)
  json.obj([("result", var_.get("value")), ("type", var_.get("type")), ("variablesReference", var_.get("variablesReference"))])
}

/// The text of the last OS error, as Rust's `io::Error` shows it.
fn os_error(): str uses ffi {
  let f = ffi.symbol("__error") else (ffi.symbol("__errno_location") else return "unknown error")
  let e = ffi.read_i32(call_errno(f), 0)
  "{c_strerror(e)} (os error {e})"
}

extern fn c_chdir(p: str): int = "int chdir(const char *)"
extern fn c_strerror(e: int): str = "char *strerror(int)"
extern fn call_errno(f: ffi.Ptr): ffi.Ptr = "void *(*)(void)"
extern fn c__exit(code: int) = "void _exit(int)"

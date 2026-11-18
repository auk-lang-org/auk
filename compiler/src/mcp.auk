/// `auk mcp` (src/mcp.rs): a Model Context Protocol server over stdio, so AI agents (Claude Code
/// and other MCP clients) get first-class Auk tools: the language reference, type-checking with
/// fix-its, running, testing, formatting, error explanations and typed holes.
///
/// - **Framing**: newline-delimited JSON-RPC 2.0, one message per line (no `Content-Length`
///   headers, unlike `auk lsp`). Nothing but protocol messages is written to stdout.
/// - **Handshake**: the initialize-based protocol (`initialize`, `notifications/initialized`,
///   `ping`, `tools/list`, `tools/call`), revisions 2024-11-05 through 2025-11-25. A requested
///   revision we know is echoed back; otherwise we answer with the newest one. Unknown methods
///   (including the stateless era's `server/discover`) get -32601, which is what dual-era clients
///   take as the cue to fall back to `initialize`.
/// - **Tools** run the binary itself (`current_exe`) as a subprocess with the matching CLI
///   command and return its output, so the server stays decoupled from the compiler's internals
///   and can never be wedged by a panic or an endless program. Subprocesses get a null stdin
///   (they must not read the protocol stream), a timeout, and their own process group so a
///   timed-out `run` kills the compiled program too.
///
/// Differences from Rust: tool calls run as tasks (Rust: threads), each printing its reply
/// whole (`print` locks stdout) and flushing; a subprocess is started with C `posix_spawnp`
/// (through FFI: Auk's `proc.run` has no stdin, stderr, timeout or process group) with its
/// stdin, stdout and stderr in files of a private temporary directory instead of pipes, so no
/// reader threads are needed (Rust waits up to 2 s for pipes a grandchild keeps open; files
/// don't wait); invalid UTF-8 in the output becomes U+FFFD as in Rust, but a NUL byte ends it.
/// Protocol and tool errors are `Fail.Msg(text)` (`T!E` needs an enum). The port's driver has
/// no `debug` yet, so `auk_debug` reports its error.

/// Protocol revisions we speak, newest first.
pub let PROTOCOL_VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

/// Captured output per stream is cut off past this many bytes (agents' context is precious).
let MAX_OUTPUT = 100000

let INSTRUCTIONS = "Auk is a statically typed language compiled to native code. Call auk_spec first to learn the language, then use auk_check after every edit: its diagnostics carry error codes (explain them with auk_explain) and machine-applicable fixes."

/// The text of a failure: a protocol error (from `call`) or a tool's error result.
pub enum Fail { Msg(text: str) }

/// Serve on stdin/stdout until stdin closes. Returns the process exit code. Tool calls run as
/// tasks (a long `auk_run` doesn't block `ping` or other calls); replies are written whole, one
/// per line, in completion order.
pub fn run(exe_arg: str): int uses fs, env, time, ffi {
  let exe = current_exe(exe_arg)
  var workers: [Task<int>] = []
  loop {
    let line = env.read_line() else break
    if line.trim() == "" { continue }
    match json.parse(line) {
      ok(msg) => if msg.get("method").as_str() == some("tools/call") {
        workers.push(worker(msg, exe))
      } else {
        match handle(msg, exe) {
          some(r) => send(r)
          none => {}
        }
      }
      err(Bad(e)) => send(error_reply(json.Json.Null, -32700, "parse error: {e}"))
    }
  }
  // stdin closed: finish the calls in flight, then exit
  for w in workers { let _ = await w }
  0
}

async fn worker(msg: json.Json, exe: str): int uses fs, time, ffi {
  match handle(msg, exe) {
    some(r) => send(r)
    none => {}
  }
  0
}

/// One message, on a line of its own.
fn send(msg: json.Json) uses ffi {
  print(msg.text())
  stdio.flush()
}

fn reply(id: json.Json, result: json.Json): json.Json =
  json.obj([("jsonrpc", json.of("2.0")), ("id", id), ("result", result)])

fn error_reply(id: json.Json, code: int, msg: str): json.Json =
  json.obj([("jsonrpc", json.of("2.0")), ("id", id), ("error", json.obj([("code", json.of(code)), ("message", json.of(msg))]))])

/// Handle one message; requests get a reply, notifications and responses don't. `exe` is the
/// binary the tools run.
pub fn handle(msg: json.Json, exe: str): json.Json? uses fs, time, ffi {
  let fields = match msg {
    Obj(kvs) => kvs
    _ => return error_reply(json.Json.Null, -32600, "invalid request: expected a JSON-RPC object")
  }
  let id = match fields.find(kv => kv.0 == "id") {
    some(kv) => some(kv.1)
    none => none
  }
  let method = match msg.get("method").as_str() {
    some(m) => m
    none => {
      // a response from the client (we never send requests) or garbage
      let i = id else return none
      if msg.get("result").is_null() && msg.get("error").is_null() {
        return error_reply(i, -32600, "invalid request: missing `method`")
      }
      return none
    }
  }
  let i = id else return none // notifications: `notifications/initialized`, `notifications/cancelled`, ...
  let params = msg.get("params")
  match method {
    "initialize" => reply(i, initialize(params))
    "ping" => reply(i, json.obj([]))
    "tools/list" => reply(i, json.obj([("tools", json.Json.Arr(tools()))]))
    "tools/call" => match call(params, exe) {
      ok(result) => reply(i, result)
      err(Msg(e)) => error_reply(i, -32602, e)
    }
    _ => error_reply(i, -32601, "method not found: {method}")
  }
}

fn initialize(params: json.Json): json.Json {
  let requested = params.get("protocolVersion").as_str() else ""
  let version = PROTOCOL_VERSIONS.find(v => v == requested) else PROTOCOL_VERSIONS[0]
  json.obj([
    ("protocolVersion", json.of(version)),
    ("capabilities", json.obj([("tools", json.obj([]))])),
    ("serverInfo", json.obj([("name", json.of("auk")), ("version", json.of(lsp.VERSION))])),
    ("instructions", json.of(INSTRUCTIONS)),
  ])
}

// ---- tool definitions ----

fn prop(ty: str, description: str): json.Json = json.obj([("type", json.of(ty)), ("description", json.of(description))])

fn schema(props: [(str, json.Json)], required: [str]): json.Json =
  json.obj([
    ("type", json.of("object")),
    ("properties", json.obj(props)),
    ("required", json.Json.Arr(required.map(r => json.of(r)))),
    ("additionalProperties", json.of(false)),
  ])

fn tool(name: str, description: str, input_schema: json.Json): json.Json =
  json.obj([("name", json.of(name)), ("description", json.of(description)), ("inputSchema", input_schema)])

let PATH_OR_SOURCE = "Give exactly one of `path` or `source`."

fn path_prop(what: str): json.Json = prop("string", "Path to {what} (absolute, or relative to the server's working directory).")

fn timeout_prop(default: int): json.Json = prop("number", "Kill the process after this many seconds (default {default}, max 600).")

fn str_array(description: str): json.Json =
  json.obj([("type", json.of("array")), ("items", json.obj([("type", json.of("string"))])), ("description", json.of(description))])

/// Every tool, with its JSON Schema input.
pub fn tools(): [json.Json] {
  let source = prop("string", "Auk source code to use instead of a file (checked as a standalone program in a temporary file).")
  [
    tool(
      "auk_spec",
      "The Auk language reference: syntax, types, effects, the standard library and idioms. Call this first, " +
        "before reading or writing any Auk code; Auk is not Rust, Go or Python and guessing syntax wastes turns.",
      schema([], []),
    ),
    tool(
      "auk_check",
      "Type-check Auk code without running it and return the diagnostics as JSON: " +
        "{{file, ok, diagnostics: [{{code, severity, line, col, end_line, end_col, message, notes, fixes}}]}}. " +
        "Each fix is an edit (1-based line/col range plus replacement `text`) that resolves the error; apply it " +
        "when it matches your intent. Run auk_explain on any code you don't understand. A `path` is checked in " +
        "its project context (the nearest raft.toml, its modules and dependencies). {PATH_OR_SOURCE} Safe: " +
        "does not execute code.",
      schema([("path", path_prop("a .auk file")), ("source", source)], []),
    ),
    tool(
      "auk_run",
      "Compile and RUN an Auk program (this executes code on the user's machine, with their permissions). " +
        "Returns JSON {{exit_code, stdout, stderr, timed_out}}, plus `trace` with `trace: true`; compile errors " +
        "appear in stderr with a non-zero exit code. The program gets no stdin. Prefer auk_check to find errors; " +
        "use this to see behaviour.",
      schema(
        [
          ("path", path_prop("the .auk file with `fn main`")),
          ("args", str_array("Command-line arguments for the program.")),
          ("timeout_seconds", timeout_prop(30)),
          (
            "trace",
            prop(
              "boolean",
              "Record an execution trace: `trace` in the result is a list of events, {{ev:\"call\", fn, loc, args, depth}}, " +
                "{{ev:\"ret\", fn, value, depth}}, {{ev:\"err\", fn, error, depth}}, {{ev:\"peek\", loc, expr, value, depth}}, " +
                "{{ev:\"panic\", msg, loc, depth}}, ending with {{ev:\"truncated\"}} past 2,000 events. Values are shown " +
                "as Auk prints them, cut to 200 characters. Use it to see what actually happened instead of guessing.",
            ),
          ),
        ],
        ["path"],
      ),
    ),
    tool(
      "auk_test",
      "Build and RUN the `test` blocks of an Auk file or project (this executes code on the user's machine). " +
        "Returns the test report (one line per test, then `N passed, M failed`) and the exit code; isError is true " +
        "when any test fails or the build fails. With `trace: true`, each FAIL is followed by the last events of that " +
        "test's execution trace (JSON lines: calls with their arguments, returns, errors, peeks, the panic).",
      schema(
        [
          ("path", path_prop("a .auk file, or a project directory (with raft.toml)")),
          ("filter", prop("string", "Only run tests whose name contains this text.")),
          ("timeout_seconds", timeout_prop(120)),
          ("trace", prop("boolean", "Print the execution trace (the last events) of each failing test under its FAIL line.")),
        ],
        ["path"],
      ),
    ),
    tool(
      "auk_debug",
      "Debug an Auk program: RUN it (this executes code on the user's machine) and stop at each breakpoint " +
        "and at a panic, recording where it stopped, the local variables there (shown as Auk prints them) and " +
        "the call stack. Returns JSON {{stops: [{{reason, fn, file, line, msg?, locals: {{name: value}}, stack}}], " +
        "exit_code, stdout, stderr, note?, errors?}}. `reason` is breakpoint, panic or timeout (still running when " +
        "the time ran out: where it was, e.g. an endless loop). Use it to see the actual values instead of " +
        "guessing or adding prints; a breakpoint inside a loop stops on every iteration (see max_stops), or only " +
        "where its condition holds (`file:line if i == 99`).",
      schema(
        [
          ("path", path_prop("the .auk file with `fn main`")),
          ("breakpoints", str_array("Where to stop: `file:line` (the next line with code) or a function name, optionally followed by ` if <Auk condition>` (e.g. `main.auk:12 if n > 3`).")),
          ("print", str_array("What to show at each stop instead of every local: names of locals, or Auk expressions evaluated there (`xs.len()`, `p.x * 2`, calls to the program's functions).")),
          ("catch", prop("string", "Stop on panics: `uncaught` (default), `all` (also inside `catch`) or `none`.")),
          ("max_stops", prop("number", "End the program after this many stops (default 20).")),
          ("args", str_array("Command-line arguments for the program.")),
          ("timeout_seconds", timeout_prop(30)),
        ],
        ["path"],
      ),
    ),
    tool(
      "auk_fmt",
      "Format Auk code in the canonical style. With `source`, returns the formatted source and changes no " +
        "files. With `path`, REWRITES that file in place and returns its new contents. {PATH_OR_SOURCE}",
      schema([("path", path_prop("a .auk file")), ("source", source)], []),
    ),
    tool(
      "auk_explain",
      "Explain an Auk error code such as E0200: what went wrong, a wrong and a fixed example, and common causes. " +
        "Omit `code` to list every code with a one-line summary.",
      schema([("code", prop("string", "An error code like `E0200`."))], []),
    ),
    tool(
      "auk_holes",
      "List the typed holes (`??`) in an Auk file as JSON: where each hole is, the type it must have and the " +
        "names in scope that could fill it. Write `??` where you don't know the code yet, then use this to see " +
        "what fits. Safe: does not execute code.",
      schema([("path", path_prop("a .auk file"))], ["path"]),
    ),
  ]
}

// ---- tool calls ----

/// What a tool hands back: text, and whether it's an error the agent should react to.
struct Outcome { text: str, is_error: bool }

fn ok_text(text: str): Outcome!Fail = Outcome { text, is_error: false }

/// `tools/call`. An error is a protocol error (unknown tool, malformed params); problems running
/// a tool (bad arguments, missing files, failed commands) are results with `isError: true`, so
/// the agent sees them and can correct itself.
fn call(params: json.Json, exe: str): json.Json!Fail uses fs, time, ffi {
  let name = params.get("name").as_str() else fail(Fail.Msg("tools/call: missing tool `name`"))
  let args = params.get("arguments")
  if !(args.is_null() || args is json.Json.Obj(_)) { fail(Fail.Msg("tools/call: `arguments` must be an object")) }
  let result = match name {
    "auk_spec" => spec(exe)
    "auk_check" => check(args, exe)
    "auk_run" => run_program(args, exe)
    "auk_test" => test(args, exe)
    "auk_debug" => debug(args, exe)
    "auk_fmt" => format(args, exe)
    "auk_explain" => explain(args, exe)
    "auk_holes" => holes(args, exe)
    _ => fail(Fail.Msg("unknown tool: {name}"))
  }
  let out = match result {
    ok(o) => o
    err(Msg(e)) => Outcome { text: e, is_error: true }
  }
  json.obj([
    ("content", json.Json.Arr([json.obj([("type", json.of("text")), ("text", json.of(out.text))])])),
    ("isError", json.of(out.is_error)),
  ])
}

fn spec(exe: str): Outcome!Fail uses fs, time, ffi {
  let o = run_tool(exe, ["spec"], 60000)?
  Outcome { is_error: !o.success(), text: o.stdout }
}

fn str_arg(args: json.Json, key: str): str?!Fail = match args.get(key) {
  Null => none
  Str(s) => some(s)
  _ => fail(Fail.Msg("argument `{key}` must be a string"))
}

fn path_arg(args: json.Json, key: str): str!Fail uses fs, ffi {
  let p = str_arg(args, key)? else fail(Fail.Msg("missing required argument `{key}`"))
  if !fs.exists(p) { fail(Fail.Msg("no such file or directory: {p} (the server's working directory is {cwd()})")) }
  p
}

fn cwd(): str uses ffi = paths.canonicalize(".") else "unknown"

/// Exactly one of `path` / `source`.
enum Input { Path(p: str), Source(s: str) }

fn path_or_source(args: json.Json): Input!Fail uses fs, ffi {
  let p = str_arg(args, "path")?
  let s = str_arg(args, "source")?
  match (p, s) {
    (some(_), none) => Input.Path(path_arg(args, "path")?)
    (none, some(x)) => Input.Source(x)
    _ => {
      let got = if args.get("path").is_null() { "neither" } else { "both" }
      fail(Fail.Msg("{PATH_OR_SOURCE} (got {got})"))
    }
  }
}

fn bool_arg(args: json.Json, key: str): bool!Fail = match args.get(key) {
  Null => false
  Bool(b) => b
  _ => fail(Fail.Msg("argument `{key}` must be a boolean"))
}

/// The most trace events `auk_run` returns (agents' context is precious).
let MCP_TRACE_LIMIT = "2000"

/// The timeout in milliseconds.
fn timeout_arg(args: json.Json, default: int): int!Fail = match args.get("timeout_seconds") {
  Null => default * 1000
  Num(n) => if n > 0.0 { int(min(n, 600.0) * 1000.0) } else { fail(Fail.Msg("argument `timeout_seconds` must be a positive number")) }
  _ => fail(Fail.Msg("argument `timeout_seconds` must be a positive number"))
}

/// A source string written to a private temporary directory (Rust removes it on drop; here
/// `remove_temp`).
struct TempSource { dir: str, file: str }

fn temp_source(src: str): TempSource!Fail uses fs {
  let dir = match fs.temp_dir() {
    ok(d) => d
    err(e) => fail(Fail.Msg("cannot write a temporary file: {e}"))
  }
  let file = paths.join(dir, "main.auk")
  match fs.write(file, src) {
    ok(_) => TempSource { dir, file }
    err(e) => fail(Fail.Msg("cannot write a temporary file: {e}"))
  }
}

/// Remove a temporary directory and the files in it.
fn remove_dir(dir: str) uses fs {
  for f in (fs.list(dir) else []) { let _ = fs.remove(paths.join(dir, f)) }
  let _ = fs.remove(dir)
}

fn check(args: json.Json, exe: str): Outcome!Fail uses fs, time, ffi {
  let input = path_or_source(args)?
  let temp = match input {
    Source(s) => some(temp_source(s)?)
    Path(_) => none
  }
  let file = match (input, temp) {
    (Path(p), _) => p
    (_, some(t)) => t.file
    _ => ""
  }
  let r = run_tool(exe, ["check", file, "--json"], 60000)
  match temp {
    some(t) => remove_dir(t.dir)
    none => {}
  }
  let out = r?
  if json.parse(out.stdout.trim()) is err(_) { fail(Fail.Msg(out.report())) }
  var text = out.stdout.trim()
  match temp {
    some(t) => text = text.replace(t.file, "<source>")
    none => {}
  }
  ok_text(text)
}

fn run_program(args: json.Json, exe: str): Outcome!Fail uses fs, time, ffi {
  let path = path_arg(args, "path")?
  let timeout = timeout_arg(args, 30)?
  // a traced run writes its events to a private temporary file, returned as `trace`
  let trace = if bool_arg(args, "trace")? { some(temp_source("")?) } else { none }
  let r = run_traced(args, exe, path, timeout, trace)
  match trace {
    some(t) => remove_dir(t.dir)
    none => {}
  }
  r
}

fn run_traced(args: json.Json, exe: str, path: str, timeout: int, trace: TempSource?): Outcome!Fail uses fs, time, ffi {
  let trace_file = match trace {
    some(t) => some(paths.join(t.dir, "trace.jsonl"))
    none => none
  }
  var argv = ["run"]
  match trace_file {
    some(f) => {
      argv.push("--trace={f}")
      argv.push("--trace-limit")
      argv.push(MCP_TRACE_LIMIT)
    }
    none => {}
  }
  argv.push(path)
  match args.get("args") {
    Null => {}
    Arr(xs) => for x in xs {
      argv.push(x.as_str() else fail(Fail.Msg("argument `args` must be an array of strings")))
    }
    _ => fail(Fail.Msg("argument `args` must be an array of strings"))
  }
  let out = run_tool(exe, argv, timeout)?
  let code = match out.code {
    some(c) => json.of(c)
    none => json.Json.Null
  }
  var fields = [
    ("exit_code", code),
    ("stdout", json.of(out.stdout)),
    ("stderr", json.of(out.stderr)),
    ("timed_out", json.of(out.timed_out)),
  ]
  match trace_file {
    some(f) => {
      let events = fs.read(f) else ""
      fields.push(("trace", json.Json.Arr(events.lines().map(l => json.parse(l) else json.of(l)))))
    }
    none => {}
  }
  Outcome { text: json.Json.Obj(fields).text(), is_error: !out.success() }
}

fn str_list(args: json.Json, key: str): [str]!Fail = match args.get(key) {
  Null => []
  Arr(xs) => {
    var out: [str] = []
    for x in xs { out.push(x.as_str() else fail(Fail.Msg("argument `{key}` must be an array of strings"))) }
    out
  }
  _ => fail(Fail.Msg("argument `{key}` must be an array of strings"))
}

/// Rust's `{}` of an `f64` number of seconds (`Duration::as_secs_f64`).
fn secs_text(ms: int): str = if ms % 1000 == 0 { "{ms / 1000}" } else { "{float(ms) / 1000.0}" }

fn debug(args: json.Json, exe: str): Outcome!Fail uses fs, time, ffi {
  let path = path_arg(args, "path")?
  let timeout = timeout_arg(args, 30)?
  var argv = ["debug", "--json"]
  for b in str_list(args, "breakpoints")? {
    argv.push("--break")
    argv.push(b)
  }
  let print_ = str_list(args, "print")?
  if print_.len() > 0 {
    argv.push("--print")
    argv.push(print_.join(","))
  }
  match str_arg(args, "catch")? {
    some(c) => {
      argv.push("--catch")
      argv.push(c)
    }
    none => {}
  }
  match args.get("max_stops") {
    Null => {}
    Num(n) => if n >= 1.0 {
      argv.push("--max-stops")
      argv.push("{int(n)}")
    } else {
      fail(Fail.Msg("argument `max_stops` must be a positive number"))
    }
    _ => fail(Fail.Msg("argument `max_stops` must be a positive number"))
  }
  // the debugger reports where a program still running at the timeout is, then ends it
  argv.push("--timeout")
  argv.push(secs_text(timeout))
  argv.push(path)
  argv = argv + str_list(args, "args")?
  let out = run_tool(exe, argv, timeout + 30000)?
  let report = out.stdout.trim()
  // a report, or (the program didn't compile) the compiler's errors
  match json.parse(report) {
    ok(j) => if j.get("error").is_null() { ok_text(report) } else { fail(Fail.Msg(out.report())) }
    err(_) => fail(Fail.Msg(out.report()))
  }
}

fn test(args: json.Json, exe: str): Outcome!Fail uses fs, time, ffi {
  let path = path_arg(args, "path")?
  let timeout = timeout_arg(args, 120)?
  var argv = ["test"]
  if bool_arg(args, "trace")? { argv.push("--trace=json") }
  argv.push(path)
  match str_arg(args, "filter")? {
    some(f) => argv.push(f)
    none => {}
  }
  let out = run_tool(exe, argv, timeout)?
  Outcome { is_error: !out.success(), text: out.report() }
}

fn format(args: json.Json, exe: str): Outcome!Fail uses fs, time, ffi {
  match path_or_source(args)? {
    Source(src) => {
      let out = run_tool_stdin(exe, ["fmt", "-"], some(src), 60000)?
      if out.success() { ok_text(out.stdout) } else { fail(Fail.Msg(out.report().replace("<stdin>", "<source>"))) }
    }
    Path(p) => {
      let out = run_tool(exe, ["fmt", p], 60000)?
      if !out.success() { fail(Fail.Msg(out.report())) }
      if paths.is_file(p) {
        match fs.read(p) {
          ok(t) => ok_text(t)
          err(e) => fail(Fail.Msg("cannot read {p}: {paths.io_error(e.show())}"))
        }
      } else {
        ok_text("formatted every .auk file under {p}\n{out.stdout}")
      }
    }
  }
}

fn explain(args: json.Json, exe: str): Outcome!Fail uses fs, time, ffi {
  let out = match str_arg(args, "code")? {
    some(code) => run_tool(exe, ["explain", code], 60000)?
    none => run_tool(exe, ["explain"], 60000)?
  }
  if out.success() { ok_text(out.stdout) } else { fail(Fail.Msg(out.report())) }
}

fn holes(args: json.Json, exe: str): Outcome!Fail uses fs, time, ffi {
  let path = path_arg(args, "path")?
  // `auk holes` is newer than this server: find it (and whether it takes --json) in the usage
  let usage = (run_tool(exe, ["help"], 60000)?).stdout
  let line = usage.lines().find(l => l.trim_start().starts_with("holes")) else fail(Fail.Msg(
    "auk_holes is not available in this build of auk (there is no `auk holes` command); " +
      "rebuild auk from a newer source",
  ))
  var argv = ["holes", path]
  if line.contains("--json") { argv.push("--json") }
  let out = run_tool(exe, argv, 60000)?
  if out.stdout.trim() == "" || out.code is none || out.timed_out { fail(Fail.Msg(out.report())) }
  ok_text(out.stdout)
}

// ---- subprocesses ----

struct Output {
  /// The exit code; none when the process was killed (on timeout, or by a signal).
  code: int?,
  stdout: str,
  stderr: str,
  timed_out: bool,
}

fn success(o: Output): bool = o.code == some(0)

/// Everything a human would have seen, for error results and reports.
fn report(o: Output): str {
  var s = o.stdout
  if o.stderr != "" {
    if s != "" && !s.ends_with("\n") { s += "\n" }
    s += o.stderr
  }
  if o.timed_out {
    s += "\n(timed out: the process was killed)"
  } else {
    match o.code {
      some(c) => if c != 0 {
        if s != "" && !s.ends_with("\n") { s += "\n" }
        s += "(exit code {c})"
      }
      none => {}
    }
  }
  s
}

fn run_tool(exe: str, args: [str], timeout: int): Output!Fail uses fs, time, ffi = run_tool_stdin(exe, args, none, timeout)

extern fn c_spawnp(pid: ffi.Ptr, file: str, fa: ffi.Ptr, attr: ffi.Ptr, argv: ffi.Ptr, envp: ffi.Ptr): int =
  "int posix_spawnp(void *, const char *, void *, void *, void *, void *)"

extern fn c_fa_init(fa: ffi.Ptr): int = "int posix_spawn_file_actions_init(void *)"

extern fn c_fa_destroy(fa: ffi.Ptr): int = "int posix_spawn_file_actions_destroy(void *)"

extern fn c_fa_addopen(fa: ffi.Ptr, fd: int, path: str, oflag: int, mode: int): int =
  "int posix_spawn_file_actions_addopen(void *, int, const char *, int, int)"

extern fn c_attr_init(a: ffi.Ptr): int = "int posix_spawnattr_init(void *)"

extern fn c_attr_destroy(a: ffi.Ptr): int = "int posix_spawnattr_destroy(void *)"

extern fn c_attr_setflags(a: ffi.Ptr, flags: int): int = "int posix_spawnattr_setflags(void *, short)"

extern fn c_attr_setpgroup(a: ffi.Ptr, pgroup: int): int = "int posix_spawnattr_setpgroup(void *, int)"

extern fn c_waitpid(pid: int, status: ffi.Ptr, options: int): int = "int waitpid(int, void *, int)"

extern fn c_kill(pid: int, sig: int): int = "int kill(int, int)"

extern fn c_strerror(e: int): str = "const char *strerror(int)"

extern fn call_get_path(f: ffi.Ptr, buf: ffi.Ptr, size: ffi.Ptr): int = "int (*)(void *, void *)"

extern fn call_get_env(f: ffi.Ptr): ffi.Ptr = "void *(*)(void)"

/// Rust's `env::current_exe()`: this binary's path (macOS `_NSGetExecutablePath`, Linux
/// `/proc/self/exe`), else `arg0` as given.
fn current_exe(arg0: str): str uses ffi {
  match ffi.symbol("_NSGetExecutablePath") {
    some(f) => {
      let buf = ffi.alloc(4096)
      let size = ffi.alloc(8)
      ffi.write_i32(size, 0, 4096)
      let r = call_get_path(f, buf, size)
      let p = if r == 0 { ffi.cstr(buf) } else { arg0 }
      ffi.free(buf)
      ffi.free(size)
      paths.canonicalize(p) else p
    }
    none => paths.canonicalize("/proc/self/exe") else arg0
  }
}

/// The C environment (`environ`; macOS `*_NSGetEnviron()`).
fn environ(): ffi.Ptr uses ffi {
  match ffi.symbol("_NSGetEnviron") {
    some(f) => ffi.read_ptr(call_get_env(f), 0)
    none => match ffi.symbol("environ") {
      some(p) => ffi.read_ptr(p, 0)
      none => ffi.null
    }
  }
}

/// A `malloc`'d C string.
fn cstring(s: str): ffi.Ptr uses ffi = ffi.from_bytes(s.bytes() + [0])

/// Run `exe <args>` with optional stdin text, capturing output, killed (with everything it
/// spawned) after `timeout` milliseconds.
fn run_tool_stdin(exe: str, args: [str], input: str?, timeout: int): Output!Fail uses fs, time, ffi {
  let cmd = args.join(" ")
  let dir = match fs.temp_dir() {
    ok(d) => d
    err(e) => fail(Fail.Msg("cannot run auk {cmd}: {e}"))
  }
  let r = spawn_in(dir, exe, args, input, timeout)
  remove_dir(dir)
  r
}

fn spawn_in(dir: str, exe: str, args: [str], input: str?, timeout: int): Output!Fail uses fs, time, ffi {
  let cmd = args.join(" ")
  let out_file = paths.join(dir, "stdout")
  let err_file = paths.join(dir, "stderr")
  let in_file = match input {
    some(text) => {
      let f = paths.join(dir, "stdin")
      match fs.write(f, text) {
        ok(_) => f
        err(e) => fail(Fail.Msg("cannot run auk {cmd}: {e}"))
      }
    }
    none => "/dev/null"
  }
  for f in [out_file, err_file] {
    match fs.write(f, "") {
      ok(_) => {}
      err(e) => fail(Fail.Msg("cannot run auk {cmd}: {e}"))
    }
  }
  // argv: the program, then the arguments, NULL-terminated
  let all = [exe] + args
  let argv = ffi.alloc((all.len() + 1) * 8)
  for i, a in all { ffi.write_ptr(argv, i * 8, cstring(a)) }
  // file actions and attributes (opaque C structs; ample room for any libc's)
  let fa = ffi.alloc(1024)
  let attr = ffi.alloc(1024)
  let _ = c_fa_init(fa)
  let _ = c_fa_addopen(fa, 0, in_file, 0, 0) // O_RDONLY
  let _ = c_fa_addopen(fa, 1, out_file, 1, 0) // O_WRONLY (the file exists, empty)
  let _ = c_fa_addopen(fa, 2, err_file, 1, 0)
  let _ = c_attr_init(attr)
  let _ = c_attr_setflags(attr, 2) // POSIX_SPAWN_SETPGROUP: its own process group
  let _ = c_attr_setpgroup(attr, 0)
  let pidp = ffi.alloc(8)
  let rc = c_spawnp(pidp, exe, fa, attr, argv, environ())
  let pid = ffi.read_i32(pidp, 0)
  let _ = c_fa_destroy(fa)
  let _ = c_attr_destroy(attr)
  for i in 0..all.len() { ffi.free(ffi.read_ptr(argv, i * 8)) }
  ffi.free(argv)
  ffi.free(fa)
  ffi.free(attr)
  ffi.free(pidp)
  if rc != 0 { fail(Fail.Msg("cannot run auk {cmd}: {c_strerror(rc)} (os error {rc})")) }
  let status = ffi.alloc(8)
  let start = time.now()
  var code: int? = none
  var timed_out = false
  loop {
    let w = c_waitpid(pid, status, 1) // WNOHANG
    if w == pid {
      let st = ffi.read_i32(status, 0)
      // WIFEXITED / WEXITSTATUS
      code = if (st & 0x7f) == 0 { some((st >> 8) & 0xff) } else { none }
      break
    }
    if w < 0 {
      ffi.free(status)
      fail(Fail.Msg("waiting for auk: waitpid failed"))
    }
    if time.now() - start >= timeout {
      // SIGKILL to the process group we created at spawn (the child is its leader)
      let _ = c_kill(-pid, 9)
      let _ = c_kill(pid, 9)
      let _ = c_waitpid(pid, status, 0)
      timed_out = true
      break
    }
    time.sleep(10)
  }
  ffi.free(status)
  Output { code, stdout: text(fs.read_bytes(out_file) else []), stderr: text(fs.read_bytes(err_file) else []), timed_out }
}

/// Output bytes as text: cut at `MAX_OUTPUT`, invalid UTF-8 as U+FFFD.
fn text(bytes: [int]): str uses ffi {
  let cut = bytes.len() > MAX_OUTPUT
  let bs = bytes.take(MAX_OUTPUT)
  var s = match str.from_utf8(bs) {
    ok(t) => t
    err(_) => {
      let p = ffi.from_bytes(bs + [0])
      let t = ffi.cstr(p)
      ffi.free(p)
      t
    }
  }
  if cut { s += "\n... (output truncated)" }
  s
}

/// `compiler spec`: the compact language reference handed to AI coders (`auk spec`;
/// docs/spec.md, embedded).
pub fn spec_main(): int uses ffi {
  let s = spec_text()
  print(s.strip_suffix("\n") else s)
  0
}

extern fn spec_text(): str = "#embed ../../docs/spec.md"

test "handshake and errors" {
  let req = (text: str) => handle(json.parse(text)!, "auk")!
  let r = req("{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{{\"protocolVersion\":\"2025-06-18\"}}}}")
  assert r.at(["result", "protocolVersion"]).as_str() == some("2025-06-18")
  let r2 = req("{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{{\"protocolVersion\":\"1999-01-01\"}}}}")
  assert r2.at(["result", "protocolVersion"]).as_str() == some(PROTOCOL_VERSIONS[0])
  assert handle(json.parse("{{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}}")!, "auk") is none
  assert handle(json.parse("{{\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{{}}}}")!, "auk") is none
  assert req("{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"nope\"}}").at(["error", "code"]).as_i64() == some(-32601)
  let r3 = req("{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{{\"name\":\"nope\"}}}}")
  assert r3.at(["error", "code"]).as_i64() == some(-32602)
  let r4 = req("{{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{{\"name\":\"auk_check\",\"arguments\":{{}}}}}}")
  assert r4.at(["result", "isError"]) == json.Json.Bool(true)
}

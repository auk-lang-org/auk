/// tests/mcp.rs: `auk mcp` end to end: spawn the server and speak newline-delimited JSON-RPC
/// 2.0 over its stdio, the way an AI agent's MCP client does.

pub fn tests(): [t.Test] uses env, fs, ffi, time = [
  t.test("initialize_and_list_tools", initialize_and_list_tools),
  t.test("check_source_with_a_type_error", check_source_with_a_type_error),
  t.test("check_a_clean_example", check_a_clean_example),
  t.test("run_hello", run_hello),
  t.test("test_calc", test_calc),
  t.test("run_and_test_with_a_trace", run_and_test_with_a_trace),
  t.test("explain_and_spec", explain_and_spec),
  t.test("fmt_messy_source", fmt_messy_source),
  t.test("errors", errors),
  t.test("debug_reports_stops", debug_reports_stops),
  t.test("holes_when_available", holes_when_available),
  t.test("closing_stdin_exits", closing_stdin_exits),
]

let TOOLS = [
  "auk_spec",
  "auk_check",
  "auk_run",
  "auk_test",
  "auk_debug",
  "auk_fmt",
  "auk_explain",
  "auk_holes",
]

/// How long to wait for a reply (Rust: 120 s).
let RECV_MS = 120000

struct Client { child: sys.Child, next_id: int }

/// Start the server and complete the initialize handshake.
fn start(): Client uses env, ffi, time {
  var c = spawn()
  let r = c.request(
    "initialize",
    json.obj([
      ("protocolVersion", json.of("2025-11-25")),
      ("capabilities", json.obj([])),
      ("clientInfo", json.obj([("name", json.of("auk-tests")), ("version", json.of("1"))])),
    ]),
  )
  let result = r.get("result")
  t.check(result.get("protocolVersion").as_str() == some("2025-11-25"), r.text())
  t.check(result.at(["capabilities", "tools"]) is json.Json.Obj(_), r.text())
  assert result.at(["serverInfo", "name"]).as_str() == some("auk")
  assert (result.at(["serverInfo", "version"]).as_str() else "") != ""
  c.send(json.obj([("jsonrpc", json.of("2.0")), ("method", json.of("notifications/initialized"))]))
  c
}

/// The server, run in the repository root.
fn spawn(): Client uses env, ffi, time =
  Client { child: t.auk().arg("mcp").cwd(t.root()).start(), next_id: 1 }

fn send(c: var Client, msg: json.Json) uses ffi, time { c.write_line(msg.text()) }

fn write_line(c: var Client, line: str) uses ffi, time {
  t.check(sys.write(&c.child, (line + "\n").bytes(), RECV_MS), "writing to auk mcp failed")
}

/// The next message: exactly one line of JSON.
fn recv(c: var Client): json.Json uses ffi, time {
  let line = match sys.read_line(&c.child, RECV_MS) {
    some(l) => l
    none => t.bail("no reply from auk mcp")
  }
  match json.parse(line) {
    ok(j) => j
    err(Bad(e)) => t.bail("not JSON ({e}): {line}")
  }
}

fn request(c: var Client, method: str, params: json.Json): json.Json uses ffi, time {
  let id = c.next_id
  c.next_id += 1
  c.send(
    json.obj([
      ("jsonrpc", json.of("2.0")),
      ("id", json.of(id)),
      ("method", json.of(method)),
      ("params", params),
    ]),
  )
  let r = c.recv()
  t.check(r.get("jsonrpc").as_str() == some("2.0"), r.text())
  t.check(r.get("id").as_i64() == some(id), r.text())
  r
}

/// Call a tool; returns (text, isError).
fn call(c: var Client, name: str, args: json.Json): (str, bool) uses ffi, time {
  let r = c.request("tools/call", json.obj([("name", json.of(name)), ("arguments", args)]))
  let result = r.get("result")
  let content = result.get("content").as_arr()
  t.check(content.len() == 1, r.text())
  t.check(content[0].get("type").as_str() == some("text"), r.text())
  let is_error = match result.get("isError") {
    Bool(b) => b
    _ => t.bail("no isError: {r.text()}")
  }
  (content[0].get("text").as_str()!, is_error)
}

/// Rust's `Drop`: kill the server and reap it.
fn close(c: var Client) uses ffi, time {
  sys.kill(&c.child)
  let _ = cmd.wait(&c.child, 5000)
}

fn parse(text: str): json.Json = match json.parse(text) {
  ok(j) => j
  err(Bad(e)) => t.bail("not JSON ({e}): {text}")
}

fn initialize_and_list_tools() uses env, ffi, time {
  var c = start()
  assert c.request("ping", json.obj([])).get("result") == json.obj([])
  let r = c.request("tools/list", json.obj([]))
  let tools = r.at(["result", "tools"]).as_arr()
  var names: [str] = []
  for tool in tools {
    match tool.get("name").as_str() {
      some(n) => names.push(n)
      none => {}
    }
  }
  assert names == TOOLS
  for tool in tools {
    let name = tool.get("name").as_str()!
    t.check((tool.get("description").as_str() else "").len() > 40, "{name}: short description")
    let schema = tool.get("inputSchema")
    t.check(schema.get("type").as_str() == some("object"), name)
    let props = match schema.get("properties") {
      Obj(kvs) => kvs
      _ => t.bail("{name}: no properties")
    }
    for (p, s) in props {
      let ty = s.get("type").as_str()
      t.check(
        ["string", "number", "array", "boolean", "object"].any(k => ty == some(k)),
        "{name}.{p}: type {ty}",
      )
      t.check(s.get("description").as_str() is some(_), "{name}.{p}: no description")
    }
    for req in schema.get("required").as_arr() {
      let req = req.as_str()!
      t.check(props.any(kv => kv.0 == req), "{name}: required `{req}` is not a property")
    }
  }
  // tools that execute code say so
  for tool in tools {
    let name = tool.get("name").as_str()!
    if name == "auk_run" || name == "auk_test" {
      t.check(tool.get("description").as_str()!.contains("executes code"), name)
    }
  }
  close(&c)
}

fn check_source_with_a_type_error() uses env, ffi, time {
  var c = start()
  let src = "fn label(n: int): str = n\n\nfn main() {{\n  print(label(1))\n}}\n"
  let (text, is_error) = c.call("auk_check", json.obj([("source", json.of(src))]))
  t.check(!is_error, text)
  let report = parse(text)
  assert report.get("file").as_str() == some("<source>")
  assert report.get("ok") == json.Json.Bool(false)
  let d = report.get("diagnostics").as_arr()[0]
  t.check(d.get("code").as_str() == some("E0200"), text)
  assert d.get("line").as_i64() == some(1)
  let fix = d.get("fixes").as_arr()[0]
  t.check(fix.get("text").as_str() == some("int"), text)
  assert (fix.get("line").as_i64(), fix.get("col").as_i64(), fix.get("end_col").as_i64()) ==
    (some(1), some(19), some(22))
  close(&c)
}

fn check_a_clean_example() uses env, ffi, time {
  var c = start()
  let (text, is_error) = c.call("auk_check", json.obj([("path", json.of("examples/hello.auk"))]))
  t.check(!is_error, text)
  let report = parse(text)
  t.check(report.get("ok") == json.Json.Bool(true), text)
  assert report.get("diagnostics").as_arr().len() == 0
  close(&c)
}

fn run_hello() uses env, ffi, time {
  if t.lacks("run", "auk_run") { return }
  var c = start()
  let (text, is_error) = c.call("auk_run", json.obj([("path", json.of("examples/hello.auk"))]))
  t.check(!is_error, text)
  let r = parse(text)
  assert r.get("stdout").as_str() == some("Hello from Auk!\n")
  assert r.get("stderr").as_str() == some("")
  assert r.get("exit_code").as_i64() == some(0)
  assert r.get("timed_out") == json.Json.Bool(false)
  close(&c)
}

fn test_calc() uses env, ffi, time {
  if t.lacks("test", "auk_test") { return }
  var c = start()
  let (text, is_error) = c.call("auk_test", json.obj([("path", json.of("examples/calc.auk"))]))
  t.check(!is_error, text)
  t.check(text.contains("passed, 0 failed"), text)
  close(&c)
}

fn run_and_test_with_a_trace() uses env, fs, ffi, time {
  if t.lacks("run", "auk_run with a trace") || t.lacks("test", "auk_test with a trace") { return }
  var c = start()
  let (text, is_error) = c.call(
    "auk_run",
    json.obj([("path", json.of("examples/fib.auk")), ("trace", json.Json.Bool(true))]),
  )
  t.check(!is_error, text)
  let r = parse(text)
  assert r.get("stdout").as_str()!.lines().len() == 10
  let events = r.get("trace").as_arr()
  t.check(events[0].get("ev").as_str() == some("call"), text)
  assert events[0].get("fn").as_str() == some("fib.main")
  let first_fib = events.find(e => e.get("fn").as_str() == some("fib.fib"))!
  assert first_fib.get("args").as_arr()[0].as_str() == some("0")
  assert first_fib.get("loc").as_str() == some("examples/fib.auk:9:11")
  assert events.all(e => e.get("ev").as_str() is some(_))
  // without `trace` there is no trace
  let (text, _) = c.call("auk_run", json.obj([("path", json.of("examples/fib.auk"))]))
  assert parse(text).get("trace").is_null()
  // a failing test shows its trace
  let d = paths.join(t.tmp_base(), "mcp-trace")
  let f = paths.join(d, "t.auk")
  t.write(f, "fn twice(n: int): int = n + n + 1\ntest \"twice\" {{ assert twice(2) == 4 }}\n")
  let (text, is_error) = c.call(
    "auk_test",
    json.obj([("path", json.of(f)), ("trace", json.Json.Bool(true))]),
  )
  t.check(is_error, text)
  t.check(text.contains("FAIL twice"), text)
  t.check(text.contains("{{\"ev\":\"ret\",\"fn\":\"t.twice\",\"value\":\"5\",\"depth\":0}}"), text)
  let (text, _) = c.call("auk_test", json.obj([("path", json.of(f))]))
  t.check(!text.contains("{{\"ev\":"), text)
  close(&c)
}

fn explain_and_spec() uses env, ffi, time {
  var c = start()
  let (text, is_error) = c.call("auk_explain", json.obj([("code", json.of("E0400"))]))
  t.check(!is_error, text)
  t.check(text.starts_with("E0400"), text)
  let (text, is_error) = c.call("auk_explain", json.obj([("code", json.of("E9999"))]))
  t.check(is_error, text)
  t.check(text.contains("not an Auk error code"), text)
  let (text, is_error) = c.call("auk_spec", json.obj([]))
  assert !is_error
  t.check(text.starts_with("# Auk"), text[0..min(text.len(), 100)])
  assert text.byte_len() > 1000
  close(&c)
}

fn fmt_messy_source() uses env, ffi, time {
  var c = start()
  let (text, is_error) = c.call(
    "auk_fmt",
    json.obj([("source", json.of("fn main(){{print( 1+2 )}}"))]),
  )
  t.check(!is_error, text)
  assert text == "fn main() {{ print(1 + 2) }}\n"
  // a syntax error is reported against the source, not a temp file
  let (text, is_error) = c.call("auk_fmt", json.obj([("source", json.of("fn main( {{"))]))
  t.check(is_error, text)
  close(&c)
}

fn errors() uses env, ffi, time {
  var c = start()
  for tool in ["auk_check", "auk_run", "auk_test", "auk_debug", "auk_fmt", "auk_holes"] {
    let (text, is_error) = c.call(tool, json.obj([("path", json.of("examples/no_such_file.auk"))]))
    t.check(is_error, "{tool}: {text}")
    t.check(text.contains("no such file"), "{tool}: {text}")
  }
  // path and source together, or neither
  let (text, is_error) = c.call(
    "auk_check",
    json.obj([("path", json.of("examples/hello.auk")), ("source", json.of(""))]),
  )
  t.check(is_error && text.contains("exactly one"), text)
  let (_, is_error) = c.call("auk_check", json.obj([]))
  assert is_error
  // protocol errors
  let r = c.request("no/such/method", json.obj([]))
  t.check(r.at(["error", "code"]).as_i64() == some(-32601), r.text())
  let r = c.request(
    "tools/call",
    json.obj([("name", json.of("auk_nope")), ("arguments", json.obj([]))]),
  )
  t.check(r.at(["error", "code"]).as_i64() == some(-32602), r.text())
  c.send(json.Json.Str("not json-rpc"))
  assert c.recv().at(["error", "code"]).as_i64() == some(-32600)
  c.write_line("{{oops")
  assert c.recv().at(["error", "code"]).as_i64() == some(-32700)
  // still serving
  assert c.request("ping", json.obj([])).get("error").is_null()
  close(&c)
}

fn debug_reports_stops() uses env, ffi, time {
  if t.lacks("debug", "auk_debug") { return }
  var c = start()
  let args = json.obj([
    ("path", json.of("examples/fib.auk")),
    ("breakpoints", json.of([json.of("examples/fib.auk:5")])),
    ("max_stops", json.of(2)),
  ])
  let (text, is_error) = c.call("auk_debug", args)
  t.check(!is_error, text)
  let r = parse(text.trim())
  let stops = r.get("stops").as_arr()
  t.check(stops.len() == 2, text)
  t.check(stops[0].get("fn").as_str() == some("fib.fib"), text)
  t.check(stops[0].at(["locals", "n"]).as_str() is some(_), text)
  t.check((r.get("note").as_str() else "").contains("max-stops"), text)
  // a missing file is an error result
  let (text, is_error) = c.call(
    "auk_debug",
    json.obj([("path", json.of("tests/fixtures/no_such.auk"))]),
  )
  t.check(is_error, text)
  close(&c)
}

fn holes_when_available() uses env, ffi, time {
  let has_holes = t
    .auk()
    .arg("help")
    .output().stdout
    .lines()
    .any(l => l.trim_start().starts_with("holes"))
  var c = start()
  let (text, is_error) = c.call("auk_holes", json.obj([("path", json.of("examples/hello.auk"))]))
  if has_holes {
    t.check(!is_error, text)
    t.check(json.parse(text.trim()) is ok(_), "not JSON: {text}")
  } else {
    assert is_error
    t.check(text.contains("not available in this build"), text)
  }
  close(&c)
}

fn closing_stdin_exits() uses env, ffi, time {
  var c = start()
  sys.close_stdin(&c.child)
  var exited = false
  for _ in 0..400 {
    time.sleep(25)
    // read what it writes meanwhile so it can't block on a full pipe
    let _ = sys.pump(&c.child, 0)
    if sys.try_wait(&c.child) {
      exited = true
      break
    }
  }
  t.check(exited, "auk mcp did not exit when stdin closed")
  assert cmd.wait(&c.child, 5000).code == some(0)
}

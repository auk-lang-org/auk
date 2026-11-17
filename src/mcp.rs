//! `duck mcp`: a Model Context Protocol server over stdio, so AI agents (Claude Code and other
//! MCP clients) get first-class Duck tools: the language reference, type-checking with fix-its,
//! running, testing, formatting, error explanations and typed holes.
//!
//! - **Framing**: newline-delimited JSON-RPC 2.0, one message per line (no `Content-Length`
//!   headers, unlike `duck lsp`). Nothing but protocol messages is written to stdout.
//! - **Handshake**: the initialize-based protocol (`initialize`, `notifications/initialized`,
//!   `ping`, `tools/list`, `tools/call`), revisions 2024-11-05 through 2025-11-25. A requested
//!   revision we know is echoed back; otherwise we answer with the newest one. Unknown methods
//!   (including the stateless era's `server/discover`) get -32601, which is what dual-era clients
//!   take as the cue to fall back to `initialize`.
//! - **Tools** run the `duck` binary itself (`current_exe`) as a subprocess with the matching CLI
//!   command and return its output, so the server stays decoupled from the compiler's internals
//!   and can never be wedged by a panic or an endless program. Subprocesses get a null stdin
//!   (they must not read the protocol stream), a timeout, and their own process group so a
//!   timed-out `run` kills the compiled program too.

use std::io::{self, BufRead, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread;
use std::time::{Duration, Instant};
use std::{env, fs};

use super::json::{self, Json, obj};

/// Protocol revisions we speak, newest first.
pub const PROTOCOL_VERSIONS: &[&str] = &["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];

/// Captured output per stream is cut off past this many bytes (agents' context is precious).
const MAX_OUTPUT: usize = 100_000;

const INSTRUCTIONS: &str = "Duck is a statically typed language compiled to native code. Call duck_spec first to \
learn the language, then use duck_check after every edit: its diagnostics carry error codes (explain them with \
duck_explain) and machine-applicable fixes.";

/// Serve on stdin/stdout until stdin closes. Returns the process exit code. Tool calls run on
/// their own threads (a long `duck_run` doesn't block `ping` or other calls); replies are written
/// whole, one per line, in completion order.
pub fn run() -> i32 {
    let output = Arc::new(Mutex::new(io::stdout()));
    let send = |out: &Mutex<io::Stdout>, msg: Json| {
        let mut w = out.lock().unwrap_or_else(|e| e.into_inner());
        let _ = writeln!(w, "{msg}").and_then(|()| w.flush());
    };
    let mut workers = Vec::new();
    for line in io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        match json::parse(&line) {
            Ok(msg) if msg.get("method").as_str() == Some("tools/call") => {
                let out = Arc::clone(&output);
                workers.push(thread::spawn(move || {
                    if let Some(r) = handle(&msg) {
                        send(&out, r);
                    }
                }));
            }
            Ok(msg) => {
                if let Some(r) = handle(&msg) {
                    send(&output, r);
                }
            }
            Err(e) => send(&output, error_reply(Json::Null, -32700, &format!("parse error: {e}"))),
        }
    }
    // stdin closed: finish the calls in flight, then exit
    for w in workers {
        let _ = w.join();
    }
    0
}

fn reply(id: Json, result: Json) -> Json {
    obj([("jsonrpc", "2.0".into()), ("id", id), ("result", result)])
}

fn error_reply(id: Json, code: i64, msg: &str) -> Json {
    obj([("jsonrpc", "2.0".into()), ("id", id), ("error", obj([("code", code.into()), ("message", msg.into())]))])
}

/// Handle one message; requests get a reply, notifications and responses don't.
pub fn handle(msg: &Json) -> Option<Json> {
    let Json::Obj(fields) = msg else {
        return Some(error_reply(Json::Null, -32600, "invalid request: expected a JSON-RPC object"));
    };
    let id = fields.iter().find(|(k, _)| k == "id").map(|(_, v)| v.clone());
    let Some(method) = msg.get("method").as_str() else {
        // a response from the client (we never send requests) or garbage
        return id.filter(|_| msg.get("result").is_null() && msg.get("error").is_null()).map(|id| error_reply(id, -32600, "invalid request: missing `method`"));
    };
    let Some(id) = id else {
        return None; // notifications: `notifications/initialized`, `notifications/cancelled`, ...
    };
    let params = msg.get("params");
    Some(match method {
        "initialize" => reply(id, initialize(params)),
        "ping" => reply(id, obj([])),
        "tools/list" => reply(id, obj([("tools", Json::Arr(tools()))])),
        "tools/call" => match call(params) {
            Ok(result) => reply(id, result),
            Err(e) => error_reply(id, -32602, &e),
        },
        _ => error_reply(id, -32601, &format!("method not found: {method}")),
    })
}

fn initialize(params: &Json) -> Json {
    let requested = params.get("protocolVersion").as_str().unwrap_or("");
    let version = PROTOCOL_VERSIONS.iter().find(|v| **v == requested).unwrap_or(&PROTOCOL_VERSIONS[0]);
    obj([
        ("protocolVersion", (*version).into()),
        ("capabilities", obj([("tools", obj([]))])),
        ("serverInfo", obj([("name", "duck".into()), ("version", env!("CARGO_PKG_VERSION").into())])),
        ("instructions", INSTRUCTIONS.into()),
    ])
}

// ---- tool definitions ----

fn prop(ty: &str, description: &str) -> Json {
    obj([("type", ty.into()), ("description", description.into())])
}

fn schema<const N: usize>(props: [(&str, Json); N], required: &[&str]) -> Json {
    obj([
        ("type", "object".into()),
        ("properties", obj(props)),
        ("required", Json::Arr(required.iter().map(|r| (*r).into()).collect())),
        ("additionalProperties", false.into()),
    ])
}

fn tool(name: &str, description: &str, input_schema: Json) -> Json {
    obj([("name", name.into()), ("description", description.into()), ("inputSchema", input_schema)])
}

const PATH_OR_SOURCE: &str = "Give exactly one of `path` or `source`.";

/// Every tool, with its JSON Schema input.
pub fn tools() -> Vec<Json> {
    let path = |what: &str| prop("string", &format!("Path to {what} (absolute, or relative to the server's working directory)."));
    let source = prop("string", "Duck source code to use instead of a file (checked as a standalone program in a temporary file).");
    let timeout = |default: u32| prop("number", &format!("Kill the process after this many seconds (default {default}, max 600)."));
    let trace = |what: &str| prop("boolean", what);
    vec![
        tool(
            "duck_spec",
            "The Duck language reference: syntax, types, effects, the standard library and idioms. Call this first, \
             before reading or writing any Duck code; Duck is not Rust, Go or Python and guessing syntax wastes turns.",
            schema([], &[]),
        ),
        tool(
            "duck_check",
            &format!(
                "Type-check Duck code without running it and return the diagnostics as JSON: \
                 {{file, ok, diagnostics: [{{code, severity, line, col, end_line, end_col, message, notes, fixes}}]}}. \
                 Each fix is an edit (1-based line/col range plus replacement `text`) that resolves the error; apply it \
                 when it matches your intent. Run duck_explain on any code you don't understand. A `path` is checked in \
                 its project context (the nearest quack.toml, its modules and dependencies). {PATH_OR_SOURCE} Safe: \
                 does not execute code."
            ),
            schema([("path", path("a .duck file")), ("source", source.clone())], &[]),
        ),
        tool(
            "duck_run",
            "Compile and RUN a Duck program (this executes code on the user's machine, with their permissions). \
             Returns JSON {exit_code, stdout, stderr, timed_out}, plus `trace` with `trace: true`; compile errors \
             appear in stderr with a non-zero exit code. The program gets no stdin. Prefer duck_check to find errors; \
             use this to see behaviour.",
            schema(
                [
                    ("path", path("the .duck file with `fn main`")),
                    ("args", obj([("type", "array".into()), ("items", obj([("type", "string".into())])), ("description", "Command-line arguments for the program.".into())])),
                    ("timeout_seconds", timeout(30)),
                    (
                        "trace",
                        trace(
                            "Record an execution trace: `trace` in the result is a list of events, {ev:\"call\", fn, loc, args, depth}, \
                             {ev:\"ret\", fn, value, depth}, {ev:\"err\", fn, error, depth}, {ev:\"peek\", loc, expr, value, depth}, \
                             {ev:\"panic\", msg, loc, depth}, ending with {ev:\"truncated\"} past 2,000 events. Values are shown \
                             as Duck prints them, cut to 200 characters. Use it to see what actually happened instead of guessing.",
                        ),
                    ),
                ],
                &["path"],
            ),
        ),
        tool(
            "duck_test",
            "Build and RUN the `test` blocks of a Duck file or project (this executes code on the user's machine). \
             Returns the test report (one line per test, then `N passed, M failed`) and the exit code; isError is true \
             when any test fails or the build fails. With `trace: true`, each FAIL is followed by the last events of that \
             test's execution trace (JSON lines: calls with their arguments, returns, errors, peeks, the panic).",
            schema(
                [
                    ("path", path("a .duck file, or a project directory (with quack.toml)")),
                    ("filter", prop("string", "Only run tests whose name contains this text.")),
                    ("timeout_seconds", timeout(120)),
                    ("trace", trace("Print the execution trace (the last events) of each failing test under its FAIL line.")),
                ],
                &["path"],
            ),
        ),
        tool(
            "duck_debug",
            "Debug a Duck program: RUN it (this executes code on the user's machine) and stop at each breakpoint \
             and at a panic, recording where it stopped, the local variables there (shown as Duck prints them) and \
             the call stack. Returns JSON {stops: [{reason, fn, file, line, msg?, locals: {name: value}, stack}], \
             exit_code, stdout, stderr, note?, errors?}. `reason` is breakpoint, panic or timeout (still running when \
             the time ran out: where it was, e.g. an endless loop). Use it to see the actual values instead of \
             guessing or adding prints; a breakpoint inside a loop stops on every iteration (see max_stops), or only \
             where its condition holds (`file:line if i == 99`).",
            schema(
                [
                    ("path", path("the .duck file with `fn main`")),
                    (
                        "breakpoints",
                        obj([
                            ("type", "array".into()),
                            ("items", obj([("type", "string".into())])),
                            ("description", "Where to stop: `file:line` (the next line with code) or a function name, optionally followed by ` if <Duck condition>` (e.g. `main.duck:12 if n > 3`).".into()),
                        ]),
                    ),
                    (
                        "print",
                        obj([
                            ("type", "array".into()),
                            ("items", obj([("type", "string".into())])),
                            ("description", "What to show at each stop instead of every local: names of locals, or Duck expressions evaluated there (`xs.len()`, `p.x * 2`, calls to the program's functions).".into()),
                        ]),
                    ),
                    ("catch", prop("string", "Stop on panics: `uncaught` (default), `all` (also inside `catch`) or `none`.")),
                    ("max_stops", prop("number", "End the program after this many stops (default 20).")),
                    ("args", obj([("type", "array".into()), ("items", obj([("type", "string".into())])), ("description", "Command-line arguments for the program.".into())])),
                    ("timeout_seconds", timeout(30)),
                ],
                &["path"],
            ),
        ),
        tool(
            "duck_fmt",
            &format!(
                "Format Duck code in the canonical style. With `source`, returns the formatted source and changes no \
                 files. With `path`, REWRITES that file in place and returns its new contents. {PATH_OR_SOURCE}"
            ),
            schema([("path", path("a .duck file")), ("source", source)], &[]),
        ),
        tool(
            "duck_explain",
            "Explain a Duck error code such as E0200: what went wrong, a wrong and a fixed example, and common causes. \
             Omit `code` to list every code with a one-line summary.",
            schema([("code", prop("string", "An error code like `E0200`."))], &[]),
        ),
        tool(
            "duck_holes",
            "List the typed holes (`??`) in a Duck file as JSON: where each hole is, the type it must have and the \
             names in scope that could fill it. Write `??` where you don't know the code yet, then use this to see \
             what fits. Safe: does not execute code.",
            schema([("path", path("a .duck file"))], &["path"]),
        ),
    ]
}

// ---- tool calls ----

/// What a tool hands back: text, and whether it's an error the agent should react to.
struct Outcome {
    text: String,
    is_error: bool,
}

fn ok(text: impl Into<String>) -> Result<Outcome, String> {
    Ok(Outcome { text: text.into(), is_error: false })
}

/// `tools/call`. `Err` is a protocol error (unknown tool, malformed params); problems running a
/// tool (bad arguments, missing files, failed commands) are results with `isError: true`, so the
/// agent sees them and can correct itself.
fn call(params: &Json) -> Result<Json, String> {
    let name = params.get("name").as_str().ok_or("tools/call: missing tool `name`")?;
    let args = params.get("arguments");
    if !(args.is_null() || matches!(args, Json::Obj(_))) {
        return Err("tools/call: `arguments` must be an object".into());
    }
    let result = match name {
        "duck_spec" => run_tool(&["spec"], Duration::from_secs(60)).map(|o| Outcome { is_error: !o.success(), text: o.stdout }),
        "duck_check" => check(args),
        "duck_run" => run_program(args),
        "duck_test" => test(args),
        "duck_debug" => debug(args),
        "duck_fmt" => format(args),
        "duck_explain" => explain(args),
        "duck_holes" => holes(args),
        _ => return Err(format!("unknown tool: {name}")),
    };
    let out = result.unwrap_or_else(|e| Outcome { text: e, is_error: true });
    Ok(obj([
        ("content", Json::Arr(vec![obj([("type", "text".into()), ("text", out.text.into())])])),
        ("isError", out.is_error.into()),
    ]))
}

fn str_arg<'a>(args: &'a Json, key: &str) -> Result<Option<&'a str>, String> {
    match args.get(key) {
        Json::Null => Ok(None),
        Json::Str(s) => Ok(Some(s)),
        _ => Err(format!("argument `{key}` must be a string")),
    }
}

fn path_arg(args: &Json, key: &str) -> Result<String, String> {
    let p = str_arg(args, key)?.ok_or_else(|| format!("missing required argument `{key}`"))?;
    if !Path::new(p).exists() {
        return Err(format!("no such file or directory: {p} (the server's working directory is {})", cwd()));
    }
    Ok(p.to_string())
}

fn cwd() -> String {
    env::current_dir().map(|d| d.display().to_string()).unwrap_or_else(|_| "unknown".into())
}

/// Exactly one of `path` / `source`.
enum Input {
    Path(String),
    Source(String),
}

fn path_or_source(args: &Json) -> Result<Input, String> {
    match (str_arg(args, "path")?, str_arg(args, "source")?) {
        (Some(_), None) => path_arg(args, "path").map(Input::Path),
        (None, Some(s)) => Ok(Input::Source(s.to_string())),
        _ => Err(format!("{PATH_OR_SOURCE} (got {})", if args.get("path").is_null() { "neither" } else { "both" })),
    }
}

fn bool_arg(args: &Json, key: &str) -> Result<bool, String> {
    match args.get(key) {
        Json::Null => Ok(false),
        Json::Bool(b) => Ok(*b),
        _ => Err(format!("argument `{key}` must be a boolean")),
    }
}

/// The most trace events `duck_run` returns (agents' context is precious).
const MCP_TRACE_LIMIT: &str = "2000";

fn timeout_arg(args: &Json, default: u64) -> Result<Duration, String> {
    match args.get("timeout_seconds") {
        Json::Null => Ok(Duration::from_secs(default)),
        Json::Num(n) if *n > 0.0 => Ok(Duration::from_secs_f64(n.min(600.0))),
        _ => Err("argument `timeout_seconds` must be a positive number".into()),
    }
}

/// A source string written to a private temporary directory, removed on drop.
struct TempSource {
    dir: PathBuf,
    file: PathBuf,
}

impl TempSource {
    fn new(src: &str) -> Result<TempSource, String> {
        static N: AtomicU32 = AtomicU32::new(0);
        let n = N.fetch_add(1, Ordering::Relaxed);
        let dir = env::temp_dir().join(format!("duck-mcp-{}-{n}", std::process::id()));
        let file = dir.join("main.duck");
        fs::create_dir_all(&dir).and_then(|()| fs::write(&file, src)).map_err(|e| format!("cannot write a temporary file: {e}"))?;
        Ok(TempSource { dir, file })
    }

    fn path(&self) -> &str {
        self.file.to_str().unwrap_or("main.duck")
    }
}

impl Drop for TempSource {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn check(args: &Json) -> Result<Outcome, String> {
    let input = path_or_source(args)?;
    let temp = match &input {
        Input::Source(s) => Some(TempSource::new(s)?),
        Input::Path(_) => None,
    };
    let file = match (&input, &temp) {
        (Input::Path(p), _) => p.as_str(),
        (_, Some(t)) => t.path(),
        _ => unreachable!(),
    };
    let out = run_tool(&["check", file, "--json"], Duration::from_secs(60))?;
    if json::parse(out.stdout.trim()).is_err() {
        return Err(out.report());
    }
    let mut text = out.stdout.trim().to_string();
    if let Some(t) = &temp {
        text = text.replace(t.path(), "<source>");
    }
    ok(text)
}

fn run_program(args: &Json) -> Result<Outcome, String> {
    let path = path_arg(args, "path")?;
    let timeout = timeout_arg(args, 30)?;
    // a traced run writes its events to a private temporary file, returned as `trace`
    let trace = if bool_arg(args, "trace")? { Some(TempSource::new("")?) } else { None };
    let trace_file = trace.as_ref().map(|t| t.dir.join("trace.jsonl"));
    let mut argv = vec!["run".to_string()];
    if let Some(f) = &trace_file {
        argv.push(format!("--trace={}", f.display()));
        argv.extend(["--trace-limit".to_string(), MCP_TRACE_LIMIT.to_string()]);
    }
    argv.push(path);
    match args.get("args") {
        Json::Null => {}
        Json::Arr(xs) => {
            for x in xs {
                argv.push(x.as_str().ok_or("argument `args` must be an array of strings")?.to_string());
            }
        }
        _ => return Err("argument `args` must be an array of strings".into()),
    }
    let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
    let out = run_tool(&argv, timeout)?;
    let code = out.status.and_then(|s| s.code()).map_or(Json::Null, |c| i64::from(c).into());
    let mut fields = vec![
        ("exit_code", code),
        ("stdout", out.stdout.clone().into()),
        ("stderr", out.stderr.clone().into()),
        ("timed_out", out.timed_out.into()),
    ];
    if let Some(f) = &trace_file {
        let events = fs::read_to_string(f).unwrap_or_default();
        let events: Vec<Json> = events.lines().map(|l| json::parse(l).unwrap_or_else(|_| l.to_string().into())).collect();
        fields.push(("trace", Json::Arr(events)));
    }
    let text = Json::Obj(fields.into_iter().map(|(k, v)| (k.to_string(), v)).collect());
    Ok(Outcome { text: text.to_string(), is_error: !out.success() })
}

fn str_list(args: &Json, key: &str) -> Result<Vec<String>, String> {
    match args.get(key) {
        Json::Null => Ok(Vec::new()),
        Json::Arr(xs) => xs.iter().map(|x| x.as_str().map(String::from).ok_or(format!("argument `{key}` must be an array of strings"))).collect(),
        _ => Err(format!("argument `{key}` must be an array of strings")),
    }
}

fn debug(args: &Json) -> Result<Outcome, String> {
    let path = path_arg(args, "path")?;
    let timeout = timeout_arg(args, 30)?;
    let mut argv: Vec<String> = vec!["debug".into(), "--json".into()];
    for b in str_list(args, "breakpoints")? {
        argv.extend(["--break".into(), b]);
    }
    let print = str_list(args, "print")?;
    if !print.is_empty() {
        argv.extend(["--print".into(), print.join(",")]);
    }
    if let Some(c) = str_arg(args, "catch")? {
        argv.extend(["--catch".into(), c.to_string()]);
    }
    match args.get("max_stops") {
        Json::Null => {}
        Json::Num(n) if *n >= 1.0 => argv.extend(["--max-stops".into(), (*n as u64).to_string()]),
        _ => return Err("argument `max_stops` must be a positive number".into()),
    }
    // the debugger reports where a program still running at the timeout is, then ends it
    argv.extend(["--timeout".into(), format!("{}", timeout.as_secs_f64())]);
    argv.push(path);
    argv.extend(str_list(args, "args")?);
    let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
    let out = run_tool(&argv, timeout + Duration::from_secs(30))?;
    let report = out.stdout.trim();
    // a report, or (the program didn't compile) the compiler's errors
    match json::parse(report) {
        Ok(j) if j.get("error").is_null() => ok(report),
        _ => Err(out.report()),
    }
}

fn test(args: &Json) -> Result<Outcome, String> {
    let path = path_arg(args, "path")?;
    let timeout = timeout_arg(args, 120)?;
    let mut argv = vec!["test"];
    if bool_arg(args, "trace")? {
        argv.push("--trace=json");
    }
    argv.push(path.as_str());
    if let Some(f) = str_arg(args, "filter")? {
        argv.push(f);
    }
    let out = run_tool(&argv, timeout)?;
    Ok(Outcome { is_error: !out.success(), text: out.report() })
}

fn format(args: &Json) -> Result<Outcome, String> {
    match path_or_source(args)? {
        Input::Source(src) => {
            let out = run_tool_stdin(&["fmt", "-"], Some(&src), Duration::from_secs(60))?;
            if out.success() { ok(out.stdout) } else { Err(out.report().replace("<stdin>", "<source>")) }
        }
        Input::Path(p) => {
            let out = run_tool(&["fmt", &p], Duration::from_secs(60))?;
            if !out.success() {
                return Err(out.report());
            }
            if Path::new(&p).is_file() {
                fs::read_to_string(&p).map_err(|e| format!("cannot read {p}: {e}")).and_then(ok)
            } else {
                ok(format!("formatted every .duck file under {p}\n{}", out.stdout))
            }
        }
    }
}

fn explain(args: &Json) -> Result<Outcome, String> {
    let out = match str_arg(args, "code")? {
        Some(code) => run_tool(&["explain", code], Duration::from_secs(60))?,
        None => run_tool(&["explain"], Duration::from_secs(60))?,
    };
    if out.success() { ok(out.stdout) } else { Err(out.report()) }
}

fn holes(args: &Json) -> Result<Outcome, String> {
    let path = path_arg(args, "path")?;
    // `duck holes` is newer than this server: find it (and whether it takes --json) in the usage
    let usage = run_tool(&["help"], Duration::from_secs(60))?.stdout;
    let Some(line) = usage.lines().find(|l| l.trim_start().starts_with("holes")) else {
        return Err("duck_holes is not available in this build of duck (there is no `duck holes` command); \
                    rebuild duck from a newer source"
            .into());
    };
    let mut argv = vec!["holes", path.as_str()];
    if line.contains("--json") {
        argv.push("--json");
    }
    let out = run_tool(&argv, Duration::from_secs(60))?;
    if out.stdout.trim().is_empty() || !out.status.is_some_and(|s| s.code().is_some()) || out.timed_out {
        return Err(out.report());
    }
    ok(out.stdout)
}

// ---- subprocesses ----

struct Output {
    /// `None` when the process was killed on timeout.
    status: Option<ExitStatus>,
    stdout: String,
    stderr: String,
    timed_out: bool,
}

impl Output {
    fn success(&self) -> bool {
        self.status.is_some_and(|s| s.success())
    }

    /// Everything a human would have seen, for error results and reports.
    fn report(&self) -> String {
        let mut s = self.stdout.clone();
        if !self.stderr.is_empty() {
            if !s.is_empty() && !s.ends_with('\n') {
                s.push('\n');
            }
            s.push_str(&self.stderr);
        }
        if self.timed_out {
            s.push_str("\n(timed out: the process was killed)");
        } else if let Some(code) = self.status.and_then(|s| s.code()).filter(|c| *c != 0) {
            if !s.is_empty() && !s.ends_with('\n') {
                s.push('\n');
            }
            s.push_str(&format!("(exit code {code})"));
        }
        s
    }
}

fn run_tool(args: &[&str], timeout: Duration) -> Result<Output, String> {
    run_tool_stdin(args, None, timeout)
}

/// Run `duck <args>` with optional stdin text, capturing output, killed (with everything it
/// spawned) after `timeout`.
fn run_tool_stdin(args: &[&str], input: Option<&str>, timeout: Duration) -> Result<Output, String> {
    let exe = env::current_exe().map_err(|e| format!("cannot find the duck executable: {e}"))?;
    let mut cmd = Command::new(exe);
    cmd.args(args)
        .stdin(if input.is_some() { Stdio::piped() } else { Stdio::null() })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(unix)]
    std::os::unix::process::CommandExt::process_group(&mut cmd, 0);
    let mut child = cmd.spawn().map_err(|e| format!("cannot run duck {}: {e}", args.join(" ")))?;
    if let (Some(text), Some(mut w)) = (input, child.stdin.take()) {
        let text = text.to_string();
        thread::spawn(move || {
            let _ = w.write_all(text.as_bytes());
        });
    }
    let (tx, rx) = mpsc::channel();
    for (i, stream) in [child.stdout.take().map(|s| Box::new(s) as Box<dyn Read + Send>), child.stderr.take().map(|s| Box::new(s) as Box<dyn Read + Send>)]
        .into_iter()
        .enumerate()
    {
        let tx = tx.clone();
        thread::spawn(move || {
            let mut buf = Vec::new();
            if let Some(mut s) = stream {
                let _ = s.read_to_end(&mut buf);
            }
            let _ = tx.send((i, buf));
        });
    }
    drop(tx);
    let start = Instant::now();
    let (status, timed_out) = loop {
        match child.try_wait() {
            Ok(Some(s)) => break (Some(s), false),
            Ok(None) if start.elapsed() >= timeout => {
                kill_tree(&mut child);
                break (None, true);
            }
            Ok(None) => thread::sleep(Duration::from_millis(10)),
            Err(e) => return Err(format!("waiting for duck: {e}")),
        }
    };
    // the pipes close when the last writer (maybe a grandchild) exits; don't wait forever for it
    let mut bufs = [Vec::new(), Vec::new()];
    let deadline = Instant::now() + Duration::from_secs(2);
    for _ in 0..2 {
        match rx.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
            Ok((i, b)) => bufs[i] = b,
            Err(_) => break,
        }
    }
    let [out, err] = bufs;
    Ok(Output { status, stdout: text(out), stderr: text(err), timed_out })
}

fn text(mut bytes: Vec<u8>) -> String {
    let cut = bytes.len() > MAX_OUTPUT;
    bytes.truncate(MAX_OUTPUT);
    let mut s = String::from_utf8_lossy(&bytes).into_owned();
    if cut {
        s.push_str("\n... (output truncated)");
    }
    s
}

#[cfg(unix)]
fn kill_tree(child: &mut std::process::Child) {
    unsafe extern "C" {
        fn kill(pid: i32, sig: i32) -> i32;
    }
    if let Ok(pid) = i32::try_from(child.id()) {
        // SAFETY: kill(2) with a negative pid signals the process group we created at spawn
        // (`process_group(0)`: the child is its leader); 9 is SIGKILL.
        unsafe {
            kill(-pid, 9);
        }
    }
    let _ = child.kill();
    let _ = child.wait();
}

#[cfg(not(unix))]
fn kill_tree(child: &mut std::process::Child) {
    let _ = child.kill();
    let _ = child.wait();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn req(text: &str) -> Json {
        handle(&json::parse(text).unwrap()).unwrap()
    }

    #[test]
    fn handshake_and_errors() {
        let r = req(r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#);
        assert_eq!(r.at(&["result", "protocolVersion"]).as_str(), Some("2025-06-18"));
        let r = req(r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#);
        assert_eq!(r.at(&["result", "protocolVersion"]).as_str(), Some(PROTOCOL_VERSIONS[0]));
        assert!(handle(&json::parse(r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#).unwrap()).is_none());
        assert!(handle(&json::parse(r#"{"jsonrpc":"2.0","id":5,"result":{}}"#).unwrap()).is_none());
        assert_eq!(req(r#"{"jsonrpc":"2.0","id":2,"method":"nope"}"#).at(&["error", "code"]).as_i64(), Some(-32601));
        let r = req(r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"nope"}}"#);
        assert_eq!(r.at(&["error", "code"]).as_i64(), Some(-32602));
        let r = req(r#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"duck_check","arguments":{}}}"#);
        assert_eq!(r.at(&["result", "isError"]), &Json::Bool(true));
    }
}

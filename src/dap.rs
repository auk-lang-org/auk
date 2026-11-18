//! `auk dap`: a Debug Adapter Protocol server on stdin/stdout, for VS Code and other editors.
//!
//! It launches the program with `auk run --debug` (src/debug.rs `launch`, output streamed as
//! `output` events) and translates DAP requests into debug engine commands
//! (runtime/src/dbg.rs). Supported: launch (program, args, cwd, stopOnEntry), line and function
//! breakpoints, panics as exception breakpoints (`uncaught`, `all`), threads, stack traces,
//! locals with expandable parts (struct fields, variants, elements, entries), continue / next /
//! stepIn / stepOut / pause, `evaluate` of a local or a path into it (`p.x`, `xs.2`), terminate.
//!
//! Variable references and frame ids are handles that last until the program resumes.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};

use super::debug::{Capture, In, Session, launch};
use super::json::{self, Json, obj};

/// What a handle stands for.
#[derive(Clone)]
enum Handle {
    /// Frame `frame` of thread `thread`.
    Frame { thread: i64, frame: i64 },
    /// A part of a local: the path of part indexes from the local `name`.
    Kids { thread: i64, frame: i64, name: String, path: Vec<u32> },
}

struct Dap {
    out: std::io::Stdout,
    seq: i64,
    s: Option<Session>,
    handles: Vec<Handle>,
    /// Engine breakpoint ids per source path (DAP sets a whole file's at once), and the
    /// function breakpoints'.
    line_bps: HashMap<String, Vec<i64>>,
    fn_bps: Vec<i64>,
    /// The temporary breakpoint of `stopOnEntry`.
    entry_bp: Option<i64>,
    stopped: bool,
    exited: bool,
}

/// Read one DAP message (`Content-Length` framing); None at the end of input.
fn read_msg(r: &mut impl BufRead) -> Option<Json> {
    let mut len = None;
    loop {
        let mut line = String::new();
        if r.read_line(&mut line).ok()? == 0 {
            return None;
        }
        let line = line.trim_end();
        if line.is_empty() {
            break;
        }
        if let Some(v) = line.strip_prefix("Content-Length:") {
            len = v.trim().parse::<usize>().ok();
        }
    }
    let mut body = vec![0u8; len?];
    r.read_exact(&mut body).ok()?;
    json::parse(std::str::from_utf8(&body).ok()?).ok()
}

pub fn run() -> i32 {
    let mut rd = BufReader::new(std::io::stdin());
    let mut d = Dap { out: std::io::stdout(), seq: 0, s: None, handles: Vec::new(), line_bps: HashMap::new(), fn_bps: Vec::new(), entry_bp: None, stopped: false, exited: false };
    // until `launch`: requests are read here; then a reader thread feeds the session's queue
    while d.s.is_none() {
        let Some(req) = read_msg(&mut rd) else { return 0 };
        let cmd = req.get("command").as_str().unwrap_or("").to_string();
        match cmd.as_str() {
            "initialize" => {
                let filters = Json::Arr(vec![
                    obj([("filter", "uncaught".into()), ("label", "Uncaught panics".into()), ("default", true.into())]),
                    obj([("filter", "all".into()), ("label", "All panics (also inside `catch`)".into()), ("default", false.into())]),
                ]);
                let caps = obj([
                    ("supportsConfigurationDoneRequest", true.into()),
                    ("supportsFunctionBreakpoints", true.into()),
                    ("supportsTerminateRequest", true.into()),
                    ("supportsEvaluateForHovers", true.into()),
                    ("supportsConditionalBreakpoints", true.into()),
                    ("supportsSetVariable", true.into()),
                    ("exceptionBreakpointFilters", filters),
                ]);
                d.respond(&req, true, Some(caps), None);
            }
            "launch" => {
                let a = req.get("arguments");
                let Some(program) = a.get("program").as_str() else {
                    d.respond(&req, false, None, Some("launch: `program` (a .auk file) is required"));
                    continue;
                };
                if let Some(cwd) = a.get("cwd").as_str()
                    && let Err(e) = std::env::set_current_dir(cwd)
                {
                    d.respond(&req, false, None, Some(&format!("launch: cwd {cwd}: {e}")));
                    continue;
                }
                let args: Vec<String> = a.get("args").as_arr().iter().filter_map(|x| x.as_str().map(String::from)).collect();
                match launch(program, &args, Capture::Stream) {
                    Ok(s) => {
                        d.s = Some(s);
                        if a.get("stopOnEntry") == &Json::Bool(true) {
                            let r = d.cmd("break main");
                            d.entry_bp = r.get("id").as_i64();
                        }
                        d.respond(&req, true, None, None);
                        d.event("initialized", None);
                    }
                    Err((code, text)) => {
                        d.output("stderr", &text);
                        d.respond(&req, false, None, Some(&format!("the program did not start (exit code {code}): see the Debug Console")));
                        d.event("terminated", None);
                    }
                }
            }
            "disconnect" | "terminate" => {
                d.respond(&req, true, None, None);
                return 0;
            }
            _ => d.respond(&req, false, None, Some(&format!("`{cmd}` before launch"))),
        }
    }
    let tx = d.s.as_ref().expect("session").tx.clone();
    std::thread::spawn(move || {
        while let Some(m) = read_msg(&mut rd) {
            if tx.send(In::Req(m)).is_err() {
                return;
            }
        }
        let _ = tx.send(In::Eof);
    });
    loop {
        let input = d.s.as_mut().expect("session").next();
        match input {
            In::Req(req) => {
                if !d.request(&req) {
                    break;
                }
            }
            In::Ev(e) => d.engine_event(&e),
            In::Out(is_err, text) => d.output(if is_err { "stderr" } else { "stdout" }, &text),
            In::Closed => d.ended(),
            In::Eof => {
                d.kill();
                break;
            }
            In::Line(_) | In::Interrupt => {}
        }
    }
    0
}

impl Dap {
    fn send(&mut self, mut m: Json) {
        self.seq += 1;
        if let Json::Obj(fs) = &mut m {
            fs.insert(0, ("seq".into(), self.seq.into()));
        }
        let body = m.to_string();
        let _ = write!(self.out, "Content-Length: {}\r\n\r\n{body}", body.len());
        let _ = self.out.flush();
    }

    fn respond(&mut self, req: &Json, ok: bool, body: Option<Json>, msg: Option<&str>) {
        let mut fs: Vec<(String, Json)> = vec![
            ("type".into(), "response".into()),
            ("request_seq".into(), req.get("seq").clone()),
            ("success".into(), ok.into()),
            ("command".into(), req.get("command").clone()),
        ];
        if let Some(m) = msg {
            fs.push(("message".into(), m.into()));
        }
        if let Some(b) = body {
            fs.push(("body".into(), b));
        }
        self.send(Json::Obj(fs));
    }

    fn event(&mut self, name: &str, body: Option<Json>) {
        let mut fs: Vec<(String, Json)> = vec![("type".into(), "event".into()), ("event".into(), name.into())];
        if let Some(b) = body {
            fs.push(("body".into(), b));
        }
        self.send(Json::Obj(fs));
    }

    fn output(&mut self, category: &str, text: &str) {
        if !text.is_empty() {
            self.event("output", Some(obj([("category", category.into()), ("output", text.into())])));
        }
    }

    fn cmd(&mut self, c: &str) -> Json {
        match self.s.as_mut() {
            Some(s) => s.cmd(c),
            None => Json::Null,
        }
    }

    fn handle(&mut self, h: Handle) -> i64 {
        self.handles.push(h);
        self.handles.len() as i64
    }

    fn resumed(&mut self) {
        self.stopped = false;
        self.handles.clear();
    }

    fn kill(&mut self) {
        if !self.exited {
            self.cmd("kill");
            if let Some(s) = self.s.as_mut() {
                let _ = s.wait();
            }
        }
    }

    /// The program ended (its connection closed).
    fn ended(&mut self) {
        if self.exited {
            return;
        }
        self.exited = true;
        let code = self.s.as_mut().map_or(0, |s| s.wait());
        self.event("exited", Some(obj([("exitCode", i64::from(code).into())])));
        self.event("terminated", None);
    }

    fn engine_event(&mut self, e: &Json) {
        if e.get("ev").as_str() != Some("stopped") {
            return;
        }
        self.stopped = true;
        self.handles.clear();
        let thread = e.get("thread").as_i64().unwrap_or(1);
        let mut reason = e.get("reason").as_str().unwrap_or("pause").to_string();
        let mut fs: Vec<(String, Json)> = vec![("threadId".into(), thread.into()), ("allThreadsStopped".into(), true.into())];
        let hit: Vec<i64> = e.get("bps").as_arr().iter().filter_map(|b| b.as_i64()).collect();
        if let Some(id) = self.entry_bp
            && hit.contains(&id)
        {
            self.cmd(&format!("delete {id}"));
            self.entry_bp = None;
            reason = "entry".into();
        }
        match reason.as_str() {
            "panic" => {
                reason = "exception".into();
                fs.push(("description".into(), "Panic".into()));
                fs.push(("text".into(), e.get("msg").clone()));
            }
            "breakpoint" => {
                fs.push(("hitBreakpointIds".into(), Json::Arr(hit.into_iter().map(Json::from).collect())));
                if let Some(c) = e.get("cond_error").as_str() {
                    fs.push(("text".into(), format!("the breakpoint's condition failed: {c}").into()));
                    self.output("console", &format!("the breakpoint's condition failed: {c}\n"));
                }
            }
            _ => {}
        }
        fs.insert(0, ("reason".into(), reason.into()));
        self.event("stopped", Some(Json::Obj(fs)));
    }

    /// Serve one request; false to end.
    fn request(&mut self, req: &Json) -> bool {
        let a = req.get("arguments");
        let cmd = req.get("command").as_str().unwrap_or("");
        match cmd {
            "setBreakpoints" => {
                let path = a.at(&["source", "path"]).as_str().unwrap_or("").to_string();
                for id in self.line_bps.remove(&path).unwrap_or_default() {
                    self.cmd(&format!("delete {id}"));
                }
                let mut ids = Vec::new();
                let mut out = Vec::new();
                for b in a.get("breakpoints").as_arr() {
                    let line = b.get("line").as_i64().unwrap_or(0);
                    let cond = b.get("condition").as_str().map(str::trim).filter(|c| !c.is_empty()).map(|c| format!(" if {c}")).unwrap_or_default();
                    let r = self.cmd(&format!("break {path}:{line}{cond}"));
                    out.push(self.bp_result(&r, line));
                    if let Some(id) = r.get("id").as_i64() {
                        ids.push(id);
                    }
                }
                self.line_bps.insert(path, ids);
                self.respond(req, true, Some(obj([("breakpoints", Json::Arr(out))])), None);
            }
            "setFunctionBreakpoints" => {
                for id in std::mem::take(&mut self.fn_bps) {
                    self.cmd(&format!("delete {id}"));
                }
                let mut out = Vec::new();
                for b in a.get("breakpoints").as_arr() {
                    let name = b.get("name").as_str().unwrap_or("");
                    let cond = b.get("condition").as_str().map(str::trim).filter(|c| !c.is_empty()).map(|c| format!(" if {c}")).unwrap_or_default();
                    let r = self.cmd(&format!("break {name}{cond}"));
                    out.push(self.bp_result(&r, 0));
                    if let Some(id) = r.get("id").as_i64() {
                        self.fn_bps.push(id);
                    }
                }
                self.respond(req, true, Some(obj([("breakpoints", Json::Arr(out))])), None);
            }
            "setExceptionBreakpoints" => {
                let fs: Vec<&str> = a.get("filters").as_arr().iter().filter_map(|f| f.as_str()).collect();
                let mode = if fs.contains(&"all") {
                    "all"
                } else if fs.contains(&"uncaught") {
                    "uncaught"
                } else {
                    "none"
                };
                self.cmd(&format!("catch {mode}"));
                self.respond(req, true, None, None);
            }
            "configurationDone" => {
                self.cmd("run");
                self.respond(req, true, None, None);
            }
            "threads" => {
                let mut ts = Vec::new();
                if self.stopped {
                    let r = self.cmd("threads");
                    for t in r.get("threads").as_arr() {
                        let id = t.get("id").as_i64().unwrap_or(0);
                        let name = if id == 1 { "main".to_string() } else { format!("task {id}") };
                        ts.push(obj([("id", id.into()), ("name", name.into())]));
                    }
                }
                if ts.is_empty() {
                    ts.push(obj([("id", 1i64.into()), ("name", "main".into())]));
                }
                self.respond(req, true, Some(obj([("threads", Json::Arr(ts))])), None);
            }
            "stackTrace" => {
                let thread = a.get("threadId").as_i64().unwrap_or(1);
                let r = self.cmd(&format!("stack {thread}"));
                let start = a.get("startFrame").as_i64().unwrap_or(0).max(0) as usize;
                let levels = a.get("levels").as_i64().filter(|&n| n > 0).map_or(usize::MAX, |n| n as usize);
                let all = r.get("frames").as_arr().to_vec();
                let mut frames = Vec::new();
                for (i, f) in all.iter().enumerate().skip(start).take(levels) {
                    let id = self.handle(Handle::Frame { thread, frame: i as i64 });
                    let mut fs: Vec<(String, Json)> = vec![
                        ("id".into(), id.into()),
                        ("name".into(), f.get("fn").clone()),
                        ("line".into(), f.get("line").as_i64().unwrap_or(0).into()),
                        ("column".into(), f.get("col").as_i64().unwrap_or(1).into()),
                    ];
                    if let Some(p) = f.get("file").as_str() {
                        let name = std::path::Path::new(p).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                        fs.push(("source".into(), obj([("name", name.into()), ("path", p.into())])));
                    }
                    frames.push(Json::Obj(fs));
                }
                self.respond(req, true, Some(obj([("stackFrames", Json::Arr(frames)), ("totalFrames", (all.len() as i64).into())])), None);
            }
            "scopes" => {
                let id = a.get("frameId").as_i64().unwrap_or(0);
                let scopes = match self.handles.get((id - 1).max(0) as usize).cloned() {
                    Some(h @ Handle::Frame { .. }) => {
                        let r = self.handle(h);
                        vec![obj([("name", "Locals".into()), ("presentationHint", "locals".into()), ("variablesReference", r.into()), ("expensive", false.into())])]
                    }
                    _ => Vec::new(),
                };
                self.respond(req, true, Some(obj([("scopes", Json::Arr(scopes))])), None);
            }
            "variables" => {
                let r = a.get("variablesReference").as_i64().unwrap_or(0);
                let vars = match self.handles.get((r - 1).max(0) as usize).cloned() {
                    Some(Handle::Frame { thread, frame }) => {
                        let v = self.cmd(&format!("vars {frame} {thread}"));
                        let items = v.get("vars").as_arr().to_vec();
                        items.iter().map(|x| self.variable(x, thread, frame, x.get("name").as_str().unwrap_or(""), &[])).collect()
                    }
                    Some(Handle::Kids { thread, frame, name, path }) => {
                        let ps: Vec<String> = path.iter().map(|p| p.to_string()).collect();
                        let v = self.cmd(&format!("kids {frame} {thread} {name} {}", ps.join(" ")));
                        let items = v.get("kids").as_arr().to_vec();
                        let mut out: Vec<Json> = items
                            .iter()
                            .enumerate()
                            .map(|(i, x)| {
                                let mut p = path.clone();
                                p.push(i as u32);
                                self.variable(x, thread, frame, &name, &p)
                            })
                            .collect();
                        if let Some(n) = v.get("more").as_i64() {
                            out.push(obj([("name", "…".into()), ("value", format!("{n} more").into()), ("variablesReference", 0i64.into())]));
                        }
                        out
                    }
                    None => Vec::new(),
                };
                self.respond(req, true, Some(obj([("variables", Json::Arr(vars))])), None);
            }
            "setVariable" => {
                // a local of a frame: `name = value`, evaluated there
                let r = a.get("variablesReference").as_i64().unwrap_or(0);
                let (name, value) = (a.get("name").as_str().unwrap_or(""), a.get("value").as_str().unwrap_or(""));
                let res = match self.handles.get((r - 1).max(0) as usize).cloned() {
                    Some(Handle::Frame { thread, frame }) => {
                        let set = self.cmd(&format!("eval {frame} {thread} {name} = ({value})"));
                        if set.get("ev").as_str() == Some("value") {
                            let v = self.cmd(&format!("eval {frame} {thread} {name}"));
                            Ok(obj([("value", v.get("value").clone()), ("type", v.get("type").clone())]))
                        } else {
                            Err(set.get("msg").as_str().unwrap_or("can't set it").to_string())
                        }
                    }
                    _ => Err("only a local of a frame can be set".to_string()),
                };
                match res {
                    Ok(b) => self.respond(req, true, Some(b), None),
                    Err(e) => self.respond(req, false, None, Some(&e)),
                }
            }
            "evaluate" => match self.evaluate(a) {
                Ok(b) => self.respond(req, true, Some(b), None),
                Err(e) => self.respond(req, false, None, Some(&e)),
            },
            "continue" | "next" | "stepIn" | "stepOut" => {
                let c = match cmd {
                    "continue" => "continue",
                    "next" => "next",
                    "stepIn" => "step",
                    _ => "finish",
                };
                let r = self.cmd(c);
                self.resumed();
                let ok = r.get("ev").as_str() == Some("ok");
                let body = (cmd == "continue").then(|| obj([("allThreadsContinued", true.into())]));
                self.respond(req, ok, body, if ok { None } else { r.get("msg").as_str() });
            }
            "pause" => {
                self.cmd("pause");
                self.respond(req, true, None, None);
            }
            "disconnect" | "terminate" => {
                self.kill();
                self.respond(req, true, None, None);
                if !self.exited {
                    self.exited = true;
                    self.event("terminated", None);
                }
                // `terminate` is followed by a `disconnect`
                return cmd != "disconnect";
            }
            _ => self.respond(req, false, None, Some(&format!("`{cmd}` is not supported"))),
        }
        true
    }

    fn bp_result(&self, r: &Json, line: i64) -> Json {
        match r.get("id").as_i64() {
            Some(id) => obj([("id", id.into()), ("verified", true.into()), ("line", r.get("line").as_i64().unwrap_or(line).into())]),
            None => obj([("verified", false.into()), ("message", r.get("msg").as_str().unwrap_or("no code there").into())]),
        }
    }

    /// A DAP variable from an engine item; parts get a handle.
    fn variable(&mut self, x: &Json, thread: i64, frame: i64, name: &str, path: &[u32]) -> Json {
        let r = if x.get("kids") == &Json::Bool(true) { self.handle(Handle::Kids { thread, frame, name: name.to_string(), path: path.to_vec() }) } else { 0 };
        obj([("name", x.get("name").clone()), ("value", x.get("value").clone()), ("type", x.get("type").clone()), ("variablesReference", r.into())])
    }

    /// A local or a path into it (expandable), else any Auk expression, evaluated in the frame
    /// (an assignment `x = 5` changes a `var` local).
    fn evaluate(&mut self, a: &Json) -> Result<Json, String> {
        if !self.stopped {
            return Err("the program is running".into());
        }
        let path_err = match self.eval_path(a) {
            Ok(j) => return Ok(j),
            Err(e) => e,
        };
        let (thread, frame) = match self.handles.get((a.get("frameId").as_i64().unwrap_or(0) - 1).max(0) as usize) {
            Some(Handle::Frame { thread, frame }) => (*thread, *frame),
            _ => (1, 0),
        };
        let expr = a.get("expression").as_str().unwrap_or("").trim();
        if expr.is_empty() {
            return Err(path_err);
        }
        let v = self.cmd(&format!("eval {frame} {thread} {expr}"));
        match v.get("ev").as_str() {
            Some("value") => Ok(obj([("result", v.get("value").clone()), ("type", v.get("type").clone()), ("variablesReference", 0i64.into())])),
            _ => Err(v.get("msg").as_str().unwrap_or("can't evaluate that").to_string()),
        }
    }

    /// `name`, or a path into it: `p.x`, `xs.2`, `xs[2]`, `m["k"]` (a part by its name as listed).
    fn eval_path(&mut self, a: &Json) -> Result<Json, String> {
        let (thread, frame) = match self.handles.get((a.get("frameId").as_i64().unwrap_or(0) - 1).max(0) as usize) {
            Some(Handle::Frame { thread, frame }) => (*thread, *frame),
            _ => (1, 0),
        };
        let expr = a.get("expression").as_str().unwrap_or("").trim().replace('[', ".").replace(']', "");
        let mut parts = expr.split('.').map(str::trim).filter(|p| !p.is_empty());
        let root = parts.next().ok_or("nothing to evaluate")?.to_string();
        let v = self.cmd(&format!("vars {frame} {thread}"));
        let mut item = v.get("vars").as_arr().iter().find(|x| x.get("name").as_str() == Some(&root)).cloned().ok_or(format!("no local `{root}` here"))?;
        let mut path: Vec<u32> = Vec::new();
        for p in parts {
            let ps: Vec<String> = path.iter().map(|x| x.to_string()).collect();
            let k = self.cmd(&format!("kids {frame} {thread} {root} {}", ps.join(" ")));
            let kids = k.get("kids").as_arr();
            let i = kids.iter().position(|x| x.get("name").as_str().is_some_and(|n| n == p || n.trim_matches('"') == p.trim_matches('"'))).ok_or(format!("no part `{p}`"))?;
            item = kids[i].clone();
            path.push(i as u32);
        }
        let var = self.variable(&item, thread, frame, &root, &path);
        Ok(obj([("result", var.get("value").clone()), ("type", var.get("type").clone()), ("variablesReference", var.get("variablesReference").clone())]))
    }
}

//! `duck debug`: the debugger's command-line front end.
//!
//! It starts the program with `duck run --debug` in a child process and drives the debug engine
//! (runtime/src/dbg.rs) over a private Unix socket (`DUCK_DEBUG`). Two modes:
//!
//! - **batch** (`--json`, `--batch`, or stdin not a terminal): set the `--break` points, run,
//!   and at every stop record where it is, the locals (`--print` names, or all) and the stack,
//!   then continue; at the end, the program's exit code and output. Made for scripts and agents
//!   (`duck mcp`'s `duck_debug` tool): one command, no conversation.
//! - **interactive** (a terminal, or `--repl`): a gdb-style prompt. Ctrl-C pauses the program.
//!
//! The program gets no stdin (the terminal belongs to the prompt).

use std::collections::VecDeque;
use std::io::{BufRead, BufReader, IsTerminal, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::time::Duration;
use std::{env, fs, thread};

use super::json::{self, Json, obj};

const USAGE: &str = "\
usage: duck debug [options] <file.duck> [args...]
  --break, -b <file:line|fn>   stop there (repeatable)
  --print, -p <a,b,...>        batch: show only these locals at each stop (default: all)
  --catch all|uncaught|none    stop on panics (default: uncaught)
  --max-stops N                batch: end the program after N stops (default 20)
  --timeout S                  batch: after S seconds, pause, report where it is, end it
  --json                       batch, with a JSON report
  --batch                      batch, with a text report (the default when stdin is not a terminal)
  --repl                       interactive (the default on a terminal)";

const REPL_HELP: &str = "\
  run, r                start the program          break, b <file:line|fn>   set a breakpoint
  continue, c           resume                     delete, d [id]            remove one, or all
  next, n               step over                  catch all|uncaught|none   stop on panics
  step, s               step into                  bt, where                 the stack
  finish, f             step out                   frame N, up, down         select a frame
  print, p [names]      locals of the frame        threads, thread N         list / select threads
  list, l               source around the line     quit, q                   end the program
  (an empty line repeats the last command; Ctrl-C pauses a running program)";

#[derive(Default)]
struct Opts {
    file: String,
    args: Vec<String>,
    breaks: Vec<String>,
    print: Option<Vec<String>>,
    catch: Option<String>,
    max_stops: usize,
    timeout: Option<f64>,
    json: bool,
    batch: Option<bool>,
}

fn parse_opts(args: &[String]) -> Result<Opts, String> {
    let mut o = Opts { max_stops: 20, ..Default::default() };
    let mut it = args.iter();
    while let Some(a) = it.next() {
        let mut val = |name: &str| it.next().cloned().ok_or(format!("{name} needs a value"));
        match a.as_str() {
            "--break" | "-b" => o.breaks.push(val(a)?),
            "--print" | "-p" => o.print = Some(val(a)?.split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect()),
            "--catch" => o.catch = Some(val(a)?),
            "--max-stops" => o.max_stops = val(a)?.parse().map_err(|_| "--max-stops needs a number")?,
            "--timeout" => o.timeout = Some(val(a)?.parse().ok().filter(|t: &f64| *t > 0.0).ok_or("--timeout needs a number of seconds")?),
            "--json" => {
                o.json = true;
                o.batch = Some(true);
            }
            "--batch" => o.batch = Some(true),
            "--repl" => o.batch = Some(false),
            s if s.starts_with('-') && o.file.is_empty() => return Err(format!("unknown option {s}")),
            _ => {
                o.file = a.clone();
                o.args = it.cloned().collect();
                break;
            }
        }
    }
    if o.file.is_empty() {
        return Err("no program given".into());
    }
    if let Some(c) = &o.catch
        && !matches!(c.as_str(), "all" | "uncaught" | "none")
    {
        return Err("--catch takes all, uncaught or none".into());
    }
    Ok(o)
}

pub fn run(args: &[String]) -> i32 {
    let o = match parse_opts(args) {
        Ok(o) => o,
        Err(e) => {
            eprintln!("duck debug: {e}\n{USAGE}");
            return 2;
        }
    };
    if !Path::new(&o.file).is_file() {
        eprintln!("duck debug: cannot read {}", o.file);
        return 2;
    }
    let batch = o.batch.unwrap_or(!std::io::stdin().is_terminal());
    if batch { batch_run(&o) } else { repl(&o) }
}

// ---- the session ------------------------------------------------------------------------

/// What a front end waits for: an engine event, the program's output (stderr: `true`), a
/// request (DAP), a line typed, or Ctrl-C.
pub(crate) enum In {
    Ev(Json),
    Closed,
    Out(bool, String),
    Req(Json),
    Line(String),
    Eof,
    Interrupt,
}

/// Where the program's stdout and stderr go.
#[derive(Clone, Copy, PartialEq)]
pub(crate) enum Capture {
    /// Our own (interactive).
    Inherit,
    /// Collected for the report (batch).
    Collect,
    /// As `In::Out` events, as they come (DAP).
    Stream,
}

pub(crate) struct Session {
    pub child: Child,
    wr: UnixStream,
    rx: Receiver<In>,
    pub tx: Sender<In>,
    seq: i64,
    pending: VecDeque<In>,
    /// The program's stdout and stderr, when collected (batch).
    output: Option<thread::JoinHandle<(String, String)>>,
}

/// Start `duck run --debug <file>` and wait for its engine to say `ready`. Err: the exit code
/// of a program that never connected (it didn't compile) and its output (Inherit: already shown).
pub(crate) fn launch(file: &str, args: &[String], capture: Capture) -> Result<Session, (i32, String)> {
    let dir = env::temp_dir();
    static N: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
    let sock = dir.join(format!("duck-dbg-{}-{}.sock", std::process::id(), N.fetch_add(1, Ordering::SeqCst)));
    let _ = fs::remove_file(&sock);
    let l = match UnixListener::bind(&sock) {
        Ok(l) => l,
        Err(e) => {
            return Err((1, format!("duck debug: cannot listen on {}: {e}\n", sock.display())));
        }
    };
    let _ = l.set_nonblocking(true);
    let exe = env::current_exe().unwrap_or_else(|_| PathBuf::from("duck"));
    let mut cmd = Command::new(exe);
    cmd.arg("run").arg("--debug").arg(file).args(args).env("DUCK_DEBUG", &sock).stdin(Stdio::null());
    // its own process group: Ctrl-C reaches only the debugger, which pauses the program
    cmd.process_group(0);
    if capture != Capture::Inherit {
        cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
    }
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => return Err((1, format!("duck debug: cannot start the program: {e}\n"))),
    };
    let (tx, rx) = channel();
    let mut streams = Vec::new();
    if capture == Capture::Stream {
        let so: Box<dyn Read + Send> = Box::new(child.stdout.take().unwrap());
        let se: Box<dyn Read + Send> = Box::new(child.stderr.take().unwrap());
        for (is_err, mut r) in [(false, so), (true, se)] {
            let tx = tx.clone();
            streams.push(thread::spawn(move || {
                let mut buf = [0u8; 4096];
                while let Ok(n) = r.read(&mut buf) {
                    if n == 0 || tx.send(In::Out(is_err, String::from_utf8_lossy(&buf[..n]).into_owned())).is_err() {
                        break;
                    }
                }
            }));
        }
    }
    let output = if capture == Capture::Collect {
        let (mut so, mut se) = (child.stdout.take().unwrap(), child.stderr.take().unwrap());
        Some(thread::spawn(move || {
            let e = thread::spawn(move || {
                let mut s = String::new();
                let _ = se.read_to_string(&mut s);
                s
            });
            let mut s = String::new();
            let _ = so.read_to_string(&mut s);
            (s, e.join().unwrap_or_default())
        }))
    } else {
        None
    };
    let conn = loop {
        match l.accept() {
            Ok((c, _)) => break c,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                if let Ok(Some(st)) = child.try_wait() {
                    let _ = fs::remove_file(&sock);
                    let mut text = String::new();
                    if let Some(h) = output {
                        let (so, se) = h.join().unwrap_or_default();
                        text = so + &se;
                    }
                    for h in streams {
                        let _ = h.join();
                    }
                    for x in rx.try_iter() {
                        if let In::Out(_, t) = x {
                            text += &t;
                        }
                    }
                    return Err((st.code().unwrap_or(1), text));
                }
                thread::sleep(Duration::from_millis(5));
            }
            Err(e) => {
                let _ = child.kill();
                return Err((1, format!("duck debug: {e}\n")));
            }
        }
    };
    let _ = fs::remove_file(&sock);
    let _ = conn.set_nonblocking(false);
    let rd = conn.try_clone().expect("socket");
    let t2 = tx.clone();
    thread::spawn(move || {
        for line in BufReader::new(rd).lines() {
            let Ok(line) = line else { break };
            if let Ok(j) = json::parse(&line) {
                let _ = t2.send(In::Ev(j));
            }
        }
        let _ = t2.send(In::Closed);
    });
    let mut s = Session { child, wr: conn, rx, tx, seq: 0, pending: VecDeque::new(), output };
    match s.next() {
        In::Ev(e) if e.get("ev").as_str() == Some("ready") => Ok(s),
        _ => {
            let _ = s.child.kill();
            Err((1, "duck debug: the program did not start its debugger\n".into()))
        }
    }
}

impl Session {
    pub fn next(&mut self) -> In {
        if let Some(x) = self.pending.pop_front() {
            return x;
        }
        self.rx.recv().unwrap_or(In::Closed)
    }

    /// `next`, or None once `deadline` passes.
    fn next_until(&mut self, deadline: Option<std::time::Instant>) -> Option<In> {
        let Some(d) = deadline else { return Some(self.next()) };
        if let Some(x) = self.pending.pop_front() {
            return Some(x);
        }
        match self.rx.recv_timeout(d.saturating_duration_since(std::time::Instant::now())) {
            Ok(x) => Some(x),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => None,
            Err(_) => Some(In::Closed),
        }
    }

    /// Send a command and wait for its reply (Null if the program went away).
    pub fn cmd(&mut self, c: &str) -> Json {
        self.seq += 1;
        if writeln!(self.wr, "@{} {c}", self.seq).is_err() {
            return Json::Null;
        }
        let mut held = VecDeque::new();
        let r = loop {
            match self.rx.recv().unwrap_or(In::Closed) {
                In::Ev(e) if e.get("seq").as_i64() == Some(self.seq) => break e,
                In::Closed => {
                    held.push_back(In::Closed);
                    break Json::Null;
                }
                x => held.push_back(x),
            }
        };
        self.pending.extend(held);
        r
    }

    /// The program's exit code (after it ends or is killed).
    pub fn wait(&mut self) -> i32 {
        match self.child.wait() {
            Ok(st) => st.code().unwrap_or_else(|| {
                use std::os::unix::process::ExitStatusExt;
                128 + st.signal().unwrap_or(0)
            }),
            Err(_) => 1,
        }
    }

    fn captured(&mut self) -> (String, String) {
        self.output.take().map(|h| h.join().unwrap_or_default()).unwrap_or_default()
    }
}

/// A path as the user would write it: relative to the working directory when inside it.
fn short(p: &str) -> String {
    match env::current_dir() {
        Ok(d) => {
            let d = fs::canonicalize(&d).unwrap_or(d);
            Path::new(p).strip_prefix(&d).map(|r| r.display().to_string()).unwrap_or_else(|_| p.to_string())
        }
        Err(_) => p.to_string(),
    }
}

/// `fn (file:line)` of a frame.
fn at(f: &Json) -> String {
    let name = f.get("fn").as_str().unwrap_or("?");
    match f.get("file").as_str() {
        Some(file) => format!("{name} ({}:{})", short(file), f.get("line").as_i64().unwrap_or(0)),
        None => name.to_string(),
    }
}

/// Line `n` of a file (1-based).
fn source_line(file: &str, n: i64) -> Option<String> {
    let src = fs::read_to_string(file).ok()?;
    src.lines().nth((n - 1).max(0) as usize).map(|l| l.to_string())
}

/// Locals of a `vars` reply as (name, type, value), optionally only `names`.
fn locals(r: &Json, names: Option<&[String]>) -> Vec<(String, String, String)> {
    r.get("vars")
        .as_arr()
        .iter()
        .map(|v| (v.get("name").as_str().unwrap_or("").to_string(), v.get("type").as_str().unwrap_or("").to_string(), v.get("value").as_str().unwrap_or("").to_string()))
        .filter(|(n, _, _)| names.is_none_or(|ns| ns.iter().any(|x| x == n)))
        .collect()
}

// ---- batch ------------------------------------------------------------------------------

fn batch_run(o: &Opts) -> i32 {
    let mut s = match launch(&o.file, &o.args, Capture::Collect) {
        Ok(s) => s,
        Err((code, text)) => {
            eprint!("{text}");
            if o.json {
                println!("{}", obj([("error", "the program did not compile".into()), ("exit_code", i64::from(code).into())]));
            }
            return code;
        }
    };
    let mut errors = Vec::new();
    if let Some(c) = &o.catch {
        s.cmd(&format!("catch {c}"));
    }
    for b in &o.breaks {
        let r = s.cmd(&format!("break {b}"));
        if r.get("ev").as_str() != Some("break") {
            errors.push(format!("break {b}: {}", r.get("msg").as_str().unwrap_or("failed")));
        }
    }
    s.cmd("run");
    let mut stops: Vec<Json> = Vec::new();
    let mut killed = false;
    let mut timed_out = false;
    let deadline = o.timeout.map(|t| std::time::Instant::now() + Duration::from_secs_f64(t));
    loop {
        let Some(ev) = s.next_until(if timed_out { None } else { deadline }) else {
            // out of time: stop it where it is (a thread blocked in a call stops when it returns)
            timed_out = true;
            s.cmd("pause");
            let t2 = s.tx.clone();
            thread::spawn(move || {
                thread::sleep(Duration::from_secs(2));
                let _ = t2.send(In::Eof);
            });
            continue;
        };
        if timed_out && matches!(ev, In::Eof) {
            killed = true;
            s.cmd("kill");
            break;
        }
        match ev {
            In::Ev(e) if timed_out && e.get("ev").as_str() == Some("stopped") => {
                let mut r = record(&mut s, &e, o.print.as_deref());
                if let Json::Obj(fs) = &mut r {
                    fs[0].1 = "timeout".into();
                }
                stops.push(r);
                killed = true;
                s.cmd("kill");
                break;
            }
            In::Ev(e) if e.get("ev").as_str() == Some("stopped") => {
                stops.push(record(&mut s, &e, o.print.as_deref()));
                if stops.len() >= o.max_stops {
                    killed = true;
                    s.cmd("kill");
                    break;
                }
                s.cmd("continue");
            }
            In::Ev(e) if e.get("ev").as_str() == Some("exited") => break,
            In::Closed | In::Eof => break,
            _ => {}
        }
    }
    let code = s.wait();
    let (out, err) = s.captured();
    if o.json {
        let mut fields = vec![("stops".to_string(), Json::Arr(stops)), ("exit_code".to_string(), i64::from(code).into())];
        if timed_out {
            fields.push(("note".into(), format!("ended after {}s (--timeout)", o.timeout.unwrap_or(0.0)).into()));
        } else if killed {
            fields.push(("note".into(), format!("ended after {} stops (--max-stops)", o.max_stops).into()));
        }
        if !errors.is_empty() {
            fields.push(("errors".into(), Json::Arr(errors.into_iter().map(Json::from).collect())));
        }
        fields.push(("stdout".into(), out.into()));
        fields.push(("stderr".into(), err.into()));
        println!("{}", Json::Obj(fields));
    } else {
        for e in &errors {
            println!("error: {e}");
        }
        for (i, st) in stops.iter().enumerate() {
            print_stop(i + 1, st);
        }
        if timed_out {
            println!("ended after {}s (--timeout)", o.timeout.unwrap_or(0.0));
        } else if killed {
            println!("ended after {} stops (--max-stops)", o.max_stops);
        }
        if !out.is_empty() {
            println!("stdout:\n{}", out.trim_end());
        }
        if !err.is_empty() {
            println!("stderr:\n{}", err.trim_end());
        }
        println!("exit {code}");
    }
    code
}

/// A stop as JSON: {reason, fn, file, line, [msg, loc], locals: {name: value}, stack: ["fn (file:line)"]}.
fn record(s: &mut Session, e: &Json, names: Option<&[String]>) -> Json {
    let f = e.get("frame");
    let mut fields: Vec<(String, Json)> = vec![("reason".into(), e.get("reason").clone())];
    if let Some(t) = e.get("thread").as_i64()
        && t != 1
    {
        fields.push(("thread".into(), t.into()));
    }
    fields.push(("fn".into(), f.get("fn").clone()));
    if let Some(file) = f.get("file").as_str() {
        fields.push(("file".into(), short(file).into()));
        fields.push(("line".into(), f.get("line").clone()));
    }
    for k in ["msg", "loc"] {
        if let Some(v) = e.get(k).as_str() {
            fields.push((k.into(), v.into()));
        }
    }
    let vars = s.cmd("vars 0");
    let ls = locals(&vars, names).into_iter().map(|(n, _, v)| (n, Json::Str(v))).collect();
    fields.push(("locals".into(), Json::Obj(ls)));
    let st = s.cmd("stack");
    fields.push(("stack".into(), Json::Arr(st.get("frames").as_arr().iter().map(|f| at(f).into()).collect())));
    Json::Obj(fields)
}

fn print_stop(n: usize, st: &Json) {
    let reason = st.get("reason").as_str().unwrap_or("?");
    let file = st.get("file").as_str().unwrap_or("?");
    let line = st.get("line").as_i64().unwrap_or(0);
    let what = match st.get("msg").as_str() {
        Some(m) => format!("panic: {m}"),
        None => reason.to_string(),
    };
    let thread = st.get("thread").as_i64().map(|t| format!(" [thread {t}]")).unwrap_or_default();
    println!("#{n} {what} at {file}:{line} in {}{thread}", st.get("fn").as_str().unwrap_or("?"));
    if let Json::Obj(ls) = st.get("locals") {
        for (k, v) in ls {
            println!("  {k} = {}", v.as_str().unwrap_or(""));
        }
    }
    let stack: Vec<&str> = st.get("stack").as_arr().iter().skip(1).filter_map(|f| f.as_str()).collect();
    if !stack.is_empty() {
        println!("  called from {}", stack.join(" < "));
    }
}

// ---- interactive ------------------------------------------------------------------------

static INTERRUPTED: AtomicBool = AtomicBool::new(false);

extern "C" fn on_sigint(_: libc::c_int) {
    INTERRUPTED.store(true, Ordering::SeqCst);
}

struct Repl {
    s: Session,
    started: bool,
    stopped: bool,
    thread: i64,
    frame: usize,
    /// The selected frame's location (file, line).
    here: Option<(String, i64)>,
    last: String,
    file: String,
}

fn repl(o: &Opts) -> i32 {
    let s = match launch(&o.file, &o.args, Capture::Inherit) {
        Ok(s) => s,
        Err((code, text)) => {
            eprint!("{text}");
            return code;
        }
    };
    // stdin and Ctrl-C feed the same queue as the engine's events
    let tx = s.tx.clone();
    thread::spawn(move || {
        let stdin = std::io::stdin();
        for line in stdin.lock().lines() {
            match line {
                Ok(l) => {
                    if tx.send(In::Line(l)).is_err() {
                        return;
                    }
                }
                Err(_) => break,
            }
        }
        let _ = tx.send(In::Eof);
    });
    unsafe { libc::signal(libc::SIGINT, on_sigint as *const () as libc::sighandler_t) };
    let tx = s.tx.clone();
    thread::spawn(move || {
        loop {
            thread::sleep(Duration::from_millis(50));
            if INTERRUPTED.swap(false, Ordering::SeqCst) && tx.send(In::Interrupt).is_err() {
                return;
            }
        }
    });
    let mut r = Repl { s, started: false, stopped: false, thread: 1, frame: 0, here: None, last: String::new(), file: o.file.clone() };
    if let Some(c) = &o.catch {
        r.s.cmd(&format!("catch {c}"));
    }
    for b in &o.breaks {
        r.command(&format!("break {b}"));
    }
    println!("duck debug: {} (`run` starts it, `help` lists commands)", o.file);
    r.prompt();
    // what is typed while the program runs waits for the next stop (as in gdb); `quit` doesn't
    let mut held: VecDeque<In> = VecDeque::new();
    loop {
        let input = match held.pop_front() {
            Some(x) if !r.started || r.stopped => x,
            Some(x) => {
                held.push_front(x);
                r.s.next()
            }
            None => r.s.next(),
        };
        let running = r.started && !r.stopped;
        match input {
            In::Line(l) if running && !matches!(l.trim(), "q" | "quit" | "kill" | "exit") => held.push_back(In::Line(l)),
            In::Eof if running => held.push_back(In::Eof),
            In::Line(l) => {
                let l = if l.trim().is_empty() { r.last.clone() } else { l.trim().to_string() };
                if l.is_empty() {
                    r.prompt();
                    continue;
                }
                r.last = l.clone();
                if !r.command(&l) {
                    break;
                }
                if !r.started || r.stopped {
                    r.prompt();
                }
            }
            In::Eof => {
                if r.started {
                    r.s.cmd("kill");
                }
                break;
            }
            In::Interrupt => {
                if r.started && !r.stopped {
                    r.s.cmd("pause");
                } else {
                    println!();
                    r.prompt();
                }
            }
            In::Ev(e) => match e.get("ev").as_str() {
                Some("stopped") => {
                    r.on_stop(&e);
                    r.prompt();
                }
                Some("exited") => {}
                _ => {}
            },
            In::Closed => break,
            In::Out(..) | In::Req(_) => {}
        }
    }
    let code = r.s.wait();
    println!("program exited with code {code}");
    code
}

impl Repl {
    fn prompt(&self) {
        print!("(duck) ");
        let _ = std::io::stdout().flush();
    }

    fn on_stop(&mut self, e: &Json) {
        self.stopped = true;
        self.thread = e.get("thread").as_i64().unwrap_or(1);
        self.frame = 0;
        let f = e.get("frame");
        let thread = if self.thread != 1 { format!(" [thread {}]", self.thread) } else { String::new() };
        match e.get("reason").as_str() {
            Some("panic") => {
                println!("panic: {}{thread}", e.get("msg").as_str().unwrap_or(""));
                println!("  in {}", at(f));
            }
            Some("breakpoint") => {
                let ids: Vec<String> = e.get("bps").as_arr().iter().filter_map(|b| b.as_i64()).map(|b| b.to_string()).collect();
                println!("breakpoint {} in {}{thread}", ids.join(","), at(f));
            }
            Some("pause") => println!("paused in {}{thread}", at(f)),
            _ => {}
        }
        self.here = f.get("file").as_str().map(|p| (p.to_string(), f.get("line").as_i64().unwrap_or(0)));
        self.show_line();
    }

    fn show_line(&self) {
        if let Some((file, n)) = &self.here
            && let Some(l) = source_line(file, *n)
        {
            println!("{n}\t{l}");
        }
    }

    /// Select frame `n` of the current thread; false when there is none.
    fn select(&mut self, n: usize) -> bool {
        let st = self.s.cmd(&format!("stack {}", self.thread));
        let frames = st.get("frames").as_arr();
        let Some(f) = frames.get(n) else {
            println!("no frame {n} ({} frames)", frames.len());
            return false;
        };
        self.frame = n;
        self.here = f.get("file").as_str().map(|p| (p.to_string(), f.get("line").as_i64().unwrap_or(0)));
        println!("#{n} {}", at(f));
        self.show_line();
        true
    }

    /// Run one command; false to quit.
    fn command(&mut self, line: &str) -> bool {
        let words: Vec<&str> = line.split_whitespace().collect();
        let (c, rest) = (words[0], &words[1..]);
        let need_stop = |r: &Repl| {
            if !r.started {
                println!("the program is not running (`run` starts it)");
                false
            } else if !r.stopped {
                println!("the program is running (Ctrl-C pauses it)");
                false
            } else {
                true
            }
        };
        match c {
            "help" | "h" | "?" => println!("{REPL_HELP}"),
            "quit" | "q" | "kill" | "exit" => {
                self.s.cmd("kill");
                return false;
            }
            "run" | "r" => {
                if self.started {
                    println!("already running");
                } else {
                    self.started = true;
                    self.s.cmd("run");
                }
            }
            "break" | "b" => {
                let spec = if rest.is_empty() {
                    match &self.here {
                        Some((f, n)) => format!("{f}:{n}"),
                        None => {
                            println!("usage: break <file:line|fn>");
                            return true;
                        }
                    }
                } else {
                    rest.join(" ")
                };
                // `break 12`: a line of the current (or the program's) file
                let spec = match spec.parse::<u32>() {
                    Ok(n) => {
                        let file = self.here.as_ref().map(|(f, _)| f.clone()).unwrap_or_else(|| self.file.clone());
                        format!("{file}:{n}")
                    }
                    Err(_) => spec,
                };
                let r = self.s.cmd(&format!("break {spec}"));
                match r.get("ev").as_str() {
                    Some("break") => println!(
                        "breakpoint {} at {}:{}",
                        r.get("id").as_i64().unwrap_or(0),
                        short(r.get("file").as_str().unwrap_or("?")),
                        r.get("line").as_i64().unwrap_or(0)
                    ),
                    _ => println!("{}", r.get("msg").as_str().unwrap_or("cannot set the breakpoint")),
                }
            }
            "delete" | "d" => {
                self.s.cmd(&format!("delete {}", rest.join(" ")));
            }
            "catch" => {
                self.s.cmd(&format!("catch {}", rest.first().unwrap_or(&"uncaught")));
            }
            "continue" | "c" | "next" | "n" | "step" | "s" | "finish" | "f" => {
                if !self.started {
                    self.started = true;
                    self.s.cmd("run");
                    return true;
                }
                if !need_stop(self) {
                    return true;
                }
                let full = match c {
                    "c" => "continue",
                    "n" => "next",
                    "s" => "step",
                    "f" => "finish",
                    x => x,
                };
                self.stopped = false;
                if self.s.cmd(full).is_null() {
                    return false;
                }
            }
            "bt" | "where" | "backtrace" => {
                if need_stop(self) {
                    let st = self.s.cmd(&format!("stack {}", self.thread));
                    for (i, f) in st.get("frames").as_arr().iter().enumerate() {
                        let mark = if i == self.frame { "*" } else { " " };
                        println!("{mark}#{i} {}", at(f));
                    }
                }
            }
            "print" | "p" | "locals" | "info" => {
                if need_stop(self) {
                    let r = self.s.cmd(&format!("vars {} {}", self.frame, self.thread));
                    let names: Vec<String> = rest.iter().filter(|w| **w != "locals").map(|w| w.to_string()).collect();
                    let ls = locals(&r, if names.is_empty() { None } else { Some(&names) });
                    if ls.is_empty() {
                        println!("{}", if names.is_empty() { "no locals here" } else { "no such local here" });
                    }
                    for (n, t, v) in ls {
                        println!("{n}: {t} = {v}");
                    }
                }
            }
            "frame" | "fr" | "up" | "down" => {
                if need_stop(self) {
                    let n = match c {
                        "up" => self.frame + 1,
                        "down" => self.frame.saturating_sub(1),
                        _ => rest.first().and_then(|x| x.parse().ok()).unwrap_or(self.frame),
                    };
                    self.select(n);
                }
            }
            "threads" => {
                if need_stop(self) {
                    let r = self.s.cmd("threads");
                    for t in r.get("threads").as_arr() {
                        let id = t.get("id").as_i64().unwrap_or(0);
                        let mark = if id == self.thread { "*" } else { " " };
                        let f = t.get("frame");
                        println!("{mark}{id} {}", if f.is_null() { "(not in Duck code)".to_string() } else { at(f) });
                    }
                }
            }
            "thread" => {
                if need_stop(self) {
                    match rest.first().and_then(|x| x.parse::<i64>().ok()) {
                        Some(t) => {
                            let old = self.thread;
                            self.thread = t;
                            if !self.select(0) {
                                self.thread = old;
                            }
                        }
                        None => println!("thread {}", self.thread),
                    }
                }
            }
            "list" | "l" => match &self.here {
                Some((file, n)) => {
                    if let Ok(src) = fs::read_to_string(file) {
                        let lines: Vec<&str> = src.lines().collect();
                        let from = (*n - 5).max(1);
                        let to = (*n + 5).min(lines.len() as i64);
                        for k in from..=to {
                            let mark = if k == *n { ">" } else { " " };
                            println!("{mark}{k}\t{}", lines[(k - 1) as usize]);
                        }
                    }
                }
                None => println!("no current line"),
            },
            _ => println!("unknown command `{c}` (`help` lists them)"),
        }
        true
    }
}

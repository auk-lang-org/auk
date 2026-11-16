//! `duck pond`: the interactive REPL.
//!
//! Every input is compiled (Cranelift JIT) and run as a whole program, so a session needs no
//! interpreter state of its own:
//!
//! ```text
//! <every definition of the session>
//! fn main(): ()! uses fs, net, time, rand, env, proc {
//!   <every earlier statement, replayed>
//!   print("\u{1}pond-start")        // the marker: only output after it is shown
//!   <the new input>
//! }
//! ```
//!
//! An input is one of three kinds, decided by its first token and, failing that, by parsing it
//! as the body of a function:
//! - a **definition** (`fn`, `struct`, `enum`, `shape`, `test`, `imprint`, `pub ...`) joins the
//!   session's definitions. A struct, enum, shape or constant of the same name is replaced; new
//!   clauses for an existing function are appended to its clause group, or replace it when the
//!   group doesn't check with them appended (a redefinition). Definitions are type-checked only.
//!   A clause group that doesn't cover every case yet (E0400) waits for more clauses on the
//!   following lines (`..`); a blank line gives up and shows the error.
//! - a **statement** (`let`, `var`, an assignment, `for`, `while`, `assert`) runs and joins the
//!   statement history.
//! - an **expression** is type-checked as `let __pond_r = <expr>`; its value is then printed
//!   with `Show` as `<value> : <type>`. A `()` expression prints nothing and joins the history
//!   like a statement (it may mutate a variable: `xs.push(4)`).
//!
//! The replayed statements' output (stdout and stderr share one file) is hidden by the marker.
//! An input that fails to check, panics or makes `main` return an error is not kept.
//! Diagnostics and panic locations are mapped back to the input's own line numbers.
//!
//! Speed: checking takes a few ms; each input is compiled in memory (Cranelift) and runs in a
//! forked child process. Nothing runs for a definition.

use std::fmt::Write as _;
use std::io::{BufRead, IsTerminal, Write};
use std::path::PathBuf;
use std::rc::Rc;
use std::{env, fs};

use super::ast::{ExprKind, FnBody, Item as AstItem, Module};
use super::build;
use super::mir::progen::Mode;
use super::diag::{Diag, FileDiag};
use super::lexer::lex;
use super::token::Tok;
use super::typed::TypedProgram;
use super::types::Ty;
use super::{check, explain, fmt, parser, resolve};

const PROMPT: &str = "🦆> ";
const CONT: &str = ".. ";
const MARK: &str = "\u{1}pond-start\n";
const VALUE_MARK: &str = "\u{1}pond-value\n";
/// The effects `main` declares, so any input may use them.
const EFFECTS: &[&str] = &["fs", "net", "time", "rand", "env", "proc"];
/// The name of the binding an expression's value is stored in.
const RESULT: &str = "__pond_r";

const HELP: &str = "\
Enter a definition, a statement or an expression:
  fn / struct / enum / shape / test / imprint   added to the session's definitions
  let x = 5   var n = 0   n += 1   for ...      run, then kept in the session's main
  [1, 2, 3].map(x => x * 2)                     evaluated and printed with its type

Commands:
  :help              show this help
  :type <expr>       show the type of an expression (checks only, runs nothing)
  :items             list the session's definitions
  :reset             forget every definition and statement
  :load <file>       add a file's definitions (its `main` is skipped)
  :save <file>       write the session as a formatted .duck file
  :explain <E0xxx>   explain an error code
  :quit              leave (Ctrl-D also works)

A line ending in an operator, `=` or `,`, or with an open bracket or string, continues on the
next line (`..`); a blank line ends it early.
Each input compiles and runs a small native program: the session's definitions plus a main that
replays the earlier statements (their output is hidden) and then runs the new input. So
replayed statements run again (`rand`, `time` and files see the re-run). Inputs that fail to
check or panic are not kept.
";

/// `duck pond [--quiet]`. Returns the exit code.
pub fn run(args: &[String]) -> i32 {
    let mut quiet = !std::io::stdin().is_terminal();
    for a in args {
        match a.as_str() {
            "--quiet" | "-q" => quiet = true,
            _ => {
                eprintln!("usage: duck pond [--quiet]");
                return 2;
            }
        }
    }
    let mut s = match Session::new() {
        Ok(s) => s,
        Err(e) => {
            eprint!("{e}");
            return 1;
        }
    };
    if !quiet {
        println!("Duck {} pond: :help for commands", env!("CARGO_PKG_VERSION"));
    }
    let stdin = std::io::stdin();
    let mut input = stdin.lock();
    let mut buf = String::new();
    // The rendered E0400 errors of a clause group waiting for more clauses.
    let mut pending: Option<String> = None;
    loop {
        if !quiet {
            print!("{}", if buf.is_empty() { PROMPT } else { CONT });
        }
        let _ = std::io::stdout().flush();
        let mut line = String::new();
        match input.read_line(&mut line) {
            Ok(0) | Err(_) => {
                if let Some(errs) = pending.take() {
                    print!("{errs}");
                } else if !buf.trim().is_empty() {
                    s.eval(&buf);
                }
                if !quiet {
                    println!();
                }
                break;
            }
            Ok(_) => {}
        }
        let line = line.trim_end_matches(['\n', '\r']);
        if let Some(errs) = &pending
            && (line.trim().is_empty() || !starts_clause(line))
        {
            print!("{errs}");
            pending = None;
            buf.clear();
            if line.trim().is_empty() {
                continue;
            }
        }
        if buf.is_empty() {
            if line.trim().is_empty() {
                continue;
            }
            if let Some(cmd) = line.trim_start().strip_prefix(':') {
                if !s.command(cmd.trim()) {
                    break;
                }
                continue;
            }
        } else if line.trim().is_empty() && pending.is_none() && !in_triple_string(&buf) {
            // A blank line ends an unfinished input early (to show its error).
            s.eval(&buf);
            buf.clear();
            continue;
        }
        buf.push_str(line);
        buf.push('\n');
        if pending.is_none() && incomplete(&buf) {
            continue;
        }
        match s.eval(&buf) {
            Outcome::Done | Outcome::Failed => {
                pending = None;
                buf.clear();
            }
            Outcome::MoreClauses(errs) => pending = Some(errs),
        }
    }
    0
}

/// Does `line` continue a clause group (another `fn`, doc comment or `pub fn`)?
fn starts_clause(line: &str) -> bool {
    let t = line.trim_start();
    t.starts_with("fn ") || t.starts_with("pub fn ") || t.starts_with("async fn ") || t.starts_with("///")
}

/// Is the input unfinished: an open bracket, string or block comment, or a last line ending in
/// an operator, `=`, `=>` or `,` (the lexer's newline rule)?
pub fn incomplete(src: &str) -> bool {
    match lex(src) {
        Err(d) => matches!(d.code, "E0002" | "E0003" | "E0012"),
        Ok(l) => {
            let last = l.toks.iter().rev().find(|t| !matches!(t.tok, Tok::Newline | Tok::Eof));
            last.is_some_and(|t| {
                matches!(
                    t.tok,
                    Tok::Plus
                        | Tok::Minus
                        | Tok::Star
                        | Tok::Slash
                        | Tok::Percent
                        | Tok::StarStar
                        | Tok::PlusWrap
                        | Tok::MinusWrap
                        | Tok::StarWrap
                        | Tok::EqEq
                        | Tok::BangEq
                        | Tok::Lt
                        | Tok::Le
                        | Tok::Gt
                        | Tok::Ge
                        | Tok::AndAnd
                        | Tok::OrOr
                        | Tok::PlusEq
                        | Tok::MinusEq
                        | Tok::StarEq
                        | Tok::SlashEq
                        | Tok::PercentEq
                        | Tok::Amp
                        | Tok::Pipe
                        | Tok::Caret
                        | Tok::Tilde
                        | Tok::Shl
                        | Tok::AmpEq
                        | Tok::PipeEq
                        | Tok::CaretEq
                        | Tok::ShlEq
                        | Tok::Eq
                        | Tok::FatArrow
                        | Tok::Comma
                        | Tok::PipeGt
                        | Tok::Dot
                        | Tok::DotDot
                        | Tok::DotDotEq
                        | Tok::Colon
                )
            })
        }
    }
}

/// Inside an unterminated `"""` string (where blank lines are content)?
fn in_triple_string(src: &str) -> bool {
    src.contains("\"\"\"") && lex(src).is_err_and(|d| d.code == "E0002")
}

/// What kind of input this is.
#[derive(Debug, PartialEq)]
pub enum Kind {
    Item,
    Stmt,
    Expr,
}

/// Decide the kind of a (complete, lexable) input. A parse error of a statement or expression
/// is reported as `Err` (rendered against the input).
pub fn classify(src: &str) -> Result<Kind, Vec<Diag>> {
    let toks = lex(src).map_err(|d| vec![d])?.toks;
    let mut it = toks.iter().map(|t| &t.tok).filter(|t| **t != Tok::Newline);
    let first = it.next();
    let second = it.next();
    let ident = |t: Option<&Tok>, names: &[&str]| matches!(t, Some(Tok::Ident(s)) if names.contains(&s.as_str()));
    match first {
        Some(Tok::Fn | Tok::Struct | Tok::Enum | Tok::Pub | Tok::Async) => return Ok(Kind::Item),
        Some(Tok::Let | Tok::Var | Tok::For | Tok::While | Tok::Assert) => return Ok(Kind::Stmt),
        t if ident(t, &["shape", "imprint"]) && matches!(second, Some(Tok::Ident(_))) => return Ok(Kind::Item),
        t if ident(t, &["test"]) && matches!(second, Some(Tok::Str(_))) => return Ok(Kind::Item),
        t if ident(t, &["extern"]) && (matches!(second, Some(Tok::Fn)) || ident(second, &["type"])) => return Ok(Kind::Item),
        _ => {}
    }
    let wrapped = format!("fn main() {{\n{src}\n}}\n");
    let m = parser::parse(&wrapped).map_err(|ds| ds.into_iter().map(|d| shift(d, 1)).collect::<Vec<_>>())?;
    let stmts = match m.items.first() {
        Some(AstItem::Fn(g)) => match g.clauses.first().and_then(|c| c.body.as_ref()) {
            Some(FnBody::Block(b)) => &b.stmts,
            _ => return Ok(Kind::Stmt),
        },
        _ => return Ok(Kind::Stmt),
    };
    match stmts.as_slice() {
        [e] if !matches!(e.kind, ExprKind::Let { .. } | ExprKind::Assign { .. } | ExprKind::Assert(_) | ExprKind::While { .. } | ExprKind::For { .. }) => {
            Ok(Kind::Expr)
        }
        _ => Ok(Kind::Stmt),
    }
}

/// Move a diagnostic `delta` lines up.
fn shift(mut d: Diag, delta: u32) -> Diag {
    let up = |l: u32| l.saturating_sub(delta).max(1);
    d.span.line = up(d.span.line);
    d.span.end_line = up(d.span.end_line);
    for f in &mut d.fixes {
        f.span.line = up(f.span.line);
        f.span.end_line = up(f.span.end_line);
    }
    d
}

/// Where some source lines came from: an input (or a loaded file) and its text.
struct Origin {
    name: String,
    text: String,
}

/// A run of lines of an origin, starting at its line `first` (1-based).
#[derive(Clone)]
struct Part {
    origin: Rc<Origin>,
    first: u32,
    text: String,
}

impl Part {
    fn whole(origin: &Rc<Origin>) -> Part {
        Part { origin: origin.clone(), first: 1, text: origin.text.clone() }
    }
}

/// What identifies a definition, for replacing or extending it.
#[derive(Debug, Clone, PartialEq)]
enum Key {
    Fn(String, usize),
    Type(String),
    Const(String),
    Test(String),
}

/// One definition of the session (a clause group may come from several inputs).
#[derive(Clone)]
struct Def {
    key: Key,
    label: String,
    clauses: usize,
    parts: Vec<Part>,
}

/// A generated program: its source and, per line, the part line it came from.
struct Prog {
    src: String,
    lines: Vec<Option<(Rc<Origin>, u32)>>,
}

impl Prog {
    fn new() -> Prog {
        Prog { src: String::new(), lines: Vec::new() }
    }

    fn scaffold(&mut self, text: &str) {
        for l in text.lines() {
            self.src.push_str(l);
            self.src.push('\n');
            self.lines.push(None);
        }
    }

    fn part(&mut self, p: &Part) {
        for (i, l) in p.text.lines().enumerate() {
            self.src.push_str(l);
            self.src.push('\n');
            self.lines.push(Some((p.origin.clone(), p.first + i as u32)));
        }
    }

    /// The origin and origin line of generated line `line`.
    fn origin(&self, line: u32) -> Option<&(Rc<Origin>, u32)> {
        self.lines.get((line as usize).checked_sub(1)?)?.as_ref()
    }
}

/// A piece of `main` after the replayed statements.
enum Piece<'a> {
    Scaffold(&'a str),
    Part(&'a Part),
}

pub enum Outcome {
    Done,
    /// The input was rejected (its errors are shown).
    Failed,
    /// A clause group that doesn't cover every case yet: wait for more clauses (the rendered
    /// errors are shown if none come).
    MoreClauses(String),
}

struct Session {
    defs: Vec<Def>,
    history: Vec<Part>,
    dir: PathBuf,
    /// The generated source's path (as diagnostics and panics name it).
    src_path: PathBuf,
    builds: usize,
}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

impl Session {
    fn new() -> Result<Session, String> {
        let dir = env::temp_dir().join(format!("duck-pond-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).map_err(|e| format!("error: cannot create {}: {e}\n", dir.display()))?;
        let src_path = dir.join("pond.duck");
        Ok(Session { defs: Vec::new(), history: Vec::new(), dir, src_path, builds: 0 })
    }

    /// Handle a `:command`. Returns false to quit.
    fn command(&mut self, cmd: &str) -> bool {
        let (name, arg) = cmd.split_once(char::is_whitespace).map(|(a, b)| (a, b.trim())).unwrap_or((cmd, ""));
        match (name, arg) {
            ("q" | "quit" | "exit", _) => return false,
            ("h" | "help" | "?", _) => print!("{HELP}"),
            ("t" | "type", e) if !e.is_empty() => self.type_of(e),
            ("items", _) => self.items(),
            ("reset", _) => {
                self.defs.clear();
                self.history.clear();
                println!("session cleared");
            }
            ("load", f) if !f.is_empty() => self.load(f),
            ("save", f) if !f.is_empty() => self.save(f),
            ("explain", c) => {
                let args: Vec<String> = c.split_whitespace().map(String::from).collect();
                let _ = std::io::stdout().flush();
                explain::run(&args);
            }
            _ => println!("unknown command `:{cmd}` (try :help)"),
        }
        true
    }

    /// Evaluate one complete input.
    fn eval(&mut self, src: &str) -> Outcome {
        let origin = Rc::new(Origin { name: "pond".into(), text: src.to_string() });
        match classify(src) {
            Err(ds) => {
                print!("{}", ds.iter().map(|d| d.render(&origin.name, src)).collect::<String>());
                Outcome::Done
            }
            Ok(Kind::Item) => self.add_items(&origin, false),
            Ok(Kind::Stmt) => {
                self.statement(&origin);
                Outcome::Done
            }
            Ok(Kind::Expr) => {
                self.expression(&origin);
                Outcome::Done
            }
        }
    }

    /// Build the program: the definitions, then `main` with the history and `tail`.
    fn program(&self, defs: &[Def], tail: &[Piece]) -> Prog {
        let mut p = Prog::new();
        for d in defs {
            for part in &d.parts {
                p.part(part);
            }
            p.scaffold("");
        }
        p.scaffold(&format!("fn main(): ()! uses {} {{", EFFECTS.join(", ")));
        for h in &self.history {
            p.part(h);
        }
        p.scaffold(&format!("print({:?})", MARK.trim_end()));
        for t in tail {
            match t {
                Piece::Scaffold(s) => p.scaffold(s),
                Piece::Part(part) => p.part(part),
            }
        }
        p.scaffold("()\n}");
        p
    }

    /// Type-check a generated program.
    fn check(&self, p: &Prog) -> Result<TypedProgram, Vec<FileDiag>> {
        resolve::load_source(&self.src_path, p.src.clone()).and_then(check::check)
    }

    /// Render the errors (warnings are dropped: the scaffold's `uses` is always too wide), each
    /// against the input it came from. Also says whether every error is in `origin`.
    fn render(&self, p: &Prog, diags: &[FileDiag], origin: &Rc<Origin>) -> (String, bool) {
        let mut out = String::new();
        let mut all_in = true;
        let gen_file = self.src_path.display().to_string();
        for fd in diags.iter().filter(|d| !d.diag.is_warning()) {
            if fd.file != gen_file {
                all_in = false;
                out += &fd.diag.render(&fd.file, &resolve::source_of(&fd.file).unwrap_or_default());
                continue;
            }
            match p.origin(fd.diag.span.line) {
                Some((o, line)) => {
                    all_in &= Rc::ptr_eq(o, origin);
                    out += &shift(fd.diag.clone(), fd.diag.span.line - line).render(&o.name, &o.text);
                }
                None => {
                    all_in = false;
                    out += &fd.diag.render("<pond>", &p.src);
                }
            }
        }
        (out, all_in)
    }

    /// Definitions: add (or extend, or replace) them and check.
    fn add_items(&mut self, origin: &Rc<Origin>, loading: bool) -> Outcome {
        let src = &origin.text;
        let module = match parser::parse(src) {
            Ok(m) => m,
            Err(ds) => {
                print!("{}", ds.iter().map(|d| d.render(&origin.name, src)).collect::<String>());
                return Outcome::Failed;
            }
        };
        let mut new = match split_items(origin, &module) {
            Ok(n) => n,
            Err(e) => {
                println!("{e}");
                return Outcome::Failed;
            }
        };
        if new.iter().any(|d| matches!(&d.key, Key::Fn(n, _) if n == "main")) {
            if !loading {
                println!("pond runs each input in its own `main`; define `main` in a file and use `duck run`");
                return Outcome::Failed;
            }
            new.retain(|d| !matches!(&d.key, Key::Fn(n, _) if n == "main"));
            println!("note: skipped `main` in {}", origin.name);
        }
        let append = merge(&self.defs, &new, true);
        let replace = merge(&self.defs, &new, false);
        let mut first_errs = None;
        for (i, cand) in [append, replace].into_iter().enumerate() {
            let p = self.program(&cand, &[]);
            match self.check(&p) {
                Ok(_) => {
                    self.defs = cand;
                    return Outcome::Done;
                }
                Err(ds) => {
                    if i == 1 || first_errs.is_none() {
                        let only_e0400 = ds.iter().filter(|d| !d.diag.is_warning()).all(|d| d.diag.code == "E0400");
                        first_errs = Some((self.render(&p, &ds, origin), only_e0400));
                    }
                }
            }
        }
        let ((errs, all_in), only_e0400) = first_errs.unwrap_or_default();
        let all_fns = new.iter().all(|d| matches!(d.key, Key::Fn(..)));
        if !loading && only_e0400 && all_in && all_fns {
            return Outcome::MoreClauses(errs);
        }
        print!("{errs}");
        Outcome::Failed
    }

    /// A statement: run it; keep it when it succeeds.
    fn statement(&mut self, origin: &Rc<Origin>) {
        let part = Part::whole(origin);
        let p = self.program(&self.defs, &[Piece::Part(&part)]);
        let tp = match self.check(&p) {
            Ok(tp) => tp,
            Err(ds) => return print!("{}", self.render(&p, &ds, origin).0),
        };
        let (ok, out) = self.exec(&tp, &p);
        print!("{out}");
        if ok {
            self.history.push(part);
        }
    }


    /// An expression: print its value and type. A `()` expression joins the history.
    fn expression(&mut self, origin: &Rc<Origin>) {
        let part = Part::whole(origin);
        let let_line = format!("let {RESULT} =");
        let value_mark = format!("print({:?})", VALUE_MARK.trim_end());
        let show_line = format!("print([{RESULT}].show())");
        // Usually one check: the program that also shows the value. Only when that fails is
        // the plain `let` checked, for the right errors (or for a value without `Show`).
        let display = self.program(
            &self.defs,
            &[Piece::Scaffold(&let_line), Piece::Part(&part), Piece::Scaffold(&value_mark), Piece::Scaffold(&show_line)],
        );
        let (ty, shown, ok, out) = match self.check(&display) {
            Ok(tp) => {
                let ty = result_ty(&tp);
                let shown = tp.defs.show(&ty);
                let (ok, out) = self.exec(&tp, &display);
                (ty, shown, ok, out)
            }
            Err(_) => {
                let typing = self.program(&self.defs, &[Piece::Scaffold(&let_line), Piece::Part(&part)]);
                let tp = match self.check(&typing) {
                    Ok(tp) => tp,
                    Err(ds) => return print!("{}", self.render(&typing, &ds, origin).0),
                };
                // No `Show` for this type (a closure, a task): run it and show only the type.
                let ty = result_ty(&tp);
                let shown = tp.defs.show(&ty);
                let (ok, out) = self.exec(&tp, &typing);
                let what = if matches!(ty, Ty::Fn(..)) { "<fn>" } else { "<value>" };
                (ty, shown.clone(), ok, if ok { format!("{out}{VALUE_MARK}[{what}]\n") } else { out })
            }
        };
        let Some((before, value)) = out.split_once(VALUE_MARK).filter(|_| ok) else {
            return print!("{out}");
        };
        print!("{before}");
        if ty.is_unit() {
            // `()` prints nothing, and the input joins the history (it may mutate something).
            self.history.push(part);
        } else if ty != Ty::Never {
            let value = value.trim_end_matches('\n');
            let value = value.strip_prefix('[').and_then(|v| v.strip_suffix(']')).unwrap_or(value);
            println!("{value} : {shown}");
        }
    }

    /// `:type <expr>`.
    fn type_of(&self, src: &str) {
        let origin = Rc::new(Origin { name: "pond".into(), text: format!("{src}\n") });
        let part = Part::whole(&origin);
        let p = self.program(&self.defs, &[Piece::Scaffold(&format!("let {RESULT} =")), Piece::Part(&part)]);
        match self.check(&p) {
            Ok(tp) => println!("{}", tp.defs.show(&result_ty(&tp))),
            Err(ds) => print!("{}", self.render(&p, &ds, &origin).0),
        }
    }

    /// `:items`.
    fn items(&self) {
        if self.defs.is_empty() {
            println!("(no definitions)");
        }
        for d in &self.defs {
            if d.clauses > 1 {
                println!("{}  ({} clauses)", d.label, d.clauses);
            } else {
                println!("{}", d.label);
            }
        }
    }

    /// `:load <file>`.
    fn load(&mut self, file: &str) {
        match fs::read_to_string(file) {
            Ok(text) => {
                let origin = Rc::new(Origin { name: file.to_string(), text });
                if matches!(self.add_items(&origin, true), Outcome::Done) {
                    println!("loaded {file}");
                }
            }
            Err(e) => println!("error: cannot read {file}: {e}"),
        }
    }

    /// The session as a program: the definitions, then a `main` with the statements (declaring
    /// only the effects they use).
    fn session_source(&self) -> String {
        let mut effects: Vec<&str> = EFFECTS.to_vec();
        let p = self.program(&self.defs, &[]);
        if let Ok(prog) = resolve::load_source(&self.src_path, p.src.clone()) {
            let (_, diags) = check::check_all(prog);
            for d in diags.iter().filter(|d| d.diag.code == "E0411") {
                // "`main` declares the effects `fs`, `net` but doesn't use them"
                let unused: Vec<&str> = d.diag.message.split('`').skip(1).step_by(2).skip(1).collect();
                effects.retain(|e| !unused.contains(e));
            }
        }
        let mut s = String::new();
        for d in &self.defs {
            for part in &d.parts {
                s += &part.text;
                if !s.ends_with('\n') {
                    s.push('\n');
                }
            }
            s.push('\n');
        }
        if !self.history.is_empty() {
            let uses = if effects.is_empty() { String::new() } else { format!(" uses {}", effects.join(", ")) };
            let _ = writeln!(s, "fn main(): ()!{uses} {{");
            for h in &self.history {
                s += &h.text;
                if !s.ends_with('\n') {
                    s.push('\n');
                }
            }
            s.push_str("}\n");
        }
        s
    }

    /// `:save <file>`.
    fn save(&self, file: &str) {
        let raw = self.session_source();
        let text = fmt::format(&raw).unwrap_or(raw);
        match fs::write(file, text) {
            Ok(()) => println!("saved {file}"),
            Err(e) => println!("error: cannot write {file}: {e}"),
        }
    }

    /// Compile and run a checked program. Returns whether it succeeded and its output after
    /// the marker (with panic locations mapped back to the inputs).
    /// It is compiled in memory and runs in a forked child: stdin closed, stdout and stderr
    /// merged (in order) in one file.
    fn exec(&mut self, tp: &TypedProgram, p: &Prog) -> (bool, String) {
        let g = match build::generate(tp, Mode::Run, Default::default()) {
            Ok(g) => g,
            Err(e) => return (false, e),
        };
        let info = crate::mir::types::TyInfo::new(tp);
        let j = match crate::mir::clif::jit(&g.prog, &info, false) {
            Ok(j) => j,
            Err(e) => return (false, format!("error: {e}\n")),
        };
        self.builds += 1;
        let out_file = self.dir.join(format!("out{}", self.builds));
        let args = vec![self.src_path.display().to_string()];
        let r = j.run_forked(&args, crate::mir::clif::Redirect { merged: Some(&out_file), stdin_null: true, ..Default::default() });
        let out = fs::read(&out_file).map(|b| String::from_utf8_lossy(&b).into_owned()).unwrap_or_default();
        let _ = fs::remove_file(&out_file);
        let ok = match r {
            Ok(code) => code == Some(0),
            Err(e) => return (false, e),
        };
        let out = match out.split_once(MARK) {
            Some((_, after)) => after.to_string(),
            None => out,
        };
        (ok, self.map_locations(&out, p))
    }

    /// Rewrite `<generated file>:line:col` to the input's own name and line.
    fn map_locations(&self, out: &str, p: &Prog) -> String {
        let file = self.src_path.display().to_string();
        let mut res = String::new();
        let mut rest = out;
        while let Some(i) = rest.find(&file) {
            res.push_str(&rest[..i]);
            rest = &rest[i + file.len()..];
            let digits = |s: &str| s.strip_prefix(':').map(|t| t.chars().take_while(char::is_ascii_digit).collect::<String>()).filter(|d| !d.is_empty());
            match digits(rest).and_then(|d| Some((d.parse::<u32>().ok()?, d.len()))) {
                Some((line, len)) => match p.origin(line) {
                    Some((o, l)) => {
                        let _ = write!(res, "{}:{l}", o.name);
                        rest = &rest[1 + len..];
                    }
                    None => res.push_str("<pond>"),
                },
                None => res.push_str("<pond>"),
            }
        }
        res.push_str(rest);
        res
    }
}

/// The type of `__pond_r` in a checked program.
fn result_ty(tp: &TypedProgram) -> Ty {
    let root = tp.program.root;
    tp.tables[root].locals.iter().rev().find(|l| l.name == RESULT).map(|l| l.ty.clone()).unwrap_or(Ty::Error)
}

/// The definitions of a parsed input, each with its own lines (doc comments above it included).
fn split_items(origin: &Rc<Origin>, m: &Module) -> Result<Vec<Def>, String> {
    let lines: Vec<&str> = origin.text.lines().collect();
    let mut out = Vec::new();
    let mut prev_end = 0u32;
    for item in &m.items {
        let (key, span, clauses, body_col) = match item {
            AstItem::Fn(g) => {
                let first = g.header.as_deref().or(g.clauses.first()).expect("a group has a clause");
                let last = g.clauses.last().unwrap_or(first);
                let c0 = g.clauses.first().unwrap_or(first);
                let body = match &c0.body {
                    Some(FnBody::Expr(e)) if e.span.line == c0.span.line => Some(e.span.col),
                    Some(FnBody::Block(b)) if b.span.line == c0.span.line => Some(b.span.col),
                    _ => None,
                };
                (Key::Fn(g.name.clone(), g.arity), first.span.to(last.span), g.clauses.len(), body.filter(|_| g.header.is_none()))
            }
            AstItem::Struct(s) => (Key::Type(s.name.name.clone()), s.span, 1, None),
            AstItem::Enum(e) => (Key::Type(e.name.name.clone()), e.span, 1, None),
            AstItem::Shape(s) => (Key::Type(s.name.name.clone()), s.span, 1, None),
            AstItem::Test(t) => (Key::Test(t.name.clone()), t.span, 1, None),
            AstItem::Let(c) | AstItem::Imprint(c) => (Key::Const(c.name.name.clone()), c.span, 1, None),
            AstItem::ExternType(t) => (Key::Type(t.name.name.clone()), t.span, 1, None),
        };
        let mut start = span.line;
        while start > prev_end + 1 && lines.get(start as usize - 2).is_some_and(|l| l.trim_start().starts_with("///")) {
            start -= 1;
        }
        if start <= prev_end {
            return Err("error: put each definition on its own lines".into());
        }
        prev_end = span.end_line;
        let text: String = lines[start as usize - 1..(span.end_line as usize).min(lines.len())].iter().map(|l| format!("{l}\n")).collect();
        let head = lines.get(span.line as usize - 1).copied().unwrap_or("");
        let label = match body_col {
            Some(col) => head.chars().take(col as usize - 1).collect::<String>().trim_end().trim_end_matches('=').trim_end().to_string(),
            None if span.line == span.end_line => head.trim().to_string(),
            None => head.trim().trim_end_matches('{').trim_end().to_string(),
        };
        out.push(Def { key, label: label.trim().to_string(), clauses, parts: vec![Part { origin: origin.clone(), first: start, text }] });
    }
    Ok(out)
}

/// The definitions with `new` added: a definition with the same key is replaced in place, except
/// that with `append` new clauses for an existing function join its clause group.
fn merge(defs: &[Def], new: &[Def], append: bool) -> Vec<Def> {
    let mut out = defs.to_vec();
    for d in new {
        match out.iter_mut().find(|o| o.key == d.key) {
            Some(o) if append && matches!(d.key, Key::Fn(..)) => {
                o.parts.extend(d.parts.iter().cloned());
                o.clauses += d.clauses;
            }
            Some(o) => *o = d.clone(),
            None => out.push(d.clone()),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kinds() {
        assert_eq!(classify("fn f(x: int): int = x\n").unwrap(), Kind::Item);
        assert_eq!(classify("struct P { x: int }\n").unwrap(), Kind::Item);
        assert_eq!(classify("shape Area { fn area(self): float }\n").unwrap(), Kind::Item);
        assert_eq!(classify("test \"t\" { assert 1 == 1 }\n").unwrap(), Kind::Item);
        assert_eq!(classify("imprint T = 1\n").unwrap(), Kind::Item);
        assert_eq!(classify("let x = 5\n").unwrap(), Kind::Stmt);
        assert_eq!(classify("n += 1\n").unwrap(), Kind::Stmt);
        assert_eq!(classify("xs[0] = 1\n").unwrap(), Kind::Stmt);
        assert_eq!(classify("1 + 2\n").unwrap(), Kind::Expr);
        assert_eq!(classify("test\n").unwrap(), Kind::Expr);
        assert_eq!(classify("[1, 2].map(x => x * 2)\n").unwrap(), Kind::Expr);
        assert!(classify("1 +* 2\n").is_err());
    }

    #[test]
    fn continuation() {
        assert!(incomplete("fn f(x: int): int {\n"));
        assert!(incomplete("[1,\n"));
        assert!(incomplete("let x =\n"));
        assert!(incomplete("1 +\n"));
        assert!(incomplete("\"\"\"\nabc\n"));
        assert!(incomplete("/* c\n"));
        assert!(!incomplete("1 + 2\n"));
        assert!(!incomplete("fn f(x: int): int {\n  x\n}\n"));
        assert!(!incomplete("let s = \"a {x}\"\n"));
    }

    #[test]
    fn splitting_and_merging() {
        let src = "/// A point.\nstruct P { x: int }\nfn f(0): int = 0\nfn f(n: int): int {\n  n\n}\n";
        let o = Rc::new(Origin { name: "pond".into(), text: src.into() });
        let m = parser::parse(src).unwrap();
        let defs = split_items(&o, &m).unwrap();
        assert_eq!(defs.len(), 2);
        assert_eq!(defs[0].parts[0].text, "/// A point.\nstruct P { x: int }\n");
        assert_eq!(defs[0].label, "struct P { x: int }");
        assert_eq!(defs[1].parts[0].first, 3);
        assert_eq!(defs[1].label, "fn f(0): int");
        assert_eq!(defs[1].clauses, 2);
        let merged = merge(&defs, &defs[1..], true);
        assert_eq!(merged[1].clauses, 4);
        let replaced = merge(&defs, &defs[1..], false);
        assert_eq!(replaced[1].clauses, 2);
    }
}

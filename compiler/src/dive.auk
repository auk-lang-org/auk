/// `auk dive [--quiet]` (src/repl.rs): the interactive REPL. See the Rust module for how a
/// session works (every input compiled and run as a whole program: the session's definitions,
/// then a `main` that replays the earlier statements behind a marker and runs the new input);
/// this is a line-by-line port, with the same names, output, prompts and exit codes.
///
/// Differences from Rust:
/// - An `Rc<Origin>` is an `Origin` with an `id` (Rust's `Rc::ptr_eq` compares ids). `Key`'s
///   `Fn` is `Func` (`fn` is a keyword). `Prog` keeps its source as a list of lines.
/// - `Session::check` is `check_prog` (a function named `check` would read as the module);
///   `Drop` is `close`, called when `run` returns.
/// - Lines come from `env.read_line` (C's buffered stdin), which ends the session at the end of
///   input, as Rust's `read_line` does; invalid UTF-8 there is not an error (Rust stops).
/// - Each input's program is JIT-compiled (`drive.generate`, `backend.jit` at O0) and runs in
///   a forked child with stdin from `/dev/null` and stdout and stderr merged in one file
///   (`posix.run_forked_merged`, Rust's `run_forked` with `Redirect { merged, stdin_null }`).
/// - `env::temp_dir()` is `$TMPDIR`, else `/tmp`. `str::trim*`, `split_whitespace` and
///   `split_once(char::is_whitespace)` use Unicode White_Space (`lexer.is_whitespace`), as Rust;
///   `fs::read_to_string`'s and `fs::write`'s errors read as Rust's (`paths.io_error`).

/// The prompts.
let PROMPT = "🦆> "
let CONT = ".. "
let MARK = "\u{1}dive-start\n"
let VALUE_MARK = "\u{1}dive-value\n"
/// `print({MARK:?})` and `print({VALUE_MARK:?})`, as Rust's `Debug` writes the strings.
let MARK_LINE = "print(\"\\u{{1}}dive-start\")"
let VALUE_MARK_LINE = "print(\"\\u{{1}}dive-value\")"
/// The effects `main` declares, so any input may use them.
let EFFECTS = ["fs", "net", "time", "rand", "env", "proc", "audio_out", "gui"]
/// The name of the binding an expression's value is stored in.
let RESULT = "__pond_r"

let HELP = """
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
  :save <file>       write the session as a formatted .auk file
  :explain <E0xxx>   explain an error code
  :quit              leave (Ctrl-D also works)

A line ending in an operator, `=` or `,`, or with an open bracket or string, continues on the
next line (`..`); a blank line ends it early.
Each input compiles and runs a small native program: the session's definitions plus a main that
replays the earlier statements (their output is hidden) and then runs the new input. So
replayed statements run again (`rand`, `time` and files see the re-run). Inputs that fail to
check or panic are not kept.
"""

/// `print!`.
fn say(s: str) uses ffi { posix.print_raw(s) }

/// `auk dive [--quiet]`. Returns the exit code.
pub fn run(cx: resolve.Sources, args: [str]): int uses fs, env, proc, ffi {
  var quiet = !env.is_terminal(0)
  for a in args {
    if a == "--quiet" || a == "-q" {
      quiet = true
    } else {
      eprint("usage: auk dive [--quiet]")
      return 2
    }
  }
  var s = match new_session(cx) {
    ok(s) => s
    err(e) => {
      posix.eprint_raw("{e}")
      return 1
    }
  }
  if !quiet { say("Auk {version.text()} dive: :help for commands\n") }
  var buf = ""
  // The rendered E0400 errors of a clause group waiting for more clauses.
  var pending: str? = none
  loop {
    if !quiet { say(if buf == "" { PROMPT } else { CONT }) }
    posix.flush()
    let read = env.read_line()
    if read == none {
      match pending {
        some(errs) => say(errs)
        none => if trim(buf) != "" { let _ = eval(&s, buf) }
      }
      if !quiet { say("\n") }
      break
    }
    let line = trim_line_end(read!)
    match pending {
      some(errs) when trim(line) == "" || !starts_clause(line) => {
        say(errs)
        pending = none
        buf = ""
        if trim(line) == "" { continue }
      }
      _ => {}
    }
    if buf == "" {
      if trim(line) == "" { continue }
      match trim_start(line).strip_prefix(":") {
        some(cmd) => {
          if !command(&s, trim(cmd)) { break }
          continue
        }
        none => {}
      }
    } else if trim(line) == "" && pending == none && !in_triple_string(buf) {
      // A blank line ends an unfinished input early (to show its error).
      let _ = eval(&s, buf)
      buf = ""
      continue
    }
    buf = buf + line + "\n"
    if pending == none && incomplete(buf) { continue }
    match eval(&s, buf) {
      MoreClauses(errs) => pending = some(errs)
      _ => {
        pending = none
        buf = ""
      }
    }
  }
  close(s)
  0
}

/// `line.trim_end_matches(['\n', '\r'])`.
fn trim_line_end(line: str): str {
  var l = line
  while l.ends_with("\n") || l.ends_with("\r") { l = l[0..l.len() - 1] }
  l
}

/// Rust's `str::trim`.
fn trim(s: str): str = trim_end(trim_start(s))

/// Rust's `str::trim_start`.
fn trim_start(s: str): str {
  let cs = s.chars()
  var i = 0
  while i < cs.len() && lexer.is_whitespace(cs[i]) { i += 1 }
  if i == 0 { s } else { str(cs.skip(i)) }
}

/// Rust's `str::trim_end`.
fn trim_end(s: str): str {
  let cs = s.chars()
  var j = cs.len()
  while j > 0 && lexer.is_whitespace(cs[j - 1]) { j -= 1 }
  if j == cs.len() { s } else { str(cs[0..j]) }
}

/// Rust's `str::split_whitespace`.
fn split_whitespace(s: str): [str] {
  var out: [str] = []
  var cur: [char] = []
  for c in s.chars() {
    if lexer.is_whitespace(c) {
      if cur.len() > 0 { out.push(str(cur)) }
      cur = []
    } else {
      cur.push(c)
    }
  }
  if cur.len() > 0 { out.push(str(cur)) }
  out
}

/// Does `line` continue a clause group (another `fn`, doc comment or `pub fn`)?
fn starts_clause(line: str): bool {
  let t = trim_start(line)
  t.starts_with("fn ") ||
    t.starts_with("pub fn ") ||
    t.starts_with("async fn ") ||
    t.starts_with("///")
}

/// Is the input unfinished: an open bracket, string or block comment, or a last line ending in
/// an operator, `=`, `=>` or `,` (the lexer's newline rule)?
pub fn incomplete(src: str): bool {
  match lexer.lex(src) {
    err(Bad(d)) => d.code == "E0002" || d.code == "E0003" || d.code == "E0012"
    ok(l) => {
      var i = l.toks.len() - 1
      while i >= 0 {
        let t = l.toks[i].tok
        if t != token.Newline && t != token.Eof { return continues(t) }
        i -= 1
      }
      false
    }
  }
}

/// Does a line ending in `t` continue on the next line?
fn continues(t: token.Tok): bool = match t {
  Plus | Minus | Star | Slash | Percent | StarStar | PlusWrap | MinusWrap | StarWrap => true
  EqEq | BangEq | Lt | Le | Gt | Ge | AndAnd | OrOr => true
  PlusEq | MinusEq | StarEq | SlashEq | PercentEq => true
  Amp | Pipe | Caret | Tilde | Shl | AmpEq | PipeEq | CaretEq | ShlEq => true
  Eq | FatArrow | Comma | PipeGt | Dot | DotDot | DotDotEq | Colon => true
  _ => false
}

/// Inside an unterminated `"""` string (where blank lines are content)?
fn in_triple_string(src: str): bool {
  if !src.contains("\"\"\"") { return false }
  match lexer.lex(src) {
    err(Bad(d)) => d.code == "E0002"
    ok(_) => false
  }
}

/// What kind of input this is.
pub enum Kind { Item, Stmt, Expr }

/// `Some(Tok::Ident(s))` with `s` among `names`?
fn ident_in(t: token.Tok?, names: [str]): bool = match t {
  some(Ident(s)) => names.contains(s)
  _ => false
}

/// Decide the kind of a (complete, lexable) input. A parse error of a statement or expression
/// is reported as `Err` (rendered against the input).
pub fn classify(src: str): Kind!parser.Fails {
  let toks = match lexer.lex(src) {
    ok(l) => l.toks
    err(Bad(d)) => return fail(parser.Many([d]))
  }
  let ts = toks.filter(t => t.tok != token.Newline).map(t => t.tok)
  let first = ts.get(0)
  let second = ts.get(1)
  let second_ident = match second {
    some(Ident(_)) => true
    _ => false
  }
  match first {
    some(t) => match t {
      Fn | Struct | Enum | Pub | Async => return Kind.Item
      Let | Var | For | While | Assert => return Kind.Stmt
      _ => {}
    }
    none => {}
  }
  if ident_in(first, ["shape", "imprint"]) && second_ident { return Kind.Item }
  if ident_in(first, ["test"]) {
    match second {
      some(Str(_)) => return Kind.Item
      _ => {}
    }
  }
  if ident_in(first, ["extern"]) && (second == some(token.Fn) || ident_in(second, ["type"])) {
    return Kind.Item
  }
  let wrapped = "fn main() {{\n{src}\n}}\n"
  let m = match parser.parse(wrapped, false) {
    ok(m) => m
    err(Many(ds)) => return fail(parser.Many(ds.map(d => shift(d, 1))))
  }
  let stmts = match m.items.get(0) {
    some(Fn(g)) => match g.clauses.get(0) {
      some(c) => match c.body {
        some(Block(b)) => b.stmts
        _ => return Kind.Stmt
      }
      none => return Kind.Stmt
    }
    _ => return Kind.Stmt
  }
  if stmts.len() != 1 { return Kind.Stmt }
  match stmts[0].kind {
    Let(_, _, _, _, _) | Assign(_, _, _) | Assert(_) | While(_, _) | For(_, _, _, _) => Kind.Stmt
    _ => Kind.Expr
  }
}

/// Move a diagnostic `delta` lines up.
fn shift(d: diag.Diag, delta: int): diag.Diag {
  let up = (l: int) => max(max(l - delta, 0), 1)
  let sp = d.span
  var d2 = d
  d2.span = diag.Span { line: up(sp.line), end_line: up(sp.end_line), ..sp }
  d2.fixes = d.fixes.map(f => diag.Fix {
    span: diag.Span { line: up(f.span.line), end_line: up(f.span.end_line), ..f.span },
    text: f.text,
  })
  d2
}

/// Where some source lines came from: an input (or a loaded file) and its text. `id` tells
/// origins apart (Rust compares the `Rc`s).
struct Origin { id: int, name: str, text: str }

/// A run of lines of an origin, starting at its line `first` (1-based).
struct Part { origin: Origin, first: int, text: str }

fn whole(origin: Origin): Part = Part { origin, first: 1, text: origin.text }

/// What identifies a definition, for replacing or extending it.
enum Key {
  Func(name: str, arity: int),
  Type(name: str),
  Const(name: str),
  Test(name: str),
}

fn is_fn_key(k: Key): bool = match k {
  Func(_, _) => true
  _ => false
}

fn is_main(d: Def): bool = match d.key {
  Func(n, _) => n == "main"
  _ => false
}

/// One definition of the session (a clause group may come from several inputs).
struct Def { key: Key, label: str, clauses: int, parts: [Part] }

/// A generated program: its source (by line) and, per line, the part line it came from.
struct Prog { src_lines: [str], lines: [(Origin, int)?] }

fn new_prog(): Prog = Prog { src_lines: [], lines: [] }

fn prog_src(p: Prog): str = p.src_lines.map(l => l + "\n").join("")

fn scaffold(p: var Prog, text: str) {
  for l in mir.progen.rust_lines(text) {
    p.src_lines.push(l)
    p.lines.push(none)
  }
}

fn add_part(p: var Prog, part: Part) {
  for i, l in mir.progen.rust_lines(part.text) {
    p.src_lines.push(l)
    p.lines.push(some((part.origin, part.first + i)))
  }
}

/// The origin and origin line of generated line `line`.
fn origin_of(p: Prog, line: int): (Origin, int)? {
  if line < 1 { return none }
  match p.lines.get(line - 1) {
    some(o) => o
    none => none
  }
}

/// A piece of `main` after the replayed statements.
enum Piece {
  Scaffold(s: str),
  PPart(p: Part),
}

pub enum Outcome {
  Done,
  /// The input was rejected (its errors are shown).
  Failed,
  /// A clause group that doesn't cover every case yet: wait for more clauses (the rendered
  /// errors are shown if none come).
  MoreClauses(errs: str),
}

struct Session {
  cx: resolve.Sources,
  defs: [Def],
  history: [Part],
  dir: str,
  /// The generated source's path (as diagnostics and panics name it).
  src_path: str,
  builds: int,
  /// The next origin's id.
  origins: int,
}

/// `fs::remove_dir_all`, errors ignored.
fn remove_all(p: str) uses fs {
  if fs.is_dir(p) {
    for n in (fs.list(p) else []) { remove_all(paths.join(p, n)) }
  }
  let _ = fs.remove(p)
}

/// `fs::create_dir_all`.
fn mkdir_all(dir: str): ()! uses fs {
  if dir == "" || fs.is_dir(dir) { return }
  match paths.parent(dir) {
    some(p) => mkdir_all(p)?
    none => {}
  }
  fs.mkdir(dir)?
}

fn new_session(cx: resolve.Sources): Session! uses fs, env, ffi {
  let tmp = env.get("TMPDIR") else "/tmp"
  let dir = paths.join(tmp, "auk-dive-{posix.pid()}")
  remove_all(dir)
  match mkdir_all(dir) {
    ok(_) => {}
    err(e) => return fail("error: cannot create {dir}: {paths.io_error(e.show())}\n")
  }
  let src_path = paths.join(dir, "dive.auk")
  Session { cx, defs: [], history: [], dir, src_path, builds: 0, origins: 0 }
}

/// Rust's `Drop`: the session's directory goes.
fn close(s: Session) uses fs { remove_all(s.dir) }

fn new_origin(s: var Session, name: str, text: str): Origin {
  s.origins += 1
  Origin { id: s.origins, name, text }
}

/// Handle a `:command`. Returns false to quit.
fn command(s: var Session, cmd: str): bool uses fs, ffi {
  let cs = cmd.chars()
  var name = cmd
  var arg = ""
  match cs.find_index(c => lexer.is_whitespace(c)) {
    some(i) => {
      name = str(cs[0..i])
      arg = trim(str(cs.skip(i + 1)))
    }
    none => {}
  }
  if name == "q" || name == "quit" || name == "exit" { return false }
  if name == "h" || name == "help" || name == "?" {
    say(HELP)
  } else if (name == "t" || name == "type") && arg != "" {
    type_of(&s, arg)
  } else if name == "items" {
    items(s)
  } else if name == "reset" {
    s.defs = []
    s.history = []
    say("session cleared\n")
  } else if name == "load" && arg != "" {
    load(&s, arg)
  } else if name == "save" && arg != "" {
    save(s, arg)
  } else if name == "explain" {
    posix.flush()
    let _ = explain.run(split_whitespace(arg))
    posix.flush()
  } else {
    say("unknown command `:{cmd}` (try :help)\n")
  }
  true
}

/// Evaluate one complete input.
fn eval(s: var Session, text: str): Outcome uses fs, env, proc, ffi {
  let origin = new_origin(&s, "dive", text)
  match classify(text) {
    err(Many(ds)) => {
      say(ds.map(d => d.render(origin.name, text)).join(""))
      Outcome.Done
    }
    ok(Item) => add_items(&s, origin, false)
    ok(Stmt) => {
      statement(&s, origin)
      Outcome.Done
    }
    ok(Expr) => {
      expression(&s, origin)
      Outcome.Done
    }
  }
}

/// Build the program: the definitions, then `main` with the history and `tail`.
fn program(s: Session, defs: [Def], tail: [Piece]): Prog {
  var p = new_prog()
  for d in defs {
    for part in d.parts { add_part(&p, part) }
    scaffold(&p, "")
  }
  scaffold(&p, "fn main(): ()! uses {EFFECTS.join(", ")} {{")
  for h in s.history { add_part(&p, h) }
  scaffold(&p, MARK_LINE)
  for t in tail {
    match t {
      Scaffold(x) => scaffold(&p, x)
      PPart(part) => add_part(&p, part)
    }
  }
  scaffold(&p, "()\n}}")
  p
}

/// Type-check a generated program (Rust's `Session::check`).
fn check_prog(s: Session, p: Prog): typed.TypedProgram!diag.FileFails uses fs, ffi {
  let prog = resolve.load_source(s.cx, s.src_path, prog_src(p))?
  match check.check_all(prog) {
    (some(tp), _) => {
      var t = tp
      units.erase(&t)
      t
    }
    (none, ds) => fail(diag.Many(ds))
  }
}

/// Render the errors (warnings are dropped: the scaffold's `uses` is always too wide), each
/// against the input it came from. Also says whether every error is in `origin`.
fn render_errs(s: Session, p: Prog, diags: [diag.FileDiag], origin: Origin): (str, bool) uses fs {
  var out: [str] = []
  var all_in = true
  let gen_file = s.src_path
  for fd in diags {
    if fd.diag.is_warning() { continue }
    if fd.file != gen_file {
      all_in = false
      out.push(fd.diag.render(fd.file, resolve.source_of(s.cx, fd.file) else ""))
      continue
    }
    match origin_of(p, fd.diag.span.line) {
      some((o, line)) => {
        all_in = all_in && o.id == origin.id
        out.push(shift(fd.diag, fd.diag.span.line - line).render(o.name, o.text))
      }
      none => {
        all_in = false
        out.push(fd.diag.render("<dive>", prog_src(p)))
      }
    }
  }
  (out.join(""), all_in)
}

/// Definitions: add (or extend, or replace) them and check.
fn add_items(s: var Session, origin: Origin, loading: bool): Outcome uses fs, ffi {
  let text = origin.text
  let module = match parser.parse(text, false) {
    ok(m) => m
    err(Many(ds)) => {
      say(ds.map(d => d.render(origin.name, text)).join(""))
      return Outcome.Failed
    }
  }
  var added = match split_items(origin, module) {
    ok(n) => n
    err(e) => {
      say("{e}\n")
      return Outcome.Failed
    }
  }
  if added.any(d => is_main(d)) {
    if !loading {
      say("dive runs each input in its own `main`; define `main` in a file and use `auk run`\n")
      return Outcome.Failed
    }
    added = added.filter(d => !is_main(d))
    say("note: skipped `main` in {origin.name}\n")
  }
  let append = merge(s.defs, added, true)
  let replace = merge(s.defs, added, false)
  var errs = ""
  var all_in = false
  var only_e0400 = false
  var have = false
  for i, cand in [append, replace] {
    let p = program(s, cand, [])
    match check_prog(s, p) {
      ok(_) => {
        s.defs = cand
        return Outcome.Done
      }
      err(Many(ds)) => {
        if i == 1 || !have {
          only_e0400 = ds.filter(d => !d.diag.is_warning()).all(d => d.diag.code == "E0400")
          let (r, a) = render_errs(s, p, ds, origin)
          errs = r
          all_in = a
          have = true
        }
      }
    }
  }
  let all_fns = added.all(d => is_fn_key(d.key))
  if !loading && only_e0400 && all_in && all_fns {
    return Outcome.MoreClauses(errs)
  }
  say(errs)
  Outcome.Failed
}

/// A statement: run it; keep it when it succeeds.
fn statement(s: var Session, origin: Origin) uses fs, env, proc, ffi {
  let part = whole(origin)
  let p = program(s, s.defs, [Piece.PPart(part)])
  let tp = match check_prog(s, p) {
    ok(tp) => tp
    err(Many(ds)) => {
      say(render_errs(s, p, ds, origin).0)
      return
    }
  }
  let (good, out) = exec(&s, tp, p)
  say(out)
  if good { s.history.push(part) }
}

/// An expression: print its value and type. A `()` expression joins the history.
fn expression(s: var Session, origin: Origin) uses fs, env, proc, ffi {
  let part = whole(origin)
  let let_line = "let {RESULT} ="
  let show_line = "print([{RESULT}].show())"
  // Usually one check: the program that also shows the value. Only when that fails is
  // the plain `let` checked, for the right errors (or for a value without `Show`).
  let display = program(s, s.defs, [
    Piece.Scaffold(let_line),
    Piece.PPart(part),
    Piece.Scaffold(VALUE_MARK_LINE),
    Piece.Scaffold(show_line),
  ])
  var ty = types.Ty.Error
  var shown = ""
  var good = false
  var out = ""
  match check_prog(s, display) {
    ok(tp) => {
      ty = result_ty(tp)
      shown = tp.defs.show(ty)
      let (g, o) = exec(&s, tp, display)
      good = g
      out = o
    }
    err(_) => {
      let typing = program(s, s.defs, [Piece.Scaffold(let_line), Piece.PPart(part)])
      let tp = match check_prog(s, typing) {
        ok(tp) => tp
        err(Many(ds)) => {
          say(render_errs(s, typing, ds, origin).0)
          return
        }
      }
      // No `Show` for this type (a closure, a task): run it and show only the type.
      ty = result_ty(tp)
      shown = tp.defs.show(ty)
      let (g, o) = exec(&s, tp, typing)
      let what = match ty {
        Fn(_, _) => "<fn>"
        _ => "<value>"
      }
      good = g
      out = if g { "{o}{VALUE_MARK}[{what}]\n" } else { o }
    }
  }
  let at = if good { out.find(VALUE_MARK) } else { none }
  let i = match at {
    some(i) => i
    none => {
      say(out)
      return
    }
  }
  let before = out[0..i]
  let after = out[i + VALUE_MARK.len()..out.len()]
  say(before)
  if ty.is_unit() {
    // `()` prints nothing, and the input joins the history (it may mutate something).
    s.history.push(part)
  } else if ty != types.Ty.Never {
    var value = after
    while value.ends_with("\n") { value = value[0..value.len() - 1] }
    if value.starts_with("[") {
      match value[1..value.len()].strip_suffix("]") {
        some(v) => value = v
        none => {}
      }
    }
    say("{value} : {shown}\n")
  }
}

/// `:type <expr>`.
fn type_of(s: var Session, text: str) uses fs, ffi {
  let origin = new_origin(&s, "dive", "{text}\n")
  let part = whole(origin)
  let p = program(s, s.defs, [Piece.Scaffold("let {RESULT} ="), Piece.PPart(part)])
  match check_prog(s, p) {
    ok(tp) => say("{tp.defs.show(result_ty(tp))}\n")
    err(Many(ds)) => say(render_errs(s, p, ds, origin).0)
  }
}

/// `:items`.
fn items(s: Session) uses ffi {
  if s.defs.len() == 0 { say("(no definitions)\n") }
  for d in s.defs {
    if d.clauses > 1 {
      say("{d.label}  ({d.clauses} clauses)\n")
    } else {
      say("{d.label}\n")
    }
  }
}

/// `:load <file>`.
fn load(s: var Session, file: str) uses fs, ffi {
  match paths.read(file) {
    ok(text) => {
      let origin = new_origin(&s, file, text)
      match add_items(&s, origin, true) {
        Done => say("loaded {file}\n")
        _ => {}
      }
    }
    err(e) => say("error: cannot read {file}: {e}\n")
  }
}

/// The session as a program: the definitions, then a `main` with the statements (declaring
/// only the effects they use).
fn session_source(s: Session): str uses fs, ffi {
  var effects = EFFECTS
  let p = program(s, s.defs, [])
  match resolve.load_source(s.cx, s.src_path, prog_src(p)) {
    ok(prog) => {
      let (_, diags) = check.check_all(prog)
      for d in diags {
        if d.diag.code != "E0411" { continue }
        // "`main` declares the effects `fs`, `net` but doesn't use them"
        let ps = d.diag.message.split("`")
        var unused: [str] = []
        var k = 3
        while k < ps.len() {
          unused.push(ps[k])
          k += 2
        }
        effects = effects.filter(e => !unused.contains(e))
      }
    }
    err(_) => {}
  }
  var out = ""
  for d in s.defs {
    for part in d.parts {
      out = out + part.text
      if !out.ends_with("\n") { out = out + "\n" }
    }
    out = out + "\n"
  }
  if s.history.len() > 0 {
    let uses_ = if effects.len() == 0 { "" } else { " uses {effects.join(", ")}" }
    out = out + "fn main(): ()!{uses_} {{\n"
    for h in s.history {
      out = out + h.text
      if !out.ends_with("\n") { out = out + "\n" }
    }
    out = out + "}}\n"
  }
  out
}

/// `:save <file>`.
fn save(s: Session, file: str) uses fs, ffi {
  let raw = session_source(s)
  let text = fmt.format(raw) else raw
  match fs.write(file, text) {
    ok(_) => say("saved {file}\n")
    err(e) => say("error: cannot write {file}: {paths.io_error(e.show())}\n")
  }
}

/// Compile and run a checked program. Returns whether it succeeded and its output after
/// the marker (with panic locations mapped back to the inputs).
/// It is compiled in memory and runs in a forked child: stdin closed, stdout and stderr
/// merged (in order) in one file.
fn exec(s: var Session, tp: typed.TypedProgram, p: Prog): (bool, str) uses fs, env, proc, ffi {
  let g = match drive.generate(tp, mir.progen.Mode.Run, mir.progen.no_trace()) {
    ok(g) => g
    err(e) => return (false, "{e}")
  }
  let code = match backend.jit(g.prog, g.info, backend.Level.O0) {
    ok(c) => c
    err(e) => return (false, "error: {e}\n")
  }
  let entry = match orcjit.lookup(code, "dk_entry") {
    ok(x) => x
    err(e) => {
      orcjit.close(code)
      return (false, "error: {e}\n")
    }
  }
  s.builds += 1
  let out_file = paths.join(s.dir, "out{s.builds}")
  let args = [s.src_path]
  let r = posix.run_forked_merged(out_file, true, () => orcjit.run(entry, args))
  orcjit.close(code)
  let out = hatch.lossy(fs.read_bytes(out_file) else [])
  let _ = fs.remove(out_file)
  let good = match r {
    ok(c) => c == some(0)
    err(e) => return (false, "{e}")
  }
  let shown = match out.find(MARK) {
    some(i) => out[i + MARK.len()..out.len()]
    none => out
  }
  (good, map_locations(s, shown, p))
}

/// Rewrite `<generated file>:line:col` to the input's own name and line.
fn map_locations(s: Session, text: str, p: Prog): str {
  let file = s.src_path
  var res: [str] = []
  var rest = text
  loop {
    let i = rest.find(file) else break
    res.push(rest[0..i])
    rest = rest[i + file.len()..rest.len()]
    var digits = ""
    if rest.starts_with(":") {
      for c in rest.chars().skip(1) {
        if c < '0' || c > '9' { break }
        digits = digits + str([c])
      }
    }
    let line: int? = if digits == "" {
      none
    } else {
      match int.parse(digits) {
        ok(n) => some(n)
        err(_) => none
      }
    }
    match line {
      some(n) => match origin_of(p, n) {
        some((o, l)) => {
          res.push("{o.name}:{l}")
          rest = rest[1 + digits.len()..rest.len()]
        }
        none => res.push("<dive>")
      }
      none => res.push("<dive>")
    }
  }
  res.push(rest)
  res.join("")
}

/// The type of `__pond_r` in a checked program.
fn result_ty(tp: typed.TypedProgram): types.Ty {
  let locals = tp.tables[tp.program.root].locals
  var i = locals.len() - 1
  while i >= 0 {
    if locals[i].name == RESULT { return locals[i].ty }
    i -= 1
  }
  types.Ty.Error
}

/// `s.trim_end_matches(c)` for a one-char `c`.
fn trim_end_char(s: str, c: str): str {
  var t = s
  while t.ends_with(c) { t = t[0..t.len() - 1] }
  t
}

/// The definitions of a parsed input, each with its own lines (doc comments above it included).
fn split_items(origin: Origin, m: ast.Module): [Def]! {
  let lines = mir.progen.rust_lines(origin.text)
  var out: [Def] = []
  var prev_end = 0
  for item in m.items {
    let (key, span, clauses, body_col) = match item {
      Fn(g) => {
        let first = g.header else g.clauses[0]
        let last = g.clauses.last() else first
        let c0 = g.clauses.get(0) else first
        let body = match c0.body {
          some(Expr(e)) when e.span.line == c0.span.line => some(e.span.col)
          some(Block(b)) when b.span.line == c0.span.line => some(b.span.col)
          _ => none
        }
        let col = match g.header {
          some(_) => none
          none => body
        }
        (Key.Func(g.name, g.arity), first.span.to(last.span), g.clauses.len(), col)
      }
      Struct(d) => (Key.Type(d.name.name), d.span, 1, none)
      Enum(d) => (Key.Type(d.name.name), d.span, 1, none)
      Shape(d) => (Key.Type(d.name.name), d.span, 1, none)
      Test(d) => (Key.Test(d.name), d.span, 1, none)
      Let(c) => (Key.Const(c.name.name), c.span, 1, none)
      Imprint(c) => (Key.Const(c.name.name), c.span, 1, none)
      ExternType(d) => (Key.Type(d.name.name), d.span, 1, none)
      Global(d) => (Key.Const(d.name.name), d.span, 1, none)
      RawAssert(a) => (Key.Const("raw assert {a.span.line}"), a.span, 1, none)
      RawType(d) => (Key.Type(d.name.name), d.span, 1, none)
    }
    var start = span.line
    while start > prev_end + 1 &&
      start - 2 < lines.len() &&
      trim_start(lines[start - 2]).starts_with("///") {
      start -= 1
    }
    if start <= prev_end { return fail("error: put each definition on its own lines") }
    prev_end = span.end_line
    let text = lines[start - 1..min(span.end_line, lines.len())].map(l => l + "\n").join("")
    let head = lines.get(span.line - 1) else ""
    let label = match body_col {
      some(col) => trim_end(trim_end_char(trim_end(str(head.chars().take(col - 1))), "="))
      none => if span.line == span.end_line {
        trim(head)
      } else {
        trim_end(trim_end_char(trim(head), "{{"))
      }
    }
    out.push(Def { key, label: trim(label), clauses, parts: [Part { origin, first: start, text }] })
  }
  out
}

/// The definitions with `added` added: a definition with the same key is replaced in place,
/// except that with `append` new clauses for an existing function join its clause group.
fn merge(defs: [Def], added: [Def], append: bool): [Def] {
  var out = defs
  for d in added {
    match out.find_index(o => o.key == d.key) {
      some(i) => if append && is_fn_key(d.key) {
        out[i].parts = out[i].parts + d.parts
        out[i].clauses += d.clauses
      } else {
        out[i] = d
      }
      none => out.push(d)
    }
  }
  out
}

test "kinds" {
  assert classify("fn f(x: int): int = x\n") is ok(Item)
  assert classify("struct P {{ x: int }}\n") is ok(Item)
  assert classify("shape Area {{ fn area(self): float }}\n") is ok(Item)
  assert classify("test \"t\" {{ assert 1 == 1 }}\n") is ok(Item)
  assert classify("imprint T = 1\n") is ok(Item)
  assert classify("let x = 5\n") is ok(Stmt)
  assert classify("n += 1\n") is ok(Stmt)
  assert classify("xs[0] = 1\n") is ok(Stmt)
  assert classify("1 + 2\n") is ok(Expr)
  assert classify("test\n") is ok(Expr)
  assert classify("[1, 2].map(x => x * 2)\n") is ok(Expr)
  assert classify("1 +* 2\n") is err(_)
}

test "continuation" {
  assert incomplete("fn f(x: int): int {{\n")
  assert incomplete("[1,\n")
  assert incomplete("let x =\n")
  assert incomplete("1 +\n")
  assert incomplete("\"\"\"\nabc\n")
  assert incomplete("/* c\n")
  assert !incomplete("1 + 2\n")
  assert !incomplete("fn f(x: int): int {{\n  x\n}}\n")
  assert !incomplete("let s = \"a {{x}}\"\n")
}

test "splitting and merging" {
  let text =
    "/// A point.\nstruct P {{ x: int }}\nfn f(0): int = 0\nfn f(n: int): int {{\n  n\n}}\n"
  let o = Origin { id: 1, name: "dive", text }
  let m = parser.parse(text, false)!
  let defs = split_items(o, m)!
  assert defs.len() == 2
  assert defs[0].parts[0].text == "/// A point.\nstruct P {{ x: int }}\n"
  assert defs[0].label == "struct P {{ x: int }}"
  assert defs[1].parts[0].first == 3
  assert defs[1].label == "fn f(0): int"
  assert defs[1].clauses == 2
  let merged = merge(defs, defs.skip(1), true)
  assert merged[1].clauses == 4
  let replaced = merge(defs, defs.skip(1), false)
  assert replaced[1].clauses == 2
}

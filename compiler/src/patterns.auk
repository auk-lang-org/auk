/// Exhaustiveness and reachability of patterns (src/patterns.rs): the usefulness algorithm of
/// Maranget, "Warnings for pattern matching" (JFP 2007), over the typed patterns of the checked
/// program. See the Rust module's docs for the pattern space.
///
/// Checked here, after typing: every clause group (one `FnInfo`: its clauses' parameter lists
/// are the rows of a matrix, one column per parameter), every `match` (one column, one row per
/// arm alternative), `let pat = e else ..` with a refutable pattern (the `else` must be needed:
/// E0402) and patterns that must always match (`let` without `else`, `for`, closure
/// parameters: E0403). A row with a `when` guard never counts toward exhaustiveness.
///
/// Differences from Rust: `Option<Option<usize>>` (reachability) is `Reach`; the optional set
/// of binding names in use (`&mut Option<HashSet<String>>`) is a `var Names`; Rust's `show_args`
/// closure is the method `show_args`.

/// How many missing cases a diagnostic lists.
let SHOW = 3

/// A constructor (see the module docs).
enum Ctor {
  /// The i-th constructor of a finite sum: `false`/`true`, `none`/`some`, `ok`/`err`, variants.
  Idx(i: int),
  /// The only constructor of a tuple or struct.
  Single,
  /// A literal of an infinite domain, by a canonical key.
  Lit(key: str),
  /// A list of exactly this length.
  Len(n: int),
  /// A list of at least this length (the last length class).
  LenMin(n: int),
  /// An open map pattern with these (sorted) keys.
  Keys(ks: [str]),
  /// `"prefix" + rest`.
  Prefix(s: str),
  /// A typed error payload variant inside a plain `Err`, with its field types.
  Payload(d: int, i: int, tys: [types.Ty]),
}

/// Rust's `PartialEq for Ctor`: a payload is equal by variant, whatever its field types.
fn ctor_eq(a: Ctor, b: Ctor): bool = match (a, b) {
  (Payload(d, i, _), Payload(e, j, _)) => d == e && i == j
  _ => a == b
}

/// A pattern of the matrix (or a witness: a pattern describing values that nothing matches).
enum P {
  Wild,
  C(c: Ctor, args: [P]),
  /// A list pattern with a rest: the patterns before and after the `..`.
  Slice(a: [P], b: [P]),
}

/// What the values of a type look like to the algorithm.
enum Kind { Finite(n: int), Single, List, Infinite }

/// One row: its patterns and whether it has a guard.
struct Row { pats: [P], guarded: bool }

/// Whether a row is reachable; if not, an earlier unguarded row that covers it alone, if any.
enum Reach { Live, Dead(single: int?) }

/// The binding names a shown witness may use (`on`: a fix-it is being built), each once.
struct Names { on: bool, used: {str: bool} }

fn no_names(): Names = Names { on: false, used: {} }

fn fresh_names(): Names = Names { on: true, used: {} }

struct Cx {
  tp: typed.TypedProgram,
  m: int,
  value_def: int?,
  out: [diag.FileDiag],
}

/// Check every clause group, `match`, `let` and binding pattern of the program.
pub fn check(tp: typed.TypedProgram): [diag.FileDiag] {
  var cx = new_cx(tp)
  for info in tp.fns {
    if tp.program.is_core(info.module) { continue }
    let Auk(item, clauses, header) = info.kind else { continue }
    let Fn(g) = tp.program.mods[info.module].ast.items[item] else { continue }
    cx.m = info.module
    let cls = clauses.map(i => g.clauses[i])
    cx.clause_group(info, cls)
    var all: [ast.FnClause] = []
    if header {
      match g.header {
        some(h) => all.push(h)
        none => {}
      }
    }
    for c in all + cls {
      match c.guard {
        some(e) => cx.expr(e)
        none => {}
      }
      for e in c.pre { cx.expr(e) }
      for e in c.post { cx.expr(e) }
      match c.body {
        some(Expr(e)) => cx.expr(e)
        some(Block(b)) => cx.block(b)
        _ => {}
      }
    }
  }
  for t in tp.tests {
    if tp.program.is_core(t.module) { continue }
    cx.m = t.module
    match tp.program.mods[t.module].ast.items[t.item] {
      Test(d) => cx.block(d.body)
      _ => {}
    }
  }
  for c in tp.consts {
    if tp.program.is_core(c.module) { continue }
    cx.m = c.module
    match tp.program.mods[c.module].ast.items[c.item] {
      Let(d) | Imprint(d) => cx.expr(d.value)
      _ => {}
    }
  }
  cx.out
}

/// The direct sub-expressions of `e`, in source order.
pub fn children(e: ast.Expr): [ast.Expr] {
  var out: [ast.Expr] = []
  match e.kind {
    Lit(_) | Name(_) | Hole | Continue | FieldSel(_) => {}
    TypeArgs(x, _) => out.push(x)
    Interp(parts) => for p in parts {
      match p {
        Expr(x, _) => out.push(x)
        _ => {}
      }
    }
    Measured(x, _) | Field(x, _) | TupleField(x, _) | Try(x) | Unwrap(x) | Await(x) | Catch(x) | AwaitAny(x) | Ref(x) | Unary(_, x) | Peek(x) | Assert(x) | Is(x, _) =>
      out.push(x)
    Call(callee, args) => {
      out.push(callee)
      out = out + args
    }
    MethodCall(recv, _, args) => {
      out.push(recv)
      out = out + args
    }
    Pipe(lhs, callee, args) => {
      out.push(lhs)
      out.push(callee)
      out = out + args
    }
    Index(x, index) => {
      out.push(x)
      out.push(index)
    }
    Slice(x, lo, hi, _) => {
      out.push(x)
      out.push(lo)
      out.push(hi)
    }
    Binary(_, lhs, rhs) => {
      out.push(lhs)
      out.push(rhs)
    }
    Range(lo, hi, _) => {
      out.push(lo)
      out.push(hi)
    }
    OptChain(x, _, args) => {
      out.push(x)
      match args {
        some(a) => out = out + a
        none => {}
      }
    }
    Else(x, arm) => {
      out.push(x)
      out.push(arm.body)
    }
    Closure(_, body) => out.push(body)
    If(cond, then, els) => {
      out.push(cond)
      out = out + then.stmts
      match els {
        some(x) => out.push(x)
        none => {}
      }
    }
    Match(scrut, arms) => {
      out.push(scrut)
      for a in arms {
        match a.guard {
          some(g) => out.push(g)
          none => {}
        }
        out.push(a.body)
      }
    }
    Loop(b) | Block(b) => out = out + b.stmts
    While(cond, body) => {
      out.push(cond)
      out = out + body.stmts
    }
    For(_, _, iter, body) => {
      out.push(iter)
      out = out + body.stmts
    }
    Let(_, _, _, value, els) => {
      out.push(value)
      match els {
        some(a) => out.push(a.body)
        none => {}
      }
    }
    Assign(_, target, value) => {
      out.push(target)
      out.push(value)
    }
    Return(x) | Break(x) => match x {
      some(v) => out.push(v)
      none => {}
    }
    Struct(_, fields, base) => {
      for f in fields {
        match f.value {
          some(v) => out.push(v)
          none => {}
        }
      }
      match base {
        some(b) => out.push(b)
        none => {}
      }
    }
    List(xs) | Tuple(xs) => out = out + xs
    Map(kvs) => for (k, v) in kvs {
      out.push(k)
      out.push(v)
    }
  }
  out
}

fn new_cx(tp: typed.TypedProgram): Cx {
  var value_def: int? = none
  for d, td in tp.defs.types {
    if td.name == "Value" && tp.program.is_core(td.module) {
      value_def = d
      break
    }
  }
  Cx { tp, m: 0, value_def, out: [] }
}

fn tables(cx: Cx): typed.Tables = cx.tp.tables[cx.m]

fn err(cx: var Cx, d: diag.Diag) {
  let file = cx.tp.program.mods[cx.m].file
  cx.out.push(diag.FileDiag { file, diag: d })
}

/// Line `k` (1-based) of the current module's source.
fn src_line(cx: Cx, k: int): str? {
  let ls = check.lines(cx.tp.program.mods[cx.m].src)
  ls.get(k - 1)
}

/// The source text of a span (to the end of its first line for a multi-line span).
fn text(cx: Cx, s: diag.Span): str {
  let line = cx.src_line(s.line) else return ""
  let chars = line.chars()
  let a = min(s.col - 1, chars.len())
  let b = if s.end_line == s.line { min(s.end_col - 1, chars.len()) } else { chars.len() }
  str(chars[a..max(b, a)])
}

/// The leading whitespace of a line.
fn indent(cx: Cx, line: int): str {
  let l = cx.src_line(line) else ""
  var out: [char] = []
  for ch in l.chars() {
    if !ch.is_space() { break }
    out.push(ch)
  }
  str(out)
}

fn ty_of(cx: Cx, id: int): types.Ty = cx.tables().types.get(id) else types.Ty.Error

// ---- walking bodies ----

fn block(cx: var Cx, b: ast.Block) {
  for s in b.stmts { cx.expr(s) }
}

fn expr(cx: var Cx, e: ast.Expr) {
  var all: [ast.Expr] = []
  visit.visit_expr(e, &all)
  for x in all {
    match x.kind {
      Match(_, arms) => cx.match_expr(x, arms)
      Let(_, pat, _, value, els) => match els {
        none => cx.must_match(pat, "this `let` pattern")
        some(arm) => {
          let refutable = match cx.tables().elses.get(x.id) {
            some(i) => i.kind == typed.ElseKind.Refutable
            none => false
          }
          if refutable && cx.exhaustive_single(pat) {
            let ts = cx.tp.defs.show(cx.ty_of(pat.id))
            let fix = diag.Span { line: value.span.end_line, col: value.span.end_col, ..arm.body.span }
            cx.err(
              diag.new("E0402", x.span, "the `else` of this `let` is never taken: the pattern matches every `{ts}`")
                .note("remove the `else` part")
                .fix(fix, ""),
            )
          }
        }
      }
      For(index, pat, _, _) => {
        match index {
          some(i) => cx.must_match(i, "the index pattern of this `for`")
          none => {}
        }
        cx.must_match(pat, "the pattern of this `for`")
      }
      Closure(params, _) => for p in params { cx.must_match(p.pat, "a closure parameter") }
      _ => {}
    }
  }
}

fn exhaustive_single(cx: Cx, p: ast.Pat): bool {
  let ty = cx.ty_of(p.id)
  cx.wit([[cx.lower_pat(p)]], [P.Wild], [ty], 1).len() == 0
}

/// A pattern that must match every value of its type (E0403).
fn must_match(cx: var Cx, p: ast.Pat, what: str) {
  match p.kind {
    Wild => return
    Bind(_) => if !cx.tables().variants.contains(p.id) && !cx.tables().raw_pats.contains(p.id) { return }
    _ => {}
  }
  let ty = cx.ty_of(p.id)
  let ws = cx.wit([[cx.lower_pat(p)]], [P.Wild], [ty], SHOW + 1)
  if ws.len() == 0 { return }
  var shown: [str] = []
  for w in ws {
    var names = no_names()
    shown.push(cx.show_w(w[0], ty, &names, none))
  }
  let list = case_list(shown)
  cx.err(
    diag.new("E0403", p.span, "{what} might not match: {list}")
      .note("a pattern here must match every value; use `let ... else {{ ... }}` or a `match` for a pattern that might not match"),
  )
}

// ---- match ----

fn match_expr(cx: var Cx, e: ast.Expr, arms: [ast.Arm]) {
  if arms.len() == 0 { return }
  let first = arms[0]
  let ty = cx.ty_of(first.pat.id)
  if ty.has_error() { return }
  // one row per alternative of an or-pattern (`A | B`), each remembering its arm
  var rows: [Row] = []
  var row_arm: [(int, ast.Pat)] = []
  for i, a in arms {
    let alts = match a.pat.kind {
      Or(ps) => ps
      _ => [a.pat]
    }
    for q in alts {
      rows.push(Row { pats: [cx.lower_pat(q)], guarded: a.guard is some(_) })
      row_arm.push((i, q))
    }
  }
  let tys = [ty]
  // reachability: an arm is unreachable when every alternative is; a single alternative that
  // can't match is reported on its own
  var k = 0
  for i, a in arms {
    var n = 0
    while k + n < row_arm.len() && row_arm[k + n].0 == i { n += 1 }
    var dead: [Reach] = []
    for r in k..k + n { dead.push(cx.unreachable(rows, r, tys)) }
    if dead.all(d => d is Reach.Dead(_)) {
      // an earlier unguarded arm that covers every alternative alone
      var single: int? = none
      for j in 0..i {
        var theirs: [[P]] = []
        for r in 0..k {
          if row_arm[r].0 == j && !rows[r].guarded { theirs.push(rows[r].pats) }
        }
        if theirs.len() == 0 { continue }
        var covers = true
        for r in k..k + n {
          if cx.wit(theirs, rows[r].pats, tys, 1).len() > 0 {
            covers = false
            break
          }
        }
        if covers {
          single = j
          break
        }
      }
      let what = match single {
        some(j) => "the arm `{cx.text(arms[j].pat.span)}` at line {arms[j].pat.span.line} already matches every value this one matches"
        none => "the arms before it together match every value this one matches"
      }
      let prev = arms[i - 1].span
      cx.err(
        diag.new("E0401", a.pat.span, "this arm is unreachable")
          .note(what)
          .fix(diag.Span { line: prev.end_line, col: prev.end_col, end_line: a.span.end_line, end_col: a.span.end_col }, ""),
      )
    } else {
      for di, d in dead {
        let r = k + di
        if d is Reach.Live { continue }
        let q = row_arm[r].1
        // remove ` | q` (or `q | ` for the first alternative)
        let fix = if r > k {
          let p = row_arm[r - 1].1.span
          diag.Span { line: p.end_line, col: p.end_col, end_line: q.span.end_line, end_col: q.span.end_col }
        } else {
          let nx = row_arm[r + 1].1.span
          diag.Span { line: q.span.line, col: q.span.col, end_line: nx.line, end_col: nx.col }
        }
        cx.err(
          diag.new("E0401", q.span, "this alternative is unreachable")
            .note("the arms and alternatives before it already match every value it matches")
            .fix(fix, ""),
        )
      }
    }
    k += n
  }
  // exhaustiveness
  let full = rows.filter(r => !r.guarded).map(r => r.pats)
  let ws = cx.wit(full, [P.Wild], tys, SHOW + 1)
  if ws.len() == 0 { return }
  var shown: [str] = []
  for w in ws {
    var names = no_names()
    shown.push(cx.show_w(w[0], ty, &names, none))
  }
  let list = case_list(shown)
  let kw = diag.Span { end_line: e.span.line, end_col: e.span.col + 5, ..e.span }
  var d = diag.new("E0400", kw, "this `match` doesn't cover every case: {list}")
  if rows.any(r => r.guarded) {
    d = d.note("arms with a `when` guard don't count toward covering every case")
  }
  let last = arms[arms.len() - 1].span
  let one_line = if arms.len() >= 2 { arms[arms.len() - 2].span.line == last.line } else { e.span.line == last.line }
  let sep = if one_line { ", " } else { "\n" + cx.indent(last.line) }
  var new_arms: [str] = []
  if ws.len() > SHOW {
    new_arms.push("_ => ??")
  } else {
    for w in ws {
      var names = fresh_names()
      new_arms.push("{cx.show_w(w[0], ty, &names, none)} => ??")
    }
  }
  let text = new_arms.map(a => sep + a).join("")
  d = d.note(if ws.len() > SHOW { "add the missing arms, or a catch-all `_ => ...`" } else { "add an arm for each missing case" })
  d = d.fix(diag.after(last), text)
  cx.err(d)
}

// ---- clause groups ----

fn clause_group(cx: var Cx, info: typed.FnInfo, cls: [ast.FnClause]) {
  if cls.len() == 0 || info.params.any(p => p.ty.has_error()) { return }
  let tys = info.params.map(p => p.ty)
  var rows: [Row] = []
  for c in cls {
    var pats: [P] = []
    for p in c.params { pats.push(cx.lower_pat(p.pat)) }
    rows.push(Row { pats, guarded: c.guard is some(_) })
  }
  for i, c in cls {
    match cx.unreachable(rows, i, tys) {
      Dead(j) => {
        let what = match j {
          some(j) => "the clause `{cx.clause_sig(info.name, cls[j])}` at line {cls[j].span.line} already matches every call this one matches"
          none => "the clauses before it together match every call this one matches"
        }
        let span = if c.params.len() > 0 { diag.to(c.params[0].span, c.params[c.params.len() - 1].span) } else { c.name.span }
        let prev = cls[i - 1].span
        cx.err(
          diag.new("E0401", span, "this clause of `{info.name}` is unreachable")
            .note(what)
            .fix(diag.Span { line: prev.end_line, col: prev.end_col, end_line: c.span.end_line, end_col: c.span.end_col }, ""),
        )
      }
      Live => {}
    }
  }
  let full = rows.filter(r => !r.guarded).map(r => r.pats)
  let wilds = tys.map(_ => P.Wild)
  let ws = cx.wit(full, wilds, tys, SHOW + 1)
  if ws.len() == 0 { return }
  var shown: [str] = []
  for w in ws {
    var ps: [str] = []
    for (p, t) in w.zip(tys) {
      var names = no_names()
      ps.push(cx.show_w(p, t, &names, none))
    }
    shown.push("{info.name}({ps.join(", ")})")
  }
  let list = case_list(shown)
  var d = diag.new("E0400", info.span, "the clauses of `{info.name}` don't cover every case: {list}")
  if rows.any(r => r.guarded) {
    d = d.note("clauses with a `when` guard don't count toward covering every case")
  }
  // a new clause in the style of the last one
  let last = cls[cls.len() - 1]
  var new: [str] = []
  if ws.len() > SHOW {
    new.push(cx.new_clause(info, last, tys, wilds))
  } else {
    for w in ws { new.push(cx.new_clause(info, last, tys, w)) }
  }
  let ind = cx.indent(last.span.line)
  let text = new.map(c => "\n" + ind + c).join("")
  d = d.note(if ws.len() > SHOW { "add the missing clauses, or a catch-all clause" } else { "add a clause for each missing case" })
  d = d.fix(diag.after(last.span), text)
  cx.err(d)
}

/// A clause for witness `w`, in the style of `last` (Rust's `clause` closure).
fn new_clause(cx: Cx, info: typed.FnInfo, last: ast.FnClause, tys: [types.Ty], w: [P]): str {
  var names = fresh_names()
  var ps: [str] = []
  for i, (p, t) in w.zip(tys) {
    let lp = last.params[i]
    let hint: str? = match info.params[i].name {
      some(n) => n
      none => match lp.pat.kind {
        Bind(n) => if !cx.tables().variants.contains(lp.pat.id) { n } else { none }
        _ => none
      }
    }
    let pat = cx.show_w(p, t, &names, hint)
    match lp.ty {
      some(ann) => ps.push("{pat}: {if lp.var_ { "var " } else { "" }}{cx.text(ann.span)}")
      none => ps.push(pat)
    }
  }
  let ret = match last.ret {
    some(r) => ": " + cx.text(r.span)
    none => ""
  }
  let asy = if last.is_async { "async " } else { "" }
  "{asy}fn {info.name}({ps.join(", ")}){ret} = ??"
}

fn clause_sig(cx: Cx, name: str, c: ast.FnClause): str {
  let ps = c.params.map(p => cx.text(p.span))
  "fn {name}({ps.join(", ")})"
}

/// `Live` if row `i` is reachable; otherwise `Dead` with an earlier unguarded row that covers it
/// alone (or `none` when only several together do).
fn unreachable(cx: Cx, rows: [Row], i: int, tys: [types.Ty]): Reach {
  var before: [[P]] = []
  for r in rows.take(i) {
    if !r.guarded { before.push(r.pats) }
  }
  if cx.wit(before, rows[i].pats, tys, 1).len() > 0 { return Reach.Live }
  for j in 0..i {
    if !rows[j].guarded && cx.wit([rows[j].pats], rows[i].pats, tys, 1).len() == 0 { return Reach.Dead(j) }
  }
  Reach.Dead(none)
}

/// "`A` is not handled" / "`A`, `B` and `C` are not handled" (with "and more").
fn case_list(cases: [str]): str {
  let more = cases.len() > SHOW
  let cs = cases.take(SHOW).map(c => "`{c}`")
  let n = cs.len()
  if n == 1 { return "{cs[0]} is not handled" }
  if !more { return "{cs.take(n - 1).join(", ")} and {cs[n - 1]} are not handled" }
  "{cs.join(", ")} and more are not handled"
}

// ---- AST patterns -> P ----

fn lower_pat(cx: Cx, p: ast.Pat): P {
  let t = cx.tables()
  match p.kind {
    Wild => P.Wild
    // or-patterns only appear at the top of a match arm, which `match_expr` splits into one
    // row per alternative
    Or(ps) => cx.lower_pat(ps[0])
    Bind(_) => match t.variants.get(p.id) {
      some(v) => P.C(Ctor.Idx(v.index), [])
      none => match t.raw_pats.get(p.id) {
        some(n) => P.C(Ctor.Lit(lit_key(ast.Lit.Int(n), false)), [])
        none => P.Wild
      }
    }
    Lit(Bool(b), _) => P.C(Ctor.Idx(if b { 1 } else { 0 }), [])
    Lit(lit, neg) => P.C(Ctor.Lit(lit_key(lit, neg)), [])
    Tuple(ps) => P.C(Ctor.Single, ps.map(q => cx.lower_pat(q)))
    List(head, rest, tail) => {
      let h = head.map(q => cx.lower_pat(q))
      match rest {
        none => P.C(Ctor.Len(h.len()), h)
        some(_) => P.Slice(h, tail.map(q => cx.lower_pat(q)))
      }
    }
    Variant(_, args) => match t.variants.get(p.id) {
      some(v) => P.C(Ctor.Idx(v.index), (args else []).map(q => cx.lower_pat(q)))
      none => P.Wild
    }
    Struct(_, fields, _) => {
      let sp = t.struct_pats.get(p.id) else return P.Wild
      let defs = cx.tp.defs.fields(sp.def)
      var args = defs.map(_ => P.Wild)
      for f in fields {
        let i = defs.find_index(d => d.name == f.name.name) else continue
        match f.pat {
          some(q) => args[i] = cx.lower_pat(q)
          none => {}
        }
      }
      P.C(Ctor.Single, args)
    }
    Map(es) => {
      var order: [(str, int)] = []
      for i, (k, _) in es { order.push((lit_key(k, false), i)) }
      var keys: [str] = []
      var pats: [P] = []
      for (key, i) in order.sort() {
        keys.push(key)
        pats.push(cx.lower_pat(es[i].1))
      }
      let m = P.C(Ctor.Keys(keys), pats)
      if t.value_map_pats.contains(p.id) {
        match cx.value_map_index() {
          some(i) => P.C(Ctor.Idx(i), [m])
          none => P.C(Ctor.Lit("map{p.id}"), [])
        }
      } else {
        m
      }
    }
    StrPrefix(prefix, rest) => P.C(Ctor.Prefix(prefix), [cx.lower_pat(rest)])
    Some(q) => P.C(Ctor.Idx(1), [cx.lower_pat(q)])
    None => P.C(Ctor.Idx(0), [])
    Ok(q) => P.C(Ctor.Idx(0), [cx.lower_pat(q)])
    Err(q) => {
      if t.err_payload_pats.contains(p.id) {
        let inner = match t.variants.get(q.id) {
          some(v) => {
            let s = cx.tp.defs.subst_of(v.def, v.args)
            let tys = cx.tp.defs.variants(v.def)[v.index].fields.map(f => f.1.subst(s))
            let args = match q.kind {
              Variant(_, some(a)) => a.map(x => cx.lower_pat(x))
              _ => []
            }
            P.C(Ctor.Payload(v.def, v.index, tys), args)
          }
          none => P.C(Ctor.Lit("payload{q.id}"), [])
        }
        return P.C(Ctor.Idx(1), [inner])
      }
      P.C(Ctor.Idx(1), [cx.lower_pat(q)])
    }
  }
}

fn value_map_index(cx: Cx): int? {
  let d = cx.value_def?
  cx.tp.defs.variants(d).find_index(v => v.name == "Map")
}

// ---- types ----

fn kind(cx: Cx, ty: types.Ty): Kind = match ty {
  Bool | Opt(_) | Res(_, _) => Kind.Finite(2)
  Tuple(_) => Kind.Single
  List(_) => Kind.List
  Named(d, _) => match cx.tp.defs.types[d].kind {
    Enum(variants) => Kind.Finite(variants.len())
    Struct(_) => Kind.Single
    Opaque(_) => Kind.Infinite
  }
  _ => Kind.Infinite
}

/// The types of a constructor's fields.
fn sub_tys(cx: Cx, ty: types.Ty, c: Ctor): [types.Ty] = match (c, ty) {
  (Payload(_, _, tys), _) => tys
  (Idx(1), Opt(t)) => [t]
  (Idx(0), Res(o, _)) => [o]
  (Idx(1), Res(_, e)) => [e]
  (Idx(i), Named(d, args)) when cx.tp.defs.is_enum(d) => {
    let s = cx.tp.defs.subst_of(d, args)
    match cx.tp.defs.variants(d).get(i) {
      some(v) => v.fields.map(f => f.1.subst(s))
      none => []
    }
  }
  (Single, Tuple(ts)) => ts
  (Single, Named(d, args)) => {
    let s = cx.tp.defs.subst_of(d, args)
    cx.tp.defs.fields(d).map(f => f.ty.subst(s))
  }
  (Len(k), List(t)) | (LenMin(k), List(t)) => (0..k).map(_ => t)
  (Keys(ks), Map(_, v)) => ks.map(_ => v)
  (Keys(ks), _) => ks.map(_ => types.Ty.Error)
  (Prefix(_), _) => [types.Ty.Str]
  _ => []
}

// ---- the algorithm ----

/// `xs` cut or padded with wildcards to length `n` (Rust's `Vec::resize`).
fn resize(xs: [P], n: int): [P] {
  if xs.len() >= n { return xs.take(n) }
  var out = xs
  while out.len() < n { out.push(P.Wild) }
  out
}

/// The witnesses that `q` is useful with respect to `rows`: vectors of patterns describing
/// values that `q` matches and no row matches (at most `limit`; empty = `q` is useless). With
/// `q` all wildcards, the witnesses are the missing cases, and together they cover them.
fn wit(cx: Cx, rows: [[P]], q: [P], tys: [types.Ty], limit: int): [[P]] {
  if q.len() == 0 {
    return if rows.len() == 0 { [[]] } else { [] }
  }
  let ty = tys[0]
  match q[0] {
    C(c, args) => cx.through(rows, c, cx.sub_tys(ty, c), args, q, tys, limit)
    Slice(a, b) => {
      var out: [[P]] = []
      for c in list_classes(rows, q[0]) {
        let k = match c {
          Len(k) | LenMin(k) => k
          _ => 0
        }
        if a.len() + b.len() > k { continue }
        let args = expand(a, b, k)
        let sub = cx.sub_tys(ty, c)
        out = out + cx.through(rows, c, sub, args, q, tys, limit - out.len())
        if out.len() >= limit { break }
      }
      out
    }
    Wild => {
      let any_head = rows.any(r => !(r[0] is P.Wild))
      let ctors: [Ctor]? = match cx.kind(ty) {
        Single => [Ctor.Single]
        Finite(n) when any_head => (0..n).map(i => Ctor.Idx(i))
        List when any_head => list_classes(rows, P.Wild)
        _ => none
      }
      var out: [[P]] = []
      match ctors {
        some(cs) => for c in cs {
          let sub = cx.sub_tys(ty, c)
          let args = sub.map(_ => P.Wild)
          out = out + cx.through(rows, c, sub, args, q, tys, limit - out.len())
          if out.len() >= limit { break }
        }
        none => {
          var d: [[P]] = []
          for r in rows {
            if r[0] is P.Wild { d.push(r.skip(1)) }
          }
          for w in cx.wit(d, q.skip(1), tys.skip(1), limit) { out.push([P.Wild] + w) }
        }
      }
      out
    }
  }
}

/// Specialize by `c` and recurse with `args` in place of `q`'s head; rebuild the witnesses.
fn through(cx: Cx, rows: [[P]], c: Ctor, sub: [types.Ty], args: [P], q: [P], tys: [types.Ty], limit: int): [[P]] {
  let n = sub.len()
  var srows: [[P]] = []
  for r in rows {
    match specialize(r, c, n) {
      some(s) => srows.push(s)
      none => {}
    }
  }
  let q2 = resize(args, n) + q.skip(1)
  let t2 = sub + tys.skip(1)
  cx.wit(srows, q2, t2, limit).map(w => [P.C(c, w.take(n))] + w.skip(n))
}

// ---- showing witnesses ----

/// A wildcard as text: with names on, the hint if it is a plain name not used yet.
fn wild_text(names: var Names, hint: str?): str {
  match hint {
    some(h) => if names.on && is_plain_name(h) && !names.used.contains(h) {
      names.used[h] = true
      return h
    }
    none => {}
  }
  "_"
}

/// A witness as Auk pattern text. With names on, wildcards inside variants become their field
/// names (for a fix-it that inserts a clause or arm), each used once.
fn show_w(cx: Cx, w: P, ty: types.Ty, names: var Names, hint: str?): str {
  let C(c, args) = w else return wild_text(&names, hint)
  let all_wild = args.all(a => a is P.Wild)
  let sub = cx.sub_tys(ty, c)
  match (c, ty) {
    (Idx(i), Bool) => if i == 1 { "true" } else { "false" }
    (Idx(0), Opt(_)) => "none"
    (Idx(_), Opt(_)) => "some({cx.show_args(args, sub, &names, [some("v")])[0]})"
    (Idx(0), Res(_, _)) => "ok({cx.show_args(args, sub, &names, [some("v")])[0]})"
    (Idx(_), Res(_, _)) => "err({cx.show_args(args, sub, &names, [some("e")])[0]})"
    (Idx(i), Named(d, _)) => cx.variant_text(d, i, args, sub, &names)
    (Payload(d, i, _), _) => cx.variant_text(d, i, args, sub, &names)
    (Single, _) when all_wild && args.len() > 0 => wild_text(&names, hint)
    (Single, Tuple(_)) => "({cx.show_args(args, sub, &names, []).join(", ")})"
    (Single, Named(d, _)) => {
      let fields = cx.tp.defs.fields(d).map(f => f.name)
      let hints: [str?] = fields.map(f => some(f))
      let shown = cx.show_args(args, sub, &names, hints)
      var parts: [str] = []
      for i, a in args {
        if i >= fields.len() || i >= shown.len() { break }
        if !(a is P.Wild) { parts.push("{fields[i]}: {shown[i]}") }
      }
      let name = cx.type_name(d)
      if parts.len() == 0 { "{name} {{ .. }}" } else { "{name} {{ {parts.join(", ")}, .. }}" }
    }
    (Len(_), _) => "[{cx.show_args(args, sub, &names, []).join(", ")}]"
    (LenMin(0), _) => wild_text(&names, hint)
    (LenMin(_), _) => "[{cx.show_args(args, sub, &names, []).join(", ")}, ..]"
    _ => wild_text(&names, hint)
  }
}

/// Each argument shown with its type and name hint (Rust's `show_args` closure).
fn show_args(cx: Cx, args: [P], sub: [types.Ty], names: var Names, hints: [str?]): [str] {
  var out: [str] = []
  for i, (a, t) in args.zip(sub) {
    let h: str? = match hints.get(i) {
      some(x) => x
      none => none
    }
    out.push(cx.show_w(a, t, &names, h))
  }
  out
}

fn variant_text(cx: Cx, d: int, i: int, args: [P], sub: [types.Ty], names: var Names): str {
  let vs = cx.tp.defs.variants(d)
  let v = vs.get(i) else return "_"
  if v.fields.len() == 0 { return v.name }
  let variant_names = vs.map(x => x.name)
  var hints: [str?] = []
  for f in v.fields {
    match f.0 {
      some(n) => hints.push(if variant_names.contains(n) { none } else { some(n) })
      none => hints.push(none)
    }
  }
  "{v.name}({cx.show_args(args, sub, &names, hints).join(", ")})"
}

/// A struct's name as written from the current module.
fn type_name(cx: Cx, d: int): str {
  let def = cx.tp.defs.types[d]
  if def.module == cx.m || cx.tp.program.is_core(def.module) { return def.name }
  let prog = cx.tp.program
  let a = prog.mods[def.module]
  let b = prog.mods[cx.m]
  let path = if a.pkg == b.pkg { a.path.skip(1) } else { a.path }
  if path.len() == 0 { def.name } else { "{path.join(".")}.{def.name}" }
}

/// Specialize one row by constructor `c` of arity `n` (none if the row can't match it).
fn specialize(r: [P], c: Ctor, n: int): [P]? {
  let head: [P] = match r[0] {
    Wild => resize([], n)
    C(c2, args) => {
      if !ctor_eq(c2, c) { return none }
      resize(args, n)
    }
    Slice(a, b) => match c {
      Len(k) | LenMin(k) => {
        if a.len() + b.len() > k { return none }
        expand(a, b, k)
      }
      _ => return none
    }
  }
  head + r.skip(1)
}

/// `[a.., .., b..]` at length `k`: the prefix, wildcards, the suffix.
fn expand(a: [P], b: [P], k: int): [P] = resize(a, k - b.len()) + b

/// The length classes of a list column: `[]`, `[_]`, ... and "at least L", where L is past
/// every fixed-length pattern and covers every rest pattern's fixed part.
fn list_classes(rows: [[P]], q: P): [Ctor] {
  var fixed: int? = none
  var slice = 0
  for p in rows.map(r => r[0]) + [q] {
    match p {
      C(Len(k), _) => fixed = match fixed {
        some(f) => max(f, k)
        none => k
      }
      Slice(a, b) => slice = max(slice, a.len() + b.len())
      _ => {}
    }
  }
  let l = match fixed {
    some(f) => max(f + 1, slice)
    none => slice
  }
  var cs: [Ctor] = []
  for i in 0..l { cs.push(Ctor.Len(i)) }
  cs.push(Ctor.LenMin(l))
  cs
}

/// A canonical key per literal value (only compared, never shown): `-0` is `0`; a literal's
/// u64 bits stay distinct from every negated one.
fn lit_key(l: ast.Lit, neg: bool): str = match l {
  Int(n) => if neg && n != 0 { "i-{n}" } else { "i{n}" }
  Float(f) => "f{(if neg { -f } else { f }).bits()}"
  Bool(b) => "b{b}"
  Char(c) => "c{c}"
  Str(s) => "s{s}"
}

/// A name usable as a binding in a generated pattern.
fn is_plain_name(s: str): bool {
  let cs = s.chars()
  if cs.len() == 0 { return false }
  let c0 = cs[0]
  if !((c0 >= 'a' && c0 <= 'z') || c0 == '_') { return false }
  for c in cs {
    if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_') { return false }
  }
  !["ok", "err", "some", "none", "true", "false", "self", "result", "_"].contains(s)
}

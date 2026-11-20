/// Last-use analysis for moves (design/ownership-plan.md, sections 1 and 2): a backward
/// liveness pass over one body that finds the reads of a local after which nothing reads it
/// again, on any path. `lower` turns such a read into a move when the value is owned there
/// (`Lower.own`): no retain, and a zero left in the variable.
///
/// A read is a move site only if, besides being dead afterwards, it is the only mention of the
/// local in its statement (inner blocks' mentions count for the statement around them). The
/// owning happens before that statement ends, so the variable can't change between the read
/// and the move; and no earlier read in it is still waiting as a borrowed value (an
/// interpolation's parts, a tuple's elements are read only when the whole is built).
///
/// Conservative where evaluation order isn't plain left to right: a closure or `catch` body,
/// a `match` guard, a struct literal's base, an assignment target. Their names are live and
/// mentioned, and never moved. A local that is the root of a `match` or `is` scrutinee or a
/// `for` loop's iterable is never moved (pattern bindings and loop elements may borrow from
/// it).

pub struct Live {
  t: typed.Tables,
  /// The reads that are last uses (by expression id).
  moves: {int: bool},
  /// Locals never moved.
  pinned: {int: bool},
  /// Locals mentioned later in the current statement.
  mentioned: {int: bool},
  /// How often each local is mentioned in the current statement (all of it).
  counts: {int: int},
  /// Live at the exit of each enclosing loop (`break`).
  brk: [{int: bool}],
  /// Live at the head of each enclosing loop (`continue`).
  cont: [{int: bool}],
}

/// The last-use reads of a function body (`body`: its statements, or one expression).
pub fn analyze(t: typed.Tables, body: [ast.Expr]): {int: bool} {
  var lv = Live { t, moves: {}, pinned: {}, mentioned: {}, counts: {}, brk: [], cont: [] }
  var all: [ast.Expr] = []
  for s in body { visit.visit_expr(s, &all) }
  for e in all {
    match e.kind {
      Match(x, _) | Is(x, _) => lv.pin_root(x)
      For(_, _, x, _) => lv.pin_root(x)
      _ => {}
    }
  }
  let _ = lv.stmts(body, nothing())
  var out: {int: bool} = {}
  for (id, m) in lv.moves {
    if m { out[id] = true }
  }
  out
}

fn local_of(lv: var Live, e: ast.Expr): int? = match lv.t.names.get(e.id) {
  some(Local(l)) => some(l)
  _ => none
}

fn pin_root(lv: var Live, e: ast.Expr) {
  match e.kind {
    Name(_) => match lv.local_of(e) {
      some(l) => lv.pinned[l] = true
      none => {}
    }
    Field(x, _) | TupleField(x, _) | Index(x, _) | Slice(x, _, _, _) | Unwrap(x) | Ref(x) => lv.pin_root(x)
    _ => {}
  }
}

fn nothing(): {int: bool} {
  let m: {int: bool} = {}
  m
}

fn union(a: {int: bool}, b: {int: bool}): {int: bool} {
  if b.len() == 0 { return a }
  var out = a
  for (k, _) in b { out[k] = true }
  out
}

fn without(a: {int: bool}, ks: [int]): {int: bool} {
  var out = a
  for k in ks { let _ = out.remove(k) }
  out
}

/// Every local read in `e`: live and mentioned, never moved.
fn mention_all(lv: var Live, e: ast.Expr, out: {int: bool}): {int: bool} {
  var all: [ast.Expr] = []
  visit.visit_expr(e, &all)
  var live = out
  for x in all {
    match x.kind {
      Name(_) => match lv.local_of(x) {
        some(l) => {
          live[l] = true
          lv.mentioned[l] = true
          lv.moves[x.id] = false
        }
        none => {}
      }
      _ => {}
    }
  }
  live
}

/// The locals a pattern binds.
fn bound(lv: var Live, p: ast.Pat, out: var [int]) {
  match lv.t.binds.get(p.id) {
    some(l) => out.push(l)
    none => {}
  }
  match p.kind {
    Tuple(ps) | Or(ps) => for q in ps { lv.bound(q, &out) }
    List(h, r, tl) => {
      for q in h { lv.bound(q, &out) }
      match r {
        some(rs) => match rs.pat {
          some(q) => lv.bound(q, &out)
          none => {}
        }
        none => {}
      }
      for q in tl { lv.bound(q, &out) }
    }
    Variant(_, args) => match args {
      some(ps) => for q in ps { lv.bound(q, &out) }
      none => {}
    }
    Struct(_, fs, _) => for f in fs {
      match f.pat {
        some(q) => lv.bound(q, &out)
        none => {}
      }
    }
    Map(es) => for (_, q) in es { lv.bound(q, &out) }
    StrPrefix(_, q) | Some(q) | Ok(q) | Err(q) => lv.bound(q, &out)
    _ => {}
  }
}

fn binds_of(lv: var Live, p: ast.Pat): [int] {
  var out: [int] = []
  lv.bound(p, &out)
  out
}

/// Statements in order; `out` is live after the last. Each starts a fresh statement for
/// `mentioned`; their mentions then count for the enclosing statement.
fn stmts(lv: var Live, ss: [ast.Expr], out: {int: bool}): {int: bool} {
  var live = out
  let outer = lv.mentioned
  var inner: {int: bool} = {}
  let outer_counts = lv.counts
  var i = ss.len() - 1
  while i >= 0 {
    lv.mentioned = {}
    lv.counts = lv.count_mentions(ss[i])
    live = lv.ex(ss[i], live)
    inner = union(inner, lv.mentioned)
    i -= 1
  }
  lv.mentioned = union(outer, inner)
  lv.counts = outer_counts
  live
}

/// How often each local is mentioned in `e` (shorthand struct fields too; not a plain
/// assignment's target).
fn count_mentions(lv: var Live, e: ast.Expr): {int: int} {
  var all: [ast.Expr] = []
  visit.visit_expr(e, &all)
  // a plain assignment's target is a store after its value, not a read waiting in it
  var stores: {int: bool} = {}
  for x in all {
    match x.kind {
      Assign(none, target, _) => if target.kind is ast.ExprKind.Name(_) { stores[target.id] = true }
      _ => {}
    }
  }
  var out: {int: int} = {}
  for x in all {
    match x.kind {
      Name(_) => if !stores.contains(x.id) {
        match lv.local_of(x) {
          some(l) => out[l] = (out.get(l) else 0) + 1
          none => {}
        }
      }
      Struct(_, fields, _) => for f in fields {
        if f.value is none {
          for l, info in lv.t.locals {
            if info.name == f.name.name { out[l] = (out.get(l) else 0) + 2 }
          }
        }
      }
      _ => {}
    }
  }
  out
}

/// Expressions evaluated in order (`xs[0]` first).
fn seq(lv: var Live, xs: [ast.Expr], out: {int: bool}): {int: bool} {
  var live = out
  var i = xs.len() - 1
  while i >= 0 {
    live = lv.ex(xs[i], live)
    i -= 1
  }
  live
}

/// Two alternatives (`a` or `b`) that both continue with `out`.
fn alt(lv: var Live, a: ast.Expr, b: ast.Expr?, out: {int: bool}): {int: bool} {
  let after = lv.mentioned
  let la = lv.ex(a, out)
  let ma = lv.mentioned
  lv.mentioned = after
  let lb = match b {
    some(x) => lv.ex(x, out)
    none => out
  }
  lv.mentioned = union(ma, lv.mentioned)
  union(la, lb)
}

fn block_e(lv: var Live, b: ast.Block, out: {int: bool}): {int: bool} = lv.stmts(b.stmts, out)

/// A loop: `body` flows back to the head, which `cond` (if any) leaves for `out`. Iterates
/// until the live set at the head is stable; the last pass records the moves.
fn loop_(lv: var Live, cond: ast.Expr?, body: ast.Block, kill: [int], out: {int: bool}): {int: bool} {
  let after = lv.mentioned
  var head = out
  var rounds = 0
  loop {
    lv.mentioned = after
    lv.brk.push(out)
    lv.cont.push(head)
    let b_in = without(lv.block_e(body, head), kill)
    let h2 = match cond {
      some(c) => lv.ex(c, union(out, b_in))
      none => b_in
    }
    let _ = lv.brk.pop()
    let _ = lv.cont.pop()
    let next = union(head, h2)
    rounds += 1
    if next.len() == head.len() || rounds > 100 {
      head = next
      break
    }
    head = next
  }
  head
}

fn ex(lv: var Live, e: ast.Expr, out: {int: bool}): {int: bool} {
  match e.kind {
    Lit(_) | Hole | FieldSel(_) | Uninit => out
    Name(_) => match lv.local_of(e) {
      some(l) => {
        let only = (lv.counts.get(l) else 0) <= 1
        let last = only && !out.contains(l) && !lv.mentioned.contains(l) && !lv.pinned.contains(l)
        lv.moves[e.id] = last
        lv.mentioned[l] = true
        var live = out
        live[l] = true
        live
      }
      none => out
    }
    Measured(x, _) | Field(x, _) | TupleField(x, _) | Unary(_, x) | Unwrap(x) | Try(x) |
      Await(x) | AwaitAny(x) | Assert(x) | Peek(x) | TypeArgs(x, _) | Is(x, _) => lv.ex(x, out)
    // `&x`: changed in place, never moved
    Ref(x) => lv.mention_all(x, out)
    Interp(parts) => {
      var xs: [ast.Expr] = []
      for p in parts {
        match p {
          Expr(x, _) => xs.push(x)
          _ => {}
        }
      }
      lv.seq(xs, out)
    }
    Call(callee, args) => lv.seq([callee] + args, out)
    MethodCall(recv, _, args) => lv.seq([recv] + args, out)
    Pipe(lhs, callee, args) => lv.seq([lhs, callee] + args, out)
    Index(x, i) => lv.seq([x, i], out)
    Slice(x, lo, hi, _) => lv.seq([x, lo, hi], out)
    Range(lo, hi, _) => lv.seq([lo, hi], out)
    Binary(_, l, r) => lv.seq([l, r], out)
    OptChain(x, _, args) => match args {
      some(a) => lv.seq([x] + a, out)
      none => lv.ex(x, out)
    }
    List(xs) | Tuple(xs) => lv.seq(xs, out)
    Map(es) => {
      var xs: [ast.Expr] = []
      for (k, v) in es {
        xs.push(k)
        xs.push(v)
      }
      lv.seq(xs, out)
    }
    Struct(_, fields, base) => {
      var live = match base {
        some(b) => lv.mention_all(b, out)
        none => out
      }
      // a shorthand field (`Point { x, y }`) reads the local of that name: live, never moved
      for f in fields {
        match f.value {
          none => for l, info in lv.t.locals {
            if info.name == f.name.name {
              live[l] = true
              lv.mentioned[l] = true
            }
          }
          some(_) => {}
        }
      }
      var xs: [ast.Expr] = []
      for f in fields {
        match f.value {
          some(v) => xs.push(v)
          none => {}
        }
      }
      lv.seq(xs, live)
    }
    Else(x, arm) => {
      let a = lv.alt(arm.body, none, out)
      lv.ex(x, a)
    }
    // run elsewhere (a closure's code, a `catch`'s frame): what they read stays live
    Closure(_, _) | Catch(_) => lv.mention_all(e, out)
    If(c, th, els) => {
      let thx = ast.Expr { id: th.id, span: th.span, kind: ast.ExprKind.Block(th) }
      let a = lv.alt(thx, els, out)
      lv.ex(c, a)
    }
    Match(scrut, arms) => {
      let after = lv.mentioned
      var live = out
      var ms = after
      for a in arms {
        lv.mentioned = after
        var l2 = lv.ex(a.body, out)
        match a.guard {
          some(g) => l2 = lv.mention_all(g, l2)
          none => {}
        }
        l2 = without(l2, lv.binds_of(a.pat))
        live = union(live, l2)
        ms = union(ms, lv.mentioned)
      }
      lv.mentioned = ms
      lv.ex(scrut, live)
    }
    Loop(body) => lv.loop_(none, body, [], out)
    While(c, body) => lv.loop_(some(c), body, [], out)
    For(idx, pat, iter, body) => {
      var kill = lv.binds_of(pat)
      match idx {
        some(p) => kill = kill + lv.binds_of(p)
        none => {}
      }
      let head = lv.loop_(none, body, kill, out)
      lv.ex(iter, union(head, out))
    }
    Block(b) => lv.block_e(b, out)
    Let(_, pat, _, value, els) => {
      let after = without(out, lv.binds_of(pat))
      let live = match els {
        some(arm) => lv.alt(arm.body, none, after)
        none => after
      }
      lv.ex(value, live)
    }
    Assign(op, target, value) => match (op, target.kind) {
      (none, Name(_)) => match lv.local_of(target) {
        some(l) => {
          // the store comes after the value (and any move in it)
          let live = lv.ex(value, without(out, [l]))
          lv.mentioned[l] = true
          live
        }
        none => lv.ex(value, out)
      }
      _ => {
        let live = lv.mention_all(target, out)
        lv.ex(value, live)
      }
    }
    Return(v) => match v {
      some(x) => lv.ex(x, nothing())
      none => nothing()
    }
    Break(v) => {
      let target = match lv.brk.last() {
        some(b) => b
        none => nothing()
      }
      match v {
        some(x) => lv.ex(x, target)
        none => target
      }
    }
    Continue => match lv.cont.last() {
      some(c) => c
      none => nothing()
    }
  }
}

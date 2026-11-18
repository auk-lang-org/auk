/// Walking the syntax tree: `visit_item_exprs` and `visit_expr` (src/check.rs) and `as_path`
/// (src/check/expr.rs). Rust's visitors call a closure on every expression; an Auk closure
/// can't collect into a captured variable, so these push every expression, in the same order
/// (pre-order), onto `out`.

/// Every expression of an item: contracts, guards and bodies of its clauses, a test's body, a
/// constant's value.
pub fn visit_item_exprs(item: ast.Item, out: var [ast.Expr]) {
  match item {
    Fn(g) => {
      match g.header {
        some(h) => clause(h, &out)
        none => {}
      }
      for c in g.clauses { clause(c, &out) }
    }
    Test(t) => for s in t.body.stmts { visit_expr(s, &out) }
    Let(c) | Imprint(c) => visit_expr(c.value, &out)
    _ => {}
  }
}

fn clause(c: ast.FnClause, out: var [ast.Expr]) {
  for e in c.pre { visit_expr(e, &out) }
  for e in c.post { visit_expr(e, &out) }
  match c.guard {
    some(e) => visit_expr(e, &out)
    none => {}
  }
  match c.body {
    some(Expr(e)) => visit_expr(e, &out)
    some(Block(b)) => for s in b.stmts { visit_expr(s, &out) }
    _ => {}
  }
}

fn block(b: ast.Block, out: var [ast.Expr]) {
  for s in b.stmts { visit_expr(s, &out) }
}

fn all(es: [ast.Expr], out: var [ast.Expr]) {
  for x in es { visit_expr(x, &out) }
}

fn opt(e: ast.Expr?, out: var [ast.Expr]) {
  match e {
    some(x) => visit_expr(x, &out)
    none => {}
  }
}

/// `e` and every expression inside it, pre-order.
pub fn visit_expr(e: ast.Expr, out: var [ast.Expr]) {
  out.push(e)
  match e.kind {
    Lit(_) | Name(_) | Hole | Continue => {}
    Measured(x, _) => visit_expr(x, &out)
    Interp(ps) => for p in ps {
      match p {
        Expr(x, _) => visit_expr(x, &out)
        _ => {}
      }
    }
    Field(x, _) | TupleField(x, _) | Unary(_, x) | Is(x, _) => visit_expr(x, &out)
    Try(x) | Unwrap(x) | Await(x) | AwaitAny(x) | Catch(x) | Ref(x) | Assert(x) | Peek(x) =>
      visit_expr(x, &out)
    Call(callee, args) => {
      visit_expr(callee, &out)
      all(args, &out)
    }
    MethodCall(recv, _, args) => {
      visit_expr(recv, &out)
      all(args, &out)
    }
    Pipe(lhs, callee, args) => {
      visit_expr(lhs, &out)
      visit_expr(callee, &out)
      all(args, &out)
    }
    Index(x, index) => {
      visit_expr(x, &out)
      visit_expr(index, &out)
    }
    Slice(x, lo, hi, _) => {
      visit_expr(x, &out)
      visit_expr(lo, &out)
      visit_expr(hi, &out)
    }
    Binary(_, lhs, rhs) => {
      visit_expr(lhs, &out)
      visit_expr(rhs, &out)
    }
    Range(lo, hi, _) => {
      visit_expr(lo, &out)
      visit_expr(hi, &out)
    }
    OptChain(x, _, args) => {
      visit_expr(x, &out)
      match args {
        some(a) => all(a, &out)
        none => {}
      }
    }
    Else(x, arm) => {
      visit_expr(x, &out)
      visit_expr(arm.body, &out)
    }
    Closure(_, body) => visit_expr(body, &out)
    If(cond, then, els) => {
      visit_expr(cond, &out)
      block(then, &out)
      opt(els, &out)
    }
    Match(scrut, arms) => {
      visit_expr(scrut, &out)
      for a in arms {
        opt(a.guard, &out)
        visit_expr(a.body, &out)
      }
    }
    Loop(b) | Block(b) => block(b, &out)
    While(cond, body) => {
      visit_expr(cond, &out)
      block(body, &out)
    }
    For(_, _, iter, body) => {
      visit_expr(iter, &out)
      block(body, &out)
    }
    Let(_, _, _, value, els) => {
      visit_expr(value, &out)
      match els {
        some(a) => visit_expr(a.body, &out)
        none => {}
      }
    }
    Assign(_, target, value) => {
      visit_expr(target, &out)
      visit_expr(value, &out)
    }
    Return(x) | Break(x) => opt(x, &out)
    Struct(_, fields, base) => {
      for f in fields { opt(f.value, &out) }
      opt(base, &out)
    }
    List(xs) | Tuple(xs) => all(xs, &out)
    Map(es) => for (k, v) in es {
      visit_expr(k, &out)
      visit_expr(v, &out)
    }
  }
}

/// `a.b.c` as a list of names, if the expression is only names and fields.
pub fn as_path(e: ast.Expr): [ast.Ident]? = match e.kind {
  Name(n) => [ast.Ident { name: n, span: e.span }]
  Field(x, name) => {
    let p = as_path(x)?
    p + [name]
  }
  _ => none
}

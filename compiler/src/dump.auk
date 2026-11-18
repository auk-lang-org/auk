/// The `auk dump tokens|ast` text (src/dump.rs): one node per line, children indented by two
/// spaces, strings escaped by `esc`, floats as their IEEE bits, chars as code points.

/// A string in double quotes: `\\ \" \n \t \r` escaped, other control chars as `\u{hex}`,
/// everything else as is.
pub fn esc(s: str): str {
  var plain = true
  for c in s.chars() {
    if c == '\\' || c == '"' || int(c) < 0x20 || int(c) == 0x7f {
      plain = false
      break
    }
  }
  if plain { return "\"" + s + "\"" }
  var out: [str] = ["\""]
  for c in s.chars() {
    match c {
      '\\' => out.push("\\\\")
      '"' => out.push("\\\"")
      '\n' => out.push("\\n")
      '\t' => out.push("\\t")
      '\r' => out.push("\\r")
      _ when int(c) < 0x20 || int(c) == 0x7f => out.push("\\u{{{hex(int(c))}}}")
      _ => out.push(str(c))
    }
  }
  out.push("\"")
  out.join("")
}

fn hex(n: int): str {
  let ds = "0123456789abcdef".chars()
  if n < 16 { return str(ds[n]) }
  hex(n / 16) + str(ds[n % 16])
}

pub fn sp(s: diag.Span): str = "{s.line}:{s.col}-{s.end_line}:{s.end_col}"

pub fn line(out: var [str], depth: int, s: str) {
  if depth == 0 {
    out.push(s)
  } else {
    out.push("  ".repeat(depth) + s)
  }
}

pub fn diag_dump(out: var [str], d: diag.Diag) {
  line(&out, 0, "error {d.code} {sp(d.span)} {esc(d.message)}")
  for n in d.notes { line(&out, 1, "note {esc(n)}") }
  for f in d.fixes { line(&out, 1, "fix {sp(f.span)} {esc(f.text)}") }
}

// ---- tokens ----

pub fn tokens(out: var [str], module_doc: str?, toks: [token.Token]) {
  match module_doc {
    some(d) => line(&out, 0, "module-doc {esc(d)}")
    none => {}
  }
  toks_at(&out, 0, toks)
}

fn toks_at(out: var [str], depth: int, toks: [token.Token]) {
  for t in toks {
    var s = "{sp(t.span)} {tok_text(t.tok)}"
    if t.space_before { s += " space" }
    match t.doc {
      some(d) => s += " doc={esc(d)}"
      none => {}
    }
    line(&out, depth, s)
    match t.tok {
      Str(parts) => for p in parts {
        match p {
          Lit(l) => line(&out, depth + 1, "lit {esc(l)}")
          Interp(ts, spec, span) => {
            let sp2 = match spec {
              some(s) => " spec={esc(s)}"
              none => ""
            }
            line(&out, depth + 1, "interp {sp(span)}{sp2}")
            toks_at(&out, depth + 2, ts)
          }
        }
      }
      _ => {}
    }
  }
}

/// The token's kind (its variant name) and payload.
pub fn tok_text(t: token.Tok): str = match t {
  Int(n) => "Int {token.uint_str(n)}"
  Float(x) => "Float {x.bits()}"
  Char(c) => "Char {int(c)}"
  Ident(s) => "Ident {esc(s)}"
  Unit(s) => "Unit {esc(s)}"
  _ => t.name()
}

// ---- syntax tree ----

pub fn module(out: var [str], m: ast.Module) {
  match m.doc {
    some(d) => line(&out, 0, "module-doc {esc(d)}")
    none => {}
  }
  for it in m.items { item(&out, 0, it) }
}

fn id(i: ast.Ident): str = "{i.name}@{sp(i.span)}"

fn ids(path: [ast.Ident]): str = path.map(id).join(" ")

fn doc(out: var [str], d: int, doc: str?) {
  match doc {
    some(s) => line(&out, d, "doc {esc(s)}")
    none => {}
  }
}

fn vis(public: bool): str = if public { " pub" } else { "" }

fn item(out: var [str], d: int, it: ast.Item) {
  match it {
    Fn(g) => {
      line(&out, d, "fn {g.name}/{g.arity}")
      match g.header {
        some(h) => clause(&out, d + 1, "header", h)
        none => {}
      }
      for c in g.clauses { clause(&out, d + 1, "clause", c) }
    }
    Struct(s) => {
      line(&out, d, "struct #{s.id} {sp(s.span)}{vis(s.public)} {id(s.name)}")
      doc(&out, d + 1, s.doc)
      generics(&out, d + 1, s.generics)
      for f in s.fields {
        line(&out, d + 1, "field {sp(f.span)} {id(f.name)}")
        doc(&out, d + 2, f.doc)
        ty(&out, d + 2, f.ty)
      }
    }
    Enum(e) => {
      line(&out, d, "enum #{e.id} {sp(e.span)}{vis(e.public)} {id(e.name)}")
      doc(&out, d + 1, e.doc)
      generics(&out, d + 1, e.generics)
      for v in e.variants {
        line(&out, d + 1, "variant #{v.id} {sp(v.span)} {id(v.name)}")
        doc(&out, d + 2, v.doc)
        for f in v.fields {
          match f.name {
            some(n) => line(&out, d + 2, "vfield {id(n)}")
            none => line(&out, d + 2, "vfield")
          }
          ty(&out, d + 3, f.ty)
        }
      }
    }
    Shape(s) => {
      line(&out, d, "shape #{s.id} {sp(s.span)}{vis(s.public)} {id(s.name)}")
      doc(&out, d + 1, s.doc)
      generics(&out, d + 1, s.generics)
      for m in s.methods { clause(&out, d + 1, "method", m) }
    }
    Test(t) => {
      line(&out, d, "test #{t.id} {sp(t.span)} {esc(t.name)}")
      doc(&out, d + 1, t.doc)
      block(&out, d + 1, t.body)
    }
    Let(c) => const_def(&out, d, "let", c)
    Imprint(c) => const_def(&out, d, "imprint", c)
    ExternType(t) => {
      line(&out, d, "extern-type #{t.id} {sp(t.span)}{vis(t.public)} {id(t.name)} {esc(t.c_type)}")
      doc(&out, d + 1, t.doc)
    }
  }
}

fn const_def(out: var [str], d: int, kw: str, c: ast.ConstDef) {
  line(&out, d, "{kw} #{c.id} {sp(c.span)}{vis(c.public)} {id(c.name)}")
  doc(&out, d + 1, c.doc)
  match c.ty {
    some(t) => ty(&out, d + 1, t)
    none => {}
  }
  expr(&out, d + 1, c.value)
}

fn generics(out: var [str], d: int, gs: [ast.Generic]) {
  for g in gs {
    line(&out, d, "generic {id(g.name)}")
    for b in g.bounds { ty(&out, d + 1, b) }
  }
}

fn clause(out: var [str], d: int, tag: str, c: ast.FnClause) {
  let asy = if c.is_async { " async" } else { "" }
  line(&out, d, "{tag} #{c.id} {sp(c.span)}{vis(c.public)}{asy} {id(c.name)}")
  doc(&out, d + 1, c.doc)
  generics(&out, d + 1, c.generics)
  for p in c.params { param(&out, d + 1, p) }
  match c.ret {
    some(t) => {
      line(&out, d + 1, "ret")
      ty(&out, d + 2, t)
    }
    none => {}
  }
  if c.effects.len() > 0 { line(&out, d + 1, "uses {ids(c.effects)}") }
  for e in c.pre {
    line(&out, d + 1, "requires")
    expr(&out, d + 2, e)
  }
  for e in c.post {
    line(&out, d + 1, "ensures")
    expr(&out, d + 2, e)
  }
  match c.guard {
    some(g) => {
      line(&out, d + 1, "when")
      expr(&out, d + 2, g)
    }
    none => {}
  }
  match c.body {
    some(Expr(e)) => {
      line(&out, d + 1, "body =")
      expr(&out, d + 2, e)
    }
    some(Block(b)) => {
      line(&out, d + 1, "body")
      block(&out, d + 2, b)
    }
    some(Extern(s)) => line(&out, d + 1, "extern {esc(s)}")
    none => {}
  }
}

fn param(out: var [str], d: int, p: ast.Param) {
  let v = if p.var_ { " var" } else { "" }
  line(&out, d, "param #{p.id} {sp(p.span)}{v}")
  pat(&out, d + 1, p.pat)
  match p.ty {
    some(t) => ty(&out, d + 1, t)
    none => {}
  }
}

fn units_text(u: [(str, int)]): str = "[" + u.map(x => "{x.0}:{x.1}").join(" ") + "]"

fn ty(out: var [str], d: int, t: ast.Type) {
  let head = "type #{t.id} {sp(t.span)}"
  match t.kind {
    Named(path, args) => {
      line(&out, d, "{head} named {ids(path)}")
      for a in args { ty(&out, d + 1, a) }
    }
    List(e) => {
      line(&out, d, "{head} list")
      ty(&out, d + 1, e)
    }
    Map(k, v) => {
      line(&out, d, "{head} map")
      ty(&out, d + 1, k)
      ty(&out, d + 1, v)
    }
    Tuple(ts) => {
      line(&out, d, "{head} tuple")
      for x in ts { ty(&out, d + 1, x) }
    }
    Optional(e) => {
      line(&out, d, "{head} optional")
      ty(&out, d + 1, e)
    }
    Fallible(ok, err) => {
      let e2 = if err is some(_) { " err" } else { "" }
      line(&out, d, "{head} fallible{e2}")
      ty(&out, d + 1, ok)
      match err {
        some(e) => ty(&out, d + 1, e)
        none => {}
      }
    }
    Any(e) => {
      line(&out, d, "{head} any")
      ty(&out, d + 1, e)
    }
    Fn(params, ret) => {
      line(&out, d, "{head} fn {params.len()}")
      for x in params { ty(&out, d + 1, x) }
      ty(&out, d + 1, ret)
    }
    Measured(base, units) => {
      line(&out, d, "{head} measured {units_text(units)}")
      ty(&out, d + 1, base)
    }
  }
}

fn lit(l: ast.Lit): str = match l {
  Int(n) => "int {token.uint_str(n)}"
  Float(x) => "float {x.bits()}"
  Bool(b) => "bool {b}"
  Char(c) => "char {int(c)}"
  Str(s) => "str {esc(s)}"
}

fn pat(out: var [str], d: int, p: ast.Pat) {
  let head = "pat #{p.id} {sp(p.span)}"
  match p.kind {
    Wild => line(&out, d, "{head} _")
    Bind(n) => line(&out, d, "{head} bind {n}")
    Lit(l, neg) => {
      let m = if neg { " -" } else { "" }
      line(&out, d, "{head} lit{m} {lit(l)}")
    }
    Tuple(ps) => {
      line(&out, d, "{head} tuple")
      for x in ps { pat(&out, d + 1, x) }
    }
    List(h, rest, tail) => {
      line(&out, d, "{head} list")
      for x in h { pat(&out, d + 1, x) }
      match rest {
        some(r) => {
          line(&out, d + 1, "rest {sp(r.span)}")
          match r.pat {
            some(x) => pat(&out, d + 2, x)
            none => {}
          }
          for x in tail { pat(&out, d + 1, x) }
        }
        none => {}
      }
    }
    Variant(path, args) => {
      let a2 = if args is some(_) { " args" } else { "" }
      line(&out, d, "{head} variant {ids(path)}{a2}")
      match args {
        some(a) => for x in a { pat(&out, d + 1, x) }
        none => {}
      }
    }
    Struct(path, fields, rest) => {
      let r2 = if rest { " .." } else { "" }
      line(&out, d, "{head} struct {ids(path)}{r2}")
      for f in fields {
        line(&out, d + 1, "field {id(f.name)}")
        match f.pat {
          some(x) => pat(&out, d + 2, x)
          none => {}
        }
      }
    }
    Map(es) => {
      line(&out, d, "{head} map")
      for (k, v) in es {
        line(&out, d + 1, "key {lit(k)}")
        pat(&out, d + 2, v)
      }
    }
    StrPrefix(prefix, rest) => {
      line(&out, d, "{head} prefix {esc(prefix)}")
      pat(&out, d + 1, rest)
    }
    Some(x) => {
      line(&out, d, "{head} some")
      pat(&out, d + 1, x)
    }
    None => line(&out, d, "{head} none")
    Ok(x) => {
      line(&out, d, "{head} ok")
      pat(&out, d + 1, x)
    }
    Err(x) => {
      line(&out, d, "{head} err")
      pat(&out, d + 1, x)
    }
  }
}

fn block(out: var [str], d: int, b: ast.Block) {
  line(&out, d, "block #{b.id} {sp(b.span)}")
  for s in b.stmts { expr(&out, d + 1, s) }
}

fn else_arm(out: var [str], d: int, a: ast.ElseArm) {
  match a.binder {
    some(b) => line(&out, d, "else {id(b)}")
    none => line(&out, d, "else")
  }
  expr(&out, d + 1, a.body)
}

fn exprs(out: var [str], d: int, es: [ast.Expr]) {
  for e in es { expr(&out, d, e) }
}

fn flag(b: bool, s: str): str = if b { s } else { "" }

fn expr(out: var [str], d: int, e: ast.Expr) {
  let head = "#{e.id} {sp(e.span)} "
  match e.kind {
    Lit(x) => line(&out, d, head + lit(x))
    Measured(x, units) => {
      line(&out, d, head + "measured {units_text(units)}")
      expr(&out, d + 1, x)
    }
    Interp(parts) => {
      line(&out, d, head + "interp")
      for part in parts {
        match part {
          Lit(s) => line(&out, d + 1, "lit {esc(s)}")
          Expr(x, spec) => {
            match spec {
              some(s) => line(&out, d + 1, "part spec={esc(s)}")
              none => line(&out, d + 1, "part")
            }
            expr(&out, d + 2, x)
          }
        }
      }
    }
    Name(n) => line(&out, d, head + "name {n}")
    Hole => line(&out, d, head + "hole")
    Field(x, name) => {
      line(&out, d, head + "field {id(name)}")
      expr(&out, d + 1, x)
    }
    TupleField(x, index) => {
      line(&out, d, head + "tuple-field {index}")
      expr(&out, d + 1, x)
    }
    Call(callee, args) => {
      line(&out, d, head + "call")
      expr(&out, d + 1, callee)
      exprs(&out, d + 1, args)
    }
    MethodCall(recv, name, args) => {
      line(&out, d, head + "method {id(name)}")
      expr(&out, d + 1, recv)
      exprs(&out, d + 1, args)
    }
    Pipe(lhs, callee, args) => {
      line(&out, d, head + "pipe")
      expr(&out, d + 1, lhs)
      expr(&out, d + 1, callee)
      exprs(&out, d + 1, args)
    }
    Index(x, index) => {
      line(&out, d, head + "index")
      expr(&out, d + 1, x)
      expr(&out, d + 1, index)
    }
    Slice(x, lo, hi, inclusive) => {
      line(&out, d, head + "slice" + flag(inclusive, " inclusive"))
      expr(&out, d + 1, x)
      expr(&out, d + 1, lo)
      expr(&out, d + 1, hi)
    }
    Unary(op, x) => {
      line(&out, d, head + "unary {op.unop_symbol()}")
      expr(&out, d + 1, x)
    }
    Binary(op, lhs, rhs) => {
      line(&out, d, head + "binary {op.symbol()}")
      expr(&out, d + 1, lhs)
      expr(&out, d + 1, rhs)
    }
    Range(lo, hi, inclusive) => {
      line(&out, d, head + "range" + flag(inclusive, " inclusive"))
      expr(&out, d + 1, lo)
      expr(&out, d + 1, hi)
    }
    Is(x, p) => {
      line(&out, d, head + "is")
      expr(&out, d + 1, x)
      pat(&out, d + 1, p)
    }
    Try(x) => {
      line(&out, d, head + "try")
      expr(&out, d + 1, x)
    }
    Unwrap(x) => {
      line(&out, d, head + "unwrap")
      expr(&out, d + 1, x)
    }
    OptChain(x, name, args) => {
      line(&out, d, head + "opt-chain {id(name)}" + flag(args is some(_), " args"))
      expr(&out, d + 1, x)
      match args {
        some(a) => exprs(&out, d + 1, a)
        none => {}
      }
    }
    Else(x, arm) => {
      line(&out, d, head + "else")
      expr(&out, d + 1, x)
      else_arm(&out, d + 1, arm)
    }
    Await(x) => {
      line(&out, d, head + "await")
      expr(&out, d + 1, x)
    }
    AwaitAny(x) => {
      line(&out, d, head + "await-any")
      expr(&out, d + 1, x)
    }
    Catch(x) => {
      line(&out, d, head + "catch")
      expr(&out, d + 1, x)
    }
    Ref(x) => {
      line(&out, d, head + "ref")
      expr(&out, d + 1, x)
    }
    Closure(params, body) => {
      line(&out, d, head + "closure")
      for p in params { param(&out, d + 1, p) }
      expr(&out, d + 1, body)
    }
    If(cond, then, els) => {
      line(&out, d, head + "if")
      expr(&out, d + 1, cond)
      block(&out, d + 1, then)
      match els {
        some(x) => expr(&out, d + 1, x)
        none => {}
      }
    }
    Match(scrut, arms) => {
      line(&out, d, head + "match")
      expr(&out, d + 1, scrut)
      for a in arms {
        line(&out, d + 1, "arm {sp(a.span)}")
        pat(&out, d + 2, a.pat)
        match a.guard {
          some(g) => {
            line(&out, d + 2, "when")
            expr(&out, d + 3, g)
          }
          none => {}
        }
        expr(&out, d + 2, a.body)
      }
    }
    Loop(b) => {
      line(&out, d, head + "loop")
      block(&out, d + 1, b)
    }
    While(cond, body) => {
      line(&out, d, head + "while")
      expr(&out, d + 1, cond)
      block(&out, d + 1, body)
    }
    For(index, p, iter, body) => {
      line(&out, d, head + "for" + flag(index is some(_), " indexed"))
      match index {
        some(i) => pat(&out, d + 1, i)
        none => {}
      }
      pat(&out, d + 1, p)
      expr(&out, d + 1, iter)
      block(&out, d + 1, body)
    }
    Block(b) => {
      line(&out, d, head + "block")
      block(&out, d + 1, b)
    }
    Let(mutable, p, t, value, els) => {
      line(&out, d, head + if mutable { "var" } else { "let" })
      pat(&out, d + 1, p)
      match t {
        some(x) => ty(&out, d + 1, x)
        none => {}
      }
      expr(&out, d + 1, value)
      match els {
        some(a) => else_arm(&out, d + 1, a)
        none => {}
      }
    }
    Assign(op, target, value) => {
      let o = match op {
        some(x) => x.symbol()
        none => ""
      }
      line(&out, d, head + "assign {o}=")
      expr(&out, d + 1, target)
      expr(&out, d + 1, value)
    }
    Assert(x) => {
      line(&out, d, head + "assert")
      expr(&out, d + 1, x)
    }
    Return(x) => {
      line(&out, d, head + "return")
      match x {
        some(v) => expr(&out, d + 1, v)
        none => {}
      }
    }
    Break(x) => {
      line(&out, d, head + "break")
      match x {
        some(v) => expr(&out, d + 1, v)
        none => {}
      }
    }
    Continue => line(&out, d, head + "continue")
    Peek(x) => {
      line(&out, d, head + "peek")
      expr(&out, d + 1, x)
    }
    Struct(path, fields, base) => {
      line(&out, d, head + "struct {ids(path)}")
      for f in fields {
        line(&out, d + 1, "field {id(f.name)}")
        match f.value {
          some(v) => expr(&out, d + 2, v)
          none => {}
        }
      }
      match base {
        some(b) => {
          line(&out, d + 1, "base")
          expr(&out, d + 2, b)
        }
        none => {}
      }
    }
    List(xs) => {
      line(&out, d, head + "list")
      exprs(&out, d + 1, xs)
    }
    Map(es) => {
      line(&out, d, head + "map")
      for (k, v) in es {
        line(&out, d + 1, "entry")
        expr(&out, d + 2, k)
        expr(&out, d + 2, v)
      }
    }
    Tuple(xs) => {
      line(&out, d, head + "tuple")
      exprs(&out, d + 1, xs)
    }
  }
}

/// The `auk dump tokens|ast|resolve` text (src/dump.rs): one node per line, children indented by two
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
    Array(e, n) => {
      line(&out, d, "{head} array {n}")
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
    Var(t) => {
      line(&out, d, "{head} var")
      ty(&out, d + 1, t)
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
    Or(ps) => {
      line(&out, d, "{head} or")
      for x in ps { pat(&out, d + 1, x) }
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
    TypeArgs(x, tys) => {
      line(&out, d, head + "type-args")
      for t in tys { ty(&out, d + 1, t) }
      expr(&out, d + 1, x)
    }
    FieldSel(n) => line(&out, d, head + "field-sel {n.name}")
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

// ---- module tree and paths (resolve) ----

/// `file` relative to the current directory `cwd` (when under it).
fn rel(cwd: str, file: str): str {
  if cwd == "" { return file }
  file.strip_prefix(cwd + "/") else file
}

pub fn resolved(out: var [str], cwd: str, r: resolve.Program!diag.FileFails) {
  match r {
    ok(p) => program(&out, cwd, p)
    err(Many(ds)) => for d in ds {
      line(&out, 0, "in {esc(rel(cwd, d.file))}")
      diag_dump(&out, d.diag)
    }
  }
}

fn program(out: var [str], cwd: str, p: resolve.Program) {
  line(&out, 0, "root {p.root} focus {p.focus} core {p.core_pkg} {p.core_root}")
  for i, k in p.pkgs {
    let dir = match k.dir {
      some(d) => esc(rel(cwd, d))
      none => "-"
    }
    line(&out, 0, "pkg {i} {esc(k.name)} root={k.root} dir={dir}{flag(k.is_core, " core")}")
    for n in resolve.sorted_keys(k.deps) { line(&out, 1, "dep {n} {k.deps[n]}") }
    if k.effects.len() > 0 { line(&out, 1, "effects {k.effects.map(esc).join(" ")}") }
    if k.links.len() > 0 { line(&out, 1, "links {k.links.map(esc).join(" ")}") }
  }
  for i, m in p.mods {
    line(
      &out,
      0,
      "mod {i} {resolve.name(p, i)} pkg={m.pkg} file={esc(rel(cwd, m.file))} items={m.ast.items.len()}",
    )
    for n in resolve.sorted_keys(m.children) { line(&out, 1, "child {n} {m.children[n]}") }
    if resolve.is_core(p, i) { continue }
    let name = resolve.name(p, i)
    for it in m.ast.items { item_line(&out, name, it) }
    var paths: [[ast.Ident]] = []
    for it in m.ast.items { item_paths(it, &paths) }
    for path in paths { use_line(&out, p, i, path) }
  }
}

fn item_line(out: var [str], m: str, it: ast.Item) {
  let (kind, n, public) = match it {
    Fn(g) => {
      var public = false
      match g.header {
        some(h) => public = h.public
        none => {}
      }
      for c in g.clauses { public = public || c.public }
      ("fn/{g.arity}", g.name, public)
    }
    Struct(d) => ("struct", d.name.name, d.public)
    Enum(d) => ("enum", d.name.name, d.public)
    Shape(d) => ("shape", d.name.name, d.public)
    Test(t) => {
      line(&out, 1, "item test {esc(t.name)} {m}")
      return
    }
    Let(c) => ("let", c.name.name, c.public)
    Imprint(c) => ("imprint", c.name.name, c.public)
    ExternType(t) => ("extern-type", t.name.name, t.public)
  }
  line(&out, 1, "item {kind} {m}.{n}{vis(public)}")
  match it {
    Enum(d) => for v in d.variants { line(&out, 2, "variant {m}.{n}.{v.name.name}") }
    _ => {}
  }
}

/// The module paths an item mentions, in order: its signature's type and pattern paths, then
/// those of its expressions (`visit.visit_item_exprs` order): `a.b.c` field chains, a method
/// call's receiver name, and the qualifier of struct literals, types and patterns (`m.T`).
fn item_paths(it: ast.Item, acc: var [[ast.Ident]]) {
  match it {
    Fn(g) => {
      match g.header {
        some(h) => clause_paths(h, &acc)
        none => {}
      }
      for c in g.clauses { clause_paths(c, &acc) }
    }
    Struct(d) => {
      generic_paths(d.generics, &acc)
      for f in d.fields { ty_paths(f.ty, &acc) }
    }
    Enum(d) => {
      generic_paths(d.generics, &acc)
      for v in d.variants {
        for f in v.fields { ty_paths(f.ty, &acc) }
      }
    }
    Shape(d) => {
      generic_paths(d.generics, &acc)
      for c in d.methods { clause_paths(c, &acc) }
    }
    Let(c) | Imprint(c) => match c.ty {
      some(t) => ty_paths(t, &acc)
      none => {}
    }
    Test(_) | ExternType(_) => {}
  }
  var es: [ast.Expr] = []
  visit.visit_item_exprs(it, &es)
  for e in es { expr_paths(e, &acc) }
}

fn clause_paths(c: ast.FnClause, acc: var [[ast.Ident]]) {
  generic_paths(c.generics, &acc)
  for p in c.params { param_paths(p, &acc) }
  match c.ret {
    some(t) => ty_paths(t, &acc)
    none => {}
  }
}

fn generic_paths(gs: [ast.Generic], acc: var [[ast.Ident]]) {
  for g in gs {
    for b in g.bounds { ty_paths(b, &acc) }
  }
}

fn param_paths(p: ast.Param, acc: var [[ast.Ident]]) {
  pat_paths(p.pat, &acc)
  match p.ty {
    some(t) => ty_paths(t, &acc)
    none => {}
  }
}

/// The qualifier of `m.x` (nothing for a bare name).
fn qualifier(path: [ast.Ident], acc: var [[ast.Ident]]) {
  if path.len() >= 2 { acc.push(path.take(path.len() - 1)) }
}

fn ty_paths(t: ast.Type, acc: var [[ast.Ident]]) {
  match t.kind {
    Named(path, args) => {
      qualifier(path, &acc)
      for a in args { ty_paths(a, &acc) }
    }
    List(x) | Optional(x) | Any(x) | Var(x) | Array(x, _) => ty_paths(x, &acc)
    Measured(b, _) => ty_paths(b, &acc)
    Map(k, v) => {
      ty_paths(k, &acc)
      ty_paths(v, &acc)
    }
    Tuple(ts) => for x in ts { ty_paths(x, &acc) }
    Fallible(ok_, err_) => {
      ty_paths(ok_, &acc)
      match err_ {
        some(e) => ty_paths(e, &acc)
        none => {}
      }
    }
    Fn(params, ret) => {
      for x in params { ty_paths(x, &acc) }
      ty_paths(ret, &acc)
    }
  }
}

fn pat_paths(p: ast.Pat, acc: var [[ast.Ident]]) {
  match p.kind {
    Wild | Bind(_) | Lit(_, _) | None => {}
    Tuple(ps) | Or(ps) => for x in ps { pat_paths(x, &acc) }
    List(head, rest, tail) => {
      for x in head { pat_paths(x, &acc) }
      match rest {
        some(r) => match r.pat {
          some(x) => pat_paths(x, &acc)
          none => {}
        }
        none => {}
      }
      for x in tail { pat_paths(x, &acc) }
    }
    Variant(path, args) => {
      qualifier(path, &acc)
      match args {
        some(a) => for x in a { pat_paths(x, &acc) }
        none => {}
      }
    }
    Struct(path, fields, _) => {
      qualifier(path, &acc)
      for f in fields {
        match f.pat {
          some(x) => pat_paths(x, &acc)
          none => {}
        }
      }
    }
    Map(es) => for (_, x) in es { pat_paths(x, &acc) }
    StrPrefix(_, rest) => pat_paths(rest, &acc)
    Some(x) | Ok(x) | Err(x) => pat_paths(x, &acc)
  }
}

/// The paths of one expression node (not its sub-expressions: the visitor reaches those).
fn expr_paths(e: ast.Expr, acc: var [[ast.Ident]]) {
  match e.kind {
    Field(_, _) => match visit.as_path(e) {
      some(p) => acc.push(p)
      none => {}
    }
    MethodCall(recv, _, _) => match recv.kind {
      Name(n) => acc.push([ast.Ident { name: n, span: recv.span }])
      _ => {}
    }
    Struct(path, _, _) => qualifier(path, &acc)
    Is(_, pat) => pat_paths(pat, &acc)
    Match(_, arms) => for a in arms { pat_paths(a.pat, &acc) }
    For(index, pat, _, _) => {
      match index {
        some(i) => pat_paths(i, &acc)
        none => {}
      }
      pat_paths(pat, &acc)
    }
    Let(_, pat, ty, _, _) => {
      pat_paths(pat, &acc)
      match ty {
        some(t) => ty_paths(t, &acc)
        none => {}
      }
    }
    Closure(params, _) => for p in params { param_paths(p, &acc) }
    _ => {}
  }
}

/// `use <span> a.b.c -> <module> k/n`: the module the first `k` of the path's `n` segments
/// name. Nothing when the first segment names no module.
fn use_line(out: var [str], p: resolve.Program, m: int, path: [ast.Ident]) {
  var cur = resolve.first_segment(p, m, path[0].name) else return
  var k = 1
  while k < path.len() {
    match resolve.child(p, cur, path[k].name) {
      some(c) => cur = c
      none => break
    }
    k += 1
  }
  let a = path[0].span
  let b = path[path.len() - 1].span
  let span = diag.Span { line: a.line, col: a.col, end_line: b.end_line, end_col: b.end_col }
  let text = path.map(i => i.name).join(".")
  line(&out, 1, "use {sp(span)} {text} -> {resolve.name(p, cur)} {k}/{path.len()}")
}

// ---- the checker's diagnostics and typed program (check, typed) ----

/// `auk dump check`: the `auk check --json` report of the type checker proper
/// (`check.check_types`), without patterns.rs and effects.rs.
pub fn checked(path: str, r: resolve.Program!diag.FileFails): str uses fs {
  let diags = match r {
    ok(prog) => check.check_types(prog).1
    err(Many(ds)) => ds
  }
  diag.json_report_files(path, diags)
}

/// `auk dump typed`: the checker's errors and the typed program (erased when there were no
/// errors, as `check::check` returns it).
pub fn typed_program(out: var [str], cwd: str, r: resolve.Program!diag.FileFails, core: bool) uses fs {
  let prog = match r {
    ok(p) => p
    err(Many(ds)) => {
      for d in ds {
        line(&out, 0, "in {esc(rel(cwd, d.file))}")
        diag_dump(&out, d.diag)
      }
      return
    }
  }
  let (tp, errs) = check.check_types(prog)
  for d in errs {
    line(&out, 0, "in {esc(rel(cwd, d.file))}")
    diag_dump(&out, d.diag)
  }
  match tp {
    some(t) => {
      var t2 = t
      if errs.len() == 0 { units.erase(&t2) }
      typed(&out, cwd, t2, core)
    }
    none => {}
  }
}

fn show_ty(tp: typed.TypedProgram, t: types.Ty): str = types.show(tp.defs, t)

fn show_tys(tp: typed.TypedProgram, ts: [types.Ty]): str = ts.map(t => types.show(tp.defs, t)).join(", ")

fn ints(xs: [int]): str = "[" + xs.map(x => "{x}").join(", ") + "]"

/// See src/dump.rs `typed`.
fn typed(out: var [str], cwd: str, tp: typed.TypedProgram, core: bool) {
  let d = tp.defs
  let focus = tp.program.focus
  match tp.main {
    some(m) => line(&out, 0, "main #{m.func} args={m.takes_args} ret={show_ty(tp, m.ret)}")
    none => line(&out, 0, "main -")
  }
  for i, t in d.types {
    if tp.program.is_core(t.module) && !core { continue }
    let ps = t.params.map(p => d.params[p].name).join(", ")
    line(&out, 0, "def #{i} {tp.program.name(t.module)}.{t.name}<{ps}>{vis(t.public)}")
    match t.kind {
      Struct(fields) => for f in fields { line(&out, 1, "field {f.name}: {show_ty(tp, f.ty)}{vis(f.public)}") }
      Enum(variants) => for v in variants {
        let fs = v.fields.map(x => match x.0 {
          some(n) => "{n}: {types.show(d, x.1)}"
          none => types.show(d, x.1)
        })
        line(&out, 1, "variant {v.name}({fs.join(", ")})")
      }
      Opaque(ct) => line(&out, 1, "opaque {esc(ct)}")
    }
  }
  for i, s in d.shapes {
    if tp.program.is_core(s.module) && !core { continue }
    line(&out, 0, "shape #{i} {tp.program.name(s.module)}.{s.name}{vis(s.public)}")
    for m in s.methods { line(&out, 1, "method {m.name}({show_tys(tp, m.params)}): {show_ty(tp, m.ret)}") }
  }
  for i, f in tp.fns {
    let ps = f.params.map(p => (if p.var_ { "var " } else { "" }) + (p.name else "_") + ": " + types.show(d, p.ty))
    let gs = f.generics.map(g => bounded(d, g))
    let kind = match f.kind {
      Auk(item, clauses, header) => "auk item={item} clauses={ints(clauses)}" + flag(header, " header")
      Extern(symbol, loc, item) => "extern {esc(symbol)}" + flag(loc, " +loc") + " item={item}"
      Ffi(sig, convs, item) => {
        let free = match sig.free {
          some(x) => " free={x}"
          none => ""
        }
        let cps = sig.params.map(x => cffi.show(x)).join(", ")
        "ffi {sig.name} ({cps}) -> {cffi.show(sig.ret)}{free}" + flag(sig.indirect, " indirect") + flag(sig.cast, " cast") + (match sig.embed {
          some(e) => " embed=" + esc(rel(cwd, e))
          none => ""
        }) +
          " convs=[{convs.map(conv_text).join(", ")}] item={item}"
      }
      Intrinsic(which, item) => "intrinsic {typed.intrinsic_name(which)} item={item}"
    }
    let g = if gs.len() == 0 { "" } else { "<" + gs.join(", ") + ">" }
    let a = if f.is_async { "async " } else { "" }
    line(&out, 0, "fn #{i} {tp.program.name(f.module)}.{a}{f.name}{g}({ps.join(", ")}): {show_ty(tp, f.ret)} [{kind}]{vis(f.public)}")
    if f.module == focus || core {
      let olds = f.olds.map(x => "#{x}").join(", ")
      let r = match f.result_local {
        some(l) => " result={l}"
        none => ""
      }
      line(&out, 1, "span {sp(f.span)} uses=[{f.effects.join(", ")}] callees=[{f.callees.map(x => "{x}").join(", ")}] olds=[{olds}]{r}")
    }
  }
  for i, k in tp.consts {
    line(&out, 0, "const #{i} {tp.program.name(k.module)}.{k.name}: {show_ty(tp, k.ty)}{vis(k.public)}" + flag(k.imprint, " imprint") + " item={k.item} {sp(k.span)}")
  }
  for i, t in tp.tests {
    line(&out, 0, "test #{i} {tp.program.name(t.module)}.{esc(t.name)} item={t.item} {sp(t.span)}")
  }
  for m, t in tp.tables {
    if m != focus && !core { continue }
    line(&out, 0, "module {m} {tp.program.name(m)} {esc(rel(cwd, tp.program.mods[m].file))}")
    tables(&out, tp, t)
  }
  for i, inst in tp.instances {
    let (what, module) = match inst.body {
      Fn(f) => ("fn #{f} {tp.fns[f].name}", tp.fns[f].module)
      Test(t) => ("test #{t} {esc(tp.tests[t].name)}", tp.tests[t].module)
      Const(k) => ("const #{k} {tp.consts[k].name}", tp.consts[k].module)
    }
    let args = if inst.type_args.len() == 0 { "" } else { "<" + show_tys(tp, inst.type_args) + ">" }
    line(&out, 0, "instance {i} {what}{args}")
    if module != focus && !core { continue }
    for n in inst.resolved.keys().sort() { line(&out, 1, "#{n} -> {target(tp, inst.resolved[n])}") }
    for n in inst.shows.keys().sort() { line(&out, 1, "show #{n} -> {target(tp, inst.shows[n])}") }
    for n in inst.vtables.keys().sort() { line(&out, 1, "vtable #{n} -> {inst.vtables[n]}") }
  }
  for t in tp.types_used { line(&out, 0, "used {show_ty(tp, t)}") }
  // Rust's BTreeMap order: by (Builtin, Ty)
  var impls: [(int, types.Ty)] = []
  for k in tp.shape_impls.keys() { impls.push((builtin_rank(k.0), k.1)) }
  for k in impls.sort_by(x => x) {
    let b = rank_builtin(k.0)
    line(&out, 0, "impl {builtin_name(b)} {show_ty(tp, k.1)} -> {target(tp, tp.shape_impls[(b, k.1)])}")
  }
  for t in tp.from_value_impls.keys().sort() {
    line(&out, 0, "from_value {show_ty(tp, t)} -> {target(tp, tp.from_value_impls[t])}")
  }
  for i, v in tp.vtables {
    line(&out, 0, "vtable {i} {d.shapes[v.shape].name} {show_ty(tp, v.ty)} [{v.methods.map(x => target(tp, x)).join(", ")}]")
  }
}

fn builtin_rank(b: types.Builtin): int = match b {
  Show => 0
  Ord => 1
  Eq => 2
  Data => 3
}

fn rank_builtin(r: int): types.Builtin =
  if r == 0 { types.Builtin.Show } else if r == 1 { types.Builtin.Ord } else if r == 2 { types.Builtin.Eq } else { types.Builtin.Data }

/// Rust's `{b:?}`.
fn builtin_name(b: types.Builtin): str = match b {
  Show => "Show"
  Ord => "Ord"
  Eq => "Eq"
  Data => "Data"
}

/// A type parameter with its bounds: `T: Show + Eq`, `Ord: Ord implicit`.
fn bounded(d: types.Defs, p: int): str {
  let tp = d.params[p]
  let bs = tp.bounds.map(b => d.shapes[b].name)
  let b = if bs.len() == 0 { "" } else { ": " + bs.join(" + ") }
  tp.name + b + flag(tp.implicit, " implicit")
}

fn conv_text(cv: cffi.Conv): str = match cv {
  Int(bytes, signed) => "int{bytes}" + (if signed { "s" } else { "u" })
  Bool => "bool"
  Float(f32) => if f32 { "f32" } else { "f64" }
  Str(owned) => "str" + flag(owned, "+owned")
  OptStr(owned) => "optstr" + flag(owned, "+owned")
  Ptr => "ptr"
  OptPtr => "optptr"
  Unit => "unit"
  List(elem, back) => "list {elem_name(elem)}" + flag(back, " back")
  Out(x) => "out(" + conv_text(x) + ")"
}

fn elem_name(e: cffi.Elem): str = match e {
  Raw => "Raw"
  I8 => "I8"
  U8 => "U8"
  I16 => "I16"
  U16 => "U16"
  I32 => "I32"
  U32 => "U32"
  F32 => "F32"
}

fn fn_name(tp: typed.TypedProgram, f: int): str = "{tp.fns[f].name}#{f}"

fn variant_name(tp: typed.TypedProgram, def: int, index: int): str {
  let vs = types.variants(tp.defs, def)
  let v = if index < vs.len() { vs[index].name } else { "?" }
  "{tp.defs.types[def].name}.{v}"
}

fn targs(tp: typed.TypedProgram, ts: [types.Ty]): str = if ts.len() == 0 { "" } else { "<" + show_tys(tp, ts) + ">" }

fn shape_method(tp: typed.TypedProgram, shape: int, method: int): str {
  let s = tp.defs.shapes[shape]
  let m = if method < s.methods.len() { s.methods[method].name } else { "?" }
  "{s.name}.{m}"
}

fn callee(tp: typed.TypedProgram, ce: typed.Callee): str = match ce {
  Fn(func, type_args) => "fn {fn_name(tp, func)}{targs(tp, type_args)}"
  Variant(v) => "variant {variant_name(tp, v.def, v.index)}{targs(tp, v.args)}"
  Closure => "closure"
  Shape(shape, method, self_ty) => "shape {shape_method(tp, shape, method)} @{show_ty(tp, self_ty)}"
  Vtable(shape, method) => "vtable {shape_method(tp, shape, method)}"
}

fn target(tp: typed.TypedProgram, t: typed.Target): str = match t {
  Instance(i) => "inst {i}"
  Extern(symbol, loc) => "extern {esc(symbol)}" + flag(loc, " +loc")
  Ffi(f) => "ffi {fn_name(tp, f)}"
  Intrinsic(which, ty) => "intrinsic {typed.intrinsic_name(which)} {show_ty(tp, ty)}"
  Derived(shape, ty) => "derived {builtin_name(shape)} {show_ty(tp, ty)}"
  Vtable(shape, method) => "vtable {shape_method(tp, shape, method)}"
  Variant(def, index) => "variant {variant_name(tp, def, index)}"
  Closure => "closure"
}

fn coercions(tp: typed.TypedProgram, cs: [typed.Coercion]): str = cs.map(co => match co {
  WrapSome => "some"
  WrapOk => "ok"
  ToAny(s) => "any {tp.defs.shapes[s].name}"
}).join(",")

fn opt_char(x: char?): str = match x {
  some(ch) => "{int(ch)}"
  none => "-"
}

fn opt_int(x: int?): str = match x {
  some(n) => "{n}"
  none => "-"
}

/// One module's side tables (see src/dump.rs `tables`).
fn tables(out: var [str], tp: typed.TypedProgram, t: typed.Tables) {
  var seen: {int: bool} = {}
  for k in t.types.keys() { seen[k] = true }
  for k in t.coercions.keys() { seen[k] = true }
  for k in t.names.keys() { seen[k] = true }
  for k in t.binds.keys() { seen[k] = true }
  for k in t.variants.keys() { seen[k] = true }
  for k in t.calls.keys() { seen[k] = true }
  for k in t.fields.keys() { seen[k] = true }
  for k in t.struct_lits.keys() { seen[k] = true }
  for k in t.struct_pats.keys() { seen[k] = true }
  for k in t.closures.keys() { seen[k] = true }
  for k in t.tries.keys() { seen[k] = true }
  for k in t.fails.keys() { seen[k] = true }
  for k in t.elses.keys() { seen[k] = true }
  for k in t.opt_chains.keys() { seen[k] = true }
  for k in t.awaits.keys() { seen[k] = true }
  for k in t.fors.keys() { seen[k] = true }
  for k in t.formats.keys() { seen[k] = true }
  for k in t.shows.keys() { seen[k] = true }
  for k in t.value_map_pats.keys() { seen[k] = true }
  for k in t.err_payload_pats.keys() { seen[k] = true }
  for k in t.units.keys() { seen[k] = true }
  let d = tp.defs
  for n in seen.keys().sort() {
    var s: [str] = ["#{n}"]
    match t.types.get(n) {
      some(ty) => s.push(" : " + types.show(d, ty))
      none => {}
    }
    match t.coercions.get(n) {
      some(cs) => s.push(" coerce=" + coercions(tp, cs))
      none => {}
    }
    match t.names.get(n) {
      some(r) => {
        let r2 = match r {
          Local(l) => "local {l}"
          Const(k) => "const {tp.consts[k].name}#{k}"
          Fn(func, type_args) => "fn {fn_name(tp, func)}{targs(tp, type_args)}"
          Variant(v) => "variant {variant_name(tp, v.def, v.index)}{targs(tp, v.args)}"
          None => "none"
        }
        s.push(" name=(" + r2 + ")")
      }
      none => {}
    }
    match t.binds.get(n) {
      some(l) => s.push(" bind={l}")
      none => {}
    }
    match t.variants.get(n) {
      some(v) => s.push(" variant={variant_name(tp, v.def, v.index)}{targs(tp, v.args)}")
      none => {}
    }
    match t.calls.get(n) {
      some(call) => {
        let args = call.args.map(a => (if a.by_ref { "&" } else { "" }) + "#{a.node}").join(", ")
        s.push(" call=({callee(tp, call.callee)})({args})")
      }
      none => {}
    }
    match t.fields.get(n) {
      some((def, i)) => {
        let fs = types.fields(d, def)
        let f = if i < fs.len() { fs[i].name } else { "?" }
        s.push(" field={d.types[def].name}.{f}")
      }
      none => {}
    }
    match t.struct_lits.get(n) {
      some(sl) => {
        let fs = sl.fields.map(x => match x.1 {
          Expr(node) => "{x.0}=#{node}"
          Local(l, cs) => "{x.0}=local {l}" + (if cs.len() == 0 { "" } else { " " + coercions(tp, cs) })
        })
        s.push(" struct={d.types[sl.def].name}{targs(tp, sl.args)}{{{fs.join(", ")}}}")
      }
      none => {}
    }
    match t.struct_pats.get(n) {
      some(spat) => {
        let fs = spat.fields.map(x => match x.1 {
          some(l) => "{x.0}=local {l}"
          none => "{x.0}"
        })
        s.push(" struct_pat={d.types[spat.def].name}{{{fs.join(", ")}}}")
      }
      none => {}
    }
    match t.closures.get(n) {
      some(cl) => {
        let caps = cl.captures.map(l => "{l}").join(", ")
        s.push(" closure=({show_tys(tp, cl.params)}) => {show_ty(tp, cl.ret)} captures=[{caps}]" + flag(cl.unpack, " unpack"))
      }
      none => {}
    }
    match t.tries.get(n) {
      some(tr) => {
        let conv = match tr.conv {
          None => ""
          ToErr(from) => " to_err " + types.show(d, from)
        }
        let k = match tr.kind {
          Result => "Result"
          Option => "Option"
          ListResult => "ListResult"
          ListOption => "ListOption"
        }
        s.push(" try={k}{conv}")
      }
      none => {}
    }
    match t.fails.get(n) {
      some(f) => {
        let f2 = match f {
          Message => "message"
          Err => "err"
          Typed => "typed"
          TypedToErr(x) => "typed_to_err " + types.show(d, x)
        }
        s.push(" fail={f2}")
      }
      none => {}
    }
    match t.elses.get(n) {
      some(e) => {
        let k = match e.kind {
          Option => "option"
          Result => "result"
          Refutable => "refutable"
          UnwrapRefutable(option) => "unwrap_refutable " + (if option { "option" } else { "result" })
        }
        let b = match e.binder {
          some(l) => " binder={l}"
          none => ""
        }
        s.push(" else={k}{b}")
      }
      none => {}
    }
    match t.opt_chains.get(n) {
      some(o) => s.push(" opt_chain" + flag(o.flatten, " flatten"))
      none => {}
    }
    match t.awaits.get(n) {
      some(a) => {
        let k = match a {
          Direct => "Direct"
          Task => "Task"
          Tuple => "Tuple"
          List => "List"
        }
        s.push(" await={k}")
      }
      none => {}
    }
    match t.fors.get(n) {
      some(f) => {
        let k = match f {
          Range(inclusive) => "range" + flag(inclusive, " inclusive")
          List => "list"
          Map => "map"
          Chan => "chan"
        }
        s.push(" for={k}")
      }
      none => {}
    }
    match t.formats.get(n) {
      some(f) => s.push(" format={esc(f.text)} fill={opt_char(f.fill)} align={opt_char(f.align)} zero={f.zero} width={opt_int(f.width)} precision={opt_int(f.precision)} radix={opt_char(f.radix)}")
      none => {}
    }
    match t.shows.get(n) {
      some(ce) => s.push(" show=({callee(tp, ce)})")
      none => {}
    }
    if t.value_map_pats.contains(n) { s.push(" value_map") }
    match t.err_payload_pats.get(n) {
      some(x) => s.push(" err_payload=" + types.show(d, x))
      none => {}
    }
    match t.units.get(n) {
      some(u) => s.push(" unit=" + esc(u))
      none => {}
    }
    line(&out, 1, s.join(""))
  }
  for i, l in t.locals {
    line(&out, 1, "local {i} {l.name}: {types.show(d, l.ty)}" + flag(l.mutable, " mut") + " {sp(l.span)}")
  }
}

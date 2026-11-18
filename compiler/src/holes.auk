/// `auk holes <file> [--json]` (src/holes.rs): a brief for every `??` hole in a program — what
/// an AI agent (or `auk hatch`) needs to fill it. See the Rust module for the JSON schema.
///
/// The holes are those of the root file and of the other modules of its project (root file
/// first, then the project's modules in load order, each in source order), numbered from 1.
/// With type errors the brief is still printed from the partial program (types that couldn't be
/// inferred show as `?`) and the exit code is 1.
///
/// Differences from Rust: the `Json` values of `hole_json` are written straight to text
/// (`jstr` is json.rs's `write_str`); `Walk`'s closures over `&mut self` are loops.

/// Everything known about one hole.
pub struct Hole {
  index: int,
  file: str,
  span: diag.Span,
  expected: str,
  context: str,
  /// The span of the block whose only statement is this hole (`{ ?? }`), if it is one.
  body: diag.Span?,
  function: FnBrief?,
  scope: [Var],
  tests: [TestRef],
  module_fns: [(str, str)],
  module_types: [(str, str)],
}

pub struct FnBrief { name: str, signature: str, doc: str?, pre: [str], post: [str] }

pub struct Var { name: str, ty: str, mutable: bool }

pub struct TestRef { name: str, file: str, line: int, source: str }

/// Load and type-check the program rooted at `path` and find its holes. Returns the holes and
/// every diagnostic; an error when the program couldn't be loaded or its declarations don't
/// check.
pub fn analyze(cx: resolve.Sources, path: str): ([Hole], [diag.FileDiag])!diag.FileFails uses fs, ffi {
  let prog = resolve.load(cx, path)?
  let (tp, diags) = check.check_all(prog)
  match tp {
    some(t) => (discover(t), diags)
    none => {
      // errors: the partial program, so the brief is still available
      match check.check_partial(prog).0 {
        some(t) => (discover(t), diags)
        none => fail(diag.Many(diags))
      }
    }
  }
}

/// The modules searched for holes: the root, then the rest of the root package with a file.
pub fn project_modules(tp: typed.TypedProgram): [int] {
  let p = tp.program
  let pkg = p.mods[p.root].pkg
  var ms = [p.root]
  for m in 0..p.mods.len() {
    if m != p.root && p.mods[m].pkg == pkg && p.mods[m].file != "" { ms.push(m) }
  }
  ms
}

fn hole_ids(es: [ast.Expr]): [int] {
  var all: [ast.Expr] = []
  for e in es { visit.visit_expr(e, &all) }
  var ids: [int] = []
  for e in all {
    if e.kind is ast.ExprKind.Hole { ids.push(e.id) }
  }
  ids
}

/// Every hole of the project, numbered from 1.
pub fn discover(tp: typed.TypedProgram): [Hole] {
  let mods = project_modules(tp)
  var out: [Hole] = []
  for m in mods {
    let module = tp.program.mods[m]
    let tables = tp.tables[m]
    for i, item in module.ast.items {
      match item {
        Fn(g) => {
          var cls: [ast.FnClause] = []
          match g.header {
            some(h) => cls.push(h)
            none => {}
          }
          for c in cls + g.clauses {
            for id in holes_in_clause(c) {
              var w = Walk { t: tables, target: id, scope: [], body: none }
              let _ = w.clause(c)
              let header = g.header
              let doc: str? = match c.doc {
                some(d) => d
                none => match header {
                  some(h) => h.doc
                  none => none
                }
              }
              var pre: [str] = []
              var post: [str] = []
              var with_header: [ast.FnClause] = []
              match header {
                some(h) => with_header.push(h)
                none => {}
              }
              with_header.push(c)
              for cl in with_header {
                for e in cl.pre { pre.push(text(module.src, e.span)) }
                for e in cl.post { post.push(text(module.src, e.span)) }
              }
              let function = FnBrief { name: g.name, signature: signature(module.src, c), doc, pre: dedup(pre), post: dedup(post) }
              var fids: {int: bool} = {}
              for fid, f in tp.fns {
                if f.module != m { continue }
                match f.kind {
                  Auk(it, _, _) => if it == i { fids[fid] = true }
                  _ => {}
                }
              }
              out.push(make(tp, m, id, w, "fn {g.name}", function, callers(tp, mods, fids), i))
            }
          }
        }
        Test(t) => for id in hole_ids(t.body.stmts) {
          var w = Walk { t: tables, target: id, scope: [], body: none }
          let _ = w.block(t.body)
          out.push(make(tp, m, id, w, "test {check_expr.debug_str(t.name)}", none, [], none))
        }
        Let(c) | Imprint(c) => {
          let kw = if item is ast.Item.Let(_) { "let" } else { "imprint" }
          for id in hole_ids([c.value]) {
            var w = Walk { t: tables, target: id, scope: [], body: none }
            let _ = w.expr(c.value)
            out.push(make(tp, m, id, w, "{kw} {c.name.name}", none, [], none))
          }
        }
        _ => {}
      }
    }
  }
  var numbered: [Hole] = []
  for i, h in out { numbered.push(Hole { index: i + 1, ..h }) }
  numbered
}

/// Rust's `Vec::dedup`: without consecutive duplicates.
fn dedup(xs: [str]): [str] {
  var out: [str] = []
  for x in xs {
    if out.len() == 0 || out[out.len() - 1] != x { out.push(x) }
  }
  out
}

fn make(tp: typed.TypedProgram, m: int, id: int, w: Walk, context: str, function: FnBrief?, tests: [TestRef], own_item: int?): Hole {
  let module = tp.program.mods[m]
  let tables = tp.tables[m]
  let span = find_span(module.ast, id) else diag.NONE
  let expected = match tables.types.get(id) {
    some(t) => show(tp, t)
    none => "?"
  }
  // innermost binding of each name wins; keep the outermost-first order
  var scope: [Var] = []
  for l in w.scope {
    let li = tables.locals.get(l) else continue
    scope = scope.filter(v => v.name != li.name)
    scope.push(Var { name: li.name, ty: show(tp, li.ty), mutable: li.mutable })
  }
  var module_fns: [(str, str)] = []
  var module_types: [(str, str)] = []
  for i, item in module.ast.items {
    match item {
      Fn(g) => if own_item != some(i) {
        let c: ast.FnClause? = match g.header {
          some(h) => h
          none => g.clauses.get(0)
        }
        match c {
          some(c) => module_fns.push((g.name, signature(module.src, c)))
          none => {}
        }
      }
      Struct(s) => module_types.push((s.name.name, text(module.src, s.span)))
      Enum(e) => module_types.push((e.name.name, text(module.src, e.span)))
      Shape(s) => module_types.push((s.name.name, text(module.src, s.span)))
      _ => {}
    }
  }
  Hole { index: 0, file: module.file, span, expected, context, body: w.body, function, scope, tests, module_fns, module_types }
}

fn show(tp: typed.TypedProgram, t: types.Ty): str = if t.has_error() || t.has_vars() { "?" } else { tp.defs.show(t) }

/// The hole ids of a clause, in source order.
fn holes_in_clause(c: ast.FnClause): [int] {
  var es = c.pre + c.post
  match c.guard {
    some(g) => es.push(g)
    none => {}
  }
  match c.body {
    some(Expr(e)) => es.push(e)
    some(Block(b)) => es = es + b.stmts
    _ => {}
  }
  hole_ids(es)
}

fn find_span(m: ast.Module, id: int): diag.Span? {
  var found: diag.Span? = none
  for item in m.items {
    var all: [ast.Expr] = []
    visit.visit_item_exprs(item, &all)
    for e in all {
      if e.id == id { found = e.span }
    }
  }
  found
}

/// The test blocks of the project that call one of `fids`.
fn callers(tp: typed.TypedProgram, mods: [int], fids: {int: bool}): [TestRef] {
  var out: [TestRef] = []
  for m in mods {
    let module = tp.program.mods[m]
    let tables = tp.tables[m]
    for item in module.ast.items {
      let Test(t) = item else continue
      var all: [ast.Expr] = []
      visit.visit_item_exprs(item, &all)
      var hit = false
      for e in all {
        match tables.calls.get(e.id) {
          some(c) => match c.callee {
            Fn(func, _) => if fids.contains(func) { hit = true }
            _ => {}
          }
          none => {}
        }
        match tables.names.get(e.id) {
          some(Fn(func, _)) => if fids.contains(func) { hit = true }
          _ => {}
        }
      }
      if hit {
        out.push(TestRef { name: t.name, file: module.file, line: t.span.line, source: text(module.src, t.span) })
      }
    }
  }
  out
}

/// The char offset of a 1-based (line, char column) position in `cs` (Rust's `offset`, in
/// chars instead of bytes: a column past the line's end runs on into the next lines).
pub fn offset(cs: [char], line: int, col: int): int {
  var start = 0
  for _ in 1..line {
    var i = start
    while i < cs.len() && cs[i] != '\n' { i += 1 }
    if i >= cs.len() { return cs.len() }
    start = i + 1
  }
  min(start + max(col - 1, 0), cs.len())
}

/// The source text of a span.
pub fn text(src: str, s: diag.Span): str {
  let cs = src.chars()
  let a = offset(cs, s.line, s.col)
  let b = offset(cs, s.end_line, s.end_col)
  if a <= b { str(cs[a..b]) } else { "" }
}

/// A clause's signature as written: from `fn` (or `pub`/`async`) up to its contracts or body.
fn signature(src: str, c: ast.FnClause): str {
  let cs = src.chars()
  let start = offset(cs, c.span.line, c.span.col)
  var end = offset(cs, c.span.end_line, c.span.end_col)
  var cuts = (c.pre + c.post).map(e => e.span)
  match c.body {
    some(Expr(e)) => cuts.push(e.span)
    some(Block(b)) => cuts.push(b.span)
    _ => {}
  }
  for s in cuts { end = min(end, offset(cs, s.line, s.col)) }
  var sig = str(cs[start..max(end, start)]).trim_end()
  for kw in ["requires", "ensures", "="] {
    match sig.strip_suffix(kw) {
      some(s) => sig = s.trim_end()
      none => {}
    }
  }
  // a contract keyword ahead of the first contract we cut at
  loop {
    let t = sig.trim_end()
    let cut: str? = match t.strip_suffix("requires") {
      some(s) => s
      none => t.strip_suffix("ensures")
    }
    match cut {
      some(s) => sig = s.trim_end()
      none => break
    }
  }
  sig
}

/// Finds the locals in scope at the target hole by walking the body the way the checker scopes
/// it (`tables.binds` gives each binding's local).
struct Walk { t: typed.Tables, target: int, scope: [int], body: diag.Span? }

fn truncate(w: var Walk, n: int) {
  if w.scope.len() > n { w.scope = w.scope.take(n) }
}

fn clause(w: var Walk, c: ast.FnClause): bool {
  for p in c.params {
    match w.t.binds.get(p.id) {
      some(l) => w.scope.push(l)
      none => w.pat(p.pat)
    }
  }
  var es = c.pre
  match c.guard {
    some(g) => es.push(g)
    none => {}
  }
  for e in es + c.post {
    if w.expr(e) { return true }
  }
  match c.body {
    some(Expr(e)) => w.expr(e)
    some(Block(b)) => w.block(b)
    _ => false
  }
}

fn pat(w: var Walk, p: ast.Pat) {
  match w.t.binds.get(p.id) {
    some(l) => w.scope.push(l)
    none => {}
  }
  match p.kind {
    Tuple(ps) => for q in ps { w.pat(q) }
    List(head, rest, tail) => {
      for q in head { w.pat(q) }
      match rest {
        some(r) => match r.pat {
          some(q) => w.pat(q)
          none => {}
        }
        none => {}
      }
      for q in tail { w.pat(q) }
    }
    Variant(_, some(ps)) => for q in ps { w.pat(q) }
    Struct(_, fields, _) => {
      match w.t.struct_pats.get(p.id) {
        some(sp) => for f in sp.fields {
          match f.1 {
            some(l) => w.scope.push(l)
            none => {}
          }
        }
        none => {}
      }
      for f in fields {
        match f.pat {
          some(q) => w.pat(q)
          none => {}
        }
      }
    }
    Map(kvs) => for kv in kvs { w.pat(kv.1) }
    StrPrefix(_, rest) => w.pat(rest)
    Some(q) | Ok(q) | Err(q) => w.pat(q)
    // every alternative binds the same locals
    Or(ps) => w.pat(ps[0])
    _ => {}
  }
}

/// Walk a block in a new scope; true (with the scope left as it is) when the target is found.
fn block(w: var Walk, b: ast.Block): bool {
  let n = w.scope.len()
  if b.stmts.len() == 1 && b.stmts[0].id == w.target {
    w.body = b.span
    return true
  }
  for s in b.stmts {
    match s.kind {
      Let(_, p, _, value, els) => {
        if w.expr(value) || w.else_arm(s.id, els) { return true }
        w.pat(p)
      }
      _ => if w.expr(s) { return true }
    }
  }
  w.truncate(n)
  false
}

fn else_arm(w: var Walk, node: int, arm: ast.ElseArm?): bool {
  let a = arm else return false
  let n = w.scope.len()
  match w.t.elses.get(node) {
    some(info) => match info.binder {
      some(b) => w.scope.push(b)
      none => {}
    }
    none => {}
  }
  if w.expr(a.body) { return true }
  w.truncate(n)
  false
}

fn expr(w: var Walk, e: ast.Expr): bool {
  if e.id == w.target { return true }
  let n = w.scope.len()
  let found = match e.kind {
    Block(b) | Loop(b) => w.block(b)
    While(cond, body) => w.expr(cond) || w.block(body)
    If(cond, then, els) => if w.expr(cond) || w.block(then) {
      true
    } else {
      match els {
        some(x) => w.expr(x)
        none => false
      }
    }
    For(index, p, iter, body) => if w.expr(iter) {
      true
    } else {
      match index {
        some(i) => w.pat(i)
        none => {}
      }
      w.pat(p)
      w.block(body)
    }
    Match(scrut, arms) => if w.expr(scrut) {
      true
    } else {
      var f = false
      for a in arms {
        let k = w.scope.len()
        w.pat(a.pat)
        f = match a.guard {
          some(g) => w.expr(g)
          none => false
        }
        if !f { f = w.expr(a.body) }
        if f { break }
        w.truncate(k)
      }
      f
    }
    Closure(params, body) => {
      for p in params {
        match w.t.binds.get(p.id) {
          some(l) => w.scope.push(l)
          none => w.pat(p.pat)
        }
      }
      w.expr(body)
    }
    Else(x, arm) => w.expr(x) || w.else_arm(e.id, some(arm))
    Let(_, _, _, value, els) => w.expr(value) || w.else_arm(e.id, els)
    _ => {
      var f = false
      for k in kids(e) {
        if w.expr(k) {
          f = true
          break
        }
      }
      f
    }
  }
  if !found { w.truncate(n) }
  found
}

/// The direct sub-expressions of the forms that don't bind names (`expr` handles the others).
fn kids(e: ast.Expr): [ast.Expr] = patterns.children(e)

// ---- output ----

/// The human-readable brief of one hole (also the brief in `auk hatch`'s prompt).
pub fn brief_text(h: Hole): str {
  var s: [str] = ["hole {h.index} at {h.file}:{h.span.line}:{h.span.col} in {h.context}\n"]
  s.push("  expected type: {h.expected}\n")
  if h.body is some(_) {
    s.push("  the hole is a whole block body: `{{ ?? }}` (replace it with the block's statements)\n")
  }
  match h.function {
    some(f) => {
      s.push("  function:\n")
      match f.doc {
        some(d) => for l in check.lines(d) { s.push("    /// {l}\n") }
        none => {}
      }
      for l in check.lines(f.signature) { s.push("    {l}\n") }
      for r in f.pre { s.push("      requires {r}\n") }
      for r in f.post { s.push("      ensures {r}\n") }
    }
    none => {}
  }
  if h.scope.len() == 0 {
    s.push("  in scope: (nothing)\n")
  } else {
    s.push("  in scope:\n")
    for v in h.scope { s.push("    {if v.mutable { "var " } else { "" }}{v.name}: {v.ty}\n") }
  }
  if h.function is some(_) {
    if h.tests.len() == 0 {
      s.push("  tests that call it: (none)\n")
    } else {
      s.push("  tests that call it:\n")
      for t in h.tests {
        for l in check.lines(t.source) { s.push("    {l}\n") }
      }
    }
  }
  if h.module_fns.len() > 0 {
    s.push("  other functions in this module:\n")
    for f in h.module_fns { s.push("    {check.lines(f.1).get(0) else ""}\n") }
  }
  if h.module_types.len() > 0 {
    s.push("  types in this module:\n")
    for t in h.module_types {
      for l in check.lines(t.1) { s.push("    {l}\n") }
    }
  }
  s.join("")
}

/// A JSON string (json.rs's `write_str`: `\r` by name too).
fn jstr(s: str): str {
  var out: [str] = ["\""]
  for c in s.chars() {
    match c {
      '"' => out.push("\\\"")
      '\\' => out.push("\\\\")
      '\n' => out.push("\\n")
      '\r' => out.push("\\r")
      '\t' => out.push("\\t")
      _ => if int(c) < 0x20 { out.push("\\u{int(c):04x}") } else { out.push(str(c)) }
    }
  }
  out.push("\"")
  out.join("")
}

fn jstrs(xs: [str]): str = "[" + xs.map(jstr).join(",") + "]"

fn jbool(b: bool): str = if b { "true" } else { "false" }

pub fn hole_json(h: Hole): str {
  let function = match h.function {
    none => "null"
    some(f) => {
      let doc = match f.doc {
        some(d) => jstr(d)
        none => "null"
      }
      "{{\"name\":{jstr(f.name)},\"signature\":{jstr(f.signature)},\"doc\":{doc},\"requires\":{jstrs(f.pre)},\"ensures\":{jstrs(f.post)}}}"
    }
  }
  let scope = h.scope.map(v => "{{\"name\":{jstr(v.name)},\"type\":{jstr(v.ty)},\"mutable\":{jbool(v.mutable)}}}").join(",")
  let tests = h.tests.map(t => "{{\"name\":{jstr(t.name)},\"file\":{jstr(t.file)},\"line\":{t.line},\"source\":{jstr(t.source)}}}").join(",")
  let fns = h.module_fns.map(f => "{{\"name\":{jstr(f.0)},\"signature\":{jstr(f.1)}}}").join(",")
  let tys = h.module_types.map(t => "{{\"name\":{jstr(t.0)},\"source\":{jstr(t.1)}}}").join(",")
  "{{\"index\":{h.index},\"file\":{jstr(h.file)},\"line\":{h.span.line},\"col\":{h.span.col},\"end_line\":{h.span.end_line},\"end_col\":{h.span.end_col},\"expected\":{jstr(h.expected)},\"context\":{jstr(h.context)},\"body\":{jbool(h.body is some(_))},\"function\":{function},\"scope\":[{scope}],\"tests\":[{tests}],\"module_fns\":[{fns}],\"module_types\":[{tys}]}}"
}

/// `auk holes <file> [--json]`. Returns the exit code.
pub fn run(cx: resolve.Sources, path: str, json: bool): int uses fs, ffi {
  let (hs, diags) = match analyze(cx, path) {
    ok(r) => r
    err(Many(ds)) => {
      cli.print_diags(cx, ds)
      return 1
    }
  }
  let ok = diags.all(d => d.diag.is_warning())
  if !ok { cli.print_diags(cx, diags) }
  if json {
    print("{{\"file\":{jstr(path)},\"ok\":{jbool(ok)},\"holes\":[{hs.map(hole_json).join(",")}]}}")
  } else if hs.len() == 0 {
    print("no holes in {path}")
  } else {
    let all = hs.map(brief_text).join("\n")
    print(all.strip_suffix("\n") else all)
  }
  if ok { 0 } else { 1 }
}

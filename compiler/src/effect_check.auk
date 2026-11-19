/// Effects checking (src/effects.rs, named `effect_check` because locals are named `effects`; spec "Effects", raft.md "Effects at the package boundary").
///
/// A function's effects are its declared `uses` (prelude externs declare theirs). Every call's
/// callee effects must be among the caller's declared effects: a direct call (or a function
/// used as a value) needs the callee's `uses`; a call through `any Shape` needs the shape
/// method's declared `uses`, and converting a value to `any Shape` requires each of its methods
/// to stay within those (E0415); a closure's calls belong to the function that defines it; a
/// generic function is checked by its instances, whose extra needs (shape methods resolved for a
/// concrete type) are *hidden* effects required wherever that instance is called.
///
/// Also: declared but unused effects (E0411, a warning), impure `let`/`imprint` initializers
/// (E0412), the package ceiling `[package] effects` (E0413) and unknown effect names (E0414).
///
/// Differences from Rust: Rust's `BTreeSet<String>` is a sorted list without duplicates (the
/// `set_*` helpers); `uses` is `effects` (a keyword can't be a field name).

/// The effects a function may declare.
pub let EFFECTS = ["fs", "net", "time", "rand", "env", "proc", "audio_out", "gui", "ffi"]

/// An effect name: one of `EFFECTS`, or `raw` (docs/lowlevel.md: the runtime's dialect, which
/// only the runtime package may use, so it isn't listed in messages).
pub fn is_effect(n: str): bool = EFFECTS.contains(n) || n == "raw"

/// One expression node of a body, in source order.
struct Node {
  id: int,
  span: diag.Span,
  /// The span of the innermost closure containing it.
  closure: diag.Span?,
}

/// Why a node needs an effect: the callee as displayed, and the instance it continues into.
struct Via {
  callee: str,
  next: int?,
  /// The callee declares the effect itself (the chain ends here).
  declared: bool,
}

/// A shape method's declared `uses`, and its signature in the AST (for fix-its).
struct ShapeUses { effs: [str], clause: ast.FnClause? }

/// A missing effect of a function: the effect, where it is needed, and why.
struct Missing { eff: str, span: diag.Span, closure: diag.Span?, via: Via }

struct Cx {
  tp: typed.TypedProgram,
  out: [diag.FileDiag],
  shape_uses: {(int, int): ShapeUses},
  insts: {typed.BodyRef: [int]},
  /// Effects an instance of a generic function needs beyond what the function declares.
  hidden: [[str]],
  /// Every effect an instance's body needs through instance-resolved calls.
  inst_needs: [[str]],
  /// Per body: its expression nodes (computed lazily).
  nodes: {typed.BodyRef: [Node]},
}

// ---- sets (Rust's BTreeSet<String>) ----

fn set_of(xs: [str]): [str] {
  var out: [str] = []
  for x in xs.sort() {
    if out.len() == 0 || out[out.len() - 1] != x { out.push(x) }
  }
  out
}

fn set_union(a: [str], b: [str]): [str] = if b.len() == 0 { a } else { set_of(a + b) }

fn set_subset(a: [str], b: [str]): bool = a.all(x => b.contains(x))

/// Check the effects of every function, constant and conversion to `any Shape` outside core.
/// Returns errors and warnings (E0411).
pub fn check(tp: typed.TypedProgram): [diag.FileDiag] {
  var cx = new_cx(tp)
  cx.run()
  cx.out
}

fn new_cx(tp: typed.TypedProgram): Cx {
  var shape_uses: {(int, int): ShapeUses} = {}
  for s, sd in tp.defs.shapes {
    var found: ast.ShapeDef? = none
    for it in tp.program.mods[sd.module].ast.items {
      match it {
        Shape(d) => if d.name.name == sd.name {
          found = d
          break
        }
        _ => {}
      }
    }
    for k in 0..sd.methods.len() {
      let clause: ast.FnClause? = match found {
        some(d) => d.methods.get(k)
        none => none
      }
      let effs = match clause {
        some(c) => c.effects.map(u => u.name)
        none => []
      }
      shape_uses[(s, k)] = ShapeUses { effs, clause }
    }
  }
  var insts: {typed.BodyRef: [int]} = {}
  for i, inst in tp.instances {
    var l = insts.get(inst.body) else []
    l.push(i)
    insts[inst.body] = l
  }
  let n = tp.instances.len()
  var hidden: [[str]] = []
  for _ in 0..n { hidden.push([]) }
  Cx { tp, out: [], shape_uses, insts, hidden, inst_needs: hidden, nodes: {} }
}

fn fn_uses(cx: Cx, f: int): [str] = set_of(cx.tp.fns[f].effects)

fn module_of(cx: Cx, b: typed.BodyRef): int = match b {
  Fn(f) => cx.tp.fns[f].module
  Test(t) => cx.tp.tests[t].module
  Const(c) => cx.tp.consts[c].module
}

fn is_generic(cx: Cx, b: typed.BodyRef): bool = match b {
  Fn(f) => cx.tp.fns[f].generics.len() > 0
  _ => false
}

fn emit(cx: var Cx, m: int, d: diag.Diag) {
  let file = cx.tp.program.mods[m].file
  cx.out.push(diag.FileDiag { file, diag: d })
}

// ---- names for messages ----

/// A function as written from module `from`: `area`, `fs.read`, `geo.area`.
fn fn_name(cx: Cx, f: int, from: int): str {
  let info = cx.tp.fns[f]
  if info.module == from { return info.name }
  let full = cx.tp.program.mods[info.module].path
  let path = if cx.tp.program.is_core(info.module) { full.skip(1) } else { full }
  if path.len() == 0 { info.name } else { "{path.join(".")}.{info.name}" }
}

fn inst_name(cx: Cx, i: int, from: int): str {
  let inst = cx.tp.instances[i]
  match inst.body {
    Fn(f) => {
      let n = cx.fn_name(f, from)
      if inst.type_args.len() == 0 { n } else { "{n}<{inst.type_args.map(t => cx.tp.defs.show(t)).join(", ")}>" }
    }
    Test(t) => "test {check_expr.debug_str(cx.tp.tests[t].name)}"
    Const(c) => cx.tp.consts[c].name
  }
}

fn shape_method_name(cx: Cx, s: int, k: int): str {
  let sd = cx.tp.defs.shapes[s]
  let mn = match sd.methods.get(k) {
    some(m) => m.name
    none => "?"
  }
  "{sd.name}.{mn}"
}

// ---- bodies ----

/// The expression roots of a body.
fn roots(cx: Cx, b: typed.BodyRef): [ast.Expr] {
  let tp = cx.tp
  var out: [ast.Expr] = []
  match b {
    Fn(f) => {
      let info = tp.fns[f]
      let Auk(item, clauses, header) = info.kind else return out
      let Fn(g) = tp.program.mods[info.module].ast.items[item] else return out
      var cls: [ast.FnClause] = []
      if header {
        match g.header {
          some(h) => cls.push(h)
          none => {}
        }
      }
      for i in clauses { cls.push(g.clauses[i]) }
      for c in cls {
        match c.guard {
          some(e) => out.push(e)
          none => {}
        }
        out = out + c.pre + c.post
        match c.body {
          some(Expr(e)) => out.push(e)
          some(Block(bl)) => out = out + bl.stmts
          _ => {}
        }
      }
    }
    Test(t) => match tp.program.mods[tp.tests[t].module].ast.items[tp.tests[t].item] {
      Test(d) => out = out + d.body.stmts
      _ => {}
    }
    Const(c) => match tp.program.mods[tp.consts[c].module].ast.items[tp.consts[c].item] {
      Let(d) | Imprint(d) => out.push(d.value)
      _ => {}
    }
  }
  out
}

fn body_nodes(cx: var Cx, b: typed.BodyRef): [Node] {
  match cx.nodes.get(b) {
    some(ns) => return ns
    none => {}
  }
  var nodes: [Node] = []
  for r in cx.roots(b) { collect(r, none, &nodes) }
  cx.nodes[b] = nodes
  nodes
}

/// Effects node `n` of a body in module `m` needs by itself (generic view): a direct call's
/// callee `uses`, a function value's `uses`, or a shape method's declared `uses` through
/// `any Shape`.
fn direct(cx: Cx, m: int, n: int): ([str], Via)? {
  let t = cx.tp.tables[m]
  match t.calls.get(n) {
    some(c) => return match c.callee {
      Fn(func, _) => (cx.fn_uses(func), Via { callee: cx.fn_name(func, m), next: none, declared: true })
      Vtable(shape, method) => {
        let effs = match cx.shape_uses.get((shape, method)) {
          some(u) => set_of(u.effs)
          none => []
        }
        let callee = "{cx.shape_method_name(shape, method)} (through `any {cx.tp.defs.shapes[shape].name}`)"
        (effs, Via { callee, next: none, declared: true })
      }
      _ => none
    }
    none => {}
  }
  match t.names.get(n) {
    some(Fn(func, _)) => return (cx.fn_uses(func), Via { callee: cx.fn_name(func, m), next: none, declared: true })
    // the runtime's dialect: C data
    some(Global(g)) when cx.tp.globals[g].kind == 4 =>
      return (["raw"], Via { callee: "the `extern var` {cx.tp.globals[g].name}", next: none, declared: true })
    _ => {}
  }
  // the runtime's dialect: memory through a pointer
  if t.raw.get(n) == some(typed.RawNode.Deref) {
    return (["raw"], Via { callee: "a field through a `raw.Ptr`", next: none, declared: true })
  }
  none
}

/// Instance `j` as a target needing its hidden effects (and its own `uses` when `own`).
fn target(cx: Cx, j: int, m: int, own: bool, out: var [([str], Via)]) {
  let Fn(g) = cx.tp.instances[j].body else return
  var s = cx.hidden[j]
  if own { s = set_union(s, cx.fn_uses(g)) }
  if s.len() > 0 { out.push((s, Via { callee: cx.inst_name(j, m), next: j, declared: false })) }
}

/// Effects node `n` needs in instance `i` through concrete targets: a shape method resolved
/// for a concrete type, the hidden effects of a generic callee instance, and `Show`
/// implementations of interpolated values.
fn resolved(cx: Cx, i: int, m: int, n: int): [([str], Via)] {
  let inst = cx.tp.instances[i]
  let t = cx.tp.tables[m]
  var out: [([str], Via)] = []
  match inst.resolved.get(n) {
    some(Instance(j)) => match t.calls.get(n) {
      some(c) => match c.callee {
        Fn(_, _) => cx.target(j, m, false, &out)
        Shape(_, _, _) => cx.target(j, m, true, &out)
        _ => {}
      }
      none => match t.names.get(n) {
        some(Fn(_, _)) => cx.target(j, m, false, &out)
        _ => {}
      }
    }
    _ => {}
  }
  match inst.shows.get(n) {
    some(Instance(j)) => cx.target(j, m, true, &out)
    _ => {}
  }
  out
}

/// Everything node `n` of body `b` needs (in instance `i`, if any), with the reason.
fn needs(cx: Cx, b: typed.BodyRef, i: int?, n: int): [([str], Via)] {
  let m = cx.module_of(b)
  var out: [([str], Via)] = []
  match cx.direct(m, n) {
    some(x) => out.push(x)
    none => {}
  }
  match i {
    some(i) => out = out + cx.resolved(i, m, n)
    none => {}
  }
  out
}

// ---- the analysis ----

fn run(cx: var Cx) {
  cx.hidden_effects()
  cx.names_and_ceiling()
  var bodies: [typed.BodyRef] = []
  for f in 0..cx.tp.fns.len() { bodies.push(typed.BodyRef.Fn(f)) }
  for c in 0..cx.tp.consts.len() { bodies.push(typed.BodyRef.Const(c)) }
  for t in 0..cx.tp.tests.len() { bodies.push(typed.BodyRef.Test(t)) }
  for b in bodies {
    let m = cx.module_of(b)
    if cx.tp.program.is_core(m) { continue }
    match b {
      Fn(f) => if cx.tp.fns[f].kind is typed.FnKind.Auk(_, _, _) { cx.check_fn(f) }
      Const(c) => cx.check_const(c)
      _ => {}
    }
    cx.check_vtables(b)
  }
}

/// The fixed point of `hidden` over the instances of generic functions.
fn hidden_effects(cx: var Cx) {
  var generic: [int] = []
  for i, inst in cx.tp.instances {
    if cx.is_generic(inst.body) { generic.push(i) }
  }
  var keys: [[int]] = []
  for i in generic {
    let inst = cx.tp.instances[i]
    var ks: [int] = []
    for k in inst.resolved.keys().sort() {
      if ks.len() == 0 || ks[ks.len() - 1] != k { ks.push(k) }
    }
    for k in inst.shows.keys() {
      if !inst.resolved.contains(k) { ks.push(k) }
    }
    var sorted: [int] = []
    for k in ks.sort() {
      if sorted.len() == 0 || sorted[sorted.len() - 1] != k { sorted.push(k) }
    }
    keys.push(sorted)
  }
  loop {
    var changed = false
    for gi, i in generic {
      let b = cx.tp.instances[i].body
      let m = cx.module_of(b)
      let Fn(f) = b else continue
      var all: [str] = []
      for n in keys[gi] {
        for (s, _) in cx.resolved(i, m, n) { all = all + s }
      }
      all = set_of(all)
      let declared = cx.fn_uses(f)
      let h = all.filter(e => !declared.contains(e))
      if h != cx.hidden[i] || all != cx.inst_needs[i] {
        if !set_subset(h, cx.hidden[i]) || !set_subset(all, cx.inst_needs[i]) { changed = true }
        let nh = set_union(cx.hidden[i], h)
        cx.hidden[i] = nh
        let na = set_union(cx.inst_needs[i], all)
        cx.inst_needs[i] = na
      }
    }
    if !changed { break }
  }
}

/// Unknown effect names (E0414) and the package ceiling (E0413).
fn names_and_ceiling(cx: var Cx) {
  let tp = cx.tp
  for info in tp.fns {
    let m = info.module
    if tp.program.is_core(m) { continue }
    let first = cx.first_clause(info) else continue
    for u in first.effects { cx.check_name(m, u) }
    let pkg = tp.program.pkgs[tp.program.mods[m].pkg]
    let runtime = resolve.is_runtime(tp.program, m)
    for u in first.effects {
      if u.name == "raw" && !runtime { cx.emit(m, raw_only(u.span, "`{info.name}` uses `raw`")) }
    }
    let dir = pkg.dir else continue
    for u in first.effects {
      if !is_effect(u.name) || pkg.effects.contains(u.name) || (u.name == "raw" && !runtime) { continue }
      let allowed = if pkg.effects.len() == 0 {
        "allows no effects"
      } else {
        "allows only {pkg.effects.map(e => "`{e}`").join(", ")}"
      }
      let toml = paths.join(dir, "raft.toml")
      cx.emit(
        m,
        diag.new("E0413", u.span, "`{info.name}` uses `{u.name}`, but the package `{pkg.name}` {allowed}")
          .note("a package's raft.toml `[package] effects` is the most its code may use")
          .note("help: add \"{u.name}\" to `effects` under [package] in {toml}"),
      )
    }
  }
  for s, sd in tp.defs.shapes {
    if tp.program.is_core(sd.module) { continue }
    for k in 0..sd.methods.len() {
      match cx.shape_uses.get((s, k)) {
        some(su) => match su.clause {
          some(c) => for u in c.effects { cx.check_name(sd.module, u) }
          none => {}
        }
        none => {}
      }
    }
  }
}

/// E0418: something of the `raw` dialect outside the runtime package.
pub fn raw_only(span: diag.Span, what: str): diag.Diag =
  diag.new("E0418", span, "{what}, but `raw` is only for the runtime")
    .note("the low-level dialect (docs/lowlevel.md) is only for the package `auk_rt` (runtime/raft.toml); ordinary code calls C with `extern fn` and the `ffi` effect")

fn check_name(cx: var Cx, m: int, u: ast.Ident) {
  if is_effect(u.name) { return }
  var d = diag.new("E0414", u.span, "unknown effect `{u.name}`").note("the effects are {EFFECTS.join(", ")}")
  match check.similar(u.name, EFFECTS) {
    some(s) => d = d.fix(u.span, s)
    none => {}
  }
  cx.emit(m, d)
}

/// The clause that carries a function's `uses` (its header line, or its first clause).
fn first_clause(cx: Cx, info: typed.FnInfo): ast.FnClause? {
  let Auk(item, clauses, header) = info.kind else return none
  let Fn(g) = cx.tp.program.mods[info.module].ast.items[item] else return none
  if header { return g.header }
  if clauses.len() == 0 { return none }
  g.clauses[clauses[0]]
}

fn check_fn(cx: var Cx, f: int) {
  let b = typed.BodyRef.Fn(f)
  let m = cx.module_of(b)
  let generic = cx.is_generic(b)
  let insts = cx.insts.get(b) else []
  // a non-generic body has one instance (every concrete target resolved); a generic body is
  // checked in its generic view here, and its instances' extra needs are hidden effects
  let inst: int? = if generic { none } else { insts.get(0) }
  let declared = cx.fn_uses(f)
  let nodes = cx.body_nodes(b)
  var used: [str] = []
  var missing: [Missing] = []
  for nd in nodes {
    for (s, via) in cx.needs(b, inst, nd.id) {
      for e in s {
        if !declared.contains(e) && !missing.any(x => x.eff == e) {
          missing.push(Missing { eff: e, span: nd.span, closure: nd.closure, via })
        }
        used.push(e)
      }
    }
  }
  for i in insts { used = used + cx.inst_needs[i] }
  used = set_of(used)
  let name = cx.tp.fns[f].name
  // declared but unused (generic functions only when instantiated, since shape methods resolved
  // per instance may use them)
  let first = cx.first_clause(cx.tp.fns[f])
  var unused: [ast.Ident] = []
  match first {
    some(c) => if !(generic && insts.len() == 0) {
      for u in c.effects {
        let gated = u.name == "raw" && !resolve.is_runtime(cx.tp.program, cx.tp.fns[f].module)
        if is_effect(u.name) && !used.contains(u.name) && !gated { unused.push(u) }
      }
    }
    none => {}
  }
  var kept: [str] = []
  match first {
    some(c) => for u in c.effects {
      if !unused.any(x => x.name == u.name) { kept.push(u.name) }
    }
    none => {}
  }
  if missing.len() > 0 {
    let effs = missing.map(x => x.eff)
    let list = effs.map(e => "`{e}`").join(", ")
    let msg = if effs.len() == 1 {
      "`{name}` uses the effect {list} but doesn't declare it"
    } else {
      "`{name}` uses the effects {list} but doesn't declare them"
    }
    var d = diag.new("E0410", missing[0].span, msg)
    for x in missing {
      d = d.note("call chain: {cx.chain(name, x.via, x.eff)}")
      match x.closure {
        some(c) => d = d.note("the closure at {diag.show_at(c)} is part of `{name}`, so its effects are `{name}`'s")
        none => {}
      }
    }
    // With unused effects too (E0411 below), both fixes would edit the same `uses` list, so
    // this one rewrites the whole clause to the right set: the kept effects in the user's order,
    // then the missing ones.
    let fix: (diag.Span, str)? = if unused.len() == 0 {
      cx.add_effects_fix(f, effs)
    } else {
      match first {
        some(c) => cx.rewrite_uses(m, c, kept + effs)
        none => none
      }
    }
    match fix {
      some((at, text)) => d = d.fix(at, text)
      none => {}
    }
    cx.emit(m, d)
  }
  if unused.len() == 0 { return }
  let list = unused.map(u => "`{u.name}`").join(", ")
  let msg = if unused.len() == 1 {
    "`{name}` declares the effect {list} but doesn't use it"
  } else {
    "`{name}` declares the effects {list} but doesn't use them"
  }
  var d = diag.new("E0411", unused[0].span, msg).note("declare only the effects a function needs, so callers and raft.toml stay accurate")
  // the E0410 above carries the one combined fix
  if missing.len() == 0 {
    match first {
      some(c) => match cx.rewrite_uses(m, c, kept) {
        some((at, text)) => d = d.fix(at, text)
        none => {}
      }
      none => {}
    }
  }
  cx.emit(m, d)
}

/// `main → total<Sq> → area (uses fs)`.
fn chain(cx: Cx, from: str, via0: Via, e: str): str {
  var parts = ["`{from}`"]
  var via = via0
  var seen: {int: bool} = {}
  loop {
    let j = via.next else {
      parts.push("`{via.callee}` (uses {e})")
      break
    }
    if via.declared {
      parts.push("`{via.callee}` (uses {e})")
      break
    }
    match cx.tp.instances[j].body {
      Fn(g) => if cx.tp.fns[g].effects.contains(e) {
        parts.push("`{via.callee}` (uses {e})")
        break
      }
      _ => {}
    }
    parts.push("`{via.callee}`")
    if seen.contains(j) || parts.len() > 8 { break }
    seen[j] = true
    // find what in instance j needs `e`
    let jb = cx.tp.instances[j].body
    let inst = cx.tp.instances[j]
    let ks = (inst.resolved.keys() + inst.shows.keys()).sort()
    var next: Via? = none
    for n in ks {
      for (s, v) in cx.needs(jb, j, n) {
        if s.contains(e) {
          next = v
          break
        }
      }
      if next is some(_) { break }
    }
    via = next else break
  }
  parts.join(" → ")
}

/// Where `uses` goes in a clause: just after the return type, or after the `)` of the
/// parameter list.
fn uses_anchor(cx: Cx, m: int, c: ast.FnClause): diag.Span? {
  match c.ret {
    some(r) => return diag.after(r.span)
    none => {}
  }
  params_close(cx.tp.program.mods[m].src, c.name.span)
}

/// The fix-it rewriting a clause's whole `uses` list to `keep` (none: drop the clause).
fn rewrite_uses(cx: Cx, m: int, c: ast.FnClause, keep: [str]): (diag.Span, str)? {
  let anchor = cx.uses_anchor(m, c)?
  if c.effects.len() == 0 { return none }
  let end = c.effects[c.effects.len() - 1].span
  let text = if keep.len() == 0 { "" } else { " uses {keep.join(", ")}" }
  (diag.Span { line: anchor.line, col: anchor.col, end_line: end.end_line, end_col: end.end_col }, text)
}

/// The fix-it adding `effs` to a function's `uses`.
fn add_effects_fix(cx: Cx, f: int, effs: [str]): (diag.Span, str)? {
  let c = cx.first_clause(cx.tp.fns[f])?
  cx.add_to_clause(cx.tp.fns[f].module, c, effs)
}

fn add_to_clause(cx: Cx, m: int, c: ast.FnClause, effs: [str]): (diag.Span, str)? {
  if c.effects.len() > 0 {
    let u = c.effects[c.effects.len() - 1]
    return (diag.after(u.span), effs.map(e => ", {e}").join(""))
  }
  (cx.uses_anchor(m, c)?, " uses {effs.join(", ")}")
}

fn check_const(cx: var Cx, c: int) {
  let b = typed.BodyRef.Const(c)
  let m = cx.module_of(b)
  let inst: int? = match cx.insts.get(b) {
    some(v) => v.get(0)
    none => none
  }
  for nd in cx.body_nodes(b) {
    for (s, via) in cx.needs(b, inst, nd.id) {
      if s.len() == 0 { continue }
      let e = s[0]
      let info = cx.tp.consts[c]
      let what = if info.imprint {
        "`imprint {info.name}` is computed at compile time and must be pure"
      } else {
        "the module constant `{info.name}` must be pure"
      }
      let d = diag.new("E0412", nd.span, "{what}, but its initializer uses the effect `{e}`")
        .note("call chain: {cx.chain(info.name, via, e)}")
        .note("compute it in a function that declares the effect (`main`, for example) and pass it where it is needed")
      cx.emit(m, d)
      return
    }
  }
}

/// Conversions to `any Shape` in a body: every method of the converted type must stay within
/// the shape method's declared effects (E0415).
fn check_vtables(cx: var Cx, b: typed.BodyRef) {
  let m = cx.module_of(b)
  let insts = cx.insts.get(b) else []
  if insts.len() == 0 { return }
  var spans: {int: diag.Span} = {}
  for nd in cx.body_nodes(b) { spans[nd.id] = nd.span }
  var done: {(int, int): bool} = {}
  for i in insts {
    var vts: [(int, int)] = []
    for n, v in cx.tp.instances[i].vtables { vts.push((n, v)) }
    for (n, v) in vts.sort() {
      let vt = cx.tp.vtables[v]
      for k, t in vt.methods {
        let Instance(j) = t else continue
        let Fn(g) = cx.tp.instances[j].body else continue
        let needs = set_union(cx.fn_uses(g), cx.hidden[j])
        let su = cx.shape_uses.get((vt.shape, k)) else ShapeUses { effs: [], clause: none }
        let extra = needs.filter(e => !su.effs.contains(e))
        if extra.len() == 0 || done.contains((n, k)) { continue }
        done[(n, k)] = true
        let span = spans.get(n) else continue
        let ts = cx.tp.defs.show(vt.ty)
        let sm = cx.shape_method_name(vt.shape, k)
        let list = extra.map(e => "`{e}`").join(", ")
        let shape = cx.tp.defs.shapes[vt.shape]
        var d = diag.new("E0415", span, "converting `{ts}` to `any {shape.name}` would let `{sm}` use {list}, which the shape doesn't declare")
          .note("`{cx.fn_name(g, m)}` for `{ts}` (at {diag.show_at(cx.tp.fns[g].span)}) uses {list}")
          .note("a call through `any Shape` may only use the effects its shape method declares")
        match su.clause {
          some(c) => if shape.module == m {
            match cx.add_to_clause(m, c, extra) {
              some((at, text)) => d = d.fix(at, text)
              none => {}
            }
          }
          none => {}
        }
        cx.emit(m, d)
      }
    }
  }
}

/// Collect the expression nodes under `e` in source order, noting the innermost closure.
fn collect(e: ast.Expr, closure: diag.Span?, out: var [Node]) {
  out.push(Node { id: e.id, span: e.span, closure })
  let inner: diag.Span? = if e.kind is ast.ExprKind.Closure(_, _) { e.span } else { closure }
  for c in patterns.children(e) { collect(c, inner, &out) }
}

/// The empty span just after the `)` closing the parameter list that follows `name`.
fn params_close(src: str, name: diag.Span): diag.Span? {
  var depth = 0
  var in_str = false
  for li, line in check.lines(src) {
    if li < name.line - 1 { continue }
    let skip = if li + 1 == name.line { name.end_col - 1 } else { 0 }
    for ci, ch in line.chars() {
      if ci < skip { continue }
      if ch == '"' {
        in_str = !in_str
      } else if in_str {
      } else if ch == '(' || ch == '[' || ch == '{' {
        depth += 1
      } else if ch == ')' || ch == ']' || ch == '}' {
        depth -= 1
        if depth == 0 && ch == ')' {
          let l = li + 1
          let c = ci + 2
          return diag.Span { line: l, col: c, end_line: l, end_col: c }
        }
      }
    }
  }
  none
}

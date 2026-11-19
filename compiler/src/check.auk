/// Types, inference, overloading and shapes: AST + module tree -> `TypedProgram` (src/check.rs).
///
/// Phases (see the Rust module docs):
/// 1. **collect** (this file): register every struct, enum, opaque type and shape per module,
///    resolve their field types, split each parsed clause group by first-parameter type into
///    functions (overloads), compute each function's signature, and register constants and tests.
/// 2. **bodies** (check_expr.auk, check_ops.auk: src/check/expr.rs; check_pat.auk:
///    src/check/pat.rs): bidirectional inference.
/// 3. **shapes and monomorphization** (check_shapes.auk: src/check/shapes.rs).
///
/// Differences from Rust: the `impl Checker` methods are functions taking `c: var Checker` and
/// are called as `c.f(..)`. A dot call finds a function in the current module, then in the
/// module that defines the receiver's type (this one), so every method implemented in one of
/// the other check_*.auk files has a one-line forwarding function here ("Methods of the other
/// files", at the end): `c.infer(e, none)` works from every file. The body stack `cxs` is the
/// current body `cx` plus the suspended ones in `outer` (`depth` counts them; Rust's
/// `cxs.last()` is `none` when `depth == 0`). Rust's `BTreeSet<FnId>` of callees is a
/// `{int: bool}` sorted when the body is done; `types_used` (a `BTreeSet<Ty>`) is a list kept
/// sorted by `types.cmp` plus a membership map.

/// What the dotted prefix of an expression path means (`expr_path`).
pub enum ExprPath {
  Module(m: int),
  /// Not a module: the first segment is a value (a local, or not a module name at all).
  Value,
  /// A local named like a module that locals don't shadow (E0116 was reported).
  Ambiguous,
}

pub enum TypeItem { Def(d: int), Shape(s: int) }

/// The items declared in one module, by name.
pub struct ItemTable {
  types: {str: TypeItem},
  fns: {str: [int]},
  consts: {str: int},
  variants: {str: [(int, int)]},
  /// The runtime's dialect: `raw var`, `raw let`, ... globals.
  globals: {str: int},
}

fn new_items(): ItemTable = ItemTable { types: {}, fns: {}, consts: {}, variants: {}, globals: {} }

/// Well-known core definitions.
pub struct Builtins { err: int, value: int, show: int, ord: int, eq: int, data: int }

/// Type parameter names in scope while resolving a type.
pub struct GenScope {
  names: {str: int},
  self_param: int?,
  /// Create an implicit type parameter for a shape name used as a type (function signatures).
  implicit: bool,
  /// Implicit parameters created so far, by shape name.
  implicit_params: [int],
  /// Splitting clause groups: a shape name stands for itself (`Any`), only as a grouping key.
  key_mode: bool,
}

/// `GenScope::default()`.
pub fn gen_scope(): GenScope =
  GenScope { names: {}, self_param: none, implicit: false, implicit_params: [], key_mode: false }

enum ConstState { Todo, Busy, Done }

/// A deferred check, done when the body's types are known: `ty` must fit `shape` (a generic
/// bound, or an operator/interpolation need).
pub enum Deferred { Fits(ty: types.Ty, shape: int, span: diag.Span, why: str) }

/// One function, closure or other body frame (for `return`, `?`, captures and loops).
pub struct Frame {
  /// What `return` / `?` / `fail` target; `none` where they are not allowed (constants).
  ret: types.Ty?,
  /// The span of the return type annotation, for fix-its.
  ret_span: diag.Span?,
  scope_base: int,
  captures: [int],
  loops: [LoopCx],
  is_closure: bool,
  /// A `catch` body: captures by reference, so it may change the variables it captures.
  by_ref: bool,
  what: str,
  /// Where to insert `: T` when the function has no return type (just after its `)`).
  ret_insert: diag.Span?,
}

/// A frame with Rust's usual field values: no captures, loops, closure or insert point.
pub fn frame(what: str, ret: types.Ty?, ret_span: diag.Span?): Frame = Frame {
  ret,
  ret_span,
  scope_base: 0,
  captures: [],
  loops: [],
  is_closure: false,
  by_ref: false,
  what,
  ret_insert: none,
}

pub struct LoopCx {
  /// `loop` (break may carry a value) vs `while`/`for`.
  is_loop: bool,
  break_ty: types.Ty,
  saw_break: bool,
}

/// The state of the body being checked.
pub struct BodyCx {
  module: int,
  body: typed.BodyRef,
  inf: types.Infer,
  t: typed.Tables,
  scopes: [{str: int}],
  frames: [Frame],
  generics: GenScope,
  deferred: [Deferred],
  /// Rust's `BTreeSet<FnId>`.
  callees: {int: bool},
  /// Inside `ensures`: the `result` local.
  result_local: int?,
  in_ensures: bool,
  olds: [int],
  /// The next call is the operand of `await`: an async call runs directly.
  direct_await: bool,
  /// > 0 while inferring expressions whose context already failed (no follow-up errors).
  quiet: int,
  local_start: int,
  /// The explicit type arguments of the call being checked (`raw.size_of<T>()`).
  explicit: [types.Ty]?,
}

pub struct Checker {
  prog: resolve.Program,
  defs: types.Defs,
  fns: [typed.FnInfo],
  consts: [typed.ConstInfo],
  tests: [typed.TestInfo],
  items: [ItemTable],
  tables: [typed.Tables],
  errs: [diag.FileDiag],
  b: Builtins,
  const_state: [ConstState],
  /// The body being checked (meaningful while `depth > 0`).
  cx: BodyCx,
  /// Suspended bodies under `cx` (a constant may be checked lazily while another body is in
  /// progress), innermost last.
  outer: [BodyCx],
  /// The number of bodies in progress (`cx` and `outer`).
  depth: int,
  /// The names `let` statements are binding while their values are checked (innermost last).
  binding: [str],
  /// While checking the second and later alternatives of an or-pattern: the locals the first
  /// one bound, by name.
  or_binds: {str: int}?,
  /// Per body: the nodes whose targets monomorphization resolves.
  body_nodes: {typed.BodyRef: BodyNodes},
  main: typed.MainInfo?,
  /// The runtime's dialect: `raw var`, `raw let`, ... globals.
  globals: [typed.GlobalInfo],
  instances: [typed.Instance],
  /// Rust's `BTreeSet<Ty>`: sorted by `types.cmp`; `types_used_set` for membership.
  types_used: [types.Ty],
  types_used_set: {types.Ty: bool},
  shape_impls: {(types.Builtin, types.Ty): typed.Target},
  /// User `from_value` functions used by `from_value` of a type.
  from_value_impls: {types.Ty: typed.Target},
  /// The types whose `from_value` was resolved.
  from_value_seen: {types.Ty: bool},
  vtables: [typed.Vtable],
  /// How to make a local mutable, for the E0320 fix-it: the `let` keyword to replace with
  /// `var`, or (for a parameter) where to insert `var `. Keyed by (module, local).
  let_fixes: {(int, int): diag.Span},
  param_fixes: {(int, int): diag.Span},
  /// Each module's source split into lines (Rust's `src.lines()`, computed once).
  src_lines: [[str]],
}

/// The call, show and `any`-conversion nodes of one body (with the module they live in).
pub struct BodyNodes {
  module: int,
  calls: [int],
  /// `Name` nodes naming a function used as a value (`NameRef.Fn`).
  fn_refs: [int],
  shows: [int],
  anys: [int],
}

pub fn new_body_nodes(): BodyNodes = BodyNodes { module: 0, calls: [], fn_refs: [], shows: [], anys: [] }

/// What the context wants from an expression (src/check/expr.rs `Exp`).
pub enum Exp {
  /// Nothing known.
  None,
  /// A type that guides inference but isn't enforced here.
  Hint(t: types.Ty),
  /// The expression must have (or convert to) this type.
  Check(t: types.Ty),
  /// Like `Check`, for a function's result.
  Tail(t: types.Ty),
  /// The value is discarded (a statement).
  Discard,
  /// Possible types for the result of a call, tried in order.
  Hints(ts: [types.Ty]),
}

/// `Exp::ty`.
pub fn exp_ty(exp: Exp): types.Ty? = match exp {
  Hint(t) | Check(t) | Tail(t) => t
  _ => none
}

/// `Exp::want`: the type and whether it is a function's result.
pub fn exp_want(exp: Exp): (types.Ty, bool)? = match exp {
  Check(t) => (t, false)
  Tail(t) => (t, true)
  _ => none
}

/// A call argument: an expression, or a receiver already inferred (dot calls, pipes).
pub enum ArgSrc { Expr(e: ast.Expr), Recv(e: ast.Expr) }

/// `ArgSrc::expr`.
pub fn arg_expr(a: ArgSrc): ast.Expr = match a {
  Expr(e) | Recv(e) => e
}

/// Why a place is being changed (for messages).
pub enum PlaceUse { Assign, Ref, Receiver(name: str) }

// ---- inference helpers (src/check/expr.rs, "inference helpers") ----

pub fn fresh(c: var Checker): types.Ty = types.fresh(&c.cx.inf)

pub fn resolve(c: Checker, t: types.Ty): types.Ty = types.resolve(c.cx.inf, t)

pub fn shallow(c: Checker, t: types.Ty): types.Ty = types.shallow(c.cx.inf, t)

pub fn unify(c: var Checker, a: types.Ty, b: types.Ty): bool = types.unify(&c.cx.inf, a, b)

pub fn try_unify(c: var Checker, a: types.Ty, b: types.Ty): bool = types.try_unify(&c.cx.inf, a, b)

/// `self.cx().inf.can_unify(a, b)`.
pub fn can_unify(c: var Checker, a: types.Ty, b: types.Ty): bool = types.can_unify(&c.cx.inf, a, b)

/// Source text of a span in the current module.
pub fn text(c: Checker, span: diag.Span): str {
  var out: [str] = []
  for i, line in c.src_lines[c.cur_module()] {
    let ln = i + 1
    if ln < span.line || ln > span.end_line { continue }
    let chars = line.chars()
    let from = if ln == span.line { max(span.col - 1, 0) } else { 0 }
    let to = if ln == span.end_line { min(max(span.end_col - 1, 0), chars.len()) } else { chars.len() }
    if from <= to { out.push(str(chars[from..to])) }
    if ln != span.end_line { out.push("\n") }
  }
  out.join("")
}

/// Rust's `str::lines`: split at `\n`, dropping one `\r` before it, and no final empty line
/// after a trailing `\n`.
pub fn lines(src: str): [str] {
  var ls = src.split("\n")
  if ls.len() > 0 && ls[ls.len() - 1] == "" { let _ = ls.pop() }
  ls.map(l => l.strip_suffix("\r") else l)
}

pub fn record(c: var Checker, node: int, t: types.Ty) {
  c.cx.t.types[node] = t
}

pub fn add_coercion(c: var Checker, node: int, co: typed.Coercion) {
  match co {
    ToAny(_) => {
      let body = c.cx.body
      let m = c.cur_module()
      var bn = c.body_nodes.get(body) else new_body_nodes()
      bn.module = m
      bn.anys.push(node)
      c.body_nodes[body] = bn
    }
    _ => {}
  }
  var cs = c.cx.t.coercions.get(node) else []
  cs.push(co)
  c.cx.t.coercions[node] = cs
}

pub fn note_call(c: var Checker, node: int, call: typed.Call) {
  match call.callee {
    Fn(f, _) => c.cx.callees[f] = true
    _ => {}
  }
  c.cx.t.calls[node] = call
  let body = c.cx.body
  let m = c.cur_module()
  var bn = c.body_nodes.get(body) else new_body_nodes()
  bn.module = m
  bn.calls.push(node)
  c.body_nodes[body] = bn
}

pub fn note_show(c: var Checker, node: int, ty: types.Ty) {
  let callee = typed.Callee.Shape(c.b.show, 0, ty)
  c.cx.t.shows[node] = callee
  let body = c.cx.body
  let m = c.cur_module()
  var bn = c.body_nodes.get(body) else new_body_nodes()
  bn.module = m
  bn.shows.push(node)
  c.body_nodes[body] = bn
}

/// Record a function-valued `Name` node for monomorphization (`bn.fn_refs` in Rust's
/// `item_value`).
pub fn note_fn_ref(c: var Checker, node: int, m: int) {
  let body = c.cx.body
  var bn = c.body_nodes.get(body) else new_body_nodes()
  bn.module = m
  bn.fn_refs.push(node)
  c.body_nodes[body] = bn
}

pub fn defer_fit(c: var Checker, ty: types.Ty, shape: int, span: diag.Span, why: str) {
  c.cx.deferred.push(Deferred.Fits(ty, shape, span, why))
}

/// The innermost frame, if a body is in progress and has one
/// (`self.cxs.last().and_then(|c| c.frames.last())`).
pub fn top_frame(c: Checker): Frame? {
  if c.depth == 0 || c.cx.frames.len() == 0 { return none }
  c.cx.frames[c.cx.frames.len() - 1]
}

/// The innermost function frame's return type (`none`: `return`/`?` not allowed here).
pub fn frame_ret(c: Checker): types.Ty? = c.top_frame()?.ret

// ---- entry points ----

/// Type-check, then check patterns and effects: the typed program (none on errors) and every
/// diagnostic, sorted, warnings (E0411) included.
pub fn check_all(prog: resolve.Program): (typed.TypedProgram?, [diag.FileDiag]) uses fs {
  let (tp, diags) = check_partial(prog)
  let ok = diags.all(d => d.diag.is_warning())
  (if ok { tp } else { none }, diags)
}

/// Like `check_all`, but on errors still returns the program as far as it type-checked, for
/// tools that want types in broken code (`auk holes`). `none` only when the declarations
/// themselves don't check. A program returned alongside an error is partial.
pub fn check_partial(prog: resolve.Program): (typed.TypedProgram?, [diag.FileDiag]) uses fs {
  let (tp0, errs) = check_types(prog)
  let tp = match tp0 {
    some(t) => if errs.len() == 0 { t } else { return (tp0, errs) }
    none => return (tp0, errs)
  }
  let diags = patterns.check(tp) + effect_check.check(tp)
  (tp, sorted(diags))
}

/// Types, inference, overloading and shapes only (Rust's private `check_types`, which
/// `check_partial` follows with patterns.rs and effects.rs): the typed program (partial when
/// there are errors; `none` when the declarations failed) and the errors.
pub fn check_types(prog: resolve.Program): (typed.TypedProgram?, [diag.FileDiag]) uses fs {
  var c = new_checker(prog)
  c.collect()
  if c.errs.len() > 0 { return (none, sorted(c.errs)) }
  c.check_bodies()
  if c.errs.len() == 0 { c.find_main() }
  if c.errs.len() > 0 {
    let errs = sorted(c.errs)
    c.errs = []
    return (c.finish(), errs)
  }
  c.monomorphize()
  let errs = c.errs
  c.errs = []
  (c.finish(), errs)
}

/// Errors in file and position order (a stable sort), without consecutive duplicates.
pub fn sorted(errs: [diag.FileDiag]): [diag.FileDiag] {
  var keys: [(str, int, int, int)] = []
  for i, d in errs { keys.push((d.file, d.diag.span.line, d.diag.span.col, i)) }
  var out: [diag.FileDiag] = []
  for k in keys.sort() {
    let d = errs[k.3]
    if out.len() > 0 && out[out.len() - 1] == d { continue }
    out.push(d)
  }
  out
}

/// "a `int`" -> "an `int`": the article before a quoted type or name that starts with a vowel.
pub fn articles(msg: str): str {
  if !msg.contains("a `") { return msg }
  let cs = msg.chars()
  var out: [char] = []
  var i = 0
  while i < cs.len() {
    if i + 2 < cs.len() && cs[i] == 'a' && cs[i + 1] == ' ' && cs[i + 2] == '`' {
      let at_word = i == 0 || !(is_word_char(cs[i - 1]))
      let vowel = i + 3 < cs.len() && "aeiouAEIOU".contains(str(cs[i + 3]))
      if at_word && vowel {
        out.push('a')
        out.push('n')
      } else {
        out.push('a')
      }
      out.push(' ')
      out.push('`')
      i += 3
    } else {
      out.push(cs[i])
      i += 1
    }
  }
  str(out)
}

/// Rust's `c.is_alphanumeric() || c == '_'` (ASCII, plus every non-ASCII letter-like char).
fn is_word_char(c: char): bool = c.is_alpha() || c.is_digit() || c == '_' || int(c) > 0x7f

/// Edit distance counting an adjacent transposition as one edit, for "did you mean" notes.
pub fn edit_distance(a: str, b: str): int {
  let x = a.chars()
  let y = b.chars()
  var d: [[int]] = []
  for i in 0..x.len() + 1 {
    var row: [int] = []
    for j in 0..y.len() + 1 { row.push(if i == 0 { j } else if j == 0 { i } else { 0 }) }
    d.push(row)
  }
  for i in 1..x.len() + 1 {
    for j in 1..y.len() + 1 {
      let cost = if x[i - 1] != y[j - 1] { 1 } else { 0 }
      d[i][j] = min(min(d[i - 1][j] + 1, d[i][j - 1] + 1), d[i - 1][j - 1] + cost)
      if i > 1 && j > 1 && x[i - 1] == y[j - 2] && x[i - 2] == y[j - 1] {
        d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
      }
    }
  }
  d[x.len()][y.len()]
}

/// The closest candidate to `name`, if it is close enough to be a likely typo. Ties go to the
/// first name in byte order, so the answer doesn't depend on the order of `cands`.
pub fn similar(name: str, cands: [str]): str? {
  var best: (int, str)? = none
  let limit = max(max(name.len(), 2) / 3, 1)
  for cand in cands {
    let d = edit_distance(name, cand)
    if d <= limit && cand != name {
      let better = match best {
        none => true
        some(b) => d < b.0 || (d == b.0 && cand < b.1)
      }
      if better { best = (d, cand) }
    }
  }
  match best {
    some(b) => b.1
    none => none
  }
}

fn new_checker(prog: resolve.Program): Checker {
  let n = prog.mods.len()
  var items: [ItemTable] = []
  var tables: [typed.Tables] = []
  for _ in 0..n {
    items.push(new_items())
    tables.push(typed.new_tables())
  }
  let root = prog.root
  let src_lines = prog.mods.map(md => lines(md.src))
  Checker {
    prog,
    defs: types.new_defs(),
    fns: [],
    consts: [],
    tests: [],
    items,
    tables,
    errs: [],
    b: Builtins { err: 0, value: 0, show: 0, ord: 0, eq: 0, data: 0 },
    const_state: [],
    cx: empty_cx(root),
    outer: [],
    depth: 0,
    binding: [],
    or_binds: none,
    body_nodes: {},
    main: none,
    globals: [],
    instances: [],
    types_used: [],
    types_used_set: {},
    shape_impls: {},
    from_value_impls: {},
    from_value_seen: {},
    vtables: [],
    let_fixes: {},
    param_fixes: {},
    src_lines,
  }
}

/// The placeholder `cx` while no body is in progress.
fn empty_cx(m: int): BodyCx = BodyCx {
  module: m,
  body: typed.BodyRef.Const(0),
  inf: types.new_infer(),
  t: typed.new_tables(),
  scopes: [],
  frames: [],
  generics: gen_scope(),
  deferred: [],
  callees: {},
  result_local: none,
  in_ensures: false,
  olds: [],
  direct_await: false,
  quiet: 0,
  local_start: 0,
  explicit: none,
}

// ---- diagnostics ----

pub fn err_in(c: var Checker, m: int, d: diag.Diag) {
  // A type shown as `{error}` comes from an earlier error; a diagnostic about it is a cascade
  // (e.g. an ambiguous overload for an argument that didn't type-check), so it is dropped. Only
  // once an error is on record, so broken code never checks clean.
  if c.errs.len() > 0 && (d.message.contains("{{error}}") || d.notes.any(n => n.contains("{{error}}"))) {
    return
  }
  let file = c.prog.mods[m].file
  var d2 = d
  d2.message = articles(d.message)
  d2.notes = d.notes.map(n => articles(n))
  c.errs.push(diag.FileDiag { file, diag: d2 })
}

/// Report in the current body's module.
pub fn err(c: var Checker, d: diag.Diag) {
  let m = c.cur_module()
  c.err_in(m, d)
}

pub fn cur_module(c: Checker): int = if c.depth > 0 { c.cx.module } else { c.prog.root }

/// Render a type for messages, resolving inference variables of the current body.
pub fn show(c: Checker, t: types.Ty): str {
  let t2 = if c.depth > 0 { types.resolve(c.cx.inf, t) } else { t }
  c.defs.show(t2)
}

// ---- collect ----

fn collect(c: var Checker) uses fs {
  let nmods = c.prog.mods.len()
  c.raw_manifests()
  // types and shapes
  for m in 0..nmods {
    for i in 0..c.prog.mods[m].ast.items.len() { c.declare_type(m, i) }
  }
  c.find_builtins()
  for m in 0..nmods {
    for i in 0..c.prog.mods[m].ast.items.len() { c.define_type(m, i) }
  }
  c.field_visibility()
  // functions, constants, tests
  for m in 0..nmods {
    for i in 0..c.prog.mods[m].ast.items.len() {
      let item = c.prog.mods[m].ast.items[i]
      match item {
        Fn(g) => c.declare_fns(m, i, g)
        Let(cd) => c.declare_const(m, i, cd, false)
        Imprint(cd) => c.declare_const(m, i, cd, true)
        Test(t) => c.tests.push(typed.TestInfo { name: t.name, module: m, item: i, span: t.span })
        Global(d) => check_raw.declare_global(&c, m, d)
        _ => {}
      }
    }
    c.check_duplicate_fns(m)
  }
  // the runtime's dialect: global initializers and `raw assert`s, evaluated now
  check_raw.check_globals(&c)
}

/// E0418 for a package other than the runtime listing `raw` in its raft.toml's effects.
fn raw_manifests(c: var Checker) uses fs {
  for pkg in c.prog.pkgs {
    if pkg.is_core || pkg.name == "auk_rt" || !pkg.effects.contains("raw") { continue }
    let dir = pkg.dir else continue
    let toml = paths.join(dir, "raft.toml")
    var span = diag.Span { line: 1, col: 1, end_line: 1, end_col: 1 }
    match fs.read(toml) {
      ok(text) => for i, l in text.lines() {
        match l.find("\"raw\"") {
          some(k) => if l.trim().starts_with("effects") {
            let col = l[0..k].chars().len() + 1
            span = diag.Span { line: i + 1, col, end_line: i + 1, end_col: col + 5 }
          }
          none => {}
        }
      }
      err(_) => {}
    }
    let d = effect_check.raw_only(span, "the package `{pkg.name}` lists the effect `raw`")
    c.errs.push(diag.FileDiag { file: toml, diag: d })
  }
}

/// `Item::Let(c) | Item::Imprint(c)` of `collect`.
fn declare_const(c: var Checker, m: int, i: int, cd: ast.ConstDef, imprint: bool) {
  var g = gen_scope()
  let ty: types.Ty? = match cd.ty {
    some(t) => c.resolve_type(m, t, &g)
    none => none
  }
  let id = c.consts.len()
  match c.items[m].consts.get(cd.name.name) {
    some(prev) => {
      let at = c.consts[prev].span
      c.err_in(
        m,
        diag.new("E0107", cd.name.span, "`{cd.name.name}` is defined twice in this module")
          .note("the first definition is at {diag.show_at(at)}"),
      )
    }
    none => {}
  }
  c.items[m].consts[cd.name.name] = id
  c.consts.push(typed.ConstInfo {
    name: cd.name.name,
    module: m,
    public: cd.public,
    imprint,
    ty: ty else types.Ty.Error,
    item: i,
    span: cd.name.span,
  })
  c.const_state.push(ConstState.Todo)
}

fn declare_type(c: var Checker, m: int, i: int) {
  let item = c.prog.mods[m].ast.items[i]
  // (name, span, public, doc, generics, node, kind)
  let info: (ast.Ident, diag.Span, bool, str?, [ast.Generic], int, int) = match item {
    Struct(d) => (d.name, d.span, d.public, d.doc, d.generics, d.id, 0)
    Enum(d) => (d.name, d.span, d.public, d.doc, d.generics, d.id, 1)
    ExternType(d) => (d.name, d.span, d.public, d.doc, [], d.id, 2)
    Shape(d) => (d.name, d.span, d.public, d.doc, d.generics, d.id, 3)
    _ => return
  }
  let (name, span, public, doc, generics, node, kind) = info
  if c.items[m].types.contains(name.name) {
    c.err_in(m, diag.new("E0107", name.span, "the type `{name.name}` is defined twice in this module"))
    return
  }
  if ["int", "float", "bool", "char", "str"].contains(name.name) {
    c.err_in(m, diag.new("E0107", name.span, "`{name.name}` is a built-in type and can't be redefined"))
    return
  }
  if kind == 3 {
    let self_param = c.defs.params.len()
    c.defs.params.push(types.TypeParam { name: "Self", bounds: [], implicit: false })
    let id = c.defs.shapes.len()
    let builtin: types.Builtin? = if c.prog.is_core(m) {
      match name.name {
        "Show" => types.Builtin.Show
        "Ord" => types.Builtin.Ord
        "Eq" => types.Builtin.Eq
        "Data" => types.Builtin.Data
        _ => none
      }
    } else {
      none
    }
    if generics.len() > 0 {
      c.err_in(
        m,
        diag.new("E0113", generics[0].name.span, "shapes can't have type parameters")
          .note("inside a shape, `Self` names the type that fits it"),
      )
    }
    c.defs.params[self_param].bounds.push(id)
    c.defs.shapes.push(types.ShapeDef { name: name.name, module: m, public, self_param, methods: [], builtin, span })
    c.items[m].types[name.name] = TypeItem.Shape(id)
    return
  }
  var params: [int] = []
  for g in generics {
    c.defs.params.push(types.TypeParam { name: g.name.name, bounds: [], implicit: false })
    params.push(c.defs.params.len() - 1)
  }
  match item {
    ExternType(d) => if !c.prog.is_core(m) { c.ffi_type(m, d) }
    _ => {}
  }
  let tk = match item {
    ExternType(d) => types.TypeDefKind.Opaque(d.c_type)
    Struct(_) => types.TypeDefKind.Struct([])
    _ => types.TypeDefKind.Enum([])
  }
  let id = c.defs.types.len()
  match item {
    Struct(d) when d.raw > 0 => {
      if !c.prog.raw_ok(m) {
        let what = if d.raw == 2 { "`raw union {name.name}`" } else { "`raw struct {name.name}`" }
        c.err_in(m, effect_check.raw_only(name.span, "{what} is a C layout"))
      }
      c.defs.raw[id] = d.raw
    }
    _ => {}
  }
  c.defs.types.push(types.TypeDef { name: name.name, module: m, public, doc, params, kind: tk, span, node })
  c.items[m].types[name.name] = TypeItem.Def(id)
}

// ---- user-level FFI (docs/ffi-plan.md) ----

/// E0036 unless `m`'s package declares the `ffi` effect in its raft.toml.
fn ffi_allowed(c: var Checker, m: int, at: diag.Span): bool {
  let pkg = c.prog.pkgs[c.prog.mods[m].pkg]
  if pkg.dir is some(_) && pkg.effects.contains("ffi") { return true }
  var d = diag.new("E0036", at, "`extern` declarations need the `ffi` effect in the package's raft.toml")
  d = match pkg.dir {
    some(dir) => d.note("help: add \"ffi\" to `effects` under [package] in {paths.join(dir, "raft.toml")}")
    none => d.note("C functions can only be bound inside a project: create a raft.toml with `effects = [\"ffi\"]` under [package]")
  }
  c.err_in(m, d.note("calling C is unchecked (a crash can't be caught), so a package says so in its manifest; callers then need `uses ffi`"))
  false
}

/// Is `t` a raw struct (passed to C by value)?
fn raw_struct(defs: types.Defs, t: types.Ty): bool = match t {
  Named(d, _) => types.is_raw_def(defs, d)
  _ => false
}

/// The span of the string literal that ends an item spanning `end` (its C prototype or C type).
fn ffi_str_span(c: Checker, m: int, end: diag.Span): diag.Span {
  let ls = c.src_lines[m]
  if end.end_line < 1 || end.end_line > ls.len() { return end }
  let cs = ls[end.end_line - 1].chars()
  let stop = min(max(end.end_col - 1, 0), cs.len())
  var close = -1
  var k = stop - 1
  while k >= 0 {
    if cs[k] == '"' {
      close = k
      break
    }
    k -= 1
  }
  if close < 0 { return end }
  var open = -1
  k = close - 1
  while k >= 0 {
    if cs[k] == '"' {
      open = k
      break
    }
    k -= 1
  }
  if open < 0 { return end }
  diag.Span { line: end.end_line, col: open + 1, end_line: end.end_line, end_col: close + 2 }
}

/// Check a user `extern type` (an opaque C pointer type).
fn ffi_type(c: var Checker, m: int, d: ast.ExternTypeDef) {
  if !c.ffi_allowed(m, d.span) { return }
  let at = c.ffi_str_span(m, d.span)
  let why: str? = match cffi.parse_type(d.c_type) {
    ok(_) when d.c_type.trim_start().starts_with("Auk") => "`Auk...` types belong to the runtime"
    ok(Ptr(_, _)) | ok(Named(_)) => none
    ok(t) => "`{t.show()}` is not a pointer: an `extern type` is an opaque C pointer type (`T *`, or a typedef of one)"
    err(Bad(e)) => e
  }
  match why {
    some(w) => c.err_in(
      m,
      diag.new("E0040", at, "`{d.c_type}` can't be an `extern type`")
        .note(w)
        .note("write the C pointer type, e.g. `extern type Db = \"sqlite3 *\"` or `extern type Module = \"LLVMModuleRef\"`"),
    )
    none => {}
  }
}

/// What `t` is to the FFI (Rust's `ptr_of` closure in `ffi_fn`).
fn ptr_kind(defs: types.Defs, prog: resolve.Program, t: types.Ty): cffi.PtrKind = match t {
  Named(d, _) => match defs.types[d].kind {
    Opaque(ct) => if ct.starts_with("Auk") {
      cffi.PtrKind.NotPtr
    } else if prog.is_core(defs.types[d].module) {
      cffi.PtrKind.AnyPtr
    } else {
      match cffi.parse_type(ct) {
        ok(x) => cffi.PtrKind.CType(x)
        err(_) => cffi.PtrKind.NotPtr
      }
    }
    _ => cffi.PtrKind.NotPtr
  }
  _ => cffi.PtrKind.NotPtr
}

/// How the argument of a cast `(T)` crosses: an opaque pointer, or its `T?`.
fn cast_conv(defs: types.Defs, prog: resolve.Program, p: typed.ParamInfo): cffi.Conv!cffi.CErr {
  if p.var_ { return fail(cffi.CErr.Bad("a cast's argument can't be `var`")) }
  match p.ty {
    Opt(x) => if ptr_kind(defs, prog, x) != cffi.PtrKind.NotPtr { return cffi.Conv.OptPtr }
    _ => {}
  }
  if ptr_kind(defs, prog, p.ty) != cffi.PtrKind.NotPtr { return cffi.Conv.Ptr }
  fail(cffi.CErr.Bad("a cast `(T)` converts an opaque pointer: an `ffi.Ptr` or an `extern type` (or its `T?`)"))
}

/// Check an `extern fn f(): T = "#embed path"`: no parameters, the file (relative to the source
/// file) is readable, and `T` is a form of its contents: `[int]`, `str` (valid UTF-8), `ffi.Ptr`
/// or `int` (the length). The path in the result is the resolved one.
fn ffi_embed(c: var Checker, m: int, cl: ast.FnClause, sig: cffi.CSig, params: [typed.ParamInfo], ret: types.Ty, at: diag.Span): (cffi.CSig, [cffi.Conv])? uses fs {
  let name = cl.name.name
  let rel = sig.embed else ""
  let path = paths.join(paths.parent(c.prog.mods[m].file) else "", rel)
  var errs: [diag.Diag] = []
  if params.len() > 0 { errs.push(diag.new("E0040", at, "`{name}` embeds a file, so it takes no parameters")) }
  let bytes: [int]? = match fs.read_bytes(path) {
    ok(b) => b
    err(e) => {
      errs.push(
        diag.new("E0040", at, "`{name}`: cannot read the file to embed, `{path}`: {paths.io_error(e.show())}")
          .note("the path is relative to this source file"),
      )
      none
    }
  }
  let is_ptr = match ret {
    Named(d, _) => c.defs.types[d].name == "Ptr" && c.prog.is_core(c.defs.types[d].module)
    _ => false
  }
  let fits = match ret {
    Int => true
    List(e) => e == types.Ty.Int
    Str => {
      match bytes {
        some(b) => match utf8_error_at(b) {
          some(at_byte) => errs.push(
            diag.new("E0040", at, "`{name}` embeds `{rel}` as a `str`, but it isn't UTF-8 (at byte {at_byte})")
              .note("embed binary files as `[int]` or `ffi.Ptr`"),
          )
          none => {}
        }
        none => {}
      }
      true
    }
    _ => is_ptr || ret.has_error()
  }
  if !fits {
    let span = match cl.ret {
      some(t) => t.span
      none => cl.name.span
    }
    errs.push(
      diag.new("E0040", span, "`{name}` returns `{c.defs.show(ret)}`, which isn't a form of an embedded file")
        .note("an embedded file is `[int]` (its bytes), `str` (UTF-8 text), `ffi.Ptr` (the address of its bytes, read-only) or `int` (its length)"),
    )
  }
  if errs.len() > 0 {
    for d in errs { c.err_in(m, d) }
    return none
  }
  (cffi.CSig { embed: path, ..sig }, [cffi.Conv.Unit])
}

/// Rust's `str::from_utf8(b).err().map(|e| e.valid_up_to())`: where the first invalid UTF-8
/// sequence starts, if any.
fn utf8_error_at(b: [int]): int? {
  var i = 0
  while i < b.len() {
    let x = b[i]
    if x < 0x80 {
      i += 1
      continue
    }
    var n = 0
    var lo = 0x80
    var hi = 0xbf
    if x >= 0xc2 && x <= 0xdf {
      n = 1
    } else if x >= 0xe0 && x <= 0xef {
      n = 2
      if x == 0xe0 { lo = 0xa0 }
      if x == 0xed { hi = 0x9f }
    } else if x >= 0xf0 && x <= 0xf4 {
      n = 3
      if x == 0xf0 { lo = 0x90 }
      if x == 0xf4 { hi = 0x8f }
    } else {
      return i
    }
    for k in 1..n + 1 {
      if i + k >= b.len() { return i }
      let y = b[i + k]
      let (l, h) = if k == 1 { (lo, hi) } else { (0x80, 0xbf) }
      if y < l || y > h { return i }
    }
    i += n + 1
  }
  none
}

/// Check a user `extern fn`: the package allows it, the prototype parses, and every Auk
/// parameter and the result fit their C types (E0040).
fn ffi_fn(c: var Checker, m: int, cl: ast.FnClause, proto: str, params: [typed.ParamInfo], ret: types.Ty, is_async: bool, generics: [int]): (cffi.CSig, [cffi.Conv])? uses fs {
  if !c.ffi_allowed(m, cl.name.span) { return none }
  let at = c.ffi_str_span(m, cl.span)
  let name = cl.name.name
  if is_async || generics.len() > 0 {
    let what = if is_async { "`async`" } else { "generic" }
    c.err_in(
      m,
      diag.new("E0040", cl.name.span, "the C function `{name}` can't be {what}")
        .note("a C function has one fixed signature and returns when it's done"),
    )
    return none
  }
  let sig = match cffi.parse_proto_in(proto, c.prog.raw_ok(m)) {
    ok(s) => s
    err(Bad(e)) => {
      c.err_in(
        m,
        diag.new("E0040", at, "`{name}`: can't read the C prototype")
          .note(e)
          .note("write the C declaration, e.g. `extern fn abs(n: int): int = \"int abs(int)\"`"),
      )
      return none
    }
  }
  if sig.embed is some(_) { return c.ffi_embed(m, cl, sig, params, ret, at) }
  if sig.params.len() != params.len() {
    c.err_in(
      m,
      if sig.cast {
        diag.new("E0040", at, "`{name}` has {params.len()} parameter(s), but a cast takes 1")
          .note("a cast `(T)` converts its one argument, an `ffi.Ptr` or an `extern type`, to `T`")
      } else if sig.indirect {
        diag.new("E0040", at, "`{name}` has {params.len()} parameter(s), but a call through a function pointer with this prototype takes {sig.params.len()}")
          .note("the first parameter is the function's address (`ffi.Ptr`), then one per C parameter")
      } else {
        diag.new("E0040", at, "`{name}` has {params.len()} parameter(s), but the C prototype of `{sig.name}` has {sig.params.len()}")
          .note("each Auk parameter matches the C parameter in the same position")
      },
    )
    return none
  }
  var convs: [cffi.Conv] = []
  var errs: [diag.Diag] = []
  let defs = c.defs
  let prog = c.prog
  let free = sig.free is some(_)
  for k, p in params {
    let ct = sig.params[k]
    if p.ty.has_error() { return none }
    let cv = if cffi.is_raw(p.ty, raw_struct(defs, p.ty)) && !p.var_ && !sig.cast {
      cffi.raw_conv(p.ty, raw_struct(defs, p.ty), ct)
    } else if sig.cast {
      cast_conv(defs, prog, p)
    } else {
      cffi.conv(p.ty, p.var_, ct, false, free, t => ptr_kind(defs, prog, t))
    }
    match cv {
      ok(cv) => convs.push(cv)
      err(Bad(why)) => {
        let span = match cl.params.get(k) {
          some(x) => match x.ty {
            some(t) => t.span
            none => x.span
          }
          none => at
        }
        let var_ = if p.var_ { "var " } else { "" }
        errs.push(
          diag.new("E0040", span, "parameter {k + 1} of `{name}` is `{var_}{defs.show(p.ty)}`, which doesn't fit the C type `{cffi.show(ct)}`")
            .note(why),
        )
      }
    }
  }
  if ret.has_error() { return none }
  let rconv = if cffi.is_raw(ret, raw_struct(defs, ret)) {
    cffi.raw_conv(ret, raw_struct(defs, ret), sig.ret)
  } else {
    cffi.conv(ret, false, sig.ret, true, free, t => ptr_kind(defs, prog, t))
  }
  match rconv {
    ok(cv) => convs.push(cv)
    err(Bad(why)) => {
      let span = match cl.ret {
        some(t) => t.span
        none => cl.name.span
      }
      errs.push(
        diag.new("E0040", span, "`{name}` returns `{defs.show(ret)}`, which doesn't fit the C result type `{cffi.show(sig.ret)}`")
          .note(why),
      )
    }
  }
  let owned = convs.any(cv => match cv {
    Str(true) | OptStr(true) => true
    Out(x) => x == cffi.Conv.OptStr(true)
    _ => false
  })
  if free && !owned && errs.len() == 0 {
    errs.push(
      diag.new("E0040", at, "`+free` in `{name}`'s prototype, but it hands over no `char *` string")
        .note("`+free(fn)` names the function that frees a returned `char *` (or a `char **` out-parameter) once it's copied"),
    )
  }
  let fine = errs.len() == 0
  for d in errs { c.err_in(m, d) }
  if fine { (sig, convs) } else { none }
}

fn find_builtins(c: var Checker) {
  let core = c.prog.core_root
  match c.items[core].types.get("Err") {
    some(Def(d)) => c.b.err = d
    _ => {}
  }
  match c.items[core].types.get("Value") {
    some(Def(d)) => c.b.value = d
    _ => {}
  }
  for (n, slot) in [("Show", 0), ("Ord", 1), ("Eq", 2), ("Data", 3)] {
    match c.items[core].types.get(n) {
      some(Shape(s)) => {
        if slot == 0 {
          c.b.show = s
        } else if slot == 1 {
          c.b.ord = s
        } else if slot == 2 {
          c.b.eq = s
        } else {
          c.b.data = s
        }
      }
      _ => {}
    }
  }
}

/// The generic scope of a type definition.
fn def_scope(c: Checker, d: int): GenScope {
  var g = gen_scope()
  for p in c.defs.types[d].params { g.names[c.defs.params[p].name] = p }
  g
}

fn define_type(c: var Checker, m: int, i: int) {
  let item = c.prog.mods[m].ast.items[i]
  match item {
    Struct(sd) => {
      let d = match c.items[m].types.get(sd.name.name) {
        some(Def(d)) => d
        _ => return
      }
      if c.defs.types[d].node != sd.id { return }
      var g = c.def_scope(d)
      let ps = c.defs.types[d].params
      c.resolve_bounds(m, sd.generics, ps, &g)
      var fields: [types.FieldDef] = []
      for f in sd.fields {
        if fields.any(x => x.name == f.name.name) {
          c.err_in(m, diag.new("E0107", f.name.span, "the field `{f.name.name}` is declared twice"))
          continue
        }
        let ty = c.resolve_type(m, f.ty, &g)
        fields.push(types.FieldDef { name: f.name.name, ty, public: false, span: f.span })
      }
      if sd.raw > 0 && fields.len() == sd.fields.len() { c.raw_fields(m, sd, fields) }
      c.defs.types[d].kind = types.TypeDefKind.Struct(fields)
    }
    Enum(ed) => {
      let d = match c.items[m].types.get(ed.name.name) {
        some(Def(d)) => d
        _ => return
      }
      if c.defs.types[d].node != ed.id { return }
      var g = c.def_scope(d)
      let ps = c.defs.types[d].params
      c.resolve_bounds(m, ed.generics, ps, &g)
      var variants: [types.VariantDef] = []
      for v in ed.variants {
        if variants.any(x => x.name == v.name.name) {
          c.err_in(m, diag.new("E0107", v.name.span, "the variant `{v.name.name}` is declared twice"))
          continue
        }
        var fields: [(str?, types.Ty)] = []
        for f in v.fields {
          let fname: str? = match f.name {
            some(n) => n.name
            none => none
          }
          fields.push((fname, c.resolve_type(m, f.ty, &g)))
        }
        let idx = variants.len()
        variants.push(types.VariantDef { name: v.name.name, fields, span: v.span, node: v.id })
        var vs = c.items[m].variants.get(v.name.name) else []
        vs.push((d, idx))
        c.items[m].variants[v.name.name] = vs
      }
      c.defs.types[d].kind = types.TypeDefKind.Enum(variants)
    }
    Shape(sd) => {
      let s = match c.items[m].types.get(sd.name.name) {
        some(Shape(s)) => s
        _ => return
      }
      let self_param = c.defs.shapes[s].self_param
      var methods: [types.ShapeMethod] = []
      for f in sd.methods {
        var g = GenScope { self_param: self_param, ..gen_scope() }
        var params: [types.Ty] = []
        for k, p in f.params {
          let t = match p.ty {
            some(t) => c.resolve_type(m, t, &g)
            none => match p.pat.kind {
              Bind(n) when n == "self" && k == 0 => types.Ty.Param(self_param)
              _ => {
                c.err_in(
                  m,
                  diag.new("E0109", p.span, "a shape method parameter needs a type")
                    .note("write `fn name(self, other: T): R`; `self` is the fitting type"),
                )
                types.Ty.Error
              }
            }
          }
          params.push(t)
        }
        let first_self = match params.first() {
          some(Param(p)) => p == self_param
          _ => false
        }
        if !first_self {
          c.err_in(
            m,
            diag.new("E0113", f.name.span, "shape method `{f.name.name}` must take `self` first")
              .note("e.g. `fn area(self): float`"),
          )
        }
        let ret = match f.ret {
          some(t) => c.resolve_type(m, t, &g)
          none => types.unit()
        }
        methods.push(types.ShapeMethod { name: f.name.name, params, ret })
      }
      c.defs.shapes[s].methods = methods
    }
    _ => {}
  }
}

fn resolve_bounds(c: var Checker, m: int, gs: [ast.Generic], params: [int], scope: var GenScope) {
  for (g, p) in gs.zip(params) {
    for b in g.bounds {
      match c.resolve_shape(m, b) {
        some(s) => c.defs.params[p].bounds.push(s)
        none => {}
      }
    }
    scope.names[g.name.name] = p
  }
}

/// A pub struct's fields are public unless their type mentions a private type of the struct's
/// module.
fn field_visibility(c: var Checker) {
  for d in 0..c.defs.types.len() {
    let public = c.defs.types[d].public
    let module = c.defs.types[d].module
    let fields = match c.defs.types[d].kind {
      Struct(fs) => fs
      _ => continue
    }
    let defs = c.defs
    var out: [types.FieldDef] = []
    for f in fields {
      let private = types.any_ty(f.ty, t => match t {
        Named(x, _) => defs.types[x].module == module && !defs.types[x].public
        _ => false
      })
      out.push(types.FieldDef { public: public && !private, ..f })
    }
    c.defs.types[d].kind = types.TypeDefKind.Struct(out)
  }
}

/// Resolve a type expression that must name a shape (a bound, `any S`).
pub fn resolve_shape(c: var Checker, m: int, t: ast.Type): int? {
  match t.kind {
    Named(path, args) when args.len() == 0 => match c.lookup_type_path(m, path) {
      some(Shape(s)) => return s
      _ => {}
    }
    _ => {}
  }
  c.err_in(
    m,
    diag.new("E0105", t.span, "expected a shape, found `{ast.type_dump(t)}`")
      .note("bounds and `any` take a shape such as `Show`, `Ord`, `Eq`, `Data` or one declared with `shape`"),
  )
  none
}

/// The type (or shape) a path names in module `m`.
pub fn lookup_type_path(c: var Checker, m: int, path: [ast.Ident]): TypeItem? {
  if path.len() == 1 {
    let n = path[0].name
    match c.items[m].types.get(n) {
      some(t) => return t
      none => {}
    }
    let core = c.prog.core_root
    match c.items[core].types.get(n) {
      some(t) when c.type_item_public(t) => return t
      _ => {}
    }
    return none
  }
  let target = c.module_of_path(m, path.take(path.len() - 1))?
  let last = path[path.len() - 1]
  let t = c.items[target].types.get(last.name)?
  if target != m && !c.type_item_public(t) {
    c.err_in(
      m,
      diag.new("E0120", last.span, "the type `{last.name}` is private to module `{c.prog.name(target)}`")
        .note("mark it `pub` to use it from other modules"),
    )
  }
  t
}

pub fn type_item_public(c: Checker, t: TypeItem): bool = match t {
  Def(d) => c.defs.types[d].public
  Shape(s) => c.defs.shapes[s].public
}

/// The module a path of module names denotes (`http.uri`), if every segment is a module.
pub fn module_of_path(c: Checker, m: int, path: [ast.Ident]): int? {
  let first = path.first()?
  var cur = c.prog.first_segment(m, first.name)?
  for seg in path.skip(1) { cur = c.prog.child(cur, seg.name)? }
  cur
}

/// What the dotted prefix `path` of an expression (`env` in `env.get(k)`) means (see the Rust
/// docs: a local named like a core module wins; a local named like a module of this package, the
/// package itself, a dependency or `core` is E0116).
pub fn expr_path(c: var Checker, m: int, path: [ast.Ident]): ExprPath {
  let target = c.module_of_path(m, path) else return ExprPath.Value
  let first = path[0]
  if !c.local_in_scope(first.name) { return ExprPath.Module(target) }
  let n = first.name
  let head = c.prog.first_segment(m, n) else 0
  if c.prog.is_core(head) && n != "core" { return ExprPath.Value }
  let pkg = c.prog.pkgs[c.prog.mods[m].pkg]
  let what = if n == "core" {
    "the core library root"
  } else if pkg.root == head {
    "this package `{n}`"
  } else if pkg.deps.contains(n) && c.prog.child(pkg.root, n) is none {
    "the dependency `{n}`"
  } else {
    "the module `{c.prog.name(head)}`"
  }
  c.err(
    diag.new("E0116", first.span, "`{n}` is both a local and {what}, so `{n}.` is ambiguous")
      .note("`{n}.` is always a path when `{n}` names a module or dependency; rename the local to use it as a value")
      .note("only core module names (`env`, `fs`, `time`, ...) are shadowed by locals"),
  )
  ExprPath.Ambiguous
}

/// Resolve a type annotation.
pub fn resolve_type(c: var Checker, m: int, t: ast.Type, g: var GenScope): types.Ty {
  match t.kind {
    List(x) => types.list(c.resolve_type(m, x, &g))
    Array(x, n) => {
      if !c.prog.raw_ok(m) {
        c.err_in(m, effect_check.raw_only(t.span, "`{ast.type_dump(t)}` is a C array type"))
        return types.Ty.Error
      }
      types.Ty.Array(c.resolve_type(m, x, &g), n)
    }
    Map(k, v) => {
      let kt = c.resolve_type(m, k, &g)
      types.map(kt, c.resolve_type(m, v, &g))
    }
    Tuple(ts) => {
      var out: [types.Ty] = []
      for x in ts { out.push(c.resolve_type(m, x, &g)) }
      types.Ty.Tuple(out)
    }
    Optional(x) => types.opt(c.resolve_type(m, x, &g))
    Fallible(ok_t, err_t) => {
      let okt = c.resolve_type(m, ok_t, &g)
      let e = match err_t {
        none => types.Ty.Named(c.b.err, [])
        some(e) => {
          let et = c.resolve_type(m, e, &g)
          let fine = match et {
            Named(d, _) => c.defs.is_enum(d) || d == c.b.err
            Error => true
            _ => false
          }
          if !fine {
            c.err_in(
              m,
              diag.new("E0112", e.span, "the error type in `T!E` must be an enum, found `{c.defs.show(et)}`")
                .note("write `T!` for a plain `Err`, or declare `enum MyErr {{ ... }}`"),
            )
            return types.Ty.Error
          }
          et
        }
      }
      types.res(okt, e)
    }
    Any(s) => match c.resolve_shape(m, s) {
      some(sh) => types.Ty.Any(sh)
      none => types.Ty.Error
    }
    Fn(params, ret) => {
      var ps: [types.Ty] = []
      for x in params { ps.push(c.resolve_type(m, x, &g)) }
      types.func(ps, c.resolve_type(m, ret, &g))
    }
    // the parser allows `var T` only as a function type's parameter
    Var(x) => types.Ty.Mut(c.resolve_type(m, x, &g))
    Measured(b, us) => match c.resolve_type(m, b, &g) {
      Int => types.measured(types.Ty.Int, us)
      Float => types.measured(types.Ty.Float, us)
      Error => types.Ty.Error
      bt => {
        let bs = c.defs.show(bt)
        c.err_in(m, diag.new("E0037", t.span, "only `int` and `float` take a unit of measure, not `{bs}`"))
        types.Ty.Error
      }
    }
    Named(path, args) => c.resolve_named(m, t, path, args, &g)
  }
}

/// The `TypeKind::Named` arm of `resolve_type`.
fn resolve_named(c: var Checker, m: int, t: ast.Type, path: [ast.Ident], args: [ast.Type], g: var GenScope): types.Ty {
  if c.prog.raw_ok(m) {
    match c.raw_named(m, t, path, args, &g) {
      some(x) => return x
      none => {}
    }
  }
  if path.len() == 1 {
    let n = path[0].name
    match g.names.get(n) {
      some(p) => return c.no_args(m, t, args, types.Ty.Param(p))
      none => {}
    }
    if n == "Self" {
      match g.self_param {
        some(p) => return c.no_args(m, t, args, types.Ty.Param(p))
        none => {}
      }
      c.err_in(m, diag.new("E0104", t.span, "`Self` is only valid inside a shape"))
      return types.Ty.Error
    }
    if !c.items[m].types.contains(n) {
      let prim: types.Ty? = match n {
        "int" => types.Ty.Int
        "float" => types.Ty.Float
        "bool" => types.Ty.Bool
        "char" => types.Ty.Char
        "str" => types.Ty.Str
        // only core can name it (`proc.exit(code): never`)
        "never" when c.prog.is_core(m) => types.Ty.Never
        _ => none
      }
      match prim {
        some(p) => return c.no_args(m, t, args, p)
        none => {}
      }
      if n == "Task" {
        if args.len() != 1 {
          c.err_in(m, diag.new("E0106", t.span, "`Task` takes 1 type argument, found {args.len()}"))
          return types.Ty.Error
        }
        return types.Ty.Task(c.resolve_type(m, args[0], &g))
      }
    }
  }
  let item = match c.lookup_type_path(m, path) {
    some(it) => it
    none => {
      let name = path.map(i => i.name).join(".")
      var d = diag.new("E0104", t.span, "unknown type `{name}`")
      var cands = c.items[m].types.keys()
      for x in ["int", "float", "bool", "char", "str", "Value", "Err"] { cands.push(x) }
      match similar(name, cands) {
        some(s) => d = d.note("did you mean `{s}`?").fix(t.span, s)
        none => if name == "string" || name == "String" {
          d = d.note("the string type is `str`").fix(t.span, "str")
        } else if name == "i64" || name == "f64" {
          d = d.note("Auk's numeric types are `int` and `float`")
        }
      }
      c.err_in(m, d)
      return types.Ty.Error
    }
  }
  match item {
    Def(d) => {
      let want = c.defs.types[d].params.len()
      if args.len() != want {
        c.err_in(m, diag.new("E0106", t.span, "`{c.defs.types[d].name}` takes {want} type argument(s), found {args.len()}"))
        return types.Ty.Error
      }
      var targs: [types.Ty] = []
      for a in args { targs.push(c.resolve_type(m, a, &g)) }
      types.Ty.Named(d, targs)
    }
    Shape(s) => {
      if g.key_mode { return types.Ty.Any(s) }
      let name = c.defs.shapes[s].name
      if g.implicit {
        match g.names.get(name) {
          some(p) => return types.Ty.Param(p)
          none => {}
        }
        c.defs.params.push(types.TypeParam { name, bounds: [s], implicit: true })
        let p = c.defs.params.len() - 1
        g.names[name] = p
        g.implicit_params.push(p)
        return types.Ty.Param(p)
      }
      c.err_in(
        m,
        diag.new("E0105", t.span, "the shape `{name}` can't be used as a type here")
          .note("a shape is a type only in a function signature (`fn f(x: {name})`); elsewhere write `any {name}` for a value of any fitting type")
          .fix(t.span, "any {name}"),
      )
      types.Ty.Error
    }
  }
}

/// The runtime's dialect (docs/lowlevel.md): the fixed-width types, `raw.Ptr<T>` and
/// `raw.Fn<(A) => R>` (`Ptr`, `Fn` inside core's `raw` module).
fn raw_named(c: var Checker, m: int, t: ast.Type, path: [ast.Ident], args: [ast.Type], g: var GenScope): types.Ty? {
  if path.len() == 1 && !g.names.contains(path[0].name) && !c.items[m].types.contains(path[0].name) {
    match types.fx_of(path[0].name) {
      some(k) => return c.no_args(m, t, args, types.Ty.Fixed(k))
      none => {}
    }
  }
  let in_raw = c.prog.is_core(m) && c.prog.mods[m].path == ["core", "raw"]
  let name = if path.len() == 1 && in_raw {
    path[0].name
  } else if path.len() == 2 && path[0].name == "raw" && c.prog.first_segment(m, "raw") == c.prog.raw_module() {
    path[1].name
  } else {
    return none
  }
  let want = match name {
    "Ptr" | "Fn" => 1
    _ => return none
  }
  if args.len() != want {
    c.err_in(m, diag.new("E0106", t.span, "`raw.{name}` takes {want} type argument(s), found {args.len()}"))
    return types.Ty.Error
  }
  let a = c.resolve_type(m, args[0], &g)
  if name == "Ptr" { return types.Ty.Ptr(a) }
  match a {
    Fn(ps, r) => types.Ty.CFn(ps, r)
    Error => types.Ty.Error
    _ => {
      c.err_in(m, diag.new("E0106", args[0].span, "`raw.Fn` takes a function type, like `raw.Fn<(i32) => i32>`"))
      types.Ty.Error
    }
  }
}

/// May a value of type `t` be in `uses raw` code or a raw struct (docs/lowlevel.md): no
/// reference-counted type (`str`, lists, maps, closures, ordinary structs and enums, `T!`,
/// tasks); numbers, `bool`, `char`, raw types, `T?` and tuples of those, plain enums.
pub fn raw_allowed(defs: types.Defs, t: types.Ty): bool = match t {
  Int | Float | Bool | Char | Never | Fixed(_) | Ptr(_) | CFn(_, _) | Param(_) | Error => true
  Tuple(ts) => ts.all(x => raw_allowed(defs, x))
  Opt(x) | Array(x, _) => raw_allowed(defs, x)
  Named(d, _) => match defs.types[d].kind {
    Struct(_) => types.is_raw_def(defs, d)
    Enum(vs) => vs.all(v => v.fields.len() == 0)
    Opaque(cty) => !cty.starts_with("Auk")
  }
  _ => false
}

/// E0419 unless every field of the raw struct `d` has a raw type; a flexible array member only
/// last.
fn raw_fields(c: var Checker, m: int, sd: ast.StructDef, fields: [types.FieldDef]) {
  if sd.generics.len() > 0 {
    c.err_in(m, diag.new("E0419", sd.generics[0].name.span, "a raw struct can't have type parameters"))
  }
  for i, f in fields {
    let ast_ty = sd.fields[i].ty
    if !raw_allowed(c.defs, f.ty) {
      c.err_in(
        m,
        diag.new("E0419", ast_ty.span, "the field `{f.name}` of a raw struct can't be `{c.defs.show(f.ty)}`")
          .note("raw structs hold C data: numbers, `bool`, raw pointers, other raw structs, `[T; N]`; an Auk object is a `raw.Ptr` to the raw struct that mirrors it"),
      )
    }
    match f.ty {
      Array(_, n) when n < 0 && i + 1 < fields.len() => c.err_in(
        m,
        diag.new("E0419", ast_ty.span, "a flexible array member `[T; ..]` must be the last field"),
      )
      _ => {}
    }
  }
}

fn no_args(c: var Checker, m: int, t: ast.Type, args: [ast.Type], ty: types.Ty): types.Ty {
  if args.len() > 0 {
    c.err_in(m, diag.new("E0106", t.span, "`{c.defs.show(ty)}` takes no type arguments"))
  }
  ty
}

// ---- functions: splitting clause groups and signatures ----

/// The type a parameter pattern implies by its form alone (for clause groups without an
/// annotation at that position): `0` is int, `Circle(r)` is `Shape`, `[]` is a list, ...
/// `none` when the pattern says nothing (a binding or `_`).
fn pattern_type(c: var Checker, m: int, p: ast.Pat, inf: var types.Infer): types.Ty? {
  match p.kind {
    Wild => none
    Bind(n) => {
      let vs = c.variants_in_scope(m, n)
      if vs.len() == 1 { c.fresh_def(vs[0].0, &inf) } else { none }
    }
    Lit(l, _) => match l {
      Int(_) => types.Ty.Int
      Float(_) => types.Ty.Float
      Bool(_) => types.Ty.Bool
      Char(_) => types.Ty.Char
      Str(_) => types.Ty.Str
    }
    Tuple(ps) => {
      var ts: [types.Ty] = []
      for q in ps { ts.push(c.pattern_type(m, q, &inf) else types.fresh(&inf)) }
      types.Ty.Tuple(ts)
    }
    List(head, rest, tail) => {
      let e = types.fresh(&inf)
      for q in head + tail {
        match c.pattern_type(m, q, &inf) {
          some(t) => { let _ = types.unify(&inf, e, t) }
          none => {}
        }
      }
      match rest {
        some(r) => match r.pat {
          some(rp) => match c.pattern_type(m, rp, &inf) {
            some(t) => { let _ = types.unify(&inf, types.list(e), t) }
            none => {}
          }
          none => {}
        }
        none => {}
      }
      types.list(e)
    }
    Variant(path, _) => {
      let (d, _) = c.variant_path(m, path)?
      c.fresh_def(d, &inf)
    }
    Struct(path, _, _) => match c.lookup_type_path(m, path) {
      some(Def(d)) => c.fresh_def(d, &inf)
      _ => none
    }
    Map(_) => none
    StrPrefix(_, _) => types.Ty.Str
    Some(q) => types.opt(c.pattern_type(m, q, &inf) else types.fresh(&inf))
    None => types.opt(types.fresh(&inf))
    Ok(_) | Err(_) => {
      let a = types.fresh(&inf)
      types.res(a, types.fresh(&inf))
    }
    Or(ps) => c.pattern_type(m, ps[0], &inf)
  }
}

pub fn fresh_def(c: Checker, d: int, inf: var types.Infer): types.Ty {
  var args: [types.Ty] = []
  for _ in c.defs.types[d].params { args.push(types.fresh(&inf)) }
  types.Ty.Named(d, args)
}

/// Variants named `name` visible unqualified in module `m`: the module's own enums, else core's
/// public enums (`Value`).
pub fn variants_in_scope(c: Checker, m: int, name: str): [(int, int)] {
  match c.items[m].variants.get(name) {
    some(v) when v.len() > 0 => return v
    _ => {}
  }
  let core = c.prog.core_root
  let vs = c.items[core].variants.get(name) else []
  let defs = c.defs
  vs.filter(x => defs.types[x.0].public || m == core)
}

/// A qualified variant path: `Shape.Circle`, `json.Eof`, `json.JsonErr.Eof`, or a bare `Circle`
/// in scope.
pub fn variant_path(c: var Checker, m: int, path: [ast.Ident]): (int, int)? {
  let last = path[path.len() - 1].name
  if path.len() == 1 {
    let vs = c.variants_in_scope(m, last)
    return if vs.len() == 1 { vs[0] } else { none }
  }
  let prefix = path.take(path.len() - 1)
  match c.lookup_type_path(m, prefix) {
    some(Def(d)) => {
      let i = c.defs.variants(d).find_index(v => v.name == last)?
      return (d, i)
    }
    _ => {}
  }
  let target = c.module_of_path(m, prefix)?
  let defs = c.defs
  let vs = (c.items[target].variants.get(last) else []).filter(x => defs.types[x.0].public || target == m)
  if vs.len() == 1 { vs[0] } else { none }
}

/// The grouping key of a clause: its first parameter's type (annotation or pattern). A clause's
/// own type parameters are matched by name across the group (`canon`).
fn clause_key(c: var Checker, m: int, cl: ast.FnClause, inf: var types.Infer, canon: var {str: int}): types.Ty? {
  let p = cl.params.first()?
  match p.ty {
    some(t) => {
      var g = GenScope { key_mode: true, ..gen_scope() }
      for gp in cl.generics {
        let id = match canon.get(gp.name.name) {
          some(x) => x
          none => {
            c.defs.params.push(types.TypeParam { name: gp.name.name, bounds: [], implicit: false })
            let x = c.defs.params.len() - 1
            canon[gp.name.name] = x
            x
          }
        }
        g.names[gp.name.name] = id
      }
      let n = c.errs.len()
      let ty = c.resolve_type(m, t, &g)
      c.errs = c.errs.take(n) // reported again when the signature is resolved
      ty
    }
    none => c.pattern_type(m, p.pat, &inf)
  }
}

fn declare_fns(c: var Checker, m: int, item: int, g: ast.FnGroup) uses fs {
  // split the clause group by first-parameter type
  var inf = types.new_infer()
  var canon: {str: int} = {}
  let header_key: types.Ty? = match g.header {
    some(h) => c.clause_key(m, h, &inf, &canon)
    none => none
  }
  var keys: [types.Ty?] = []
  var splits: [[int]] = []
  for ci, cl in g.clauses {
    let k = c.clause_key(m, cl, &inf, &canon)
    if splits.len() == 0 {
      keys.push(k)
      splits.push([ci])
      continue
    }
    let last = splits.len() - 1
    match k {
      none => splits[last].push(ci)
      some(kt) => match keys[last] {
        none => {
          keys[last] = kt
          splits[last].push(ci)
        }
        some(t) => if types.try_unify(&inf, t, kt) {
          splits[last].push(ci)
        } else {
          keys.push(kt)
          splits.push([ci])
        }
      }
    }
  }
  var header_split = 0
  match header_key {
    some(hk) => {
      for si, k in keys {
        let fits = match k {
          none => true
          some(kt) => types.can_unify(&inf, kt, hk)
        }
        if fits {
          header_split = si
          break
        }
      }
    }
    none => {}
  }
  for si, clauses in splits {
    let header = g.header is some(_) && si == header_split
    c.declare_fn(m, item, g, clauses, header)
  }
}

fn declare_fn(c: var Checker, m: int, item: int, g: ast.FnGroup, clauses: [int], header: bool) uses fs {
  let hdr: ast.FnClause? = if header { g.header } else { none }
  let cls = clauses.map(i => g.clauses[i])
  let first = hdr else cls[0]
  var all: [ast.FnClause] = []
  match hdr {
    some(h) => all.push(h)
    none => {}
  }
  for x in cls { all.push(x) }
  // generics: explicit ones, plus implicit shape parameters
  var gs = GenScope { implicit: true, ..gen_scope() }
  var generics: [int] = []
  match all.find(x => x.generics.len() > 0) {
    some(src) => {
      for gp in src.generics {
        c.defs.params.push(types.TypeParam { name: gp.name.name, bounds: [], implicit: false })
        let p = c.defs.params.len() - 1
        gs.names[gp.name.name] = p
        generics.push(p)
      }
      for (gp, p) in src.generics.zip(generics) {
        for b in gp.bounds {
          match c.resolve_shape(m, b) {
            some(s) => c.defs.params[p].bounds.push(s)
            none => {}
          }
        }
      }
    }
    none => {}
  }
  // parameters
  var params: [typed.ParamInfo] = []
  var inf = types.new_infer()
  for i in 0..g.arity {
    let ann_at = all.find_index(x => x.params[i].ty is some(_))
    let ty = match ann_at {
      some(ai) => {
        let t = all[ai].params[i].ty else continue
        let ty = c.resolve_type(m, t, &gs)
        for k, x in all {
          if k == ai { continue }
          match x.params[i].ty {
            some(t2) => {
              let n = c.errs.len()
              let ty2 = c.resolve_type(m, t2, &gs)
              c.errs = c.errs.take(n)
              if ty2 != ty && !ty2.has_error() && !ty.has_error() {
                c.err_in(
                  m,
                  diag.new("E0108", t2.span, "this clause of `{g.name}` declares parameter {i + 1} as `{c.defs.show(ty2)}`, but an earlier clause says `{c.defs.show(ty)}`")
                    .note("all clauses of a function take the same parameter types")
                    .fix(t2.span, c.defs.show(ty)),
                )
              }
            }
            none => {}
          }
        }
        ty
      }
      none => {
        let v = types.fresh(&inf)
        for x in all {
          match c.pattern_type(m, x.params[i].pat, &inf) {
            some(t) => { let _ = types.unify(&inf, v, t) }
            none => {}
          }
        }
        let t = types.resolve(inf, v)
        if t.has_vars() {
          let span = cls[0].params[i].span
          c.err_in(
            m,
            diag.new("E0109", span, "can't tell the type of parameter {i + 1} of `{g.name}`")
              .note("annotate it in one clause (`x: T`) or in a header line; a clause pattern like `0`, `[]` or `Circle(r)` only implies a type when it fixes it completely"),
          )
          types.Ty.Error
        } else {
          t
        }
      }
    }
    let var_ = all.any(x => x.params[i].var_)
    var names: [str?] = []
    for x in cls {
      names.push(match x.params[i].pat.kind {
        Bind(n) => n
        _ => none
      })
    }
    let name: str? = match names[0] {
      some(n) => if names.all(x => x == some(n)) && c.variants_in_scope(m, n).len() == 0 { n } else { none }
      none => none
    }
    params.push(typed.ParamInfo { name, ty, var_ })
  }
  // return type
  let ret = match all.find_index(x => x.ret is some(_)) {
    some(ai) => {
      let t = all[ai].ret else return
      let r = c.resolve_type(m, t, &gs)
      for k, x in all {
        if k == ai { continue }
        match x.ret {
          some(t2) => {
            let n = c.errs.len()
            let r2 = c.resolve_type(m, t2, &gs)
            c.errs = c.errs.take(n)
            if r2 != r && !r2.has_error() && !r.has_error() {
              c.err_in(
                m,
                diag.new("E0110", t2.span, "this clause of `{g.name}` returns `{c.defs.show(r2)}`, but an earlier clause returns `{c.defs.show(r)}`")
                  .note("all clauses of a function have the same return type")
                  .fix(t2.span, c.defs.show(r)),
              )
            }
          }
          none => {}
        }
      }
      r
    }
    none => types.unit()
  }
  for p in gs.implicit_params { generics.push(p) }
  let is_async = all.any(x => x.is_async)
  let public = all.any(x => x.public)
  var effs = first.effects.map(u => u.name)
  var doc: str? = none
  for x in all {
    match x.doc {
      some(d) => {
        doc = d
        break
      }
      none => {}
    }
  }
  var ext: str? = none
  for x in cls {
    match x.body {
      some(Extern(s)) => {
        ext = s
        break
      }
      _ => {}
    }
  }
  let kind = match ext {
    some(proto) when !c.prog.is_core(m) => {
      // a user C function: implicitly `uses ffi`
      if !effs.contains("ffi") { effs.push("ffi") }
      let ec = cls.find(x => x.body is some(ast.FnBody.Extern(_))) else first
      match c.ffi_fn(m, ec, proto, params, ret, is_async, generics) {
        some((sig, convs)) => typed.FnKind.Ffi(sig, convs, item)
        none => typed.FnKind.Extern("", false, item)
      }
    }
    some(sym) when sym.starts_with("@") => match typed.intrinsic_from_symbol(sym) {
      some(which) => typed.FnKind.Intrinsic(which, item)
      none => {
        // Internal: only prelude externs name runtime symbols, so this fires only for a broken
        // prelude declaration.
        c.err_in(m, diag.new("E0114", first.name.span, "unknown compiler intrinsic `{sym}`"))
        typed.FnKind.Extern(sym, false, item)
      }
    }
    some(sym) => match sym.strip_suffix(" +loc") {
      some(s) => typed.FnKind.Extern(s, true, item)
      none => typed.FnKind.Extern(sym, false, item)
    }
    none => typed.FnKind.Auk(item, clauses, header)
  }
  let export = all.reduce(0, (a, x) => if x.export > a { x.export } else { a })
  if export > 0 { check_raw.export_fn(&c, m, first, cls.len(), generics.len() > 0) }
  let id = c.fns.len()
  c.fns.push(typed.FnInfo {
    name: g.name,
    module: m,
    public,
    is_async,
    doc,
    generics,
    params,
    ret,
    effects: effs,
    kind,
    span: first.name.span,
    callees: [],
    olds: [],
    result_local: none,
    export: export,
  })
  var ids = c.items[m].fns.get(g.name) else []
  ids.push(id)
  c.items[m].fns[g.name] = ids
}

/// Two functions with the same name, arity and (non-generic) first-parameter type in one
/// module: the clauses were split apart.
fn check_duplicate_fns(c: var Checker, m: int) {
  var dups: [(int, int)] = []
  for name in c.items[m].fns.keys().sort() {
    let ids = c.items[m].fns[name]
    for i, a in ids {
      for b in ids.skip(i + 1) {
        let fa = c.fns[a]
        let fb = c.fns[b]
        if fa.params.len() != fb.params.len() { continue }
        let same = match (fa.params.first(), fb.params.first()) {
          (some(x), some(y)) => x.ty == y.ty && !x.ty.has_params() && !x.ty.has_error()
          (none, none) => true
          _ => false
        }
        if same { dups.push((a, b)) }
      }
    }
  }
  for (a, b) in dups {
    let fa = c.fns[a]
    let fb = c.fns[b]
    let first = match fa.params.first() {
      some(p) => " with a first parameter of type `{c.defs.show(p.ty)}`"
      none => ""
    }
    let d = diag.new("E0111", fb.span, "`{fb.name}` is defined twice{first} taking {fb.params.len()} parameter(s)")
      .note("the other definition is at {diag.show_at(fa.span)}; the clauses of one function must be contiguous (and differ in the first parameter's type to overload)")
    c.err_in(m, d)
  }
}

// ---- function lookup ----

/// Functions named `name` visible from module `m` in `target` (all if the same module, else
/// public ones).
pub fn fns_in(c: Checker, m: int, target: int, name: str): [int] {
  let core_internal = c.prog.is_core(m) && c.prog.is_core(target)
  let fs = c.items[target].fns.get(name) else return []
  let infos = c.fns
  fs.filter(f => target == m || core_internal || infos[f].public)
}

// ---- bodies ----

fn check_bodies(c: var Checker) {
  for k in 0..c.consts.len() { c.ensure_const(k) }
  for f in 0..c.fns.len() {
    if c.fns[f].kind is typed.FnKind.Auk(_, _, _) { c.check_fn(f) }
  }
  for t in 0..c.tests.len() { c.check_test(t) }
}

pub fn new_cx(c: Checker, module: int, body: typed.BodyRef, generics: GenScope): BodyCx = BodyCx {
  module,
  body,
  inf: types.new_infer(),
  t: typed.new_tables(),
  scopes: [{}],
  frames: [],
  generics,
  deferred: [],
  callees: {},
  result_local: none,
  in_ensures: false,
  olds: [],
  direct_await: false,
  quiet: 0,
  local_start: c.tables[module].locals.len(),
  explicit: none,
}

/// Start checking a body (Rust's `self.cxs.push(cx)`).
pub fn push_cx(c: var Checker, cx: BodyCx) {
  if c.depth > 0 { c.outer.push(c.cx) }
  c.cx = cx
  c.depth += 1
}

/// Stop checking the current body (Rust's `self.cxs.pop()`).
pub fn pop_cx(c: var Checker): BodyCx {
  let done = c.cx
  c.depth -= 1
  if c.depth > 0 {
    c.cx = c.outer.pop() else empty_cx(c.prog.root)
  } else {
    c.cx = empty_cx(c.prog.root)
  }
  done
}

/// Check a constant if it hasn't been yet (constants are checked on first use, so their
/// inferred types are available to the bodies that use them).
pub fn ensure_const(c: var Checker, k: int) {
  match c.const_state[k] {
    Done => return
    Busy => {
      let m = c.consts[k].module
      let span = c.consts[k].span
      let name = c.consts[k].name
      c.err_in(
        m,
        diag.new("E0115", span, "the constant `{name}` depends on itself").note("give it a type annotation or break the cycle"),
      )
      c.consts[k].ty = types.Ty.Error
      c.const_state[k] = ConstState.Done
      return
    }
    Todo => {}
  }
  c.const_state[k] = ConstState.Busy
  let m = c.consts[k].module
  let item = c.consts[k].item
  let cd = match c.prog.mods[m].ast.items[item] {
    Let(cd) | Imprint(cd) => cd
    _ => return
  }
  let cx = c.new_cx(m, typed.BodyRef.Const(k), gen_scope())
  c.push_cx(cx)
  c.push_frame(frame("constant", none, none))
  if cd.ty is some(_) {
    let want = c.consts[k].ty
    let _ = c.check(cd.value, want)
  } else {
    let _ = c.infer(cd.value, none)
  }
  c.finish_body()
  let resolved = c.tables[m].types.get(cd.value.id)
  if cd.ty is none { c.consts[k].ty = resolved else types.Ty.Error }
  c.const_state[k] = ConstState.Done
  // an imprint is computed at compile time and embedded as data: its type must fit `Data`
  let ty = c.consts[k].ty
  if c.consts[k].imprint && !ty.has_error() && !ty.has_vars() {
    let data = c.b.data
    match c.fit(ty, data, m) {
      some(note) => {
        let name = c.consts[k].name
        let span = c.consts[k].span
        let ts = c.defs.show(ty)
        c.err_in(
          m,
          diag.new("E0350", span, "`{ts}` doesn't fit the shape `Data`, which `imprint {name}` needs: its value is computed at compile time and embedded as data")
            .note(note)
            .note("compute it at startup with `let` instead, or store data (lists, maps, structs, enums) and build the value from it"),
        )
      }
      none => {}
    }
  }
}

fn check_fn(c: var Checker, f: int) {
  let info = c.fns[f]
  let (item, clauses, header) = match info.kind {
    Auk(i, cs, h) => (i, cs, h)
    _ => return
  }
  let m = info.module
  let group = match c.prog.mods[m].ast.items[item] {
    Fn(g) => g
    _ => return
  }
  var gs = gen_scope()
  for p in info.generics { gs.names[c.defs.params[p].name] = p }
  let cx = c.new_cx(m, typed.BodyRef.Fn(f), gs)
  c.push_cx(cx)
  let hdr: ast.FnClause? = if header { group.header } else { none }
  // contracts on the header line, in the header's own scope
  match hdr {
    some(h) => {
      c.push_scope()
      c.push_frame(frame("function", info.ret, span_of(h.ret)))
      c.bind_params(h, info, true)
      c.contracts(h, info)
      let _ = c.pop_frame()
      c.pop_scope()
    }
    none => {}
  }
  for ci in clauses {
    let cl = group.clauses[ci]
    c.push_scope()
    let ret_insert = if cl.ret is none { c.params_close(m, cl) } else { none }
    c.push_frame(Frame { ret_insert, ..frame("function", info.ret, span_of(cl.ret)) })
    c.bind_params(cl, info, false)
    match cl.guard {
      some(g) => c.guard(g)
      none => {}
    }
    c.contracts(cl, info)
    match cl.body {
      some(Expr(e)) => c.check_tail(e, info.ret)
      some(Block(b)) => {
        let e = ast.Expr { id: b.id, span: b.span, kind: ast.ExprKind.Block(b) }
        c.check_tail(e, info.ret)
      }
      _ => {}
    }
    let _ = c.pop_frame()
    c.pop_scope()
  }
  let olds = c.cx.olds
  let result_local = c.cx.result_local
  let callees = c.cx.callees.keys().sort()
  c.finish_body()
  c.fns[f].olds = olds
  c.fns[f].result_local = result_local
  c.fns[f].callees = callees
}

/// The span of an optional type annotation.
fn span_of(t: ast.Type?): diag.Span? = match t {
  some(x) => x.span
  none => none
}

/// The empty span just after the `)` that closes a clause's parameter list.
fn params_close(c: Checker, m: int, cl: ast.FnClause): diag.Span? {
  let ls = c.src_lines[m]
  let ln = cl.name.span.line
  if ln < 1 || ln > ls.len() { return none }
  let chars = ls[ln - 1].chars()
  var i = cl.name.span.end_col - 1
  var depth = 0
  while i < chars.len() {
    let ch = chars[i]
    if ch == '(' || ch == '[' || ch == '{' || ch == '<' {
      depth += 1
    } else if ch == ')' || ch == ']' || ch == '}' || ch == '>' {
      depth -= 1
      if depth == 0 && ch == ')' {
        let col = i + 2
        return diag.Span { line: ln, col, end_line: ln, end_col: col }
      }
    }
    i += 1
  }
  none
}

/// Bind a clause's parameter patterns to the function's parameter types.
fn bind_params(c: var Checker, cl: ast.FnClause, info: typed.FnInfo, header: bool) {
  var seen: {str: diag.Span} = {}
  for (p, pi) in cl.params.zip(info.params) {
    c.cx.t.types[p.id] = pi.ty
    if header {
      // a header binds plain names only (for its contracts)
      match p.pat.kind {
        Bind(n) => {
          let l = c.new_local(n, pi.ty, pi.var_, p.pat.span)
          c.cx.t.binds[p.pat.id] = l
          c.cx.t.types[p.pat.id] = pi.ty
          c.scope_insert(n, l)
        }
        _ => {}
      }
      continue
    }
    let before = c.tables[c.cur_module()].locals.len()
    c.pattern(p.pat, pi.ty, pi.var_, &seen)
    // assigning to an immutable parameter suggests `x: var T`
    match p.ty {
      some(t) when !pi.var_ => {
        let m = c.cur_module()
        let after = c.tables[m].locals.len()
        let at = diag.Span { end_line: t.span.line, end_col: t.span.col, ..t.span }
        for l in before..after { c.param_fixes[(m, l)] = at }
      }
      _ => {}
    }
  }
}

fn contracts(c: var Checker, cl: ast.FnClause, info: typed.FnInfo) {
  for r in cl.pre { let _ = c.check(r, types.Ty.Bool) }
  if cl.post.len() == 0 { return }
  c.push_scope()
  let rt = match info.ret {
    Res(t, _) => t
    t => t
  }
  let l = match c.cx.result_local {
    some(l) => l
    none => {
      let l = c.new_local("result", rt, false, cl.name.span)
      c.cx.result_local = l
      l
    }
  }
  c.scope_insert("result", l)
  c.cx.in_ensures = true
  for e in cl.post { let _ = c.check(e, types.Ty.Bool) }
  c.cx.in_ensures = false
  c.pop_scope()
}

fn check_test(c: var Checker, t: int) {
  let m = c.tests[t].module
  let td = match c.prog.mods[m].ast.items[c.tests[t].item] {
    Test(td) => td
    _ => return
  }
  let cx = c.new_cx(m, typed.BodyRef.Test(t), gen_scope())
  c.push_cx(cx)
  let ret = types.res(types.unit(), types.Ty.Named(c.b.err, []))
  c.push_frame(frame("test", ret, none))
  let e = ast.Expr { id: td.body.id, span: td.body.span, kind: ast.ExprKind.Block(td.body) }
  let _ = c.stmt(e, true)
  let _ = c.pop_frame()
  c.finish_body()
}

// ---- scopes and locals ----

pub fn push_scope(c: var Checker) {
  c.cx.scopes.push({})
}

pub fn pop_scope(c: var Checker) {
  let _ = c.cx.scopes.pop()
}

/// A `when` guard: a `bool` that can't fail or leave the function, so it is checked in a frame
/// without a return type.
pub fn guard(c: var Checker, g: ast.Expr) {
  c.push_frame(frame("guard", none, none))
  let _ = c.check(g, types.Ty.Bool)
  let _ = c.pop_frame()
}

pub fn push_frame(c: var Checker, f: Frame) {
  var f2 = f
  f2.scope_base = c.cx.scopes.len()
  c.cx.frames.push(f2)
}

pub fn pop_frame(c: var Checker): Frame = c.cx.frames.pop() else frame("frame", none, none)

pub fn new_local(c: var Checker, name: str, ty: types.Ty, mutable: bool, span: diag.Span): int {
  let m = c.cur_module()
  c.tables[m].locals.push(typed.LocalInfo { name, ty, mutable, span })
  c.tables[m].locals.len() - 1
}

pub fn scope_insert(c: var Checker, name: str, l: int) {
  let n = c.cx.scopes.len()
  c.cx.scopes[n - 1][name] = l
}

/// Is a local named `name` in scope? (Unlike `lookup_local`, records no capture.)
pub fn local_in_scope(c: Checker, name: str): bool = c.depth > 0 && c.cx.scopes.any(s => s.contains(name))

/// Find a local by name, recording captures for every closure frame it crosses.
pub fn lookup_local(c: var Checker, name: str): int? {
  if c.depth == 0 { return none }
  var idx = c.cx.scopes.len() - 1
  while idx >= 0 && !c.cx.scopes[idx].contains(name) { idx -= 1 }
  if idx < 0 { return none }
  let l = c.cx.scopes[idx][name]
  var fi = c.cx.frames.len() - 1
  while fi >= 0 {
    if c.cx.frames[fi].scope_base <= idx { break }
    if c.cx.frames[fi].is_closure && !c.cx.frames[fi].captures.contains(l) {
      c.cx.frames[fi].captures.push(l)
    }
    fi -= 1
  }
  l
}

/// Is local `l` captured by the innermost closure frame (declared outside it)?
pub fn is_captured(c: Checker, l: int): bool {
  if c.depth == 0 { return false }
  var fi = c.cx.frames.len() - 1
  while fi >= 0 {
    let f = c.cx.frames[fi]
    if !f.is_closure { break }
    if !f.by_ref && f.captures.contains(l) { return true }
    fi -= 1
  }
  false
}

pub fn local_ty(c: Checker, l: int): types.Ty = c.tables[c.cur_module()].locals[l].ty

/// `ty` resolved, with unresolved variables as `Error`.
fn fix_ty(inf: types.Infer, ty: types.Ty): types.Ty = types.map_ty(types.resolve(inf, ty), x => match x {
  Var(_) => types.Ty.Error
  x => x
})

fn fix_all(inf: types.Infer, ts: [types.Ty]): [types.Ty] = ts.map(a => fix_ty(inf, a))

fn fix_callee(inf: types.Infer, ce: typed.Callee): typed.Callee = match ce {
  Fn(f, targs) => typed.Callee.Fn(f, fix_all(inf, targs))
  Variant(v) => typed.Callee.Variant(typed.VariantRef { args: fix_all(inf, v.args), ..v })
  Shape(s, i, st) => typed.Callee.Shape(s, i, fix_ty(inf, st))
  x => x
}

/// Resolve every inference variable of the finished body and merge its tables into the module's.
/// Unresolved variables are reported once (E0360).
fn finish_body(c: var Checker) {
  // deferred shape checks
  let deferred = c.cx.deferred
  c.cx.deferred = []
  for d in deferred {
    match d {
      Fits(ty, shape, span, why) => {
        let t = types.resolve(c.cx.inf, ty)
        if t.has_vars() || t.has_error() { continue }
        c.require_fit(t, shape, span, why)
      }
    }
  }
  // `cx` is the only owner of the body's tables: update them in place
  var cx = c.pop_cx()
  let m = cx.module
  let inf = cx.inf
  var unresolved: [int] = []
  for n in cx.t.types.keys() {
    let ty0 = cx.t.types[n]
    if !ty0.has_vars() { continue }
    var ty = types.resolve(inf, ty0)
    if ty.has_vars() {
      ty = types.map_ty(ty, x => match x {
        Var(_) => types.Ty.Error
        x => x
      })
      unresolved.push(n)
    }
    cx.t.types[n] = ty
  }
  for n in cx.t.calls.keys() {
    let call = cx.t.calls[n]
    cx.t.calls[n] = typed.Call { callee: fix_callee(inf, call.callee), ..call }
  }
  for n in cx.t.shows.keys() {
    match cx.t.shows[n] {
      Shape(s, i, st) => cx.t.shows[n] = typed.Callee.Shape(s, i, fix_ty(inf, st))
      _ => {}
    }
  }
  for n in cx.t.variants.keys() {
    let v = cx.t.variants[n]
    cx.t.variants[n] = typed.VariantRef { args: fix_all(inf, v.args), ..v }
  }
  for n in cx.t.names.keys() {
    match cx.t.names[n] {
      Fn(f, targs) => cx.t.names[n] = typed.NameRef.Fn(f, fix_all(inf, targs))
      Variant(v) => cx.t.names[n] = typed.NameRef.Variant(typed.VariantRef { args: fix_all(inf, v.args), ..v })
      _ => {}
    }
  }
  for n in cx.t.struct_lits.keys() {
    let s = cx.t.struct_lits[n]
    cx.t.struct_lits[n] = typed.StructLit { args: fix_all(inf, s.args), ..s }
  }
  for n in cx.t.closures.keys() {
    let cl = cx.t.closures[n]
    cx.t.closures[n] = typed.ClosureInfo { params: fix_all(inf, cl.params), ret: fix_ty(inf, cl.ret), ..cl }
  }
  for n in cx.t.fails.keys() {
    match cx.t.fails[n] {
      TypedToErr(x) => cx.t.fails[n] = typed.FailKind.TypedToErr(fix_ty(inf, x))
      _ => {}
    }
  }
  for n in cx.t.tries.keys() {
    let tr = cx.t.tries[n]
    match tr.conv {
      ToErr(from) => cx.t.tries[n] = typed.TryInfo { kind: tr.kind, conv: typed.ErrConv.ToErr(fix_ty(inf, from)) }
      _ => {}
    }
  }
  for n in cx.t.err_payload_pats.keys() { cx.t.err_payload_pats[n] = fix_ty(inf, cx.t.err_payload_pats[n]) }
  for l in cx.local_start..c.tables[m].locals.len() {
    let ty = c.tables[m].locals[l].ty
    if ty.has_vars() {
      let fixed = fix_ty(inf, ty)
      c.tables[m].locals[l].ty = fixed
    }
  }
  if c.prog.raw_ok(m) && !c.prog.is_core(m) {
    check_raw.validate(&c, cx.t, m)
    check_raw.extern_vars(&c, cx.t, m, cx.body)
  }
  c.raw_body_types(cx)
  if unresolved.len() > 0 && c.errs.len() == 0 {
    // report at the first (in source order) expression whose type is unknown
    let span = c.first_span(m, unresolved) else diag.NONE
    c.err_in(
      m,
      diag.new("E0360", span, "can't infer the type of this expression").note("add a type annotation, e.g. `let xs: [int] = []`"),
    )
  }
  merge_tables(&c.tables[m], cx.t)
}

/// E0419: a `uses raw` function (docs/lowlevel.md) holds only types without references, so the
/// compiler emits no reference counting there (the runtime's allocator and RC are written in it).
fn raw_body_types(c: var Checker, cx: BodyCx) {
  let f = match cx.body {
    Fn(f) => f
    _ => return
  }
  let info = c.fns[f]
  if !(info.effects.contains("raw") || info.export > 0) || c.prog.is_core(info.module) { return }
  let m = cx.module
  for p in info.params {
    if !raw_allowed(c.defs, p.ty) {
      c.err_in(m, raw_type_diag(c, info.span, p.ty, "a parameter"))
      return
    }
  }
  if !raw_allowed(c.defs, info.ret) {
    c.err_in(m, raw_type_diag(c, info.span, info.ret, "the result"))
    return
  }
  var bad: [int] = []
  var bad_ty = types.Ty.Error
  for n in cx.t.types.keys() {
    let t = cx.t.types[n]
    if !raw_allowed(c.defs, t) {
      bad.push(n)
      bad_ty = t
    }
  }
  if bad.len() > 0 {
    // the first in source order
    let span = c.first_span(m, bad) else info.span
    var t = bad_ty
    for n in bad {
      match c.first_span(m, [n]) {
        some(s) => if s == span { t = cx.t.types[n] }
        none => {}
      }
    }
    c.err_in(m, raw_type_diag(c, span, t, "a value"))
    return
  }
  for l in cx.local_start..c.tables[m].locals.len() {
    let li = c.tables[m].locals[l]
    if !raw_allowed(c.defs, li.ty) {
      c.err_in(m, raw_type_diag(c, li.span, li.ty, "`{li.name}`"))
      return
    }
  }
}

/// Is `f` an `export fn` (C's calling convention, its name as the symbol)?
pub fn is_export(c: Checker, f: int): bool = c.fns[f].export > 0

fn raw_type_diag(c: Checker, span: diag.Span, t: types.Ty, what: str): diag.Diag =
  diag.new("E0419", span, "{what} of type `{c.defs.show(t)}` in `uses raw` code, which has no reference counting")
    .note("`uses raw` code holds numbers, `bool`, `char`, raw pointers, raw structs, plain enums and `T?` of those; reach Auk objects through a `raw.Ptr` to the raw struct that mirrors them")

/// `tm.x.extend(t.x)` for every side table but `locals` (Rust's tail of `finish_body`).
fn merge_tables(tm: var typed.Tables, t: typed.Tables) {
  for k, v in t.types { tm.types[k] = v }
  for k, v in t.coercions { tm.coercions[k] = v }
  for k, v in t.names { tm.names[k] = v }
  for k, v in t.binds { tm.binds[k] = v }
  for k, v in t.variants { tm.variants[k] = v }
  for k, v in t.calls { tm.calls[k] = v }
  for k, v in t.fields { tm.fields[k] = v }
  for k, v in t.struct_lits { tm.struct_lits[k] = v }
  for k, v in t.struct_pats { tm.struct_pats[k] = v }
  for k, v in t.closures { tm.closures[k] = v }
  for k, v in t.tries { tm.tries[k] = v }
  for k, v in t.fails { tm.fails[k] = v }
  for k, v in t.elses { tm.elses[k] = v }
  for k, v in t.opt_chains { tm.opt_chains[k] = v }
  for k, v in t.awaits { tm.awaits[k] = v }
  for k, v in t.fors { tm.fors[k] = v }
  for k, v in t.formats { tm.formats[k] = v }
  for k, v in t.shows { tm.shows[k] = v }
  for k, v in t.value_map_pats { tm.value_map_pats[k] = v }
  for k, v in t.err_payload_pats { tm.err_payload_pats[k] = v }
  for k, v in t.units { tm.units[k] = v }
  for k, v in t.raw { tm.raw[k] = v }
}

/// The earliest span (in source order) among expression nodes of module `m` (searched in the
/// AST; only used for rare diagnostics).
pub fn first_span(c: Checker, m: int, nodes: [int]): diag.Span? {
  var want: {int: bool} = {}
  for n in nodes { want[n] = true }
  var best: diag.Span? = none
  for item in c.prog.mods[m].ast.items {
    var es: [ast.Expr] = []
    visit.visit_item_exprs(item, &es)
    for e in es {
      if !want.contains(e.id) { continue }
      let better = match best {
        none => true
        some(b) => e.span.line < b.line || (e.span.line == b.line && e.span.col < b.col)
      }
      if better { best = e.span }
    }
  }
  best
}

// ---- main ----

fn find_main(c: var Checker) {
  let root = c.prog.root
  let ids = c.items[root].fns.get("main") else return
  let f = ids[0]
  let info = c.fns[f]
  let errt = types.Ty.Named(c.b.err, [])
  let ok_args = info.params.len() == 0 ||
    (info.params.len() == 1 && info.params[0].ty == types.list(types.Ty.Str) && !info.params[0].var_)
  let ok_ret = [types.unit(), types.Ty.Int, types.res(types.unit(), errt), types.res(types.Ty.Int, errt)].contains(info.ret)
  if ids.len() > 1 || !ok_args || !ok_ret || info.generics.len() > 0 {
    let defs = c.defs
    let ps = info.params.map(p => defs.show(p.ty)).join(", ")
    c.err_in(
      root,
      diag.new("E0370", info.span, "`main` has an unsupported signature: ({ps}) returning `{c.defs.show(info.ret)}`")
        .note("write `fn main()` or `fn main(args: [str])`, returning nothing, `int`, `()!` or `int!` (an `int` is the exit code)"),
    )
    return
  }
  c.main = typed.MainInfo { func: f, takes_args: info.params.len() > 0, ret: info.ret }
}

fn finish(c: Checker): typed.TypedProgram = typed.TypedProgram {
  program: c.prog,
  defs: c.defs,
  fns: c.fns,
  consts: c.consts,
  tests: c.tests,
  tables: c.tables,
  instances: c.instances,
  types_used: c.types_used,
  shape_impls: c.shape_impls,
  from_value_impls: c.from_value_impls,
  vtables: c.vtables,
  main: c.main,
  globals: c.globals,
}

// ---- Methods of the other files ----
//
// Every `impl Checker` method of src/check/expr.rs, pat.rs and shapes.rs, forwarded to the file
// that implements it with the same name and signature, so that `c.f(..)` reaches it from every
// check_*.auk file (see the module docs).

// check_expr.auk (src/check/expr.rs up to `fail_call`)

pub fn infer(c: var Checker, e: ast.Expr, hint: types.Ty?): types.Ty = check_expr.infer(&c, e, hint)
pub fn check(c: var Checker, e: ast.Expr, want: types.Ty): types.Ty = check_expr.check(&c, e, want)
pub fn check_tail(c: var Checker, e: ast.Expr, want: types.Ty) = check_expr.check_tail(&c, e, want)
pub fn check_mode(c: var Checker, e: ast.Expr, want: types.Ty, tail: bool) = check_expr.check_mode(&c, e, want, tail)
pub fn stmt(c: var Checker, e: ast.Expr, discard: bool): types.Ty = check_expr.stmt(&c, e, discard)
pub fn check_unawaited(c: var Checker, e: ast.Expr, t: types.Ty) = check_expr.check_unawaited(&c, e, t)
pub fn expr(c: var Checker, e: ast.Expr, exp: Exp): types.Ty = check_expr.expr(&c, e, exp)
pub fn coerce_at(c: var Checker, e: ast.Expr, have: types.Ty, want: types.Ty, tail: bool): bool =
  check_expr.coerce_at(&c, e, have, want, tail)
pub fn coerce_ty(c: var Checker, have: types.Ty, want: types.Ty, out: var [typed.Coercion], span: diag.Span): bool =
  check_expr.coerce_ty(&c, have, want, &out, span)
pub fn mismatch(c: var Checker, e: ast.Expr, have: types.Ty, want: types.Ty, tail: bool) =
  check_expr.mismatch(&c, e, have, want, tail)
pub fn expr_inner(c: var Checker, e: ast.Expr, exp: Exp): types.Ty = check_expr.expr_inner(&c, e, exp)
pub fn wants_unit(c: Checker, exp: Exp): bool = check_expr.wants_unit(c, exp)
pub fn infer_quiet(c: var Checker, e: ast.Expr) = check_expr.infer_quiet(&c, e)
pub fn cant_infer(c: var Checker, span: diag.Span, what: str): types.Ty = check_expr.cant_infer(&c, span, what)
pub fn lit(c: var Checker, e: ast.Expr, l: ast.Lit, negated: bool): types.Ty = check_expr.lit(&c, e, l, negated)
pub fn zero_takes_unit(c: var Checker, e: ast.Expr, t: types.Ty, want: types.Ty?): types.Ty =
  check_expr.zero_takes_unit(&c, e, t, want)
pub fn name_expr(c: var Checker, e: ast.Expr, n: str, exp: Exp): types.Ty = check_expr.name_expr(&c, e, n, exp)
pub fn item_value(c: var Checker, e: ast.Expr, m: int, target: int, n: str, exp: Exp): types.Ty? =
  check_expr.item_value(&c, e, m, target, n, exp)
pub fn variant_hint(c: Checker, exp: Exp): types.Ty? = check_expr.variant_hint(c, exp)
pub fn value_variant_clash(c: var Checker, span: diag.Span, n: str, hint: types.Ty?): bool =
  check_expr.value_variant_clash(&c, span, n, hint)
pub fn variant_candidates(c: Checker, target: int, n: str, hint: types.Ty?, need_pub: bool): (int, int)? =
  check_expr.variant_candidates(c, target, n, hint, need_pub)
pub fn variant_value(c: var Checker, e: ast.Expr, d: int, i: int, hint: types.Ty?): types.Ty =
  check_expr.variant_value(&c, e, d, i, hint)
pub fn instantiate_def(c: var Checker, d: int): ({int: types.Ty}, [types.Ty]) = check_expr.instantiate_def(&c, d)
pub fn instantiate(c: var Checker, f: int): ({int: types.Ty}, [types.Ty]) = check_expr.instantiate(&c, f)
pub fn unknown_name(c: var Checker, span: diag.Span, n: str, call: bool): types.Ty =
  check_expr.unknown_name(&c, span, n, call)
pub fn field_expr(c: var Checker, e: ast.Expr, base: ast.Expr, name: ast.Ident, exp: Exp): types.Ty =
  check_expr.field_expr(&c, e, base, name, exp)
pub fn field_of(c: var Checker, e: ast.Expr, base: ast.Expr, t: types.Ty, name: ast.Ident): types.Ty =
  check_expr.field_of(&c, e, base, t, name)
pub fn call_expr(c: var Checker, e: ast.Expr, callee: ast.Expr, args: [ast.Expr], exp: Exp): types.Ty =
  check_expr.call_expr(&c, e, callee, args, exp)
pub fn named_call(c: var Checker, e: ast.Expr, callee: ast.Expr, n: str, args: [ArgSrc], exp: Exp, direct: bool): types.Ty =
  check_expr.named_call(&c, e, callee, n, args, exp, direct)
pub fn quiet_args(c: var Checker, args: [ArgSrc]): types.Ty = check_expr.quiet_args(&c, args)
pub fn path_call(c: var Checker, e: ast.Expr, target: int, name: ast.Ident, args: [ArgSrc], exp: Exp, direct: bool): types.Ty =
  check_expr.path_call(&c, e, target, name, args, exp, direct)
pub fn method_call(c: var Checker, e: ast.Expr, recv: ast.Expr, name: ast.Ident, args: [ast.Expr], exp: Exp): types.Ty =
  check_expr.method_call(&c, e, recv, name, args, exp)
pub fn dot_call(c: var Checker, e: ast.Expr, recv: ast.Expr, rt: types.Ty, name: ast.Ident, args: [ArgSrc], exp: Exp, direct: bool): types.Ty =
  check_expr.dot_call(&c, e, recv, rt, name, args, exp, direct)
pub fn cx_can_unify_param_loose(c: var Checker, f: int, p: types.Ty, t: types.Ty): bool =
  check_expr.cx_can_unify_param_loose(&c, f, p, t)
pub fn cx_can_unify_param(c: var Checker, f: int, p: types.Ty, t: types.Ty): bool =
  check_expr.cx_can_unify_param(&c, f, p, t)
pub fn method_tiers(c: Checker, t: types.Ty): [int] = check_expr.method_tiers(c, t)
pub fn method_cands(c: var Checker, name: str, t: types.Ty, nargs: int): [int] = check_expr.method_cands(&c, name, t, nargs)
pub fn args_plausible(c: Checker, f: int, rest: [ArgSrc]): bool = check_expr.args_plausible(c, f, rest)
pub fn method_cands_after(c: var Checker, name: str, t: types.Ty, nargs: int, skip: [int], rest: [ArgSrc]): [int] =
  check_expr.method_cands_after(&c, name, t, nargs, skip, rest)
pub fn sig_text(c: Checker, f: int): str = check_expr.sig_text(c, f)
pub fn pipe_call(c: var Checker, e: ast.Expr, lhs: ast.Expr, callee: ast.Expr, args: [ast.Expr], exp: Exp): types.Ty =
  check_expr.pipe_call(&c, e, lhs, callee, args, exp)
pub fn recv_ty(c: var Checker, e: ast.Expr): types.Ty = check_expr.recv_ty(&c, e)
pub fn arg_ty_for_choice(c: var Checker, a: ArgSrc): types.Ty = check_expr.arg_ty_for_choice(&c, a)
pub fn call_fns(c: var Checker, e: ast.Expr, span: diag.Span, name: str, cands: [int], args: [ArgSrc], exp: Exp, direct: bool): types.Ty =
  check_expr.call_fns(&c, e, span, name, cands, args, exp, direct)
pub fn can_coerce_param(c: var Checker, f: int, p: types.Ty, t: types.Ty): bool = check_expr.can_coerce_param(&c, f, p, t)
pub fn shape_call(c: var Checker, e: ast.Expr, s: int, i: int, self_ty: types.Ty, callee: typed.Callee, args: [ArgSrc]): types.Ty =
  check_expr.shape_call(&c, e, s, i, self_ty, callee, args)
pub fn variant_call(c: var Checker, e: ast.Expr, d: int, i: int, args: [ArgSrc], hint: types.Ty?): types.Ty =
  check_expr.variant_call(&c, e, d, i, args, hint)
pub fn closure_call(c: var Checker, e: ast.Expr, callee: ast.Expr, ft: types.Ty, args: [ArgSrc]): types.Ty =
  check_expr.closure_call(&c, e, callee, ft, args)
pub fn fail_call(c: var Checker, e: ast.Expr, args: [ArgSrc]): types.Ty = check_expr.fail_call(&c, e, args)

// check_ops.auk (src/check/expr.rs from `place`)

pub fn place(c: var Checker, e: ast.Expr, mutate: bool, use_: PlaceUse): types.Ty = check_ops.place(&c, e, mutate, use_)
pub fn local_fix(c: Checker, l: int): (diag.Span, str, str)? = check_ops.local_fix(c, l)
pub fn unary(c: var Checker, e: ast.Expr, op: ast.UnOp, x: ast.Expr, exp: Exp): types.Ty = check_ops.unary(&c, e, op, x, exp)
pub fn binary(c: var Checker, e: ast.Expr, op: ast.BinOp, l: ast.Expr, r: ast.Expr, exp: Exp): types.Ty =
  check_ops.binary(&c, e, op, l, r, exp)
pub fn bit_operand(c: var Checker, x: ast.Expr, t: types.Ty, op: str, fix: bool): bool = check_ops.bit_operand(&c, x, t, op, fix)
pub fn compare(c: var Checker, e: ast.Expr, op: ast.BinOp, t: types.Ty, shape: int, l: ast.Expr, r: ast.Expr) =
  check_ops.compare(&c, e, op, t, shape, l, r)
pub fn arith(c: var Checker, e: ast.Expr, op: ast.BinOp, l: ast.Expr, r: ast.Expr, exp: Exp): types.Ty =
  check_ops.arith(&c, e, op, l, r, exp)
pub fn check_operand(c: var Checker, r: ast.Expr, lt: types.Ty, op: ast.BinOp, l: ast.Expr) = check_ops.check_operand(&c, r, lt, op, l)
pub fn number_compare(c: var Checker, e: ast.Expr, op: ast.BinOp, l: ast.Expr, r: ast.Expr, lt: types.Ty): bool =
  check_ops.number_compare(&c, e, op, l, r, lt)
pub fn unit_operands(c: var Checker, e: ast.Expr, op: ast.BinOp, l: ast.Expr, r: ast.Expr, lt: types.Ty, rt: types.Ty): types.Ty =
  check_ops.unit_operands(&c, e, op, l, r, lt, rt)
pub fn unit_clash(c: var Checker, e: ast.Expr, op: ast.BinOp, l: types.Ty, r: types.Ty) = check_ops.unit_clash(&c, e, op, l, r)
pub fn unit_mismatch(c: Checker, span: diag.Span, have: types.Ty, want: types.Ty): diag.Diag =
  check_ops.unit_mismatch(c, span, have, want)
pub fn operand_with(c: var Checker, r: ast.Expr, lt: types.Ty, rt: types.Ty, op: ast.BinOp, l: ast.Expr) =
  check_ops.operand_with(&c, r, lt, rt, op, l)
pub fn index_expr(c: var Checker, e: ast.Expr, x: ast.Expr, i: ast.Expr): types.Ty = check_ops.index_expr(&c, e, x, i)
pub fn interp_part(c: var Checker, x: ast.Expr, spec: str?) = check_ops.interp_part(&c, x, spec)
pub fn try_expr(c: var Checker, e: ast.Expr, x: ast.Expr, exp: Exp): types.Ty = check_ops.try_expr(&c, e, x, exp)
pub fn bad_try(c: var Checker, e: ast.Expr, x: ast.Expr, t: types.Ty): types.Ty = check_ops.bad_try(&c, e, x, t)
pub fn opt_chain(c: var Checker, e: ast.Expr, x: ast.Expr, name: ast.Ident, args: [ast.Expr]?, exp: Exp): types.Ty =
  check_ops.opt_chain(&c, e, x, name, args, exp)
pub fn opt_tuple_elem(c: var Checker, e: ast.Expr, x: ast.Expr, inner: types.Ty, index: int): types.Ty =
  check_ops.opt_tuple_elem(&c, e, x, inner, index)
pub fn else_expr(c: var Checker, e: ast.Expr, x: ast.Expr, arm: ast.ElseArm, exp: Exp): types.Ty =
  check_ops.else_expr(&c, e, x, arm, exp)
pub fn value_cands(c: Checker, want: types.Ty): [types.Ty] = check_ops.value_cands(c, want)
pub fn wrap_hints(c: var Checker, vals: [types.Ty]): [types.Ty]? = check_ops.wrap_hints(&c, vals)
pub fn else_binder(c: var Checker, arm: ast.ElseArm, err: types.Ty?): int? = check_ops.else_binder(&c, arm, err)
pub fn await_expr(c: var Checker, e: ast.Expr, x: ast.Expr): types.Ty = check_ops.await_expr(&c, e, x)
pub fn bad_await(c: var Checker, e: ast.Expr, x: ast.Expr, t: types.Ty): types.Ty = check_ops.bad_await(&c, e, x, t)
pub fn await_any_expr(c: var Checker, e: ast.Expr, x: ast.Expr): types.Ty = check_ops.await_any_expr(&c, e, x)
pub fn bad_await_any(c: var Checker, e: ast.Expr, x: ast.Expr, t: types.Ty): types.Ty = check_ops.bad_await_any(&c, e, x, t)
pub fn catch_expr(c: var Checker, e: ast.Expr, x: ast.Expr): types.Ty = check_ops.catch_expr(&c, e, x)
pub fn closure(c: var Checker, e: ast.Expr, params: [ast.Param], body: ast.Expr, exp: Exp): types.Ty =
  check_ops.closure(&c, e, params, body, exp)
pub fn block(c: var Checker, b: ast.Block, exp: Exp): types.Ty = check_ops.block(&c, b, exp)
pub fn if_expr(c: var Checker, cond: ast.Expr, then: ast.Block, els: ast.Expr?, exp: Exp): types.Ty =
  check_ops.if_expr(&c, cond, then, els, exp)
pub fn match_expr(c: var Checker, scrut: ast.Expr, arms: [ast.Arm], exp: Exp): types.Ty = check_ops.match_expr(&c, scrut, arms, exp)
pub fn push_loop(c: var Checker, is_loop: bool, break_ty: types.Ty) = check_ops.push_loop(&c, is_loop, break_ty)
pub fn pop_loop(c: var Checker): LoopCx = check_ops.pop_loop(&c)
pub fn in_loop(c: Checker): bool = check_ops.in_loop(c)
pub fn break_expr(c: var Checker, e: ast.Expr, x: ast.Expr?) = check_ops.break_expr(&c, e, x)
pub fn for_expr(c: var Checker, e: ast.Expr, index: ast.Pat?, pat: ast.Pat, iter: ast.Expr, body: ast.Block) =
  check_ops.for_expr(&c, e, index, pat, iter, body)
pub fn let_stmt(c: var Checker, e: ast.Expr, mutable: bool, pat: ast.Pat, ann: ast.Type?, value: ast.Expr, els: ast.ElseArm?) =
  check_ops.let_stmt(&c, e, mutable, pat, ann, value, els)
pub fn mark_let_locals(c: var Checker, before: int, kw: diag.Span, mutable: bool) = check_ops.mark_let_locals(&c, before, kw, mutable)
pub fn irrefutable(c: Checker, p: ast.Pat): bool = check_ops.irrefutable(c, p)
pub fn assign_target(c: var Checker, target: ast.Expr): types.Ty = check_ops.assign_target(&c, target)
pub fn assign(c: var Checker, e: ast.Expr, op: ast.BinOp?, target: ast.Expr, value: ast.Expr) = check_ops.assign(&c, e, op, target, value)
pub fn struct_lit(c: var Checker, e: ast.Expr, path: [ast.Ident], fields: [ast.FieldInit], base: ast.Expr?, exp: Exp): types.Ty =
  check_ops.struct_lit(&c, e, path, fields, base, exp)

// check_pat.auk (src/check/pat.rs)

pub fn pattern(c: var Checker, p: ast.Pat, ty: types.Ty, mutable: bool, seen: var {str: diag.Span}) =
  check_pat.pattern(&c, p, ty, mutable, &seen)
pub fn is_pattern(c: var Checker, p: ast.Pat, ty: types.Ty) = check_pat.is_pattern(&c, p, ty)
pub fn bind_name(c: var Checker, n: str, ty: types.Ty, mutable: bool, span: diag.Span): int = check_pat.bind_name(&c, n, ty, mutable, span)
pub fn or_pat(c: var Checker, alts: [ast.Pat], ty: types.Ty, mutable: bool, seen: var {str: diag.Span}, bind: bool) =
  check_pat.or_pat(&c, alts, ty, mutable, &seen, bind)
pub fn pat_mismatch(c: var Checker, p: ast.Pat, what: str, ty: types.Ty) = check_pat.pat_mismatch(&c, p, what, ty)
pub fn pat(c: var Checker, p: ast.Pat, ty: types.Ty, mutable: bool, seen: var {str: diag.Span}, bind: bool) =
  check_pat.pat(&c, p, ty, mutable, &seen, bind)
pub fn payload_variant(c: var Checker, q: ast.Pat): (int, int)? = check_pat.payload_variant(&c, q)
pub fn fresh_def_cx(c: var Checker, d: int): types.Ty = check_pat.fresh_def_cx(&c, d)
pub fn variant_pat(c: var Checker, p: ast.Pat, d: int, i: int, args: [ast.Pat]?, ty: types.Ty, mutable: bool, seen: var {str: diag.Span}, bind: bool) =
  check_pat.variant_pat(&c, p, d, i, args, ty, mutable, &seen, bind)

// check_shapes.auk (src/check/shapes.rs)

pub fn require_fit(c: var Checker, ty: types.Ty, shape: int, span: diag.Span, why: str) = check_shapes.require_fit(&c, ty, shape, span, why)
/// Rust's `Result<(), String>`: `none` when `ty` fits, else the note saying why not.
pub fn fit(c: var Checker, ty: types.Ty, shape: int, m: int): str? = check_shapes.fit(&c, ty, shape, m)
pub fn missing_note(c: Checker, shape: int, ty: types.Ty): str = check_shapes.missing_note(c, shape, ty)
pub fn find_impl(c: var Checker, shape: int, ty: types.Ty, m: int): [(int, [types.Ty])]? = check_shapes.find_impl(&c, shape, ty, m)
pub fn monomorphize(c: var Checker) = check_shapes.monomorphize(&c)

/// Types, type definitions and the inference engine (src/types.rs): unification with snapshots.
///
/// A `Ty` is a plain tree. Nominal types (structs, enums and the opaque runtime types `Err` and
/// `net.Conn`) are `Named(DefId, args)`, indexing `Defs.types`. Type parameters (explicit
/// `<A: Show>` or implicit shape names used as types, `fn top(xs: [Ord])`) are `Param(ParamId)`
/// into `Defs.params`. During checking, unknown types are inference variables `Var(n)` owned by
/// an `Infer`; the checker resolves every type it records, so the typed program (typed.rs) never
/// contains a `Var`.
///
/// Rust's `DefId`, `ShapeId`, `ParamId` and `ModId` are `int`s here, and a unit of measure
/// (`Units`) is its canonical list `[(str, int)]` (units.auk). `walk` with a closure that
/// collects becomes `any_ty` (every use in Rust asks "is there a node that ...").

pub enum Ty {
  Int,
  Float,
  Bool,
  Char,
  Str,
  /// The type of `return`, `break`, `continue`, `fail(..)`, a panic or a loop without `break`:
  /// it converts to every type.
  Never,
  List(t: Ty),
  Map(k: Ty, v: Ty),
  /// `(A, B)`; the empty tuple is `()`, the unit type.
  Tuple(ts: [Ty]),
  /// `T?`
  Opt(t: Ty),
  /// `T!` (the error is the core `Err` type) or `T!E` (a user error enum).
  Res(t: Ty, e: Ty),
  /// A struct, enum or opaque runtime type, with its type arguments.
  Named(d: int, args: [Ty]),
  /// A type parameter of the enclosing generic function or type.
  Param(p: int),
  /// `any S`: a value of any type that fits shape `S`, dispatched through a vtable.
  Any(s: int),
  /// The type of a closure: `(A, B) => R`.
  Fn(ps: [Ty], r: Ty),
  /// The value of an un-awaited `async fn` call: a running task that yields `T`.
  Task(t: Ty),
  /// `float<m/s>`, `int<px>`: `Int` or `Float` with a non-empty unit of measure. Checked
  /// only: `erase_units` turns it back into the plain number type before codegen.
  Measured(t: Ty, u: [(str, int)]),
  /// `var T`: a `var` parameter of a function type (only there, as a parameter of `Fn`): the
  /// closure gets the caller's variable by reference.
  Mut(t: Ty),
  /// An inference variable (only during checking).
  Var(v: int),
  /// The type of an expression that already produced a diagnostic; it unifies with anything so
  /// one mistake doesn't cascade.
  Error,
}

pub fn unit(): Ty = Ty.Tuple([])

pub fn is_unit(t: Ty): bool = match t {
  Tuple(ts) => ts.len() == 0
  _ => false
}

pub fn list(t: Ty): Ty = Ty.List(t)

pub fn opt(t: Ty): Ty = Ty.Opt(t)

pub fn res(t: Ty, e: Ty): Ty = Ty.Res(t, e)

pub fn map(k: Ty, v: Ty): Ty = Ty.Map(k, v)

pub fn func(ps: [Ty], r: Ty): Ty = Ty.Fn(ps, r)

/// `base` with unit `u` (just `base` when `u` is dimensionless).
pub fn measured(base: Ty, u: [(str, int)]): Ty {
  let b = match base {
    Measured(b, _) => b
    b => b
  }
  if units.is_none(u) { b } else { Ty.Measured(b, u) }
}

/// The unit of a number type (dimensionless for anything without one).
pub fn units_of(t: Ty): [(str, int)] = match t {
  Measured(_, u) => u
  _ => []
}

/// The type without its unit at the top (`float<m>` -> `float`).
pub fn base(t: Ty): Ty = match t {
  Measured(b, _) => b
  t => t
}

/// Every unit of measure removed, deeply (`[float<m>]` -> `[float]`).
pub fn erase_units(t: Ty): Ty = map_ty(t, x => match x {
  Measured(b, _) => b
  x => x
})

pub fn has_units(t: Ty): bool = any_ty(t, x => x is Ty.Measured(_, _))

/// Does the type mention a type parameter?
pub fn has_params(t: Ty): bool = any_ty(t, x => x is Ty.Param(_))

pub fn has_vars(t: Ty): bool = any_ty(t, x => x is Ty.Var(_))

pub fn has_error(t: Ty): bool = any_ty(t, x => x is Ty.Error)

/// Is `pred` true of this type or any type inside it? (Rust's `walk` with a flag.)
pub fn any_ty(t: Ty, pred: (Ty) => bool): bool {
  if pred(t) { return true }
  for c in children(t) {
    if any_ty(c, pred) { return true }
  }
  false
}

pub fn children(t: Ty): [Ty] = match t {
  List(x) | Opt(x) | Task(x) | Measured(x, _) | Mut(x) => [x]
  Map(a, b) | Res(a, b) => [a, b]
  Tuple(ts) | Named(_, ts) => ts
  Fn(ps, r) => ps + [r]
  _ => []
}

/// Rebuild the type bottom-up through `f` (applied to every node after its children).
pub fn map_ty(t: Ty, f: (Ty) => Ty): Ty {
  let t2 = match t {
    List(x) => Ty.List(map_ty(x, f))
    Opt(x) => Ty.Opt(map_ty(x, f))
    Task(x) => Ty.Task(map_ty(x, f))
    Mut(x) => Ty.Mut(map_ty(x, f))
    Measured(x, u) => Ty.Measured(map_ty(x, f), u)
    Map(a, b) => Ty.Map(map_ty(a, f), map_ty(b, f))
    Res(a, b) => Ty.Res(map_ty(a, f), map_ty(b, f))
    Tuple(ts) => Ty.Tuple(ts.map(x => map_ty(x, f)))
    Named(d, ts) => Ty.Named(d, ts.map(x => map_ty(x, f)))
    Fn(ps, r) => Ty.Fn(ps.map(x => map_ty(x, f)), map_ty(r, f))
    t => t
  }
  f(t2)
}

/// Replace type parameters per `s`.
pub fn subst(t: Ty, s: {int: Ty}): Ty {
  if s.len() == 0 { return t }
  map_ty(t, x => match x {
    Param(p) => s.get(p) else Ty.Param(p)
    x => x
  })
}

/// A struct, enum or opaque type definition.
pub struct TypeDef {
  name: str,
  module: int,
  public: bool,
  doc: str?,
  /// Type parameters (`struct Set<T>`).
  params: [int],
  kind: TypeDefKind,
  span: diag.Span,
  node: int,
}

pub enum TypeDefKind {
  Struct(fields: [FieldDef]),
  Enum(variants: [VariantDef]),
  /// A runtime type declared with `extern type` in the prelude (`Err` is `AukErr *`,
  /// `net.Conn` is `AukConn *`).
  Opaque(c_type: str),
}

pub struct FieldDef {
  name: str,
  ty: Ty,
  /// Readable from other modules: the struct is `pub` and the field's type mentions no
  /// private type of the struct's module.
  public: bool,
  span: diag.Span,
}

pub struct VariantDef {
  name: str,
  /// Field names (`Circle(r: float)`) are optional (`Wrap(int)`).
  fields: [(str?, Ty)],
  span: diag.Span,
  node: int,
}

/// `shape Area { fn area(self): float }`. `self_param` stands for the fitting type (`Self`).
pub struct ShapeDef {
  name: str,
  module: int,
  public: bool,
  self_param: int,
  methods: [ShapeMethod],
  /// One of the built-in shapes, whose automatic instances the compiler derives.
  builtin: Builtin?,
  span: diag.Span,
}

pub struct ShapeMethod {
  name: str,
  /// Every parameter, `self` included (as `Param(self_param)`).
  params: [Ty],
  ret: Ty,
}

pub enum Builtin { Show, Ord, Eq, Data }

pub struct TypeParam {
  name: str,
  bounds: [int],
  /// An implicit parameter created for a shape name used as a type (`fn f(x: Show)`).
  implicit: bool,
}

/// Every definition, indexed by `DefId`, `ShapeId` and `ParamId`.
pub struct Defs { types: [TypeDef], shapes: [ShapeDef], params: [TypeParam] }

pub fn new_defs(): Defs = Defs { types: [], shapes: [], params: [] }

pub fn fields(defs: Defs, d: int): [FieldDef] = match defs.types[d].kind {
  Struct(fields) => fields
  _ => []
}

pub fn variants(defs: Defs, d: int): [VariantDef] = match defs.types[d].kind {
  Enum(variants) => variants
  _ => []
}

pub fn is_enum(defs: Defs, d: int): bool = defs.types[d].kind is TypeDefKind.Enum(_)

pub fn is_struct(defs: Defs, d: int): bool = defs.types[d].kind is TypeDefKind.Struct(_)

/// The substitution from a type definition's parameters to `args`.
pub fn subst_of(defs: Defs, d: int, args: [Ty]): {int: Ty} {
  var s: {int: Ty} = {}
  for (p, a) in defs.types[d].params.zip(args) { s[p] = a }
  s
}

/// Source-like rendering: `[int]`, `{str: Todo}`, `Resp!`, `any Show`, `(int) => str`.
pub fn show(defs: Defs, t: Ty): str {
  var out: [str] = []
  fmt(defs, t, &out)
  out.join("")
}

fn fmt(defs: Defs, t: Ty, out: var [str]) {
  match t {
    Int => out.push("int")
    Float => out.push("float")
    Bool => out.push("bool")
    Char => out.push("char")
    Str => out.push("str")
    Never => out.push("never")
    List(x) => {
      out.push("[")
      fmt(defs, x, &out)
      out.push("]")
    }
    Map(k, v) => {
      out.push("{{")
      fmt(defs, k, &out)
      out.push(": ")
      fmt(defs, v, &out)
      out.push("}}")
    }
    Tuple(ts) => {
      out.push("(")
      for i, x in ts {
        if i > 0 { out.push(", ") }
        fmt(defs, x, &out)
      }
      out.push(")")
    }
    Opt(x) => {
      fmt_inner(defs, x, &out)
      out.push("?")
    }
    Res(x, e) => {
      fmt_inner(defs, x, &out)
      out.push("!")
      if !is_err(defs, e) { fmt(defs, e, &out) }
    }
    Named(d, args) => {
      out.push(defs.types[d].name)
      if args.len() > 0 {
        out.push("<")
        for i, x in args {
          if i > 0 { out.push(", ") }
          fmt(defs, x, &out)
        }
        out.push(">")
      }
    }
    Param(p) => out.push(defs.params[p].name)
    Any(s) => out.push("any {defs.shapes[s].name}")
    Fn(ps, r) => {
      out.push("(")
      for i, x in ps {
        if i > 0 { out.push(", ") }
        fmt(defs, x, &out)
      }
      out.push(") => ")
      fmt(defs, r, &out)
    }
    Task(x) => {
      out.push("Task<")
      fmt(defs, x, &out)
      out.push(">")
    }
    Measured(x, u) => {
      fmt(defs, x, &out)
      out.push("<{units.text(u)}>")
    }
    Mut(x) => {
      out.push("var ")
      fmt(defs, x, &out)
    }
    Var(_) => out.push("_")
    Error => out.push("{{error}}")
  }
}

/// `T?` and `T!` bind tighter than `=>` but a closure type inside needs parentheses.
fn fmt_inner(defs: Defs, t: Ty, out: var [str]) {
  if t is Ty.Fn(_, _) {
    out.push("(")
    fmt(defs, t, &out)
    out.push(")")
  } else {
    fmt(defs, t, &out)
  }
}

/// Is `t` the core `Err` type?
pub fn is_err(defs: Defs, t: Ty): bool = match t {
  Named(d, _) => defs.types[d].name == "Err" && defs.types[d].kind is TypeDefKind.Opaque(_)
  _ => false
}

/// Inference variables with a trail, so a tentative unification can be undone.
pub struct Infer { vars: [Ty?], trail: [int] }

pub fn new_infer(): Infer = Infer { vars: [], trail: [] }

pub fn fresh(inf: var Infer): Ty {
  inf.vars.push(none)
  Ty.Var(inf.vars.len() - 1)
}

pub fn snapshot(inf: Infer): int = inf.trail.len()

pub fn rollback(inf: var Infer, snap: int) {
  while inf.trail.len() > snap {
    let v = inf.trail.pop() else 0
    inf.vars[v] = none
  }
}

/// Follow bound variables at the top only.
pub fn shallow(inf: Infer, t: Ty): Ty {
  var t2 = t
  loop {
    match t2 {
      Var(v) => match inf.vars[v] {
        some(b) => t2 = b
        none => return t2
      }
      _ => return t2
    }
  }
}

/// Substitute every bound variable, deeply.
pub fn resolve(inf: Infer, t: Ty): Ty = map_ty(t, x => match x {
  Var(v) => match inf.vars[v] {
    some(b) => resolve(inf, b)
    none => Ty.Var(v)
  }
  x => x
})

fn bind(inf: var Infer, v: int, t: Ty) {
  inf.vars[v] = t
  inf.trail.push(v)
}

fn occurs(inf: Infer, v: int, t: Ty): bool = any_ty(resolve(inf, t), x => x == Ty.Var(v))

/// Make `a` and `b` equal. `Never` and `Error` are compatible with anything (and bind
/// nothing). On failure some variables may already be bound: callers that want an
/// all-or-nothing attempt use `try_unify`.
pub fn unify(inf: var Infer, a: Ty, b: Ty): bool {
  let a2 = shallow(inf, a)
  let b2 = shallow(inf, b)
  match (a2, b2) {
    (Error, _) | (_, Error) | (Never, _) | (_, Never) => true
    (Var(x), Var(y)) when x == y => true
    // `var T` is only a function type's parameter: no type variable stands for it
    (Var(_), Mut(_)) | (Mut(_), Var(_)) => false
    (Var(x), t) | (t, Var(x)) => {
      if occurs(inf, x, t) { return false }
      bind(&inf, x, t)
      true
    }
    (List(x), List(y)) | (Opt(x), Opt(y)) | (Task(x), Task(y)) | (Mut(x), Mut(y)) =>
      unify(&inf, x, y)
    (Measured(x, u), Measured(y, v)) => u == v && unify(&inf, x, y)
    (Map(a1, b1), Map(a2, b2)) | (Res(a1, b1), Res(a2, b2)) =>
      unify(&inf, a1, a2) && unify(&inf, b1, b2)
    (Tuple(xs), Tuple(ys)) => xs.len() == ys.len() && unify_all(&inf, xs, ys)
    (Named(d1, xs), Named(d2, ys)) => d1 == d2 && xs.len() == ys.len() && unify_all(&inf, xs, ys)
    (Fn(p1, r1), Fn(p2, r2)) =>
      p1.len() == p2.len() && unify_all(&inf, p1, p2) && unify(&inf, r1, r2)
    (x, y) => x == y
  }
}

/// `xs.iter().zip(ys).all(|(x, y)| self.unify(x, y))`: stops at the first failure.
fn unify_all(inf: var Infer, xs: [Ty], ys: [Ty]): bool {
  for i, x in xs {
    if !unify(&inf, x, ys[i]) { return false }
  }
  true
}

/// Unify, or leave every variable as it was.
pub fn try_unify(inf: var Infer, a: Ty, b: Ty): bool {
  let snap = snapshot(inf)
  if unify(&inf, a, b) {
    true
  } else {
    rollback(&inf, snap)
    false
  }
}

/// Could `a` and `b` unify? Binds nothing.
pub fn can_unify(inf: var Infer, a: Ty, b: Ty): bool {
  let snap = snapshot(inf)
  let ok = unify(&inf, a, b)
  rollback(&inf, snap)
  ok
}

test "unify and rollback" {
  var inf = new_infer()
  let a = fresh(&inf)
  let b = fresh(&inf)
  assert unify(&inf, list(a), list(Ty.Int))
  assert resolve(inf, a) == Ty.Int
  let snap = snapshot(inf)
  assert unify(&inf, b, Ty.Str)
  rollback(&inf, snap)
  assert resolve(inf, b) == b
  assert !try_unify(&inf, Ty.Tuple([b, Ty.Int]), Ty.Tuple([Ty.Str, Ty.Bool]))
  // a failed try_unify binds nothing
  assert resolve(inf, b) == b
  // occurs check
  assert !unify(&inf, b, list(b))
  assert unify(&inf, Ty.Never, Ty.Str)
}

test "show types" {
  let d = new_defs()
  assert show(d, map(Ty.Str, list(opt(Ty.Int)))) == "{{str: [int?]}}"
  assert show(d, func([Ty.Int], Ty.Bool)) == "(int) => bool"
  assert show(d, unit()) == "()"
  assert show(d, Ty.Measured(Ty.Float, [("m", 1), ("s", -2)])) == "float<m/s^2>"
}

/// The typed program (src/typed.rs): everything codegen needs to lower Auk without redoing
/// analysis. See the Rust module's docs for how to read it: codegen walks the AST
/// (`program.mods[m].ast`) and looks every node up in the per-module side tables (`Tables`),
/// keyed by node id.
///
/// Differences from Rust: ids (`FnId`, `ConstId`, `TestId`, `LocalId`, `InstId`, `VtableId`,
/// `DefId`, `ShapeId`, `ParamId`, `ModId`, `NodeId`) are `int`s; `HashMap<NodeId, X>` is
/// `{int: X}`; Rust's `BTreeSet<NodeId>` is `{int: bool}` (dumps sort the keys); the ordered
/// `types_used` set is a list kept sorted by `types.cmp`, with a membership map;
/// `BTreeMap<(Builtin, Ty), Target>` is `{(types.Builtin, types.Ty): Target}` (its iteration
/// order is never used by the checker); struct-like variants are positional.

pub struct TypedProgram {
  program: resolve.Program,
  defs: types.Defs,
  fns: [FnInfo],
  consts: [ConstInfo],
  tests: [TestInfo],
  /// Side tables per module (index = module id).
  tables: [Tables],
  instances: [Instance],
  /// Sorted by `types.cmp` (Rust's `BTreeSet<Ty>`).
  types_used: [types.Ty],
  shape_impls: {(types.Builtin, types.Ty): Target},
  from_value_impls: {types.Ty: Target},
  vtables: [Vtable],
  main: MainInfo?,
  /// The runtime's dialect: `raw var`, `raw thread var`, `raw let`, `export var`.
  globals: [GlobalInfo],
}

/// A global of the runtime's dialect, with its initializer evaluated at compile time.
pub struct GlobalInfo {
  name: str,
  module: int,
  public: bool,
  /// As `ast.GlobalDef.kind`: 0 `raw var`, 1 `raw thread var`, 2 `raw let`, 3 `export var`, 4
  /// `extern var`.
  kind: int,
  /// The C symbol of an `extern var` ("" otherwise).
  c_name: str,
  ty: types.Ty,
  value: ConstVal,
  span: diag.Span,
}

/// A compile-time constant of the runtime's dialect.
pub enum ConstVal {
  Int(n: int),
  Float(x: float),
  /// All zero bytes (`raw.null()`, a raw struct literal without fields).
  Zero,
  /// A raw struct literal: (field index, value).
  Agg(fields: [(int, ConstVal)]),
}

/// One function: a clause group after splitting by first-parameter type.
pub struct FnInfo {
  name: str,
  module: int,
  public: bool,
  is_async: bool,
  doc: str?,
  /// Type parameters: explicit (`<A: Show>`) then implicit ones from shape names used as types.
  generics: [int],
  params: [ParamInfo],
  ret: types.Ty,
  /// `uses` effects as written (Rust's `uses`; a keyword can't be a field name).
  effects: [str],
  kind: FnKind,
  /// The span of the name in the first clause (or header).
  span: diag.Span,
  /// Functions called directly from the body (Rust's `BTreeSet<FnId>`: kept sorted, no
  /// duplicates).
  callees: [int],
  /// `old(e)` expressions in `ensures`, captured at entry.
  olds: [int],
  /// The local bound to `result` in `ensures`, if any.
  result_local: int?,
  /// The runtime's dialect: 1 `export fn`, 2 `inline export fn`, 0 otherwise.
  export: int,
}

pub struct ParamInfo {
  /// The bare name if every clause binds this parameter to the same plain name.
  name: str?,
  ty: types.Ty,
  /// A `var` parameter.
  var_: bool,
}

pub enum FnKind {
  /// Auk code: the clause group `program.mods[module].ast.items[item]`, clauses `clauses`;
  /// `header`: the group's header line belongs to this function.
  Auk(item: int, clauses: [int], header: bool),
  /// A C function of the runtime. `loc` = append the call site's "file:line:col".
  Extern(symbol: str, loc: bool, item: int),
  /// A user C function (`extern fn` with a C prototype).
  Ffi(sig: cffi.CSig, convs: [cffi.Conv], item: int),
  /// Implemented by the compiler.
  Intrinsic(which: Intrinsic, item: int),
}

/// Compiler intrinsics declared in the prelude with an `@` symbol. `Raw(name)`: `@raw_<name>`,
/// the runtime's dialect (compiler/prelude/raw.auk).
pub enum Intrinsic { Show, Eq, Cmp, ToValue, FromValue, Some, Fail, IntToFloat, CharToInt, Raw(name: str) }

pub fn intrinsic_from_symbol(s: str): Intrinsic? = match s.strip_prefix("@raw_") {
  some(n) => Intrinsic.Raw(n)
  none => builtin_intrinsic(s)
}

fn builtin_intrinsic(s: str): Intrinsic? = match s {
  "@show" => Intrinsic.Show
  "@eq" => Intrinsic.Eq
  "@cmp" => Intrinsic.Cmp
  "@to_value" => Intrinsic.ToValue
  "@from_value" => Intrinsic.FromValue
  "@some" => Intrinsic.Some
  "@fail" => Intrinsic.Fail
  "@int_to_float" => Intrinsic.IntToFloat
  "@char_to_int" => Intrinsic.CharToInt
  _ => none
}

/// Rust's `{which:?}`.
pub fn intrinsic_name(i: Intrinsic): str = match i {
  Show => "Show"
  Eq => "Eq"
  Cmp => "Cmp"
  ToValue => "ToValue"
  FromValue => "FromValue"
  Some => "Some"
  Fail => "Fail"
  IntToFloat => "IntToFloat"
  CharToInt => "CharToInt"
  Raw(n) => "Raw({n})"
}

/// What a node of the runtime's dialect does (docs/lowlevel.md), beyond its call.
pub enum RawNode {
  /// `u8(x)`, `int(x)`, `bool(x)`, ...: a numeric conversion to `to`.
  Conv(to: types.Ty),
  /// `raw.field_addr(p, .f)` / `raw.offset_of<T>(.f)`: field `i` of the raw struct `d`.
  Field(d: int, i: int),
  /// `raw.fn_of(f)`: the C address of the function its argument names.
  FnOf,
  /// `f(x)` with `f: raw.Fn<...>`: a call through a C function pointer.
  CallFn,
  /// `p.f` with `p: raw.Ptr<S>`: memory read or written through a pointer (needs `uses raw`).
  Deref,
}

pub struct ConstInfo {
  name: str,
  module: int,
  public: bool,
  /// `imprint X = e`.
  imprint: bool,
  ty: types.Ty,
  item: int,
  span: diag.Span,
}

pub struct TestInfo { name: str, module: int, item: int, span: diag.Span }

/// Which body an instance is for.
pub enum BodyRef { Fn(f: int), Test(t: int), Const(c: int) }

/// A body to emit, with concrete type arguments for a generic function.
pub struct Instance {
  body: BodyRef,
  type_args: [types.Ty],
  resolved: {int: Target},
  shows: {int: Target},
  vtables: {int: int},
}

/// The substitution to apply to every type in this body's tables.
pub fn inst_subst(i: Instance, fns: [FnInfo]): {int: types.Ty} {
  var s: {int: types.Ty} = {}
  match i.body {
    Fn(f) => for (g, a) in fns[f].generics.zip(i.type_args) { s[g] = a }
    _ => {}
  }
  s
}

/// A concrete call target.
pub enum Target {
  Instance(i: int),
  Extern(symbol: str, loc: bool),
  Ffi(f: int),
  Intrinsic(which: Intrinsic, ty: types.Ty),
  Derived(shape: types.Builtin, ty: types.Ty),
  Vtable(shape: int, method: int),
  Variant(def: int, index: int),
  Closure,
}

/// The implementation of every method of a shape for one type, for `any Shape`.
pub struct Vtable { shape: int, ty: types.Ty, methods: [Target] }

pub struct MainInfo {
  func: int,
  /// `fn main(args: [str])`.
  takes_args: bool,
  /// `()`, `int`, `()!` or `int!`.
  ret: types.Ty,
}

/// Per-module side tables (see src/typed.rs).
pub struct Tables {
  types: {int: types.Ty},
  coercions: {int: [Coercion]},
  names: {int: NameRef},
  binds: {int: int},
  locals: [LocalInfo],
  variants: {int: VariantRef},
  calls: {int: Call},
  /// Field reads `x.f` on structs: (struct, field index).
  fields: {int: (int, int)},
  struct_lits: {int: StructLit},
  struct_pats: {int: StructPat},
  closures: {int: ClosureInfo},
  tries: {int: TryInfo},
  fails: {int: FailKind},
  elses: {int: ElseInfo},
  opt_chains: {int: OptChainInfo},
  awaits: {int: AwaitKind},
  fors: {int: ForKind},
  formats: {int: FormatSpec},
  shows: {int: Callee},
  /// Map patterns matched against a `Value` (Rust's `BTreeSet<NodeId>`).
  value_map_pats: {int: bool},
  err_payload_pats: {int: types.Ty},
  /// Interpolation parts whose value has a unit of measure: the unit's text.
  units: {int: str},
  /// Nodes of the runtime's dialect (conversions, ...).
  raw: {int: RawNode},
}

pub fn new_tables(): Tables = Tables {
  types: {},
  coercions: {},
  names: {},
  binds: {},
  locals: [],
  variants: {},
  calls: {},
  fields: {},
  struct_lits: {},
  struct_pats: {},
  closures: {},
  tries: {},
  fails: {},
  elses: {},
  opt_chains: {},
  awaits: {},
  fors: {},
  formats: {},
  shows: {},
  value_map_pats: {},
  err_payload_pats: {},
  units: {},
  raw: {},
}

pub enum Coercion {
  /// `T` -> `T?`
  WrapSome,
  /// `T` -> `T!` / `T!E`
  WrapOk,
  /// A concrete type -> `any S`.
  ToAny(s: int),
}

pub enum NameRef {
  Local(l: int),
  Const(c: int),
  /// A function used as a value.
  Fn(func: int, type_args: [types.Ty]),
  /// A field-less variant value, or a variant constructor used as a function value.
  Variant(v: VariantRef),
  /// `none`.
  None,
  /// The runtime's dialect: a `raw var` / `raw let` / ... global.
  Global(g: int),
}

pub struct VariantRef { def: int, index: int, args: [types.Ty] }

pub struct LocalInfo { name: str, ty: types.Ty, mutable: bool, span: diag.Span }

pub struct Call { callee: Callee, args: [Arg] }

pub struct Arg {
  node: int,
  /// Passed to a `var` parameter: by address.
  by_ref: bool,
}

pub enum Callee {
  /// A function with type arguments for its `generics`.
  Fn(func: int, type_args: [types.Ty]),
  /// An enum variant constructor.
  Variant(v: VariantRef),
  /// A closure value.
  Closure,
  /// A shape method on a type parameter (or a derived operator): resolved per instance.
  Shape(shape: int, method: int, self_ty: types.Ty),
  /// A method of an `any S` value: dynamic dispatch.
  Vtable(shape: int, method: int),
}

pub struct StructLit {
  def: int,
  args: [types.Ty],
  /// (field index, value) per field written, in source order.
  fields: [(int, FieldValue)],
}

pub enum FieldValue {
  Expr(node: int),
  Local(l: int, cs: [Coercion]),
}

pub struct StructPat {
  def: int,
  /// Per field pattern in source order: (field index, shorthand binding if `{ name }`).
  fields: [(int, int?)],
}

pub struct ClosureInfo {
  params: [types.Ty],
  ret: types.Ty,
  /// Captured locals.
  captures: [int],
  /// Written with n parameters where one n-tuple is passed: unpack the tuple.
  unpack: bool,
}

pub struct TryInfo { kind: TryKind, conv: ErrConv }

pub enum TryKind { Result, Option, ListResult, ListOption }

/// How an error passes up through `?`.
pub enum ErrConv {
  None,
  /// A typed error enum becomes an `Err`.
  ToErr(from: types.Ty),
}

pub enum FailKind {
  Message,
  Err,
  Typed,
  TypedToErr(t: types.Ty),
}

pub struct ElseInfo {
  kind: ElseKind,
  /// `else e => ...`: the error.
  binder: int?,
}

pub enum ElseKind {
  Option,
  Result,
  Refutable,
  UnwrapRefutable(option: bool),
}

pub struct OptChainInfo { flatten: bool }

pub enum AwaitKind { Direct, Task, Tuple, List }

pub enum ForKind {
  Range(inclusive: bool),
  List,
  Map,
  Chan,
}

/// A parsed `{x:spec}`: `[fill? align] ['0'] [width] ['.' precision] [x X o b]`.
pub struct FormatSpec {
  text: str,
  fill: char?,
  align: char?,
  zero: bool,
  width: int?,
  precision: int?,
  radix: char?,
}

/// Invariants codegen relies on (src/typed.rs `validate`): no inference variables or error
/// types anywhere in the tables, every call node of an emitted instance resolved. Returns the
/// violations (a table's nodes in id order).
pub fn validate(tp: TypedProgram): [str] {
  var out: [str] = []
  let bad = (t: types.Ty) => types.has_vars(t) || types.has_error(t)
  for m, t in tp.tables {
    let file = tp.program.mods[m].file
    for n in t.types.keys().sort() {
      let ty = t.types[n]
      if bad(ty) { out.push("{file}: node {n} has type {types.show(tp.defs, ty)}") }
    }
    for i, l in t.locals {
      if bad(l.ty) { out.push("{file}: local {i} `{l.name}` has type {types.show(tp.defs, l.ty)}") }
    }
    for n in t.calls.keys().sort() {
      match t.calls[n].callee {
        Fn(_, type_args) when type_args.any(bad) =>
          out.push("{file}: call {n} has unresolved type arguments")
        _ => {}
      }
    }
  }
  for i, inst in tp.instances {
    if inst.type_args.any(t => bad(t) || types.has_params(t)) {
      out.push("instance {i} has non-concrete type arguments")
    }
  }
  for f in tp.fns {
    if f.params.any(p => bad(p.ty)) || bad(f.ret) { out.push("fn {f.name} has a bad signature") }
  }
  out
}

/// A readable summary for debugging (`auk typed <file>`, src/typed.rs `dump`): every non-core
/// function with its signature, then the instances to emit (each line ends in `\n`).
pub fn dump(tp: TypedProgram): str {
  var s: [str] = []
  let d = tp.defs
  for f in tp.fns {
    if tp.program.is_core(f.module) { continue }
    let ps = f.params.map(p => "{if p.var_ { "var " } else { "" }}{types.show(d, p.ty)}")
    let gs = f.generics.map(g => d.params[g].name)
    let g = if gs.len() == 0 { "" } else { "<{gs.join(", ")}>" }
    let a = if f.is_async { "async " } else { "" }
    let kind = match f.kind {
      Auk(_, clauses, _) => "{clauses.len()} clause(s)"
      Extern(symbol, _, _) => "extern {symbol}"
      Ffi(sig, _, _) => "extern C {sig.name}"
      Intrinsic(which, _) => "intrinsic {intrinsic_name(which)}"
    }
    s.push("fn {tp.program.name(f.module)}.{a}{f.name}{g}({ps.join(", ")}): {types.show(d, f.ret)} [{kind}]\n")
  }
  for i, inst in tp.instances {
    let what = match inst.body {
      Fn(f) => "{tp.program.name(tp.fns[f].module)}.{tp.fns[f].name}"
      Test(t) => "test {ast_dump.debug_str(tp.tests[t].name)}"
      Const(c) => "const {tp.consts[c].name}"
    }
    if inst.type_args.len() > 0 {
      s.push("instance {i}: {what}<{inst.type_args.map(t => types.show(d, t)).join(", ")}>\n")
    }
  }
  s.push("{tp.instances.len()} instances, {tp.types_used.len()} concrete types, {tp.shape_impls.len()} shape impls, {tp.vtables.len()} vtables\n")
  s.join("")
}

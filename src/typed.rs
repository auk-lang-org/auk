//! The typed program: everything codegen needs to lower Duck to C without redoing analysis.
//!
//! # How to read it (for the codegen author)
//!
//! The checker does not build a second tree. Codegen walks the **AST** (`program.mods[m].ast`)
//! and looks every node up in **side tables** keyed by `NodeId`. NodeIds are unique per file, so
//! each module has its own `Tables` (`TypedProgram::tables[m]`). What the program contains:
//!
//! - `program`: the module tree and the ASTs (resolve.rs). Module 0.. are the core prelude.
//! - `defs`: struct, enum, opaque and shape definitions, and type parameters (types.rs).
//! - `fns`: every function, one per *clause group after overload splitting* (`FnInfo`): its
//!   signature, where its clauses are in the AST, and whether it is Duck code, an `extern` C
//!   function or a compiler intrinsic.
//! - `consts`, `tests`: top-level `let` / `imprint` constants and `test` blocks.
//! - `instances`: the **monomorphized bodies to emit** (`Instance`): every non-generic Duck
//!   function, every test and constant initializer, and every generic function at each concrete
//!   type-argument list reachable from those. An instance's `resolved` maps every call and
//!   operator node (and function-valued name) in its body to a concrete `Target`, `shows` does
//!   the same for interpolation parts and `peek` operands, and `vtables` gives the vtable of each
//!   conversion to `any S`. Codegen emits exactly the instances in this list (tests of
//!   dependencies included; filter by module for `duck test` without `--deps`).
//! - `types_used`: every concrete type that appears in an emitted instance (after substitution),
//!   closed under components, so codegen can declare its C representation up front.
//! - `shape_impls`: for every (built-in shape, concrete type) pair that something needs, how it
//!   is implemented: a user function instance (including a private one in the type's own
//!   module, like `fn cmp(a: Item, b: Item)` next to `struct Item`, even when the need comes from
//!   generic code elsewhere) or a compiler-derived instance. This is what
//!   `DuckElemOps.eq/cmp/show` of a container element and derived `to_value`/`from_value` use.
//!   Primitives (`int float bool char str`) aren't listed: use the runtime's `duck_ops_*`.
//!   Derived `Show` prints `Point { x: 1.0, y: 2.0 }` / `Circle(2.0)`; inside a container,
//!   strings and chars are shown quoted (runtime "debug form"), at top level a `str` shows as
//!   itself.
//! - `vtables`: one per (shape, concrete type) coerced to `any Shape`.
//! - `main`: the entry point and its signature.
//!
//! ## Types in tables
//! Every expression has `tables.types[expr.id]`: its type *before* the implicit conversions in
//! `tables.coercions[expr.id]`, which codegen applies in order to get the value the context
//! wants (auto-wrap into `T?`/`T!`, conversion to `any S`). Every pattern has
//! `tables.types[pat.id]`: the type of the value it matches. Every parameter's type is in
//! `tables.types[param.id]`. Inside a generic function these types mention `Ty::Param`; an
//! `Instance` gives the substitution (`Instance::subst`). No table contains `Ty::Var`.
//!
//! Expression forms whose meaning follows from the AST plus the operand types (codegen decides
//! by type): arithmetic and comparison operators on `int`/`float`/`char`/`bool`/`str` (`+` on
//! `str` and `[T]` concatenates; `==` and `<` on primitives); `x[i]` on `[T]` (element), `{K: V}`
//! (value, panics if missing) and `str` (char); slices; `!x` / `-x`; `if`/`while`/`loop`/`match`/
//! `for` (see `fors`); list, map and tuple literals (an empty map literal `{}` whose type is `()`
//! is an empty block, as in `_ => {}`); ranges (in `for` heads and slices, or as a
//! materialized `[int]` elsewhere); `x is pat`; `peek e` (prints `[file:line] <src> = <show>`,
//! see `shows` for the show); holes (`duck_hole`, with `tables.types[hole.id]` as the expected
//! type); `assert`. Runtime representations follow duck.h: `T?` is `DuckOpt_*`, `T!`/`T!E` is
//! `DuckRes_*` (a typed error enum value travels as a `DuckErr` payload), `Ty::Task` is a
//! `DuckTask *`, closures are `DuckClosure`, `Err` / `net.Conn` are their `extern type` C types.
//!
//! ## Names
//! `tables.names[expr.id]` for every `Name` expression, and for a `Field`/path expression that
//! names an item (`json.MAX`, `Shape.Circle`): a local (parameter, `let`, pattern binding, closure
//! parameter, `else e =>` binder, `result` in `ensures`), a global constant, a function used as
//! a value, an enum variant, or `none`.
//! `tables.binds[pat.id]` is the local a `Bind` pattern (or a parameter's bare name) introduces;
//! `tables.locals[id]` describes it (name, type, mutable). Struct-pattern shorthand fields
//! (`User { name, .. }`) and struct-literal shorthand (`Point { x, y }`) are in `struct_pats` /
//! `struct_lits`. A bare name in a pattern that resolved to a variant (`Eof`, `Quoted`) is in
//! `tables.variants[pat.id]` instead of `binds`.
//!
//! ## Calls
//! `tables.calls[node]` for every `Call`, `MethodCall` (`x.f(a)` is `f(x, a)`: args start with
//! the receiver), `Pipe` (`x |> f(a)`: args start with `x`), `OptChain` with arguments, and every
//! operator node that calls a function (user `add`/`sub`/`mul`/`div`/`mod`/`eq`/`cmp`, or `==`/`<`
//! on a non-primitive type via the `Eq`/`Ord` shape). The `Callee` is the *generic* view; the
//! instance's `resolved[node]` is the concrete `Target`. `Arg::by_ref` marks a `var` parameter:
//! pass the caller's place by address (`&x`, or a dot-call receiver).
//! On an operator node the call implements the operator: for `==` / `!=` it is an `eq` (`Eq`)
//! returning `bool` (negate it for `!=`); for `<` `<=` `>` `>=` it is a `cmp` (`Ord`) returning
//! an `int` to compare with 0; for `+ - * / %` (and `+=` etc.) it is the user's `add`/`sub`/`mul`/
//! `div`/`mod`, whose result is the operator's value. Its `args` are the two operand nodes.
//! An `async fn` call whose type is `Task<T>` spawns a task; under `await` it is a direct call
//! (`awaits[node] == AwaitKind::Direct`).
//! `path.module(...)` calls (`json.parse(s)`, `fs.read(p)`) are ordinary `Call`s to that module's
//! function: `MethodCall` nodes whose receiver is a module path are resolved as path calls.
//!
//! ## Implicit operations made explicit
//! - `coercions`: auto-wrap (`T` -> `T?` / `T!`), `ToAny` (a vtable), in order.
//! - `tries[node]` for postfix `?`: on `T!`/`T!E`, on `T?`, or on a list of them (`[T!]?` gives
//!   `[T]` or the first error), with the error conversion to apply when the error passes up
//!   (`ErrConv::ToErr` wraps a typed error enum into an `Err` with a typed payload so
//!   `err(BadUrl(w))` still matches; see `DuckErrPayload`).
//! - `fails[call.id]`: what `fail(e)` returns (message -> `Err`, `Err`, typed error, or typed
//!   error converted to `Err`).
//! - `elses[node]` for `e else x` / `e else err => x`, and for `let pat = e else ...`
//!   (`LetElse`).
//! - `opt_chains[node]` for `x?.f` / `x?.f(a)`: whether the result is flattened (`T??` -> `T?`).
//!   For `x?.f(a)` the call in `calls[node]` takes the *unwrapped* value of `x` as its first
//!   argument (its recorded type is still `T?`); `x?.f` reads field `fields[node]` of it.
//! - `awaits[node]` for `await`.
//! - `fors[node]`: range, list or map iteration.
//! - `formats[part_expr.id]`: a parsed `{x:spec}` format spec for interpolation (the part's value
//!   is shown with `shows[part_expr.id]` when it is not a primitive, then padded per the spec;
//!   primitives use `duck_fmt_int/float/str/char/bool`).
//! - `value_map_pats` / `err_payload_pats`: map patterns that match a `Value.Map`, and `err(..)`
//!   patterns that match the typed payload of a plain `Err`.
//! - Contracts: `FnInfo::olds` lists the `old(e)` expressions to capture at entry; `result` in
//!   `ensures` is the local `FnInfo::result_local` (the success value `T` of a `T!`/`T!E`
//!   function, checked on successful returns; otherwise the return value).
//!
//! ## Effects
//! Effects are checked by effects.rs, after this phase: `FnInfo::uses` is each function's
//! declared `uses`, `FnInfo::callees` its direct callees, and `Instance::resolved` the concrete
//! call graph (shape methods and generic instances resolved). `resolve::Package::effects` is each
//! package's manifest ceiling.

use std::collections::{BTreeMap, BTreeSet, HashMap};

use super::ast::NodeId;
use super::diag::Span;
use super::resolve::{ModId, Program};
use super::types::{Builtin, DefId, Defs, ParamId, ShapeId, Ty};

pub type FnId = usize;
pub type ConstId = usize;
pub type TestId = usize;
pub type LocalId = usize;
pub type InstId = usize;
pub type VtableId = usize;

pub struct TypedProgram {
    pub program: Program,
    pub defs: Defs,
    pub fns: Vec<FnInfo>,
    pub consts: Vec<ConstInfo>,
    pub tests: Vec<TestInfo>,
    /// Side tables per module (index = `ModId`).
    pub tables: Vec<Tables>,
    pub instances: Vec<Instance>,
    pub types_used: BTreeSet<Ty>,
    pub shape_impls: BTreeMap<(Builtin, Ty), Target>,
    /// User `from_value` functions for types whose derived `from_value` must not be used: a
    /// type listed here, as a `from_value` target or a field or element of a derived one, is
    /// read by that function (the inverse of a user `to_value` in `shape_impls`).
    pub from_value_impls: BTreeMap<Ty, Target>,
    pub vtables: Vec<Vtable>,
    pub main: Option<MainInfo>,
}

/// One function: a clause group after splitting by first-parameter type (overloads like
/// `show(i: Item)` / `show(o: Order)` are separate `FnInfo`s).
#[derive(Debug, Clone)]
pub struct FnInfo {
    pub name: String,
    pub module: ModId,
    pub public: bool,
    pub is_async: bool,
    pub doc: Option<String>,
    /// Type parameters: explicit (`<A: Show>`) then implicit ones from shape names used as types
    /// (`fn top(xs: [Ord])` has one parameter named `Ord` bounded by `Ord`).
    pub generics: Vec<ParamId>,
    pub params: Vec<ParamInfo>,
    pub ret: Ty,
    /// `uses` effects as written (checked by effects.rs).
    pub uses: Vec<String>,
    pub kind: FnKind,
    /// The span of the name in the first clause (or header).
    pub span: Span,
    /// Functions called directly from the body (generic view; the concrete graph is in
    /// `Instance::resolved`).
    pub callees: BTreeSet<FnId>,
    /// `old(e)` expressions in `ensures`, captured at entry (in clause order).
    pub olds: Vec<NodeId>,
    /// The local bound to `result` in `ensures`, if any.
    pub result_local: Option<LocalId>,
}

#[derive(Debug, Clone)]
pub struct ParamInfo {
    /// The bare name if every clause binds this parameter to the same plain name, else none
    /// (codegen names it `pN` and each clause's pattern destructures it).
    pub name: Option<String>,
    pub ty: Ty,
    /// A `var` parameter: passed by address, mutations are visible to the caller.
    pub var: bool,
}

#[derive(Debug, Clone)]
pub enum FnKind {
    /// Duck code: the AST group is `program.mods[module].ast.items[item]` (an `Item::Fn`), and
    /// this function is the clauses at `clauses` (indices into `FnGroup::clauses`), tried top to
    /// bottom. `header` says whether the group's header line belongs to this function.
    Duck { item: usize, clauses: Vec<usize>, header: bool },
    /// A C function of the runtime. `loc` = append the call site's "file:line:col".
    Extern { symbol: String, loc: bool, item: usize },
    /// Implemented by the compiler.
    Intrinsic { which: Intrinsic, item: usize },
}

/// Compiler intrinsics declared in the prelude with an `@` symbol.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Intrinsic {
    /// `show(x)`: the `Show` text, via `shape_impls[(Show, T)]`.
    Show,
    /// `eq(a, b)`, via `shape_impls[(Eq, T)]`.
    Eq,
    /// `cmp(a, b)`, via `shape_impls[(Ord, T)]`.
    Cmp,
    /// `to_value(x)`: derived per type (structs as `Map` keyed by field name, enums as
    /// `Map {"tag": Str(variant), ...fields}` or a bare `Str(variant)` when field-less).
    ToValue,
    /// `from_value(v): T!`: the inverse; an `Int` fills a `float` field. `T` is the type
    /// argument.
    FromValue,
    /// `some(x)`: wrap into `T?`.
    Some,
    /// `fail(e)`: see `Tables::fails`; never returns.
    Fail,
    /// `float(n)` for an int: a C cast.
    IntToFloat,
    /// `int(c)` for a char: its code point.
    CharToInt,
}

impl Intrinsic {
    pub fn from_symbol(s: &str) -> Option<Intrinsic> {
        Some(match s {
            "@show" => Intrinsic::Show,
            "@eq" => Intrinsic::Eq,
            "@cmp" => Intrinsic::Cmp,
            "@to_value" => Intrinsic::ToValue,
            "@from_value" => Intrinsic::FromValue,
            "@some" => Intrinsic::Some,
            "@fail" => Intrinsic::Fail,
            "@int_to_float" => Intrinsic::IntToFloat,
            "@char_to_int" => Intrinsic::CharToInt,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone)]
pub struct ConstInfo {
    pub name: String,
    pub module: ModId,
    pub public: bool,
    /// `imprint X = e`: evaluated at compile time (effects.rs checks purity, check.rs that the
    /// type fits `Data`; build.rs `eval_imprints` computes it).
    pub imprint: bool,
    pub ty: Ty,
    /// `program.mods[module].ast.items[item]`.
    pub item: usize,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct TestInfo {
    pub name: String,
    pub module: ModId,
    pub item: usize,
    pub span: Span,
}

/// Which body an instance is for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum BodyRef {
    Fn(FnId),
    Test(TestId),
    Const(ConstId),
}

/// A body to emit, with concrete type arguments for a generic function.
#[derive(Debug, Clone)]
pub struct Instance {
    pub body: BodyRef,
    /// The function's `generics`, in order (empty for non-generic bodies).
    pub type_args: Vec<Ty>,
    /// Concrete targets of every call and operator node in the body (closures inside included):
    /// the nodes of `Tables::calls`, plus every `Name` node that uses a function as a value
    /// (`NameRef::Fn`).
    pub resolved: HashMap<NodeId, Target>,
    /// The `Show` implementation for each interpolation part / `peek` operand in
    /// `Tables::shows`.
    pub shows: HashMap<NodeId, Target>,
    /// Vtables for `Coercion::ToAny` nodes in this body.
    pub vtables: HashMap<NodeId, VtableId>,
}

impl Instance {
    /// The substitution to apply to every type in this body's tables.
    pub fn subst(&self, fns: &[FnInfo]) -> HashMap<ParamId, Ty> {
        match self.body {
            BodyRef::Fn(f) => fns[f].generics.iter().copied().zip(self.type_args.iter().cloned()).collect(),
            _ => HashMap::new(),
        }
    }
}

/// A concrete call target.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub enum Target {
    /// Call the emitted instance.
    Instance(InstId),
    /// Call a runtime C function (`loc`: append the call site location).
    Extern { symbol: String, loc: bool },
    /// A compiler intrinsic at a concrete type argument (`Show` etc. at a type with a
    /// user-defined instance resolve to `Instance` instead).
    Intrinsic { which: Intrinsic, ty: Ty },
    /// A compiler-derived instance of a built-in shape method for a concrete type (for example
    /// `Show` of a struct, `Eq` of a list): generate it structurally, using `shape_impls` for the
    /// component types.
    Derived { shape: Builtin, ty: Ty },
    /// Call through the vtable of an `any S` value: method index `method` of `defs.shapes[shape]`.
    Vtable { shape: ShapeId, method: usize },
    /// Construct an enum variant.
    Variant { def: DefId, index: usize },
    /// Call a closure value (`{fnptr, env}`).
    Closure,
}

/// The implementation of every method of a shape for one type, for `any Shape`.
#[derive(Debug, Clone)]
pub struct Vtable {
    pub shape: ShapeId,
    pub ty: Ty,
    pub methods: Vec<Target>,
}

#[derive(Debug, Clone)]
pub struct MainInfo {
    pub func: FnId,
    /// `fn main(args: [str])`.
    pub takes_args: bool,
    /// `()`, `int`, `()!` or `int!`.
    pub ret: Ty,
}

/// Per-module side tables (see the module docs).
#[derive(Debug, Default, Clone)]
pub struct Tables {
    pub types: HashMap<NodeId, Ty>,
    pub coercions: HashMap<NodeId, Vec<Coercion>>,
    pub names: HashMap<NodeId, NameRef>,
    pub binds: HashMap<NodeId, LocalId>,
    pub locals: Vec<LocalInfo>,
    pub variants: HashMap<NodeId, VariantRef>,
    pub calls: HashMap<NodeId, Call>,
    /// Field reads `x.f` on structs: (struct, field index).
    pub fields: HashMap<NodeId, (DefId, usize)>,
    pub struct_lits: HashMap<NodeId, StructLit>,
    pub struct_pats: HashMap<NodeId, StructPat>,
    pub closures: HashMap<NodeId, ClosureInfo>,
    pub tries: HashMap<NodeId, TryInfo>,
    pub fails: HashMap<NodeId, FailKind>,
    pub elses: HashMap<NodeId, ElseInfo>,
    pub opt_chains: HashMap<NodeId, OptChainInfo>,
    pub awaits: HashMap<NodeId, AwaitKind>,
    pub fors: HashMap<NodeId, ForKind>,
    pub formats: HashMap<NodeId, FormatSpec>,
    /// Interpolation parts and `peek` operands that need a `Show` call (non-primitive types):
    /// the generic view; `Instance::resolved` has the target.
    pub shows: HashMap<NodeId, Callee>,
    /// Map patterns matched against a `Value` (they match `Value.Map`).
    pub value_map_pats: BTreeSet<NodeId>,
    /// `err(pat)` patterns on a plain `T!` whose inner pattern matches a typed error payload:
    /// the error enum to look for.
    pub err_payload_pats: HashMap<NodeId, Ty>,
    /// Interpolation parts whose value has a unit of measure (erased from `types`): the unit,
    /// printed after the number and a space (`"{d}"` gives `3.0 m`).
    pub units: HashMap<NodeId, String>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Coercion {
    /// `T` -> `T?`
    WrapSome,
    /// `T` -> `T!` / `T!E`
    WrapOk,
    /// A concrete type -> `any S` (vtable in `Instance::vtables[node]`).
    ToAny(ShapeId),
}

#[derive(Debug, Clone, PartialEq)]
pub enum NameRef {
    Local(LocalId),
    Const(ConstId),
    /// A function used as a value (a closure with no environment).
    Fn {
        func: FnId,
        type_args: Vec<Ty>,
    },
    /// A field-less variant value, or a variant constructor used as a function value.
    Variant(VariantRef),
    /// `none`.
    None,
}

#[derive(Debug, Clone, PartialEq)]
pub struct VariantRef {
    pub def: DefId,
    pub index: usize,
    pub args: Vec<Ty>,
}

#[derive(Debug, Clone)]
pub struct LocalInfo {
    pub name: String,
    pub ty: Ty,
    pub mutable: bool,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct Call {
    pub callee: Callee,
    pub args: Vec<Arg>,
}

#[derive(Debug, Clone)]
pub struct Arg {
    pub node: NodeId,
    /// Passed to a `var` parameter: by address.
    pub by_ref: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Callee {
    /// A function (Duck, extern or intrinsic) with type arguments for its `generics`.
    Fn { func: FnId, type_args: Vec<Ty> },
    /// An enum variant constructor.
    Variant(VariantRef),
    /// A closure value: the callee expression (`f` in `f(x)`, or the `|>` step name).
    Closure,
    /// A shape method on a type parameter (or a derived operator `==`/`<` on any type): resolved
    /// per instance.
    Shape { shape: ShapeId, method: usize, self_ty: Ty },
    /// A method of an `any S` value: dynamic dispatch.
    Vtable { shape: ShapeId, method: usize },
}

#[derive(Debug, Clone)]
pub struct StructLit {
    pub def: DefId,
    pub args: Vec<Ty>,
    /// One entry per field written, in source order: (field index, the value expression, or the
    /// local for shorthand `Point { x }` with the conversions to apply to it, like
    /// `tables.coercions` of an expression: auto-wrap into `T?`/`T!`, never `ToAny`).
    pub fields: Vec<(usize, FieldValue)>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum FieldValue {
    Expr(NodeId),
    Local(LocalId, Vec<Coercion>),
}

#[derive(Debug, Clone)]
pub struct StructPat {
    pub def: DefId,
    /// Per field pattern in source order: (field index, shorthand binding if `{ name }`).
    pub fields: Vec<(usize, Option<LocalId>)>,
}

#[derive(Debug, Clone)]
pub struct ClosureInfo {
    pub params: Vec<Ty>,
    pub ret: Ty,
    /// Captured locals (by value: values are copy-on-write).
    pub captures: Vec<LocalId>,
    /// The closure was written with n parameters where one n-tuple is passed
    /// (`pairs.map((i, x) => ..)`): unpack the tuple.
    pub unpack: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TryInfo {
    pub kind: TryKind,
    pub conv: ErrConv,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum TryKind {
    /// `T!` / `T!E`
    Result,
    /// `T?` (in a function returning `U?`)
    Option,
    /// `[T!]`: all values, or the first error.
    ListResult,
    /// `[T?]`: all values, or none.
    ListOption,
}

/// How an error passes up through `?`.
#[derive(Debug, Clone, PartialEq)]
pub enum ErrConv {
    /// Same error type (or a missing value up to a `T?` function).
    None,
    /// A typed error enum becomes an `Err` (message = its `Show`, payload = the value).
    ToErr { from: Ty },
}

#[derive(Debug, Clone, PartialEq)]
pub enum FailKind {
    /// `fail("message")`: a new `Err`.
    Message,
    /// `fail(e)` with `e: Err`.
    Err,
    /// `fail(E.Variant(..))` in a `T!E` function.
    Typed,
    /// A typed error in a `T!` function: converted to `Err` with a payload.
    TypedToErr(Ty),
}

#[derive(Debug, Clone, PartialEq)]
pub struct ElseInfo {
    pub kind: ElseKind,
    /// `else e => ...`: the error (`Err` or the typed `E`).
    pub binder: Option<LocalId>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ElseKind {
    /// `e` is `T?`: the fallback runs when it is none.
    Option,
    /// `e` is `T!`/`T!E`: the fallback runs on an error.
    Result,
    /// `let pat = e else ..` where `pat` is refutable for `e`'s type: the fallback runs when the
    /// pattern doesn't match.
    Refutable,
    /// `let pat = e else ..` with `e: T?`/`T!`, where `pat` is also refutable for `T`: the
    /// fallback runs on none/error or a non-match. `option` says which wrapper.
    UnwrapRefutable { option: bool },
}

#[derive(Debug, Clone, PartialEq)]
pub struct OptChainInfo {
    /// The member is itself `U?`, so the result is `U?`, not `U??`.
    pub flatten: bool,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum AwaitKind {
    /// `await f(x)` of an `async fn`: just call it (no thread).
    Direct,
    /// `await t` on a `Task<T>`.
    Task,
    /// `await (a, b)`: start all, join all.
    Tuple,
    /// `await xs` on `[Task<T>]`: start all, join all.
    List,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ForKind {
    /// `for i in a..b` / `a..=b` (no list is built).
    Range { inclusive: bool },
    /// `for x in xs` / `for i, x in xs` (the index is an int).
    List,
    /// `for k, v in m` (or `for kv in m`: a `(K, V)` tuple).
    Map,
}

/// A parsed `{x:spec}`: `[fill? align] ['0'] [width] ['.' precision]` (runtime `duck_fmt_*`).
#[derive(Debug, Clone, PartialEq)]
pub struct FormatSpec {
    pub text: String,
    pub fill: Option<char>,
    pub align: Option<char>,
    pub zero: bool,
    pub width: Option<usize>,
    pub precision: Option<usize>,
}

impl TypedProgram {
    /// Invariants codegen relies on: no inference variables or error types anywhere in the
    /// tables, every call node of an emitted instance resolved. Returns the violations.
    pub fn validate(&self) -> Vec<String> {
        let mut out = Vec::new();
        let bad = |t: &Ty| t.has_vars() || t.has_error();
        for (m, t) in self.tables.iter().enumerate() {
            let file = &self.program.mods[m].file;
            for (n, ty) in &t.types {
                if bad(ty) {
                    out.push(format!("{file}: node {n} has type {}", self.defs.show(ty)));
                }
            }
            for (i, l) in t.locals.iter().enumerate() {
                if bad(&l.ty) {
                    out.push(format!("{file}: local {i} `{}` has type {}", l.name, self.defs.show(&l.ty)));
                }
            }
            for (n, c) in &t.calls {
                if let Callee::Fn { type_args, .. } = &c.callee
                    && type_args.iter().any(bad)
                {
                    out.push(format!("{file}: call {n} has unresolved type arguments"));
                }
            }
        }
        for (i, inst) in self.instances.iter().enumerate() {
            if inst.type_args.iter().any(|t| bad(t) || t.has_params()) {
                out.push(format!("instance {i} has non-concrete type arguments"));
            }
        }
        for f in &self.fns {
            if f.params.iter().any(|p| bad(&p.ty)) || bad(&f.ret) {
                out.push(format!("fn {} has a bad signature", f.name));
            }
        }
        out
    }

    /// A readable summary for debugging (`duck typed <file>`): every non-core function with its
    /// signature, then the instances to emit.
    pub fn dump(&self) -> String {
        let mut s = String::new();
        let sig = |f: &FnInfo| {
            let ps: Vec<String> = f.params.iter().map(|p| format!("{}{}", if p.var { "var " } else { "" }, self.defs.show(&p.ty))).collect();
            let gs: Vec<String> = f.generics.iter().map(|g| self.defs.params[*g].name.clone()).collect();
            let g = if gs.is_empty() { String::new() } else { format!("<{}>", gs.join(", ")) };
            format!("{}{}{g}({}): {}", if f.is_async { "async " } else { "" }, f.name, ps.join(", "), self.defs.show(&f.ret))
        };
        for f in &self.fns {
            if self.program.is_core(f.module) {
                continue;
            }
            let kind = match &f.kind {
                FnKind::Duck { clauses, .. } => format!("{} clause(s)", clauses.len()),
                FnKind::Extern { symbol, .. } => format!("extern {symbol}"),
                FnKind::Intrinsic { which, .. } => format!("intrinsic {which:?}"),
            };
            s += &format!("fn {}.{} [{kind}]\n", self.program.name(f.module), sig(f));
        }
        for (i, inst) in self.instances.iter().enumerate() {
            let what = match inst.body {
                BodyRef::Fn(f) => format!("{}.{}", self.program.name(self.fns[f].module), self.fns[f].name),
                BodyRef::Test(t) => format!("test {:?}", self.tests[t].name),
                BodyRef::Const(c) => format!("const {}", self.consts[c].name),
            };
            if !inst.type_args.is_empty() {
                let args: Vec<String> = inst.type_args.iter().map(|t| self.defs.show(t)).collect();
                s += &format!("instance {i}: {what}<{}>\n", args.join(", "));
            }
        }
        s += &format!(
            "{} instances, {} concrete types, {} shape impls, {} vtables\n",
            self.instances.len(),
            self.types_used.len(),
            self.shape_impls.len(),
            self.vtables.len()
        );
        s
    }
}

/// MIR: the mid-level IR between the typed program and the machine back ends (src/mir/mod.rs).
///
/// A program is a list of functions, generated aggregate types, and globals. Function bodies
/// are *structured*, C-like statement trees over typed expressions: every expression knows its
/// machine type (`MTy`), aggregates are values (copied by value), and control flow is `If`,
/// `Loop` (with a latch run by `Continue`), `Break`, labels and forward `Goto`s, and `Ret`.
/// Reference counting is explicit (calls to `auk_retain`/`auk_release` and generated helpers),
/// so the back end (`codegen`) only translates.
///
/// Auk values have type `MTy.D(ty)`; their representation (and the members `Sel` names) is
/// described in `mir.types`. Calls to the runtime name its C symbol (`Callee.Rt`); calls between
/// generated functions use `Callee.Fn`. Aggregates passed to or returned from *generated*
/// functions use the back end's own convention; runtime calls follow the C ABI.
///
/// The back end reads a program written by the Rust compiler (`auk dump mir`, `mir.reader`) or
/// one lowered here (`mir.lower`, with the builder `Body` and `retype` below). Rust's `VarId`,
/// `FuncId`, `GlobalId`, `AggId` and `LabelId` are `int`s; a `CStr` is its bytes. Rust's
/// `Ex::new`, `Ex::var`, `Ex::int`, `Ex::bool`, `Ex::float` are `ex`, `var_`, `int_`, `bool_`,
/// `float_`; the others keep their names (`e.field(..)`, `e.cast(..)` are dot calls).

/// A machine-level type.
pub enum MTy {
  /// No value (the result of a `void` runtime function).
  Void,
  Bool,
  I32,
  U32,
  I64,
  U64,
  /// C-only widths and `float`, for calls to user C functions (FFI marshalling).
  I8,
  U8,
  I16,
  U16,
  F32,
  /// A pointer to a value of the given type (`Ptr(Void)` is `void *`).
  Ptr(t: MTy),
  /// A static NUL-terminated string (`const char *`).
  CStr,
  /// A code pointer (a generated or runtime function's address), `void *` in C.
  Code,
  /// An Auk value.
  D(t: types.Ty),
  /// A generated aggregate (box cell, closure environment, task arguments, vtable).
  Agg(a: int),
  /// A runtime struct (see runtime/c/auk_rt.h).
  Rt(r: Rt),
}

/// Runtime structs that generated code names.
pub enum Rt {
  StrBuf,
  /// `AukObj` (a generic heap object header with a drop function).
  Obj,
  ElemOps,
  Task,
}

pub fn ptr(t: MTy): MTy = MTy.Ptr(t)

pub fn void_ptr(): MTy = MTy.Ptr(MTy.Void)

pub fn obj_ptr(): MTy = MTy.Ptr(MTy.Rt(Rt.Obj))

/// A member of an aggregate value (see `mir.types` for each type's members).
pub enum Sel {
  /// The n-th member (tuple field, struct field, `some`/`val`, `ok`/`val`/`err`, closure
  /// `fn`/`env`, `any` `obj`/`vt`, generated aggregate field).
  F(i: int),
  /// An enum's (or `Value`'s) tag.
  Tag,
  /// Field `fi` of variant `vi` of an enum (`Value`: the payload of variant `vi`).
  V(vi: int, fi: int),
}

/// A field of a runtime struct reached through a pointer.
pub enum RtF {
  /// `AukArr.len` (i64)
  ArrLen,
  /// `AukArr.data` (char *)
  ArrData,
  /// `AukErr.msg` (AukStr *)
  ErrMsg,
}

pub enum UOp { Not, Neg, BitNot }

/// `Rem`, `Shl`, `Shr` only on the runtime dialect's fixed-width numbers (a shift amount is
/// taken modulo the width; `Div`/`Rem`/`Shr`/comparisons are unsigned on its unsigned types).
pub enum BOp { Add, Sub, Mul, Div, BitAnd, BitOr, BitXor, Eq, Ne, Lt, Le, Gt, Ge, Rem, Shl, Shr }

/// A function reference.
pub enum FRef {
  /// A generated function.
  Fn(f: int),
  /// A runtime (C ABI) function.
  Rt(s: str),
}

pub enum Callee {
  Fn(f: int),
  /// A runtime function (C ABI). The argument and result types are the expressions' types.
  Rt(s: str),
  /// A call through a code pointer to a generated function with these parameter types.
  Indirect(code: Ex, ps: [MTy]),
  /// A call through a pointer to a C function (C ABI, like `Rt`; the argument and result types
  /// are the expressions' types): `extern fn` with a `"T (*)(...)"` prototype.
  CPtr(code: Ex),
}

/// A typed expression.
pub struct Ex { k: K, ty: MTy }

pub enum K {
  Var(v: int),
  Global(g: int),
  Int(n: int),
  Float(x: float),
  /// A static C string (type `CStr`), as bytes.
  CStr(b: [int]),
  /// The zero value of the type (NULL, 0, false, an all-zero aggregate).
  Zero,
  /// The address of a function (type `Code`).
  FnAddr(f: FRef),
  /// The address of a global (generated, or a runtime one like `auk_ops_int`).
  GlobalAddr(g: int),
  RtGlobalAddr(s: str),
  /// A member of an aggregate (a place when the aggregate is a place).
  Field(b: Ex, s: Sel),
  /// `*p` (a place); `ty` is the pointee type.
  Deref(p: Ex),
  /// `&place`.
  Addr(p: Ex),
  Un(op: UOp, a: Ex),
  Bin(op: BOp, a: Ex, b: Ex),
  /// Short-circuit conjunction.
  And(xs: [Ex]),
  /// A conversion to `ty` (numeric conversion, or a pointer reinterpretation).
  Cast(x: Ex),
  Call(c: Callee, args: [Ex]),
  /// An aggregate of type `ty` with the given members set (the rest zero).
  Agg(ms: [(Sel, Ex)]),
  Cond(c: Ex, a: Ex, b: Ex),
  /// Element `i` of an array's buffer: `((T *)arr->data)[i]` (a place); `ty` is `T`.
  Elem(arr: Ex, i: Ex),
  /// A field of a runtime struct through a pointer (a place).
  RtField(p: Ex, f: RtF),
  /// The size in bytes of a type (type `U64`).
  SizeOf(t: MTy),
}

/// Is this a variable (an addressable name that can be reused freely)?
pub fn is_var(e: Ex): bool = e.k is K.Var(_)

pub fn as_var(e: Ex): int? = match e.k {
  Var(v) => v
  _ => none
}

/// Is this a place (can be assigned to or have its address taken)?
pub fn is_place(e: Ex): bool = match e.k {
  Var(_) | Global(_) | Deref(_) | Elem(_, _) | RtField(_, _) => true
  Field(b, _) => is_place(b)
  _ => false
}

/// Is evaluating this free of side effects and cheap enough to repeat?
pub fn is_simple(e: Ex): bool = match e.k {
  Var(_) | Global(_) | Int(_) | Float(_) | CStr(_) | Zero | FnAddr(_) | GlobalAddr(_) | RtGlobalAddr(_) => true
  Field(b, _) | Deref(b) | Addr(b) | Cast(b) | RtField(b, _) => is_simple(b)
  _ => false
}

pub enum Stmt {
  /// Declare (and initialize) a variable.
  Let(v: int, e: Ex),
  /// Store into a place.
  Set(p: Ex, e: Ex),
  /// Evaluate for effect.
  Do(e: Ex),
  If(c: Ex, a: [Stmt], b: [Stmt]),
  /// Repeat `body`; `Continue` runs `latch` and repeats, `Break` leaves.
  Loop(body: [Stmt], latch: [Stmt]),
  Break,
  Continue,
  Label(l: int),
  /// A jump to a label later in the same function (or a self tail call's loop label).
  Goto(l: int),
  Ret(e: Ex?),
  /// Control never gets here (after a call that doesn't return).
  Unreachable,
  /// The code from here on comes from source location `Program.locs[i]` (debug info).
  Loc(i: int),
}

/// The calling convention of a generated function.
pub enum Abi {
  /// Called only by generated code.
  Auk,
  /// Called by the runtime through a C function pointer (element ops, drops, thunks, tests,
  /// the entry point): the signature only has scalars and pointers.
  C,
}

/// A generated function.
pub struct Func {
  name: str,
  params: [int],
  ret: MTy,
  /// The type of each variable (parameters included).
  vars: [MTy],
  body: [Stmt],
  abi: Abi,
}

/// A generated aggregate type.
pub struct AggDef { name: str, fields: [MTy] }

/// A global variable.
pub struct Global {
  name: str,
  ty: MTy,
  /// A constant initializer (built from addresses, sizes and numbers), or zero.
  init: Ex?,
  /// Read-only data (element ops, vtables).
  constant: bool,
  /// The runtime's dialect: 0 a generated global; 1 `raw var` (internal), 2 `raw thread var`
  /// (internal, thread-local), 3 `raw let` (not a global), 4 `export var` (external, its name),
  /// 5 `extern var` (a declaration of a C global).
  kind: int,
}

/// A whole program.
pub struct Program {
  funcs: [Func],
  aggs: [AggDef],
  globals: [Global],
  /// The entry point: `int f(int argc, char **argv)`.
  entry: int?,
  /// Source locations (file, line, column) that `Stmt.Loc` refers to: set only when building
  /// with debug info (`auk build -g`).
  locs: [(str, int, int)],
  /// The Auk name of each function that holds an Auk body (`mod.f`, `mod.f.<fn:12>`,
  /// `test "t"`): debug info names functions by it. Set with `locs`.
  names: {int: str},
  /// C libraries to load (JIT) or link (`auk build`): `[link] libs` of every package.
  links: [str],
  /// The user C functions the program calls (`extern fn` with a C prototype).
  c_syms: [str],
}

/// A compiler bug: print `msg` and panic (Rust's `panic!`, `unreachable!`).
pub fn bug<T>(msg: str): T {
  eprint("internal error: {msg}")
  let x: T? = none
  x!
}

// ---- building expressions (Rust's `impl Ex`) ----

pub fn ex(k: K, ty: MTy): Ex = Ex { k, ty }

pub fn var_(v: int, ty: MTy): Ex = Ex { k: K.Var(v), ty }

pub fn int_(n: int): Ex = Ex { k: K.Int(n), ty: MTy.D(types.Ty.Int) }

pub fn i64(n: int): Ex = Ex { k: K.Int(n), ty: MTy.I64 }

pub fn int_as(n: int, ty: MTy): Ex = Ex { k: K.Int(n), ty }

pub fn bool_(b: bool): Ex = Ex { k: K.Int(if b { 1 } else { 0 }), ty: MTy.D(types.Ty.Bool) }

pub fn float_(x: float): Ex = Ex { k: K.Float(x), ty: MTy.D(types.Ty.Float) }

pub fn cstr(s: str): Ex = Ex { k: K.CStr(s.bytes()), ty: MTy.CStr }

pub fn zero(ty: MTy): Ex = Ex { k: K.Zero, ty }

pub fn null(): Ex = Ex { k: K.Zero, ty: void_ptr() }

pub fn unit(): Ex = Ex { k: K.Int(0), ty: MTy.D(types.unit()) }

pub fn fn_addr(f: int): Ex = Ex { k: K.FnAddr(FRef.Fn(f)), ty: MTy.Code }

pub fn rt_global(s: str, ty: MTy): Ex = Ex { k: K.RtGlobalAddr(s), ty: ptr(ty) }

pub fn field(e: Ex, s: Sel, ty: MTy): Ex = Ex { k: K.Field(e, s), ty }

pub fn deref(e: Ex, ty: MTy): Ex = Ex { k: K.Deref(e), ty }

pub fn addr(e: Ex): Ex = Ex { k: K.Addr(e), ty: ptr(e.ty) }

pub fn cast(e: Ex, ty: MTy): Ex {
  if e.ty == ty { return e }
  Ex { k: K.Cast(e), ty }
}

pub fn bin(op: BOp, a: Ex, b: Ex): Ex {
  let ty = match op {
    Eq | Ne | Lt | Le | Gt | Ge => MTy.D(types.Ty.Bool)
    _ => a.ty
  }
  Ex { k: K.Bin(op, a, b), ty }
}

pub fn not(e: Ex): Ex = Ex { k: K.Un(UOp.Not, e), ty: MTy.D(types.Ty.Bool) }

pub fn and(xs: [Ex]): Ex = match xs.len() {
  0 => bool_(true)
  1 => xs[0]
  _ => Ex { k: K.And(xs), ty: MTy.D(types.Ty.Bool) }
}

pub fn cond(c: Ex, a: Ex, b: Ex): Ex = Ex { k: K.Cond(c, a, b), ty: a.ty }

pub fn rt(sym: str, args: [Ex], ret: MTy): Ex = Ex { k: K.Call(Callee.Rt(sym), args), ty: ret }

pub fn call(f: int, args: [Ex], ret: MTy): Ex = Ex { k: K.Call(Callee.Fn(f), args), ty: ret }

pub fn agg(ty: MTy, members: [(Sel, Ex)]): Ex = Ex { k: K.Agg(members), ty }

pub fn elem(arr: Ex, i: Ex, ty: MTy): Ex = Ex { k: K.Elem(arr, i), ty }

pub fn rt_field(e: Ex, f: RtF): Ex {
  let ty = match f {
    ArrLen => MTy.D(types.Ty.Int)
    ArrData => void_ptr()
    ErrMsg => MTy.D(types.Ty.Str)
  }
  Ex { k: K.RtField(e, f), ty }
}

pub fn size_of(t: MTy): Ex = Ex { k: K.SizeOf(t), ty: MTy.U64 }

// ---- building function bodies ----

enum Frame {
  If(c: Ex),
  Else(c: Ex, then: [Stmt]),
  Loop(latch: [Stmt]),
}

/// Builds one function body: a stack of open statement lists (`if` branches, loop bodies).
pub struct Body {
  vars: [MTy],
  out: [[Stmt]],
  frames: [Frame],
  next_label: int,
}

/// `Body::new()`.
pub fn new_body(): Body = Body { vars: [], out: [[]], frames: [], next_label: 0 }

/// A fresh (undeclared) variable.
pub fn new_var(b: var Body, ty: MTy): Ex {
  b.vars.push(ty)
  var_(b.vars.len() - 1, ty)
}

/// Declare a variable initialized to `init`.
pub fn decl(b: var Body, init: Ex): Ex {
  let v = b.new_var(init.ty)
  b.emit(Stmt.Let(b.vars.len() - 1, init))
  v
}

/// Declare a variable of type `ty` initialized to `init` (converted).
pub fn decl_as(b: var Body, ty: MTy, init: Ex): Ex {
  let v = b.new_var(ty)
  b.emit(Stmt.Let(b.vars.len() - 1, retype(init, ty)))
  v
}

pub fn label(b: var Body): int {
  b.next_label += 1
  b.next_label
}

pub fn emit(b: var Body, s: Stmt) {
  let n = b.out.len()
  b.out[n - 1].push(s)
}

pub fn set(b: var Body, place: Ex, v: Ex) {
  let v2 = retype(v, place.ty)
  b.emit(Stmt.Set(place, v2))
}

pub fn do_(b: var Body, e: Ex) { b.emit(Stmt.Do(e)) }

pub fn open_if(b: var Body, c: Ex) {
  b.frames.push(Frame.If(c))
  b.out.push([])
}

/// Switch from the `then` branch of the innermost `if` to its `else` branch.
pub fn else_(b: var Body) {
  let then = b.out.pop()!
  match b.frames.pop() {
    some(If(c)) => b.frames.push(Frame.Else(c, then))
    _ => { let _: int = bug("mir: else without if") }
  }
  b.out.push([])
}

/// Open a loop whose `Continue` runs `latch` first.
pub fn open_loop(b: var Body, latch: [Stmt]) {
  b.frames.push(Frame.Loop(latch))
  b.out.push([])
}

/// Close the innermost `if` / `else` / loop.
pub fn close(b: var Body) {
  let inner = b.out.pop()!
  let s = match b.frames.pop() {
    some(If(c)) => Stmt.If(c, inner, [])
    some(Else(c, then)) => Stmt.If(c, then, inner)
    some(Loop(latch)) => Stmt.Loop(inner, latch)
    none => bug("mir: close without open")
  }
  b.emit(s)
}

/// The finished statements and variables (Rust's `finish(self)`).
pub fn finish(b: var Body): ([Stmt], [MTy]) {
  while b.frames.len() > 0 { b.close() }
  (b.out.pop()!, b.vars)
}

/// `e` as a value of type `ty`: integer literals and zeros take the type; other expressions are
/// converted only between distinct machine types (Auk types of the same representation are
/// interchangeable).
pub fn retype(e: Ex, ty: MTy): Ex {
  if e.ty == ty { return e }
  let lit = match e.k {
    Int(_) | Zero | Float(_) => !(ty is MTy.Agg(_)) || (e.k is K.Zero)
    _ => false
  }
  if lit { Ex { k: e.k, ty } } else { e.cast(ty) }
}

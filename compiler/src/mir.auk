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
/// The port reads a program written by the Rust compiler (`auk dump mir`, `mir.reader`) instead
/// of lowering one, so the builder (`Body`) and `retype` are not here yet. Rust's `VarId`,
/// `FuncId`, `GlobalId`, `AggId` and `LabelId` are `int`s; a `CStr` is its bytes.

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

pub enum BOp { Add, Sub, Mul, Div, BitAnd, BitOr, BitXor, Eq, Ne, Lt, Le, Gt, Ge }

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

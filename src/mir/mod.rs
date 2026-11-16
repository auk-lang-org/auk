//! MIR: the mid-level IR between the typed program and the machine back ends.
//!
//! A program is a list of functions, generated aggregate types, and globals. Function bodies
//! are *structured*, C-like statement trees over typed expressions: every expression knows its
//! machine type (`MTy`), aggregates are values (copied by value), and control flow is `If`,
//! `Loop` (with a latch run by `Continue`), `Break`, labels and forward `Goto`s, and `Ret`.
//! Reference counting is explicit (calls to `duck_retain`/`duck_release` and generated helpers),
//! so a back end only translates: `c.rs` prints C, `clif.rs` emits Cranelift IR.
//!
//! Duck values have type `MTy::D(ty)`; their representation (and the members `Sel` names) is
//! described in `types.rs`. Calls to the runtime name its C symbol (`Callee::Rt`); calls between
//! generated functions use `Callee::Fn`. Aggregates passed to or returned from *generated*
//! functions use the back end's own convention; runtime calls follow the C ABI.

pub mod print;
pub mod clif;
pub mod progen;
pub mod lower;
pub mod types;

use crate::types::Ty;

pub type VarId = u32;
pub type FuncId = u32;
pub type GlobalId = u32;
pub type AggId = u32;
pub type LabelId = u32;

/// A machine-level type.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum MTy {
    /// No value (the result of a `void` runtime function).
    Void,
    Bool,
    I32,
    U32,
    I64,
    U64,
    /// A pointer to a value of the given type (`Ptr(Void)` is `void *`).
    Ptr(Box<MTy>),
    /// A static NUL-terminated string (`const char *`).
    CStr,
    /// A code pointer (a generated or runtime function's address), `void *` in C.
    Code,
    /// A Duck value.
    D(Ty),
    /// A generated aggregate (box cell, closure environment, task arguments, vtable).
    Agg(AggId),
    /// A runtime struct (see runtime/src/lib.rs).
    Rt(Rt),
}

/// Runtime structs that generated code names.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Rt {
    StrBuf,
    /// `DuckObj` (a generic heap object header with a drop function).
    Obj,
    ElemOps,
    Task,
}

impl MTy {
    pub fn ptr(t: MTy) -> MTy {
        MTy::Ptr(Box::new(t))
    }
    pub fn void_ptr() -> MTy {
        MTy::ptr(MTy::Void)
    }
    pub fn obj_ptr() -> MTy {
        MTy::ptr(MTy::Rt(Rt::Obj))
    }
}

/// A member of an aggregate value (see `types.rs` for each type's members).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Sel {
    /// The n-th member (tuple field, struct field, `some`/`val`, `ok`/`val`/`err`, closure
    /// `fn`/`env`, `any` `obj`/`vt`, generated aggregate field).
    F(u32),
    /// An enum's (or `Value`'s) tag.
    Tag,
    /// Field `fi` of variant `vi` of an enum (`Value`: the payload of variant `vi`).
    V(u32, u32),
}

/// A field of a runtime struct reached through a pointer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RtF {
    /// `DuckArr.len` (i64)
    ArrLen,
    /// `DuckArr.data` (char *)
    ArrData,
    /// `DuckErr.msg` (DuckStr *)
    ErrMsg,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UOp {
    Not,
    Neg,
    BitNot,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BOp {
    Add,
    Sub,
    Mul,
    Div,
    BitAnd,
    BitOr,
    BitXor,
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
}

/// A function reference.
#[derive(Debug, Clone, PartialEq)]
pub enum FRef {
    /// A generated function.
    Fn(FuncId),
    /// A runtime (C ABI) function.
    Rt(String),
}

#[derive(Debug, Clone, PartialEq)]
pub enum Callee {
    Fn(FuncId),
    /// A runtime function (C ABI). The argument and result types are the expressions' types.
    Rt(String),
    /// A call through a code pointer to a generated function with these parameter types.
    Indirect(Box<Ex>, Vec<MTy>),
}

/// A typed expression.
#[derive(Debug, Clone, PartialEq)]
pub struct Ex {
    pub k: K,
    pub ty: MTy,
}

#[derive(Debug, Clone, PartialEq)]
pub enum K {
    Var(VarId),
    Global(GlobalId),
    Int(i64),
    Float(f64),
    /// A static C string (type `CStr`).
    CStr(Vec<u8>),
    /// The zero value of the type (NULL, 0, false, an all-zero aggregate).
    Zero,
    /// The address of a function (type `Code`).
    FnAddr(FRef),
    /// The address of a global (generated, or a runtime one like `duck_ops_int`).
    GlobalAddr(GlobalId),
    RtGlobalAddr(String),
    /// A member of an aggregate (a place when the aggregate is a place).
    Field(Box<Ex>, Sel),
    /// `*p` (a place); `ty` is the pointee type.
    Deref(Box<Ex>),
    /// `&place`.
    Addr(Box<Ex>),
    Un(UOp, Box<Ex>),
    Bin(BOp, Box<Ex>, Box<Ex>),
    /// Short-circuit conjunction.
    And(Vec<Ex>),
    /// A conversion to `ty` (numeric conversion, or a pointer reinterpretation).
    Cast(Box<Ex>),
    Call(Callee, Vec<Ex>),
    /// An aggregate of type `ty` with the given members set (the rest zero).
    Agg(Vec<(Sel, Ex)>),
    Cond(Box<Ex>, Box<Ex>, Box<Ex>),
    /// Element `i` of an array's buffer: `((T *)arr->data)[i]` (a place); `ty` is `T`.
    Elem(Box<Ex>, Box<Ex>),
    /// A field of a runtime struct through a pointer (a place).
    RtField(Box<Ex>, RtF),
    /// The size in bytes of a type (type `U64`).
    SizeOf(MTy),
}

impl Ex {
    pub fn new(k: K, ty: MTy) -> Ex {
        Ex { k, ty }
    }
    pub fn var(v: VarId, ty: MTy) -> Ex {
        Ex::new(K::Var(v), ty)
    }
    pub fn int(n: i64) -> Ex {
        Ex::new(K::Int(n), MTy::D(Ty::Int))
    }
    pub fn i64(n: i64) -> Ex {
        Ex::new(K::Int(n), MTy::I64)
    }
    pub fn int_as(n: i64, ty: MTy) -> Ex {
        Ex::new(K::Int(n), ty)
    }
    pub fn bool(b: bool) -> Ex {
        Ex::new(K::Int(b as i64), MTy::D(Ty::Bool))
    }
    pub fn float(x: f64) -> Ex {
        Ex::new(K::Float(x), MTy::D(Ty::Float))
    }
    pub fn cstr(s: &str) -> Ex {
        Ex::new(K::CStr(s.as_bytes().to_vec()), MTy::CStr)
    }
    pub fn zero(ty: MTy) -> Ex {
        Ex::new(K::Zero, ty)
    }
    pub fn null() -> Ex {
        Ex::new(K::Zero, MTy::void_ptr())
    }
    pub fn unit() -> Ex {
        Ex::new(K::Int(0), MTy::D(Ty::unit()))
    }
    pub fn fn_addr(f: FuncId) -> Ex {
        Ex::new(K::FnAddr(FRef::Fn(f)), MTy::Code)
    }
    pub fn rt_global(s: &str, ty: MTy) -> Ex {
        Ex::new(K::RtGlobalAddr(s.to_string()), MTy::ptr(ty))
    }
    pub fn field(self, s: Sel, ty: MTy) -> Ex {
        Ex::new(K::Field(Box::new(self), s), ty)
    }
    pub fn deref(self, ty: MTy) -> Ex {
        Ex::new(K::Deref(Box::new(self)), ty)
    }
    pub fn addr(self) -> Ex {
        let t = MTy::ptr(self.ty.clone());
        Ex::new(K::Addr(Box::new(self)), t)
    }
    pub fn cast(self, ty: MTy) -> Ex {
        if self.ty == ty {
            return self;
        }
        Ex::new(K::Cast(Box::new(self)), ty)
    }
    pub fn bin(op: BOp, a: Ex, b: Ex) -> Ex {
        let ty = match op {
            BOp::Eq | BOp::Ne | BOp::Lt | BOp::Le | BOp::Gt | BOp::Ge => MTy::D(Ty::Bool),
            _ => a.ty.clone(),
        };
        Ex::new(K::Bin(op, Box::new(a), Box::new(b)), ty)
    }
    pub fn not(self) -> Ex {
        Ex::new(K::Un(UOp::Not, Box::new(self)), MTy::D(Ty::Bool))
    }
    pub fn and(xs: Vec<Ex>) -> Ex {
        match xs.len() {
            0 => Ex::bool(true),
            1 => xs.into_iter().next().unwrap(),
            _ => Ex::new(K::And(xs), MTy::D(Ty::Bool)),
        }
    }
    pub fn cond(c: Ex, a: Ex, b: Ex) -> Ex {
        let ty = a.ty.clone();
        Ex::new(K::Cond(Box::new(c), Box::new(a), Box::new(b)), ty)
    }
    pub fn rt(sym: &str, args: Vec<Ex>, ret: MTy) -> Ex {
        Ex::new(K::Call(Callee::Rt(sym.to_string()), args), ret)
    }
    pub fn call(f: FuncId, args: Vec<Ex>, ret: MTy) -> Ex {
        Ex::new(K::Call(Callee::Fn(f), args), ret)
    }
    pub fn agg(ty: MTy, members: Vec<(Sel, Ex)>) -> Ex {
        Ex::new(K::Agg(members), ty)
    }
    pub fn elem(arr: Ex, i: Ex, ty: MTy) -> Ex {
        Ex::new(K::Elem(Box::new(arr), Box::new(i)), ty)
    }
    pub fn rt_field(self, f: RtF) -> Ex {
        let ty = match f {
            RtF::ArrLen => MTy::D(Ty::Int),
            RtF::ArrData => MTy::void_ptr(),
            RtF::ErrMsg => MTy::D(Ty::Str),
        };
        Ex::new(K::RtField(Box::new(self), f), ty)
    }
    pub fn size_of(t: MTy) -> Ex {
        Ex::new(K::SizeOf(t), MTy::U64)
    }

    /// Is this a variable (an addressable name that can be reused freely)?
    pub fn is_var(&self) -> bool {
        matches!(self.k, K::Var(_))
    }
    pub fn as_var(&self) -> Option<VarId> {
        match self.k {
            K::Var(v) => Some(v),
            _ => None,
        }
    }
    /// Is this a place (can be assigned to or have its address taken)?
    pub fn is_place(&self) -> bool {
        match &self.k {
            K::Var(_) | K::Global(_) | K::Deref(_) | K::Elem(..) | K::RtField(..) => true,
            K::Field(b, _) => b.is_place(),
            _ => false,
        }
    }
    /// Is evaluating this free of side effects and cheap enough to repeat?
    pub fn is_simple(&self) -> bool {
        match &self.k {
            K::Var(_) | K::Global(_) | K::Int(_) | K::Float(_) | K::CStr(_) | K::Zero | K::FnAddr(_) | K::GlobalAddr(_) | K::RtGlobalAddr(_) => true,
            K::Field(b, _) | K::Deref(b) | K::Addr(b) | K::Cast(b) | K::RtField(b, _) => b.is_simple(),
            _ => false,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Stmt {
    /// Declare (and initialize) a variable.
    Let(VarId, Ex),
    /// Store into a place.
    Set(Ex, Ex),
    /// Evaluate for effect.
    Do(Ex),
    If(Ex, Vec<Stmt>, Vec<Stmt>),
    /// Repeat `body`; `Continue` runs `latch` and repeats, `Break` leaves.
    Loop(Vec<Stmt>, Vec<Stmt>),
    Break,
    Continue,
    Label(LabelId),
    /// A jump to a label later in the same function (or a self tail call's loop label).
    Goto(LabelId),
    Ret(Option<Ex>),
    /// Control never gets here (after a call that doesn't return).
    Unreachable,
}

/// A generated function.
#[derive(Debug, Clone)]
pub struct Func {
    pub name: String,
    pub params: Vec<VarId>,
    pub ret: MTy,
    /// The type of each variable (parameters included).
    pub vars: Vec<MTy>,
    pub body: Vec<Stmt>,
    /// How the runtime calls it, if it does (`None`: only generated code calls it).
    pub abi: Abi,
}

/// The calling convention of a generated function.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Abi {
    /// Called only by generated code.
    Duck,
    /// Called by the runtime through a C function pointer (element ops, drops, thunks, tests,
    /// the entry point): the signature only has scalars and pointers.
    C,
}

/// A generated aggregate type.
#[derive(Debug, Clone)]
pub struct AggDef {
    pub name: String,
    pub fields: Vec<MTy>,
}

/// A global variable.
#[derive(Debug, Clone)]
pub struct Global {
    pub name: String,
    pub ty: MTy,
    /// A constant initializer (built from addresses, sizes and numbers), or zero.
    pub init: Option<Ex>,
    /// Read-only data (element ops, vtables).
    pub constant: bool,
}

/// A whole program.
#[derive(Debug, Default)]
pub struct Program {
    pub funcs: Vec<Func>,
    pub aggs: Vec<AggDef>,
    pub globals: Vec<Global>,
    /// The entry point: `int f(int argc, char **argv)`.
    pub entry: Option<FuncId>,
    /// A key for each user function instance that stays the same across compiles of edited
    /// source (its module, name and signature): `duck run --live` swaps bodies by it.
    pub live_keys: std::collections::HashMap<FuncId, String>,
}

// ---- building function bodies -----------------------------------------------------------

enum Frame {
    If(Ex),
    Else(Ex, Vec<Stmt>),
    Loop(Vec<Stmt>),
}

/// Builds one function body: a stack of open statement lists (`if` branches, loop bodies).
pub struct Body {
    pub vars: Vec<MTy>,
    out: Vec<Vec<Stmt>>,
    frames: Vec<Frame>,
    next_label: LabelId,
}

impl Default for Body {
    fn default() -> Self {
        Body::new()
    }
}

impl Body {
    pub fn new() -> Body {
        Body { vars: Vec::new(), out: vec![Vec::new()], frames: Vec::new(), next_label: 0 }
    }

    /// A fresh (undeclared) variable.
    pub fn new_var(&mut self, ty: MTy) -> Ex {
        self.vars.push(ty.clone());
        Ex::var(self.vars.len() as VarId - 1, ty)
    }

    /// Declare a variable initialized to `init`.
    pub fn decl(&mut self, init: Ex) -> Ex {
        let v = self.new_var(init.ty.clone());
        self.emit(Stmt::Let(v.as_var().unwrap(), init));
        v
    }

    /// Declare a variable of type `ty` initialized to `init` (converted).
    pub fn decl_as(&mut self, ty: MTy, init: Ex) -> Ex {
        let v = self.new_var(ty.clone());
        self.emit(Stmt::Let(v.as_var().unwrap(), retype(init, &ty)));
        v
    }

    pub fn label(&mut self) -> LabelId {
        self.next_label += 1;
        self.next_label
    }

    pub fn emit(&mut self, s: Stmt) {
        self.out.last_mut().unwrap().push(s);
    }
    pub fn set(&mut self, place: Ex, v: Ex) {
        let v = retype(v, &place.ty);
        self.emit(Stmt::Set(place, v));
    }
    pub fn do_(&mut self, e: Ex) {
        self.emit(Stmt::Do(e));
    }

    pub fn open_if(&mut self, c: Ex) {
        self.frames.push(Frame::If(c));
        self.out.push(Vec::new());
    }
    /// Switch from the `then` branch of the innermost `if` to its `else` branch.
    pub fn else_(&mut self) {
        let then = self.out.pop().unwrap();
        let Some(Frame::If(c)) = self.frames.pop() else { panic!("mir: else without if") };
        self.frames.push(Frame::Else(c, then));
        self.out.push(Vec::new());
    }
    /// Open a loop whose `Continue` runs `latch` first.
    pub fn open_loop(&mut self, latch: Vec<Stmt>) {
        self.frames.push(Frame::Loop(latch));
        self.out.push(Vec::new());
    }
    /// Close the innermost `if` / `else` / loop.
    pub fn close(&mut self) {
        let inner = self.out.pop().unwrap();
        let s = match self.frames.pop().expect("mir: close without open") {
            Frame::If(c) => Stmt::If(c, inner, Vec::new()),
            Frame::Else(c, then) => Stmt::If(c, then, inner),
            Frame::Loop(latch) => Stmt::Loop(inner, latch),
        };
        self.emit(s);
    }

    /// The finished statements.
    pub fn finish(mut self) -> (Vec<Stmt>, Vec<MTy>) {
        while !self.frames.is_empty() {
            self.close();
        }
        (self.out.pop().unwrap(), self.vars)
    }
}

/// `e` as a value of type `ty`: integer literals and zeros take the type; other expressions are
/// converted only between distinct machine types (Duck types of the same representation are
/// interchangeable).
pub fn retype(e: Ex, ty: &MTy) -> Ex {
    if &e.ty == ty {
        return e;
    }
    match e.k {
        K::Int(_) | K::Zero | K::Float(_) if !matches!(ty, MTy::Agg(_)) || matches!(e.k, K::Zero) => Ex { k: e.k, ty: ty.clone() },
        _ => e.cast(ty.clone()),
    }
}

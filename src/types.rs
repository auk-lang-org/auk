//! Types, type definitions and the inference engine (unification with snapshots).
//!
//! A `Ty` is a plain tree. Nominal types (structs, enums and the opaque runtime types `Err` and
//! `net.Conn`) are `Named(DefId, args)`, indexing `Defs::types`. Type parameters (explicit
//! `<A: Show>` or implicit shape names used as types, `fn top(xs: [Ord])`) are `Param(ParamId)`
//! into `Defs::params`. During checking, unknown types are inference variables `Var(n)` owned by
//! an `Infer`; the checker resolves every type it records, so the typed program (typed.rs) never
//! contains a `Var`.

use std::collections::HashMap;
use std::fmt::Write;

use super::ast::NodeId;
use super::diag::Span;
use super::units::Units;

pub type DefId = usize;
pub type ShapeId = usize;
pub type ParamId = usize;
pub type ModId = usize;

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Ty {
    Int,
    Float,
    Bool,
    Char,
    Str,
    /// The type of `return`, `break`, `continue`, `fail(..)`, a panic or a loop without `break`:
    /// it converts to every type.
    Never,
    List(Box<Ty>),
    Map(Box<Ty>, Box<Ty>),
    /// `(A, B)`; the empty tuple is `()`, the unit type.
    Tuple(Vec<Ty>),
    /// `T?`
    Opt(Box<Ty>),
    /// `T!` (the error is the core `Err` type) or `T!E` (a user error enum).
    Res(Box<Ty>, Box<Ty>),
    /// A struct, enum or opaque runtime type, with its type arguments.
    Named(DefId, Vec<Ty>),
    /// A type parameter of the enclosing generic function or type.
    Param(ParamId),
    /// `any S`: a value of any type that fits shape `S`, dispatched through a vtable.
    Any(ShapeId),
    /// The type of a closure: `(A, B) => R`.
    Fn(Vec<Ty>, Box<Ty>),
    /// The value of an un-awaited `async fn` call: a running task that yields `T`.
    Task(Box<Ty>),
    /// `float<m/s>`, `int<px>`: `Int` or `Float` with a non-empty unit of measure. Checked
    /// only: `erase_units` turns it back into the plain number type before codegen.
    Measured(Box<Ty>, Units),
    /// An inference variable (only during checking).
    Var(u32),
    /// The type of an expression that already produced a diagnostic; it unifies with anything so
    /// one mistake doesn't cascade.
    Error,
}

impl Ty {
    pub fn unit() -> Ty {
        Ty::Tuple(Vec::new())
    }

    pub fn is_unit(&self) -> bool {
        matches!(self, Ty::Tuple(ts) if ts.is_empty())
    }

    pub fn list(t: Ty) -> Ty {
        Ty::List(Box::new(t))
    }

    pub fn opt(t: Ty) -> Ty {
        Ty::Opt(Box::new(t))
    }

    pub fn res(t: Ty, e: Ty) -> Ty {
        Ty::Res(Box::new(t), Box::new(e))
    }

    pub fn map(k: Ty, v: Ty) -> Ty {
        Ty::Map(Box::new(k), Box::new(v))
    }

    pub fn func(ps: Vec<Ty>, r: Ty) -> Ty {
        Ty::Fn(ps, Box::new(r))
    }

    /// `base` with unit `u` (just `base` when `u` is dimensionless).
    pub fn measured(base: Ty, u: Units) -> Ty {
        let b = match base {
            Ty::Measured(b, _) => *b,
            b => b,
        };
        if u.is_none() { b } else { Ty::Measured(Box::new(b), u) }
    }

    /// The unit of a number type (dimensionless for anything without one).
    pub fn units(&self) -> Units {
        match self {
            Ty::Measured(_, u) => u.clone(),
            _ => Units::default(),
        }
    }

    /// The type without its unit at the top (`float<m>` -> `float`).
    pub fn base(&self) -> &Ty {
        match self {
            Ty::Measured(b, _) => b,
            t => t,
        }
    }

    /// Every unit of measure removed, deeply (`[float<m>]` -> `[float]`).
    pub fn erase_units(&self) -> Ty {
        self.map_ty(&mut |t| match t {
            Ty::Measured(b, _) => *b,
            t => t,
        })
    }

    pub fn has_units(&self) -> bool {
        let mut yes = false;
        self.walk(&mut |t| yes |= matches!(t, Ty::Measured(..)));
        yes
    }

    /// Does the type mention a type parameter?
    pub fn has_params(&self) -> bool {
        let mut yes = false;
        self.walk(&mut |t| yes |= matches!(t, Ty::Param(_)));
        yes
    }

    pub fn has_vars(&self) -> bool {
        let mut yes = false;
        self.walk(&mut |t| yes |= matches!(t, Ty::Var(_)));
        yes
    }

    pub fn has_error(&self) -> bool {
        let mut yes = false;
        self.walk(&mut |t| yes |= matches!(t, Ty::Error));
        yes
    }

    /// Visit this type and every type inside it.
    pub fn walk(&self, f: &mut impl FnMut(&Ty)) {
        f(self);
        for c in self.children() {
            c.walk(f);
        }
    }

    pub fn children(&self) -> Vec<&Ty> {
        match self {
            Ty::List(t) | Ty::Opt(t) | Ty::Task(t) | Ty::Measured(t, _) => vec![t],
            Ty::Map(a, b) | Ty::Res(a, b) => vec![a, b],
            Ty::Tuple(ts) | Ty::Named(_, ts) => ts.iter().collect(),
            Ty::Fn(ps, r) => ps.iter().chain(std::iter::once(&**r)).collect(),
            _ => Vec::new(),
        }
    }

    /// Rebuild the type bottom-up through `f` (applied to every node after its children).
    pub fn map_ty(&self, f: &mut impl FnMut(Ty) -> Ty) -> Ty {
        let t = match self {
            Ty::List(t) => Ty::List(Box::new(t.map_ty(f))),
            Ty::Opt(t) => Ty::Opt(Box::new(t.map_ty(f))),
            Ty::Task(t) => Ty::Task(Box::new(t.map_ty(f))),
            Ty::Measured(t, u) => Ty::Measured(Box::new(t.map_ty(f)), u.clone()),
            Ty::Map(a, b) => Ty::Map(Box::new(a.map_ty(f)), Box::new(b.map_ty(f))),
            Ty::Res(a, b) => Ty::Res(Box::new(a.map_ty(f)), Box::new(b.map_ty(f))),
            Ty::Tuple(ts) => Ty::Tuple(ts.iter().map(|t| t.map_ty(f)).collect()),
            Ty::Named(d, ts) => Ty::Named(*d, ts.iter().map(|t| t.map_ty(f)).collect()),
            Ty::Fn(ps, r) => Ty::Fn(ps.iter().map(|t| t.map_ty(f)).collect(), Box::new(r.map_ty(f))),
            t => t.clone(),
        };
        f(t)
    }

    /// Replace type parameters per `s`.
    pub fn subst(&self, s: &HashMap<ParamId, Ty>) -> Ty {
        if s.is_empty() {
            return self.clone();
        }
        self.map_ty(&mut |t| match t {
            Ty::Param(p) => s.get(&p).cloned().unwrap_or(Ty::Param(p)),
            t => t,
        })
    }
}

/// A struct, enum or opaque type definition.
#[derive(Debug, Clone)]
pub struct TypeDef {
    pub name: String,
    pub module: ModId,
    pub public: bool,
    pub doc: Option<String>,
    /// Type parameters (`struct Set<T>`).
    pub params: Vec<ParamId>,
    pub kind: TypeDefKind,
    pub span: Span,
    pub node: NodeId,
}

#[derive(Debug, Clone)]
pub enum TypeDefKind {
    Struct {
        fields: Vec<FieldDef>,
    },
    Enum {
        variants: Vec<VariantDef>,
    },
    /// A runtime type declared with `extern type` in the prelude (`Err` is `DuckErr *`,
    /// `net.Conn` is `DuckConn *`).
    Opaque {
        c_type: String,
    },
}

#[derive(Debug, Clone)]
pub struct FieldDef {
    pub name: String,
    pub ty: Ty,
    /// Readable from other modules: the struct is `pub` and the field's type mentions no
    /// private type of the struct's module.
    pub public: bool,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct VariantDef {
    pub name: String,
    /// Field names (`Circle(r: float)`) are optional (`Wrap(int)`).
    pub fields: Vec<(Option<String>, Ty)>,
    pub span: Span,
    pub node: NodeId,
}

/// `shape Area { fn area(self): float }`. `self_param` stands for the fitting type (`Self`).
#[derive(Debug, Clone)]
pub struct ShapeDef {
    pub name: String,
    pub module: ModId,
    pub public: bool,
    pub self_param: ParamId,
    pub methods: Vec<ShapeMethod>,
    /// One of the built-in shapes, whose automatic instances the compiler derives.
    pub builtin: Option<Builtin>,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct ShapeMethod {
    pub name: String,
    /// Every parameter, `self` included (as `Param(self_param)`).
    pub params: Vec<Ty>,
    pub ret: Ty,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Builtin {
    Show,
    Ord,
    Eq,
    Data,
}

#[derive(Debug, Clone)]
pub struct TypeParam {
    pub name: String,
    pub bounds: Vec<ShapeId>,
    /// An implicit parameter created for a shape name used as a type (`fn f(x: Show)`).
    pub implicit: bool,
}

/// Every definition, indexed by `DefId`, `ShapeId` and `ParamId`.
#[derive(Debug, Default, Clone)]
pub struct Defs {
    pub types: Vec<TypeDef>,
    pub shapes: Vec<ShapeDef>,
    pub params: Vec<TypeParam>,
}

impl Defs {
    pub fn fields(&self, d: DefId) -> &[FieldDef] {
        match &self.types[d].kind {
            TypeDefKind::Struct { fields } => fields,
            _ => &[],
        }
    }

    pub fn variants(&self, d: DefId) -> &[VariantDef] {
        match &self.types[d].kind {
            TypeDefKind::Enum { variants } => variants,
            _ => &[],
        }
    }

    pub fn is_enum(&self, d: DefId) -> bool {
        matches!(self.types[d].kind, TypeDefKind::Enum { .. })
    }

    pub fn is_struct(&self, d: DefId) -> bool {
        matches!(self.types[d].kind, TypeDefKind::Struct { .. })
    }

    /// The substitution from a type definition's parameters to `args`.
    pub fn subst_of(&self, d: DefId, args: &[Ty]) -> HashMap<ParamId, Ty> {
        self.types[d].params.iter().copied().zip(args.iter().cloned()).collect()
    }

    /// Source-like rendering: `[int]`, `{str: Todo}`, `Resp!`, `any Show`, `(int) => str`.
    pub fn show(&self, t: &Ty) -> String {
        let mut s = String::new();
        self.fmt(t, &mut s);
        s
    }

    fn fmt(&self, t: &Ty, out: &mut String) {
        match t {
            Ty::Int => out.push_str("int"),
            Ty::Float => out.push_str("float"),
            Ty::Bool => out.push_str("bool"),
            Ty::Char => out.push_str("char"),
            Ty::Str => out.push_str("str"),
            Ty::Never => out.push_str("never"),
            Ty::List(t) => {
                out.push('[');
                self.fmt(t, out);
                out.push(']');
            }
            Ty::Map(k, v) => {
                out.push('{');
                self.fmt(k, out);
                out.push_str(": ");
                self.fmt(v, out);
                out.push('}');
            }
            Ty::Tuple(ts) => {
                out.push('(');
                for (i, t) in ts.iter().enumerate() {
                    if i > 0 {
                        out.push_str(", ");
                    }
                    self.fmt(t, out);
                }
                out.push(')');
            }
            Ty::Opt(t) => {
                self.fmt_inner(t, out);
                out.push('?');
            }
            Ty::Res(t, e) => {
                self.fmt_inner(t, out);
                out.push('!');
                if !self.is_err(e) {
                    self.fmt(e, out);
                }
            }
            Ty::Named(d, args) => {
                out.push_str(&self.types[*d].name);
                if !args.is_empty() {
                    out.push('<');
                    for (i, t) in args.iter().enumerate() {
                        if i > 0 {
                            out.push_str(", ");
                        }
                        self.fmt(t, out);
                    }
                    out.push('>');
                }
            }
            Ty::Param(p) => out.push_str(&self.params[*p].name),
            Ty::Any(s) => {
                let _ = write!(out, "any {}", self.shapes[*s].name);
            }
            Ty::Fn(ps, r) => {
                out.push('(');
                for (i, t) in ps.iter().enumerate() {
                    if i > 0 {
                        out.push_str(", ");
                    }
                    self.fmt(t, out);
                }
                out.push_str(") => ");
                self.fmt(r, out);
            }
            Ty::Task(t) => {
                out.push_str("task of ");
                self.fmt(t, out);
            }
            Ty::Measured(t, u) => {
                self.fmt(t, out);
                let _ = write!(out, "<{u}>");
            }
            Ty::Var(_) => out.push('_'),
            Ty::Error => out.push_str("{error}"),
        }
    }

    /// `T?` and `T!` bind tighter than `=>` but a closure type inside needs parentheses.
    fn fmt_inner(&self, t: &Ty, out: &mut String) {
        if matches!(t, Ty::Fn(..)) {
            out.push('(');
            self.fmt(t, out);
            out.push(')');
        } else {
            self.fmt(t, out);
        }
    }

    /// Is `t` the core `Err` type?
    pub fn is_err(&self, t: &Ty) -> bool {
        matches!(t, Ty::Named(d, _) if self.types[*d].name == "Err" && matches!(self.types[*d].kind, TypeDefKind::Opaque { .. }))
    }
}

/// Inference variables with a trail, so a tentative unification can be undone.
#[derive(Debug, Default)]
pub struct Infer {
    vars: Vec<Option<Ty>>,
    trail: Vec<u32>,
}

impl Infer {
    pub fn fresh(&mut self) -> Ty {
        self.vars.push(None);
        Ty::Var(self.vars.len() as u32 - 1)
    }

    pub fn snapshot(&self) -> usize {
        self.trail.len()
    }

    pub fn rollback(&mut self, snap: usize) {
        while self.trail.len() > snap {
            let v = self.trail.pop().unwrap();
            self.vars[v as usize] = None;
        }
    }

    /// Follow bound variables at the top only.
    pub fn shallow(&self, t: &Ty) -> Ty {
        let mut t = t.clone();
        while let Ty::Var(v) = t {
            match &self.vars[v as usize] {
                Some(b) => t = b.clone(),
                None => return t,
            }
        }
        t
    }

    /// Substitute every bound variable, deeply.
    pub fn resolve(&self, t: &Ty) -> Ty {
        t.map_ty(&mut |t| match t {
            Ty::Var(v) => match &self.vars[v as usize] {
                Some(b) => self.resolve(b),
                None => Ty::Var(v),
            },
            t => t,
        })
    }

    fn bind(&mut self, v: u32, t: Ty) {
        self.vars[v as usize] = Some(t);
        self.trail.push(v);
    }

    fn occurs(&self, v: u32, t: &Ty) -> bool {
        let t = self.resolve(t);
        let mut yes = false;
        t.walk(&mut |x| yes |= *x == Ty::Var(v));
        yes
    }

    /// Make `a` and `b` equal. `Never` and `Error` are compatible with anything (and bind
    /// nothing). On failure some variables may already be bound: callers that want an
    /// all-or-nothing attempt use `try_unify`.
    pub fn unify(&mut self, a: &Ty, b: &Ty) -> bool {
        let (a, b) = (self.shallow(a), self.shallow(b));
        match (&a, &b) {
            (Ty::Error, _) | (_, Ty::Error) | (Ty::Never, _) | (_, Ty::Never) => true,
            (Ty::Var(x), Ty::Var(y)) if x == y => true,
            (Ty::Var(x), t) | (t, Ty::Var(x)) => {
                if self.occurs(*x, t) {
                    return false;
                }
                self.bind(*x, t.clone());
                true
            }
            (Ty::List(x), Ty::List(y)) | (Ty::Opt(x), Ty::Opt(y)) | (Ty::Task(x), Ty::Task(y)) => self.unify(x, y),
            (Ty::Measured(x, u), Ty::Measured(y, v)) => u == v && self.unify(x, y),
            (Ty::Map(a1, b1), Ty::Map(a2, b2)) | (Ty::Res(a1, b1), Ty::Res(a2, b2)) => self.unify(a1, a2) && self.unify(b1, b2),
            (Ty::Tuple(xs), Ty::Tuple(ys)) => xs.len() == ys.len() && xs.iter().zip(ys).all(|(x, y)| self.unify(x, y)),
            (Ty::Named(d1, xs), Ty::Named(d2, ys)) => d1 == d2 && xs.len() == ys.len() && xs.iter().zip(ys).all(|(x, y)| self.unify(x, y)),
            (Ty::Fn(p1, r1), Ty::Fn(p2, r2)) => p1.len() == p2.len() && p1.iter().zip(p2).all(|(x, y)| self.unify(x, y)) && self.unify(r1, r2),
            (x, y) => x == y,
        }
    }

    /// Unify, or leave every variable as it was.
    pub fn try_unify(&mut self, a: &Ty, b: &Ty) -> bool {
        let snap = self.snapshot();
        if self.unify(a, b) {
            true
        } else {
            self.rollback(snap);
            false
        }
    }

    /// Could `a` and `b` unify? Binds nothing.
    pub fn can_unify(&mut self, a: &Ty, b: &Ty) -> bool {
        let snap = self.snapshot();
        let ok = self.unify(a, b);
        self.rollback(snap);
        ok
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unify_and_rollback() {
        let mut inf = Infer::default();
        let a = inf.fresh();
        let b = inf.fresh();
        assert!(inf.unify(&Ty::list(a.clone()), &Ty::list(Ty::Int)));
        assert_eq!(inf.resolve(&a), Ty::Int);
        let snap = inf.snapshot();
        assert!(inf.unify(&b, &Ty::Str));
        inf.rollback(snap);
        assert_eq!(inf.resolve(&b), b);
        assert!(!inf.try_unify(&Ty::Tuple(vec![b.clone(), Ty::Int]), &Ty::Tuple(vec![Ty::Str, Ty::Bool])));
        assert_eq!(inf.resolve(&b), b, "a failed try_unify binds nothing");
        assert!(!inf.unify(&b, &Ty::list(b.clone())), "occurs check");
        assert!(inf.unify(&Ty::Never, &Ty::Str));
    }

    #[test]
    fn show_types() {
        let d = Defs::default();
        assert_eq!(d.show(&Ty::map(Ty::Str, Ty::list(Ty::opt(Ty::Int)))), "{str: [int?]}");
        assert_eq!(d.show(&Ty::func(vec![Ty::Int], Ty::Bool)), "(int) => bool");
        assert_eq!(d.show(&Ty::unit()), "()");
    }
}

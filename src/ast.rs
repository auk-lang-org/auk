//! The syntax tree. Every expression, pattern and type (and every item, block and parameter)
//! has a `Span` and a `NodeId`, unique within a parse, that later phases key side tables on.
//! The tree is purely syntactic: whether `a.b` is a module path or a field, or whether a bare
//! name in a pattern is an enum variant, is decided by name resolution.

use std::fmt::Write;

use super::diag::Span;
use super::units::Units;

pub type NodeId = u32;

#[derive(Debug, Clone, PartialEq)]
pub struct Module {
    /// The `///` block at the top of the file, if it is separated from the first item.
    pub doc: Option<String>,
    pub items: Vec<Item>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Item {
    Fn(FnGroup),
    Struct(StructDef),
    Enum(EnumDef),
    Shape(ShapeDef),
    Test(TestDef),
    /// A top-level `let`: a module constant.
    Let(ConstDef),
    /// `imprint X = e`: evaluated at compile time.
    Imprint(ConstDef),
    /// Prelude only: `extern type Err = "AukErr *"`, an opaque type implemented by the runtime.
    ExternType(ExternTypeDef),
}

/// `extern type Name = "C type"` (core prelude only): an opaque runtime type such as `Err` or
/// `net.Conn`. `c_type` is the C spelling codegen uses for a value of this type.
#[derive(Debug, Clone, PartialEq)]
pub struct ExternTypeDef {
    pub id: NodeId,
    pub span: Span,
    pub name: Ident,
    pub doc: Option<String>,
    pub public: bool,
    pub c_type: String,
}

/// A name with its span.
#[derive(Debug, Clone, PartialEq)]
pub struct Ident {
    pub name: String,
    pub span: Span,
}

impl Ident {
    /// The element number when this is the member of `x?.N` (all digits), else `None`.
    pub fn tuple_index(&self) -> Option<u32> {
        if self.name.is_empty() || !self.name.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        self.name.parse().ok()
    }
}

/// A contiguous run of `fn`s with the same name and number of parameters. The spec's clause
/// group also requires the same first-parameter type; that needs types, so the checker splits a
/// group by first-parameter type (overloads like `show(i: Item)` / `show(o: Order)`).
#[derive(Debug, Clone, PartialEq)]
pub struct FnGroup {
    pub name: String,
    pub arity: usize,
    /// The optional body-less header line (docs, `pub`, contracts) before the clauses.
    pub header: Option<Box<FnClause>>,
    pub clauses: Vec<FnClause>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct FnClause {
    pub id: NodeId,
    pub span: Span,
    pub name: Ident,
    pub doc: Option<String>,
    pub public: bool,
    pub is_async: bool,
    /// `<A: Show, B>`.
    pub generics: Vec<Generic>,
    pub params: Vec<Param>,
    pub ret: Option<Type>,
    /// Effects: `uses fs, net`.
    pub uses: Vec<Ident>,
    pub requires: Vec<Expr>,
    pub ensures: Vec<Expr>,
    /// `when` guard.
    pub guard: Option<Expr>,
    /// `None` for a header line (or a shape method signature).
    pub body: Option<FnBody>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum FnBody {
    /// `= expr`
    Expr(Box<Expr>),
    Block(Block),
    /// Prelude only: `extern fn len(s: str): int = "auk_str_len"`. The symbol names a C function
    /// in the runtime, or a compiler intrinsic when it starts with `@` (see `typed::Intrinsic`).
    Extern(String),
}

/// A function or closure parameter: a pattern with an optional type. `var` marks a parameter
/// that mutates the caller's variable (`xs: var [int]`).
#[derive(Debug, Clone, PartialEq)]
pub struct Param {
    pub id: NodeId,
    pub span: Span,
    pub pat: Pat,
    pub ty: Option<Type>,
    pub var: bool,
}

/// A type parameter with optional shape bounds: `T: Show + Eq`.
#[derive(Debug, Clone, PartialEq)]
pub struct Generic {
    pub name: Ident,
    pub bounds: Vec<Type>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct StructDef {
    pub id: NodeId,
    pub span: Span,
    pub name: Ident,
    pub doc: Option<String>,
    pub public: bool,
    pub generics: Vec<Generic>,
    pub fields: Vec<FieldDef>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct FieldDef {
    pub span: Span,
    pub name: Ident,
    pub ty: Type,
    pub doc: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct EnumDef {
    pub id: NodeId,
    pub span: Span,
    pub name: Ident,
    pub doc: Option<String>,
    pub public: bool,
    pub generics: Vec<Generic>,
    pub variants: Vec<Variant>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Variant {
    pub id: NodeId,
    pub span: Span,
    pub name: Ident,
    pub doc: Option<String>,
    /// `Circle(r: float)`; a field may also be written without a name: `Wrap(int)`.
    pub fields: Vec<VariantField>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct VariantField {
    pub name: Option<Ident>,
    pub ty: Type,
}

/// `shape Area { fn area(self): float }`. Methods are usually body-less signatures.
#[derive(Debug, Clone, PartialEq)]
pub struct ShapeDef {
    pub id: NodeId,
    pub span: Span,
    pub name: Ident,
    pub doc: Option<String>,
    pub public: bool,
    pub generics: Vec<Generic>,
    pub methods: Vec<FnClause>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TestDef {
    pub id: NodeId,
    pub span: Span,
    pub name: String,
    pub doc: Option<String>,
    pub body: Block,
}

/// A top-level `let NAME: T = e` or `imprint NAME: T = e`.
#[derive(Debug, Clone, PartialEq)]
pub struct ConstDef {
    pub id: NodeId,
    pub span: Span,
    pub name: Ident,
    pub doc: Option<String>,
    pub public: bool,
    pub ty: Option<Type>,
    pub value: Expr,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Type {
    pub id: NodeId,
    pub span: Span,
    pub kind: TypeKind,
}

#[derive(Debug, Clone, PartialEq)]
pub enum TypeKind {
    /// `int`, `str`, `Todo`, `net.Conn`, `Set<int>`, `Self`. Primitive types are named types
    /// too, since resolution decides what a name means (`core.str` vs a local `str`).
    Named { path: Vec<Ident>, args: Vec<Type> },
    /// `[T]`
    List(Box<Type>),
    /// `{K: V}`
    Map(Box<Type>, Box<Type>),
    /// `(A, B)`; `()` is the empty tuple.
    Tuple(Vec<Type>),
    /// `T?`
    Optional(Box<Type>),
    /// `T!` (err `None`) or `T!E`.
    Fallible { ok: Box<Type>, err: Option<Box<Type>> },
    /// `any Shape`: dynamic dispatch.
    Any(Box<Type>),
    /// `(A, B) => R`: the type of a closure.
    Fn { params: Vec<Type>, ret: Box<Type> },
    /// `float<m/s>`, `int<px>`: a number type with a unit of measure (`units` is canonical;
    /// a malformed unit was already reported by the parser).
    Measured { base: Box<Type>, units: Units },
}

#[derive(Debug, Clone, PartialEq)]
pub struct Pat {
    pub id: NodeId,
    pub span: Span,
    pub kind: PatKind,
}

#[derive(Debug, Clone, PartialEq)]
pub enum PatKind {
    /// `_`
    Wild,
    /// A bare name: binds, unless resolution finds an enum variant of that name (`Eof`).
    Bind(String),
    /// `0`, `-1`, `"s"`, `'c'`, `true`, `1.5`.
    Lit { lit: Lit, neg: bool },
    /// `(a, b)`
    Tuple(Vec<Pat>),
    /// `[]`, `[a, b]`, `[h, ..t]`, `[.., last]`, `[a, b, ..]`: `head`, then an optional rest,
    /// then `tail` (only non-empty when there is a rest).
    List { head: Vec<Pat>, rest: Option<Rest>, tail: Vec<Pat> },
    /// `Circle(r)`, `Op('-')`, `Shape.Circle(r)`, or a qualified field-less variant
    /// `Need.Required` (`args: None`).
    Variant { path: Vec<Ident>, args: Option<Vec<Pat>> },
    /// `User { name, age: a, .. }`
    Struct { path: Vec<Ident>, fields: Vec<FieldPat>, rest: bool },
    /// `{"k": v}`: keys are literals; extra keys are allowed.
    Map(Vec<(Lit, Pat)>),
    /// `"GET " + rest`
    StrPrefix { prefix: String, rest: Box<Pat> },
    Some(Box<Pat>),
    None,
    Ok(Box<Pat>),
    Err(Box<Pat>),
}

/// The `..` of a list pattern, with an optional binding: `..t`, `.._`.
#[derive(Debug, Clone, PartialEq)]
pub struct Rest {
    pub span: Span,
    pub pat: Option<Box<Pat>>,
}

/// `name: pat`, or the shorthand `name` (`pat: None`).
#[derive(Debug, Clone, PartialEq)]
pub struct FieldPat {
    pub name: Ident,
    pub pat: Option<Pat>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Lit {
    Int(u64),
    Float(f64),
    Bool(bool),
    Char(char),
    /// A string without interpolations.
    Str(String),
}

#[derive(Debug, Clone, PartialEq)]
pub struct Block {
    pub id: NodeId,
    pub span: Span,
    /// Statements are expressions (`Let`, `Assign` and `Assert` only appear here and, except
    /// `Let`, as match-arm and closure bodies). The last one is the block's value.
    pub stmts: Vec<Expr>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Expr {
    pub id: NodeId,
    pub span: Span,
    pub kind: ExprKind,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ExprKind {
    Lit(Lit),
    /// `3.0<m/s>`, `5<px>`: a number literal with a unit of measure (`expr` is the `Lit`).
    Measured { expr: Box<Expr>, units: Units },
    /// A string with at least one interpolation.
    Interp(Vec<InterpPart>),
    Name(String),
    /// `??`
    Hole,
    /// `a.b`: a field, or a module path (`json.parse`); see `Expr::as_path`.
    Field { expr: Box<Expr>, name: Ident },
    /// `t.0`
    TupleField { expr: Box<Expr>, index: u32 },
    /// `f(a, &b)`
    Call { callee: Box<Expr>, args: Vec<Expr> },
    /// `x.f(a)`: means `f(x, a)`, unless `x` names a module (then it is the path call `x.f`).
    MethodCall { recv: Box<Expr>, name: Ident, args: Vec<Expr> },
    /// `x |> f(a)` means `f(x, a)`; `callee` is a name or path, `args` exclude `x`.
    Pipe { lhs: Box<Expr>, callee: Box<Expr>, args: Vec<Expr> },
    /// `x[i]`
    Index { expr: Box<Expr>, index: Box<Expr> },
    /// `x[a..b]`, `x[a..=b]`
    Slice { expr: Box<Expr>, lo: Box<Expr>, hi: Box<Expr>, inclusive: bool },
    Unary { op: UnOp, expr: Box<Expr> },
    Binary { op: BinOp, lhs: Box<Expr>, rhs: Box<Expr> },
    /// `a..b`, `a..=b`
    Range { lo: Box<Expr>, hi: Box<Expr>, inclusive: bool },
    /// `x is pat`
    Is { expr: Box<Expr>, pat: Pat },
    /// Postfix `?`: pass the error or missing value up.
    Try(Box<Expr>),
    /// Postfix `!`: unwrap or panic.
    Unwrap(Box<Expr>),
    /// `x?.f`, `x?.f(a)` or `x?.N` (a tuple element: `name` is the digits, `args` is `None`):
    /// optional chaining on `T?`.
    OptChain { expr: Box<Expr>, name: Ident, args: Option<Vec<Expr>> },
    /// `e else fallback`, `e else err => fallback`.
    Else { expr: Box<Expr>, arm: ElseArm },
    Await(Box<Expr>),
    /// `await any ts`: wait for the first task of the list `ts` to finish: `(index, T!)`.
    AwaitAny(Box<Expr>),
    /// `catch e`: e's value as `T!`; a panic while evaluating it becomes an `Err`.
    Catch(Box<Expr>),
    /// `&x`: marks a `var` argument; only valid directly as a call argument.
    Ref(Box<Expr>),
    /// `x => body`, `(a, b: int) => body`. A closure passed where one tuple parameter is
    /// expected unpacks it: `pairs.map((i, x) => ...)` (decided by the checker).
    Closure { params: Vec<Param>, body: Box<Expr> },
    /// `els` is another `If` (for `else if`) or a `Block`.
    If { cond: Box<Expr>, then: Block, els: Option<Box<Expr>> },
    Match { scrut: Box<Expr>, arms: Vec<Arm> },
    Loop(Block),
    While { cond: Box<Expr>, body: Block },
    /// `for pat in e`, `for i, pat in e`.
    For { index: Option<Pat>, pat: Pat, iter: Box<Expr>, body: Block },
    Block(Block),
    /// `let pat: T = value else ...` (or `var`). A top-level `else` after the value is always
    /// stored here; the checker decides whether it handles a refutable pattern
    /// (`let [h, ..t] = xs else ...`) or a missing/failed value (`let n = parse(s) else 0`),
    /// which can't be told apart before names and types are known.
    Let { mutable: bool, pat: Pat, ty: Option<Type>, value: Box<Expr>, els: Option<ElseArm> },
    /// `target = value`, `target += value` (`op` is the compound operator).
    Assign { op: Option<BinOp>, target: Box<Expr>, value: Box<Expr> },
    Assert(Box<Expr>),
    Return(Option<Box<Expr>>),
    Break(Option<Box<Expr>>),
    Continue,
    /// `peek e`: prints the source text of `e` (its span) and its value.
    Peek(Box<Expr>),
    /// `Point { x: 1.0, y, ..base }`
    Struct { path: Vec<Ident>, fields: Vec<FieldInit>, base: Option<Box<Expr>> },
    List(Vec<Expr>),
    Map(Vec<(Expr, Expr)>),
    /// `(a, b)`; `()` is the unit value.
    Tuple(Vec<Expr>),
}

/// The part after `else`: an optional error binder (`e =>`) and the fallback.
#[derive(Debug, Clone, PartialEq)]
pub struct ElseArm {
    pub binder: Option<Ident>,
    pub body: Box<Expr>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Arm {
    pub span: Span,
    pub pat: Pat,
    pub guard: Option<Expr>,
    pub body: Expr,
}

/// `name: value`, or the shorthand `name` (`value: None`).
#[derive(Debug, Clone, PartialEq)]
pub struct FieldInit {
    pub name: Ident,
    pub value: Option<Expr>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum InterpPart {
    Lit(String),
    /// `{expr}` or `{expr:spec}`
    Expr { expr: Box<Expr>, spec: Option<String> },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UnOp {
    Neg,
    Not,
    /// `~x` on `int`
    BitNot,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BinOp {
    Add,
    Sub,
    Mul,
    Div,
    Rem,
    Pow,
    AddWrap,
    SubWrap,
    MulWrap,
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
    And,
    Or,
    BitAnd,
    BitOr,
    BitXor,
    Shl,
    Shr,
}

impl UnOp {
    pub fn symbol(self) -> &'static str {
        match self {
            UnOp::Neg => "-",
            UnOp::Not => "!",
            UnOp::BitNot => "~",
        }
    }
}

impl BinOp {
    pub fn symbol(self) -> &'static str {
        match self {
            BinOp::Add => "+",
            BinOp::Sub => "-",
            BinOp::Mul => "*",
            BinOp::Div => "/",
            BinOp::Rem => "%",
            BinOp::Pow => "**",
            BinOp::AddWrap => "+%",
            BinOp::SubWrap => "-%",
            BinOp::MulWrap => "*%",
            BinOp::Eq => "==",
            BinOp::Ne => "!=",
            BinOp::Lt => "<",
            BinOp::Le => "<=",
            BinOp::Gt => ">",
            BinOp::Ge => ">=",
            BinOp::And => "&&",
            BinOp::Or => "||",
            BinOp::BitAnd => "&",
            BinOp::BitOr => "|",
            BinOp::BitXor => "^",
            BinOp::Shl => "<<",
            BinOp::Shr => ">>",
        }
    }
}

// ---- debug dump: an S-expression rendering used by `auk parse --ast` and tests ----

impl Module {
    pub fn dump(&self) -> String {
        let mut out = String::new();
        if let Some(d) = &self.doc {
            let _ = writeln!(out, "(doc {d:?})");
        }
        for item in &self.items {
            out += &item_dump(item);
            out.push('\n');
        }
        out
    }
}

fn join<T>(xs: &[T], f: impl Fn(&T) -> String) -> String {
    xs.iter().map(f).collect::<Vec<_>>().join(" ")
}

fn path_str(p: &[Ident]) -> String {
    p.iter().map(|i| i.name.as_str()).collect::<Vec<_>>().join(".")
}

fn generics_dump(gs: &[Generic]) -> String {
    if gs.is_empty() {
        return String::new();
    }
    let g = gs
        .iter()
        .map(|g| {
            let b = g.bounds.iter().map(type_dump).collect::<Vec<_>>().join(" + ");
            if b.is_empty() { g.name.name.clone() } else { format!("{}: {b}", g.name.name) }
        })
        .collect::<Vec<_>>()
        .join(", ");
    format!(" <{g}>")
}

fn item_dump(item: &Item) -> String {
    let vis = |p: bool| if p { "pub " } else { "" };
    match item {
        Item::Fn(g) => {
            let mut s = format!("(fn {}/{}", g.name, g.arity);
            if let Some(h) = &g.header {
                s += &format!("\n  {}", clause_dump("header", h));
            }
            for c in &g.clauses {
                s += &format!("\n  {}", clause_dump("clause", c));
            }
            s + ")"
        }
        Item::Struct(d) => {
            let fields = join(&d.fields, |f| format!("({} {})", f.name.name, type_dump(&f.ty)));
            format!("({}struct {}{} {fields})", vis(d.public), d.name.name, generics_dump(&d.generics))
        }
        Item::Enum(d) => {
            let vs = join(&d.variants, |v| {
                if v.fields.is_empty() {
                    return v.name.name.clone();
                }
                let fs = join(&v.fields, |f| match &f.name {
                    Some(n) => format!("({} {})", n.name, type_dump(&f.ty)),
                    None => type_dump(&f.ty),
                });
                format!("({} {fs})", v.name.name)
            });
            format!("({}enum {}{} {vs})", vis(d.public), d.name.name, generics_dump(&d.generics))
        }
        Item::Shape(d) => {
            let ms = join(&d.methods, |m| clause_dump("method", m));
            format!("({}shape {}{} {ms})", vis(d.public), d.name.name, generics_dump(&d.generics))
        }
        Item::Test(t) => format!("(test {:?} {})", t.name, block_dump(&t.body)),
        Item::Let(c) | Item::Imprint(c) => {
            let kw = if matches!(item, Item::Let(_)) { "let" } else { "imprint" };
            let ty = c.ty.as_ref().map(|t| format!(" : {}", type_dump(t))).unwrap_or_default();
            format!("({}{kw} {}{ty} {})", vis(c.public), c.name.name, expr_dump(&c.value))
        }
        Item::ExternType(t) => format!("({}extern type {} {:?})", vis(t.public), t.name.name, t.c_type),
    }
}

fn clause_dump(tag: &str, c: &FnClause) -> String {
    let mut s = format!("({tag}");
    if c.public {
        s += " pub";
    }
    if c.is_async {
        s += " async";
    }
    s += &generics_dump(&c.generics);
    s += &if c.params.is_empty() { " (params)".to_string() } else { format!(" (params {})", join(&c.params, param_dump)) };
    if let Some(t) = &c.ret {
        s += &format!(" : {}", type_dump(t));
    }
    if !c.uses.is_empty() {
        s += &format!(" (uses {})", join(&c.uses, |u| u.name.clone()));
    }
    for e in &c.requires {
        s += &format!(" (requires {})", expr_dump(e));
    }
    for e in &c.ensures {
        s += &format!(" (ensures {})", expr_dump(e));
    }
    if let Some(g) = &c.guard {
        s += &format!(" (when {})", expr_dump(g));
    }
    match &c.body {
        Some(FnBody::Expr(e)) => s += &format!(" = {}", expr_dump(e)),
        Some(FnBody::Block(b)) => s += &format!(" {}", block_dump(b)),
        Some(FnBody::Extern(sym)) => s += &format!(" (extern {sym:?})"),
        None => {}
    }
    s + ")"
}

fn param_dump(p: &Param) -> String {
    match &p.ty {
        None => pat_dump(&p.pat),
        Some(t) => format!("({}: {}{})", pat_dump(&p.pat), if p.var { "var " } else { "" }, type_dump(t)),
    }
}

/// Types print in source syntax.
pub fn type_dump(t: &Type) -> String {
    match &t.kind {
        TypeKind::Named { path, args } if args.is_empty() => path_str(path),
        TypeKind::Named { path, args } => {
            format!("{}<{}>", path_str(path), args.iter().map(type_dump).collect::<Vec<_>>().join(", "))
        }
        TypeKind::List(t) => format!("[{}]", type_dump(t)),
        TypeKind::Map(k, v) => format!("{{{}: {}}}", type_dump(k), type_dump(v)),
        TypeKind::Tuple(ts) => format!("({})", ts.iter().map(type_dump).collect::<Vec<_>>().join(", ")),
        TypeKind::Optional(t) => format!("{}?", type_dump(t)),
        TypeKind::Fallible { ok, err: None } => format!("{}!", type_dump(ok)),
        TypeKind::Fallible { ok, err: Some(e) } => format!("{}!{}", type_dump(ok), type_dump(e)),
        TypeKind::Any(t) => format!("any {}", type_dump(t)),
        TypeKind::Fn { params, ret } => {
            format!("({}) => {}", params.iter().map(type_dump).collect::<Vec<_>>().join(", "), type_dump(ret))
        }
        TypeKind::Measured { base, units } => format!("{}<{units}>", type_dump(base)),
    }
}

fn lit_dump(l: &Lit) -> String {
    match l {
        Lit::Int(n) => n.to_string(),
        Lit::Float(x) => format!("{x:?}"),
        Lit::Bool(b) => b.to_string(),
        Lit::Char(c) => format!("{c:?}"),
        Lit::Str(s) => format!("{s:?}"),
    }
}

pub fn pat_dump(p: &Pat) -> String {
    match &p.kind {
        PatKind::Wild => "_".into(),
        PatKind::Bind(n) => n.clone(),
        PatKind::Lit { lit, neg } => format!("{}{}", if *neg { "-" } else { "" }, lit_dump(lit)),
        PatKind::Tuple(ps) if ps.is_empty() => "(tuple)".into(),
        PatKind::Tuple(ps) => format!("(tuple {})", join(ps, pat_dump)),
        PatKind::List { head, rest, tail } => {
            let mut parts: Vec<String> = head.iter().map(pat_dump).collect();
            if let Some(r) = rest {
                parts.push(match &r.pat {
                    Some(p) => format!("(.. {})", pat_dump(p)),
                    None => "..".into(),
                });
            }
            parts.extend(tail.iter().map(pat_dump));
            if parts.is_empty() { "(list)".into() } else { format!("(list {})", parts.join(" ")) }
        }
        PatKind::Variant { path, args: None } => path_str(path),
        PatKind::Variant { path, args: Some(a) } if a.is_empty() => format!("({})", path_str(path)),
        PatKind::Variant { path, args: Some(a) } => format!("({} {})", path_str(path), join(a, pat_dump)),
        PatKind::Struct { path, fields, rest } => {
            let mut s = format!("(struct {}", path_str(path));
            for f in fields {
                s += &match &f.pat {
                    Some(p) => format!(" ({} {})", f.name.name, pat_dump(p)),
                    None => format!(" {}", f.name.name),
                };
            }
            if *rest {
                s += " ..";
            }
            s + ")"
        }
        PatKind::Map(es) if es.is_empty() => "(map)".into(),
        PatKind::Map(es) => format!("(map {})", join(es, |(k, v)| format!("({} {})", lit_dump(k), pat_dump(v)))),
        PatKind::StrPrefix { prefix, rest } => format!("(prefix {prefix:?} {})", pat_dump(rest)),
        PatKind::Some(p) => format!("(some {})", pat_dump(p)),
        PatKind::None => "none".into(),
        PatKind::Ok(p) => format!("(ok {})", pat_dump(p)),
        PatKind::Err(p) => format!("(err {})", pat_dump(p)),
    }
}

fn block_dump(b: &Block) -> String {
    if b.stmts.is_empty() {
        return "(block)".into();
    }
    format!("(block {})", join(&b.stmts, expr_dump))
}

fn args_dump(args: &[Expr]) -> String {
    args.iter().map(|a| format!(" {}", expr_dump(a))).collect()
}

fn else_dump(a: &ElseArm) -> String {
    match &a.binder {
        Some(b) => format!("{} => {}", b.name, expr_dump(&a.body)),
        None => expr_dump(&a.body),
    }
}

pub fn expr_dump(e: &Expr) -> String {
    let d = |e: &Expr| expr_dump(e);
    match &e.kind {
        ExprKind::Lit(l) => lit_dump(l),
        ExprKind::Measured { expr, units } => format!("{}<{units}>", d(expr)),
        ExprKind::Interp(parts) => {
            let ps = join(parts, |p| match p {
                InterpPart::Lit(s) => format!("{s:?}"),
                InterpPart::Expr { expr, spec: None } => d(expr),
                InterpPart::Expr { expr, spec: Some(s) } => format!("(fmt {} {s:?})", d(expr)),
            });
            format!("(str {ps})")
        }
        ExprKind::Name(n) => n.clone(),
        ExprKind::Hole => "??".into(),
        ExprKind::Field { expr, name } => format!("(. {} {})", d(expr), name.name),
        ExprKind::TupleField { expr, index } => format!("(. {} {index})", d(expr)),
        ExprKind::Call { callee, args } => format!("(call {}{})", d(callee), args_dump(args)),
        ExprKind::MethodCall { recv, name, args } => format!("(method {} {}{})", d(recv), name.name, args_dump(args)),
        ExprKind::Pipe { lhs, callee, args } => format!("(|> {} {}{})", d(lhs), d(callee), args_dump(args)),
        ExprKind::Index { expr, index } => format!("(index {} {})", d(expr), d(index)),
        ExprKind::Slice { expr, lo, hi, inclusive } => {
            format!("(slice {} {} {} {})", d(expr), d(lo), if *inclusive { "..=" } else { ".." }, d(hi))
        }
        ExprKind::Unary { op, expr } => format!("({} {})", op.symbol(), d(expr)),
        ExprKind::Binary { op, lhs, rhs } => format!("({} {} {})", op.symbol(), d(lhs), d(rhs)),
        ExprKind::Range { lo, hi, inclusive } => format!("({} {} {})", if *inclusive { "..=" } else { ".." }, d(lo), d(hi)),
        ExprKind::Is { expr, pat } => format!("(is {} {})", d(expr), pat_dump(pat)),
        ExprKind::Try(e) => format!("(? {})", d(e)),
        ExprKind::Unwrap(e) => format!("(unwrap {})", d(e)),
        ExprKind::OptChain { expr, name, args: None } => format!("(?. {} {})", d(expr), name.name),
        ExprKind::OptChain { expr, name, args: Some(a) } => format!("(?. {} {} (args{}))", d(expr), name.name, args_dump(a)),
        ExprKind::Else { expr, arm } => format!("(else {} {})", d(expr), else_dump(arm)),
        ExprKind::Await(e) => format!("(await {})", d(e)),
        ExprKind::Catch(e) => format!("(catch {})", d(e)),
        ExprKind::AwaitAny(e) => format!("(await-any {})", d(e)),
        ExprKind::Ref(e) => format!("(& {})", d(e)),
        ExprKind::Closure { params, body } => format!("(closure ({}) {})", join(params, param_dump), d(body)),
        ExprKind::If { cond, then, els } => match els {
            Some(x) => format!("(if {} {} {})", d(cond), block_dump(then), d(x)),
            None => format!("(if {} {})", d(cond), block_dump(then)),
        },
        ExprKind::Match { scrut, arms } => {
            let arms = join(arms, |a| match &a.guard {
                Some(g) => format!("({} when {} => {})", pat_dump(&a.pat), d(g), d(&a.body)),
                None => format!("({} => {})", pat_dump(&a.pat), d(&a.body)),
            });
            format!("(match {} {arms})", d(scrut))
        }
        ExprKind::Loop(b) => format!("(loop {})", block_dump(b)),
        ExprKind::While { cond, body } => format!("(while {} {})", d(cond), block_dump(body)),
        ExprKind::For { index, pat, iter, body } => {
            let i = index.as_ref().map(|i| format!("{} ", pat_dump(i))).unwrap_or_default();
            format!("(for {i}{} {} {})", pat_dump(pat), d(iter), block_dump(body))
        }
        ExprKind::Block(b) => block_dump(b),
        ExprKind::Let { mutable, pat, ty, value, els } => {
            let ty = ty.as_ref().map(|t| format!(" : {}", type_dump(t))).unwrap_or_default();
            let els = els.as_ref().map(|a| format!(" (else {})", else_dump(a))).unwrap_or_default();
            format!("({} {}{ty} {}{els})", if *mutable { "var" } else { "let" }, pat_dump(pat), d(value))
        }
        ExprKind::Assign { op, target, value } => {
            format!("({}= {} {})", op.map(|o| o.symbol()).unwrap_or(""), d(target), d(value))
        }
        ExprKind::Assert(e) => format!("(assert {})", d(e)),
        ExprKind::Return(e) => e.as_ref().map(|e| format!("(return {})", d(e))).unwrap_or("(return)".into()),
        ExprKind::Break(e) => e.as_ref().map(|e| format!("(break {})", d(e))).unwrap_or("(break)".into()),
        ExprKind::Continue => "(continue)".into(),
        ExprKind::Peek(e) => format!("(peek {})", d(e)),
        ExprKind::Struct { path, fields, base } => {
            let mut s = format!("(new {}", path_str(path));
            for f in fields {
                s += &match &f.value {
                    Some(v) => format!(" ({} {})", f.name.name, d(v)),
                    None => format!(" {}", f.name.name),
                };
            }
            if let Some(b) = base {
                s += &format!(" (.. {})", d(b));
            }
            s + ")"
        }
        ExprKind::List(xs) => format!("(list{})", args_dump(xs)),
        ExprKind::Map(es) => format!("(map{})", es.iter().map(|(k, v)| format!(" ({} {})", d(k), d(v))).collect::<String>()),
        ExprKind::Tuple(xs) => format!("(tuple{})", args_dump(xs)),
    }
}

/// The syntax tree (src/ast.rs). Every expression, pattern and type (and every item, block
/// and parameter) has a span and a node id, unique within a parse, that later phases key side
/// tables on. Rust's struct-like variants become positional fields here.

pub struct Module { doc: str?, items: [Item] }

pub enum Item {
  Fn(g: FnGroup),
  Struct(d: StructDef),
  Enum(d: EnumDef),
  Shape(d: ShapeDef),
  Test(d: TestDef),
  /// A top-level `let`: a module constant.
  Let(c: ConstDef),
  /// `imprint X = e`: evaluated at compile time.
  Imprint(c: ConstDef),
  /// Prelude only: `extern type Err = "AukErr *"`.
  ExternType(d: ExternTypeDef),
  /// The runtime's dialect: `raw var`, `raw thread var`, `raw let`, `export var`.
  Global(d: GlobalDef),
  /// The runtime's dialect: `raw assert e`, checked at compile time.
  RawAssert(a: RawAssertDef),
  /// The runtime's dialect: `raw type NAME = T`, a transparent alias of a raw type.
  RawType(d: RawTypeDef),
}

/// `raw type NAME = T`: `NAME` means `T` (a raw type) wherever it is written.
pub struct RawTypeDef { id: int, span: diag.Span, name: Ident, doc: str?, public: bool, ty: Type }

/// `raw var NAME: T = e` (kind 0), `raw thread var` (1), `raw let NAME[: T] = e` (2), `export
/// var NAME: T = e` (3), `extern var NAME: T = "c_symbol"` (4: a C global defined elsewhere;
/// `value` is the symbol's string literal).
pub struct GlobalDef {
  id: int,
  span: diag.Span,
  name: Ident,
  doc: str?,
  public: bool,
  kind: int,
  ty: Type?,
  value: Expr,
}

pub struct RawAssertDef { id: int, span: diag.Span, expr: Expr }

/// The keywords of a `GlobalDef` of `kind`.
pub fn global_kw(kind: int): str = match kind {
  0 => "raw var"
  1 => "raw thread var"
  2 => "raw let"
  3 => "export var"
  _ => "extern var"
}

pub struct ExternTypeDef {
  id: int,
  span: diag.Span,
  name: Ident,
  doc: str?,
  public: bool,
  c_type: str,
}

/// A name with its span.
pub struct Ident { name: str, span: diag.Span }

/// A contiguous run of `fn`s with the same name and number of parameters.
pub struct FnGroup {
  name: str,
  arity: int,
  /// The optional body-less header line (docs, `pub`, contracts) before the clauses.
  header: FnClause?,
  clauses: [FnClause],
}

pub struct FnClause {
  id: int,
  span: diag.Span,
  name: Ident,
  doc: str?,
  public: bool,
  is_async: bool,
  generics: [Generic],
  params: [Param],
  /// The span of a variadic tail `...` after the parameters: an `extern fn` of a C varargs
  /// function (the runtime's dialect, docs/lowlevel.md 7a).
  variadic: diag.Span?,
  ret: Type?,
  effects: [Ident],
  pre: [Expr],
  post: [Expr],
  guard: Expr?,
  /// `none` for a header line (or a shape method signature).
  body: FnBody?,
  /// The runtime's dialect: 1 `export fn` (C's calling convention, its name as the symbol), 2
  /// `inline export fn` (also `inlinehint`), 3 `noinline export fn` (also `noinline`: never
  /// inlined, nor offered to programs by `rtlink`); 0 otherwise.
  export: int,
}

pub enum FnBody {
  /// `= expr`
  Expr(e: Expr),
  Block(b: Block),
  /// Prelude only: `extern fn len(s: str): int = "auk_str_len"`.
  Extern(sym: str),
}

/// A function or closure parameter: a pattern with an optional type; `var` mutates the
/// caller's variable.
pub struct Param { id: int, span: diag.Span, pat: Pat, ty: Type?, var_: bool }

/// A type parameter with optional shape bounds: `T: Show + Eq`.
pub struct Generic { name: Ident, bounds: [Type] }

pub struct StructDef {
  id: int,
  span: diag.Span,
  name: Ident,
  doc: str?,
  public: bool,
  generics: [Generic],
  fields: [FieldDef],
  /// The runtime's dialect (docs/lowlevel.md): 0 a plain struct, 1 `raw struct`, 2 `raw union`.
  raw: int,
}

pub struct FieldDef { span: diag.Span, name: Ident, ty: Type, doc: str? }

pub struct EnumDef {
  id: int,
  span: diag.Span,
  name: Ident,
  doc: str?,
  public: bool,
  generics: [Generic],
  variants: [Variant],
}

pub struct Variant { id: int, span: diag.Span, name: Ident, doc: str?, fields: [VariantField] }

pub struct VariantField { name: Ident?, ty: Type }

pub struct ShapeDef {
  id: int,
  span: diag.Span,
  name: Ident,
  doc: str?,
  public: bool,
  generics: [Generic],
  methods: [FnClause],
}

pub struct TestDef { id: int, span: diag.Span, name: str, doc: str?, body: Block }

/// A top-level `let NAME: T = e` or `imprint NAME: T = e`.
pub struct ConstDef {
  id: int,
  span: diag.Span,
  name: Ident,
  doc: str?,
  public: bool,
  ty: Type?,
  value: Expr,
}

pub struct Type { id: int, span: diag.Span, kind: TypeKind }

pub enum TypeKind {
  /// `int`, `str`, `Todo`, `net.Conn`, `Set<int>`, `Self`.
  Named(path: [Ident], args: [Type]),
  List(t: Type),
  Map(k: Type, v: Type),
  /// `()` is the empty tuple.
  Tuple(ts: [Type]),
  Optional(t: Type),
  /// `T!` (err `none`) or `T!E`.
  Fallible(ok: Type, err: Type?),
  Any(t: Type),
  Fn(params: [Type], ret: Type),
  /// `float<m/s>`: `units` is canonical (sorted base names, non-zero exponents).
  Measured(base: Type, units: [(str, int)]),
  /// `var T`: a `var` parameter of a function type (only there): `(var P) => R`.
  Var(t: Type),
  /// `[T; N]` (`n` is -1 for `[T; ..]`): a C array, in the runtime's dialect only.
  Array(t: Type, n: int),
}

pub struct Pat { id: int, span: diag.Span, kind: PatKind }

pub enum PatKind {
  Wild,
  /// A bare name: binds, unless resolution finds an enum variant of that name.
  Bind(name: str),
  Lit(lit: Lit, neg: bool),
  Tuple(ps: [Pat]),
  /// `head`, then an optional rest, then `tail` (only non-empty when there is a rest).
  List(head: [Pat], rest: Rest?, tail: [Pat]),
  /// `Circle(r)`, or a qualified field-less variant `Need.Required` (`args: none`).
  Variant(path: [Ident], args: [Pat]?),
  Struct(path: [Ident], fields: [FieldPat], rest: bool),
  /// `{"k": v}`: keys are literals; extra keys are allowed.
  Map(entries: [(Lit, Pat)]),
  /// `"GET " + rest`
  StrPrefix(prefix: str, rest: Pat),
  Some(p: Pat),
  None,
  Ok(p: Pat),
  Err(p: Pat),
  /// `A | B(x)`: a match arm's alternatives (only at the top of an arm).
  Or(ps: [Pat]),
}

/// The `..` of a list pattern, with an optional binding: `..t`, `.._`.
pub struct Rest { span: diag.Span, pat: Pat? }

/// `name: pat`, or the shorthand `name` (`pat: none`).
pub struct FieldPat { name: Ident, pat: Pat? }

pub enum Lit {
  /// The bits of a u64 (see `token.Tok.Int`).
  Int(n: int),
  Float(x: float),
  Bool(b: bool),
  Char(c: char),
  /// A string without interpolations.
  Str(s: str),
}

pub struct Block { id: int, span: diag.Span, stmts: [Expr] }

pub struct Expr { id: int, span: diag.Span, kind: ExprKind }

pub enum ExprKind {
  Lit(lit: Lit),
  /// `3.0<m/s>`: a number literal with a unit of measure (`expr` is the `Lit`).
  Measured(expr: Expr, units: [(str, int)]),
  /// A string with at least one interpolation.
  Interp(parts: [InterpPart]),
  Name(name: str),
  /// `??`
  Hole,
  Field(expr: Expr, name: Ident),
  TupleField(expr: Expr, index: int),
  Call(callee: Expr, args: [Expr]),
  MethodCall(recv: Expr, name: Ident, args: [Expr]),
  Pipe(lhs: Expr, callee: Expr, args: [Expr]),
  Index(expr: Expr, index: Expr),
  Slice(expr: Expr, lo: Expr, hi: Expr, inclusive: bool),
  Unary(op: UnOp, expr: Expr),
  Binary(op: BinOp, lhs: Expr, rhs: Expr),
  Range(lo: Expr, hi: Expr, inclusive: bool),
  Is(expr: Expr, pat: Pat),
  Try(expr: Expr),
  Unwrap(expr: Expr),
  /// `x?.f`, `x?.f(a)` or `x?.N` (`args` is `none` without parentheses).
  OptChain(expr: Expr, name: Ident, args: [Expr]?),
  Else(expr: Expr, arm: ElseArm),
  Await(expr: Expr),
  AwaitAny(expr: Expr),
  Catch(expr: Expr),
  Ref(expr: Expr),
  Closure(params: [Param], body: Expr),
  /// `els` is another `If` (for `else if`) or a `Block`.
  If(cond: Expr, then: Block, els: Expr?),
  Match(scrut: Expr, arms: [Arm]),
  Loop(body: Block),
  While(cond: Expr, body: Block),
  For(index: Pat?, pat: Pat, iter: Expr, body: Block),
  Block(b: Block),
  Let(mutable: bool, pat: Pat, ty: Type?, value: Expr, els: ElseArm?),
  /// `target = value`, `target += value` (`op` is the compound operator).
  Assign(op: BinOp?, target: Expr, value: Expr),
  Assert(expr: Expr),
  Return(value: Expr?),
  Break(value: Expr?),
  Continue,
  Peek(expr: Expr),
  Struct(path: [Ident], fields: [FieldInit], base: Expr?),
  List(xs: [Expr]),
  Map(entries: [(Expr, Expr)]),
  Tuple(xs: [Expr]),
  /// The runtime's dialect: `raw.f<T, U>(args)`, a call (`expr`) with explicit type arguments.
  TypeArgs(expr: Expr, tys: [Type]),
  /// The runtime's dialect: `.f`, a field named in `raw.offset_of<T>(.f)`, `raw.field_addr(p, .f)`.
  FieldSel(name: Ident),
  /// The runtime's dialect: the missing value of `var x: T` (no initializer; the contents are
  /// undefined until written, as a C local's).
  Uninit,
}

/// The part after `else`: an optional error binder (`e =>`) and the fallback.
pub struct ElseArm { binder: Ident?, body: Expr }

pub struct Arm { span: diag.Span, pat: Pat, guard: Expr?, body: Expr }

/// `name: value`, or the shorthand `name` (`value: none`).
pub struct FieldInit { name: Ident, value: Expr? }

pub enum InterpPart {
  Lit(s: str),
  /// `{expr}` or `{expr:spec}`
  Expr(expr: Expr, spec: str?),
}

pub enum UnOp { Neg, Not, BitNot }

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

pub fn unop_symbol(op: UnOp): str = match op {
  Neg => "-"
  Not => "!"
  BitNot => "~"
}

pub fn symbol(op: BinOp): str = match op {
  Add => "+"
  Sub => "-"
  Mul => "*"
  Div => "/"
  Rem => "%"
  Pow => "**"
  AddWrap => "+%"
  SubWrap => "-%"
  MulWrap => "*%"
  Eq => "=="
  Ne => "!="
  Lt => "<"
  Le => "<="
  Gt => ">"
  Ge => ">="
  And => "&&"
  Or => "||"
  BitAnd => "&"
  BitOr => "|"
  BitXor => "^"
  Shl => "<<"
  Shr => ">>"
}

/// A type as written (src/ast.rs `type_dump`), for messages.
pub fn type_dump(t: Type): str = match t.kind {
  Named(path, args) => if args.len() == 0 {
    path.map(i => i.name).join(".")
  } else {
    path.map(i => i.name).join(".") + "<" + args.map(type_dump).join(", ") + ">"
  }
  List(x) => "[" + type_dump(x) + "]"
  Map(k, v) => "{{" + type_dump(k) + ": " + type_dump(v) + "}}"
  Tuple(ts) => "(" + ts.map(type_dump).join(", ") + ")"
  Optional(x) => type_dump(x) + "?"
  Fallible(ok, err) => match err {
    none => type_dump(ok) + "!"
    some(e) => type_dump(ok) + "!" + type_dump(e)
  }
  Any(x) => "any " + type_dump(x)
  Fn(params, ret) => "(" + params.map(type_dump).join(", ") + ") => " + type_dump(ret)
  Measured(base, us) => type_dump(base) + "<" + units.text(us) + ">"
  Var(x) => "var " + type_dump(x)
  Array(x, n) => "[" + type_dump(x) + (if n < 0 { "; ..]" } else { "; {n}]" })
}

/// Tokens -> AST (src/parser.rs): recursive descent, with precedence climbing for binary
/// operators. See the Rust file for the precedence table and the readings it chooses.
///
/// Rust's `list(close, what, |p| ...)` and `nested(|p| ...)` take closures over `&mut Parser`;
/// Auk closures can't take a `var` parameter, so each list is an explicit loop over
/// `list_end`/`list_sep`, and `nested`/`head` are `lift`/`head_flags` + `restore` around the call.

/// Every diagnostic of a file (`T!E` needs an enum).
pub enum Fails { Many(ds: [diag.Diag]) }

/// An item before clause grouping.
enum Raw {
  RItem(i: ast.Item),
  RClause(c: ast.FnClause),
}

struct Parser {
  toks: [token.Token],
  /// The source, by line, for fix-its that move text.
  lines: [[char]],
  pos: int,
  /// The span of the last consumed token.
  prev: diag.Span,
  next_id: int,
  /// In an `if`/`while`/`for`/`match` head or a contract/guard before a body: a `{` ends the
  /// expression, so there are no struct literals (or struct patterns), and `else` is not taken.
  no_struct: bool,
  /// In a match-arm guard: `x =>` and `(a) =>` end the guard instead of starting a closure.
  no_closure: bool,
  /// Parsing a core prelude file: `extern` declarations are allowed.
  prelude: bool,
  /// Expressions written inside their own parentheses `(a & b)`.
  parened: {int: bool},
}

/// Parse a whole file (`prelude`: a core prelude file, where `extern` items are allowed and
/// functions may be named with keywords). Errors are reported per item: after an error the
/// parser skips to the next line that starts an item, so one file can produce several.
pub fn parse(src: str, prelude: bool): ast.Module!Fails {
  let lexed = match lexer.lex(src) {
    ok(l) => l
    err(Bad(d)) => fail(Many([d]))
  }
  var p = Parser {
    toks: lexed.toks,
    lines: src.lines().map(l => l.chars()),
    pos: 0,
    prev: diag.NONE,
    next_id: 0,
    no_struct: false,
    no_closure: false,
    prelude,
    parened: {},
  }
  var raw: [Raw] = []
  var errs: [diag.Diag] = []
  loop {
    p.skip_newlines()
    if p.at(token.Eof) { break }
    match item(&p) {
      ok(it) => if p.item_ended() {
        raw.push(it)
      } else {
        errs.push(
          p.expected(
            "E0025",
            "a line break after the item",
          ).note("each item (`fn`, `struct`, ...) starts on its own line"),
        )
        p.recover()
      }
      err(Bad(d)) => {
        errs.push(d)
        p.recover()
      }
    }
  }
  let items = group(raw, &errs)
  if errs.len() > 0 { fail(Many(errs)) }
  ast.Module { doc: lexed.module_doc, items }
}

/// Group contiguous `fn`s with the same name and arity (a body-less first one is the header).
/// The open group is kept aside in `cur` (pushing a clause onto a group already in `items`
/// would copy its clause list).
fn group(raw: [Raw], errs: var [diag.Diag]): [ast.Item] {
  var items: [ast.Item] = []
  var cur: ast.FnGroup? = none
  for r in raw {
    match r {
      RItem(i) => {
        match cur {
          some(g) => items.push(ast.Item.Fn(g))
          none => {}
        }
        cur = none
        items.push(i)
      }
      RClause(c) => {
        var g = cur else ast.FnGroup { name: "", arity: -1, header: none, clauses: [] }
        cur = none  // so `g` holds the only reference to its clause list
        if g.name == c.name.name && g.arity == c.params.len() {
          if c.body is none {
            errs.push(
              diag
                .new("E0031", c.name.span, "body-less `fn {c.name.name}` after its clauses")
                .note("a header line (docs, `pub`, contracts) must come before the clauses; otherwise give this `fn` a body"),
            )
          } else {
            g.clauses.push(c)
          }
          cur = g
        } else {
          if g.arity >= 0 { items.push(ast.Item.Fn(g)) }
          let header: ast.FnClause? = if c.body is none { c } else { none }
          let clauses: [ast.FnClause] = if c.body is none { [] } else { [c] }
          cur = ast.FnGroup { name: c.name.name, arity: c.params.len(), header, clauses }
        }
      }
    }
  }
  match cur {
    some(g) => items.push(ast.Item.Fn(g))
    none => {}
  }
  for it in items {
    match it {
      Fn(g) => match g.header {
        some(h) when g.clauses.len() == 0 => errs.push(
          diag
            .new("E0031", h.name.span, "`fn {h.name.name}` has no body and no clauses follow it")
            .note("give it a body (`{{ ... }}` or `= expr`), or follow this header line with clauses `fn {h.name.name}(...)` taking {h.params.len()} parameter(s)"),
        )
        _ => {}
      }
      _ => {}
    }
  }
  items
}

/// Binding powers between `&&` (2) and `|` (6).
let IS = 3
let CMP = 4
let RANGE = 5
let SHIFT = 9

fn binop(t: token.Tok): (ast.BinOp, int)? = match t {
  OrOr => (ast.BinOp.Or, 1)
  AndAnd => (ast.BinOp.And, 2)
  EqEq => (ast.BinOp.Eq, CMP)
  BangEq => (ast.BinOp.Ne, CMP)
  Lt => (ast.BinOp.Lt, CMP)
  Le => (ast.BinOp.Le, CMP)
  Gt => (ast.BinOp.Gt, CMP)
  Ge => (ast.BinOp.Ge, CMP)
  Pipe => (ast.BinOp.BitOr, 6)
  Caret => (ast.BinOp.BitXor, 7)
  Amp => (ast.BinOp.BitAnd, 8)
  Shl => (ast.BinOp.Shl, 9)
  Plus => (ast.BinOp.Add, 10)
  Minus => (ast.BinOp.Sub, 10)
  PlusWrap => (ast.BinOp.AddWrap, 10)
  MinusWrap => (ast.BinOp.SubWrap, 10)
  Star => (ast.BinOp.Mul, 11)
  Slash => (ast.BinOp.Div, 11)
  Percent => (ast.BinOp.Rem, 11)
  StarWrap => (ast.BinOp.MulWrap, 11)
  StarStar => (ast.BinOp.Pow, 12)
  _ => none
}

fn is_bitwise(op: ast.BinOp): bool =
  op == ast.BinOp.BitAnd || op == ast.BinOp.BitOr || op == ast.BinOp.BitXor

/// Is `t` `=` or a compound assignment? (Rust's `assign_op` returns `Option<Option<BinOp>>`;
/// `T??` isn't a type here, so it is split in two.)
fn is_assign(t: token.Tok): bool = match t {
  Eq => true
  PlusEq => true
  MinusEq => true
  StarEq => true
  SlashEq => true
  PercentEq => true
  AmpEq => true
  PipeEq => true
  CaretEq => true
  ShlEq => true
  _ => false
}

fn compound_op(t: token.Tok): ast.BinOp? = match t {
  PlusEq => ast.BinOp.Add
  MinusEq => ast.BinOp.Sub
  StarEq => ast.BinOp.Mul
  SlashEq => ast.BinOp.Div
  PercentEq => ast.BinOp.Rem
  AmpEq => ast.BinOp.BitAnd
  PipeEq => ast.BinOp.BitOr
  CaretEq => ast.BinOp.BitXor
  ShlEq => ast.BinOp.Shl
  _ => none
}

fn is_lvalue(e: ast.Expr): bool = match e.kind {
  Name(_) => true
  Field(x, _) | TupleField(x, _) | Index(x, _) => is_lvalue(x)
  // the runtime's dialect: `p.at(i) = v` (the checker allows it only there)
  MethodCall(_, n, args) => n.name == "at" && args.len() == 1
  _ => false
}

/// An assignment target: an lvalue, or for a plain `=` a tuple of targets (`(a, b) = (b, a)`).
fn is_target(e: ast.Expr, plain: bool): bool = match e.kind {
  Tuple(xs) => plain && xs.len() > 0 && xs.all(x => is_target(x, true))
  _ => is_lvalue(e)
}

fn bad(d: diag.Diag): diag.Fail = diag.Bad(d)

// ---- token helpers ----

fn peek(p: Parser): token.Tok = p.toks[p.pos].tok

fn peek_at(p: Parser, n: int): token.Tok {
  let i = p.pos + n
  if i < p.toks.len() { p.toks[i].tok } else { p.toks[p.toks.len() - 1].tok }
}

fn span(p: Parser): diag.Span = p.toks[p.pos].span

fn at(p: Parser, t: token.Tok): bool = p.peek() == t

/// The source text of `s`.
fn text(p: Parser, s: diag.Span): str {
  var out: [char] = []
  for ln in s.line..=s.end_line {
    if ln - 1 >= p.lines.len() { break }
    let chars = p.lines[ln - 1]
    let from = if ln == s.line { min(s.col - 1, chars.len()) } else { 0 }
    let to = if ln == s.end_line { min(s.end_col - 1, chars.len()) } else { chars.len() }
    out = out + chars[from..max(to, from)]
    if ln != s.end_line { out.push('\n') }
  }
  str(out)
}

fn min(a: int, b: int): int = if a < b { a } else { b }
fn max(a: int, b: int): int = if a > b { a } else { b }

fn bump(p: var Parser): token.Token {
  let t = p.toks[p.pos]
  if p.pos < p.toks.len() - 1 { p.pos += 1 }
  p.prev = t.span
  t
}

fn eat(p: var Parser, t: token.Tok): bool {
  if !p.at(t) { return false }
  p.bump()
  true
}

fn skip_newlines(p: var Parser) {
  while p.at(token.Newline) { p.bump() }
}

fn id(p: var Parser): int {
  p.next_id += 1
  p.next_id
}

/// An error at the current token: "expected {what}, found {token}".
fn expected(p: Parser, code: str, what: str): diag.Diag =
  diag.new(code, p.span(), "expected {what}, found {p.peek().display()}")

fn expect(p: var Parser, t: token.Tok, why: str): diag.Span!diag.Fail {
  if p.at(t) { return p.bump().span }
  let what = if why == "" { "`{t.text()}`" } else { "`{t.text()}` {why}" }
  fail(bad(p.expected("E0020", what)))
}

/// A name after `.` or `?.`, where keywords are plain names too (`pairs.enum()`).
fn member(p: var Parser, what: str): ast.Ident!diag.Fail {
  if p.peek().is_keyword() {
    let name = p.peek().text()
    return ast.Ident { name, span: p.bump().span }
  }
  p.ident(what)
}

fn ident(p: var Parser, what: str): ast.Ident!diag.Fail = match p.peek() {
  Ident(n) when n != "_" => ast.Ident { name: n, span: p.bump().span }
  _ => fail(bad(p.expected("E0020", what)))
}

/// Lift the head restrictions (inside brackets or a block); returns the old ones for `restore`.
fn lift(p: var Parser): (bool, bool) {
  let saved = (p.no_struct, p.no_closure)
  p.no_struct = false
  p.no_closure = false
  saved
}

/// Set the restrictions of a head (an expression followed by a `{` body).
fn head_flags(p: var Parser, no_closure: bool): (bool, bool) {
  let saved = (p.no_struct, p.no_closure)
  p.no_struct = true
  p.no_closure = no_closure
  saved
}

fn restore(p: var Parser, saved: (bool, bool)) {
  p.no_struct = saved.0
  p.no_closure = saved.1
}

fn nested_expr(p: var Parser): ast.Expr!diag.Fail {
  let s = p.lift()
  let r = expr(&p)
  p.restore(s)
  r
}

fn nested_ty(p: var Parser): ast.Type!diag.Fail {
  let s = p.lift()
  let r = ty(&p)
  p.restore(s)
  r
}

/// A type in a parenthesized list, which may be a function type's `var T` parameter.
fn nested_param_ty(p: var Parser): ast.Type!diag.Fail {
  if !p.at(token.Var) { return nested_ty(&p) }
  let start = p.bump().span
  let t = nested_ty(&p)?
  ast.Type { id: p.id(), span: start.to(p.prev), kind: ast.TypeKind.Var(t) }
}

/// `item`s separated by commas up to `close` (which it eats).
fn list(p: var Parser, close: token.Tok, what: str, item: (var Parser) => ast.Type!diag.Fail): [ast.Type]!diag.Fail {
  var xs: [ast.Type] = []
  while !p.list_end(close) {
    xs.push(item(&p)?)
    if p.list_sep(close, what)? { break }
  }
  xs
}

fn nested_pattern(p: var Parser): ast.Pat!diag.Fail {
  let s = p.lift()
  let r = pattern(&p)
  p.restore(s)
  r
}

fn nested_param(p: var Parser): ast.Param!diag.Fail {
  let s = p.lift()
  let r = param(&p)
  p.restore(s)
  r
}

fn head_expr(p: var Parser): ast.Expr!diag.Fail {
  let s = p.head_flags(false)
  let r = expr(&p)
  p.restore(s)
  r
}

fn head_pattern(p: var Parser): ast.Pat!diag.Fail {
  let s = p.head_flags(false)
  let r = pattern(&p)
  p.restore(s)
  r
}

/// The top of each iteration of `open item, item, ... close` (optional trailing comma; line
/// breaks between items are allowed): true, with `close` consumed, when the list is over.
fn list_end(p: var Parser, close: token.Tok): bool {
  p.skip_newlines()
  p.eat(close)
}

/// After a list item: false after a `,` (another item may follow), true with `close` consumed.
fn list_sep(p: var Parser, close: token.Tok, what: str): bool!diag.Fail {
  p.skip_newlines()
  if p.eat(token.Comma) { return false }
  p.skip_newlines()
  if p.eat(close) { return true }
  fail(bad(p.expected("E0020", "`,` or `{close.text()}` after the {what}")))
}

fn expr_list(p: var Parser, close: token.Tok, what: str): [ast.Expr]!diag.Fail {
  var xs: [ast.Expr] = []
  while !p.list_end(close) {
    xs.push(nested_expr(&p)?)
    if p.list_sep(close, what)? { break }
  }
  xs
}

fn type_list(p: var Parser, close: token.Tok, what: str): [ast.Type]!diag.Fail {
  var xs: [ast.Type] = []
  while !p.list_end(close) {
    xs.push(nested_ty(&p)?)
    if p.list_sep(close, what)? { break }
  }
  xs
}

fn pattern_list(p: var Parser, close: token.Tok, what: str): [ast.Pat]!diag.Fail {
  var xs: [ast.Pat] = []
  while !p.list_end(close) {
    xs.push(nested_pattern(&p)?)
    if p.list_sep(close, what)? { break }
  }
  xs
}

fn param_list(p: var Parser, close: token.Tok, what: str): [ast.Param]!diag.Fail {
  var xs: [ast.Param] = []
  while !p.list_end(close) {
    xs.push(nested_param(&p)?)
    if p.list_sep(close, what)? { break }
  }
  xs
}

/// After an item: a line break, the end of the file, or a token on a later line.
fn item_ended(p: Parser): bool = match p.peek() {
  Newline => true
  Eof => true
  _ => p.span().line > p.prev.end_line
}

/// Skip to the next line that starts with an item keyword.
fn recover(p: var Parser) {
  loop {
    p.bump()
    if p.at(token.Eof) { return }
    let t = p.toks[p.pos]
    let is_item = match t.tok {
      Fn => true
      Pub => true
      Async => true
      Struct => true
      Enum => true
      Let => true
      Ident(n) => n == "test" || n == "shape" || n == "imprint"
      _ => false
    }
    if is_item && t.span.col == 1 { return }
  }
}

// ---- items ----

fn item(p: var Parser): Raw!diag.Fail {
  let doc = p.toks[p.pos].doc
  let start = p.span()
  let public = p.eat(token.Pub)
  let next_ident = p.peek_at(1) is Ident(_)
  if p.peek() == token.Ident("extern") {
    let ok = match p.peek_at(1) {
      Fn => true
      Async => true
      Ident(_) => true
      _ => false
    }
    if ok { return extern_item(&p, doc, public, start) }
    // the runtime's dialect: `extern var name: T = "c_symbol"`, a C global defined elsewhere
    if p.peek_at(1) == token.Var {
      p.bump()
      return RItem(ast.Item.Global(global_def(&p, doc, public, start, 4)?))
    }
  }
  // the runtime's dialect (docs/lowlevel.md): `raw struct`, `raw union`, `raw var`, `raw thread
  // var`, `raw let`, `raw assert`, `export var`
  if p.peek() == token.Ident("raw") {
    let k = match p.peek_at(1) {
      Struct => 1
      Ident(n) when n == "union" => 2
      _ => 0
    }
    if k > 0 {
      p.bump()
      var d = struct_def(&p, doc, public, start)?
      d.raw = k
      return RItem(ast.Item.Struct(d))
    }
    let g = match p.peek_at(1) {
      Var => 0
      Ident(n) when n == "thread" && p.peek_at(2) == token.Var => 1
      Let => 2
      Assert => 4
      _ => -1
    }
    if p.peek_at(1) == token.Ident("type") {
      p.bump()
      p.bump()
      let name = p.ident("a name for the type")?
      p.expect(token.Eq, "and the type it names: `raw type NAME = T`")?
      let t = ty(&p)?
      return RItem(ast.Item.RawType(ast.RawTypeDef { id: p.id(), span: start.to(p.prev), name, doc, public, ty: t }))
    }
    if g == 4 {
      p.bump()
      p.bump()
      let x = expr(&p)?
      return RItem(ast.Item.RawAssert(ast.RawAssertDef { id: p.id(), span: start.to(p.prev), expr: x }))
    }
    if g >= 0 {
      p.bump()
      if g == 1 { p.bump() }
      return RItem(ast.Item.Global(global_def(&p, doc, public, start, g)?))
    }
  }
  if p.peek() == token.Ident("export") && p.peek_at(1) == token.Var {
    p.bump()
    return RItem(ast.Item.Global(global_def(&p, doc, public, start, 3)?))
  }
  // `export fn`, `inline export fn`
  let export = if p.peek() == token.Ident("export") && p.peek_at(1) == token.Fn {
    1
  } else if p.peek() == token.Ident("inline") && p.peek_at(1) == token.Ident("export") && p.peek_at(2) == token.Fn {
    2
  } else {
    0
  }
  if export > 0 {
    p.bump()
    if export == 2 { p.bump() }
    var c = fn_clause(&p, doc, public, start)?
    c.export = export
    return RClause(c)
  }
  match p.peek() {
    Fn => RClause(fn_clause(&p, doc, public, start)?)
    Async => RClause(fn_clause(&p, doc, public, start)?)
    Struct => RItem(ast.Item.Struct(struct_def(&p, doc, public, start)?))
    Enum => RItem(ast.Item.Enum(enum_def(&p, doc, public, start)?))
    Let => RItem(ast.Item.Let(const_def(&p, doc, public, start)?))
    Ident(n) when n == "imprint" && next_ident =>
      RItem(ast.Item.Imprint(const_def(&p, doc, public, start)?))
    Ident(n) when n == "shape" && next_ident =>
      RItem(ast.Item.Shape(shape_def(&p, doc, public, start)?))
    Ident(n) when n == "test" && p.peek_at(1) is Str(_) => {
      p.bump()
      let parts = match p.bump().tok {
        Str(ps) => ps
        _ => []
      }
      var name = ""
      if parts.len() == 1 {
        match parts[0] {
          Lit(s) => name = s
          _ => fail(
            bad(
              diag.new(
                "E0020",
                p.prev,
                "a test name can't interpolate",
              ).note("write a plain string: test \"name\" {{ ... }}"),
            ),
          )
        }
      } else if parts.len() > 1 {
        fail(
          bad(
            diag.new(
              "E0020",
              p.prev,
              "a test name can't interpolate",
            ).note("write a plain string: test \"name\" {{ ... }}"),
          ),
        )
      }
      let body = block(&p)?
      RItem(ast.Item.Test(ast.TestDef { id: p.id(), span: start.to(p.prev), name, doc, body }))
    }
    t => {
      var d = p.expected(
        "E0024",
        "an item (`fn`, `struct`, `enum`, `shape`, `test`, `let` or `imprint`)",
      )
      if t == token.Ident("import") || t == token.Ident("use") {
        d = d.note("Auk has no imports: refer to anything by its path, e.g. `json.parse(s)`; dependencies go in raft.toml")
      } else if !public {
        d = d.note("statements and expressions belong inside a function; a program starts at `fn main`")
      }
      fail(bad(d))
    }
  }
}

/// `extern fn ... = "symbol"` or `extern type Name = "CType"`. In the prelude the string is a
/// runtime symbol; elsewhere a C prototype or C type, allowed only in a package with the `ffi`
/// effect (checked with the manifest: E0036).
fn extern_item(p: var Parser, doc: str?, public: bool, start: diag.Span): Raw!diag.Fail {
  p.bump()
  if p.peek() == token.Ident("type") {
    p.bump()
    let name = p.ident("a type name after `extern type`")?
    p.expect(token.Eq, "and the C type in quotes")?
    let c_type = extern_str(&p, "the C type")?
    return RItem(
      ast.Item.ExternType(ast.ExternTypeDef {
        id: p.id(),
        span: start.to(p.prev),
        name,
        doc,
        public,
        c_type,
      }),
    )
  }
  var c = fn_signature(&p, doc, public, start)?
  let what = if p.prelude { "the runtime symbol" } else { "the C prototype" }
  p.expect(token.Eq, "and {what} in quotes")?
  c.body = ast.FnBody.Extern(extern_str(&p, what)?)
  c.span = start.to(p.prev)
  RClause(c)
}

fn extern_str(p: var Parser, what: str): str!diag.Fail = match p.peek() {
  Str(parts) => {
    p.bump()
    p.plain_str(parts, what)?
  }
  _ => fail(bad(p.expected("E0020", "{what} as a string")))
}

fn fn_clause(p: var Parser, doc: str?, public: bool, start: diag.Span): ast.FnClause!diag.Fail {
  var c = fn_signature(&p, doc, public, start)?
  if p.eat(token.Eq) {
    c.body = ast.FnBody.Expr(expr(&p)?)
  } else if p.at(token.LBrace) {
    c.body = ast.FnBody.Block(block(&p)?)
  } else {
    let ends = match p.peek() {
      Newline => true
      Eof => true
      RBrace => true
      _ => p.span().line > p.prev.end_line
    }
    if !ends {
      fail(
        bad(
          p.expected(
            "E0020",
            "`{{` or `=` to start the function body, or a line break after a header line",
          ),
        ),
      )
    }
  }
  c.span = start.to(p.prev)
  c
}

/// Everything of a clause up to its body (`body: none`).
fn fn_signature(p: var Parser, doc: str?, public: bool, start: diag.Span): ast.FnClause!diag.Fail {
  let is_async = p.eat(token.Async)
  p.expect(token.Fn, "")?
  let name = if p.prelude {
    p.member("a function name after `fn`")?
  } else {
    p.ident("a function name after `fn`")?
  }
  let generics = generics(&p)?
  p.expect(token.LParen, "to start the parameter list")?
  let params = param_list(&p, token.RParen, "parameter")?
  var ret: ast.Type? = none
  if p.eat(token.Colon) {
    ret = ty(&p)?
  } else if p.at(token.Arrow) {
    let s = p.span()
    fail(
      bad(
        diag
          .new("E0035", s, "return types are written with `:`, not `->`")
          .note("e.g. `fn add(a: int, b: int): int = a + b`")
          .fix(s, ":"),
      ),
    )
  }
  var effects: [ast.Ident] = []
  if p.eat(token.Uses) {
    effects.push(
      p.ident("an effect name after `uses` (fs, net, time, rand, env, proc, audio_out, gui, ffi)")?,
    )
    while p.eat(token.Comma) { effects.push(p.ident("an effect name after `,`")?) }
  }
  var pre: [ast.Expr] = []
  var post: [ast.Expr] = []
  loop {
    if p.eat(token.Requires) {
      pre.push(head_expr(&p)?)
    } else if p.eat(token.Ensures) {
      post.push(head_expr(&p)?)
    } else {
      break
    }
  }
  let guard: ast.Expr? = if p.eat(token.When) { head_expr(&p)? } else { none }
  ast.FnClause {
    id: p.id(),
    span: start.to(p.prev),
    name,
    doc,
    public,
    is_async,
    generics,
    params,
    ret,
    effects,
    pre,
    post,
    guard,
    body: none,
    export: 0,
  }
}

/// `pat`, `pat: T` or `pat: var T`.
fn param(p: var Parser): ast.Param!diag.Fail {
  let start = p.span()
  let pat = pattern(&p)?
  var t: ast.Type? = none
  var is_var = false
  if p.eat(token.Colon) {
    is_var = p.eat(token.Var)
    t = ty(&p)?
  }
  ast.Param { id: p.id(), span: start.to(p.prev), pat, ty: t, var_: is_var }
}

/// `<A: Show + Eq, B>` or nothing.
fn generics(p: var Parser): [ast.Generic]!diag.Fail {
  var gs: [ast.Generic] = []
  if !p.eat(token.Lt) { return gs }
  while !p.list_end(token.Gt) {
    let s = p.lift()
    let r = generic(&p)
    p.restore(s)
    gs.push(r?)
    if p.list_sep(token.Gt, "type parameter")? { break }
  }
  gs
}

fn generic(p: var Parser): ast.Generic!diag.Fail {
  let name = p.ident("a type parameter name")?
  var bounds: [ast.Type] = []
  if p.eat(token.Colon) {
    bounds.push(ty(&p)?)
    while p.eat(token.Plus) { bounds.push(ty(&p)?) }
  }
  ast.Generic { name, bounds }
}

fn struct_def(p: var Parser, doc: str?, public: bool, start: diag.Span): ast.StructDef!diag.Fail {
  p.bump()
  let name = p.ident("a struct name")?
  let generics = generics(&p)?
  p.expect(token.LBrace, "to start the struct's fields")?
  var fields: [ast.FieldDef] = []
  while !p.list_end(token.RBrace) {
    let s = p.lift()
    let r = field_def(&p)
    p.restore(s)
    fields.push(r?)
    if p.list_sep(token.RBrace, "field")? { break }
  }
  ast.StructDef { id: p.id(), span: start.to(p.prev), name, doc, public, generics, fields, raw: 0 }
}

fn field_def(p: var Parser): ast.FieldDef!diag.Fail {
  let doc = p.toks[p.pos].doc
  let start = p.span()
  let name = p.ident("a field name")?
  p.expect(token.Colon, "and a type after the field name")?
  let t = ty(&p)?
  ast.FieldDef { span: start.to(p.prev), name, ty: t, doc }
}

fn enum_def(p: var Parser, doc: str?, public: bool, start: diag.Span): ast.EnumDef!diag.Fail {
  p.bump()
  let name = p.ident("an enum name")?
  let generics = generics(&p)?
  p.expect(token.LBrace, "to start the enum's variants")?
  var variants: [ast.Variant] = []
  while !p.list_end(token.RBrace) {
    let s = p.lift()
    let r = variant(&p)
    p.restore(s)
    variants.push(r?)
    if p.list_sep(token.RBrace, "variant")? { break }
  }
  ast.EnumDef { id: p.id(), span: start.to(p.prev), name, doc, public, generics, variants }
}

fn variant(p: var Parser): ast.Variant!diag.Fail {
  let doc = p.toks[p.pos].doc
  let start = p.span()
  let name = p.ident("a variant name")?
  var fields: [ast.VariantField] = []
  if p.eat(token.LParen) {
    while !p.list_end(token.RParen) {
      let s = p.lift()
      let r = variant_field(&p)
      p.restore(s)
      fields.push(r?)
      if p.list_sep(token.RParen, "variant field")? { break }
    }
  }
  ast.Variant { id: p.id(), span: start.to(p.prev), name, doc, fields }
}

fn variant_field(p: var Parser): ast.VariantField!diag.Fail {
  var name: ast.Ident? = none
  if p.peek_at(1) == token.Colon {
    name = p.ident("a field name")?
    p.bump()
  }
  ast.VariantField { name, ty: ty(&p)? }
}

fn shape_def(p: var Parser, doc: str?, public: bool, start: diag.Span): ast.ShapeDef!diag.Fail {
  p.bump()
  let name = p.ident("a shape name")?
  let generics = generics(&p)?
  p.expect(token.LBrace, "to start the shape's methods")?
  var methods: [ast.FnClause] = []
  loop {
    p.skip_newlines()
    if p.eat(token.RBrace) { break }
    if !p.at(token.Fn) && !p.at(token.Async) {
      fail(
        bad(p.expected("E0020", "a method signature `fn name(self, ...): T` or `}}` in the shape")),
      )
    }
    let mdoc = p.toks[p.pos].doc
    let ms = p.span()
    let s = p.lift()
    let r = fn_clause(&p, mdoc, false, ms)
    p.restore(s)
    methods.push(r?)
    p.eat(token.Comma)
  }
  ast.ShapeDef { id: p.id(), span: start.to(p.prev), name, doc, public, generics, methods }
}

/// A global of the runtime's dialect, at its `var`/`let` (`kind`: see `ast.GlobalDef`).
fn global_def(p: var Parser, doc: str?, public: bool, start: diag.Span, kind: int): ast.GlobalDef!diag.Fail {
  p.bump()
  let name = p.ident("a name for the global")?
  let t: ast.Type? = if p.eat(token.Colon) { ty(&p)? } else { none }
  p.expect(token.Eq, "and its initial value (a constant)")?
  let value = expr(&p)?
  ast.GlobalDef { id: p.id(), span: start.to(p.prev), name, doc, public, kind, ty: t, value }
}

/// Top-level `let NAME: T = e` or `imprint NAME: T = e`.
fn const_def(p: var Parser, doc: str?, public: bool, start: diag.Span): ast.ConstDef!diag.Fail {
  let kw = if p.bump().tok == token.Let { "let" } else { "imprint" }
  let name = p.ident("a constant name after `{kw}`")?
  let t: ast.Type? = if p.eat(token.Colon) { ty(&p)? } else { none }
  p.expect(token.Eq, "and a value")?
  let value = expr(&p)?
  ast.ConstDef { id: p.id(), span: start.to(p.prev), name, doc, public, ty: t, value }
}

// ---- types ----

fn ty(p: var Parser): ast.Type!diag.Fail {
  let start = p.span()
  let kind = match p.peek() {
    LBracket => {
      p.bump()
      let t = nested_ty(&p)?
      if p.eat(token.Semi) {
        // `[T; N]` / `[T; ..]`: a C array (the lexer makes `;` a token only here)
        let n = match p.peek() {
          Int(n) => {
            p.bump()
            n
          }
          _ => {
            p.expect(token.DotDot, "the array length")?
            -1
          }
        }
        p.expect(token.RBracket, "to close the array type")?
        ast.TypeKind.Array(t, n)
      } else {
        p.expect(token.RBracket, "to close the list type")?
        ast.TypeKind.List(t)
      }
    }
    LBrace => {
      p.bump()
      let k = nested_ty(&p)?
      p.expect(token.Colon, "between the key and value types of a map type `{{K: V}}`")?
      let v = nested_ty(&p)?
      p.expect(token.RBrace, "to close the map type")?
      ast.TypeKind.Map(k, v)
    }
    LParen => {
      p.bump()
      let ts = list(&p, token.RParen, "type", nested_param_ty)?
      let vs = ts.filter(t => t.kind is Var(_))
      if p.eat(token.FatArrow) {
        let ret = ty(&p)?
        ast.TypeKind.Fn(ts, ret)
      } else if vs.len() > 0 {
        fail(bad(diag.new("E0023", vs[0].span, "`var` is only for a parameter of a function type").note("a function type looks like `(var P, int) => R`")))
      } else if ts.len() == 1 {
        // `(T)` is just `T`
        var t = ts[0]
        t.span = start.to(p.prev)
        return type_suffix(&p, t, start)
      } else {
        ast.TypeKind.Tuple(ts)
      }
    }
    Ident(n) when n == "any" && p.peek_at(1) is Ident(_) => {
      p.bump()
      ast.TypeKind.Any(named_type(&p)?)
    }
    Ident(_) => {
      let t = named_type(&p)?
      if !(p.peek() is Unit(_)) { return type_suffix(&p, t, start) }
      ast.TypeKind.Measured(t, units(&p)?)
    }
    _ => fail(
      bad(
        p
          .expected("E0023", "a type")
          .note("types look like `int`, `[str]`, `{{str: int}}`, `(int, str)`, `T?`, `T!`, `T!E` or `Set<int>`"),
      ),
    )
  }
  let t = ast.Type { id: p.id(), span: start.to(p.prev), kind }
  type_suffix(&p, t, start)
}

/// The `<m/s>` unit token after a number literal or `int`/`float`, in canonical form.
fn units(p: var Parser): [(str, int)]!diag.Fail {
  let t = p.bump()
  let src = match t.tok {
    Unit(s) => s
    _ => ""
  }
  match units.parse(src) {
    ok(u) => u
    err(why) => fail(
      bad(
        diag
          .new("E0037", t.span, "malformed unit of measure `<{src}>`: {why}")
          .note("a unit is names joined by `*` and `/`, with integer powers: `<m>`, `<m/s^2>`, `<kg*m/s^2>`, `<1/s>`; for a comparison, put spaces around `<`"),
      ),
    )
  }
}

/// `T?`, `T!` and `T!E` suffixes.
fn type_suffix(p: var Parser, t0: ast.Type, start: diag.Span): ast.Type!diag.Fail {
  var t = t0
  loop {
    var kind = ast.TypeKind.Tuple([])
    if p.eat(token.Question) {
      kind = ast.TypeKind.Optional(t)
    } else if p.eat(token.Bang) {
      let err: ast.Type? = if p.peek() is Ident(_) { named_type(&p)? } else { none }
      kind = ast.TypeKind.Fallible(t, err)
    } else {
      return t
    }
    t = ast.Type { id: p.id(), span: start.to(p.prev), kind }
  }
}

/// `a.b.Name<Args>`
fn named_type(p: var Parser): ast.Type!diag.Fail {
  let start = p.span()
  var path = [p.ident("a type name")?]
  while p.at(token.Dot) {
    p.bump()
    path.push(p.ident("a type name after `.`")?)
  }
  let args = if p.eat(token.Lt) { type_list(&p, token.Gt, "type argument")? } else { [] }
  ast.Type { id: p.id(), span: start.to(p.prev), kind: ast.TypeKind.Named(path, args) }
}

// ---- patterns ----

fn pattern(p: var Parser): ast.Pat!diag.Fail {
  let start = p.span()
  let kind = match p.peek() {
    Ident(n) when n == "_" => {
      p.bump()
      ast.PatKind.Wild
    }
    Ident(n) when (n == "some" || n == "ok" || n == "err") && p.peek_at(1) == token.LParen => {
      p.bump()
      p.bump()
      let inner = nested_pattern(&p)?
      p.eat(token.Comma)
      p.expect(token.RParen, "to close `{n}(`")?
      if n == "some" {
        ast.PatKind.Some(inner)
      } else if n == "ok" {
        ast.PatKind.Ok(inner)
      } else {
        ast.PatKind.Err(inner)
      }
    }
    Ident(n) when n == "none" && p.peek_at(1) != token.LParen && p.peek_at(1) != token.Dot => {
      p.bump()
      ast.PatKind.None
    }
    Ident(_) => {
      var path = [p.ident("a name")?]
      while p.at(token.Dot) {
        p.bump()
        path.push(p.ident("a variant name after `.`")?)
      }
      if p.eat(token.LParen) {
        ast.PatKind.Variant(path, some(pattern_list(&p, token.RParen, "pattern")?))
      } else if p.at(token.LBrace) && !p.no_struct {
        p.bump()
        struct_pattern(&p, path)?
      } else if path.len() > 1 {
        ast.PatKind.Variant(path, none)
      } else {
        ast.PatKind.Bind(path[0].name)
      }
    }
    Minus when p.peek_at(1) is Int(_) || p.peek_at(1) is Float(_) => {
      p.bump()
      ast.PatKind.Lit(p.lit_token()!, true)
    }
    Str(parts) => {
      p.bump()
      let s = p.plain_str(parts, "a string pattern")?
      if p.eat(token.Plus) {
        let rest = pattern(&p)?
        let ok = match rest.kind {
          Bind(_) => true
          Wild => true
          _ => false
        }
        if !ok {
          fail(
            bad(
              diag
                .new(
                  "E0022",
                  rest.span,
                  "expected a name or `_` after `+` in a string-prefix pattern",
                )
                .note("a prefix pattern looks like `\"GET \" + rest`"),
            ),
          )
        }
        ast.PatKind.StrPrefix(s, rest)
      } else {
        ast.PatKind.Lit(ast.Lit.Str(s), false)
      }
    }
    Int(_) => ast.PatKind.Lit(p.lit_token()!, false)
    Float(_) => ast.PatKind.Lit(p.lit_token()!, false)
    Char(_) => ast.PatKind.Lit(p.lit_token()!, false)
    True => ast.PatKind.Lit(p.lit_token()!, false)
    False => ast.PatKind.Lit(p.lit_token()!, false)
    LParen => {
      p.bump()
      let ps = pattern_list(&p, token.RParen, "pattern")?
      if ps.len() == 1 && p.toks[p.pos - 2].tok != token.Comma { return ps[0] }
      ast.PatKind.Tuple(ps)
    }
    LBracket => {
      p.bump()
      list_pattern(&p)?
    }
    LBrace => {
      p.bump()
      var es: [(ast.Lit, ast.Pat)] = []
      while !p.list_end(token.RBrace) {
        let s = p.lift()
        let r = map_pattern_entry(&p)
        p.restore(s)
        es.push(r?)
        if p.list_sep(token.RBrace, "map pattern entry")? { break }
      }
      ast.PatKind.Map(es)
    }
    _ => fail(
      bad(
        p.expected(
          "E0022",
          "a pattern",
        ).note("patterns look like `0`, `\"s\"`, `x`, `_`, `(a, b)`, `[h, ..t]`, `Circle(r)`, `User {{ name, .. }}`, `{{\"k\": v}}`, `\"GET \" + rest`, `some(v)` or `none`"),
      ),
    )
  }
  ast.Pat { id: p.id(), span: start.to(p.prev), kind }
}

fn map_pattern_entry(p: var Parser): (ast.Lit, ast.Pat)!diag.Fail {
  let key = lit_key(&p)?
  p.expect(token.Colon, "after the key in a map pattern")?
  (key, pattern(&p)?)
}

/// A literal map-pattern key (`"k"`, `1`, `-1`, `'c'`, `true`).
fn lit_key(p: var Parser): ast.Lit!diag.Fail {
  let neg = p.at(token.Minus) && (p.peek_at(1) is Int(_) || p.peek_at(1) is Float(_))
  if neg { p.bump() }
  match p.peek() {
    Str(parts) => {
      p.bump()
      return ast.Lit.Str(p.plain_str(parts, "a map pattern key")?)
    }
    _ => {}
  }
  match p.lit_token() {
    some(Int(n)) when neg => ast.Lit.Int(0 -% n)
    some(Float(x)) when neg => ast.Lit.Float(-x)
    some(l) => l
    none => fail(
      bad(
        p.expected(
          "E0034",
          "a literal key in a map pattern",
        ).note("map patterns match fixed keys: `{{\"name\": n}}`"),
      ),
    )
  }
}

/// Consume an int, float, char or bool token as a literal.
fn lit_token(p: var Parser): ast.Lit? {
  let l = match p.peek() {
    Int(n) => ast.Lit.Int(n)
    Float(x) => ast.Lit.Float(x)
    Char(c) => ast.Lit.Char(c)
    True => ast.Lit.Bool(true)
    False => ast.Lit.Bool(false)
    _ => return none
  }
  p.bump()
  l
}

fn plain_str(p: Parser, parts: [token.StrPart], what: str): str!diag.Fail {
  if parts.len() == 0 { return "" }
  if parts.len() == 1 {
    match parts[0] {
      Lit(s) => return s
      _ => {}
    }
  }
  fail(
    bad(
      diag.new(
        "E0022",
        p.prev,
        "{what} can't interpolate",
      ).note("use a plain string; bind the rest with `\"prefix\" + rest`"),
    ),
  )
}

/// After `[`: `[]`, `[a, b]`, `[h, ..t]`, `[.., last]`, `[a, .._, z]`.
fn list_pattern(p: var Parser): ast.PatKind!diag.Fail {
  var head: [ast.Pat] = []
  var rest: ast.Rest? = none
  var tail: [ast.Pat] = []
  while !p.list_end(token.RBracket) {
    let s = p.lift()
    let r = list_pattern_elem(&p, &head, &rest, &tail)
    p.restore(s)
    r?
    if p.list_sep(token.RBracket, "list pattern element")? { break }
  }
  ast.PatKind.List(head, rest, tail)
}

fn list_pattern_elem(
  p: var Parser,
  head: var [ast.Pat],
  rest: var ast.Rest?,
  tail: var [ast.Pat],
): ()!diag.Fail {
  if p.at(token.DotDot) {
    let s = p.bump().span
    match rest {
      some(r) => fail(
        bad(
          diag.new(
            "E0033",
            s,
            "a list pattern can have only one `..`",
          ).note("the first `..` is at {r.span.show_at()}"),
        ),
      )
      none => {}
    }
    let pat: ast.Pat? = if p.at(token.Comma) || p.at(token.RBracket) { none } else { pattern(&p)? }
    rest = ast.Rest { span: s.to(p.prev), pat }
  } else if rest is some(_) {
    tail.push(pattern(&p)?)
  } else {
    head.push(pattern(&p)?)
  }
}

/// After `Path {`: `{ name, age: a, .. }`.
fn struct_pattern(p: var Parser, path: [ast.Ident]): ast.PatKind!diag.Fail {
  var rest = false
  var fields: [ast.FieldPat] = []
  while !p.list_end(token.RBrace) {
    let s = p.lift()
    let r = field_pattern(&p, &rest)
    p.restore(s)
    match r? {
      some(f) => fields.push(f)
      none => {}
    }
    if p.list_sep(token.RBrace, "field pattern")? { break }
  }
  ast.PatKind.Struct(path, fields, rest)
}

fn field_pattern(p: var Parser, rest: var bool): ast.FieldPat?!diag.Fail {
  if p.eat(token.DotDot) {
    if !p.at(token.RBrace) && !p.at(token.Comma) && !p.at(token.Newline) {
      fail(bad(p.expected("E0020", "`}}` after `..` in a struct pattern")))
    }
    rest = true
    return none
  }
  let name = p.ident("a field name in the struct pattern")?
  let pat: ast.Pat? = if p.eat(token.Colon) { pattern(&p)? } else { none }
  some(ast.FieldPat { name, pat })
}

// ---- statements and blocks ----

fn block(p: var Parser): ast.Block!diag.Fail {
  let start = p.span()
  p.expect(token.LBrace, "to start a block")?
  let s = p.lift()
  let r = block_stmts(&p)
  p.restore(s)
  let stmts = r?
  ast.Block { id: p.id(), span: start.to(p.prev), stmts }
}

fn block_stmts(p: var Parser): [ast.Expr]!diag.Fail {
  var stmts: [ast.Expr] = []
  loop {
    p.skip_newlines()
    if p.eat(token.RBrace) { return stmts }
    stmts.push(stmt(&p)?)
    if !p.at(token.Newline) && !p.at(token.RBrace) {
      fail(
        bad(
          p
            .expected("E0025", "a line break or `}}` after the statement")
            .note("each statement goes on its own line; a line that ends with an operator continues on the next"),
        ),
      )
    }
  }
}

fn stmt(p: var Parser): ast.Expr!diag.Fail {
  if !p.at(token.Let) && !p.at(token.Var) { return stmt_expr(&p) }
  let start = p.span()
  let mutable = p.bump().tok == token.Var
  let pat = pattern(&p)?
  let t: ast.Type? = if p.eat(token.Colon) { ty(&p)? } else { none }
  // the runtime's dialect: `var x: T` without a value (the checker allows it only there)
  if mutable && t != none && (p.at(token.Newline) || p.at(token.RBrace)) {
    let value = ast.Expr { id: p.id(), span: p.prev, kind: ast.ExprKind.Uninit }
    return ast.Expr { id: p.id(), span: start.to(p.prev), kind: ast.ExprKind.Let(mutable, pat, t, value, none) }
  }
  p.expect(token.Eq, "and a value")?
  let value = pipe_expr(&p)?
  let els: ast.ElseArm? = if p.eat(token.Else) { else_arm(&p)? } else { none }
  let kind = ast.ExprKind.Let(mutable, pat, t, value, els)
  ast.Expr { id: p.id(), span: start.to(p.prev), kind }
}

/// An expression, an assignment or an `assert`: block statements, match-arm and closure
/// bodies.
fn stmt_expr(p: var Parser): ast.Expr!diag.Fail {
  let start = p.span()
  if p.eat(token.Assert) {
    let e = expr(&p)?
    return ast.Expr { id: p.id(), span: start.to(p.prev), kind: ast.ExprKind.Assert(e) }
  }
  let target = expr(&p)?
  let shr_eq = p.shr_ahead() == some(true)
  if !shr_eq && !is_assign(p.peek()) { return target }
  let op: ast.BinOp? = if shr_eq { ast.BinOp.Shr } else { compound_op(p.peek()) }
  if !is_target(target, op == none) {
    fail(
      bad(
        diag
          .new("E0027", target.span, "can't assign to this expression")
          .note("an assignment target is a variable, a field or an index, like `a.b[i].c`, or for `=` a tuple of them: `(a, b) = (b, a)`"),
      ),
    )
  }
  p.bump()
  if shr_eq { p.bump() }
  let value = expr(&p)?
  let kind = ast.ExprKind.Assign(op, target, value)
  ast.Expr { id: p.id(), span: start.to(p.prev), kind }
}

// ---- expressions ----

fn mk(p: var Parser, kind: ast.ExprKind, start: diag.Span): ast.Expr =
  ast.Expr { id: p.id(), span: start.to(p.prev), kind }

pub fn expr(p: var Parser): ast.Expr!diag.Fail {
  let e = pipe_expr(&p)?
  if p.no_struct || !p.at(token.Else) { return e }
  p.bump()
  let arm = else_arm(&p)?
  let start = e.span
  p.mk(ast.ExprKind.Else(e, arm), start)
}

/// After `else`: `fallback` or `e => fallback`.
fn else_arm(p: var Parser): ast.ElseArm!diag.Fail {
  var binder: ast.Ident? = none
  match p.peek() {
    Ident(n) when n != "_" && p.peek_at(1) == token.FatArrow => {
      binder = p.ident("a name")?
      p.bump()
    }
    _ => {}
  }
  let body = expr(&p)?
  ast.ElseArm { binder, body }
}

fn pipe_expr(p: var Parser): ast.Expr!diag.Fail {
  var lhs = binary(&p, 1)?
  while p.at(token.PipeGt) {
    p.bump()
    let start = p.span()
    var callee = match p.peek() {
      Ident(n) when n != "_" => {
        p.bump()
        p.mk(ast.ExprKind.Name(n), start)
      }
      _ => fail(
        bad(
          p
            .expected("E0030", "a function name after `|>`")
            .note("`x |> f(a)` means `f(x, a)`; the step is a function name or path with optional arguments"),
        ),
      )
    }
    while p.at(token.Dot) && p.peek_at(1) is Ident(_) {
      p.bump()
      let name = p.ident("a name")?
      callee = p.mk(ast.ExprKind.Field(callee, name), start)
    }
    let args = if p.at(token.LParen) { call_args(&p)? } else { [] }
    let s = lhs.span
    lhs = p.mk(ast.ExprKind.Pipe(lhs, callee, args), s)
    // A `?` or `!` after a step applies to the whole pipe so far.
    loop {
      var kind = ast.ExprKind.Hole
      match p.peek() {
        QuestionQuestion => kind = double_try(&p, lhs)?
        Question => {
          p.bump()
          kind = ast.ExprKind.Try(lhs)
        }
        Bang => {
          p.bump()
          kind = ast.ExprKind.Unwrap(lhs)
        }
        _ => break
      }
      lhs = p.mk(kind, s)
    }
    if p.at(token.Dot) || p.at(token.QuestionDot) || p.at(token.LBracket) {
      fail(
        bad(
          p.expected(
            "E0030",
            "`|>` or the end of the pipe",
          ).note("`x.f(a)` and `x |> f(a)` both mean `f(x, a)`; don't mix them in one chain (use `|>` for every step, or wrap the pipe in parentheses)"),
        ),
      )
    }
  }
  lhs
}

fn binary(p: var Parser, min: int): ast.Expr!diag.Fail {
  var lhs = unary(&p)?
  loop {
    let start = lhs.span
    let t = p.peek()
    if t == token.Is && IS >= min {
      p.bump()
      let pat = pattern(&p)?
      lhs = p.mk(ast.ExprKind.Is(lhs, pat), start)
      continue
    }
    if (t == token.DotDot || t == token.DotDotEq) && RANGE >= min {
      p.bump()
      let hi = binary(&p, RANGE + 1)?
      lhs = p.mk(ast.ExprKind.Range(lhs, hi, t == token.DotDotEq), start)
      if p.at(token.DotDot) || p.at(token.DotDotEq) {
        fail(
          bad(
            p.expected(
              "E0020",
              "the end of the range",
            ).note("ranges can't be chained; use parentheses"),
          ),
        )
      }
      continue
    }
    let shr = p.shr_ahead()
    if shr == some(true) { break }  // `>>=`
    let (op, prec) = if shr is some(_) { (ast.BinOp.Shr, SHIFT) } else { binop(t) else break }
    if prec < min { break }
    p.bump()
    if shr is some(_) { p.bump() }
    // `**` is right-associative; the rest are left-associative.
    let rhs = binary(&p, if op == ast.BinOp.Pow { prec } else { prec + 1 })?
    if prec == CMP {
      p.check_bitwise_operand(lhs)?
      p.check_bitwise_operand(rhs)?
    }
    lhs = p.mk(ast.ExprKind.Binary(op, lhs, rhs), start)
    if prec == CMP {
      match binop(p.peek()) {
        some((_, q)) when q == CMP => fail(
          bad(
            diag
              .new("E0026", p.span(), "comparison operators cannot be chained")
              .note("write `a < b && b < c` instead of `a < b < c`"),
          ),
        )
        _ => {}
      }
    }
  }
  lhs
}

/// At `>`: `some(false)` for `>>`, `some(true)` for `>>=` (the lexer leaves them as separate
/// `>` tokens so nested generics close), `none` otherwise.
fn shr_ahead(p: Parser): bool? {
  if p.pos + 1 >= p.toks.len() { return none }
  let next = p.toks[p.pos + 1]
  if next.space_before || p.peek() != token.Gt { return none }
  match next.tok {
    Gt => false
    Ge => true
    _ => none
  }
}

/// A comparison operand that is a bare `&`, `|` or `^`: C reads `x & 1 == 0` as
/// `x & (1 == 0)`, so Auk asks for parentheses whichever way it is meant.
fn check_bitwise_operand(p: Parser, e: ast.Expr): ()!diag.Fail {
  let op = match e.kind {
    Binary(op, _, _) => op
    _ => return
  }
  if !is_bitwise(op) || p.parened.contains(e.id) { return }
  let open = diag.Span { end_line: e.span.line, end_col: e.span.col, ..e.span }
  let close = e.span.after()
  fail(
    bad(
      diag
        .new("E0038", e.span, "`{op.symbol()}` mixed with a comparison needs parentheses")
        .note("C reads `x & 1 == 0` as `x & (1 == 0)`; Auk makes you write which one you mean")
        .note("add parentheses around the bitwise operation")
        .fix(open, "(")
        .fix(close, ")"),
    ),
  )
}

fn unary(p: var Parser): ast.Expr!diag.Fail {
  let start = p.span()
  let op = match p.peek() {
    Minus => ast.UnOp.Neg
    Bang => ast.UnOp.Not
    Tilde => ast.UnOp.BitNot
    Amp => fail(
      bad(
        diag
          .new("E0028", start, "`&` is only allowed directly on a call argument")
          .note("`&x` passes `x` to a `var` parameter: `push2(&xs, 7)`"),
      ),
    )
    _ => return await_expr(&p)
  }
  p.bump()
  let e = unary(&p)?
  p.mk(ast.ExprKind.Unary(op, e), start)
}

/// `await e` and `catch e` (same precedence, either order: `catch await t`). A trailing `?`,
/// `!` or `?.` applies to the result: `catch f(x)?` is `(catch f(x))?`.
fn await_expr(p: var Parser): ast.Expr!diag.Fail {
  let start = p.span()
  let is_catch = p.at(token.Catch)
  if !is_catch && !p.eat(token.Await) {
    let e = primary(&p)?
    return postfix(&p, e, false)
  }
  if is_catch {
    p.bump()
  } else if p.peek() == token.Ident("any") && p.peek_operand_ahead() {
    // `await any ts` (`any` is only special here; `await any(ts)` calls a function `any`)
    p.bump()
    let operand0 = primary(&p)?
    let operand = postfix(&p, operand0, true)?
    let e = p.mk(ast.ExprKind.AwaitAny(operand), start)
    return postfix(&p, e, false)
  }
  let operand0 = if p.at(token.Await) || p.at(token.Catch) { await_expr(&p)? } else { primary(&p)? }
  let operand = postfix(&p, operand0, true)?
  let kind = if is_catch { ast.ExprKind.Catch(operand) } else { ast.ExprKind.Await(operand) }
  let e = p.mk(kind, start)
  postfix(&p, e, false)
}

/// Postfix operators. With `stop_at_try`, stop before `?`, `!` and `?.` (an `await` operand).
fn postfix(p: var Parser, e0: ast.Expr, stop_at_try: bool): ast.Expr!diag.Fail {
  var e = e0
  loop {
    let start = e.span
    let kind = match p.peek() {
      Dot => {
        p.bump()
        match p.peek() {
          Int(n) => {
            p.bump()
            ast.ExprKind.TupleField(e, n & 0xffffffff)
          }
          _ => {
            let name = p.member("a field or method name after `.`")?
            // the runtime's dialect: `raw.size_of<T>()`, explicit type arguments
            if p.at(token.Lt) && !p.toks[p.pos].space_before && e.kind == ast.ExprKind.Name("raw") {
              p.bump()
              let tys = type_list(&p, token.Gt, "type argument")?
              let args = call_args(&p)?
              let call = p.mk(ast.ExprKind.MethodCall(e, name, args), start)
              e = p.mk(ast.ExprKind.TypeArgs(call, tys), start)
              continue
            }
            if p.at(token.LParen) {
              let args = call_args(&p)?
              ast.ExprKind.MethodCall(e, name, args)
            } else {
              ast.ExprKind.Field(e, name)
            }
          }
        }
      }
      LParen => {
        let args = call_args(&p)?
        ast.ExprKind.Call(e, args)
      }
      LBracket => {
        p.bump()
        let i = nested_expr(&p)?
        p.expect(token.RBracket, "to close the index")?
        match i.kind {
          Range(lo, hi, inclusive) => ast.ExprKind.Slice(e, lo, hi, inclusive)
          _ => ast.ExprKind.Index(e, i)
        }
      }
      Question when !stop_at_try => {
        p.bump()
        ast.ExprKind.Try(e)
      }
      Bang when !stop_at_try => {
        p.bump()
        ast.ExprKind.Unwrap(e)
      }
      QuestionQuestion when !stop_at_try => double_try(&p, e)?
      QuestionDot when !stop_at_try => {
        p.bump()
        match p.peek() {
          Int(n) => {
            // `x?.0`: a tuple element
            let span = p.bump().span
            ast.ExprKind.OptChain(e, ast.Ident { name: token.uint_str(n), span }, none)
          }
          _ => {
            let name = p.member("a field, method name or tuple element number after `?.`")?
            let args: [ast.Expr]? = if p.at(token.LParen) { call_args(&p)? } else { none }
            ast.ExprKind.OptChain(e, name, args)
          }
        }
      }
      _ => return e
    }
    e = p.mk(kind, start)
  }
}

/// At `??` after an operand: two postfix `?`s. Consumes the `??`.
fn double_try(p: var Parser, e: ast.Expr): ast.ExprKind!diag.Fail {
  let q = p.bump().span
  // `x ?? 0`: an attempt at a default (null-coalescing) operator
  let next = p.span()
  let operand = match p.peek() {
    Int(_) => true
    Float(_) => true
    Char(_) => true
    Str(_) => true
    Ident(_) => true
    True => true
    False => true
    _ => false
  }
  if operand && next.line == q.end_line {
    let pre = if q.col == e.span.end_col && q.line == e.span.end_line { " " } else { "" }
    let post = if next.col == q.end_col { " " } else { "" }
    fail(
      bad(
        diag
          .new("E0039", q, "`??` is a hole, not a default operator; use `x else 0`")
          .note("`else` gives the default for a missing (`T?`) or failed (`T!`) value: `m.get(k) else 0`; it binds loosest, so write `(m.get(k) else 0) + 1` inside a larger expression")
          .fix(q, "{pre}else{post}"),
      ),
    )
  }
  let start = e.span
  let inner = p.mk(ast.ExprKind.Try(e), start)
  ast.ExprKind.Try(inner)
}

/// `(a, &b, x => y)`
fn call_args(p: var Parser): [ast.Expr]!diag.Fail {
  p.expect(token.LParen, "")?
  var xs: [ast.Expr] = []
  while !p.list_end(token.RParen) {
    let s = p.lift()
    let r = call_arg(&p)
    p.restore(s)
    xs.push(r?)
    if p.list_sep(token.RParen, "argument")? { break }
  }
  xs
}

fn call_arg(p: var Parser): ast.Expr!diag.Fail {
  let start = p.span()
  // the runtime's dialect: `.f` names a field (`raw.offset_of<T>(.f)`)
  if p.at(token.Dot) && p.peek_at(1) is Ident(_) {
    p.bump()
    let name = p.ident("a field name")?
    return p.mk(ast.ExprKind.FieldSel(name), start)
  }
  if !p.eat(token.Amp) { return expr(&p) }
  let e = await_expr(&p)?
  if !is_lvalue(e) {
    fail(
      bad(
        diag
          .new("E0028", e.span, "`&` needs a variable, field or index")
          .note("`&x` lets a `var` parameter change the caller's `x`, so `x` must be something assignable"),
      ),
    )
  }
  p.mk(ast.ExprKind.Ref(e), start)
}

fn primary(p: var Parser): ast.Expr!diag.Fail {
  let start = p.span()
  let kind = match p.peek() {
    Int(_) when p.peek_at(1) is Unit(_) => measured(&p, start)?
    Float(_) when p.peek_at(1) is Unit(_) => measured(&p, start)?
    Int(_) => ast.ExprKind.Lit(p.lit_token()!)
    Float(_) => ast.ExprKind.Lit(p.lit_token()!)
    Char(_) => ast.ExprKind.Lit(p.lit_token()!)
    True => ast.ExprKind.Lit(p.lit_token()!)
    False => ast.ExprKind.Lit(p.lit_token()!)
    Str(parts) => {
      p.bump()
      string(&p, parts)?
    }
    QuestionQuestion => {
      p.bump()
      ast.ExprKind.Hole
    }
    Ident(_) when p.peek_at(1) == token.FatArrow && !p.no_closure => {
      let prm = param(&p)?
      return closure(&p, [prm], start)
    }
    LParen when !p.no_closure && p.paren_closure_ahead() => {
      p.bump()
      let params = param_list(&p, token.RParen, "closure parameter")?
      return closure(&p, params, start)
    }
    Ident(n) when n == "_" => fail(
      bad(
        diag
          .new("E0021", start, "`_` can only be used in patterns, not as a value")
          .note("`_` ignores a value in `let _ = ...`, match arms and parameters"),
      ),
    )
    Ident(n) when n == "peek" && p.peek_operand_ahead() => {
      p.bump()
      ast.ExprKind.Peek(expr(&p)?)
    }
    Ident(_) when p.struct_lit_ahead() => {
      var path = [p.ident("a name")?]
      while p.eat(token.Dot) { path.push(p.ident("a name")?) }
      struct_lit(&p, path)?
    }
    Ident(n) => {
      p.bump()
      ast.ExprKind.Name(n)
    }
    LParen => {
      p.bump()
      let xs = expr_list(&p, token.RParen, "tuple element")?
      // `(x)` and `(x,)` are just `x`: there are no 1-tuples.
      if xs.len() == 1 {
        let e = xs[0]
        p.parened[e.id] = true
        return e
      }
      ast.ExprKind.Tuple(xs)
    }
    LBracket => {
      p.bump()
      ast.ExprKind.List(expr_list(&p, token.RBracket, "list element")?)
    }
    LBrace when p.map_lit_ahead() => {
      p.bump()
      var es: [(ast.Expr, ast.Expr)] = []
      while !p.list_end(token.RBrace) {
        let s = p.lift()
        let r = map_entry(&p)
        p.restore(s)
        es.push(r?)
        if p.list_sep(token.RBrace, "map entry")? { break }
      }
      ast.ExprKind.Map(es)
    }
    LBrace => ast.ExprKind.Block(block(&p)?)
    If => return if_expr(&p)
    Match => {
      p.bump()
      let scrut = head_expr(&p)?
      p.head_brace("match")?
      p.bump()
      let s = p.lift()
      let r = arms(&p)
      p.restore(s)
      ast.ExprKind.Match(scrut, r?)
    }
    Loop => {
      p.bump()
      ast.ExprKind.Loop(block(&p)?)
    }
    While => {
      p.bump()
      let cond = head_expr(&p)?
      p.head_brace("while")?
      let body = block(&p)?
      ast.ExprKind.While(cond, body)
    }
    For => {
      p.bump()
      let first = head_pattern(&p)?
      var index: ast.Pat? = none
      var pat = first
      if p.eat(token.Comma) {
        index = first
        pat = head_pattern(&p)?
      }
      p.expect(token.In, "after the loop pattern (`for x in xs` or `for i, x in xs`)")?
      let iter = head_expr(&p)?
      p.head_brace("for")?
      let body = block(&p)?
      ast.ExprKind.For(index, pat, iter, body)
    }
    Return => {
      p.bump()
      let value: ast.Expr? = if p.operand_ahead() { expr(&p)? } else { none }
      ast.ExprKind.Return(value)
    }
    Break => {
      p.bump()
      let value: ast.Expr? = if p.operand_ahead() { expr(&p)? } else { none }
      ast.ExprKind.Break(value)
    }
    Continue => {
      p.bump()
      ast.ExprKind.Continue
    }
    Let => fail(
      bad(
        diag.new(
          "E0032",
          start,
          "`let` is a statement, not an expression",
        ).note("put the binding on its own line inside a block"),
      ),
    )
    Var => fail(
      bad(
        diag.new(
          "E0032",
          start,
          "`var` is a statement, not an expression",
        ).note("put the binding on its own line inside a block"),
      ),
    )
    Assert => fail(
      bad(
        diag.new(
          "E0021",
          start,
          "`assert` is a statement, not an expression",
        ).note("put `assert cond` on its own line"),
      ),
    )
    Fn => fail(
      bad(
        p.expected(
          "E0021",
          "an expression",
        ).note("closures are written `x => x * 2` or `(a, b) => a + b`"),
      ),
    )
    _ => fail(bad(p.expected("E0021", "an expression")))
  }
  p.mk(kind, start)
}

/// `3.0<m/s>`: the literal, then its unit.
fn measured(p: var Parser, start: diag.Span): ast.ExprKind!diag.Fail {
  let lit = p.lit_token()!
  let e = p.mk(ast.ExprKind.Lit(lit), start)
  ast.ExprKind.Measured(e, units(&p)?)
}

fn map_entry(p: var Parser): (ast.Expr, ast.Expr)!diag.Fail {
  let k = expr(&p)?
  p.expect(token.Colon, "between a map key and its value")?
  (k, expr(&p)?)
}

/// A string literal: plain, or with interpolations parsed from their own token lists.
fn string(p: var Parser, parts: [token.StrPart]): ast.ExprKind!diag.Fail {
  if parts.all(x => x is Lit(_)) {
    var s: [str] = []
    for x in parts {
      match x {
        Lit(l) => s.push(l)
        _ => {}
      }
    }
    return ast.ExprKind.Lit(ast.Lit.Str(s.join("")))
  }
  var out: [ast.InterpPart] = []
  for part in parts {
    match part {
      Lit(l) => out.push(ast.InterpPart.Lit(l))
      Interp(toks, spec, _) => {
        let saved_toks = p.toks
        let saved_pos = p.pos
        let saved_prev = p.prev
        p.toks = toks
        p.pos = 0
        let s = p.lift()
        let r = interp_expr(&p)
        p.restore(s)
        p.toks = saved_toks
        p.pos = saved_pos
        p.prev = saved_prev
        out.push(ast.InterpPart.Expr(r?, spec))
      }
    }
  }
  ast.ExprKind.Interp(out)
}

fn interp_expr(p: var Parser): ast.Expr!diag.Fail {
  let e = expr(&p)?
  if !p.at(token.Eof) {
    fail(
      bad(
        p
          .expected("E0008", "`}}` or `:` after the interpolated expression")
          .note("an interpolation holds one expression, then an optional `:spec` (e.g. `{{x:.2}}`)"),
      ),
    )
  }
  e
}

fn closure(p: var Parser, params: [ast.Param], start: diag.Span): ast.Expr!diag.Fail {
  p.expect(token.FatArrow, "after the closure parameters")?
  let s = p.lift()
  let r = stmt_expr(&p)
  p.restore(s)
  let body = r?
  p.mk(ast.ExprKind.Closure(params, body), start)
}

fn if_expr(p: var Parser): ast.Expr!diag.Fail {
  let start = p.span()
  p.bump()
  let cond = head_expr(&p)?
  p.head_brace("if")?
  let then = block(&p)?
  // `} else` may also continue on the next line.
  if p.at(token.Newline) && p.peek_at(1) == token.Else { p.bump() }
  var els: ast.Expr? = none
  if p.eat(token.Else) {
    if p.at(token.If) {
      els = if_expr(&p)?
    } else {
      let s = p.span()
      let b = block(&p)?
      els = p.mk(ast.ExprKind.Block(b), s)
    }
  }
  p.mk(ast.ExprKind.If(cond, then, els), start)
}

/// Check for the `{` after a control-flow head, explaining the common mistakes.
fn head_brace(p: Parser, kw: str): ()!diag.Fail = match p.peek() {
  LBrace => if p.peek_at(1) is Ident(_) && p.peek_at(2) == token.Colon {
    fail(
      bad(
        diag
          .new("E0029", p.span(), "a struct literal inside a `{kw}` head needs parentheses")
          .note("the `{{` here starts the `{kw}` body; write e.g. `{kw} p == (Point {{ x: 1 }}) {{`"),
      ),
    )
  }
  Else => fail(
    bad(
      diag
        .new("E0029", p.span(), "an `else` inside a `{kw}` head needs parentheses")
        .note("write `{kw} (x else y) {{ ... }}`"),
    ),
  )
  Eq => fail(bad(p.expected("E0020", "`{{` to start the `{kw}` body").note("use `==` to compare")))
  _ => fail(bad(p.expected("E0020", "`{{` to start the `{kw}` body")))
}

/// After `match ... {`: arms separated by line breaks or commas, up to `}`.
fn arms(p: var Parser): [ast.Arm]!diag.Fail {
  var arms: [ast.Arm] = []
  loop {
    p.skip_newlines()
    if p.eat(token.RBrace) { return arms }
    let start = p.span()
    var pat = pattern(&p)?
    if p.at(token.Pipe) {
      var alts = [pat]
      while p.eat(token.Pipe) { alts.push(pattern(&p)?) }
      pat = ast.Pat { id: p.id(), span: start.to(p.prev), kind: ast.PatKind.Or(alts) }
    }
    var guard: ast.Expr? = none
    if p.eat(token.When) {
      let saved = p.no_closure
      p.no_closure = true
      let g = expr(&p)
      p.no_closure = saved
      guard = g?
    }
    p.expect(token.FatArrow, "after the match pattern")?
    let body = stmt_expr(&p)?
    arms.push(ast.Arm { span: start.to(p.prev), pat, guard, body })
    // The lexer joins a line that starts with `{` onto the previous one, so a map pattern
    // starting the next arm (`{"k": v} => ..`) arrives with no `Newline` before it.
    if !p.eat(token.Comma) &&
      !p.at(token.Newline) &&
      !p.at(token.RBrace) &&
      !p.brace_on_new_line() {
      fail(bad(p.expected("E0020", "a line break, `,` or `}}` after the match arm")))
    }
  }
}

/// At a `{` that starts a later line than the previous token.
fn brace_on_new_line(p: Parser): bool = p.at(token.LBrace) && p.span().line > p.prev.end_line

/// After `Path`, at `{`: `{ x: 1, y, ..base }`.
fn struct_lit(p: var Parser, path: [ast.Ident]): ast.ExprKind!diag.Fail {
  p.bump()
  var base: ast.Expr? = none
  var fields: [(ast.FieldInit?, diag.Span?)] = []
  while !p.list_end(token.RBrace) {
    let s = p.lift()
    let r = struct_lit_field(&p, &base)
    p.restore(s)
    fields.push(r?)
    if p.list_sep(token.RBrace, "field")? { break }
  }
  // `..base` followed by fields: (the span of `..base`, the first field after it)
  var misplaced: (diag.Span, diag.Span)? = none
  var out: [ast.FieldInit] = []
  var base_at: diag.Span? = none
  for (f, b) in fields {
    if b is some(_) { base_at = b }
    match f {
      some(fi) => {
        match base_at {
          some(b2) when misplaced is none => misplaced = (b2, fi.name.span)
          _ => {}
        }
        out.push(fi)
      }
      none => {}
    }
  }
  match misplaced {
    some((b, first)) => {
      var last = first
      match out.last() {
        some(f) => last = match f.value {
          some(v) => v.span
          none => f.name.span
        }
        none => {}
      }
      let t = p.text(b)
      fail(
        bad(
          diag
            .new("E0020", first, "`..base` must be the last thing in a struct literal")
            .note("move `{t}` after the last field")
            .fix(diag.Span { end_line: first.line, end_col: first.col, ..b }, "")
            .fix(last.after(), ", {t}"),
        ),
      )
    }
    none => {}
  }
  ast.ExprKind.Struct(path, out, base)
}

fn struct_lit_field(p: var Parser, base: var ast.Expr?): (ast.FieldInit?, diag.Span?)!diag.Fail {
  if p.at(token.DotDot) {
    let start = p.bump().span
    if base is some(_) {
      fail(bad(diag.new("E0020", start, "a struct literal has at most one `..base`")))
    }
    let b = expr(&p)?
    let at = start.to(b.span)
    base = b
    if !p.at(token.RBrace) && !p.at(token.Comma) && !p.at(token.Newline) {
      fail(bad(p.expected("E0020", "`}}` after `..base` (it must come last)")))
    }
    return (none, some(at))
  }
  let name = p.ident("a field name in the struct literal")?
  let value: ast.Expr? = if p.eat(token.Colon) { expr(&p)? } else { none }
  (some(ast.FieldInit { name, value }), none)
}

// ---- lookahead ----

/// At `(`: does the matching `)` precede `=>`?
fn paren_closure_ahead(p: Parser): bool {
  var depth = 0
  var i = p.pos
  while i < p.toks.len() {
    match p.toks[i].tok {
      LParen => depth += 1
      LBracket => depth += 1
      LBrace => depth += 1
      RParen => {
        depth -= 1
        if depth == 0 { return p.peek_at(i - p.pos + 1) == token.FatArrow }
      }
      RBracket => {
        depth -= 1
        if depth == 0 { return p.peek_at(i - p.pos + 1) == token.FatArrow }
      }
      RBrace => {
        depth -= 1
        if depth == 0 { return p.peek_at(i - p.pos + 1) == token.FatArrow }
      }
      Eof => return false
      _ => {}
    }
    i += 1
  }
  false
}

/// At `Name` or `a.b.Name`: is a struct literal body `{ field: ..`, `{ field, ..`, `{ field }`,
/// `{ ..base }` or `{}` next? Never in a control-flow head.
fn struct_lit_ahead(p: Parser): bool {
  if p.no_struct { return false }
  var i = 1
  while p.peek_at(i) == token.Dot && p.peek_at(i + 1) is Ident(_) { i += 2 }
  if p.peek_at(i) != token.LBrace { return false }
  // A struct literal's `{` is on the name's line; a `{` on the next line starts something
  // else (e.g. a `{}` map pattern starting the next match arm).
  if p.toks[p.pos + i].span.line > p.toks[p.pos + i - 1].span.end_line { return false }
  let j = p.skip_nl(i + 1)
  match p.peek_at(j) {
    RBrace => true
    DotDot => true
    Ident(_) => match p.peek_at(p.skip_nl(j + 1)) {
      Colon => true
      Comma => true
      RBrace => true
      _ => false
    }
    _ => false
  }
}

fn skip_nl(p: Parser, j0: int): int {
  var j = j0
  while p.peek_at(j) == token.Newline { j += 1 }
  j
}

/// At `{` in expression position: a map literal (`{}` or a first entry with a top-level
/// `:`) rather than a block.
fn map_lit_ahead(p: Parser): bool {
  let i = p.skip_nl(1)
  match p.peek_at(i) {
    RBrace => return true
    Let => return false
    Var => return false
    _ => {}
  }
  var depth = 0
  var k = p.pos + i
  while k < p.toks.len() {
    match p.toks[k].tok {
      LParen => depth += 1
      LBracket => depth += 1
      LBrace => depth += 1
      RParen => if depth == 0 { return false } else { depth -= 1 }
      RBracket => if depth == 0 { return false } else { depth -= 1 }
      RBrace => if depth == 0 { return false } else { depth -= 1 }
      Colon when depth == 0 => return true
      Comma when depth == 0 => return false
      Newline when depth == 0 => return false
      Eof when depth == 0 => return false
      _ => {}
    }
    k += 1
  }
  false
}

/// After `return` / `break`: does a value follow?
fn operand_ahead(p: Parser): bool = match p.peek() {
  Newline => false
  RBrace => false
  RParen => false
  RBracket => false
  Comma => false
  Eof => false
  Else => false
  FatArrow => false
  Colon => false
  _ => true
}

/// At `peek`: is it the `peek e` form? `peek(x)` (no space) and `p.peek()` are calls.
fn peek_operand_ahead(p: Parser): bool {
  let next = p.toks[min(p.pos + 1, p.toks.len() - 1)]
  match next.tok {
    Ident(_) => true
    Int(_) => true
    Float(_) => true
    Char(_) => true
    Str(_) => true
    True => true
    False => true
    If => true
    Match => true
    Await => true
    Catch => true
    LParen => next.space_before
    LBracket => next.space_before
    _ => false
  }
}

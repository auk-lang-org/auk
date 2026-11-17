//! Tokens -> AST: recursive descent, with precedence climbing for binary operators.
//!
//! Precedence, tightest first (spec.md): postfix (`.f()` `[i]` `?` `!` `?.`) > `await` > unary
//! `- ! ~` > `**` > `* / %` > `+ -` > `<< >>` > `&` > `^` > `|` > `..` > comparisons > `is` >
//! `&&` > `||` > `|>` > `else`. A bare `&`, `^` or `|` as a comparison operand is E0038 (C
//! would read `x & 1 == 0` differently), so the bitwise row's place relative to comparisons
//! never changes a program's meaning.
//! Two readings the table leaves open, chosen to match the spec's own examples:
//! - `await get(u)?` is `(await get(u))?` (spec, Async). So `await` takes a postfix chain of
//!   `.f`, `.f()`, `[i]` and calls, and a trailing `?`, `!` or `?.` applies to the awaited value.
//! - `x |> f(a)?` is `(x |> f(a))?` (spec: a `?` after a `|>` step applies to the whole pipe).

use super::ast::*;
use super::diag::{Diag, Span};
use super::lexer::lex;
use super::token::{StrPart, Tok, Token, keyword};

/// Parse a whole file. Errors are reported per item: after an error the parser skips to the
/// next line that starts an item, so one file can produce several diagnostics.
pub fn parse(src: &str) -> Result<Module, Vec<Diag>> {
    parse_with(src, false)
}

/// Parse a core prelude file (`src/prelude/*.duck`). The prelude may also use the
/// prelude-only forms `extern fn f(..): T = "c_symbol"` and `extern type T = "CType"`, and may
/// name functions with keywords (`fn enum(..)`, for `xs.enum()`).
pub fn parse_prelude(src: &str) -> Result<Module, Vec<Diag>> {
    parse_with(src, true)
}

fn parse_with(src: &str, prelude: bool) -> Result<Module, Vec<Diag>> {
    let lexed = lex(src).map_err(|d| vec![d])?;
    let lines = src.lines().map(|l| l.chars().collect()).collect();
    let mut p = Parser {
        toks: lexed.toks,
        lines,
        pos: 0,
        prev: Span::default(),
        next_id: 0,
        no_struct: false,
        no_closure: false,
        prelude,
        parened: Default::default(),
    };
    let mut raw = Vec::new();
    let mut errs = Vec::new();
    loop {
        p.skip_newlines();
        if p.at(&Tok::Eof) {
            break;
        }
        match p.item() {
            Ok(item) if p.item_ended() => raw.push(item),
            Ok(_) => {
                errs.push(p.expected("E0025", "a line break after the item").note("each item (`fn`, `struct`, ...) starts on its own line"));
                p.recover();
            }
            Err(d) => {
                errs.push(d);
                p.recover();
            }
        }
    }
    let items = group(raw, &mut errs);
    if errs.is_empty() { Ok(Module { doc: lexed.module_doc, items }) } else { Err(errs) }
}

/// An item before clause grouping.
enum Raw {
    Item(Item),
    Clause(FnClause),
}

/// Group contiguous `fn`s with the same name and arity (a body-less first one is the header).
/// Splitting a group by first-parameter type (overloading) needs types: the checker does it.
fn group(raw: Vec<Raw>, errs: &mut Vec<Diag>) -> Vec<Item> {
    let mut items: Vec<Item> = Vec::new();
    let mut last_was_clause = false;
    for r in raw {
        let c = match r {
            Raw::Item(i) => {
                items.push(i);
                last_was_clause = false;
                continue;
            }
            Raw::Clause(c) => c,
        };
        let same = |g: &FnGroup| g.name == c.name.name && g.arity == c.params.len();
        match items.last_mut() {
            Some(Item::Fn(g)) if last_was_clause && same(g) => {
                if c.body.is_none() {
                    errs.push(
                        Diag::new("E0031", c.name.span, format!("body-less `fn {}` after its clauses", c.name.name))
                            .note("a header line (docs, `pub`, contracts) must come before the clauses; otherwise give this `fn` a body"),
                    );
                } else {
                    g.clauses.push(c);
                }
            }
            _ => {
                let (name, arity) = (c.name.name.clone(), c.params.len());
                let (header, clauses) = if c.body.is_none() { (Some(Box::new(c)), vec![]) } else { (None, vec![c]) };
                items.push(Item::Fn(FnGroup { name, arity, header, clauses }));
            }
        }
        last_was_clause = true;
    }
    for item in &items {
        if let Item::Fn(FnGroup { header: Some(h), clauses, .. }) = item
            && clauses.is_empty()
        {
            {
                errs.push(
                    Diag::new("E0031", h.name.span, format!("`fn {}` has no body and no clauses follow it", h.name.name))
                        .note(format!(
                            "give it a body (`{{ ... }}` or `= expr`), or follow this header line with clauses `fn {}(...)` taking {} parameter(s)",
                            h.name.name,
                            h.params.len()
                        )),
                );
            }
        }
    }
    items
}

type PResult<T> = Result<T, Diag>;

struct Parser {
    toks: Vec<Token>,
    /// The source, by line, for fix-its that move text.
    lines: Vec<Vec<char>>,
    pos: usize,
    /// The span of the last consumed token.
    prev: Span,
    next_id: NodeId,
    /// In an `if`/`while`/`for`/`match` head or a contract/guard before a body: a `{` ends the
    /// expression, so there are no struct literals (or struct patterns), and `else` is not taken.
    no_struct: bool,
    /// In a match-arm guard: `x =>` and `(a) =>` end the guard instead of starting a closure.
    no_closure: bool,
    /// Parsing a core prelude file: `extern` declarations are allowed.
    prelude: bool,
    /// Expressions written inside their own parentheses `(a & b)`.
    parened: std::collections::HashSet<NodeId>,
}

fn binop(t: &Tok) -> Option<(BinOp, u8)> {
    Some(match t {
        Tok::OrOr => (BinOp::Or, 1),
        Tok::AndAnd => (BinOp::And, 2),
        Tok::EqEq => (BinOp::Eq, CMP),
        Tok::BangEq => (BinOp::Ne, CMP),
        Tok::Lt => (BinOp::Lt, CMP),
        Tok::Le => (BinOp::Le, CMP),
        Tok::Gt => (BinOp::Gt, CMP),
        Tok::Ge => (BinOp::Ge, CMP),
        Tok::Pipe => (BinOp::BitOr, 6),
        Tok::Caret => (BinOp::BitXor, 7),
        Tok::Amp => (BinOp::BitAnd, 8),
        Tok::Shl => (BinOp::Shl, 9),
        Tok::Plus => (BinOp::Add, 10),
        Tok::Minus => (BinOp::Sub, 10),
        Tok::PlusWrap => (BinOp::AddWrap, 10),
        Tok::MinusWrap => (BinOp::SubWrap, 10),
        Tok::Star => (BinOp::Mul, 11),
        Tok::Slash => (BinOp::Div, 11),
        Tok::Percent => (BinOp::Rem, 11),
        Tok::StarWrap => (BinOp::MulWrap, 11),
        Tok::StarStar => (BinOp::Pow, 12),
        _ => return None,
    })
}

/// Binding powers between `&&` (2) and `|` (6).
const IS: u8 = 3;
const CMP: u8 = 4;
const RANGE: u8 = 5;
const SHIFT: u8 = 9;

fn is_bitwise(op: BinOp) -> bool {
    matches!(op, BinOp::BitAnd | BinOp::BitOr | BinOp::BitXor)
}

fn assign_op(t: &Tok) -> Option<Option<BinOp>> {
    Some(match t {
        Tok::Eq => None,
        Tok::PlusEq => Some(BinOp::Add),
        Tok::MinusEq => Some(BinOp::Sub),
        Tok::StarEq => Some(BinOp::Mul),
        Tok::SlashEq => Some(BinOp::Div),
        Tok::PercentEq => Some(BinOp::Rem),
        Tok::AmpEq => Some(BinOp::BitAnd),
        Tok::PipeEq => Some(BinOp::BitOr),
        Tok::CaretEq => Some(BinOp::BitXor),
        Tok::ShlEq => Some(BinOp::Shl),
        _ => return None,
    })
}

fn is_lvalue(e: &Expr) -> bool {
    match &e.kind {
        ExprKind::Name(_) => true,
        ExprKind::Field { expr, .. } | ExprKind::TupleField { expr, .. } | ExprKind::Index { expr, .. } => is_lvalue(expr),
        _ => false,
    }
}

impl Parser {
    // ---- token helpers ----

    fn peek(&self) -> &Tok {
        &self.toks[self.pos].tok
    }

    /// The source text of `span`.
    fn text(&self, span: Span) -> String {
        let mut out = String::new();
        for ln in span.line..=span.end_line {
            let Some(chars) = self.lines.get(ln as usize - 1) else { break };
            let from = if ln == span.line { (span.col as usize - 1).min(chars.len()) } else { 0 };
            let to = if ln == span.end_line { (span.end_col as usize - 1).min(chars.len()) } else { chars.len() };
            out.extend(&chars[from..to.max(from)]);
            if ln != span.end_line {
                out.push('\n');
            }
        }
        out
    }

    fn peek_at(&self, n: usize) -> &Tok {
        &self.toks[(self.pos + n).min(self.toks.len() - 1)].tok
    }

    fn span(&self) -> Span {
        self.toks[self.pos].span
    }

    fn at(&self, t: &Tok) -> bool {
        self.peek() == t
    }

    fn bump(&mut self) -> Token {
        let t = self.toks[self.pos].clone();
        if self.pos < self.toks.len() - 1 {
            self.pos += 1;
        }
        self.prev = t.span;
        t
    }

    fn eat(&mut self, t: &Tok) -> bool {
        let yes = self.at(t);
        if yes {
            self.bump();
        }
        yes
    }

    fn skip_newlines(&mut self) {
        while self.at(&Tok::Newline) {
            self.bump();
        }
    }

    fn id(&mut self) -> NodeId {
        self.next_id += 1;
        self.next_id
    }

    /// An error at the current token: "expected {what}, found {token}".
    fn expected(&self, code: &'static str, what: &str) -> Diag {
        Diag::new(code, self.span(), format!("expected {what}, found {}", self.peek()))
    }

    fn expect(&mut self, t: &Tok, why: &str) -> PResult<Span> {
        if self.at(t) {
            return Ok(self.bump().span);
        }
        let what = if why.is_empty() { format!("`{}`", t.text()) } else { format!("`{}` {why}", t.text()) };
        Err(self.expected("E0020", &what))
    }

    /// A name after `.` or `?.`, where keywords are plain names too (`pairs.enum()`).
    fn member(&mut self, what: &str) -> PResult<Ident> {
        if keyword(self.peek().text()).as_ref() == Some(self.peek()) {
            let name = self.peek().text().to_string();
            return Ok(Ident { name, span: self.bump().span });
        }
        self.ident(what)
    }

    fn ident(&mut self, what: &str) -> PResult<Ident> {
        match self.peek() {
            Tok::Ident(n) if n != "_" => {
                let name = n.clone();
                Ok(Ident { name, span: self.bump().span })
            }
            _ => Err(self.expected("E0020", what)),
        }
    }

    /// Run `f` with the head restrictions lifted (inside brackets or a block).
    fn nested<T>(&mut self, f: impl FnOnce(&mut Self) -> PResult<T>) -> PResult<T> {
        let saved = (self.no_struct, self.no_closure);
        (self.no_struct, self.no_closure) = (false, false);
        let r = f(self);
        (self.no_struct, self.no_closure) = saved;
        r
    }

    /// Run `f` as a head: an expression followed by a `{` body.
    fn head<T>(&mut self, no_closure: bool, f: impl FnOnce(&mut Self) -> PResult<T>) -> PResult<T> {
        let saved = (self.no_struct, self.no_closure);
        (self.no_struct, self.no_closure) = (true, no_closure);
        let r = f(self);
        (self.no_struct, self.no_closure) = saved;
        r
    }

    /// `open item, item, ... close` with optional trailing comma; line breaks between items are
    /// allowed (they only occur inside braces).
    fn list<T>(&mut self, close: Tok, what: &str, mut f: impl FnMut(&mut Self) -> PResult<T>) -> PResult<Vec<T>> {
        let mut xs = Vec::new();
        loop {
            self.skip_newlines();
            if self.eat(&close) {
                return Ok(xs);
            }
            xs.push(self.nested(&mut f)?);
            self.skip_newlines();
            if !self.eat(&Tok::Comma) {
                self.skip_newlines();
                if self.eat(&close) {
                    return Ok(xs);
                }
                return Err(self.expected("E0020", &format!("`,` or `{}` after the {what}", close.text())));
            }
        }
    }

    /// After an item: a line break, the end of the file, or a token on a later line. (A line
    /// that ends with `>`, as in `fn f(): Set<int>`, continues by the newline rule, but a
    /// header line can still end there.)
    fn item_ended(&self) -> bool {
        matches!(self.peek(), Tok::Newline | Tok::Eof) || self.span().line > self.prev.end_line
    }

    /// Skip to the next line that starts with an item keyword.
    fn recover(&mut self) {
        loop {
            self.bump();
            if self.at(&Tok::Eof) {
                return;
            }
            let t = &self.toks[self.pos];
            let item = matches!(&t.tok, Tok::Fn | Tok::Pub | Tok::Async | Tok::Struct | Tok::Enum | Tok::Let)
                || matches!(&t.tok, Tok::Ident(n) if n == "test" || n == "shape" || n == "imprint");
            if item && t.span.col == 1 {
                return;
            }
        }
    }

    // ---- items ----

    fn item(&mut self) -> PResult<Raw> {
        let doc = self.toks[self.pos].doc.clone();
        let start = self.span();
        let public = self.eat(&Tok::Pub);
        let next_ident = matches!(self.peek_at(1), Tok::Ident(_));
        if matches!(self.peek(), Tok::Ident(n) if n == "extern") && matches!(self.peek_at(1), Tok::Fn | Tok::Async | Tok::Ident(_)) {
            return self.extern_item(doc, public, start);
        }
        Ok(match self.peek() {
            Tok::Fn | Tok::Async => Raw::Clause(self.fn_clause(doc, public, start)?),
            Tok::Struct => Raw::Item(Item::Struct(self.struct_def(doc, public, start)?)),
            Tok::Enum => Raw::Item(Item::Enum(self.enum_def(doc, public, start)?)),
            Tok::Let => Raw::Item(Item::Let(self.const_def(doc, public, start)?)),
            Tok::Ident(n) if n == "imprint" && next_ident => Raw::Item(Item::Imprint(self.const_def(doc, public, start)?)),
            Tok::Ident(n) if n == "shape" && next_ident => Raw::Item(Item::Shape(self.shape_def(doc, public, start)?)),
            Tok::Ident(n) if n == "test" && matches!(self.peek_at(1), Tok::Str(_)) => {
                self.bump();
                let name = match self.bump().tok {
                    Tok::Str(parts) => match parts.as_slice() {
                        [] => String::new(),
                        [StrPart::Lit(s)] => s.clone(),
                        _ => return Err(Diag::new("E0020", self.prev, "a test name can't interpolate").note("write a plain string: test \"name\" { ... }")),
                    },
                    _ => unreachable!(),
                };
                let body = self.block()?;
                Raw::Item(Item::Test(TestDef { id: self.id(), span: start.to(self.prev), name, doc, body }))
            }
            t => {
                let mut d = self.expected("E0024", "an item (`fn`, `struct`, `enum`, `shape`, `test`, `let` or `imprint`)");
                if matches!(t, Tok::Ident(n) if n == "import" || n == "use") {
                    d = d.note("Duck has no imports: refer to anything by its path, e.g. `json.parse(s)`; dependencies go in quack.toml");
                } else if !public {
                    d = d.note("statements and expressions belong inside a function; a program starts at `fn main`");
                }
                return Err(d);
            }
        })
    }

    /// `extern fn ... = "symbol"` or `extern type Name = "CType"` (prelude only).
    fn extern_item(&mut self, doc: Option<String>, public: bool, start: Span) -> PResult<Raw> {
        let kw = self.span();
        if !self.prelude {
            return Err(Diag::new("E0036", kw, "`extern` declarations are only allowed in the core prelude")
                .note("Duck code calls the runtime through the core library; there is no FFI syntax in user code"));
        }
        self.bump();
        if matches!(self.peek(), Tok::Ident(n) if n == "type") {
            self.bump();
            let name = self.ident("a type name after `extern type`")?;
            self.expect(&Tok::Eq, "and the C type in quotes")?;
            let c_type = self.extern_str("the C type")?;
            return Ok(Raw::Item(Item::ExternType(ExternTypeDef { id: self.id(), span: start.to(self.prev), name, doc, public, c_type })));
        }
        let mut c = self.fn_signature(doc, public, start)?;
        self.expect(&Tok::Eq, "and the runtime symbol in quotes")?;
        c.body = Some(FnBody::Extern(self.extern_str("the runtime symbol")?));
        c.span = start.to(self.prev);
        Ok(Raw::Clause(c))
    }

    fn extern_str(&mut self, what: &str) -> PResult<String> {
        if let Tok::Str(parts) = self.peek().clone() {
            self.bump();
            return self.plain_str(&parts, what);
        }
        Err(self.expected("E0020", &format!("{what} as a string")))
    }

    fn fn_clause(&mut self, doc: Option<String>, public: bool, start: Span) -> PResult<FnClause> {
        let mut c = self.fn_signature(doc, public, start)?;
        let body = if self.eat(&Tok::Eq) {
            Some(FnBody::Expr(Box::new(self.expr()?)))
        } else if self.at(&Tok::LBrace) {
            Some(FnBody::Block(self.block()?))
        } else if matches!(self.peek(), Tok::Newline | Tok::Eof | Tok::RBrace) || self.span().line > self.prev.end_line {
            None
        } else {
            return Err(self.expected("E0020", "`{` or `=` to start the function body, or a line break after a header line"));
        };
        c.body = body;
        c.span = start.to(self.prev);
        Ok(c)
    }

    /// Everything of a clause up to its body (`body: None`).
    fn fn_signature(&mut self, doc: Option<String>, public: bool, start: Span) -> PResult<FnClause> {
        let is_async = self.eat(&Tok::Async);
        self.expect(&Tok::Fn, "")?;
        let name = if self.prelude { self.member("a function name after `fn`")? } else { self.ident("a function name after `fn`")? };
        let generics = self.generics()?;
        self.expect(&Tok::LParen, "to start the parameter list")?;
        let params = self.list(Tok::RParen, "parameter", |p| p.param())?;
        let ret = if self.eat(&Tok::Colon) {
            Some(self.ty()?)
        } else if self.at(&Tok::Arrow) {
            let s = self.span();
            return Err(Diag::new("E0035", s, "return types are written with `:`, not `->`").note("e.g. `fn add(a: int, b: int): int = a + b`").fix(s, ":"));
        } else {
            None
        };
        let mut uses = Vec::new();
        if self.eat(&Tok::Uses) {
            uses.push(self.ident("an effect name after `uses` (fs, net, time, rand, env, proc, audio_out, gui, ffi)")?);
            while self.eat(&Tok::Comma) {
                uses.push(self.ident("an effect name after `,`")?);
            }
        }
        let (mut requires, mut ensures) = (Vec::new(), Vec::new());
        loop {
            if self.eat(&Tok::Requires) {
                requires.push(self.head(false, |p| p.expr())?);
            } else if self.eat(&Tok::Ensures) {
                ensures.push(self.head(false, |p| p.expr())?);
            } else {
                break;
            }
        }
        let guard = if self.eat(&Tok::When) { Some(self.head(false, |p| p.expr())?) } else { None };
        Ok(FnClause {
            id: self.id(),
            span: start.to(self.prev),
            name,
            doc,
            public,
            is_async,
            generics,
            params,
            ret,
            uses,
            requires,
            ensures,
            guard,
            body: None,
        })
    }

    /// `pat`, `pat: T` or `pat: var T`.
    fn param(&mut self) -> PResult<Param> {
        let start = self.span();
        let pat = self.pattern()?;
        let (ty, var) = if self.eat(&Tok::Colon) {
            let var = self.eat(&Tok::Var);
            (Some(self.ty()?), var)
        } else {
            (None, false)
        };
        Ok(Param { id: self.id(), span: start.to(self.prev), pat, ty, var })
    }

    /// `<A: Show + Eq, B>` or nothing.
    fn generics(&mut self) -> PResult<Vec<Generic>> {
        if !self.eat(&Tok::Lt) {
            return Ok(Vec::new());
        }
        self.list(Tok::Gt, "type parameter", |p| {
            let name = p.ident("a type parameter name")?;
            let mut bounds = Vec::new();
            if p.eat(&Tok::Colon) {
                bounds.push(p.ty()?);
                while p.eat(&Tok::Plus) {
                    bounds.push(p.ty()?);
                }
            }
            Ok(Generic { name, bounds })
        })
    }

    fn struct_def(&mut self, doc: Option<String>, public: bool, start: Span) -> PResult<StructDef> {
        self.bump();
        let name = self.ident("a struct name")?;
        let generics = self.generics()?;
        self.expect(&Tok::LBrace, "to start the struct's fields")?;
        let fields = self.list(Tok::RBrace, "field", |p| {
            let doc = p.toks[p.pos].doc.clone();
            let start = p.span();
            let name = p.ident("a field name")?;
            p.expect(&Tok::Colon, "and a type after the field name")?;
            let ty = p.ty()?;
            Ok(FieldDef { span: start.to(p.prev), name, ty, doc })
        })?;
        Ok(StructDef { id: self.id(), span: start.to(self.prev), name, doc, public, generics, fields })
    }

    fn enum_def(&mut self, doc: Option<String>, public: bool, start: Span) -> PResult<EnumDef> {
        self.bump();
        let name = self.ident("an enum name")?;
        let generics = self.generics()?;
        self.expect(&Tok::LBrace, "to start the enum's variants")?;
        let variants = self.list(Tok::RBrace, "variant", |p| {
            let doc = p.toks[p.pos].doc.clone();
            let start = p.span();
            let name = p.ident("a variant name")?;
            let fields = if p.eat(&Tok::LParen) {
                p.list(Tok::RParen, "variant field", |p| {
                    let name = if matches!(p.peek_at(1), Tok::Colon) {
                        let n = p.ident("a field name")?;
                        p.bump();
                        Some(n)
                    } else {
                        None
                    };
                    Ok(VariantField { name, ty: p.ty()? })
                })?
            } else {
                Vec::new()
            };
            Ok(Variant { id: p.id(), span: start.to(p.prev), name, doc, fields })
        })?;
        Ok(EnumDef { id: self.id(), span: start.to(self.prev), name, doc, public, generics, variants })
    }

    fn shape_def(&mut self, doc: Option<String>, public: bool, start: Span) -> PResult<ShapeDef> {
        self.bump();
        let name = self.ident("a shape name")?;
        let generics = self.generics()?;
        self.expect(&Tok::LBrace, "to start the shape's methods")?;
        let mut methods = Vec::new();
        loop {
            self.skip_newlines();
            if self.eat(&Tok::RBrace) {
                break;
            }
            if !matches!(self.peek(), Tok::Fn | Tok::Async) {
                return Err(self.expected("E0020", "a method signature `fn name(self, ...): T` or `}` in the shape"));
            }
            let doc = self.toks[self.pos].doc.clone();
            let s = self.span();
            methods.push(self.nested(|p| p.fn_clause(doc, false, s))?);
            self.eat(&Tok::Comma);
        }
        Ok(ShapeDef { id: self.id(), span: start.to(self.prev), name, doc, public, generics, methods })
    }

    /// Top-level `let NAME: T = e` or `imprint NAME: T = e`.
    fn const_def(&mut self, doc: Option<String>, public: bool, start: Span) -> PResult<ConstDef> {
        let kw = if self.bump().tok == Tok::Let { "let" } else { "imprint" };
        let name = self.ident(&format!("a constant name after `{kw}`"))?;
        let ty = if self.eat(&Tok::Colon) { Some(self.ty()?) } else { None };
        self.expect(&Tok::Eq, "and a value")?;
        let value = self.expr()?;
        Ok(ConstDef { id: self.id(), span: start.to(self.prev), name, doc, public, ty, value })
    }

    // ---- types ----

    fn ty(&mut self) -> PResult<Type> {
        let start = self.span();
        let kind = match self.peek().clone() {
            Tok::LBracket => {
                self.bump();
                let t = self.nested(|p| p.ty())?;
                self.expect(&Tok::RBracket, "to close the list type")?;
                TypeKind::List(Box::new(t))
            }
            Tok::LBrace => {
                self.bump();
                let k = self.nested(|p| p.ty())?;
                self.expect(&Tok::Colon, "between the key and value types of a map type `{K: V}`")?;
                let v = self.nested(|p| p.ty())?;
                self.expect(&Tok::RBrace, "to close the map type")?;
                TypeKind::Map(Box::new(k), Box::new(v))
            }
            Tok::LParen => {
                self.bump();
                let ts = self.list(Tok::RParen, "type", |p| p.ty())?;
                if self.eat(&Tok::FatArrow) {
                    TypeKind::Fn { params: ts, ret: Box::new(self.ty()?) }
                } else if ts.len() == 1 {
                    // `(T)` is just `T`
                    let mut t = ts.into_iter().next().unwrap();
                    t.span = start.to(self.prev);
                    return self.type_suffix(t, start);
                } else {
                    TypeKind::Tuple(ts)
                }
            }
            Tok::Ident(n) if n == "any" && matches!(self.peek_at(1), Tok::Ident(_)) => {
                self.bump();
                TypeKind::Any(Box::new(self.named_type()?))
            }
            Tok::Ident(_) => {
                let t = self.named_type()?;
                if !matches!(self.peek(), Tok::Unit(_)) {
                    return self.type_suffix(t, start);
                }
                TypeKind::Measured { base: Box::new(t), units: self.units()? }
            }
            _ => {
                return Err(self
                    .expected("E0023", "a type")
                    .note("types look like `int`, `[str]`, `{str: int}`, `(int, str)`, `T?`, `T!`, `T!E` or `Set<int>`"));
            }
        };
        let t = Type { id: self.id(), span: start.to(self.prev), kind };
        self.type_suffix(t, start)
    }

    /// The `<m/s>` unit token after a number literal or `int`/`float`, in canonical form.
    fn units(&mut self) -> PResult<super::units::Units> {
        let t = self.bump();
        let Tok::Unit(src) = &t.tok else { unreachable!() };
        super::units::parse(src).map_err(|why| {
            Diag::new("E0037", t.span, format!("malformed unit of measure `<{src}>`: {why}"))
                .note("a unit is names joined by `*` and `/`, with integer powers: `<m>`, `<m/s^2>`, `<kg*m/s^2>`, `<1/s>`; for a comparison, put spaces around `<`")
        })
    }

    /// `T?`, `T!` and `T!E` suffixes.
    fn type_suffix(&mut self, mut t: Type, start: Span) -> PResult<Type> {
        loop {
            let kind = if self.eat(&Tok::Question) {
                TypeKind::Optional(Box::new(t))
            } else if self.eat(&Tok::Bang) {
                let err = if matches!(self.peek(), Tok::Ident(_)) { Some(Box::new(self.named_type()?)) } else { None };
                TypeKind::Fallible { ok: Box::new(t), err }
            } else {
                return Ok(t);
            };
            t = Type { id: self.id(), span: start.to(self.prev), kind };
        }
    }

    /// `a.b.Name<Args>`
    fn named_type(&mut self) -> PResult<Type> {
        let start = self.span();
        let mut path = vec![self.ident("a type name")?];
        while self.at(&Tok::Dot) {
            self.bump();
            path.push(self.ident("a type name after `.`")?);
        }
        let args = if self.eat(&Tok::Lt) { self.list(Tok::Gt, "type argument", |p| p.ty())? } else { Vec::new() };
        Ok(Type { id: self.id(), span: start.to(self.prev), kind: TypeKind::Named { path, args } })
    }

    // ---- patterns ----

    fn pattern(&mut self) -> PResult<Pat> {
        let start = self.span();
        let kind = match self.peek().clone() {
            Tok::Ident(n) if n == "_" => {
                self.bump();
                PatKind::Wild
            }
            Tok::Ident(n) if matches!(n.as_str(), "some" | "ok" | "err") && self.peek_at(1) == &Tok::LParen => {
                self.bump();
                self.bump();
                let inner = Box::new(self.nested(|p| p.pattern())?);
                self.eat(&Tok::Comma);
                self.expect(&Tok::RParen, &format!("to close `{n}(`"))?;
                match n.as_str() {
                    "some" => PatKind::Some(inner),
                    "ok" => PatKind::Ok(inner),
                    _ => PatKind::Err(inner),
                }
            }
            Tok::Ident(n) if n == "none" && !matches!(self.peek_at(1), Tok::LParen | Tok::Dot) => {
                self.bump();
                PatKind::None
            }
            Tok::Ident(_) => {
                let mut path = vec![self.ident("a name")?];
                while self.at(&Tok::Dot) {
                    self.bump();
                    path.push(self.ident("a variant name after `.`")?);
                }
                if self.eat(&Tok::LParen) {
                    PatKind::Variant { path, args: Some(self.list(Tok::RParen, "pattern", |p| p.pattern())?) }
                } else if self.at(&Tok::LBrace) && !self.no_struct {
                    self.bump();
                    self.struct_pattern(path)?
                } else if path.len() > 1 {
                    PatKind::Variant { path, args: None }
                } else {
                    PatKind::Bind(path.pop().unwrap().name)
                }
            }
            Tok::Minus if matches!(self.peek_at(1), Tok::Int(_) | Tok::Float(_)) => {
                self.bump();
                PatKind::Lit { lit: self.lit_token().unwrap(), neg: true }
            }
            Tok::Str(parts) => {
                self.bump();
                let s = self.plain_str(&parts, "a string pattern")?;
                if self.eat(&Tok::Plus) {
                    let rest = self.pattern()?;
                    if !matches!(rest.kind, PatKind::Bind(_) | PatKind::Wild) {
                        return Err(Diag::new("E0022", rest.span, "expected a name or `_` after `+` in a string-prefix pattern")
                            .note("a prefix pattern looks like `\"GET \" + rest`"));
                    }
                    PatKind::StrPrefix { prefix: s, rest: Box::new(rest) }
                } else {
                    PatKind::Lit { lit: Lit::Str(s), neg: false }
                }
            }
            Tok::Int(_) | Tok::Float(_) | Tok::Char(_) | Tok::True | Tok::False => PatKind::Lit { lit: self.lit_token().unwrap(), neg: false },
            Tok::LParen => {
                self.bump();
                let mut ps = self.list(Tok::RParen, "pattern", |p| p.pattern())?;
                if ps.len() == 1 && self.toks[self.pos - 2].tok != Tok::Comma {
                    return Ok(ps.pop().unwrap());
                }
                PatKind::Tuple(ps)
            }
            Tok::LBracket => {
                self.bump();
                self.list_pattern()?
            }
            Tok::LBrace => {
                self.bump();
                let es = self.list(Tok::RBrace, "map pattern entry", |p| {
                    let key = p.lit_key()?;
                    p.expect(&Tok::Colon, "after the key in a map pattern")?;
                    Ok((key, p.pattern()?))
                })?;
                PatKind::Map(es)
            }
            _ => {
                return Err(self.expected("E0022", "a pattern").note(
                    "patterns look like `0`, `\"s\"`, `x`, `_`, `(a, b)`, `[h, ..t]`, `Circle(r)`, `User { name, .. }`, `{\"k\": v}`, `\"GET \" + rest`, `some(v)` or `none`",
                ));
            }
        };
        Ok(Pat { id: self.id(), span: start.to(self.prev), kind })
    }

    /// A literal map-pattern key (`"k"`, `1`, `-1`, `'c'`, `true`).
    fn lit_key(&mut self) -> PResult<Lit> {
        let neg = self.at(&Tok::Minus) && matches!(self.peek_at(1), Tok::Int(_) | Tok::Float(_));
        if neg {
            self.bump();
        }
        if let Tok::Str(parts) = self.peek().clone() {
            self.bump();
            return Ok(Lit::Str(self.plain_str(&parts, "a map pattern key")?));
        }
        match self.lit_token() {
            Some(Lit::Int(n)) if neg => Ok(Lit::Int(n.wrapping_neg())),
            Some(Lit::Float(x)) if neg => Ok(Lit::Float(-x)),
            Some(l) => Ok(l),
            None => Err(self.expected("E0034", "a literal key in a map pattern").note("map patterns match fixed keys: `{\"name\": n}`")),
        }
    }

    /// Consume an int, float, char or bool token as a literal.
    fn lit_token(&mut self) -> Option<Lit> {
        let l = match *self.peek() {
            Tok::Int(n) => Lit::Int(n),
            Tok::Float(x) => Lit::Float(x),
            Tok::Char(c) => Lit::Char(c),
            Tok::True => Lit::Bool(true),
            Tok::False => Lit::Bool(false),
            _ => return None,
        };
        self.bump();
        Some(l)
    }

    fn plain_str(&self, parts: &[StrPart], what: &str) -> PResult<String> {
        match parts {
            [] => Ok(String::new()),
            [StrPart::Lit(s)] => Ok(s.clone()),
            _ => Err(Diag::new("E0022", self.prev, format!("{what} can't interpolate")).note("use a plain string; bind the rest with `\"prefix\" + rest`")),
        }
    }

    /// After `[`: `[]`, `[a, b]`, `[h, ..t]`, `[.., last]`, `[a, .._, z]`.
    fn list_pattern(&mut self) -> PResult<PatKind> {
        let (mut head, mut rest, mut tail) = (Vec::new(), None::<Rest>, Vec::new());
        self.list(Tok::RBracket, "list pattern element", |p| {
            if p.at(&Tok::DotDot) {
                let s = p.bump().span;
                if let Some(r) = &rest {
                    return Err(Diag::new("E0033", s, "a list pattern can have only one `..`").note(format!("the first `..` is at {}", r.span)));
                }
                let pat = if matches!(p.peek(), Tok::Comma | Tok::RBracket) { None } else { Some(Box::new(p.pattern()?)) };
                rest = Some(Rest { span: s.to(p.prev), pat });
            } else if rest.is_some() {
                tail.push(p.pattern()?);
            } else {
                head.push(p.pattern()?);
            }
            Ok(())
        })?;
        Ok(PatKind::List { head, rest, tail })
    }

    /// After `Path {`: `{ name, age: a, .. }`.
    fn struct_pattern(&mut self, path: Vec<Ident>) -> PResult<PatKind> {
        let mut rest = false;
        let fields = self.list(Tok::RBrace, "field pattern", |p| {
            if p.eat(&Tok::DotDot) {
                if !matches!(p.peek(), Tok::RBrace | Tok::Comma | Tok::Newline) {
                    return Err(p.expected("E0020", "`}` after `..` in a struct pattern"));
                }
                rest = true;
                return Ok(None);
            }
            let name = p.ident("a field name in the struct pattern")?;
            let pat = if p.eat(&Tok::Colon) { Some(p.pattern()?) } else { None };
            Ok(Some(FieldPat { name, pat }))
        })?;
        Ok(PatKind::Struct { path, fields: fields.into_iter().flatten().collect(), rest })
    }

    // ---- statements and blocks ----

    fn block(&mut self) -> PResult<Block> {
        let start = self.span();
        self.expect(&Tok::LBrace, "to start a block")?;
        let stmts = self.nested(|p| {
            let mut stmts = Vec::new();
            loop {
                p.skip_newlines();
                if p.eat(&Tok::RBrace) {
                    return Ok(stmts);
                }
                stmts.push(p.stmt()?);
                if !matches!(p.peek(), Tok::Newline | Tok::RBrace) {
                    return Err(p
                        .expected("E0025", "a line break or `}` after the statement")
                        .note("each statement goes on its own line; a line that ends with an operator continues on the next"));
                }
            }
        })?;
        Ok(Block { id: self.id(), span: start.to(self.prev), stmts })
    }

    fn stmt(&mut self) -> PResult<Expr> {
        if !matches!(self.peek(), Tok::Let | Tok::Var) {
            return self.stmt_expr();
        }
        let start = self.span();
        let mutable = self.bump().tok == Tok::Var;
        let pat = self.pattern()?;
        let ty = if self.eat(&Tok::Colon) { Some(self.ty()?) } else { None };
        self.expect(&Tok::Eq, "and a value")?;
        let value = self.pipe_expr()?;
        let els = if self.eat(&Tok::Else) { Some(self.else_arm()?) } else { None };
        let kind = ExprKind::Let { mutable, pat, ty, value: Box::new(value), els };
        Ok(Expr { id: self.id(), span: start.to(self.prev), kind })
    }

    /// An expression, an assignment or an `assert`: block statements, match-arm and closure
    /// bodies.
    fn stmt_expr(&mut self) -> PResult<Expr> {
        let start = self.span();
        if self.eat(&Tok::Assert) {
            let e = self.expr()?;
            return Ok(Expr { id: self.id(), span: start.to(self.prev), kind: ExprKind::Assert(Box::new(e)) });
        }
        let target = self.expr()?;
        let shr_eq = self.shr_ahead() == Some(true);
        let op = if shr_eq { Some(BinOp::Shr) } else if let Some(op) = assign_op(self.peek()) { op } else { return Ok(target) };
        if !is_lvalue(&target) {
            return Err(Diag::new("E0027", target.span, "can't assign to this expression")
                .note("an assignment target is a variable, a field or an index, like `a.b[i].c`"));
        }
        self.bump();
        if shr_eq {
            self.bump();
        }
        let value = self.expr()?;
        let kind = ExprKind::Assign { op, target: Box::new(target), value: Box::new(value) };
        Ok(Expr { id: self.id(), span: start.to(self.prev), kind })
    }

    // ---- expressions ----

    fn mk(&mut self, kind: ExprKind, start: Span) -> Expr {
        Expr { id: self.id(), span: start.to(self.prev), kind }
    }

    pub fn expr(&mut self) -> PResult<Expr> {
        let e = self.pipe_expr()?;
        if self.no_struct || !self.at(&Tok::Else) {
            return Ok(e);
        }
        self.bump();
        let arm = self.else_arm()?;
        let start = e.span;
        Ok(self.mk(ExprKind::Else { expr: Box::new(e), arm }, start))
    }

    /// After `else`: `fallback` or `e => fallback`.
    fn else_arm(&mut self) -> PResult<ElseArm> {
        let binder = match self.peek() {
            Tok::Ident(n) if n != "_" && self.peek_at(1) == &Tok::FatArrow => {
                let b = self.ident("a name")?;
                self.bump();
                Some(b)
            }
            _ => None,
        };
        Ok(ElseArm { binder, body: Box::new(self.expr()?) })
    }

    fn pipe_expr(&mut self) -> PResult<Expr> {
        let mut lhs = self.binary(1)?;
        while self.at(&Tok::PipeGt) {
            self.bump();
            let start = self.span();
            let mut callee = match self.peek().clone() {
                Tok::Ident(n) if n != "_" => {
                    self.bump();
                    self.mk(ExprKind::Name(n), start)
                }
                _ => {
                    return Err(self
                        .expected("E0030", "a function name after `|>`")
                        .note("`x |> f(a)` means `f(x, a)`; the step is a function name or path with optional arguments"));
                }
            };
            while self.at(&Tok::Dot) && matches!(self.peek_at(1), Tok::Ident(_)) {
                self.bump();
                let name = self.ident("a name")?;
                callee = self.mk(ExprKind::Field { expr: Box::new(callee), name }, start);
            }
            let args = if self.at(&Tok::LParen) { self.call_args()? } else { Vec::new() };
            let s = lhs.span;
            lhs = self.mk(ExprKind::Pipe { lhs: Box::new(lhs), callee: Box::new(callee), args }, s);
            // A `?` or `!` after a step applies to the whole pipe so far.
            while matches!(self.peek(), Tok::Question | Tok::Bang | Tok::QuestionQuestion) {
                let kind = match self.peek() {
                    Tok::QuestionQuestion => self.double_try(lhs)?,
                    Tok::Question => {
                        self.bump();
                        ExprKind::Try(Box::new(lhs))
                    }
                    _ => {
                        self.bump();
                        ExprKind::Unwrap(Box::new(lhs))
                    }
                };
                lhs = self.mk(kind, s);
            }
            if matches!(self.peek(), Tok::Dot | Tok::QuestionDot | Tok::LBracket) {
                return Err(self.expected("E0030", "`|>` or the end of the pipe").note(
                    "`x.f(a)` and `x |> f(a)` both mean `f(x, a)`; don't mix them in one chain (use `|>` for every step, or wrap the pipe in parentheses)",
                ));
            }
        }
        Ok(lhs)
    }

    fn binary(&mut self, min: u8) -> PResult<Expr> {
        let mut lhs = self.unary()?;
        loop {
            let start = lhs.span;
            let t = self.peek().clone();
            if t == Tok::Is && IS >= min {
                self.bump();
                let pat = self.pattern()?;
                lhs = self.mk(ExprKind::Is { expr: Box::new(lhs), pat }, start);
                continue;
            }
            if matches!(t, Tok::DotDot | Tok::DotDotEq) && RANGE >= min {
                self.bump();
                let hi = self.binary(RANGE + 1)?;
                lhs = self.mk(ExprKind::Range { lo: Box::new(lhs), hi: Box::new(hi), inclusive: t == Tok::DotDotEq }, start);
                if matches!(self.peek(), Tok::DotDot | Tok::DotDotEq) {
                    return Err(self.expected("E0020", "the end of the range").note("ranges can't be chained; use parentheses"));
                }
                continue;
            }
            let shr = self.shr_ahead();
            if shr == Some(true) {
                break; // `>>=`
            }
            let Some((op, prec)) = (if shr.is_some() { Some((BinOp::Shr, SHIFT)) } else { binop(&t) }) else { break };
            if prec < min {
                break;
            }
            self.bump();
            if shr.is_some() {
                self.bump();
            }
            // `**` is right-associative; the rest are left-associative.
            let rhs = self.binary(if op == BinOp::Pow { prec } else { prec + 1 })?;
            if prec == CMP {
                self.check_bitwise_operand(&lhs)?;
                self.check_bitwise_operand(&rhs)?;
            }
            lhs = self.mk(ExprKind::Binary { op, lhs: Box::new(lhs), rhs: Box::new(rhs) }, start);
            if prec == CMP && binop(self.peek()).is_some_and(|(_, p)| p == CMP) {
                return Err(Diag::new("E0026", self.span(), "comparison operators cannot be chained")
                    .note("write `a < b && b < c` instead of `a < b < c`"));
            }
        }
        Ok(lhs)
    }

    /// At `>`: `Some(false)` for `>>`, `Some(true)` for `>>=` (the lexer leaves them as separate
    /// `>` tokens so nested generics close), `None` otherwise.
    fn shr_ahead(&self) -> Option<bool> {
        let next = self.toks.get(self.pos + 1).filter(|t| !t.space_before)?;
        match (self.peek(), &next.tok) {
            (Tok::Gt, Tok::Gt) => Some(false),
            (Tok::Gt, Tok::Ge) => Some(true),
            _ => None,
        }
    }

    /// A comparison operand that is a bare `&`, `|` or `^`: C reads `x & 1 == 0` as
    /// `x & (1 == 0)`, so Duck asks for parentheses whichever way it is meant.
    fn check_bitwise_operand(&self, e: &Expr) -> PResult<()> {
        let ExprKind::Binary { op, .. } = &e.kind else { return Ok(()) };
        if !is_bitwise(*op) || self.parened.contains(&e.id) {
            return Ok(());
        }
        let (open, close) = (Span { end_line: e.span.line, end_col: e.span.col, ..e.span }, e.span.after());
        Err(Diag::new("E0038", e.span, format!("`{}` mixed with a comparison needs parentheses", op.symbol()))
            .note("C reads `x & 1 == 0` as `x & (1 == 0)`; Duck makes you write which one you mean")
            .note("add parentheses around the bitwise operation")
            .fix(open, "(")
            .fix(close, ")"))
    }

    fn unary(&mut self) -> PResult<Expr> {
        let start = self.span();
        let op = match self.peek() {
            Tok::Minus => UnOp::Neg,
            Tok::Bang => UnOp::Not,
            Tok::Tilde => UnOp::BitNot,
            Tok::Amp => {
                return Err(Diag::new("E0028", start, "`&` is only allowed directly on a call argument")
                    .note("`&x` passes `x` to a `var` parameter: `push2(&xs, 7)`"));
            }
            _ => return self.await_expr(),
        };
        self.bump();
        let e = self.unary()?;
        Ok(self.mk(ExprKind::Unary { op, expr: Box::new(e) }, start))
    }

    /// `await e` and `catch e` (same precedence, either order: `catch await t`). A trailing `?`,
    /// `!` or `?.` applies to the result: `catch f(x)?` is `(catch f(x))?`.
    fn await_expr(&mut self) -> PResult<Expr> {
        let start = self.span();
        let catch = self.at(&Tok::Catch);
        if !catch && !self.eat(&Tok::Await) {
            let e = self.primary()?;
            return self.postfix(e, false);
        }
        if catch {
            self.bump();
        } else if matches!(self.peek(), Tok::Ident(s) if s == "any") && self.peek_operand_ahead() {
            // `await any ts` (`any` is only special here; `await any(ts)` calls a function `any`)
            self.bump();
            let operand = self.primary()?;
            let operand = self.postfix(operand, true)?;
            let e = self.mk(ExprKind::AwaitAny(Box::new(operand)), start);
            return self.postfix(e, false);
        }
        let operand = if self.at(&Tok::Await) || self.at(&Tok::Catch) { self.await_expr()? } else { self.primary()? };
        let operand = self.postfix(operand, true)?;
        let kind = if catch { ExprKind::Catch(Box::new(operand)) } else { ExprKind::Await(Box::new(operand)) };
        let e = self.mk(kind, start);
        self.postfix(e, false)
    }

    /// Postfix operators. With `stop_at_try`, stop before `?`, `!` and `?.` (an `await`
    /// operand).
    fn postfix(&mut self, mut e: Expr, stop_at_try: bool) -> PResult<Expr> {
        loop {
            let start = e.span;
            let kind = match self.peek().clone() {
                Tok::Dot => {
                    self.bump();
                    if let Tok::Int(n) = *self.peek() {
                        self.bump();
                        ExprKind::TupleField { expr: Box::new(e), index: n as u32 }
                    } else {
                        let name = self.member("a field or method name after `.`")?;
                        if self.at(&Tok::LParen) {
                            ExprKind::MethodCall { recv: Box::new(e), name, args: self.call_args()? }
                        } else {
                            ExprKind::Field { expr: Box::new(e), name }
                        }
                    }
                }
                Tok::LParen => ExprKind::Call { callee: Box::new(e), args: self.call_args()? },
                Tok::LBracket => {
                    self.bump();
                    let i = self.nested(|p| p.expr())?;
                    self.expect(&Tok::RBracket, "to close the index")?;
                    match i.kind {
                        ExprKind::Range { lo, hi, inclusive } => ExprKind::Slice { expr: Box::new(e), lo, hi, inclusive },
                        _ => ExprKind::Index { expr: Box::new(e), index: Box::new(i) },
                    }
                }
                Tok::Question if !stop_at_try => {
                    self.bump();
                    ExprKind::Try(Box::new(e))
                }
                Tok::Bang if !stop_at_try => {
                    self.bump();
                    ExprKind::Unwrap(Box::new(e))
                }
                Tok::QuestionQuestion if !stop_at_try => self.double_try(e)?,
                Tok::QuestionDot if !stop_at_try => {
                    self.bump();
                    if let Tok::Int(n) = *self.peek() {
                        // `x?.0`: a tuple element (see `Ident::tuple_index`)
                        let span = self.bump().span;
                        let name = Ident { name: n.to_string(), span };
                        ExprKind::OptChain { expr: Box::new(e), name, args: None }
                    } else {
                        let name = self.member("a field, method name or tuple element number after `?.`")?;
                        let args = if self.at(&Tok::LParen) { Some(self.call_args()?) } else { None };
                        ExprKind::OptChain { expr: Box::new(e), name, args }
                    }
                }
                _ => return Ok(e),
            };
            e = self.mk(kind, start);
        }
    }

    /// At `??` after an operand: two postfix `?`s. Consumes the `??`.
    fn double_try(&mut self, e: Expr) -> PResult<ExprKind> {
        let q = self.bump().span;
        // `x ?? 0`: an attempt at a default (null-coalescing) operator
        let next = self.span();
        let operand = matches!(self.peek(), Tok::Int(_) | Tok::Float(_) | Tok::Char(_) | Tok::Str(_) | Tok::Ident(_) | Tok::True | Tok::False);
        if operand && next.line == q.end_line {
            let pre = if q.col == e.span.end_col && q.line == e.span.end_line { " " } else { "" };
            let post = if next.col == q.end_col { " " } else { "" };
            return Err(Diag::new("E0039", q, "`??` is a hole, not a default operator; use `x else 0`")
                .note("`else` gives the default for a missing (`T?`) or failed (`T!`) value: `m.get(k) else 0`; it binds loosest, so write `(m.get(k) else 0) + 1` inside a larger expression")
                .fix(q, format!("{pre}else{post}")));
        }
        let start = e.span;
        let inner = self.mk(ExprKind::Try(Box::new(e)), start);
        Ok(ExprKind::Try(Box::new(inner)))
    }

    /// `(a, &b, x => y)`
    fn call_args(&mut self) -> PResult<Vec<Expr>> {
        self.expect(&Tok::LParen, "")?;
        self.list(Tok::RParen, "argument", |p| {
            let start = p.span();
            if !p.eat(&Tok::Amp) {
                return p.expr();
            }
            let e = p.await_expr()?;
            if !is_lvalue(&e) {
                return Err(Diag::new("E0028", e.span, "`&` needs a variable, field or index")
                    .note("`&x` lets a `var` parameter change the caller's `x`, so `x` must be something assignable"));
            }
            Ok(p.mk(ExprKind::Ref(Box::new(e)), start))
        })
    }

    fn primary(&mut self) -> PResult<Expr> {
        let start = self.span();
        let kind = match self.peek().clone() {
            Tok::Int(_) | Tok::Float(_) if matches!(self.peek_at(1), Tok::Unit(_)) => {
                let lit = self.lit_token().unwrap();
                let expr = Box::new(self.mk(ExprKind::Lit(lit), start));
                ExprKind::Measured { expr, units: self.units()? }
            }
            Tok::Int(_) | Tok::Float(_) | Tok::Char(_) | Tok::True | Tok::False => ExprKind::Lit(self.lit_token().unwrap()),
            Tok::Str(parts) => {
                self.bump();
                self.string(parts)?
            }
            Tok::QuestionQuestion => {
                self.bump();
                ExprKind::Hole
            }
            Tok::Ident(_) if self.peek_at(1) == &Tok::FatArrow && !self.no_closure => {
                let param = self.param()?;
                return self.closure(vec![param], start);
            }
            Tok::LParen if !self.no_closure && self.paren_closure_ahead() => {
                self.bump();
                let params = self.list(Tok::RParen, "closure parameter", |p| p.param())?;
                return self.closure(params, start);
            }
            Tok::Ident(n) if n == "_" => {
                return Err(Diag::new("E0021", start, "`_` can only be used in patterns, not as a value").note("`_` ignores a value in `let _ = ...`, match arms and parameters"));
            }
            Tok::Ident(n) if n == "peek" && self.peek_operand_ahead() => {
                self.bump();
                ExprKind::Peek(Box::new(self.expr()?))
            }
            Tok::Ident(_) if self.struct_lit_ahead() => {
                let mut path = vec![self.ident("a name")?];
                while self.eat(&Tok::Dot) {
                    path.push(self.ident("a name")?);
                }
                self.struct_lit(path)?
            }
            Tok::Ident(n) => {
                self.bump();
                ExprKind::Name(n)
            }
            Tok::LParen => {
                self.bump();
                let mut xs = self.list(Tok::RParen, "tuple element", |p| p.expr())?;
                // `(x)` and `(x,)` are just `x`: there are no 1-tuples.
                if xs.len() == 1 {
                    let e = xs.pop().unwrap();
                    self.parened.insert(e.id);
                    return Ok(e);
                }
                ExprKind::Tuple(xs)
            }
            Tok::LBracket => {
                self.bump();
                ExprKind::List(self.list(Tok::RBracket, "list element", |p| p.expr())?)
            }
            Tok::LBrace if self.map_lit_ahead() => {
                self.bump();
                ExprKind::Map(self.list(Tok::RBrace, "map entry", |p| {
                    let k = p.expr()?;
                    p.expect(&Tok::Colon, "between a map key and its value")?;
                    Ok((k, p.expr()?))
                })?)
            }
            Tok::LBrace => ExprKind::Block(self.block()?),
            Tok::If => return self.if_expr(),
            Tok::Match => {
                self.bump();
                let scrut = self.head(false, |p| p.expr())?;
                self.head_brace("match")?;
                self.bump();
                let arms = self.nested(|p| p.arms())?;
                ExprKind::Match { scrut: Box::new(scrut), arms }
            }
            Tok::Loop => {
                self.bump();
                ExprKind::Loop(self.block()?)
            }
            Tok::While => {
                self.bump();
                let cond = self.head(false, |p| p.expr())?;
                self.head_brace("while")?;
                ExprKind::While { cond: Box::new(cond), body: self.block()? }
            }
            Tok::For => {
                self.bump();
                let first = self.head(false, |p| p.pattern())?;
                let (index, pat) = if self.eat(&Tok::Comma) { (Some(first), self.head(false, |p| p.pattern())?) } else { (None, first) };
                self.expect(&Tok::In, "after the loop pattern (`for x in xs` or `for i, x in xs`)")?;
                let iter = self.head(false, |p| p.expr())?;
                self.head_brace("for")?;
                ExprKind::For { index, pat, iter: Box::new(iter), body: self.block()? }
            }
            Tok::Return | Tok::Break => {
                let is_return = self.bump().tok == Tok::Return;
                let value = if self.operand_ahead() { Some(Box::new(self.expr()?)) } else { None };
                if is_return { ExprKind::Return(value) } else { ExprKind::Break(value) }
            }
            Tok::Continue => {
                self.bump();
                ExprKind::Continue
            }
            Tok::Let | Tok::Var => {
                return Err(Diag::new("E0032", start, format!("`{}` is a statement, not an expression", self.peek().text()))
                    .note("put the binding on its own line inside a block"));
            }
            Tok::Assert => {
                return Err(Diag::new("E0021", start, "`assert` is a statement, not an expression").note("put `assert cond` on its own line"));
            }
            Tok::Fn => {
                return Err(self.expected("E0021", "an expression").note("closures are written `x => x * 2` or `(a, b) => a + b`"));
            }
            _ => return Err(self.expected("E0021", "an expression")),
        };
        Ok(self.mk(kind, start))
    }

    /// A string literal: plain, or with interpolations parsed from their own token lists.
    fn string(&mut self, parts: Vec<StrPart>) -> PResult<ExprKind> {
        if parts.iter().all(|p| matches!(p, StrPart::Lit(_))) {
            return Ok(ExprKind::Lit(Lit::Str(parts.into_iter().map(|p| if let StrPart::Lit(s) = p { s } else { unreachable!() }).collect())));
        }
        let mut out = Vec::new();
        for p in parts {
            match p {
                StrPart::Lit(s) => out.push(InterpPart::Lit(s)),
                StrPart::Interp { toks, spec, .. } => {
                    let saved = (std::mem::replace(&mut self.toks, toks), self.pos, self.prev);
                    self.pos = 0;
                    let r = self.nested(|p| {
                        let e = p.expr()?;
                        if !p.at(&Tok::Eof) {
                            return Err(p
                                .expected("E0008", "`}` or `:` after the interpolated expression")
                                .note("an interpolation holds one expression, then an optional `:spec` (e.g. `{x:.2}`)"));
                        }
                        Ok(e)
                    });
                    (self.toks, self.pos, self.prev) = saved;
                    out.push(InterpPart::Expr { expr: Box::new(r?), spec });
                }
            }
        }
        Ok(ExprKind::Interp(out))
    }

    fn closure(&mut self, params: Vec<Param>, start: Span) -> PResult<Expr> {
        self.expect(&Tok::FatArrow, "after the closure parameters")?;
        let body = self.nested(|p| p.stmt_expr())?;
        Ok(self.mk(ExprKind::Closure { params, body: Box::new(body) }, start))
    }

    fn if_expr(&mut self) -> PResult<Expr> {
        let start = self.span();
        self.bump();
        let cond = self.head(false, |p| p.expr())?;
        self.head_brace("if")?;
        let then = self.block()?;
        // `} else` may also continue on the next line.
        if self.at(&Tok::Newline) && self.peek_at(1) == &Tok::Else {
            self.bump();
        }
        let els = if self.eat(&Tok::Else) {
            if self.at(&Tok::If) {
                Some(Box::new(self.if_expr()?))
            } else {
                let s = self.span();
                let b = self.block()?;
                Some(Box::new(self.mk(ExprKind::Block(b), s)))
            }
        } else {
            None
        };
        Ok(self.mk(ExprKind::If { cond: Box::new(cond), then, els }, start))
    }

    /// Check for the `{` after a control-flow head, explaining the common mistakes.
    fn head_brace(&self, kw: &str) -> PResult<()> {
        match self.peek() {
            Tok::LBrace => {
                if matches!(self.peek_at(1), Tok::Ident(_)) && self.peek_at(2) == &Tok::Colon {
                    return Err(Diag::new("E0029", self.span(), format!("a struct literal inside a `{kw}` head needs parentheses"))
                        .note(format!("the `{{` here starts the `{kw}` body; write e.g. `{kw} p == (Point {{ x: 1 }}) {{`")));
                }
                Ok(())
            }
            Tok::Else => Err(Diag::new("E0029", self.span(), format!("an `else` inside a `{kw}` head needs parentheses"))
                .note(format!("write `{kw} (x else y) {{ ... }}`"))),
            Tok::Eq => Err(self.expected("E0020", &format!("`{{` to start the `{kw}` body")).note("use `==` to compare")),
            _ => Err(self.expected("E0020", &format!("`{{` to start the `{kw}` body"))),
        }
    }

    /// After `match ... {`: arms separated by line breaks or commas, up to `}`.
    fn arms(&mut self) -> PResult<Vec<Arm>> {
        let mut arms = Vec::new();
        loop {
            self.skip_newlines();
            if self.eat(&Tok::RBrace) {
                return Ok(arms);
            }
            let start = self.span();
            let pat = self.pattern()?;
            let guard = if self.eat(&Tok::When) {
                let saved = self.no_closure;
                self.no_closure = true;
                let g = self.expr();
                self.no_closure = saved;
                Some(g?)
            } else {
                None
            };
            self.expect(&Tok::FatArrow, "after the match pattern")?;
            let body = self.stmt_expr()?;
            arms.push(Arm { span: start.to(self.prev), pat, guard, body });
            // The lexer joins a line that starts with `{` onto the previous one, so a map pattern
            // starting the next arm (`{"k": v} => ..`) arrives with no `Newline` before it.
            if !self.eat(&Tok::Comma) && !matches!(self.peek(), Tok::Newline | Tok::RBrace) && !self.brace_on_new_line() {
                return Err(self.expected("E0020", "a line break, `,` or `}` after the match arm"));
            }
        }
    }

    /// At a `{` that starts a later line than the previous token.
    fn brace_on_new_line(&self) -> bool {
        self.at(&Tok::LBrace) && self.span().line > self.prev.end_line
    }

    /// After `Path`, at `{`: `{ x: 1, y, ..base }`.
    fn struct_lit(&mut self, path: Vec<Ident>) -> PResult<ExprKind> {
        self.bump();
        let mut base: Option<Box<Expr>> = None;
        let fields = self.list(Tok::RBrace, "field", |p| {
            if p.at(&Tok::DotDot) {
                let start = p.bump().span;
                if base.is_some() {
                    return Err(Diag::new("E0020", start, "a struct literal has at most one `..base`"));
                }
                let b = p.expr()?;
                let at = start.to(b.span);
                base = Some(Box::new(b));
                if !matches!(p.peek(), Tok::RBrace | Tok::Comma | Tok::Newline) {
                    return Err(p.expected("E0020", "`}` after `..base` (it must come last)"));
                }
                return Ok((None, Some(at)));
            }
            let name = p.ident("a field name in the struct literal")?;
            let value = if p.eat(&Tok::Colon) { Some(p.expr()?) } else { None };
            Ok((Some(FieldInit { name, value }), None))
        })?;
        // `..base` followed by fields: (the span of `..base`, the first field after it)
        let mut misplaced: Option<(Span, Span)> = None;
        let mut out = Vec::new();
        let mut base_at: Option<Span> = None;
        for (f, b) in fields {
            if let Some(b) = b {
                base_at = Some(b);
            }
            if let Some(f) = f {
                if let Some(b) = base_at
                    && misplaced.is_none()
                {
                    misplaced = Some((b, f.name.span));
                }
                out.push(f);
            }
        }
        if let Some((b, first)) = misplaced {
            let last = out.last().map(|f| f.value.as_ref().map_or(f.name.span, |v| v.span)).unwrap_or(first);
            return Err(Diag::new("E0020", first, "`..base` must be the last thing in a struct literal")
                .note(format!("move `{}` after the last field", self.text(b)))
                .fix(Span { end_line: first.line, end_col: first.col, ..b }, "")
                .fix(last.after(), format!(", {}", self.text(b))));
        }
        Ok(ExprKind::Struct { path, fields: out, base })
    }

    // ---- lookahead ----

    /// At `(`: does the matching `)` precede `=>`?
    fn paren_closure_ahead(&self) -> bool {
        let mut depth = 0;
        for (i, t) in self.toks[self.pos..].iter().enumerate() {
            match t.tok {
                Tok::LParen | Tok::LBracket | Tok::LBrace => depth += 1,
                Tok::RParen | Tok::RBracket | Tok::RBrace => {
                    depth -= 1;
                    if depth == 0 {
                        return self.peek_at(i + 1) == &Tok::FatArrow;
                    }
                }
                Tok::Eof => return false,
                _ => {}
            }
        }
        false
    }

    /// At `Name` or `a.b.Name`: is a struct literal body `{ field: ..`, `{ field, ..`, `{ field }`,
    /// `{ ..base }` or `{}` next? Never in a control-flow head.
    fn struct_lit_ahead(&self) -> bool {
        if self.no_struct {
            return false;
        }
        let mut i = 1;
        while self.peek_at(i) == &Tok::Dot && matches!(self.peek_at(i + 1), Tok::Ident(_)) {
            i += 2;
        }
        if self.peek_at(i) != &Tok::LBrace {
            return false;
        }
        // A struct literal's `{` is on the name's line; a `{` on the next line starts something
        // else (e.g. a `{}` map pattern starting the next match arm).
        if self.toks[self.pos + i].span.line > self.toks[self.pos + i - 1].span.end_line {
            return false;
        }
        let skip = |mut j: usize| {
            while self.peek_at(j) == &Tok::Newline {
                j += 1;
            }
            j
        };
        let j = skip(i + 1);
        match self.peek_at(j) {
            Tok::RBrace | Tok::DotDot => true,
            Tok::Ident(_) => matches!(self.peek_at(skip(j + 1)), Tok::Colon | Tok::Comma | Tok::RBrace),
            _ => false,
        }
    }

    /// At `{` in expression position: a map literal (`{}` or a first entry with a top-level
    /// `:`) rather than a block.
    fn map_lit_ahead(&self) -> bool {
        let mut i = 1;
        while self.peek_at(i) == &Tok::Newline {
            i += 1;
        }
        match self.peek_at(i) {
            Tok::RBrace => return true,
            Tok::Let | Tok::Var => return false,
            _ => {}
        }
        let mut depth = 0;
        for t in &self.toks[self.pos + i..] {
            match t.tok {
                Tok::LParen | Tok::LBracket | Tok::LBrace => depth += 1,
                Tok::RParen | Tok::RBracket | Tok::RBrace if depth == 0 => return false,
                Tok::RParen | Tok::RBracket | Tok::RBrace => depth -= 1,
                Tok::Colon if depth == 0 => return true,
                Tok::Comma | Tok::Newline | Tok::Eof if depth == 0 => return false,
                _ => {}
            }
        }
        false
    }

    /// After `return` / `break`: does a value follow?
    fn operand_ahead(&self) -> bool {
        !matches!(
            self.peek(),
            Tok::Newline | Tok::RBrace | Tok::RParen | Tok::RBracket | Tok::Comma | Tok::Eof | Tok::Else | Tok::FatArrow | Tok::Colon
        )
    }

    /// At `peek`: is it the `peek e` form? `peek(x)` (no space) and `p.peek()` are calls.
    fn peek_operand_ahead(&self) -> bool {
        let next = &self.toks[(self.pos + 1).min(self.toks.len() - 1)];
        match next.tok {
            Tok::Ident(_)
            | Tok::Int(_)
            | Tok::Float(_)
            | Tok::Char(_)
            | Tok::Str(_)
            | Tok::True
            | Tok::False
            | Tok::If
            | Tok::Match
            | Tok::Await
            | Tok::Catch => true,
            Tok::LParen | Tok::LBracket => next.space_before,
            _ => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn module(src: &str) -> Module {
        parse(src).unwrap_or_else(|ds| panic!("{}", ds.iter().map(|d| d.render("t.duck", src)).collect::<String>()))
    }

    fn dump(src: &str) -> String {
        module(src).dump()
    }

    /// The statements of `fn t() { src }`, one dump per line.
    fn e(src: &str) -> String {
        let m = module(&format!("fn t() {{\n{src}\n}}"));
        let Item::Fn(g) = &m.items[0] else { panic!() };
        let Some(FnBody::Block(b)) = &g.clauses[0].body else { panic!() };
        b.stmts.iter().map(expr_dump).collect::<Vec<_>>().join("\n")
    }

    /// The first diagnostic for `src`.
    fn err(src: &str) -> Diag {
        parse(src).expect_err("expected a parse error").remove(0)
    }

    /// The first diagnostic for `src` inside a function body.
    fn err_in(src: &str) -> Diag {
        err(&format!("fn t() {{\n{src}\n}}"))
    }

    #[test]
    fn precedence() {
        assert_eq!(e("await x?"), "(? (await x))");
        assert_eq!(e("await get(u).body"), "(await (. (call get u) body))");
        assert_eq!(e("catch f(x)?"), "(? (catch (call f x)))");
        assert_eq!(e("catch await t"), "(catch (await t))");
        assert_eq!(e("await any ts"), "(await-any ts)");
        assert_eq!(e("await any [a(), b()]"), "(await-any (list (call a) (call b)))");
        assert_eq!(e("await any(ts)"), "(await (call any ts))");
        assert_eq!(e("catch xs[i] else 0"), "(else (catch (index xs i)) 0)");
        assert_eq!(e("-e.1"), "(- (. e 1))");
        assert_eq!(e("-eval(e)?"), "(- (? (call eval e)))");
        assert_eq!(e("!p.at(c)"), "(! (method p at c))");
        assert_eq!(e("-2 ** 2"), "(** (- 2) 2)");
        assert_eq!(e("a + b * c ** d ** e"), "(+ a (* b (** c (** d e))))");
        assert_eq!(e("a - b - c"), "(- (- a b) c)");
        assert_eq!(e("0..n + 1"), "(.. 0 (+ n 1))");
        assert_eq!(e("bs[end + 4..bs.len()]"), "(slice bs (+ end 4) .. (method bs len))");
        assert_eq!(e("a == b && c < d || e"), "(|| (&& (== a b) (< c d)) e)");
        assert_eq!(e("x is some(_) && y"), "(&& (is x (some _)) y)");
        assert_eq!(e("a < b is true"), "(is (< a b) true)");
        assert_eq!(e("a +% b *% c -% d"), "(-% (+% a (*% b c)) d)");
        assert_eq!(e("xs.max()! + 1"), "(+ (unwrap (method xs max)) 1)");
        assert_eq!(e("x??"), "(? (? x))");
        assert_eq!(e("f(??)"), "(call f ??)");
    }

    #[test]
    fn bitwise_precedence() {
        // `+ -` > `<< >>` > `&` > `^` > `|` > `..` > comparisons
        assert_eq!(e("a | b ^ c & d"), "(| a (^ b (& c d)))");
        assert_eq!(e("a & b << 2 + c"), "(& a (<< b (+ 2 c)))");
        assert_eq!(e("a << 1 >> 2"), "(>> (<< a 1) 2)");
        assert_eq!(e("~a & -b"), "(& (~ a) (- b))");
        assert_eq!(e("~x.f()"), "(~ (method x f))");
        assert_eq!(e("0..1 << n"), "(.. 0 (<< 1 n))");
        assert_eq!(e("a ^ b | c"), "(| (^ a b) c)");
        assert_eq!(e("x >> 1 == 0"), "(== (>> x 1) 0)");
        assert_eq!(e("(x & 1) == 0"), "(== (& x 1) 0)");
        assert_eq!(e("a | b && c"), "(&& (| a b) c)");
        // `&x` at the start of an argument is still a `var` argument
        assert_eq!(e("f(&x, a & b)"), "(call f (& x) (& a b))");
        // `>>` is two `>` with nothing between; nested generics still close
        assert_eq!(e("a > b"), "(> a b)");
        assert!(parse("fn f(s: Set<Set<int>>): int = 0").is_ok());
    }

    #[test]
    fn bitwise_compound_assignment() {
        let d = dump("fn f() {\n  x &= 1\n  x |= 2\n  x ^= 3\n  x <<= 4\n  x >>= 5\n}");
        assert!(d.contains("(block (&= x 1) (|= x 2) (^= x 3) (<<= x 4) (>>= x 5))"), "{d}");
    }

    #[test]
    fn error_bitwise_in_comparison() {
        for (src, op, col, end) in [("x & 1 == 0", "&", 1, 6), ("0 != x | 2", "|", 6, 11), ("a ^ b < c", "^", 1, 6)] {
            let d = err_in(src);
            assert_eq!((d.code, d.message.clone()), ("E0038", format!("`{op}` mixed with a comparison needs parentheses")), "{src}");
            let fixes: Vec<_> = d.fixes.iter().map(|f| (f.span.col, f.span.end_col, f.text.as_str())).collect();
            assert_eq!(fixes, [(col, col, "("), (end, end, ")")], "{src}");
        }
        // parenthesized either way is fine, and shifts need none
        assert!(parse("fn f() = (x & 1) == 0").is_ok());
        assert!(parse("fn f() = x & (1 == 0)").is_ok());
        assert!(parse("fn f() = x << 1 == 0").is_ok());
    }

    #[test]
    fn pipe_and_else() {
        assert_eq!(e("a |> f(b)?"), "(? (|> a f b))");
        assert_eq!(e("rows\n  |> filter(p)\n  |> map(g)?"), "(? (|> (|> rows filter p) map g))");
        assert_eq!(e("a |> f()? |> g"), "(|> (? (|> a f)) g)");
        assert_eq!(e("a |> json.encode()"), "(|> a (. json encode))");
        assert_eq!(e("a || b |> f()"), "(|> (|| a b) f)");
        assert_eq!(e("x else y |> f()"), "(else x (|> y f))");
        assert_eq!(e("a else b else c"), "(else a (else b c))");
        assert_eq!(e("load(p) else e => default(e)"), "(else (call load p) e => (call default e))");
        assert_eq!(e("f(x else 0)"), "(call f (else x 0))");
        assert_eq!(e("int.parse(s) else return 0"), "(else (method int parse s) (return 0))");
    }

    #[test]
    fn let_and_assignment() {
        assert_eq!(e("let x = 1"), "(let x 1)");
        assert_eq!(e("var n: int = 0"), "(var n : int 0)");
        // a top-level `else` after the value belongs to the `let`
        assert_eq!(e("let [h, ..t] = xs else { return 0 }"), "(let (list h (.. t)) xs (else (block (return 0))))");
        assert_eq!(e("let n = parse(s) else 0"), "(let n (call parse s) (else 0))");
        assert_eq!(e("let u = parse(s) else e => fail(e)"), "(let u (call parse s) (else e => (call fail e)))");
        assert_eq!(e("let job = k.pop() else break true"), "(let job (method k pop) (else (break true)))");
        assert_eq!(e("a.b[i].c += 1"), "(+= (. (index (. a b) i) c) 1)");
        assert_eq!(e("t.0 = 1"), "(= (. t 0) 1)");
        assert_eq!(e("i += if u { 2 } else { 1 }"), "(+= i (if u (block 2) (block 1)))");
        assert_eq!(e("x -= 1\ny *= 2\nz /= 3\nw %= 4"), "(-= x 1)\n(*= y 2)\n(/= z 3)\n(%= w 4)");
    }

    #[test]
    fn statements() {
        assert_eq!(e("assert (a, b) == (1, 2)"), "(assert (== (tuple a b) (tuple 1 2)))");
        assert_eq!(e("assert f() is err(_)"), "(assert (is (call f) (err _)))");
        assert_eq!(e("peek x * 2"), "(peek (* x 2))");
        assert_eq!(e("peek (a, b)"), "(peek (tuple a b))");
        assert_eq!(e("p.peek()\npeek(p)"), "(method p peek)\n(call peek p)");
        assert_eq!(e("return"), "(return)");
        assert_eq!(e("loop { break }"), "(loop (block (break)))");
        assert_eq!(e("loop { if d { break 42 } }"), "(loop (block (if d (block (break 42)))))");
        assert_eq!(e("for x in xs { continue }"), "(for x xs (block (continue)))");
        assert_eq!(e("fail(\"bad\")"), "(call fail \"bad\")");
        assert_eq!(e("f(&xs, 7)\nxs.push2(7)"), "(call f (& xs) 7)\n(method xs push2 7)");
        assert_eq!(e("f(&a.b[0])"), "(call f (& (index (. a b) 0)))");
        assert_eq!(e("{ ?? }"), "(block ??)");
    }

    #[test]
    fn postfix_forms() {
        assert_eq!(e("t.0.1"), "(. (. t 0) 1)");
        assert_eq!(e("xs[a..b]\ns[0..=2]\nm[k]"), "(slice xs a .. b)\n(slice s 0 ..= 2)\n(index m k)");
        assert_eq!(e("find(us, 1)?.name else \"nobody\""), "(else (?. (call find us 1) name) \"nobody\")");
        assert_eq!(e("g.get(y)?.get(x)"), "(?. (method g get y) get (args x))");
        assert_eq!(e("(x?).f()"), "(method (? x) f)");
        assert_eq!(e("pairs.enum().map(f)"), "(method (method pairs enum) map f)");
        assert_eq!(e("f(a)(b)"), "(call (call f a) b)");
        assert_eq!(e("let x = await (a(), b())"), "(let x (await (tuple (call a) (call b))))");
    }

    #[test]
    fn closures() {
        assert_eq!(e("xs.map(x => x * 2)"), "(method xs map (closure (x) (* x 2)))");
        assert_eq!(e("f((a, b) => a + b)"), "(call f (closure (a b) (+ a b)))");
        assert_eq!(e("f(((i, x), y) => y)"), "(call f (closure ((tuple i x) y) y))");
        assert_eq!(e("let has = (name: str) => name"), "(let has (closure ((name: str)) name))");
        assert_eq!(e("f(_ => 0)"), "(call f (closure (_) 0))");
        assert_eq!(e("f(() => 1)"), "(call f (closure () 1))");
        assert_eq!(e("f(x => {\n  let y = x\n  y\n})"), "(call f (closure (x) (block (let y x) y)))");
        assert_eq!(e("f(x => {})"), "(call f (closure (x) (map)))");
        assert_eq!(e("f(x => total += x)"), "(call f (closure (x) (+= total x)))");
    }

    #[test]
    fn strings() {
        assert_eq!(e(r#""plain""#), r#""plain""#);
        assert_eq!(e(r#""hi {name}!""#), r#"(str "hi " name "!")"#);
        assert_eq!(e(r#""{x:.2} {i + 1:>2}""#), r#"(str (fmt x ".2") " " (fmt (+ i 1) ">2"))"#);
        assert_eq!(e(r#""{if a { "x" } else { "y" }}""#), r#"(str (if a (block "x") (block "y")))"#);
        assert_eq!(e(r#""{m.get(k) else "-"}""#), r#"(str (else (method m get k) "-"))"#);
        assert_eq!(e(r#""{{\"name\": {n}}}""#), r#"(str "{\"name\": " n "}")"#);
        assert_eq!(e(r#""{Point { x: 1 }.x}""#), r#"(str (. (new Point (x 1)) x))"#);
        let d = err_in(r#""{a b}""#);
        assert_eq!((d.code, d.message.as_str()), ("E0008", "expected `}` or `:` after the interpolated expression, found `b`"));
    }

    #[test]
    fn struct_block_map_disambiguation() {
        assert_eq!(e("let p = Point { x: 1.0, y }"), "(let p (new Point (x 1.0) y))");
        assert_eq!(e("let q = Point { x: 3.0, ..p }"), "(let q (new Point (x 3.0) (.. p)))");
        assert_eq!(e("let r = geo.Point { x, y, }"), "(let r (new geo.Point x y))");
        assert_eq!(e("let e = Empty {}"), "(let e (new Empty))");
        assert_eq!(e("Req {\n  a: 1,\n  b: 2\n}"), "(new Req (a 1) (b 2))");
        // no struct literal in a head: the `{` starts the body
        assert_eq!(e("if ok { x }"), "(if ok (block x))");
        assert_eq!(e("while ok { x }"), "(while ok (block x))");
        assert_eq!(e("for k in keys { k }"), "(for k keys (block k))");
        assert_eq!(e("match s { _ => 1 }"), "(match s (_ => 1))");
        assert_eq!(e("if x is Empty { 1 }"), "(if (is x Empty) (block 1))");
        // ...unless it is parenthesized or nested
        assert_eq!(e("if p == (Point { x: 1 }) { 1 }"), "(if (== p (new Point (x 1))) (block 1))");
        assert_eq!(e("if xs.any(x => x == P { a: 1 }) { 1 }"), "(if (method xs any (closure (x) (== x (new P (a 1))))) (block 1))");
        assert_eq!(e("if (a else b) { 1 }"), "(if (else a b) (block 1))");
        // maps vs blocks
        assert_eq!(e("let m = {}"), "(let m (map))");
        assert_eq!(e("let m = {\"a\": 1, \"b\": {}}"), "(let m (map (\"a\" 1) (\"b\" (map))))");
        assert_eq!(e("let m = {k: v}"), "(let m (map (k v)))");
        assert_eq!(e("let b = { f(x) }"), "(let b (block (call f x)))");
        assert_eq!(e("let b = {\n  let x: int = 1\n  x\n}"), "(let b (block (let x : int 1) x))");
        assert_eq!(e("match x { A => {\"k\": 1}, B => { 1 } }"), "(match x (A => (map (\"k\" 1))) (B => (block 1)))");
    }

    #[test]
    fn control_flow() {
        assert_eq!(e("if a { 1 } else if b { 2 } else { 3 }"), "(if a (block 1) (if b (block 2) (block 3)))");
        assert_eq!(e("if a {\n  1\n}\nelse {\n  2\n}"), "(if a (block 1) (block 2))");
        assert_eq!(e("for i, (a, b) in pairs { a }"), "(for i (tuple a b) pairs (block a))");
        assert_eq!(e("for _ in 0..3 {}"), "(for _ (.. 0 3) (block))");
        assert_eq!(e("let v = loop { break 42 }"), "(let v (loop (block (break 42))))");
    }

    #[test]
    fn match_arms() {
        let want = "(match s ((Circle r) => (* r r)) ((Rect w h) when (== w h) => (* w w)) (_ => 0))";
        assert_eq!(e("match s {\n  Circle(r) => r * r\n  Rect(w, h) when w == h => w * w\n  _ => 0\n}"), want);
        assert_eq!(e("match s { Circle(r) => r * r, Rect(w, h) when w == h => w * w, _ => 0, }"), want);
        assert_eq!(e("match s {\n\n  Circle(r) => r * r,\n  Rect(w, h) when w == h => w * w\n\n  _ => 0\n}"), want);
        // a guard ends at `=>`, even after a name or parentheses
        assert_eq!(e("match x { a when b => c }"), "(match x (a when b => c))");
        assert_eq!(e("match x { a when (b) => c }"), "(match x (a when b => c))");
        assert_eq!(e("match x { a when f(y => y) => c }"), "(match x (a when (call f (closure (y) y)) => c))");
        // arm bodies may assign
        assert_eq!(e("match x { _ => m.n = 1 }"), "(match x (_ => (= (. m n) 1)))");
        // a map pattern can start an arm, including on a new line (which the lexer joins on)
        assert_eq!(e("match v { {\"a\": n} => n, _ => 0 }"), "(match v ((map (\"a\" n)) => n) (_ => 0))");
        assert_eq!(
            e("match v {\n  {\"b\": n} => n\n  {\"a\": n} => n\n  {} => 0\n  _ => 1\n}"),
            "(match v ((map (\"b\" n)) => n) ((map (\"a\" n)) => n) ((map) => 0) (_ => 1))"
        );
        assert_eq!(e("match v {\n  _ when x => k\n  {} => 0\n}"), "(match v (_ when x => k) ((map) => 0))");
        let d = err_in("match x { a => 1 b => 2 }");
        assert_eq!((d.code, d.message.as_str()), ("E0020", "expected a line break, `,` or `}` after the match arm, found `b`"));
    }

    #[test]
    fn patterns() {
        let p = |src: &str| e(&format!("match v {{ {src} => 0 }}")).trim_start_matches("(match v (").trim_end_matches(" => 0))").to_string();
        assert_eq!(p("0"), "0");
        assert_eq!(p("-1"), "-1");
        assert_eq!(p("1.5"), "1.5");
        assert_eq!(p("\"s\""), "\"s\"");
        assert_eq!(p("'c'"), "'c'");
        assert_eq!(p("true"), "true");
        assert_eq!(p("_"), "_");
        assert_eq!(p("x"), "x");
        assert_eq!(p("Eof"), "Eof");
        assert_eq!(p("Need.Required"), "Need.Required");
        assert_eq!(p("Circle(r)"), "(Circle r)");
        assert_eq!(p("Shape.Rect(w, _)"), "(Shape.Rect w _)");
        assert_eq!(p("(a, b)"), "(tuple a b)");
        assert_eq!(p("()"), "(tuple)");
        assert_eq!(p("(a)"), "a");
        assert_eq!(p("[]"), "(list)");
        assert_eq!(p("[a, b]"), "(list a b)");
        assert_eq!(p("[h, ..t]"), "(list h (.. t))");
        assert_eq!(p("[.., last]"), "(list .. last)");
        assert_eq!(p("[a, b, ..]"), "(list a b ..)");
        assert_eq!(p("[c, .._]"), "(list c (.. _))");
        assert_eq!(p("[a, ..m, z]"), "(list a (.. m) z)");
        assert_eq!(p("User { name, .. }"), "(struct User name ..)");
        assert_eq!(p("User { name: n, age: 3 }"), "(struct User (name n) (age 3))");
        assert_eq!(p("{\"k\": v, \"n\": 1}"), "(map (\"k\" v) (\"n\" 1))");
        assert_eq!(p("{}"), "(map)");
        assert_eq!(p("\"GET \" + rest"), "(prefix \"GET \" rest)");
        assert_eq!(p("ok(v)"), "(ok v)");
        assert_eq!(p("err(BadToken(at))"), "(err (BadToken at))");
        assert_eq!(p("some([x, ..])"), "(some (list x ..))");
        assert_eq!(p("none"), "none");
        assert_eq!(p("(Flag, some(_), none)"), "(tuple Flag (some _) none)");
        assert_eq!(p("[h, \":\" + p]"), "(list h (prefix \":\" p))");
    }

    #[test]
    fn types() {
        let ty = |src: &str| {
            let m = module(&format!("fn f(x: {src}) = 0"));
            let Item::Fn(g) = &m.items[0] else { panic!() };
            type_dump(g.clauses[0].params[0].ty.as_ref().unwrap())
        };
        for src in [
            "int", "float", "bool", "char", "str", "[int]", "{str: [int]}", "(int, str)", "()", "int?", "Value!", "[Tok]!CalcErr",
            "(Expr, [Tok])!CalcErr", "Set<int>", "Map<str, Set<int>>", "any Shape", "[any Area]", "net.Conn", "(int) => bool",
            "() => ()", "[str?]?", "int!E?",
        ] {
            assert_eq!(ty(src), src);
        }
        assert_eq!(ty("(int)"), "int");
        assert_eq!(ty("(int, str,)"), "(int, str)");
    }

    #[test]
    fn functions_and_contracts() {
        assert_eq!(
            dump("fn isqrt(n: int): int\n  requires n >= 0\n  ensures result * result <= n\n{ ?? }"),
            "(fn isqrt/1\n  (clause (params (n: int)) : int (requires (>= n 0)) (ensures (<= (* result result) n)) (block ??)))\n"
        );
        assert_eq!(
            dump("pub async fn get(url: str): Resp! uses net, time {\n  await request(url)\n}"),
            "(fn get/1\n  (clause pub async (params (url: str)) : Resp! (uses net time) (block (await (call request url)))))\n"
        );
        assert_eq!(dump("fn push2(xs: var [int], v: int) { xs.push(v) }"), "(fn push2/2\n  (clause (params (xs: var [int]) (v: int)) (block (method xs push v))))\n");
        assert_eq!(dump("fn pair<A: Show, B: Show + Eq>(a: A, b: B): str = a"), "(fn pair/2\n  (clause <A: Show, B: Show + Eq> (params (a: A) (b: B)) : str = a))\n");
        assert_eq!(dump("fn g(n: int): str when n >= 90 = \"A\""), "(fn g/1\n  (clause (params (n: int)) : str (when (>= n 90)) = \"A\"))\n");
        // a guard before a block body
        assert_eq!(dump("fn g(n: int): str when ok { x }"), "(fn g/1\n  (clause (params (n: int)) : str (when ok) (block x)))\n");
        // `=` at the end of the line continues
        assert_eq!(dump("fn f(): int =\n  1"), "(fn f/0\n  (clause (params) : int = 1))\n");
        assert_eq!(dump("fn main() {}"), "(fn main/0\n  (clause (params) (block)))\n");
    }

    #[test]
    fn clause_grouping() {
        let src = "\
/// Fibonacci.
pub fn fib(n: int): int
fn fib(0): int = 0
fn fib(1): int = 1
fn fib(n: int): int = fib(n - 1) + fib(n - 2)
fn fib(a: int, b: int): int = a
fn len([], acc: int): int = acc
fn other() {}
fn fib(x: str): int = 0
";
        let m = module(src);
        let groups: Vec<_> = m
            .items
            .iter()
            .map(|i| match i {
                Item::Fn(g) => (g.name.as_str(), g.arity, g.header.is_some(), g.clauses.len()),
                _ => panic!(),
            })
            .collect();
        assert_eq!(groups, [("fib", 1, true, 3), ("fib", 2, false, 1), ("len", 2, false, 1), ("other", 0, false, 1), ("fib", 1, false, 1)]);
        let Item::Fn(g) = &m.items[0] else { panic!() };
        let h = g.header.as_ref().unwrap();
        assert!(h.public && h.body.is_none());
        assert_eq!(h.doc.as_deref(), Some("Fibonacci."));
        // a header line with contracts, then clauses
        let m = module("fn f(n: int): int\n  requires n > 0\nfn f(1): int = 1\nfn f(n: int): int = n");
        let Item::Fn(g) = &m.items[0] else { panic!() };
        assert_eq!((g.header.as_ref().unwrap().requires.len(), g.clauses.len()), (1, 2));
        // a header whose return type ends in `>` (a continuation operator) still ends the line
        let m = module("fn f(n: int): Set<int>\nfn f(n: int): Set<int> = s");
        let Item::Fn(g) = &m.items[0] else { panic!() };
        assert!(g.header.is_some() && g.clauses.len() == 1);
    }

    #[test]
    fn items() {
        assert_eq!(dump("struct Point { x: float, y: float, }"), "(struct Point (x float) (y float))\n");
        assert_eq!(dump("pub struct Box<T> {\n  /// the value\n  v: T\n}"), "(pub struct Box <T> (v T))\n");
        assert_eq!(
            dump("enum Shape { Circle(r: float), Rect(w: float, h: float), Dot, Wrap(int), }"),
            "(enum Shape (Circle (r float)) (Rect (w float) (h float)) Dot (Wrap int))\n"
        );
        assert_eq!(
            dump("shape Area { fn area(self): float }\nshape Ord {\n  fn cmp(self, o: Self): int\n}"),
            "(shape Area (method (params self) : float))\n(shape Ord (method (params self (o: Self)) : int))\n"
        );
        assert_eq!(dump("test \"isqrt\" { assert isqrt(17) == 4 }"), "(test \"isqrt\" (block (assert (== (call isqrt 17) 4))))\n");
        assert_eq!(dump("let MAX = 10\nimprint T: [int] = table()\npub let N = 1"), "(let MAX 10)\n(imprint T : [int] (call table))\n(pub let N 1)\n");
        let m = module("/// Module doc.\n\n/// Point doc.\nstruct P { x: int }");
        assert_eq!(m.doc.as_deref(), Some("Module doc."));
        let Item::Struct(s) = &m.items[0] else { panic!() };
        assert_eq!(s.doc.as_deref(), Some("Point doc."));
        // a block directly above an item is the item's, even at the top of the file
        let m = module("/// Todo doc.\nstruct Todo { x: int }\n");
        assert_eq!(m.doc, None);
        let Item::Struct(s) = &m.items[0] else { panic!() };
        assert_eq!(s.doc.as_deref(), Some("Todo doc."));
        // a top block followed by a blank line is the module doc, and the item has none
        let m = module("/// Module doc.\n/// Two lines.\n\nstruct P { x: int }\n");
        assert_eq!(m.doc.as_deref(), Some("Module doc.\nTwo lines."));
        let Item::Struct(s) = &m.items[0] else { panic!() };
        assert_eq!(s.doc, None);
        // a top block with no item below it is the module doc
        assert_eq!(module("/// Only docs.\n").doc.as_deref(), Some("Only docs."));
        assert_eq!(module("/// Only docs.").doc.as_deref(), Some("Only docs."));
        assert_eq!(module("/// Module doc.\n// a comment\nfn f() {}\n").doc.as_deref(), Some("Module doc."));
        // `test` and `shape` are ordinary names elsewhere
        assert_eq!(e("let test = shape + any"), "(let test (+ shape any))");
    }

    #[test]
    fn trailing_commas() {
        assert_eq!(e("f(a, b,)"), "(call f a b)");
        assert_eq!(e("[1, 2,]"), "(list 1 2)");
        assert_eq!(e("(1, 2,)"), "(tuple 1 2)");
        assert_eq!(e("(1,)"), "1");
        assert_eq!(e("{\"a\": 1,}"), "(map (\"a\" 1))");
        assert_eq!(e("let [a, b,] = xs"), "(let (list a b) xs)");
        assert_eq!(e("[\n  1,\n  2,\n]"), "(list 1 2)");
        assert_eq!(dump("fn f(a: int, b: int,) = a"), "(fn f/2\n  (clause (params (a: int) (b: int)) = a))\n");
    }

    #[test]
    fn spans_and_ids() {
        let m = module("fn f() = a + bc");
        let Item::Fn(g) = &m.items[0] else { panic!() };
        let Some(FnBody::Expr(x)) = &g.clauses[0].body else { panic!() };
        assert_eq!((x.span.line, x.span.col, x.span.end_line, x.span.end_col), (1, 10, 1, 16));
        let ExprKind::Binary { lhs, rhs, .. } = &x.kind else { panic!() };
        assert_eq!((rhs.span.col, rhs.span.end_col), (14, 16));
        assert!(lhs.id != rhs.id && rhs.id != x.id);
        let m = module("fn f() {\n  g(\"a{x}\")\n}");
        let Item::Fn(g) = &m.items[0] else { panic!() };
        let Some(FnBody::Block(b)) = &g.clauses[0].body else { panic!() };
        assert_eq!((b.span.line, b.span.end_line, b.span.end_col), (1, 3, 2));
        let ExprKind::Call { args, .. } = &b.stmts[0].kind else { panic!() };
        let ExprKind::Interp(parts) = &args[0].kind else { panic!() };
        let InterpPart::Expr { expr, .. } = &parts[1] else { panic!() };
        assert_eq!((expr.span.line, expr.span.col), (2, 8));
    }

    // ---- negative tests: specific codes and messages ----

    #[test]
    fn error_top_level_statement() {
        let d = err("print(\"hi\")");
        assert_eq!(d.code, "E0024");
        assert_eq!(d.message, "expected an item (`fn`, `struct`, `enum`, `shape`, `test`, `let` or `imprint`), found `print`");
        assert!(d.notes[0].contains("fn main"));
        assert!(err("import json").notes[0].contains("no imports"));
    }

    #[test]
    fn error_arrow_return_type() {
        let d = err("fn f() -> int = 1");
        assert_eq!((d.code, d.message.as_str()), ("E0035", "return types are written with `:`, not `->`"));
        assert_eq!(d.fixes[0].text, ":");
    }

    #[test]
    fn error_two_statements_on_a_line() {
        let d = err_in("let x = 1 let y = 2");
        assert_eq!((d.code, d.message.as_str()), ("E0025", "expected a line break or `}` after the statement, found `let`"));
        assert_eq!((d.span.line, d.span.col), (2, 11));
    }

    #[test]
    fn error_chained_comparison() {
        let d = err_in("a < b < c");
        assert_eq!((d.code, d.message.as_str()), ("E0026", "comparison operators cannot be chained"));
    }

    #[test]
    fn error_bad_assignment_target() {
        let d = err_in("f() = 1");
        assert_eq!((d.code, d.message.as_str()), ("E0027", "can't assign to this expression"));
        assert_eq!(err_in("a + b += 1").code, "E0027");
    }

    #[test]
    fn error_misplaced_ref() {
        let d = err_in("let y = &x");
        assert_eq!((d.code, d.message.as_str()), ("E0028", "`&` is only allowed directly on a call argument"));
        let d = err_in("f(&g())");
        assert_eq!((d.code, d.message.as_str()), ("E0028", "`&` needs a variable, field or index"));
    }

    #[test]
    fn error_struct_or_else_in_head() {
        let d = err_in("if p == Point { x: 1 } { 1 }");
        assert_eq!((d.code, d.message.as_str()), ("E0029", "a struct literal inside a `if` head needs parentheses"));
        let d = err_in("while a else b { 1 }");
        assert_eq!((d.code, d.message.as_str()), ("E0029", "an `else` inside a `while` head needs parentheses"));
        let d = err_in("if a = b { 1 }");
        assert_eq!((d.code, d.notes[0].as_str()), ("E0020", "use `==` to compare"));
    }

    #[test]
    fn error_mixed_pipe_and_dot() {
        let d = err_in("xs |> map(f).len()");
        assert_eq!((d.code, d.message.as_str()), ("E0030", "expected `|>` or the end of the pipe, found `.`"));
        assert_eq!(err_in("xs |> (x => x)").code, "E0030");
    }

    #[test]
    fn error_header_without_clauses() {
        let d = err("fn f(n: int): int\nfn g() = 1");
        assert_eq!((d.code, d.message.as_str()), ("E0031", "`fn f` has no body and no clauses follow it"));
        let d = err("fn f(0): int = 0\nfn f(n: int): int");
        assert_eq!((d.code, d.message.as_str()), ("E0031", "body-less `fn f` after its clauses"));
    }

    #[test]
    fn error_let_as_expression() {
        let d = err_in("f(let x = 1)");
        assert_eq!((d.code, d.message.as_str()), ("E0032", "`let` is a statement, not an expression"));
    }

    #[test]
    fn error_bad_patterns() {
        let d = err_in("let [a, .., b, ..] = xs");
        assert_eq!((d.code, d.message.as_str()), ("E0033", "a list pattern can have only one `..`"));
        let d = err_in("match m { {k: v} => 1 }");
        assert_eq!((d.code, d.message.as_str()), ("E0034", "expected a literal key in a map pattern, found `k`"));
        let d = err_in("match x { => 1 }");
        assert_eq!((d.code, d.message.as_str()), ("E0022", "expected a pattern, found `=>`"));
        let d = err_in("match x { err(T(1, N + 1)) => 1 }");
        assert_eq!((d.code, d.message.as_str()), ("E0020", "expected `,` or `)` after the pattern, found `+`"));
        assert_eq!(err_in("match s { \"a\" + \"b\" => 1 }").code, "E0022");
    }

    #[test]
    fn error_expected_expression_and_type() {
        let d = err_in("let x = * 2");
        assert_eq!((d.code, d.message.as_str()), ("E0021", "expected an expression, found `*`"));
        let d = err("fn f(x: 1) = x");
        assert_eq!((d.code, d.message.as_str()), ("E0023", "expected a type, found `1`"));
        let d = err_in("f(a b)");
        assert_eq!((d.code, d.message.as_str()), ("E0020", "expected `,` or `)` after the argument, found `b`"));
        let d = err_in("let _ = _");
        assert_eq!(d.code, "E0021");
    }

    #[test]
    fn errors_recover_per_item() {
        let ds = parse("fn a() = *\nfn b() = 1\nfn c() { let }\nstruct S { x int }\n").unwrap_err();
        let codes: Vec<_> = ds.iter().map(|d| (d.code, d.span.line)).collect();
        assert_eq!(codes, [("E0021", 1), ("E0022", 3), ("E0020", 4)]);
    }

    #[test]
    fn lex_errors_come_through() {
        let d = err("fn f() = 1;");
        assert_eq!(d.code, "E0011");
    }
}

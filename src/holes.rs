//! `duck holes <file> [--json]`: a brief for every `??` hole in a program — what an AI agent (or
//! `duck hatch`) needs to fill it.
//!
//! The holes are those of the root file and of the other modules of its project (dependencies and
//! core are not searched), root file first, then the project's modules in load order, each in
//! source order. They are numbered from 1; `duck hatch --hole N` uses the same numbering. The
//! program must type-check (holes are allowed); with type errors the brief is still printed from
//! the partial program (types that couldn't be inferred show as `?`) and the exit code is 1.
//!
//! # JSON schema (`--json`, stable)
//! ```text
//! {
//!   "file": "hatch.duck",            // the root file, as given
//!   "ok": true,                      // the program type-checks (holes allowed)
//!   "holes": [{
//!     "index": 1,                    // 1-based, in the order described above
//!     "file": "hatch.duck",          // the file the hole is in
//!     "line": 6, "col": 3, "end_line": 6, "end_col": 5,   // 1-based; end_col exclusive (chars)
//!     "expected": "float",           // the type the hole must have
//!     "context": "fn median",        // "fn <name>", "test \"<name>\"", "let <name>" or "imprint <name>"
//!     "body": true,                  // the hole is the only statement of a block (`{ ?? }`)
//!     "function": {                  // the enclosing function, or null (a hole in a test or constant)
//!       "name": "median",
//!       "signature": "fn median(xs: [float]): float",   // source text, without contracts or body
//!       "doc": "Median of a non-empty list.",           // the `///` doc, or null
//!       "requires": ["xs.len() > 0"],                   // source text of each clause
//!       "ensures": []
//!     },
//!     "scope": [{"name": "xs", "type": "[float]", "mutable": false}],  // visible locals, outermost first
//!     "tests": [{"name": "median", "file": "hatch.duck", "line": 21, "source": "test \"median\" {...}"}],
//!     "module_fns": [{"name": "dedup", "signature": "fn dedup(xs: [int]): [int]"}],  // the module's other functions
//!     "module_types": [{"name": "DurErr", "source": "enum DurErr { ... }"}]      // its structs, enums and shapes
//!   }]
//! }
//! ```
//! `tests` are the `test` blocks of the project that call the enclosing function (directly, by
//! any call form, or by naming it as a value).

use std::collections::BTreeSet;
use std::path::Path;

use super::ast::{self, Block, Expr, ExprKind as K, FnBody, FnClause, Item, NodeId, Pat, PatKind};
use super::diag::{FileDiag, Span};
use super::json::{Json, obj};
use super::resolve::ModId;
use super::typed::{Callee, LocalId, NameRef, Tables, TypedProgram};

/// Everything known about one hole.
#[derive(Debug, Clone)]
pub struct Hole {
    pub index: usize,
    pub file: String,
    pub span: Span,
    pub expected: String,
    pub context: String,
    /// The span of the block whose only statement is this hole (`{ ?? }`), if it is one.
    pub body: Option<Span>,
    pub function: Option<FnBrief>,
    pub scope: Vec<Var>,
    pub tests: Vec<TestRef>,
    pub module_fns: Vec<(String, String)>,
    pub module_types: Vec<(String, String)>,
}

#[derive(Debug, Clone)]
pub struct FnBrief {
    pub name: String,
    pub signature: String,
    pub doc: Option<String>,
    pub requires: Vec<String>,
    pub ensures: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct Var {
    pub name: String,
    pub ty: String,
    pub mutable: bool,
}

#[derive(Debug, Clone)]
pub struct TestRef {
    pub name: String,
    pub file: String,
    pub line: u32,
    pub source: String,
}

/// Load and type-check the program rooted at `path` (honoring `resolve::with_sources`) and find
/// its holes. Returns the holes and every diagnostic; `Err` when the program couldn't be loaded
/// or its declarations don't check.
pub fn analyze(path: &Path) -> Result<(Vec<Hole>, Vec<FileDiag>), Vec<FileDiag>> {
    let prog = super::resolve::load(path)?;
    match super::check::check_all(prog) {
        (Some(tp), diags) => Ok((discover(&tp), diags)),
        (None, diags) => {
            // errors: retry for the partial program, so the brief is still available
            let prog = super::resolve::load(path)?;
            match super::check::check_partial(prog) {
                (Some(tp), _) => Ok((discover(&tp), diags)),
                (None, _) => Err(diags),
            }
        }
    }
}

/// The modules searched for holes: the root, then the rest of the root package with a file.
pub fn project_modules(tp: &TypedProgram) -> Vec<ModId> {
    let p = &tp.program;
    let pkg = p.mods[p.root].pkg;
    let mut ms = vec![p.root];
    ms.extend((0..p.mods.len()).filter(|&m| m != p.root && p.mods[m].pkg == pkg && !p.mods[m].file.is_empty()));
    ms
}

/// Every hole of the project, numbered from 1.
pub fn discover(tp: &TypedProgram) -> Vec<Hole> {
    let mods = project_modules(tp);
    let mut out = Vec::new();
    for &m in &mods {
        let module = &tp.program.mods[m];
        let tables = &tp.tables[m];
        for (i, item) in module.ast.items.iter().enumerate() {
            // (context, hole ids in this item's bodies) — collected per clause / body
            match item {
                Item::Fn(g) => {
                    for c in g.header.iter().map(|h| &**h).chain(&g.clauses) {
                        for id in holes_in_clause(c) {
                            let mut w = Walk { t: tables, target: id, scope: Vec::new(), body: None };
                            w.clause(c);
                            let header = g.header.as_deref();
                            let doc = c.doc.clone().or_else(|| header.and_then(|h| h.doc.clone()));
                            let mut requires: Vec<String> = Vec::new();
                            let mut ensures: Vec<String> = Vec::new();
                            for cl in header.into_iter().chain(std::iter::once(c)) {
                                requires.extend(cl.requires.iter().map(|e| text(&module.src, e.span).to_string()));
                                ensures.extend(cl.ensures.iter().map(|e| text(&module.src, e.span).to_string()));
                            }
                            requires.dedup();
                            ensures.dedup();
                            let function = FnBrief { name: g.name.clone(), signature: signature(&module.src, c), doc, requires, ensures };
                            let fids: BTreeSet<usize> = tp
                                .fns
                                .iter()
                                .enumerate()
                                .filter(|(_, f)| f.module == m && matches!(&f.kind, super::typed::FnKind::Duck { item, .. } if *item == i))
                                .map(|(fid, _)| fid)
                                .collect();
                            out.push(make(tp, m, id, w, format!("fn {}", g.name), Some(function), callers(tp, &mods, &fids), Some(i)));
                        }
                    }
                }
                Item::Test(t) => {
                    for id in holes_in_block(&t.body) {
                        let mut w = Walk { t: tables, target: id, scope: Vec::new(), body: None };
                        w.block(&t.body);
                        out.push(make(tp, m, id, w, format!("test {:?}", t.name), None, Vec::new(), None));
                    }
                }
                Item::Let(c) | Item::Imprint(c) => {
                    let mut ids = Vec::new();
                    super::check::visit_expr(&c.value, &mut |e| {
                        if matches!(e.kind, K::Hole) {
                            ids.push(e.id);
                        }
                    });
                    let kw = if matches!(item, Item::Let(_)) { "let" } else { "imprint" };
                    for id in ids {
                        let mut w = Walk { t: tables, target: id, scope: Vec::new(), body: None };
                        w.expr(&c.value);
                        out.push(make(tp, m, id, w, format!("{kw} {}", c.name.name), None, Vec::new(), None));
                    }
                }
                _ => {}
            }
        }
    }
    // source order within each file (items are already in order; clauses of a header first)
    for (i, h) in out.iter_mut().enumerate() {
        h.index = i + 1;
    }
    out
}

#[allow(clippy::too_many_arguments)]
fn make(
    tp: &TypedProgram,
    m: ModId,
    id: NodeId,
    w: Walk,
    context: String,
    function: Option<FnBrief>,
    tests: Vec<TestRef>,
    own_item: Option<usize>,
) -> Hole {
    let module = &tp.program.mods[m];
    let tables = &tp.tables[m];
    let span = find_span(&module.ast, id).unwrap_or_default();
    let expected = tables.types.get(&id).map(|t| show(tp, t)).unwrap_or_else(|| "?".into());
    // innermost binding of each name wins; keep the outermost-first order
    let mut scope: Vec<Var> = Vec::new();
    for &l in &w.scope {
        let Some(li) = tables.locals.get(l) else { continue };
        scope.retain(|v| v.name != li.name);
        scope.push(Var { name: li.name.clone(), ty: show(tp, &li.ty), mutable: li.mutable });
    }
    let mut module_fns = Vec::new();
    let mut module_types = Vec::new();
    for (i, item) in module.ast.items.iter().enumerate() {
        match item {
            Item::Fn(g) if Some(i) != own_item => {
                if let Some(c) = g.header.as_deref().or(g.clauses.first()) {
                    module_fns.push((g.name.clone(), signature(&module.src, c)));
                }
            }
            Item::Struct(s) => module_types.push((s.name.name.clone(), text(&module.src, s.span).to_string())),
            Item::Enum(e) => module_types.push((e.name.name.clone(), text(&module.src, e.span).to_string())),
            Item::Shape(s) => module_types.push((s.name.name.clone(), text(&module.src, s.span).to_string())),
            _ => {}
        }
    }
    Hole { index: 0, file: module.file.clone(), span, expected, context, body: w.body, function, scope, tests, module_fns, module_types }
}

fn show(tp: &TypedProgram, t: &super::types::Ty) -> String {
    if t.has_error() || t.has_vars() { "?".into() } else { tp.defs.show(t) }
}

/// The hole ids of a clause, in source order.
fn holes_in_clause(c: &FnClause) -> Vec<NodeId> {
    let mut ids = Vec::new();
    let mut f = |e: &Expr| {
        if matches!(e.kind, K::Hole) {
            ids.push(e.id);
        }
    };
    for e in c.requires.iter().chain(&c.ensures).chain(&c.guard) {
        super::check::visit_expr(e, &mut f);
    }
    match &c.body {
        Some(FnBody::Expr(e)) => super::check::visit_expr(e, &mut f),
        Some(FnBody::Block(b)) => b.stmts.iter().for_each(|s| super::check::visit_expr(s, &mut f)),
        _ => {}
    }
    ids
}

fn holes_in_block(b: &Block) -> Vec<NodeId> {
    let mut ids = Vec::new();
    for s in &b.stmts {
        super::check::visit_expr(s, &mut |e| {
            if matches!(e.kind, K::Hole) {
                ids.push(e.id);
            }
        });
    }
    ids
}

fn find_span(m: &ast::Module, id: NodeId) -> Option<Span> {
    let mut found = None;
    for item in &m.items {
        super::check::visit_item_exprs(item, &mut |e| {
            if e.id == id {
                found = Some(e.span);
            }
        });
    }
    found
}

/// The test blocks of the project that call one of `fids`.
fn callers(tp: &TypedProgram, mods: &[ModId], fids: &BTreeSet<usize>) -> Vec<TestRef> {
    let mut out = Vec::new();
    for &m in mods {
        let module = &tp.program.mods[m];
        let tables = &tp.tables[m];
        for item in &module.ast.items {
            let Item::Test(t) = item else { continue };
            let mut hit = false;
            super::check::visit_item_exprs(item, &mut |e| {
                let called = match tables.calls.get(&e.id).map(|c| &c.callee) {
                    Some(Callee::Fn { func, .. }) => fids.contains(func),
                    _ => false,
                };
                let named = matches!(tables.names.get(&e.id), Some(NameRef::Fn { func, .. }) if fids.contains(func));
                hit |= called || named;
            });
            if hit {
                out.push(TestRef { name: t.name.clone(), file: module.file.clone(), line: t.span.line, source: text(&module.src, t.span).to_string() });
            }
        }
    }
    out
}

/// The byte offset of a 1-based (line, char column) position.
pub fn offset(src: &str, line: u32, col: u32) -> usize {
    let mut start = 0;
    for _ in 1..line {
        match src[start..].find('\n') {
            Some(i) => start += i + 1,
            None => return src.len(),
        }
    }
    let rest = &src[start..];
    start + rest.char_indices().nth(col.saturating_sub(1) as usize).map_or(rest.len(), |(i, _)| i)
}

/// The source text of a span.
pub fn text(src: &str, s: Span) -> &str {
    let (a, b) = (offset(src, s.line, s.col), offset(src, s.end_line, s.end_col));
    if a <= b { &src[a..b] } else { "" }
}

/// A clause's signature as written: from `fn` (or `pub`/`async`) up to its contracts or body.
fn signature(src: &str, c: &FnClause) -> String {
    let start = offset(src, c.span.line, c.span.col);
    let mut end = offset(src, c.span.end_line, c.span.end_col);
    let body_start = match &c.body {
        Some(FnBody::Expr(e)) => Some(e.span),
        Some(FnBody::Block(b)) => Some(b.span),
        _ => None,
    };
    for s in c.requires.iter().chain(&c.ensures).map(|e| e.span).chain(body_start) {
        end = end.min(offset(src, s.line, s.col));
    }
    let mut sig = src[start..end.max(start)].trim_end();
    for kw in ["requires", "ensures", "="] {
        if let Some(s) = sig.strip_suffix(kw) {
            sig = s.trim_end();
        }
    }
    // a contract keyword ahead of the first contract we cut at
    loop {
        let t = sig.trim_end();
        let cut = ["requires", "ensures"].iter().find_map(|kw| t.strip_suffix(kw));
        match cut {
            Some(s) => sig = s.trim_end(),
            None => break,
        }
    }
    sig.to_string()
}

/// Finds the locals in scope at the target hole by walking the body the way the checker scopes
/// it (`tables.binds` gives each binding's local).
struct Walk<'a> {
    t: &'a Tables,
    target: NodeId,
    scope: Vec<LocalId>,
    body: Option<Span>,
}

impl Walk<'_> {
    fn clause(&mut self, c: &FnClause) -> bool {
        for p in &c.params {
            if let Some(&l) = self.t.binds.get(&p.id) {
                self.scope.push(l);
            } else {
                self.pat(&p.pat);
            }
        }
        for e in c.requires.iter().chain(&c.guard).chain(&c.ensures) {
            if self.expr(e) {
                return true;
            }
        }
        match &c.body {
            Some(FnBody::Expr(e)) => self.expr(e),
            Some(FnBody::Block(b)) => self.block(b),
            _ => false,
        }
    }

    fn pat(&mut self, p: &Pat) {
        if let Some(&l) = self.t.binds.get(&p.id) {
            self.scope.push(l);
        }
        match &p.kind {
            PatKind::Tuple(ps) => ps.iter().for_each(|p| self.pat(p)),
            PatKind::List { head, rest, tail } => {
                head.iter().for_each(|p| self.pat(p));
                if let Some(r) = rest.as_ref().and_then(|r| r.pat.as_ref()) {
                    self.pat(r);
                }
                tail.iter().for_each(|p| self.pat(p));
            }
            PatKind::Variant { args: Some(ps), .. } => ps.iter().for_each(|p| self.pat(p)),
            PatKind::Struct { fields, .. } => {
                if let Some(sp) = self.t.struct_pats.get(&p.id) {
                    self.scope.extend(sp.fields.iter().filter_map(|(_, l)| *l));
                }
                for f in fields {
                    if let Some(p) = &f.pat {
                        self.pat(p);
                    }
                }
            }
            PatKind::Map(kvs) => kvs.iter().for_each(|(_, p)| self.pat(p)),
            PatKind::StrPrefix { rest, .. } => self.pat(rest),
            PatKind::Some(p) | PatKind::Ok(p) | PatKind::Err(p) => self.pat(p),
            _ => {}
        }
    }

    /// Walk a block in a new scope; true (with the scope left as it is) when the target is found.
    fn block(&mut self, b: &Block) -> bool {
        let n = self.scope.len();
        if let [only] = b.stmts.as_slice()
            && only.id == self.target
        {
            self.body = Some(b.span);
            return true;
        }
        for s in &b.stmts {
            if let K::Let { pat, value, els, .. } = &s.kind {
                if self.expr(value) || self.else_arm(s.id, els.as_ref()) {
                    return true;
                }
                self.pat(pat);
            } else if self.expr(s) {
                return true;
            }
        }
        self.scope.truncate(n);
        false
    }

    fn else_arm(&mut self, node: NodeId, arm: Option<&ast::ElseArm>) -> bool {
        let Some(arm) = arm else { return false };
        let n = self.scope.len();
        if let Some(b) = self.t.elses.get(&node).and_then(|e| e.binder) {
            self.scope.push(b);
        }
        if self.expr(&arm.body) {
            return true;
        }
        self.scope.truncate(n);
        false
    }

    fn expr(&mut self, e: &Expr) -> bool {
        if e.id == self.target {
            return true;
        }
        let n = self.scope.len();
        let found = match &e.kind {
            K::Block(b) | K::Loop(b) => self.block(b),
            K::While { cond, body } => self.expr(cond) || self.block(body),
            K::If { cond, then, els } => self.expr(cond) || self.block(then) || els.as_ref().is_some_and(|x| self.expr(x)),
            K::For { index, pat, iter, body } => {
                self.expr(iter) || {
                    if let Some(i) = index {
                        self.pat(i);
                    }
                    self.pat(pat);
                    self.block(body)
                }
            }
            K::Match { scrut, arms } => {
                self.expr(scrut)
                    || arms.iter().any(|a| {
                        let n = self.scope.len();
                        self.pat(&a.pat);
                        let f = a.guard.as_ref().is_some_and(|g| self.expr(g)) || self.expr(&a.body);
                        if !f {
                            self.scope.truncate(n);
                        }
                        f
                    })
            }
            K::Closure { params, body } => {
                for p in params {
                    if let Some(&l) = self.t.binds.get(&p.id) {
                        self.scope.push(l);
                    } else {
                        self.pat(&p.pat);
                    }
                }
                self.expr(body)
            }
            K::Else { expr, arm } => self.expr(expr) || self.else_arm(e.id, Some(arm)),
            K::Let { value, els, .. } => self.expr(value) || self.else_arm(e.id, els.as_ref()),
            _ => kids(e).into_iter().any(|k| self.expr(k)),
        };
        if !found {
            self.scope.truncate(n);
        }
        found
    }
}

/// The direct sub-expressions of the forms that don't bind names.
fn kids(e: &Expr) -> Vec<&Expr> {
    let mut v: Vec<&Expr> = Vec::new();
    match &e.kind {
        K::Interp(ps) => {
            for p in ps {
                if let ast::InterpPart::Expr { expr, .. } = p {
                    v.push(expr);
                }
            }
        }
        K::Field { expr, .. } | K::TupleField { expr, .. } | K::Unary { expr, .. } | K::Is { expr, .. } => v.push(expr),
        K::Try(x) | K::Unwrap(x) | K::Await(x) | K::Ref(x) | K::Assert(x) | K::Peek(x) | K::Measured { expr: x, .. } => v.push(x),
        K::Call { callee, args } => {
            v.push(callee);
            v.extend(args);
        }
        K::MethodCall { recv, args, .. } => {
            v.push(recv);
            v.extend(args);
        }
        K::Pipe { lhs, callee, args } => {
            v.push(lhs);
            v.push(callee);
            v.extend(args);
        }
        K::Index { expr, index } => v.extend([&**expr, &**index]),
        K::Slice { expr, lo, hi, .. } => v.extend([&**expr, &**lo, &**hi]),
        K::Binary { lhs, rhs, .. } => v.extend([&**lhs, &**rhs]),
        K::Range { lo, hi, .. } => v.extend([&**lo, &**hi]),
        K::OptChain { expr, args, .. } => {
            v.push(expr);
            v.extend(args.iter().flatten());
        }
        K::Assign { target, value, .. } => v.extend([&**target, &**value]),
        K::Return(x) | K::Break(x) => v.extend(x.as_deref()),
        K::Struct { fields, base, .. } => {
            v.extend(fields.iter().filter_map(|f| f.value.as_ref()));
            v.extend(base.as_deref());
        }
        K::List(xs) | K::Tuple(xs) => v.extend(xs),
        K::Map(kvs) => {
            for (k, x) in kvs {
                v.push(k);
                v.push(x);
            }
        }
        _ => {}
    }
    v
}

// ---- output ----

/// The human-readable brief of one hole (also the brief in `duck hatch`'s prompt).
pub fn brief_text(h: &Hole) -> String {
    let mut s = format!("hole {} at {}:{}:{} in {}\n", h.index, h.file, h.span.line, h.span.col, h.context);
    s += &format!("  expected type: {}\n", h.expected);
    if h.body.is_some() {
        s += "  the hole is a whole block body: `{ ?? }` (replace it with the block's statements)\n";
    }
    if let Some(f) = &h.function {
        s += "  function:\n";
        if let Some(d) = &f.doc {
            for l in d.lines() {
                s += &format!("    /// {l}\n");
            }
        }
        for l in f.signature.lines() {
            s += &format!("    {l}\n");
        }
        for r in &f.requires {
            s += &format!("      requires {r}\n");
        }
        for r in &f.ensures {
            s += &format!("      ensures {r}\n");
        }
    }
    if h.scope.is_empty() {
        s += "  in scope: (nothing)\n";
    } else {
        s += "  in scope:\n";
        for v in &h.scope {
            s += &format!("    {}{}: {}\n", if v.mutable { "var " } else { "" }, v.name, v.ty);
        }
    }
    if h.function.is_some() {
        if h.tests.is_empty() {
            s += "  tests that call it: (none)\n";
        } else {
            s += "  tests that call it:\n";
            for t in &h.tests {
                for l in t.source.lines() {
                    s += &format!("    {l}\n");
                }
            }
        }
    }
    if !h.module_fns.is_empty() {
        s += "  other functions in this module:\n";
        for (_, sig) in &h.module_fns {
            s += &format!("    {}\n", sig.lines().next().unwrap_or(""));
        }
    }
    if !h.module_types.is_empty() {
        s += "  types in this module:\n";
        for (_, src) in &h.module_types {
            for l in src.lines() {
                s += &format!("    {l}\n");
            }
        }
    }
    s
}

pub fn hole_json(h: &Hole) -> Json {
    let strs = |xs: &[String]| Json::Arr(xs.iter().map(|x| Json::from(x.as_str())).collect());
    let function = match &h.function {
        None => Json::Null,
        Some(f) => obj([
            ("name", f.name.as_str().into()),
            ("signature", f.signature.as_str().into()),
            ("doc", f.doc.as_deref().map_or(Json::Null, Json::from)),
            ("requires", strs(&f.requires)),
            ("ensures", strs(&f.ensures)),
        ]),
    };
    obj([
        ("index", (h.index as i64).into()),
        ("file", h.file.as_str().into()),
        ("line", h.span.line.into()),
        ("col", h.span.col.into()),
        ("end_line", h.span.end_line.into()),
        ("end_col", h.span.end_col.into()),
        ("expected", h.expected.as_str().into()),
        ("context", h.context.as_str().into()),
        ("body", h.body.is_some().into()),
        ("function", function),
        (
            "scope",
            Json::Arr(h.scope.iter().map(|v| obj([("name", v.name.as_str().into()), ("type", v.ty.as_str().into()), ("mutable", v.mutable.into())])).collect()),
        ),
        (
            "tests",
            Json::Arr(
                h.tests
                    .iter()
                    .map(|t| obj([("name", t.name.as_str().into()), ("file", t.file.as_str().into()), ("line", t.line.into()), ("source", t.source.as_str().into())]))
                    .collect(),
            ),
        ),
        ("module_fns", Json::Arr(h.module_fns.iter().map(|(n, s)| obj([("name", n.as_str().into()), ("signature", s.as_str().into())])).collect())),
        ("module_types", Json::Arr(h.module_types.iter().map(|(n, s)| obj([("name", n.as_str().into()), ("source", s.as_str().into())])).collect())),
    ])
}

/// Render diagnostics to stderr.
pub fn print_diags(diags: &[FileDiag]) {
    for d in diags {
        let src = super::resolve::source_of(&d.file).unwrap_or_default();
        eprint!("{}", d.diag.render(&d.file, &src));
    }
}

/// `duck holes <file> [--json]`. Returns the exit code.
pub fn run(args: &[String]) -> i32 {
    let (path, json) = match args {
        [p] => (p, false),
        [p, f] if f == "--json" => (p, true),
        [f, p] if f == "--json" => (p, true),
        _ => {
            eprintln!("usage: duck holes <file> [--json]");
            return 2;
        }
    };
    let (holes, diags) = match analyze(Path::new(path)) {
        Ok(r) => r,
        Err(ds) => {
            print_diags(&ds);
            return 1;
        }
    };
    let ok = diags.iter().all(|d| d.diag.is_warning());
    if !ok {
        print_diags(&diags);
    }
    if json {
        let j = obj([("file", path.as_str().into()), ("ok", ok.into()), ("holes", Json::Arr(holes.iter().map(hole_json).collect()))]);
        println!("{j}");
    } else if holes.is_empty() {
        println!("no holes in {path}");
    } else {
        let blocks: Vec<String> = holes.iter().map(brief_text).collect();
        print!("{}", blocks.join("\n"));
    }
    i32::from(!ok)
}

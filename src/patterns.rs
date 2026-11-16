//! Exhaustiveness and reachability of patterns: the usefulness algorithm of Maranget,
//! "Warnings for pattern matching" (JFP 2007), over the typed patterns of the checked program.
//!
//! Checked here, after typing (check.rs runs this on the `TypedProgram`):
//! - every **clause group** (one `FnInfo`): its clauses' parameter lists are the rows of a
//!   matrix, one column per parameter;
//! - every **`match`**: one column, one row per arm;
//! - **`let pat = e else ..`** with a refutable pattern: the `else` must be needed (E0402);
//! - patterns that must always match (`let` without `else`, `for`, closure parameters): E0403.
//!
//! A row with a `when` guard never counts toward exhaustiveness (nor toward the reachability of
//! later rows), but it can itself be unreachable.
//!
//! # The pattern space
//! Every pattern becomes a `P`: a wildcard, a constructor applied to sub-patterns, or a list
//! pattern with a rest (`[a, .., z]`). A type's constructors are:
//! - finite sums (`Ctor::Idx`): `bool` (`false`, `true`), `T?` (`none`, `some`), `T!` (`ok`,
//!   `err`) and enums (variants in declaration order, `Value` included);
//! - one constructor (`Ctor::Single`): tuples and structs (a struct pattern's missing fields are
//!   wildcards);
//! - lists, by length: `[]`, `[_]`, ... up to a bound `L` that depends on the patterns, plus the
//!   class "`L` or more" (`Ctor::LenMin`), which is all that is needed to decide usefulness;
//! - infinite domains (`int`, `float`, `str`, `char`, maps, opaque types such as `Err`, type
//!   parameters, closures): each literal, string prefix, open map pattern (by its key set) and
//!   typed error payload (`err(BadUrl(w))` on a plain `T!`) is a constructor that covers some of
//!   the values; only a wildcard covers them all.
//!
//! Treating overlapping constructors of an infinite domain (`"GET " + r` and `"GET /"`, or two
//! open maps with different key sets) as disjoint can only miss an unreachable row, never report
//! a reachable one.

use std::collections::HashSet;

use super::ast::{Arm, Block, Expr, ExprKind, FnBody, FnClause, Item, Lit, Pat, PatKind};
use super::diag::{Diag, FileDiag, Span};
use super::resolve::ModId;
use super::typed::{ElseKind, FnInfo, FnKind, Tables, TypedProgram};
use super::types::{DefId, Ty, TypeDefKind};

/// How many missing cases a diagnostic lists.
const SHOW: usize = 3;

/// Check every clause group, `match`, `let` and binding pattern of the program.
pub fn check(tp: &TypedProgram) -> Vec<FileDiag> {
    let mut cx = Cx::new(tp);
    for info in &tp.fns {
        if tp.program.is_core(info.module) {
            continue;
        }
        let FnKind::Duck { item, clauses, header } = &info.kind else { continue };
        let Item::Fn(g) = &tp.program.mods[info.module].ast.items[*item] else { continue };
        cx.m = info.module;
        let cls: Vec<&FnClause> = clauses.iter().map(|&i| &g.clauses[i]).collect();
        cx.clause_group(info, &cls);
        let hdr = if *header { g.header.as_deref() } else { None };
        for c in hdr.into_iter().chain(cls.iter().copied()) {
            for e in c.guard.iter().chain(&c.requires).chain(&c.ensures) {
                cx.expr(e);
            }
            match &c.body {
                Some(FnBody::Expr(e)) => cx.expr(e),
                Some(FnBody::Block(b)) => cx.block(b),
                _ => {}
            }
        }
    }
    for t in &tp.tests {
        if tp.program.is_core(t.module) {
            continue;
        }
        cx.m = t.module;
        if let Item::Test(d) = &tp.program.mods[t.module].ast.items[t.item] {
            cx.block(&d.body);
        }
    }
    for c in &tp.consts {
        if tp.program.is_core(c.module) {
            continue;
        }
        cx.m = c.module;
        if let Item::Let(d) | Item::Imprint(d) = &tp.program.mods[c.module].ast.items[c.item] {
            cx.expr(&d.value);
        }
    }
    cx.out
}

/// Visit `e` and every expression inside it (pre-order), including closure bodies, guards and
/// `else` arms.
pub(crate) fn walk_expr<'a>(e: &'a Expr, f: &mut dyn FnMut(&'a Expr)) {
    f(e);
    for c in children(e) {
        walk_expr(c, f);
    }
}

/// The direct sub-expressions of `e`, in source order.
pub(crate) fn children<'e>(e: &'e Expr) -> Vec<&'e Expr> {
    let mut out: Vec<&Expr> = Vec::new();
    let mut go = |x: &'e Expr| out.push(x);
    match &e.kind {
        ExprKind::Lit(_) | ExprKind::Name(_) | ExprKind::Hole | ExprKind::Continue => {}
        ExprKind::Interp(parts) => {
            for p in parts {
                if let super::ast::InterpPart::Expr { expr, .. } = p {
                    go(expr);
                }
            }
        }
        ExprKind::Measured { expr, .. }
        | ExprKind::Field { expr, .. }
        | ExprKind::TupleField { expr, .. }
        | ExprKind::Try(expr)
        | ExprKind::Unwrap(expr)
        | ExprKind::Await(expr)
        | ExprKind::Catch(expr)
        | ExprKind::AwaitAny(expr)
        | ExprKind::Ref(expr)
        | ExprKind::Unary { expr, .. }
        | ExprKind::Peek(expr)
        | ExprKind::Assert(expr)
        | ExprKind::Is { expr, .. } => go(expr),
        ExprKind::Call { callee, args } => {
            go(callee);
            args.iter().for_each(&mut go);
        }
        ExprKind::MethodCall { recv, args, .. } => {
            go(recv);
            args.iter().for_each(&mut go);
        }
        ExprKind::Pipe { lhs, callee, args } => {
            go(lhs);
            go(callee);
            args.iter().for_each(&mut go);
        }
        ExprKind::Index { expr, index } => {
            go(expr);
            go(index);
        }
        ExprKind::Slice { expr, lo, hi, .. } => {
            go(expr);
            go(lo);
            go(hi);
        }
        ExprKind::Binary { lhs, rhs, .. } => {
            go(lhs);
            go(rhs);
        }
        ExprKind::Range { lo, hi, .. } => {
            go(lo);
            go(hi);
        }
        ExprKind::OptChain { expr, args, .. } => {
            go(expr);
            args.iter().flatten().for_each(&mut go);
        }
        ExprKind::Else { expr, arm } => {
            go(expr);
            go(&arm.body);
        }
        ExprKind::Closure { body, .. } => go(body),
        ExprKind::If { cond, then, els } => {
            go(cond);
            then.stmts.iter().for_each(&mut go);
            if let Some(x) = els {
                go(x);
            }
        }
        ExprKind::Match { scrut, arms } => {
            go(scrut);
            for a in arms {
                if let Some(g) = &a.guard {
                    go(g);
                }
                go(&a.body);
            }
        }
        ExprKind::Loop(b) | ExprKind::Block(b) => b.stmts.iter().for_each(&mut go),
        ExprKind::While { cond, body } => {
            go(cond);
            body.stmts.iter().for_each(&mut go);
        }
        ExprKind::For { iter, body, .. } => {
            go(iter);
            body.stmts.iter().for_each(&mut go);
        }
        ExprKind::Let { value, els, .. } => {
            go(value);
            if let Some(a) = els {
                go(&a.body);
            }
        }
        ExprKind::Assign { target, value, .. } => {
            go(target);
            go(value);
        }
        ExprKind::Return(x) | ExprKind::Break(x) => {
            if let Some(x) = x {
                go(x);
            }
        }
        ExprKind::Struct { fields, base, .. } => {
            fields.iter().filter_map(|f| f.value.as_ref()).for_each(&mut go);
            if let Some(b) = base {
                go(b);
            }
        }
        ExprKind::List(xs) | ExprKind::Tuple(xs) => xs.iter().for_each(&mut go),
        ExprKind::Map(kvs) => {
            for (k, v) in kvs {
                go(k);
                go(v);
            }
        }
    }
    out
}

/// Shows a constructor's arguments, given the binding names in use and a name hint per field.
type ShowArgs<'s> = dyn FnMut(&mut Option<HashSet<String>>, &[Option<String>]) -> Vec<String> + 's;

/// A constructor (see the module docs).
#[derive(Debug, Clone)]
enum Ctor {
    /// The i-th constructor of a finite sum: `false`/`true`, `none`/`some`, `ok`/`err`, variants.
    Idx(usize),
    /// The only constructor of a tuple or struct.
    Single,
    /// A literal of an infinite domain, by a canonical key.
    Lit(String),
    /// A list of exactly this length.
    Len(usize),
    /// A list of at least this length (the last length class).
    LenMin(usize),
    /// An open map pattern with these (sorted) keys.
    Keys(Vec<String>),
    /// `"prefix" + rest`.
    Prefix(String),
    /// A typed error payload variant inside a plain `Err`, with its field types.
    Payload(DefId, usize, Vec<Ty>),
}

impl PartialEq for Ctor {
    fn eq(&self, o: &Ctor) -> bool {
        match (self, o) {
            (Ctor::Idx(a), Ctor::Idx(b)) | (Ctor::Len(a), Ctor::Len(b)) | (Ctor::LenMin(a), Ctor::LenMin(b)) => a == b,
            (Ctor::Single, Ctor::Single) => true,
            (Ctor::Lit(a), Ctor::Lit(b)) | (Ctor::Prefix(a), Ctor::Prefix(b)) => a == b,
            (Ctor::Keys(a), Ctor::Keys(b)) => a == b,
            (Ctor::Payload(d, i, _), Ctor::Payload(e, j, _)) => d == e && i == j,
            _ => false,
        }
    }
}

/// A pattern of the matrix (or a witness: a pattern describing values that nothing matches).
#[derive(Debug, Clone)]
enum P {
    Wild,
    C(Ctor, Vec<P>),
    /// A list pattern with a rest: the patterns before and after the `..`.
    Slice(Vec<P>, Vec<P>),
}

/// What the values of a type look like to the algorithm.
enum Kind {
    Finite(usize),
    Single,
    List,
    Infinite,
}

/// One row: its patterns, whether it has a guard, and where it is (for diagnostics).
struct Row {
    pats: Vec<P>,
    guarded: bool,
}

struct Cx<'a> {
    tp: &'a TypedProgram,
    m: ModId,
    value_def: Option<DefId>,
    out: Vec<FileDiag>,
}

impl<'a> Cx<'a> {
    fn new(tp: &'a TypedProgram) -> Cx<'a> {
        let value_def = tp.defs.types.iter().position(|d| d.name == "Value" && tp.program.is_core(d.module));
        Cx { tp, m: 0, value_def, out: Vec::new() }
    }

    fn t(&self) -> &'a Tables {
        &self.tp.tables[self.m]
    }

    fn err(&mut self, d: Diag) {
        let file = self.tp.program.mods[self.m].file.clone();
        self.out.push(FileDiag { file, diag: d });
    }

    fn src(&self) -> &'a str {
        &self.tp.program.mods[self.m].src
    }

    /// The source text of a span (to the end of its first line for a multi-line span).
    fn text(&self, s: Span) -> String {
        let Some(line) = self.src().lines().nth(s.line as usize - 1) else { return String::new() };
        let chars: Vec<char> = line.chars().collect();
        let a = (s.col as usize - 1).min(chars.len());
        let b = if s.end_line == s.line { (s.end_col as usize - 1).min(chars.len()) } else { chars.len() };
        chars[a..b.max(a)].iter().collect()
    }

    /// The leading whitespace of a line.
    fn indent(&self, line: u32) -> String {
        let l = self.src().lines().nth(line as usize - 1).unwrap_or("");
        l.chars().take_while(|c| c.is_whitespace()).collect()
    }

    fn ty_of(&self, id: u32) -> Ty {
        self.t().types.get(&id).cloned().unwrap_or(Ty::Error)
    }

    // ---- walking bodies ----

    fn block(&mut self, b: &Block) {
        for s in &b.stmts {
            self.expr(s);
        }
    }

    fn expr(&mut self, e: &Expr) {
        let mut found: Vec<&Expr> = Vec::new();
        walk_expr(e, &mut |x| {
            if matches!(x.kind, ExprKind::Match { .. } | ExprKind::Let { .. } | ExprKind::For { .. } | ExprKind::Closure { .. }) {
                found.push(x);
            }
        });
        for x in found {
            match &x.kind {
                ExprKind::Match { arms, .. } => self.match_expr(x, arms),
                ExprKind::Let { pat, value, els, .. } => match els {
                    None => self.must_match(pat, "this `let` pattern"),
                    Some(arm) => {
                        if self.t().elses.get(&x.id).is_some_and(|i| i.kind == ElseKind::Refutable) && self.exhaustive_single(pat) {
                            let ts = self.tp.defs.show(&self.ty_of(pat.id));
                            let fix = Span { line: value.span.end_line, col: value.span.end_col, ..arm.body.span };
                            self.err(
                                Diag::new("E0402", x.span, format!("the `else` of this `let` is never taken: the pattern matches every `{ts}`"))
                                    .note("remove the `else` part")
                                    .fix(fix, ""),
                            );
                        }
                    }
                },
                ExprKind::For { index, pat, .. } => {
                    if let Some(i) = index {
                        self.must_match(i, "the index pattern of this `for`");
                    }
                    self.must_match(pat, "the pattern of this `for`");
                }
                ExprKind::Closure { params, .. } => {
                    for p in params {
                        self.must_match(&p.pat, "a closure parameter");
                    }
                }
                _ => {}
            }
        }
    }

    fn exhaustive_single(&self, p: &Pat) -> bool {
        let ty = self.ty_of(p.id);
        let rows = vec![vec![self.lower(p)]];
        self.wit(&rows, &[P::Wild], &[ty], 1).is_empty()
    }

    /// A pattern that must match every value of its type (E0403).
    fn must_match(&mut self, p: &Pat, what: &str) {
        if matches!(p.kind, PatKind::Wild) || (matches!(p.kind, PatKind::Bind(_)) && !self.t().variants.contains_key(&p.id)) {
            return;
        }
        let ty = self.ty_of(p.id);
        let rows = vec![vec![self.lower(p)]];
        let ws = self.wit(&rows, &[P::Wild], std::slice::from_ref(&ty), SHOW + 1);
        if ws.is_empty() {
            return;
        }
        let list = self.case_list(ws.iter().map(|w| self.show(&w[0], &ty, &mut None, None)).collect());
        self.err(
            Diag::new("E0403", p.span, format!("{what} might not match: {list}"))
                .note("a pattern here must match every value; use `let ... else { ... }` or a `match` for a pattern that might not match"),
        );
    }

    // ---- match ----

    fn match_expr(&mut self, e: &Expr, arms: &[Arm]) {
        let Some(first) = arms.first() else { return };
        let ty = self.ty_of(first.pat.id);
        if ty.has_error() {
            return;
        }
        let rows: Vec<Row> = arms.iter().map(|a| Row { pats: vec![self.lower(&a.pat)], guarded: a.guard.is_some() }).collect();
        let tys = [ty.clone()];
        // reachability
        for (i, a) in arms.iter().enumerate() {
            if let Some(j) = self.unreachable(&rows, i, &tys) {
                let what = match j {
                    Some(j) => format!(
                        "the arm `{}` at line {} already matches every value this one matches",
                        self.text(arms[j].pat.span),
                        arms[j].pat.span.line
                    ),
                    None => "the arms before it together match every value this one matches".to_string(),
                };
                let prev = arms[i - 1].span;
                self.err(
                    Diag::new("E0401", a.pat.span, "this arm is unreachable")
                        .note(what)
                        .fix(Span { line: prev.end_line, col: prev.end_col, end_line: a.span.end_line, end_col: a.span.end_col }, ""),
                );
            }
        }
        // exhaustiveness
        let full: Vec<Vec<P>> = rows.iter().filter(|r| !r.guarded).map(|r| r.pats.clone()).collect();
        let ws = self.wit(&full, &[P::Wild], &tys, SHOW + 1);
        if ws.is_empty() {
            return;
        }
        let shown: Vec<String> = ws.iter().map(|w| self.show(&w[0], &ty, &mut None, None)).collect();
        let list = self.case_list(shown);
        let kw = Span { end_line: e.span.line, end_col: e.span.col + 5, ..e.span };
        let mut d = Diag::new("E0400", kw, format!("this `match` doesn't cover every case: {list}"));
        if rows.iter().any(|r| r.guarded) {
            d = d.note("arms with a `when` guard don't count toward covering every case");
        }
        let last = arms[arms.len() - 1].span;
        let one_line = if arms.len() >= 2 { arms[arms.len() - 2].span.line == last.line } else { e.span.line == last.line };
        let sep = if one_line { ", ".to_string() } else { format!("\n{}", self.indent(last.line)) };
        let new_arms: Vec<String> = if ws.len() > SHOW {
            vec!["_ => ??".to_string()]
        } else {
            ws.iter().map(|w| format!("{} => ??", self.show(&w[0], &ty, &mut Some(HashSet::new()), None))).collect()
        };
        let text: String = new_arms.iter().map(|a| format!("{sep}{a}")).collect();
        d = d.note(if ws.len() > SHOW { "add the missing arms, or a catch-all `_ => ...`" } else { "add an arm for each missing case" });
        d = d.fix(last.after(), text);
        self.err(d);
    }

    // ---- clause groups ----

    fn clause_group(&mut self, info: &FnInfo, cls: &[&FnClause]) {
        if cls.is_empty() || info.params.iter().any(|p| p.ty.has_error()) {
            return;
        }
        let tys: Vec<Ty> = info.params.iter().map(|p| p.ty.clone()).collect();
        let rows: Vec<Row> = cls.iter().map(|c| Row { pats: c.params.iter().map(|p| self.lower(&p.pat)).collect(), guarded: c.guard.is_some() }).collect();
        for (i, c) in cls.iter().enumerate() {
            if let Some(j) = self.unreachable(&rows, i, &tys) {
                let what = match j {
                    Some(j) => format!("the clause `{}` at line {} already matches every call this one matches", self.clause_sig(&info.name, cls[j]), cls[j].span.line),
                    None => "the clauses before it together match every call this one matches".to_string(),
                };
                let span = match (c.params.first(), c.params.last()) {
                    (Some(a), Some(b)) => a.span.to(b.span),
                    _ => c.name.span,
                };
                let prev = cls[i - 1].span;
                self.err(
                    Diag::new("E0401", span, format!("this clause of `{}` is unreachable", info.name))
                        .note(what)
                        .fix(Span { line: prev.end_line, col: prev.end_col, end_line: c.span.end_line, end_col: c.span.end_col }, ""),
                );
            }
        }
        let full: Vec<Vec<P>> = rows.iter().filter(|r| !r.guarded).map(|r| r.pats.clone()).collect();
        let wilds = vec![P::Wild; tys.len()];
        let ws = self.wit(&full, &wilds, &tys, SHOW + 1);
        if ws.is_empty() {
            return;
        }
        let shown: Vec<String> = ws
            .iter()
            .map(|w| {
                let ps: Vec<String> = w.iter().zip(&tys).map(|(p, t)| self.show(p, t, &mut None, None)).collect();
                format!("{}({})", info.name, ps.join(", "))
            })
            .collect();
        let list = self.case_list(shown);
        let mut d = Diag::new("E0400", info.span, format!("the clauses of `{}` don't cover every case: {list}", info.name));
        if rows.iter().any(|r| r.guarded) {
            d = d.note("clauses with a `when` guard don't count toward covering every case");
        }
        // a new clause in the style of the last one
        let last = cls[cls.len() - 1];
        let clause = |w: &[P]| -> String {
            let mut names = Some(HashSet::new());
            let ps: Vec<String> = w
                .iter()
                .zip(&tys)
                .enumerate()
                .map(|(i, (p, t))| {
                    let hint = info.params[i].name.clone().or_else(|| match &last.params[i].pat.kind {
                        PatKind::Bind(n) if !self.t().variants.contains_key(&last.params[i].pat.id) => Some(n.clone()),
                        _ => None,
                    });
                    let pat = self.show(p, t, &mut names, hint.as_deref());
                    match &last.params[i].ty {
                        Some(ann) => format!("{pat}: {}{}", if last.params[i].var { "var " } else { "" }, self.text(ann.span)),
                        None => pat,
                    }
                })
                .collect();
            let ret = last.ret.as_ref().map(|r| format!(": {}", self.text(r.span))).unwrap_or_default();
            let asy = if last.is_async { "async " } else { "" };
            format!("{asy}fn {}({}){ret} = ??", info.name, ps.join(", "))
        };
        let new: Vec<String> = if ws.len() > SHOW { vec![clause(&wilds)] } else { ws.iter().map(|w| clause(w)).collect() };
        let ind = self.indent(last.span.line);
        let text: String = new.iter().map(|c| format!("\n{ind}{c}")).collect();
        d = d.note(if ws.len() > SHOW { "add the missing clauses, or a catch-all clause" } else { "add a clause for each missing case" });
        d = d.fix(last.span.after(), text);
        self.err(d);
    }

    fn clause_sig(&self, name: &str, c: &FnClause) -> String {
        let ps: Vec<String> = c.params.iter().map(|p| self.text(p.span)).collect();
        format!("fn {name}({})", ps.join(", "))
    }

    /// `None` if row `i` is reachable; otherwise `Some(j)` with an earlier unguarded row that
    /// covers it alone (or `Some(None)` when only several together do).
    fn unreachable(&self, rows: &[Row], i: usize, tys: &[Ty]) -> Option<Option<usize>> {
        let before: Vec<Vec<P>> = rows[..i].iter().filter(|r| !r.guarded).map(|r| r.pats.clone()).collect();
        if !self.wit(&before, &rows[i].pats, tys, 1).is_empty() {
            return None;
        }
        let single = (0..i).find(|&j| !rows[j].guarded && self.wit(std::slice::from_ref(&rows[j].pats), &rows[i].pats, tys, 1).is_empty());
        Some(single)
    }

    /// "`A` is not handled" / "`A`, `B` and `C` are not handled" (with "and more").
    fn case_list(&self, cases: Vec<String>) -> String {
        let more = cases.len() > SHOW;
        let cs: Vec<String> = cases.iter().take(SHOW).map(|c| format!("`{c}`")).collect();
        match (cs.len(), more) {
            (1, _) => format!("{} is not handled", cs[0]),
            (n, false) => format!("{} and {} are not handled", cs[..n - 1].join(", "), cs[n - 1]),
            (_, true) => format!("{} and more are not handled", cs.join(", ")),
        }
    }

    // ---- AST patterns -> P ----

    fn lower(&self, p: &Pat) -> P {
        let t = self.t();
        match &p.kind {
            PatKind::Wild => P::Wild,
            PatKind::Bind(_) => match t.variants.get(&p.id) {
                Some(v) => P::C(Ctor::Idx(v.index), Vec::new()),
                None => P::Wild,
            },
            PatKind::Lit { lit: Lit::Bool(b), .. } => P::C(Ctor::Idx(usize::from(*b)), Vec::new()),
            PatKind::Lit { lit, neg } => P::C(Ctor::Lit(lit_key(lit, *neg)), Vec::new()),
            PatKind::Tuple(ps) => P::C(Ctor::Single, ps.iter().map(|q| self.lower(q)).collect()),
            PatKind::List { head, rest, tail } => {
                let h: Vec<P> = head.iter().map(|q| self.lower(q)).collect();
                match rest {
                    None => P::C(Ctor::Len(h.len()), h),
                    Some(_) => P::Slice(h, tail.iter().map(|q| self.lower(q)).collect()),
                }
            }
            PatKind::Variant { args, .. } => match t.variants.get(&p.id) {
                Some(v) => P::C(Ctor::Idx(v.index), args.iter().flatten().map(|q| self.lower(q)).collect()),
                None => P::Wild,
            },
            PatKind::Struct { fields, .. } => {
                let Some(sp) = t.struct_pats.get(&p.id) else { return P::Wild };
                let n = self.tp.defs.fields(sp.def).len();
                let mut args = vec![P::Wild; n];
                let defs = self.tp.defs.fields(sp.def);
                for f in fields {
                    if let (Some(i), Some(q)) = (defs.iter().position(|d| d.name == f.name.name), &f.pat) {
                        args[i] = self.lower(q);
                    }
                }
                P::C(Ctor::Single, args)
            }
            PatKind::Map(es) => {
                let mut kv: Vec<(String, P)> = es.iter().map(|(k, q)| (lit_key(k, false), self.lower(q))).collect();
                kv.sort_by(|a, b| a.0.cmp(&b.0));
                let (keys, pats): (Vec<String>, Vec<P>) = kv.into_iter().unzip();
                let map = P::C(Ctor::Keys(keys), pats);
                match (t.value_map_pats.contains(&p.id), self.value_map_index()) {
                    (true, Some(i)) => P::C(Ctor::Idx(i), vec![map]),
                    (true, None) => P::C(Ctor::Lit(format!("map{}", p.id)), Vec::new()),
                    _ => map,
                }
            }
            PatKind::StrPrefix { prefix, rest } => P::C(Ctor::Prefix(prefix.clone()), vec![self.lower(rest)]),
            PatKind::Some(q) => P::C(Ctor::Idx(1), vec![self.lower(q)]),
            PatKind::None => P::C(Ctor::Idx(0), Vec::new()),
            PatKind::Ok(q) => P::C(Ctor::Idx(0), vec![self.lower(q)]),
            PatKind::Err(q) => {
                if t.err_payload_pats.contains_key(&p.id) {
                    let inner = match t.variants.get(&q.id) {
                        Some(v) => {
                            let s = self.tp.defs.subst_of(v.def, &v.args);
                            let tys: Vec<Ty> = self.tp.defs.variants(v.def)[v.index].fields.iter().map(|(_, ft)| ft.subst(&s)).collect();
                            let args: Vec<P> = match &q.kind {
                                PatKind::Variant { args: Some(a), .. } => a.iter().map(|x| self.lower(x)).collect(),
                                _ => Vec::new(),
                            };
                            P::C(Ctor::Payload(v.def, v.index, tys), args)
                        }
                        None => P::C(Ctor::Lit(format!("payload{}", q.id)), Vec::new()),
                    };
                    return P::C(Ctor::Idx(1), vec![inner]);
                }
                P::C(Ctor::Idx(1), vec![self.lower(q)])
            }
        }
    }

    fn value_map_index(&self) -> Option<usize> {
        let d = self.value_def?;
        self.tp.defs.variants(d).iter().position(|v| v.name == "Map")
    }

    // ---- types ----

    fn kind(&self, ty: &Ty) -> Kind {
        match ty {
            Ty::Bool | Ty::Opt(_) | Ty::Res(..) => Kind::Finite(2),
            Ty::Tuple(_) => Kind::Single,
            Ty::List(_) => Kind::List,
            Ty::Named(d, _) => match &self.tp.defs.types[*d].kind {
                TypeDefKind::Enum { variants } => Kind::Finite(variants.len()),
                TypeDefKind::Struct { .. } => Kind::Single,
                TypeDefKind::Opaque { .. } => Kind::Infinite,
            },
            _ => Kind::Infinite,
        }
    }

    /// The types of a constructor's fields.
    fn sub_tys(&self, ty: &Ty, c: &Ctor) -> Vec<Ty> {
        match (c, ty) {
            (Ctor::Payload(_, _, tys), _) => tys.clone(),
            (Ctor::Idx(1), Ty::Opt(t)) => vec![(**t).clone()],
            (Ctor::Idx(0), Ty::Res(o, _)) => vec![(**o).clone()],
            (Ctor::Idx(1), Ty::Res(_, e)) => vec![(**e).clone()],
            (Ctor::Idx(i), Ty::Named(d, args)) if self.tp.defs.is_enum(*d) => {
                let s = self.tp.defs.subst_of(*d, args);
                self.tp.defs.variants(*d).get(*i).map(|v| v.fields.iter().map(|(_, t)| t.subst(&s)).collect()).unwrap_or_default()
            }
            (Ctor::Single, Ty::Tuple(ts)) => ts.clone(),
            (Ctor::Single, Ty::Named(d, args)) => {
                let s = self.tp.defs.subst_of(*d, args);
                self.tp.defs.fields(*d).iter().map(|f| f.ty.subst(&s)).collect()
            }
            (Ctor::Len(k) | Ctor::LenMin(k), Ty::List(t)) => vec![(**t).clone(); *k],
            (Ctor::Keys(ks), Ty::Map(_, v)) => vec![(**v).clone(); ks.len()],
            (Ctor::Keys(ks), _) => vec![Ty::Error; ks.len()],
            (Ctor::Prefix(_), _) => vec![Ty::Str],
            _ => Vec::new(),
        }
    }

    // ---- the algorithm ----

    /// The witnesses that `q` is useful with respect to `rows`: vectors of patterns describing
    /// values that `q` matches and no row matches (at most `limit`; empty = `q` is useless). With
    /// `q` all wildcards, the witnesses are the missing cases, and together they cover them.
    fn wit(&self, rows: &[Vec<P>], q: &[P], tys: &[Ty], limit: usize) -> Vec<Vec<P>> {
        if q.is_empty() {
            return if rows.is_empty() { vec![Vec::new()] } else { Vec::new() };
        }
        let ty = &tys[0];
        match &q[0] {
            P::C(c, args) => {
                let sub = self.sub_tys(ty, c);
                self.through(rows, c, sub, args.clone(), q, tys, limit)
            }
            P::Slice(a, b) => {
                let mut out = Vec::new();
                for c in list_classes(rows, &q[0]) {
                    let k = match c {
                        Ctor::Len(k) | Ctor::LenMin(k) => k,
                        _ => unreachable!(),
                    };
                    if a.len() + b.len() > k {
                        continue;
                    }
                    let args = expand(a, b, k);
                    let sub = self.sub_tys(ty, &c);
                    out.extend(self.through(rows, &c, sub, args, q, tys, limit - out.len()));
                    if out.len() >= limit {
                        break;
                    }
                }
                out
            }
            P::Wild => {
                let any_head = rows.iter().any(|r| !matches!(r[0], P::Wild));
                let ctors: Option<Vec<Ctor>> = match self.kind(ty) {
                    Kind::Single => Some(vec![Ctor::Single]),
                    Kind::Finite(n) if any_head => Some((0..n).map(Ctor::Idx).collect()),
                    Kind::List if any_head => Some(list_classes(rows, &P::Wild)),
                    _ => None,
                };
                let mut out = Vec::new();
                match ctors {
                    Some(cs) => {
                        for c in cs {
                            let sub = self.sub_tys(ty, &c);
                            let args = vec![P::Wild; sub.len()];
                            out.extend(self.through(rows, &c, sub, args, q, tys, limit - out.len()));
                            if out.len() >= limit {
                                break;
                            }
                        }
                    }
                    None => {
                        let d: Vec<Vec<P>> = rows.iter().filter(|r| matches!(r[0], P::Wild)).map(|r| r[1..].to_vec()).collect();
                        for w in self.wit(&d, &q[1..], &tys[1..], limit) {
                            let mut v = vec![P::Wild];
                            v.extend(w);
                            out.push(v);
                        }
                    }
                }
                out
            }
        }
    }

    /// Specialize by `c` and recurse with `args` in place of `q`'s head; rebuild the witnesses.
    #[allow(clippy::too_many_arguments)]
    fn through(&self, rows: &[Vec<P>], c: &Ctor, sub: Vec<Ty>, args: Vec<P>, q: &[P], tys: &[Ty], limit: usize) -> Vec<Vec<P>> {
        let n = sub.len();
        let srows: Vec<Vec<P>> = rows.iter().filter_map(|r| specialize(r, c, n)).collect();
        let mut q2 = args;
        q2.resize(n, P::Wild);
        q2.extend(q[1..].iter().cloned());
        let mut t2 = sub;
        t2.extend(tys[1..].iter().cloned());
        self.wit(&srows, &q2, &t2, limit)
            .into_iter()
            .map(|w| {
                let (a, rest) = w.split_at(n);
                let mut v = vec![P::C(c.clone(), a.to_vec())];
                v.extend(rest.iter().cloned());
                v
            })
            .collect()
    }

    // ---- showing witnesses ----

    /// A witness as Duck pattern text. With `names`, wildcards inside variants become their
    /// field names (for a fix-it that inserts a clause or arm), each used once.
    fn show(&self, w: &P, ty: &Ty, names: &mut Option<HashSet<String>>, hint: Option<&str>) -> String {
        let wild = |names: &mut Option<HashSet<String>>, hint: Option<&str>| -> String {
            if let (Some(used), Some(h)) = (names.as_mut(), hint)
                && is_plain_name(h)
                && used.insert(h.to_string())
            {
                return h.to_string();
            }
            "_".to_string()
        };
        let P::C(c, args) = w else { return wild(names, hint) };
        let all_wild = args.iter().all(|a| matches!(a, P::Wild));
        let sub = self.sub_tys(ty, c);
        let mut show_args = |names: &mut Option<HashSet<String>>, hints: &[Option<String>]| -> Vec<String> {
            args.iter().zip(&sub).enumerate().map(|(i, (a, t))| self.show(a, t, names, hints.get(i).and_then(|h| h.as_deref()))).collect()
        };
        match (c, ty) {
            (Ctor::Idx(i), Ty::Bool) => (if *i == 1 { "true" } else { "false" }).to_string(),
            (Ctor::Idx(0), Ty::Opt(_)) => "none".to_string(),
            (Ctor::Idx(_), Ty::Opt(_)) => format!("some({})", show_args(names, &[Some("v".into())])[0]),
            (Ctor::Idx(0), Ty::Res(..)) => format!("ok({})", show_args(names, &[Some("v".into())])[0]),
            (Ctor::Idx(_), Ty::Res(..)) => format!("err({})", show_args(names, &[Some("e".into())])[0]),
            (Ctor::Idx(i), Ty::Named(d, _)) => self.variant_text(*d, *i, &mut show_args, names),
            (Ctor::Payload(d, i, _), _) => self.variant_text(*d, *i, &mut show_args, names),
            (Ctor::Single, _) if all_wild && !args.is_empty() => wild(names, hint),
            (Ctor::Single, Ty::Tuple(_)) => format!("({})", show_args(names, &[]).join(", ")),
            (Ctor::Single, Ty::Named(d, _)) => {
                let fields: Vec<String> = self.tp.defs.fields(*d).iter().map(|f| f.name.clone()).collect();
                let hints: Vec<Option<String>> = fields.iter().map(|f| Some(f.clone())).collect();
                let shown = show_args(names, &hints);
                let parts: Vec<String> =
                    args.iter().zip(&fields).zip(shown).filter(|((a, _), _)| !matches!(a, P::Wild)).map(|((_, f), s)| format!("{f}: {s}")).collect();
                let name = self.type_name(*d);
                if parts.is_empty() { format!("{name} {{ .. }}") } else { format!("{name} {{ {}, .. }}", parts.join(", ")) }
            }
            (Ctor::Len(_), _) => format!("[{}]", show_args(names, &[]).join(", ")),
            (Ctor::LenMin(0), _) => wild(names, hint),
            (Ctor::LenMin(_), _) => format!("[{}, ..]", show_args(names, &[]).join(", ")),
            _ => wild(names, hint),
        }
    }

    fn variant_text(
        &self,
        d: DefId,
        i: usize,
        show_args: &mut ShowArgs,
        names: &mut Option<HashSet<String>>,
    ) -> String {
        let Some(v) = self.tp.defs.variants(d).get(i) else { return "_".into() };
        if v.fields.is_empty() {
            return v.name.clone();
        }
        let variant_names: Vec<&String> = self.tp.defs.variants(d).iter().map(|v| &v.name).collect();
        let hints: Vec<Option<String>> = v.fields.iter().map(|(n, _)| n.clone().filter(|n| !variant_names.contains(&n))).collect();
        format!("{}({})", v.name, show_args(names, &hints).join(", "))
    }

    /// A struct's name as written from the current module.
    fn type_name(&self, d: DefId) -> String {
        let def = &self.tp.defs.types[d];
        if def.module == self.m || self.tp.program.is_core(def.module) {
            return def.name.clone();
        }
        let prog = &self.tp.program;
        let (a, b) = (&prog.mods[def.module], &prog.mods[self.m]);
        let path = if a.pkg == b.pkg { &a.path[1..] } else { &a.path[..] };
        if path.is_empty() { def.name.clone() } else { format!("{}.{}", path.join("."), def.name) }
    }
}

/// Specialize one row by constructor `c` of arity `n` (none if the row can't match it).
fn specialize(r: &[P], c: &Ctor, n: usize) -> Option<Vec<P>> {
    let mut out = match &r[0] {
        P::Wild => vec![P::Wild; n],
        P::C(c2, args) => {
            if c2 != c {
                return None;
            }
            let mut a = args.clone();
            a.resize(n, P::Wild);
            a
        }
        P::Slice(a, b) => match c {
            Ctor::Len(k) | Ctor::LenMin(k) if a.len() + b.len() <= *k => expand(a, b, *k),
            _ => return None,
        },
    };
    out.extend(r[1..].iter().cloned());
    Some(out)
}

/// `[a.., .., b..]` at length `k`: the prefix, wildcards, the suffix.
fn expand(a: &[P], b: &[P], k: usize) -> Vec<P> {
    let mut v = a.to_vec();
    v.extend(std::iter::repeat_n(P::Wild, k - a.len() - b.len()));
    v.extend(b.iter().cloned());
    v
}

/// The length classes of a list column: `[]`, `[_]`, ... and "at least L", where L is past
/// every fixed-length pattern and covers every rest pattern's fixed part.
fn list_classes(rows: &[Vec<P>], q: &P) -> Vec<Ctor> {
    let (mut fixed, mut slice) = (None::<usize>, 0usize);
    for p in rows.iter().map(|r| &r[0]).chain(std::iter::once(q)) {
        match p {
            P::C(Ctor::Len(k), _) => fixed = Some(fixed.map_or(*k, |f| f.max(*k))),
            P::Slice(a, b) => slice = slice.max(a.len() + b.len()),
            _ => {}
        }
    }
    let l = match fixed {
        Some(f) => (f + 1).max(slice),
        None => slice,
    };
    let mut cs: Vec<Ctor> = (0..l).map(Ctor::Len).collect();
    cs.push(Ctor::LenMin(l));
    cs
}

fn lit_key(l: &Lit, neg: bool) -> String {
    match l {
        Lit::Int(n) => format!("i{}", if neg { -(*n as i128) } else { *n as i128 }),
        Lit::Float(f) => format!("f{}", if neg { -f } else { *f }.to_bits()),
        Lit::Bool(b) => format!("b{b}"),
        Lit::Char(c) => format!("c{c}"),
        Lit::Str(s) => format!("s{s}"),
    }
}

/// A name usable as a binding in a generated pattern.
fn is_plain_name(s: &str) -> bool {
    let mut cs = s.chars();
    cs.next().is_some_and(|c| c.is_ascii_lowercase() || c == '_')
        && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
        && !matches!(s, "ok" | "err" | "some" | "none" | "true" | "false" | "self" | "result" | "_")
}

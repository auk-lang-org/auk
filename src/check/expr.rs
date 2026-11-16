//! Expressions: bidirectional inference, calls and overloading, `?`, `else`, `await`, closures.

use std::collections::HashMap;

use super::*;
use crate::ast::{BinOp, Block, ElseArm, Expr, ExprKind as K, Ident, InterpPart, Lit, Pat, UnOp};

/// What the context wants from an expression.
#[derive(Debug, Clone)]
pub(crate) enum Exp {
    /// Nothing known.
    None,
    /// A type that guides inference (`[]` gets its element type) but isn't enforced here.
    Hint(Ty),
    /// The expression must have (or convert to) this type; branches are checked one by one.
    Check(Ty),
    /// Like `Check`, for a function's result: a mismatch suggests changing the return type.
    Tail(Ty),
    /// The value is discarded (a statement).
    Discard,
    /// Possible types for the result of a call, tried in order (the operand of `?` / `else`).
    Hints(Vec<Ty>),
}

impl Exp {
    fn ty(&self) -> Option<&Ty> {
        match self {
            Exp::Hint(t) | Exp::Check(t) | Exp::Tail(t) => Some(t),
            _ => None,
        }
    }

    fn want(&self) -> Option<(&Ty, bool)> {
        match self {
            Exp::Check(t) => Some((t, false)),
            Exp::Tail(t) => Some((t, true)),
            _ => None,
        }
    }
}

/// A call argument: an expression, or a receiver already inferred (dot calls, pipes).
#[derive(Clone, Copy)]
pub(crate) enum ArgSrc<'a> {
    Expr(&'a Expr),
    Recv(&'a Expr),
}

impl ArgSrc<'_> {
    fn expr(&self) -> &Expr {
        match self {
            ArgSrc::Expr(e) | ArgSrc::Recv(e) => e,
        }
    }
}

/// `a.b.c` as a list of names, if the expression is only names and fields.
pub(crate) fn as_path(e: &Expr) -> Option<Vec<Ident>> {
    match &e.kind {
        K::Name(n) => Some(vec![Ident { name: n.clone(), span: e.span }]),
        K::Field { expr, name } => {
            let mut p = as_path(expr)?;
            p.push(name.clone());
            Some(p)
        }
        _ => None,
    }
}

fn is_prim(t: &Ty) -> bool {
    matches!(t.base(), Ty::Int | Ty::Float | Ty::Bool | Ty::Char | Ty::Str)
}

/// A `0` or `0.0` literal.
fn is_zero_lit(e: &Expr) -> bool {
    matches!(e.kind, K::Lit(Lit::Int(0))) || matches!(e.kind, K::Lit(Lit::Float(x)) if x == 0.0)
}

/// The integer value of a literal exponent (`2`, `2.0`, `-1`), for `**` on a unit value.
fn int_exponent(e: &Expr) -> Option<i32> {
    match &e.kind {
        K::Lit(Lit::Int(n)) => i32::try_from(*n).ok(),
        K::Lit(Lit::Float(x)) if x.fract() == 0.0 && x.abs() < 1e6 => Some(*x as i32),
        K::Unary { op: UnOp::Neg, expr } => int_exponent(expr).map(|n| -n),
        _ => None,
    }
}

/// How a core function treats the unit of its first argument (`sum([float<m>])` is a
/// `float<m>`): see `Checker::unit_rule`.
#[derive(Clone, Copy, PartialEq)]
enum UnitRule {
    /// `float(x)`, `int(x)`: the explicit way to drop a unit.
    Strip,
    /// `sum abs floor ceil round`: the result has the argument's unit.
    Keep,
    /// `sqrt`: the result has half of each exponent.
    Root,
}

/// `t` with every plain `int`/`float` in it given unit `u` (`[float]` -> `[float<m>]`).
fn put_units(t: &Ty, u: &crate::units::Units) -> Ty {
    t.map_ty(&mut |x| match x {
        Ty::Int | Ty::Float => Ty::measured(x, u.clone()),
        x => x,
    })
}

/// The first unit inside `t` (`[float<m>]` -> `m`), or dimensionless.
fn first_units(t: &Ty) -> crate::units::Units {
    let mut u = None;
    t.walk(&mut |x| {
        if u.is_none()
            && let Ty::Measured(_, v) = x
        {
            u = Some(v.clone());
        }
    });
    u.unwrap_or_default()
}

impl Checker {
    // ---- inference helpers ----

    pub fn fresh(&mut self) -> Ty {
        self.cx().inf.fresh()
    }

    pub fn resolve(&self, t: &Ty) -> Ty {
        self.cxs.last().unwrap().inf.resolve(t)
    }

    pub fn shallow(&self, t: &Ty) -> Ty {
        self.cxs.last().unwrap().inf.shallow(t)
    }

    pub fn unify(&mut self, a: &Ty, b: &Ty) -> bool {
        self.cx().inf.unify(a, b)
    }

    pub fn try_unify(&mut self, a: &Ty, b: &Ty) -> bool {
        self.cx().inf.try_unify(a, b)
    }

    /// Source text of a span in the current module.
    pub fn text(&self, span: Span) -> String {
        let src = &self.prog.mods[self.cur_module()].src;
        let mut out = String::new();
        for (i, line) in src.lines().enumerate() {
            let ln = i as u32 + 1;
            if ln < span.line || ln > span.end_line {
                continue;
            }
            let chars: Vec<char> = line.chars().collect();
            let from = if ln == span.line { (span.col as usize).saturating_sub(1) } else { 0 };
            let to = if ln == span.end_line { (span.end_col as usize).saturating_sub(1).min(chars.len()) } else { chars.len() };
            if from <= to {
                out.extend(&chars[from..to]);
            }
            if ln != span.end_line {
                out.push('\n');
            }
        }
        out
    }

    fn record(&mut self, node: NodeId, t: &Ty) {
        self.cx().t.types.insert(node, t.clone());
    }

    fn add_coercion(&mut self, node: NodeId, c: Coercion) {
        if let Coercion::ToAny(_) = c {
            let body = self.cx().body;
            let m = self.cur_module();
            let bn = self.body_nodes.entry(body).or_default();
            bn.module = m;
            bn.anys.push(node);
        }
        self.cx().t.coercions.entry(node).or_default().push(c);
    }

    pub fn note_call(&mut self, node: NodeId, call: Call) {
        if let Callee::Fn { func, .. } = &call.callee {
            let f = *func;
            self.cx().callees.insert(f);
        }
        self.cx().t.calls.insert(node, call);
        let body = self.cx().body;
        let m = self.cur_module();
        let bn = self.body_nodes.entry(body).or_default();
        bn.module = m;
        bn.calls.push(node);
    }

    fn note_show(&mut self, node: NodeId, ty: &Ty) {
        let callee = Callee::Shape { shape: self.b.show, method: 0, self_ty: ty.clone() };
        self.cx().t.shows.insert(node, callee);
        let body = self.cx().body;
        let m = self.cur_module();
        let bn = self.body_nodes.entry(body).or_default();
        bn.module = m;
        bn.shows.push(node);
    }

    pub fn defer_fit(&mut self, ty: &Ty, shape: ShapeId, span: Span, why: String) {
        self.cx().deferred.push(Deferred::Fits { ty: ty.clone(), shape, span, why });
    }

    /// The innermost function frame's return type (`None`: `return`/`?` not allowed here).
    fn frame_ret(&self) -> Option<Ty> {
        self.cxs.last().and_then(|c| c.frames.last()).and_then(|f| f.ret.clone())
    }

    // ---- entry points ----

    pub fn infer(&mut self, e: &Expr, hint: Option<&Ty>) -> Ty {
        self.expr(e, hint.map_or(Exp::None, |t| Exp::Hint(t.clone())))
    }

    pub fn check(&mut self, e: &Expr, want: &Ty) -> Ty {
        let have = self.expr(e, Exp::Check(want.clone()));
        self.coerce_at(e, &have, want, false);
        want.clone()
    }

    /// Check a function body's value against its return type.
    pub fn check_tail(&mut self, e: &Expr, want: &Ty) {
        let have = self.expr(e, Exp::Tail(want.clone()));
        self.coerce_at(e, &have, want, true);
    }

    fn check_mode(&mut self, e: &Expr, want: &Ty, tail: bool) {
        let have = self.expr(e, if tail { Exp::Tail(want.clone()) } else { Exp::Check(want.clone()) });
        self.coerce_at(e, &have, want, tail);
    }

    /// A statement whose value is discarded (when `discard`) or used.
    pub fn stmt(&mut self, e: &Expr, discard: bool) -> Ty {
        let t = self.expr(e, if discard { Exp::Discard } else { Exp::None });
        if discard {
            self.check_unawaited(e, &t);
        }
        t
    }

    fn check_unawaited(&mut self, e: &Expr, t: &Ty) {
        if let Ty::Res(..) = self.shallow(t)
            && !matches!(e.kind, K::Block(_) | K::If { .. } | K::Match { .. } | K::Loop(_))
        {
            let ts = self.show(t);
            let ret = self.frame_ret().map(|r| self.shallow(&r));
            let mut d = Diag::new("E0334", e.span, format!("the result of `{}` is a `{ts}`, and its error is ignored", self.text(e.span)));
            if matches!(ret, Some(Ty::Res(..))) {
                d = d
                    .note("add `?` to pass the error up, handle it with `else`, or discard it explicitly with `let _ = ...`")
                    .fix(e.span.after(), "?");
            } else {
                d = d.note("handle the error with `else` (or unwrap with `!`), or discard it explicitly with `let _ = ...`");
            }
            self.err(d);
            return;
        }
        if let Ty::Task(_) = self.shallow(t) {
            self.err(
                Diag::new("E0332", e.span, "this `async fn` call is never awaited")
                    .note("an `async fn` call must be awaited, stored or returned; `await` it to wait for the result")
                    .fix(Span { end_line: e.span.line, end_col: e.span.col, ..e.span }, "await "),
            );
        }
    }

    fn expr(&mut self, e: &Expr, exp: Exp) -> Ty {
        let t = self.expr_inner(e, &exp);
        self.record(e.id, &t);
        t
    }

    // ---- conversions ----

    /// Convert `have` to `want` at `e`: unify, or auto-wrap into `T?`/`T!`, or convert to
    /// `any S`. Reports a mismatch.
    pub fn coerce_at(&mut self, e: &Expr, have: &Ty, want: &Ty, tail: bool) -> bool {
        let mut cs = Vec::new();
        if self.coerce_ty(have, want, &mut cs, e.span) {
            for c in cs {
                self.add_coercion(e.id, c);
            }
            return true;
        }
        self.mismatch(e, have, want, tail);
        false
    }

    fn coerce_ty(&mut self, have: &Ty, want: &Ty, out: &mut Vec<Coercion>, span: Span) -> bool {
        if self.try_unify(have, want) {
            return true;
        }
        let h = self.shallow(have);
        if matches!(h, Ty::Var(_)) {
            return false;
        }
        match self.shallow(want) {
            Ty::Opt(inner) => {
                if self.coerce_ty(have, &inner, out, span) {
                    out.push(Coercion::WrapSome);
                    return true;
                }
            }
            Ty::Res(inner, _) => {
                if self.coerce_ty(have, &inner, out, span) {
                    out.push(Coercion::WrapOk);
                    return true;
                }
            }
            Ty::Any(s) => {
                let h = self.resolve(&h);
                if !matches!(h, Ty::Any(_)) {
                    let name = self.defs.shapes[s].name.clone();
                    self.defer_fit(&h, s, span, format!("to convert it to `any {name}`"));
                    out.push(Coercion::ToAny(s));
                    return true;
                }
            }
            _ => {}
        }
        false
    }

    /// Report "expected X, found Y" with the most useful notes and fixes.
    fn mismatch(&mut self, e: &Expr, have: &Ty, want: &Ty, tail: bool) {
        let (hs, ws) = (self.show(have), self.show(want));
        let h = self.resolve(have);
        let w = self.resolve(want);
        if h.has_error() || w.has_error() {
            return;
        }
        // a missing `?`
        if let Ty::Res(inner, _) | Ty::Opt(inner) = &h
            && self.cx().inf.can_unify(inner, &w)
        {
            let opt = matches!(h, Ty::Opt(_));
            let ret = self.frame_ret().map(|r| self.shallow(&r));
            let can_pass = matches!((&ret, opt), (Some(Ty::Res(..)), false) | (Some(Ty::Opt(_)), true));
            let mut d =
                Diag::new("E0201", e.span, format!("expected `{ws}`, found `{hs}`: the value may be {}", if opt { "missing" } else { "an error" }));
            if can_pass {
                d = d.note(format!("add `?` to pass the {} up to the caller", if opt { "missing value" } else { "error" })).fix(e.span.after(), "?");
            } else {
                d = d.note(format!(
                    "handle it with `else` (`{} else fallback`) or unwrap it with `!`; `?` needs the function to return `{}`",
                    self.text(e.span),
                    if opt { "T?" } else { "T!" }
                ));
            }
            self.err(d);
            return;
        }
        // a missing `await`
        if let Ty::Task(inner) = &h
            && self.cx().inf.can_unify(inner, &w)
        {
            self.err(
                Diag::new("E0333", e.span, format!("expected `{ws}`, found an un-awaited `async fn` call"))
                    .note("`await` the call to get its result")
                    .fix(Span { end_line: e.span.line, end_col: e.span.col, ..e.span }, "await "),
            );
            return;
        }
        let mut d = Diag::new("E0200", e.span, format!("expected `{ws}`, found `{hs}`"));
        let units_only = h != w && h.erase_units() == w.erase_units();
        if units_only {
            d = self.unit_mismatch(e.span, &h, &w);
        }
        match (&h, &w) {
            (Ty::Int, Ty::Float) => {
                if let K::Lit(Lit::Int(n)) = &e.kind {
                    d = d.note("an integer literal is an `int`; write a float literal").fix(e.span, format!("{n}.0"));
                } else {
                    d = d
                        .note("there are no implicit conversions; convert with `float(x)`")
                        .fix(Span { end_line: e.span.line, end_col: e.span.col, ..e.span }, "float(")
                        .fix(e.span.after(), ")");
                }
            }
            (Ty::Float, Ty::Int) => d = d.note("there are no implicit conversions; convert with `int(x)` (truncates toward zero)"),
            (Ty::Char, Ty::Str) => {
                if let K::Lit(Lit::Char(c)) = &e.kind {
                    d = d.note("a char literal uses single quotes; a one-char string uses double quotes").fix(e.span, format!("{:?}", c.to_string()));
                } else {
                    d = d.note("convert with `str(c)`");
                }
            }
            (_, Ty::Str) if !matches!(h, Ty::Var(_)) => d = d.note("convert with `str(x)` or interpolate: `\"{x}\"`"),
            _ => {}
        }
        if tail && units_only {
            d = d.note(format!("the function's return type says `{ws}`"));
        } else if tail {
            let frame = self.cxs.last().and_then(|c| c.frames.last());
            let (ret_span, ret_insert) = (frame.and_then(|f| f.ret_span), frame.and_then(|f| f.ret_insert));
            if !matches!(h, Ty::Var(_) | Ty::Never) && !h.has_vars() {
                if let Some(rs) = ret_span {
                    d = d.note(format!("the function's return type says `{ws}`")).fix(rs, hs.clone());
                } else if let Some(at) = ret_insert
                    && w.is_unit()
                {
                    d = Diag::new("E0200", e.span, format!("this function has no return type, so it returns `()`, but its body is a `{hs}`"))
                        .note(format!("declare the return type: `: {hs}`"))
                        .fix(at, format!(": {hs}"));
                }
            }
        }
        self.err(d);
    }

    // ---- the expression forms ----

    fn expr_inner(&mut self, e: &Expr, exp: &Exp) -> Ty {
        match &e.kind {
            K::Lit(l) => {
                let t = self.lit(e, l, false);
                self.zero_takes_unit(e, t, exp.ty())
            }
            K::Measured { expr, units } => {
                let t = self.infer(expr, None);
                Ty::measured(t, units.clone())
            }
            K::Interp(parts) => {
                for p in parts {
                    if let InterpPart::Expr { expr, spec } = p {
                        self.interp_part(expr, spec.as_deref());
                    }
                }
                Ty::Str
            }
            K::Name(n) => self.name_expr(e, n, exp),
            K::Hole => match exp.ty() {
                Some(t) => t.clone(),
                None => self.fresh(),
            },
            K::Field { expr, name } => self.field_expr(e, expr, name, exp),
            K::TupleField { expr, index } => {
                let t = self.infer(expr, None);
                match self.shallow(&t) {
                    Ty::Tuple(ts) if (*index as usize) < ts.len() => ts[*index as usize].clone(),
                    Ty::Tuple(ts) => {
                        self.err(
                            Diag::new("E0223", e.span, format!("the tuple `{}` has no element {index}", self.show(&t)))
                                .note(format!("it has {} element(s), numbered from 0", ts.len())),
                        );
                        Ty::Error
                    }
                    Ty::Error => Ty::Error,
                    Ty::Var(_) => self.cant_infer(expr.span, "the tuple"),
                    Ty::Opt(i) if matches!(self.shallow(&i), Ty::Tuple(_)) => {
                        let mut d = Diag::new("E0223", e.span, format!("`{}` may be missing (`{}`), so it has no element {index}", self.text(expr.span), self.show(&t)))
                            .note(format!("use `?.{index}` to get the element when present (`x?.{index}` is `T?`), or unwrap first with `?`, `!` or `else`"));
                        let (l, c) = (expr.span.end_line, expr.span.end_col);
                        if e.span.end_line == l && e.span.end_col == c + 1 + index.to_string().len() as u32 {
                            d = d.fix(Span { line: l, col: c, end_line: l, end_col: c + 1 }, "?.");
                        }
                        self.err(d);
                        Ty::Error
                    }
                    _ => {
                        self.err(Diag::new("E0223", e.span, format!("`.{index}` needs a tuple, found `{}`", self.show(&t))));
                        Ty::Error
                    }
                }
            }
            K::Call { callee, args } => self.call_expr(e, callee, args, exp),
            K::MethodCall { recv, name, args } => self.method_call(e, recv, name, args, exp),
            K::Pipe { lhs, callee, args } => self.pipe_call(e, lhs, callee, args, exp),
            K::Index { expr, index } => self.index_expr(e, expr, index),
            K::Slice { expr, lo, hi, .. } => {
                let t = self.infer(expr, exp.ty());
                self.check(lo, &Ty::Int);
                self.check(hi, &Ty::Int);
                match self.shallow(&t) {
                    Ty::List(_) | Ty::Str | Ty::Error => t,
                    Ty::Var(_) => self.cant_infer(expr.span, "the sliced value"),
                    _ => {
                        self.err(
                            Diag::new("E0270", e.span, format!("can't slice a `{}`", self.show(&t)))
                                .note("slices work on lists and strings: `xs[a..b]`, `s[a..b]`"),
                        );
                        Ty::Error
                    }
                }
            }
            K::Unary { op, expr } => self.unary(e, *op, expr, exp),
            K::Binary { op, lhs, rhs } => self.binary(e, *op, lhs, rhs, exp),
            K::Range { lo, hi, .. } => {
                self.check(lo, &Ty::Int);
                self.check(hi, &Ty::Int);
                Ty::list(Ty::Int)
            }
            K::Is { expr, pat } => {
                let t = self.infer(expr, None);
                self.is_pattern(pat, &t);
                Ty::Bool
            }
            K::Try(x) => self.try_expr(e, x, exp),
            K::Unwrap(x) => {
                let vals = exp.ty().map(|t| self.value_cands(t)).unwrap_or_default();
                let hint = self.wrap_hints(&vals);
                let t = self.expr(x, hint.map_or(Exp::None, Exp::Hints));
                match self.shallow(&t) {
                    Ty::Opt(inner) | Ty::Res(inner, _) => *inner,
                    Ty::Error => Ty::Error,
                    Ty::Var(_) => self.cant_infer(x.span, "the unwrapped value"),
                    _ => {
                        self.err(
                            Diag::new("E0251", e.span, format!("`!` unwraps a `T?` or `T!`, but this is `{}`", self.show(&t)))
                                .note("remove the `!`")
                                .fix(Span { line: e.span.end_line, col: e.span.end_col - 1, ..e.span }, ""),
                        );
                        t
                    }
                }
            }
            K::OptChain { expr, name, args } => self.opt_chain(e, expr, name, args.as_deref(), exp),
            K::Else { expr, arm } => self.else_expr(e, expr, arm, exp),
            K::Await(x) => self.await_expr(e, x),
            K::Catch(x) => self.catch_expr(e, x),
            K::AwaitAny(x) => self.await_any_expr(e, x),
            K::Ref(x) => {
                self.err(Diag::new("E0311", e.span, "`&` is only for an argument passed to a `var` parameter"));
                self.infer(x, None)
            }
            K::Closure { params, body } => self.closure(e, params, body, exp),
            K::If { cond, then, els } => self.if_expr(cond, then, els.as_deref(), exp),
            K::Match { scrut, arms } => self.match_expr(scrut, arms, exp),
            K::Loop(b) => {
                let bt = match exp.ty() {
                    Some(t) if !matches!(exp, Exp::Hint(_)) => t.clone(),
                    _ => self.fresh(),
                };
                self.push_loop(true, bt.clone());
                self.block(b, &Exp::Discard);
                let l = self.pop_loop();
                if l.saw_break { bt } else { Ty::Never }
            }
            K::While { cond, body } => {
                self.check(cond, &Ty::Bool);
                self.push_loop(false, Ty::unit());
                self.block(body, &Exp::Discard);
                self.pop_loop();
                Ty::unit()
            }
            K::For { index, pat, iter, body } => {
                self.for_expr(e, index.as_ref(), pat, iter, body);
                Ty::unit()
            }
            K::Block(b) => self.block(b, exp),
            K::Let { mutable, pat, ty, value, els } => {
                self.let_stmt(e, *mutable, pat, ty.as_ref(), value, els.as_ref());
                Ty::unit()
            }
            K::Assign { op, target, value } => {
                self.assign(e, *op, target, value);
                Ty::unit()
            }
            K::Assert(x) => {
                self.check(x, &Ty::Bool);
                Ty::unit()
            }
            K::Return(_) if self.cxs.last().and_then(|c| c.frames.last()).is_some_and(|f| f.what == "catch") => {
                self.err(
                    Diag::new("E0335", e.span, "`return` can't leave a `catch`")
                        .note("`catch e` is an expression: its value is `e`'s value; compute it, then `return` after the `catch`"),
                );
                Ty::Never
            }
            K::Return(x) => {
                match self.frame_ret() {
                    None => {
                        let what = self.cxs.last().and_then(|c| c.frames.last()).map(|f| f.what).unwrap_or("constant");
                        self.err(Diag::new("E0246", e.span, format!("`return` is not allowed in a {what}")));
                    }
                    Some(r) => match x {
                        Some(x) => self.check_mode(x, &r, true),
                        None => {
                            let mut cs = Vec::new();
                            if !self.coerce_ty(&Ty::unit(), &r, &mut cs, e.span) {
                                let rs = self.show(&r);
                                self.err(
                                    Diag::new("E0200", e.span, format!("`return` without a value, but the function returns `{rs}`"))
                                        .note("write `return value`"),
                                );
                            }
                            for c in cs {
                                self.add_coercion(e.id, c);
                            }
                        }
                    },
                }
                Ty::Never
            }
            K::Break(x) => {
                self.break_expr(e, x.as_deref());
                Ty::Never
            }
            K::Continue => {
                if !self.in_loop() {
                    self.err(Diag::new("E0244", e.span, "`continue` outside a loop"));
                }
                Ty::Never
            }
            K::Peek(x) => {
                let t = self.infer(x, exp.ty());
                let r = self.resolve(&t);
                self.defer_fit(&t, self.b.show, x.span, "to `peek` it".into());
                if !is_prim(&r) {
                    self.note_show(x.id, &t);
                }
                t
            }
            K::Struct { path, fields, base } => self.struct_lit(e, path, fields, base.as_deref(), exp),
            K::List(xs) => {
                let et = match exp.ty().map(|t| self.shallow(t)) {
                    Some(Ty::List(t)) => *t,
                    _ => self.fresh(),
                };
                let mut first = true;
                for x in xs {
                    if first && matches!(self.shallow(&et), Ty::Var(_)) {
                        let t = self.infer(x, None);
                        self.unify(&et, &t);
                    } else {
                        self.check(x, &et);
                    }
                    first = false;
                }
                Ty::list(et)
            }
            K::Map(es) if es.is_empty() && self.wants_unit(exp) => {
                // `{}` is parsed as an empty map; where nothing (`()`) is expected it is an empty
                // block (`_ => {}` in a match). Codegen: a `Map` node of type `()` is a no-op.
                Ty::unit()
            }
            K::Map(es) => {
                let (kt, vt) = match exp.ty().map(|t| self.shallow(t)) {
                    Some(Ty::Map(k, v)) => (*k, *v),
                    _ => (self.fresh(), self.fresh()),
                };
                for (k, v) in es {
                    self.check(k, &kt);
                    self.check(v, &vt);
                }
                Ty::map(kt, vt)
            }
            K::Tuple(xs) => {
                let hint = match exp.ty().map(|t| self.shallow(t)) {
                    Some(Ty::Tuple(ts)) if ts.len() == xs.len() => Some(ts),
                    _ => None,
                };
                let mut out = Vec::new();
                for (i, x) in xs.iter().enumerate() {
                    out.push(match &hint {
                        Some(ts) if matches!(exp, Exp::Check(_) | Exp::Tail(_)) => self.check(x, &ts[i]),
                        Some(ts) => self.infer(x, Some(&ts[i])),
                        None => self.infer(x, None),
                    });
                }
                Ty::Tuple(out)
            }
        }
    }

    /// Is the expression's value discarded or expected to be `()` (or `()!`, `()?`)?
    fn wants_unit(&self, exp: &Exp) -> bool {
        match exp {
            Exp::Discard => true,
            Exp::Check(t) | Exp::Tail(t) => match self.shallow(t) {
                Ty::Opt(i) | Ty::Res(i, _) => self.shallow(&i).is_unit(),
                t => t.is_unit(),
            },
            _ => false,
        }
    }

    /// Infer an expression after an error was already reported for its context (arguments of
    /// an unknown function, ...): no "can't infer" follow-up errors.
    fn infer_quiet(&mut self, e: &Expr) {
        self.cx().quiet += 1;
        self.infer(e, None);
        self.cx().quiet -= 1;
    }

    pub fn cant_infer(&mut self, span: Span, what: &str) -> Ty {
        if self.cxs.last().is_some_and(|c| c.quiet > 0) {
            return Ty::Error;
        }
        self.err(
            Diag::new("E0360", span, format!("can't infer the type of {what} here"))
                .note("add a type annotation where it is declared, e.g. `let xs: [int] = []`"),
        );
        Ty::Error
    }

    fn lit(&mut self, e: &Expr, l: &Lit, negated: bool) -> Ty {
        match l {
            Lit::Int(n) => {
                let max = if negated { 1u64 << 63 } else { i64::MAX as u64 };
                if *n > max {
                    self.err(
                        Diag::new("E0210", e.span, format!("the integer literal {n} doesn't fit in an `int`"))
                            .note("an `int` is 64-bit: -9223372036854775808 to 9223372036854775807"),
                    );
                }
                Ty::Int
            }
            Lit::Float(_) => Ty::Float,
            Lit::Bool(_) => Ty::Bool,
            Lit::Char(_) => Ty::Char,
            Lit::Str(_) => Ty::Str,
        }
    }

    /// A literal `0` / `0.0` where a number with a unit is expected takes that unit (zero is
    /// zero in every unit); any other plain literal is dimensionless.
    fn zero_takes_unit(&mut self, e: &Expr, t: Ty, want: Option<&Ty>) -> Ty {
        if is_zero_lit(e)
            && let Some(w) = want
            && let Ty::Measured(b, u) = self.resolve(w)
            && *b == t
        {
            return Ty::Measured(b, u);
        }
        t
    }

    // ---- names ----

    fn name_expr(&mut self, e: &Expr, n: &str, exp: &Exp) -> Ty {
        if let Some(l) = self.lookup_local(n) {
            self.cx().t.names.insert(e.id, NameRef::Local(l));
            return self.local_ty(l);
        }
        let m = self.cur_module();
        if let Some(t) = self.item_value(e, m, m, n, exp) {
            return t;
        }
        let core = self.prog.core_root;
        if n == "none" {
            self.cx().t.names.insert(e.id, NameRef::None);
            let t = self.fresh();
            return Ty::opt(t);
        }
        if let Some(t) = self.item_value(e, m, core, n, exp) {
            return t;
        }
        // `regex` alone means `regex.regex`
        if let Some(target) = self.prog.first_segment(m, n)
            && let Some(t) = self.item_value(e, m, target, n, exp)
        {
            return t;
        }
        self.unknown_name(e.span, n, false)
    }

    /// A constant, function value or variant named `n` in module `target`, seen from `m`.
    fn item_value(&mut self, e: &Expr, m: ModId, target: ModId, n: &str, exp: &Exp) -> Option<Ty> {
        if let Some(&c) = self.items[target].consts.get(n)
            && (target == m || self.consts[c].public)
        {
            self.ensure_const(c);
            self.cx().t.names.insert(e.id, NameRef::Const(c));
            return Some(self.consts[c].ty.clone());
        }
        let fns = self.fns_in(m, target, n);
        if !fns.is_empty() {
            let f = match exp.ty().map(|t| self.shallow(t)) {
                Some(Ty::Fn(ps, _)) => fns.iter().copied().find(|&f| self.fns[f].params.len() == ps.len()).unwrap_or(fns[0]),
                _ => fns[0],
            };
            if fns.len() > 1 && !matches!(exp.ty().map(|t| self.shallow(t)), Some(Ty::Fn(..))) {
                self.err(
                    Diag::new("E0301", e.span, format!("`{n}` is overloaded, so it can't be used as a value here"))
                        .note(format!("wrap it in a closure, e.g. `x => {n}(x)`")),
                );
                return Some(Ty::Error);
            }
            let (s, args) = self.instantiate(f);
            let info = &self.fns[f];
            let ps: Vec<Ty> = info.params.iter().map(|p| p.ty.subst(&s)).collect();
            let r = info.ret.subst(&s);
            self.cx().t.names.insert(e.id, NameRef::Fn { func: f, type_args: args });
            self.cx().callees.insert(f);
            let body = self.cx().body;
            let bn = self.body_nodes.entry(body).or_default();
            bn.module = m;
            bn.fn_refs.push(e.id);
            return Some(Ty::func(ps, r));
        }
        let hint = exp.ty().map(|t| self.shallow(t));
        let vs = self.variant_candidates(target, n, hint.as_ref(), target != m);
        if let Some((d, i)) = vs {
            return Some(self.variant_value(e, d, i, hint.as_ref()));
        }
        None
    }

    /// Variants named `n` in module `target` (or core's when `target` is core), preferring one
    /// of the hinted enum type.
    fn variant_candidates(&self, target: ModId, n: &str, hint: Option<&Ty>, need_pub: bool) -> Option<(DefId, usize)> {
        // the expected type picks the variant, even one of another module's (pub) enum
        let cur = self.cur_module();
        if let Some(Ty::Named(d, _)) = hint
            && self.defs.is_enum(*d)
            && let Some(i) = self.defs.variants(*d).iter().position(|v| v.name == n)
            && (self.defs.types[*d].public || self.defs.types[*d].module == cur)
            && (target == cur || self.defs.types[*d].module == target)
        {
            return Some((*d, i));
        }
        let vs: Vec<(DefId, usize)> = self.items[target]
            .variants
            .get(n)
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .filter(|(d, _)| !need_pub || self.defs.types[*d].public)
            .collect();
        vs.first().copied()
    }

    fn variant_value(&mut self, e: &Expr, d: DefId, i: usize, hint: Option<&Ty>) -> Ty {
        let (s, args) = self.instantiate_def(d);
        let ty = Ty::Named(d, args.clone());
        if let Some(h) = hint {
            self.try_unify(&ty, h);
        }
        self.cx().t.names.insert(e.id, NameRef::Variant(VariantRef { def: d, index: i, args }));
        let fields: Vec<Ty> = self.defs.variants(d)[i].fields.iter().map(|(_, t)| t.subst(&s)).collect();
        if fields.is_empty() { ty } else { Ty::func(fields, ty) }
    }

    pub fn instantiate_def(&mut self, d: DefId) -> (HashMap<ParamId, Ty>, Vec<Ty>) {
        let params = self.defs.types[d].params.clone();
        let args: Vec<Ty> = params.iter().map(|_| self.fresh()).collect();
        (params.into_iter().zip(args.iter().cloned()).collect(), args)
    }

    /// Fresh type arguments for a function's generics.
    pub fn instantiate(&mut self, f: FnId) -> (HashMap<ParamId, Ty>, Vec<Ty>) {
        let gens = self.fns[f].generics.clone();
        let args: Vec<Ty> = gens.iter().map(|_| self.fresh()).collect();
        (gens.into_iter().zip(args.iter().cloned()).collect(), args)
    }

    fn unknown_name(&mut self, span: Span, n: &str, call: bool) -> Ty {
        let m = self.cur_module();
        let mut cands: Vec<String> = Vec::new();
        if let Some(cx) = self.cxs.last() {
            for s in &cx.scopes {
                cands.extend(s.keys().cloned());
            }
        }
        cands.extend(self.items[m].fns.keys().cloned());
        cands.extend(self.items[m].consts.keys().cloned());
        let core = self.prog.core_root;
        cands.extend(self.items[core].fns.iter().filter(|(_, v)| v.iter().any(|&f| self.fns[f].public)).map(|(k, _)| k.clone()));
        let what = if call { "function" } else { "name" };
        let mut d = Diag::new("E0102", span, format!("unknown {what} `{n}`"));
        if let Some(TypeItem::Def(_)) = self.items[m].types.get(n) {
            d = d.note(format!("`{n}` is a type; build a value with `{n} {{ ... }}`"));
        } else if n == "old" {
            d = d.note("`old(e)` is only available in `ensures`");
        } else if n == "result" {
            d = d.note("`result` is only available in `ensures`");
        } else if let Some(s) = similar(n, &cands) {
            d = d.note(format!("did you mean `{s}`?")).fix(span, s);
        } else if self.prog.first_segment(m, n).is_none() && call {
            d = d.note("functions of other modules and packages are called by path, e.g. `json.parse(s)`; dependencies are listed in quack.toml");
        }
        self.err(d);
        Ty::Error
    }

    // ---- fields and paths ----

    fn field_expr(&mut self, e: &Expr, base: &Expr, name: &Ident, exp: &Exp) -> Ty {
        let m = self.cur_module();
        if let Some(path) = as_path(base) {
            let target = match self.expr_path(m, &path) {
                ExprPath::Module(t) => Some(t),
                ExprPath::Value => None,
                ExprPath::Ambiguous => return Ty::Error,
            };
            if let Some(target) = target {
                if let Some(t) = self.item_value(e, m, target, &name.name, exp) {
                    return t;
                }
                let d = Diag::new("E0102", name.span, format!("module `{}` has no public item `{}`", self.prog.name(target), name.name));
                let mut d = d;
                let cands: Vec<String> = self.items[target].fns.keys().chain(self.items[target].consts.keys()).cloned().collect();
                if let Some(s) = similar(&name.name, &cands) {
                    d = d.note(format!("did you mean `{s}`?")).fix(name.span, s);
                }
                self.err(d);
                return Ty::Error;
            }
            // `Shape.Circle`
            if (path.len() > 1 || self.lookup_local(&path[0].name).is_none())
                && let Some(TypeItem::Def(d)) = self.lookup_type_path(m, &path)
                && self.defs.is_enum(d)
            {
                if let Some(i) = self.defs.variants(d).iter().position(|v| v.name == name.name) {
                    let hint = exp.ty().map(|t| self.shallow(t));
                    return self.variant_value(e, d, i, hint.as_ref());
                }
                self.err(Diag::new("E0102", name.span, format!("the enum `{}` has no variant `{}`", self.defs.types[d].name, name.name)));
                return Ty::Error;
            }
        }
        let t = self.infer(base, None);
        self.field_of(e, base, &t, name)
    }

    /// The type of field `name` of a value of type `t` (`e` is the field expression).
    fn field_of(&mut self, e: &Expr, base: &Expr, t: &Ty, name: &Ident) -> Ty {
        match self.shallow(t) {
            Ty::Named(d, args) if self.defs.is_struct(d) => {
                let fields = self.defs.fields(d).to_vec();
                let Some(i) = fields.iter().position(|f| f.name == name.name) else {
                    let names: Vec<String> = fields.iter().map(|f| f.name.clone()).collect();
                    let mut dg = Diag::new("E0221", name.span, format!("the struct `{}` has no field `{}`", self.defs.types[d].name, name.name))
                        .note(format!("its fields are: {}", names.join(", ")));
                    if let Some(s) = similar(&name.name, &names) {
                        dg = dg.fix(name.span, s);
                    }
                    self.err(dg);
                    return Ty::Error;
                };
                let dm = self.defs.types[d].module;
                if dm != self.cur_module() && !fields[i].public {
                    let why = if self.defs.types[d].public { "its type is private to that module" } else { "the struct is not `pub`" };
                    self.err(
                        Diag::new(
                            "E0121",
                            name.span,
                            format!("the field `{}` of `{}` is private to module `{}`", name.name, self.defs.types[d].name, self.prog.name(dm)),
                        )
                        .note(format!("fields of another module's struct are readable when the struct is `pub`; here {why}")),
                    );
                }
                self.cx().t.fields.insert(e.id, (d, i));
                let s = self.defs.subst_of(d, &args);
                fields[i].ty.subst(&s)
            }
            Ty::Opt(_) => {
                let mut d = Diag::new(
                    "E0222",
                    e.span,
                    format!("`{}` may be missing (`{}`), so it has no field `{}`", self.text(base.span), self.show(t), name.name),
                )
                .note("use `?.` to get the field when present (`x?.f` is `T?`), or unwrap first with `?`, `!` or `else`");
                if name.span.line == base.span.end_line && name.span.col == base.span.end_col + 1 {
                    d = d.fix(
                        Span { line: base.span.end_line, col: base.span.end_col, end_line: base.span.end_line, end_col: base.span.end_col + 1 },
                        "?.",
                    );
                }
                self.err(d);
                Ty::Error
            }
            Ty::Res(..) => {
                self.err(
                    Diag::new(
                        "E0201",
                        e.span,
                        format!("`{}` may be an error (`{}`), so it has no field `{}`", self.text(base.span), self.show(t), name.name),
                    )
                    .note("pass the error up with `?` first: `(x?).f`... or `x?.f` is only for optionals")
                    .fix(base.span.after(), "?"),
                );
                Ty::Error
            }
            Ty::Error => Ty::Error,
            Ty::Var(_) => self.cant_infer(base.span, &format!("`{}`", self.text(base.span))),
            other => {
                let s = self.defs.show(&self.resolve(&other));
                self.err(
                    Diag::new("E0221", name.span, format!("`{s}` has no field `{}`", name.name))
                        .note("only structs have named fields; to call a function write `x.f()`"),
                );
                Ty::Error
            }
        }
    }

    // ---- calls ----

    fn call_expr(&mut self, e: &Expr, callee: &Expr, args: &[Expr], exp: &Exp) -> Ty {
        let direct = std::mem::take(&mut self.cx().direct_await);
        let srcs: Vec<ArgSrc> = args.iter().map(ArgSrc::Expr).collect();
        if let K::Name(n) = &callee.kind {
            if let Some(l) = self.lookup_local(n) {
                self.cx().t.names.insert(callee.id, NameRef::Local(l));
                let ft = self.local_ty(l);
                self.record(callee.id, &ft);
                return self.closure_call(e, callee, &ft, &srcs);
            }
            if self.cx().in_ensures && n == "old" && args.len() == 1 {
                let t = self.infer(&args[0], exp.ty());
                self.cx().olds.push(args[0].id);
                return t;
            }
            return self.named_call(e, callee, n, &srcs, exp, direct);
        }
        if let K::Field { .. } = &callee.kind
            && let Some(path) = as_path(callee)
        {
            let m = self.cur_module();
            let (last, prefix) = path.split_last().unwrap();
            match self.expr_path(m, prefix) {
                ExprPath::Module(target) => return self.path_call(e, target, last, &srcs, exp, direct),
                ExprPath::Ambiguous => return self.quiet_args(&srcs),
                ExprPath::Value => {}
            }
        }
        let ft = self.infer(callee, None);
        self.closure_call(e, callee, &ft, &srcs)
    }

    /// `f(args)` with a bare name: module functions, then variants, then core, then the
    /// `regex(p)` = `regex.regex(p)` rule.
    fn named_call(&mut self, e: &Expr, callee: &Expr, n: &str, args: &[ArgSrc], exp: &Exp, direct: bool) -> Ty {
        let m = self.cur_module();
        let core = self.prog.core_root;
        let hint = exp.ty().map(|t| self.shallow(t));
        let mut local_fns = self.fns_in(m, m, n);
        if !local_fns.is_empty() {
            // A module function overloads a same-named core function instead of hiding it
            // (spec: overloading is by parameter count or first-parameter type): with
            // `fn to_value(d: D): Value` defined, `to_value(w)` of another type still reaches
            // core's generic `to_value`. `call_fns` prefers the module's own overloads whenever
            // one takes the arguments, so a same-signature module function still wins: a module
            // `fn from_value(v: Value): D!` takes every `from_value(v)` there (core's has the same
            // first parameter, `Value`), and other types need `core.from_value(v)`.
            if m != core {
                let core_fns = self.fns_in(m, core, n);
                if !core_fns.iter().any(|&f| matches!(self.fns[f].kind, FnKind::Intrinsic { which: Intrinsic::Fail, .. })) {
                    local_fns.extend(core_fns);
                }
            }
            return self.call_fns(e, callee.span, n, local_fns, args, exp, direct);
        }
        if let Some((d, i)) = self.variant_candidates(m, n, hint.as_ref(), false) {
            return self.variant_call(e, d, i, args, hint.as_ref());
        }
        if let Some(&c) = self.items[m].consts.get(n) {
            self.ensure_const(c);
            let ft = self.consts[c].ty.clone();
            self.cx().t.names.insert(callee.id, NameRef::Const(c));
            self.record(callee.id, &ft);
            return self.closure_call(e, callee, &ft, args);
        }
        let core_fns = self.fns_in(m, core, n);
        if !core_fns.is_empty() {
            if core_fns.iter().any(|&f| matches!(self.fns[f].kind, FnKind::Intrinsic { which: Intrinsic::Fail, .. })) {
                return self.fail_call(e, args);
            }
            return self.call_fns(e, callee.span, n, core_fns, args, exp, direct);
        }
        if let Some((d, i)) = self.variant_candidates(core, n, hint.as_ref(), m != core) {
            return self.variant_call(e, d, i, args, hint.as_ref());
        }
        if let Some(target) = self.prog.first_segment(m, n) {
            let fs = self.fns_in(m, target, n);
            if !fs.is_empty() {
                return self.call_fns(e, callee.span, n, fs, args, exp, direct);
            }
        }
        self.unknown_name(callee.span, n, true);
        for a in args {
            if let ArgSrc::Expr(x) = a {
                self.infer_quiet(x);
            }
        }
        Ty::Error
    }

    /// After an error that stops a call from resolving: infer the arguments without reporting
    /// anything more about the call.
    fn quiet_args(&mut self, args: &[ArgSrc]) -> Ty {
        for a in args {
            if let ArgSrc::Expr(x) = a {
                self.infer_quiet(x);
            }
        }
        Ty::Error
    }

    /// `module.f(args)`: functions and variant constructors of that module.
    fn path_call(&mut self, e: &Expr, target: ModId, name: &Ident, args: &[ArgSrc], exp: &Exp, direct: bool) -> Ty {
        let m = self.cur_module();
        let fs = self.fns_in(m, target, &name.name);
        if !fs.is_empty() {
            return self.call_fns(e, name.span, &name.name, fs, args, exp, direct);
        }
        let hint = exp.ty().map(|t| self.shallow(t));
        if let Some((d, i)) = self.variant_candidates(target, &name.name, hint.as_ref(), target != m) {
            return self.variant_call(e, d, i, args, hint.as_ref());
        }
        let private = self.items[target].fns.contains_key(&name.name);
        let mut d = if private {
            Diag::new("E0120", name.span, format!("`{}` is private to module `{}`", name.name, self.prog.name(target)))
                .note("mark it `pub` to call it from other modules")
        } else {
            Diag::new("E0102", name.span, format!("module `{}` has no function `{}`", self.prog.name(target), name.name))
        };
        if !private {
            let cands: Vec<String> =
                self.items[target].fns.iter().filter(|(_, v)| v.iter().any(|&f| self.fns[f].public || target == m)).map(|(k, _)| k.clone()).collect();
            if let Some(s) = similar(&name.name, &cands) {
                d = d.note(format!("did you mean `{s}`?")).fix(name.span, s);
            }
        }
        self.err(d);
        for a in args {
            if let ArgSrc::Expr(x) = a {
                self.infer_quiet(x);
            }
        }
        Ty::Error
    }

    fn method_call(&mut self, e: &Expr, recv: &Expr, name: &Ident, args: &[Expr], exp: &Exp) -> Ty {
        let direct = std::mem::take(&mut self.cx().direct_await);
        let m = self.cur_module();
        let srcs: Vec<ArgSrc> = args.iter().map(ArgSrc::Expr).collect();
        if let Some(path) = as_path(recv) {
            match self.expr_path(m, &path) {
                ExprPath::Module(target) => return self.path_call(e, target, name, &srcs, exp, direct),
                ExprPath::Ambiguous => return self.quiet_args(&srcs),
                ExprPath::Value => {}
            }
            if (path.len() > 1 || self.lookup_local(&path[0].name).is_none())
                && let Some(TypeItem::Def(d)) = self.lookup_type_path(m, &path)
                && self.defs.is_enum(d)
                && let Some(i) = self.defs.variants(d).iter().position(|v| v.name == name.name)
            {
                let hint = exp.ty().map(|t| self.shallow(t));
                return self.variant_call(e, d, i, &srcs, hint.as_ref());
            }
        }
        let rt = self.infer(recv, None);
        let mut all = vec![ArgSrc::Recv(recv)];
        all.extend(srcs);
        self.dot_call(e, recv, &rt, name, &all, exp, direct)
    }

    /// `recv.name(args)` once the receiver's type is known: a shape method on a type parameter
    /// or `any S`, else UFCS lookup by type.
    #[allow(clippy::too_many_arguments)]
    fn dot_call(&mut self, e: &Expr, recv: &Expr, rt: &Ty, name: &Ident, args: &[ArgSrc], exp: &Exp, direct: bool) -> Ty {
        let r = self.shallow(rt);
        match &r {
            Ty::Error => {
                for a in &args[1..] {
                    self.infer_quiet(a.expr());
                }
                return Ty::Error;
            }
            Ty::Var(_) => {
                for a in &args[1..] {
                    self.infer_quiet(a.expr());
                }
                return self.cant_infer(recv.span, &format!("`{}` before calling `.{}()`", self.text(recv.span), name.name));
            }
            Ty::Param(p) => {
                let bounds = self.defs.params[*p].bounds.clone();
                for s in bounds {
                    if let Some(i) = self.defs.shapes[s].methods.iter().position(|x| x.name == name.name) {
                        return self.shape_call(e, s, i, r.clone(), Callee::Shape { shape: s, method: i, self_ty: r.clone() }, args);
                    }
                }
            }
            Ty::Any(s) => {
                if let Some(i) = self.defs.shapes[*s].methods.iter().position(|x| x.name == name.name) {
                    return self.shape_call(e, *s, i, r.clone(), Callee::Vtable { shape: *s, method: i }, args);
                }
            }
            _ => {}
        }
        let mut cands = self.method_cands(&name.name, rt, args.len());
        // a tier whose candidates can't take the other arguments (a closure for an `int`, ...)
        // doesn't hide the next tier: `fn find(xs: [User], id: int)` calling `xs.find(u => ..)`
        // reaches core's `find`
        if !cands.is_empty() && cands.iter().all(|&f| !self.args_plausible(f, &args[1..])) {
            let first = cands.clone();
            cands = self.method_cands_after(&name.name, rt, args.len(), &first, &args[1..]);
            if cands.is_empty() {
                cands = first;
            }
        }
        if cands.is_empty() {
            let m = self.cur_module();
            let ts = self.show(rt);
            let mut d = Diag::new("E0103", name.span, format!("no function `{}` takes a `{ts}` first ({} argument(s))", name.name, args.len()));
            let any_named: Vec<FnId> = self.method_tiers(rt).into_iter().flat_map(|t| self.fns_in(m, t, &name.name)).collect();
            let inner = match &r {
                Ty::Opt(i) | Ty::Res(i, _) => Some((**i).clone()),
                _ => None,
            };
            let inner_fits = inner.as_ref().is_some_and(|i| !self.method_cands(&name.name, i, args.len()).is_empty());
            if inner_fits {
                let rs = self.text(recv.span);
                if matches!(r, Ty::Opt(_)) {
                    d = d.note(format!("`{rs}` may be missing (`{ts}`); `?.{}(..)` calls it when present", name.name));
                    if name.span.line == recv.span.end_line && name.span.col == recv.span.end_col + 1 {
                        d = d.fix(
                            Span { line: recv.span.end_line, col: recv.span.end_col, end_line: recv.span.end_line, end_col: recv.span.end_col + 1 },
                            "?.",
                        );
                    }
                } else {
                    d = d.note(format!("`{rs}` may be an error (`{ts}`); pass it up with `?` first")).fix(recv.span.after(), "?");
                }
            } else if !any_named.is_empty() {
                let sigs: Vec<String> = any_named.iter().take(4).map(|&f| self.sig_text(f)).collect();
                d = d.note(format!("`{}` exists, but for other types or arities: {}", name.name, sigs.join("; ")));
            } else {
                let mut names: Vec<String> = Vec::new();
                for t in self.method_tiers(rt) {
                    let entries: Vec<(String, Vec<FnId>)> = self.items[t].fns.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
                    for (k, v) in entries {
                        let ok = v.into_iter().any(|f| {
                            let p0 = self.fns[f].params.first().map(|p| p.ty.clone());
                            (self.fns[f].public || t == m) && p0.is_some_and(|p| self.cx_can_unify_param(f, &p, rt))
                        });
                        if ok {
                            names.push(k);
                        }
                    }
                }
                if let Some(s) = similar(&name.name, &names) {
                    d = d.note(format!("did you mean `{s}`?")).fix(name.span, s);
                } else if let Ty::Named(dd, _) = &r
                    && self.defs.is_struct(*dd)
                    && self.defs.fields(*dd).iter().any(|f| f.name == name.name)
                {
                    d = d.note(format!("`{}` is a field; read it without parentheses: `x.{}`", name.name, name.name));
                }
            }
            self.err(d);
            for a in &args[1..] {
                self.infer_quiet(a.expr());
            }
            return Ty::Error;
        }
        self.call_fns(e, name.span, &name.name, cands, args, exp, direct)
    }

    /// Like `cx_can_unify_param`, ignoring units (`abs(d)` for a `float<m>` finds
    /// `abs(x: float)`; a unit mismatch is reported once the call is chosen).
    fn cx_can_unify_param_loose(&mut self, f: FnId, p: &Ty, t: &Ty) -> bool {
        let t = self.resolve(t);
        t.has_units() && self.cx_can_unify_param(f, &p.erase_units(), &t.erase_units())
    }

    /// How core function `f` treats a unit on its first argument, if it is unit-aware.
    fn unit_rule(&self, f: FnId) -> Option<UnitRule> {
        let info = &self.fns[f];
        if info.module != self.prog.core_root {
            return None;
        }
        match info.name.as_str() {
            "float" | "int" if info.params.len() == 1 => Some(UnitRule::Strip),
            "sum" | "abs" | "floor" | "ceil" | "round" => Some(UnitRule::Keep),
            "sqrt" => Some(UnitRule::Root),
            _ => None,
        }
    }

    fn cx_can_unify_param(&mut self, f: FnId, p: &Ty, t: &Ty) -> bool {
        let snap = self.cx().inf.snapshot();
        let (s, _) = self.instantiate(f);
        let ok = self.unify(&p.subst(&s), t);
        self.cx().inf.rollback(snap);
        ok
    }

    /// The modules searched for a dot call on a value of type `t`: the current module, the
    /// module that defines `t`, then core.
    pub fn method_tiers(&self, t: &Ty) -> Vec<ModId> {
        let m = self.cur_module();
        let mut tiers = vec![m];
        if let Ty::Named(d, _) = self.resolve(t) {
            let home = self.defs.types[d].module;
            if !tiers.contains(&home) {
                tiers.push(home);
            }
        }
        let core = self.prog.core_root;
        if !tiers.contains(&core) {
            tiers.push(core);
        }
        tiers
    }

    /// Functions `name` with `nargs` parameters whose first parameter accepts `t`, from the
    /// first tier that has any.
    pub fn method_cands(&mut self, name: &str, t: &Ty, nargs: usize) -> Vec<FnId> {
        let m = self.cur_module();
        for tier in self.method_tiers(t) {
            let named: Vec<FnId> = self.fns_in(m, tier, name).into_iter().filter(|&f| self.fns[f].params.len() == nargs).collect();
            let mut cands = Vec::new();
            for &f in &named {
                let p0 = self.fns[f].params[0].ty.clone();
                if self.cx_can_unify_param(f, &p0, t) {
                    cands.push(f);
                }
            }
            if cands.is_empty() {
                for &f in &named {
                    let p0 = self.fns[f].params[0].ty.clone();
                    if self.cx_can_unify_param_loose(f, &p0, t) {
                        cands.push(f);
                    }
                }
            }
            if !cands.is_empty() {
                return cands;
            }
        }
        Vec::new()
    }

    /// Can `f`'s parameters 1.. plausibly take these arguments? (A cheap syntactic test: a
    /// closure needs a function parameter; a literal needs its own primitive type.)
    fn args_plausible(&self, f: FnId, rest: &[ArgSrc]) -> bool {
        let ps = &self.fns[f].params;
        rest.iter().zip(ps.iter().skip(1)).all(|(a, p)| {
            let e = a.expr();
            let generic = matches!(p.ty, Ty::Param(_));
            match &e.kind {
                K::Closure { .. } => generic || matches!(p.ty, Ty::Fn(..)),
                K::Lit(l) => {
                    let lt = match l {
                        Lit::Int(_) => Ty::Int,
                        Lit::Float(_) => Ty::Float,
                        Lit::Bool(_) => Ty::Bool,
                        Lit::Char(_) => Ty::Char,
                        Lit::Str(_) => Ty::Str,
                    };
                    match &p.ty {
                        Ty::Opt(t) | Ty::Res(t, _) => **t == lt || matches!(**t, Ty::Param(_)),
                        t => *t == lt || generic || !is_prim(t),
                    }
                }
                _ => true,
            }
        })
    }

    /// Like `method_cands`, from the tiers after the one that produced `skip`, keeping only
    /// candidates whose arguments are plausible.
    fn method_cands_after(&mut self, name: &str, t: &Ty, nargs: usize, skip: &[FnId], rest: &[ArgSrc]) -> Vec<FnId> {
        let m = self.cur_module();
        let tiers = self.method_tiers(t);
        let start = tiers.iter().position(|&tier| skip.iter().any(|&f| self.fns[f].module == tier)).map_or(tiers.len(), |i| i + 1);
        for &tier in &tiers[start..] {
            let named: Vec<FnId> = self.fns_in(m, tier, name).into_iter().filter(|&f| self.fns[f].params.len() == nargs).collect();
            let mut cands = Vec::new();
            for f in named {
                let p0 = self.fns[f].params[0].ty.clone();
                if self.cx_can_unify_param(f, &p0, t) && self.args_plausible(f, rest) {
                    cands.push(f);
                }
            }
            if !cands.is_empty() {
                return cands;
            }
        }
        Vec::new()
    }

    fn sig_text(&self, f: FnId) -> String {
        let i = &self.fns[f];
        let ps: Vec<String> = i.params.iter().map(|p| format!("{}{}", if p.var { "var " } else { "" }, self.defs.show(&p.ty))).collect();
        let r = if i.ret.is_unit() { String::new() } else { format!(": {}", self.defs.show(&i.ret)) };
        format!("{}({}){r}", i.name, ps.join(", "))
    }

    fn pipe_call(&mut self, e: &Expr, lhs: &Expr, callee: &Expr, args: &[Expr], exp: &Exp) -> Ty {
        let direct = std::mem::take(&mut self.cx().direct_await);
        let m = self.cur_module();
        let mut all = vec![ArgSrc::Recv(lhs)];
        all.extend(args.iter().map(ArgSrc::Expr));
        let lt = self.infer(lhs, None);
        let _ = lt;
        if let K::Name(n) = &callee.kind {
            if let Some(l) = self.lookup_local(n) {
                self.cx().t.names.insert(callee.id, NameRef::Local(l));
                let ft = self.local_ty(l);
                self.record(callee.id, &ft);
                return self.closure_call(e, callee, &ft, &all);
            }
            return self.named_call(e, callee, n, &all, exp, direct);
        }
        if let Some(path) = as_path(callee) {
            let (last, prefix) = path.split_last().unwrap();
            match self.expr_path(m, prefix) {
                ExprPath::Module(target) => return self.path_call(e, target, last, &all, exp, direct),
                ExprPath::Ambiguous => return self.quiet_args(&all[1..]),
                ExprPath::Value => {}
            }
        }
        self.err(Diag::new("E0030", callee.span, "a `|>` step must name a function").note("`x |> f(a)` means `f(x, a)`"));
        Ty::Error
    }

    /// The (already inferred) type of a receiver argument.
    fn recv_ty(&mut self, e: &Expr) -> Ty {
        self.cx().t.types.get(&e.id).cloned().unwrap_or(Ty::Error)
    }

    /// Type of an argument for choosing an overload: receivers are known; other arguments are
    /// inferred (once; `pre` caches it).
    fn arg_ty_for_choice(&mut self, a: ArgSrc) -> Ty {
        match a {
            ArgSrc::Recv(e) => self.recv_ty(e),
            ArgSrc::Expr(e) => match &e.kind {
                K::Ref(x) => {
                    let t = self.infer(x, None);
                    self.record(e.id, &t);
                    t
                }
                _ => self.infer(e, None),
            },
        }
    }

    /// Resolve an overloaded call among `cands`, check the arguments, record the call.
    #[allow(clippy::too_many_arguments)]
    pub fn call_fns(&mut self, e: &Expr, span: Span, name: &str, cands: Vec<FnId>, args: &[ArgSrc], exp: &Exp, direct: bool) -> Ty {
        let n = args.len();
        let by_arity: Vec<FnId> = cands.iter().copied().filter(|&f| self.fns[f].params.len() == n).collect();
        if by_arity.is_empty() {
            let sigs: Vec<String> = cands.iter().take(4).map(|&f| self.sig_text(f)).collect();
            let given = if matches!(args.first(), Some(ArgSrc::Recv(_))) { format!("{} (counting the receiver)", n) } else { n.to_string() };
            self.err(
                Diag::new("E0300", span, format!("`{name}` takes {} argument(s), but {given} were given", self.fns[cands[0]].params.len()))
                    .note(format!("signature(s): {}", sigs.join("; "))),
            );
            for a in args {
                if let ArgSrc::Expr(x) = a {
                    self.infer_quiet(x);
                }
            }
            return Ty::Error;
        }
        let mut pre: Option<Ty> = None;
        let f = if by_arity.len() == 1 {
            by_arity[0]
        } else {
            let t0 = self.arg_ty_for_choice(args[0]);
            pre = Some(t0.clone());
            let mut fits: Vec<FnId> = by_arity
                .iter()
                .copied()
                .filter(|&f| {
                    let p0 = self.fns[f].params[0].ty.clone();
                    self.cx_can_unify_param(f, &p0, &t0) || self.can_coerce_param(f, &p0, &t0)
                })
                .collect();
            if fits.is_empty() {
                fits = by_arity
                    .iter()
                    .copied()
                    .filter(|&f| {
                        let p0 = self.fns[f].params[0].ty.clone();
                        self.cx_can_unify_param_loose(f, &p0, &t0)
                    })
                    .collect();
            }
            // the current module's own overloads come before core's (see `named_call`)
            let m = self.cur_module();
            if fits.iter().any(|&f| self.fns[f].module == m) {
                fits.retain(|&f| self.fns[f].module == m);
            }
            let specific: Vec<FnId> = fits.iter().copied().filter(|&f| !matches!(self.fns[f].params[0].ty, Ty::Param(_))).collect();
            let exact: Vec<FnId> = specific
                .iter()
                .copied()
                .filter(|&f| {
                    let p0 = self.fns[f].params[0].ty.clone();
                    self.cx_can_unify_param(f, &p0, &t0)
                })
                .collect();
            if fits.len() == 1 {
                fits[0]
            } else if exact.len() == 1 {
                exact[0]
            } else if specific.len() == 1 {
                specific[0]
            } else if fits.is_empty() {
                let r0 = self.resolve(&t0);
                if !r0.has_error() {
                    let sigs: Vec<String> = by_arity.iter().take(6).map(|&f| self.sig_text(f)).collect();
                    self.err(
                        Diag::new("E0202", args[0].expr().span, format!("no `{name}` takes a first argument of type `{}`", self.show(&t0)))
                            .note(format!("the overloads are: {}", sigs.join("; "))),
                    );
                }
                for a in &args[1..] {
                    if let ArgSrc::Expr(x) = a {
                        self.infer_quiet(x);
                    }
                }
                return Ty::Error;
            } else {
                let r0 = self.resolve(&t0);
                if r0.has_error() {
                    // the argument's own error was reported; any overload could be meant
                } else if r0.has_vars() {
                    self.cant_infer(args[0].expr().span, "the first argument (needed to choose an overload)");
                } else {
                    let sigs: Vec<String> = fits.iter().take(6).map(|&f| self.sig_text(f)).collect();
                    self.err(
                        Diag::new(
                            "E0301",
                            span,
                            format!("the call to `{name}` is ambiguous: {} overloads take a `{}` first", fits.len(), self.show(&t0)),
                        )
                        .note(format!("candidates: {}", sigs.join("; ")))
                        .note("call it by path (`module.f(x)`) to pick one"),
                    );
                }
                for a in &args[1..] {
                    if let ArgSrc::Expr(x) = a {
                        self.infer_quiet(x);
                    }
                }
                return Ty::Error;
            }
        };
        if let FnKind::Intrinsic { which: Intrinsic::Fail, .. } = self.fns[f].kind {
            return self.fail_call(e, args);
        }
        let (s, targs) = self.instantiate(f);
        let info = self.fns[f].clone();
        let mut ps: Vec<Ty> = info.params.iter().map(|p| p.ty.subst(&s)).collect();
        let mut ret = info.ret.subst(&s);
        if let Some(rule) = self.unit_rule(f) {
            if pre.is_none() {
                pre = Some(self.arg_ty_for_choice(args[0]));
            }
            let u = first_units(&self.resolve(pre.as_ref().unwrap()));
            if !u.is_none() {
                ps[0] = put_units(&ps[0], &u);
                ret = match rule {
                    UnitRule::Strip => ret,
                    UnitRule::Keep => put_units(&ret, &u),
                    UnitRule::Root => match u.root(2) {
                        Some(h) => put_units(&ret, &h),
                        None => {
                            self.err(
                                Diag::new("E0292", args[0].expr().span, format!("`{name}` of a `float<{u}>` has no unit: an exponent is odd"))
                                    .note("a square root needs even exponents (`m^2` gives `m`); strip the unit first with `float(x)`"),
                            );
                            Ty::Error
                        }
                    },
                };
            }
        }
        // the value of an `async fn` call is a task unless it is awaited right away
        let result = if info.is_async && !direct { Ty::Task(Box::new(ret.clone())) } else { ret.clone() };
        // let the expected type guide the type arguments (`let t: Todo = json.decode(s)?`)
        // A hint is taken only together with the receiver's (already known) type, so a hint that
        // contradicts the receiver is skipped instead of binding a wrong type argument.
        if !matches!(info.ret, Ty::Param(_)) || info.generics.is_empty() {
            let hints: Vec<Ty> = match exp {
                Exp::Hint(t) | Exp::Check(t) | Exp::Tail(t) if !matches!(self.shallow(t), Ty::Var(_)) => vec![t.clone()],
                Exp::Hints(ts) => ts.clone(),
                _ => Vec::new(),
            };
            if !hints.is_empty() {
                let (mut have, mut want) = (vec![result.clone()], vec![Ty::Error]);
                for (a, p) in args.iter().zip(&ps) {
                    if let ArgSrc::Recv(x) = *a {
                        have.push(self.recv_ty(x));
                        want.push(p.clone());
                    }
                }
                let have = Ty::Tuple(have);
                for t in hints {
                    want[0] = t;
                    if self.try_unify(&have, &Ty::Tuple(want.clone())) {
                        break;
                    }
                }
            }
        }
        let mut out_args = Vec::new();
        for (i, a) in args.iter().enumerate() {
            let var = info.params[i].var;
            let p = &ps[i];
            match *a {
                ArgSrc::Recv(x) => {
                    let t = self.recv_ty(x);
                    if var {
                        if !self.unify(&t, p) {
                            self.mismatch(x, &t, p, false);
                        }
                        self.place(x, true, PlaceUse::Receiver(name));
                    } else {
                        self.coerce_at(x, &t, p, false);
                    }
                    out_args.push(Arg { node: x.id, by_ref: var });
                }
                ArgSrc::Expr(x) => {
                    let is_ref = matches!(x.kind, K::Ref(_));
                    if let K::Ref(inner) = &x.kind {
                        let t = if i == 0 && pre.is_some() { pre.clone().unwrap() } else { self.infer(inner, Some(p)) };
                        self.record(x.id, &t);
                        if !var {
                            self.err(
                                Diag::new(
                                    "E0311",
                                    x.span,
                                    format!("parameter {} of `{name}` is not a `var` parameter, so its argument takes no `&`", i + 1),
                                )
                                .note("`&` marks an argument the callee may change; remove it")
                                .fix(Span { end_line: x.span.line, end_col: x.span.col + 1, ..x.span }, ""),
                            );
                            self.coerce_at(inner, &t, p, false);
                        } else {
                            if !self.unify(&t, p) {
                                self.mismatch(inner, &t, p, false);
                            }
                            self.place(inner, true, PlaceUse::Ref);
                        }
                    } else {
                        if var {
                            let pname = info.params[i].name.clone().map(|n| format!("`{n}`")).unwrap_or_else(|| format!("{}", i + 1));
                            self.err(
                                Diag::new("E0310", x.span, format!("parameter {pname} of `{name}` is `var`, so the argument needs `&`"))
                                    .note(format!("`{name}` may change it; write `&{}` to let it change the caller's variable", self.text(x.span)))
                                    .fix(Span { end_line: x.span.line, end_col: x.span.col, ..x.span }, "&"),
                            );
                        }
                        if i == 0 && pre.is_some() {
                            let t = pre.clone().unwrap();
                            self.coerce_at(x, &t, p, false);
                        } else {
                            self.check(x, p);
                        }
                    }
                    out_args.push(Arg { node: x.id, by_ref: var && is_ref });
                }
            }
        }
        for (k, &g) in info.generics.iter().enumerate() {
            for &b in &self.defs.params[g].bounds.clone() {
                let shape = self.defs.shapes[b].name.clone();
                let tn = self.defs.params[g].name.clone();
                let why = if self.defs.params[g].implicit {
                    format!("which `{name}` needs (it takes `{shape}` values)")
                } else {
                    format!("which `{name}` needs for its type parameter `{tn}`")
                };
                self.defer_fit(&targs[k], b, span, why);
            }
        }
        self.note_call(e.id, Call { callee: Callee::Fn { func: f, type_args: targs }, args: out_args });
        if info.is_async && direct {
            self.cx().t.awaits.insert(e.id, AwaitKind::Direct);
        } else if info.is_async
            && let Some(p) = info.params.iter().find(|p| p.var)
        {
            // a task shares nothing with its caller (its arguments are copied into its own heap)
            self.err(
                Diag::new("E0336", e.span, format!("`{name}` takes {} by `var`, so it can't run as a task", p.name.as_deref().map(|n| format!("`{n}`")).unwrap_or("an argument".into())))
                    .note("a task gets copies of its arguments and shares nothing with its caller; `await` the call right away to run it here, or pass the value and return the new one")
                    .fix(Span { end_line: e.span.line, end_col: e.span.col, ..e.span }, "await "),
            );
        }
        result
    }

    /// Could `t` convert to the parameter type (auto-wrap) for overload choice?
    fn can_coerce_param(&mut self, f: FnId, p: &Ty, t: &Ty) -> bool {
        let snap = self.cx().inf.snapshot();
        let (s, _) = self.instantiate(f);
        let p = p.subst(&s);
        let ok = match self.shallow(&p) {
            Ty::Opt(inner) | Ty::Res(inner, _) => self.unify(&inner, t),
            _ => false,
        };
        self.cx().inf.rollback(snap);
        ok
    }

    fn shape_call(&mut self, e: &Expr, s: ShapeId, i: usize, self_ty: Ty, callee: Callee, args: &[ArgSrc]) -> Ty {
        let meth = self.defs.shapes[s].methods[i].clone();
        let sub: HashMap<ParamId, Ty> = [(self.defs.shapes[s].self_param, self_ty)].into_iter().collect();
        if meth.params.len() != args.len() {
            self.err(Diag::new(
                "E0300",
                e.span,
                format!("`{}` takes {} argument(s), but {} were given", meth.name, meth.params.len() - 1, args.len() - 1),
            ));
            return Ty::Error;
        }
        let mut out = Vec::new();
        for (a, p) in args.iter().zip(&meth.params) {
            let p = p.subst(&sub);
            match *a {
                ArgSrc::Recv(x) => {
                    let t = self.recv_ty(x);
                    self.coerce_at(x, &t, &p, false);
                    out.push(Arg { node: x.id, by_ref: false });
                }
                ArgSrc::Expr(x) => {
                    self.check(x, &p);
                    out.push(Arg { node: x.id, by_ref: false });
                }
            }
        }
        self.note_call(e.id, Call { callee, args: out });
        meth.ret.subst(&sub)
    }

    fn variant_call(&mut self, e: &Expr, d: DefId, i: usize, args: &[ArgSrc], hint: Option<&Ty>) -> Ty {
        let (s, targs) = self.instantiate_def(d);
        let ty = Ty::Named(d, targs.clone());
        if let Some(h) = hint {
            let _ = self.try_unify(&ty, h);
        }
        let v = self.defs.variants(d)[i].clone();
        if v.fields.len() != args.len() {
            let what = if v.fields.is_empty() {
                format!("`{}` has no fields; write it without parentheses", v.name)
            } else {
                format!("`{}` has {} field(s)", v.name, v.fields.len())
            };
            self.err(
                Diag::new("E0302", e.span, format!("the variant `{}` takes {} value(s), but {} were given", v.name, v.fields.len(), args.len()))
                    .note(what),
            );
            for a in args {
                if let ArgSrc::Expr(x) = a {
                    self.infer_quiet(x);
                }
            }
            return ty;
        }
        let mut out = Vec::new();
        for (a, (_, ft)) in args.iter().zip(&v.fields) {
            let ft = ft.subst(&s);
            match *a {
                ArgSrc::Recv(x) => {
                    let t = self.recv_ty(x);
                    self.coerce_at(x, &t, &ft, false);
                    out.push(Arg { node: x.id, by_ref: false });
                }
                ArgSrc::Expr(x) => {
                    self.check(x, &ft);
                    out.push(Arg { node: x.id, by_ref: false });
                }
            }
        }
        self.note_call(e.id, Call { callee: Callee::Variant(VariantRef { def: d, index: i, args: targs }), args: out });
        ty
    }

    fn closure_call(&mut self, e: &Expr, callee: &Expr, ft: &Ty, args: &[ArgSrc]) -> Ty {
        let ft = match self.shallow(ft) {
            Ty::Var(_) => {
                let ps: Vec<Ty> = args.iter().map(|_| self.fresh()).collect();
                let r = self.fresh();
                let f = Ty::func(ps, r);
                self.unify(ft, &f);
                f
            }
            t => t,
        };
        match ft {
            Ty::Fn(ps, r) => {
                if ps.len() != args.len() {
                    self.err(Diag::new("E0300", e.span, format!("this closure takes {} argument(s), but {} were given", ps.len(), args.len())));
                    return *r;
                }
                let mut out = Vec::new();
                for (a, p) in args.iter().zip(&ps) {
                    match *a {
                        ArgSrc::Recv(x) => {
                            let t = self.recv_ty(x);
                            self.coerce_at(x, &t, p, false);
                            out.push(Arg { node: x.id, by_ref: false });
                        }
                        ArgSrc::Expr(x) => {
                            self.check(x, p);
                            out.push(Arg { node: x.id, by_ref: false });
                        }
                    }
                }
                self.note_call(e.id, Call { callee: Callee::Closure, args: out });
                *r
            }
            Ty::Error => Ty::Error,
            other => {
                let s = self.defs.show(&self.resolve(&other));
                self.err(Diag::new("E0203", callee.span, format!("`{}` is a `{s}`, not a function", self.text(callee.span))));
                Ty::Error
            }
        }
    }

    /// `fail(e)`: never returns; `e` is a message, an `Err` or the function's error enum.
    fn fail_call(&mut self, e: &Expr, args: &[ArgSrc]) -> Ty {
        if args.len() != 1 {
            self.err(Diag::new("E0300", e.span, format!("`fail` takes 1 argument, but {} were given", args.len())));
            return Ty::Never;
        }
        let x = args[0].expr();
        let ret = self.frame_ret().map(|r| self.shallow(&r));
        let et = match &ret {
            Some(Ty::Res(_, et)) => Some(self.shallow(et)),
            _ => None,
        };
        let hint = et.clone().filter(|t| !self.defs.is_err(t));
        let t = self.infer(x, hint.as_ref());
        let t = self.resolve(&t);
        let what = self.cxs.last().and_then(|c| c.frames.last()).map(|f| f.what).unwrap_or("function");
        if ret.is_none() && (what == "guard" || what == "constant") {
            self.err(Diag::new("E0246", e.span, format!("`fail` is not allowed in a {what}")).note("guards and constants can't fail"));
            return Ty::Never;
        }
        let Some(et) = et else {
            let mut d = Diag::new("E0242", e.span, "`fail` can only be used in a function that returns `T!` or `T!E` (or in a test)");
            let rs = self.cxs.last().and_then(|c| c.frames.last()).and_then(|f| f.ret_span);
            if let (Some(rs), Some(r)) = (rs, ret.clone()) {
                let r = self.show(&r);
                d = d.note(format!("change the return type to `{r}!`")).fix(rs, format!("{r}!"));
            } else {
                d = d.note("declare the return type as `T!` (e.g. `fn f(): int!`) to report errors");
            }
            self.err(d);
            return Ty::Never;
        };
        let kind = match &t {
            Ty::Str => FailKind::Message,
            Ty::Error => FailKind::Message,
            t if self.defs.is_err(t) => {
                if self.defs.is_err(&et) {
                    FailKind::Err
                } else {
                    self.err(
                        Diag::new("E0241", x.span, format!("this function's errors are `{}`, so it can't fail with an `Err`", self.show(&et)))
                            .note("fail with one of its variants, or make the return type `T!`"),
                    );
                    FailKind::Err
                }
            }
            Ty::Named(d, _) if self.defs.is_enum(*d) => {
                if self.unify(&t, &et) {
                    FailKind::Typed
                } else if self.defs.is_err(&et) {
                    FailKind::TypedToErr(t.clone())
                } else {
                    self.err(
                        Diag::new("E0241", x.span, format!("this function's errors are `{}`, but this is a `{}`", self.show(&et), self.show(&t)))
                            .note("fail with a variant of the declared error enum"),
                    );
                    FailKind::Message
                }
            }
            _ => {
                let what = if self.defs.is_err(&et) {
                    "a `str` message, an `Err` or an error enum value".to_string()
                } else {
                    format!("a `str` message or a `{}`", self.show(&et))
                };
                self.err(
                    Diag::new("E0241", x.span, format!("`fail` needs {what}, found `{}`", self.show(&t))).note("e.g. `fail(\"bad input: {x}\")`"),
                );
                FailKind::Message
            }
        };
        if let Ty::Str = t {
            // a message: make a plain `Err` even in a `T!E` function? No: a `T!E` function's
            // errors are its enum, so a message only fits a `T!` function.
            if !self.defs.is_err(&et) {
                self.err(
                    Diag::new("E0241", x.span, format!("this function's errors are `{}`, so it can't fail with a message", self.show(&et)))
                        .note("fail with one of its variants, or make the return type `T!` to use messages"),
                );
            }
        }
        self.cx().t.fails.insert(e.id, kind);
        Ty::Never
    }

    // ---- places (assignment targets, `&x`, `var` receivers) ----

    /// The type of a place expression, checking that it can be changed. `use_` says why.
    pub fn place(&mut self, e: &Expr, mutate: bool, use_: PlaceUse) -> Ty {
        match &e.kind {
            K::Name(n) => {
                let Some(l) = self.lookup_local(n) else {
                    let what = match use_ {
                        PlaceUse::Assign => "assign to",
                        _ => "change",
                    };
                    let m = self.cur_module();
                    if self.items[m].consts.contains_key(n) {
                        self.err(
                            Diag::new("E0320", e.span, format!("can't {what} `{n}`: it is a module constant"))
                                .note("constants never change; use a `var` inside a function"),
                        );
                    } else {
                        self.unknown_name(e.span, n, false);
                    }
                    return Ty::Error;
                };
                self.cx().t.names.insert(e.id, NameRef::Local(l));
                let t = self.local_ty(l);
                self.record(e.id, &t);
                if mutate {
                    let m = self.cur_module();
                    if !self.tables[m].locals[l].mutable {
                        let mut d = Diag::new(
                            "E0320",
                            e.span,
                            match use_ {
                                PlaceUse::Assign => format!("can't assign to `{n}`: it isn't mutable"),
                                PlaceUse::Ref => format!("can't pass `&{n}`: `{n}` isn't mutable"),
                                PlaceUse::Receiver(f) => format!("`{f}` changes its first argument, but `{n}` isn't mutable"),
                            },
                        );
                        let fix = self.local_fix(l);
                        match fix {
                            Some((span, text, what)) => d = d.note(format!("declare it with `var` to change it ({what})")).fix(span, text),
                            None => d = d.note("only `var` locals and `var` parameters can change; copy it into a `var` first"),
                        }
                        self.err(d);
                    } else if self.is_captured(l) {
                        self.err(
                            Diag::new("E0323", e.span, format!("a closure can't change `{n}`, a variable it captures"))
                                .note("closures capture by value; return the new value from the closure instead"),
                        );
                    }
                }
                t
            }
            K::Field { expr, name } => {
                let bt = self.place(expr, mutate, use_);
                let t = self.field_of(e, expr, &bt, name);
                self.record(e.id, &t);
                t
            }
            K::TupleField { expr, index } => {
                let bt = self.place(expr, mutate, use_);
                let t = match self.shallow(&bt) {
                    Ty::Tuple(ts) if (*index as usize) < ts.len() => ts[*index as usize].clone(),
                    Ty::Error => Ty::Error,
                    _ => {
                        self.err(Diag::new("E0223", e.span, format!("`.{index}` needs a tuple, found `{}`", self.show(&bt))));
                        Ty::Error
                    }
                };
                self.record(e.id, &t);
                t
            }
            K::Index { expr, index } => {
                let bt = self.place(expr, mutate, use_);
                let t = match self.shallow(&bt) {
                    Ty::List(t) => {
                        self.check(index, &Ty::Int);
                        *t
                    }
                    Ty::Map(k, v) => {
                        self.check(index, &k);
                        *v
                    }
                    Ty::Str => {
                        self.check(index, &Ty::Int);
                        self.err(
                            Diag::new("E0322", e.span, "strings are immutable: `s[i]` can't be assigned")
                                .note("build a new string, e.g. with `s.chars()` and `str(cs)`"),
                        );
                        Ty::Char
                    }
                    Ty::Error => Ty::Error,
                    _ => {
                        self.err(Diag::new("E0270", e.span, format!("can't index a `{}`", self.show(&bt))));
                        Ty::Error
                    }
                };
                self.record(e.id, &t);
                t
            }
            _ => {
                if mutate {
                    self.err(
                        Diag::new("E0027", e.span, "this expression can't be changed")
                            .note("only variables, fields and indexes (like `a.b[i]`) can be assigned or passed with `&`"),
                    );
                }
                self.infer(e, None)
            }
        }
    }

    /// How to make local `l` mutable: (span, replacement, description).
    fn local_fix(&self, l: LocalId) -> Option<(Span, String, &'static str)> {
        let m = self.cur_module();
        if let Some(&s) = self.let_fixes.get(&(m, l)) {
            return Some((s, "var".into(), "`let` makes an immutable binding"));
        }
        if let Some(&s) = self.param_fixes.get(&(m, l)) {
            return Some((s, "var ".into(), "parameters are immutable unless declared `var`, and then the caller passes `&x`"));
        }
        None
    }

    // ---- operators ----

    fn unary(&mut self, e: &Expr, op: UnOp, x: &Expr, exp: &Exp) -> Ty {
        match op {
            UnOp::Not => {
                self.check(x, &Ty::Bool);
                Ty::Bool
            }
            UnOp::BitNot => {
                let t = self.infer(x, Some(&Ty::Int));
                if self.bit_operand(x, &t, "~", true) { Ty::Int } else { Ty::Error }
            }
            UnOp::Neg => {
                let t = if let K::Lit(l @ (Lit::Int(_) | Lit::Float(_))) = &x.kind {
                    let t = self.lit(x, l, true);
                    self.record(x.id, &t);
                    t
                } else {
                    self.infer(x, exp.ty())
                };
                match self.shallow(&t) {
                    Ty::Int | Ty::Float | Ty::Measured(..) | Ty::Error => t,
                    Ty::Var(_) => self.cant_infer(x.span, "the negated value"),
                    _ => {
                        self.err(Diag::new("E0260", e.span, format!("can't negate a `{}`", self.show(&t))).note("`-x` works on `int` and `float`"));
                        Ty::Error
                    }
                }
            }
        }
    }

    fn binary(&mut self, e: &Expr, op: BinOp, l: &Expr, r: &Expr, exp: &Exp) -> Ty {
        use BinOp::*;
        match op {
            And | Or => {
                self.check(l, &Ty::Bool);
                self.check(r, &Ty::Bool);
                Ty::Bool
            }
            Eq | Ne | Lt | Le | Gt | Ge => {
                let lt = self.infer(l, None);
                if !self.number_compare(e, op, l, r, &lt) {
                    self.check(r, &lt);
                }
                let shape = if matches!(op, Eq | Ne) { self.b.eq } else { self.b.ord };
                self.compare(e, op, &lt, shape, l, r);
                Ty::Bool
            }
            BitAnd | BitOr | BitXor | Shl | Shr => {
                // one error is enough: `x | true` on a bool reports the left side only
                let lt = self.infer(l, Some(&Ty::Int));
                let ok = self.bit_operand(l, &lt, op.symbol(), true);
                let rt = self.infer(r, Some(&Ty::Int));
                if ok && self.bit_operand(r, &rt, op.symbol(), true) { Ty::Int } else { Ty::Error }
            }
            _ => self.arith(e, op, l, r, exp),
        }
    }

    /// An operand of `& | ^ << >> ~` (already inferred as `t`): a plain `int`. A unit is
    /// E0293 (with an `int(x)` fix when `fix`), anything else E0260. False after an error.
    fn bit_operand(&mut self, x: &Expr, t: &Ty, op: &str, fix: bool) -> bool {
        match self.shallow(t) {
            Ty::Int | Ty::Never => true,
            Ty::Error => false,
            Ty::Var(_) => {
                if self.unify(t, &Ty::Int) {
                    return true;
                }
                self.cant_infer(x.span, &format!("the operand of `{op}`"));
                false
            }
            Ty::Measured(b, _) => {
                let ts = self.show(t);
                let mut d = Diag::new("E0293", x.span, format!("`{op}` works on bits, but this is `{ts}`, a value with a unit"))
                    .note("bitwise operators take a plain `int`; a unit of measure has no meaning for single bits");
                if *b == Ty::Int && fix {
                    d = d
                        .note("strip the unit with `int(x)` first")
                        .fix(Span { end_line: x.span.line, end_col: x.span.col, ..x.span }, "int(")
                        .fix(x.span.after(), ")");
                }
                self.err(d);
                false
            }
            _ => {
                let ts = self.show(t);
                let mut d = Diag::new("E0260", x.span, format!("can't apply `{op}` to `{ts}`")).note("bitwise operators work on `int` only");
                let logical = match op.trim_end_matches('=') {
                    "&" => Some("&&"),
                    "|" => Some("||"),
                    "^" => Some("!="),
                    "~" => Some("!"),
                    _ => None,
                };
                if let (Ty::Bool, Some(l)) = (self.shallow(t), logical) {
                    d = d.note(format!("for booleans use `{l}`"));
                }
                self.err(d);
                false
            }
        }
    }

    /// `==`/`<` on `t`: built in for primitives, otherwise a user `eq`/`cmp` or the shape.
    fn compare(&mut self, e: &Expr, op: BinOp, t: &Ty, shape: ShapeId, l: &Expr, r_: &Expr) {
        let args = vec![Arg { node: l.id, by_ref: false }, Arg { node: r_.id, by_ref: false }];
        let r = self.resolve(t);
        let ord = shape == self.b.ord;
        if is_prim(&r) || r.has_error() || matches!(r, Ty::Never) {
            return;
        }
        if r.has_vars() {
            self.cant_infer(e.span, &format!("the operands of `{}`", op.symbol()));
            return;
        }
        let meth = if ord { "cmp" } else { "eq" };
        if !matches!(r, Ty::Param(_) | Ty::Any(_)) {
            let cands: Vec<FnId> =
                self.method_cands(meth, &r, 2).into_iter().filter(|&f| !matches!(self.fns[f].params[0].ty, Ty::Param(_))).collect();
            if let Some(&f) = cands.first() {
                let (s, targs) = self.instantiate(f);
                let p0 = self.fns[f].params[0].ty.subst(&s);
                let p1 = self.fns[f].params[1].ty.subst(&s);
                self.unify(&p0, &r);
                self.unify(&p1, &r);
                self.note_call(e.id, Call { callee: Callee::Fn { func: f, type_args: targs }, args });
                return;
            }
        }
        let why = if ord {
            format!("to compare with `{}` (it needs `Ord`; define `fn cmp(a: T, b: T): int`)", op.symbol())
        } else {
            format!("to compare with `{}`", op.symbol())
        };
        self.defer_fit(&r, shape, e.span, why);
        self.note_call(e.id, Call { callee: Callee::Shape { shape, method: 0, self_ty: r }, args });
    }

    fn arith(&mut self, e: &Expr, op: BinOp, l: &Expr, r: &Expr, exp: &Exp) -> Ty {
        use BinOp::*;
        // `*` `/` `**` change units, so the expected type's unit says nothing about an operand
        let hint = match op {
            Mul | Div | MulWrap | Pow => exp.ty().map(|t| self.resolve(t).erase_units()),
            _ => exp.ty().cloned(),
        };
        let lt = self.infer(l, hint.as_ref());
        let ls = self.shallow(&lt);
        if let Ty::Measured(b, _) = &ls
            && (matches!(op, Add | Sub | Mul | Div | Rem | Pow) || (matches!(op, AddWrap | SubWrap | MulWrap) && **b == Ty::Int))
        {
            let rhint = if matches!(op, Mul | Div | MulWrap | Pow) { (**b).clone() } else { lt.clone() };
            let rt = self.infer(r, Some(&rhint));
            return self.unit_operands(e, op, l, r, &lt, &rt);
        }
        let ok_prim = match op {
            Add => matches!(ls, Ty::Int | Ty::Float | Ty::Str | Ty::List(_)),
            Sub | Mul | Div | Rem | Pow => matches!(ls, Ty::Int | Ty::Float),
            AddWrap | SubWrap | MulWrap => matches!(ls, Ty::Int),
            _ => false,
        };
        if ok_prim {
            if matches!(ls, Ty::Int | Ty::Float) {
                // `2.0 * d`: a plain number scales a unit value
                let rt = self.infer(r, Some(&lt));
                if let Ty::Measured(..) = self.shallow(&rt) {
                    return self.unit_operands(e, op, l, r, &lt, &rt);
                }
                self.operand_with(r, &lt, &rt, op, l);
            } else {
                self.check_operand(r, &lt, op, l);
            }
            return lt;
        }
        match ls {
            Ty::Error => {
                self.infer(r, None);
                Ty::Error
            }
            Ty::Var(_) => {
                let rt = self.infer(r, None);
                if self.unify(&lt, &rt) && matches!(self.shallow(&rt), Ty::Int | Ty::Float | Ty::Str | Ty::List(_) | Ty::Measured(..)) {
                    return rt;
                }
                self.cant_infer(l.span, &format!("the left side of `{}`", op.symbol()))
            }
            Ty::Named(..) | Ty::Param(_) if matches!(op, Add | Sub | Mul | Div | Rem) => {
                let fname = match op {
                    Add => "add",
                    Sub => "sub",
                    Mul => "mul",
                    Div => "div",
                    _ => "mod",
                };
                let cands = self.method_cands(fname, &lt, 2);
                if let Some(&f) = cands.first() {
                    let (s, targs) = self.instantiate(f);
                    let info = self.fns[f].clone();
                    let p0 = info.params[0].ty.subst(&s);
                    self.unify(&p0, &lt);
                    let p1 = info.params[1].ty.subst(&s);
                    self.check(r, &p1);
                    self.note_call(
                        e.id,
                        Call {
                            callee: Callee::Fn { func: f, type_args: targs },
                            args: vec![Arg { node: l.id, by_ref: false }, Arg { node: r.id, by_ref: false }],
                        },
                    );
                    return info.ret.subst(&s);
                }
                let ts = self.show(&lt);
                self.err(
                    Diag::new("E0261", e.span, format!("`{}` isn't defined for `{ts}`", op.symbol()))
                        .note(format!("define `fn {fname}(a: {ts}, b: {ts}): {ts}` to give `{ts}` the `{}` operator", op.symbol())),
                );
                self.infer(r, None);
                Ty::Error
            }
            Ty::Task(_) => {
                self.infer(r, None);
                self.err(
                    Diag::new(
                        "E0333",
                        l.span,
                        format!("`{}` is an un-awaited `async fn` call, so `{}` can't use its value", self.text(l.span), op.symbol()),
                    )
                    .note("`await` the call to get its result")
                    .fix(Span { end_line: l.span.line, end_col: l.span.col, ..l.span }, "await "),
                );
                Ty::Error
            }
            _ => {
                let rt = self.infer(r, None);
                let (lts, rts) = (self.show(&lt), self.show(&rt));
                let mut d = Diag::new("E0260", e.span, format!("can't apply `{}` to `{lts}` and `{rts}`", op.symbol()));
                d = match (self.shallow(&lt), op) {
                    (Ty::Char, Add) => d.note("`+` doesn't work on chars; build a string with `str(c)` or `\"{a}{b}\"`"),
                    (Ty::Bool, _) => d.note("arithmetic needs numbers; use `&&` / `||` for booleans"),
                    (_, AddWrap | SubWrap | MulWrap) => d.note("wrapping arithmetic is only for `int`"),
                    _ => d.note("arithmetic works on `int` and `float` (both sides the same type); `+` also joins `str` and lists"),
                };
                self.err(d);
                Ty::Error
            }
        }
    }

    /// The right operand of a primitive arithmetic operator: same type as the left.
    fn check_operand(&mut self, r: &Expr, lt: &Ty, op: BinOp, l: &Expr) {
        let rt = self.infer(r, Some(lt));
        self.operand_with(r, lt, &rt, op, l);
    }

    /// `==` `<` ... on numbers when either side has a unit (or the left is a literal `0`):
    /// the units must be equal. Returns false when this isn't such a comparison (nothing
    /// checked yet).
    fn number_compare(&mut self, e: &Expr, op: BinOp, l: &Expr, r: &Expr, lt: &Ty) -> bool {
        let lr = self.resolve(lt);
        if !matches!(lr, Ty::Int | Ty::Float | Ty::Measured(..)) {
            return false;
        }
        let rt = self.infer(r, Some(lt));
        let rr = self.resolve(&rt);
        if !matches!(lr, Ty::Measured(..)) && !matches!(rr, Ty::Measured(..)) {
            self.coerce_at(r, &rt, lt, false);
            return true;
        }
        if lr.base() != rr.base() || rr.has_error() {
            self.coerce_at(r, &rt, lt, false);
        } else if lr.units() != rr.units() && !is_zero_lit(l) && !is_zero_lit(r) {
            self.unit_clash(e, op, &lr, &rr);
        }
        true
    }

    /// Arithmetic on numbers where either side has a unit: `+ - %` need equal units (a literal
    /// `0` fits any), `*` `/` combine them, `**` takes a literal integer exponent.
    fn unit_operands(&mut self, e: &Expr, op: BinOp, l: &Expr, r: &Expr, lt: &Ty, rt: &Ty) -> Ty {
        use BinOp::*;
        let lr = self.resolve(lt);
        let base = lr.base().clone();
        let scale = matches!(op, Mul | Div | MulWrap | Pow);
        if let Ty::Var(_) = self.shallow(rt) {
            let want = if scale { base.clone() } else { lr.clone() };
            self.unify(rt, &want);
        }
        let rr = self.resolve(rt);
        if lr.has_error() || rr.has_error() {
            return Ty::Error;
        }
        if lr.base() != rr.base() {
            self.operand_with(r, &base, rr.base(), op, l);
            return Ty::Error;
        }
        let (lu, ru) = (lr.units(), rr.units());
        match op {
            Mul | MulWrap => Ty::measured(base, lu.combine(&ru, 1)),
            Div => Ty::measured(base, lu.combine(&ru, -1)),
            Pow => match int_exponent(r) {
                Some(n) if ru.is_none() => Ty::measured(base, lu.pow(n)),
                _ => {
                    let msg = if ru.is_none() {
                        format!("`**` on `{}` needs a literal integer exponent to know the result's unit", self.defs.show(&lr))
                    } else {
                        format!("an exponent can't have a unit (`{}`)", self.defs.show(&rr))
                    };
                    self.err(
                        Diag::new("E0292", r.span, msg)
                            .note("write the exponent as a literal (`d ** 2.0`), or strip the unit first with `float(x)`"),
                    );
                    Ty::Error
                }
            },
            _ if lu == ru => lr,
            _ if is_zero_lit(l) => rr,
            _ if is_zero_lit(r) => lr,
            _ => {
                self.unit_clash(e, op, &lr, &rr);
                Ty::Error
            }
        }
    }

    /// E0290: `+ - % == <` ... on numbers with different units.
    fn unit_clash(&mut self, e: &Expr, op: BinOp, l: &Ty, r: &Ty) {
        let (ls, rs) = (self.defs.show(l), self.defs.show(r));
        let verb = if matches!(op, BinOp::Add | BinOp::Sub | BinOp::Rem | BinOp::AddWrap | BinOp::SubWrap) { "combine" } else { "compare" };
        let mut d = Diag::new("E0290", e.span, format!("can't {verb} `{ls}` and `{rs}` with `{}`: the units differ", op.symbol()));
        let (lu, ru) = (l.units(), r.units());
        if lu.is_none() || ru.is_none() {
            let u = if lu.is_none() { &ru } else { &lu };
            d = d.note(format!("a plain number has no unit: write the literal with one (`2.0<{u}>`), or strip a unit with `float(x)`"));
        } else if let Some(h) = lu.exponent_hint(&ru) {
            d = d.note(format!("{h} (`{lu}` vs `{ru}`)"));
        } else {
            d = d.note(format!("both sides need the same unit; convert one with a factor (a factor in `{}` turns `{ru}` into `{lu}`)", lu.combine(&ru, -1)));
        }
        self.err(d);
    }

    /// E0291: expected one unit, found another (the types are otherwise equal).
    fn unit_mismatch(&self, span: Span, have: &Ty, want: &Ty) -> Diag {
        let (hs, ws) = (self.defs.show(have), self.defs.show(want));
        let (hu, wu) = (first_units(have), first_units(want));
        let d = Diag::new("E0291", span, format!("expected `{ws}`, found `{hs}`: the units differ"));
        if hu.is_none() {
            d.note(format!("a plain number has no unit; give it one (`2.0<{wu}>`, or multiply by a value in `{wu}`)"))
        } else if wu.is_none() {
            d.note("`float(x)` / `int(x)` strip a unit when a plain number is meant")
        } else if let Some(h) = hu.exponent_hint(&wu) {
            d.note(format!("{h} (`{hu}` vs `{wu}`)"))
        } else {
            d.note(format!("convert with a factor (a factor in `{}` turns `{hu}` into `{wu}`), or fix the formula", wu.combine(&hu, -1)))
        }
    }

    /// Check a primitive arithmetic operand already inferred as `rt` against the left's `lt`.
    fn operand_with(&mut self, r: &Expr, lt: &Ty, rt: &Ty, op: BinOp, l: &Expr) {
        let rt = rt.clone();
        if self.unify(&rt, lt) {
            return;
        }
        let (lr, rr) = (self.resolve(lt), self.resolve(&rt));
        if rr.has_error() {
            return;
        }
        let mut d = Diag::new("E0260", r.span, format!("can't apply `{}` to `{}` and `{}`", op.symbol(), self.defs.show(&lr), self.defs.show(&rr)));
        match (&lr, &rr) {
            (Ty::Float, Ty::Int) => {
                if let K::Lit(Lit::Int(n)) = &r.kind {
                    d = d.note("both sides must be `float`; write a float literal").fix(r.span, format!("{n}.0"));
                } else {
                    d = d
                        .note("there are no implicit conversions; convert with `float(x)`")
                        .fix(Span { end_line: r.span.line, end_col: r.span.col, ..r.span }, "float(")
                        .fix(r.span.after(), ")");
                }
            }
            (Ty::Int, Ty::Float) => {
                if let K::Lit(Lit::Int(n)) = &l.kind {
                    d = d.note("both sides must be `float`; write a float literal").fix(l.span, format!("{n}.0"));
                } else {
                    d = d
                        .note("there are no implicit conversions; convert with `float(x)`")
                        .fix(Span { end_line: l.span.line, end_col: l.span.col, ..l.span }, "float(")
                        .fix(l.span.after(), ")");
                }
            }
            (Ty::Str, _) => d = d.note("`+` joins two strings; convert with `str(x)` or interpolate: `\"{a}{b}\"`"),
            _ => d = d.note("both sides of an arithmetic operator have the same type"),
        }
        self.err(d);
    }

    fn index_expr(&mut self, e: &Expr, x: &Expr, i: &Expr) -> Ty {
        let t = self.infer(x, None);
        match self.shallow(&t) {
            Ty::List(et) => {
                self.check(i, &Ty::Int);
                *et
            }
            Ty::Map(k, v) => {
                self.check(i, &k);
                *v
            }
            Ty::Str => {
                self.check(i, &Ty::Int);
                Ty::Char
            }
            Ty::Error => {
                self.infer(i, None);
                Ty::Error
            }
            Ty::Var(_) => self.cant_infer(x.span, "the indexed value"),
            Ty::Opt(_) => {
                self.err(
                    Diag::new("E0270", e.span, format!("`{}` may be missing (`{}`), so it can't be indexed", self.text(x.span), self.show(&t)))
                        .note("unwrap it first with `?`, `!` or `else`"),
                );
                Ty::Error
            }
            _ => {
                self.err(
                    Diag::new("E0270", e.span, format!("can't index a `{}`", self.show(&t)))
                        .note("indexing works on lists (`xs[i]`), maps (`m[k]`) and strings (`s[i]`)"),
                );
                Ty::Error
            }
        }
    }

    // ---- interpolation ----

    fn interp_part(&mut self, x: &Expr, spec: Option<&str>) {
        let t = self.infer(x, None);
        let r = self.resolve(&t);
        if !matches!(r, Ty::Error) {
            self.defer_fit(&t, self.b.show, x.span, "to interpolate it into a string".into());
        }
        if !is_prim(&r) && !r.has_error() {
            self.note_show(x.id, &t);
        }
        if let Ty::Measured(_, u) = &r {
            self.cx().t.units.insert(x.id, u.to_string());
        }
        let Some(spec) = spec else { return };
        match parse_format(spec) {
            Err(why) => {
                self.err(
                    Diag::new("E0282", x.span, format!("malformed format spec `{spec}`: {why}"))
                        .note("a spec is `[fill][<^>][0][width][.precision]`, e.g. `{x:>5}`, `{x:.2}`, `{x:08.3}`, `{s:-^20}`"),
                );
            }
            Ok(f) => {
                let num = matches!(r.base(), Ty::Int | Ty::Float);
                let ts = self.defs.show(&r);
                if f.precision.is_some() && !matches!(r.base(), Ty::Float | Ty::Str | Ty::Error) {
                    self.err(
                        Diag::new(
                            "E0280",
                            x.span,
                            format!("the format spec `{spec}` has a precision, which applies to `float` and `str`, not `{ts}`"),
                        )
                        .note("`.N` is decimal places for a float and a maximum length for a str; remove it, or convert with `float(x)`"),
                    );
                }
                if f.zero && !num && !matches!(r, Ty::Error) {
                    self.err(
                        Diag::new("E0281", x.span, format!("the format spec `{spec}` pads with zeros, which applies to numbers, not `{ts}`"))
                            .note("use a fill char instead, e.g. `{x:0>5}` (fill `0`, right-aligned)"),
                    );
                }
                self.cx().t.formats.insert(x.id, f);
            }
        }
    }

    // ---- `?`, `!`, `?.`, `else`, `await` ----

    fn try_expr(&mut self, e: &Expr, x: &Expr, exp: &Exp) -> Ty {
        // the operand's possible types, to steer type arguments (`json.decode(s)?`). The `?`
        // yields the operand's VALUE, which is then converted to the expected type, so the hints
        // wrap the expected value type: in a `T!` function's tail, `f()?` is `T` (then `T!`), and
        // its operand is `T!` / `T?`, never `T!!` (#524). As for `else`, a plain value comes first.
        let vals = exp.ty().map(|t| self.value_cands(t)).unwrap_or_default();
        let mut hints = self.wrap_hints(&vals).unwrap_or_default();
        for v in &vals {
            if let Ty::List(a) = self.shallow(v) {
                let ev = self.fresh();
                hints.push(Ty::list(Ty::res((*a).clone(), ev)));
                hints.push(Ty::list(Ty::opt(*a)));
            }
        }
        let t = self.expr(x, if hints.is_empty() { Exp::None } else { Exp::Hints(hints) });
        let ts = self.shallow(&t);
        let (kind, inner, err) = match &ts {
            Ty::Res(ok, er) => (TryKind::Result, (**ok).clone(), Some((**er).clone())),
            Ty::Opt(ok) => (TryKind::Option, (**ok).clone(), None),
            Ty::List(el) => match self.shallow(el) {
                Ty::Res(ok, er) => (TryKind::ListResult, Ty::list(*ok), Some(*er)),
                Ty::Opt(ok) => (TryKind::ListOption, Ty::list(*ok), None),
                _ => return self.bad_try(e, x, &t),
            },
            Ty::Error => return Ty::Error,
            Ty::Var(_) => return self.cant_infer(x.span, "the value before `?`"),
            _ => return self.bad_try(e, x, &t),
        };
        let ret = self.frame_ret().map(|r| self.shallow(&r));
        let what = self.cxs.last().and_then(|c| c.frames.last()).map(|f| f.what).unwrap_or("function");
        let conv = match (&ret, &err) {
            (None, _) => {
                self.err(
                    Diag::new("E0246", e.span, format!("`?` is not allowed in a {what}"))
                        .note("a guard or constant can't fail; handle the error with `else` or unwrap it with `!`"),
                );
                ErrConv::None
            }
            (Some(Ty::Res(_, rerr)), Some(er)) => {
                let (rerr, er) = (self.shallow(rerr), self.shallow(er));
                if self.try_unify(&rerr, &er) {
                    ErrConv::None
                } else if self.defs.is_err(&rerr) {
                    ErrConv::ToErr { from: er }
                } else {
                    self.err(
                        Diag::new("E0247", e.span, format!("`?` can't pass a `{}` error up: this {what} returns `{}`", self.show(&er), self.show(ret.as_ref().unwrap())))
                            .note(format!("a `T!{}` function's errors must be `{}`; handle this one with `else e => fail(...)`, or make the return type `T!` (any error converts to `Err`)", self.show(&rerr), self.show(&rerr))),
                    );
                    ErrConv::None
                }
            }
            (Some(Ty::Opt(_)), None) => ErrConv::None,
            (Some(Ty::Opt(_)), Some(_)) => {
                self.err(
                    Diag::new(
                        "E0248",
                        e.span,
                        format!(
                            "`?` on `{}` passes an error up, but this {what} returns an optional `{}`",
                            self.show(&t),
                            self.show(ret.as_ref().unwrap())
                        ),
                    )
                    .note("turn the error into a missing value with `x else none`... or make the function return `T!`"),
                );
                ErrConv::None
            }
            (Some(Ty::Res(..)), None) => {
                self.err(
                    Diag::new(
                        "E0249",
                        e.span,
                        format!("`?` on an optional `{}` in a {what} that returns `{}`", self.show(&t), self.show(ret.as_ref().unwrap())),
                    )
                    .note("a missing value isn't an error; say what went wrong with `x else fail(\"...\")`, or unwrap with `!`"),
                );
                ErrConv::None
            }
            (Some(r), _) => {
                let rs = self.show(r);
                let mut d = Diag::new(
                    "E0243",
                    e.span,
                    format!("`?` passes {} up, but this {what} returns `{rs}`", if err.is_some() { "an error" } else { "a missing value" }),
                );
                let ret_span = self.cxs.last().and_then(|c| c.frames.last()).and_then(|f| f.ret_span);
                let wrapped = if err.is_some() { format!("{rs}!") } else { format!("{rs}?") };
                if let Some(rs_span) = ret_span {
                    d = d.note(format!("make it return `{wrapped}`, or handle the value here with `else`")).fix(rs_span, wrapped);
                } else {
                    d = d.note(format!("declare the return type `{wrapped}`, or handle the value here with `else` or `!`"));
                }
                self.err(d);
                ErrConv::None
            }
        };
        self.cx().t.tries.insert(e.id, TryInfo { kind, conv });
        inner
    }

    fn bad_try(&mut self, e: &Expr, x: &Expr, t: &Ty) -> Ty {
        let ts = self.show(t);
        let mut d = Diag::new("E0250", e.span, format!("`?` needs a `T!`, `T?` or a list of them, but `{}` is `{ts}`", self.text(x.span)));
        if let Ty::Task(_) = self.shallow(t) {
            d = d
                .note("this is an un-awaited `async fn` call: `await` it first")
                .fix(Span { end_line: x.span.line, end_col: x.span.col, ..x.span }, "await ");
        } else {
            d = d.note("remove the `?`").fix(Span { line: e.span.end_line, col: e.span.end_col - 1, ..e.span }, "");
        }
        self.err(d);
        t.clone()
    }

    fn opt_chain(&mut self, e: &Expr, x: &Expr, name: &Ident, args: Option<&[Expr]>, exp: &Exp) -> Ty {
        let t = self.infer(x, None);
        let inner = match self.shallow(&t) {
            Ty::Opt(i) => *i,
            Ty::Error => return Ty::Error,
            Ty::Var(_) => return self.cant_infer(x.span, "the value before `?.`"),
            Ty::Res(..) => {
                let xt = self.text(x.span);
                let full = Span { end_line: name.span.line, end_col: name.span.col, ..x.span };
                self.err(
                    Diag::new("E0252", e.span, format!("`?.` works on `T?` only, but `{xt}` is `{}`", self.show(&t)))
                        .note("to pass the error up and then use the value, write `(x?).f`")
                        .fix(full, format!("({xt}?).")),
                );
                return Ty::Error;
            }
            _ => {
                self.err(
                    Diag::new("E0253", e.span, format!("`?.` needs an optional `T?`, but `{}` is `{}`", self.text(x.span), self.show(&t)))
                        .note("use `.` for a value that is always present")
                        .fix(Span { line: name.span.line, col: name.span.col - 2, end_line: name.span.line, end_col: name.span.col }, "."),
                );
                return Ty::Error;
            }
        };
        let member = match args {
            None => match name.tuple_index() {
                Some(index) => self.opt_tuple_elem(e, x, &inner, index),
                None => self.field_of(e, x, &inner, name),
            },
            Some(args) => {
                // the receiver's value is the unwrapped `inner`
                let direct = false;
                let mut all = vec![ArgSrc::Recv(x)];
                all.extend(args.iter().map(ArgSrc::Expr));
                // the receiver's recorded type is the optional; temporarily present the inner one
                let saved = self.cx().t.types.insert(x.id, inner.clone());
                let r = self.dot_call(e, x, &inner, name, &all, exp, direct);
                if let Some(s) = saved {
                    self.cx().t.types.insert(x.id, s);
                }
                if let Some(Call { args: a, .. }) = self.cx().t.calls.get(&e.id)
                    && a.first().is_some_and(|a| a.by_ref)
                {
                    self.err(Diag::new("E0253", e.span, format!("`?.{}` can't call a function that changes its receiver", name.name)));
                }
                r
            }
        };
        let flatten = matches!(self.shallow(&member), Ty::Opt(_));
        self.cx().t.opt_chains.insert(e.id, OptChainInfo { flatten });
        if flatten { member } else { Ty::opt(member) }
    }

    /// The element type of `x?.N`, `inner` being the type under `x`'s `?`.
    fn opt_tuple_elem(&mut self, e: &Expr, x: &Expr, inner: &Ty, index: u32) -> Ty {
        match self.shallow(inner) {
            Ty::Tuple(ts) if (index as usize) < ts.len() => ts[index as usize].clone(),
            Ty::Tuple(ts) => {
                self.err(
                    Diag::new("E0223", e.span, format!("the tuple `{}` has no element {index}", self.show(inner)))
                        .note(format!("it has {} element(s), numbered from 0", ts.len())),
                );
                Ty::Error
            }
            Ty::Error => Ty::Error,
            Ty::Var(_) => self.cant_infer(x.span, "the tuple"),
            _ => {
                let t = Ty::opt(inner.clone());
                self.err(Diag::new("E0223", e.span, format!("`?.{index}` needs an optional tuple, found `{}`", self.show(&t))));
                Ty::Error
            }
        }
    }

    fn else_expr(&mut self, e: &Expr, x: &Expr, arm: &ElseArm, exp: &Exp) -> Ty {
        let vals = exp.ty().map(|t| self.value_cands(t)).unwrap_or_default();
        let hints = self.wrap_hints(&vals);
        let t = self.expr(x, hints.map_or(Exp::None, Exp::Hints));
        let (kind, inner, err) = match self.shallow(&t) {
            Ty::Opt(i) => (ElseKind::Option, *i, None),
            Ty::Res(i, er) => (ElseKind::Result, *i, Some(*er)),
            Ty::Error => {
                self.infer(&arm.body, None);
                return Ty::Error;
            }
            Ty::Var(_) => return self.cant_infer(x.span, "the value before `else`"),
            other => {
                let s = self.defs.show(&self.resolve(&other));
                self.err(
                    Diag::new("E0255", e.span, format!("`else` handles a missing value or an error, but `{}` is a plain `{s}`", self.text(x.span)))
                        .note("remove the `else` part"),
                );
                self.infer(&arm.body, None);
                return other;
            }
        };
        self.push_scope();
        let binder = self.else_binder(arm, err.as_ref());
        match exp.want() {
            Some((_, tail)) => {
                // the result is `inner` (then converted to the expected type); the fallback must be
                // an `inner`. Pin an unsolved `inner` to the expected value type, unwrapped first.
                for v in &vals {
                    if self.try_unify(&inner, v) {
                        break;
                    }
                }
                self.check_mode(&arm.body, &inner, tail);
            }
            None => {
                self.check(&arm.body, &inner);
            }
        }
        self.pop_scope();
        self.cx().t.elses.insert(e.id, ElseInfo { kind, binder });
        inner
    }

    /// The value types an `x else y` / `x!` may have when `want` is expected: the value is
    /// converted to `want` afterwards, so for `want = T?` or `T!` a plain `T` comes first, then
    /// `want` itself (`T??` handled down to `T?`).
    fn value_cands(&self, want: &Ty) -> Vec<Ty> {
        let w = self.shallow(want);
        match &w {
            Ty::Var(_) => Vec::new(),
            Ty::Opt(i) | Ty::Res(i, _) => vec![(**i).clone(), w.clone()],
            _ => vec![w],
        }
    }

    /// Hints for the operand of `else` / `!` / `?`: `V?` or `V!` for each candidate value type `V`.
    fn wrap_hints(&mut self, vals: &[Ty]) -> Option<Vec<Ty>> {
        if vals.is_empty() {
            return None;
        }
        let mut hints = Vec::new();
        for v in vals {
            hints.push(Ty::opt(v.clone()));
            let ev = self.fresh();
            hints.push(Ty::res(v.clone(), ev));
        }
        Some(hints)
    }

    fn else_binder(&mut self, arm: &ElseArm, err: Option<&Ty>) -> Option<LocalId> {
        let b = arm.binder.as_ref()?;
        match err {
            Some(et) => {
                let l = self.new_local(&b.name, et.clone(), false, b.span);
                self.scope_insert(&b.name, l);
                Some(l)
            }
            None => {
                self.err(
                    Diag::new("E0254", b.span, format!("`else {} =>` binds an error, but the value is optional (`T?`), so there is none", b.name))
                        .note("write `else fallback`")
                        .fix(Span { end_line: arm.body.span.line, end_col: arm.body.span.col, ..b.span }, ""),
                );
                None
            }
        }
    }

    fn await_expr(&mut self, e: &Expr, x: &Expr) -> Ty {
        let call_like = matches!(x.kind, K::Call { .. } | K::MethodCall { .. } | K::Pipe { .. });
        if call_like {
            self.cx().direct_await = true;
        }
        let t = self.infer(x, None);
        self.cx().direct_await = false;
        if self.cx().t.awaits.get(&x.id) == Some(&AwaitKind::Direct) {
            self.cx().t.awaits.remove(&x.id);
            self.cx().t.awaits.insert(e.id, AwaitKind::Direct);
            return t;
        }
        let (kind, out) = match self.shallow(&t) {
            Ty::Task(r) => (AwaitKind::Task, *r),
            Ty::Tuple(ts) if !ts.is_empty() => {
                let mut outs = Vec::new();
                for t in &ts {
                    match self.shallow(t) {
                        Ty::Task(r) => outs.push(*r),
                        _ => return self.bad_await(e, x, &Ty::Tuple(ts.clone())),
                    }
                }
                (AwaitKind::Tuple, Ty::Tuple(outs))
            }
            Ty::List(el) => match self.shallow(&el) {
                Ty::Task(r) => (AwaitKind::List, Ty::list(*r)),
                _ => return self.bad_await(e, x, &t),
            },
            Ty::Error => return Ty::Error,
            _ => return self.bad_await(e, x, &t),
        };
        self.cx().t.awaits.insert(e.id, kind);
        out
    }

    fn bad_await(&mut self, e: &Expr, x: &Expr, t: &Ty) -> Ty {
        let ts = self.show(t);
        self.err(
            Diag::new(
                "E0331",
                e.span,
                format!("`await` needs an `async fn` call, a task, a tuple of tasks or a list of tasks, but `{}` is `{ts}`", self.text(x.span)),
            )
            .note("only calls of `async fn`s produce tasks; remove the `await`")
            .fix(Span { end_line: x.span.line, end_col: x.span.col, ..e.span }, ""),
        );
        t.clone()
    }

    /// `await any ts`: `(index, T!)` for a list of `Task<T>` (a `T!`/`T!E` result stays as is, as
    /// `T!`); a task's panic is the `Err` instead of being raised.
    fn await_any_expr(&mut self, e: &Expr, x: &Expr) -> Ty {
        let t = self.infer(x, None);
        let el = match self.shallow(&t) {
            Ty::List(el) => match self.shallow(&el) {
                Ty::Task(r) => *r,
                Ty::Error => return Ty::Error,
                _ => return self.bad_await_any(e, x, &t),
            },
            Ty::Error => return Ty::Error,
            _ => return self.bad_await_any(e, x, &t),
        };
        let err = Ty::Named(self.b.err, Vec::new());
        let r = match self.shallow(&el) {
            Ty::Res(ok, _) => Ty::res(*ok, err),
            other => Ty::res(other, err),
        };
        Ty::Tuple(vec![Ty::Int, r])
    }

    fn bad_await_any(&mut self, e: &Expr, x: &Expr, t: &Ty) -> Ty {
        let ts = self.show(t);
        self.err(
            Diag::new("E0331", e.span, format!("`await any` needs a list of tasks, but `{}` is `{ts}`", self.text(x.span)))
                .note("build the list from `async fn` calls without `await`: `var ts = [a(), b()]`, then `await any ts`"),
        );
        Ty::Error
    }

    // ---- `catch` ----

    /// `catch x`: x's value as `T!`, where a panic while evaluating it becomes an `Err`. The
    /// body runs in a function of its own (the runtime's recovery point needs a frame), checked
    /// like a closure `() => x` returning `T!`: `?` and `fail` inside it end the `catch` with that
    /// error. It captures by reference, so it may change the variables it uses.
    fn catch_expr(&mut self, e: &Expr, x: &Expr) -> Ty {
        let ok = self.fresh();
        let ret = Ty::res(ok, Ty::Named(self.b.err, Vec::new()));
        self.push_scope();
        self.push_frame(Frame {
            ret: Some(ret.clone()),
            ret_span: None,
            scope_base: 0,
            captures: Vec::new(),
            loops: Vec::new(),
            is_closure: true,
            by_ref: true,
            ret_insert: None,
            what: "catch",
        });
        self.check(x, &ret);
        let frame = self.pop_frame();
        self.pop_scope();
        self.cx().t.closures.insert(e.id, ClosureInfo { params: Vec::new(), ret: ret.clone(), captures: frame.captures, unpack: false });
        ret
    }

    // ---- closures ----

    fn closure(&mut self, e: &Expr, params: &[ast::Param], body: &Expr, exp: &Exp) -> Ty {
        let expected = match exp.ty().map(|t| self.shallow(t)) {
            Some(Ty::Fn(ps, r)) => Some((ps, *r)),
            Some(v @ Ty::Var(_)) => {
                let ps: Vec<Ty> = params.iter().map(|_| self.fresh()).collect();
                let r = self.fresh();
                self.unify(&v, &Ty::func(ps.clone(), r.clone()));
                Some((ps, r))
            }
            _ => None,
        };
        let mut unpack = false;
        let mut elem_tys: Option<Vec<Ty>> = None;
        if let Some((ps, _)) = &expected
            && ps.len() == 1
            && params.len() > 1
            && let Ty::Tuple(ts) = self.shallow(&ps[0])
            && ts.len() == params.len()
        {
            unpack = true;
            elem_tys = Some(ts);
        }
        let arity_mismatch = expected.as_ref().is_some_and(|(ps, _)| !unpack && ps.len() != params.len());
        if arity_mismatch
            && let Some((ps, _)) = &expected
        {
            self.err(
                Diag::new("E0204", e.span, format!("this closure takes {} parameter(s), but {} are expected here", params.len(), ps.len()))
                    .note(format!("the expected function type is `{}`", self.show(&Ty::func(ps.clone(), expected.as_ref().unwrap().1.clone())))),
            );
        }
        let m = self.cur_module();
        let mut ptys = Vec::new();
        for (i, p) in params.iter().enumerate() {
            let from_exp = match (&elem_tys, &expected) {
                (Some(ts), _) => ts.get(i).cloned(),
                (None, Some((ps, _))) => ps.get(i).cloned(),
                _ => None,
            };
            let t = match &p.ty {
                Some(ann) => {
                    let mut g = self.cx().generics.clone();
                    let t = self.resolve_type(m, ann, &mut g);
                    if let Some(x) = &from_exp
                        && !self.unify(&t, x)
                    {
                        let (ts, xs) = (self.show(&t), self.show(x));
                        self.err(
                            Diag::new("E0200", ann.span, format!("this closure parameter is declared `{ts}`, but `{xs}` is passed here"))
                                .fix(ann.span, xs),
                        );
                    }
                    t
                }
                None => from_exp.unwrap_or_else(|| self.fresh()),
            };
            ptys.push(t);
        }
        let ret = expected.as_ref().map(|(_, r)| r.clone()).unwrap_or_else(|| self.fresh());
        self.push_scope();
        self.push_frame(Frame {
            ret: Some(ret.clone()),
            ret_span: None,
            scope_base: 0,
            captures: Vec::new(),
            loops: Vec::new(),
            is_closure: true,
            by_ref: false,
            ret_insert: None,
            what: "closure",
        });
        let mut seen = HashMap::new();
        for (p, t) in params.iter().zip(&ptys) {
            self.cx().t.types.insert(p.id, t.clone());
            self.pattern(&p.pat, t, false, &mut seen);
        }
        self.check(body, &ret);
        let frame = self.pop_frame();
        self.pop_scope();
        self.cx().t.closures.insert(e.id, ClosureInfo { params: ptys.clone(), ret: ret.clone(), captures: frame.captures.clone(), unpack });
        // captures of a nested closure are captures of the enclosing closure too (handled by
        // lookup_local walking every frame)
        // E0204 already reported the arity mismatch: don't let the caller report it again as E0200
        if arity_mismatch {
            return Ty::Error;
        }
        let fparams = if unpack { vec![Ty::Tuple(ptys)] } else { ptys };
        Ty::func(fparams, ret)
    }

    // ---- control flow ----

    fn block(&mut self, b: &Block, exp: &Exp) -> Ty {
        self.push_scope();
        let n = b.stmts.len();
        let mut out = Ty::unit();
        if n == 0 {
            if let Some((w, tail)) = exp.want() {
                let w = w.clone();
                let mut cs = Vec::new();
                if !self.coerce_ty(&Ty::unit(), &w, &mut cs, b.span) {
                    let e = Expr { id: b.id, span: b.span, kind: K::Tuple(Vec::new()) };
                    self.mismatch(&e, &Ty::unit(), &w, tail);
                }
                for c in cs {
                    self.add_coercion(b.id, c);
                }
                out = w;
            }
            self.pop_scope();
            return out;
        }
        for (i, s) in b.stmts.iter().enumerate() {
            if i + 1 < n {
                let t = self.stmt(s, true);
                if matches!(self.shallow(&t), Ty::Never) && !matches!(s.kind, K::Let { .. }) {
                    // unreachable code after a diverging statement is allowed (patterns.rs may warn)
                }
                continue;
            }
            let stmt_like = matches!(s.kind, K::Let { .. } | K::Assign { .. } | K::Assert(_) | K::While { .. } | K::For { .. });
            out = match exp {
                Exp::Discard => {
                    self.stmt(s, true);
                    Ty::unit()
                }
                _ if stmt_like => {
                    self.stmt(s, true);
                    if let Some((w, tail)) = exp.want() {
                        let w = w.clone();
                        self.coerce_at(s, &Ty::unit(), &w, tail);
                        w
                    } else {
                        Ty::unit()
                    }
                }
                Exp::Check(w) => {
                    let w = w.clone();
                    self.check_mode(s, &w, false);
                    w
                }
                Exp::Tail(w) => {
                    let w = w.clone();
                    self.check_mode(s, &w, true);
                    w
                }
                other => self.expr(s, other.clone()),
            };
        }
        self.pop_scope();
        out
    }

    fn if_expr(&mut self, cond: &Expr, then: &Block, els: Option<&Expr>, exp: &Exp) -> Ty {
        self.check(cond, &Ty::Bool);
        let Some(els) = els else {
            self.block(then, &Exp::Discard);
            if let Some((w, tail)) = exp.want() {
                let w = w.clone();
                let mut cs = Vec::new();
                if !self.coerce_ty(&Ty::unit(), &w, &mut cs, then.span) {
                    let ws = self.show(&w);
                    self.err(
                        Diag::new("E0205", cond.span, format!("an `if` without `else` has no value, but a `{ws}` is expected here"))
                            .note("add an `else` branch"),
                    );
                    let _ = tail;
                    return w;
                }
                // its value is `()`; the caller (`check`/`check_mode`) records the conversion to
                // `w` (auto-wrap into `()!` / `()?`) on this node
                return Ty::unit();
            }
            return Ty::unit();
        };
        match exp {
            Exp::Discard => {
                self.block(then, &Exp::Discard);
                self.stmt(els, true);
                Ty::unit()
            }
            Exp::Check(w) | Exp::Tail(w) => {
                // a mismatch in one branch doesn't mean the return type is wrong: no `Tail`
                let w = w.clone();
                self.block(then, &Exp::Check(w.clone()));
                self.check_mode(els, &w, false);
                w
            }
            _ => {
                let tt = self.block(then, exp);
                if matches!(self.shallow(&tt), Ty::Never) {
                    return self.expr(els, exp.clone());
                }
                self.check(els, &tt);
                tt
            }
        }
    }

    fn match_expr(&mut self, scrut: &Expr, arms: &[ast::Arm], exp: &Exp) -> Ty {
        let st = self.infer(scrut, None);
        let mut result: Option<Ty> = exp.want().map(|(w, _)| w.clone());
        for a in arms {
            self.push_scope();
            let mut seen = HashMap::new();
            self.pattern(&a.pat, &st, false, &mut seen);
            if let Some(g) = &a.guard {
                self.guard(g);
            }
            match exp {
                Exp::Discard => {
                    self.stmt(&a.body, true);
                }
                Exp::Check(w) | Exp::Tail(w) => {
                    let w = w.clone();
                    self.check_mode(&a.body, &w, false);
                }
                _ => match &result {
                    Some(r) => {
                        let r = r.clone();
                        self.check(&a.body, &r);
                    }
                    None => {
                        let t = self.expr(&a.body, exp.clone());
                        if !matches!(self.shallow(&t), Ty::Never) {
                            result = Some(t);
                        }
                    }
                },
            }
            self.pop_scope();
        }
        match exp {
            Exp::Discard => Ty::unit(),
            _ => result.unwrap_or(Ty::Never),
        }
    }

    fn push_loop(&mut self, is_loop: bool, break_ty: Ty) {
        let f = self.cx().frames.last_mut().expect("frame");
        f.loops.push(LoopCx { is_loop, break_ty, saw_break: false });
    }

    fn pop_loop(&mut self) -> LoopCx {
        self.cx().frames.last_mut().unwrap().loops.pop().unwrap()
    }

    fn in_loop(&self) -> bool {
        self.cxs.last().and_then(|c| c.frames.last()).is_some_and(|f| !f.loops.is_empty())
    }

    fn break_expr(&mut self, e: &Expr, x: Option<&Expr>) {
        let Some(l) = self.cxs.last().and_then(|c| c.frames.last()).and_then(|f| f.loops.last()).cloned() else {
            self.err(
                Diag::new("E0244", e.span, "`break` outside a loop")
                    .note("`break` ends the innermost `loop`, `while` or `for` of this function (not of an enclosing one, from inside a closure)"),
            );
            if let Some(x) = x {
                self.infer(x, None);
            }
            return;
        };
        match x {
            Some(x) if l.is_loop => {
                self.check(x, &l.break_ty);
            }
            Some(x) => {
                self.err(
                    Diag::new("E0245", x.span, "only `loop` can `break` with a value")
                        .note("a `while` or `for` loop has no value; write `break`")
                        .fix(Span { line: e.span.line, col: e.span.col + 5, ..e.span }, ""),
                );
                self.infer(x, None);
            }
            None if l.is_loop => {
                let bt = l.break_ty.clone();
                let mut cs = Vec::new();
                if !self.coerce_ty(&Ty::unit(), &bt, &mut cs, e.span) {
                    let bs = self.show(&bt);
                    self.err(
                        Diag::new("E0245", e.span, format!("this `loop` has a value of type `{bs}`, so `break` needs one"))
                            .note("write `break value`"),
                    );
                }
                // a bare `break` is `break ()`: record its auto-wrap (into `()!` / `()?`)
                for c in cs {
                    self.add_coercion(e.id, c);
                }
            }
            None => {}
        }
        let f = self.cx().frames.last_mut().unwrap();
        f.loops.last_mut().unwrap().saw_break = true;
    }

    fn for_expr(&mut self, e: &Expr, index: Option<&Pat>, pat: &Pat, iter: &Expr, body: &Block) {
        self.push_scope();
        let mut seen = HashMap::new();
        if let K::Range { lo, hi, inclusive } = &iter.kind {
            self.check(lo, &Ty::Int);
            self.check(hi, &Ty::Int);
            self.record(iter.id, &Ty::list(Ty::Int));
            if let Some(ix) = index {
                self.err(Diag::new("E0207", ix.span, "a range loop has no separate index").note("write `for i in a..b`"));
            }
            self.pattern(pat, &Ty::Int, false, &mut seen);
            self.cx().t.fors.insert(e.id, ForKind::Range { inclusive: *inclusive });
        } else {
            let t = self.infer(iter, None);
            match self.shallow(&t) {
                Ty::List(el) => {
                    if let Some(ix) = index {
                        self.pattern(ix, &Ty::Int, false, &mut seen);
                    }
                    self.pattern(pat, &el, false, &mut seen);
                    self.cx().t.fors.insert(e.id, ForKind::List);
                }
                Ty::Map(k, v) => {
                    match index {
                        Some(ix) => {
                            self.pattern(ix, &k, false, &mut seen);
                            self.pattern(pat, &v, false, &mut seen);
                        }
                        None => self.pattern(pat, &Ty::Tuple(vec![*k, *v]), false, &mut seen),
                    }
                    self.cx().t.fors.insert(e.id, ForKind::Map);
                }
                Ty::Named(dd, args) if args.len() == 1 && self.defs.types[dd].name == "Chan" && self.prog.is_core(self.defs.types[dd].module) => {
                    if let Some(ix) = index {
                        self.err(Diag::new("E0207", ix.span, "a channel loop has no index").note("write `for x in c`"));
                    }
                    self.pattern(pat, &args[0], false, &mut seen);
                    self.cx().t.fors.insert(e.id, ForKind::Chan);
                }
                Ty::Error => {
                    if let Some(ix) = index {
                        self.pattern(ix, &Ty::Error, false, &mut seen);
                    }
                    self.pattern(pat, &Ty::Error, false, &mut seen);
                }
                other => {
                    let s = self.defs.show(&self.resolve(&other));
                    let mut d =
                        Diag::new("E0207", iter.span, format!("can't loop over a `{s}`")).note("`for` loops over a list, a map or a range `a..b`");
                    if matches!(other, Ty::Str) {
                        let text = self.text(iter.span);
                        let postfix = matches!(
                            iter.kind,
                            K::Lit(_) | K::Interp(_) | K::Name(_) | K::Field { .. } | K::TupleField { .. } | K::Call { .. } | K::MethodCall { .. } | K::Index { .. } | K::Slice { .. }
                        );
                        let chars = if postfix { format!("{text}.chars()") } else { format!("({text}).chars()") };
                        d = d.note(format!("a `str` is not iterable; loop over its chars with `for c in {chars}`"));
                        d = if postfix { d.fix(iter.span.after(), ".chars()") } else { d.fix(iter.span, chars) };
                        self.err(d);
                        // the body checks as it will after the fix: `c` is a `char`
                        if let Some(ix) = index {
                            self.pattern(ix, &Ty::Int, false, &mut seen);
                        }
                        self.pattern(pat, &Ty::Char, false, &mut seen);
                        self.push_loop(false, Ty::unit());
                        self.block(body, &Exp::Discard);
                        self.pop_loop();
                        self.pop_scope();
                        return;
                    } else if matches!(other, Ty::Opt(_) | Ty::Res(..)) {
                        d = d.note("unwrap it first with `?`").fix(iter.span.after(), "?");
                    }
                    self.err(d);
                    if let Some(ix) = index {
                        self.pattern(ix, &Ty::Error, false, &mut seen);
                    }
                    self.pattern(pat, &Ty::Error, false, &mut seen);
                }
            }
        }
        self.push_loop(false, Ty::unit());
        self.block(body, &Exp::Discard);
        self.pop_loop();
        self.pop_scope();
    }

    fn let_stmt(&mut self, e: &Expr, mutable: bool, pat: &Pat, ann: Option<&ast::Type>, value: &Expr, els: Option<&ElseArm>) {
        let m = self.cur_module();
        let ann_ty = ann.map(|t| {
            let mut g = self.cx().generics.clone();
            self.resolve_type(m, t, &mut g)
        });
        let before = self.tables[m].locals.len();
        let kw = Span { end_line: e.span.line, end_col: e.span.col + 3, ..e.span };
        let Some(arm) = els else {
            let t = match &ann_ty {
                Some(t) => self.check(value, t),
                None => self.infer(value, None),
            };
            self.check_unawaited_let(value, &t);
            let mut seen = HashMap::new();
            self.pattern(pat, &t, mutable, &mut seen);
            self.mark_let_locals(before, kw, mutable);
            return;
        };
        // `let pat = value else ...`: either `value` is `T?`/`T!` and the `else` handles the
        // missing value or error (the pattern then matches the `T`), or the pattern is refutable
        // and the `else` handles a non-match.
        let wrapper_pat = matches!(pat.kind, PatKind::Some(_) | PatKind::None | PatKind::Ok(_) | PatKind::Err(_));
        let hints = ann_ty.as_ref().map(|t| {
            let ev = self.fresh();
            vec![Ty::opt(t.clone()), Ty::res(t.clone(), ev)]
        });
        let t = self.expr(value, hints.map_or(Exp::None, Exp::Hints));
        let ts = self.shallow(&t);
        let refutable = !self.irrefutable(pat);
        let (kind, inner, err) = match (&ts, wrapper_pat) {
            (Ty::Opt(i), false) => (if refutable { ElseKind::UnwrapRefutable { option: true } } else { ElseKind::Option }, (**i).clone(), None),
            (Ty::Res(i, er), false) => {
                (if refutable { ElseKind::UnwrapRefutable { option: false } } else { ElseKind::Result }, (**i).clone(), Some((**er).clone()))
            }
            _ => {
                if !refutable && !matches!(ts, Ty::Error) {
                    let s = self.show(&t);
                    self.err(
                        Diag::new(
                            "E0255",
                            e.span,
                            format!("this `let` always succeeds: `{}` is a plain `{s}` and the pattern always matches", self.text(value.span)),
                        )
                        .note("remove the `else` part")
                        .fix(Span { line: value.span.end_line, col: value.span.end_col, ..arm.body.span }, ""),
                    );
                    self.infer(&arm.body, None);
                    let mut seen = HashMap::new();
                    self.pattern(pat, &t, mutable, &mut seen);
                    self.mark_let_locals(before, kw, mutable);
                    return;
                }
                (ElseKind::Refutable, t.clone(), None)
            }
        };
        if let Some(a) = &ann_ty
            && !self.unify(&inner, a)
        {
            let (is, as_) = (self.show(&inner), self.show(a));
            self.err(Diag::new("E0200", value.span, format!("expected `{as_}`, found `{is}`")));
        }
        // the else arm: no bindings of the pattern are visible in it
        self.push_scope();
        let binder = self.else_binder(arm, err.as_ref());
        let diverge_only = matches!(kind, ElseKind::Refutable | ElseKind::UnwrapRefutable { .. });
        if diverge_only {
            let bt = self.infer(&arm.body, None);
            let b = self.shallow(&bt);
            if !matches!(b, Ty::Never | Ty::Error) {
                let s = self.show(&bt);
                self.err(
                    Diag::new("E0240", arm.body.span, format!("the `else` of a refutable `let` must leave the block (return, break, continue or fail), but this is a `{s}`"))
                        .note("when the pattern doesn't match there are no values to bind, so the `else` can't provide a fallback; write `else { return ... }` or use a `match`"),
                );
            }
        } else {
            self.check(&arm.body, &inner);
        }
        self.pop_scope();
        let mut seen = HashMap::new();
        self.pattern(pat, &inner, mutable, &mut seen);
        self.mark_let_locals(before, kw, mutable);
        self.cx().t.elses.insert(e.id, ElseInfo { kind, binder });
    }

    fn check_unawaited_let(&mut self, _value: &Expr, _t: &Ty) {
        // storing a task in a variable is allowed ("awaited, stored or returned")
    }

    /// Remember how to make the locals of a `let` mutable (for the E0320 fix-it).
    fn mark_let_locals(&mut self, before: usize, kw: Span, mutable: bool) {
        if mutable {
            return;
        }
        let m = self.cur_module();
        let after = self.tables[m].locals.len();
        for l in before..after {
            self.let_fixes.insert((m, l), kw);
        }
    }

    /// A pattern that matches every value of its type (no exhaustiveness needed).
    pub fn irrefutable(&self, p: &Pat) -> bool {
        let m = self.cur_module();
        match &p.kind {
            PatKind::Wild => true,
            PatKind::Bind(n) => self.variants_in_scope(m, n).is_empty() || self.cxs.last().and_then(|c| c.t.binds.get(&p.id)).is_some(),
            PatKind::Tuple(ps) => ps.iter().all(|p| self.irrefutable(p)),
            PatKind::Struct { fields, .. } => fields.iter().all(|f| f.pat.as_ref().is_none_or(|p| self.irrefutable(p))),
            _ => false,
        }
    }

    fn assign(&mut self, e: &Expr, op: Option<BinOp>, target: &Expr, value: &Expr) {
        let t = self.place(target, true, PlaceUse::Assign);
        match op {
            None => {
                self.check(value, &t);
            }
            Some(op @ (BinOp::BitAnd | BinOp::BitOr | BinOp::BitXor | BinOp::Shl | BinOp::Shr)) => {
                let sym = format!("{}=", op.symbol());
                let ok = self.bit_operand(target, &t, &sym, false);
                let rt = self.infer(value, Some(&Ty::Int));
                if ok {
                    self.bit_operand(value, &rt, &sym, true);
                }
            }
            Some(op) => {
                let ts = self.shallow(&t);
                let ok = match op {
                    BinOp::Add => matches!(ts, Ty::Int | Ty::Float | Ty::Str | Ty::List(_)),
                    _ => matches!(ts, Ty::Int | Ty::Float),
                };
                if matches!(ts, Ty::Int | Ty::Float | Ty::Measured(..)) {
                    // units: `d += x` needs `x` in `d`'s unit, `d *= 2.0` keeps it
                    let scale = matches!(op, BinOp::Mul | BinOp::Div);
                    let hint = if scale { ts.base().clone() } else { t.clone() };
                    let rt = self.infer(value, Some(&hint));
                    if matches!(ts, Ty::Measured(..)) || matches!(self.shallow(&rt), Ty::Measured(..)) {
                        let r = self.unit_operands(e, op, target, value, &t, &rt);
                        if !r.has_error() && !self.unify(&r, &t) {
                            self.mismatch(e, &r, &t, false);
                        }
                    } else {
                        self.operand_with(value, &t, &rt, op, target);
                    }
                } else if ok {
                    self.check_operand(value, &t, op, target);
                } else if matches!(ts, Ty::Named(..)) {
                    let fname = match op {
                        BinOp::Add => "add",
                        BinOp::Sub => "sub",
                        BinOp::Mul => "mul",
                        BinOp::Div => "div",
                        _ => "mod",
                    };
                    let cands = self.method_cands(fname, &t, 2);
                    if let Some(&f) = cands.first() {
                        let (s, targs) = self.instantiate(f);
                        let info = self.fns[f].clone();
                        self.unify(&info.params[0].ty.subst(&s), &t);
                        self.check(value, &info.params[1].ty.subst(&s));
                        let r = info.ret.subst(&s);
                        if !self.unify(&r, &t) {
                            self.mismatch(e, &r, &t, false);
                        }
                        self.note_call(
                            e.id,
                            Call {
                                callee: Callee::Fn { func: f, type_args: targs },
                                args: vec![Arg { node: target.id, by_ref: false }, Arg { node: value.id, by_ref: false }],
                            },
                        );
                    } else {
                        let s = self.show(&t);
                        self.err(
                            Diag::new("E0261", e.span, format!("`{}=` isn't defined for `{s}`", op.symbol()))
                                .note(format!("define `fn {fname}(a: {s}, b: {s}): {s}`")),
                        );
                        self.infer(value, None);
                    }
                } else if !matches!(ts, Ty::Error) {
                    let s = self.show(&t);
                    self.err(Diag::new("E0260", e.span, format!("can't apply `{}=` to `{s}`", op.symbol())));
                    self.infer(value, None);
                }
            }
        }
    }

    // ---- struct literals ----

    fn struct_lit(&mut self, e: &Expr, path: &[Ident], fields: &[ast::FieldInit], base: Option<&Expr>, exp: &Exp) -> Ty {
        let m = self.cur_module();
        let d = match self.lookup_type_path(m, path) {
            Some(TypeItem::Def(d)) if self.defs.is_struct(d) => d,
            other => {
                let name = path.iter().map(|i| i.name.clone()).collect::<Vec<_>>().join(".");
                let msg = match other {
                    Some(_) => format!("`{name}` is not a struct"),
                    None => format!("unknown struct `{name}`"),
                };
                let mut d = Diag::new("E0104", path[0].span.to(path[path.len() - 1].span), msg);
                let cands: Vec<String> = self.items[m].types.keys().cloned().collect();
                if let Some(s) = similar(&name, &cands) {
                    d = d.note(format!("did you mean `{s}`?")).fix(path[0].span.to(path[path.len() - 1].span), s);
                }
                self.err(d);
                for f in fields {
                    if let Some(v) = &f.value {
                        self.infer(v, None);
                    }
                }
                return Ty::Error;
            }
        };
        let (s, args) = self.instantiate_def(d);
        let ty = Ty::Named(d, args.clone());
        if let Some(h) = exp.ty() {
            let _ = self.try_unify(&ty, h);
        }
        let defs = self.defs.fields(d).to_vec();
        let foreign = self.defs.types[d].module != m;
        if foreign && !self.defs.types[d].public {
            self.err(Diag::new(
                "E0120",
                e.span,
                format!("the struct `{}` is private to module `{}`", self.defs.types[d].name, self.prog.name(self.defs.types[d].module)),
            ));
        }
        let mut out = Vec::new();
        let mut given = vec![false; defs.len()];
        for f in fields {
            let Some(i) = defs.iter().position(|x| x.name == f.name.name) else {
                let names: Vec<String> = defs.iter().map(|x| x.name.clone()).collect();
                let mut dg = Diag::new("E0225", f.name.span, format!("the struct `{}` has no field `{}`", self.defs.types[d].name, f.name.name))
                    .note(format!("its fields are: {}", names.join(", ")));
                if let Some(sim) = similar(&f.name.name, &names) {
                    dg = dg.fix(f.name.span, sim);
                }
                self.err(dg);
                if let Some(v) = &f.value {
                    self.infer(v, None);
                }
                continue;
            };
            if given[i] {
                self.err(Diag::new("E0225", f.name.span, format!("the field `{}` is given twice", f.name.name)));
            }
            given[i] = true;
            if foreign && !defs[i].public {
                self.err(
                    Diag::new("E0121", f.name.span, format!("the field `{}` of `{}` is private", f.name.name, self.defs.types[d].name))
                        .note("a struct with private fields can only be built in its own module; look for a constructor function"),
                );
            }
            let ft = defs[i].ty.subst(&s);
            match &f.value {
                Some(v) => {
                    self.check(v, &ft);
                    out.push((i, FieldValue::Expr(v.id)));
                }
                None => match self.lookup_local(&f.name.name) {
                    Some(l) => {
                        let lt = self.local_ty(l);
                        let mut cs = Vec::new();
                        if !self.coerce_ty(&lt, &ft, &mut cs, f.name.span) {
                            let (ls, fs) = (self.show(&lt), self.show(&ft));
                            self.err(Diag::new(
                                "E0200",
                                f.name.span,
                                format!("the field `{}` is a `{fs}`, but the variable `{}` is a `{ls}`", f.name.name, f.name.name),
                            ));
                        } else if cs.iter().any(|c| matches!(c, Coercion::ToAny(_))) {
                            // a conversion to `any S` needs a node for its vtable
                            let fs = self.show(&ft);
                            self.err(
                                Diag::new(
                                    "E0200",
                                    f.name.span,
                                    format!("the field `{}` is a `{fs}`; the shorthand can't convert the variable `{}` to it", f.name.name, f.name.name),
                                )
                                .note(format!("write the field out: `{}: {}`", f.name.name, f.name.name)),
                            );
                        }
                        out.push((i, FieldValue::Local(l, cs)));
                    }
                    None => {
                        self.err(
                            Diag::new(
                                "E0102",
                                f.name.span,
                                format!("`{}` (shorthand for `{}: {}`) is not a variable in scope", f.name.name, f.name.name, f.name.name),
                            )
                            .note(format!("write `{}: value`", f.name.name)),
                        );
                    }
                },
            }
        }
        match base {
            Some(b) => {
                self.check(b, &ty);
            }
            None => {
                let missing: Vec<String> = defs.iter().zip(&given).filter(|(_, g)| !**g).map(|(f, _)| f.name.clone()).collect();
                if !missing.is_empty() {
                    let list = missing.iter().map(|x| format!("`{x}`")).collect::<Vec<_>>().join(", ");
                    self.err(
                        Diag::new("E0224", e.span, format!("the struct literal is missing field(s) {list} of `{}`", self.defs.types[d].name))
                            .note("give every field a value, or copy the rest from another value with `..base`"),
                    );
                }
            }
        }
        self.cx().t.struct_lits.insert(e.id, StructLit { def: d, args, fields: out });
        ty
    }
}

/// Why a place is being changed (for messages).
#[derive(Clone, Copy)]
pub(crate) enum PlaceUse<'a> {
    Assign,
    Ref,
    Receiver(&'a str),
}

/// Parse `[fill? align] ['0'] [width] ['.' precision]`.
pub(crate) fn parse_format(spec: &str) -> Result<FormatSpec, String> {
    let cs: Vec<char> = spec.chars().collect();
    let mut i = 0;
    let (mut fill, mut align) = (None, None);
    let is_align = |c: char| matches!(c, '<' | '>' | '^');
    if cs.len() >= 2 && is_align(cs[1]) {
        fill = Some(cs[0]);
        align = Some(cs[1]);
        i = 2;
    } else if !cs.is_empty() && is_align(cs[0]) {
        align = Some(cs[0]);
        i = 1;
    }
    let mut zero = false;
    if i < cs.len() && cs[i] == '0' {
        zero = true;
        i += 1;
    }
    let num = |i: &mut usize| -> Option<usize> {
        let start = *i;
        while *i < cs.len() && cs[*i].is_ascii_digit() {
            *i += 1;
        }
        if *i == start { None } else { cs[start..*i].iter().collect::<String>().parse().ok() }
    };
    let width = num(&mut i);
    let mut precision = None;
    if i < cs.len() && cs[i] == '.' {
        i += 1;
        precision = num(&mut i);
        if precision.is_none() {
            return Err("`.` must be followed by the number of digits".into());
        }
    }
    if i != cs.len() {
        return Err(format!("unexpected `{}`", cs[i..].iter().collect::<String>()));
    }
    if spec.is_empty() {
        return Err("empty spec (remove the `:`)".into());
    }
    Ok(FormatSpec { text: spec.to_string(), fill, align, zero, width, precision })
}

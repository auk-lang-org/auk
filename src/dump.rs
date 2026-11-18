//! `auk dump tokens|ast <file>...`: a hidden command that prints the token stream or the syntax
//! tree of each file as stable, line-oriented text, every node with its span (and NodeId). These
//! dumps are the oracles the self-hosted front end (`compiler/`) is diffed against, so the
//! format is deliberately simple to reproduce: one node per line, children indented by two
//! spaces, strings escaped by `esc`, floats as their IEEE bits, chars as code points.
//!
//! `auk dump resolve <file>...` loads each file as `auk check` does (`resolve::load_in_package`)
//! and prints the module tree: packages, modules in load order with their children, each
//! non-core module's items with their full paths, and every dotted path in it whose first
//! segment names a module (`Program::first_segment`, then `child` per segment) with the module
//! it reaches; or the load's diagnostics. File names are relative to the current directory.
//!
//! `auk dump check <file>...` prints the `auk check --json` report of the type checker proper
//! (`check::check_types`: types, inference, overloading, shapes), without the later passes
//! (patterns.rs exhaustiveness, effects.rs). `auk dump typed [--core] <file>...` prints the
//! checker's errors and the typed program it produces (erased of units when there are no
//! errors, as `check::check` returns it): definitions, signatures, every node's facts from the
//! side tables, locals, instances with their resolved call targets, concrete types, shape
//! implementations and vtables (see `typed`). These are the oracles of the self-hosted checker.
//!
//! A file under a `prelude/` directory is parsed as a core prelude file (`extern` allowed).
//! For timing: `--quiet` lexes or parses without printing, `--repeat N` does the whole job N
//! times, and `--time` prints the time per repetition (file reading excluded) to stderr.

use std::fmt::Write;
use std::time::Instant;
use std::{fs, path::Path};

use super::ast::*;
use super::diag::{Diag, Span};
use super::lexer::lex;
use super::diag::FileDiag;
use super::parser;
use super::resolve::{self, ModId, Program};
use super::token::{StrPart, Tok, Token};
use super::check;
use super::ffi::Conv;
use super::typed::*;
use super::types::{Defs, DefId, ParamId, ShapeId, Ty, TypeDefKind};
use std::collections::{BTreeSet, HashMap};

pub fn run(args: &[String]) -> i32 {
    let (what, rest) = match args.split_first() {
        Some((w, rest)) if ["tokens", "ast", "resolve", "check", "typed"].contains(&w.as_str()) => (w.as_str(), rest),
        _ => {
            eprintln!("usage: auk dump tokens|ast|resolve|check|typed [--quiet] [--time] [--repeat N] [--core] <file>...");
            return 2;
        }
    };
    let quiet = rest.iter().any(|a| a == "--quiet");
    let time = rest.iter().any(|a| a == "--time");
    let core = rest.iter().any(|a| a == "--core");
    let repeat: u32 = match rest.iter().position(|a| a == "--repeat") {
        Some(i) => rest.get(i + 1).and_then(|n| n.parse().ok()).unwrap_or(1),
        None => 1,
    };
    let files: Vec<&String> =
        rest.iter().enumerate().filter(|(i, a)| !a.starts_with("--") && (*i == 0 || rest[i - 1] != "--repeat")).map(|(_, a)| a).collect();
    let mut srcs = Vec::new();
    for f in &files {
        match fs::read_to_string(f) {
            Ok(s) => srcs.push(s),
            Err(e) => {
                eprintln!("error: cannot read {f}: {e}");
                return 1;
            }
        }
    }
    let start = Instant::now();
    let mut out = String::new();
    for (f, src) in (0..repeat).flat_map(|_| files.iter().zip(&srcs)) {
        if files.len() > 1 && !quiet {
            let _ = writeln!(out, "== {f}");
        }
        if what == "check" || what == "typed" {
            let r = resolve::load_in_package(Path::new(f.as_str()), src.clone());
            if quiet {
                std::hint::black_box(r.map(check::check_types)).ok();
            } else if what == "check" {
                out.push_str(&checked(f, r));
            } else {
                typed_program(&mut out, r, core);
            }
        } else if what == "resolve" {
            let r = resolve::load_in_package(Path::new(f.as_str()), src.clone());
            if !quiet {
                resolved(&mut out, &r);
            } else {
                std::hint::black_box(r).ok();
            }
        } else if what == "tokens" {
            match lex(src) {
                Ok(lx) if !quiet => tokens(&mut out, lx.module_doc.as_deref(), &lx.toks),
                r => {
                    if let Err(d) = std::hint::black_box(r)
                        && !quiet
                    {
                        diag(&mut out, &d)
                    }
                }
            }
        } else {
            let prelude = Path::new(f).parent().and_then(|p| p.file_name()).is_some_and(|n| n == "prelude");
            let r = if prelude { parser::parse_prelude(src) } else { parser::parse(src) };
            match r {
                Ok(m) if !quiet => module(&mut out, &m),
                r => {
                    if let Err(ds) = std::hint::black_box(r)
                        && !quiet
                    {
                        ds.iter().for_each(|d| diag(&mut out, d))
                    }
                }
            }
        }
    }
    print!("{out}");
    if time {
        eprintln!("time: {} us", start.elapsed().as_micros() / u128::from(repeat.max(1)));
    }
    0
}

/// A string in double quotes: `\\ \" \n \t \r` escaped, other control chars as `\u{hex}`,
/// everything else as is.
pub fn esc(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            c if (c as u32) < 0x20 || c as u32 == 0x7f => {
                let _ = write!(out, "\\u{{{:x}}}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn sp(s: Span) -> String {
    format!("{}:{}-{}:{}", s.line, s.col, s.end_line, s.end_col)
}

fn line(out: &mut String, depth: usize, s: &str) {
    for _ in 0..depth {
        out.push_str("  ");
    }
    out.push_str(s);
    out.push('\n');
}

fn diag(out: &mut String, d: &Diag) {
    line(out, 0, &format!("error {} {} {}", d.code, sp(d.span), esc(&d.message)));
    for n in &d.notes {
        line(out, 1, &format!("note {}", esc(n)));
    }
    for f in &d.fixes {
        line(out, 1, &format!("fix {} {}", sp(f.span), esc(&f.text)));
    }
}

// ---- tokens ----

fn tokens(out: &mut String, module_doc: Option<&str>, toks: &[Token]) {
    if let Some(d) = module_doc {
        line(out, 0, &format!("module-doc {}", esc(d)));
    }
    toks_at(out, 0, toks);
}

fn toks_at(out: &mut String, depth: usize, toks: &[Token]) {
    for t in toks {
        let mut s = format!("{} {}", sp(t.span), tok_text(&t.tok));
        if t.space_before {
            s += " space";
        }
        if let Some(d) = &t.doc {
            s += &format!(" doc={}", esc(d));
        }
        line(out, depth, &s);
        if let Tok::Str(parts) = &t.tok {
            for p in parts {
                match p {
                    StrPart::Lit(l) => line(out, depth + 1, &format!("lit {}", esc(l))),
                    StrPart::Interp { toks, spec, span } => {
                        let spec = spec.as_ref().map(|s| format!(" spec={}", esc(s))).unwrap_or_default();
                        line(out, depth + 1, &format!("interp {}{spec}", sp(*span)));
                        toks_at(out, depth + 2, toks);
                    }
                }
            }
        }
    }
}

/// The token's kind (its variant name) and payload.
pub fn tok_text(t: &Tok) -> String {
    match t {
        Tok::Int(n) => format!("Int {n}"),
        Tok::Float(x) => format!("Float {}", x.to_bits() as i64),
        Tok::Char(c) => format!("Char {}", *c as u32),
        Tok::Str(_) => "Str".into(),
        Tok::Ident(s) => format!("Ident {}", esc(s)),
        Tok::Unit(s) => format!("Unit {}", esc(s)),
        t => format!("{t:?}"),
    }
}

// ---- syntax tree ----

fn module(out: &mut String, m: &Module) {
    if let Some(d) = &m.doc {
        line(out, 0, &format!("module-doc {}", esc(d)));
    }
    for item in &m.items {
        self::item(out, 0, item);
    }
}

fn id(i: &Ident) -> String {
    format!("{}@{}", i.name, sp(i.span))
}

fn doc(out: &mut String, d: usize, doc: &Option<String>) {
    if let Some(s) = doc {
        line(out, d, &format!("doc {}", esc(s)));
    }
}

fn vis(public: bool) -> &'static str {
    if public { " pub" } else { "" }
}

fn item(out: &mut String, d: usize, item: &Item) {
    match item {
        Item::Fn(g) => {
            line(out, d, &format!("fn {}/{}", g.name, g.arity));
            if let Some(h) = &g.header {
                clause(out, d + 1, "header", h);
            }
            for c in &g.clauses {
                clause(out, d + 1, "clause", c);
            }
        }
        Item::Struct(s) => {
            line(out, d, &format!("struct #{} {}{} {}", s.id, sp(s.span), vis(s.public), id(&s.name)));
            doc(out, d + 1, &s.doc);
            generics(out, d + 1, &s.generics);
            for f in &s.fields {
                line(out, d + 1, &format!("field {} {}", sp(f.span), id(&f.name)));
                doc(out, d + 2, &f.doc);
                ty(out, d + 2, &f.ty);
            }
        }
        Item::Enum(e) => {
            line(out, d, &format!("enum #{} {}{} {}", e.id, sp(e.span), vis(e.public), id(&e.name)));
            doc(out, d + 1, &e.doc);
            generics(out, d + 1, &e.generics);
            for v in &e.variants {
                line(out, d + 1, &format!("variant #{} {} {}", v.id, sp(v.span), id(&v.name)));
                doc(out, d + 2, &v.doc);
                for f in &v.fields {
                    line(out, d + 2, &match &f.name {
                        Some(n) => format!("vfield {}", id(n)),
                        None => "vfield".into(),
                    });
                    ty(out, d + 3, &f.ty);
                }
            }
        }
        Item::Shape(s) => {
            line(out, d, &format!("shape #{} {}{} {}", s.id, sp(s.span), vis(s.public), id(&s.name)));
            doc(out, d + 1, &s.doc);
            generics(out, d + 1, &s.generics);
            for m in &s.methods {
                clause(out, d + 1, "method", m);
            }
        }
        Item::Test(t) => {
            line(out, d, &format!("test #{} {} {}", t.id, sp(t.span), esc(&t.name)));
            doc(out, d + 1, &t.doc);
            block(out, d + 1, &t.body);
        }
        Item::Let(c) | Item::Imprint(c) => {
            let kw = if matches!(item, Item::Let(_)) { "let" } else { "imprint" };
            line(out, d, &format!("{kw} #{} {}{} {}", c.id, sp(c.span), vis(c.public), id(&c.name)));
            doc(out, d + 1, &c.doc);
            if let Some(t) = &c.ty {
                ty(out, d + 1, t);
            }
            expr(out, d + 1, &c.value);
        }
        Item::ExternType(t) => {
            line(out, d, &format!("extern-type #{} {}{} {} {}", t.id, sp(t.span), vis(t.public), id(&t.name), esc(&t.c_type)));
            doc(out, d + 1, &t.doc);
        }
    }
}

fn generics(out: &mut String, d: usize, gs: &[Generic]) {
    for g in gs {
        line(out, d, &format!("generic {}", id(&g.name)));
        for b in &g.bounds {
            ty(out, d + 1, b);
        }
    }
}

fn clause(out: &mut String, d: usize, tag: &str, c: &FnClause) {
    let asy = if c.is_async { " async" } else { "" };
    line(out, d, &format!("{tag} #{} {}{}{asy} {}", c.id, sp(c.span), vis(c.public), id(&c.name)));
    doc(out, d + 1, &c.doc);
    generics(out, d + 1, &c.generics);
    for p in &c.params {
        param(out, d + 1, p);
    }
    if let Some(t) = &c.ret {
        line(out, d + 1, "ret");
        ty(out, d + 2, t);
    }
    if !c.uses.is_empty() {
        line(out, d + 1, &format!("uses {}", c.uses.iter().map(id).collect::<Vec<_>>().join(" ")));
    }
    for e in &c.requires {
        line(out, d + 1, "requires");
        expr(out, d + 2, e);
    }
    for e in &c.ensures {
        line(out, d + 1, "ensures");
        expr(out, d + 2, e);
    }
    if let Some(g) = &c.guard {
        line(out, d + 1, "when");
        expr(out, d + 2, g);
    }
    match &c.body {
        Some(FnBody::Expr(e)) => {
            line(out, d + 1, "body =");
            expr(out, d + 2, e);
        }
        Some(FnBody::Block(b)) => {
            line(out, d + 1, "body");
            block(out, d + 2, b);
        }
        Some(FnBody::Extern(s)) => line(out, d + 1, &format!("extern {}", esc(s))),
        None => {}
    }
}

fn param(out: &mut String, d: usize, p: &Param) {
    line(out, d, &format!("param #{} {}{}", p.id, sp(p.span), if p.var { " var" } else { "" }));
    pat(out, d + 1, &p.pat);
    if let Some(t) = &p.ty {
        ty(out, d + 1, t);
    }
}

fn ty(out: &mut String, d: usize, t: &Type) {
    let head = format!("type #{} {}", t.id, sp(t.span));
    match &t.kind {
        TypeKind::Named { path, args } => {
            line(out, d, &format!("{head} named {}", path.iter().map(id).collect::<Vec<_>>().join(" ")));
            for a in args {
                ty(out, d + 1, a);
            }
        }
        TypeKind::List(e) => {
            line(out, d, &format!("{head} list"));
            ty(out, d + 1, e);
        }
        TypeKind::Map(k, v) => {
            line(out, d, &format!("{head} map"));
            ty(out, d + 1, k);
            ty(out, d + 1, v);
        }
        TypeKind::Tuple(ts) => {
            line(out, d, &format!("{head} tuple"));
            for t in ts {
                ty(out, d + 1, t);
            }
        }
        TypeKind::Optional(e) => {
            line(out, d, &format!("{head} optional"));
            ty(out, d + 1, e);
        }
        TypeKind::Fallible { ok, err } => {
            line(out, d, &format!("{head} fallible{}", if err.is_some() { " err" } else { "" }));
            ty(out, d + 1, ok);
            if let Some(e) = err {
                ty(out, d + 1, e);
            }
        }
        TypeKind::Any(e) => {
            line(out, d, &format!("{head} any"));
            ty(out, d + 1, e);
        }
        TypeKind::Fn { params, ret } => {
            line(out, d, &format!("{head} fn {}", params.len()));
            for p in params {
                ty(out, d + 1, p);
            }
            ty(out, d + 1, ret);
        }
        TypeKind::Measured { base, units } => {
            line(out, d, &format!("{head} measured {}", units_text(units)));
            ty(out, d + 1, base);
        }
        TypeKind::Var(t) => {
            line(out, d, &format!("{head} var"));
            ty(out, d + 1, t);
        }
    }
}

fn units_text(u: &super::units::Units) -> String {
    let parts: Vec<String> = u.0.iter().map(|(n, e)| format!("{n}:{e}")).collect();
    format!("[{}]", parts.join(" "))
}

fn lit(l: &Lit) -> String {
    match l {
        Lit::Int(n) => format!("int {n}"),
        Lit::Float(x) => format!("float {}", x.to_bits() as i64),
        Lit::Bool(b) => format!("bool {b}"),
        Lit::Char(c) => format!("char {}", *c as u32),
        Lit::Str(s) => format!("str {}", esc(s)),
    }
}

fn pat(out: &mut String, d: usize, p: &Pat) {
    let head = format!("pat #{} {}", p.id, sp(p.span));
    match &p.kind {
        PatKind::Wild => line(out, d, &format!("{head} _")),
        PatKind::Bind(n) => line(out, d, &format!("{head} bind {n}")),
        PatKind::Lit { lit: l, neg } => line(out, d, &format!("{head} lit{} {}", if *neg { " -" } else { "" }, lit(l))),
        PatKind::Tuple(ps) => {
            line(out, d, &format!("{head} tuple"));
            ps.iter().for_each(|p| pat(out, d + 1, p));
        }
        PatKind::List { head: h, rest, tail } => {
            line(out, d, &format!("{head} list"));
            h.iter().for_each(|p| pat(out, d + 1, p));
            if let Some(r) = rest {
                line(out, d + 1, &format!("rest {}", sp(r.span)));
                if let Some(p) = &r.pat {
                    pat(out, d + 2, p);
                }
                tail.iter().for_each(|p| pat(out, d + 1, p));
            }
        }
        PatKind::Variant { path, args } => {
            let a = if args.is_some() { " args" } else { "" };
            line(out, d, &format!("{head} variant {}{a}", path.iter().map(id).collect::<Vec<_>>().join(" ")));
            if let Some(a) = args {
                a.iter().for_each(|p| pat(out, d + 1, p));
            }
        }
        PatKind::Struct { path, fields, rest } => {
            let r = if *rest { " .." } else { "" };
            line(out, d, &format!("{head} struct {}{r}", path.iter().map(id).collect::<Vec<_>>().join(" ")));
            for f in fields {
                line(out, d + 1, &format!("field {}", id(&f.name)));
                if let Some(p) = &f.pat {
                    pat(out, d + 2, p);
                }
            }
        }
        PatKind::Map(es) => {
            line(out, d, &format!("{head} map"));
            for (k, v) in es {
                line(out, d + 1, &format!("key {}", lit(k)));
                pat(out, d + 2, v);
            }
        }
        PatKind::StrPrefix { prefix, rest } => {
            line(out, d, &format!("{head} prefix {}", esc(prefix)));
            pat(out, d + 1, rest);
        }
        PatKind::Some(p) => {
            line(out, d, &format!("{head} some"));
            pat(out, d + 1, p);
        }
        PatKind::None => line(out, d, &format!("{head} none")),
        PatKind::Ok(p) => {
            line(out, d, &format!("{head} ok"));
            pat(out, d + 1, p);
        }
        PatKind::Err(p) => {
            line(out, d, &format!("{head} err"));
            pat(out, d + 1, p);
        }
        PatKind::Or(ps) => {
            line(out, d, &format!("{head} or"));
            ps.iter().for_each(|p| pat(out, d + 1, p));
        }
    }
}

fn block(out: &mut String, d: usize, b: &Block) {
    line(out, d, &format!("block #{} {}", b.id, sp(b.span)));
    for s in &b.stmts {
        expr(out, d + 1, s);
    }
}

fn else_arm(out: &mut String, d: usize, a: &ElseArm) {
    line(out, d, &match &a.binder {
        Some(b) => format!("else {}", id(b)),
        None => "else".into(),
    });
    expr(out, d + 1, &a.body);
}

fn exprs(out: &mut String, d: usize, es: &[Expr]) {
    for e in es {
        expr(out, d, e);
    }
}

fn expr(out: &mut String, d: usize, e: &Expr) {
    let head = format!("#{} {}", e.id, sp(e.span));
    let mut l = |s: String| line(out, d, &format!("{head} {s}"));
    match &e.kind {
        ExprKind::Lit(x) => l(lit(x)),
        ExprKind::Measured { expr: x, units } => {
            l(format!("measured {}", units_text(units)));
            expr(out, d + 1, x);
        }
        ExprKind::Interp(parts) => {
            l("interp".into());
            for p in parts {
                match p {
                    InterpPart::Lit(s) => line(out, d + 1, &format!("lit {}", esc(s))),
                    InterpPart::Expr { expr: x, spec } => {
                        line(out, d + 1, &match spec {
                            Some(s) => format!("part spec={}", esc(s)),
                            None => "part".into(),
                        });
                        expr(out, d + 2, x);
                    }
                }
            }
        }
        ExprKind::Name(n) => l(format!("name {n}")),
        ExprKind::Hole => l("hole".into()),
        ExprKind::Field { expr: x, name } => {
            l(format!("field {}", id(name)));
            expr(out, d + 1, x);
        }
        ExprKind::TupleField { expr: x, index } => {
            l(format!("tuple-field {index}"));
            expr(out, d + 1, x);
        }
        ExprKind::Call { callee, args } => {
            l("call".into());
            expr(out, d + 1, callee);
            exprs(out, d + 1, args);
        }
        ExprKind::MethodCall { recv, name, args } => {
            l(format!("method {}", id(name)));
            expr(out, d + 1, recv);
            exprs(out, d + 1, args);
        }
        ExprKind::Pipe { lhs, callee, args } => {
            l("pipe".into());
            expr(out, d + 1, lhs);
            expr(out, d + 1, callee);
            exprs(out, d + 1, args);
        }
        ExprKind::Index { expr: x, index } => {
            l("index".into());
            expr(out, d + 1, x);
            expr(out, d + 1, index);
        }
        ExprKind::Slice { expr: x, lo, hi, inclusive } => {
            l(format!("slice{}", if *inclusive { " inclusive" } else { "" }));
            expr(out, d + 1, x);
            expr(out, d + 1, lo);
            expr(out, d + 1, hi);
        }
        ExprKind::Unary { op, expr: x } => {
            l(format!("unary {}", op.symbol()));
            expr(out, d + 1, x);
        }
        ExprKind::Binary { op, lhs, rhs } => {
            l(format!("binary {}", op.symbol()));
            expr(out, d + 1, lhs);
            expr(out, d + 1, rhs);
        }
        ExprKind::Range { lo, hi, inclusive } => {
            l(format!("range{}", if *inclusive { " inclusive" } else { "" }));
            expr(out, d + 1, lo);
            expr(out, d + 1, hi);
        }
        ExprKind::Is { expr: x, pat: p } => {
            l("is".into());
            expr(out, d + 1, x);
            pat(out, d + 1, p);
        }
        ExprKind::Try(x) => {
            l("try".into());
            expr(out, d + 1, x);
        }
        ExprKind::Unwrap(x) => {
            l("unwrap".into());
            expr(out, d + 1, x);
        }
        ExprKind::OptChain { expr: x, name, args } => {
            l(format!("opt-chain {}{}", id(name), if args.is_some() { " args" } else { "" }));
            expr(out, d + 1, x);
            if let Some(a) = args {
                exprs(out, d + 1, a);
            }
        }
        ExprKind::Else { expr: x, arm } => {
            l("else".into());
            expr(out, d + 1, x);
            else_arm(out, d + 1, arm);
        }
        ExprKind::Await(x) => {
            l("await".into());
            expr(out, d + 1, x);
        }
        ExprKind::AwaitAny(x) => {
            l("await-any".into());
            expr(out, d + 1, x);
        }
        ExprKind::Catch(x) => {
            l("catch".into());
            expr(out, d + 1, x);
        }
        ExprKind::Ref(x) => {
            l("ref".into());
            expr(out, d + 1, x);
        }
        ExprKind::Closure { params, body } => {
            l("closure".into());
            params.iter().for_each(|p| param(out, d + 1, p));
            expr(out, d + 1, body);
        }
        ExprKind::If { cond, then, els } => {
            l("if".into());
            expr(out, d + 1, cond);
            block(out, d + 1, then);
            if let Some(x) = els {
                expr(out, d + 1, x);
            }
        }
        ExprKind::Match { scrut, arms } => {
            l("match".into());
            expr(out, d + 1, scrut);
            for a in arms {
                line(out, d + 1, &format!("arm {}", sp(a.span)));
                pat(out, d + 2, &a.pat);
                if let Some(g) = &a.guard {
                    line(out, d + 2, "when");
                    expr(out, d + 3, g);
                }
                expr(out, d + 2, &a.body);
            }
        }
        ExprKind::Loop(b) => {
            l("loop".into());
            block(out, d + 1, b);
        }
        ExprKind::While { cond, body } => {
            l("while".into());
            expr(out, d + 1, cond);
            block(out, d + 1, body);
        }
        ExprKind::For { index, pat: p, iter, body } => {
            l(format!("for{}", if index.is_some() { " indexed" } else { "" }));
            if let Some(i) = index {
                pat(out, d + 1, i);
            }
            pat(out, d + 1, p);
            expr(out, d + 1, iter);
            block(out, d + 1, body);
        }
        ExprKind::Block(b) => {
            l("block".into());
            block(out, d + 1, b);
        }
        ExprKind::Let { mutable, pat: p, ty: t, value, els } => {
            l((if *mutable { "var" } else { "let" }).into());
            pat(out, d + 1, p);
            if let Some(t) = t {
                ty(out, d + 1, t);
            }
            expr(out, d + 1, value);
            if let Some(a) = els {
                else_arm(out, d + 1, a);
            }
        }
        ExprKind::Assign { op, target, value } => {
            l(format!("assign {}=", op.map(|o| o.symbol()).unwrap_or("")));
            expr(out, d + 1, target);
            expr(out, d + 1, value);
        }
        ExprKind::Assert(x) => {
            l("assert".into());
            expr(out, d + 1, x);
        }
        ExprKind::Return(x) => {
            l("return".into());
            if let Some(x) = x {
                expr(out, d + 1, x);
            }
        }
        ExprKind::Break(x) => {
            l("break".into());
            if let Some(x) = x {
                expr(out, d + 1, x);
            }
        }
        ExprKind::Continue => l("continue".into()),
        ExprKind::Peek(x) => {
            l("peek".into());
            expr(out, d + 1, x);
        }
        ExprKind::Struct { path, fields, base } => {
            l(format!("struct {}", path.iter().map(id).collect::<Vec<_>>().join(" ")));
            for f in fields {
                line(out, d + 1, &format!("field {}", id(&f.name)));
                if let Some(v) = &f.value {
                    expr(out, d + 2, v);
                }
            }
            if let Some(b) = base {
                line(out, d + 1, "base");
                expr(out, d + 2, b);
            }
        }
        ExprKind::List(xs) => {
            l("list".into());
            exprs(out, d + 1, xs);
        }
        ExprKind::Map(es) => {
            l("map".into());
            for (k, v) in es {
                line(out, d + 1, "entry");
                expr(out, d + 2, k);
                expr(out, d + 2, v);
            }
        }
        ExprKind::Tuple(xs) => {
            l("tuple".into());
            exprs(out, d + 1, xs);
        }
    }
}

// ---- module tree and paths (resolve) ----

/// `file` relative to the current directory (when under it).
fn rel(file: &str) -> String {
    let cwd = std::env::current_dir().map(|d| d.display().to_string()).unwrap_or_default();
    match file.strip_prefix(&format!("{cwd}/")) {
        Some(r) if !cwd.is_empty() => r.to_string(),
        _ => file.to_string(),
    }
}

fn resolved(out: &mut String, r: &Result<Program, Vec<FileDiag>>) {
    match r {
        Ok(p) => program(out, p),
        Err(ds) => {
            for d in ds {
                line(out, 0, &format!("in {}", esc(&rel(&d.file))));
                diag(out, &d.diag);
            }
        }
    }
}

fn program(out: &mut String, p: &Program) {
    line(out, 0, &format!("root {} focus {} core {} {}", p.root, p.focus, p.core_pkg, p.core_root));
    for (i, k) in p.pkgs.iter().enumerate() {
        let dir = k.dir.as_ref().map(|d| esc(&rel(&d.display().to_string()))).unwrap_or_else(|| "-".into());
        line(out, 0, &format!("pkg {i} {} root={} dir={dir}{}", esc(&k.name), k.root, if k.is_core { " core" } else { "" }));
        for (n, d) in &k.deps {
            line(out, 1, &format!("dep {n} {d}"));
        }
        if !k.effects.is_empty() {
            line(out, 1, &format!("effects {}", k.effects.iter().map(|e| esc(e)).collect::<Vec<_>>().join(" ")));
        }
        if !k.links.is_empty() {
            line(out, 1, &format!("links {}", k.links.iter().map(|l| esc(l)).collect::<Vec<_>>().join(" ")));
        }
    }
    for (i, m) in p.mods.iter().enumerate() {
        line(out, 0, &format!("mod {i} {} pkg={} file={} items={}", p.name(i), m.pkg, esc(&rel(&m.file)), m.ast.items.len()));
        for (n, c) in &m.children {
            line(out, 1, &format!("child {n} {c}"));
        }
        if p.is_core(i) {
            continue;
        }
        let name = p.name(i);
        for item in &m.ast.items {
            item_line(out, &name, item);
        }
        let mut paths = Vec::new();
        for item in &m.ast.items {
            item_paths(item, &mut paths);
        }
        for path in &paths {
            use_line(out, p, i, path);
        }
    }
}

fn item_line(out: &mut String, m: &str, item: &Item) {
    let (kind, n, public) = match item {
        Item::Fn(g) => {
            let public = g.header.iter().map(|h| &**h).chain(&g.clauses).any(|c| c.public);
            (format!("fn/{}", g.arity), g.name.clone(), public)
        }
        Item::Struct(d) => ("struct".into(), d.name.name.clone(), d.public),
        Item::Enum(d) => ("enum".into(), d.name.name.clone(), d.public),
        Item::Shape(d) => ("shape".into(), d.name.name.clone(), d.public),
        Item::Test(t) => {
            line(out, 1, &format!("item test {} {m}", esc(&t.name)));
            return;
        }
        Item::Let(c) => ("let".into(), c.name.name.clone(), c.public),
        Item::Imprint(c) => ("imprint".into(), c.name.name.clone(), c.public),
        Item::ExternType(t) => ("extern-type".into(), t.name.name.clone(), t.public),
    };
    line(out, 1, &format!("item {kind} {m}.{n}{}", vis(public)));
    if let Item::Enum(d) = item {
        for v in &d.variants {
            line(out, 2, &format!("variant {m}.{n}.{}", v.name.name));
        }
    }
}

/// A dotted path's segments, if the expression is only names and fields (`check::expr::as_path`).
fn as_path(e: &Expr) -> Option<Vec<Ident>> {
    match &e.kind {
        ExprKind::Name(n) => Some(vec![Ident { name: n.clone(), span: e.span }]),
        ExprKind::Field { expr, name } => {
            let mut p = as_path(expr)?;
            p.push(name.clone());
            Some(p)
        }
        _ => None,
    }
}

/// The module paths an item mentions, in order: its signature's type and pattern paths, then
/// those of its expressions (`check::visit_item_exprs` order): `a.b.c` field chains, a method
/// call's receiver name, and the qualifier of struct literals, types and patterns (`m.T`).
fn item_paths(item: &Item, acc: &mut Vec<Vec<Ident>>) {
    match item {
        Item::Fn(g) => {
            for c in g.header.iter().map(|h| &**h).chain(&g.clauses) {
                clause_paths(c, acc);
            }
        }
        Item::Struct(d) => {
            generic_paths(&d.generics, acc);
            d.fields.iter().for_each(|f| ty_paths(&f.ty, acc));
        }
        Item::Enum(d) => {
            generic_paths(&d.generics, acc);
            d.variants.iter().flat_map(|v| &v.fields).for_each(|f| ty_paths(&f.ty, acc));
        }
        Item::Shape(d) => {
            generic_paths(&d.generics, acc);
            d.methods.iter().for_each(|c| clause_paths(c, acc));
        }
        Item::Let(c) | Item::Imprint(c) => {
            if let Some(t) = &c.ty {
                ty_paths(t, acc);
            }
        }
        Item::Test(_) | Item::ExternType(_) => {}
    }
    super::check::visit_item_exprs(item, &mut |e| expr_paths(e, acc));
}

fn clause_paths(c: &FnClause, acc: &mut Vec<Vec<Ident>>) {
    generic_paths(&c.generics, acc);
    for p in &c.params {
        param_paths(p, acc);
    }
    if let Some(t) = &c.ret {
        ty_paths(t, acc);
    }
}

fn generic_paths(gs: &[Generic], acc: &mut Vec<Vec<Ident>>) {
    gs.iter().flat_map(|g| &g.bounds).for_each(|b| ty_paths(b, acc));
}

fn param_paths(p: &Param, acc: &mut Vec<Vec<Ident>>) {
    pat_paths(&p.pat, acc);
    if let Some(t) = &p.ty {
        ty_paths(t, acc);
    }
}

/// The qualifier of `m.x` (nothing for a bare name).
fn qualifier(path: &[Ident], acc: &mut Vec<Vec<Ident>>) {
    if path.len() >= 2 {
        acc.push(path[..path.len() - 1].to_vec());
    }
}

fn ty_paths(t: &Type, acc: &mut Vec<Vec<Ident>>) {
    match &t.kind {
        TypeKind::Named { path, args } => {
            qualifier(path, acc);
            args.iter().for_each(|a| ty_paths(a, acc));
        }
        TypeKind::List(x) | TypeKind::Optional(x) | TypeKind::Any(x) | TypeKind::Var(x) => ty_paths(x, acc),
        TypeKind::Measured { base, .. } => ty_paths(base, acc),
        TypeKind::Map(k, v) => {
            ty_paths(k, acc);
            ty_paths(v, acc);
        }
        TypeKind::Tuple(ts) => ts.iter().for_each(|x| ty_paths(x, acc)),
        TypeKind::Fallible { ok, err } => {
            ty_paths(ok, acc);
            if let Some(e) = err {
                ty_paths(e, acc);
            }
        }
        TypeKind::Fn { params, ret } => {
            params.iter().for_each(|x| ty_paths(x, acc));
            ty_paths(ret, acc);
        }
    }
}

fn pat_paths(p: &Pat, acc: &mut Vec<Vec<Ident>>) {
    match &p.kind {
        PatKind::Wild | PatKind::Bind(_) | PatKind::Lit { .. } | PatKind::None => {}
        PatKind::Tuple(ps) | PatKind::Or(ps) => ps.iter().for_each(|x| pat_paths(x, acc)),
        PatKind::List { head, rest, tail } => {
            head.iter().for_each(|x| pat_paths(x, acc));
            if let Some(x) = rest.as_ref().and_then(|r| r.pat.as_ref()) {
                pat_paths(x, acc);
            }
            tail.iter().for_each(|x| pat_paths(x, acc));
        }
        PatKind::Variant { path, args } => {
            qualifier(path, acc);
            args.iter().flatten().for_each(|x| pat_paths(x, acc));
        }
        PatKind::Struct { path, fields, .. } => {
            qualifier(path, acc);
            fields.iter().filter_map(|f| f.pat.as_ref()).for_each(|x| pat_paths(x, acc));
        }
        PatKind::Map(es) => es.iter().for_each(|(_, x)| pat_paths(x, acc)),
        PatKind::StrPrefix { rest, .. } => pat_paths(rest, acc),
        PatKind::Some(x) | PatKind::Ok(x) | PatKind::Err(x) => pat_paths(x, acc),
    }
}

/// The paths of one expression node (not its sub-expressions: the visitor reaches those).
fn expr_paths(e: &Expr, acc: &mut Vec<Vec<Ident>>) {
    match &e.kind {
        ExprKind::Field { .. } => {
            if let Some(p) = as_path(e) {
                acc.push(p);
            }
        }
        ExprKind::MethodCall { recv, .. } => {
            if let ExprKind::Name(n) = &recv.kind {
                acc.push(vec![Ident { name: n.clone(), span: recv.span }]);
            }
        }
        ExprKind::Struct { path, .. } => qualifier(path, acc),
        ExprKind::Is { pat, .. } => pat_paths(pat, acc),
        ExprKind::Match { arms, .. } => arms.iter().for_each(|a| pat_paths(&a.pat, acc)),
        ExprKind::For { index, pat, .. } => {
            if let Some(i) = index {
                pat_paths(i, acc);
            }
            pat_paths(pat, acc);
        }
        ExprKind::Let { pat, ty, .. } => {
            pat_paths(pat, acc);
            if let Some(t) = ty {
                ty_paths(t, acc);
            }
        }
        ExprKind::Closure { params, .. } => params.iter().for_each(|p| param_paths(p, acc)),
        _ => {}
    }
}

/// `use <span> a.b.c -> <module> k/n`: the module the first `k` of the path's `n` segments
/// name. Nothing when the first segment names no module.
fn use_line(out: &mut String, p: &Program, m: ModId, path: &[Ident]) {
    let Some(mut cur) = p.first_segment(m, &path[0].name) else { return };
    let mut k = 1;
    while k < path.len() {
        match p.child(cur, &path[k].name) {
            Some(c) => cur = c,
            None => break,
        }
        k += 1;
    }
    let (a, b) = (path[0].span, path[path.len() - 1].span);
    let span = Span { line: a.line, col: a.col, end_line: b.end_line, end_col: b.end_col };
    let text = path.iter().map(|i| i.name.as_str()).collect::<Vec<_>>().join(".");
    line(out, 1, &format!("use {} {text} -> {} {k}/{}", sp(span), p.name(cur), path.len()));
}

// ---- the checker's diagnostics and typed program (check, typed) ----

/// `auk dump check`: the `auk check --json` report of the type checker proper (types,
/// inference, overloading, shapes: `check::check_types`), without the later passes
/// (patterns.rs exhaustiveness, effects.rs).
fn checked(path: &str, r: Result<Program, Vec<FileDiag>>) -> String {
    let diags = match r {
        Ok(prog) => check::check_types(prog).1,
        Err(ds) => ds,
    };
    format!("{}\n", super::diag::json_report_files(path, &diags))
}

/// `auk dump typed`: the checker's errors (as `in <file>` + `error ...` lines) and the typed
/// program (`typed`), the erased one (`check::check`'s result) when there were no errors.
fn typed_program(out: &mut String, r: Result<Program, Vec<FileDiag>>, core: bool) {
    let prog = match r {
        Ok(p) => p,
        Err(ds) => return resolved(out, &Err(ds)),
    };
    let (tp, errs) = check::check_types(prog);
    for d in &errs {
        line(out, 0, &format!("in {}", esc(&rel(&d.file))));
        diag(out, &d.diag);
    }
    if let Some(mut tp) = tp {
        if errs.is_empty() {
            super::units::erase(&mut tp);
        }
        typed(out, &tp, core);
    }
}

/// The typed program: the non-core type and shape definitions, every function's signature,
/// constants and tests, the focus module's side tables (a line per node, in node order, with
/// every fact about it) and locals, the instances (with their resolved targets for bodies in the
/// focus module), then the concrete types, shape implementations and vtables. (Each file of a
/// project is the focus once, so the corpus covers every module.) `core` adds core's
/// definitions, and prints every module's tables and every instance's targets.
fn typed(out: &mut String, tp: &TypedProgram, core: bool) {
    let d = &tp.defs;
    let show = |t: &Ty| d.show(t);
    let shows = |ts: &[Ty]| ts.iter().map(|t| d.show(t)).collect::<Vec<_>>().join(", ");
    match &tp.main {
        Some(m) => line(out, 0, &format!("main #{} args={} ret={}", m.func, m.takes_args, show(&m.ret))),
        None => line(out, 0, "main -"),
    }
    for (i, t) in d.types.iter().enumerate() {
        if tp.program.is_core(t.module) && !core {
            continue;
        }
        let ps: Vec<String> = t.params.iter().map(|p| d.params[*p].name.clone()).collect();
        line(out, 0, &format!("def #{i} {}.{}<{}>{}", tp.program.name(t.module), t.name, ps.join(", "), vis(t.public)));
        match &t.kind {
            TypeDefKind::Struct { fields } => {
                for f in fields {
                    line(out, 1, &format!("field {}: {}{}", f.name, show(&f.ty), vis(f.public)));
                }
            }
            TypeDefKind::Enum { variants } => {
                for v in variants {
                    let fs: Vec<String> = v.fields.iter().map(|(n, t)| format!("{}{}", n.as_ref().map(|n| format!("{n}: ")).unwrap_or_default(), show(t))).collect();
                    line(out, 1, &format!("variant {}({})", v.name, fs.join(", ")));
                }
            }
            TypeDefKind::Opaque { c_type } => line(out, 1, &format!("opaque {}", esc(c_type))),
        }
    }
    for (i, s) in d.shapes.iter().enumerate() {
        if tp.program.is_core(s.module) && !core {
            continue;
        }
        line(out, 0, &format!("shape #{i} {}.{}{}", tp.program.name(s.module), s.name, vis(s.public)));
        for m in &s.methods {
            line(out, 1, &format!("method {}({}): {}", m.name, shows(&m.params), show(&m.ret)));
        }
    }
    for (i, f) in tp.fns.iter().enumerate() {
        let ps: Vec<String> = f.params.iter().map(|p| format!("{}{}: {}", if p.var { "var " } else { "" }, p.name.as_deref().unwrap_or("_"), show(&p.ty))).collect();
        let gs: Vec<String> = f.generics.iter().map(|g| bounded(d, *g)).collect();
        let kind = match &f.kind {
            FnKind::Auk { item, clauses, header } => {
                format!("auk item={item} clauses={clauses:?}{}", if *header { " header" } else { "" })
            }
            FnKind::Extern { symbol, loc, item } => format!("extern {}{} item={item}", esc(symbol), if *loc { " +loc" } else { "" }),
            FnKind::Ffi { sig, convs, item } => {
                let cs: Vec<String> = convs.iter().map(conv_text).collect();
                let cps: Vec<String> = sig.params.iter().map(|p| p.show()).collect();
                format!(
                    "ffi {} ({}) -> {}{}{}{}{} convs=[{}] item={item}",
                    sig.name,
                    cps.join(", "),
                    sig.ret.show(),
                    sig.free.as_ref().map(|f| format!(" free={f}")).unwrap_or_default(),
                    if sig.indirect { " indirect" } else { "" },
                    if sig.cast { " cast" } else { "" },
                    sig.embed.as_ref().map(|e| format!(" embed={}", esc(&rel(e)))).unwrap_or_default(),
                    cs.join(", ")
                )
            }
            FnKind::Intrinsic { which, item } => format!("intrinsic {which:?} item={item}"),
        };
        line(
            out,
            0,
            &format!(
                "fn #{i} {}.{}{}{}({}): {} [{kind}]{}",
                tp.program.name(f.module),
                if f.is_async { "async " } else { "" },
                f.name,
                if gs.is_empty() { String::new() } else { format!("<{}>", gs.join(", ")) },
                ps.join(", "),
                show(&f.ret),
                vis(f.public)
            ),
        );
        if f.module == tp.program.focus || core {
            let callees: Vec<String> = f.callees.iter().map(|c| c.to_string()).collect();
            let olds: Vec<String> = f.olds.iter().map(|c| format!("#{c}")).collect();
            let r = f.result_local.map(|l| format!(" result={l}")).unwrap_or_default();
            line(out, 1, &format!("span {} uses=[{}] callees=[{}] olds=[{}]{r}", sp(f.span), f.uses.join(", "), callees.join(", "), olds.join(", ")));
        }
    }
    for (i, c) in tp.consts.iter().enumerate() {
        line(out, 0, &format!("const #{i} {}.{}: {}{}{} item={} {}", tp.program.name(c.module), c.name, show(&c.ty), vis(c.public), if c.imprint { " imprint" } else { "" }, c.item, sp(c.span)));
    }
    for (i, t) in tp.tests.iter().enumerate() {
        line(out, 0, &format!("test #{i} {}.{} item={} {}", tp.program.name(t.module), esc(&t.name), t.item, sp(t.span)));
    }
    for (m, t) in tp.tables.iter().enumerate() {
        if m != tp.program.focus && !core {
            continue;
        }
        line(out, 0, &format!("module {m} {} {}", tp.program.name(m), esc(&rel(&tp.program.mods[m].file))));
        tables(out, tp, t);
    }
    for (i, inst) in tp.instances.iter().enumerate() {
        let (what, module) = match inst.body {
            BodyRef::Fn(f) => (format!("fn #{f} {}", tp.fns[f].name), tp.fns[f].module),
            BodyRef::Test(t) => (format!("test #{t} {}", esc(&tp.tests[t].name)), tp.tests[t].module),
            BodyRef::Const(c) => (format!("const #{c} {}", tp.consts[c].name), tp.consts[c].module),
        };
        let args = if inst.type_args.is_empty() { String::new() } else { format!("<{}>", shows(&inst.type_args)) };
        line(out, 0, &format!("instance {i} {what}{args}"));
        if module != tp.program.focus && !core {
            continue;
        }
        for (n, t) in sorted(&inst.resolved) {
            line(out, 1, &format!("#{n} -> {}", target(tp, t)));
        }
        for (n, t) in sorted(&inst.shows) {
            line(out, 1, &format!("show #{n} -> {}", target(tp, t)));
        }
        for (n, v) in sorted(&inst.vtables) {
            line(out, 1, &format!("vtable #{n} -> {v}"));
        }
    }
    for t in &tp.types_used {
        line(out, 0, &format!("used {}", show(t)));
    }
    for ((b, t), x) in &tp.shape_impls {
        line(out, 0, &format!("impl {b:?} {} -> {}", show(t), target(tp, x)));
    }
    for (t, x) in &tp.from_value_impls {
        line(out, 0, &format!("from_value {} -> {}", show(t), target(tp, x)));
    }
    for (i, v) in tp.vtables.iter().enumerate() {
        let ms: Vec<String> = v.methods.iter().map(|x| target(tp, x)).collect();
        line(out, 0, &format!("vtable {i} {} {} [{}]", d.shapes[v.shape].name, show(&v.ty), ms.join(", ")));
    }
}

/// A type parameter with its bounds: `T: Show + Eq`, `Ord (implicit)`.
fn bounded(d: &Defs, p: ParamId) -> String {
    let tp = &d.params[p];
    let bs: Vec<String> = tp.bounds.iter().map(|b| d.shapes[*b].name.clone()).collect();
    format!("{}{}{}", tp.name, if bs.is_empty() { String::new() } else { format!(": {}", bs.join(" + ")) }, if tp.implicit { " implicit" } else { "" })
}

/// A map keyed by node id, in node order.
fn sorted<V>(m: &HashMap<NodeId, V>) -> Vec<(NodeId, &V)> {
    let mut v: Vec<(NodeId, &V)> = m.iter().map(|(k, v)| (*k, v)).collect();
    v.sort_by_key(|x| x.0);
    v
}

fn conv_text(c: &Conv) -> String {
    match c {
        Conv::Int { bytes, signed } => format!("int{bytes}{}", if *signed { "s" } else { "u" }),
        Conv::Bool => "bool".into(),
        Conv::Float { f32 } => if *f32 { "f32".into() } else { "f64".into() },
        Conv::Str { owned } => format!("str{}", if *owned { "+owned" } else { "" }),
        Conv::OptStr { owned } => format!("optstr{}", if *owned { "+owned" } else { "" }),
        Conv::Ptr => "ptr".into(),
        Conv::OptPtr => "optptr".into(),
        Conv::Unit => "unit".into(),
        Conv::List { elem, back } => format!("list {elem:?}{}", if *back { " back" } else { "" }),
        Conv::Out(x) => format!("out({})", conv_text(x)),
    }
}

fn fn_name(tp: &TypedProgram, f: FnId) -> String {
    format!("{}#{f}", tp.fns[f].name)
}

fn variant_name(tp: &TypedProgram, def: DefId, index: usize) -> String {
    let vs = tp.defs.variants(def);
    format!("{}.{}", tp.defs.types[def].name, vs.get(index).map(|v| v.name.as_str()).unwrap_or("?"))
}

fn targs(tp: &TypedProgram, ts: &[Ty]) -> String {
    if ts.is_empty() { String::new() } else { format!("<{}>", ts.iter().map(|t| tp.defs.show(t)).collect::<Vec<_>>().join(", ")) }
}

fn shape_method(tp: &TypedProgram, shape: ShapeId, method: usize) -> String {
    let s = &tp.defs.shapes[shape];
    format!("{}.{}", s.name, s.methods.get(method).map(|m| m.name.as_str()).unwrap_or("?"))
}

fn callee(tp: &TypedProgram, c: &Callee) -> String {
    match c {
        Callee::Fn { func, type_args } => format!("fn {}{}", fn_name(tp, *func), targs(tp, type_args)),
        Callee::Variant(v) => format!("variant {}{}", variant_name(tp, v.def, v.index), targs(tp, &v.args)),
        Callee::Closure => "closure".into(),
        Callee::Shape { shape, method, self_ty } => format!("shape {} @{}", shape_method(tp, *shape, *method), tp.defs.show(self_ty)),
        Callee::Vtable { shape, method } => format!("vtable {}", shape_method(tp, *shape, *method)),
    }
}

fn target(tp: &TypedProgram, t: &Target) -> String {
    match t {
        Target::Instance(i) => format!("inst {i}"),
        Target::Extern { symbol, loc } => format!("extern {}{}", esc(symbol), if *loc { " +loc" } else { "" }),
        Target::Ffi(f) => format!("ffi {}", fn_name(tp, *f)),
        Target::Intrinsic { which, ty } => format!("intrinsic {which:?} {}", tp.defs.show(ty)),
        Target::Derived { shape, ty } => format!("derived {shape:?} {}", tp.defs.show(ty)),
        Target::Vtable { shape, method } => format!("vtable {}", shape_method(tp, *shape, *method)),
        Target::Variant { def, index } => format!("variant {}", variant_name(tp, *def, *index)),
        Target::Closure => "closure".into(),
    }
}

fn coercions(tp: &TypedProgram, cs: &[Coercion]) -> String {
    let v: Vec<String> = cs
        .iter()
        .map(|c| match c {
            Coercion::WrapSome => "some".to_string(),
            Coercion::WrapOk => "ok".to_string(),
            Coercion::ToAny(s) => format!("any {}", tp.defs.shapes[*s].name),
        })
        .collect();
    v.join(",")
}

/// One module's side tables: a line per node that appears in any of them (node order), with
/// every fact about it, then the module's locals.
fn tables(out: &mut String, tp: &TypedProgram, t: &Tables) {
    let mut ids: BTreeSet<NodeId> = BTreeSet::new();
    ids.extend(t.types.keys());
    ids.extend(t.coercions.keys());
    ids.extend(t.names.keys());
    ids.extend(t.binds.keys());
    ids.extend(t.variants.keys());
    ids.extend(t.calls.keys());
    ids.extend(t.fields.keys());
    ids.extend(t.struct_lits.keys());
    ids.extend(t.struct_pats.keys());
    ids.extend(t.closures.keys());
    ids.extend(t.tries.keys());
    ids.extend(t.fails.keys());
    ids.extend(t.elses.keys());
    ids.extend(t.opt_chains.keys());
    ids.extend(t.awaits.keys());
    ids.extend(t.fors.keys());
    ids.extend(t.formats.keys());
    ids.extend(t.shows.keys());
    ids.extend(t.value_map_pats.iter());
    ids.extend(t.err_payload_pats.keys());
    ids.extend(t.units.keys());
    let d = &tp.defs;
    for n in ids {
        let mut s = format!("#{n}");
        if let Some(ty) = t.types.get(&n) {
            let _ = write!(s, " : {}", d.show(ty));
        }
        if let Some(cs) = t.coercions.get(&n) {
            let _ = write!(s, " coerce={}", coercions(tp, cs));
        }
        if let Some(r) = t.names.get(&n) {
            let r = match r {
                NameRef::Local(l) => format!("local {l}"),
                NameRef::Const(c) => format!("const {}#{c}", tp.consts[*c].name),
                NameRef::Fn { func, type_args } => format!("fn {}{}", fn_name(tp, *func), targs(tp, type_args)),
                NameRef::Variant(v) => format!("variant {}{}", variant_name(tp, v.def, v.index), targs(tp, &v.args)),
                NameRef::None => "none".into(),
            };
            let _ = write!(s, " name=({r})");
        }
        if let Some(l) = t.binds.get(&n) {
            let _ = write!(s, " bind={l}");
        }
        if let Some(v) = t.variants.get(&n) {
            let _ = write!(s, " variant={}{}", variant_name(tp, v.def, v.index), targs(tp, &v.args));
        }
        if let Some(c) = t.calls.get(&n) {
            let args: Vec<String> = c.args.iter().map(|a| format!("{}#{}", if a.by_ref { "&" } else { "" }, a.node)).collect();
            let _ = write!(s, " call=({})({})", callee(tp, &c.callee), args.join(", "));
        }
        if let Some((def, i)) = t.fields.get(&n) {
            let f = d.fields(*def).get(*i).map(|f| f.name.as_str()).unwrap_or("?");
            let _ = write!(s, " field={}.{f}", d.types[*def].name);
        }
        if let Some(sl) = t.struct_lits.get(&n) {
            let fs: Vec<String> = sl
                .fields
                .iter()
                .map(|(i, v)| match v {
                    FieldValue::Expr(x) => format!("{i}=#{x}"),
                    FieldValue::Local(l, cs) => format!("{i}=local {l}{}", if cs.is_empty() { String::new() } else { format!(" {}", coercions(tp, cs)) }),
                })
                .collect();
            let _ = write!(s, " struct={}{}{{{}}}", d.types[sl.def].name, targs(tp, &sl.args), fs.join(", "));
        }
        if let Some(sp) = t.struct_pats.get(&n) {
            let fs: Vec<String> = sp.fields.iter().map(|(i, l)| match l {
                Some(l) => format!("{i}=local {l}"),
                None => i.to_string(),
            }).collect();
            let _ = write!(s, " struct_pat={}{{{}}}", d.types[sp.def].name, fs.join(", "));
        }
        if let Some(c) = t.closures.get(&n) {
            let caps: Vec<String> = c.captures.iter().map(|l| l.to_string()).collect();
            let ps: Vec<String> = c.params.iter().map(|p| d.show(p)).collect();
            let _ = write!(s, " closure=({}) => {} captures=[{}]{}", ps.join(", "), d.show(&c.ret), caps.join(", "), if c.unpack { " unpack" } else { "" });
        }
        if let Some(tr) = t.tries.get(&n) {
            let conv = match &tr.conv {
                ErrConv::None => String::new(),
                ErrConv::ToErr { from } => format!(" to_err {}", d.show(from)),
            };
            let _ = write!(s, " try={:?}{conv}", tr.kind);
        }
        if let Some(f) = t.fails.get(&n) {
            let f = match f {
                FailKind::Message => "message".to_string(),
                FailKind::Err => "err".to_string(),
                FailKind::Typed => "typed".to_string(),
                FailKind::TypedToErr(x) => format!("typed_to_err {}", d.show(x)),
            };
            let _ = write!(s, " fail={f}");
        }
        if let Some(e) = t.elses.get(&n) {
            let k = match e.kind {
                ElseKind::Option => "option".to_string(),
                ElseKind::Result => "result".to_string(),
                ElseKind::Refutable => "refutable".to_string(),
                ElseKind::UnwrapRefutable { option } => format!("unwrap_refutable {}", if option { "option" } else { "result" }),
            };
            let b = e.binder.map(|l| format!(" binder={l}")).unwrap_or_default();
            let _ = write!(s, " else={k}{b}");
        }
        if let Some(o) = t.opt_chains.get(&n) {
            let _ = write!(s, " opt_chain{}", if o.flatten { " flatten" } else { "" });
        }
        if let Some(a) = t.awaits.get(&n) {
            let _ = write!(s, " await={a:?}");
        }
        if let Some(f) = t.fors.get(&n) {
            let f = match f {
                ForKind::Range { inclusive } => format!("range{}", if *inclusive { " inclusive" } else { "" }),
                ForKind::List => "list".into(),
                ForKind::Map => "map".into(),
                ForKind::Chan => "chan".into(),
            };
            let _ = write!(s, " for={f}");
        }
        if let Some(f) = t.formats.get(&n) {
            let c = |x: Option<char>| x.map(|c| (c as u32).to_string()).unwrap_or_else(|| "-".into());
            let u = |x: Option<usize>| x.map(|c| c.to_string()).unwrap_or_else(|| "-".into());
            let _ = write!(s, " format={} fill={} align={} zero={} width={} precision={} radix={}", esc(&f.text), c(f.fill), c(f.align), f.zero, u(f.width), u(f.precision), c(f.radix));
        }
        if let Some(c) = t.shows.get(&n) {
            let _ = write!(s, " show=({})", callee(tp, c));
        }
        if t.value_map_pats.contains(&n) {
            s.push_str(" value_map");
        }
        if let Some(x) = t.err_payload_pats.get(&n) {
            let _ = write!(s, " err_payload={}", d.show(x));
        }
        if let Some(u) = t.units.get(&n) {
            let _ = write!(s, " unit={}", esc(u));
        }
        line(out, 1, &s);
    }
    for (i, l) in t.locals.iter().enumerate() {
        line(out, 1, &format!("local {i} {}: {}{} {}", l.name, d.show(&l.ty), if l.mutable { " mut" } else { "" }, sp(l.span)));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn toks(src: &str) -> String {
        let lx = lex(src).unwrap();
        let mut out = String::new();
        tokens(&mut out, lx.module_doc.as_deref(), &lx.toks);
        out
    }

    fn ast(src: &str) -> String {
        let mut out = String::new();
        match parser::parse(src) {
            Ok(m) => module(&mut out, &m),
            Err(ds) => ds.iter().for_each(|d| diag(&mut out, d)),
        }
        out
    }

    #[test]
    fn token_dump() {
        assert_eq!(
            toks("/// m\n\nlet x = \"a{y:>2}\" 1.5 'c'\n"),
            "module-doc \"m\"\n\
             3:1-3:4 Let space\n\
             3:5-3:6 Ident \"x\" space\n\
             3:7-3:8 Eq space\n\
             3:9-3:18 Str space\n  \
               lit \"a\"\n  \
               interp 3:11-3:17 spec=\">2\"\n    \
                 3:12-3:13 Ident \"y\"\n    \
                 3:16-3:17 Eof\n\
             3:19-3:22 Float 4609434218613702656 space\n\
             3:23-3:26 Char 99 space\n\
             4:1-4:1 Eof space\n"
        );
        assert_eq!(esc("a\"\\\n\u{1}é"), "\"a\\\"\\\\\\n\\u{1}é\"");
    }

    #[test]
    fn ast_dump() {
        assert_eq!(
            ast("fn f(x: int): int = x + 1\n"),
            "fn f/1\n  \
               clause #5 1:1-1:26 f@1:4-1:5\n    \
                 param #3 1:6-1:12\n      \
                   pat #1 1:6-1:7 bind x\n      \
                   type #2 1:9-1:12 named int@1:9-1:12\n    \
                 ret\n      \
                   type #4 1:15-1:18 named int@1:15-1:18\n    \
                 body =\n      \
                   #8 1:21-1:26 binary +\n        \
                     #6 1:21-1:22 name x\n        \
                     #7 1:25-1:26 int 1\n"
        );
        let e = ast("fn f() {\n  x & 1 == 0\n}\n");
        assert!(e.starts_with("error E0038 2:3-2:8 \"`&` mixed with a comparison needs parentheses\"\n  note "), "{e}");
        assert!(e.contains("  fix 2:3-2:3 \"(\"\n"), "{e}");
    }

    fn res(src: &str) -> String {
        let mut out = String::new();
        resolved(&mut out, &resolve::load_source(Path::new("t.auk"), src.to_string()));
        out
    }

    #[test]
    fn resolve_dump() {
        let out = res("pub enum E { A(x: core.str.Q) }\nfn f(p: str): str! uses fs {\n  let n: net.Conn? = none\n  match e { fs.X => 1 }\n  core.fs.read(p)?\n}\n");
        assert!(out.starts_with("root 14 focus 14 core 0 0\npkg 0 \"core\" root=0 dir=- core\npkg 1 \"t\" root=14 dir=-\nmod 0 core pkg=0 file=\"<prelude>/core.auk\""), "{out}");
        assert!(out.contains("  child fs 1\n"), "{out}");
        let tail = &out[out.find("mod 14 ").unwrap()..];
        assert_eq!(
            tail,
            "mod 14 t pkg=1 file=\"t.auk\" items=2\n  \
               item enum t.E pub\n    \
                 variant t.E.A\n  \
               item fn/1 t.f\n  \
               use 1:19-1:27 core.str -> core.str 2/2\n  \
               use 3:10-3:13 net -> core.net 1/1\n  \
               use 4:13-4:15 fs -> core.fs 1/1\n  \
               use 5:3-5:10 core.fs -> core.fs 2/2\n"
        );
        let e = res("fn f( {\n");
        assert!(e.starts_with("in \"t.auk\"\nerror E0"), "{e}");
    }

    fn typ(src: &str) -> String {
        let mut out = String::new();
        typed_program(&mut out, resolve::load_source(Path::new("t.auk"), src.to_string()), false);
        out
    }

    #[test]
    fn typed_dump() {
        let out = typ("fn f(x: int): int = x + 1\nfn main() { print(\"{f(2)}\") }\n");
        assert!(out.starts_with("main #227 args=false ret=()\nfn #0 core.show<T: Show>(x: T): str [intrinsic Show item=6] pub\n"), "{out}");
        assert!(out.contains("fn #226 t.f(x: int): int [auk item=0 clauses=[0]]\n  span 1:4-1:5 uses=[] callees=[] olds=[]\n"), "{out}");
        assert!(out.contains("  span 2:4-2:8 uses=[] callees=[16, 226] olds=[]\n"), "{out}");
        assert!(
            out.contains(
                "module 14 t \"t.auk\"\n  \
                   #1 : int bind=0\n  \
                   #3 : int\n  \
                   #6 : int name=(local 0)\n  \
                   #7 : int\n  \
                   #8 : int\n  \
                   #12 : int\n  \
                   #13 : int call=(fn f#226)(#12)\n  \
                   #14 : str\n  \
                   #15 : () call=(fn print#16<str>)(#14)\n  \
                   #16 : ()\n  \
                   local 0 x: int 1:6-1:7\n"
            ),
            "{out}"
        );
        assert!(out.contains("instance 22 fn #227 main\n  #13 -> inst 21\n  #15 -> inst 27\n"), "{out}");
        assert!(out.contains("instance 27 fn #16 print<str>\n"), "{out}");
        // errors first, then the partial program
        let e = typ("fn f(x: int): str = x\n");
        assert!(e.starts_with("in \"t.auk\"\nerror E0200 1:21-1:22 \"expected `str`, found `int`\"\n"), "{e}");
        assert!(e.contains("\nmain -\n"), "{e}");
        let j = checked("t.auk", resolve::load_source(Path::new("t.auk"), "fn f(x: int): str = x\n".to_string()));
        assert!(j.starts_with("{\"file\":\"t.auk\",\"ok\":false,\"diagnostics\":[{\"code\":\"E0200\""), "{j}");
    }
}

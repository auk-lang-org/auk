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

pub fn run(args: &[String]) -> i32 {
    let (what, rest) = match args.split_first() {
        Some((w, rest)) if w == "tokens" || w == "ast" || w == "resolve" => (w.as_str(), rest),
        _ => {
            eprintln!("usage: auk dump tokens|ast|resolve [--quiet] [--time] [--repeat N] <file>...");
            return 2;
        }
    };
    let quiet = rest.iter().any(|a| a == "--quiet");
    let time = rest.iter().any(|a| a == "--time");
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
        if what == "resolve" {
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
}

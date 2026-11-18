//! `auk dump mir`: a MIR program as a precise, machine-readable text, for the self-hosted back
//! end (compiler/src/mir/read.auk reads it). Unlike `auk ir` (print.rs, C-like and lossy: `int`
//! and `int64_t` print alike), it keeps every machine type, member and literal exactly, plus the
//! type definitions layouts need (`TyInfo`: struct fields, enum variants, opaque C types).
//!
//! The format is a stream of whitespace-separated tokens in prefix form (each node is a tag and
//! then its children; lists are counted). Strings and byte strings are one token: `'` and the
//! bytes, with `\` and anything outside `!`..`~` written as `\` and two hex digits. Floats are
//! their IEEE bits (as a signed decimal). Records start on their own lines (for reading only). Deterministic:
//! maps are written sorted.
//!
//! ```text
//! auk-mir 1
//! types <n> { T <name> <nparams> <param>... (S <n> {<name> <ty>}... | E <n> {<name> <n> {<fname>|- <ty>}...}... | O <c_type>) }
//! shapes <n> { <name> <self_param> }      params <n> { <name> }
//! value <def>|-   err <def>
//! aggs <n> { <name> <n> <mty>... }
//! globals <n> { <name> <mty> <0|1 constant> (-|<ex>) }
//! funcs <n> { F <name> A|C <ret mty> <n> <param var>... <n> <var mty>... <n> <stmt>... }
//! entry <func>|-   locs <n> { <file> <line> <col> }   names <n> { <func> <name> }
//! links <n> { <str> }   csyms <n> { <str> }
//! ```
//! Types: `int float bool char str never`, `L t`, `M k v`, `T n t...`, `O t`, `R t e`,
//! `N d n t...`, `P p`, `A s`, `F n t... r`, `K t` (task), `U t` (var), `Me t n {name exp}...`.
//! Machine types: `void bool i8 u8 i16 u16 i32 u32 i64 u64 f32 cstr code`, `* m` (pointer),
//! `D t`, `G a` (aggregate), `rt:strbuf rt:obj rt:elemops rt:task`.
//! Members: `f i`, `tag`, `v vi fi`. Expressions are `<kind> <children...> <mty>`; statements are
//! `let v e`, `set p e`, `do e`, `if c <n> s... <n> s...`, `loop <n> s... <n> s...`, `break`,
//! `cont`, `label l`, `goto l`, `ret0`, `ret1 e`, `unr`, `loc i` (see `ex` and `stmt`).

use std::fmt::Write;

use super::{Abi, BOp, Callee, Ex, FRef, K, MTy, Program, Rt, RtF, Sel, Stmt, UOp};
use crate::typed::TypedProgram;
use crate::types::{Ty, TypeDefKind};

/// `s` as one token: `'` then the bytes, escaped.
pub fn bytes_tok(out: &mut String, s: &[u8]) {
    out.push(' ');
    out.push('\'');
    for &b in s {
        if b == b'\\' || !(0x21..=0x7e).contains(&b) {
            let _ = write!(out, "\\{b:02x}");
        } else {
            out.push(b as char);
        }
    }
}

fn s(out: &mut String, x: &str) {
    bytes_tok(out, x.as_bytes());
}

fn w(out: &mut String, tok: impl std::fmt::Display) {
    let _ = write!(out, " {tok}");
}

fn ty(out: &mut String, t: &Ty) {
    match t {
        Ty::Int => w(out, "int"),
        Ty::Float => w(out, "float"),
        Ty::Bool => w(out, "bool"),
        Ty::Char => w(out, "char"),
        Ty::Str => w(out, "str"),
        Ty::Never => w(out, "never"),
        Ty::List(x) => {
            w(out, "L");
            ty(out, x);
        }
        Ty::Map(k, v) => {
            w(out, "M");
            ty(out, k);
            ty(out, v);
        }
        Ty::Tuple(ts) => {
            w(out, "T");
            tys(out, ts);
        }
        Ty::Opt(x) => {
            w(out, "O");
            ty(out, x);
        }
        Ty::Res(x, e) => {
            w(out, "R");
            ty(out, x);
            ty(out, e);
        }
        Ty::Named(d, args) => {
            w(out, "N");
            w(out, d);
            tys(out, args);
        }
        Ty::Param(p) => {
            w(out, "P");
            w(out, p);
        }
        Ty::Any(sh) => {
            w(out, "A");
            w(out, sh);
        }
        Ty::Fn(ps, r) => {
            w(out, "F");
            tys(out, ps);
            ty(out, r);
        }
        Ty::Task(x) => {
            w(out, "K");
            ty(out, x);
        }
        Ty::Mut(x) => {
            w(out, "U");
            ty(out, x);
        }
        Ty::Measured(x, u) => {
            w(out, "Me");
            ty(out, x);
            w(out, u.0.len());
            for (n, e) in &u.0 {
                s(out, n);
                w(out, e);
            }
        }
        Ty::Var(_) | Ty::Error => panic!("dump mir: an unresolved type in MIR"),
    }
}

fn tys(out: &mut String, ts: &[Ty]) {
    w(out, ts.len());
    for t in ts {
        ty(out, t);
    }
}

fn mty(out: &mut String, t: &MTy) {
    match t {
        MTy::Void => w(out, "void"),
        MTy::Bool => w(out, "bool"),
        MTy::I8 => w(out, "i8"),
        MTy::U8 => w(out, "u8"),
        MTy::I16 => w(out, "i16"),
        MTy::U16 => w(out, "u16"),
        MTy::I32 => w(out, "i32"),
        MTy::U32 => w(out, "u32"),
        MTy::I64 => w(out, "i64"),
        MTy::U64 => w(out, "u64"),
        MTy::F32 => w(out, "f32"),
        MTy::CStr => w(out, "cstr"),
        MTy::Code => w(out, "code"),
        MTy::Ptr(x) => {
            w(out, "*");
            mty(out, x);
        }
        MTy::D(t) => {
            w(out, "D");
            ty(out, t);
        }
        MTy::Agg(a) => {
            w(out, "G");
            w(out, a);
        }
        MTy::Rt(r) => w(
            out,
            match r {
                Rt::StrBuf => "rt:strbuf",
                Rt::Obj => "rt:obj",
                Rt::ElemOps => "rt:elemops",
                Rt::Task => "rt:task",
            },
        ),
    }
}

fn sel(out: &mut String, x: Sel) {
    match x {
        Sel::F(i) => {
            w(out, "f");
            w(out, i);
        }
        Sel::Tag => w(out, "tag"),
        Sel::V(vi, fi) => {
            w(out, "v");
            w(out, vi);
            w(out, fi);
        }
    }
}

fn bop(op: BOp) -> &'static str {
    match op {
        BOp::Add => "add",
        BOp::Sub => "sub",
        BOp::Mul => "mul",
        BOp::Div => "div",
        BOp::BitAnd => "band",
        BOp::BitOr => "bor",
        BOp::BitXor => "bxor",
        BOp::Eq => "eq",
        BOp::Ne => "ne",
        BOp::Lt => "lt",
        BOp::Le => "le",
        BOp::Gt => "gt",
        BOp::Ge => "ge",
    }
}

fn ex(out: &mut String, e: &Ex) {
    match &e.k {
        K::Var(v) => {
            w(out, "var");
            w(out, v);
        }
        K::Global(g) => {
            w(out, "glob");
            w(out, g);
        }
        K::Int(n) => {
            w(out, "int");
            w(out, n);
        }
        K::Float(x) => {
            w(out, "flt");
            w(out, x.to_bits() as i64);
        }
        K::CStr(b) => {
            w(out, "cs");
            bytes_tok(out, b);
        }
        K::Zero => w(out, "zero"),
        K::FnAddr(FRef::Fn(f)) => {
            w(out, "fn");
            w(out, f);
        }
        K::FnAddr(FRef::Rt(x)) => {
            w(out, "fnrt");
            s(out, x);
        }
        K::GlobalAddr(g) => {
            w(out, "gaddr");
            w(out, g);
        }
        K::RtGlobalAddr(x) => {
            w(out, "rtg");
            s(out, x);
        }
        K::Field(b, x) => {
            w(out, "fld");
            ex(out, b);
            sel(out, *x);
        }
        K::Deref(p) => {
            w(out, "deref");
            ex(out, p);
        }
        K::Addr(p) => {
            w(out, "addr");
            ex(out, p);
        }
        K::Un(op, a) => {
            w(out, "un");
            w(
                out,
                match op {
                    UOp::Not => "not",
                    UOp::Neg => "neg",
                    UOp::BitNot => "bnot",
                },
            );
            ex(out, a);
        }
        K::Bin(op, a, b) => {
            w(out, "bin");
            w(out, bop(*op));
            ex(out, a);
            ex(out, b);
        }
        K::And(xs) => {
            w(out, "and");
            w(out, xs.len());
            for x in xs {
                ex(out, x);
            }
        }
        K::Cast(x) => {
            w(out, "cast");
            ex(out, x);
        }
        K::Call(c, args) => {
            w(out, "call");
            match c {
                Callee::Fn(f) => {
                    w(out, "fn");
                    w(out, f);
                }
                Callee::Rt(x) => {
                    w(out, "rt");
                    s(out, x);
                }
                Callee::Indirect(code, ps) => {
                    w(out, "ind");
                    ex(out, code);
                    w(out, ps.len());
                    for p in ps {
                        mty(out, p);
                    }
                }
                Callee::CPtr(code) => {
                    w(out, "cptr");
                    ex(out, code);
                }
            }
            w(out, args.len());
            for a in args {
                ex(out, a);
            }
        }
        K::Agg(ms) => {
            w(out, "agg");
            w(out, ms.len());
            for (x, v) in ms {
                sel(out, *x);
                ex(out, v);
            }
        }
        K::Cond(c, a, b) => {
            w(out, "cond");
            ex(out, c);
            ex(out, a);
            ex(out, b);
        }
        K::Elem(a, i) => {
            w(out, "elem");
            ex(out, a);
            ex(out, i);
        }
        K::RtField(p, f) => {
            w(out, "rtf");
            ex(out, p);
            w(
                out,
                match f {
                    RtF::ArrLen => "len",
                    RtF::ArrData => "data",
                    RtF::ErrMsg => "msg",
                },
            );
        }
        K::SizeOf(t) => {
            w(out, "sizeof");
            mty(out, t);
        }
    }
    mty(out, &e.ty);
}

fn stmts(out: &mut String, ss: &[Stmt], depth: usize) {
    w(out, ss.len());
    for x in ss {
        stmt(out, x, depth);
    }
}

fn stmt(out: &mut String, x: &Stmt, depth: usize) {
    out.push('\n');
    for _ in 0..depth {
        out.push(' ');
    }
    match x {
        Stmt::Let(v, e) => {
            out.push_str("let");
            w(out, v);
            ex(out, e);
        }
        Stmt::Set(p, e) => {
            out.push_str("set");
            ex(out, p);
            ex(out, e);
        }
        Stmt::Do(e) => {
            out.push_str("do");
            ex(out, e);
        }
        Stmt::If(c, a, b) => {
            out.push_str("if");
            ex(out, c);
            stmts(out, a, depth + 1);
            stmts(out, b, depth + 1);
        }
        Stmt::Loop(a, b) => {
            out.push_str("loop");
            stmts(out, a, depth + 1);
            stmts(out, b, depth + 1);
        }
        Stmt::Break => out.push_str("break"),
        Stmt::Continue => out.push_str("cont"),
        Stmt::Label(l) => {
            out.push_str("label");
            w(out, l);
        }
        Stmt::Goto(l) => {
            out.push_str("goto");
            w(out, l);
        }
        Stmt::Ret(None) => out.push_str("ret0"),
        Stmt::Ret(Some(e)) => {
            out.push_str("ret1");
            ex(out, e);
        }
        Stmt::Unreachable => out.push_str("unr"),
        Stmt::Loc(i) => {
            out.push_str("loc");
            w(out, i);
        }
    }
}

/// The dump of `prog`, with the type definitions of `tp` (as `TyInfo` sees them).
pub fn dump(prog: &Program, tp: &TypedProgram) -> String {
    let mut out = String::from("auk-mir 1\n");
    let defs = &tp.defs;
    out.push_str("types");
    w(&mut out, defs.types.len());
    for d in &defs.types {
        out.push_str("\nT");
        s(&mut out, &d.name);
        w(&mut out, d.params.len());
        for p in &d.params {
            w(&mut out, p);
        }
        match &d.kind {
            TypeDefKind::Struct { fields } => {
                w(&mut out, "S");
                w(&mut out, fields.len());
                for f in fields {
                    s(&mut out, &f.name);
                    ty(&mut out, &f.ty);
                }
            }
            TypeDefKind::Enum { variants } => {
                w(&mut out, "E");
                w(&mut out, variants.len());
                for v in variants {
                    s(&mut out, &v.name);
                    w(&mut out, v.fields.len());
                    for (n, t) in &v.fields {
                        match n {
                            Some(n) => s(&mut out, n),
                            None => w(&mut out, "-"),
                        }
                        ty(&mut out, t);
                    }
                }
            }
            TypeDefKind::Opaque { c_type } => {
                w(&mut out, "O");
                s(&mut out, c_type);
            }
        }
    }
    out.push_str("\nshapes");
    w(&mut out, defs.shapes.len());
    for sh in &defs.shapes {
        s(&mut out, &sh.name);
        w(&mut out, sh.self_param);
    }
    out.push_str("\nparams");
    w(&mut out, defs.params.len());
    for p in &defs.params {
        s(&mut out, &p.name);
    }
    let info = super::types::TyInfo::new(tp);
    out.push_str("\nvalue");
    match info.value_def {
        Some(d) => w(&mut out, d),
        None => w(&mut out, "-"),
    }
    let Ty::Named(err, _) = info.err_ty() else { unreachable!() };
    w(&mut out, "err");
    w(&mut out, err);
    out.push_str("\naggs");
    w(&mut out, prog.aggs.len());
    for a in &prog.aggs {
        out.push('\n');
        s(&mut out, &a.name);
        w(&mut out, a.fields.len());
        for f in &a.fields {
            mty(&mut out, f);
        }
    }
    out.push_str("\nglobals");
    w(&mut out, prog.globals.len());
    for g in &prog.globals {
        out.push('\n');
        s(&mut out, &g.name);
        mty(&mut out, &g.ty);
        w(&mut out, g.constant as u8);
        match &g.init {
            Some(e) => ex(&mut out, e),
            None => w(&mut out, "-"),
        }
    }
    out.push_str("\nfuncs");
    w(&mut out, prog.funcs.len());
    for f in &prog.funcs {
        out.push_str("\nF");
        s(&mut out, &f.name);
        w(&mut out, if f.abi == Abi::C { "C" } else { "A" });
        mty(&mut out, &f.ret);
        w(&mut out, f.params.len());
        for p in &f.params {
            w(&mut out, p);
        }
        w(&mut out, f.vars.len());
        for v in &f.vars {
            mty(&mut out, v);
        }
        stmts(&mut out, &f.body, 1);
    }
    out.push_str("\nentry");
    match prog.entry {
        Some(e) => w(&mut out, e),
        None => w(&mut out, "-"),
    }
    out.push_str("\nlocs");
    w(&mut out, prog.locs.len());
    for (f, l, c) in &prog.locs {
        out.push('\n');
        s(&mut out, f);
        w(&mut out, l);
        w(&mut out, c);
    }
    out.push_str("\nnames");
    let mut names: Vec<_> = prog.names.iter().collect();
    names.sort();
    w(&mut out, names.len());
    for (f, n) in names {
        out.push('\n');
        w(&mut out, f);
        s(&mut out, n);
    }
    out.push_str("\nlinks");
    w(&mut out, prog.links.len());
    for l in &prog.links {
        s(&mut out, l);
    }
    out.push_str("\ncsyms");
    w(&mut out, prog.c_syms.len());
    for c in &prog.c_syms {
        s(&mut out, c);
    }
    out.push('\n');
    out
}

#[cfg(test)]
mod tests {
    use std::io::Write as _;

    #[test]
    fn mir_dump() {
        let dir = std::env::temp_dir().join(format!("auk-dump-mir-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let f = dir.join("p.auk");
        let mut file = std::fs::File::create(&f).unwrap();
        writeln!(file, "fn twice(x: float): float = x * 2.5\nfn main() {{\n  let xs = [1, 2]\n  print(\"a b\\\\{{xs.len()}} {{twice(1.0)}}\")\n}}").unwrap();
        let tp = crate::build::check(&f).unwrap();
        let g = crate::build::generate(&tp, crate::mir::progen::Mode::Run, Default::default()).unwrap();
        let d = super::dump(&g.prog, &tp);
        let d2 = super::dump(&g.prog, &tp);
        assert_eq!(d, d2);
        assert!(d.starts_with("auk-mir 1\ntypes "), "{d}");
        // the float literal by its bits; a string with a space and a backslash as one token
        assert!(d.contains(&format!(" flt {} D float", 2.5f64.to_bits() as i64)), "{d}");
        assert!(d.contains("'a\\20b\\5c"), "{d}");
        assert!(d.contains("_twice A D float 1 0 "), "{d}");
        assert!(d.contains("\nentry "), "{d}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}

//! `duck ir`: a MIR program printed as C-like text, one function after another (with the type
//! definitions and globals it uses): every variable is declared at the top of its function,
//! `Loop` is `for (;;)` with its latch after a continue label, runtime calls name the runtime's
//! C symbols. (It reads as C against the runtime's ABI; nothing compiles it.)

use std::collections::HashMap;
use std::fmt::Write;

use super::types::TyInfo;
use super::{BOp, Callee, Ex, FRef, Func, K, MTy, Program, Rt, RtF, Sel, Stmt, UOp};
use crate::types::{Ty, TypeDefKind};

/// Escape bytes as the contents of a C string literal (octal escapes keep it unambiguous).
pub fn c_str(s: &[u8]) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for &b in s {
        match b {
            b'"' => out.push_str("\\\""),
            b'\\' => out.push_str("\\\\"),
            b'?' => out.push_str("\\?"),
            0x20..=0x7e => out.push(b as char),
            _ => {
                let _ = write!(out, "\\{:03o}", b);
            }
        }
    }
    out.push('"');
    out
}

struct Printer<'p, 'a> {
    p: &'p Program,
    info: &'p TyInfo<'a>,
    types: String,
    names: HashMap<MTy, String>,
    n: usize,
    /// Continue labels of the open loops.
    conts: Vec<usize>,
}

/// The C source of a program.
pub fn print(p: &Program, info: &TyInfo) -> String {
    let mut pr = Printer { p, info, types: String::new(), names: HashMap::new(), n: 0, conts: Vec::new() };
    let mut protos = String::new();
    let mut funcs = String::new();
    for f in &p.funcs {
        let sig = pr.sig(f);
        let _ = writeln!(protos, "{sig};");
        let _ = writeln!(funcs, "{sig} {{");
        let body = pr.body(f);
        funcs.push_str(&body);
        funcs.push_str("}\n\n");
    }
    let mut globals = String::new();
    for g in &p.globals {
        let t = pr.ct(&g.ty);
        let q = if g.constant { "const " } else { "" };
        match &g.init {
            Some(init) => {
                let i = pr.init(init);
                let _ = writeln!(globals, "static {q}{t} {} = {i};", g.name);
            }
            None => {
                let _ = writeln!(globals, "static {q}{t} {};", g.name);
            }
        }
    }
    let mut out = String::from("/* duck ir: the program's MIR, printed as C-like text */\n\n");
    out.push_str("/* ---- types ---- */\n");
    out.push_str(&pr.types);
    out.push_str("\n/* ---- prototypes ---- */\n");
    out.push_str(&protos);
    out.push_str("\n/* ---- globals ---- */\n");
    out.push_str(&globals);
    out.push_str("\n/* ---- functions ---- */\n");
    out.push_str(&funcs);
    if let Some(e) = p.entry {
        let _ = writeln!(out, "int main(int argc, char **argv) {{\n    return {}(argc, argv);\n}}", p.funcs[e as usize].name);
    }
    out
}

impl Printer<'_, '_> {
    fn fresh(&mut self) -> usize {
        self.n += 1;
        self.n
    }

    // ---- types ----

    /// The C spelling of a type, defining it first if needed.
    fn ct(&mut self, t: &MTy) -> String {
        match t {
            MTy::Void => "void".into(),
            MTy::Bool => "bool".into(),
            MTy::I32 => "int32_t".into(),
            MTy::U32 => "uint32_t".into(),
            MTy::I64 => "int64_t".into(),
            MTy::U64 => "uint64_t".into(),
            MTy::CStr => "const char *".into(),
            MTy::Code => "void *".into(),
            MTy::Ptr(x) => match &**x {
                MTy::Rt(Rt::ElemOps) => "const DuckElemOps *".into(),
                x => {
                    let c = self.ct(x);
                    if c.ends_with('*') { format!("{c}*") } else { format!("{c} *") }
                }
            },
            MTy::Rt(r) => match r {
                Rt::StrBuf => "DuckStrBuf",
                Rt::Obj => "DuckObj",
                Rt::ElemOps => "DuckElemOps",
                Rt::Task => "DuckTask",
            }
            .into(),
            MTy::Agg(a) => {
                if let Some(n) = self.names.get(t) {
                    return n.clone();
                }
                let def = &self.p.aggs[*a as usize];
                let name = format!("{}_{a}", def.name);
                self.names.insert(t.clone(), name.clone());
                let mut body = String::new();
                for (i, f) in def.fields.clone().iter().enumerate() {
                    let c = self.ct(f);
                    let _ = writeln!(body, "    {c} f{i};");
                }
                if def.fields.is_empty() {
                    body.push_str("    int dummy;\n");
                }
                let _ = writeln!(self.types, "typedef struct {name} {{\n{body}}} {name};");
                name
            }
            MTy::D(t) => self.dt(t),
        }
    }

    fn dt(&mut self, t: &Ty) -> String {
        let info = self.info;
        match t {
            Ty::Int => "int64_t".into(),
            Ty::Float => "double".into(),
            Ty::Bool => "bool".into(),
            Ty::Char => "uint32_t".into(),
            Ty::Str => "DuckStr *".into(),
            Ty::Never => "DuckUnit".into(),
            Ty::Tuple(ts) if ts.is_empty() => "DuckUnit".into(),
            Ty::List(_) => "DuckArr *".into(),
            Ty::Map(..) => "DuckMap *".into(),
            Ty::Fn(..) => "DuckClosure".into(),
            Ty::Task(_) => "DuckTask *".into(),
            t if info.is_value(t) => "DuckValue".into(),
            t if info.opaque_c(t).is_some() => info.opaque_c(t).unwrap().to_string(),
            Ty::Opt(inner) => match &**inner {
                Ty::Int => "DuckOpt_int".into(),
                Ty::Float => "DuckOpt_float".into(),
                Ty::Bool => "DuckOpt_bool".into(),
                Ty::Char => "DuckOpt_char".into(),
                Ty::Str => "DuckOpt_str".into(),
                Ty::List(_) => "DuckOpt_arr".into(),
                x if info.is_value(x) => "DuckOpt_value".into(),
                _ => self.define(t),
            },
            Ty::Res(inner, _) => match &**inner {
                Ty::Tuple(ts) if ts.is_empty() => "DuckRes_unit".into(),
                Ty::Int => "DuckRes_int".into(),
                Ty::Float => "DuckRes_float".into(),
                Ty::Str => "DuckRes_str".into(),
                Ty::List(_) => "DuckRes_arr".into(),
                x if info.is_value(x) => "DuckRes_value".into(),
                x if info.opaque_c(x) == Some("DuckConn *") => "DuckRes_conn".into(),
                x if info.opaque_c(x) == Some("DuckListener *") => "DuckRes_listener".into(),
                _ => self.define(&Ty::res((**inner).clone(), Ty::unit())),
            },
            _ => self.define(t),
        }
    }

    fn define(&mut self, t: &Ty) -> String {
        let key = MTy::D(t.clone());
        if let Some(n) = self.names.get(&key) {
            return n.clone();
        }
        let k = self.fresh();
        let info = self.info;
        let mut body = String::new();
        let show = info.show_ty(t).replace("*/", "* /");
        let name = match t {
            Ty::Tuple(ts) => {
                let name = format!("DkTup{k}");
                for (i, x) in ts.iter().enumerate() {
                    let c = self.dt(x);
                    let _ = writeln!(body, "    {c} f{i};");
                }
                let _ = writeln!(self.types, "/* {show} */\ntypedef struct {name} {{\n{body}}} {name};");
                name
            }
            Ty::Opt(inner) => {
                let c = self.dt(inner);
                let name = format!("DkOpt{k}");
                let _ = writeln!(self.types, "/* {show} */\nDUCK_DEF_OPT({name}, {c});");
                name
            }
            Ty::Res(inner, _) => {
                let c = self.dt(inner);
                let name = format!("DkRes{k}");
                let _ = writeln!(self.types, "/* {show} */\nDUCK_DEF_RES({name}, {c});");
                name
            }
            Ty::Named(d, _) => {
                let def = &info.tp.defs.types[*d];
                let dname: String = def.name.chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '_' }).collect();
                match &def.kind {
                    TypeDefKind::Struct { .. } => {
                        let name = format!("DkS{k}_{dname}");
                        for (i, (ft, boxed)) in info.struct_layout(t).iter().enumerate() {
                            let c = if *boxed { "DuckObj *".to_string() } else { self.dt(ft) };
                            let _ = writeln!(body, "    {c} f{i};");
                        }
                        if body.is_empty() {
                            body.push_str("    DuckUnit dummy;\n");
                        }
                        let _ = writeln!(self.types, "/* {show} */\ntypedef struct {name} {{\n{body}}} {name};");
                        name
                    }
                    TypeDefKind::Enum { .. } => {
                        let name = format!("DkE{k}_{dname}");
                        let mut un = String::new();
                        for (vi, fs) in info.enum_layout(t).iter().enumerate() {
                            if fs.is_empty() {
                                continue;
                            }
                            let mut st = String::new();
                            for (fi, (ft, boxed)) in fs.iter().enumerate() {
                                let c = if *boxed { "DuckObj *".to_string() } else { self.dt(ft) };
                                let _ = write!(st, " {c} f{fi};");
                            }
                            let _ = writeln!(un, "        struct {{{st} }} v{vi};");
                        }
                        if un.is_empty() {
                            let _ = writeln!(self.types, "/* {show} */\ntypedef struct {name} {{\n    int32_t tag;\n}} {name};");
                        } else {
                            let _ = writeln!(self.types, "/* {show} */\ntypedef struct {name} {{\n    int32_t tag;\n    union {{\n{un}    }} u;\n}} {name};");
                        }
                        name
                    }
                    TypeDefKind::Opaque { c_type } => c_type.clone(),
                }
            }
            Ty::Any(_) => {
                let name = format!("DkAny{k}");
                let _ = writeln!(self.types, "typedef struct {name} {{\n    DuckObj *f0;\n    const void *f1;\n}} {name};");
                name
            }
            _ => panic!("c: can't define {}", info.show_ty(t)),
        };
        self.names.insert(key, name.clone());
        name
    }

    /// The C member path of `sel` in a value of type `t`.
    fn member(&self, t: &MTy, sel: Sel) -> String {
        let info = self.info;
        match (t, sel) {
            (MTy::Agg(_), Sel::F(i)) => format!("f{i}"),
            (MTy::Rt(Rt::ElemOps), Sel::F(i)) => ["size", "retain", "release", "eq", "cmp", "hash", "show", "copy"][i as usize].into(),
            (MTy::D(t), sel) => match (t, sel) {
                (Ty::Opt(_), Sel::F(0)) => "some".into(),
                (Ty::Opt(_), Sel::F(1)) | (Ty::Res(..), Sel::F(1)) => "val".into(),
                (Ty::Res(..), Sel::F(0)) => "ok".into(),
                (Ty::Res(..), Sel::F(2)) => "err".into(),
                (Ty::Fn(..), Sel::F(0)) => "fn".into(),
                (Ty::Fn(..), Sel::F(1)) => "env".into(),
                (_, Sel::Tag) => "tag".into(),
                (t, Sel::V(vi, _)) if info.is_value(t) => format!("u.{}", ["", "b", "i", "f", "s", "list", "map"][vi as usize]),
                (_, Sel::V(vi, fi)) => format!("u.v{vi}.f{fi}"),
                (_, Sel::F(i)) => format!("f{i}"),
            },
            _ => panic!("c: no member {sel:?} of {t:?}"),
        }
    }

    // ---- functions ----

    fn sig(&mut self, f: &Func) -> String {
        let r = self.ct(&f.ret);
        let mut ps = Vec::new();
        for &v in &f.params {
            let t = self.ct(&f.vars[v as usize]);
            ps.push(format!("{t} v{v}"));
        }
        let ps = if ps.is_empty() { "void".to_string() } else { ps.join(", ") };
        format!("static {r} {}({ps})", f.name)
    }

    fn body(&mut self, f: &Func) -> String {
        let mut out = String::new();
        for (v, t) in f.vars.iter().enumerate() {
            if f.params.contains(&(v as u32)) {
                continue;
            }
            let c = self.ct(t);
            let _ = writeln!(out, "    {c} v{v};");
        }
        for (v, _) in f.vars.iter().enumerate() {
            if !f.params.contains(&(v as u32)) {
                let _ = writeln!(out, "    (void)v{v};");
            }
        }
        for &v in &f.params {
            let _ = writeln!(out, "    (void)v{v};");
        }
        self.stmts(&f.body, 1, &mut out);
        out
    }

    fn stmts(&mut self, ss: &[Stmt], ind: usize, out: &mut String) {
        for s in ss {
            self.stmt(s, ind, out);
        }
    }

    fn stmt(&mut self, s: &Stmt, ind: usize, out: &mut String) {
        let pad = "    ".repeat(ind);
        match s {
            Stmt::Let(v, e) => {
                let e = self.ex(e);
                let _ = writeln!(out, "{pad}v{v} = {e};");
            }
            Stmt::Set(p, e) => {
                let (p, e) = (self.ex(p), self.ex(e));
                let _ = writeln!(out, "{pad}{p} = {e};");
            }
            Stmt::Do(e) => {
                let e = self.ex(e);
                let _ = writeln!(out, "{pad}{e};");
            }
            Stmt::If(c, a, b) => {
                let c = self.ex(c);
                let _ = writeln!(out, "{pad}if ({c}) {{");
                self.stmts(a, ind + 1, out);
                if b.is_empty() {
                    let _ = writeln!(out, "{pad}}}");
                } else {
                    let _ = writeln!(out, "{pad}}} else {{");
                    self.stmts(b, ind + 1, out);
                    let _ = writeln!(out, "{pad}}}");
                }
            }
            Stmt::Loop(body, latch) => {
                let l = self.fresh();
                self.conts.push(l);
                let _ = writeln!(out, "{pad}for (;;) {{");
                self.stmts(body, ind + 1, out);
                self.conts.pop();
                let _ = writeln!(out, "{pad}dk_c{l}:;");
                self.stmts(latch, ind + 1, out);
                let _ = writeln!(out, "{pad}}}");
            }
            Stmt::Break => {
                let _ = writeln!(out, "{pad}break;");
            }
            Stmt::Continue => {
                let l = *self.conts.last().expect("continue outside a loop");
                let _ = writeln!(out, "{pad}goto dk_c{l};");
            }
            Stmt::Label(0) => {
                let _ = writeln!(out, "dk_tail:;");
            }
            Stmt::Goto(0) => {
                let _ = writeln!(out, "{pad}goto dk_tail;");
            }
            Stmt::Label(l) => {
                let _ = writeln!(out, "dk_l{l}:;");
            }
            Stmt::Goto(l) => {
                let _ = writeln!(out, "{pad}goto dk_l{l};");
            }
            Stmt::Ret(None) => {
                let _ = writeln!(out, "{pad}return;");
            }
            Stmt::Ret(Some(e)) => {
                let e = self.ex(e);
                let _ = writeln!(out, "{pad}return {e};");
            }
            Stmt::Unreachable => {
                let _ = writeln!(out, "{pad}__builtin_unreachable();");
            }
        }
    }

    // ---- expressions ----

    fn is_int(t: &MTy) -> bool {
        matches!(t, MTy::I32 | MTy::U32 | MTy::I64 | MTy::U64 | MTy::D(Ty::Int) | MTy::D(Ty::Char))
    }

    fn ex(&mut self, e: &Ex) -> String {
        match &e.k {
            K::Var(v) => format!("v{v}"),
            K::Global(g) => self.p.globals[*g as usize].name.clone(),
            K::Int(n) => match &e.ty {
                MTy::Bool | MTy::D(Ty::Bool) => (if *n != 0 { "true" } else { "false" }).into(),
                MTy::I64 | MTy::D(Ty::Int) => {
                    if *n == i64::MIN {
                        "INT64_MIN".into()
                    } else {
                        format!("INT64_C({n})")
                    }
                }
                MTy::U64 => format!("UINT64_C({})", *n as u64),
                MTy::U32 | MTy::D(Ty::Char) => format!("UINT32_C({})", *n as u32),
                t if matches!(t, MTy::D(_)) && !Self::is_int(t) && !matches!(t, MTy::D(Ty::Float)) => "0".into(),
                t => {
                    let c = self.ct(t);
                    format!("(({c}){n})")
                }
            },
            K::Float(x) => {
                if x.is_nan() {
                    "(__builtin_nan(\"\"))".into()
                } else if x.is_infinite() {
                    if *x > 0.0 { "(__builtin_inf())".into() } else { "(-__builtin_inf())".into() }
                } else {
                    let mut s = format!("{x:?}");
                    if !s.contains('.') && !s.contains('e') {
                        s.push_str(".0");
                    }
                    format!("({s})")
                }
            }
            K::CStr(s) => c_str(s),
            K::Zero => {
                let c = self.ct(&e.ty);
                if c.ends_with('*') {
                    "NULL".into()
                } else if matches!(e.ty, MTy::Agg(_) | MTy::Rt(_)) || matches!(&e.ty, MTy::D(t) if !self.info.is_scalar(t)) {
                    format!("(({c}){{0}})")
                } else {
                    format!("(({c})0)")
                }
            }
            K::FnAddr(f) => match f {
                FRef::Fn(f) => format!("((void *){})", self.p.funcs[*f as usize].name),
                FRef::Rt(s) => format!("((void *){s})"),
            },
            K::GlobalAddr(g) => format!("((void *)&{})", self.p.globals[*g as usize].name),
            K::RtGlobalAddr(s) => format!("(&{s})"),
            K::Field(b, s) => {
                let m = self.member(&b.ty, *s);
                let b = self.ex(b);
                format!("({b}).{m}")
            }
            K::Deref(p) => {
                let pt = self.ct(&MTy::ptr(e.ty.clone()));
                let p = self.ex(p);
                format!("(*({pt})({p}))")
            }
            K::Addr(p) => {
                let p = self.ex(p);
                format!("(&{p})")
            }
            K::Un(op, a) => {
                let a = self.ex(a);
                match op {
                    UOp::Not => format!("(!({a}))"),
                    UOp::Neg => format!("(-({a}))"),
                    UOp::BitNot => format!("(~({a}))"),
                }
            }
            K::Bin(op, a, b) => {
                let int = Self::is_int(&a.ty);
                let (x, y) = (self.ex(a), self.ex(b));
                let sym = match op {
                    BOp::Add => "+",
                    BOp::Sub => "-",
                    BOp::Mul => "*",
                    BOp::Div => "/",
                    BOp::BitAnd => "&",
                    BOp::BitOr => "|",
                    BOp::BitXor => "^",
                    BOp::Eq => "==",
                    BOp::Ne => "!=",
                    BOp::Lt => "<",
                    BOp::Le => "<=",
                    BOp::Gt => ">",
                    BOp::Ge => ">=",
                };
                if int && matches!(op, BOp::Add | BOp::Sub | BOp::Mul) {
                    // wrapping integer arithmetic
                    let t = self.ct(&e.ty);
                    format!("(({t})((uint64_t)({x}) {sym} (uint64_t)({y})))")
                } else {
                    format!("(({x}) {sym} ({y}))")
                }
            }
            K::And(xs) => {
                let parts: Vec<String> = xs.iter().map(|x| format!("({})", self.ex(x))).collect();
                format!("({})", parts.join(" && "))
            }
            K::Cast(x) => {
                let (from, to) = (self.ct(&x.ty), self.ct(&e.ty));
                let s = self.ex(x);
                if from == to { s } else { format!("(({to})({s}))") }
            }
            K::Call(c, args) => {
                let a: Vec<String> = args.iter().map(|x| self.ex(x)).collect();
                let a = a.join(", ");
                match c {
                    Callee::Fn(f) => format!("{}({a})", self.p.funcs[*f as usize].name),
                    Callee::Rt(s) => format!("{s}({a})"),
                    Callee::Indirect(code, ps) => {
                        let r = self.ct(&e.ty);
                        let ps: Vec<String> = ps.iter().map(|t| self.ct(t)).collect();
                        let code = self.ex(code);
                        format!("(({r} (*)({}))({code}))({a})", ps.join(", "))
                    }
                }
            }
            K::Agg(ms) => {
                let c = self.ct(&e.ty);
                if ms.is_empty() {
                    return format!("(({c}){{0}})");
                }
                let parts: Vec<String> = ms
                    .iter()
                    .map(|(s, v)| {
                        let m = self.member(&e.ty, *s);
                        format!(".{m} = {}", self.ex(v))
                    })
                    .collect();
                format!("(({c}){{{}}})", parts.join(", "))
            }
            K::Cond(c, a, b) => {
                let (c, a, b) = (self.ex(c), self.ex(a), self.ex(b));
                format!("(({c}) ? ({a}) : ({b}))")
            }
            K::Elem(arr, i) => {
                let t = self.ct(&e.ty);
                let (arr, i) = (self.ex(arr), self.ex(i));
                format!("((({t} *)({arr})->data)[{i}])")
            }
            K::RtField(p, f) => {
                let p = self.ex(p);
                let m = match f {
                    RtF::ArrLen => "len",
                    RtF::ArrData => "data",
                    RtF::ErrMsg => "msg",
                };
                format!("(({p})->{m})")
            }
            K::SizeOf(t) => {
                let c = self.ct(t);
                format!("sizeof({c})")
            }
        }
    }

    /// A constant initializer (for a global).
    fn init(&mut self, e: &Ex) -> String {
        match &e.k {
            K::Agg(ms) => {
                let parts: Vec<String> = ms
                    .iter()
                    .map(|(s, v)| {
                        let m = self.member(&e.ty, *s);
                        format!(".{m} = {}", self.ex(v))
                    })
                    .collect();
                if parts.is_empty() { "{0}".into() } else { format!("{{{}}}", parts.join(", ")) }
            }
            _ => self.ex(e),
        }
    }
}

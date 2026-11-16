//! C code generation, program level: the C representation of every Duck type, refcounting
//! helpers, element-ops vtables, the compiler-derived instances of the built-in shapes
//! (`Show`, `Eq`, `Ord`, hashing, `to_value` / `from_value`), string literals, constants, the
//! `main` shim and test registration. Function bodies are lowered by `lower.rs`.
//!
//! # Output layout
//! One C file: `#include "duck.h"`, then four sections that are filled on demand while bodies
//! are lowered and concatenated at the end:
//! 1. **types**: typedefs in dependency order (a type's by-value components come first);
//! 2. **protos**: prototypes of every generated function and tentative definitions of the
//!    element-ops tables;
//! 3. **ops**: the element-ops tables (`DuckElemOps`), vtables and literal/constant globals;
//! 4. **funcs**: function bodies.
//!
//! # Representation (see runtime/duck.h)
//! - `int float bool char str` → `int64_t double bool uint32_t DuckStr *`; `()` and `never` →
//!   `DuckUnit`; `[T]` → `DuckArr *`; `{K: V}` → `DuckMap *`; closures → `DuckClosure`; tasks →
//!   `DuckTask *`; opaque runtime types use their `extern type` spelling; core `Value` is the
//!   runtime's `DuckValue` (same variant order).
//! - `T?` → `DUCK_DEF_OPT`, `T!`/`T!E` → `DUCK_DEF_RES` (the runtime's own `DuckOpt_*`/`DuckRes_*`
//!   where one exists, so externs link directly). A `T!E` error is a `DuckErr` whose typed payload
//!   holds the `E` value (type id from `type_id`), so converting `T!E` to `T!` is free and
//!   `err(BadUrl(w))` matches after conversion.
//! - tuples and structs are C structs (fields `f0..` / `f_<name>`); enums are `{int32_t tag; union
//!   {struct {..} vK;} u;}`; a variant field whose type contains the enum by value is boxed (a
//!   `DuckObj` cell `DkBox*`).
//! - `any S` is `{DuckObj *obj; const void *vt}`: a boxed value plus the vtable of its type.
//!
//! # Ownership
//! The runtime's rules: arguments are borrowed, results are owned (+1). `retain`/`release` give
//! the C statements that copy/drop a value of any type.

use std::collections::{HashMap, HashSet};
use std::fmt::Write;

use super::ast::Item;
use super::resolve::ModId;
use super::typed::{BodyRef, ConstId, FnKind, InstId, Target, TypedProgram};
use super::types::{Builtin, DefId, ShapeId, Ty, TypeDefKind};

/// What kind of executable is being built.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// `duck run` / `duck ir`: debug build (ensures checked), entry point `main`.
    Run,
    /// `duck build`: release build (ensures not checked).
    Release,
    /// `duck test`: debug build, entry point is the test runner.
    Test,
}

/// Execution-trace instrumentation (`duck run --trace`, `duck test --trace`). With `on` unset
/// (every other build) the generated C is exactly what it would be without tracing.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Trace {
    /// Wrap the traced functions, set call sites, and start the tracer in `main`.
    pub on: bool,
    /// Trace the core library's Duck functions too (by default only the program's and its
    /// dependencies' functions are traced).
    pub core: bool,
}

/// Escape bytes as the contents of a C string literal (octal escapes keep it unambiguous).
pub fn c_str(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for &b in s.as_bytes() {
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

/// A C identifier fragment from a Duck name.
pub fn sanitize(s: &str) -> String {
    s.chars().map(|c| if c.is_ascii_alphanumeric() || c == '_' { c } else { '_' }).collect()
}

pub struct Gen<'a> {
    pub tp: &'a TypedProgram,
    pub mode: Mode,
    pub types: String,
    pub protos: String,
    pub ops_defs: String,
    pub funcs: String,
    ctypes: HashMap<Ty, String>,
    rc: HashMap<Ty, bool>,
    memo: HashMap<(&'static str, Ty), String>,
    /// Other memoized generated functions (thunks, function values, vtables), by key.
    pub memo2: HashMap<String, String>,
    lits: Vec<String>,
    lit_index: HashMap<String, usize>,
    type_ids: HashMap<Ty, u32>,
    n: usize,
    pub value_def: Option<DefId>,
    /// Instance ids that have been emitted (or are being emitted).
    pub emitted: HashSet<InstId>,
    /// Instances still to emit (requested by calls, function values, thunks...).
    pub queue: Vec<InstId>,
    /// `(inst) -> name` of each instance's C function.
    inst_names: HashMap<InstId, String>,
    /// Holes found in emitted bodies: "file:line:col: unfilled hole (expected T)".
    pub holes: Vec<String>,
    /// Constants: (const id) -> getter name.
    consts: HashMap<usize, String>,
    const_order: Vec<(usize, String, Ty)>,
    /// The imprint helper program (build.rs `eval_imprints`): constant getters report on the
    /// imprint protocol stream (`dk_out`) when they start and finish and when one is re-entered
    /// (a cycle), and `to_value` is always the derived, structural one.
    pub imprint_eval: bool,
    /// The compile-time values of the imprints (final program): each becomes a global built
    /// from data at startup out of immortal objects; its initializer is never run.
    pub imprints: HashMap<ConstId, CVal>,
    /// The functions that build the imprint globals, called first in `dk_init`.
    imprint_inits: Vec<String>,
    /// Execution-trace instrumentation.
    pub trace: Trace,
}

/// A value computed at compile time: the `Value` tree of an evaluated imprint.
#[derive(Debug, Clone, PartialEq)]
pub enum CVal {
    Null,
    Bool(bool),
    Int(i64),
    Float(f64),
    Str(String),
    List(Vec<CVal>),
    Map(Vec<(String, CVal)>),
}

impl CVal {
    fn field(&self, key: &str) -> Option<&CVal> {
        match self {
            CVal::Map(es) => es.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }
}

/// A C literal for an int.
fn int_lit(n: i64) -> String {
    if n == i64::MIN { "INT64_MIN".into() } else { format!("INT64_C({n})") }
}

/// A C literal for a float that reads back to the same bits.
fn float_lit(x: f64) -> String {
    if x.is_nan() {
        return "(__builtin_nan(\"\"))".into();
    }
    if x.is_infinite() {
        return if x > 0.0 { "(__builtin_inf())".into() } else { "(-__builtin_inf())".into() };
    }
    let mut s = format!("{x:?}");
    if !s.contains('.') && !s.contains('e') {
        s.push_str(".0");
    }
    format!("({s})")
}

impl<'a> Gen<'a> {
    pub fn new(tp: &'a TypedProgram, mode: Mode) -> Gen<'a> {
        let value_def = tp
            .defs
            .types
            .iter()
            .position(|d| d.name == "Value" && tp.program.is_core(d.module) && matches!(d.kind, TypeDefKind::Enum { .. }));
        Gen {
            tp,
            mode,
            types: String::new(),
            protos: String::new(),
            ops_defs: String::new(),
            funcs: String::new(),
            ctypes: HashMap::new(),
            rc: HashMap::new(),
            memo: HashMap::new(),
            memo2: HashMap::new(),
            lits: Vec::new(),
            lit_index: HashMap::new(),
            type_ids: HashMap::new(),
            n: 0,
            value_def,
            emitted: HashSet::new(),
            queue: Vec::new(),
            inst_names: HashMap::new(),
            holes: Vec::new(),
            consts: HashMap::new(),
            const_order: Vec::new(),
            imprint_eval: false,
            imprints: HashMap::new(),
            imprint_inits: Vec::new(),
            trace: Trace::default(),
        }
    }

    /// Is a function of module `m` traced?
    pub fn traced(&self, m: ModId) -> bool {
        self.trace.on && (self.trace.core || !self.tp.program.is_core(m))
    }

    pub fn debug(&self) -> bool {
        self.mode != Mode::Release
    }

    pub fn fresh(&mut self) -> usize {
        self.n += 1;
        self.n
    }

    pub fn show_ty(&self, t: &Ty) -> String {
        self.tp.defs.show(t)
    }

    pub fn is_value(&self, t: &Ty) -> bool {
        matches!(t, Ty::Named(d, _) if Some(*d) == self.value_def)
    }

    pub fn is_err_ty(&self, t: &Ty) -> bool {
        self.tp.defs.is_err(t)
    }

    // ---- names of instances ----

    /// The C function name of an instance (requesting its emission).
    pub fn inst_fn(&mut self, i: InstId) -> String {
        if let Some(n) = self.inst_names.get(&i) {
            return n.clone();
        }
        let what = match self.tp.instances[i].body {
            BodyRef::Fn(f) => sanitize(&self.tp.fns[f].name),
            BodyRef::Test(_) => "test".to_string(),
            BodyRef::Const(c) => format!("const_{}", sanitize(&self.tp.consts[c].name)),
        };
        let name = format!("dk_f{i}_{what}");
        self.inst_names.insert(i, name.clone());
        if !self.emitted.contains(&i) {
            self.queue.push(i);
        }
        name
    }

    /// The return type of instance `i` (its function's return type, substituted).
    pub fn inst_ret(&self, i: InstId) -> Ty {
        let inst = &self.tp.instances[i];
        match inst.body {
            BodyRef::Fn(f) => self.tp.fns[f].ret.subst(&inst.subst(&self.tp.fns)),
            BodyRef::Test(_) => Ty::res(Ty::unit(), self.err_ty()),
            BodyRef::Const(c) => self.tp.consts[c].ty.clone(),
        }
    }

    /// The parameter types of instance `i` (with `var` flags).
    pub fn inst_params(&self, i: InstId) -> Vec<(Ty, bool)> {
        let inst = &self.tp.instances[i];
        match inst.body {
            BodyRef::Fn(f) => {
                let s = inst.subst(&self.tp.fns);
                self.tp.fns[f].params.iter().map(|p| (p.ty.subst(&s), p.var)).collect()
            }
            _ => Vec::new(),
        }
    }

    pub fn err_ty(&self) -> Ty {
        let d = self.tp.defs.types.iter().position(|d| d.name == "Err" && matches!(d.kind, TypeDefKind::Opaque { .. })).unwrap_or(0);
        Ty::Named(d, Vec::new())
    }

    /// The getter of a constant (`T dk_const_N(void)`, returns a borrowed value).
    pub fn const_getter(&mut self, c: usize) -> String {
        if let Some(n) = self.consts.get(&c) {
            return n.clone();
        }
        let name = format!("dk_const{c}_{}", sanitize(&self.tp.consts[c].name));
        self.consts.insert(c, name.clone());
        let ty = self.tp.consts[c].ty.clone();
        let ct = self.ct(&ty);
        if let Some(v) = self.imprints.get(&c).cloned() {
            // computed at compile time: rebuilt from its value at startup (no initializer runs)
            let mut code = String::new();
            let e = self.imprint_value(&ty, &v, &mut code);
            let _ = writeln!(self.protos, "static {ct} {name}(void);\nstatic void {name}_init(void);");
            let _ = writeln!(self.ops_defs, "static {ct} {name}_v;");
            let _ = writeln!(
                self.funcs,
                "static {ct} {name}(void) {{\n    return {name}_v;\n}}\n/* imprint {}: its value, computed at compile time */\nstatic void {name}_init(void) {{\n{code}    {name}_v = {e};\n}}\n",
                self.tp.consts[c].name
            );
            self.imprint_inits.push(format!("{name}_init"));
            return name;
        }
        let inst = self.tp.instances.iter().position(|i| i.body == BodyRef::Const(c)).expect("constant instance");
        let init = self.inst_fn(inst);
        let _ = writeln!(self.protos, "static {ct} {name}(void);");
        let _ = writeln!(self.ops_defs, "static {ct} {name}_v;\nstatic int {name}_s;");
        let rel = self.release(&ty, &format!("{name}_v")).unwrap_or_default();
        // the imprint helper reports progress (to attribute a panic) and cycles
        let (enter, start, done) = if self.imprint_eval {
            (
                format!("    if ({name}_s == 1) {{\n        fputs(\"C{c}\\n\", dk_out);\n        fflush(dk_out);\n        exit(3);\n    }}\n"),
                format!("\n        fputs(\"B{c}\\n\", dk_out);\n        fflush(dk_out);"),
                format!("\n        fputs(\"E{c}\\n\", dk_out);\n        fflush(dk_out);"),
            )
        } else {
            Default::default()
        };
        let _ = writeln!(
            self.funcs,
            "static {ct} {name}(void) {{\n{enter}    if ({name}_s == 0) {{\n        {name}_s = 1;{start}\n        {name}_v = {init}();\n        {name}_s = 2;{done}\n    }}\n    return {name}_v;\n}}\nstatic void {name}_free(void) {{\n    if ({name}_s == 2) {{ {rel} }}\n    {name}_s = 0;\n}}\n"
        );
        self.const_order.push((c, name.clone(), ty));
        name
    }

    /// A C expression for the compile-time value `v` of type `t`, built (by statements appended
    /// to `code`) from immortal objects: literal strings, and lists, maps and boxes made immortal.
    /// The reverse of the derived `to_value`, like `from_value`.
    fn imprint_value(&mut self, t: &Ty, v: &CVal, code: &mut String) -> String {
        match t {
            Ty::Int => match v {
                CVal::Int(n) => int_lit(*n),
                _ => "0".into(),
            },
            Ty::Float => match v {
                CVal::Float(x) => float_lit(*x),
                CVal::Int(n) => float_lit(*n as f64),
                _ => "0.0".into(),
            },
            Ty::Bool => (if *v == CVal::Bool(true) { "true" } else { "false" }).into(),
            Ty::Char => match v {
                CVal::Str(s) => format!("UINT32_C({})", s.chars().next().map_or(0, |c| c as u32)),
                _ => "0".into(),
            },
            Ty::Str => match v {
                CVal::Str(s) => self.lit(s),
                _ => self.lit(""),
            },
            t if self.is_value(t) => self.imprint_dvalue(v, code),
            Ty::List(et) => {
                let xs = match v {
                    CVal::List(xs) => xs.as_slice(),
                    _ => &[],
                };
                let es: Vec<String> = xs.iter().map(|x| self.imprint_value(et, x, code)).collect();
                let (ops, ct) = (self.ops(et), self.ct(et));
                let init = if es.is_empty() {
                    format!("duck_arr_new({ops}, 0)")
                } else {
                    format!("duck_arr_from({ops}, ({ct}[]){{{}}}, {})", es.join(", "), es.len())
                };
                self.imprint_obj("DuckArr *", &init, code)
            }
            Ty::Map(kt, vt) => {
                let (ko, vo) = (self.ops(kt), self.ops(vt));
                let m = format!("o{}", self.fresh());
                let _ = writeln!(code, "    DuckMap *{m} = duck_map_new({ko}, {vo});");
                if let CVal::Map(es) = v {
                    let vc = self.ct(vt);
                    for (k, x) in es {
                        let kc = self.lit(k);
                        let xc = self.imprint_value(vt, x, code);
                        let _ = writeln!(code, "    {{\n        DuckStr *k = {kc};\n        {vc} v = {xc};\n        duck_map_set(&{m}, &k, &v);\n    }}");
                    }
                }
                // immortal only once filled (setting into an immortal map would copy it)
                let _ = writeln!(code, "    duck_make_immortal({m});");
                m
            }
            Ty::Opt(inner) => match v {
                CVal::Null => self.zero(t),
                _ => {
                    let e = self.imprint_value(inner, v, code);
                    let ct = self.ct(t);
                    format!("(({ct}){{.some = true, .val = {e}}})")
                }
            },
            Ty::Named(d, _) if self.tp.defs.is_struct(*d) => {
                let names: Vec<String> = self.tp.defs.fields(*d).iter().map(|f| f.name.clone()).collect();
                let mut parts = Vec::new();
                for (i, (member, ft, boxed)) in self.struct_layout(t).into_iter().enumerate() {
                    let fv = v.field(&names[i]).cloned().unwrap_or(CVal::Null);
                    let e = self.imprint_value(&ft, &fv, code);
                    let e = if boxed { self.imprint_box(&ft, &e, code) } else { e };
                    parts.push(format!(".{member} = {e}"));
                }
                if parts.is_empty() {
                    parts.push(".dummy = 0".into());
                }
                let ct = self.ct(t);
                format!("(({ct}){{{}}})", parts.join(", "))
            }
            Ty::Named(d, _) if self.tp.defs.is_enum(*d) => {
                let vs = self.tp.defs.variants(*d).to_vec();
                let tag = match v {
                    CVal::Str(s) => Some(s.as_str()),
                    _ => match v.field("tag") {
                        Some(CVal::Str(s)) => Some(s.as_str()),
                        _ => None,
                    },
                };
                let vi = tag.and_then(|n| vs.iter().position(|x| x.name == n)).unwrap_or(0);
                let layout = self.enum_layout(t);
                let ct = self.ct(t);
                let mut parts = vec![format!(".tag = {vi}")];
                for (fi, (fname, _)) in vs[vi].fields.iter().enumerate() {
                    let key = fname.clone().unwrap_or_else(|| fi.to_string());
                    let fv = v.field(&key).cloned().unwrap_or(CVal::Null);
                    let (ft, boxed) = layout[vi][fi].clone();
                    let e = self.imprint_value(&ft, &fv, code);
                    let e = if boxed { self.imprint_box(&ft, &e, code) } else { e };
                    parts.push(format!(".u.v{vi}.f{fi} = {e}"));
                }
                format!("(({ct}){{{}}})", parts.join(", "))
            }
            _ => self.zero(t),
        }
    }

    /// A core `Value` built from a compile-time value.
    fn imprint_dvalue(&mut self, v: &CVal, code: &mut String) -> String {
        match v {
            CVal::Null => "duck_value_null()".into(),
            CVal::Bool(b) => format!("duck_value_bool({b})"),
            CVal::Int(n) => format!("duck_value_int({})", int_lit(*n)),
            CVal::Float(x) => format!("duck_value_float({})", float_lit(*x)),
            CVal::Str(s) => format!("duck_value_str({})", self.lit(s)),
            CVal::List(xs) => {
                let es: Vec<String> = xs.iter().map(|x| self.imprint_dvalue(x, code)).collect();
                let init = if es.is_empty() {
                    "duck_value_list_new()".to_string()
                } else {
                    format!("duck_arr_from(&duck_ops_value, (DuckValue[]){{{}}}, {})", es.join(", "), es.len())
                };
                let a = self.imprint_obj("DuckArr *", &init, code);
                format!("duck_value_list({a})")
            }
            CVal::Map(es) => {
                let m = format!("o{}", self.fresh());
                let _ = writeln!(code, "    DuckMap *{m} = duck_value_map_new();");
                for (k, x) in es {
                    let kc = self.lit(k);
                    let xc = self.imprint_dvalue(x, code);
                    let _ = writeln!(code, "    {{\n        DuckStr *k = {kc};\n        DuckValue v = {xc};\n        duck_map_set(&{m}, &k, &v);\n    }}");
                }
                let _ = writeln!(code, "    duck_make_immortal({m});");
                format!("duck_value_map({m})")
            }
        }
    }

    /// A box holding the value `e` (of type `t`), made immortal.
    fn imprint_box(&mut self, t: &Ty, e: &str, code: &mut String) -> String {
        let b = self.box_new(t, e);
        self.imprint_obj("DuckObj *", &b, code)
    }

    /// Declare a heap object of an imprint (C type `ct`) and make it immortal.
    fn imprint_obj(&mut self, ct: &str, init: &str, code: &mut String) -> String {
        let n = format!("o{}", self.fresh());
        let _ = writeln!(code, "    {ct}{}{n} = {init};\n    duck_make_immortal({n});", if ct.ends_with('*') { "" } else { " " });
        n
    }

    // ---- string literals ----

    /// The global holding an immortal `DuckStr` for this text.
    pub fn lit(&mut self, s: &str) -> String {
        if let Some(&i) = self.lit_index.get(s) {
            return format!("dk_lit{i}");
        }
        let i = self.lits.len();
        self.lits.push(s.to_string());
        self.lit_index.insert(s.to_string(), i);
        format!("dk_lit{i}")
    }

    /// A small stable id for a typed error payload type.
    pub fn type_id(&mut self, t: &Ty) -> u32 {
        let n = self.type_ids.len() as u32 + 1;
        *self.type_ids.entry(t.clone()).or_insert(n)
    }

    // ---- C types ----

    /// The C spelling of a type, defining it first if needed.
    pub fn ct(&mut self, t: &Ty) -> String {
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
            Ty::Named(d, _) if Some(*d) == self.value_def => "DuckValue".into(),
            Ty::Named(d, _) if matches!(self.tp.defs.types[*d].kind, TypeDefKind::Opaque { .. }) => {
                let TypeDefKind::Opaque { c_type } = &self.tp.defs.types[*d].kind else { unreachable!() };
                c_type.clone()
            }
            Ty::Opt(inner) => match &**inner {
                Ty::Int => "DuckOpt_int".into(),
                Ty::Float => "DuckOpt_float".into(),
                Ty::Bool => "DuckOpt_bool".into(),
                Ty::Char => "DuckOpt_char".into(),
                Ty::Str => "DuckOpt_str".into(),
                Ty::List(_) => "DuckOpt_arr".into(),
                x if self.is_value(x) => "DuckOpt_value".into(),
                _ => self.define(t),
            },
            Ty::Res(inner, _) => match &**inner {
                Ty::Tuple(ts) if ts.is_empty() => "DuckRes_unit".into(),
                Ty::Int => "DuckRes_int".into(),
                Ty::Float => "DuckRes_float".into(),
                Ty::Str => "DuckRes_str".into(),
                Ty::List(_) => "DuckRes_arr".into(),
                x if self.is_value(x) => "DuckRes_value".into(),
                Ty::Named(d, _) if matches!(self.tp.defs.types[*d].kind, TypeDefKind::Opaque { .. }) && self.tp.defs.types[*d].name == "Conn" => {
                    "DuckRes_conn".into()
                }
                Ty::Named(d, _) if matches!(self.tp.defs.types[*d].kind, TypeDefKind::Opaque { .. }) && self.tp.defs.types[*d].name == "Listener" => {
                    "DuckRes_listener".into()
                }
                _ => self.define(&Ty::res((**inner).clone(), Ty::unit())),
            },
            Ty::Param(_) | Ty::Var(_) | Ty::Error => panic!("codegen: non-concrete type {}", self.show_ty(t)),
            _ => self.define(t),
        }
    }

    fn define(&mut self, t: &Ty) -> String {
        if let Some(n) = self.ctypes.get(t) {
            return n.clone();
        }
        let k = self.fresh();
        let mut body = String::new();
        let name = match t {
            Ty::Tuple(ts) => {
                let name = format!("DkTup{k}");
                for (i, x) in ts.iter().enumerate() {
                    let c = self.ct(x);
                    let _ = writeln!(body, "    {c} f{i};");
                }
                let _ = writeln!(self.types, "/* {} */\ntypedef struct {name} {{\n{body}}} {name};", self.show_ty(t));
                name
            }
            Ty::Opt(inner) => {
                let c = self.ct(inner);
                let name = format!("DkOpt{k}");
                let _ = writeln!(self.types, "/* {} */\nDUCK_DEF_OPT({name}, {c});", self.show_ty(t));
                name
            }
            Ty::Res(inner, _) => {
                let c = self.ct(inner);
                let name = format!("DkRes{k}");
                let _ = writeln!(self.types, "/* {}! */\nDUCK_DEF_RES({name}, {c});", self.show_ty(inner));
                name
            }
            Ty::Named(d, args) => {
                let def = &self.tp.defs.types[*d];
                let s = self.tp.defs.subst_of(*d, args);
                match &def.kind {
                    TypeDefKind::Struct { fields } => {
                        let name = format!("DkS{k}_{}", sanitize(&def.name));
                        let fields = fields.clone();
                        let layout = self.struct_layout(t);
                        for (f, (_, ft, boxed)) in fields.iter().zip(&layout) {
                            let c = if *boxed { "DuckObj *".to_string() } else { self.ct(ft) };
                            let _ = writeln!(body, "    {c} f_{};", sanitize(&f.name));
                        }
                        let _ = &s;
                        if fields.is_empty() {
                            body.push_str("    DuckUnit dummy;\n");
                        }
                        let _ = writeln!(self.types, "/* {} */\ntypedef struct {name} {{\n{body}}} {name};", self.show_ty(t));
                        name
                    }
                    TypeDefKind::Enum { .. } => {
                        let name = format!("DkE{k}_{}", sanitize(&def.name));
                        let layout = self.enum_layout(t);
                        let mut un = String::new();
                        for (vi, fs) in layout.iter().enumerate() {
                            if fs.is_empty() {
                                continue;
                            }
                            let mut st = String::new();
                            for (fi, (ft, boxed)) in fs.iter().enumerate() {
                                let c = if *boxed { "DuckObj *".to_string() } else { self.ct(ft) };
                                let _ = write!(st, " {c} f{fi};");
                            }
                            let _ = writeln!(un, "        struct {{{st} }} v{vi};");
                        }
                        if un.is_empty() {
                            let _ = writeln!(self.types, "/* {} */\ntypedef struct {name} {{\n    int32_t tag;\n}} {name};", self.show_ty(t));
                        } else {
                            let _ = writeln!(
                                self.types,
                                "/* {} */\ntypedef struct {name} {{\n    int32_t tag;\n    union {{\n{un}    }} u;\n}} {name};",
                                self.show_ty(t)
                            );
                        }
                        name
                    }
                    TypeDefKind::Opaque { c_type } => c_type.clone(),
                }
            }
            Ty::Any(s) => {
                let name = format!("DkAny{k}_{}", sanitize(&self.tp.defs.shapes[*s].name));
                let _ = writeln!(self.types, "typedef struct {name} {{\n    DuckObj *obj;\n    const void *vt;\n}} {name};");
                name
            }
            _ => panic!("codegen: can't define {}", self.show_ty(t)),
        };
        self.ctypes.insert(t.clone(), name.clone());
        name
    }

    /// Per variant, the field types (substituted) and whether each is boxed.
    pub fn enum_layout(&mut self, t: &Ty) -> Vec<Vec<(Ty, bool)>> {
        let Ty::Named(d, args) = t else { return Vec::new() };
        let s = self.tp.defs.subst_of(*d, args);
        let vs = self.tp.defs.variants(*d).to_vec();
        vs.iter()
            .map(|v| {
                v.fields
                    .iter()
                    .map(|(_, ft)| {
                        let ft = ft.subst(&s);
                        let boxed = self.reaches(&ft, t, &mut HashSet::new());
                        (ft, boxed)
                    })
                    .collect()
            })
            .collect()
    }

    /// Per struct field: its C member name (`f_x`), type (substituted) and whether it is boxed
    /// (a field whose type contains the struct itself by value, like `boss: User?`).
    pub fn struct_layout(&mut self, t: &Ty) -> Vec<(String, Ty, bool)> {
        let Ty::Named(d, args) = t else { return Vec::new() };
        let s = self.tp.defs.subst_of(*d, args);
        let fs = self.tp.defs.fields(*d).to_vec();
        fs.iter()
            .map(|f| {
                let ft = f.ty.subst(&s);
                let boxed = self.reaches(&ft, t, &mut HashSet::new());
                (format!("f_{}", sanitize(&f.name)), ft, boxed)
            })
            .collect()
    }

    /// C lvalue of field `i` of the struct value `v` (unboxed).
    pub fn field_get(&mut self, t: &Ty, i: usize, v: &str) -> String {
        let layout = self.struct_layout(t);
        let (n, ft, boxed) = &layout[i];
        if *boxed {
            let b = self.box_ty(ft);
            format!("(({b} *)({v}).{n})->v")
        } else {
            format!("({v}).{n}")
        }
    }

    /// The raw C member of field `i` (a `DuckObj *` when boxed) and whether it is boxed.
    pub fn field_raw(&mut self, t: &Ty, i: usize, v: &str) -> (String, bool) {
        let layout = self.struct_layout(t);
        (format!("({v}).{}", layout[i].0), layout[i].2)
    }

    /// The C value to store in field `i` from an owned value (boxing it if needed).
    pub fn field_put(&mut self, t: &Ty, i: usize, owned: &str) -> String {
        let layout = self.struct_layout(t);
        let (_, ft, boxed) = layout[i].clone();
        if boxed { self.box_new(&ft, owned) } else { owned.to_string() }
    }

    /// Does `t` contain `target` by value (through tuples, optionals, results, structs, enums)?
    fn reaches(&self, t: &Ty, target: &Ty, seen: &mut HashSet<Ty>) -> bool {
        if t == target {
            return true;
        }
        if !seen.insert(t.clone()) {
            return false;
        }
        match t {
            Ty::Tuple(ts) => ts.iter().any(|x| self.reaches(x, target, seen)),
            Ty::Opt(x) => self.reaches(x, target, seen),
            Ty::Res(x, _) => self.reaches(x, target, seen),
            Ty::Named(d, args) if Some(*d) != self.value_def => {
                let s = self.tp.defs.subst_of(*d, args);
                match &self.tp.defs.types[*d].kind {
                    TypeDefKind::Struct { fields } => fields.iter().any(|f| self.reaches(&f.ty.subst(&s), target, seen)),
                    TypeDefKind::Enum { variants } => variants.iter().any(|v| v.fields.iter().any(|(_, ft)| self.reaches(&ft.subst(&s), target, seen))),
                    _ => false,
                }
            }
            _ => false,
        }
    }

    /// The box cell type for a boxed value of type `t`: `struct { DuckObj o; T v; }`.
    pub fn box_ty(&mut self, t: &Ty) -> String {
        if let Some(n) = self.memo.get(&("box", t.clone())) {
            return n.clone();
        }
        let c = self.ct(t);
        let k = self.fresh();
        let name = format!("DkBox{k}");
        self.memo.insert(("box", t.clone()), name.clone());
        let _ = writeln!(self.types, "typedef struct {name} {{\n    DuckObj o;\n    {c} v;\n}} {name};");
        let rel = self.release(t, "b->v").unwrap_or_default();
        let _ = writeln!(self.protos, "static void {name}_drop(DuckObj *o);");
        let _ = writeln!(self.funcs, "static void {name}_drop(DuckObj *o) {{\n    {name} *b = ({name} *)o;\n    (void)b;\n    {rel}\n}}\n");
        name
    }

    /// C expression boxing an owned value `v` of type `t` (the result is an owned `DuckObj *`).
    pub fn box_new(&mut self, t: &Ty, v: &str) -> String {
        let b = self.box_ty(t);
        let f = self.helper("boxnew", t, |g, name| {
            let c = g.ct(t);
            format!("static DuckObj *{name}({c} v) {{\n    {b} *x = duck_obj_alloc(sizeof({b}), {b}_drop);\n    x->v = v;\n    return (DuckObj *)x;\n}}\n")
        });
        format!("{f}({v})")
    }

    /// `void f(DuckObj **p)`: make the box `*p` (holding a `t`) uniquely owned before a write
    /// through it, copying it when it is shared (or immortal): copy-on-write for boxed fields.
    pub fn box_unique(&mut self, t: &Ty) -> String {
        let b = self.box_ty(t);
        self.helper("boxuniq", t, |g, name| {
            let c = g.ct(t);
            let ret = g.retain(t, "v").unwrap_or_default();
            let mk = g.box_new(t, "v");
            format!(
                "static void {name}(DuckObj **p) {{\n    if (duck_refcount(*p) == 1) return;\n    {c} v = (({b} *)*p)->v;\n    {ret}\n    DuckObj *n = {mk};\n    duck_release(*p);\n    *p = n;\n}}\n"
            )
        })
    }

    /// C lvalue of field `fi` of variant `vi` of the enum value `v` (unboxing).
    pub fn variant_field(&mut self, t: &Ty, vi: usize, fi: usize, v: &str) -> String {
        if self.is_value(t) {
            return format!("({v}).u.{}", VALUE_FIELDS[vi]);
        }
        let layout = self.enum_layout(t);
        let (ft, boxed) = layout[vi][fi].clone();
        if boxed {
            let b = self.box_ty(&ft);
            format!("(({b} *)({v}).u.v{vi}.f{fi})->v")
        } else {
            format!("({v}).u.v{vi}.f{fi}")
        }
    }

    /// C expression constructing variant `vi` of enum `t` from owned field values.
    pub fn variant_new(&mut self, t: &Ty, vi: usize, fields: &[String]) -> String {
        let ct = self.ct(t);
        if self.is_value(t) {
            if fields.is_empty() {
                return format!("(({ct}){{.tag = {}}})", VALUE_TAGS[vi]);
            }
            return format!("(({ct}){{.tag = {}, .u.{} = {}}})", VALUE_TAGS[vi], VALUE_FIELDS[vi], fields[0]);
        }
        let layout = self.enum_layout(t);
        if fields.is_empty() {
            return format!("(({ct}){{.tag = {vi}}})");
        }
        let mut parts = Vec::new();
        for (fi, f) in fields.iter().enumerate() {
            let (ft, boxed) = layout[vi][fi].clone();
            let v = if boxed { self.box_new(&ft, f) } else { f.clone() };
            parts.push(format!(".u.v{vi}.f{fi} = {v}"));
        }
        format!("(({ct}){{.tag = {vi}, {}}})", parts.join(", "))
    }

    /// The tag test of variant `vi` for an enum value `v`.
    pub fn variant_tag(&self, t: &Ty, vi: usize, v: &str) -> String {
        if self.is_value(t) { format!("({v}).tag == {}", VALUE_TAGS[vi]) } else { format!("({v}).tag == {vi}") }
    }

    /// A zero value of the type (for unreachable code and initializers).
    pub fn zero(&mut self, t: &Ty) -> String {
        match t {
            Ty::Int | Ty::Char | Ty::Never => "0".into(),
            Ty::Tuple(ts) if ts.is_empty() => "0".into(),
            Ty::Float => "0.0".into(),
            Ty::Bool => "false".into(),
            Ty::Str | Ty::List(_) | Ty::Map(..) | Ty::Task(_) => "NULL".into(),
            _ => {
                let c = self.ct(t);
                if c.ends_with('*') { "NULL".into() } else { format!("(({c}){{0}})") }
            }
        }
    }

    // ---- refcounting ----

    /// Does a value of this type hold references?
    pub fn needs_rc(&mut self, t: &Ty) -> bool {
        if let Some(&b) = self.rc.get(t) {
            return b;
        }
        let b = match t {
            Ty::Int | Ty::Float | Ty::Bool | Ty::Char | Ty::Never => false,
            Ty::Str | Ty::List(_) | Ty::Map(..) | Ty::Task(_) | Ty::Fn(..) | Ty::Any(_) => true,
            Ty::Tuple(ts) => {
                self.rc.insert(t.clone(), false);
                ts.iter().any(|x| self.needs_rc(x))
            }
            Ty::Opt(x) => self.needs_rc(x),
            Ty::Res(..) => true,
            Ty::Named(d, _) => {
                if Some(*d) == self.value_def {
                    true
                } else {
                    match &self.tp.defs.types[*d].kind {
                        TypeDefKind::Opaque { .. } => true,
                        TypeDefKind::Struct { .. } => {
                            // a boxed (recursive) field is a heap cell
                            let layout = self.struct_layout(t);
                            self.rc.insert(t.clone(), false);
                            layout.iter().any(|(_, ft, boxed)| *boxed || self.needs_rc(ft))
                        }
                        TypeDefKind::Enum { .. } => {
                            let layout = self.enum_layout(t);
                            self.rc.insert(t.clone(), false);
                            layout.iter().flatten().any(|(ft, boxed)| *boxed || self.needs_rc(ft))
                        }
                    }
                }
            }
            _ => false,
        };
        self.rc.insert(t.clone(), b);
        b
    }

    /// A C statement that retains the value `v` (None if the type holds no references).
    pub fn retain(&mut self, t: &Ty, v: &str) -> Option<String> {
        if !self.needs_rc(t) {
            return None;
        }
        Some(match t {
            Ty::Str | Ty::List(_) | Ty::Map(..) | Ty::Task(_) => format!("duck_retain({v});"),
            Ty::Fn(..) => format!("duck_retain(({v}).env);"),
            Ty::Any(_) => format!("duck_retain(({v}).obj);"),
            Ty::Named(d, _) if matches!(self.tp.defs.types[*d].kind, TypeDefKind::Opaque { .. }) => format!("duck_retain({v});"),
            t if self.is_value(t) => format!("duck_value_retain({v});"),
            _ => {
                let f = self.rc_fns(t).0;
                format!("{f}({v});")
            }
        })
    }

    /// A C statement that releases the value `v` (None if the type holds no references).
    pub fn release(&mut self, t: &Ty, v: &str) -> Option<String> {
        if !self.needs_rc(t) {
            return None;
        }
        Some(match t {
            Ty::Str | Ty::List(_) | Ty::Map(..) | Ty::Task(_) => format!("duck_release({v});"),
            Ty::Fn(..) => format!("duck_release(({v}).env);"),
            Ty::Any(_) => format!("duck_release(({v}).obj);"),
            Ty::Named(d, _) if matches!(self.tp.defs.types[*d].kind, TypeDefKind::Opaque { .. }) => format!("duck_release({v});"),
            t if self.is_value(t) => format!("duck_value_release({v});"),
            _ => {
                let f = self.rc_fns(t).1;
                format!("{f}({v});")
            }
        })
    }

    /// Generated retain/release functions for an aggregate type.
    fn rc_fns(&mut self, t: &Ty) -> (String, String) {
        if let Some(n) = self.memo.get(&("rc", t.clone())) {
            return (format!("{n}_retain"), format!("{n}_release"));
        }
        let k = self.fresh();
        let n = format!("dk_rc{k}");
        self.memo.insert(("rc", t.clone()), n.clone());
        let c = self.ct(t);
        let _ = writeln!(self.protos, "static void {n}_retain({c} v);\nstatic void {n}_release({c} v);");
        let mut inc = String::new();
        let mut dec = String::new();
        let both = |g: &mut Gen, ty: &Ty, e: &str, indent: &str, inc: &mut String, dec: &mut String| {
            if let Some(s) = g.retain(ty, e) {
                let _ = writeln!(inc, "{indent}{s}");
            }
            if let Some(s) = g.release(ty, e) {
                let _ = writeln!(dec, "{indent}{s}");
            }
        };
        match t {
            Ty::Tuple(ts) => {
                for (i, x) in ts.iter().enumerate() {
                    both(self, x, &format!("v.f{i}"), "    ", &mut inc, &mut dec);
                }
            }
            Ty::Opt(x) => {
                inc.push_str("    if (v.some) {\n");
                dec.push_str("    if (v.some) {\n");
                both(self, x, "v.val", "        ", &mut inc, &mut dec);
                inc.push_str("    }\n");
                dec.push_str("    }\n");
            }
            Ty::Res(x, _) => {
                inc.push_str("    if (v.ok) {\n");
                dec.push_str("    if (v.ok) {\n");
                both(self, x, "v.val", "        ", &mut inc, &mut dec);
                inc.push_str("    } else {\n        duck_retain(v.err);\n    }\n");
                dec.push_str("    } else {\n        duck_release(v.err);\n    }\n");
            }
            Ty::Named(d, args) if self.tp.defs.is_struct(*d) => {
                let s = self.tp.defs.subst_of(*d, args);
                let _ = &s;
                for (n, ft, boxed) in self.struct_layout(t) {
                    if boxed {
                        let _ = writeln!(inc, "    duck_retain(v.{n});");
                        let _ = writeln!(dec, "    duck_release(v.{n});");
                    } else {
                        both(self, &ft, &format!("v.{n}"), "    ", &mut inc, &mut dec);
                    }
                }
            }
            Ty::Named(..) => {
                let layout = self.enum_layout(t);
                inc.push_str("    switch (v.tag) {\n");
                dec.push_str("    switch (v.tag) {\n");
                for (vi, fs) in layout.iter().enumerate() {
                    let _ = writeln!(inc, "    case {vi}:");
                    let _ = writeln!(dec, "    case {vi}:");
                    for (fi, (ft, boxed)) in fs.iter().enumerate() {
                        let e = format!("v.u.v{vi}.f{fi}");
                        if *boxed {
                            let _ = writeln!(inc, "        duck_retain({e});");
                            let _ = writeln!(dec, "        duck_release({e});");
                        } else {
                            both(self, ft, &e, "        ", &mut inc, &mut dec);
                        }
                    }
                    inc.push_str("        break;\n");
                    dec.push_str("        break;\n");
                }
                inc.push_str("    }\n");
                dec.push_str("    }\n");
            }
            _ => {}
        }
        let _ = writeln!(self.funcs, "static void {n}_retain({c} v) {{\n    (void)v;\n{inc}}}\nstatic void {n}_release({c} v) {{\n    (void)v;\n{dec}}}\n");
        (format!("{n}_retain"), format!("{n}_release"))
    }

    // ---- memoized helper functions ----

    /// A generated helper function for (kind, type), created once by `make(gen, name)` which
    /// returns its full C definition. The prototype is derived from the first line.
    pub fn helper(&mut self, kind: &'static str, t: &Ty, make: impl FnOnce(&mut Gen<'a>, &str) -> String) -> String {
        if let Some(n) = self.memo.get(&(kind, t.clone())) {
            return n.clone();
        }
        let k = self.fresh();
        let name = format!("dk_{kind}{k}");
        self.memo.insert((kind, t.clone()), name.clone());
        let def = make(self, &name);
        let proto = def.lines().next().unwrap_or("").trim_end_matches('{').trim_end().to_string();
        let _ = writeln!(self.protos, "{proto};");
        self.funcs.push_str(&def);
        self.funcs.push('\n');
        name
    }

    /// The user (or core) implementation of a built-in shape for `t`, when it is a function
    /// (the checker records a private one from the type's own module too).
    pub fn user_impl(&mut self, b: Builtin, t: &Ty) -> Option<String> {
        if b == Builtin::Data && self.imprint_eval {
            return None;
        }
        match self.tp.shape_impls.get(&(b, t.clone())) {
            Some(Target::Instance(i)) => Some(self.inst_fn(*i)),
            Some(Target::Extern { symbol, .. }) => Some(symbol.clone()),
            _ => None,
        }
    }

    // ---- element ops ----

    /// `&ops` for a container element type.
    pub fn ops(&mut self, t: &Ty) -> String {
        match t {
            Ty::Int => return "&duck_ops_int".into(),
            Ty::Float => return "&duck_ops_float".into(),
            Ty::Bool => return "&duck_ops_bool".into(),
            Ty::Char => return "&duck_ops_char".into(),
            Ty::Str => {
                if self.user_impl(Builtin::Show, t).is_none() {
                    return "&duck_ops_str".into();
                }
            }
            Ty::Never => return "&duck_ops_unit".into(),
            Ty::Tuple(ts) if ts.is_empty() => return "&duck_ops_unit".into(),
            Ty::Task(_) => return "&duck_ops_task".into(),
            Ty::Fn(..) => return "&duck_ops_closure".into(),
            t if self.is_value(t) => return "&duck_ops_value".into(),
            t if self.is_err_ty(t) => return "&duck_ops_err".into(),
            _ => {}
        }
        if let Some(n) = self.memo.get(&("ops", t.clone())) {
            return format!("&{n}");
        }
        let k = self.fresh();
        let name = format!("dk_ops{k}");
        self.memo.insert(("ops", t.clone()), name.clone());
        let c = self.ct(t);
        let _ = writeln!(self.protos, "static const DuckElemOps {name};");
        let (ret, rel) = if self.needs_rc(t) {
            let r = self.retain(t, &format!("*({c} *)p")).unwrap();
            let l = self.release(t, &format!("*({c} *)p")).unwrap();
            let rn = format!("{name}_retain");
            let ln = format!("{name}_release");
            let _ = writeln!(self.protos, "static void {rn}(void *p);\nstatic void {ln}(void *p);");
            let _ = writeln!(self.funcs, "static void {rn}(void *p) {{ {r} }}\nstatic void {ln}(void *p) {{ {l} }}\n");
            (rn, ln)
        } else {
            ("NULL".to_string(), "NULL".to_string())
        };
        let eq = match self.eq_fn(t) {
            Some(f) => {
                let n = format!("{name}_eq");
                let _ = writeln!(self.protos, "static bool {n}(const void *a, const void *b);");
                let _ = writeln!(self.funcs, "static bool {n}(const void *a, const void *b) {{ return {f}(*({c} const *)a, *({c} const *)b); }}\n");
                n
            }
            None => "NULL".into(),
        };
        let cmp = match self.cmp_fn(t) {
            Some(f) => {
                let n = format!("{name}_cmp");
                let _ = writeln!(self.protos, "static int {n}(const void *a, const void *b);");
                let _ = writeln!(
                    self.funcs,
                    "static int {n}(const void *a, const void *b) {{ int64_t r = {f}(*({c} const *)a, *({c} const *)b); return (r > 0) - (r < 0); }}\n"
                );
                n
            }
            None => "NULL".into(),
        };
        let hash = match self.hash_fn(t) {
            Some(f) => {
                let n = format!("{name}_hash");
                let _ = writeln!(self.protos, "static uint64_t {n}(const void *a);");
                let _ = writeln!(self.funcs, "static uint64_t {n}(const void *a) {{ return {f}(*({c} const *)a); }}\n");
                n
            }
            None => "NULL".into(),
        };
        let show = match self.dshow_fn(t) {
            Some(f) => {
                let n = format!("{name}_show");
                let _ = writeln!(self.protos, "static DuckStr *{n}(const void *a);");
                let _ = writeln!(self.funcs, "static DuckStr *{n}(const void *a) {{ return {f}(*({c} const *)a); }}\n");
                n
            }
            None => "NULL".into(),
        };
        let _ = writeln!(self.ops_defs, "static const DuckElemOps {name} = {{sizeof({c}), {ret}, {rel}, {eq}, {cmp}, {hash}, {show}}};");
        format!("&{name}")
    }

    // ---- Show ----

    /// `DuckStr *f(T)`: the top-level `Show` text of a value (owned result). None for types
    /// without `Show`.
    pub fn show_fn(&mut self, t: &Ty) -> Option<String> {
        if let Some(f) = self.user_impl(Builtin::Show, t) {
            return Some(f);
        }
        Some(match t {
            Ty::Int => "duck_str_from_int".into(),
            Ty::Float => "duck_str_from_float".into(),
            Ty::Bool => "duck_str_from_bool".into(),
            Ty::Char => "duck_str_from_char".into(),
            Ty::Str => self.helper("showstr", t, |_, n| format!("static DuckStr *{n}(DuckStr *s) {{\n    return duck_retain(s);\n}}\n")),
            t if self.is_value(t) => "duck_value_show".into(),
            t if self.is_err_ty(t) => "duck_err_show".into(),
            Ty::Fn(..) | Ty::Task(_) => return None,
            Ty::Named(d, _) if matches!(self.tp.defs.types[*d].kind, TypeDefKind::Opaque { .. }) => return None,
            _ => {
                let t2 = t.clone();
                self.helper("show", t, move |g, n| g.derive_show(&t2, n))
            }
        })
    }

    /// The "debug" show used inside containers and derived shows: strings and chars quoted.
    pub fn dshow_fn(&mut self, t: &Ty) -> Option<String> {
        match t {
            Ty::Str if self.user_impl(Builtin::Show, t).is_none() => Some("duck_str_quote".into()),
            Ty::Char if self.user_impl(Builtin::Show, t).is_none() => Some("duck_char_quote".into()),
            _ => self.show_fn(t),
        }
    }

    fn derive_show(&mut self, t: &Ty, n: &str) -> String {
        let c = self.ct(t);
        let mut b = format!("static DuckStr *{n}({c} v) {{\n    DuckStrBuf b = DUCK_SB_INIT;\n    (void)v;\n");
        let field = |g: &mut Gen, b: &mut String, ft: &Ty, e: &str| match g.dshow_fn(ft) {
            Some(f) => {
                let _ = writeln!(b, "    duck_sb_str_own(&b, {f}({e}));");
            }
            None => {
                let _ = writeln!(b, "    duck_sb_lit(&b, \"<{}>\");", g.show_ty(ft).replace('"', ""));
            }
        };
        match t {
            Ty::Never => b.push_str("    duck_sb_lit(&b, \"()\");\n"),
            Ty::Tuple(ts) => {
                b.push_str("    duck_sb_lit(&b, \"(\");\n");
                for (i, x) in ts.iter().enumerate() {
                    if i > 0 {
                        b.push_str("    duck_sb_lit(&b, \", \");\n");
                    }
                    field(self, &mut b, x, &format!("v.f{i}"));
                }
                b.push_str("    duck_sb_lit(&b, \")\");\n");
            }
            Ty::List(_) => {
                return format!("static DuckStr *{n}(DuckArr *v) {{\n    return duck_arr_show(v);\n}}\n");
            }
            Ty::Map(..) => {
                return format!("static DuckStr *{n}(DuckMap *v) {{\n    return duck_map_show(v);\n}}\n");
            }
            Ty::Opt(x) => {
                b.push_str("    if (!v.some) {\n        duck_sb_lit(&b, \"none\");\n    } else {\n        duck_sb_lit(&b, \"some(\");\n");
                field(self, &mut b, x, "v.val");
                b.push_str("        duck_sb_lit(&b, \")\");\n    }\n");
            }
            Ty::Res(x, _) => {
                b.push_str("    if (!v.ok) {\n        duck_sb_lit(&b, \"err(\");\n        duck_sb_str_own(&b, duck_err_show(v.err));\n        duck_sb_lit(&b, \")\");\n    } else {\n        duck_sb_lit(&b, \"ok(\");\n");
                field(self, &mut b, x, "v.val");
                b.push_str("        duck_sb_lit(&b, \")\");\n    }\n");
            }
            Ty::Any(s) => {
                let sd = &self.tp.defs.shapes[*s];
                if sd.builtin == Some(Builtin::Show) {
                    let vt = self.vt_struct(*s);
                    let _ = writeln!(b, "    duck_sb_str_own(&b, ((const {vt} *)v.vt)->m0(v.obj));");
                } else {
                    let _ = writeln!(b, "    duck_sb_lit(&b, \"<any {}>\");", sd.name);
                }
            }
            Ty::Named(d, args) if self.tp.defs.is_struct(*d) => {
                let s = self.tp.defs.subst_of(*d, args);
                let def = self.tp.defs.types[*d].clone();
                let TypeDefKind::Struct { fields } = &def.kind else { unreachable!() };
                if fields.is_empty() {
                    let _ = writeln!(b, "    duck_sb_lit(&b, {});", c_str(&format!("{} {{}}", def.name)));
                } else {
                    for (i, f) in fields.iter().enumerate() {
                        let sep = if i == 0 { format!("{} {{ ", def.name) } else { ", ".to_string() };
                        let _ = writeln!(b, "    duck_sb_lit(&b, {});", c_str(&format!("{sep}{}: ", f.name)));
                        let e = self.field_get(t, i, "v");
                        field(self, &mut b, &f.ty.subst(&s), &e);
                    }
                    b.push_str("    duck_sb_lit(&b, \" }\");\n");
                }
            }
            Ty::Named(d, _) => {
                let vs = self.tp.defs.variants(*d).to_vec();
                let layout = self.enum_layout(t);
                b.push_str("    switch (v.tag) {\n");
                for (vi, v) in vs.iter().enumerate() {
                    let _ = writeln!(b, "    case {vi}:");
                    let _ = writeln!(b, "        duck_sb_lit(&b, {});", c_str(&v.name));
                    if !v.fields.is_empty() {
                        b.push_str("        duck_sb_lit(&b, \"(\");\n");
                        for (fi, (ft, _)) in layout[vi].iter().enumerate() {
                            if fi > 0 {
                                b.push_str("        duck_sb_lit(&b, \", \");\n");
                            }
                            let e = self.variant_field(t, vi, fi, "v");
                            field(self, &mut b, ft, &e);
                        }
                        b.push_str("        duck_sb_lit(&b, \")\");\n");
                    }
                    b.push_str("        break;\n");
                }
                b.push_str("    }\n");
            }
            _ => {
                let _ = writeln!(b, "    duck_sb_lit(&b, \"<{}>\");", self.show_ty(t).replace('"', ""));
            }
        }
        b.push_str("    return duck_sb_finish(&b);\n}\n");
        b
    }

    // ---- Eq / Ord / hash ----

    /// `bool f(T a, T b)`, or None when the type has no equality.
    pub fn eq_fn(&mut self, t: &Ty) -> Option<String> {
        if let Some(f) = self.user_impl(Builtin::Eq, t) {
            return Some(f);
        }
        match t {
            Ty::Fn(..) | Ty::Task(_) => return None,
            Ty::Named(d, _) if matches!(self.tp.defs.types[*d].kind, TypeDefKind::Opaque { .. }) && !self.is_err_ty(t) => return None,
            t if self.is_value(t) => return Some("duck_value_eq".into()),
            Ty::Str => return Some("duck_str_eq".into()),
            Ty::List(_) => return Some("duck_arr_eq".into()),
            Ty::Map(..) => return Some("duck_map_eq".into()),
            _ => {}
        }
        if !self.can(t, Builtin::Eq, &mut HashSet::new()) {
            return None;
        }
        let t2 = t.clone();
        Some(self.helper("eq", t, move |g, n| g.derive_eq(&t2, n)))
    }

    /// Can the derived instance of `b` (Eq, Ord, hash) be built for `t`?
    fn can(&mut self, t: &Ty, b: Builtin, seen: &mut HashSet<Ty>) -> bool {
        if self.tp.shape_impls.get(&(b, t.clone())).is_some_and(|x| matches!(x, Target::Instance(_))) {
            return true;
        }
        if !seen.insert(t.clone()) {
            return true;
        }
        match t {
            Ty::Int | Ty::Float | Ty::Bool | Ty::Char | Ty::Str | Ty::Never => true,
            Ty::Fn(..) | Ty::Task(_) | Ty::Any(_) => false,
            Ty::Tuple(ts) => ts.iter().all(|x| self.can(x, b, seen)),
            Ty::List(x) | Ty::Opt(x) => self.can(x, b, seen),
            Ty::Map(k, v) => b != Builtin::Ord && self.can(k, b, seen) && self.can(v, b, seen),
            Ty::Res(x, _) => b == Builtin::Eq && self.can(x, b, seen),
            Ty::Named(d, args) => {
                if Some(*d) == self.value_def {
                    return b != Builtin::Ord;
                }
                let s = self.tp.defs.subst_of(*d, args);
                match self.tp.defs.types[*d].kind.clone() {
                    TypeDefKind::Opaque { .. } => b == Builtin::Eq && self.is_err_ty(t),
                    TypeDefKind::Struct { fields } => fields.iter().all(|f| self.can(&f.ty.subst(&s), b, seen)),
                    TypeDefKind::Enum { variants } => variants.iter().all(|v| v.fields.iter().all(|(_, ft)| self.can(&ft.subst(&s), b, seen))),
                }
            }
            _ => false,
        }
    }

    /// Equality of two C values of type `t` as a C boolean expression.
    pub fn eq_expr(&mut self, t: &Ty, a: &str, b: &str) -> String {
        match t {
            Ty::Int | Ty::Float | Ty::Bool | Ty::Char => format!("({a} == {b})"),
            Ty::Never => "true".into(),
            Ty::Tuple(ts) if ts.is_empty() => "true".into(),
            _ => match self.eq_fn(t) {
                Some(f) => format!("{f}({a}, {b})"),
                None => "false".into(),
            },
        }
    }

    fn derive_eq(&mut self, t: &Ty, n: &str) -> String {
        let c = self.ct(t);
        let mut b = format!("static bool {n}({c} a, {c} b) {{\n    (void)a;\n    (void)b;\n");
        match t {
            Ty::Tuple(ts) => {
                for (i, x) in ts.iter().enumerate() {
                    let e = self.eq_expr(x, &format!("a.f{i}"), &format!("b.f{i}"));
                    let _ = writeln!(b, "    if (!{e}) return false;");
                }
                b.push_str("    return true;\n");
            }
            Ty::Opt(x) => {
                let e = self.eq_expr(x, "a.val", "b.val");
                let _ = writeln!(b, "    if (a.some != b.some) return false;\n    return !a.some || {e};");
            }
            Ty::Res(x, _) => {
                let e = self.eq_expr(x, "a.val", "b.val");
                let _ = writeln!(b, "    if (a.ok != b.ok) return false;\n    if (a.ok) return {e};\n    return duck_str_eq(a.err->msg, b.err->msg);");
            }
            t if self.is_err_ty(t) => b.push_str("    return a == b || duck_str_eq(a->msg, b->msg);\n"),
            Ty::Named(d, args) if self.tp.defs.is_struct(*d) => {
                let s = self.tp.defs.subst_of(*d, args);
                for (i, f) in self.tp.defs.fields(*d).to_vec().into_iter().enumerate() {
                    let (x, y) = (self.field_get(t, i, "a"), self.field_get(t, i, "b"));
                    let e = self.eq_expr(&f.ty.subst(&s), &x, &y);
                    let _ = writeln!(b, "    if (!{e}) return false;");
                }
                b.push_str("    return true;\n");
            }
            Ty::Named(..) => {
                let layout = self.enum_layout(t);
                b.push_str("    if (a.tag != b.tag) return false;\n    switch (a.tag) {\n");
                for (vi, fs) in layout.iter().enumerate() {
                    let _ = writeln!(b, "    case {vi}:");
                    for (fi, (ft, _)) in fs.iter().enumerate() {
                        let x = self.variant_field(t, vi, fi, "a");
                        let y = self.variant_field(t, vi, fi, "b");
                        let e = self.eq_expr(ft, &x, &y);
                        let _ = writeln!(b, "        if (!{e}) return false;");
                    }
                    b.push_str("        return true;\n");
                }
                b.push_str("    }\n    return true;\n");
            }
            _ => b.push_str("    return false;\n"),
        }
        b.push_str("}\n");
        b
    }

    /// `int64_t f(T a, T b)` (negative, 0, positive), or None when the type has no order.
    pub fn cmp_fn(&mut self, t: &Ty) -> Option<String> {
        if let Some(f) = self.user_impl(Builtin::Ord, t) {
            return Some(f);
        }
        if !self.can(t, Builtin::Ord, &mut HashSet::new()) {
            return None;
        }
        let t2 = t.clone();
        Some(self.helper("cmp", t, move |g, n| g.derive_cmp(&t2, n)))
    }

    /// A C `int64_t` expression comparing two values of type `t`.
    pub fn cmp_expr(&mut self, t: &Ty, a: &str, b: &str) -> String {
        match t {
            Ty::Int => format!("(int64_t)duck_int_cmp({a}, {b})"),
            Ty::Float => format!("(int64_t)duck_float_cmp({a}, {b})"),
            Ty::Char | Ty::Bool => format!("(int64_t)(({a} > {b}) - ({a} < {b}))"),
            Ty::Str => format!("(int64_t)duck_str_cmp({a}, {b})"),
            _ => match self.cmp_fn(t) {
                Some(f) => format!("{f}({a}, {b})"),
                None => "0".into(),
            },
        }
    }

    fn derive_cmp(&mut self, t: &Ty, n: &str) -> String {
        let c = self.ct(t);
        let mut b = format!("static int64_t {n}({c} a, {c} b) {{\n    int64_t r = 0;\n    (void)a;\n    (void)b;\n    (void)r;\n");
        match t {
            Ty::Int | Ty::Float | Ty::Char | Ty::Bool | Ty::Str => {
                let e = self.cmp_expr(t, "a", "b");
                let _ = writeln!(b, "    return {e};");
            }
            Ty::List(_) => b.push_str("    return duck_arr_cmp(a, b);\n"),
            Ty::Tuple(ts) => {
                for (i, x) in ts.iter().enumerate() {
                    let e = self.cmp_expr(x, &format!("a.f{i}"), &format!("b.f{i}"));
                    let _ = writeln!(b, "    if ((r = {e}) != 0) return r;");
                }
                b.push_str("    return 0;\n");
            }
            Ty::Opt(x) => {
                let e = self.cmp_expr(x, "a.val", "b.val");
                let _ = writeln!(b, "    if (a.some != b.some) return a.some ? 1 : -1;\n    return a.some ? {e} : 0;");
            }
            Ty::Named(d, args) if self.tp.defs.is_struct(*d) => {
                let s = self.tp.defs.subst_of(*d, args);
                for (i, f) in self.tp.defs.fields(*d).to_vec().into_iter().enumerate() {
                    let (x, y) = (self.field_get(t, i, "a"), self.field_get(t, i, "b"));
                    let e = self.cmp_expr(&f.ty.subst(&s), &x, &y);
                    let _ = writeln!(b, "    if ((r = {e}) != 0) return r;");
                }
                b.push_str("    return 0;\n");
            }
            Ty::Named(..) => {
                let layout = self.enum_layout(t);
                b.push_str("    if (a.tag != b.tag) return a.tag < b.tag ? -1 : 1;\n    switch (a.tag) {\n");
                for (vi, fs) in layout.iter().enumerate() {
                    let _ = writeln!(b, "    case {vi}:");
                    for (fi, (ft, _)) in fs.iter().enumerate() {
                        let x = self.variant_field(t, vi, fi, "a");
                        let y = self.variant_field(t, vi, fi, "b");
                        let e = self.cmp_expr(ft, &x, &y);
                        let _ = writeln!(b, "        if ((r = {e}) != 0) return r;");
                    }
                    b.push_str("        return 0;\n");
                }
                b.push_str("    }\n    return 0;\n");
            }
            _ => b.push_str("    return 0;\n"),
        }
        b.push_str("}\n");
        b
    }

    /// `uint64_t f(T)` for map keys, or None.
    pub fn hash_fn(&mut self, t: &Ty) -> Option<String> {
        match t {
            Ty::Str => return Some("duck_str_hash".into()),
            Ty::List(_) => return Some("duck_arr_hash".into()),
            Ty::Map(..) | Ty::Fn(..) | Ty::Task(_) | Ty::Any(_) => return None,
            _ => {}
        }
        if !self.can(t, Builtin::Eq, &mut HashSet::new()) || self.is_err_ty(t) {
            return None;
        }
        let t2 = t.clone();
        Some(self.helper("hash", t, move |g, n| g.derive_hash(&t2, n)))
    }

    fn hash_expr(&mut self, t: &Ty, v: &str) -> String {
        match t {
            Ty::Int => format!("duck_hash_int({v})"),
            Ty::Char | Ty::Bool => format!("duck_hash_int((int64_t)({v}))"),
            Ty::Float => format!("duck_ops_float.hash(&({v}))"),
            Ty::Never => "0".into(),
            Ty::Tuple(ts) if ts.is_empty() => "0".into(),
            _ => match self.hash_fn(t) {
                Some(f) => format!("{f}({v})"),
                None => "0".into(),
            },
        }
    }

    fn derive_hash(&mut self, t: &Ty, n: &str) -> String {
        let c = self.ct(t);
        let mut b = format!("static uint64_t {n}({c} v) {{\n    uint64_t h = 7;\n    (void)v;\n");
        match t {
            Ty::Int | Ty::Char | Ty::Bool | Ty::Float => {
                let e = self.hash_expr(t, "v");
                let _ = writeln!(b, "    h = {e};");
            }
            t if self.is_value(t) => b.push_str("    h = duck_ops_value.hash(&v);\n"),
            Ty::Tuple(ts) => {
                for (i, x) in ts.iter().enumerate() {
                    let e = self.hash_expr(x, &format!("v.f{i}"));
                    let _ = writeln!(b, "    h = duck_hash_combine(h, {e});");
                }
            }
            Ty::Opt(x) => {
                let e = self.hash_expr(x, "v.val");
                let _ = writeln!(b, "    if (v.some) h = duck_hash_combine(h, {e});");
            }
            Ty::Res(x, _) => {
                let e = self.hash_expr(x, "v.val");
                let _ = writeln!(b, "    if (v.ok) h = duck_hash_combine(h, {e});");
            }
            Ty::Named(d, args) if self.tp.defs.is_struct(*d) => {
                let s = self.tp.defs.subst_of(*d, args);
                for (i, f) in self.tp.defs.fields(*d).to_vec().into_iter().enumerate() {
                    let x = self.field_get(t, i, "v");
                    let e = self.hash_expr(&f.ty.subst(&s), &x);
                    let _ = writeln!(b, "    h = duck_hash_combine(h, {e});");
                }
            }
            Ty::Named(..) => {
                let layout = self.enum_layout(t);
                b.push_str("    h = duck_hash_int(v.tag);\n    switch (v.tag) {\n");
                for (vi, fs) in layout.iter().enumerate() {
                    let _ = writeln!(b, "    case {vi}:");
                    for (fi, (ft, _)) in fs.iter().enumerate() {
                        let x = self.variant_field(t, vi, fi, "v");
                        let e = self.hash_expr(ft, &x);
                        let _ = writeln!(b, "        h = duck_hash_combine(h, {e});");
                    }
                    b.push_str("        break;\n");
                }
                b.push_str("    }\n");
            }
            _ => {}
        }
        b.push_str("    return h;\n}\n");
        b
    }

    // ---- Data: to_value / from_value ----

    /// `DuckValue f(T)` (owned result).
    pub fn tov_fn(&mut self, t: &Ty) -> String {
        if let Some(f) = self.user_impl(Builtin::Data, t) {
            return f;
        }
        let t2 = t.clone();
        self.helper("tov", t, move |g, n| g.derive_tov(&t2, n))
    }

    fn tov_expr(&mut self, t: &Ty, v: &str) -> String {
        let f = self.tov_fn(t);
        format!("{f}({v})")
    }

    fn derive_tov(&mut self, t: &Ty, n: &str) -> String {
        let c = self.ct(t);
        let mut b = format!("static DuckValue {n}({c} v) {{\n    (void)v;\n");
        match t {
            Ty::Int => b.push_str("    return duck_value_int(v);\n"),
            Ty::Float => b.push_str("    return duck_value_float(v);\n"),
            Ty::Bool => b.push_str("    return duck_value_bool(v);\n"),
            Ty::Str => b.push_str("    return duck_value_str(v);\n"),
            Ty::Char => b.push_str("    DuckStr *s = duck_str_from_char(v);\n    DuckValue r = duck_value_str(s);\n    duck_release(s);\n    return r;\n"),
            t if self.is_value(t) => b.push_str("    duck_value_retain(v);\n    return v;\n"),
            Ty::List(x) => {
                let cx = self.ct(x);
                let e = self.tov_expr(x, &format!("*({cx} *)duck_arr_at(v, i, NULL)"));
                let _ = writeln!(
                    b,
                    "    DuckArr *xs = duck_value_list_new();\n    for (int64_t i = 0; i < duck_arr_len(v); i++) {{\n        DuckValue e = {e};\n        duck_arr_push(&xs, &e);\n        duck_value_release(e);\n    }}\n    DuckValue r = duck_value_list(xs);\n    duck_release(xs);\n    return r;"
                );
            }
            Ty::Map(_, x) => {
                let cx = self.ct(x);
                let e = self.tov_expr(x, &format!("*({cx} *)vp"));
                let _ = writeln!(
                    b,
                    "    DuckMap *m = duck_value_map_new();\n    int64_t it = 0;\n    void *kp, *vp;\n    while (duck_map_next(v, &it, &kp, &vp)) {{\n        DuckValue e = {e};\n        duck_map_set(&m, kp, &e);\n        duck_value_release(e);\n    }}\n    DuckValue r = duck_value_map(m);\n    duck_release(m);\n    return r;"
                );
            }
            Ty::Opt(x) => {
                let e = self.tov_expr(x, "v.val");
                let _ = writeln!(b, "    if (!v.some) return duck_value_null();\n    return {e};");
            }
            Ty::Named(d, args) if self.tp.defs.is_struct(*d) => {
                let s = self.tp.defs.subst_of(*d, args);
                b.push_str("    DuckMap *m = duck_value_map_new();\n");
                for (i, f) in self.tp.defs.fields(*d).to_vec().into_iter().enumerate() {
                    let x = self.field_get(t, i, "v");
                    let e = self.tov_expr(&f.ty.subst(&s), &x);
                    let _ = writeln!(b, "    {{\n        DuckValue e = {e};\n        duck_value_map_put(&m, {}, e);\n        duck_value_release(e);\n    }}", c_str(&f.name));
                }
                b.push_str("    DuckValue r = duck_value_map(m);\n    duck_release(m);\n    return r;\n");
            }
            Ty::Named(d, _) if self.tp.defs.is_enum(*d) => {
                let vs = self.tp.defs.variants(*d).to_vec();
                let layout = self.enum_layout(t);
                b.push_str("    switch (v.tag) {\n");
                for (vi, var) in vs.iter().enumerate() {
                    let _ = writeln!(b, "    case {vi}: {{");
                    if var.fields.is_empty() {
                        let _ = writeln!(b, "        DuckStr *s = duck_str_lit({});\n        DuckValue r = duck_value_str(s);\n        duck_release(s);\n        return r;\n    }}", c_str(&var.name));
                        continue;
                    }
                    let _ = writeln!(
                        b,
                        "        DuckMap *m = duck_value_map_new();\n        DuckStr *s = duck_str_lit({});\n        DuckValue tag = duck_value_str(s);\n        duck_release(s);\n        duck_value_map_put(&m, \"tag\", tag);\n        duck_value_release(tag);",
                        c_str(&var.name)
                    );
                    for (fi, (fname, _)) in var.fields.iter().enumerate() {
                        let key = fname.clone().unwrap_or_else(|| fi.to_string());
                        let x = self.variant_field(t, vi, fi, "v");
                        let e = self.tov_expr(&layout[vi][fi].0, &x);
                        let _ = writeln!(b, "        {{\n            DuckValue e = {e};\n            duck_value_map_put(&m, {}, e);\n            duck_value_release(e);\n        }}", c_str(&key));
                    }
                    b.push_str("        DuckValue r = duck_value_map(m);\n        duck_release(m);\n        return r;\n    }\n");
                }
                b.push_str("    }\n    return duck_value_null();\n");
            }
            _ => b.push_str("    return duck_value_null();\n"),
        }
        b.push_str("}\n");
        b
    }

    /// `ResT f(DuckValue)`: the derived `from_value` (owned result).
    pub fn fromv_fn(&mut self, t: &Ty) -> String {
        // a user `from_value` for the type (or a field/element type), like `tov_fn`'s `to_value`
        if !self.imprint_eval {
            match self.tp.from_value_impls.get(t) {
                Some(Target::Instance(i)) => return self.inst_fn(*i),
                Some(Target::Extern { symbol, .. }) => return symbol.clone(),
                _ => {}
            }
        }
        let t2 = t.clone();
        self.helper("fromv", t, move |g, n| g.derive_fromv(&t2, n))
    }

    fn derive_fromv(&mut self, t: &Ty, n: &str) -> String {
        let rt = Ty::res(t.clone(), self.err_ty());
        let r = self.ct(&rt);
        let c = self.ct(t);
        let what = self.show_ty(t);
        let mut b = format!("static {r} {n}(DuckValue v) {{\n");
        let mism = |want: &str| {
            format!(
                "duck_err_fmt(\"from_value: expected {want} for `%s`, got %s\", {}, duck_value_tag_name(v.tag))",
                c_str(&what)
            )
        };
        match t {
            Ty::Int => {
                let _ = writeln!(b, "    if (v.tag != DUCK_V_INT) return DUCK_ERR({r}, {});\n    return DUCK_OK({r}, v.u.i);", mism("Int"));
            }
            Ty::Float => {
                let _ = writeln!(
                    b,
                    "    if (v.tag == DUCK_V_INT) return DUCK_OK({r}, (double)v.u.i);\n    if (v.tag != DUCK_V_FLOAT) return DUCK_ERR({r}, {});\n    return DUCK_OK({r}, v.u.f);",
                    mism("Float")
                );
            }
            Ty::Bool => {
                let _ = writeln!(b, "    if (v.tag != DUCK_V_BOOL) return DUCK_ERR({r}, {});\n    return DUCK_OK({r}, v.u.b);", mism("Bool"));
            }
            Ty::Str => {
                let _ = writeln!(b, "    if (v.tag != DUCK_V_STR) return DUCK_ERR({r}, {});\n    return DUCK_OK({r}, duck_retain(v.u.s));", mism("Str"));
            }
            Ty::Char => {
                let _ = writeln!(
                    b,
                    "    if (v.tag != DUCK_V_STR || duck_str_len(v.u.s) != 1) return DUCK_ERR({r}, {});\n    return DUCK_OK({r}, duck_str_char_at(v.u.s, 0, NULL));",
                    mism("a one-char Str")
                );
            }
            Ty::Tuple(ts) if ts.is_empty() => {
                let _ = writeln!(b, "    if (v.tag != DUCK_V_NULL) return DUCK_ERR({r}, {});\n    return DUCK_OK({r}, 0);", mism("Null"));
            }
            t if self.is_value(t) => {
                let _ = writeln!(b, "    duck_value_retain(v);\n    return DUCK_OK({r}, v);");
            }
            Ty::List(x) => {
                let f = self.fromv_fn(x);
                let ops = self.ops(x);
                let _ = writeln!(
                    b,
                    "    if (v.tag != DUCK_V_LIST) return DUCK_ERR({r}, {});\n    DuckArr *out = duck_arr_new({ops}, duck_arr_len(v.u.list));\n    for (int64_t i = 0; i < duck_arr_len(v.u.list); i++) {{\n        DuckValue e = *(DuckValue *)duck_arr_at(v.u.list, i, NULL);\n        __typeof__({f}(e)) x = {f}(e);\n        if (!x.ok) {{\n            duck_release(out);\n            return DUCK_ERR({r}, x.err);\n        }}\n        duck_arr_push(&out, &x.val);",
                    mism("List")
                );
                if let Some(rel) = self.release(x, "x.val") {
                    let _ = writeln!(b, "        {rel}");
                }
                let _ = writeln!(b, "    }}\n    return DUCK_OK({r}, out);");
            }
            Ty::Map(k, x) if **k == Ty::Str => {
                let f = self.fromv_fn(x);
                let vops = self.ops(x);
                let _ = writeln!(
                    b,
                    "    if (v.tag != DUCK_V_MAP) return DUCK_ERR({r}, {});\n    DuckMap *out = duck_map_new(&duck_ops_str, {vops});\n    int64_t it = 0;\n    void *kp, *vp;\n    while (duck_map_next(v.u.map, &it, &kp, &vp)) {{\n        __typeof__({f}(*(DuckValue *)vp)) x = {f}(*(DuckValue *)vp);\n        if (!x.ok) {{\n            duck_release(out);\n            return DUCK_ERR({r}, x.err);\n        }}\n        duck_map_set(&out, kp, &x.val);",
                    mism("Map")
                );
                if let Some(rel) = self.release(x, "x.val") {
                    let _ = writeln!(b, "        {rel}");
                }
                let _ = writeln!(b, "    }}\n    return DUCK_OK({r}, out);");
            }
            Ty::Opt(x) => {
                let f = self.fromv_fn(x);
                let _ = writeln!(
                    b,
                    "    if (v.tag == DUCK_V_NULL) return DUCK_OK({r}, (({c}){{.some = false}}));\n    __typeof__({f}(v)) x = {f}(v);\n    if (!x.ok) return DUCK_ERR({r}, x.err);\n    return DUCK_OK({r}, (({c}){{.some = true, .val = x.val}}));"
                );
            }
            Ty::Named(d, args) if self.tp.defs.is_struct(*d) => {
                let s = self.tp.defs.subst_of(*d, args);
                let fields = self.tp.defs.fields(*d).to_vec();
                let _ = writeln!(b, "    if (v.tag != DUCK_V_MAP) return DUCK_ERR({r}, {});\n    {c} out = {{0}};\n    DuckErr *err = NULL;\n    int done = 0;\n    (void)done;", mism("Map"));
                let mut rels = Vec::new();
                for (i, f) in fields.iter().enumerate() {
                    let ft = f.ty.subst(&s);
                    let (fname, boxed) = self.field_raw(t, i, "out");
                    let key = self.lit(&f.name);
                    let conv = self.fromv_fn(&ft);
                    let zput = {
                        let z = self.zero(&ft);
                        self.field_put(t, i, &z)
                    };
                    let xput = self.field_put(t, i, "x.val");
                    let missing = if let Ty::Opt(_) = ft {
                        format!("{fname} = {zput};")
                    } else {
                        format!("err = duck_err_fmt(\"from_value: missing field `{}` of `%s`\", {});", f.name.replace('"', ""), c_str(&what))
                    };
                    let _ = writeln!(
                        b,
                        "    if (!err) {{\n        DuckValue *fv = duck_map_find(v.u.map, &{key});\n        if (!fv) {{\n            {missing}\n        }} else {{\n            __typeof__({conv}(*fv)) x = {conv}(*fv);\n            if (!x.ok) err = duck_err_wrap({key}, x.err), duck_release(x.err);\n            else {fname} = {xput};\n        }}\n        if (!err) done = {};\n    }}",
                        i + 1
                    );
                    rels.push((i + 1, if boxed { Ty::Str } else { ft }, fname));
                }
                b.push_str("    if (err) {\n");
                for (i, ft, fname) in rels {
                    if let Some(rel) = self.release(&ft, &fname) {
                        let _ = writeln!(b, "        if (done >= {i}) {{ {rel} }}");
                    }
                }
                let _ = writeln!(b, "        return DUCK_ERR({r}, err);\n    }}\n    return DUCK_OK({r}, out);");
            }
            Ty::Named(d, _) if self.tp.defs.is_enum(*d) => {
                let vs = self.tp.defs.variants(*d).to_vec();
                let layout = self.enum_layout(t);
                let _ = writeln!(b, "    DuckStr *tag = NULL;\n    if (v.tag == DUCK_V_STR) tag = v.u.s;\n    else if (v.tag == DUCK_V_MAP) {{\n        DuckValue *tv = duck_map_find(v.u.map, &{});\n        if (tv && tv->tag == DUCK_V_STR) tag = tv->u.s;\n    }}\n    if (!tag) return DUCK_ERR({r}, {});", self.lit("tag"), mism("a Str or a Map with a \\\"tag\\\""));
                for (vi, var) in vs.iter().enumerate() {
                    let _ = writeln!(b, "    if (duck_str_eq_lit(tag, {})) {{", c_str(&var.name));
                    if var.fields.is_empty() {
                        let e = self.variant_new(t, vi, &[]);
                        let _ = writeln!(b, "        return DUCK_OK({r}, {e});\n    }}");
                        continue;
                    }
                    let _ = writeln!(b, "        if (v.tag != DUCK_V_MAP) return DUCK_ERR({r}, {});", mism("a Map"));
                    let mut names = Vec::new();
                    for (fi, (fname, _)) in var.fields.iter().enumerate() {
                        let ft = layout[vi][fi].0.clone();
                        let cf = self.ct(&ft);
                        let key = self.lit(&fname.clone().unwrap_or_else(|| fi.to_string()));
                        let conv = self.fromv_fn(&ft);
                        let _ = writeln!(b, "        {cf} a{fi} = {};\n        DuckValue *fv{fi} = duck_map_find(v.u.map, &{key});", self.zero(&ft));
                        let mut cleanup = String::new();
                        for (pj, pty) in names.iter() {
                            if let Some(rel) = self.release(pty, &format!("a{pj}")) {
                                cleanup.push_str(&rel);
                                cleanup.push(' ');
                            }
                        }
                        let _ = writeln!(
                            b,
                            "        if (!fv{fi}) {{ {cleanup}return DUCK_ERR({r}, duck_err_fmt(\"from_value: missing field of variant {}\")); }}\n        {{\n            __typeof__({conv}(*fv{fi})) x = {conv}(*fv{fi});\n            if (!x.ok) {{ {cleanup}return DUCK_ERR({r}, x.err); }}\n            a{fi} = x.val;\n        }}",
                            var.name.replace('"', "")
                        );
                        names.push((fi, ft));
                    }
                    let args: Vec<String> = (0..var.fields.len()).map(|i| format!("a{i}")).collect();
                    let e = self.variant_new(t, vi, &args);
                    let _ = writeln!(b, "        return DUCK_OK({r}, {e});\n    }}");
                }
                let _ = writeln!(b, "    return DUCK_ERR({r}, duck_err_fmt(\"from_value: unknown variant `%s` of `%s`\", duck_str_cstr(tag), {}));", c_str(&what));
            }
            _ => {
                let _ = writeln!(b, "    return DUCK_ERR({r}, duck_err_fmt(\"from_value: `%s` doesn't convert from Value\", {}));", c_str(&what));
            }
        }
        b.push_str("}\n");
        b
    }

    // ---- any S ----

    /// The vtable struct type of shape `s`.
    pub fn vt_struct(&mut self, s: ShapeId) -> String {
        let key = Ty::Any(s);
        if let Some(n) = self.memo.get(&("vts", key.clone())) {
            return n.clone();
        }
        let name = format!("DkVt{s}_{}", sanitize(&self.tp.defs.shapes[s].name));
        self.memo.insert(("vts", key), name.clone());
        let sh = self.tp.defs.shapes[s].clone();
        let mut body = String::new();
        for (k, m) in sh.methods.iter().enumerate() {
            let r = self.ct(&self.method_ty(&m.ret, s));
            let mut ps = vec!["DuckObj *".to_string()];
            for p in m.params.iter().skip(1) {
                ps.push(self.ct(&self.method_ty(p, s)));
            }
            let _ = writeln!(body, "    {r} (*m{k})({});", ps.join(", "));
        }
        if body.is_empty() {
            body.push_str("    int dummy;\n");
        }
        let _ = writeln!(self.types, "typedef struct {name} {{\n{body}}} {name};");
        name
    }

    /// A shape method's parameter or return type, with `Self` (unsupported for `any`) as `()`.
    pub fn method_ty(&self, t: &Ty, s: ShapeId) -> Ty {
        let sp = self.tp.defs.shapes[s].self_param;
        t.map_ty(&mut |x| if x == Ty::Param(sp) { Ty::unit() } else { x })
    }

    // ---- the program ----

    /// Assemble the C file.
    pub fn finish(mut self, entry: &str) -> String {
        let mut init = String::from("static void dk_init(void) {\n");
        for (i, s) in self.lits.iter().enumerate() {
            let _ = writeln!(init, "    dk_lit{i} = duck_str_from_bytes({}, {});\n    duck_make_immortal(dk_lit{i});", c_str(s), s.len());
        }
        for f in &self.imprint_inits {
            let _ = writeln!(init, "    {f}();");
        }
        for (_, name, _) in self.const_order.clone() {
            let _ = writeln!(init, "    (void){name}();");
        }
        init.push_str("}\n");
        let mut cleanup = String::from("static void dk_cleanup(void) {\n");
        for (_, name, _) in self.const_order.iter().rev() {
            let _ = writeln!(cleanup, "    {name}_free();");
        }
        cleanup.push_str("}\n");
        let mut lits = String::new();
        for i in 0..self.lits.len() {
            let _ = writeln!(lits, "static DuckStr *dk_lit{i};");
        }
        let mut out = String::new();
        out.push_str("/* Generated by the duck compiler. */\n#include \"duck.h\"\n#include <stdio.h>\n#include <stdlib.h>\n\n");
        out.push_str("/* ---- types ---- */\n");
        out.push_str(&self.types);
        out.push_str("\n/* ---- prototypes ---- */\n");
        out.push_str(&lits);
        out.push_str(&self.protos);
        out.push_str("\n/* ---- element ops, vtables, globals ---- */\n");
        out.push_str(&self.ops_defs);
        out.push_str("\n/* ---- functions ---- */\n");
        out.push_str(&std::mem::take(&mut self.funcs));
        out.push_str(&init);
        out.push_str(&cleanup);
        out.push_str(entry);
        out
    }

    /// Is module `m` part of the root package (whose tests `duck test` runs)?
    pub fn in_root_pkg(&self, m: ModId) -> bool {
        let p = &self.tp.program;
        p.mods[m].pkg == p.mods[p.root].pkg
    }

    /// The source text of a span in module `m`.
    pub fn span_text(&self, m: ModId, span: super::diag::Span) -> String {
        let src = &self.tp.program.mods[m].src;
        let mut out = String::new();
        for (i, line) in src.lines().enumerate() {
            let ln = i as u32 + 1;
            if ln < span.line || ln > span.end_line {
                continue;
            }
            let chars: Vec<char> = line.chars().collect();
            let from = if ln == span.line { (span.col as usize).saturating_sub(1) } else { 0 };
            let to = if ln == span.end_line { (span.end_col as usize).saturating_sub(1).min(chars.len()) } else { chars.len() };
            if from <= to && from <= chars.len() {
                out.extend(&chars[from..to]);
            }
            if ln != span.end_line {
                out.push('\n');
            }
        }
        out
    }

    /// The AST item of a body.
    pub fn body_item(&self, b: BodyRef) -> (ModId, &'a Item) {
        let tp = self.tp;
        match b {
            BodyRef::Fn(f) => {
                let FnKind::Duck { item, .. } = &tp.fns[f].kind else { panic!("not a Duck function") };
                (tp.fns[f].module, &tp.program.mods[tp.fns[f].module].ast.items[*item])
            }
            BodyRef::Test(t) => (tp.tests[t].module, &tp.program.mods[tp.tests[t].module].ast.items[tp.tests[t].item]),
            BodyRef::Const(c) => (tp.consts[c].module, &tp.program.mods[tp.consts[c].module].ast.items[tp.consts[c].item]),
        }
    }

    /// Record a hole for `duck build`'s refusal.
    pub fn note_hole(&mut self, loc: String, expected: String) {
        self.holes.push(format!("{loc}: unfilled hole (expected {expected})"));
    }

}

/// `DuckValue` union members for each `Value` variant (index = variant).
pub const VALUE_FIELDS: [&str; 7] = ["", "b", "i", "f", "s", "list", "map"];
pub const VALUE_TAGS: [&str; 7] = ["DUCK_V_NULL", "DUCK_V_BOOL", "DUCK_V_INT", "DUCK_V_FLOAT", "DUCK_V_STR", "DUCK_V_LIST", "DUCK_V_MAP"];

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{check, resolve};
    use std::path::Path;

    fn typed(src: &str) -> TypedProgram {
        let prog = resolve::load_source(Path::new("t.duck"), src.to_string()).unwrap_or_else(|_| panic!("load"));
        check::check(prog).unwrap_or_else(|_| panic!("check"))
    }

    #[test]
    fn c_string_literals() {
        assert_eq!(c_str("a\"b\\c"), "\"a\\\"b\\\\c\"");
        assert_eq!(c_str("??/"), "\"\\?\\?/\"");
        assert_eq!(c_str("\0\n"), "\"\\000\\012\"");
        assert_eq!(c_str("é"), "\"\\303\\251\"");
        assert_eq!(sanitize("a-b.c"), "a_b_c");
    }

    #[test]
    fn representations() {
        let tp = typed("enum T { L(v: int), N(l: T, r: T) }\nstruct U { name: str, boss: U? }\nfn main() {}\n");
        let mut g = Gen::new(&tp, Mode::Run);
        assert_eq!(g.ct(&Ty::opt(Ty::Int)), "DuckOpt_int");
        assert_eq!(g.ct(&Ty::res(Ty::Str, g.err_ty())), "DuckRes_str");
        assert_eq!(g.ct(&Ty::list(Ty::Str)), "DuckArr *");
        let t = tp.defs.types.iter().position(|d| d.name == "T").unwrap();
        let tt = Ty::Named(t, vec![]);
        // the recursive variant fields are boxed, the int is not
        let layout = g.enum_layout(&tt);
        assert_eq!(layout[0], vec![(Ty::Int, false)]);
        assert!(layout[1].iter().all(|(_, b)| *b));
        assert!(g.needs_rc(&tt));
        let u = tp.defs.types.iter().position(|d| d.name == "U").unwrap();
        let ut = Ty::Named(u, vec![]);
        let sl = g.struct_layout(&ut);
        assert!(!sl[0].2 && sl[1].2, "{sl:?}");
        assert!(g.ct(&ut).starts_with("DkS"));
        assert!(!g.needs_rc(&Ty::Tuple(vec![Ty::Int, Ty::Bool])));
        assert_eq!(g.retain(&Ty::Int, "x"), None);
        assert_eq!(g.release(&Ty::Str, "s").as_deref(), Some("duck_release(s);"));
    }

    /// A private `cmp` next to the struct implements `Ord` even for generic code instantiated
    /// elsewhere (core's `sort`): the checker records it, codegen doesn't search.
    #[test]
    fn private_shape_fns_are_recorded() {
        let tp = typed("struct Item { n: int }\nfn cmp(a: Item, b: Item): int = b.n - a.n\nfn main() { print([Item { n: 1 }].sort()) }\n");
        let item = Ty::Named(tp.defs.types.iter().position(|d| d.name == "Item").unwrap(), vec![]);
        let Some(Target::Instance(i)) = tp.shape_impls.get(&(Builtin::Ord, item.clone())) else { panic!("{:?}", tp.shape_impls.get(&(Builtin::Ord, item))) };
        assert_eq!(tp.instances[*i].body, BodyRef::Fn(tp.fns.iter().position(|f| f.name == "cmp" && f.params[0].ty == item).unwrap()));
        // shorthand fields carry their auto-wraps
        let tp = typed("struct P { x: int?, y: int }\nfn main() {\n  let x = 1\n  let y = 2\n  print(P { x, y })\n}\n");
        let root = tp.program.root;
        let lit = tp.tables[root].struct_lits.values().next().unwrap();
        assert!(matches!(&lit.fields[0].1, crate::typed::FieldValue::Local(_, cs) if *cs == vec![crate::typed::Coercion::WrapSome]));
        assert!(matches!(&lit.fields[1].1, crate::typed::FieldValue::Local(_, cs) if cs.is_empty()));
    }

    #[test]
    fn whole_program_c() {
        let tp = typed("fn len([], acc: int): int = acc\nfn len([_, ..t]: [int], acc: int): int = len(t, acc + 1)\nfn main() { print(len([1, 2], 0)) }\n");
        let o = crate::build::generate(&tp, Mode::Run).unwrap();
        assert!(o.c.contains("goto dk_tail;"), "self tail call is a loop");
        assert!(o.c.contains("duck_main_wrapper(argc, argv, dk_main_shim)"));
        assert!(o.holes.is_empty());
        let tp = typed("fn f(): int { ?? }\ntest \"t\" { assert f() == 1 }\n");
        let o = crate::build::generate(&tp, Mode::Test).unwrap();
        assert_eq!(o.tests, 1);
        assert_eq!(o.holes.len(), 1);
        assert!(o.c.contains("duck_test_register(\"t\""));
    }
}

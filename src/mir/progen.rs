//! Program-level MIR generation: refcounting helpers, element-ops tables, the compiler-derived
//! instances of the built-in shapes (`Show`, `Eq`, `Ord`, hashing, `to_value` / `from_value`),
//! boxes, string literals, constants and imprints, vtable types. Function bodies are lowered by
//! `lower.rs`; `build.rs` adds the entry point.
//!
//! # Ownership
//! The runtime's rules: arguments are borrowed, results are owned (+1). `retain`/`release` give
//! the statements that copy/drop a value of any type.

use std::collections::{HashMap, HashSet};

use super::types::TyInfo;
use super::{Abi, AggDef, BOp, Body, Ex, FRef, FuncId, Func, Global, GlobalId, K, MTy, Program, Rt, RtF, Sel, Stmt, AggId};
use crate::ast::Item;
use crate::resolve::ModId;
use crate::typed::{BodyRef, ConstId, FnKind, InstId, Target, TypedProgram};
use crate::types::{Builtin, ShapeId, Ty, TypeDefKind};

/// What kind of program is being built.
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
/// (every other build) the generated program is exactly what it would be without tracing.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Trace {
    /// Wrap the traced functions, set call sites, and start the tracer in `main`.
    pub on: bool,
    /// Trace the core library's Duck functions too.
    pub core: bool,
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

/// A C identifier fragment from a Duck name.
pub fn sanitize(s: &str) -> String {
    s.chars().map(|c| if c.is_ascii_alphanumeric() || c == '_' { c } else { '_' }).collect()
}

pub fn d(t: &Ty) -> MTy {
    MTy::D(t.clone())
}

pub struct Gen<'a> {
    pub tp: &'a TypedProgram,
    pub mode: Mode,
    pub info: TyInfo<'a>,
    pub prog: Program,
    memo: HashMap<(&'static str, Ty), u32>,
    /// Other memoized generated items (thunks, function values, vtables), by key.
    pub memo2: HashMap<String, u32>,
    lits: HashMap<String, GlobalId>,
    lit_order: Vec<(String, GlobalId)>,
    type_ids: HashMap<Ty, u32>,
    n: usize,
    /// Instances that have been emitted (or are being emitted).
    pub emitted: HashSet<InstId>,
    /// Instances still to emit.
    pub queue: Vec<InstId>,
    inst_fns: HashMap<InstId, FuncId>,
    /// Holes found in emitted bodies: "file:line:col: unfilled hole (expected T)".
    pub holes: Vec<String>,
    consts: HashMap<usize, FuncId>,
    /// (getter, free function) of each lazily computed constant, in creation order.
    const_order: Vec<(FuncId, FuncId)>,
    /// Building the imprint evaluator: constant getters report on the imprint protocol, and
    /// `to_value` is always the derived one.
    pub imprint_eval: bool,
    /// The compile-time values of the imprints (final program).
    pub imprints: HashMap<ConstId, CVal>,
    imprint_inits: Vec<FuncId>,
    pub trace: Trace,
}

impl<'a> Gen<'a> {
    pub fn new(tp: &'a TypedProgram, mode: Mode) -> Gen<'a> {
        Gen {
            tp,
            mode,
            info: TyInfo::new(tp),
            prog: Program::default(),
            memo: HashMap::new(),
            memo2: HashMap::new(),
            lits: HashMap::new(),
            lit_order: Vec::new(),
            type_ids: HashMap::new(),
            n: 0,
            emitted: HashSet::new(),
            queue: Vec::new(),
            inst_fns: HashMap::new(),
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
        self.info.is_value(t)
    }
    pub fn is_err_ty(&self, t: &Ty) -> bool {
        self.info.is_err_ty(t)
    }
    pub fn err_ty(&self) -> Ty {
        self.info.err_ty()
    }
    pub fn needs_rc(&self, t: &Ty) -> bool {
        self.info.needs_rc(t)
    }

    // ---- functions, aggregates, globals ----

    /// Declare a function (its body is defined later with `define`).
    pub fn declare(&mut self, name: String, params: Vec<MTy>, ret: MTy, abi: Abi) -> FuncId {
        let n = params.len() as u32;
        self.prog.funcs.push(Func { name, params: (0..n).collect(), ret, vars: params, body: Vec::new(), abi });
        self.prog.funcs.len() as FuncId - 1
    }

    /// A body whose first variables are the parameters of `f`.
    pub fn body_for(&self, f: FuncId) -> (Body, Vec<Ex>) {
        let mut b = Body::new();
        let ps: Vec<Ex> = self.prog.funcs[f as usize].vars.clone().into_iter().map(|t| b.new_var(t)).collect();
        (b, ps)
    }

    pub fn define(&mut self, f: FuncId, b: Body) {
        let (body, vars) = b.finish();
        let func = &mut self.prog.funcs[f as usize];
        func.body = body;
        func.vars = vars;
    }

    pub fn func_ret(&self, f: FuncId) -> MTy {
        self.prog.funcs[f as usize].ret.clone()
    }

    pub fn agg(&mut self, name: String, fields: Vec<MTy>) -> AggId {
        self.prog.aggs.push(AggDef { name, fields });
        self.prog.aggs.len() as AggId - 1
    }

    pub fn global(&mut self, name: String, ty: MTy, init: Option<Ex>, constant: bool) -> GlobalId {
        self.prog.globals.push(Global { name, ty, init, constant });
        self.prog.globals.len() as GlobalId - 1
    }

    pub fn global_ex(&self, g: GlobalId) -> Ex {
        Ex::new(K::Global(g), self.prog.globals[g as usize].ty.clone())
    }

    pub fn member_ty(&self, t: &MTy, s: Sel) -> MTy {
        self.info.member_ty(t, s, &self.prog.aggs)
    }

    /// Member `s` of an aggregate expression.
    pub fn fld(&self, v: &Ex, s: Sel) -> Ex {
        let ty = self.member_ty(&v.ty, s);
        v.clone().field(s, ty)
    }

    /// A call to a generated function.
    pub fn call(&self, f: FuncId, args: Vec<Ex>) -> Ex {
        let ret = self.func_ret(f);
        let ps = self.prog.funcs[f as usize].vars.clone();
        let args = args.into_iter().zip(ps.iter()).map(|(a, p)| super::retype(a, p)).collect();
        Ex::call(f, args, ret)
    }

    /// A call through a function reference with a known result type.
    pub fn call_ref(&self, f: &FRef, args: Vec<Ex>, ret: MTy) -> Ex {
        match f {
            FRef::Fn(f) => self.call(*f, args),
            FRef::Rt(s) => Ex::rt(s, args, ret),
        }
    }

    // ---- names of instances ----

    /// The function of an instance (requesting its emission).
    pub fn inst_fn(&mut self, i: InstId) -> FuncId {
        if let Some(&f) = self.inst_fns.get(&i) {
            return f;
        }
        let what = match self.tp.instances[i].body {
            BodyRef::Fn(f) => sanitize(&self.tp.fns[f].name),
            BodyRef::Test(_) => "test".to_string(),
            BodyRef::Const(c) => format!("const_{}", sanitize(&self.tp.consts[c].name)),
        };
        let (params, ret, abi) = match self.tp.instances[i].body {
            BodyRef::Test(_) => (Vec::new(), MTy::D(self.err_ty()), Abi::C),
            _ => {
                let ps = self.inst_params(i).into_iter().map(|(t, var)| if var { MTy::ptr(d(&t)) } else { d(&t) }).collect();
                (ps, d(&self.inst_ret(i)), Abi::Duck)
            }
        };
        let f = self.declare(format!("dk_f{i}_{what}"), params, ret, abi);
        self.inst_fns.insert(i, f);
        if let BodyRef::Fn(fid) = self.tp.instances[i].body {
            let info = &self.tp.fns[fid];
            let ps: Vec<String> = self.inst_params(i).iter().map(|(t, var)| format!("{}{}", if *var { "var " } else { "" }, self.tp.defs.show(t))).collect();
            let key = format!("{}::{}({}): {}", self.tp.program.mods[info.module].file, info.name, ps.join(", "), self.tp.defs.show(&self.inst_ret(i)));
            self.prog.live_keys.insert(f, key);
        }
        if !self.emitted.contains(&i) {
            self.queue.push(i);
        }
        f
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

    // ---- constants ----

    /// The getter of a constant (returns a borrowed value).
    pub fn const_getter(&mut self, c: usize) -> FuncId {
        if let Some(&f) = self.consts.get(&c) {
            return f;
        }
        let name = format!("dk_const{c}_{}", sanitize(&self.tp.consts[c].name));
        let ty = self.tp.consts[c].ty.clone();
        let getter = self.declare(name.clone(), Vec::new(), d(&ty), Abi::Duck);
        self.consts.insert(c, getter);
        let gv = self.global(format!("{name}_v"), d(&ty), None, false);
        if let Some(v) = self.imprints.get(&c).cloned() {
            // computed at compile time: rebuilt from its value at startup (no initializer runs)
            let mut b = Body::new();
            b.emit(Stmt::Ret(Some(self.global_ex(gv))));
            self.define(getter, b);
            let init = self.declare(format!("{name}_init"), Vec::new(), MTy::Void, Abi::Duck);
            let mut b = Body::new();
            let e = self.imprint_value(&ty, &v, &mut b);
            b.set(self.global_ex(gv), e);
            self.define(init, b);
            self.imprint_inits.push(init);
            return getter;
        }
        let inst = self.tp.instances.iter().position(|i| i.body == BodyRef::Const(c)).expect("constant instance");
        let initf = self.inst_fn(inst);
        let gs = self.global(format!("{name}_s"), MTy::I32, None, false);
        let (v, s) = (self.global_ex(gv), self.global_ex(gs));
        let mut b = Body::new();
        // the imprint evaluator reports progress (to attribute a panic) and cycles
        if self.imprint_eval {
            b.open_if(Ex::bin(BOp::Eq, s.clone(), Ex::int_as(1, MTy::I32)));
            b.do_(Ex::rt("duck__imprint_mark", vec![Ex::int_as(b'C' as i64, MTy::I32), Ex::i64(c as i64)], MTy::Void));
            b.close();
        }
        b.open_if(Ex::bin(BOp::Eq, s.clone(), Ex::int_as(0, MTy::I32)));
        b.set(s.clone(), Ex::int_as(1, MTy::I32));
        if self.imprint_eval {
            b.do_(Ex::rt("duck__imprint_mark", vec![Ex::int_as(b'B' as i64, MTy::I32), Ex::i64(c as i64)], MTy::Void));
        }
        // computed outside any task's heap: the value outlives the task that computes it first
        let heap = b.decl(Ex::rt("duck_heap_switch", vec![Ex::zero(MTy::void_ptr())], MTy::void_ptr()));
        let call = self.call(initf, vec![]);
        b.set(v.clone(), call);
        b.do_(Ex::rt("duck_heap_switch", vec![heap], MTy::void_ptr()));
        b.set(s.clone(), Ex::int_as(2, MTy::I32));
        if self.imprint_eval {
            b.do_(Ex::rt("duck__imprint_mark", vec![Ex::int_as(b'E' as i64, MTy::I32), Ex::i64(c as i64)], MTy::Void));
        }
        b.close();
        b.emit(Stmt::Ret(Some(v.clone())));
        self.define(getter, b);
        let free = self.declare(format!("{name}_free"), Vec::new(), MTy::Void, Abi::Duck);
        let mut b = Body::new();
        if let Some(r) = self.release(&ty, &v) {
            b.open_if(Ex::bin(BOp::Eq, s.clone(), Ex::int_as(2, MTy::I32)));
            b.emit(r);
            b.close();
        }
        b.set(s, Ex::int_as(0, MTy::I32));
        self.define(free, b);
        self.const_order.push((getter, free));
        getter
    }

    /// An expression for the compile-time value `v` of type `t`, built (by statements appended
    /// to `b`) from immortal objects: literal strings, and lists, maps and boxes made immortal.
    fn imprint_value(&mut self, t: &Ty, v: &CVal, b: &mut Body) -> Ex {
        match t {
            Ty::Int => match v {
                CVal::Int(n) => Ex::int(*n),
                _ => Ex::int(0),
            },
            Ty::Float => match v {
                CVal::Float(x) => Ex::float(*x),
                CVal::Int(n) => Ex::float(*n as f64),
                _ => Ex::float(0.0),
            },
            Ty::Bool => Ex::bool(*v == CVal::Bool(true)),
            Ty::Char => match v {
                CVal::Str(s) => Ex::int_as(s.chars().next().map_or(0, |c| c as i64), MTy::D(Ty::Char)),
                _ => Ex::int_as(0, MTy::D(Ty::Char)),
            },
            Ty::Str => match v {
                CVal::Str(s) => self.lit(s),
                _ => self.lit(""),
            },
            t if self.is_value(t) => self.imprint_dvalue(v, b),
            Ty::List(et) => {
                let xs = match v {
                    CVal::List(xs) => xs.as_slice(),
                    _ => &[],
                };
                let ops = self.ops(et);
                let a = b.decl(Ex::rt("duck_arr_new", vec![ops, Ex::int(xs.len() as i64)], d(t)));
                for x in xs {
                    let e = self.imprint_value(et, x, b);
                    let tmp = b.decl_as(d(et), e);
                    b.do_(Ex::rt("duck_arr_push", vec![a.clone().addr(), tmp.addr()], MTy::Void));
                }
                b.do_(Ex::rt("duck_make_immortal", vec![a.clone()], MTy::Void));
                a
            }
            Ty::Map(kt, vt) => {
                let (ko, vo) = (self.ops(kt), self.ops(vt));
                let m = b.decl(Ex::rt("duck_map_new", vec![ko, vo], d(t)));
                if let CVal::Map(es) = v {
                    for (k, x) in es {
                        let kc = self.lit(k);
                        let kv = b.decl(kc);
                        let xc = self.imprint_value(vt, x, b);
                        let xv = b.decl_as(d(vt), xc);
                        b.do_(Ex::rt("duck_map_set", vec![m.clone().addr(), kv.addr(), xv.addr()], MTy::Void));
                    }
                }
                // immortal only once filled (setting into an immortal map would copy it)
                b.do_(Ex::rt("duck_make_immortal", vec![m.clone()], MTy::Void));
                m
            }
            Ty::Opt(inner) => match v {
                CVal::Null => Ex::zero(d(t)),
                _ => {
                    let e = self.imprint_value(inner, v, b);
                    Ex::agg(d(t), vec![(Sel::F(0), Ex::new(K::Int(1), MTy::Bool)), (Sel::F(1), super::retype(e, &d(inner)))])
                }
            },
            Ty::Named(dd, _) if self.tp.defs.is_struct(*dd) => {
                let names: Vec<String> = self.tp.defs.fields(*dd).iter().map(|f| f.name.clone()).collect();
                let mut parts = Vec::new();
                for (i, (ft, boxed)) in self.info.struct_layout(t).into_iter().enumerate() {
                    let fv = v.field(&names[i]).cloned().unwrap_or(CVal::Null);
                    let e = self.imprint_value(&ft, &fv, b);
                    let e = if boxed { self.imprint_box(&ft, e, b) } else { e };
                    parts.push((Sel::F(i as u32), e));
                }
                Ex::agg(d(t), parts)
            }
            Ty::Named(dd, _) if self.tp.defs.is_enum(*dd) => {
                let vs = self.tp.defs.variants(*dd).to_vec();
                let tag = match v {
                    CVal::Str(s) => Some(s.as_str()),
                    _ => match v.field("tag") {
                        Some(CVal::Str(s)) => Some(s.as_str()),
                        _ => None,
                    },
                };
                let vi = tag.and_then(|n| vs.iter().position(|x| x.name == n)).unwrap_or(0);
                let layout = self.info.enum_layout(t);
                let mut parts = vec![(Sel::Tag, Ex::int_as(vi as i64, MTy::I32))];
                for (fi, (fname, _)) in vs[vi].fields.iter().enumerate() {
                    let key = fname.clone().unwrap_or_else(|| fi.to_string());
                    let fv = v.field(&key).cloned().unwrap_or(CVal::Null);
                    let (ft, boxed) = layout[vi][fi].clone();
                    let e = self.imprint_value(&ft, &fv, b);
                    let e = if boxed { self.imprint_box(&ft, e, b) } else { e };
                    parts.push((Sel::V(vi as u32, fi as u32), e));
                }
                Ex::agg(d(t), parts)
            }
            _ => Ex::zero(d(t)),
        }
    }

    /// A core `Value` built from a compile-time value.
    fn imprint_dvalue(&mut self, v: &CVal, b: &mut Body) -> Ex {
        let vt = d(&self.value_ty());
        match v {
            CVal::Null => Ex::rt("duck_value_null", vec![], vt),
            CVal::Bool(x) => Ex::rt("duck_value_bool", vec![Ex::bool(*x)], vt),
            CVal::Int(n) => Ex::rt("duck_value_int", vec![Ex::int(*n)], vt),
            CVal::Float(x) => Ex::rt("duck_value_float", vec![Ex::float(*x)], vt),
            CVal::Str(s) => {
                let l = self.lit(s);
                Ex::rt("duck_value_str", vec![l], vt)
            }
            CVal::List(xs) => {
                let lt = Ty::list(self.value_ty());
                let a = b.decl(Ex::rt("duck_value_list_new", vec![], d(&lt)));
                for x in xs {
                    let e = self.imprint_dvalue(x, b);
                    let tmp = b.decl(e);
                    b.do_(Ex::rt("duck_arr_push", vec![a.clone().addr(), tmp.addr()], MTy::Void));
                }
                b.do_(Ex::rt("duck_make_immortal", vec![a.clone()], MTy::Void));
                Ex::rt("duck_value_list", vec![a], vt)
            }
            CVal::Map(es) => {
                let mt = Ty::Map(Box::new(Ty::Str), Box::new(self.value_ty()));
                let m = b.decl(Ex::rt("duck_value_map_new", vec![], d(&mt)));
                for (k, x) in es {
                    let kc = self.lit(k);
                    let kv = b.decl(kc);
                    let xc = self.imprint_dvalue(x, b);
                    let xv = b.decl(xc);
                    b.do_(Ex::rt("duck_map_set", vec![m.clone().addr(), kv.addr(), xv.addr()], MTy::Void));
                }
                b.do_(Ex::rt("duck_make_immortal", vec![m.clone()], MTy::Void));
                Ex::rt("duck_value_map", vec![m], vt)
            }
        }
    }

    /// A box holding the value `e` (of type `t`), made immortal.
    fn imprint_box(&mut self, t: &Ty, e: Ex, b: &mut Body) -> Ex {
        let bx = self.box_new(t, e);
        let o = b.decl(bx);
        b.do_(Ex::rt("duck_make_immortal", vec![o.clone()], MTy::Void));
        o
    }

    /// The core `Value` type.
    pub fn value_ty(&self) -> Ty {
        Ty::Named(self.info.value_def.expect("core Value"), Vec::new())
    }

    // ---- string literals ----

    /// The global holding an immortal `DuckStr` for this text (a `str` value).
    pub fn lit(&mut self, s: &str) -> Ex {
        if let Some(&g) = self.lits.get(s) {
            return self.global_ex(g);
        }
        let g = self.global(format!("dk_lit{}", self.lit_order.len()), MTy::D(Ty::Str), None, false);
        self.lits.insert(s.to_string(), g);
        self.lit_order.push((s.to_string(), g));
        self.global_ex(g)
    }

    /// A small stable id for a typed error payload type.
    pub fn type_id(&mut self, t: &Ty) -> u32 {
        let n = self.type_ids.len() as u32 + 1;
        *self.type_ids.entry(t.clone()).or_insert(n)
    }

    // ---- struct fields, boxes, variants ----

    /// Field `i` of the struct value `v`, unboxed (a place when `v` is one).
    pub fn field_get(&mut self, t: &Ty, i: usize, v: &Ex) -> Ex {
        let (ft, boxed) = self.info.struct_layout(t).swap_remove(i);
        let raw = self.fld(v, Sel::F(i as u32));
        if boxed { self.unbox(&ft, raw) } else { raw }
    }

    /// The raw member of field `i` (a `DuckObj *` when boxed) and whether it is boxed.
    pub fn field_raw(&mut self, t: &Ty, i: usize, v: &Ex) -> (Ex, bool) {
        let boxed = self.info.struct_layout(t)[i].1;
        (self.fld(v, Sel::F(i as u32)), boxed)
    }

    /// The member value to store in field `i` from an owned value (boxing it if needed).
    pub fn field_put(&mut self, t: &Ty, i: usize, owned: Ex) -> Ex {
        let (ft, boxed) = self.info.struct_layout(t).swap_remove(i);
        if boxed { self.box_new(&ft, owned) } else { super::retype(owned, &d(&ft)) }
    }

    /// The value inside a box cell (a place).
    pub fn unbox(&mut self, t: &Ty, raw: Ex) -> Ex {
        let bt = self.box_ty(t);
        raw.cast(MTy::ptr(MTy::Agg(bt))).deref(MTy::Agg(bt)).field(Sel::F(1), d(t))
    }

    /// The box cell type for a boxed value of type `t`: `{ DuckObj o; T v; }`, and its drop.
    pub fn box_ty(&mut self, t: &Ty) -> AggId {
        if let Some(&n) = self.memo.get(&("box", t.clone())) {
            return n;
        }
        let k = self.fresh();
        let a = self.agg(format!("DkBox{k}"), vec![MTy::Rt(Rt::Obj), d(t)]);
        self.memo.insert(("box", t.clone()), a);
        let drop = self.declare(format!("DkBox{k}_drop"), vec![MTy::obj_ptr()], MTy::Void, Abi::C);
        self.memo.insert(("boxdrop", t.clone()), drop);
        let copy = self.declare(format!("DkBox{k}_copy"), vec![MTy::obj_ptr()], MTy::obj_ptr(), Abi::C);
        self.memo.insert(("boxcopy", t.clone()), copy);
        let (mut b, ps) = self.body_for(drop);
        let v = ps[0].clone().cast(MTy::ptr(MTy::Agg(a))).deref(MTy::Agg(a)).field(Sel::F(1), d(t));
        if let Some(r) = self.release(t, &v) {
            b.emit(r);
        }
        self.define(drop, b);
        // the copy: a new box holding a deep copy of the value
        let (mut b, ps) = self.body_for(copy);
        let v = ps[0].clone().cast(MTy::ptr(MTy::Agg(a))).deref(MTy::Agg(a)).field(Sel::F(1), d(t));
        let c = self.copy_ex(t, v);
        let nb = self.box_new(t, c);
        b.emit(Stmt::Ret(Some(nb)));
        self.define(copy, b);
        a
    }

    /// An expression boxing an owned value `v` of type `t` (an owned `DuckObj *`).
    pub fn box_new(&mut self, t: &Ty, v: Ex) -> Ex {
        let f = self.helper("boxnew", t, vec![d(t)], MTy::obj_ptr(), |g, f| {
            let bt = g.box_ty(t);
            let drop = g.memo[&("boxdrop", t.clone())];
            let copy = g.memo[&("boxcopy", t.clone())];
            let (mut b, ps) = g.body_for(f);
            let x = b.decl(Ex::rt("duck_obj_alloc", vec![Ex::size_of(MTy::Agg(bt)), Ex::fn_addr(drop), Ex::fn_addr(copy)], MTy::ptr(MTy::Agg(bt))));
            b.set(x.clone().deref(MTy::Agg(bt)).field(Sel::F(1), d(t)), ps[0].clone());
            b.emit(Stmt::Ret(Some(x.cast(MTy::obj_ptr()))));
            b
        });
        self.call(f, vec![v])
    }

    /// `void f(DuckObj **p)`: make the box `*p` (holding a `t`) uniquely owned before a write
    /// through it, copying it when it is shared (or immortal): copy-on-write for boxed fields.
    pub fn box_unique(&mut self, t: &Ty) -> FuncId {
        self.helper("boxuniq", t, vec![MTy::ptr(MTy::obj_ptr())], MTy::Void, |g, f| {
            let (mut b, ps) = g.body_for(f);
            let p = ps[0].clone().deref(MTy::obj_ptr());
            b.open_if(Ex::bin(BOp::Eq, Ex::rt("duck_refcount", vec![p.clone()], MTy::I64), Ex::i64(1)));
            b.emit(Stmt::Ret(None));
            b.close();
            let inner = g.unbox(t, p.clone());
            let v = b.decl(inner);
            if let Some(r) = g.retain(t, &v) {
                b.emit(r);
            }
            let mk = g.box_new(t, v);
            let n = b.decl(mk);
            b.do_(Ex::rt("duck_release", vec![p.clone()], MTy::Void));
            b.set(p, n);
            b
        })
    }

    /// Field `fi` of variant `vi` of the enum value `v` (unboxed; a place when `v` is one).
    pub fn variant_field(&mut self, t: &Ty, vi: usize, fi: usize, v: &Ex) -> Ex {
        let raw = self.fld(v, Sel::V(vi as u32, fi as u32));
        if self.is_value(t) {
            return raw;
        }
        let (ft, boxed) = self.info.enum_layout(t)[vi][fi].clone();
        if boxed { self.unbox(&ft, raw) } else { raw }
    }

    /// Variant `vi` of enum `t` from owned field values.
    pub fn variant_new(&mut self, t: &Ty, vi: usize, fields: Vec<Ex>) -> Ex {
        let layout = self.info.enum_layout(t);
        let mut parts = vec![(Sel::Tag, Ex::int_as(vi as i64, MTy::I32))];
        for (fi, f) in fields.into_iter().enumerate() {
            let (ft, boxed) = layout[vi][fi].clone();
            let v = if boxed { self.box_new(&ft, f) } else { super::retype(f, &d(&ft)) };
            parts.push((Sel::V(vi as u32, fi as u32), v));
        }
        Ex::agg(d(t), parts)
    }

    /// The tag test of variant `vi` for an enum value `v`.
    pub fn variant_tag(&self, _t: &Ty, vi: usize, v: &Ex) -> Ex {
        Ex::bin(BOp::Eq, self.fld(v, Sel::Tag), Ex::int_as(vi as i64, MTy::I32))
    }

    /// A zero value of the type.
    pub fn zero(&self, t: &Ty) -> Ex {
        Ex::zero(d(t))
    }

    // ---- refcounting ----

    /// A statement that retains the value `v` (None if the type holds no references).
    pub fn retain(&mut self, t: &Ty, v: &Ex) -> Option<Stmt> {
        if !self.needs_rc(t) {
            return None;
        }
        let ptr = |p: Ex| Stmt::Do(Ex::rt("duck_retain", vec![p], MTy::void_ptr()));
        Some(match t {
            Ty::Str | Ty::List(_) | Ty::Map(..) | Ty::Task(_) => ptr(v.clone()),
            Ty::Fn(..) => ptr(self.fld(v, Sel::F(1))),
            Ty::Any(_) => ptr(self.fld(v, Sel::F(0))),
            t if self.info.is_opaque(t) => ptr(v.clone()),
            t if self.is_value(t) => Stmt::Do(Ex::rt("duck_value_retain", vec![v.clone()], MTy::Void)),
            _ => {
                let f = self.rc_fns(t).0;
                Stmt::Do(self.call(f, vec![v.clone()]))
            }
        })
    }

    /// A statement that releases the value `v` (None if the type holds no references).
    pub fn release(&mut self, t: &Ty, v: &Ex) -> Option<Stmt> {
        if !self.needs_rc(t) {
            return None;
        }
        let ptr = |p: Ex| Stmt::Do(Ex::rt("duck_release", vec![p], MTy::Void));
        Some(match t {
            Ty::Str | Ty::List(_) | Ty::Map(..) | Ty::Task(_) => ptr(v.clone()),
            Ty::Fn(..) => ptr(self.fld(v, Sel::F(1))),
            Ty::Any(_) => ptr(self.fld(v, Sel::F(0))),
            t if self.info.is_opaque(t) => ptr(v.clone()),
            t if self.is_value(t) => Stmt::Do(Ex::rt("duck_value_release", vec![v.clone()], MTy::Void)),
            _ => {
                let f = self.rc_fns(t).1;
                Stmt::Do(self.call(f, vec![v.clone()]))
            }
        })
    }

    /// Generated retain/release functions for an aggregate type.
    fn rc_fns(&mut self, t: &Ty) -> (FuncId, FuncId) {
        if let Some(&n) = self.memo.get(&("rc", t.clone())) {
            return (n, n + 1);
        }
        let k = self.fresh();
        let inc = self.declare(format!("dk_rc{k}_retain"), vec![d(t)], MTy::Void, Abi::Duck);
        let dec = self.declare(format!("dk_rc{k}_release"), vec![d(t)], MTy::Void, Abi::Duck);
        self.memo.insert(("rc", t.clone()), inc);
        let (mut bi, pi) = self.body_for(inc);
        let (mut bd, pd) = self.body_for(dec);
        let (vi, vd) = (pi[0].clone(), pd[0].clone());
        let both = |g: &mut Gen, ty: &Ty, s: Sel, bi: &mut Body, bd: &mut Body| {
            let (ei, ed) = (g.fld(&vi, s), g.fld(&vd, s));
            if let Some(s) = g.retain(ty, &ei) {
                bi.emit(s);
            }
            if let Some(s) = g.release(ty, &ed) {
                bd.emit(s);
            }
        };
        let obj = |g: &mut Gen, s: Sel, bi: &mut Body, bd: &mut Body| {
            bi.do_(Ex::rt("duck_retain", vec![g.fld(&vi, s)], MTy::void_ptr()));
            bd.do_(Ex::rt("duck_release", vec![g.fld(&vd, s)], MTy::Void));
        };
        match t {
            Ty::Tuple(ts) => {
                for (i, x) in ts.iter().enumerate() {
                    both(self, x, Sel::F(i as u32), &mut bi, &mut bd);
                }
            }
            Ty::Opt(x) => {
                bi.open_if(self.fld(&vi, Sel::F(0)));
                bd.open_if(self.fld(&vd, Sel::F(0)));
                both(self, x, Sel::F(1), &mut bi, &mut bd);
                bi.close();
                bd.close();
            }
            Ty::Res(x, _) => {
                bi.open_if(self.fld(&vi, Sel::F(0)));
                bd.open_if(self.fld(&vd, Sel::F(0)));
                both(self, x, Sel::F(1), &mut bi, &mut bd);
                bi.else_();
                bd.else_();
                obj(self, Sel::F(2), &mut bi, &mut bd);
                bi.close();
                bd.close();
            }
            Ty::Named(dd, _) if self.tp.defs.is_struct(*dd) => {
                for (i, (ft, boxed)) in self.info.struct_layout(t).into_iter().enumerate() {
                    if boxed {
                        obj(self, Sel::F(i as u32), &mut bi, &mut bd);
                    } else {
                        both(self, &ft, Sel::F(i as u32), &mut bi, &mut bd);
                    }
                }
            }
            Ty::Named(..) => {
                let layout = self.info.enum_layout(t);
                for (vi_, fs) in layout.iter().enumerate() {
                    if !fs.iter().any(|(ft, boxed)| *boxed || self.needs_rc(ft)) {
                        continue;
                    }
                    bi.open_if(self.variant_tag(t, vi_, &vi));
                    bd.open_if(self.variant_tag(t, vi_, &vd));
                    for (fi, (ft, boxed)) in fs.iter().enumerate() {
                        let s = Sel::V(vi_ as u32, fi as u32);
                        if *boxed {
                            obj(self, s, &mut bi, &mut bd);
                        } else {
                            both(self, ft, s, &mut bi, &mut bd);
                        }
                    }
                    bi.close();
                    bd.close();
                }
            }
            _ => {}
        }
        self.define(inc, bi);
        self.define(dec, bd);
        (inc, dec)
    }

    // ---- deep copies (values crossing a task boundary: runtime/src/heap.rs) ----

    /// An owned deep copy of the value `v` of type `t`, allocated in the current heap. Handles
    /// (tasks, connections, listeners, channels) are shared instead.
    pub fn copy_ex(&mut self, t: &Ty, v: Ex) -> Ex {
        if !self.needs_rc(t) {
            return v;
        }
        let rt = |s: &str, v: Ex| Ex::rt(s, vec![v], d(t));
        match t {
            Ty::Str => rt("duck_str_copy", v),
            Ty::List(_) => rt("duck_arr_copy_deep", v),
            Ty::Map(..) => rt("duck_map_copy_deep", v),
            Ty::Task(_) => rt("duck_retain", v),
            t if self.info.is_opaque(t) && !self.is_err_ty(t) => rt("duck_retain", v),
            t if self.is_value(t) => rt("duck_value_copy", v),
            t if self.is_err_ty(t) => rt("duck_err_copy_deep", v),
            _ => {
                let f = self.copy_fn(t);
                self.call(f, vec![v])
            }
        }
    }

    /// `T f(T)`: a deep copy of an aggregate (closure, `any`, tuple, optional, result, struct,
    /// enum).
    fn copy_fn(&mut self, t: &Ty) -> FuncId {
        self.helper("copy", t, vec![d(t)], d(t), |g, f| {
            let (mut b, ps) = g.body_for(f);
            let src = ps[0].clone();
            let r = b.decl(src.clone());
            let obj = |g: &mut Gen, b: &mut Body, s: Sel| {
                let c = Ex::rt("duck_obj_copy", vec![g.fld(&src, s)], MTy::obj_ptr());
                b.set(g.fld(&r, s), c);
            };
            let field = |g: &mut Gen, b: &mut Body, ty: &Ty, s: Sel| {
                if g.needs_rc(ty) {
                    let c = g.copy_ex(ty, g.fld(&src, s));
                    b.set(g.fld(&r, s), c);
                }
            };
            match t {
                Ty::Fn(..) => obj(g, &mut b, Sel::F(1)),
                Ty::Any(_) => obj(g, &mut b, Sel::F(0)),
                Ty::Tuple(ts) => {
                    for (i, x) in ts.iter().enumerate() {
                        field(g, &mut b, x, Sel::F(i as u32));
                    }
                }
                Ty::Opt(x) => {
                    b.open_if(g.fld(&src, Sel::F(0)));
                    field(g, &mut b, x, Sel::F(1));
                    b.close();
                }
                Ty::Res(x, _) => {
                    b.open_if(g.fld(&src, Sel::F(0)));
                    field(g, &mut b, x, Sel::F(1));
                    b.else_();
                    let c = Ex::rt("duck_err_copy_deep", vec![g.fld(&src, Sel::F(2))], MTy::void_ptr());
                    b.set(g.fld(&r, Sel::F(2)), c);
                    b.close();
                }
                Ty::Named(dd, _) if g.tp.defs.is_struct(*dd) => {
                    for (i, (ft, boxed)) in g.info.struct_layout(t).into_iter().enumerate() {
                        if boxed {
                            obj(g, &mut b, Sel::F(i as u32));
                        } else {
                            field(g, &mut b, &ft, Sel::F(i as u32));
                        }
                    }
                }
                Ty::Named(..) => {
                    let layout = g.info.enum_layout(t);
                    for (vi, fs) in layout.iter().enumerate() {
                        if !fs.iter().any(|(ft, boxed)| *boxed || g.needs_rc(ft)) {
                            continue;
                        }
                        b.open_if(g.variant_tag(t, vi, &src));
                        for (fi, (ft, boxed)) in fs.iter().enumerate() {
                            let s = Sel::V(vi as u32, fi as u32);
                            if *boxed {
                                obj(g, &mut b, s);
                            } else {
                                field(g, &mut b, ft, s);
                            }
                        }
                        b.close();
                    }
                }
                _ => {}
            }
            b.emit(Stmt::Ret(Some(r)));
            b
        })
    }

    // ---- memoized helper functions ----

    /// A generated helper function for (kind, type), created once: declared with `params` and
    /// `ret`, then `make(gen, f)` builds its body.
    pub fn helper(&mut self, kind: &'static str, t: &Ty, params: Vec<MTy>, ret: MTy, make: impl FnOnce(&mut Gen<'a>, FuncId) -> Body) -> FuncId {
        self.helper_abi(kind, t, params, ret, Abi::Duck, make)
    }

    pub fn helper_abi(&mut self, kind: &'static str, t: &Ty, params: Vec<MTy>, ret: MTy, abi: Abi, make: impl FnOnce(&mut Gen<'a>, FuncId) -> Body) -> FuncId {
        if let Some(&f) = self.memo.get(&(kind, t.clone())) {
            return f;
        }
        let k = self.fresh();
        let f = self.declare(format!("dk_{kind}{k}"), params, ret, abi);
        self.memo.insert((kind, t.clone()), f);
        let b = make(self, f);
        self.define(f, b);
        f
    }

    /// The user (or core) implementation of a built-in shape for `t`, when it is a function.
    pub fn user_impl(&mut self, b: Builtin, t: &Ty) -> Option<FRef> {
        if b == Builtin::Data && self.imprint_eval {
            return None;
        }
        match self.tp.shape_impls.get(&(b, t.clone())) {
            Some(Target::Instance(i)) => Some(FRef::Fn(self.inst_fn(*i))),
            Some(Target::Extern { symbol, .. }) => Some(FRef::Rt(symbol.clone())),
            _ => None,
        }
    }

    // ---- element ops ----

    /// A pointer to the element ops of a container element type.
    pub fn ops(&mut self, t: &Ty) -> Ex {
        let rt = |s: &str| Ex::rt_global(s, MTy::Rt(Rt::ElemOps));
        match t {
            Ty::Int => return rt("duck_ops_int"),
            Ty::Float => return rt("duck_ops_float"),
            Ty::Bool => return rt("duck_ops_bool"),
            Ty::Char => return rt("duck_ops_char"),
            Ty::Str => {
                if self.user_impl(Builtin::Show, t).is_none() {
                    return rt("duck_ops_str");
                }
            }
            Ty::Never => return rt("duck_ops_unit"),
            Ty::Tuple(ts) if ts.is_empty() => return rt("duck_ops_unit"),
            Ty::Task(_) => return rt("duck_ops_task"),
            Ty::Fn(..) => return rt("duck_ops_closure"),
            t if self.is_value(t) => return rt("duck_ops_value"),
            t if self.is_err_ty(t) => return rt("duck_ops_err"),
            _ => {}
        }
        if let Some(&g) = self.memo.get(&("ops", t.clone())) {
            return Ex::new(K::GlobalAddr(g), MTy::ptr(MTy::Rt(Rt::ElemOps)));
        }
        let k = self.fresh();
        let name = format!("dk_ops{k}");
        let g = self.global(name.clone(), MTy::Rt(Rt::ElemOps), None, true);
        self.memo.insert(("ops", t.clone()), g);
        let elem = |p: &Ex| p.clone().cast(MTy::ptr(d(t))).deref(d(t));
        let cv = MTy::void_ptr();
        let (ret, rel) = if self.needs_rc(t) {
            let rn = self.declare(format!("{name}_retain"), vec![cv.clone()], MTy::Void, Abi::C);
            let ln = self.declare(format!("{name}_release"), vec![cv.clone()], MTy::Void, Abi::C);
            for (f, inc) in [(rn, true), (ln, false)] {
                let (mut b, ps) = self.body_for(f);
                let s = if inc { self.retain(t, &elem(&ps[0])) } else { self.release(t, &elem(&ps[0])) };
                b.emit(s.unwrap());
                self.define(f, b);
            }
            (Ex::fn_addr(rn), Ex::fn_addr(ln))
        } else {
            (Ex::zero(MTy::Code), Ex::zero(MTy::Code))
        };
        let eq = match self.eq_fn(t) {
            Some(f) => {
                let n = self.declare(format!("{name}_eq"), vec![cv.clone(), cv.clone()], MTy::Bool, Abi::C);
                let (mut b, ps) = self.body_for(n);
                let c = self.call_ref(&f, vec![elem(&ps[0]), elem(&ps[1])], MTy::D(Ty::Bool));
                b.emit(Stmt::Ret(Some(c.cast(MTy::Bool))));
                self.define(n, b);
                Ex::fn_addr(n)
            }
            None => Ex::zero(MTy::Code),
        };
        let cmp = match self.cmp_fn(t) {
            Some(f) => {
                let n = self.declare(format!("{name}_cmp"), vec![cv.clone(), cv.clone()], MTy::I32, Abi::C);
                let (mut b, ps) = self.body_for(n);
                let r = b.decl(self.call_ref(&f, vec![elem(&ps[0]), elem(&ps[1])], MTy::D(Ty::Int)));
                let gt = Ex::bin(BOp::Gt, r.clone(), Ex::int(0)).cast(MTy::I32);
                let lt = Ex::bin(BOp::Lt, r, Ex::int(0)).cast(MTy::I32);
                b.emit(Stmt::Ret(Some(Ex::bin(BOp::Sub, gt, lt))));
                self.define(n, b);
                Ex::fn_addr(n)
            }
            None => Ex::zero(MTy::Code),
        };
        let hash = match self.hash_fn(t) {
            Some(f) => {
                let n = self.declare(format!("{name}_hash"), vec![cv.clone()], MTy::U64, Abi::C);
                let (mut b, ps) = self.body_for(n);
                b.emit(Stmt::Ret(Some(self.call_ref(&f, vec![elem(&ps[0])], MTy::U64))));
                self.define(n, b);
                Ex::fn_addr(n)
            }
            None => Ex::zero(MTy::Code),
        };
        let show = match self.dshow_fn(t) {
            Some(f) => {
                let n = self.declare(format!("{name}_show"), vec![cv.clone()], MTy::D(Ty::Str), Abi::C);
                let (mut b, ps) = self.body_for(n);
                b.emit(Stmt::Ret(Some(self.call_ref(&f, vec![elem(&ps[0])], MTy::D(Ty::Str)))));
                self.define(n, b);
                Ex::fn_addr(n)
            }
            None => Ex::zero(MTy::Code),
        };
        let copy = if self.needs_rc(t) {
            let n = self.declare(format!("{name}_copy"), vec![cv.clone(), cv.clone()], MTy::Void, Abi::C);
            let (mut b, ps) = self.body_for(n);
            let c = self.copy_ex(t, elem(&ps[0]));
            b.set(elem(&ps[1]), c);
            self.define(n, b);
            Ex::fn_addr(n)
        } else {
            Ex::zero(MTy::Code)
        };
        let init = Ex::agg(
            MTy::Rt(Rt::ElemOps),
            vec![
                (Sel::F(0), Ex::size_of(d(t))),
                (Sel::F(1), ret),
                (Sel::F(2), rel),
                (Sel::F(3), eq),
                (Sel::F(4), cmp),
                (Sel::F(5), hash),
                (Sel::F(6), show),
                (Sel::F(7), copy),
            ],
        );
        self.prog.globals[g as usize].init = Some(init);
        Ex::new(K::GlobalAddr(g), MTy::ptr(MTy::Rt(Rt::ElemOps)))
    }

    // ---- Show ----

    /// `DuckStr *f(T)`: the top-level `Show` text of a value (owned result). None for types
    /// without `Show`.
    pub fn show_fn(&mut self, t: &Ty) -> Option<FRef> {
        if let Some(f) = self.user_impl(Builtin::Show, t) {
            return Some(f);
        }
        let rt = |s: &str| Some(FRef::Rt(s.to_string()));
        match t {
            Ty::Int => rt("duck_str_from_int"),
            Ty::Float => rt("duck_str_from_float"),
            Ty::Bool => rt("duck_str_from_bool"),
            Ty::Char => rt("duck_str_from_char"),
            Ty::Str => Some(FRef::Fn(self.helper("showstr", t, vec![d(t)], d(t), |g, f| {
                let (mut b, ps) = g.body_for(f);
                b.emit(Stmt::Ret(Some(Ex::rt("duck_retain", vec![ps[0].clone()], MTy::D(Ty::Str)))));
                b
            }))),
            t if self.is_value(t) => rt("duck_value_show"),
            t if self.is_err_ty(t) => rt("duck_err_show"),
            Ty::Fn(..) | Ty::Task(_) => None,
            t if self.info.is_opaque(t) => None,
            _ => {
                let t2 = t.clone();
                Some(FRef::Fn(self.helper("show", t, vec![d(t)], MTy::D(Ty::Str), move |g, f| g.derive_show(&t2, f))))
            }
        }
    }

    /// The "debug" show used inside containers and derived shows: strings and chars quoted.
    pub fn dshow_fn(&mut self, t: &Ty) -> Option<FRef> {
        match t {
            Ty::Str if self.user_impl(Builtin::Show, t).is_none() => Some(FRef::Rt("duck_str_quote".into())),
            Ty::Char if self.user_impl(Builtin::Show, t).is_none() => Some(FRef::Rt("duck_char_quote".into())),
            _ => self.show_fn(t),
        }
    }

    /// Push a static text onto a string builder.
    pub fn sb_lit(&self, b: &mut Body, sb: &Ex, s: &str) {
        b.do_(Ex::rt("duck_sb_bytes", vec![sb.clone().addr(), Ex::cstr(s), Ex::int(s.len() as i64)], MTy::Void));
    }

    fn derive_show(&mut self, t: &Ty, f: FuncId) -> Body {
        let (mut b, ps) = self.body_for(f);
        let v = ps[0].clone();
        let str_t = MTy::D(Ty::Str);
        if let Ty::List(_) = t {
            b.emit(Stmt::Ret(Some(Ex::rt("duck_arr_show", vec![v], str_t))));
            return b;
        }
        if let Ty::Map(..) = t {
            b.emit(Stmt::Ret(Some(Ex::rt("duck_map_show", vec![v], str_t))));
            return b;
        }
        let sb = b.decl(Ex::zero(MTy::Rt(Rt::StrBuf)));
        let field = |g: &mut Gen, b: &mut Body, ft: &Ty, e: Ex| match g.dshow_fn(ft) {
            Some(f) => {
                let s = g.call_ref(&f, vec![e], MTy::D(Ty::Str));
                b.do_(Ex::rt("duck_sb_str_own", vec![sb.clone().addr(), s], MTy::Void));
            }
            None => {
                let text = format!("<{}>", g.show_ty(ft).replace('"', ""));
                g.sb_lit(b, &sb, &text);
            }
        };
        match t {
            Ty::Never => self.sb_lit(&mut b, &sb, "()"),
            Ty::Tuple(ts) => {
                self.sb_lit(&mut b, &sb, "(");
                for (i, x) in ts.iter().enumerate() {
                    if i > 0 {
                        self.sb_lit(&mut b, &sb, ", ");
                    }
                    let e = self.fld(&v, Sel::F(i as u32));
                    field(self, &mut b, x, e);
                }
                self.sb_lit(&mut b, &sb, ")");
            }
            Ty::Opt(x) => {
                b.open_if(self.fld(&v, Sel::F(0)).not());
                self.sb_lit(&mut b, &sb, "none");
                b.else_();
                self.sb_lit(&mut b, &sb, "some(");
                let e = self.fld(&v, Sel::F(1));
                field(self, &mut b, x, e);
                self.sb_lit(&mut b, &sb, ")");
                b.close();
            }
            Ty::Res(x, _) => {
                b.open_if(self.fld(&v, Sel::F(0)).not());
                self.sb_lit(&mut b, &sb, "err(");
                let es = Ex::rt("duck_err_show", vec![self.fld(&v, Sel::F(2))], MTy::D(Ty::Str));
                b.do_(Ex::rt("duck_sb_str_own", vec![sb.clone().addr(), es], MTy::Void));
                self.sb_lit(&mut b, &sb, ")");
                b.else_();
                self.sb_lit(&mut b, &sb, "ok(");
                let e = self.fld(&v, Sel::F(1));
                field(self, &mut b, x, e);
                self.sb_lit(&mut b, &sb, ")");
                b.close();
            }
            Ty::Any(s) => {
                let sd = self.tp.defs.shapes[*s].clone();
                if sd.builtin == Some(Builtin::Show) {
                    let vt = self.vt_struct(*s);
                    let m0 = self.fld(&v, Sel::F(1)).cast(MTy::ptr(MTy::Agg(vt))).deref(MTy::Agg(vt)).field(Sel::F(0), MTy::Code);
                    let call = Ex::new(K::Call(super::Callee::Indirect(Box::new(m0), vec![MTy::obj_ptr()]), vec![self.fld(&v, Sel::F(0))]), MTy::D(Ty::Str));
                    b.do_(Ex::rt("duck_sb_str_own", vec![sb.clone().addr(), call], MTy::Void));
                } else {
                    self.sb_lit(&mut b, &sb, &format!("<any {}>", sd.name));
                }
            }
            Ty::Named(dd, args) if self.tp.defs.is_struct(*dd) => {
                let s = self.tp.defs.subst_of(*dd, args);
                let def = self.tp.defs.types[*dd].clone();
                let TypeDefKind::Struct { fields } = &def.kind else { unreachable!() };
                if fields.is_empty() {
                    self.sb_lit(&mut b, &sb, &format!("{} {{}}", def.name));
                } else {
                    for (i, f) in fields.iter().enumerate() {
                        let sep = if i == 0 { format!("{} {{ ", def.name) } else { ", ".to_string() };
                        self.sb_lit(&mut b, &sb, &format!("{sep}{}: ", f.name));
                        let e = self.field_get(t, i, &v);
                        field(self, &mut b, &f.ty.subst(&s), e);
                    }
                    self.sb_lit(&mut b, &sb, " }");
                }
            }
            Ty::Named(dd, _) => {
                let vs = self.tp.defs.variants(*dd).to_vec();
                let layout = self.info.enum_layout(t);
                for (vi, var) in vs.iter().enumerate() {
                    b.open_if(self.variant_tag(t, vi, &v));
                    self.sb_lit(&mut b, &sb, &var.name);
                    if !var.fields.is_empty() {
                        self.sb_lit(&mut b, &sb, "(");
                        for (fi, (ft, _)) in layout[vi].iter().enumerate() {
                            if fi > 0 {
                                self.sb_lit(&mut b, &sb, ", ");
                            }
                            let e = self.variant_field(t, vi, fi, &v);
                            field(self, &mut b, ft, e);
                        }
                        self.sb_lit(&mut b, &sb, ")");
                    }
                    b.close();
                }
            }
            _ => {
                let text = format!("<{}>", self.show_ty(t).replace('"', ""));
                self.sb_lit(&mut b, &sb, &text);
            }
        }
        b.emit(Stmt::Ret(Some(Ex::rt("duck_sb_finish", vec![sb.addr()], str_t))));
        b
    }

    // ---- Eq / Ord / hash ----

    /// `bool f(T a, T b)`, or None when the type has no equality.
    pub fn eq_fn(&mut self, t: &Ty) -> Option<FRef> {
        if let Some(f) = self.user_impl(Builtin::Eq, t) {
            return Some(f);
        }
        let rt = |s: &str| Some(FRef::Rt(s.to_string()));
        match t {
            Ty::Fn(..) | Ty::Task(_) => return None,
            t if self.info.is_opaque(t) && !self.is_err_ty(t) => return None,
            t if self.is_value(t) => return rt("duck_value_eq"),
            Ty::Str => return rt("duck_str_eq"),
            Ty::List(_) => return rt("duck_arr_eq"),
            Ty::Map(..) => return rt("duck_map_eq"),
            _ => {}
        }
        if !self.can(t, Builtin::Eq, &mut HashSet::new()) {
            return None;
        }
        let t2 = t.clone();
        Some(FRef::Fn(self.helper("eq", t, vec![d(t), d(t)], MTy::D(Ty::Bool), move |g, f| g.derive_eq(&t2, f))))
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
            Ty::Named(dd, args) => {
                if Some(*dd) == self.info.value_def {
                    return b != Builtin::Ord;
                }
                let s = self.tp.defs.subst_of(*dd, args);
                match self.tp.defs.types[*dd].kind.clone() {
                    TypeDefKind::Opaque { .. } => b == Builtin::Eq && self.is_err_ty(t),
                    TypeDefKind::Struct { fields } => fields.iter().all(|f| self.can(&f.ty.subst(&s), b, seen)),
                    TypeDefKind::Enum { variants } => variants.iter().all(|v| v.fields.iter().all(|(_, ft)| self.can(&ft.subst(&s), b, seen))),
                }
            }
            _ => false,
        }
    }

    /// Equality of two values of type `t` (a bool expression).
    pub fn eq_expr(&mut self, t: &Ty, a: Ex, b: Ex) -> Ex {
        match t {
            Ty::Int | Ty::Float | Ty::Bool | Ty::Char => Ex::bin(BOp::Eq, a, b),
            Ty::Never => Ex::bool(true),
            Ty::Tuple(ts) if ts.is_empty() => Ex::bool(true),
            _ => match self.eq_fn(t) {
                Some(f) => self.call_ref(&f, vec![a, b], MTy::D(Ty::Bool)),
                None => Ex::bool(false),
            },
        }
    }

    fn derive_eq(&mut self, t: &Ty, f: FuncId) -> Body {
        let (mut b, ps) = self.body_for(f);
        let (x, y) = (ps[0].clone(), ps[1].clone());
        let fail = |b: &mut Body, c: Ex| {
            b.open_if(c.not());
            b.emit(Stmt::Ret(Some(Ex::bool(false))));
            b.close();
        };
        match t {
            Ty::Tuple(ts) => {
                for (i, et) in ts.iter().enumerate() {
                    let s = Sel::F(i as u32);
                    let e = self.eq_expr(et, self.fld(&x, s), self.fld(&y, s));
                    fail(&mut b, e);
                }
                b.emit(Stmt::Ret(Some(Ex::bool(true))));
            }
            Ty::Opt(et) => {
                let (sa, sb) = (self.fld(&x, Sel::F(0)), self.fld(&y, Sel::F(0)));
                fail(&mut b, Ex::bin(BOp::Eq, sa.clone(), sb));
                b.open_if(sa.not());
                b.emit(Stmt::Ret(Some(Ex::bool(true))));
                b.close();
                let e = self.eq_expr(et, self.fld(&x, Sel::F(1)), self.fld(&y, Sel::F(1)));
                b.emit(Stmt::Ret(Some(e)));
            }
            Ty::Res(et, _) => {
                let (oa, ob) = (self.fld(&x, Sel::F(0)), self.fld(&y, Sel::F(0)));
                fail(&mut b, Ex::bin(BOp::Eq, oa.clone(), ob));
                b.open_if(oa);
                let e = self.eq_expr(et, self.fld(&x, Sel::F(1)), self.fld(&y, Sel::F(1)));
                b.emit(Stmt::Ret(Some(e)));
                b.close();
                let ma = self.fld(&x, Sel::F(2)).rt_field(RtF::ErrMsg);
                let mb = self.fld(&y, Sel::F(2)).rt_field(RtF::ErrMsg);
                b.emit(Stmt::Ret(Some(Ex::rt("duck_str_eq", vec![ma, mb], MTy::D(Ty::Bool)))));
            }
            t if self.is_err_ty(t) => {
                let same = Ex::bin(BOp::Eq, x.clone(), y.clone());
                let msg = Ex::rt("duck_str_eq", vec![x.rt_field(RtF::ErrMsg), y.rt_field(RtF::ErrMsg)], MTy::D(Ty::Bool));
                b.emit(Stmt::Ret(Some(Ex::cond(same, Ex::bool(true), msg))));
            }
            Ty::Named(dd, args) if self.tp.defs.is_struct(*dd) => {
                let s = self.tp.defs.subst_of(*dd, args);
                for (i, fd) in self.tp.defs.fields(*dd).to_vec().into_iter().enumerate() {
                    let (fa, fb) = (self.field_get(t, i, &x), self.field_get(t, i, &y));
                    let e = self.eq_expr(&fd.ty.subst(&s), fa, fb);
                    fail(&mut b, e);
                }
                b.emit(Stmt::Ret(Some(Ex::bool(true))));
            }
            Ty::Named(..) => {
                let layout = self.info.enum_layout(t);
                fail(&mut b, Ex::bin(BOp::Eq, self.fld(&x, Sel::Tag), self.fld(&y, Sel::Tag)));
                for (vi, fs) in layout.iter().enumerate() {
                    if fs.is_empty() {
                        continue;
                    }
                    b.open_if(self.variant_tag(t, vi, &x));
                    for (fi, (ft, _)) in fs.iter().enumerate() {
                        let fa = self.variant_field(t, vi, fi, &x);
                        let fb = self.variant_field(t, vi, fi, &y);
                        let e = self.eq_expr(ft, fa, fb);
                        fail(&mut b, e);
                    }
                    b.close();
                }
                b.emit(Stmt::Ret(Some(Ex::bool(true))));
            }
            _ => b.emit(Stmt::Ret(Some(Ex::bool(false)))),
        }
        b
    }

    /// `int64_t f(T a, T b)` (negative, 0, positive), or None when the type has no order.
    pub fn cmp_fn(&mut self, t: &Ty) -> Option<FRef> {
        if let Some(f) = self.user_impl(Builtin::Ord, t) {
            return Some(f);
        }
        if !self.can(t, Builtin::Ord, &mut HashSet::new()) {
            return None;
        }
        let t2 = t.clone();
        Some(FRef::Fn(self.helper("cmp", t, vec![d(t), d(t)], MTy::D(Ty::Int), move |g, f| g.derive_cmp(&t2, f))))
    }

    /// An `int` expression comparing two values of type `t`.
    pub fn cmp_expr(&mut self, t: &Ty, a: Ex, b: Ex) -> Ex {
        let int = MTy::D(Ty::Int);
        match t {
            Ty::Int => Ex::rt("duck_int_cmp", vec![a, b], MTy::I32).cast(int),
            Ty::Float => Ex::rt("duck_float_cmp", vec![a, b], MTy::I32).cast(int),
            Ty::Char | Ty::Bool => {
                let gt = Ex::bin(BOp::Gt, a.clone(), b.clone()).cast(int.clone());
                let lt = Ex::bin(BOp::Lt, a, b).cast(int);
                Ex::bin(BOp::Sub, gt, lt)
            }
            Ty::Str => Ex::rt("duck_str_cmp", vec![a, b], MTy::I32).cast(int),
            _ => match self.cmp_fn(t) {
                Some(f) => self.call_ref(&f, vec![a, b], int),
                None => Ex::int(0),
            },
        }
    }

    fn derive_cmp(&mut self, t: &Ty, f: FuncId) -> Body {
        let (mut b, ps) = self.body_for(f);
        let (x, y) = (ps[0].clone(), ps[1].clone());
        let step = |b: &mut Body, e: Ex| {
            let r = b.decl(e);
            b.open_if(Ex::bin(BOp::Ne, r.clone(), Ex::int(0)));
            b.emit(Stmt::Ret(Some(r)));
            b.close();
        };
        match t {
            Ty::Int | Ty::Float | Ty::Char | Ty::Bool | Ty::Str => {
                let e = self.cmp_expr(t, x, y);
                b.emit(Stmt::Ret(Some(e)));
            }
            Ty::List(_) => b.emit(Stmt::Ret(Some(Ex::rt("duck_arr_cmp", vec![x, y], MTy::I32).cast(MTy::D(Ty::Int))))),
            Ty::Tuple(ts) => {
                for (i, et) in ts.iter().enumerate() {
                    let s = Sel::F(i as u32);
                    let e = self.cmp_expr(et, self.fld(&x, s), self.fld(&y, s));
                    step(&mut b, e);
                }
                b.emit(Stmt::Ret(Some(Ex::int(0))));
            }
            Ty::Opt(et) => {
                let (sa, sb) = (self.fld(&x, Sel::F(0)), self.fld(&y, Sel::F(0)));
                b.open_if(Ex::bin(BOp::Ne, sa.clone(), sb));
                b.emit(Stmt::Ret(Some(Ex::cond(sa.clone(), Ex::int(1), Ex::int(-1)))));
                b.close();
                b.open_if(sa.not());
                b.emit(Stmt::Ret(Some(Ex::int(0))));
                b.close();
                let e = self.cmp_expr(et, self.fld(&x, Sel::F(1)), self.fld(&y, Sel::F(1)));
                b.emit(Stmt::Ret(Some(e)));
            }
            Ty::Named(dd, args) if self.tp.defs.is_struct(*dd) => {
                let s = self.tp.defs.subst_of(*dd, args);
                for (i, fd) in self.tp.defs.fields(*dd).to_vec().into_iter().enumerate() {
                    let (fa, fb) = (self.field_get(t, i, &x), self.field_get(t, i, &y));
                    let e = self.cmp_expr(&fd.ty.subst(&s), fa, fb);
                    step(&mut b, e);
                }
                b.emit(Stmt::Ret(Some(Ex::int(0))));
            }
            Ty::Named(..) => {
                let layout = self.info.enum_layout(t);
                let (ta, tb) = (self.fld(&x, Sel::Tag), self.fld(&y, Sel::Tag));
                b.open_if(Ex::bin(BOp::Ne, ta.clone(), tb.clone()));
                b.emit(Stmt::Ret(Some(Ex::cond(Ex::bin(BOp::Lt, ta, tb), Ex::int(-1), Ex::int(1)))));
                b.close();
                for (vi, fs) in layout.iter().enumerate() {
                    if fs.is_empty() {
                        continue;
                    }
                    b.open_if(self.variant_tag(t, vi, &x));
                    for (fi, (ft, _)) in fs.iter().enumerate() {
                        let fa = self.variant_field(t, vi, fi, &x);
                        let fb = self.variant_field(t, vi, fi, &y);
                        let e = self.cmp_expr(ft, fa, fb);
                        step(&mut b, e);
                    }
                    b.close();
                }
                b.emit(Stmt::Ret(Some(Ex::int(0))));
            }
            _ => b.emit(Stmt::Ret(Some(Ex::int(0)))),
        }
        b
    }

    /// `uint64_t f(T)` for map keys, or None.
    pub fn hash_fn(&mut self, t: &Ty) -> Option<FRef> {
        match t {
            Ty::Str => return Some(FRef::Rt("duck_str_hash".into())),
            Ty::List(_) => return Some(FRef::Rt("duck_arr_hash".into())),
            Ty::Map(..) | Ty::Fn(..) | Ty::Task(_) | Ty::Any(_) => return None,
            _ => {}
        }
        if !self.can(t, Builtin::Eq, &mut HashSet::new()) || self.is_err_ty(t) {
            return None;
        }
        let t2 = t.clone();
        Some(FRef::Fn(self.helper("hash", t, vec![d(t)], MTy::U64, move |g, f| g.derive_hash(&t2, f))))
    }

    fn hash_expr(&mut self, t: &Ty, v: Ex) -> Ex {
        match t {
            Ty::Int => Ex::rt("duck_hash_int", vec![v], MTy::U64),
            Ty::Char | Ty::Bool => Ex::rt("duck_hash_int", vec![v.cast(MTy::D(Ty::Int))], MTy::U64),
            Ty::Float => Ex::rt("duck_hash_float", vec![v], MTy::U64),
            Ty::Never => Ex::int_as(0, MTy::U64),
            Ty::Tuple(ts) if ts.is_empty() => Ex::int_as(0, MTy::U64),
            _ => match self.hash_fn(t) {
                Some(f) => self.call_ref(&f, vec![v], MTy::U64),
                None => Ex::int_as(0, MTy::U64),
            },
        }
    }

    fn derive_hash(&mut self, t: &Ty, f: FuncId) -> Body {
        let (mut b, ps) = self.body_for(f);
        let v = ps[0].clone();
        let h = b.decl(Ex::int_as(7, MTy::U64));
        let comb = |b: &mut Body, e: Ex| {
            b.set(h.clone(), Ex::rt("duck_hash_combine", vec![h.clone(), e], MTy::U64));
        };
        match t {
            Ty::Int | Ty::Char | Ty::Bool | Ty::Float => {
                let e = self.hash_expr(t, v);
                b.set(h.clone(), e);
            }
            t if self.is_value(t) => b.set(h.clone(), Ex::rt("duck_value_hash", vec![v.addr()], MTy::U64)),
            Ty::Tuple(ts) => {
                for (i, et) in ts.iter().enumerate() {
                    let e = self.hash_expr(et, self.fld(&v, Sel::F(i as u32)));
                    comb(&mut b, e);
                }
            }
            Ty::Opt(et) | Ty::Res(et, _) => {
                b.open_if(self.fld(&v, Sel::F(0)));
                let e = self.hash_expr(et, self.fld(&v, Sel::F(1)));
                comb(&mut b, e);
                b.close();
            }
            Ty::Named(dd, args) if self.tp.defs.is_struct(*dd) => {
                let s = self.tp.defs.subst_of(*dd, args);
                for (i, fd) in self.tp.defs.fields(*dd).to_vec().into_iter().enumerate() {
                    let x = self.field_get(t, i, &v);
                    let e = self.hash_expr(&fd.ty.subst(&s), x);
                    comb(&mut b, e);
                }
            }
            Ty::Named(..) => {
                let layout = self.info.enum_layout(t);
                b.set(h.clone(), Ex::rt("duck_hash_int", vec![self.fld(&v, Sel::Tag).cast(MTy::D(Ty::Int))], MTy::U64));
                for (vi, fs) in layout.iter().enumerate() {
                    if fs.is_empty() {
                        continue;
                    }
                    b.open_if(self.variant_tag(t, vi, &v));
                    for (fi, (ft, _)) in fs.iter().enumerate() {
                        let x = self.variant_field(t, vi, fi, &v);
                        let e = self.hash_expr(ft, x);
                        comb(&mut b, e);
                    }
                    b.close();
                }
            }
            _ => {}
        }
        b.emit(Stmt::Ret(Some(h)));
        b
    }

    // ---- Data: to_value / from_value ----

    /// `DuckValue f(T)` (owned result).
    pub fn tov_fn(&mut self, t: &Ty) -> FRef {
        if let Some(f) = self.user_impl(Builtin::Data, t) {
            return f;
        }
        let t2 = t.clone();
        let vt = d(&self.value_ty());
        FRef::Fn(self.helper("tov", t, vec![d(t)], vt, move |g, f| g.derive_tov(&t2, f)))
    }

    fn tov_expr(&mut self, t: &Ty, v: Ex) -> Ex {
        let f = self.tov_fn(t);
        let vt = d(&self.value_ty());
        self.call_ref(&f, vec![v], vt)
    }

    /// Put an owned `Value` under `key` into the Value map `m` (then release it).
    fn map_put(&mut self, b: &mut Body, m: &Ex, key: &str, e: Ex) {
        let ev = b.decl(e);
        b.do_(Ex::rt("duck_value_map_put", vec![m.clone().addr(), Ex::cstr(key), ev.clone()], MTy::Void));
        b.do_(Ex::rt("duck_value_release", vec![ev], MTy::Void));
    }

    fn derive_tov(&mut self, t: &Ty, f: FuncId) -> Body {
        let (mut b, ps) = self.body_for(f);
        let v = ps[0].clone();
        let vty = self.value_ty();
        let vt = d(&vty);
        let ret = |b: &mut Body, e: Ex| b.emit(Stmt::Ret(Some(e)));
        let mty = Ty::Map(Box::new(Ty::Str), Box::new(vty.clone()));
        let lty = Ty::list(vty.clone());
        // wrap an owned container into a Value and release our reference
        let wrap = |b: &mut Body, ctor: &str, c: Ex| {
            let r = b.decl(Ex::rt(ctor, vec![c.clone()], vt.clone()));
            b.do_(Ex::rt("duck_release", vec![c], MTy::Void));
            b.emit(Stmt::Ret(Some(r)));
        };
        match t {
            Ty::Int => ret(&mut b, Ex::rt("duck_value_int", vec![v], vt.clone())),
            Ty::Float => ret(&mut b, Ex::rt("duck_value_float", vec![v], vt.clone())),
            Ty::Bool => ret(&mut b, Ex::rt("duck_value_bool", vec![v], vt.clone())),
            Ty::Str => ret(&mut b, Ex::rt("duck_value_str", vec![v], vt.clone())),
            Ty::Char => {
                let s = b.decl(Ex::rt("duck_str_from_char", vec![v], MTy::D(Ty::Str)));
                wrap(&mut b, "duck_value_str", s);
            }
            t if self.is_value(t) => {
                b.do_(Ex::rt("duck_value_retain", vec![v.clone()], MTy::Void));
                ret(&mut b, v);
            }
            Ty::List(x) => {
                let xs = b.decl(Ex::rt("duck_value_list_new", vec![], d(&lty)));
                let i = b.decl(Ex::int(0));
                b.open_loop(vec![Stmt::Set(i.clone(), Ex::bin(BOp::Add, i.clone(), Ex::int(1)))]);
                b.open_if(Ex::bin(BOp::Ge, i.clone(), Ex::rt("duck_arr_len", vec![v.clone()], MTy::D(Ty::Int))));
                b.emit(Stmt::Break);
                b.close();
                let el = Ex::rt("duck_arr_at", vec![v.clone(), i.clone(), Ex::null().cast(MTy::CStr)], MTy::void_ptr()).cast(MTy::ptr(d(x))).deref(d(x));
                let e = self.tov_expr(x, el);
                let ev = b.decl(e);
                b.do_(Ex::rt("duck_arr_push", vec![xs.clone().addr(), ev.clone().addr()], MTy::Void));
                b.do_(Ex::rt("duck_value_release", vec![ev], MTy::Void));
                b.emit(Stmt::Continue);
                b.close();
                wrap(&mut b, "duck_value_list", xs);
            }
            Ty::Map(_, x) => {
                let m = b.decl(Ex::rt("duck_value_map_new", vec![], d(&mty)));
                let it = b.decl(Ex::int(0));
                let kp = b.decl(Ex::null());
                let vp = b.decl(Ex::null());
                b.open_loop(vec![]);
                let next = Ex::rt("duck_map_next", vec![v.clone(), it.addr(), kp.clone().addr(), vp.clone().addr()], MTy::Bool);
                b.open_if(next.not());
                b.emit(Stmt::Break);
                b.close();
                let e = self.tov_expr(x, vp.cast(MTy::ptr(d(x))).deref(d(x)));
                let ev = b.decl(e);
                b.do_(Ex::rt("duck_map_set", vec![m.clone().addr(), kp, ev.clone().addr()], MTy::Void));
                b.do_(Ex::rt("duck_value_release", vec![ev], MTy::Void));
                b.close();
                wrap(&mut b, "duck_value_map", m);
            }
            Ty::Opt(x) => {
                b.open_if(self.fld(&v, Sel::F(0)).not());
                b.emit(Stmt::Ret(Some(Ex::rt("duck_value_null", vec![], vt.clone()))));
                b.close();
                let e = self.tov_expr(x, self.fld(&v, Sel::F(1)));
                ret(&mut b, e);
            }
            Ty::Named(dd, args) if self.tp.defs.is_struct(*dd) => {
                let s = self.tp.defs.subst_of(*dd, args);
                let m = b.decl(Ex::rt("duck_value_map_new", vec![], d(&mty)));
                for (i, fd) in self.tp.defs.fields(*dd).to_vec().into_iter().enumerate() {
                    let x = self.field_get(t, i, &v);
                    let e = self.tov_expr(&fd.ty.subst(&s), x);
                    self.map_put(&mut b, &m, &fd.name, e);
                }
                wrap(&mut b, "duck_value_map", m);
            }
            Ty::Named(dd, _) if self.tp.defs.is_enum(*dd) => {
                let vs = self.tp.defs.variants(*dd).to_vec();
                let layout = self.info.enum_layout(t);
                for (vi, var) in vs.iter().enumerate() {
                    b.open_if(self.variant_tag(t, vi, &v));
                    if var.fields.is_empty() {
                        let s = b.decl(Ex::rt("duck_str_lit", vec![Ex::cstr(&var.name)], MTy::D(Ty::Str)));
                        wrap(&mut b, "duck_value_str", s);
                        b.close();
                        continue;
                    }
                    let m = b.decl(Ex::rt("duck_value_map_new", vec![], d(&mty)));
                    let s = b.decl(Ex::rt("duck_str_lit", vec![Ex::cstr(&var.name)], MTy::D(Ty::Str)));
                    let tag = Ex::rt("duck_value_str", vec![s.clone()], vt.clone());
                    let tv = b.decl(tag);
                    b.do_(Ex::rt("duck_release", vec![s], MTy::Void));
                    b.do_(Ex::rt("duck_value_map_put", vec![m.clone().addr(), Ex::cstr("tag"), tv.clone()], MTy::Void));
                    b.do_(Ex::rt("duck_value_release", vec![tv], MTy::Void));
                    for (fi, (fname, _)) in var.fields.iter().enumerate() {
                        let key = fname.clone().unwrap_or_else(|| fi.to_string());
                        let x = self.variant_field(t, vi, fi, &v);
                        let e = self.tov_expr(&layout[vi][fi].0, x);
                        self.map_put(&mut b, &m, &key, e);
                    }
                    wrap(&mut b, "duck_value_map", m);
                    b.close();
                }
                b.emit(Stmt::Ret(Some(Ex::rt("duck_value_null", vec![], vt.clone()))));
            }
            _ => b.emit(Stmt::Ret(Some(Ex::rt("duck_value_null", vec![], vt.clone())))),
        }
        b
    }

    /// `T! f(Value)`: the derived `from_value` (owned result).
    pub fn fromv_fn(&mut self, t: &Ty) -> FRef {
        // a user `from_value` for the type (or a field/element type), like `tov_fn`'s `to_value`
        if !self.imprint_eval {
            match self.tp.from_value_impls.get(t) {
                Some(Target::Instance(i)) => return FRef::Fn(self.inst_fn(*i)),
                Some(Target::Extern { symbol, .. }) => return FRef::Rt(symbol.clone()),
                _ => {}
            }
        }
        let t2 = t.clone();
        let vt = d(&self.value_ty());
        let rt = d(&Ty::res(t.clone(), self.err_ty()));
        FRef::Fn(self.helper("fromv", t, vec![vt], rt, move |g, f| g.derive_fromv(&t2, f)))
    }

    fn derive_fromv(&mut self, t: &Ty, f: FuncId) -> Body {
        let (mut b, ps) = self.body_for(f);
        let v = ps[0].clone();
        let rty = Ty::res(t.clone(), self.err_ty());
        let r = d(&rty);
        let what = self.show_ty(t);
        let et = d(&self.err_ty());
        let vty = self.value_ty();
        let ok = |e: Ex| Ex::agg(r.clone(), vec![(Sel::F(0), Ex::new(K::Int(1), MTy::Bool)), (Sel::F(1), super::retype(e, &d(t)))]);
        let err = |e: Ex| Ex::agg(r.clone(), vec![(Sel::F(2), e)]);
        let tag = self.fld(&v, Sel::Tag);
        let is = |n: i64| Ex::bin(BOp::Eq, tag.clone(), Ex::int_as(n, MTy::I32));
        let mism = |want: &str| {
            let prefix = format!("from_value: expected {want} for `{what}`, got ");
            Ex::rt("duck__err_with_tag", vec![Ex::cstr(&prefix), tag.clone()], et.clone())
        };
        let msg = |s: &str| Ex::rt("duck_err_new_cstr", vec![Ex::cstr(s)], et.clone());
        let check = |b: &mut Body, cond: Ex, want: &str| {
            b.open_if(cond.not());
            b.emit(Stmt::Ret(Some(err(mism(want)))));
            b.close();
        };
        let pay = |vi: u32, ty: Ty| v.clone().field(Sel::V(vi, 0), d(&ty));
        let (vlist, vmap) = (Ty::list(vty.clone()), Ty::Map(Box::new(Ty::Str), Box::new(vty.clone())));
        let vfield = |vi: u32| if vi == 5 { vlist.clone() } else { vmap.clone() };
        match t {
            Ty::Int => {
                check(&mut b, is(2), "Int");
                b.emit(Stmt::Ret(Some(ok(pay(2, Ty::Int)))));
            }
            Ty::Float => {
                b.open_if(is(2));
                b.emit(Stmt::Ret(Some(ok(pay(2, Ty::Int).cast(MTy::D(Ty::Float))))));
                b.close();
                check(&mut b, is(3), "Float");
                b.emit(Stmt::Ret(Some(ok(pay(3, Ty::Float)))));
            }
            Ty::Bool => {
                check(&mut b, is(1), "Bool");
                b.emit(Stmt::Ret(Some(ok(pay(1, Ty::Bool)))));
            }
            Ty::Str => {
                check(&mut b, is(4), "Str");
                b.emit(Stmt::Ret(Some(ok(Ex::rt("duck_retain", vec![pay(4, Ty::Str)], MTy::D(Ty::Str))))));
            }
            Ty::Char => {
                let s = pay(4, Ty::Str);
                let one = Ex::and(vec![is(4), Ex::bin(BOp::Eq, Ex::rt("duck_str_len", vec![s.clone()], MTy::D(Ty::Int)), Ex::int(1))]);
                check(&mut b, one, "a one-char Str");
                b.emit(Stmt::Ret(Some(ok(Ex::rt("duck_str_char_at", vec![s, Ex::int(0), Ex::null().cast(MTy::CStr)], MTy::D(Ty::Char))))));
            }
            Ty::Tuple(ts) if ts.is_empty() => {
                check(&mut b, is(0), "Null");
                b.emit(Stmt::Ret(Some(ok(Ex::unit()))));
            }
            t if self.is_value(t) => {
                b.do_(Ex::rt("duck_value_retain", vec![v.clone()], MTy::Void));
                b.emit(Stmt::Ret(Some(ok(v.clone()))));
            }
            Ty::List(x) => {
                let conv = self.fromv_fn(x);
                let ops = self.ops(x);
                check(&mut b, is(5), "List");
                let list = pay(5, vfield(5));
                let out = b.decl(Ex::rt("duck_arr_new", vec![ops, Ex::rt("duck_arr_len", vec![list.clone()], MTy::D(Ty::Int))], d(t)));
                let i = b.decl(Ex::int(0));
                b.open_loop(vec![Stmt::Set(i.clone(), Ex::bin(BOp::Add, i.clone(), Ex::int(1)))]);
                b.open_if(Ex::bin(BOp::Ge, i.clone(), Ex::rt("duck_arr_len", vec![list.clone()], MTy::D(Ty::Int))));
                b.emit(Stmt::Break);
                b.close();
                let e = Ex::rt("duck_arr_at", vec![list.clone(), i.clone(), Ex::null().cast(MTy::CStr)], MTy::void_ptr()).cast(MTy::ptr(d(&vty))).deref(d(&vty));
                let xr = b.decl(self.call_ref(&conv, vec![e], d(&Ty::res((**x).clone(), self.err_ty()))));
                b.open_if(self.fld(&xr, Sel::F(0)).not());
                b.do_(Ex::rt("duck_release", vec![out.clone()], MTy::Void));
                b.emit(Stmt::Ret(Some(err(self.fld(&xr, Sel::F(2))))));
                b.close();
                let xv = self.fld(&xr, Sel::F(1));
                b.do_(Ex::rt("duck_arr_push", vec![out.clone().addr(), xv.clone().addr()], MTy::Void));
                if let Some(rel) = self.release(x, &xv) {
                    b.emit(rel);
                }
                b.emit(Stmt::Continue);
                b.close();
                b.emit(Stmt::Ret(Some(ok(out))));
            }
            Ty::Map(k, x) if **k == Ty::Str => {
                let conv = self.fromv_fn(x);
                let vops = self.ops(x);
                check(&mut b, is(6), "Map");
                let map = pay(6, vfield(6));
                let out = b.decl(Ex::rt("duck_map_new", vec![Ex::rt_global("duck_ops_str", MTy::Rt(Rt::ElemOps)), vops], d(t)));
                let it = b.decl(Ex::int(0));
                let kp = b.decl(Ex::null());
                let vp = b.decl(Ex::null());
                b.open_loop(vec![]);
                let next = Ex::rt("duck_map_next", vec![map, it.addr(), kp.clone().addr(), vp.clone().addr()], MTy::Bool);
                b.open_if(next.not());
                b.emit(Stmt::Break);
                b.close();
                let xr = b.decl(self.call_ref(&conv, vec![vp.cast(MTy::ptr(d(&vty))).deref(d(&vty))], d(&Ty::res((**x).clone(), self.err_ty()))));
                b.open_if(self.fld(&xr, Sel::F(0)).not());
                b.do_(Ex::rt("duck_release", vec![out.clone()], MTy::Void));
                b.emit(Stmt::Ret(Some(err(self.fld(&xr, Sel::F(2))))));
                b.close();
                let xv = self.fld(&xr, Sel::F(1));
                b.do_(Ex::rt("duck_map_set", vec![out.clone().addr(), kp, xv.clone().addr()], MTy::Void));
                if let Some(rel) = self.release(x, &xv) {
                    b.emit(rel);
                }
                b.close();
                b.emit(Stmt::Ret(Some(ok(out))));
            }
            Ty::Opt(x) => {
                let conv = self.fromv_fn(x);
                b.open_if(is(0));
                b.emit(Stmt::Ret(Some(ok(Ex::zero(d(t))))));
                b.close();
                let xr = b.decl(self.call_ref(&conv, vec![v.clone()], d(&Ty::res((**x).clone(), self.err_ty()))));
                b.open_if(self.fld(&xr, Sel::F(0)).not());
                b.emit(Stmt::Ret(Some(err(self.fld(&xr, Sel::F(2))))));
                b.close();
                let some = Ex::agg(d(t), vec![(Sel::F(0), Ex::new(K::Int(1), MTy::Bool)), (Sel::F(1), self.fld(&xr, Sel::F(1)))]);
                b.emit(Stmt::Ret(Some(ok(some))));
            }
            Ty::Named(dd, args) if self.tp.defs.is_struct(*dd) => {
                let s = self.tp.defs.subst_of(*dd, args);
                let fields = self.tp.defs.fields(*dd).to_vec();
                check(&mut b, is(6), "Map");
                let map = pay(6, vfield(6));
                let out = b.decl(Ex::zero(d(t)));
                let errv = b.decl(Ex::zero(et.clone()));
                let done = b.decl(Ex::i64(0));
                let mut rels = Vec::new();
                for (i, fd) in fields.iter().enumerate() {
                    let ft = fd.ty.subst(&s);
                    let (raw, boxed) = self.field_raw(t, i, &out);
                    let key = self.lit(&fd.name);
                    let conv = self.fromv_fn(&ft);
                    b.open_if(Ex::bin(BOp::Eq, errv.clone(), Ex::zero(et.clone())));
                    let fv = b.decl(Ex::rt("duck_map_find", vec![map.clone(), key.clone().addr()], MTy::void_ptr()).cast(MTy::ptr(d(&vty))));
                    b.open_if(Ex::bin(BOp::Eq, fv.clone(), Ex::zero(MTy::ptr(d(&vty)))));
                    if let Ty::Opt(_) = ft {
                        let z = self.field_put(t, i, Ex::zero(d(&ft)));
                        b.set(raw.clone(), z);
                    } else {
                        b.set(errv.clone(), msg(&format!("from_value: missing field `{}` of `{what}`", fd.name.replace('"', ""))));
                    }
                    b.else_();
                    let xr = b.decl(self.call_ref(&conv, vec![fv.deref(d(&vty))], d(&Ty::res(ft.clone(), self.err_ty()))));
                    b.open_if(self.fld(&xr, Sel::F(0)).not());
                    b.set(errv.clone(), Ex::rt("duck_err_wrap", vec![key, self.fld(&xr, Sel::F(2))], et.clone()));
                    b.do_(Ex::rt("duck_release", vec![self.fld(&xr, Sel::F(2))], MTy::Void));
                    b.else_();
                    let put = self.field_put(t, i, self.fld(&xr, Sel::F(1)));
                    b.set(raw.clone(), put);
                    b.close();
                    b.close();
                    b.open_if(Ex::bin(BOp::Eq, errv.clone(), Ex::zero(et.clone())));
                    b.set(done.clone(), Ex::i64(i as i64 + 1));
                    b.close();
                    b.close();
                    rels.push((i + 1, if boxed { Ty::Str } else { ft }, raw));
                }
                b.open_if(Ex::bin(BOp::Ne, errv.clone(), Ex::zero(et.clone())));
                for (i, ft, raw) in rels {
                    let raw = if matches!(raw.ty, MTy::Ptr(_)) { raw.cast(MTy::D(Ty::Str)) } else { raw };
                    if let Some(rel) = self.release(&ft, &raw) {
                        b.open_if(Ex::bin(BOp::Ge, done.clone(), Ex::i64(i as i64)));
                        b.emit(rel);
                        b.close();
                    }
                }
                b.emit(Stmt::Ret(Some(err(errv))));
                b.close();
                b.emit(Stmt::Ret(Some(ok(out))));
            }
            Ty::Named(dd, _) if self.tp.defs.is_enum(*dd) => {
                let vs = self.tp.defs.variants(*dd).to_vec();
                let layout = self.info.enum_layout(t);
                let st = MTy::D(Ty::Str);
                let tagv = b.decl(Ex::zero(st.clone()));
                b.open_if(is(4));
                b.set(tagv.clone(), pay(4, Ty::Str));
                b.else_();
                b.open_if(is(6));
                let tk = self.lit("tag");
                let tvp = b.decl(Ex::rt("duck_map_find", vec![pay(6, vfield(6)), tk.addr()], MTy::void_ptr()).cast(MTy::ptr(d(&vty))));
                let tvd = tvp.clone().deref(d(&vty));
                let tv_is_str = Ex::bin(BOp::Eq, tvd.clone().field(Sel::Tag, MTy::I32), Ex::int_as(4, MTy::I32));
                b.open_if(Ex::and(vec![Ex::bin(BOp::Ne, tvp.clone(), Ex::zero(MTy::ptr(d(&vty)))), tv_is_str]));
                b.set(tagv.clone(), tvd.field(Sel::V(4, 0), st.clone()));
                b.close();
                b.close();
                b.close();
                b.open_if(Ex::bin(BOp::Eq, tagv.clone(), Ex::zero(st.clone())));
                b.emit(Stmt::Ret(Some(err(mism("a Str or a Map with a \"tag\"")))));
                b.close();
                for (vi, var) in vs.iter().enumerate() {
                    b.open_if(Ex::rt("duck_str_eq_lit", vec![tagv.clone(), Ex::cstr(&var.name)], MTy::Bool));
                    if var.fields.is_empty() {
                        let e = self.variant_new(t, vi, vec![]);
                        b.emit(Stmt::Ret(Some(ok(e))));
                        b.close();
                        continue;
                    }
                    check(&mut b, is(6), "a Map");
                    let map = pay(6, vfield(6));
                    let mut names: Vec<(Ex, Ty)> = Vec::new();
                    for (fi, (fname, _)) in var.fields.iter().enumerate() {
                        let ft = layout[vi][fi].0.clone();
                        let key = self.lit(&fname.clone().unwrap_or_else(|| fi.to_string()));
                        let conv = self.fromv_fn(&ft);
                        let a = b.decl(Ex::zero(d(&ft)));
                        let fv = b.decl(Ex::rt("duck_map_find", vec![map.clone(), key.addr()], MTy::void_ptr()).cast(MTy::ptr(d(&vty))));
                        let cleanup = |g: &mut Gen, b: &mut Body| {
                            for (pa, pty) in names.iter() {
                                if let Some(rel) = g.release(pty, pa) {
                                    b.emit(rel);
                                }
                            }
                        };
                        b.open_if(Ex::bin(BOp::Eq, fv.clone(), Ex::zero(MTy::ptr(d(&vty)))));
                        cleanup(self, &mut b);
                        b.emit(Stmt::Ret(Some(err(msg(&format!("from_value: missing field of variant {}", var.name.replace('"', "")))))));
                        b.close();
                        let xr = b.decl(self.call_ref(&conv, vec![fv.deref(d(&vty))], d(&Ty::res(ft.clone(), self.err_ty()))));
                        b.open_if(self.fld(&xr, Sel::F(0)).not());
                        cleanup(self, &mut b);
                        b.emit(Stmt::Ret(Some(err(self.fld(&xr, Sel::F(2))))));
                        b.close();
                        b.set(a.clone(), self.fld(&xr, Sel::F(1)));
                        names.push((a, ft));
                    }
                    let args: Vec<Ex> = names.into_iter().map(|(a, _)| a).collect();
                    let e = self.variant_new(t, vi, args);
                    b.emit(Stmt::Ret(Some(ok(e))));
                    b.close();
                }
                let e = Ex::rt(
                    "duck__err_concat",
                    vec![Ex::cstr("from_value: unknown variant `"), tagv, Ex::cstr(&format!("` of `{what}`"))],
                    et.clone(),
                );
                b.emit(Stmt::Ret(Some(err(e))));
            }
            _ => {
                b.emit(Stmt::Ret(Some(err(msg(&format!("from_value: `{what}` doesn't convert from Value"))))));
            }
        }
        b
    }

    // ---- any S ----

    /// The vtable aggregate of shape `s`: one code pointer per method.
    pub fn vt_struct(&mut self, s: ShapeId) -> AggId {
        let key = Ty::Any(s);
        if let Some(&n) = self.memo.get(&("vts", key.clone())) {
            return n;
        }
        let n = self.tp.defs.shapes[s].methods.len().max(1);
        let a = self.agg(format!("DkVt{s}_{}", sanitize(&self.tp.defs.shapes[s].name)), vec![MTy::Code; n]);
        self.memo.insert(("vts", key), a);
        a
    }

    pub fn method_ty(&self, t: &Ty, s: ShapeId) -> Ty {
        self.info.method_ty(t, s)
    }

    // ---- the program ----

    /// Build `dk_init` (string literals, imprints, constants) and `dk_cleanup` (release the
    /// constants); returns them.
    pub fn init_and_cleanup(&mut self) -> (FuncId, FuncId) {
        let init = self.declare("dk_init".into(), Vec::new(), MTy::Void, Abi::Duck);
        let mut b = Body::new();
        for (s, g) in self.lit_order.clone() {
            let ge = self.global_ex(g);
            b.set(ge.clone(), Ex::rt("duck_str_from_bytes", vec![Ex::new(K::CStr(s.as_bytes().to_vec()), MTy::CStr), Ex::int(s.len() as i64)], MTy::D(Ty::Str)));
            b.do_(Ex::rt("duck_make_immortal", vec![ge], MTy::Void));
        }
        for f in self.imprint_inits.clone() {
            b.do_(self.call(f, vec![]));
        }
        for (getter, _) in self.const_order.clone() {
            b.do_(self.call(getter, vec![]));
        }
        // literals created by the imprints above are initialized too (new ones were appended)
        self.define(init, b);
        let cleanup = self.declare("dk_cleanup".into(), Vec::new(), MTy::Void, Abi::C);
        let mut b = Body::new();
        for (_, free) in self.const_order.clone().into_iter().rev() {
            b.do_(self.call(free, vec![]));
        }
        self.define(cleanup, b);
        (init, cleanup)
    }

    /// Is module `m` part of the root package (whose tests `duck test` runs)?
    pub fn in_root_pkg(&self, m: ModId) -> bool {
        let p = &self.tp.program;
        p.mods[m].pkg == p.mods[p.root].pkg
    }

    /// The source text of a span in module `m`.
    pub fn span_text(&self, m: ModId, span: crate::diag::Span) -> String {
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

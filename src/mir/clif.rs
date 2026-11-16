//! The Cranelift back end: MIR → machine code, in memory (`jit`) or as an object file
//! (`object`, linked by `build.rs` into an executable).
//!
//! # Representation
//! Every MIR type is either a *scalar* (one Cranelift value: i8 for bools and `()`, i32, i64,
//! f64, pointers) or an *aggregate* living in memory and handled through its address. Layouts
//! follow C's struct rules (they must match the runtime's `#[repr(C)]` types).
//!
//! A scalar variable whose address is never taken is an SSA variable; every other variable
//! lives in a stack slot.
//!
//! # Calling conventions
//! - Generated functions called only by generated code (`Abi::Duck`) take aggregates by pointer
//!   (the callee copies them on entry) and return them through a leading result pointer.
//! - Runtime functions, and generated functions the runtime calls (`Abi::C`), use the platform
//!   C ABI: an aggregate of at most 16 bytes travels in one or two registers (integer words, or
//!   on x86-64 a float register for an all-float eightbyte); a bigger result is returned
//!   through the struct-return pointer.

use std::cell::RefCell;
use std::collections::HashMap;

use cranelift_codegen::ir::condcodes::{FloatCC, IntCC};
use cranelift_codegen::ir::{self, AbiParam, ArgumentPurpose, Block, InstBuilder, MemFlagsData, Signature, StackSlotData, StackSlotKind, TrapCode, Type, Value, types};
use cranelift_codegen::isa::{CallConv, OwnedTargetIsa};
use cranelift_codegen::settings::{self, Configurable};
use cranelift_frontend::{FunctionBuilder, FunctionBuilderContext, Variable};
use cranelift_module::{DataDescription, DataId, FuncId as CFuncId, Linkage, Module};

use super::types::TyInfo;
use super::{Abi, AggDef, BOp, Callee, Ex, FRef, Func, K, LabelId, MTy, Program, Rt, RtF, Sel, Stmt, UOp, VarId};
use crate::types::Ty;

const PTR: Type = types::I64;

/// A target ISA for this machine. `opt`: optimize for speed; `pic`: position-independent code
/// (object files).
pub fn isa(opt: bool, pic: bool) -> Result<OwnedTargetIsa, String> {
    let mut flags = settings::builder();
    flags.set("opt_level", if opt { "speed" } else { "none" }).map_err(|e| e.to_string())?;
    flags.set("is_pic", if pic { "true" } else { "false" }).map_err(|e| e.to_string())?;
    flags.set("use_colocated_libcalls", "false").map_err(|e| e.to_string())?;
    flags.set("preserve_frame_pointers", "true").map_err(|e| e.to_string())?;
    let builder = cranelift_native::builder().map_err(|e| e.to_string())?;
    builder.finish(settings::Flags::new(flags)).map_err(|e| e.to_string())
}

// ---- layout ----------------------------------------------------------------------------

#[derive(Clone, Copy, Debug)]
struct Lay {
    size: u32,
    align: u32,
}

fn align_up(x: u32, a: u32) -> u32 {
    x.div_ceil(a) * a
}

/// A type's layout, its member offsets (struct-like) and per-variant field offsets within the
/// union (enums; the union starts at the first member offset).
type LayInfo = (Lay, Vec<u32>, Vec<Vec<u32>>);

/// Sizes, alignments and member offsets of MIR types.
pub struct Layouts<'p, 'a> {
    info: &'p TyInfo<'a>,
    aggs: &'p [AggDef],
    memo: RefCell<HashMap<MTy, LayInfo>>,
}

impl<'p, 'a> Layouts<'p, 'a> {
    pub fn new(info: &'p TyInfo<'a>, aggs: &'p [AggDef]) -> Self {
        Layouts { info, aggs, memo: RefCell::new(HashMap::new()) }
    }

    /// The Cranelift type of a scalar, or None for an aggregate (or `Void`).
    fn scalar(&self, t: &MTy) -> Option<Type> {
        Some(match t {
            MTy::Void => return None,
            MTy::Bool => types::I8,
            MTy::I32 | MTy::U32 => types::I32,
            MTy::I64 | MTy::U64 => types::I64,
            MTy::Ptr(_) | MTy::CStr | MTy::Code => PTR,
            MTy::D(t) => match t {
                Ty::Int => types::I64,
                Ty::Float => types::F64,
                Ty::Bool | Ty::Never => types::I8,
                Ty::Char => types::I32,
                t if t.is_unit() => types::I8,
                t if self.info.is_ptr(t) => PTR,
                _ => return None,
            },
            MTy::Agg(_) | MTy::Rt(_) => return None,
        })
    }

    fn is_agg(&self, t: &MTy) -> bool {
        !matches!(t, MTy::Void) && self.scalar(t).is_none()
    }

    /// Is the scalar signed (sign-extended when widened)?
    fn signed(t: &MTy) -> bool {
        matches!(t, MTy::I32 | MTy::I64 | MTy::D(Ty::Int))
    }

    /// The members of a struct-like aggregate (not enums).
    fn members(&self, t: &MTy) -> Vec<MTy> {
        let info = self.info;
        match t {
            MTy::Agg(a) => {
                let fs = self.aggs[*a as usize].fields.clone();
                if fs.is_empty() { vec![MTy::I32] } else { fs }
            }
            MTy::Rt(Rt::StrBuf) => vec![MTy::void_ptr(), MTy::I64, MTy::I64],
            MTy::Rt(Rt::Obj) => vec![MTy::I64, MTy::U32, MTy::Code, MTy::Code],
            MTy::Rt(Rt::ElemOps) => vec![MTy::U64, MTy::Code, MTy::Code, MTy::Code, MTy::Code, MTy::Code, MTy::Code, MTy::Code],
            MTy::D(d) => match d {
                Ty::Tuple(ts) => ts.iter().map(|x| MTy::D(x.clone())).collect(),
                Ty::Opt(x) => vec![MTy::Bool, MTy::D((**x).clone())],
                Ty::Res(x, _) => vec![MTy::Bool, MTy::D((**x).clone()), MTy::void_ptr()],
                Ty::Fn(..) => vec![MTy::Code, MTy::obj_ptr()],
                Ty::Any(_) => vec![MTy::obj_ptr(), MTy::void_ptr()],
                _ if info.is_struct(d) => {
                    let n = info.struct_layout(d).len();
                    if n == 0 {
                        vec![MTy::Bool]
                    } else {
                        (0..n).map(|i| info.member_ty(t, Sel::F(i as u32), self.aggs)).collect()
                    }
                }
                _ => panic!("clif: no members for {}", info.show_ty(d)),
            },
            _ => panic!("clif: no members for {t:?}"),
        }
    }

    fn is_enum_like(&self, t: &MTy) -> bool {
        matches!(t, MTy::D(d) if self.info.is_value(d) || matches!(d, Ty::Named(..)) && !self.info.is_struct(d) && !self.info.is_opaque(d))
    }

    /// Layout, member offsets (struct-like), and per-variant field offsets within the union
    /// (enums; the union starts at `offs[0]`).
    fn get(&self, t: &MTy) -> LayInfo {
        if let Some(x) = self.memo.borrow().get(t) {
            return x.clone();
        }
        let r = if let Some(s) = self.scalar(t) {
            let n = s.bytes();
            (Lay { size: n, align: n }, vec![], vec![])
        } else if self.is_enum_like(t) {
            let MTy::D(d) = t else { unreachable!() };
            let variants = self.info.enum_layout(d);
            let mut ualign = 1;
            let mut usize_ = 0;
            let mut voffs = Vec::new();
            for (vi, fs) in variants.iter().enumerate() {
                let ms: Vec<MTy> = (0..fs.len()).map(|fi| self.info.member_ty(t, Sel::V(vi as u32, fi as u32), self.aggs)).collect();
                let (l, offs) = self.struct_of(&ms);
                if !ms.is_empty() {
                    ualign = ualign.max(l.align);
                    usize_ = usize_.max(l.size);
                }
                voffs.push(offs);
            }
            if usize_ == 0 {
                (Lay { size: 4, align: 4 }, vec![4], voffs)
            } else {
                let uoff = align_up(4, ualign);
                let a = ualign.max(4);
                (Lay { size: align_up(uoff + usize_, a), align: a }, vec![uoff], voffs)
            }
        } else {
            let ms = self.members(t);
            let (l, offs) = self.struct_of(&ms);
            (l, offs, vec![])
        };
        self.memo.borrow_mut().insert(t.clone(), r.clone());
        r
    }

    fn struct_of(&self, ms: &[MTy]) -> (Lay, Vec<u32>) {
        let mut off = 0;
        let mut align = 1;
        let mut offs = Vec::new();
        for m in ms {
            let l = self.get(m).0;
            off = align_up(off, l.align);
            offs.push(off);
            off += l.size;
            align = align.max(l.align);
        }
        (Lay { size: align_up(off.max(if ms.is_empty() { 1 } else { 0 }), align), align }, offs)
    }

    fn lay(&self, t: &MTy) -> Lay {
        self.get(t).0
    }

    /// The offset of member `s` in a value of type `t`.
    fn offset(&self, t: &MTy, s: Sel) -> u32 {
        let (_, offs, voffs) = self.get(t);
        match s {
            Sel::Tag => 0,
            Sel::F(i) => offs[i as usize],
            Sel::V(vi, fi) => offs[0] + voffs[vi as usize][fi as usize],
        }
    }

    /// The scalar leaves of a type: (offset, type), unions included (for C ABI classification).
    fn leaves(&self, t: &MTy, base: u32, out: &mut Vec<(u32, Type)>) {
        if let Some(s) = self.scalar(t) {
            out.push((base, s));
            return;
        }
        if self.is_enum_like(t) {
            out.push((base, types::I32));
            let MTy::D(d) = t else { unreachable!() };
            for (vi, fs) in self.info.enum_layout(d).iter().enumerate() {
                for fi in 0..fs.len() {
                    let s = Sel::V(vi as u32, fi as u32);
                    let mt = self.info.member_ty(t, s, self.aggs);
                    self.leaves(&mt, base + self.offset(t, s), out);
                }
            }
            return;
        }
        for (i, m) in self.members(t).iter().enumerate() {
            self.leaves(m, base + self.offset(t, Sel::F(i as u32)), out);
        }
    }
}

// ---- the C ABI ------------------------------------------------------------------------

/// How a value crosses a C call boundary.
#[derive(Clone, Debug)]
enum CPass {
    None,
    /// One scalar.
    Scalar(Type),
    /// An aggregate of at most 16 bytes, as register-sized words.
    Words(Vec<Type>),
    /// A result returned through the struct-return pointer.
    Sret,
}

fn is_x86() -> bool {
    cfg!(target_arch = "x86_64")
}

impl Layouts<'_, '_> {
    fn c_pass(&self, t: &MTy) -> CPass {
        if let MTy::Void = t {
            return CPass::None;
        }
        if let Some(s) = self.scalar(t) {
            return CPass::Scalar(s);
        }
        let l = self.lay(t);
        if l.size > 16 {
            return CPass::Sret;
        }
        let n = l.size.div_ceil(8);
        let mut leaves = Vec::new();
        self.leaves(t, 0, &mut leaves);
        let words = (0..n)
            .map(|k| {
                let (lo, hi) = (k * 8, k * 8 + 8);
                let inside: Vec<_> = leaves.iter().filter(|(o, ty)| *o < hi && o + ty.bytes() > lo).collect();
                if is_x86() && !inside.is_empty() && inside.iter().all(|(_, ty)| *ty == types::F64) { types::F64 } else { types::I64 }
            })
            .collect();
        CPass::Words(words)
    }

    fn ext(t: &MTy, s: Type) -> AbiParam {
        let p = AbiParam::new(s);
        if s.bits() < 64 && !s.is_float() {
            if Self::signed(t) { p.sext() } else { p.uext() }
        } else {
            p
        }
    }

    /// A C signature: (signature, how each parameter passes, how the result returns).
    fn c_sig(&self, cc: CallConv, params: &[MTy], ret: &MTy) -> (Signature, Vec<CPass>, CPass) {
        let mut sig = Signature::new(cc);
        let rp = self.c_pass(ret);
        match &rp {
            CPass::None => {}
            CPass::Scalar(s) => sig.returns.push(Self::ext(ret, *s)),
            CPass::Words(ws) => sig.returns.extend(ws.iter().map(|w| AbiParam::new(*w))),
            CPass::Sret => sig.params.push(AbiParam::special(PTR, ArgumentPurpose::StructReturn)),
        }
        let mut pp = Vec::new();
        for p in params {
            let c = self.c_pass(p);
            match &c {
                CPass::Scalar(s) => sig.params.push(Self::ext(p, *s)),
                CPass::Words(ws) => sig.params.extend(ws.iter().map(|w| AbiParam::new(*w))),
                CPass::Sret => sig.params.push(AbiParam::new(PTR)),
                CPass::None => {}
            }
            pp.push(c);
        }
        (sig, pp, rp)
    }

    /// A generated function's own signature: aggregates by pointer, a leading result pointer.
    fn duck_sig(&self, cc: CallConv, params: &[MTy], ret: &MTy) -> Signature {
        let mut sig = Signature::new(cc);
        if self.is_agg(ret) {
            sig.params.push(AbiParam::new(PTR));
        } else if let Some(s) = self.scalar(ret) {
            sig.returns.push(AbiParam::new(s));
        }
        for p in params {
            sig.params.push(AbiParam::new(self.scalar(p).unwrap_or(PTR)));
        }
        sig
    }
}

// ---- compiling a program ----------------------------------------------------------------

struct Decls {
    funcs: Vec<CFuncId>,
    /// `duck run --live`: calls to these functions (by MIR id) load their target from the live
    /// table: `(table address, slot of each function)`.
    live: Option<(usize, HashMap<u32, usize>)>,
    rt_funcs: HashMap<String, (CFuncId, Signature)>,
    globals: Vec<DataId>,
    rt_data: HashMap<String, DataId>,
    cstrs: HashMap<Vec<u8>, DataId>,
}

/// Compile `prog` into module `m`; returns the entry function's id. `entry_name`: the symbol of
/// the entry point (exported).
pub fn compile<M: Module>(m: &mut M, prog: &Program, info: &TyInfo, entry_name: &str, dump: Option<&mut String>) -> Result<CFuncId, String> {
    compile_with(m, prog, info, entry_name, dump, None)
}

fn compile_with<M: Module>(
    m: &mut M,
    prog: &Program,
    info: &TyInfo,
    entry_name: &str,
    mut dump: Option<&mut String>,
    live: Option<(usize, HashMap<u32, usize>)>,
) -> Result<CFuncId, String> {
    let lay = Layouts::new(info, &prog.aggs);
    let cc = m.isa().default_call_conv();
    let mut d = Decls { funcs: Vec::new(), live, rt_funcs: HashMap::new(), globals: Vec::new(), rt_data: HashMap::new(), cstrs: HashMap::new() };
    let entry = prog.entry.ok_or("no entry point")?;
    for (i, f) in prog.funcs.iter().enumerate() {
        let sig = func_sig(&lay, cc, f);
        let (name, link) = if i as u32 == entry { (entry_name.to_string(), Linkage::Export) } else { (f.name.clone(), Linkage::Local) };
        let id = m.declare_function(&name, link, &sig).map_err(|e| format!("declaring {name}: {e}"))?;
        d.funcs.push(id);
    }
    for g in &prog.globals {
        let id = m.declare_data(&g.name, Linkage::Local, !g.constant, false).map_err(|e| e.to_string())?;
        d.globals.push(id);
    }
    // globals' contents (element-ops tables and vtables point at functions)
    for (gi, g) in prog.globals.iter().enumerate() {
        let l = lay.lay(&g.ty);
        let mut desc = DataDescription::new();
        desc.set_align(l.align.max(8) as u64);
        match &g.init {
            None => desc.define_zeroinit(l.size.max(1) as usize),
            Some(init) => {
                let mut bytes = vec![0u8; l.size as usize];
                let K::Agg(ms) = &init.k else { return Err(format!("global {}: unsupported initializer", g.name)) };
                for (s, v) in ms {
                    let off = lay.offset(&g.ty, *s) as usize;
                    match &v.k {
                        K::Int(n) => {
                            let sz = lay.lay(&v.ty).size as usize;
                            bytes[off..off + sz].copy_from_slice(&n.to_le_bytes()[..sz]);
                        }
                        K::SizeOf(t) => bytes[off..off + 8].copy_from_slice(&(lay.lay(t).size as u64).to_le_bytes()),
                        K::Zero => {}
                        K::FnAddr(FRef::Fn(f)) => {
                            let fr = m.declare_func_in_data(d.funcs[*f as usize], &mut desc);
                            desc.write_function_addr(off as u32, fr);
                        }
                        _ => return Err(format!("global {}: unsupported initializer member", g.name)),
                    }
                }
                desc.define(bytes.into_boxed_slice());
            }
        }
        m.define_data(d.globals[gi], &desc).map_err(|e| format!("defining {}: {e}", g.name))?;
    }
    let mut ctx = m.make_context();
    let mut fctx = FunctionBuilderContext::new();
    for (i, f) in prog.funcs.iter().enumerate() {
        ctx.func.signature = func_sig(&lay, cc, f);
        {
            let b = FunctionBuilder::new(&mut ctx.func, &mut fctx);
            let mut fc = FnCx { m, d: &mut d, lay: &lay, prog, f, b, cc, vars: Vec::new(), sret: None, loops: Vec::new(), labels: HashMap::new(), terminated: false };
            fc.body()?;
            let cfg = fc.m.isa().frontend_config();
            fc.b.finalize(cfg);
        }
        if let Some(out) = dump.as_deref_mut() {
            out.push_str(&format!("; {}\n{}\n", f.name, ctx.func.display()));
        }
        m.define_function(d.funcs[i], &mut ctx).map_err(|e| format!("compiling {}: {e:?}\n{}", f.name, ctx.func.display()))?;
        m.clear_context(&mut ctx);
    }
    Ok(d.funcs[entry as usize])
}

/// A function's signature by its calling convention.
fn func_sig(lay: &Layouts, cc: CallConv, f: &Func) -> Signature {
    let params: Vec<MTy> = f.params.iter().map(|&v| f.vars[v as usize].clone()).collect();
    match f.abi {
        Abi::Duck => lay.duck_sig(cc, &params, &f.ret),
        Abi::C => lay.c_sig(cc, &params, &f.ret).0,
    }
}

enum VarLoc {
    Reg(Variable),
    Mem(ir::StackSlot),
}

/// A value: a scalar, an aggregate's address, or nothing.
#[derive(Clone, Copy)]
enum V {
    S(Value),
    M(Value),
    None,
}

struct FnCx<'m, 'b, 'p, 'l, 'a, M: Module> {
    m: &'m mut M,
    d: &'m mut Decls,
    lay: &'l Layouts<'p, 'a>,
    prog: &'p Program,
    f: &'p Func,
    b: FunctionBuilder<'b>,
    cc: CallConv,
    vars: Vec<VarLoc>,
    sret: Option<Value>,
    /// (latch, exit) of each open loop.
    loops: Vec<(Block, Block)>,
    labels: HashMap<LabelId, Block>,
    terminated: bool,
}

fn mem() -> MemFlagsData {
    MemFlagsData::trusted()
}

/// Mark variables whose address is taken (they live in memory).
fn addressed(ss: &[Stmt], out: &mut Vec<bool>) {
    fn ex(e: &Ex, out: &mut Vec<bool>) {
        if let K::Addr(p) = &e.k {
            let mut b = &**p;
            while let K::Field(x, _) = &b.k {
                b = x;
            }
            if let K::Var(v) = b.k {
                out[v as usize] = true;
            }
        }
        match &e.k {
            K::Field(x, _) | K::Deref(x) | K::Addr(x) | K::Un(_, x) | K::Cast(x) | K::RtField(x, _) => ex(x, out),
            K::Bin(_, a, b) | K::Elem(a, b) => {
                ex(a, out);
                ex(b, out);
            }
            K::And(xs) => xs.iter().for_each(|x| ex(x, out)),
            K::Call(c, args) => {
                if let Callee::Indirect(x, _) = c {
                    ex(x, out);
                }
                args.iter().for_each(|x| ex(x, out));
            }
            K::Agg(ms) => ms.iter().for_each(|(_, x)| ex(x, out)),
            K::Cond(a, b, c) => {
                ex(a, out);
                ex(b, out);
                ex(c, out);
            }
            _ => {}
        }
    }
    for s in ss {
        match s {
            Stmt::Let(_, e) | Stmt::Do(e) | Stmt::Ret(Some(e)) => ex(e, out),
            Stmt::Set(p, e) => {
                ex(p, out);
                ex(e, out);
            }
            Stmt::If(c, a, b) => {
                ex(c, out);
                addressed(a, out);
                addressed(b, out);
            }
            Stmt::Loop(a, b) => {
                addressed(a, out);
                addressed(b, out);
            }
            _ => {}
        }
    }
}

impl<M: Module> FnCx<'_, '_, '_, '_, '_, M> {
    fn slot(&mut self, l: Lay) -> ir::StackSlot {
        let size = align_up(l.size.max(1), 8);
        let shift = l.align.max(8).trailing_zeros() as u8;
        self.b.create_sized_stack_slot(StackSlotData::new(StackSlotKind::ExplicitSlot, size, shift))
    }

    /// A fresh zeroed stack temporary for a value of type `t`; returns its address.
    fn temp(&mut self, t: &MTy) -> Value {
        let l = self.lay.lay(t);
        let s = self.slot(l);
        
        self.b.ins().stack_addr(PTR, s, 0)
    }

    fn zero_mem(&mut self, addr: Value, t: &MTy) {
        let l = self.lay.lay(t);
        let cfg = self.m.isa().frontend_config();
        let size = align_up(l.size.max(1), 1) as u64;
        self.b.emit_small_memset(cfg, addr, 0, size, l.align.min(8) as u8, mem());
    }

    fn copy(&mut self, dst: Value, src: Value, t: &MTy) {
        let l = self.lay.lay(t);
        let cfg = self.m.isa().frontend_config();
        let a = l.align.min(8) as u8;
        self.b.emit_small_memory_copy(cfg, dst, src, l.size as u64, a, a, false, mem());
    }

    fn ensure_open(&mut self) {
        if self.terminated {
            let blk = self.b.create_block();
            self.b.switch_to_block(blk);
            self.terminated = false;
        }
    }

    fn body(&mut self) -> Result<(), String> {
        let f = self.f;
        let entry = self.b.create_block();
        self.b.append_block_params_for_function_params(entry);
        self.b.switch_to_block(entry);
        let mut addr = vec![false; f.vars.len()];
        addressed(&f.body, &mut addr);
        for (v, t) in f.vars.iter().enumerate() {
            let loc = match self.lay.scalar(t) {
                Some(s) if !addr[v] => VarLoc::Reg(self.b.declare_var(s)),
                _ => {
                    let l = self.lay.lay(t);
                    VarLoc::Mem(self.slot(l))
                }
            };
            self.vars.push(loc);
        }
        // parameters
        let params: Vec<Value> = self.b.block_params(entry).to_vec();
        let mut k = 0;
        match f.abi {
            Abi::Duck => {
                if self.lay.is_agg(&f.ret) {
                    self.sret = Some(params[0]);
                    k = 1;
                }
                for &v in &f.params {
                    let t = f.vars[v as usize].clone();
                    let p = params[k];
                    k += 1;
                    if self.lay.is_agg(&t) {
                        let dst = self.var_addr(v);
                        self.copy(dst, p, &t);
                    } else {
                        self.def_var(v, p);
                    }
                }
            }
            Abi::C => {
                let ps: Vec<MTy> = f.params.iter().map(|&v| f.vars[v as usize].clone()).collect();
                let (_, pp, rp) = self.lay.c_sig(self.cc, &ps, &f.ret);
                if let CPass::Sret = rp {
                    self.sret = Some(params[0]);
                    k = 1;
                }
                for (i, &v) in f.params.iter().enumerate() {
                    match &pp[i] {
                        CPass::Scalar(_) => {
                            self.def_var(v, params[k]);
                            k += 1;
                        }
                        CPass::Words(ws) => {
                            let dst = self.var_addr(v);
                            for j in 0..ws.len() {
                                self.b.ins().store(mem(), params[k], dst, (j * 8) as i32);
                                k += 1;
                            }
                        }
                        CPass::Sret => {
                            let dst = self.var_addr(v);
                            self.copy(dst, params[k], &f.vars[v as usize].clone());
                            k += 1;
                        }
                        CPass::None => {}
                    }
                }
            }
        }
        self.stmts(&f.body)?;
        if !self.terminated {
            self.ret_default();
        }
        self.b.seal_all_blocks();
        Ok(())
    }

    fn ret_default(&mut self) {
        let f = self.f;
        match (f.abi, self.lay.scalar(&f.ret)) {
            (_, Some(s)) => {
                let z = self.zero_scalar(s);
                self.b.ins().return_(&[z]);
            }
            (Abi::C, None) if self.lay.is_agg(&f.ret) => {
                let ps: Vec<MTy> = f.params.iter().map(|&v| f.vars[v as usize].clone()).collect();
                match self.lay.c_sig(self.cc, &ps, &f.ret).2 {
                    CPass::Words(ws) => {
                        let vals: Vec<Value> = ws.iter().map(|w| self.zero_scalar(*w)).collect();
                        self.b.ins().return_(&vals);
                    }
                    _ => {
                        self.b.ins().return_(&[]);
                    }
                }
            }
            _ => {
                self.b.ins().return_(&[]);
            }
        }
        self.terminated = true;
    }

    fn zero_scalar(&mut self, s: Type) -> Value {
        if s == types::F64 { self.b.ins().f64const(0.0) } else { self.b.ins().iconst(s, 0) }
    }

    fn def_var(&mut self, v: VarId, x: Value) {
        match self.vars[v as usize] {
            VarLoc::Reg(var) => self.b.def_var(var, x),
            VarLoc::Mem(s) => {
                self.b.ins().stack_store(PTR, x, s, 0);
            }
        }
    }

    fn var_addr(&mut self, v: VarId) -> Value {
        match self.vars[v as usize] {
            VarLoc::Mem(s) => self.b.ins().stack_addr(PTR, s, 0),
            VarLoc::Reg(_) => panic!("clif: address of a register variable v{v}"),
        }
    }

    // ---- statements ----

    fn stmts(&mut self, ss: &[Stmt]) -> Result<(), String> {
        for s in ss {
            self.stmt(s)?;
        }
        Ok(())
    }

    fn label_block(&mut self, l: LabelId) -> Block {
        if let Some(&b) = self.labels.get(&l) {
            return b;
        }
        let b = self.b.create_block();
        self.labels.insert(l, b);
        b
    }

    fn stmt(&mut self, s: &Stmt) -> Result<(), String> {
        if let Stmt::Label(l) = s {
            let blk = self.label_block(*l);
            if !self.terminated {
                self.b.ins().jump(blk, &[]);
            }
            self.b.switch_to_block(blk);
            self.terminated = false;
            return Ok(());
        }
        self.ensure_open();
        match s {
            Stmt::Let(v, e) => {
                let t = self.f.vars[*v as usize].clone();
                let x = self.ex(e);
                self.store_var(*v, &t, x, &e.ty);
            }
            Stmt::Set(p, e) => {
                let x = self.ex(e);
                if let K::Var(v) = p.k {
                    let t = self.f.vars[v as usize].clone();
                    self.store_var(v, &t, x, &e.ty);
                } else {
                    let a = self.place(p);
                    self.store_at(a, &p.ty, x, &e.ty);
                }
            }
            Stmt::Do(e) => {
                let _ = self.ex(e);
            }
            Stmt::If(c, a, b) => {
                let cv = self.val(c);
                let (tb, eb, merge) = (self.b.create_block(), self.b.create_block(), self.b.create_block());
                self.b.ins().brif(cv, tb, &[], eb, &[]);
                self.b.switch_to_block(tb);
                self.terminated = false;
                self.stmts(a)?;
                if !self.terminated {
                    self.b.ins().jump(merge, &[]);
                }
                self.b.switch_to_block(eb);
                self.terminated = false;
                self.stmts(b)?;
                if !self.terminated {
                    self.b.ins().jump(merge, &[]);
                }
                self.b.switch_to_block(merge);
                self.terminated = false;
            }
            Stmt::Loop(body, latch) => {
                let (head, lat, exit) = (self.b.create_block(), self.b.create_block(), self.b.create_block());
                self.b.ins().jump(head, &[]);
                self.b.switch_to_block(head);
                self.terminated = false;
                self.loops.push((lat, exit));
                self.stmts(body)?;
                self.loops.pop();
                if !self.terminated {
                    self.b.ins().jump(lat, &[]);
                }
                self.b.switch_to_block(lat);
                self.terminated = false;
                self.stmts(latch)?;
                if !self.terminated {
                    self.b.ins().jump(head, &[]);
                }
                self.b.switch_to_block(exit);
                self.terminated = false;
            }
            Stmt::Break => {
                let (_, exit) = *self.loops.last().ok_or("break outside a loop")?;
                self.b.ins().jump(exit, &[]);
                self.terminated = true;
            }
            Stmt::Continue => {
                let (lat, _) = *self.loops.last().ok_or("continue outside a loop")?;
                self.b.ins().jump(lat, &[]);
                self.terminated = true;
            }
            Stmt::Label(_) => unreachable!(),
            Stmt::Goto(l) => {
                let blk = self.label_block(*l);
                self.b.ins().jump(blk, &[]);
                self.terminated = true;
            }
            Stmt::Ret(e) => {
                self.ret(e.as_ref());
                self.terminated = true;
            }
            Stmt::Unreachable => {
                self.b.ins().trap(TrapCode::unwrap_user(1));
                self.terminated = true;
            }
        }
        Ok(())
    }

    fn ret(&mut self, e: Option<&Ex>) {
        let f = self.f;
        let Some(e) = e else {
            self.ret_default();
            return;
        };
        let x = self.ex(e);
        if let Some(s) = self.lay.scalar(&f.ret) {
            let v = self.scalar_of(x, &e.ty, &f.ret, s);
            self.b.ins().return_(&[v]);
            return;
        }
        let V::M(src) = self.as_mem(x, &e.ty) else { panic!("clif: aggregate return") };
        match f.abi {
            Abi::Duck => {
                let dst = self.sret.unwrap();
                self.copy(dst, src, &f.ret);
                self.b.ins().return_(&[]);
            }
            Abi::C => {
                let ps: Vec<MTy> = f.params.iter().map(|&v| f.vars[v as usize].clone()).collect();
                match self.lay.c_sig(self.cc, &ps, &f.ret).2 {
                    CPass::Words(ws) => {
                        let vals: Vec<Value> = ws.iter().enumerate().map(|(k, w)| self.b.ins().load(*w, mem(), src, (k * 8) as i32)).collect();
                        self.b.ins().return_(&vals);
                    }
                    _ => {
                        let dst = self.sret.unwrap();
                        self.copy(dst, src, &f.ret);
                        self.b.ins().return_(&[]);
                    }
                }
            }
        }
    }

    // ---- storing ----

    fn store_var(&mut self, v: VarId, t: &MTy, x: V, from: &MTy) {
        match self.vars[v as usize] {
            VarLoc::Reg(var) => {
                let s = self.lay.scalar(t).unwrap();
                let val = self.scalar_of(x, from, t, s);
                self.b.def_var(var, val);
            }
            VarLoc::Mem(slot) => {
                let a = self.b.ins().stack_addr(PTR, slot, 0);
                self.store_at(a, t, x, from);
            }
        }
    }

    fn store_at(&mut self, a: Value, t: &MTy, x: V, from: &MTy) {
        if let Some(s) = self.lay.scalar(t) {
            let val = self.scalar_of(x, from, t, s);
            self.b.ins().store(mem(), val, a, 0);
        } else if let V::M(src) = self.as_mem(x, from) {
            self.copy(a, src, t);
        }
    }

    /// A scalar value converted from type `from` to `to` (Cranelift type `s`).
    fn scalar_of(&mut self, x: V, from: &MTy, to: &MTy, s: Type) -> Value {
        match x {
            V::S(v) => self.convert(v, from, to),
            V::M(a) => self.b.ins().load(s, mem(), a, 0),
            V::None => self.zero_scalar(s),
        }
    }

    /// An aggregate as an address (materializing a zero for `None`).
    fn as_mem(&mut self, x: V, t: &MTy) -> V {
        match x {
            V::M(_) => x,
            V::S(v) => {
                // a scalar used where an aggregate is expected (a one-word aggregate)
                let a = self.temp(t);
                self.zero_mem(a, t);
                self.b.ins().store(mem(), v, a, 0);
                V::M(a)
            }
            V::None => {
                let a = self.temp(t);
                self.zero_mem(a, t);
                V::M(a)
            }
        }
    }

    fn convert(&mut self, v: Value, from: &MTy, to: &MTy) -> Value {
        let ft = self.b.func.dfg.value_type(v);
        let Some(tt) = self.lay.scalar(to) else { return v };
        if ft == tt {
            return v;
        }
        match (ft.is_float(), tt.is_float()) {
            (false, false) => {
                if tt.bits() > ft.bits() {
                    if Layouts::signed(from) { self.b.ins().sextend(tt, v) } else { self.b.ins().uextend(tt, v) }
                } else {
                    self.b.ins().ireduce(tt, v)
                }
            }
            (false, true) => {
                if Layouts::signed(from) {
                    self.b.ins().fcvt_from_sint(tt, v)
                } else {
                    self.b.ins().fcvt_from_uint(tt, v)
                }
            }
            (true, false) => self.b.ins().fcvt_to_sint_sat(tt, v),
            (true, true) => v,
        }
    }

    // ---- expressions ----

    /// A scalar expression's value.
    fn val(&mut self, e: &Ex) -> Value {
        let x = self.ex(e);
        let s = self.lay.scalar(&e.ty).unwrap_or(types::I8);
        self.scalar_of(x, &e.ty, &e.ty, s)
    }

    /// An aggregate expression's address.
    fn mem_of(&mut self, e: &Ex) -> Value {
        if e.is_place() {
            return self.place(e);
        }
        let x = self.ex(e);
        match self.as_mem(x, &e.ty) {
            V::M(a) => a,
            _ => unreachable!(),
        }
    }

    /// The address of a place.
    fn place(&mut self, e: &Ex) -> Value {
        match &e.k {
            K::Var(v) => self.var_addr(*v),
            K::Global(g) => self.global_addr(*g),
            K::Deref(p) => self.val(p),
            K::Field(b, s) => {
                let base = self.mem_of(b);
                let off = self.lay.offset(&b.ty, *s);
                self.b.ins().iadd_imm_s(base, off as i64)
            }
            K::Elem(arr, i) => {
                let a = self.val(arr);
                let data = self.b.ins().load(PTR, mem(), a, 40);
                let iv = self.val(i);
                let size = self.lay.lay(&e.ty).size as i64;
                let off = self.b.ins().imul_imm_s(iv, size);
                self.b.ins().iadd(data, off)
            }
            K::RtField(p, f) => {
                let a = self.val(p);
                let off = match f {
                    RtF::ArrLen => 24,
                    RtF::ArrData => 40,
                    RtF::ErrMsg => 16,
                };
                self.b.ins().iadd_imm_s(a, off)
            }
            _ => self.mem_of_value(e),
        }
    }

    /// Materialize a non-place expression into a temporary; its address.
    fn mem_of_value(&mut self, e: &Ex) -> Value {
        let x = self.ex(e);
        let a = self.temp(&e.ty);
        self.store_at(a, &e.ty, x, &e.ty);
        a
    }

    /// Load a value of type `t` from address `a`: a scalar, or the address itself.
    fn load(&mut self, a: Value, t: &MTy) -> V {
        match self.lay.scalar(t) {
            Some(s) => V::S(self.b.ins().load(s, mem(), a, 0)),
            None => V::M(a),
        }
    }

    fn global_addr(&mut self, g: u32) -> Value {
        let id = self.d.globals[g as usize];
        let gv = self.m.declare_data_in_func(id, self.b.func);
        self.b.ins().symbol_value(PTR, gv)
    }

    fn rt_data_addr(&mut self, name: &str) -> Value {
        let id = match self.d.rt_data.get(name) {
            Some(&id) => id,
            None => {
                let id = self.m.declare_data(name, Linkage::Import, false, false).expect("declare runtime data");
                self.d.rt_data.insert(name.to_string(), id);
                id
            }
        };
        let gv = self.m.declare_data_in_func(id, self.b.func);
        self.b.ins().symbol_value(PTR, gv)
    }

    fn cstr_addr(&mut self, s: &[u8]) -> Value {
        let id = match self.d.cstrs.get(s) {
            Some(&id) => id,
            None => {
                let id = self.m.declare_anonymous_data(false, false).expect("declare string");
                let mut desc = DataDescription::new();
                let mut bytes = s.to_vec();
                bytes.push(0);
                desc.define(bytes.into_boxed_slice());
                self.m.define_data(id, &desc).expect("define string");
                self.d.cstrs.insert(s.to_vec(), id);
                id
            }
        };
        let gv = self.m.declare_data_in_func(id, self.b.func);
        self.b.ins().symbol_value(PTR, gv)
    }

    fn ex(&mut self, e: &Ex) -> V {
        match &e.k {
            K::Var(v) => match self.vars[*v as usize] {
                VarLoc::Reg(var) => V::S(self.b.use_var(var)),
                VarLoc::Mem(_) => {
                    let a = self.var_addr(*v);
                    self.load(a, &e.ty)
                }
            },
            K::Global(_) | K::Deref(_) | K::Field(..) | K::Elem(..) | K::RtField(..) if e.is_place() || !matches!(e.k, K::Field(..)) => {
                let a = self.place(e);
                self.load(a, &e.ty)
            }
            K::Field(b, s) => {
                // a member of an aggregate value
                let base = self.mem_of(b);
                let off = self.lay.offset(&b.ty, *s);
                let a = self.b.ins().iadd_imm_s(base, off as i64);
                self.load(a, &e.ty)
            }
            K::Int(n) => match self.lay.scalar(&e.ty) {
                Some(s) if s.is_float() => V::S(self.b.ins().f64const(*n as f64)),
                Some(s) => V::S(self.b.ins().iconst(s, if s.bits() < 64 { *n & ((1i64 << s.bits()) - 1) } else { *n })),
                None => V::None,
            },
            K::Float(x) => V::S(self.b.ins().f64const(*x)),
            K::CStr(s) => V::S(self.cstr_addr(s)),
            K::Zero => match self.lay.scalar(&e.ty) {
                Some(s) => V::S(self.zero_scalar(s)),
                None => V::None,
            },
            K::FnAddr(FRef::Fn(f)) => {
                let fr = self.m.declare_func_in_func(self.d.funcs[*f as usize], self.b.func);
                V::S(self.b.ins().func_addr(PTR, fr))
            }
            K::FnAddr(FRef::Rt(s)) => panic!("clif: address of runtime function {s}"),
            K::GlobalAddr(g) => V::S(self.global_addr(*g)),
            K::RtGlobalAddr(s) => V::S(self.rt_data_addr(s)),
            K::Addr(p) => V::S(self.place(p)),
            K::Un(op, a) => {
                let v = self.val(a);
                V::S(match op {
                    UOp::Not => self.b.ins().icmp_imm_s(IntCC::Equal, v, 0),
                    UOp::Neg => {
                        if self.b.func.dfg.value_type(v).is_float() {
                            self.b.ins().fneg(v)
                        } else {
                            self.b.ins().ineg(v)
                        }
                    }
                    UOp::BitNot => self.b.ins().bnot(v),
                })
            }
            K::Bin(op, a, b) => V::S(self.bin(*op, a, b)),
            K::And(xs) => {
                let done = self.b.create_block();
                self.b.append_block_param(done, types::I8);
                for x in xs {
                    let v = self.val(x);
                    let next = self.b.create_block();
                    let zero = self.b.ins().iconst(types::I8, 0);
                    self.b.ins().brif(v, next, &[], done, &[zero.into()]);
                    self.b.switch_to_block(next);
                }
                let one = self.b.ins().iconst(types::I8, 1);
                self.b.ins().jump(done, &[one.into()]);
                self.b.switch_to_block(done);
                V::S(self.b.block_params(done)[0])
            }
            K::Cast(x) => {
                let v = self.ex(x);
                match (v, self.lay.scalar(&e.ty)) {
                    (V::S(s), Some(_)) => V::S(self.convert(s, &x.ty, &e.ty)),
                    (V::M(a), Some(s)) => V::S(self.b.ins().load(s, mem(), a, 0)),
                    (v, _) => v,
                }
            }
            K::Call(c, args) => self.call(c, args, &e.ty),
            K::Agg(ms) => {
                let a = self.temp(&e.ty);
                self.zero_mem(a, &e.ty);
                for (s, v) in ms {
                    let off = self.lay.offset(&e.ty, *s);
                    let mt = self.lay.info.member_ty(&e.ty, *s, &self.prog.aggs);
                    let x = self.ex(v);
                    let p = self.b.ins().iadd_imm_s(a, off as i64);
                    self.store_at(p, &mt, x, &v.ty);
                }
                V::M(a)
            }
            K::Cond(c, a, b) => {
                let cv = self.val(c);
                let s = self.lay.scalar(&e.ty).expect("clif: aggregate conditional");
                let (tb, eb, done) = (self.b.create_block(), self.b.create_block(), self.b.create_block());
                self.b.append_block_param(done, s);
                self.b.ins().brif(cv, tb, &[], eb, &[]);
                self.b.switch_to_block(tb);
                let x = self.ex(a);
                let xv = self.scalar_of(x, &a.ty, &e.ty, s);
                self.b.ins().jump(done, &[xv.into()]);
                self.b.switch_to_block(eb);
                let y = self.ex(b);
                let yv = self.scalar_of(y, &b.ty, &e.ty, s);
                self.b.ins().jump(done, &[yv.into()]);
                self.b.switch_to_block(done);
                V::S(self.b.block_params(done)[0])
            }
            K::SizeOf(t) => {
                let n = self.lay.lay(t).size as i64;
                V::S(self.b.ins().iconst(types::I64, n))
            }
            _ => unreachable!(),
        }
    }

    fn bin(&mut self, op: BOp, a: &Ex, b: &Ex) -> Value {
        let x = self.val(a);
        let y0 = self.val(b);
        let y = self.convert(y0, &b.ty, &a.ty);
        let float = self.b.func.dfg.value_type(x).is_float();
        let unsigned = matches!(a.ty, MTy::U32 | MTy::U64 | MTy::D(Ty::Char)) || matches!(a.ty, MTy::Ptr(_) | MTy::CStr | MTy::Code);
        let ins = self.b.ins();
        if float {
            return match op {
                BOp::Add => ins.fadd(x, y),
                BOp::Sub => ins.fsub(x, y),
                BOp::Mul => ins.fmul(x, y),
                BOp::Div => ins.fdiv(x, y),
                BOp::Eq => ins.fcmp(FloatCC::Equal, x, y),
                BOp::Ne => ins.fcmp(FloatCC::NotEqual, x, y),
                BOp::Lt => ins.fcmp(FloatCC::LessThan, x, y),
                BOp::Le => ins.fcmp(FloatCC::LessThanOrEqual, x, y),
                BOp::Gt => ins.fcmp(FloatCC::GreaterThan, x, y),
                BOp::Ge => ins.fcmp(FloatCC::GreaterThanOrEqual, x, y),
                _ => panic!("clif: float {op:?}"),
            };
        }
        let cc = |s: IntCC, u: IntCC| if unsigned { u } else { s };
        match op {
            BOp::Add => ins.iadd(x, y),
            BOp::Sub => ins.isub(x, y),
            BOp::Mul => ins.imul(x, y),
            BOp::Div => ins.sdiv(x, y),
            BOp::BitAnd => ins.band(x, y),
            BOp::BitOr => ins.bor(x, y),
            BOp::BitXor => ins.bxor(x, y),
            BOp::Eq => ins.icmp(IntCC::Equal, x, y),
            BOp::Ne => ins.icmp(IntCC::NotEqual, x, y),
            BOp::Lt => ins.icmp(cc(IntCC::SignedLessThan, IntCC::UnsignedLessThan), x, y),
            BOp::Le => ins.icmp(cc(IntCC::SignedLessThanOrEqual, IntCC::UnsignedLessThanOrEqual), x, y),
            BOp::Gt => ins.icmp(cc(IntCC::SignedGreaterThan, IntCC::UnsignedGreaterThan), x, y),
            BOp::Ge => ins.icmp(cc(IntCC::SignedGreaterThanOrEqual, IntCC::UnsignedGreaterThanOrEqual), x, y),
        }
    }

    // ---- calls ----

    fn call(&mut self, c: &Callee, args: &[Ex], ret: &MTy) -> V {
        match c {
            Callee::Fn(f) if self.d.live.as_ref().is_some_and(|(_, s)| s.contains_key(f)) => {
                // live: the current body of `f` is in its table slot
                let (table, slot) = self.d.live.as_ref().map(|(t, s)| (*t, s[f])).unwrap();
                let func = &self.prog.funcs[*f as usize];
                let ps: Vec<MTy> = func.params.iter().map(|&v| func.vars[v as usize].clone()).collect();
                let sig = func_sig(self.lay, self.cc, func);
                let sr = self.b.import_signature(sig);
                let at = self.b.ins().iconst(PTR, (table + slot * 8) as i64);
                let code = self.b.ins().load(PTR, mem(), at, 0);
                let fret = func.ret.clone();
                match func.abi {
                    Abi::Duck => {
                        let (vals, out) = self.duck_args(&ps, args, &fret);
                        let inst = self.b.ins().call_indirect(sr, code, &vals);
                        self.duck_result(inst, out, &fret)
                    }
                    Abi::C => {
                        let (_, pp, rp) = self.lay.c_sig(self.cc, &ps, &fret);
                        let (vals, out) = self.c_args(&pp, &ps, args, &rp, &fret);
                        let inst = self.b.ins().call_indirect(sr, code, &vals);
                        self.c_result(inst, out, &rp, &fret)
                    }
                }
            }
            Callee::Fn(f) => {
                let func = &self.prog.funcs[*f as usize];
                let fr = self.m.declare_func_in_func(self.d.funcs[*f as usize], self.b.func);
                let ps: Vec<MTy> = func.params.iter().map(|&v| func.vars[v as usize].clone()).collect();
                match func.abi {
                    Abi::Duck => {
                        let (vals, out) = self.duck_args(&ps, args, &func.ret.clone());
                        let inst = self.b.ins().call(fr, &vals);
                        self.duck_result(inst, out, &func.ret.clone())
                    }
                    Abi::C => {
                        let fret = func.ret.clone();
                        let (_, pp, rp) = self.lay.c_sig(self.cc, &ps, &fret);
                        let (vals, out) = self.c_args(&pp, &ps, args, &rp, &fret);
                        let inst = self.b.ins().call(fr, &vals);
                        self.c_result(inst, out, &rp, &fret)
                    }
                }
            }
            Callee::Indirect(code, ps) => {
                let cv = self.val(code);
                let sig = self.lay.duck_sig(self.cc, ps, ret);
                let sr = self.b.import_signature(sig);
                let (vals, out) = self.duck_args(ps, args, ret);
                let inst = self.b.ins().call_indirect(sr, cv, &vals);
                self.duck_result(inst, out, ret)
            }
            Callee::Rt(sym) => {
                let ps: Vec<MTy> = args.iter().map(|a| a.ty.clone()).collect();
                let (sig, pp, rp) = self.lay.c_sig(self.cc, &ps, ret);
                let (vals, out) = self.c_args(&pp, &ps, args, &rp, ret);
                let inst = match self.d.rt_funcs.get(sym) {
                    Some((id, s)) if *s == sig => {
                        let fr = self.m.declare_func_in_func(*id, self.b.func);
                        self.b.ins().call(fr, &vals)
                    }
                    Some((id, _)) => {
                        // the same runtime function called with another (compatible) signature
                        let fr = self.m.declare_func_in_func(*id, self.b.func);
                        let addr = self.b.ins().func_addr(PTR, fr);
                        let sr = self.b.import_signature(sig);
                        self.b.ins().call_indirect(sr, addr, &vals)
                    }
                    None => {
                        let id = self.m.declare_function(sym, Linkage::Import, &sig).unwrap_or_else(|e| panic!("declaring {sym}: {e}"));
                        self.d.rt_funcs.insert(sym.clone(), (id, sig));
                        let fr = self.m.declare_func_in_func(id, self.b.func);
                        self.b.ins().call(fr, &vals)
                    }
                };
                self.c_result(inst, out, &rp, ret)
            }
        }
    }

    /// Arguments in the generated-function convention (and the result slot, if any).
    fn duck_args(&mut self, ps: &[MTy], args: &[Ex], ret: &MTy) -> (Vec<Value>, Option<Value>) {
        let mut vals = Vec::new();
        let out = if self.lay.is_agg(ret) {
            let a = self.temp(ret);
            vals.push(a);
            Some(a)
        } else {
            None
        };
        for (p, a) in ps.iter().zip(args) {
            if self.lay.is_agg(p) {
                let m = self.mem_of(a);
                vals.push(m);
            } else {
                let x = self.ex(a);
                let s = self.lay.scalar(p).unwrap();
                let v = self.scalar_of(x, &a.ty, p, s);
                vals.push(v);
            }
        }
        (vals, out)
    }

    fn duck_result(&mut self, inst: ir::Inst, out: Option<Value>, ret: &MTy) -> V {
        if let Some(a) = out {
            return V::M(a);
        }
        match self.b.inst_results(inst).first() {
            Some(&v) if !matches!(ret, MTy::Void) => V::S(v),
            _ => V::None,
        }
    }

    /// Arguments in the C convention (and the struct-return slot, if any).
    fn c_args(&mut self, pp: &[CPass], ps: &[MTy], args: &[Ex], rp: &CPass, ret: &MTy) -> (Vec<Value>, Option<Value>) {
        let mut vals = Vec::new();
        let out = if let CPass::Sret = rp {
            let a = self.temp(ret);
            vals.push(a);
            Some(a)
        } else {
            None
        };
        for ((c, p), a) in pp.iter().zip(ps).zip(args) {
            match c {
                CPass::Scalar(s) => {
                    let x = self.ex(a);
                    let v = self.scalar_of(x, &a.ty, p, *s);
                    vals.push(v);
                }
                CPass::Words(ws) => {
                    let m = self.mem_of(a);
                    for (k, w) in ws.iter().enumerate() {
                        let v = self.b.ins().load(*w, mem(), m, (k * 8) as i32);
                        vals.push(v);
                    }
                }
                CPass::Sret => {
                    // an aggregate argument bigger than 16 bytes: a pointer to a copy (AArch64)
                    let m = self.mem_of(a);
                    let t = self.temp(p);
                    self.copy(t, m, p);
                    vals.push(t);
                }
                CPass::None => {}
            }
        }
        (vals, out)
    }

    fn c_result(&mut self, inst: ir::Inst, out: Option<Value>, rp: &CPass, ret: &MTy) -> V {
        if let Some(a) = out {
            return V::M(a);
        }
        let rs = self.b.inst_results(inst).to_vec();
        match rp {
            CPass::None => V::None,
            CPass::Scalar(_) => V::S(rs[0]),
            CPass::Words(_) => {
                let a = self.temp(ret);
                for (k, v) in rs.iter().enumerate() {
                    self.b.ins().store(mem(), *v, a, (k * 8) as i32);
                }
                V::M(a)
            }
            CPass::Sret => unreachable!(),
        }
    }
}

// ---- drivers --------------------------------------------------------------------------

/// A program compiled in memory; keep it alive while its code runs.
pub struct Jit {
    module: Option<cranelift_jit::JITModule>,
    entry: *const u8,
}

/// Compile a program in memory (resolving runtime symbols to the runtime linked into this
/// process).
pub fn jit(prog: &Program, info: &TyInfo, opt: bool) -> Result<Jit, String> {
    let isa = isa(opt, false)?;
    let mut jb = cranelift_jit::JITBuilder::with_isa(isa, cranelift_module::default_libcall_names());
    for (name, addr) in crate::rt_symbols::rt_symbols() {
        jb.symbol(name, addr);
    }
    let mut module = cranelift_jit::JITModule::new(jb);
    let entry = compile(&mut module, prog, info, "dk_entry", None)?;
    module.finalize_definitions().map_err(|e| e.to_string())?;
    let entry = module.get_finalized_function(entry);
    Ok(Jit { module: Some(module), entry })
}

/// A program compiled for `duck run --live`: every call to a function in `slots` goes through
/// the live table at `table` (8-byte code pointers), so a later compile can replace bodies.
pub struct LiveJit {
    pub jit: Jit,
    /// (slot, code address) of each function in `slots`, to store into the table.
    pub entries: Vec<(usize, *const u8)>,
    /// The program's `dk_init` (literals, imprints, constants), to run before a reloaded module's
    /// code is used.
    pub init: *const u8,
}

pub fn jit_live(prog: &Program, info: &TyInfo, table: usize, slots: &HashMap<u32, usize>) -> Result<LiveJit, String> {
    let isa = isa(false, false)?;
    let mut jb = cranelift_jit::JITBuilder::with_isa(isa, cranelift_module::default_libcall_names());
    for (name, addr) in crate::rt_symbols::rt_symbols() {
        jb.symbol(name, addr);
    }
    let mut module = cranelift_jit::JITModule::new(jb);
    let entry = compile_with(&mut module, prog, info, "dk_entry", None, Some((table, slots.clone())))?;
    module.finalize_definitions().map_err(|e| e.to_string())?;
    let entry = module.get_finalized_function(entry);
    let ids: Vec<CFuncId> = module.declarations().get_functions().map(|(id, _)| id).collect();
    let by_name: HashMap<String, CFuncId> = ids.iter().map(|&id| (module.declarations().get_function_decl(id).name.clone().unwrap_or_default(), id)).collect();
    let addr = |m: &cranelift_jit::JITModule, name: &str| by_name.get(name).map(|&id| m.get_finalized_function(id));
    let mut entries = Vec::new();
    for (&f, &slot) in slots {
        if let Some(a) = addr(&module, &prog.funcs[f as usize].name) {
            entries.push((slot, a));
        }
    }
    let init = addr(&module, "dk_init").ok_or("no dk_init")?;
    Ok(LiveJit { jit: Jit { module: Some(module), entry }, entries, init })
}

impl Jit {
    /// Leave the compiled code in memory for good (a live reload: old frames may still run it).
    pub fn leak(mut self) {
        std::mem::forget(self.module.take());
    }

    /// Call the entry point with these arguments (`argv[0]` first); returns its exit code.
    pub fn run(&self, args: &[String]) -> i32 {
        let cs: Vec<std::ffi::CString> = args.iter().map(|a| std::ffi::CString::new(a.as_bytes()).unwrap_or_default()).collect();
        let mut argv: Vec<*const std::ffi::c_char> = cs.iter().map(|c| c.as_ptr()).collect();
        argv.push(std::ptr::null());
        let f: extern "C" fn(i32, *const *const std::ffi::c_char) -> i32 = unsafe { std::mem::transmute(self.entry) };
        f(cs.len() as i32, argv.as_ptr())
    }
}

/// Where a forked program's standard streams go.
#[derive(Default)]
pub struct Redirect<'p> {
    pub stdout: Option<&'p std::path::Path>,
    pub stderr: Option<&'p std::path::Path>,
    /// stdout and stderr both to this file, in order.
    pub merged: Option<&'p std::path::Path>,
    pub stdin_null: bool,
}

impl Jit {
    /// Run the entry point in a forked child process with its streams redirected; returns its
    /// exit code (None: killed by a signal).
    pub fn run_forked(&self, args: &[String], r: Redirect) -> Result<Option<i32>, String> {
        let pid = self.spawn(args, r, false)?;
        wait_child(pid, None).map(|w| w.unwrap_or(None))
    }

    /// Start the entry point in a forked child process (`own_group`: in a new process group);
    /// returns its pid.
    pub fn spawn(&self, args: &[String], r: Redirect, own_group: bool) -> Result<i32, String> {
        use std::os::fd::IntoRawFd;
        let open = |p: Option<&std::path::Path>| -> Result<Option<i32>, String> {
            match p {
                Some(p) => std::fs::File::create(p).map(|f| Some(f.into_raw_fd())).map_err(|e| format!("error: cannot create {}: {e}\n", p.display())),
                None => Ok(None),
            }
        };
        let (out, err, both) = (open(r.stdout)?, open(r.stderr)?, open(r.merged)?);
        let null = if r.stdin_null { std::fs::File::open("/dev/null").ok().map(|f| f.into_raw_fd()) } else { None };
        unsafe {
            libc::fflush(std::ptr::null_mut());
            let pid = libc::fork();
            if pid < 0 {
                return Err("error: fork failed\n".into());
            }
            if pid == 0 {
                if own_group {
                    libc::setpgid(0, 0);
                }
                if let Some(fd) = null {
                    libc::dup2(fd, 0);
                }
                if let Some(fd) = out.or(both) {
                    libc::dup2(fd, 1);
                }
                if let Some(fd) = err.or(both) {
                    libc::dup2(fd, 2);
                }
                let code = self.run(args);
                libc::fflush(std::ptr::null_mut());
                libc::_exit(code);
            }
            if own_group {
                libc::setpgid(pid, pid);
            }
            for fd in [out, err, both, null].into_iter().flatten() {
                libc::close(fd);
            }
            Ok(pid)
        }
    }
}

/// Wait for a child process: Ok(Some(exit code, or None if killed by a signal)), or Ok(None)
/// when `limit` passed first (the child is then killed with its process group).
pub fn wait_child(pid: i32, limit: Option<std::time::Duration>) -> Result<Option<Option<i32>>, String> {
    let start = std::time::Instant::now();
    loop {
        let mut status = 0;
        let flags = if limit.is_some() { libc::WNOHANG } else { 0 };
        let r = unsafe { libc::waitpid(pid, &mut status, flags) };
        if r == pid {
            return Ok(Some(if libc::WIFEXITED(status) { Some(libc::WEXITSTATUS(status)) } else { None }));
        }
        if r < 0 {
            if std::io::Error::last_os_error().raw_os_error() == Some(libc::EINTR) {
                continue;
            }
            return Err("error: waitpid failed\n".into());
        }
        if limit.is_some_and(|l| start.elapsed() > l) {
            unsafe {
                libc::kill(-pid, libc::SIGKILL);
                libc::kill(pid, libc::SIGKILL);
                libc::waitpid(pid, &mut status, 0);
            }
            return Ok(None);
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
}

impl Drop for Jit {
    fn drop(&mut self) {
        if let Some(m) = self.module.take() {
            // SAFETY: nothing from this module runs any more (forked children own their copies)
            unsafe { m.free_memory() };
        }
    }
}

/// Compile a program to an object file whose `main` is the entry point.
pub fn object(prog: &Program, info: &TyInfo, opt: bool) -> Result<Vec<u8>, String> {
    let isa = isa(opt, true)?;
    let ob = cranelift_object::ObjectBuilder::new(isa, "duck", cranelift_module::default_libcall_names()).map_err(|e| e.to_string())?;
    let mut module = cranelift_object::ObjectModule::new(ob);
    compile(&mut module, prog, info, "main", None)?;
    module.finish().emit().map_err(|e| e.to_string())
}

/// The Cranelift IR of every function, as text (`duck ir --clif`).
pub fn ir_text(prog: &Program, info: &TyInfo) -> Result<String, String> {
    let isa = isa(false, true)?;
    let ob = cranelift_object::ObjectBuilder::new(isa, "duck", cranelift_module::default_libcall_names()).map_err(|e| e.to_string())?;
    let mut module = cranelift_object::ObjectModule::new(ob);
    let mut out = String::new();
    compile(&mut module, prog, info, "main", Some(&mut out))?;
    Ok(out)
}

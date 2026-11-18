//! MIR → LLVM IR.
//!
//! # Representation
//! Every MIR variable is an `alloca` in the function's entry block (LLVM's SROA/mem2reg turn
//! scalars back into registers), except aggregate parameters that the function never writes:
//! those are used in place through the incoming pointer. Aggregates are untyped memory: an
//! aggregate is `[size x i8]`, members are reached with byte-offset GEPs (`Layouts::offset`), and
//! copies are `llvm.memcpy` with a constant size. LLVM never sees a struct type for an Auk value,
//! so the C layout is decided only in `layout.rs`.
//!
//! # Calling conventions
//! - `Abi::Auk` (called only by generated code): aggregates by pointer, an aggregate result
//!   through a leading `noalias` result pointer. An aggregate parameter the callee never writes
//!   or takes the address of is marked `noalias readonly` and read in place; the caller then
//!   passes a pointer to memory nothing else can reach during the call (an unaddressed local or a
//!   fresh temporary). A written one is copied on entry.
//! - `Abi::C` and runtime calls: the platform C ABI as classified by `Layouts::c_pass`.

use std::collections::HashMap;
use std::ffi::CString;

#[path = "intrin.rs"]
mod intrin;

use llvm_sys::core::*;
use llvm_sys::prelude::*;
use llvm_sys::{LLVMIntPredicate, LLVMLinkage, LLVMRealPredicate, LLVMTypeKind, LLVMUnnamedAddr};

use super::debug::Debug;
use super::super::layout::{CPass, Layouts, Sc, align_up};
use super::super::types::TyInfo;
use super::super::{Abi, BOp, Callee, Ex, FRef, Func, K, LabelId, MTy, Program, RtF, Stmt, UOp, VarId};
use crate::types::Ty;

/// Runtime functions that never return (marked `noreturn cold`).
const NORETURN: &[&str] = &[
    "auk_assert_fail",
    "auk_ensures_fail",
    "auk_hole",
    "auk_panic_div_zero",
    "auk_panic_overflow",
    "auk_panic_str",
    "auk_proc_exit",
    "auk_requires_fail",
    "auk_unwrap_err",
    "auk_unwrap_none",
];

fn c(s: &str) -> CString {
    CString::new(s).unwrap()
}

const NONAME: *const libc::c_char = c"".as_ptr();

/// What to export (external linkage) besides nothing: everything else is internal.
pub struct Exports {
    /// The entry point's symbol (`main` for executables, `dk_entry` in memory).
    pub entry: String,
    /// Also export these functions by MIR name (JIT lookups: `dk_init`).
    pub names: Vec<String>,
    /// Export every function (`auk run --live` looks them all up by name).
    pub all: bool,
}

/// A function type and the attributes its declaration and every call carry.
#[derive(Clone)]
struct Sig {
    ty: LLVMTypeRef,
    /// (attribute index, attribute): 0 = result, i + 1 = parameter i.
    attrs: Vec<(u32, LLVMAttributeRef)>,
}

/// A value: a scalar, an aggregate's address, or nothing.
#[derive(Clone, Copy)]
enum V {
    S(LLVMValueRef),
    M(LLVMValueRef),
    None,
}

pub struct Gen<'p, 'a> {
    cx: LLVMContextRef,
    pub m: LLVMModuleRef,
    b: LLVMBuilderRef,
    /// A second builder for entry-block allocas.
    ab: LLVMBuilderRef,
    lay: Layouts<'p, 'a>,
    prog: &'p Program,
    funcs: Vec<(LLVMValueRef, Sig)>,
    globals: Vec<LLVMValueRef>,
    rt_funcs: HashMap<String, LLVMValueRef>,
    rt_data: HashMap<String, LLVMValueRef>,
    cstrs: HashMap<Vec<u8>, LLVMValueRef>,
    /// `auk run --live`: calls to these functions load their target from the live table.
    live: Option<(usize, HashMap<u32, usize>)>,
    /// Which aggregate parameters each Auk function reads in place (never written).
    inplace: Vec<Vec<bool>>,
    /// Compile the hot runtime calls inline (`intrin.rs`; every level but O0).
    pub inline_rt: bool,
    /// The element size of the `auk_arr_at` call being compiled, when its caller knows it.
    elem_hint: Option<u32>,
    /// Debug info (`auk build -g`), and the current function's subprogram.
    debug: Option<Debug>,
    sp: Option<LLVMMetadataRef>,
    // per function
    f: Option<&'p Func>,
    fv: LLVMValueRef,
    vars: Vec<LLVMValueRef>,
    /// Variables whose address is taken (their memory must be private to them).
    addressed: Vec<bool>,
    sret: Option<LLVMValueRef>,
    loops: Vec<(LLVMBasicBlockRef, LLVMBasicBlockRef)>,
    labels: HashMap<LabelId, LLVMBasicBlockRef>,
    terminated: bool,
    // types
    t_i1: LLVMTypeRef,
    t_i8: LLVMTypeRef,
    t_i32: LLVMTypeRef,
    t_i64: LLVMTypeRef,
    t_f64: LLVMTypeRef,
    t_i16: LLVMTypeRef,
    t_f32: LLVMTypeRef,
    t_ptr: LLVMTypeRef,
    t_void: LLVMTypeRef,
}

fn attr_kind(name: &str) -> u32 {
    unsafe { LLVMGetEnumAttributeKindForName(name.as_ptr().cast(), name.len()) }
}

/// Variables written in `ss`: assigned after their declaration, or whose address is taken
/// (`addr`). Parameters are "declared" on entry, so any `Set` of one counts.
fn writes(ss: &[Stmt], set: &mut Vec<bool>, addr: &mut Vec<bool>) {
    fn ex(e: &Ex, addr: &mut Vec<bool>) {
        if let K::Addr(p) = &e.k {
            let mut b = &**p;
            while let K::Field(x, _) = &b.k {
                b = x;
            }
            if let K::Var(v) = b.k {
                addr[v as usize] = true;
            }
        }
        match &e.k {
            K::Field(x, _) | K::Deref(x) | K::Addr(x) | K::Un(_, x) | K::Cast(x) | K::RtField(x, _) => ex(x, addr),
            K::Bin(_, a, b) | K::Elem(a, b) => {
                ex(a, addr);
                ex(b, addr);
            }
            K::And(xs) => xs.iter().for_each(|x| ex(x, addr)),
            K::Call(c, args) => {
                if let Callee::Indirect(x, _) | Callee::CPtr(x) = c {
                    ex(x, addr);
                }
                args.iter().for_each(|x| ex(x, addr));
            }
            K::Agg(ms) => ms.iter().for_each(|(_, x)| ex(x, addr)),
            K::Cond(a, b, c) => {
                ex(a, addr);
                ex(b, addr);
                ex(c, addr);
            }
            _ => {}
        }
    }
    for s in ss {
        match s {
            Stmt::Let(_, e) | Stmt::Do(e) | Stmt::Ret(Some(e)) => ex(e, addr),
            Stmt::Set(p, e) => {
                let mut b = p;
                while let K::Field(x, _) = &b.k {
                    b = x;
                }
                if let K::Var(v) = b.k {
                    set[v as usize] = true;
                }
                ex(p, addr);
                ex(e, addr);
            }
            Stmt::If(c, a, b) => {
                ex(c, addr);
                writes(a, set, addr);
                writes(b, set, addr);
            }
            Stmt::Loop(a, b) => {
                writes(a, set, addr);
                writes(b, set, addr);
            }
            _ => {}
        }
    }
}

impl<'p, 'a> Gen<'p, 'a> {
    /// A generator for `prog` writing into a new module `name` in context `cx`.
    pub fn new(cx: LLVMContextRef, name: &str, prog: &'p Program, info: &'p TyInfo<'a>, live: Option<(usize, HashMap<u32, usize>)>) -> Self {
        unsafe {
            let m = LLVMModuleCreateWithNameInContext(c(name).as_ptr(), cx);
            Gen {
                cx,
                m,
                b: LLVMCreateBuilderInContext(cx),
                ab: LLVMCreateBuilderInContext(cx),
                lay: Layouts::new(info, &prog.aggs),
                prog,
                funcs: Vec::new(),
                globals: Vec::new(),
                rt_funcs: HashMap::new(),
                rt_data: HashMap::new(),
                cstrs: HashMap::new(),
                live,
                inplace: Vec::new(),
                inline_rt: false,
                elem_hint: None,
                debug: Debug::new(cx, m, prog),
                sp: None,
                f: None,
                fv: std::ptr::null_mut(),
                vars: Vec::new(),
                addressed: Vec::new(),
                sret: None,
                loops: Vec::new(),
                labels: HashMap::new(),
                terminated: false,
                t_i1: LLVMInt1TypeInContext(cx),
                t_i8: LLVMInt8TypeInContext(cx),
                t_i32: LLVMInt32TypeInContext(cx),
                t_i64: LLVMInt64TypeInContext(cx),
                t_f64: LLVMDoubleTypeInContext(cx),
                t_i16: LLVMInt16TypeInContext(cx),
                t_f32: LLVMFloatTypeInContext(cx),
                t_ptr: LLVMPointerTypeInContext(cx, 0),
                t_void: LLVMVoidTypeInContext(cx),
            }
        }
    }

    // ---- types and signatures ----

    fn lt(&self, s: Sc) -> LLVMTypeRef {
        match s {
            Sc::I8 => self.t_i8,
            Sc::I16 => self.t_i16,
            Sc::F32 => self.t_f32,
            Sc::I32 => self.t_i32,
            Sc::I64 => self.t_i64,
            Sc::F64 => self.t_f64,
            Sc::Ptr => self.t_ptr,
        }
    }

    fn scalar(&self, t: &MTy) -> Option<LLVMTypeRef> {
        self.lay.scalar(t).map(|s| self.lt(s))
    }

    fn bytes_ty(&self, n: u32) -> LLVMTypeRef {
        unsafe { LLVMArrayType2(self.t_i8, n as u64) }
    }

    fn enum_attr(&self, name: &str) -> LLVMAttributeRef {
        unsafe { LLVMCreateEnumAttribute(self.cx, attr_kind(name), 0) }
    }

    fn ext_attr(&self, t: &MTy, s: Sc) -> Option<LLVMAttributeRef> {
        (s.bits() < 64 && !s.is_float()).then(|| self.enum_attr(if Layouts::signed(t) { "signext" } else { "zeroext" }))
    }

    /// The LLVM type of a C result passed as words: one word, or a literal struct of them.
    fn words_ty(&self, ws: &[Sc]) -> LLVMTypeRef {
        if ws.len() == 1 {
            return self.lt(ws[0]);
        }
        let mut ts: Vec<LLVMTypeRef> = ws.iter().map(|w| self.lt(*w)).collect();
        unsafe { LLVMStructTypeInContext(self.cx, ts.as_mut_ptr(), ts.len() as u32, 0) }
    }

    /// A C signature: (signature, how each parameter passes, how the result returns).
    fn c_sig(&self, params: &[MTy], ret: &MTy) -> (Sig, Vec<CPass>, CPass) {
        let (pp, rp) = self.lay.c_sig(params, ret);
        let mut ps = Vec::new();
        let mut attrs = Vec::new();
        let rt = match &rp {
            CPass::None => self.t_void,
            CPass::Scalar(s) => {
                if let Some(a) = self.ext_attr(ret, *s) {
                    attrs.push((0, a));
                }
                self.lt(*s)
            }
            CPass::Words(ws) => self.words_ty(ws),
            CPass::Sret => {
                let size = self.lay.lay(ret).size;
                let a = unsafe { LLVMCreateTypeAttribute(self.cx, attr_kind("sret"), self.bytes_ty(size)) };
                attrs.push((1, a));
                ps.push(self.t_ptr);
                self.t_void
            }
        };
        for (p, c) in params.iter().zip(&pp) {
            match c {
                CPass::Scalar(s) => {
                    if let Some(a) = self.ext_attr(p, *s) {
                        attrs.push((ps.len() as u32 + 1, a));
                    }
                    ps.push(self.lt(*s));
                }
                CPass::Words(ws) => ps.extend(ws.iter().map(|w| self.lt(*w))),
                CPass::Sret => ps.push(self.t_ptr),
                CPass::None => {}
            }
        }
        let ty = unsafe { LLVMFunctionType(rt, ps.as_mut_ptr(), ps.len() as u32, 0) };
        (Sig { ty, attrs }, pp, rp)
    }

    /// A generated function's own signature: aggregates by pointer, a leading result pointer.
    /// `inplace`: which parameters are read in place (`noalias readonly`), if known.
    fn auk_sig(&self, params: &[MTy], ret: &MTy, inplace: Option<&[bool]>) -> Sig {
        let mut ps = Vec::new();
        let mut attrs = Vec::new();
        let rt = if self.lay.is_agg(ret) {
            ps.push(self.t_ptr);
            attrs.push((1, self.enum_attr("noalias")));
            self.t_void
        } else {
            self.scalar(ret).unwrap_or(self.t_void)
        };
        for (i, p) in params.iter().enumerate() {
            if inplace.is_some_and(|ip| ip[i]) {
                let k = ps.len() as u32 + 1;
                attrs.push((k, self.enum_attr("noalias")));
                attrs.push((k, self.enum_attr("readonly")));
            }
            ps.push(self.scalar(p).unwrap_or(self.t_ptr));
        }
        let ty = unsafe { LLVMFunctionType(rt, ps.as_mut_ptr(), ps.len() as u32, 0) };
        Sig { ty, attrs }
    }

    fn params_of(f: &Func) -> Vec<MTy> {
        f.params.iter().map(|&v| f.vars[v as usize].clone()).collect()
    }

    fn func_sig(&self, fi: usize) -> (Sig, Vec<CPass>, CPass) {
        let f = &self.prog.funcs[fi];
        let ps = Self::params_of(f);
        match f.abi {
            Abi::Auk => (self.auk_sig(&ps, &f.ret, Some(&self.inplace[fi])), vec![], CPass::None),
            Abi::C => self.c_sig(&ps, &f.ret),
        }
    }

    // ---- the module ----

    /// Translate the whole program.
    pub fn program(&mut self, ex: &Exports) -> Result<(), String> {
        let prog = self.prog;
        let entry = prog.entry.ok_or("no entry point")?;
        // which aggregate parameters each function reads in place
        for f in &prog.funcs {
            let mut set = vec![false; f.vars.len()];
            let mut addr = vec![false; f.vars.len()];
            writes(&f.body, &mut set, &mut addr);
            let ip = f.params.iter().map(|&v| f.abi == Abi::Auk && self.lay.is_agg(&f.vars[v as usize]) && !set[v as usize] && !addr[v as usize]).collect();
            self.inplace.push(ip);
        }
        let fattrs = [self.enum_attr("nounwind"), unsafe { LLVMCreateStringAttribute(self.cx, c"frame-pointer".as_ptr(), 13, c"all".as_ptr(), 3) }];
        for (i, f) in prog.funcs.iter().enumerate() {
            let (sig, _, _) = self.func_sig(i);
            let is_entry = i as u32 == entry;
            let name = if is_entry { ex.entry.clone() } else { f.name.clone() };
            let fv = unsafe { LLVMAddFunction(self.m, c(&name).as_ptr(), sig.ty) };
            let export = is_entry || ex.all || ex.names.contains(&f.name);
            unsafe {
                LLVMSetLinkage(fv, if export { LLVMLinkage::LLVMExternalLinkage } else { LLVMLinkage::LLVMInternalLinkage });
                for (k, a) in &sig.attrs {
                    LLVMAddAttributeAtIndex(fv, *k, *a);
                }
                for a in fattrs {
                    LLVMAddAttributeAtIndex(fv, u32::MAX, a);
                }
            }
            self.funcs.push((fv, sig));
        }
        for g in &prog.globals {
            let gv = self.global(g)?;
            self.globals.push(gv);
        }
        for i in 0..prog.funcs.len() {
            self.body(i)?;
        }
        if let Some(d) = self.debug.take() {
            d.finish();
        }
        Ok(())
    }

    /// A global's definition: zeros, or bytes with function addresses at their offsets.
    fn global(&mut self, g: &super::super::Global) -> Result<LLVMValueRef, String> {
        let l = self.lay.lay(&g.ty);
        let size = l.size.max(1);
        let (ty, init) = match &g.init {
            None => {
                let t = self.bytes_ty(size);
                (t, unsafe { LLVMConstNull(t) })
            }
            Some(init) => {
                let K::Agg(ms) = &init.k else { return Err(format!("global {}: unsupported initializer", g.name)) };
                let mut bytes = vec![0u8; size as usize];
                let mut ptrs: Vec<(usize, LLVMValueRef)> = Vec::new();
                for (s, v) in ms {
                    let off = self.lay.offset(&g.ty, *s) as usize;
                    match &v.k {
                        K::Int(n) => {
                            let sz = self.lay.lay(&v.ty).size as usize;
                            bytes[off..off + sz].copy_from_slice(&n.to_le_bytes()[..sz]);
                        }
                        K::SizeOf(t) => bytes[off..off + 8].copy_from_slice(&(self.lay.lay(t).size as u64).to_le_bytes()),
                        K::Zero => {}
                        K::FnAddr(FRef::Fn(f)) => ptrs.push((off, self.funcs[*f as usize].0)),
                        K::CStr(b) => {
                            let p = self.cstr_addr(b);
                            ptrs.push((off, p));
                        }
                        _ => return Err(format!("global {}: unsupported initializer member", g.name)),
                    }
                }
                ptrs.sort_by_key(|p| p.0);
                // a packed struct of byte runs and pointers
                let mut fields = Vec::new();
                let mut at = 0;
                for (off, p) in ptrs {
                    if off > at {
                        fields.push(self.const_bytes(&bytes[at..off]));
                    }
                    fields.push(p);
                    at = off + 8;
                }
                if at < bytes.len() {
                    fields.push(self.const_bytes(&bytes[at..]));
                }
                let v = unsafe { LLVMConstStructInContext(self.cx, fields.as_mut_ptr(), fields.len() as u32, 1) };
                (unsafe { LLVMTypeOf(v) }, v)
            }
        };
        unsafe {
            let gv = LLVMAddGlobal(self.m, ty, c(&g.name).as_ptr());
            LLVMSetInitializer(gv, init);
            LLVMSetLinkage(gv, LLVMLinkage::LLVMInternalLinkage);
            LLVMSetGlobalConstant(gv, g.constant as i32);
            LLVMSetAlignment(gv, l.align.max(8));
            Ok(gv)
        }
    }

    fn const_bytes(&self, b: &[u8]) -> LLVMValueRef {
        unsafe { LLVMConstStringInContext2(self.cx, b.as_ptr().cast(), b.len(), 1) }
    }

    // ---- function bodies ----

    fn body(&mut self, fi: usize) -> Result<(), String> {
        let prog = self.prog;
        let f = &prog.funcs[fi];
        let (fv, _) = self.funcs[fi].clone();
        let (_, pp, rp) = self.func_sig(fi);
        self.f = Some(f);
        self.fv = fv;
        self.sret = None;
        self.loops.clear();
        self.labels.clear();
        self.terminated = false;
        // debug info: the prologue is at the function's first line
        self.sp = None;
        let at = match self.debug.as_mut().map(|d| d.subprogram(fv, prog, fi)) {
            Some((sp, at)) => {
                self.sp = Some(sp);
                at
            }
            None => std::ptr::null_mut(),
        };
        unsafe {
            LLVMSetCurrentDebugLocation2(self.b, at);
            let allocas = LLVMAppendBasicBlockInContext(self.cx, fv, c"allocas".as_ptr());
            let start = LLVMAppendBasicBlockInContext(self.cx, fv, c"start".as_ptr());
            LLVMPositionBuilderAtEnd(self.ab, allocas);
            LLVMPositionBuilderAtEnd(self.b, start);
            let mut set = vec![false; f.vars.len()];
            self.addressed = vec![false; f.vars.len()];
            writes(&f.body, &mut set, &mut self.addressed);
            // variables (in-place parameters get their incoming pointer below)
            self.vars = vec![std::ptr::null_mut(); f.vars.len()];
            let inplace: Vec<VarId> = f.params.iter().zip(&self.inplace[fi]).filter(|(_, ip)| **ip).map(|(v, _)| *v).collect();
            for (v, t) in f.vars.iter().enumerate() {
                if !inplace.contains(&(v as VarId)) {
                    self.vars[v] = self.alloca(t);
                }
            }
            // parameters
            let mut k = 0;
            let param = |k: u32| LLVMGetParam(fv, k);
            match f.abi {
                Abi::Auk => {
                    if self.lay.is_agg(&f.ret) {
                        self.sret = Some(param(0));
                        k = 1;
                    }
                    for (i, &v) in f.params.iter().enumerate() {
                        let t = f.vars[v as usize].clone();
                        let p = param(k);
                        k += 1;
                        if self.inplace[fi][i] {
                            self.vars[v as usize] = p;
                        } else if self.lay.is_agg(&t) {
                            self.copy(self.vars[v as usize], p, &t);
                        } else {
                            self.store(p, self.vars[v as usize]);
                        }
                    }
                }
                Abi::C => {
                    if let CPass::Sret = rp {
                        self.sret = Some(param(0));
                        k = 1;
                    }
                    for (i, &v) in f.params.iter().enumerate() {
                        let dst = self.vars[v as usize];
                        match &pp[i] {
                            CPass::Scalar(_) => {
                                self.store(param(k), dst);
                                k += 1;
                            }
                            CPass::Words(ws) => {
                                for j in 0..ws.len() {
                                    let at = self.gep(dst, (j * 8) as u32);
                                    self.store(param(k), at);
                                    k += 1;
                                }
                            }
                            CPass::Sret => {
                                self.copy(dst, param(k), &f.vars[v as usize].clone());
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
            LLVMPositionBuilderAtEnd(self.ab, allocas);
            LLVMBuildBr(self.ab, start);
        }
        Ok(())
    }

    /// A stack slot for a value of type `t` in the entry block, rounded up to whole words (C
    /// results arrive as full words).
    fn alloca(&self, t: &MTy) -> LLVMValueRef {
        let l = self.lay.lay(t);
        let size = align_up(l.size.max(1), 8);
        unsafe {
            let a = LLVMBuildAlloca(self.ab, self.bytes_ty(size), NONAME);
            LLVMSetAlignment(a, l.align.max(8));
            a
        }
    }

    fn cur_ret_sig(&self) -> (Vec<CPass>, CPass) {
        let f = self.f.unwrap();
        self.lay.c_sig(&Self::params_of(f), &f.ret)
    }

    fn ret_default(&mut self) {
        let f = self.f.unwrap();
        unsafe {
            match (f.abi, self.scalar(&f.ret)) {
                (_, Some(t)) => {
                    LLVMBuildRet(self.b, LLVMConstNull(t));
                }
                (Abi::C, None) if self.lay.is_agg(&f.ret) => match self.cur_ret_sig().1 {
                    CPass::Words(ws) => {
                        LLVMBuildRet(self.b, LLVMConstNull(self.words_ty(&ws)));
                    }
                    _ => {
                        LLVMBuildRetVoid(self.b);
                    }
                },
                _ => {
                    LLVMBuildRetVoid(self.b);
                }
            }
        }
        self.terminated = true;
    }

    // ---- memory helpers ----

    fn gep(&self, base: LLVMValueRef, off: u32) -> LLVMValueRef {
        if off == 0 {
            return base;
        }
        unsafe {
            let mut idx = [LLVMConstInt(self.t_i64, off as u64, 0)];
            LLVMBuildInBoundsGEP2(self.b, self.t_i8, base, idx.as_mut_ptr(), 1, NONAME)
        }
    }

    fn store(&self, v: LLVMValueRef, at: LLVMValueRef) {
        unsafe {
            LLVMBuildStore(self.b, v, at);
        }
    }

    fn load_ty(&self, t: LLVMTypeRef, at: LLVMValueRef) -> LLVMValueRef {
        unsafe { LLVMBuildLoad2(self.b, t, at, NONAME) }
    }

    fn temp(&self, t: &MTy) -> LLVMValueRef {
        self.alloca(t)
    }

    fn zero_mem(&self, at: LLVMValueRef, t: &MTy) {
        let l = self.lay.lay(t);
        unsafe {
            LLVMBuildMemSet(self.b, at, LLVMConstInt(self.t_i8, 0, 0), LLVMConstInt(self.t_i64, l.size.max(1) as u64, 0), l.align.min(8));
        }
    }

    fn copy(&self, dst: LLVMValueRef, src: LLVMValueRef, t: &MTy) {
        let l = self.lay.lay(t);
        if l.size == 0 {
            return;
        }
        let a = l.align.min(8);
        unsafe {
            LLVMBuildMemCpy(self.b, dst, a, src, a, LLVMConstInt(self.t_i64, l.size as u64, 0));
        }
    }

    /// Word `k` of a C aggregate of type `t` at `src`: a full 8-byte load, or only the bytes the
    /// aggregate has (zero-extended) for a partial last word.
    fn load_word(&self, src: LLVMValueRef, k: usize, w: Sc, t: &MTy) -> LLVMValueRef {
        let size = self.lay.lay(t).size as usize;
        let at = self.gep(src, (k * 8) as u32);
        let n = (size - k * 8).min(8);
        if n == 8 || w.is_float() {
            return self.load_ty(self.lt(w), at);
        }
        unsafe {
            let part = LLVMBuildLoad2(self.b, LLVMIntTypeInContext(self.cx, (n * 8) as u32), at, NONAME);
            LLVMSetAlignment(part, 1);
            LLVMBuildZExt(self.b, part, self.t_i64, NONAME)
        }
    }

    // ---- control flow ----

    fn new_block(&self, name: &std::ffi::CStr) -> LLVMBasicBlockRef {
        unsafe { LLVMAppendBasicBlockInContext(self.cx, self.fv, name.as_ptr()) }
    }

    fn switch_to(&mut self, b: LLVMBasicBlockRef) {
        unsafe { LLVMPositionBuilderAtEnd(self.b, b) };
        self.terminated = false;
    }

    fn br(&self, b: LLVMBasicBlockRef) {
        unsafe {
            LLVMBuildBr(self.b, b);
        }
    }

    fn ensure_open(&mut self) {
        if self.terminated {
            let b = self.new_block(c"dead");
            self.switch_to(b);
        }
    }

    fn label_block(&mut self, l: LabelId) -> LLVMBasicBlockRef {
        if let Some(&b) = self.labels.get(&l) {
            return b;
        }
        let b = self.new_block(c"label");
        self.labels.insert(l, b);
        b
    }

    /// An i1 from an Auk bool (i8).
    fn truth(&self, v: LLVMValueRef) -> LLVMValueRef {
        unsafe {
            if LLVMTypeOf(v) == self.t_i1 {
                return v;
            }
            LLVMBuildICmp(self.b, LLVMIntPredicate::LLVMIntNE, v, LLVMConstNull(LLVMTypeOf(v)), NONAME)
        }
    }

    fn bool8(&self, v: LLVMValueRef) -> LLVMValueRef {
        unsafe { LLVMBuildZExt(self.b, v, self.t_i8, NONAME) }
    }

    fn stmts(&mut self, ss: &[Stmt]) -> Result<(), String> {
        for s in ss {
            self.stmt(s)?;
        }
        Ok(())
    }

    fn stmt(&mut self, s: &Stmt) -> Result<(), String> {
        if let Stmt::Loc(i) = s {
            // the code from here on comes from this source location
            if let (Some(d), Some(sp)) = (&self.debug, self.sp) {
                let at = d.loc(self.prog, *i, sp);
                unsafe { LLVMSetCurrentDebugLocation2(self.b, at) };
            }
            return Ok(());
        }
        if let Stmt::Label(l) = s {
            let blk = self.label_block(*l);
            if !self.terminated {
                self.br(blk);
            }
            self.switch_to(blk);
            return Ok(());
        }
        self.ensure_open();
        let f = self.f.unwrap();
        match s {
            Stmt::Let(v, e) => {
                let t = f.vars[*v as usize].clone();
                let x = self.ex(e);
                self.store_at(self.vars[*v as usize], &t, x, &e.ty);
            }
            Stmt::Set(p, e) => {
                let x = self.ex(e);
                let a = self.place(p);
                self.store_at(a, &p.ty, x, &e.ty);
            }
            Stmt::Do(e) => {
                let _ = self.ex(e);
            }
            Stmt::If(cnd, a, b) => {
                let cv = self.val(cnd);
                let cv = self.truth(cv);
                let (tb, eb, merge) = (self.new_block(c"then"), self.new_block(c"else"), self.new_block(c"endif"));
                unsafe { LLVMBuildCondBr(self.b, cv, tb, eb) };
                self.switch_to(tb);
                self.stmts(a)?;
                if !self.terminated {
                    self.br(merge);
                }
                self.switch_to(eb);
                self.stmts(b)?;
                if !self.terminated {
                    self.br(merge);
                }
                self.switch_to(merge);
            }
            Stmt::Loop(body, latch) => {
                let (head, lat, exit) = (self.new_block(c"loop"), self.new_block(c"latch"), self.new_block(c"endloop"));
                self.br(head);
                self.switch_to(head);
                self.loops.push((lat, exit));
                self.stmts(body)?;
                self.loops.pop();
                if !self.terminated {
                    self.br(lat);
                }
                self.switch_to(lat);
                self.stmts(latch)?;
                if !self.terminated {
                    self.br(head);
                }
                self.switch_to(exit);
            }
            Stmt::Break => {
                let (_, exit) = *self.loops.last().ok_or("break outside a loop")?;
                self.br(exit);
                self.terminated = true;
            }
            Stmt::Continue => {
                let (lat, _) = *self.loops.last().ok_or("continue outside a loop")?;
                self.br(lat);
                self.terminated = true;
            }
            Stmt::Goto(l) => {
                let blk = self.label_block(*l);
                self.br(blk);
                self.terminated = true;
            }
            Stmt::Ret(e) => {
                self.ret(e.as_ref());
                self.terminated = true;
            }
            Stmt::Unreachable => {
                self.trap();
                self.terminated = true;
            }
            Stmt::Label(_) | Stmt::Loc(_) => unreachable!(),
        }
        Ok(())
    }

    fn intrinsic(&self, name: &str, tys: &[LLVMTypeRef]) -> (LLVMValueRef, LLVMTypeRef) {
        unsafe {
            let id = LLVMLookupIntrinsicID(name.as_ptr().cast(), name.len());
            let mut ts = tys.to_vec();
            let f = LLVMGetIntrinsicDeclaration(self.m, id, ts.as_mut_ptr(), ts.len());
            let ft = LLVMIntrinsicGetType(self.cx, id, ts.as_mut_ptr(), ts.len());
            (f, ft)
        }
    }

    fn trap(&self) {
        let (f, ft) = self.intrinsic("llvm.trap", &[]);
        unsafe {
            LLVMBuildCall2(self.b, ft, f, std::ptr::null_mut(), 0, NONAME);
            LLVMBuildUnreachable(self.b);
        }
    }

    fn ret(&mut self, e: Option<&Ex>) {
        let f = self.f.unwrap();
        let Some(e) = e else {
            self.ret_default();
            return;
        };
        let x = self.ex(e);
        unsafe {
            if let Some(t) = self.scalar(&f.ret) {
                let v = self.scalar_of(x, &e.ty, &f.ret, t);
                LLVMBuildRet(self.b, v);
                return;
            }
            if matches!(f.ret, MTy::Void) {
                LLVMBuildRetVoid(self.b);
                return;
            }
            let V::M(src) = self.as_mem(x, &e.ty) else { panic!("llvm: aggregate return") };
            match (f.abi, self.cur_ret_sig().1) {
                (Abi::C, CPass::Words(ws)) => {
                    let vals: Vec<LLVMValueRef> = ws.iter().enumerate().map(|(k, w)| self.load_word(src, k, *w, &f.ret)).collect();
                    if vals.len() == 1 {
                        LLVMBuildRet(self.b, vals[0]);
                    } else {
                        let mut agg = LLVMGetUndef(self.words_ty(&ws));
                        for (k, v) in vals.into_iter().enumerate() {
                            agg = LLVMBuildInsertValue(self.b, agg, v, k as u32, NONAME);
                        }
                        LLVMBuildRet(self.b, agg);
                    }
                }
                _ => {
                    self.copy(self.sret.unwrap(), src, &f.ret);
                    LLVMBuildRetVoid(self.b);
                }
            }
        }
    }

    // ---- storing and converting ----

    fn store_at(&mut self, a: LLVMValueRef, t: &MTy, x: V, from: &MTy) {
        if let Some(s) = self.scalar(t) {
            let v = self.scalar_of(x, from, t, s);
            self.store(v, a);
        } else if let V::M(src) = self.as_mem(x, from) {
            if src != a {
                self.copy(a, src, t);
            }
        }
    }

    /// A scalar value converted from type `from` to `to` (LLVM type `s`).
    fn scalar_of(&mut self, x: V, from: &MTy, to: &MTy, s: LLVMTypeRef) -> LLVMValueRef {
        match x {
            V::S(v) => self.convert(v, from, to),
            V::M(a) => self.load_ty(s, a),
            V::None => unsafe { LLVMConstNull(s) },
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
                self.store(v, a);
                V::M(a)
            }
            V::None => {
                let a = self.temp(t);
                self.zero_mem(a, t);
                V::M(a)
            }
        }
    }

    fn convert(&mut self, v: LLVMValueRef, from: &MTy, to: &MTy) -> LLVMValueRef {
        let Some(tt) = self.scalar(to) else { return v };
        unsafe {
            let ft = LLVMTypeOf(v);
            if ft == tt {
                return v;
            }
            let kind = |t: LLVMTypeRef| LLVMGetTypeKind(t);
            let (fk, tk) = (kind(ft), kind(tt));
            use LLVMTypeKind::*;
            let signed = Layouts::signed(from);
            match (fk, tk) {
                (LLVMIntegerTypeKind, LLVMIntegerTypeKind) => {
                    let (fw, tw) = (LLVMGetIntTypeWidth(ft), LLVMGetIntTypeWidth(tt));
                    if tw > fw {
                        // an i1 (a comparison) is always zero-extended
                        if signed && fw > 1 { LLVMBuildSExt(self.b, v, tt, NONAME) } else { LLVMBuildZExt(self.b, v, tt, NONAME) }
                    } else {
                        LLVMBuildTrunc(self.b, v, tt, NONAME)
                    }
                }
                (LLVMFloatTypeKind, LLVMDoubleTypeKind) => LLVMBuildFPExt(self.b, v, tt, NONAME),
                (LLVMDoubleTypeKind, LLVMFloatTypeKind) => LLVMBuildFPTrunc(self.b, v, tt, NONAME),
                (LLVMIntegerTypeKind, LLVMDoubleTypeKind) => {
                    if signed {
                        LLVMBuildSIToFP(self.b, v, tt, NONAME)
                    } else {
                        LLVMBuildUIToFP(self.b, v, tt, NONAME)
                    }
                }
                (LLVMDoubleTypeKind, LLVMIntegerTypeKind) => {
                    let (f, fty) = self.intrinsic("llvm.fptosi.sat", &[tt, ft]);
                    let mut args = [v];
                    LLVMBuildCall2(self.b, fty, f, args.as_mut_ptr(), 1, NONAME)
                }
                (LLVMPointerTypeKind, LLVMIntegerTypeKind) => LLVMBuildPtrToInt(self.b, v, tt, NONAME),
                (LLVMIntegerTypeKind, LLVMPointerTypeKind) => LLVMBuildIntToPtr(self.b, v, tt, NONAME),
                (LLVMDoubleTypeKind, LLVMPointerTypeKind) => {
                    let i = LLVMBuildBitCast(self.b, v, self.t_i64, NONAME);
                    LLVMBuildIntToPtr(self.b, i, tt, NONAME)
                }
                (LLVMPointerTypeKind, LLVMDoubleTypeKind) => {
                    let i = LLVMBuildPtrToInt(self.b, v, self.t_i64, NONAME);
                    LLVMBuildBitCast(self.b, i, tt, NONAME)
                }
                _ => v,
            }
        }
    }

    // ---- expressions ----

    /// A scalar expression's value.
    fn val(&mut self, e: &Ex) -> LLVMValueRef {
        let x = self.ex(e);
        let t = self.scalar(&e.ty).unwrap_or(self.t_i8);
        self.scalar_of(x, &e.ty, &e.ty, t)
    }

    /// An aggregate expression's address.
    fn mem_of(&mut self, e: &Ex) -> LLVMValueRef {
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
    fn place(&mut self, e: &Ex) -> LLVMValueRef {
        match &e.k {
            K::Var(v) => self.vars[*v as usize],
            K::Global(g) => self.globals[*g as usize],
            K::Deref(p) => {
                // `*(T *)auk_arr_at(xs, i, loc)`: the element size is T's
                let inner = if let K::Cast(x) = &p.k { &**x } else { &**p };
                if matches!(&inner.k, K::Call(Callee::Rt(s), _) if s == "auk_arr_at") {
                    self.elem_hint = Some(self.lay.lay(&e.ty).size);
                }
                let v = self.val(p);
                self.elem_hint = None;
                v
            }
            K::Field(b, s) => {
                let base = self.mem_of(b);
                let off = self.lay.offset(&b.ty, *s);
                self.gep(base, off)
            }
            K::Elem(arr, i) => {
                let a = self.val(arr);
                let dp = self.gep(a, 40);
                let data = self.load_ty(self.t_ptr, dp);
                let iv = self.val(i);
                let iv = self.convert(iv, &i.ty, &MTy::I64);
                let size = self.lay.lay(&e.ty).size as u64;
                unsafe {
                    let off = LLVMBuildMul(self.b, iv, LLVMConstInt(self.t_i64, size, 0), NONAME);
                    let mut idx = [off];
                    LLVMBuildGEP2(self.b, self.t_i8, data, idx.as_mut_ptr(), 1, NONAME)
                }
            }
            K::RtField(p, f) => {
                let a = self.val(p);
                let off = match f {
                    RtF::ArrLen => 24,
                    RtF::ArrData => 40,
                    RtF::ErrMsg => 16,
                };
                self.gep(a, off)
            }
            _ => {
                let x = self.ex(e);
                let a = self.temp(&e.ty);
                self.store_at(a, &e.ty, x, &e.ty);
                a
            }
        }
    }

    /// Load a value of type `t` from address `a`: a scalar, or the address itself.
    fn load(&self, a: LLVMValueRef, t: &MTy) -> V {
        match self.scalar(t) {
            Some(s) => V::S(self.load_ty(s, a)),
            None => V::M(a),
        }
    }

    fn rt_data_addr(&mut self, name: &str) -> LLVMValueRef {
        if let Some(&g) = self.rt_data.get(name) {
            return g;
        }
        let g = unsafe { LLVMAddGlobal(self.m, self.t_i8, c(name).as_ptr()) };
        self.rt_data.insert(name.to_string(), g);
        g
    }

    fn cstr_addr(&mut self, s: &[u8]) -> LLVMValueRef {
        if let Some(&g) = self.cstrs.get(s) {
            return g;
        }
        unsafe {
            let init = LLVMConstStringInContext2(self.cx, s.as_ptr().cast(), s.len(), 0);
            let g = LLVMAddGlobal(self.m, LLVMTypeOf(init), c"str".as_ptr());
            LLVMSetInitializer(g, init);
            LLVMSetLinkage(g, LLVMLinkage::LLVMPrivateLinkage);
            LLVMSetGlobalConstant(g, 1);
            LLVMSetUnnamedAddress(g, LLVMUnnamedAddr::LLVMGlobalUnnamedAddr);
            LLVMSetAlignment(g, 1);
            self.cstrs.insert(s.to_vec(), g);
            g
        }
    }

    fn ex(&mut self, e: &Ex) -> V {
        unsafe {
            match &e.k {
                K::Var(v) => {
                    let a = self.vars[*v as usize];
                    self.load(a, &e.ty)
                }
                K::Global(_) | K::Deref(_) | K::Field(..) | K::Elem(..) | K::RtField(..) if e.is_place() || !matches!(e.k, K::Field(..)) => {
                    let a = self.place(e);
                    self.load(a, &e.ty)
                }
                K::Field(b, s) => {
                    // a member of an aggregate value
                    let base = self.mem_of(b);
                    let off = self.lay.offset(&b.ty, *s);
                    let a = self.gep(base, off);
                    self.load(a, &e.ty)
                }
                K::Int(n) => match self.scalar(&e.ty) {
                    Some(t) if t == self.t_f64 => V::S(LLVMConstReal(t, *n as f64)),
                    Some(t) if t == self.t_ptr => {
                        if *n == 0 {
                            V::S(LLVMConstNull(t))
                        } else {
                            V::S(LLVMConstIntToPtr(LLVMConstInt(self.t_i64, *n as u64, 0), t))
                        }
                    }
                    Some(t) => V::S(LLVMConstInt(t, *n as u64, 0)),
                    None => V::None,
                },
                K::Float(x) => V::S(LLVMConstReal(self.t_f64, *x)),
                K::CStr(s) => V::S(self.cstr_addr(s)),
                K::Zero => match self.scalar(&e.ty) {
                    Some(t) => V::S(LLVMConstNull(t)),
                    None => V::None,
                },
                K::FnAddr(FRef::Fn(f)) => V::S(self.funcs[*f as usize].0),
                K::FnAddr(FRef::Rt(s)) => panic!("llvm: address of runtime function {s}"),
                K::GlobalAddr(g) => V::S(self.globals[*g as usize]),
                K::RtGlobalAddr(s) => V::S(self.rt_data_addr(s)),
                K::Addr(p) => V::S(self.place(p)),
                K::Un(op, a) => {
                    let v = self.val(a);
                    V::S(match op {
                        UOp::Not => {
                            let z = LLVMBuildICmp(self.b, LLVMIntPredicate::LLVMIntEQ, v, LLVMConstNull(LLVMTypeOf(v)), NONAME);
                            self.bool8(z)
                        }
                        UOp::Neg => {
                            if LLVMTypeOf(v) == self.t_f64 {
                                LLVMBuildFNeg(self.b, v, NONAME)
                            } else {
                                LLVMBuildNeg(self.b, v, NONAME)
                            }
                        }
                        UOp::BitNot => LLVMBuildNot(self.b, v, NONAME),
                    })
                }
                K::Bin(op, a, b) => V::S(self.bin(*op, a, b)),
                K::And(xs) => {
                    let done = self.new_block(c"and");
                    let mut incoming = Vec::new();
                    for x in xs {
                        let v = self.val(x);
                        let v = self.truth(v);
                        let next = self.new_block(c"and.next");
                        LLVMBuildCondBr(self.b, v, next, done);
                        incoming.push((LLVMConstInt(self.t_i8, 0, 0), LLVMGetInsertBlock(self.b)));
                        self.switch_to(next);
                    }
                    self.br(done);
                    incoming.push((LLVMConstInt(self.t_i8, 1, 0), LLVMGetInsertBlock(self.b)));
                    self.switch_to(done);
                    let phi = LLVMBuildPhi(self.b, self.t_i8, NONAME);
                    let (mut vs, mut bs): (Vec<_>, Vec<_>) = incoming.into_iter().unzip();
                    LLVMAddIncoming(phi, vs.as_mut_ptr(), bs.as_mut_ptr(), vs.len() as u32);
                    V::S(phi)
                }
                K::Cast(x) => {
                    let v = self.ex(x);
                    match (v, self.scalar(&e.ty)) {
                        (V::S(s), Some(_)) => V::S(self.convert(s, &x.ty, &e.ty)),
                        (V::M(a), Some(t)) => V::S(self.load_ty(t, a)),
                        (v, _) => v,
                    }
                }
                K::Call(cl, args) => self.call(cl, args, &e.ty),
                K::Agg(ms) => {
                    let a = self.temp(&e.ty);
                    self.zero_mem(a, &e.ty);
                    for (s, v) in ms {
                        let off = self.lay.offset(&e.ty, *s);
                        let mt = self.lay.info.member_ty(&e.ty, *s, &self.prog.aggs);
                        let x = self.ex(v);
                        let p = self.gep(a, off);
                        self.store_at(p, &mt, x, &v.ty);
                    }
                    V::M(a)
                }
                K::Cond(cnd, a, b) => {
                    let cv = self.val(cnd);
                    let cv = self.truth(cv);
                    let t = self.scalar(&e.ty).expect("llvm: aggregate conditional");
                    let (tb, eb, done) = (self.new_block(c"cond.then"), self.new_block(c"cond.else"), self.new_block(c"cond"));
                    LLVMBuildCondBr(self.b, cv, tb, eb);
                    self.switch_to(tb);
                    let x = self.ex(a);
                    let xv = self.scalar_of(x, &a.ty, &e.ty, t);
                    let xb = LLVMGetInsertBlock(self.b);
                    self.br(done);
                    self.switch_to(eb);
                    let y = self.ex(b);
                    let yv = self.scalar_of(y, &b.ty, &e.ty, t);
                    let yb = LLVMGetInsertBlock(self.b);
                    self.br(done);
                    self.switch_to(done);
                    let phi = LLVMBuildPhi(self.b, t, NONAME);
                    let mut vs = [xv, yv];
                    let mut bs = [xb, yb];
                    LLVMAddIncoming(phi, vs.as_mut_ptr(), bs.as_mut_ptr(), 2);
                    V::S(phi)
                }
                K::SizeOf(t) => V::S(LLVMConstInt(self.t_i64, self.lay.lay(t).size as u64, 0)),
                K::Global(_) | K::Deref(_) | K::Elem(..) | K::RtField(..) => unreachable!(),
            }
        }
    }

    fn bin(&mut self, op: BOp, a: &Ex, b: &Ex) -> LLVMValueRef {
        let x = self.val(a);
        let y0 = self.val(b);
        let y = self.convert(y0, &b.ty, &a.ty);
        unsafe {
            let bld = self.b;
            if LLVMTypeOf(x) == self.t_f64 {
                use LLVMRealPredicate::*;
                let cmp = |p| self.bool8(LLVMBuildFCmp(bld, p, x, y, NONAME));
                return match op {
                    BOp::Add => LLVMBuildFAdd(bld, x, y, NONAME),
                    BOp::Sub => LLVMBuildFSub(bld, x, y, NONAME),
                    BOp::Mul => LLVMBuildFMul(bld, x, y, NONAME),
                    BOp::Div => LLVMBuildFDiv(bld, x, y, NONAME),
                    BOp::Eq => cmp(LLVMRealOEQ),
                    BOp::Ne => cmp(LLVMRealUNE),
                    BOp::Lt => cmp(LLVMRealOLT),
                    BOp::Le => cmp(LLVMRealOLE),
                    BOp::Gt => cmp(LLVMRealOGT),
                    BOp::Ge => cmp(LLVMRealOGE),
                    _ => panic!("llvm: float {op:?}"),
                };
            }
            let unsigned = matches!(a.ty, MTy::U8 | MTy::U16 | MTy::U32 | MTy::U64 | MTy::D(Ty::Char) | MTy::Ptr(_) | MTy::CStr | MTy::Code);
            use LLVMIntPredicate::*;
            let cc = |s, u| if unsigned { u } else { s };
            let cmp = |p| self.bool8(LLVMBuildICmp(bld, p, x, y, NONAME));
            let is_ptr = LLVMTypeOf(x) == self.t_ptr;
            // arithmetic on pointers goes through integers
            let arith = |f: unsafe extern "C" fn(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, *const libc::c_char) -> LLVMValueRef| {
                if is_ptr {
                    let xi = LLVMBuildPtrToInt(bld, x, self.t_i64, NONAME);
                    let yi = if LLVMTypeOf(y) == self.t_ptr { LLVMBuildPtrToInt(bld, y, self.t_i64, NONAME) } else { y };
                    LLVMBuildIntToPtr(bld, f(bld, xi, yi, NONAME), self.t_ptr, NONAME)
                } else {
                    f(bld, x, y, NONAME)
                }
            };
            match op {
                BOp::Add => arith(LLVMBuildAdd),
                BOp::Sub => arith(LLVMBuildSub),
                BOp::Mul => arith(LLVMBuildMul),
                BOp::Div => arith(LLVMBuildSDiv),
                BOp::BitAnd => arith(LLVMBuildAnd),
                BOp::BitOr => arith(LLVMBuildOr),
                BOp::BitXor => arith(LLVMBuildXor),
                BOp::Eq => cmp(LLVMIntEQ),
                BOp::Ne => cmp(LLVMIntNE),
                BOp::Lt => cmp(cc(LLVMIntSLT, LLVMIntULT)),
                BOp::Le => cmp(cc(LLVMIntSLE, LLVMIntULE)),
                BOp::Gt => cmp(cc(LLVMIntSGT, LLVMIntUGT)),
                BOp::Ge => cmp(cc(LLVMIntSGE, LLVMIntUGE)),
            }
        }
    }

    // ---- calls ----

    fn build_call(&self, sig: &Sig, callee: LLVMValueRef, args: &mut [LLVMValueRef]) -> LLVMValueRef {
        unsafe {
            let call = LLVMBuildCall2(self.b, sig.ty, callee, args.as_mut_ptr(), args.len() as u32, NONAME);
            for (k, a) in &sig.attrs {
                LLVMAddCallSiteAttribute(call, *k, *a);
            }
            call
        }
    }

    fn call(&mut self, cl: &Callee, args: &[Ex], ret: &MTy) -> V {
        let prog = self.prog;
        match cl {
            Callee::Fn(f) => {
                let func = &prog.funcs[*f as usize];
                let ps = Self::params_of(func);
                let (fv, sig) = self.funcs[*f as usize].clone();
                // live: the current body of `f` is in its table slot
                let target = match self.live.as_ref().and_then(|(t, s)| s.get(f).map(|slot| t + slot * 8)) {
                    Some(at) => unsafe {
                        let p = LLVMConstIntToPtr(LLVMConstInt(self.t_i64, at as u64, 0), self.t_ptr);
                        self.load_ty(self.t_ptr, p)
                    },
                    None => fv,
                };
                match func.abi {
                    Abi::Auk => {
                        let inplace = self.inplace[*f as usize].clone();
                        let (mut vals, out) = self.auk_args(&ps, args, &func.ret, &inplace);
                        let call = self.build_call(&sig, target, &mut vals);
                        self.auk_result(call, out, &func.ret)
                    }
                    Abi::C => {
                        let (_, pp, rp) = self.c_sig(&ps, &func.ret);
                        let (mut vals, out) = self.c_args(&pp, &ps, args, &rp, &func.ret);
                        let call = self.build_call(&sig, target, &mut vals);
                        self.c_result(call, out, &rp, &func.ret)
                    }
                }
            }
            Callee::Indirect(code, ps) => {
                let cv = self.val(code);
                let sig = self.auk_sig(ps, ret, None);
                let none = vec![false; ps.len()];
                let (mut vals, out) = self.auk_args(ps, args, ret, &none);
                let call = self.build_call(&sig, cv, &mut vals);
                self.auk_result(call, out, ret)
            }
            Callee::CPtr(code) => {
                let cv = self.val(code);
                let ps: Vec<MTy> = args.iter().map(|a| a.ty.clone()).collect();
                let (sig, pp, rp) = self.c_sig(&ps, ret);
                let (mut vals, out) = self.c_args(&pp, &ps, args, &rp, ret);
                let call = self.build_call(&sig, cv, &mut vals);
                self.c_result(call, out, &rp, ret)
            }
            Callee::Rt(sym) => {
                if let Some(v) = self.rt_inline(sym, args, ret) {
                    return v;
                }
                let ps: Vec<MTy> = args.iter().map(|a| a.ty.clone()).collect();
                let (sig, pp, rp) = self.c_sig(&ps, ret);
                let (mut vals, out) = self.c_args(&pp, &ps, args, &rp, ret);
                let fv = self.rt_func(sym, &sig);
                let call = self.build_call(&sig, fv, &mut vals);
                self.c_result(call, out, &rp, ret)
            }
        }
    }

    /// A runtime function's declaration (with the signature of its first use; later calls with
    /// another compatible signature call the same symbol with their own function type).
    fn rt_func(&mut self, sym: &str, sig: &Sig) -> LLVMValueRef {
        if let Some(&f) = self.rt_funcs.get(sym) {
            return f;
        }
        unsafe {
            let f = LLVMAddFunction(self.m, c(sym).as_ptr(), sig.ty);
            for (k, a) in &sig.attrs {
                LLVMAddAttributeAtIndex(f, *k, *a);
            }
            LLVMAddAttributeAtIndex(f, u32::MAX, self.enum_attr("nounwind"));
            if NORETURN.contains(&sym) {
                LLVMAddAttributeAtIndex(f, u32::MAX, self.enum_attr("noreturn"));
                LLVMAddAttributeAtIndex(f, u32::MAX, self.enum_attr("cold"));
            }
            self.rt_funcs.insert(sym.to_string(), f);
            f
        }
    }

    /// Arguments in the generated-function convention (and the result slot, if any). An
    /// in-place parameter gets memory nothing else can reach during the call.
    fn auk_args(&mut self, ps: &[MTy], args: &[Ex], ret: &MTy, inplace: &[bool]) -> (Vec<LLVMValueRef>, Option<LLVMValueRef>) {
        let mut vals = Vec::new();
        let out = if self.lay.is_agg(ret) {
            let a = self.temp(ret);
            vals.push(a);
            Some(a)
        } else {
            None
        };
        for (i, (p, a)) in ps.iter().zip(args).enumerate() {
            if self.lay.is_agg(p) {
                let private = if a.is_place() { self.private_place(a) } else { true };
                let m = self.mem_of(a);
                if inplace[i] && !private {
                    let t = self.temp(p);
                    self.copy(t, m, p);
                    vals.push(t);
                } else {
                    vals.push(m);
                }
            } else {
                let x = self.ex(a);
                let s = self.scalar(p).unwrap();
                let v = self.scalar_of(x, &a.ty, p, s);
                vals.push(v);
            }
        }
        (vals, out)
    }

    /// Can nothing but this function reach `place` (a local whose address is never taken, or a
    /// member of one)? An in-place parameter counts: nobody writes it during the call.
    fn private_place(&self, place: &Ex) -> bool {
        let mut b = place;
        while let K::Field(x, _) = &b.k {
            b = x;
        }
        matches!(b.k, K::Var(v) if !self.addressed[v as usize])
    }

    fn auk_result(&mut self, call: LLVMValueRef, out: Option<LLVMValueRef>, ret: &MTy) -> V {
        if let Some(a) = out {
            return V::M(a);
        }
        if matches!(ret, MTy::Void) || self.scalar(ret).is_none() { V::None } else { V::S(call) }
    }

    /// Arguments in the C convention (and the struct-return slot, if any).
    fn c_args(&mut self, pp: &[CPass], ps: &[MTy], args: &[Ex], rp: &CPass, ret: &MTy) -> (Vec<LLVMValueRef>, Option<LLVMValueRef>) {
        let mut vals = Vec::new();
        let out = if let CPass::Sret = rp {
            let a = self.temp(ret);
            vals.push(a);
            Some(a)
        } else {
            None
        };
        for ((cp, p), a) in pp.iter().zip(ps).zip(args) {
            match cp {
                CPass::Scalar(s) => {
                    let x = self.ex(a);
                    let v = self.scalar_of(x, &a.ty, p, self.lt(*s));
                    vals.push(v);
                }
                CPass::Words(ws) => {
                    let m = self.mem_of(a);
                    for (k, w) in ws.iter().enumerate() {
                        vals.push(self.load_word(m, k, *w, p));
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

    fn c_result(&mut self, call: LLVMValueRef, out: Option<LLVMValueRef>, rp: &CPass, ret: &MTy) -> V {
        if let Some(a) = out {
            return V::M(a);
        }
        match rp {
            CPass::None => V::None,
            CPass::Scalar(_) => V::S(call),
            CPass::Words(ws) => {
                let a = self.temp(ret);
                if ws.len() == 1 {
                    self.store(call, a);
                } else {
                    for k in 0..ws.len() {
                        let v = unsafe { LLVMBuildExtractValue(self.b, call, k as u32, NONAME) };
                        let at = self.gep(a, (k * 8) as u32);
                        self.store(v, at);
                    }
                }
                V::M(a)
            }
            CPass::Sret => unreachable!(),
        }
    }
}

impl Drop for Gen<'_, '_> {
    fn drop(&mut self) {
        unsafe {
            LLVMDisposeBuilder(self.b);
            LLVMDisposeBuilder(self.ab);
        }
    }
}

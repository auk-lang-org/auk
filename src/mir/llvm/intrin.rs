//! Runtime calls compiled inline: the hot ones (checked arithmetic, list reads and writes,
//! reference counting) get their fast path in the generated code and call the runtime only on
//! the slow or failing path. A failing path calls the *same* runtime function with the same
//! arguments (which then panics), so messages and edge cases are exactly the runtime's.
//!
//! Layouts used here (runtime/c/auk_rt.h): `AukHeader { rc: i64 @0, kind: u32 @8 }`,
//! `AukArr { h @0, ops @16, len @24, cap @32, data @40, base @48 }`, `AukElemOps { size @0 }`.
//! Handle kinds (`heap::is_handle`): 6..=10.

use llvm_sys::core::*;
use llvm_sys::prelude::*;
use llvm_sys::{LLVMAtomicOrdering, LLVMAtomicRMWBinOp, LLVMIntPredicate};

use super::{Gen, NONAME, V};
use crate::mir::{Ex, K, MTy};

const ARR_OPS: u32 = 16;
const ARR_LEN: u32 = 24;
const ARR_CAP: u32 = 32;
const ARR_DATA: u32 = 40;
const ARR_BASE: u32 = 48;
const HDR_KIND: u32 = 8;
const HANDLE_FIRST: u64 = 6;
const HANDLE_COUNT: u64 = 5;

impl Gen<'_, '_> {
    /// Compile runtime call `sym(args)` inline, if it is one of the known ones.
    pub(super) fn rt_inline(&mut self, sym: &str, args: &[Ex], ret: &MTy) -> Option<V> {
        if !self.inline_rt {
            return None;
        }
        let int = |e: &Ex| matches!(e.ty, MTy::D(crate::types::Ty::Int) | MTy::I64);
        Some(match (sym, args) {
            ("auk_add" | "auk_sub" | "auk_mul", [a, b, _]) if int(a) && int(b) => {
                let op = match sym {
                    "auk_add" => "llvm.sadd.with.overflow",
                    "auk_sub" => "llvm.ssub.with.overflow",
                    _ => "llvm.smul.with.overflow",
                };
                let vals = self.eval_args(args);
                let (f, ft) = self.intrinsic(op, &[self.t_i64]);
                unsafe {
                    let mut xy = [vals[0], vals[1]];
                    let r = LLVMBuildCall2(self.b, ft, f, xy.as_mut_ptr(), 2, NONAME);
                    let of = LLVMBuildExtractValue(self.b, r, 1, NONAME);
                    self.fail_if(of, sym, args, &vals, ret);
                    V::S(LLVMBuildExtractValue(self.b, r, 0, NONAME))
                }
            }
            ("auk_div" | "auk_mod", [a, b, _]) if int(a) && int(b) => {
                let vals = self.eval_args(args);
                let (x, y) = (vals[0], vals[1]);
                unsafe {
                    let zero = LLVMConstInt(self.t_i64, 0, 0);
                    let m1 = LLVMConstInt(self.t_i64, u64::MAX, 1);
                    let by0 = LLVMBuildICmp(self.b, LLVMIntPredicate::LLVMIntEQ, y, zero, NONAME);
                    if sym == "auk_div" {
                        // also MIN / -1 overflows
                        let min = LLVMConstInt(self.t_i64, i64::MIN as u64, 1);
                        let xm = LLVMBuildICmp(self.b, LLVMIntPredicate::LLVMIntEQ, x, min, NONAME);
                        let ym = LLVMBuildICmp(self.b, LLVMIntPredicate::LLVMIntEQ, y, m1, NONAME);
                        let ov = LLVMBuildAnd(self.b, xm, ym, NONAME);
                        let bad = LLVMBuildOr(self.b, by0, ov, NONAME);
                        self.fail_if(bad, sym, args, &vals, ret);
                        V::S(LLVMBuildSDiv(self.b, x, y, NONAME))
                    } else {
                        // x % -1 is 0 (and x % 1 is too, without MIN % -1's overflow)
                        self.fail_if(by0, sym, args, &vals, ret);
                        let ym = LLVMBuildICmp(self.b, LLVMIntPredicate::LLVMIntEQ, y, m1, NONAME);
                        let y1 = LLVMBuildSelect(self.b, ym, LLVMConstInt(self.t_i64, 1, 0), y, NONAME);
                        V::S(LLVMBuildSRem(self.b, x, y1, NONAME))
                    }
                }
            }
            ("auk_shl" | "auk_shr", [a, b, _]) if int(a) && int(b) => {
                let vals = self.eval_args(args);
                unsafe {
                    let bad = LLVMBuildICmp(self.b, LLVMIntPredicate::LLVMIntUGT, vals[1], LLVMConstInt(self.t_i64, 63, 0), NONAME);
                    self.fail_if(bad, sym, args, &vals, ret);
                    V::S(if sym == "auk_shl" { LLVMBuildShl(self.b, vals[0], vals[1], NONAME) } else { LLVMBuildAShr(self.b, vals[0], vals[1], NONAME) })
                }
            }
            // exact float operations (bit-identical to Rust's f64 methods in the runtime)
            ("auk_fsqrt" | "auk_fabs" | "auk_ffloor" | "auk_fceil" | "auk_fround", [_]) => {
                let name = match sym {
                    "auk_fsqrt" => "llvm.sqrt",
                    "auk_fabs" => "llvm.fabs",
                    "auk_ffloor" => "llvm.floor",
                    "auk_fceil" => "llvm.ceil",
                    _ => "llvm.round",
                };
                let vals = self.eval_args(args);
                let (f, ft) = self.intrinsic(name, &[self.t_f64]);
                let mut a = [vals[0]];
                V::S(unsafe { LLVMBuildCall2(self.b, ft, f, a.as_mut_ptr(), 1, NONAME) })
            }
            ("auk_arr_len", [_]) => {
                let vals = self.eval_args(args);
                V::S(self.arr_len(vals[0]))
            }
            ("auk_arr_at", [_, i, _]) if int(i) => {
                let size = self.elem_hint.take();
                let vals = self.eval_args(args);
                let (a, i) = (vals[0], vals[1]);
                unsafe {
                    let n = self.arr_len(a);
                    let bad = LLVMBuildICmp(self.b, LLVMIntPredicate::LLVMIntUGE, i, n, NONAME);
                    self.fail_if(bad, sym, args, &vals, ret);
                    let size = match size {
                        Some(s) => LLVMConstInt(self.t_i64, s as u64, 0),
                        None => {
                            let ops = self.load_ty(self.t_ptr, self.gep(a, ARR_OPS));
                            self.load_ty(self.t_i64, ops)
                        }
                    };
                    V::S(self.elem_addr(a, i, size))
                }
            }
            ("auk_arr_set", [_, i, e, _]) if int(i) => {
                let (s, size) = self.plain_elem(e)?;
                let vals = self.eval_args(args);
                let (pa, i, ep) = (vals[0], vals[1], vals[2]);
                unsafe {
                    // fast: a unique list and i in range
                    let (a, slow, done) = self.unique_list(pa);
                    let n = self.load_ty(self.t_i64, self.gep(a, ARR_LEN));
                    let inr = LLVMBuildICmp(self.b, LLVMIntPredicate::LLVMIntULT, i, n, NONAME);
                    let store = self.new_block(c"set.store");
                    LLVMBuildCondBr(self.b, self.likely(inr), store, slow);
                    self.switch_to(store);
                    let v = self.load_ty(s, ep);
                    let at = self.elem_addr(a, i, LLVMConstInt(self.t_i64, size, 0));
                    self.store(v, at);
                    self.slow_and_join(slow, done, sym, args, &vals, ret);
                    V::None
                }
            }
            ("auk_arr_push", [_, e]) => {
                let (s, size) = self.plain_elem(e)?;
                let vals = self.eval_args(args);
                let (pa, ep) = (vals[0], vals[1]);
                unsafe {
                    // fast: a unique list with room for one more
                    let (a, slow, done) = self.unique_list(pa);
                    let n = self.load_ty(self.t_i64, self.gep(a, ARR_LEN));
                    let cap = self.load_ty(self.t_i64, self.gep(a, ARR_CAP));
                    let room = LLVMBuildICmp(self.b, LLVMIntPredicate::LLVMIntSLT, n, cap, NONAME);
                    let store = self.new_block(c"push.store");
                    LLVMBuildCondBr(self.b, self.likely(room), store, slow);
                    self.switch_to(store);
                    let v = self.load_ty(s, ep);
                    let at = self.elem_addr(a, n, LLVMConstInt(self.t_i64, size, 0));
                    self.store(v, at);
                    let n1 = LLVMBuildAdd(self.b, n, LLVMConstInt(self.t_i64, 1, 0), NONAME);
                    self.store(n1, self.gep(a, ARR_LEN));
                    self.slow_and_join(slow, done, sym, args, &vals, ret);
                    V::None
                }
            }
            ("auk_retain", [_]) => {
                let vals = self.eval_args(args);
                let p = vals[0];
                self.rc_update(p, true, args, &vals, ret);
                V::S(p)
            }
            ("auk_release", [_]) => {
                let vals = self.eval_args(args);
                self.rc_update(vals[0], false, args, &vals, ret);
                V::None
            }
            _ => return None,
        })
    }

    /// The scalar type and size of a list element passed as `(void *)&v`, if it holds no
    /// references (no retain/release needed: storing it is a plain store).
    fn plain_elem(&self, e: &Ex) -> Option<(LLVMTypeRef, u64)> {
        let ety = if let K::Cast(x) = &e.k { &x.ty } else { &e.ty };
        let MTy::Ptr(et) = ety else { return None };
        let MTy::D(d) = &**et else { return None };
        if self.lay.info.is_ptr(d) {
            return None;
        }
        let s = self.scalar(et)?;
        Some((s, self.lay.lay(et).size as u64))
    }

    /// Load the list `*pa` and branch on whether it may be mutated in place: non-NULL and
    /// unique (one reference, not a slice view). Continues in the "unique" block; returns the
    /// list and the slow and join blocks.
    fn unique_list(&mut self, pa: LLVMValueRef) -> (LLVMValueRef, LLVMBasicBlockRef, LLVMBasicBlockRef) {
        unsafe {
            let a = self.load_ty(self.t_ptr, pa);
            let nonnull = LLVMBuildIsNotNull(self.b, a, NONAME);
            let (check, slow, done) = (self.new_block(c"list.check"), self.new_block(c"list.slow"), self.new_block(c"list.done"));
            LLVMBuildCondBr(self.b, self.likely(nonnull), check, slow);
            self.switch_to(check);
            let base = self.load_ty(self.t_ptr, self.gep(a, ARR_BASE));
            let noview = LLVMBuildIsNull(self.b, base, NONAME);
            let rc = self.load_ty(self.t_i64, a);
            let one = LLVMBuildICmp(self.b, LLVMIntPredicate::LLVMIntEQ, rc, LLVMConstInt(self.t_i64, 1, 0), NONAME);
            let uniq = LLVMBuildAnd(self.b, noview, one, NONAME);
            let fast = self.new_block(c"list.unique");
            LLVMBuildCondBr(self.b, self.likely(uniq), fast, slow);
            self.switch_to(fast);
            (a, slow, done)
        }
    }

    /// End the fast path (jump to `done`), emit the slow path (the runtime call) and continue
    /// after both.
    fn slow_and_join(&mut self, slow: LLVMBasicBlockRef, done: LLVMBasicBlockRef, sym: &str, args: &[Ex], vals: &[LLVMValueRef], ret: &MTy) {
        self.br(done);
        self.switch_to(slow);
        self.slow_call(sym, args, vals, ret);
        self.br(done);
        self.switch_to(done);
    }

    /// The arguments' values, each converted to its own scalar type.
    fn eval_args(&mut self, args: &[Ex]) -> Vec<LLVMValueRef> {
        args.iter().map(|a| self.val(a)).collect()
    }

    /// `cond` marked as almost always true.
    fn likely(&self, cond: LLVMValueRef) -> LLVMValueRef {
        let (f, ft) = self.intrinsic("llvm.expect", &[self.t_i1]);
        unsafe {
            let mut a = [cond, LLVMConstInt(self.t_i1, 1, 0)];
            LLVMBuildCall2(self.b, ft, f, a.as_mut_ptr(), 2, NONAME)
        }
    }

    /// If `bad`, call the runtime function itself (which panics) on a cold path.
    fn fail_if(&mut self, bad: LLVMValueRef, sym: &str, args: &[Ex], vals: &[LLVMValueRef], ret: &MTy) {
        unsafe {
            let ok = LLVMBuildNot(self.b, bad, NONAME);
            let (cold, cont) = (self.new_block(c"rt.fail"), self.new_block(c"rt.ok"));
            LLVMBuildCondBr(self.b, self.likely(ok), cont, cold);
            self.switch_to(cold);
            let call = self.slow_call(sym, args, vals, ret);
            LLVMAddCallSiteAttribute(call, u32::MAX, self.enum_attr("cold"));
            LLVMBuildUnreachable(self.b);
            self.switch_to(cont);
        }
    }

    /// The out-of-line call to runtime function `sym` with already evaluated (scalar) arguments.
    fn slow_call(&mut self, sym: &str, args: &[Ex], vals: &[LLVMValueRef], ret: &MTy) -> LLVMValueRef {
        let ps: Vec<MTy> = args.iter().map(|a| a.ty.clone()).collect();
        let (sig, _, _) = self.c_sig(&ps, ret);
        let f = self.rt_func(sym, &sig);
        let mut vs = vals.to_vec();
        self.build_call(&sig, f, &mut vs)
    }

    /// `auk_arr_len`: a list's length (0 for NULL).
    fn arr_len(&mut self, a: LLVMValueRef) -> LLVMValueRef {
        unsafe {
            let nonnull = LLVMBuildIsNotNull(self.b, a, NONAME);
            let (load, done) = (self.new_block(c"len.load"), self.new_block(c"len"));
            let from = LLVMGetInsertBlock(self.b);
            LLVMBuildCondBr(self.b, self.likely(nonnull), load, done);
            self.switch_to(load);
            let n = self.load_ty(self.t_i64, self.gep(a, ARR_LEN));
            let loaded = LLVMGetInsertBlock(self.b);
            self.br(done);
            self.switch_to(done);
            let phi = LLVMBuildPhi(self.b, self.t_i64, NONAME);
            let mut vs = [LLVMConstInt(self.t_i64, 0, 0), n];
            let mut bs = [from, loaded];
            LLVMAddIncoming(phi, vs.as_mut_ptr(), bs.as_mut_ptr(), 2);
            phi
        }
    }

    /// The address of element `i` (size `size` bytes) of list `a`.
    fn elem_addr(&mut self, a: LLVMValueRef, i: LLVMValueRef, size: LLVMValueRef) -> LLVMValueRef {
        unsafe {
            let data = self.load_ty(self.t_ptr, self.gep(a, ARR_DATA));
            let off = LLVMBuildMul(self.b, i, size, NONAME);
            let mut idx = [off];
            LLVMBuildInBoundsGEP2(self.b, self.t_i8, data, idx.as_mut_ptr(), 1, NONAME)
        }
    }

    /// `auk_retain(p)` / `auk_release(p)` inline: nothing for NULL and immortal objects (a
    /// negative count), the runtime for handles (their heap keeps a ledger), an atomic add or
    /// subtract otherwise; the last release frees the object through the runtime.
    fn rc_update(&mut self, p: LLVMValueRef, retain: bool, args: &[Ex], vals: &[LLVMValueRef], ret: &MTy) {
        let sym = if retain { "auk_retain" } else { "auk_release" };
        unsafe {
            let done = self.new_block(c"rc.done");
            let check = self.new_block(c"rc.check");
            let nonnull = LLVMBuildIsNotNull(self.b, p, NONAME);
            LLVMBuildCondBr(self.b, nonnull, check, done);
            self.switch_to(check);
            let rc = self.load_ty(self.t_i64, p);
            LLVMSetOrdering(rc, LLVMAtomicOrdering::LLVMAtomicOrderingMonotonic);
            LLVMSetAlignment(rc, 8);
            let mortal = LLVMBuildICmp(self.b, LLVMIntPredicate::LLVMIntSGE, rc, LLVMConstInt(self.t_i64, 0, 0), NONAME);
            let kinds = self.new_block(c"rc.kind");
            LLVMBuildCondBr(self.b, self.likely(mortal), kinds, done);
            self.switch_to(kinds);
            let kind = self.load_ty(self.t_i32, self.gep(p, HDR_KIND));
            let rel = LLVMBuildSub(self.b, kind, LLVMConstInt(self.t_i32, HANDLE_FIRST, 0), NONAME);
            let handle = LLVMBuildICmp(self.b, LLVMIntPredicate::LLVMIntULT, rel, LLVMConstInt(self.t_i32, HANDLE_COUNT, 0), NONAME);
            let (slow, fast) = (self.new_block(c"rc.handle"), self.new_block(c"rc.atomic"));
            let not_handle = LLVMBuildNot(self.b, handle, NONAME);
            LLVMBuildCondBr(self.b, self.likely(not_handle), fast, slow);
            self.switch_to(slow);
            self.slow_call(sym, args, vals, ret);
            self.br(done);
            self.switch_to(fast);
            let one = LLVMConstInt(self.t_i64, 1, 0);
            if retain {
                LLVMBuildAtomicRMW(self.b, LLVMAtomicRMWBinOp::LLVMAtomicRMWBinOpAdd, p, one, LLVMAtomicOrdering::LLVMAtomicOrderingMonotonic, 0);
                self.br(done);
            } else {
                let old = LLVMBuildAtomicRMW(self.b, LLVMAtomicRMWBinOp::LLVMAtomicRMWBinOpSub, p, one, LLVMAtomicOrdering::LLVMAtomicOrderingRelease, 0);
                let last = LLVMBuildICmp(self.b, LLVMIntPredicate::LLVMIntEQ, old, one, NONAME);
                let free = self.new_block(c"rc.free");
                LLVMBuildCondBr(self.b, last, free, done);
                self.switch_to(free);
                LLVMBuildFence(self.b, LLVMAtomicOrdering::LLVMAtomicOrderingAcquire, 0, NONAME);
                let ps = [MTy::void_ptr()];
                let (sig, _, _) = self.c_sig(&ps, &MTy::Void);
                let f = self.rt_func("auk__free_last", &sig);
                let mut a = [p];
                self.build_call(&sig, f, &mut a);
                self.br(done);
            }
            self.switch_to(done);
        }
    }
}

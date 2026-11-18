//! Calls to user C functions (`extern fn` with a C prototype, docs/ffi-plan.md): each argument
//! is converted to its C type as `crate::ffi::Conv` says, the C function is called, then
//! out-parameters are written back, temporary C arrays freed, and the result converted to its
//! Auk type (C strings are copied, and freed with the `+free` function when they're owned).

use super::{ArgV, Lower, Val};
use crate::ffi::{CSig, Conv};
use crate::mir::progen::d;
use crate::mir::{BOp, Ex, MTy, Sel, Stmt};
use crate::typed::{FnId, FnKind};
use crate::types::Ty;

/// Work left for after the call.
enum After {
    /// Free a temporary C array.
    Free(Ex),
    /// Copy a C array back into the list variable at the address, then free it.
    ArrBack(Ex, Ex, i64),
    /// Write the C value in the temporary back to the `var` at the address (of Auk type `Ty`).
    Out(Ex, Ex, Conv, Ty),
}

fn int_mty(bytes: u8, signed: bool) -> MTy {
    match (bytes, signed) {
        (1, true) => MTy::I8,
        (1, false) => MTy::U8,
        (2, true) => MTy::I16,
        (2, false) => MTy::U16,
        (4, true) => MTy::I32,
        (4, false) => MTy::U32,
        (_, true) => MTy::I64,
        (_, false) => MTy::U64,
    }
}

/// The machine type a value has on the C side.
fn c_mty(c: &Conv) -> MTy {
    match c {
        Conv::Int { bytes, signed } => int_mty(*bytes, *signed),
        Conv::Bool => MTy::Bool,
        Conv::Float { f32: true } => MTy::F32,
        Conv::Float { f32: false } => MTy::D(Ty::Float),
        Conv::Str { .. } | Conv::OptStr { .. } => MTy::CStr,
        Conv::Unit => MTy::Void,
        Conv::Ptr | Conv::OptPtr | Conv::List { .. } | Conv::Out(_) => MTy::void_ptr(),
    }
}

impl Lower<'_, '_> {
    /// Call the user C function `f`.
    pub(super) fn ffi_call(&mut self, f: FnId, args: Vec<ArgV>, ret: &Ty, loc: Ex) -> Val {
        let tp = self.tp;
        let FnKind::Ffi { sig, convs, .. } = &tp.fns[f].kind else { panic!("ffi_call of a non-C function") };
        let sig: &CSig = sig;
        if !self.g.prog.c_syms.contains(&sig.name) {
            self.g.prog.c_syms.push(sig.name.clone());
        }
        let mut cs = Vec::new();
        let mut after = Vec::new();
        for (a, conv) in args.into_iter().zip(convs) {
            let c = match (a, conv) {
                (ArgV::Addr(p, ty), Conv::List { elem, back: true }) => {
                    let arr = p.clone().deref(d(&ty));
                    let buf = self.f.b.decl_as(MTy::void_ptr(), Ex::rt("auk_ffi_arr_in", vec![arr, Ex::int_as(*elem as i64, MTy::I32)], MTy::void_ptr()));
                    after.push(After::ArrBack(p, buf.clone(), *elem as i64));
                    buf
                }
                (ArgV::Addr(p, ty), Conv::Out(inner)) => {
                    let init = match &**inner {
                        Conv::OptStr { .. } => Ex::zero(MTy::CStr),
                        _ => {
                            let cur = Val::plain(p.clone().deref(d(&ty)), ty.clone());
                            self.ffi_in(&cur, inner)
                        }
                    };
                    let tmp = self.f.b.decl_as(c_mty(inner), init);
                    after.push(After::Out(p, tmp.clone(), (**inner).clone(), ty));
                    tmp.addr().cast(MTy::void_ptr())
                }
                (ArgV::Addr(p, ty), conv) => {
                    // not reached: a `var` parameter is always an out-parameter or a list
                    let cur = Val::plain(p.deref(d(&ty)), ty);
                    self.ffi_in(&cur, conv)
                }
                (ArgV::Val(v), Conv::List { elem, .. }) => {
                    let x = self.val_as(&v, &v.ty.clone());
                    let buf = self.f.b.decl_as(MTy::void_ptr(), Ex::rt("auk_ffi_arr_in", vec![x, Ex::int_as(*elem as i64, MTy::I32)], MTy::void_ptr()));
                    after.push(After::Free(buf.clone()));
                    buf
                }
                (ArgV::Val(v), Conv::Out(inner)) => {
                    // a function value can't have `var` parameters; pass a scratch slot
                    let tmp = self.f.b.decl_as(c_mty(inner), Ex::zero(c_mty(inner)));
                    let _ = v;
                    tmp.addr().cast(MTy::void_ptr())
                }
                (ArgV::Val(v), conv) => self.ffi_in(&v, conv),
            };
            cs.push(c);
        }
        let rconv = convs.last().expect("result conversion");
        let call = Ex::rt(&sig.name, cs, c_mty(rconv));
        let raw = if *rconv == Conv::Unit {
            self.do_(call);
            None
        } else {
            Some(self.f.b.decl_as(c_mty(rconv), call))
        };
        // the result first (a C string is copied before anything can free it)
        let out = match raw {
            None => None,
            Some(r) => Some(self.ffi_out(r, rconv, ret, &sig.name, sig.free.as_deref(), &loc)),
        };
        for a in after {
            match a {
                After::Free(buf) => self.do_(Ex::rt("auk_ffi_free", vec![buf], MTy::Void)),
                After::ArrBack(p, buf, kind) => self.do_(Ex::rt("auk_ffi_arr_out", vec![p.cast(MTy::void_ptr()), buf, Ex::int_as(kind, MTy::I32)], MTy::Void)),
                After::Out(p, tmp, inner, ty) => {
                    let place = p.deref(d(&ty));
                    let v = self.ffi_out_ex(tmp, &inner, &ty, &sig.name, sig.free.as_deref(), &loc);
                    let n = self.decl(&ty, v);
                    if let Some(r) = self.g.release(&ty, &place) {
                        self.emit(r);
                    }
                    self.set(place, n);
                }
            }
        }
        match out {
            None if *ret == Ty::Never => Val::never(),
            None => Val::unit(),
            Some(v) => v,
        }
    }

    /// An Auk value as its C argument.
    fn ffi_in(&mut self, v: &Val, conv: &Conv) -> Ex {
        let ty = v.ty.clone();
        let x = self.val_as(v, &ty);
        let null = || Ex::zero(MTy::void_ptr());
        match conv {
            Conv::Int { .. } | Conv::Bool | Conv::Float { .. } => x.cast(c_mty(conv)),
            Conv::Str { .. } => Ex::rt("auk_str_cstr", vec![x], MTy::CStr),
            Conv::OptStr { .. } => {
                let o = self.lvalue(v, &ty);
                let s = Ex::rt("auk_str_cstr", vec![self.fld(&o, Sel::F(1))], MTy::CStr);
                Ex::cond(self.fld(&o, Sel::F(0)), s, Ex::zero(MTy::CStr))
            }
            Conv::Ptr => x.cast(MTy::void_ptr()),
            Conv::OptPtr => {
                let o = self.lvalue(v, &ty);
                Ex::cond(self.fld(&o, Sel::F(0)), self.fld(&o, Sel::F(1)).cast(MTy::void_ptr()), null())
            }
            Conv::Unit | Conv::List { .. } | Conv::Out(_) => null(),
        }
    }

    /// The C value in variable `r` as an Auk value of type `ty` (an owned temporary).
    fn ffi_out(&mut self, r: Ex, conv: &Conv, ty: &Ty, name: &str, free: Option<&str>, loc: &Ex) -> Val {
        let e = self.ffi_out_ex(r, conv, ty, name, free, loc);
        self.tmp(ty, e)
    }

    /// The C value in variable `r` converted to Auk type `ty` (owned). An owned C string is
    /// freed here, after its copy.
    fn ffi_out_ex(&mut self, r: Ex, conv: &Conv, ty: &Ty, name: &str, free: Option<&str>, loc: &Ex) -> Ex {
        let nonnull = |r: &Ex| Ex::bin(BOp::Ne, r.clone().cast(MTy::void_ptr()), Ex::zero(MTy::void_ptr()));
        let e = match conv {
            Conv::Int { .. } | Conv::Bool | Conv::Float { .. } | Conv::Ptr => return r.cast(d(ty)),
            Conv::OptPtr => {
                let Ty::Opt(inner) = ty else { panic!("ffi: OptPtr of a non-optional") };
                return Ex::agg(d(ty), vec![(Sel::F(0), nonnull(&r).cast(MTy::Bool)), (Sel::F(1), r.cast(d(inner)))]);
            }
            Conv::Str { .. } => Ex::rt("auk_ffi_str", vec![r.clone(), Ex::cstr(name), loc.clone()], MTy::D(Ty::Str)),
            Conv::OptStr { .. } => {
                let s = Ex::rt("auk_ffi_str_or_null", vec![r.clone()], MTy::D(Ty::Str));
                Ex::agg(d(ty), vec![(Sel::F(0), nonnull(&r).cast(MTy::Bool)), (Sel::F(1), s)])
            }
            Conv::Unit | Conv::List { .. } | Conv::Out(_) => return Ex::zero(d(ty)),
        };
        let v = self.decl(ty, e);
        if let (Conv::Str { owned: true } | Conv::OptStr { owned: true }, Some(f)) = (conv, free) {
            self.open_if(nonnull(&r));
            self.emit(Stmt::Do(Ex::rt(f, vec![r.cast(MTy::void_ptr())], MTy::Void)));
            self.close();
        }
        v
    }
}

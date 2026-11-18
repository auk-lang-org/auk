//! Memory layout of MIR types and the C ABI classification, shared by the back ends.
//!
//! Every MIR type is either a *scalar* (`Sc`: one machine value) or an *aggregate* living in
//! memory. Layouts follow C's struct rules: they must match the runtime's `#[repr(C)]` types.

use std::cell::RefCell;
use std::collections::HashMap;

use super::types::TyInfo;
use super::{AggDef, MTy, Rt, Sel};
use crate::types::Ty;

/// A scalar machine type.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Sc {
    I8,
    I32,
    I64,
    F64,
    Ptr,
}

impl Sc {
    pub fn bytes(self) -> u32 {
        match self {
            Sc::I8 => 1,
            Sc::I32 => 4,
            Sc::I64 | Sc::F64 | Sc::Ptr => 8,
        }
    }
    pub fn bits(self) -> u32 {
        self.bytes() * 8
    }
    pub fn is_float(self) -> bool {
        self == Sc::F64
    }
}

// ---- layout ----------------------------------------------------------------------------

#[derive(Clone, Copy, Debug)]
pub struct Lay {
    pub size: u32,
    pub align: u32,
}

pub fn align_up(x: u32, a: u32) -> u32 {
    x.div_ceil(a) * a
}

/// A type's layout, its member offsets (struct-like) and per-variant field offsets within the
/// union (enums; the union starts at the first member offset).
type LayInfo = (Lay, Vec<u32>, Vec<Vec<u32>>);

/// Sizes, alignments and member offsets of MIR types.
pub struct Layouts<'p, 'a> {
    pub info: &'p TyInfo<'a>,
    pub aggs: &'p [AggDef],
    memo: RefCell<HashMap<MTy, LayInfo>>,
}

impl<'p, 'a> Layouts<'p, 'a> {
    pub fn new(info: &'p TyInfo<'a>, aggs: &'p [AggDef]) -> Self {
        Layouts { info, aggs, memo: RefCell::new(HashMap::new()) }
    }

    /// The scalar type of `t`, or None for an aggregate (or `Void`).
    pub fn scalar(&self, t: &MTy) -> Option<Sc> {
        Some(match t {
            MTy::Void => return None,
            MTy::Bool => Sc::I8,
            MTy::I32 | MTy::U32 => Sc::I32,
            MTy::I64 | MTy::U64 => Sc::I64,
            MTy::Ptr(_) | MTy::CStr | MTy::Code => Sc::Ptr,
            MTy::D(t) => match t {
                Ty::Int => Sc::I64,
                Ty::Float => Sc::F64,
                Ty::Bool | Ty::Never => Sc::I8,
                Ty::Char => Sc::I32,
                t if t.is_unit() => Sc::I8,
                t if self.info.is_ptr(t) => Sc::Ptr,
                _ => return None,
            },
            MTy::Agg(_) | MTy::Rt(_) => return None,
        })
    }

    pub fn is_agg(&self, t: &MTy) -> bool {
        !matches!(t, MTy::Void) && self.scalar(t).is_none()
    }

    /// Is the scalar signed (sign-extended when widened)?
    pub fn signed(t: &MTy) -> bool {
        matches!(t, MTy::I32 | MTy::I64 | MTy::D(Ty::Int))
    }

    /// The members of a struct-like aggregate (not enums).
    pub fn members(&self, t: &MTy) -> Vec<MTy> {
        let info = self.info;
        match t {
            MTy::Agg(a) => {
                let fs = self.aggs[*a as usize].fields.clone();
                if fs.is_empty() { vec![MTy::I32] } else { fs }
            }
            // DuckStrBuf: buf, len, cap, then DUCK_SB_SMALL (40) inline bytes
            MTy::Rt(Rt::StrBuf) => vec![MTy::void_ptr(), MTy::I64, MTy::I64, MTy::I64, MTy::I64, MTy::I64, MTy::I64, MTy::I64],
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
                _ => panic!("layout: no members for {}", info.show_ty(d)),
            },
            _ => panic!("layout: no members for {t:?}"),
        }
    }

    pub fn is_enum_like(&self, t: &MTy) -> bool {
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

    pub fn lay(&self, t: &MTy) -> Lay {
        self.get(t).0
    }

    /// The offset of member `s` in a value of type `t`.
    pub fn offset(&self, t: &MTy, s: Sel) -> u32 {
        let (_, offs, voffs) = self.get(t);
        match s {
            Sel::Tag => 0,
            Sel::F(i) => offs[i as usize],
            Sel::V(vi, fi) => offs[0] + voffs[vi as usize][fi as usize],
        }
    }

    /// The scalar leaves of a type: (offset, type), unions included (for C ABI classification).
    fn leaves(&self, t: &MTy, base: u32, out: &mut Vec<(u32, Sc)>) {
        if let Some(s) = self.scalar(t) {
            out.push((base, s));
            return;
        }
        if self.is_enum_like(t) {
            out.push((base, Sc::I32));
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
pub enum CPass {
    None,
    /// One scalar.
    Scalar(Sc),
    /// An aggregate of at most 16 bytes as register-sized words (8 bytes each; the last may be
    /// partial), or an AArch64 floating-point aggregate as one double per member.
    Words(Vec<Sc>),
    /// A result returned through the struct-return pointer.
    Sret,
}

fn is_x86() -> bool {
    cfg!(target_arch = "x86_64")
}

impl Layouts<'_, '_> {
    pub fn c_pass(&self, t: &MTy) -> CPass {
        if let MTy::Void = t {
            return CPass::None;
        }
        if let Some(s) = self.scalar(t) {
            return CPass::Scalar(s);
        }
        let l = self.lay(t);
        let mut leaves = Vec::new();
        self.leaves(t, 0, &mut leaves);
        // AArch64: a homogeneous floating-point aggregate (1-4 doubles, no other members) travels
        // in float registers, one per member, whatever its size
        if cfg!(target_arch = "aarch64") && !leaves.is_empty() && leaves.len() <= 4 && leaves.iter().all(|(_, s)| *s == Sc::F64) && l.size == 8 * leaves.len() as u32 {
            return CPass::Words(vec![Sc::F64; leaves.len()]);
        }
        if l.size > 16 {
            return CPass::Sret;
        }
        let n = l.size.div_ceil(8);
        let words = (0..n)
            .map(|k| {
                let (lo, hi) = (k * 8, k * 8 + 8);
                let inside: Vec<_> = leaves.iter().filter(|(o, ty)| *o < hi && o + ty.bytes() > lo).collect();
                if is_x86() && !inside.is_empty() && inside.iter().all(|(_, ty)| *ty == Sc::F64) { Sc::F64 } else { Sc::I64 }
            })
            .collect();
        CPass::Words(words)
    }

    /// How each parameter and the result of a C function cross the call boundary.
    pub fn c_sig(&self, params: &[MTy], ret: &MTy) -> (Vec<CPass>, CPass) {
        (params.iter().map(|p| self.c_pass(p)).collect(), self.c_pass(ret))
    }
}

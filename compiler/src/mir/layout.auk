/// Memory layout of MIR types and the C ABI classification, shared by the back ends
/// (src/mir/layout.rs).
///
/// Every MIR type is either a *scalar* (`Sc`: one machine value) or an *aggregate* living in
/// memory. Layouts follow C's struct rules: they must match the runtime's `#[repr(C)]` types.
/// Rust memoizes through a `RefCell`; here the memo is a field, so the functions that fill it
/// take `var Layouts`. Rust's `cfg!(target_arch)` is `Layouts.arch` (from LLVM's default target
/// triple: `"aarch64"` or `"x86_64"`).

/// A scalar machine type.
pub enum Sc { I8, I16, I32, I64, F64, F32, Ptr }

pub fn bytes(s: Sc): int = match s {
  I8 => 1
  I16 => 2
  I32 | F32 => 4
  I64 | F64 | Ptr => 8
}

pub fn bits(s: Sc): int = bytes(s) * 8

pub fn is_float(s: Sc): bool = s == Sc.F64 || s == Sc.F32

// ---- layout ----------------------------------------------------------------------------

pub struct Lay { size: int, align: int }

pub fn align_up(x: int, a: int): int = (x + a - 1) / a * a

/// A type's layout, its member offsets (struct-like) and per-variant field offsets within the
/// union (enums; the union starts at the first member offset).
struct LayInfo { lay: Lay, offs: [int], voffs: [[int]] }

/// Sizes, alignments and member offsets of MIR types.
pub struct Layouts {
  info: mir.types.TyInfo,
  aggs: [mir.AggDef],
  memo: {mir.MTy: LayInfo},
  /// `"aarch64"` or `"x86_64"` (the C ABI's rules differ).
  arch: str,
}

pub fn new(info: mir.types.TyInfo, aggs: [mir.AggDef], arch: str): Layouts =
  Layouts { info, aggs, memo: {}, arch }

/// The architecture of an LLVM target triple (`arm64-apple-darwin25`, `x86_64-pc-linux-gnu`).
pub fn arch_of(triple: str): str = if triple.starts_with("x86_64") { "x86_64" } else { "aarch64" }

/// The scalar type of `t`, or none for an aggregate (or `Void`).
pub fn scalar(l: Layouts, t: mir.MTy): Sc? = match t {
  Void => none
  Bool | I8 | U8 => Sc.I8
  I16 | U16 => Sc.I16
  F32 => Sc.F32
  I32 | U32 => Sc.I32
  I64 | U64 => Sc.I64
  Ptr(_) | CStr | Code => Sc.Ptr
  D(d) => match d {
    Int => Sc.I64
    Float => Sc.F64
    Bool | Never => Sc.I8
    Char => Sc.I32
    Fixed(k) => match k {
      I8 | U8 => Sc.I8
      I16 | U16 => Sc.I16
      I32 | U32 => Sc.I32
      F32 => Sc.F32
      _ => Sc.I64
    }
    Ptr(_) | CFn(_, _) => Sc.Ptr
    d when types.is_unit(d) => Sc.I8
    d when mir.types.is_ptr(l.info, d) => Sc.Ptr
    _ => none
  }
  Agg(_) | Rt(_) => none
}

pub fn is_agg(l: Layouts, t: mir.MTy): bool = t != mir.MTy.Void && scalar(l, t) == none

/// Is the scalar signed (sign-extended when widened)?
pub fn signed(t: mir.MTy): bool = match t {
  I8 | I16 | I32 | I64 => true
  D(Int) => true
  D(Fixed(k)) => types.fx_signed(k)
  _ => false
}

/// An unsigned type of the runtime's dialect (fixed-width, or a raw pointer)?
pub fn raw_unsigned(t: mir.MTy): bool = match t {
  D(Fixed(k)) => !types.fx_signed(k) && k != types.Fx.F32
  D(Ptr(_)) | D(CFn(_, _)) => true
  _ => false
}

/// The members of a struct-like aggregate (not enums).
pub fn members(l: Layouts, t: mir.MTy): [mir.MTy] {
  let info = l.info
  match t {
    Agg(a) => {
      let fs = l.aggs[a].fields
      if fs.len() == 0 { [mir.MTy.I32] } else { fs }
    }
    // AukStrBuf: buf, len, cap, then AUK_SB_SMALL (40) inline bytes
    Rt(StrBuf) => [mir.void_ptr()] + rep(mir.MTy.I64, 7)
    Rt(Obj) => [mir.MTy.I64, mir.MTy.U32, mir.MTy.Code, mir.MTy.Code]
    Rt(ElemOps) => [mir.MTy.U64] + rep(mir.MTy.Code, 7)
    D(d) => match d {
      Tuple(ts) => ts.map(x => mir.MTy.D(x))
      Opt(x) => [mir.MTy.Bool, mir.MTy.D(x)]
      Res(x, _) => [mir.MTy.Bool, mir.MTy.D(x), mir.void_ptr()]
      Fn(_, _) => [mir.MTy.Code, mir.obj_ptr()]
      Any(_) => [mir.obj_ptr(), mir.void_ptr()]
      Array(x, n) => rep(mir.MTy.D(x), max(n, 0))
      _ when mir.types.is_struct(info, d) => {
        let n = mir.types.struct_layout(info, d).len()
        if n == 0 {
          [mir.MTy.Bool]
        } else {
          (0..n).map(i => mir.types.member_ty(info, t, mir.Sel.F(i), l.aggs))
        }
      }
      _ => mir.bug("layout: no members for {mir.types.show_ty(info, d)}")
    }
    _ => mir.bug("layout: no members for {t}")
  }
}

pub fn is_enum_like(l: Layouts, t: mir.MTy): bool = match t {
  D(d) => mir.types.is_value(l.info, d) ||
    (d is types.Ty.Named(_, _)) &&
      !mir.types.is_struct(l.info, d) &&
      !mir.types.is_opaque(l.info, d)
  _ => false
}

/// Layout, member offsets (struct-like), and per-variant field offsets within the union
/// (enums; the union starts at `offs[0]`).
fn get(l: var Layouts, t: mir.MTy): LayInfo {
  match l.memo.get(t) {
    some(x) => return x
    none => {}
  }
  let r = match scalar(l, t) {
    some(s) => {
      let n = bytes(s)
      LayInfo { lay: Lay { size: n, align: n }, offs: [], voffs: [] }
    }
    none => if is_enum_like(l, t) {
      let d = match t {
        D(d) => d
        _ => mir.bug("unreachable")
      }
      let variants = mir.types.enum_layout(l.info, d)
      var ualign = 1
      var usize = 0
      var voffs: [[int]] = []
      for vi, fs in variants {
        let ms = (0..fs.len()).map(fi => mir.types.member_ty(l.info, t, mir.Sel.V(vi, fi), l.aggs))
        let (lay, offs) = struct_of(&l, ms)
        if ms.len() > 0 {
          ualign = max(ualign, lay.align)
          usize = max(usize, lay.size)
        }
        voffs.push(offs)
      }
      if usize == 0 {
        LayInfo { lay: Lay { size: 4, align: 4 }, offs: [4], voffs }
      } else {
        let uoff = align_up(4, ualign)
        let a = max(ualign, 4)
        LayInfo { lay: Lay { size: align_up(uoff + usize, a), align: a }, offs: [uoff], voffs }
      }
    } else {
      let ms = members(l, t)
      let (lay0, offs0) = struct_of(&l, ms)
      var lay = lay0
      var offs = offs0
      match t {
        // the runtime's dialect: a C array (a flexible one has no size), a `raw union`
        D(Array(x, n)) => {
          let e = get(&l, mir.MTy.D(x)).lay
          lay = Lay { size: max(n, 0) * e.size, align: e.align }
        }
        D(Named(d, _)) when types.is_union(l.info.defs, d) => {
          var size = 0
          var align = 1
          for m in ms {
            let x = get(&l, m).lay
            size = max(size, x.size)
            align = max(align, x.align)
          }
          lay = Lay { size: align_up(max(size, 1), align), align }
          offs = ms.map(_ => 0)
        }
        _ => {}
      }
      LayInfo { lay, offs, voffs: [] }
    }
  }
  l.memo[t] = r
  r
}

fn struct_of(l: var Layouts, ms: [mir.MTy]): (Lay, [int]) {
  var off = 0
  var align = 1
  var offs: [int] = []
  for m in ms {
    let x = get(&l, m).lay
    off = align_up(off, x.align)
    offs.push(off)
    off += x.size
    align = max(align, x.align)
  }
  let size = max(off, if ms.len() == 0 { 1 } else { 0 })
  (Lay { size: align_up(size, align), align }, offs)
}

pub fn lay(l: var Layouts, t: mir.MTy): Lay = get(&l, t).lay

/// The offset of member `s` in a value of type `t`.
pub fn offset(l: var Layouts, t: mir.MTy, s: mir.Sel): int {
  let x = get(&l, t)
  match s {
    Tag => 0
    F(i) => x.offs[i]
    V(vi, fi) => x.offs[0] + x.voffs[vi][fi]
  }
}

/// The scalar leaves of a type: (offset, type), unions included (for C ABI classification).
fn leaves(l: var Layouts, t: mir.MTy, base: int, out: var [(int, Sc)]) {
  match scalar(l, t) {
    some(s) => {
      out.push((base, s))
      return
    }
    none => {}
  }
  if is_enum_like(l, t) {
    out.push((base, Sc.I32))
    let d = match t {
      D(d) => d
      _ => mir.bug("unreachable")
    }
    for vi, fs in mir.types.enum_layout(l.info, d) {
      for fi in 0..fs.len() {
        let s = mir.Sel.V(vi, fi)
        let mt = mir.types.member_ty(l.info, t, s, l.aggs)
        let at = base + offset(&l, t, s)
        leaves(&l, mt, at, &out)
      }
    }
    return
  }
  for i, m in members(l, t) {
    let at = base + offset(&l, t, mir.Sel.F(i))
    leaves(&l, m, at, &out)
  }
}

// ---- the C ABI ------------------------------------------------------------------------

/// How a value crosses a C call boundary (what clang emits for the same C type).
pub enum CPass {
  Nothing,
  /// One scalar.
  Scalar(s: Sc),
  /// An aggregate of at most 16 bytes as eightbytes (word `k` at offset `8 * k`; the last may
  /// be partial). On x86-64 an eightbyte of floats only (SysV class SSE) is `F64`, or `F32`
  /// when it holds one `f32` and then padding: two `f32`s travel as the bits of a double,
  /// which is the register (and stack slot) clang's `<2 x float>` uses. AArch64 passes two
  /// words as `[2 x i64]` (one block: both in registers or both on the stack).
  Words(ws: [Sc]),
  /// An AArch64 homogeneous floating-point aggregate: `n` (1-4) members of `s` (`F32` or
  /// `F64`, no padding) in consecutive SIMD registers, passed as `[n x s]`, returned as a
  /// struct of them.
  Hfa(s: Sc, n: int),
  /// A result returned through the struct-return pointer.
  Sret,
  /// An argument in memory: AArch64 passes a pointer to a copy (an aggregate over 16 bytes),
  /// x86-64 a `byval` copy on the stack (over 16 bytes, or not enough registers left for all
  /// of its eightbytes).
  Mem,
}

pub fn c_pass(l: var Layouts, t: mir.MTy): CPass {
  if t == mir.MTy.Void { return CPass.Nothing }
  match scalar(l, t) {
    some(s) => return CPass.Scalar(s)
    none => {}
  }
  let x = lay(&l, t)
  var lv: [(int, Sc)] = []
  leaves(&l, t, 0, &lv)
  // AArch64: a homogeneous floating-point aggregate (1-4 members of one float type, no
  // other members or padding) travels in float registers, whatever its size
  if l.arch == "aarch64" && lv.len() > 0 && lv.len() <= 4 {
    let s = lv[0].1
    if is_float(s) && lv.all(p => p.1 == s) && x.size == bytes(s) * lv.len() {
      return CPass.Hfa(s, lv.len())
    }
  }
  if x.size > 16 { return CPass.Sret }
  let n = (x.size + 7) / 8
  let x86 = l.arch == "x86_64"
  CPass.Words(
    (0..n).map(k => {
      let (lo, hi) = (k * 8, k * 8 + 8)
      let inside = lv.filter(p => p.0 < hi && p.0 + bytes(p.1) > lo)
      if x86 && inside.len() > 0 && inside.all(p => is_float(p.1)) {
        // SSE: `float` when only the low half holds data, else the whole eightbyte
        if inside.all(p => p.0 + bytes(p.1) <= lo + 4) { Sc.F32 } else { Sc.F64 }
      } else {
        Sc.I64
      }
    }),
  )
}

/// How each parameter and the result of a C function cross the call boundary. An aggregate
/// parameter over 16 bytes is `Mem`; on x86-64 (SysV) so is one whose eightbytes don't all
/// fit in the registers left (6 general, 8 SSE; the struct-return pointer takes one general
/// register), as clang decides it.
pub fn c_sig(l: var Layouts, params: [mir.MTy], ret: mir.MTy): ([CPass], CPass) {
  let rp = c_pass(&l, ret)
  let x86 = l.arch == "x86_64"
  var gp = if rp == CPass.Sret { 5 } else { 6 }
  var sse = 8
  var ps: [CPass] = []
  for p in params {
    let c = c_pass(&l, p)
    let c2 = match c {
      Sret => CPass.Mem
      Scalar(s) => {
        if x86 {
          if is_float(s) {
            if sse > 0 { sse -= 1 }
          } else if gp > 0 {
            gp -= 1
          }
        }
        c
      }
      Words(ws) => {
        if x86 {
          let nf = ws.filter(w => is_float(w)).len()
          let ni = ws.len() - nf
          if nf <= sse && ni <= gp {
            sse -= nf
            gp -= ni
            c
          } else {
            CPass.Mem
          }
        } else {
          c
        }
      }
      _ => c
    }
    ps.push(c2)
  }
  (ps, rp)
}

fn rep(t: mir.MTy, n: int): [mir.MTy] = (0..n).map(_ => t)

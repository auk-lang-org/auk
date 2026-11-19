/// MIR → LLVM IR (src/mir/llvm/codegen.rs).
///
/// # Representation
/// Every MIR variable is an `alloca` in the function's entry block (LLVM's SROA/mem2reg turn
/// scalars back into registers), except aggregate parameters that the function never writes:
/// those are used in place through the incoming pointer. Aggregates are untyped memory: an
/// aggregate is `[size x i8]`, members are reached with byte-offset GEPs (`mir.layout.offset`),
/// and copies are `llvm.memcpy` with a constant size. LLVM never sees a struct type for an Auk
/// value, so the C layout is decided only in `mir.layout`.
///
/// # Calling conventions
/// - `Abi.Auk` (called only by generated code): aggregates by pointer, an aggregate result
///   through a leading `noalias` result pointer. An aggregate parameter the callee never writes
///   or takes the address of is marked `noalias readonly` and read in place; the caller then
///   passes a pointer to memory nothing else can reach during the call (an unaddressed local or a
///   fresh temporary). A written one is copied on entry.
/// - `Abi.C` and runtime calls: the platform C ABI as classified by `mir.layout.c_pass`.
///
/// Rust's `Gen` methods are functions taking `var Gen`; its null `LLVMValueRef`s are `?`s or a
/// placeholder (`vars` of in-place parameters until they are set). The hot runtime calls compiled
/// inline are in `intrin` (intrin.rs).

/// Runtime functions that never return (marked `noreturn cold`).
let NORETURN = [
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
]

/// What to export (external linkage) besides nothing: everything else is internal.
pub struct Exports {
  /// The entry point's symbol (`main` for executables, `dk_entry` in memory).
  entry: str,
  /// Also export these functions by MIR name (JIT lookups: `dk_init`).
  names: [str],
  /// Export every function (`auk run --live` looks them all up by name).
  all: bool,
}

/// A function type and the attributes its declaration and every call carry.
pub struct Sig {
  ty: llvm.Type,
  /// (attribute index, attribute): 0 = result, i + 1 = parameter i.
  attrs: [(int, llvm.Attribute)],
}

/// A value: a scalar, an aggregate's address, or nothing.
pub enum V { S(v: llvm.Value), M(a: llvm.Value), Nil }

pub struct Gen {
  cx: llvm.Context,
  m: llvm.Module,
  b: llvm.Builder,
  /// A second builder for entry-block allocas.
  ab: llvm.Builder,
  lay: mir.layout.Layouts,
  prog: mir.Program,
  funcs: [(llvm.Value, Sig)],
  globals: [llvm.Value],
  rt_funcs: {str: llvm.Value},
  rt_data: {str: llvm.Value},
  cstrs: {[int]: llvm.Value},
  /// `auk run --live`: calls to these functions load their target from the live table.
  live: (int, {int: int})?,
  /// Which aggregate parameters each Auk function reads in place (never written).
  inplace: [[bool]],
  /// Compile the hot runtime calls inline (`intrin`; every level but O0).
  inline_rt: bool,
  /// The element size of the `auk_arr_at` call being compiled, when its caller knows it.
  elem_hint: int?,
  /// Debug info (`auk build -g`), and the current function's subprogram.
  debug: dwarf.Debug,
  sp: llvm.Metadata?,
  // per function
  fi: int,
  fv: llvm.Value,
  vars: [llvm.Value],
  /// Variables whose address is taken (their memory must be private to them).
  addressed: [bool],
  sret: llvm.Value?,
  loops: [(llvm.BasicBlock, llvm.BasicBlock)],
  labels: {int: llvm.BasicBlock},
  terminated: bool,
  // types
  t_i1: llvm.Type,
  t_i8: llvm.Type,
  t_i32: llvm.Type,
  t_i64: llvm.Type,
  t_f64: llvm.Type,
  t_i16: llvm.Type,
  t_f32: llvm.Type,
  t_ptr: llvm.Type,
  t_void: llvm.Type,
}

fn attr_kind(name: str): int uses ffi = llvm.ir.get_enum_attribute_kind_for_name(name)

/// Variables written in `ss`: assigned after their declaration, or whose address is taken
/// (`addr`). Parameters are "declared" on entry, so any `Set` of one counts.
fn writes(ss: [mir.Stmt], set: var [bool], addr: var [bool]) {
  for s in ss {
    match s {
      Let(_, e) | Do(e) | Ret(some(e)) => writes_ex(e, &addr)
      Set(p, e) => {
        var b = p
        while b.k is mir.K.Field(_, _) {
          b = match b.k {
            Field(x, _) => x
            _ => b
          }
        }
        match b.k {
          Var(v) => set[v] = true
          _ => {}
        }
        writes_ex(p, &addr)
        writes_ex(e, &addr)
      }
      If(c, a, b) => {
        writes_ex(c, &addr)
        writes(a, &set, &addr)
        writes(b, &set, &addr)
      }
      Loop(a, b) => {
        writes(a, &set, &addr)
        writes(b, &set, &addr)
      }
      _ => {}
    }
  }
}

fn writes_ex(e: mir.Ex, addr: var [bool]) {
  match e.k {
    Addr(p) => {
      var b = p
      while b.k is mir.K.Field(_, _) {
        b = match b.k {
          Field(x, _) => x
          _ => b
        }
      }
      match b.k {
        Var(v) => addr[v] = true
        _ => {}
      }
    }
    _ => {}
  }
  match e.k {
    Field(x, _) | Deref(x) | Addr(x) | Un(_, x) | Cast(x) | RtField(x, _) => writes_ex(x, &addr)
    Bin(_, a, b) | Elem(a, b) => {
      writes_ex(a, &addr)
      writes_ex(b, &addr)
    }
    And(xs) => for x in xs { writes_ex(x, &addr) }
    Call(c, args) => {
      match c {
        Indirect(x, _) | CPtr(x) => writes_ex(x, &addr)
        _ => {}
      }
      for x in args { writes_ex(x, &addr) }
    }
    Agg(ms) => for (_, x) in ms { writes_ex(x, &addr) }
    Cond(a, b, c) => {
      writes_ex(a, &addr)
      writes_ex(b, &addr)
      writes_ex(c, &addr)
    }
    _ => {}
  }
}

/// A generator for `prog` writing into a new module `name` in context `cx`.
pub fn new(
  cx: llvm.Context,
  name: str,
  prog: mir.Program,
  info: mir.types.TyInfo,
  live: (int, {int: int})?,
  arch: str,
): Gen uses fs, ffi {
  let m = llvm.ir.module_create_with_name_in_context(name, cx)
  let b = llvm.builder.create_builder_in_context(cx)
  let ab = llvm.builder.create_builder_in_context(cx)
  let lay = mir.layout.new(info, prog.aggs, arch)
  let debug = dwarf.new(cx, m, prog)
  let t_i8 = llvm.ir.int8_type_in_context(cx)
  Gen {
    cx,
    m,
    b,
    ab,
    lay,
    prog,
    funcs: [],
    globals: [],
    rt_funcs: {},
    rt_data: {},
    cstrs: {},
    live,
    inplace: [],
    inline_rt: false,
    elem_hint: none,
    debug,
    sp: none,
    fi: 0,
    fv: llvm.values.const_null(t_i8),
    vars: [],
    addressed: [],
    sret: none,
    loops: [],
    labels: {},
    terminated: false,
    t_i1: llvm.ir.int1_type_in_context(cx),
    t_i8,
    t_i32: llvm.ir.int32_type_in_context(cx),
    t_i64: llvm.ir.int64_type_in_context(cx),
    t_f64: llvm.ir.double_type_in_context(cx),
    t_i16: llvm.ir.int16_type_in_context(cx),
    t_f32: llvm.ir.float_type_in_context(cx),
    t_ptr: llvm.ir.pointer_type_in_context(cx, 0),
    t_void: llvm.ir.void_type_in_context(cx),
  }
}

/// Dispose of the builders (Rust's `Drop`); the module stays.
pub fn dispose(g: Gen) uses ffi {
  llvm.builder.dispose_builder(g.b)
  llvm.builder.dispose_builder(g.ab)
}

// ---- layouts ----

pub fn lay(g: var Gen, t: mir.MTy): mir.layout.Lay = mir.layout.lay(&g.lay, t)

pub fn offset(g: var Gen, t: mir.MTy, s: mir.Sel): int = mir.layout.offset(&g.lay, t, s)

pub fn is_agg(g: Gen, t: mir.MTy): bool = mir.layout.is_agg(g.lay, t)

// ---- types and signatures ----

pub fn lt(g: Gen, s: mir.layout.Sc): llvm.Type = match s {
  I8 => g.t_i8
  I16 => g.t_i16
  F32 => g.t_f32
  I32 => g.t_i32
  I64 => g.t_i64
  F64 => g.t_f64
  Ptr => g.t_ptr
}

pub fn scalar(g: Gen, t: mir.MTy): llvm.Type? = match mir.layout.scalar(g.lay, t) {
  some(s) => lt(g, s)
  none => none
}

fn bytes_ty(g: Gen, n: int): llvm.Type uses ffi = llvm.ir.array_type2(g.t_i8, n)

pub fn enum_attr(g: Gen, name: str): llvm.Attribute uses ffi =
  llvm.ir.create_enum_attribute(g.cx, attr_kind(name), 0)

fn ext_attr(g: Gen, t: mir.MTy, s: mir.layout.Sc): llvm.Attribute? uses ffi {
  if mir.layout.bits(s) < 64 && !mir.layout.is_float(s) {
    return enum_attr(g, if mir.layout.signed(t) { "signext" } else { "zeroext" })
  }
  none
}

/// The LLVM type of a C result passed as words: one word, or a literal struct of them.
fn words_ty(g: Gen, ws: [mir.layout.Sc]): llvm.Type uses ffi {
  if ws.len() == 1 { return lt(g, ws[0]) }
  llvm.ir.struct_type_in_context(g.cx, ws.map(w => lt(g, w)), 0)
}

/// The LLVM type of a C result of type `rp` (`Words` or `Hfa`; others are void).
fn c_ret_ty(g: Gen, rp: mir.layout.CPass): llvm.Type uses ffi = match rp {
  Words(ws) => words_ty(g, ws)
  Hfa(s, n) => llvm.ir.struct_type_in_context(g.cx, (0..n).map(_ => lt(g, s)), 0)
  Scalar(s) => lt(g, s)
  _ => g.t_void
}

/// The LLVM parameters of an aggregate argument passed as `c` (`Words` or `Hfa`): x86-64
/// passes each word on its own, AArch64 one block (clang's `[2 x i64]`, `[n x float]`).
fn c_arg_tys(g: Gen, c: mir.layout.CPass): [llvm.Type] uses ffi = match c {
  Words(ws) => if g.lay.arch == "aarch64" && ws.len() > 1 {
    [llvm.ir.array_type2(g.t_i64, ws.len())]
  } else {
    ws.map(w => lt(g, w))
  }
  Hfa(s, n) => [llvm.ir.array_type2(lt(g, s), n)]
  _ => []
}

/// The byte offset of part `k` of a C aggregate passed as `c` (`Words` or `Hfa`).
fn c_part_off(c: mir.layout.CPass, k: int): int = match c {
  Hfa(s, _) => k * mir.layout.bytes(s)
  _ => k * 8
}

/// The scalar type of part `k` of a C aggregate passed as `c` (`Words` or `Hfa`).
fn c_part_sc(c: mir.layout.CPass, k: int): mir.layout.Sc = match c {
  Words(ws) => ws[k]
  Hfa(s, _) => s
  _ => mir.bug("c_part_sc")
}

/// The number of parts of a C aggregate passed as `c` (`Words` or `Hfa`).
fn c_parts(c: mir.layout.CPass): int = match c {
  Words(ws) => ws.len()
  Hfa(_, n) => n
  _ => 0
}

/// The LLVM argument(s) of a C aggregate of type `t` at `m` passed as `c`.
fn c_arg_vals(g: var Gen, c: mir.layout.CPass, m: llvm.Value, t: mir.MTy): [llvm.Value] uses ffi {
  var parts: [llvm.Value] = []
  for k in 0..c_parts(c) { parts.push(load_part(&g, m, c, k, t)) }
  let tys = c_arg_tys(g, c)
  if tys.len() == parts.len() { return parts }
  var agg = llvm.values.get_undef(tys[0])
  for k, v in parts { agg = llvm.builder.build_insert_value(g.b, agg, v, k, "") }
  [agg]
}

/// Store the incoming LLVM argument(s) of a C aggregate passed as `c`, from parameter `k` of
/// `fv`, at `dst`; returns the next parameter's index.
fn c_param_store(g: Gen, c: mir.layout.CPass, fv: llvm.Value, k: int, dst: llvm.Value): int uses ffi {
  let n = c_parts(c)
  if c_arg_tys(g, c).len() == n {
    for j in 0..n { store(g, llvm.values.get_param(fv, k + j), gep(g, dst, c_part_off(c, j))) }
    return k + n
  }
  let agg = llvm.values.get_param(fv, k)
  for j in 0..n {
    let v = llvm.builder.build_extract_value(g.b, agg, j, "")
    store(g, v, gep(g, dst, c_part_off(c, j)))
  }
  k + 1
}

/// A C signature: (signature, how each parameter passes, how the result returns).
pub fn c_sig(
  g: var Gen,
  params: [mir.MTy],
  ret: mir.MTy,
): (Sig, [mir.layout.CPass], mir.layout.CPass) uses ffi {
  let (pp, rp) = mir.layout.c_sig(&g.lay, params, ret)
  var ps: [llvm.Type] = []
  var attrs: [(int, llvm.Attribute)] = []
  let rt = match rp {
    Nothing => g.t_void
    Scalar(s) => {
      match ext_attr(g, ret, s) {
        some(a) => attrs.push((0, a))
        none => {}
      }
      lt(g, s)
    }
    Words(_) | Hfa(_, _) => c_ret_ty(g, rp)
    Sret | Mem => {
      let size = lay(&g, ret).size
      let a = llvm.ir.create_type_attribute(g.cx, attr_kind("sret"), bytes_ty(g, size))
      attrs.push((1, a))
      ps.push(g.t_ptr)
      g.t_void
    }
  }
  for (p, c) in params.zip(pp) {
    match c {
      Scalar(s) => {
        match ext_attr(g, p, s) {
          some(a) => attrs.push((ps.len() + 1, a))
          none => {}
        }
        ps.push(lt(g, s))
      }
      Words(_) | Hfa(_, _) => for t in c_arg_tys(g, c) { ps.push(t) }
      Sret | Mem => {
        if g.lay.arch == "x86_64" {
          // a copy on the stack, as clang's `byval(%struct.S) align 8`
          let l = lay(&g, p)
          let k = ps.len() + 1
          attrs.push((k, llvm.ir.create_type_attribute(g.cx, attr_kind("byval"), bytes_ty(g, l.size))))
          attrs.push((k, llvm.ir.create_enum_attribute(g.cx, attr_kind("align"), max(l.align, 8))))
        }
        ps.push(g.t_ptr)
      }
      Nothing => {}
    }
  }
  let ty = llvm.ir.function_type(rt, ps, 0)
  (Sig { ty, attrs }, pp, rp)
}

/// A generated function's own signature: aggregates by pointer, a leading result pointer.
/// `inplace`: which parameters are read in place (`noalias readonly`), if known.
pub fn auk_sig(g: Gen, params: [mir.MTy], ret: mir.MTy, inplace: [bool]?): Sig uses ffi {
  var ps: [llvm.Type] = []
  var attrs: [(int, llvm.Attribute)] = []
  let rt = if is_agg(g, ret) {
    ps.push(g.t_ptr)
    attrs.push((1, enum_attr(g, "noalias")))
    g.t_void
  } else {
    scalar(g, ret) else g.t_void
  }
  for i, p in params {
    let ip = match inplace {
      some(xs) => xs[i]
      none => false
    }
    if ip {
      let k = ps.len() + 1
      attrs.push((k, enum_attr(g, "noalias")))
      attrs.push((k, enum_attr(g, "readonly")))
    }
    ps.push(scalar(g, p) else g.t_ptr)
  }
  let ty = llvm.ir.function_type(rt, ps, 0)
  Sig { ty, attrs }
}

pub fn params_of(f: mir.Func): [mir.MTy] = f.params.map(v => f.vars[v])

fn func_sig(g: var Gen, fi: int): (Sig, [mir.layout.CPass], mir.layout.CPass) uses ffi {
  let f = g.prog.funcs[fi]
  let ps = params_of(f)
  match f.abi {
    Auk => (auk_sig(g, ps, f.ret, some(g.inplace[fi])), [], mir.layout.CPass.Nothing)
    C => c_sig(&g, ps, f.ret)
  }
}

// ---- the module ----

/// Translate the whole program.
pub fn program(g: var Gen, ex: Exports): ()! uses ffi {
  let prog = g.prog
  // (a library of the runtime's dialect has none: `auk build --lib`)
  let entry = prog.entry else -1
  // which aggregate parameters each function reads in place
  for f in prog.funcs {
    var set = f.vars.map(_ => false)
    var addr = f.vars.map(_ => false)
    writes(f.body, &set, &addr)
    let ip = f.params.map(v => f.abi == mir.Abi.Auk && is_agg(g, f.vars[v]) && !set[v] && !addr[v])
    g.inplace.push(ip)
  }
  let fattrs = [
    enum_attr(g, "nounwind"),
    llvm.ir.create_string_attribute(g.cx, "frame-pointer", "all"),
  ]
  for i, f in prog.funcs {
    let (sig, _, _) = func_sig(&g, i)
    let is_entry = i == entry
    let name = if is_entry { ex.entry } else { f.name }
    let fv = llvm.ir.add_function(g.m, name, sig.ty)
    // an `export fn` is an ordinary external definition (never dropped as unused), an `inline
    // export fn` also `inlinehint` (for the runtime's bitcode, `rtlink`)
    let raw_export = prog.exports.get(i) else 0
    let export = is_entry || ex.all || ex.names.contains(f.name) || raw_export > 0
    llvm.values.set_linkage(fv, if export { llvm.EXTERNAL_LINKAGE } else { llvm.INTERNAL_LINKAGE })
    if raw_export == 2 { llvm.values.add_attribute_at_index(fv, llvm.ATTRIBUTE_FUNCTION_INDEX, enum_attr(g, "inlinehint")) }
    for (k, a) in sig.attrs { llvm.values.add_attribute_at_index(fv, k, a) }
    for a in fattrs { llvm.values.add_attribute_at_index(fv, llvm.ATTRIBUTE_FUNCTION_INDEX, a) }
    if rawgen.calls_setjmp(f.body) {
      // after `raw.setjmp` returns the second time, every local must hold its last value
      // (C's `volatile` rule): no optimization keeps one in a register across it
      for a in ["optnone", "noinline"] {
        llvm.values.add_attribute_at_index(fv, llvm.ATTRIBUTE_FUNCTION_INDEX, enum_attr(g, a))
      }
    }
    g.funcs.push((fv, sig))
  }
  for gl in prog.globals {
    let gv = global(&g, gl)?
    g.globals.push(gv)
  }
  for i in 0..prog.funcs.len() { body(&g, i)? }
  dwarf.finish(g.debug)
}

/// A global's definition: zeros, or bytes with function addresses at their offsets.
fn global(g: var Gen, gl: mir.Global): llvm.Value! uses ffi {
  if gl.kind != 0 { return rawgen.global(&g, gl) }
  let l = lay(&g, gl.ty)
  let size = max(l.size, 1)
  var ty = bytes_ty(g, size)
  var init = llvm.values.const_null(ty)
  match gl.init {
    none => {}
    some(e) => {
      let ms = match e.k {
        Agg(ms) => ms
        _ => return fail("global {gl.name}: unsupported initializer")
      }
      var bytes = (0..size).map(_ => 0)
      var ptrs: [(int, llvm.Value)] = []
      for (s, v) in ms {
        let off = offset(&g, gl.ty, s)
        match v.k {
          Int(n) => {
            let sz = lay(&g, v.ty).size
            for k in 0..sz { bytes[off + k] = (n >> (8 * k)) & 255 }
          }
          SizeOf(t) => {
            let n = lay(&g, t).size
            for k in 0..8 { bytes[off + k] = (n >> (8 * k)) & 255 }
          }
          Zero => {}
          FnAddr(Fn(f)) => ptrs.push((off, g.funcs[f].0))
          CStr(b) => {
            let p = cstr_addr(&g, b)
            ptrs.push((off, p))
          }
          _ => return fail("global {gl.name}: unsupported initializer member")
        }
      }
      let sorted = ptrs.sort_by(p => p.0)
      // a packed struct of byte runs and pointers
      var fields: [llvm.Value] = []
      var at = 0
      for (off, p) in sorted {
        if off > at { fields.push(const_bytes(g, bytes[at..off])) }
        fields.push(p)
        at = off + 8
      }
      if at < bytes.len() { fields.push(const_bytes(g, bytes[at..bytes.len()])) }
      init = llvm.values.const_struct_in_context(g.cx, fields, 1)
      ty = llvm.values.type_of(init)
    }
  }
  let gv = llvm.values.add_global(g.m, ty, gl.name)
  llvm.values.set_initializer(gv, init)
  llvm.values.set_linkage(gv, llvm.INTERNAL_LINKAGE)
  llvm.values.set_global_constant(gv, if gl.constant { 1 } else { 0 })
  llvm.values.set_alignment(gv, max(l.align, 8))
  gv
}

extern fn c_const_bytes(
  c: llvm.Context,
  s: ffi.Ptr,
  n: int,
  dont_null_terminate: int,
): llvm.Value = "LLVMValueRef LLVMConstStringInContext2(LLVMContextRef, void *, size_t, int)"

/// `LLVMConstStringInContext2` of arbitrary bytes (an Auk `str` is UTF-8).
fn const_string(g: Gen, b: [int], dont_null_terminate: int): llvm.Value uses ffi {
  let p = ffi.from_bytes(if b.len() == 0 { [0] } else { b })
  let v = c_const_bytes(g.cx, p, b.len(), dont_null_terminate)
  ffi.free(p)
  v
}

pub fn const_bytes(g: Gen, b: [int]): llvm.Value uses ffi = const_string(g, b, 1)

// ---- function bodies ----

fn body(g: var Gen, fi: int): ()! uses ffi {
  let f = g.prog.funcs[fi]
  let fv = g.funcs[fi].0
  let (_, pp, rp) = func_sig(&g, fi)
  g.fi = fi
  g.fv = fv
  g.sret = none
  g.loops = []
  g.labels = {}
  g.terminated = false
  // debug info: the prologue is at the function's first line
  g.sp = none
  var at: llvm.Metadata? = none
  if g.debug.on {
    let (sp, a) = dwarf.subprogram(&g.debug, fv, g.prog, fi)
    g.sp = sp
    at = a
  }
  llvm.builder.set_current_debug_location2(g.b, at)
  let allocas = llvm.values.append_basic_block_in_context(g.cx, fv, "allocas")
  let start = llvm.values.append_basic_block_in_context(g.cx, fv, "start")
  llvm.builder.position_builder_at_end(g.ab, allocas)
  llvm.builder.position_builder_at_end(g.b, start)
  var set = f.vars.map(_ => false)
  var addressed = f.vars.map(_ => false)
  writes(f.body, &set, &addressed)
  g.addressed = addressed
  // variables (in-place parameters get their incoming pointer below)
  let ips = g.inplace[fi]
  var inplace = f.vars.map(_ => false)
  for i, v in f.params {
    if ips[i] { inplace[v] = true }
  }
  var vars: [llvm.Value] = []
  for v, t in f.vars {
    vars.push(if inplace[v] { fv } else { alloca(&g, t) })
  }
  g.vars = vars
  // parameters
  var k = 0
  match f.abi {
    Auk => {
      if is_agg(g, f.ret) {
        g.sret = llvm.values.get_param(fv, 0)
        k = 1
      }
      for i, v in f.params {
        let t = f.vars[v]
        let p = llvm.values.get_param(fv, k)
        k += 1
        if ips[i] {
          g.vars[v] = p
        } else if is_agg(g, t) {
          copy(&g, g.vars[v], p, t)
        } else {
          store(g, p, g.vars[v])
        }
      }
    }
    C => {
      if rp == mir.layout.CPass.Sret {
        g.sret = llvm.values.get_param(fv, 0)
        k = 1
      }
      for i, v in f.params {
        let dst = g.vars[v]
        match pp[i] {
          Scalar(_) => {
            store(g, llvm.values.get_param(fv, k), dst)
            k += 1
          }
          Words(_) | Hfa(_, _) => k = c_param_store(g, pp[i], fv, k, dst)
          Sret | Mem => {
            copy(&g, dst, llvm.values.get_param(fv, k), f.vars[v])
            k += 1
          }
          Nothing => {}
        }
      }
    }
  }
  stmts(&g, f.body)?
  if !g.terminated { ret_default(&g) }
  llvm.builder.position_builder_at_end(g.ab, allocas)
  let _ = llvm.builder.build_br(g.ab, start)
}

/// A stack slot for a value of type `t` in the entry block, rounded up to whole words (C
/// results arrive as full words).
fn alloca(g: var Gen, t: mir.MTy): llvm.Value uses ffi {
  let l = lay(&g, t)
  let size = mir.layout.align_up(max(l.size, 1), 8)
  let a = llvm.builder.build_alloca(g.ab, bytes_ty(g, size), "")
  llvm.values.set_alignment(a, max(l.align, 8))
  a
}

fn cur_ret_sig(g: var Gen): ([mir.layout.CPass], mir.layout.CPass) {
  let f = g.prog.funcs[g.fi]
  mir.layout.c_sig(&g.lay, params_of(f), f.ret)
}

fn ret_default(g: var Gen) uses ffi {
  let f = g.prog.funcs[g.fi]
  match scalar(g, f.ret) {
    some(t) => llvm.builder.build_ret(g.b, llvm.values.const_null(t))
    none => if f.abi == mir.Abi.C && is_agg(g, f.ret) {
      let rp = cur_ret_sig(&g).1
      match rp {
        Words(_) | Hfa(_, _) => llvm.builder.build_ret(g.b, llvm.values.const_null(c_ret_ty(g, rp)))
        _ => llvm.builder.build_ret_void(g.b)
      }
    } else {
      llvm.builder.build_ret_void(g.b)
    }
  }
  g.terminated = true
}

// ---- memory helpers ----

pub fn gep(g: Gen, base: llvm.Value, off: int): llvm.Value uses ffi {
  if off == 0 { return base }
  llvm.builder.build_in_bounds_gep2(g.b, g.t_i8, base, [llvm.values.const_int(g.t_i64, off, 0)], "")
}

pub fn store(g: Gen, v: llvm.Value, at: llvm.Value) uses ffi {
  let _ = llvm.builder.build_store(g.b, v, at)
}

pub fn load_ty(g: Gen, t: llvm.Type, at: llvm.Value): llvm.Value uses ffi =
  llvm.builder.build_load2(g.b, t, at, "")

pub fn temp(g: var Gen, t: mir.MTy): llvm.Value uses ffi = alloca(&g, t)

fn zero_mem(g: var Gen, at: llvm.Value, t: mir.MTy) uses ffi {
  let l = lay(&g, t)
  let _ = llvm.builder.build_mem_set(
    g.b,
    at,
    llvm.values.const_int(g.t_i8, 0, 0),
    llvm.values.const_int(g.t_i64, max(l.size, 1), 0),
    min(l.align, 8),
  )
}

pub fn copy(g: var Gen, dst: llvm.Value, src: llvm.Value, t: mir.MTy) uses ffi {
  let l = lay(&g, t)
  if l.size == 0 { return }
  let a = min(l.align, 8)
  let _ = llvm.builder.build_mem_cpy(g.b, dst, a, src, a, llvm.values.const_int(g.t_i64, l.size, 0))
}

/// The offset of word `k` of a C aggregate passed as words: 8 bytes each, except the `f32`s of an
/// AArch64 float aggregate (only raw structs have them).
/// Part `k` of a C aggregate of type `t` at `src` passed as `c`: a full load, or only the
/// bytes the aggregate has (zero-extended) for a partial last integer word.
fn load_part(
  g: var Gen,
  src: llvm.Value,
  c: mir.layout.CPass,
  k: int,
  t: mir.MTy,
): llvm.Value uses ffi {
  let size = lay(&g, t).size
  let w = c_part_sc(c, k)
  let at = gep(g, src, c_part_off(c, k))
  let n = min(size - k * 8, 8)
  if n == 8 || mir.layout.is_float(w) { return load_ty(g, lt(g, w), at) }
  let part = llvm.builder.build_load2(g.b, llvm.ir.int_type_in_context(g.cx, n * 8), at, "")
  llvm.values.set_alignment(part, 1)
  llvm.builder.build_zext(g.b, part, g.t_i64, "")
}

// ---- control flow ----

pub fn new_block(g: Gen, name: str): llvm.BasicBlock uses ffi =
  llvm.values.append_basic_block_in_context(g.cx, g.fv, name)

pub fn switch_to(g: var Gen, b: llvm.BasicBlock) uses ffi {
  llvm.builder.position_builder_at_end(g.b, b)
  g.terminated = false
}

pub fn br(g: Gen, b: llvm.BasicBlock) uses ffi {
  let _ = llvm.builder.build_br(g.b, b)
}

pub fn insert_block(g: Gen): llvm.BasicBlock uses ffi = llvm.builder.get_insert_block(g.b)!

fn ensure_open(g: var Gen) uses ffi {
  if g.terminated {
    let b = new_block(g, "dead")
    switch_to(&g, b)
  }
}

fn label_block(g: var Gen, l: int): llvm.BasicBlock uses ffi {
  match g.labels.get(l) {
    some(b) => return b
    none => {}
  }
  let b = new_block(g, "label")
  g.labels[l] = b
  b
}

/// An i1 from an Auk bool (i8).
pub fn truth(g: Gen, v: llvm.Value): llvm.Value uses ffi {
  let t = llvm.values.type_of(v)
  if t == g.t_i1 { return v }
  llvm.builder.build_icmp(g.b, llvm.INT_NE, v, llvm.values.const_null(t), "")
}

pub fn bool8(g: Gen, v: llvm.Value): llvm.Value uses ffi = llvm.builder.build_zext(g.b, v, g.t_i8, "")

fn stmts(g: var Gen, ss: [mir.Stmt]): ()! uses ffi {
  for s in ss { stmt(&g, s)? }
}

fn stmt(g: var Gen, s: mir.Stmt): ()! uses ffi {
  match s {
    Loc(i) => {
      // the code from here on comes from this source location
      match g.sp {
        some(sp) => if g.debug.on {
          let at = dwarf.loc(g.debug, g.prog, i, sp)
          llvm.builder.set_current_debug_location2(g.b, at)
        }
        none => {}
      }
      return
    }
    Label(l) => {
      let blk = label_block(&g, l)
      if !g.terminated { br(g, blk) }
      switch_to(&g, blk)
      return
    }
    _ => {}
  }
  ensure_open(&g)
  match s {
    Let(v, e) => {
      let t = g.prog.funcs[g.fi].vars[v]
      let x = ex(&g, e)
      store_at(&g, g.vars[v], t, x, e.ty)
    }
    Set(p, e) => {
      let x = ex(&g, e)
      let a = place(&g, p)
      store_at(&g, a, p.ty, x, e.ty)
    }
    Do(e) => {
      let _ = ex(&g, e)
    }
    If(cnd, a, b) => {
      let cv = val(&g, cnd)
      let cv = truth(g, cv)
      let tb = new_block(g, "then")
      let eb = new_block(g, "else")
      let merge = new_block(g, "endif")
      llvm.builder.build_cond_br(g.b, cv, tb, eb)
      switch_to(&g, tb)
      stmts(&g, a)?
      if !g.terminated { br(g, merge) }
      switch_to(&g, eb)
      stmts(&g, b)?
      if !g.terminated { br(g, merge) }
      switch_to(&g, merge)
    }
    Loop(body, latch) => {
      let head = new_block(g, "loop")
      let lat = new_block(g, "latch")
      let exit = new_block(g, "endloop")
      br(g, head)
      switch_to(&g, head)
      g.loops.push((lat, exit))
      stmts(&g, body)?
      g.loops.pop()
      if !g.terminated { br(g, lat) }
      switch_to(&g, lat)
      stmts(&g, latch)?
      if !g.terminated { br(g, head) }
      switch_to(&g, exit)
    }
    Break => {
      let (_, exit) = g.loops.last() else return fail("break outside a loop")
      br(g, exit)
      g.terminated = true
    }
    Continue => {
      let (lat, _) = g.loops.last() else return fail("continue outside a loop")
      br(g, lat)
      g.terminated = true
    }
    Goto(l) => {
      let blk = label_block(&g, l)
      br(g, blk)
      g.terminated = true
    }
    Ret(e) => {
      ret(&g, e)
      g.terminated = true
    }
    Unreachable => {
      trap(g)
      g.terminated = true
    }
    Label(_) | Loc(_) => mir.bug("unreachable")
  }
}

pub fn intrinsic(g: Gen, name: str, tys: [llvm.Type]): (llvm.Value, llvm.Type) uses ffi {
  let id = llvm.values.lookup_intrinsic_id(name)
  let f = llvm.values.get_intrinsic_declaration(g.m, id, tys)
  let ft = llvm.values.intrinsic_get_type(g.cx, id, tys)
  (f, ft)
}

fn trap(g: Gen) uses ffi {
  let (f, ft) = intrinsic(g, "llvm.trap", [])
  llvm.builder.build_call2(g.b, ft, f, [], "")
  let _ = llvm.builder.build_unreachable(g.b)
}

fn ret(g: var Gen, e: mir.Ex?) uses ffi {
  let f = g.prog.funcs[g.fi]
  let e = e else {
    ret_default(&g)
    return
  }
  let x = ex(&g, e)
  match scalar(g, f.ret) {
    some(t) => {
      let v = scalar_of(&g, x, e.ty, f.ret, t)
      llvm.builder.build_ret(g.b, v)
      return
    }
    none => {}
  }
  if f.ret == mir.MTy.Void {
    llvm.builder.build_ret_void(g.b)
    return
  }
  let src = match as_mem(&g, x, e.ty) {
    M(a) => a
    _ => mir.bug("llvm: aggregate return")
  }
  let parts = if f.abi == mir.Abi.C {
    let rp = cur_ret_sig(&g).1
    if c_parts(rp) > 0 { some(rp) } else { none }
  } else {
    none
  }
  match parts {
    some(rp) => {
      var vals: [llvm.Value] = []
      for k in 0..c_parts(rp) { vals.push(load_part(&g, src, rp, k, f.ret)) }
      if rp is mir.layout.CPass.Words(_) && vals.len() == 1 {
        let _ = llvm.builder.build_ret(g.b, vals[0])
      } else {
        var agg = llvm.values.get_undef(c_ret_ty(g, rp))
        for k, v in vals { agg = llvm.builder.build_insert_value(g.b, agg, v, k, "") }
        let _ = llvm.builder.build_ret(g.b, agg)
      }
    }
    none => {
      copy(&g, g.sret!, src, f.ret)
      let _ = llvm.builder.build_ret_void(g.b)
    }
  }
}

// ---- storing and converting ----

fn store_at(g: var Gen, a: llvm.Value, t: mir.MTy, x: V, from: mir.MTy) uses ffi {
  match scalar(g, t) {
    some(s) => {
      let v = scalar_of(&g, x, from, t, s)
      store(g, v, a)
    }
    none => match as_mem(&g, x, from) {
      M(src) => if src != a { copy(&g, a, src, t) }
      _ => {}
    }
  }
}

/// A scalar value converted from type `from` to `to` (LLVM type `s`).
pub fn scalar_of(
  g: var Gen,
  x: V,
  from: mir.MTy,
  to: mir.MTy,
  s: llvm.Type,
): llvm.Value uses ffi = match x {
  S(v) => convert(&g, v, from, to)
  M(a) => load_ty(g, s, a)
  Nil => llvm.values.const_null(s)
}

/// An aggregate as an address (materializing a zero for `Nil`).
fn as_mem(g: var Gen, x: V, t: mir.MTy): V uses ffi = match x {
  M(_) => x
  S(v) => {
    // a scalar used where an aggregate is expected (a one-word aggregate)
    let a = temp(&g, t)
    zero_mem(&g, a, t)
    store(g, v, a)
    V.M(a)
  }
  Nil => {
    let a = temp(&g, t)
    zero_mem(&g, a, t)
    V.M(a)
  }
}

pub fn convert(g: var Gen, v: llvm.Value, from: mir.MTy, to: mir.MTy): llvm.Value uses ffi {
  let tt = scalar(g, to) else return v
  let ft = llvm.values.type_of(v)
  if ft == tt { return v }
  let fk = llvm.ir.get_type_kind(ft)
  let tk = llvm.ir.get_type_kind(tt)
  let signed = mir.layout.signed(from)
  let b = g.b
  let int_k = llvm.INTEGER_TYPE_KIND
  let dbl_k = llvm.DOUBLE_TYPE_KIND
  let flt_k = llvm.FLOAT_TYPE_KIND
  let ptr_k = llvm.POINTER_TYPE_KIND
  if fk == int_k && tk == int_k {
    let fw = llvm.ir.get_int_type_width(ft)
    let tw = llvm.ir.get_int_type_width(tt)
    if tw > fw {
      // an i1 (a comparison) is always zero-extended
      if signed && fw > 1 {
        llvm.builder.build_sext(b, v, tt, "")
      } else {
        llvm.builder.build_zext(b, v, tt, "")
      }
    } else {
      llvm.builder.build_trunc(b, v, tt, "")
    }
  } else if fk == flt_k && tk == dbl_k {
    llvm.builder.build_fp_ext(b, v, tt, "")
  } else if fk == dbl_k && tk == flt_k {
    llvm.builder.build_fp_trunc(b, v, tt, "")
  } else if fk == int_k && tk == flt_k {
    // the runtime's dialect: an integer to `f32`
    if signed {
      llvm.builder.build_si_to_fp(b, v, tt, "")
    } else {
      llvm.builder.build_ui_to_fp(b, v, tt, "")
    }
  } else if (fk == flt_k || fk == dbl_k) && tk == int_k && (mir.layout.raw_unsigned(to) || fk == flt_k) {
    // the runtime's dialect: to an unsigned fixed-width integer, or from `f32` (saturating)
    let name = if mir.layout.raw_unsigned(to) { "llvm.fptoui.sat" } else { "llvm.fptosi.sat" }
    let (f, fty) = intrinsic(g, name, [tt, ft])
    llvm.builder.build_call2(b, fty, f, [v], "")
  } else if fk == int_k && tk == dbl_k {
    if signed {
      llvm.builder.build_si_to_fp(b, v, tt, "")
    } else {
      llvm.builder.build_ui_to_fp(b, v, tt, "")
    }
  } else if fk == dbl_k && tk == int_k {
    let (f, fty) = intrinsic(g, "llvm.fptosi.sat", [tt, ft])
    llvm.builder.build_call2(b, fty, f, [v], "")
  } else if fk == ptr_k && tk == int_k {
    llvm.builder.build_ptr_to_int(b, v, tt, "")
  } else if fk == int_k && tk == ptr_k {
    llvm.builder.build_int_to_ptr(b, v, tt, "")
  } else if fk == dbl_k && tk == ptr_k {
    let i = llvm.builder.build_bit_cast(b, v, g.t_i64, "")
    llvm.builder.build_int_to_ptr(b, i, tt, "")
  } else if fk == ptr_k && tk == dbl_k {
    let i = llvm.builder.build_ptr_to_int(b, v, g.t_i64, "")
    llvm.builder.build_bit_cast(b, i, tt, "")
  } else {
    v
  }
}

// ---- expressions ----

/// A scalar expression's value.
pub fn val(g: var Gen, e: mir.Ex): llvm.Value uses ffi {
  let x = ex(&g, e)
  let t = scalar(g, e.ty) else g.t_i8
  scalar_of(&g, x, e.ty, e.ty, t)
}

/// An aggregate expression's address.
pub fn mem_of(g: var Gen, e: mir.Ex): llvm.Value uses ffi {
  if mir.is_place(e) { return place(&g, e) }
  let x = ex(&g, e)
  match as_mem(&g, x, e.ty) {
    M(a) => a
    _ => mir.bug("unreachable")
  }
}

/// The address of a place.
fn place(g: var Gen, e: mir.Ex): llvm.Value uses ffi = match e.k {
  Var(v) => g.vars[v]
  Global(gl) => g.globals[gl]
  Deref(p) => {
    // `*(T *)auk_arr_at(xs, i, loc)`: the element size is T's
    let inner = match p.k {
      Cast(x) => x
      _ => p
    }
    match inner.k {
      Call(Rt(s), _) => if s == "auk_arr_at" { g.elem_hint = lay(&g, e.ty).size }
      _ => {}
    }
    let v = val(&g, p)
    g.elem_hint = none
    v
  }
  Field(b, s) => {
    let base = mem_of(&g, b)
    let off = offset(&g, b.ty, s)
    gep(g, base, off)
  }
  Elem(arr, i) => {
    let a = val(&g, arr)
    let dp = gep(g, a, 40)
    let data = load_ty(g, g.t_ptr, dp)
    let iv = val(&g, i)
    let iv = convert(&g, iv, i.ty, mir.MTy.I64)
    let size = lay(&g, e.ty).size
    let off = llvm.builder.build_mul(g.b, iv, llvm.values.const_int(g.t_i64, size, 0), "")
    llvm.builder.build_gep2(g.b, g.t_i8, data, [off], "")
  }
  RtField(p, f) => {
    let a = val(&g, p)
    let off = match f {
      ArrLen => 24
      ArrData => 40
      ErrMsg => 16
    }
    gep(g, a, off)
  }
  _ => {
    let x = ex(&g, e)
    let a = temp(&g, e.ty)
    store_at(&g, a, e.ty, x, e.ty)
    a
  }
}

/// Load a value of type `t` from address `a`: a scalar, or the address itself.
fn load(g: Gen, a: llvm.Value, t: mir.MTy): V uses ffi = match scalar(g, t) {
  some(s) => V.S(load_ty(g, s, a))
  none => V.M(a)
}

fn rt_data_addr(g: var Gen, name: str): llvm.Value uses ffi {
  match g.rt_data.get(name) {
    some(gl) => return gl
    none => {}
  }
  let gl = llvm.values.add_global(g.m, g.t_i8, name)
  g.rt_data[name] = gl
  gl
}

fn cstr_addr(g: var Gen, s: [int]): llvm.Value uses ffi {
  match g.cstrs.get(s) {
    some(gl) => return gl
    none => {}
  }
  let init = const_string(g, s, 0)
  let gl = llvm.values.add_global(g.m, llvm.values.type_of(init), "str")
  llvm.values.set_initializer(gl, init)
  llvm.values.set_linkage(gl, llvm.PRIVATE_LINKAGE)
  llvm.values.set_global_constant(gl, 1)
  llvm.values.set_unnamed_address(gl, llvm.GLOBAL_UNNAMED_ADDR)
  llvm.values.set_alignment(gl, 1)
  g.cstrs[s] = gl
  gl
}

pub fn ex(g: var Gen, e: mir.Ex): V uses ffi = match e.k {
  Var(v) => load(g, g.vars[v], e.ty)
  Global(_) | Deref(_) | Elem(_, _) | RtField(_, _) => {
    let a = place(&g, e)
    load(g, a, e.ty)
  }
  Field(b, s) => if mir.is_place(e) {
    let a = place(&g, e)
    load(g, a, e.ty)
  } else {
    // a member of an aggregate value
    let base = mem_of(&g, b)
    let off = offset(&g, b.ty, s)
    let a = gep(g, base, off)
    load(g, a, e.ty)
  }
  Int(n) => match scalar(g, e.ty) {
    some(t) => if t == g.t_f64 {
      V.S(llvm.values.const_real(t, float(n)))
    } else if t == g.t_ptr {
      if n == 0 {
        V.S(llvm.values.const_null(t))
      } else {
        V.S(llvm.values.const_int_to_ptr(llvm.values.const_int(g.t_i64, n, 0), t))
      }
    } else {
      // a negative constant narrower than 64 bits (the runtime's dialect) is sign-extended:
      // LLVM's APInt doesn't take an out-of-range unsigned value
      let sext = if n < 0 && (e.ty is mir.MTy.D(types.Ty.Fixed(_))) { 1 } else { 0 }
      V.S(llvm.values.const_int(t, n, sext))
    }
    none => V.Nil
  }
  Float(x) => V.S(llvm.values.const_real(g.t_f64, x))
  CStr(s) => V.S(cstr_addr(&g, s))
  Zero => match scalar(g, e.ty) {
    some(t) => V.S(llvm.values.const_null(t))
    none => V.Nil
  }
  FnAddr(Fn(f)) => V.S(g.funcs[f].0)
  FnAddr(Rt(s)) => mir.bug("llvm: address of runtime function {s}")
  GlobalAddr(gl) => V.S(g.globals[gl])
  RtGlobalAddr(s) => V.S(rt_data_addr(&g, s))
  Addr(p) => V.S(place(&g, p))
  Un(op, a) => {
    let v = val(&g, a)
    V.S(
      match op {
        Not => {
          let z = llvm.builder.build_icmp(
            g.b,
            llvm.INT_EQ,
            v,
            llvm.values.const_null(llvm.values.type_of(v)),
            "",
          )
          bool8(g, z)
        }
        Neg => if llvm.values.type_of(v) == g.t_f64 || llvm.values.type_of(v) == g.t_f32 {
          llvm.builder.build_fneg(g.b, v, "")
        } else {
          llvm.builder.build_neg(g.b, v, "")
        }
        BitNot => llvm.builder.build_not(g.b, v, "")
      },
    )
  }
  Bin(op, a, b) => V.S(bin(&g, op, a, b))
  And(xs) => {
    let done = new_block(g, "and")
    var vs: [llvm.Value] = []
    var bs: [llvm.BasicBlock] = []
    for x in xs {
      let v = val(&g, x)
      let v = truth(g, v)
      let next = new_block(g, "and.next")
      llvm.builder.build_cond_br(g.b, v, next, done)
      vs.push(llvm.values.const_int(g.t_i8, 0, 0))
      bs.push(insert_block(g))
      switch_to(&g, next)
    }
    br(g, done)
    vs.push(llvm.values.const_int(g.t_i8, 1, 0))
    bs.push(insert_block(g))
    switch_to(&g, done)
    let phi = llvm.builder.build_phi(g.b, g.t_i8, "")
    llvm.values.add_incoming(phi, vs, bs)
    V.S(phi)
  }
  Cast(x) => {
    let v = ex(&g, x)
    match (v, scalar(g, e.ty)) {
      (S(s), some(_)) => V.S(convert(&g, s, x.ty, e.ty))
      (M(a), some(t)) => V.S(load_ty(g, t, a))
      (v, _) => v
    }
  }
  Call(cl, args) => call(&g, cl, args, e.ty)
  Agg(ms) => {
    let a = temp(&g, e.ty)
    zero_mem(&g, a, e.ty)
    for (s, v) in ms {
      let off = offset(&g, e.ty, s)
      let mt = mir.types.member_ty(g.lay.info, e.ty, s, g.prog.aggs)
      let x = ex(&g, v)
      let p = gep(g, a, off)
      store_at(&g, p, mt, x, v.ty)
    }
    V.M(a)
  }
  Cond(cnd, a, b) => {
    let cv = val(&g, cnd)
    let cv = truth(g, cv)
    let t = scalar(g, e.ty) else mir.bug("llvm: aggregate conditional")
    let tb = new_block(g, "cond.then")
    let eb = new_block(g, "cond.else")
    let done = new_block(g, "cond")
    llvm.builder.build_cond_br(g.b, cv, tb, eb)
    switch_to(&g, tb)
    let x = ex(&g, a)
    let xv = scalar_of(&g, x, a.ty, e.ty, t)
    let xb = insert_block(g)
    br(g, done)
    switch_to(&g, eb)
    let y = ex(&g, b)
    let yv = scalar_of(&g, y, b.ty, e.ty, t)
    let yb = insert_block(g)
    br(g, done)
    switch_to(&g, done)
    let phi = llvm.builder.build_phi(g.b, t, "")
    llvm.values.add_incoming(phi, [xv, yv], [xb, yb])
    V.S(phi)
  }
  SizeOf(t) => V.S(llvm.values.const_int(g.t_i64, lay(&g, t).size, 0))
}

fn bin(g: var Gen, op: mir.BOp, a: mir.Ex, b: mir.Ex): llvm.Value uses ffi {
  let x = val(&g, a)
  let y0 = val(&g, b)
  let y = convert(&g, y0, b.ty, a.ty)
  let bld = g.b
  if llvm.values.type_of(x) == g.t_f64 || llvm.values.type_of(x) == g.t_f32 {
    let cmp = (p: int) => bool8(g, llvm.builder.build_fcmp(bld, p, x, y, ""))
    return match op {
      Add => llvm.builder.build_fadd(bld, x, y, "")
      Sub => llvm.builder.build_fsub(bld, x, y, "")
      Mul => llvm.builder.build_fmul(bld, x, y, "")
      Div => llvm.builder.build_fdiv(bld, x, y, "")
      Rem => llvm.builder.build_f_rem(bld, x, y, "")
      Eq => cmp(llvm.REAL_OEQ)
      Ne => cmp(llvm.REAL_UNE)
      Lt => cmp(llvm.REAL_OLT)
      Le => cmp(llvm.REAL_OLE)
      Gt => cmp(llvm.REAL_OGT)
      Ge => cmp(llvm.REAL_OGE)
      _ => mir.bug("llvm: float {op}")
    }
  }
  let unsigned = match a.ty {
    U8 | U16 | U32 | U64 | Ptr(_) | CStr | Code => true
    D(Char) => true
    t => mir.layout.raw_unsigned(t)
  }
  let cc = (s: int, u: int) => if unsigned { u } else { s }
  let cmp = (p: int) => bool8(g, llvm.builder.build_icmp(bld, p, x, y, ""))
  let is_ptr = llvm.values.type_of(x) == g.t_ptr
  let t_i64 = g.t_i64
  let t_ptr = g.t_ptr
  // the runtime's dialect: an address plus a byte offset is a GEP (`p.offset(i)`, `p.at(i)`)
  if op == mir.BOp.Add && (a.ty is mir.MTy.D(types.Ty.Ptr(_))) {
    return llvm.builder.build_gep2(bld, g.t_i8, x, [y0], "")
  }
  // arithmetic on pointers goes through integers
  let arith = (f: (llvm.Builder, llvm.Value, llvm.Value, str) => llvm.Value) => {
    if is_ptr {
      let xi = llvm.builder.build_ptr_to_int(bld, x, t_i64, "")
      let yi = if llvm.values.type_of(y) == t_ptr {
        llvm.builder.build_ptr_to_int(bld, y, t_i64, "")
      } else {
        y
      }
      llvm.builder.build_int_to_ptr(bld, f(bld, xi, yi, ""), t_ptr, "")
    } else {
      f(bld, x, y, "")
    }
  }
  // the runtime's dialect: the shift amount modulo the width (no poison)
  let amount = () => {
    let w = llvm.ir.get_int_type_width(llvm.values.type_of(x))
    llvm.builder.build_and(bld, y, llvm.values.const_int(llvm.values.type_of(x), w - 1, 0), "")
  }
  let raw_u = mir.layout.raw_unsigned(a.ty)
  match op {
    Add => arith(llvm.builder.build_add)
    Sub => arith(llvm.builder.build_sub)
    Mul => arith(llvm.builder.build_mul)
    Div => if raw_u { llvm.builder.build_u_div(bld, x, y, "") } else { arith(llvm.builder.build_sdiv) }
    Rem => if raw_u { llvm.builder.build_u_rem(bld, x, y, "") } else { llvm.builder.build_s_rem(bld, x, y, "") }
    Shl => llvm.builder.build_shl(bld, x, amount(), "")
    Shr => if raw_u { llvm.builder.build_l_shr(bld, x, amount(), "") } else { llvm.builder.build_a_shr(bld, x, amount(), "") }
    BitAnd => arith(llvm.builder.build_and)
    BitOr => arith(llvm.builder.build_or)
    BitXor => arith(llvm.builder.build_xor)
    Eq => cmp(llvm.INT_EQ)
    Ne => cmp(llvm.INT_NE)
    Lt => cmp(cc(llvm.INT_SLT, llvm.INT_ULT))
    Le => cmp(cc(llvm.INT_SLE, llvm.INT_ULE))
    Gt => cmp(cc(llvm.INT_SGT, llvm.INT_UGT))
    Ge => cmp(cc(llvm.INT_SGE, llvm.INT_UGE))
  }
}

// ---- calls ----

pub fn build_call(g: Gen, sig: Sig, callee: llvm.Value, args: [llvm.Value]): llvm.Value uses ffi {
  let c = llvm.builder.build_call2(g.b, sig.ty, callee, args, "")
  for (k, a) in sig.attrs { llvm.values.add_call_site_attribute(c, k, a) }
  c
}

fn call(g: var Gen, cl: mir.Callee, args: [mir.Ex], ret: mir.MTy): V uses ffi = match cl {
  Fn(f) => {
    let func = g.prog.funcs[f]
    let ps = params_of(func)
    let (fv, sig) = g.funcs[f]
    // live: the current body of `f` is in its table slot
    let slot_at = match g.live {
      some((t, s)) => match s.get(f) {
        some(slot) => some(t + slot * 8)
        none => none
      }
      none => none
    }
    let target = match slot_at {
      some(at) => {
        let p = llvm.values.const_int_to_ptr(llvm.values.const_int(g.t_i64, at, 0), g.t_ptr)
        load_ty(g, g.t_ptr, p)
      }
      none => fv
    }
    match func.abi {
      Auk => {
        let inplace = g.inplace[f]
        let (vals, out) = auk_args(&g, ps, args, func.ret, inplace)
        let c = build_call(g, sig, target, vals)
        auk_result(g, c, out, func.ret)
      }
      C => {
        let (_, pp, rp) = c_sig(&g, ps, func.ret)
        let (vals, out) = c_args(&g, pp, ps, args, rp, func.ret)
        let c = build_call(g, sig, target, vals)
        c_result(&g, c, out, rp, func.ret)
      }
    }
  }
  Indirect(code, ps) => {
    let cv = val(&g, code)
    let sig = auk_sig(g, ps, ret, none)
    let nothing = ps.map(_ => false)
    let (vals, out) = auk_args(&g, ps, args, ret, nothing)
    let c = build_call(g, sig, cv, vals)
    auk_result(g, c, out, ret)
  }
  CPtr(code) => {
    let cv = val(&g, code)
    let ps = args.map(a => a.ty)
    let (sig, pp, rp) = c_sig(&g, ps, ret)
    let (vals, out) = c_args(&g, pp, ps, args, rp, ret)
    let c = build_call(g, sig, cv, vals)
    c_result(&g, c, out, rp, ret)
  }
  Rt(sym) => {
    if rawgen.is_raw(sym) { return rawgen.call(&g, sym, args, ret) }
    match intrin.rt_inline(&g, sym, args, ret) {
      some(v) => return v
      none => {}
    }
    let ps = args.map(a => a.ty)
    let (sig, pp, rp) = c_sig(&g, ps, ret)
    let (vals, out) = c_args(&g, pp, ps, args, rp, ret)
    let fv = rt_func(&g, sym, sig)
    let c = build_call(g, sig, fv, vals)
    c_result(&g, c, out, rp, ret)
  }
}

/// A runtime function's declaration (with the signature of its first use; later calls with
/// another compatible signature call the same symbol with their own function type).
pub fn rt_func(g: var Gen, sym: str, sig: Sig): llvm.Value uses ffi {
  match g.rt_funcs.get(sym) {
    some(f) => return f
    none => {}
  }
  let f = llvm.ir.add_function(g.m, sym, sig.ty)
  for (k, a) in sig.attrs { llvm.values.add_attribute_at_index(f, k, a) }
  let fx = llvm.ATTRIBUTE_FUNCTION_INDEX
  llvm.values.add_attribute_at_index(f, fx, enum_attr(g, "nounwind"))
  if NORETURN.contains(sym) {
    llvm.values.add_attribute_at_index(f, fx, enum_attr(g, "noreturn"))
    llvm.values.add_attribute_at_index(f, fx, enum_attr(g, "cold"))
  }
  g.rt_funcs[sym] = f
  f
}

/// Arguments in the generated-function convention (and the result slot, if any). An
/// in-place parameter gets memory nothing else can reach during the call.
fn auk_args(
  g: var Gen,
  ps: [mir.MTy],
  args: [mir.Ex],
  ret: mir.MTy,
  inplace: [bool],
): ([llvm.Value], llvm.Value?) uses ffi {
  var vals: [llvm.Value] = []
  var out: llvm.Value? = none
  if is_agg(g, ret) {
    let a = temp(&g, ret)
    vals.push(a)
    out = a
  }
  for i, (p, a) in ps.zip(args) {
    if is_agg(g, p) {
      let private = if mir.is_place(a) { private_place(g, a) } else { true }
      let m = mem_of(&g, a)
      if inplace[i] && !private {
        let t = temp(&g, p)
        copy(&g, t, m, p)
        vals.push(t)
      } else {
        vals.push(m)
      }
    } else {
      let x = ex(&g, a)
      let s = scalar(g, p)!
      let v = scalar_of(&g, x, a.ty, p, s)
      vals.push(v)
    }
  }
  (vals, out)
}

/// Can nothing but this function reach `place` (a local whose address is never taken, or a
/// member of one)? An in-place parameter counts: nobody writes it during the call.
fn private_place(g: Gen, place: mir.Ex): bool {
  var b = place
  loop {
    match b.k {
      Field(x, _) => b = x
      _ => break
    }
  }
  match b.k {
    Var(v) => !g.addressed[v]
    _ => false
  }
}

fn auk_result(g: Gen, c: llvm.Value, out: llvm.Value?, ret: mir.MTy): V {
  match out {
    some(a) => return V.M(a)
    none => {}
  }
  if ret == mir.MTy.Void || scalar(g, ret) == none { V.Nil } else { V.S(c) }
}

/// Arguments in the C convention (and the struct-return slot, if any).
fn c_args(
  g: var Gen,
  pp: [mir.layout.CPass],
  ps: [mir.MTy],
  args: [mir.Ex],
  rp: mir.layout.CPass,
  ret: mir.MTy,
): ([llvm.Value], llvm.Value?) uses ffi {
  var vals: [llvm.Value] = []
  var out: llvm.Value? = none
  if rp == mir.layout.CPass.Sret {
    let a = temp(&g, ret)
    vals.push(a)
    out = a
  }
  for i, cp in pp {
    if i >= ps.len() || i >= args.len() { break }
    let p = ps[i]
    let a = args[i]
    match cp {
      Scalar(s) => {
        let x = ex(&g, a)
        let v = scalar_of(&g, x, a.ty, p, lt(g, s))
        vals.push(v)
      }
      Words(_) | Hfa(_, _) => {
        let m = mem_of(&g, a)
        for v in c_arg_vals(&g, cp, m, p) { vals.push(v) }
      }
      Sret | Mem => {
        // an aggregate in memory: a pointer to a copy (AArch64; x86-64 `byval` copies it
        // again, onto the stack)
        let m = mem_of(&g, a)
        let t = temp(&g, p)
        copy(&g, t, m, p)
        vals.push(t)
      }
      Nothing => {}
    }
  }
  (vals, out)
}

fn c_result(
  g: var Gen,
  c: llvm.Value,
  out: llvm.Value?,
  rp: mir.layout.CPass,
  ret: mir.MTy,
): V uses ffi {
  match out {
    some(a) => return V.M(a)
    none => {}
  }
  match rp {
    Nothing => V.Nil
    Scalar(_) => V.S(c)
    Words(_) | Hfa(_, _) => {
      let a = temp(&g, ret)
      if rp is mir.layout.CPass.Words(_) && c_parts(rp) == 1 {
        store(g, c, a)
      } else {
        for k in 0..c_parts(rp) {
          let v = llvm.builder.build_extract_value(g.b, c, k, "")
          store(g, v, gep(g, a, c_part_off(rp, k)))
        }
      }
      V.M(a)
    }
    Sret | Mem => mir.bug("unreachable")
  }
}

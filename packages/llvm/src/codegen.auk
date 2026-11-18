/// A piece of the Rust back end ported to Auk, as proof the bindings carry compiler code:
/// `Gen::bin` (binary operators on scalars), `truth`, `bool8` and `cstr_addr` from
/// `src/mir/llvm/codegen.rs`, over the same LLVM calls.

/// The cached LLVM types and the builder a function body is generated with (part of `Gen`).
pub struct Gen {
  cx: llvm.Context,
  m: llvm.Module,
  b: llvm.Builder,
  t_i1: llvm.Type,
  t_i8: llvm.Type,
  t_i64: llvm.Type,
  t_f64: llvm.Type,
  t_ptr: llvm.Type,
  cstrs: {str: llvm.Value},
}

/// MIR's binary operators (`mir::BOp`).
pub enum BOp { Add, Sub, Mul, Div, BitAnd, BitOr, BitXor, Eq, Ne, Lt, Le, Gt, Ge }

pub fn new(cx: llvm.Context, name: str): Gen uses ffi = Gen {
  cx,
  m: llvm.ir.module_create_with_name_in_context(name, cx),
  b: llvm.builder.create_builder_in_context(cx),
  t_i1: llvm.ir.int1_type_in_context(cx),
  t_i8: llvm.ir.int8_type_in_context(cx),
  t_i64: llvm.ir.int64_type_in_context(cx),
  t_f64: llvm.ir.double_type_in_context(cx),
  t_ptr: llvm.ir.pointer_type_in_context(cx, 0),
  cstrs: {},
}

/// An `i1` for a condition: `v` itself, or `v != 0`.
pub fn truth(g: Gen, v: llvm.Value): llvm.Value uses ffi {
  let t = llvm.values.type_of(v)
  if t == g.t_i1 { return v }
  llvm.builder.build_icmp(g.b, llvm.INT_NE, v, llvm.values.const_null(t), "")
}

/// A comparison's `i1` as Auk's `bool` (`i8`).
pub fn bool8(g: Gen, v: llvm.Value): llvm.Value uses ffi =
  llvm.builder.build_zext(g.b, v, g.t_i8, "")

/// `x op y`. `unsigned`: the operands are unsigned integers, chars or pointers (MIR's `a.ty`).
/// Floats use the ordered predicates (`!=` is unordered: NaN != NaN); arithmetic on pointers
/// goes through `i64`. Comparisons give `bool8`.
pub fn bin(g: Gen, op: BOp, x: llvm.Value, y: llvm.Value, unsigned: bool): llvm.Value uses ffi {
  let b = g.b
  if llvm.values.type_of(x) == g.t_f64 {
    let fcmp = (p: int) => bool8(g, llvm.builder.build_fcmp(b, p, x, y, ""))
    return match op {
      Add => llvm.builder.build_fadd(b, x, y, "")
      Sub => llvm.builder.build_fsub(b, x, y, "")
      Mul => llvm.builder.build_fmul(b, x, y, "")
      Div => llvm.builder.build_fdiv(b, x, y, "")
      Eq => fcmp(llvm.REAL_OEQ)
      Ne => fcmp(llvm.REAL_UNE)
      Lt => fcmp(llvm.REAL_OLT)
      Le => fcmp(llvm.REAL_OLE)
      Gt => fcmp(llvm.REAL_OGT)
      Ge => fcmp(llvm.REAL_OGE)
      _ => {
        assert false  // no bitwise operators on floats
        x
      }
    }
  }
  let cc = (s: int, u: int) => if unsigned { u } else { s }
  let icmp = (p: int) => bool8(g, llvm.builder.build_icmp(b, p, x, y, ""))
  let is_ptr = llvm.values.type_of(x) == g.t_ptr
  let arith = (f: (llvm.Builder, llvm.Value, llvm.Value, str) => llvm.Value) => {
    if is_ptr {
      let xi = llvm.builder.build_ptr_to_int(b, x, g.t_i64, "")
      let yi = if llvm.values.type_of(y) == g.t_ptr {
        llvm.builder.build_ptr_to_int(b, y, g.t_i64, "")
      } else {
        y
      }
      llvm.builder.build_int_to_ptr(b, f(b, xi, yi, ""), g.t_ptr, "")
    } else {
      f(b, x, y, "")
    }
  }
  match op {
    Add => arith(llvm.builder.build_add)
    Sub => arith(llvm.builder.build_sub)
    Mul => arith(llvm.builder.build_mul)
    Div => arith(llvm.builder.build_sdiv)
    BitAnd => arith(llvm.builder.build_and)
    BitOr => arith(llvm.builder.build_or)
    BitXor => arith(llvm.builder.build_xor)
    Eq => icmp(llvm.INT_EQ)
    Ne => icmp(llvm.INT_NE)
    Lt => icmp(cc(llvm.INT_SLT, llvm.INT_ULT))
    Le => icmp(cc(llvm.INT_SLE, llvm.INT_ULE))
    Gt => icmp(cc(llvm.INT_SGT, llvm.INT_UGT))
    Ge => icmp(cc(llvm.INT_SGE, llvm.INT_UGE))
  }
}

/// The address of a private, constant, NUL-terminated copy of `s` (one global per string).
pub fn cstr_addr(g: var Gen, s: str): llvm.Value uses ffi {
  match g.cstrs.get(s) {
    some(v) => return v
    none => {}
  }
  let init = llvm.values.const_string_in_context2(g.cx, s, 0)
  let v = llvm.values.add_global(g.m, llvm.values.type_of(init), "str")
  llvm.values.set_initializer(v, init)
  llvm.values.set_linkage(v, llvm.PRIVATE_LINKAGE)
  llvm.values.set_global_constant(v, 1)
  llvm.values.set_unnamed_address(v, llvm.GLOBAL_UNNAMED_ADDR)
  llvm.values.set_alignment(v, 1)
  g.cstrs[s] = v
  v
}

// ---- tests: each operator compiled to a function, JIT-compiled, called ----

/// A function `name(a, b)` of type `(ty, ty) -> ret` whose body is `body(a, b)`.
fn define(
  g: Gen,
  name: str,
  ty: llvm.Type,
  ret: llvm.Type,
  body: (llvm.Value, llvm.Value) => llvm.Value,
) uses ffi {
  let f = llvm.ir.add_function(g.m, name, llvm.ir.function_type(ret, [ty, ty], 0))
  llvm.builder.position_builder_at_end(
    g.b,
    llvm.values.append_basic_block_in_context(g.cx, f, "entry"),
  )
  let _ = llvm.builder.build_ret(
    g.b,
    body(llvm.values.get_param(f, 0), llvm.values.get_param(f, 1)),
  )
}

extern fn call_b(f: ffi.Ptr, a: int, b: int): int = "uint8_t (*)(int64_t, int64_t)"
extern fn call_f(f: ffi.Ptr, a: float, b: float): float = "double (*)(double, double)"
extern fn call_fb(f: ffi.Ptr, a: float, b: float): int = "uint8_t (*)(double, double)"
extern fn call_p(f: ffi.Ptr, a: ffi.Ptr, b: int): ffi.Ptr = "void *(*)(void *, int64_t)"
extern fn call_s(f: ffi.Ptr): str = "const char *(*)(void)"

test "ported bin: signed and unsigned compares, floats, pointer arithmetic, strings" {
  let cx = llvm.ir.context_create()
  var g = new(cx, "ops")
  define(g, "sub", g.t_i64, g.t_i64, (a, b) => bin(g, Sub, a, b, false))
  define(g, "slt", g.t_i64, g.t_i8, (a, b) => bin(g, Lt, a, b, false))
  define(g, "ult", g.t_i64, g.t_i8, (a, b) => bin(g, Lt, a, b, true))
  define(g, "xor", g.t_i64, g.t_i64, (a, b) => bin(g, BitXor, a, b, false))
  define(g, "fdiv", g.t_f64, g.t_f64, (a, b) => bin(g, Div, a, b, false))
  define(g, "fne", g.t_f64, g.t_i8, (a, b) => bin(g, Ne, a, b, false))
  let pf = llvm.ir.add_function(g.m, "padd", llvm.ir.function_type(g.t_ptr, [g.t_ptr, g.t_i64], 0))
  llvm.builder.position_builder_at_end(
    g.b,
    llvm.values.append_basic_block_in_context(cx, pf, "entry"),
  )
  llvm.builder.build_ret(
    g.b,
    bin(g, Add, llvm.values.get_param(pf, 0), llvm.values.get_param(pf, 1), true),
  )
  let hf = llvm.ir.add_function(g.m, "hello", llvm.ir.function_type(g.t_ptr, [], 0))
  llvm.builder.position_builder_at_end(
    g.b,
    llvm.values.append_basic_block_in_context(cx, hf, "entry"),
  )
  let s1 = cstr_addr(&g, "hello")
  assert cstr_addr(&g, "hello") == s1
  llvm.builder.build_ret(g.b, s1)
  llvm.kit.verify(g.m)?
  assert llvm.ir.print_module_to_string(
    g.m,
  ).contains("@str = private unnamed_addr constant [6 x i8] c\"hello\\00\", align 1")
  let tm = llvm.kit.host_machine(Default)?
  llvm.kit.set_target(g.m, tm)
  let obj = llvm.kit.emit(tm, g.m, false)?
  let jt = llvm.kit.jit()?
  llvm.kit.add_object(jt, obj)?
  let at = (n: str) => llvm.kit.lookup(jt, n)!
  assert llvm.kit.call_ii_i(at("sub"), 50, 8) == 42
  assert (call_b(at("slt"), -1, 1), call_b(at("ult"), -1, 1)) == (1, 0)
  assert llvm.kit.call_ii_i(at("xor"), 0b1100, 0b1010) == 0b0110
  assert call_f(at("fdiv"), 1.0, 8.0) == 0.125
  assert (call_fb(at("fne"), 1.0, 1.0), call_fb(at("fne"), 0.0 / 0.0, 0.0 / 0.0)) == (0, 1)
  let base = ffi.alloc(16)
  assert ffi.addr(call_p(at("padd"), base, 12)) == ffi.addr(base) + 12
  ffi.free(base)
  assert call_s(at("hello")) == "hello"
  llvm.kit.close(jt)?
  llvm.target.dispose_target_machine(tm)
  llvm.builder.dispose_builder(g.b)
  llvm.ir.dispose_module(g.m)
  llvm.ir.context_dispose(cx)
}

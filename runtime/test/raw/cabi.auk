// The C calling convention for raw structs by value (`auk build --lib`, linked with cabi_main.c
// and compiled by cc): float members (x86-64 SysV SSE eightbytes, AArch64 homogeneous float
// aggregates), mixed float/integer eightbytes, aggregates in memory, and arguments that no
// longer fit in the registers left. Both directions: C calls `auk_*`, `auk_calls_c` calls the
// `c_*` twins. Every function returns its argument with each member plus one.

raw struct F1 { a: f32 }
raw struct F2 { a: f32, b: f32 }
raw struct F3 { a: f32, b: f32, c: f32 }
raw struct F4 { a: f32, b: f32, c: f32, d: f32 }
raw struct F5 { a: f32, b: f32, c: f32, d: f32, e: f32 }
raw struct D1 { a: float }
raw struct D2 { a: float, b: float }
raw struct D3 { a: float, b: float, c: float }
raw struct D4 { a: float, b: float, c: float, d: float }
raw struct D5 { a: float, b: float, c: float, d: float, e: float }
raw struct DI { a: float, b: i64 }
raw struct ID { a: i64, b: float }
raw struct FI { a: f32, b: i32 }
raw struct FFI { a: f32, b: f32, c: i32 }
raw struct DF { a: float, b: f32 }
raw struct FD { a: f32, b: float }
raw struct FA { a: [f32; 4] }
raw struct NF { a: F2, b: F2 }
raw struct II { a: i64, b: i64 }
raw struct I3 { a: i64, b: i64, c: i64 }
raw union U { f: f32, i: i32 }

fn f2_inc(x: F2): F2 = F2 { a: x.a + 1.0, b: x.b + 1.0 }

export fn auk_f1(x: F1): F1 = F1 { a: x.a + 1.0 }
export fn auk_f2(x: F2): F2 = f2_inc(x)
export fn auk_f3(x: F3): F3 = F3 { a: x.a + 1.0, b: x.b + 1.0, c: x.c + 1.0 }
export fn auk_f4(x: F4): F4 = F4 { a: x.a + 1.0, b: x.b + 1.0, c: x.c + 1.0, d: x.d + 1.0 }
export fn auk_f5(x: F5): F5 = F5 { a: x.a + 1.0, b: x.b + 1.0, c: x.c + 1.0, d: x.d + 1.0, e: x.e + 1.0 }
export fn auk_d1(x: D1): D1 = D1 { a: x.a + 1.0 }
export fn auk_d2(x: D2): D2 = D2 { a: x.a + 1.0, b: x.b + 1.0 }
export fn auk_d3(x: D3): D3 = D3 { a: x.a + 1.0, b: x.b + 1.0, c: x.c + 1.0 }
export fn auk_d4(x: D4): D4 = D4 { a: x.a + 1.0, b: x.b + 1.0, c: x.c + 1.0, d: x.d + 1.0 }
export fn auk_d5(x: D5): D5 = D5 { a: x.a + 1.0, b: x.b + 1.0, c: x.c + 1.0, d: x.d + 1.0, e: x.e + 1.0 }
export fn auk_di(x: DI): DI = DI { a: x.a + 1.0, b: x.b + 1 }
export fn auk_id(x: ID): ID = ID { a: x.a + 1, b: x.b + 1.0 }
export fn auk_fi(x: FI): FI = FI { a: x.a + 1.0, b: x.b + 1 }
export fn auk_ffi(x: FFI): FFI = FFI { a: x.a + 1.0, b: x.b + 1.0, c: x.c + 1 }
export fn auk_df(x: DF): DF = DF { a: x.a + 1.0, b: x.b + 1.0 }
export fn auk_fd(x: FD): FD = FD { a: x.a + 1.0, b: x.b + 1.0 }
export fn auk_fa(x: FA): FA uses raw {
  var y = x
  let p: raw.Ptr<f32> = raw.cast(raw.addr_of(&y))
  p.at(0) = p.at(0) + 1.0
  p.at(1) = p.at(1) + 1.0
  p.at(2) = p.at(2) + 1.0
  p.at(3) = p.at(3) + 1.0
  y
}
export fn auk_nf(x: NF): NF = NF { a: f2_inc(x.a), b: f2_inc(x.b) }
export fn auk_ii(x: II): II = II { a: x.a + 1, b: x.b + 1 }
export fn auk_i3(x: I3): I3 = I3 { a: x.a + 1, b: x.b + 1, c: x.c + 1 }
export fn auk_u(x: U): U = U { i: x.i + 1 }

// registers running out: x86-64 passes the struct in memory (and later scalars still take the
// registers left); AArch64 puts the whole struct on the stack (and later ones too)
export fn auk_many_d(a: float, b: float, c: float, d: float, e: float, f: float, g: float, x: D2, h: float): float =
  g * 1000.0 + x.a * 100.0 + x.b * 10.0 + h
export fn auk_many_f(a: float, b: float, c: float, d: float, e: float, f: float, g: float, x: F4, h: f32): float =
  g * 100000.0 + float(x.a) * 10000.0 + float(x.b) * 1000.0 + float(x.c) * 100.0 + float(x.d) * 10.0 + float(h)
export fn auk_many_i(a: i64, b: i64, c: i64, d: i64, e: i64, x: II, h: i64): i64 = e * 1000 + x.a * 100 + x.b * 10 + h
export fn auk_many_i7(a: i64, b: i64, c: i64, d: i64, e: i64, f: i64, g: i64, x: II, h: i64): i64 =
  g * 1000 + x.a * 100 + x.b * 10 + h
export fn auk_many_di(a: i64, b: i64, c: i64, d: i64, e: i64, f: i64, x: DI, h: float): float =
  float(f) * 1000.0 + x.a * 100.0 + float(x.b) * 10.0 + h
export fn auk_many_big(x: I3, a: i64, b: i64, c: i64, d: i64, e: i64, f: i64, y: F5, h: float): float =
  float(x.a + x.b + x.c + f) + float(y.a + y.e) * 100.0 + h * 1000.0

// the same functions in C
extern fn c_f1(x: F1): F1 = "F1 c_f1(F1)"
extern fn c_f2(x: F2): F2 = "F2 c_f2(F2)"
extern fn c_f3(x: F3): F3 = "F3 c_f3(F3)"
extern fn c_f4(x: F4): F4 = "F4 c_f4(F4)"
extern fn c_f5(x: F5): F5 = "F5 c_f5(F5)"
extern fn c_d1(x: D1): D1 = "D1 c_d1(D1)"
extern fn c_d2(x: D2): D2 = "D2 c_d2(D2)"
extern fn c_d3(x: D3): D3 = "D3 c_d3(D3)"
extern fn c_d4(x: D4): D4 = "D4 c_d4(D4)"
extern fn c_d5(x: D5): D5 = "D5 c_d5(D5)"
extern fn c_di(x: DI): DI = "DI c_di(DI)"
extern fn c_id(x: ID): ID = "ID c_id(ID)"
extern fn c_fi(x: FI): FI = "FI c_fi(FI)"
extern fn c_ffi(x: FFI): FFI = "FFI c_ffi(FFI)"
extern fn c_df(x: DF): DF = "DF c_df(DF)"
extern fn c_fd(x: FD): FD = "FD c_fd(FD)"
extern fn c_fa(x: FA): FA = "FA c_fa(FA)"
extern fn c_nf(x: NF): NF = "NF c_nf(NF)"
extern fn c_ii(x: II): II = "II c_ii(II)"
extern fn c_i3(x: I3): I3 = "I3 c_i3(I3)"
extern fn c_u(x: U): U = "U c_u(U)"
extern fn c_many_d(a: float, b: float, c: float, d: float, e: float, f: float, g: float, x: D2, h: float): float =
  "double c_many_d(double, double, double, double, double, double, double, D2, double)"
extern fn c_many_f(a: float, b: float, c: float, d: float, e: float, f: float, g: float, x: F4, h: f32): float =
  "double c_many_f(double, double, double, double, double, double, double, F4, float)"
extern fn c_many_i(a: i64, b: i64, c: i64, d: i64, e: i64, x: II, h: i64): i64 =
  "int64_t c_many_i(int64_t, int64_t, int64_t, int64_t, int64_t, II, int64_t)"
extern fn c_many_i7(a: i64, b: i64, c: i64, d: i64, e: i64, f: i64, g: i64, x: II, h: i64): i64 =
  "int64_t c_many_i7(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, II, int64_t)"
extern fn c_many_di(a: i64, b: i64, c: i64, d: i64, e: i64, f: i64, x: DI, h: float): float =
  "double c_many_di(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, DI, double)"
extern fn c_many_big(x: I3, a: i64, b: i64, c: i64, d: i64, e: i64, f: i64, y: F5, h: float): float =
  "double c_many_big(I3, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, F5, double)"

/// Calls each C function; 0, or the number of the first wrong result.
export fn auk_calls_c(): i32 uses raw, ffi {
  if c_f1(F1 { a: 1.5 }).a != 2.5 { return 1 }
  let f2 = c_f2(F2 { a: 1.5, b: -2.0 })
  if f2.a != 2.5 || f2.b != -1.0 { return 2 }
  let f3 = c_f3(F3 { a: 1.0, b: 2.0, c: 3.0 })
  if f3.a != 2.0 || f3.b != 3.0 || f3.c != 4.0 { return 3 }
  let f4 = c_f4(F4 { a: 1.0, b: 2.0, c: 3.0, d: 4.0 })
  if f4.a != 2.0 || f4.b != 3.0 || f4.c != 4.0 || f4.d != 5.0 { return 4 }
  let f5 = c_f5(F5 { a: 1.0, b: 2.0, c: 3.0, d: 4.0, e: 5.0 })
  if f5.a != 2.0 || f5.b != 3.0 || f5.c != 4.0 || f5.d != 5.0 || f5.e != 6.0 { return 5 }
  if c_d1(D1 { a: 1.5 }).a != 2.5 { return 6 }
  let d2 = c_d2(D2 { a: 1.0, b: 2.0 })
  if d2.a != 2.0 || d2.b != 3.0 { return 7 }
  let d3 = c_d3(D3 { a: 1.0, b: 2.0, c: 3.0 })
  if d3.a != 2.0 || d3.b != 3.0 || d3.c != 4.0 { return 8 }
  let d4 = c_d4(D4 { a: 1.0, b: 2.0, c: 3.0, d: 4.0 })
  if d4.a != 2.0 || d4.b != 3.0 || d4.c != 4.0 || d4.d != 5.0 { return 9 }
  let d5 = c_d5(D5 { a: 1.0, b: 2.0, c: 3.0, d: 4.0, e: 5.0 })
  if d5.a != 2.0 || d5.b != 3.0 || d5.c != 4.0 || d5.d != 5.0 || d5.e != 6.0 { return 10 }
  let di = c_di(DI { a: 1.5, b: 7 })
  if di.a != 2.5 || di.b != 8 { return 11 }
  let id = c_id(ID { a: 7, b: 1.5 })
  if id.a != 8 || id.b != 2.5 { return 12 }
  let fi = c_fi(FI { a: 1.5, b: 7 })
  if fi.a != 2.5 || fi.b != 8 { return 13 }
  let ffi_ = c_ffi(FFI { a: 1.5, b: 2.5, c: 7 })
  if ffi_.a != 2.5 || ffi_.b != 3.5 || ffi_.c != 8 { return 14 }
  let df = c_df(DF { a: 1.5, b: 2.5 })
  if df.a != 2.5 || df.b != 3.5 { return 15 }
  let fd = c_fd(FD { a: 1.5, b: 2.5 })
  if fd.a != 2.5 || fd.b != 3.5 { return 16 }
  var fa = FA {}
  let p: raw.Ptr<f32> = raw.cast(raw.addr_of(&fa))
  p.at(0) = 1.0
  p.at(1) = 2.0
  p.at(2) = 3.0
  p.at(3) = 4.0
  fa = c_fa(fa)
  if p.at(0) != 2.0 || p.at(1) != 3.0 || p.at(2) != 4.0 || p.at(3) != 5.0 { return 17 }
  let nf = c_nf(NF { a: F2 { a: 1.0, b: 2.0 }, b: F2 { a: 3.0, b: 4.0 } })
  if nf.a.a != 2.0 || nf.a.b != 3.0 || nf.b.a != 4.0 || nf.b.b != 5.0 { return 18 }
  let ii = c_ii(II { a: 1, b: 2 })
  if ii.a != 2 || ii.b != 3 { return 19 }
  let i3 = c_i3(I3 { a: 1, b: 2, c: 3 })
  if i3.a != 2 || i3.b != 3 || i3.c != 4 { return 20 }
  if c_u(U { i: 41 }).i != 42 { return 21 }
  if c_many_d(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, D2 { a: 8.0, b: 9.0 }, 3.0) != 7893.0 { return 22 }
  if c_many_f(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, F4 { a: 1.0, b: 2.0, c: 3.0, d: 4.0 }, 5.0) != 712345.0 { return 23 }
  if c_many_i(1, 2, 3, 4, 5, II { a: 6, b: 7 }, 8) != 5678 { return 24 }
  if c_many_i7(1, 2, 3, 4, 5, 6, 7, II { a: 8, b: 9 }, 3) != 7893 { return 25 }
  if c_many_di(1, 2, 3, 4, 5, 6, DI { a: 7.0, b: 8 }, 9.0) != 6789.0 { return 26 }
  if c_many_big(I3 { a: 1, b: 2, c: 3 }, 0, 0, 0, 0, 0, 4, F5 { a: 1.0, e: 2.0 }, 5.0) != 5310.0 { return 27 }
  0
}

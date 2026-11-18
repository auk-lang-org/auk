// Every marshalling case of user-level FFI against tests/fixtures/ffi/testlib.c (tests/ffi.rs).

extern fn i8(x: int): int = "int8_t t_i8(int8_t)"
extern fn u8(x: int): int = "uint8_t t_u8(uint8_t)"
extern fn i16(x: int): int = "int16_t t_i16(int16_t)"
extern fn u16(x: int): int = "uint16_t t_u16(uint16_t)"
extern fn i32(x: int): int = "int32_t t_i32(int32_t)"
extern fn u32(x: int): int = "uint32_t t_u32(uint32_t)"
extern fn u64(x: int): int = "uint64_t t_u64(uint64_t)"
extern fn add(a: int, b: int): int = "long long t_add(long long a, long long b)"
extern fn next_char(c: int): int = "char t_next_char(char)"
extern fn not(b: bool): bool = "bool t_not(bool)"
extern fn half(x: float): float = "float t_half(float)"
extern fn mix(a: int, b: float, c: float, d: int, e: bool): float = "double t_mix(int8_t, float, double, uint16_t, _Bool)"

extern fn greet(name: str): str = "const char *t_greet(const char *name)"
extern fn null_str(): str? = "const char *t_null_str(void)"
extern fn null_str_panics(): str = "const char *t_null_str(void)"
extern fn is_null(s: str?): int = "int t_is_null(const char *)"

extern fn dup(s: str): str = "char *t_dup(const char *) +free(t_free)"
extern fn frees(): int = "int t_frees(void)"

extern fn out(x: int, twice: var int, msg: var str?): int = "int t_out(int, int *, char **) +free(t_free)"
extern fn scale(x: var float, y: var float) = "void t_scale(double *, float *)"
extern fn flip(b: var bool) = "void t_flip(bool *)"

extern type Thing = "struct thing *"
extern fn new(id: int): Thing = "struct thing *t_new(int)"
extern fn id(t: Thing): int = "int t_id(const struct thing *)"
extern fn del(t: Thing) = "void t_del(struct thing *)"
extern fn make(id: int, out: var Thing?): int = "int t_make(int, struct thing **)"
extern fn maybe(id: int): Thing? = "struct thing *t_maybe(int)"
extern fn id_or(t: Thing?, dflt: int): int = "int t_id_or(const struct thing *, int)"

extern fn sum_ids(ts: [Thing], n: int): int = "int t_sum_ids(struct thing *const *ts, unsigned n)"
extern fn fill(xs: var [int], n: int) = "void t_fill(int32_t *, size_t)"
extern fn sumf(xs: [float], n: int): float = "double t_sumf(const float *, size_t)"
extern fn halve(xs: var [float], n: int) = "void t_halve(float *, size_t)"
extern fn sum_i64(xs: [int], n: int): int = "long long t_sum_i64(const int64_t *, size_t)"
extern fn count_true(bs: [bool], n: int): int = "int t_count_true(const bool *, size_t)"
extern fn reverse_handles(ts: var [Thing], n: int) = "void t_reverse_handles(struct thing **, size_t)"

extern fn checksum(buf: [int], n: int): int = "unsigned t_checksum(const void *, size_t)"
extern fn bytes_out(buf: var [int], n: int) = "void t_bytes_out(uint8_t *, size_t)"
extern fn blob(n: var int): ffi.Ptr = "const void *t_blob(size_t *n)"

fn ints() uses ffi {
  print("ints {i8(200)} {u8(-1)} {i16(70000)} {u16(-2)} {i32(4294967295)} {u32(-1)} {u64(-1)} {add(2, 40)} {next_char(65)}")
}

fn scalars() uses ffi {
  print("scalars {not(true)} {not(false)} {half(3.0)} {mix(-1, 0.5, 0.25, 65535, true)}")
}

fn strings() uses ffi {
  print(greet("Auk ✓"))
  print(null_str() else "none")
  print("null param {is_null(none)} {is_null(some("x"))}")
  let d = dup("owned")
  print("{d} freed {frees()}")
}

fn outs() uses ffi {
  var n = 0
  var msg: str? = some("old")
  out(21, &n, &msg)
  print("out {n} {msg else "none"} freed {frees()}")
  out(-1, &n, &msg)
  print("out {n} {msg else "none"} freed {frees()}")
  var x = 1.5
  var y = 2.0
  scale(&x, &y)
  var b = false
  flip(&b)
  print("scaled {x} {y} {b}")
}

fn handles() uses ffi {
  let a = new(7)
  var m: Thing? = none
  print("made {make(9, &m)} {make(-1, &m)}")
  print("maybe {maybe(-1) is none} {id(maybe(3)!)}")
  print("id_or {id_or(none, 5)} {id_or(some(a), 5)}")
  let b = new(9)
  var ts = [a, b, new(11)]
  print("sum {sum_ids(ts, ts.len())} same {a == a} {a == b}")
  reverse_handles(&ts, ts.len())
  print("reversed {ts.map(id)}")
  print("hex {"{ffi.null}"}")
  for t in ts { del(t) }
}

fn lists() uses ffi {
  var xs = [1, 2, -3]
  let keep = xs
  fill(&xs, xs.len())
  print("fill {xs} kept {keep}")
  var fs = [1.0, 3.0]
  halve(&fs, fs.len())
  print("floats {sumf([0.5, 0.25], 2)} {fs} {sum_i64([1, 2, 3000000000000], 3)} {count_true([true, false, true], 3)}")
  var empty: [int] = []
  fill(&empty, 0)
  print("empty {empty} {sum_i64([], 0)}")
}

fn buffers() uses ffi {
  print("checksum {checksum([1, 2, 3], 3)}")
  var buf = [0, 0, 0]
  bytes_out(&buf, buf.len())
  var n = 0
  let p = blob(&n)
  print("bytes {buf} {ffi.bytes(p, n)}")
  let q = ffi.from_bytes([104, 105, 0])
  print("cstr {ffi.cstr(q)}")
  ffi.free(q)
}

fn main(args: [str]) uses ffi {
  if args.len() > 1 {
    print(null_str_panics())
  }
  ints()
  scalars()
  strings()
  outs()
  handles()
  lists()
  buffers()
}

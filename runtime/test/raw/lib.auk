// A library of the runtime's dialect, built with `auk build --lib` and called from C
// (lib_main.c): C layouts checked against C's own, raw structs by value both ways, C calling
// back through a `raw.Fn`, Auk calling C, globals, thread-locals and atomics across pthreads.

raw struct Header { rc: i64, kind: u32, flags: u32 }
raw struct Str { h: Header, len_bytes: i64, len_chars: i64, is_ascii: bool, data: [u8; ..] }
raw union Value { i: i64, f: float, s: raw.Ptr<Str> }
raw struct Mixed { a: u8, b: i16, c: i32, d: u8, e: i64, f: f32, g: [u16; 3] }
raw struct V2 { x: float, y: float }
raw struct F2 { x: f32, y: f32 }
raw struct Big { a: i64, b: i64, c: i64, d: u8 }
raw struct Small { a: i32, b: u8 }

raw assert raw.size_of<Str>() == 40
raw assert raw.offset_of<Str>(.data) == 33

/// The layouts, for C to compare with sizeof/offsetof.
export fn auk_size(k: i32): i64 = match int(k) {
  0 => i64(raw.size_of<Header>())
  1 => i64(raw.size_of<Str>())
  2 => i64(raw.offset_of<Str>(.data))
  3 => i64(raw.size_of<Value>())
  4 => i64(raw.size_of<Mixed>())
  5 => i64(raw.offset_of<Mixed>(.b))
  6 => i64(raw.offset_of<Mixed>(.c))
  7 => i64(raw.offset_of<Mixed>(.d))
  8 => i64(raw.offset_of<Mixed>(.e))
  9 => i64(raw.offset_of<Mixed>(.f))
  10 => i64(raw.offset_of<Mixed>(.g))
  11 => i64(raw.align_of<Mixed>())
  _ => -1
}

// by value, in and out
export fn auk_v2_add(a: V2, b: V2): V2 = V2 { x: a.x + b.x, y: a.y + b.y }
export fn auk_f2_scale(a: F2, k: f32): F2 = F2 { x: a.x * k, y: a.y * k }
export fn auk_big_sum(b: Big): i64 = b.a + b.b + b.c + i64(b.d)
inline export fn auk_mk_big(n: i64): Big = Big { a: n, b: n * 2, c: n * 3, d: 4 }
export fn auk_small(s: Small, k: bool): Small = Small { a: s.a + 1, b: if k { s.b } else { 0 } }
export fn auk_value_f(v: Value): float = v.f
inline export fn auk_str_len(s: raw.Ptr<Str>): i64 uses raw = s.len_chars

// C functions (lib_main.c) called from Auk, by value and through a callback
extern fn c_v2_sub(a: V2, b: V2): V2 = "struct v2 c_v2_sub(struct v2, struct v2)"
extern fn c_apply(f: raw.Fn<(i32) => i32>, x: i32): i32 = "int c_apply(int (*f)(int), int)"
export fn auk_twice(x: i32): i32 = x * 2

export fn auk_calls_c(): i32 uses raw, ffi {
  let d = c_v2_sub(V2 { x: 5.0, y: 7.0 }, V2 { x: 1.5, y: 2.0 })
  if d.x != 3.5 || d.y != 5.0 { return 1 }
  if c_apply(raw.fn_of(auk_twice), 21) != 42 { return 2 }
  let f = raw.fn_of(auk_twice)
  if f(4) != 8 { return 3 }
  0
}

// globals and thread-locals across threads
raw var counter: i64 = 0
raw thread var mine: i64 = 100
export var auk_flag: i32 = 7
// a table of function pointers, filled in at link time (no code runs at startup)
raw struct Ops { twice: raw.Fn<(i32) => i32>, flag: raw.Ptr<i32> }
export var auk_ops: Ops = Ops { twice: raw.fn_of(auk_twice), flag: raw.addr_of(&auk_flag) }

export fn auk_bump(n: i64): i64 uses raw {
  var i: i64 = 0
  while i < n {
    mine += 1
    let _ = raw.atomic_add(raw.addr_of(&counter), 1, raw.Order.Relaxed)
    i += 1
  }
  mine
}

export fn auk_total(): i64 uses raw = raw.atomic_load(raw.addr_of(&counter), raw.Order.SeqCst)

// pthreads from Auk: a C start routine is an `export fn`
extern fn pthread_create(t: raw.Ptr<u64>, attr: raw.Ptr<()>, f: raw.Fn<(raw.Ptr<()>) => raw.Ptr<()>>, arg: raw.Ptr<()>): i32 =
  "int pthread_create(void *, const void *, void *(*start)(void *), void *)"
extern fn pthread_join(t: u64, out: raw.Ptr<()>): i32 = "int pthread_join(uint64_t, void *)"

export fn auk_worker(arg: raw.Ptr<()>): raw.Ptr<()> uses raw {
  let n = auk_bump(1000)
  raw.from_int(int(n))
}

export fn auk_spawn(n: i64): i64 uses raw, ffi {
  let ts: raw.Ptr<u64> = raw.cast(raw.alloc(n * 8))
  var i: i64 = 0
  while i < n {
    if pthread_create(ts.offset(i), raw.null(), raw.fn_of(auk_worker), raw.null()) != 0 { return -1 }
    i += 1
  }
  i = 0
  while i < n {
    let _ = pthread_join(ts.at(i), raw.null())
    i += 1
  }
  raw.free(ts)
  auk_total()
}

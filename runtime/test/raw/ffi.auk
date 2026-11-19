// C prototypes over raw types: any `T *` is a `raw.Ptr`, C integers fixed-width ones of their
// width, a C struct by value a raw struct, a function pointer a `raw.Fn` (a callback into Auk).

raw struct DivT { quot: i32, rem: i32 }

extern fn c_div(a: i32, b: i32): DivT = "div_t div(int, int)"
extern fn c_qsort(base: raw.Ptr<i64>, n: usize, size: usize, cmp: raw.Fn<(raw.Ptr<i64>, raw.Ptr<i64>) => i32>) =
  "void qsort(void *, size_t, size_t, int (*compar)(const void *, const void *))"
extern fn c_strlen(s: raw.Ptr<u8>): usize = "size_t strlen(const char *)"

export fn by_value(a: raw.Ptr<i64>, b: raw.Ptr<i64>): i32 uses raw {
  let x = a.load()
  let y = b.load()
  if x < y { -1 } else if x > y { 1 } else { 0 }
}

fn run(): int uses raw, ffi {
  let d = c_div(17, 5)
  if d.quot != 3 || d.rem != 2 { return 1 }
  let xs: raw.Ptr<i64> = raw.cast(raw.alloc(8 * 5))
  xs.at(0) = 5
  xs.at(1) = -2
  xs.at(2) = 9
  xs.at(3) = 0
  xs.at(4) = 3
  c_qsort(xs, 5, 8, raw.fn_of(by_value))
  if xs.at(0) != -2 || xs.at(1) != 0 || xs.at(2) != 3 || xs.at(3) != 5 || xs.at(4) != 9 { return 2 }
  let s: raw.Ptr<u8> = raw.cast(xs)
  s.at(0) = 104
  s.at(1) = 105
  s.at(2) = 0
  if c_strlen(s) != 2 { return 3 }
  // a string literal where a `raw.Ptr<u8>` is expected is a C string constant
  if c_strlen("hello, C") != 8 { return 4 }
  let msg: raw.Ptr<u8> = "\u{e9}t\u{e9}\n"
  if c_strlen(msg) != 6 || msg.at(5) != 10 || msg.at(6) != 0 { return 5 }
  raw.free(xs)
  0
}

fn main(): int uses raw, ffi = run()

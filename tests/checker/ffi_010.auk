
extern fn make_str(f: ffi.Ptr, s: str, n: int): ffi.Ptr = "void *(*)(const char *, int64_t)"
extern fn str_len(f: ffi.Ptr, s: ffi.Ptr): int = "int64_t (*)(void *)"
extern fn release(f: ffi.Ptr, p: ffi.Ptr) = "void (*)(void *)"

fn main() uses ffi {
  let s = make_str(ffi.symbol("auk_str_from_bytes")!, "héllo", 6)
  print(str_len(ffi.symbol("auk_str_len")!, s))
  release(ffi.symbol("auk_release")!, s)
  print("{ffi.symbol("strlen") != none} {ffi.symbol("auk_no_such_symbol") == none}")
}

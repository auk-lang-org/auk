
extern fn c_abs(n: int): int = "int abs(int)"
extern fn strlen(s: str): int = "size_t strlen(const char *)"
extern fn getenv(k: str): str? = "char *getenv(const char *)"
extern fn malloc(n: int): ffi.Ptr? = "void *malloc(size_t)"
extern fn free(p: ffi.Ptr) = "void free(void *)"

fn main() uses ffi {
  print("{c_abs(-5)} {c_abs(4294967296 + 7)} {strlen("héllo")}")
  print("{getenv("AUK_FFI_TEST") else "unset"} {getenv("AUK_FFI_NOT_SET") else "unset"}")
  let p = malloc(16)!
  ffi.write_i64(p, 8, 99)
  ffi.write_u8(p, 0, 300)
  print("{p.is_null()} {p == ffi.null} {ffi.null.is_null()} {ffi.read_i64(p, 8)} {ffi.read_u8(p, 0)}")
  free(p)
}

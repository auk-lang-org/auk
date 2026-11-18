// The self-hosted back end's corpus: calls to C (libc), C pointers, a call by address
// (`"T (*)(..)"`), a cast prototype and an embedded file.

extern type File = "FILE *"

extern fn c_strlen(s: str): int = "size_t strlen(const char *)"
extern fn c_labs(n: int): int = "long labs(long)"
extern fn c_atof(s: str): float = "double atof(const char *)"
extern fn c_getenv(name: str): str? = "char *getenv(const char *)"
extern fn c_fdopen(fd: int, mode: str): File? = "FILE *fdopen(int, const char *)"
extern fn c_fputs(s: str, f: File): int = "int fputs(const char *, FILE *)"
extern fn c_fflush(f: File): int = "int fflush(FILE *)"
extern fn file_ptr(f: File): ffi.Ptr = "(void *)"
extern fn call_labs(f: ffi.Ptr, n: int): int = "long (*)(long)"
extern fn call_pow(f: ffi.Ptr, x: float, y: float): float = "double (*)(double, double)"
extern fn me(): str = "#embed ffi.auk"
extern fn me_len(): int = "#embed ffi.auk"
extern fn me_bytes(): [int] = "#embed ffi.auk"

fn main() uses ffi {
  print(c_strlen("hello, world"))
  print(c_labs(-42))
  print(c_atof("2.5") * 2.0)
  print(c_getenv("AUK_NO_SUCH_VARIABLE_HERE") else "unset")
  let out = c_fdopen(1, "w")!
  print(!ffi.is_null(file_ptr(out)))
  c_fflush(out)
  let labs = ffi.symbol("labs")!
  print(call_labs(labs, -7))
  print(call_pow(ffi.symbol("pow")!, 2.0, 10.0))
  print(me().lines()[0])
  print(me_len() == me_bytes().len())
  let p = ffi.alloc(16)
  ffi.write_i64(p, 0, 123)
  ffi.write_f64(p, 8, 0.5)
  print((ffi.read_i64(p, 0), ffi.read_f64(p, 8)))
  ffi.free(p)
}

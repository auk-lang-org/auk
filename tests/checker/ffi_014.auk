extern type Db = "sqlite3 *"
extern fn a(x: int): ffi.Ptr = "(void *)"
extern fn b(x: ffi.Ptr): Db = "(void *)"
extern fn c(x: ffi.Ptr, y: ffi.Ptr): Db = "(sqlite3 *)"
extern fn d(x: ffi.Ptr): int = "(int)"
fn main() {}

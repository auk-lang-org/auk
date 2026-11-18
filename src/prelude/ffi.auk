/// C interop: `ffi.Ptr` and raw C memory, for packages that bind C libraries with `extern fn`
/// (`effects = ["ffi"]` in raft.toml). A `Ptr` is a plain machine address: not reference
/// counted, never freed for you, compared by address, and `"{p}"` prints it in hex. Reading and
/// writing memory `uses ffi`; the leak checker doesn't see C allocations.

/// Any C pointer (`T *`).
pub extern type Ptr = "void *"

/// The pointer at address `a`.
pub extern fn ptr(a: int): Ptr = "auk_ffi_ptr"
/// The address `p` points to.
pub extern fn addr(p: Ptr): int = "auk_ffi_addr"

/// NULL.
pub let null = ptr(0)

pub fn is_null(p: Ptr): bool = addr(p) == 0
/// `p` moved by `n` bytes.
pub fn offset(p: Ptr, n: int): Ptr = ptr(addr(p) + n)

/// `n` zeroed bytes of C memory (`calloc`); free them with `free`.
pub extern fn alloc(n: int): Ptr uses ffi = "auk_ffi_alloc +loc"
/// Free C memory from `alloc` or `from_bytes` (`free`).
pub extern fn free(p: Ptr) uses ffi = "auk_ffi_free"

/// The byte at `p + off` (0..255).
pub extern fn read_u8(p: Ptr, off: int): int uses ffi = "auk_ffi_read_u8 +loc"
/// The `int32_t` at `p + off`.
pub extern fn read_i32(p: Ptr, off: int): int uses ffi = "auk_ffi_read_i32 +loc"
/// The `int64_t` at `p + off`.
pub extern fn read_i64(p: Ptr, off: int): int uses ffi = "auk_ffi_read_i64 +loc"
/// The `double` at `p + off`.
pub extern fn read_f64(p: Ptr, off: int): float uses ffi = "auk_ffi_read_f64 +loc"
/// The pointer at `p + off`.
pub extern fn read_ptr(p: Ptr, off: int): Ptr uses ffi = "auk_ffi_read_ptr +loc"
pub extern fn write_u8(p: Ptr, off: int, v: int) uses ffi = "auk_ffi_write_u8 +loc"
pub extern fn write_i32(p: Ptr, off: int, v: int) uses ffi = "auk_ffi_write_i32 +loc"
pub extern fn write_i64(p: Ptr, off: int, v: int) uses ffi = "auk_ffi_write_i64 +loc"
pub extern fn write_f64(p: Ptr, off: int, v: float) uses ffi = "auk_ffi_write_f64 +loc"
pub extern fn write_ptr(p: Ptr, off: int, v: Ptr) uses ffi = "auk_ffi_write_ptr +loc"

extern fn symbol_at(name: str): Ptr uses ffi = "auk_ffi_symbol"
/// The address of the C symbol `name` in this process (`dlsym(RTLD_DEFAULT, name)`): libc, loaded
/// libraries, and the Auk runtime (`auk_str_len`, ...), which `auk build` exports. `none` if absent.
pub fn symbol(name: str): Ptr? uses ffi {
  let p = symbol_at(name)
  if is_null(p) { none } else { some(p) }
}

/// The NUL-terminated C string at `p`, copied (invalid UTF-8 becomes U+FFFD).
pub extern fn cstr(p: Ptr): str uses ffi = "auk_ffi_cstr +loc"
/// The `n` bytes at `p`, copied, as ints 0..255.
pub extern fn bytes(p: Ptr, n: int): [int] uses ffi = "auk_ffi_bytes +loc"
/// A `malloc`'d copy of the bytes `xs` (ints 0..255); free it with `free`.
pub extern fn from_bytes(xs: [int]): Ptr uses ffi = "auk_ffi_from_bytes"

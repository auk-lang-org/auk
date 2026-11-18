// User FFI inside a project with the `ffi` effect: casts and `#embed` (both checked and wrong).
extern type Buf = "struct buf *"
extern fn buf_new(n: int): Buf? = "struct buf *malloc(size_t)"
extern fn buf_ptr(b: Buf): ffi.Ptr = "(void *)"
extern fn buf_at(p: ffi.Ptr): Buf = "(struct buf *)"
extern fn maybe_buf(p: ffi.Ptr?): Buf? = "(struct buf *)"
extern fn bad_cast(n: int): Buf = "(struct buf *)"
extern fn var_cast(p: var ffi.Ptr): Buf = "(struct buf *)"
extern fn two_cast(p: ffi.Ptr, q: ffi.Ptr): Buf = "(struct buf *)"
extern fn int_cast(p: ffi.Ptr): int = "(int)"
extern fn free_cast(p: ffi.Ptr): Buf = "(void *) +free(f)"

extern fn hello(): str = "#embed data/hello.txt"
extern fn hello_bytes(): [int] = "#embed data/hello.txt"
extern fn hello_len(): int = "#embed \"data/hello.txt\""
extern fn hello_ptr(): ffi.Ptr = "#embed <data/hello.txt>"
extern fn bin_text(): str = "#embed data/bin.dat"
extern fn missing(): [int] = "#embed data/nope.bin"
extern fn with_param(n: int): [int] = "#embed data/hello.txt"
extern fn wrong_form(): float = "#embed data/hello.txt"
extern fn no_path(): str = "#embed"

fn main() uses ffi {
  let b = buf_new(16)!
  let p = buf_ptr(b)
  print("{hello()} {hello_bytes().len()} {hello_len()} {ffi.addr(hello_ptr()) != 0}")
  print("{maybe_buf(some(p)) != none} {ffi.addr(buf_ptr(buf_at(p)))}")
}

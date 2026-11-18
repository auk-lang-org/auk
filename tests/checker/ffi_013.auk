
extern type Buf = "struct buf *"
extern fn buf_new(n: int): Buf? = "struct buf *malloc(size_t)"
extern fn buf_free(b: Buf) = "void free(struct buf *)"
extern fn buf_ptr(b: Buf): ffi.Ptr = "(void *)"
extern fn buf_at(p: ffi.Ptr): Buf = "(struct buf *)"
extern fn maybe_buf(p: ffi.Ptr?): Buf? = "(struct buf *)"

fn main() uses ffi {
  let b = buf_new(16)!
  let p = buf_ptr(b)
  ffi.write_i64(p, 8, 77)
  let back = buf_at(ffi.offset(p, 0))
  print("{ffi.read_i64(buf_ptr(back), 8)} {ffi.addr(buf_ptr(back)) == ffi.addr(p)}")
  print("{maybe_buf(none) == none} {maybe_buf(some(p)) != none}")
  buf_free(back)
}

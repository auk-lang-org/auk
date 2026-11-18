/// C stdio for the servers (`lsp`, `mcp`), which speak a protocol over stdin/stdout: reading an
/// exact number of bytes after `env.read_line`'s header lines (both read C's buffered `stdin`, so
/// they agree on what was consumed), writing without the line break `print` adds, and flushing
/// (`print` leaves a piped stdout buffered). Rust's `BufRead::read_exact`, `write!` and `flush`.

extern fn c_fread(buf: ffi.Ptr, size: int, n: int, f: ffi.Ptr): int = "size_t fread(void *, size_t, size_t, void *)"

extern fn c_fwrite(s: str, size: int, n: int, f: ffi.Ptr): int = "size_t fwrite(const char *, size_t, size_t, void *)"

extern fn c_fflush(f: ffi.Ptr): int = "int fflush(void *)"

/// The C `FILE *` named `stdin`/`stdout` (macOS calls the variables `__stdinp`/`__stdoutp`).
fn stream(names: [str]): ffi.Ptr uses ffi {
  for n in names {
    match ffi.symbol(n) {
      some(p) => return ffi.read_ptr(p, 0)
      none => {}
    }
  }
  ffi.null
}

/// Exactly `n` bytes of stdin, as text; none at the end of input (or on invalid UTF-8: `what`
/// says which).
pub fn read_exact(n: int): str!Fail uses ffi {
  let f = stream(["__stdinp", "stdin"])
  let buf = ffi.alloc(n + 1)
  var got = 0
  while got < n {
    let r = c_fread(ffi.offset(buf, got), 1, n - got, f)
    if r <= 0 { break }
    got += r
  }
  let bytes = ffi.bytes(buf, got)
  ffi.free(buf)
  if got < n { fail(Fail.Io("failed to fill whole buffer")) }
  match str.from_utf8(bytes) {
    ok(s) => s
    err(_) => fail(Fail.Io("stream did not contain valid UTF-8"))
  }
}

pub enum Fail { Io(msg: str) }

/// Write `s` to stdout as is and flush; false if that failed.
pub fn write_out(s: str): bool uses ffi {
  let f = stream(["__stdoutp", "stdout"])
  let n = s.byte_len()
  let w = if n == 0 { 0 } else { c_fwrite(s, 1, n, f) }
  w == n && c_fflush(f) == 0
}

/// Flush stdout (after `print`).
pub fn flush() uses ffi {
  let _ = c_fflush(stream(["__stdoutp", "stdout"]))
}

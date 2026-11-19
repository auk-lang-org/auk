/// What the core library does differently per OS (was core.c's `#if`s): macOS. The Linux
/// variant is core_os.linux.auk; both declare the same functions.

// libc
extern fn arc4random_buf(buf: raw.Ptr<()>, n: usize) = "void arc4random_buf(void *, size_t)"
extern var c_stdin: raw.Ptr<()> = "__stdinp"

/// C's `stdin` (a FILE *; cfacts has stdout and stderr).
pub fn stdin(): raw.Ptr<()> uses raw = c_stdin

/// Fill buf from the OS CSPRNG; false if none is available.
pub fn os_random(buf: raw.Ptr<u8>, n: usize): bool uses raw, ffi {
  if n > 0 {
    arc4random_buf(raw.cast(buf), n)
  }
  true
}

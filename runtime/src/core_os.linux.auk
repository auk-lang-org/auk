/// What the core library does differently per OS (was core.c's `#if`s): Linux. The macOS
/// variant is core_os.macos.auk; both declare the same functions.

// the rest of the runtime (C, for now)
extern fn auk__c_open(path: raw.Ptr<u8>, flags: i32, mode: i32): i32 = "int auk__c_open(const char *, int, int)"
// libc
extern fn getrandom(buf: raw.Ptr<()>, n: usize, flags: u32): i64 = "ssize_t getrandom(void *, size_t, unsigned int)"
extern fn read(fd: i32, buf: raw.Ptr<()>, n: usize): i64 = "ssize_t read(int, void *, size_t)"
extern fn close(fd: i32): i32 = "int close(int)"
extern var c_stdin: raw.Ptr<()> = "stdin"

/// C's `stdin` (a FILE *; cfacts has stdout and stderr).
pub fn stdin(): raw.Ptr<()> uses raw = c_stdin

/// Fill buf from the OS CSPRNG; false if none is available.
pub fn os_random(buf: raw.Ptr<u8>, n: usize): bool uses raw, ffi {
  var p: usize = 0
  while p < n {
    let r = getrandom(raw.cast(buf.offset(p)), n - p, 0)
    if r < 0 {
      if cfacts.errno() == cfacts.EINTR {
        continue
      }
      break // ENOSYS (old kernel): fall back to /dev/urandom
    }
    p += usize(r)
  }
  if p == n {
    return true
  }
  let fd = auk__c_open("/dev/urandom", cfacts.O_RDONLY | cfacts.O_CLOEXEC, 0)
  if fd < 0 {
    return false
  }
  while p < n {
    let r = read(fd, raw.cast(buf.offset(p)), n - p)
    if r < 0 && cfacts.errno() == cfacts.EINTR {
      continue
    }
    if r <= 0 {
      break
    }
    p += usize(r)
  }
  close(fd)
  p == n
}

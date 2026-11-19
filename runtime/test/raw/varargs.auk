// Calls of C varargs functions (docs/lowlevel.md 7a): `snprintf`/`printf` with integers of
// every width (C's default argument promotions: narrower than `int` becomes `int`, `f32`
// becomes `double`, `bool` an `int`), doubles, `*` precisions, C strings, pointers and more
// arguments than there are registers; `open(2)` with a mode and `fcntl(2)` with an int. On
// Apple arm64 the variadic tail goes on the stack, not in registers (a fixed-argument call
// would pass `open`'s mode in a register, where it isn't read). Each line is checked against
// the same calls made by C (varargs_main.c). The runner adds `facts.auk` (the platform's
// constants: the `O_*`, `F_*`, `FD_CLOEXEC`, the offset of `st_mode` in `struct stat`).

extern fn c_snprintf(buf: raw.Ptr<u8>, n: usize, fmt: raw.Ptr<u8>, ...): i32 =
  "int snprintf(char *, size_t, const char *, ...)"
extern fn c_printf(fmt: raw.Ptr<u8>, ...): i32 = "int printf(const char *, ...)"
extern fn c_fflush(f: raw.Ptr<()>): i32 = "int fflush(void *)"
extern fn c_write(fd: i32, p: raw.Ptr<u8>, n: usize): i64 = "long write(int, const void *, size_t)"
extern fn c_open(path: raw.Ptr<u8>, flags: i32, ...): i32 = "int open(const char *, int, ...)"
extern fn c_fcntl(fd: i32, cmd: i32, ...): i32 = "int fcntl(int, int, ...)"
extern fn c_close(fd: i32): i32 = "int close(int)"
extern fn c_unlink(p: raw.Ptr<u8>): i32 = "int unlink(const char *)"
extern fn c_umask(m: u32): u32 = "unsigned umask(unsigned)"
extern fn c_fstat(fd: i32, st: raw.Ptr<u8>): i32 = "int fstat(int, void *)"
extern fn c_getpid(): i32 = "int getpid(void)"

raw struct Buf {
  b: [u8; 512],
}

/// The `n` bytes at `p` and a line break on stdout.
fn out(p: raw.Ptr<u8>, n: i32) uses ffi {
  let _ = c_write(1, p, usize(n))
  let _ = c_write(1, "\n", 1)
}

fn run(): i32 uses raw, ffi {
  var buf = Buf {}
  let p: raw.Ptr<u8> = raw.cast(raw.addr_of(&buf))
  let cap: usize = 512
  // integers: narrower than `int` promoted by their sign, 32 and 64 bits as they are
  out(p, c_snprintf(p, cap, "%d %d %d %u %d %u", i8(-5), i16(-300), i32(-70000), u8(200), u16(65535), u32(4000000000)))
  out(p, c_snprintf(p, cap, "%lld %llu %zu %ld %x %c %d %d", i64(-9000000000), u64(-1), usize(42), -7, i32(0xbeef), i32(65), true, false))
  // doubles, an `f32` (promoted to double), `*` precisions (an `int`)
  out(p, c_snprintf(p, cap, "%.3f %e %g %.*f %.*e %g %g", 3.14159, 0.000123, 1e21, i32(2), 2.71828, i32(3), -1234.5, f32(1.5), f32(-0.25)))
  // C strings (a literal is one) and pointers
  let s: raw.Ptr<u8> = "auk"
  out(p, c_snprintf(p, cap, "[%s|%5s|%-5s|%.2s] %p", s, "hi", s, "abcdef", raw.from_int<u8>(0x1234)))
  // more arguments than registers (8 general and 8 vector on arm64, 6 and 8 on x86-64)
  out(
    p,
    c_snprintf(
      p,
      cap,
      "%d %.1f %d %.1f %d %.1f %d %.1f %d %.1f %d %.1f %d %.1f %d %.1f %d %.1f %d %.1f %d %lld %s",
      i32(1),
      1.5,
      i32(2),
      2.5,
      i32(3),
      3.5,
      i32(4),
      4.5,
      i32(5),
      5.5,
      i32(6),
      6.5,
      i32(7),
      7.5,
      i32(8),
      8.5,
      i32(9),
      9.5,
      i32(10),
      10.5,
      i8(-11),
      i64(1) << 40,
      "end",
    ),
  )
  // the length the whole text has (nothing written)
  let n = c_snprintf(raw.null(), 0, "%d-%s-%.3f", i32(12345), "xyz", 0.5)
  out(p, c_snprintf(p, cap, "len %d", n))
  // printf itself (to stdout, flushed before the next write)
  let _ = c_printf("printf %d %s %.2f %lu\n", i32(7), "ok", 0.125, u64(1) << 63)
  let _ = c_fflush(raw.null())
  // open(2) with a mode (umask 0, so the file gets exactly that mode), then fcntl(2)
  var pbuf = Buf {}
  let path: raw.Ptr<u8> = raw.cast(raw.addr_of(&pbuf))
  let _ = c_snprintf(path, 512, "/tmp/auk-varargs-%d", c_getpid())
  let old = c_umask(0)
  let fd = c_open(path, facts.O_CREAT | facts.O_WRONLY | facts.O_TRUNC, u32(416))
  let _ = c_umask(old)
  if fd < 0 { return 1 }
  var st = Buf {}
  let sp: raw.Ptr<u8> = raw.cast(raw.addr_of(&st))
  if c_fstat(fd, sp) != 0 { return 2 }
  let mode = i32(raw.cast<u16>(sp.offset(facts.ST_MODE)).load()) & 511
  let a = c_fcntl(fd, facts.F_SETFD, facts.FD_CLOEXEC)
  let cloexec = c_fcntl(fd, facts.F_GETFD)
  let fl = c_fcntl(fd, facts.F_GETFL)
  let b = c_fcntl(fd, facts.F_SETFL, fl | facts.O_NONBLOCK)
  let nonblock = (c_fcntl(fd, facts.F_GETFL) & facts.O_NONBLOCK) != 0
  let _ = c_close(fd)
  let _ = c_unlink(path)
  out(p, c_snprintf(p, cap, "open %o setfd %d cloexec %d setfl %d nonblock %d", mode, a, cloexec, b, nonblock))
  0
}

fn main(): int uses raw, ffi = int(run())

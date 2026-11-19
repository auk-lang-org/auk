// Overflow and bit intrinsics: llvm.{s,u}{add,sub,mul}.with.overflow by the type's signedness,
// cttz, ctlz, ctpop, bswap.

fn run(): int uses raw {
  let (a, o1) = raw.add_overflow(i32(2147483647), 1)
  if a != -2147483648 || !o1 { return 1 }
  let (b, o2) = raw.add_overflow(u8(200), 55)
  if b != 255 || o2 { return 2 }
  let (c, o3) = raw.add_overflow(u8(200), 56)
  if c != 0 || !o3 { return 3 }
  let (d, o4) = raw.sub_overflow(u32(1), 2)
  if d != 4294967295 || !o4 { return 4 }
  let (e, o5) = raw.mul_overflow(i64(3037000500), 3037000500)
  if !o5 { return 5 }
  let (f, o6) = raw.mul_overflow(9, 7)
  if f != 63 || o6 { return 6 }
  if raw.ctz(u32(8)) != 3 || raw.ctz(u32(0)) != 32 { return 7 }
  if raw.clz(u64(1)) != 63 || raw.clz(u16(0)) != 16 { return 8 }
  if raw.popcount(u8(0xff)) != 8 || raw.popcount(i64(-1)) != 64 { return 9 }
  if raw.bswap(u32(0x11223344)) != 0x44332211 || raw.bswap(u16(0xabcd)) != 0xcdab { return 10 }
  if e == 0 { return 11 }
  0
}

fn main(): int uses raw = run()

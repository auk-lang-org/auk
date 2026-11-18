/// Bitwise operators on `int` (tests/bitwise.rs).

test "and or xor truth tables" {
  for (a, b, and, or, xor) in [(0, 0, 0, 0, 0), (0, 1, 0, 1, 1), (1, 0, 0, 1, 1), (1, 1, 1, 1, 0)] {
    assert (a & b) == and
    assert (a | b) == or
    assert (a ^ b) == xor
  }
  assert (0b1100 & 0b1010) == 0b1000
  assert (0b1100 | 0b1010) == 0b1110
  assert (0b1100 ^ 0b1010) == 0b0110
  assert (-1 & 0xff) == 0xff
  assert (-256 | 0xff) == -1
  assert (-1 ^ 0xff) == -256
  assert (9_223_372_036_854_775_807 ^ -1) == -9_223_372_036_854_775_807 - 1
}

test "not" {
  assert ~0 == -1
  assert ~-1 == 0
  assert ~5 == -6
  assert (~0xf0 & 0xff) == 0x0f
  assert ~~42 == 42
}

test "shifts" {
  assert 1 << 0 == 1
  assert 1 << 10 == 1024
  assert 1 << 62 == 4_611_686_018_427_387_904
  // bits shifted out of `<<` are dropped: shifts are bit operations, not arithmetic
  assert 1 << 63 == -9_223_372_036_854_775_807 - 1
  assert 3 << 63 == -9_223_372_036_854_775_807 - 1
  assert 0xff << 60 == -1_152_921_504_606_846_976
  assert 1024 >> 10 == 1
  assert 1023 >> 10 == 0
  // `>>` is arithmetic: it copies the sign bit
  assert -16 >> 2 == -4
  assert -1 >> 63 == -1
  assert (1 << 63) >> 63 == -1
  // a logical shift right masks off the copied sign bits
  let n = 4
  assert ((-16 >> n) & ~(-1 << (64 - n))) == 0x0fff_ffff_ffff_ffff
  assert 5 >> 0 == 5
}

test "precedence" {
  assert 1 + 2 << 3 == 24
  assert 1 << 2 + 1 == 8
  assert (6 | 1 & 3) == 7
  assert (6 ^ 3 & 1) == 7
  assert (1 | 6 ^ 3) == 5
  assert (2 * 3 & 4) == 4
  assert -~5 == 6
  assert (0..1 << 2).len() == 4
  let x = 6
  assert (x & 1) == 0
  assert (x & 2) != 0 && (x | 1) == 7
}

test "compound assignment" {
  var z = 0b1111
  z &= 0b0110
  assert z == 0b0110
  z |= 0b1000
  assert z == 0b1110
  z ^= 0b0011
  assert z == 0b1101
  z <<= 4
  assert z == 0b1101_0000
  z >>= 6
  assert z == 0b11
  var xs = [1, 2, 3]
  xs[1] <<= 3
  xs[2] ^= 1
  assert xs == [1, 16, 2]
}

test "bytes" {
  // big-endian packing and unpacking, as an encoder would do
  let bs = [0xde, 0xad, 0xbe, 0xef]
  let n = (bs[0] << 24) | (bs[1] << 16) | (bs[2] << 8) | bs[3]
  assert n == 0xdeadbeef
  assert [24, 16, 8, 0].map(s => (n >> s) & 0xff) == bs
  assert "{n >> 28 & 0xf}" == "13"
}

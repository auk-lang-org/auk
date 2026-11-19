// A raw union read through two different fields, and raw.cast reinterpretation, at O2 (no
// type-based alias metadata).

raw union Bits { f: float, i: u64, b: [u8; 8] }

fn punned(p: raw.Ptr<Bits>): u64 uses raw {
  p.f = 1.0
  let a = p.i
  p.f = -2.0
  a ^ p.i
}

fn run(): int uses raw {
  let p: raw.Ptr<Bits> = raw.cast(raw.alloc(8))
  if punned(p) != (0xc000000000000000 ^ 0x3ff0000000000000) { return 1 }
  let words: raw.Ptr<u32> = raw.cast(p)
  words.at(0) = 0
  words.at(1) = 0x40080000
  if p.f != 3.0 { return 2 }
  let bytes: raw.Ptr<u8> = raw.cast(p)
  if bytes.at(7) != 0x40 { return 3 }
  let u = Bits { i: 0x4000000000000000 }
  if u.f != 2.0 { return 4 }
  raw.free(p)
  0
}

fn main(): int uses raw = run()

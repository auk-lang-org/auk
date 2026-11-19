raw struct Header { rc: i64, kind: u32, flags: u32 }
raw struct Str { h: Header, len_bytes: i64, len_chars: i64, is_ascii: bool, data: [u8; ..] }
raw union U { i: i64, f: float }

fn check(ok: bool, code: int): int = if ok { 0 } else { code }

fn run(): int uses raw {
  var bad = 0
  bad += check(raw.size_of<Header>() == 16, 1)
  bad += check(raw.size_of<Str>() == 40, 2)
  bad += check(raw.offset_of<Str>(.data) == 33, 3)
  bad += check(raw.offset_of<Str>(.is_ascii) == 32, 4)
  bad += check(raw.align_of<Str>() == 8, 5)
  let p: raw.Ptr<Str> = raw.cast(raw.alloc(raw.size_of<Str>() + 8))
  p.len_bytes = 5
  p.h.rc = 1
  p.h.kind = 7
  let d = p.data
  d.at(0) = 104
  d.at(4) = 111
  bad += check(int(p.data.at(4)) == 111, 6)
  bad += check(p.h.kind == 7 && p.len_bytes == 5, 7)
  let q = raw.field_addr(p, .len_chars)
  q.store(42)
  bad += check(p.len_chars == 42, 8)
  var x: i64 = 1
  let px = raw.addr_of(&x)
  px.store(9)
  bad += check(x == 9, 9)
  let xs: raw.Ptr<i64> = raw.cast(raw.alloc(80))
  var i = 0
  while i < 10 {
    xs.at(i) = i64(i * i)
    i += 1
  }
  bad += check(xs.offset(3).load() == 9, 10)
  raw.fill(xs, 0, 80)
  bad += check(xs.at(9) == 0, 11)
  raw.free(xs)
  let u = raw.alloc(16)
  let up: raw.Ptr<U> = raw.cast(u)
  up.f = 1.0
  bad += check(up.i == 0x3ff0000000000000, 12)
  bad += check(up.int() != 0 && raw.null<i64>().is_null(), 13)
  let c: raw.Ptr<i64> = raw.cast(u)
  let old = raw.atomic_add(c, 5, raw.Order.SeqCst)
  bad += check(old == 0x3ff0000000000000, 14)
  let (prev, ok) = raw.atomic_cas(c, 0x3ff0000000000005, 3, raw.Order.AcqRel, raw.Order.Acquire)
  bad += check(ok && prev == 0x3ff0000000000005 && raw.atomic_load(c, raw.Order.Acquire) == 3, 15)
  raw.fence(raw.Order.SeqCst)
  bad += check(raw.compare(u, u, 16) == 0, 16)
  raw.free(raw.cast<u8>(p))
  bad
}

fn main(): int uses raw = run()

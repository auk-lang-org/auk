raw struct V2 { x: float, y: float }
raw struct Big { a: i64, b: i64, c: i64, d: u8 }
raw struct Small { a: i32, b: u8 }

export fn auk_v2_add(a: V2, b: V2): V2 = V2 { x: a.x + b.x, y: a.y + b.y }
export fn auk_big_sum(b: Big): i64 = b.a + b.b + b.c + i64(b.d)
inline export fn auk_mk_big(n: i64): Big = Big { a: n, b: n * 2, c: n * 3, d: 4 }
export fn auk_small(s: Small, k: bool): Small = Small { a: s.a + 1, b: if k { s.b } else { 0 } }
export fn twice(x: i32): i32 = x * 2

fn run(): int uses raw {
  var bad = 0
  let v = auk_v2_add(V2 { x: 1.5, y: 2.0 }, V2 { x: 0.5, y: 1.0 })
  if v.x != 2.0 || v.y != 3.0 { bad += 1 }
  if auk_big_sum(auk_mk_big(10)) != 64 { bad += 2 }
  let s = auk_small(Small { a: 41, b: 7 }, true)
  if s.a != 42 || s.b != 7 { bad += 4 }
  let f = raw.fn_of(twice)
  if f.is_null() || f(21) != 42 { bad += 8 }
  bad += fn_casts()
  bad
}

raw struct Block { isa: raw.Ptr<()>, invoke: raw.Ptr<()> }

export fn block_invoke(b: raw.Ptr<Block>, x: i32): i32 = x + 1

/// A code pointer held as `void *` (a block's `invoke`): `raw.cast` to a `raw.Fn` and back.
fn fn_casts(): int uses raw {
  var bad = 0
  var b = Block { invoke: raw.cast(raw.fn_of(block_invoke)) }
  let p = raw.addr_of(&b)
  // the explicit form, called at once (lowlevel.md §10's `complete.invoke(complete, ok)`)
  let inv = b.invoke
  if raw.cast<raw.Fn<(raw.Ptr<Block>, i32) => i32>>(inv)(p, 41) != 42 { bad += 16 }
  // by the expected type
  let g: raw.Fn<(raw.Ptr<Block>, i32) => i32> = raw.cast(inv)
  if g(p, 1) != 2 { bad += 32 }
  // and back to a pointer: the same address
  let back: raw.Ptr<()> = raw.cast(g)
  if back.int() != inv.int() || raw.cast<u8>(g).int() != inv.int() { bad += 64 }
  // a pointer to function pointers (a table) is still `raw.Ptr<raw.Fn<...>>` by its type
  let slots: raw.Ptr<raw.Fn<(raw.Ptr<Block>, i32) => i32>> = raw.cast(raw.field_addr(p, .invoke))
  let h = slots.load()
  if h(p, 9) != 10 { bad += 128 }
  bad
}

fn main(): int uses raw = run()

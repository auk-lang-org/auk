// Addresses in constant initializers: `raw.addr_of(&g)` (also of a later global and of the
// global itself), `raw.fn_of(f)`, `raw.cast` of them, and raw struct and array literals built
// from them: a table of function pointers, a ring, a pointer to C data. Nothing runs at startup.

raw struct Ops { add: raw.Fn<(i64, i64) => i64>, mul: raw.Fn<(i64, i64) => i64>, name: raw.Ptr<()> }
raw struct Node { next: raw.Ptr<Node>, v: i64 }

fn add(a: i64, b: i64): i64 = a + b
export fn mul(a: i64, b: i64): i64 = a * b

raw var counter: i64 = 40
raw var pc: raw.Ptr<i64> = raw.addr_of(&counter)
raw var first: raw.Ptr<i64> = raw.addr_of(&later)
raw var later: i64 = 5
raw let OPS: Ops = Ops { add: raw.fn_of(add), mul: raw.fn_of(mul), name: raw.cast(raw.addr_of(&counter)) }
raw var table: [raw.Fn<(i64, i64) => i64>; 3] = [raw.fn_of(add), raw.fn_of(mul)]
raw var small: [i32; 4] = [1, 2, 3]
raw var ring: Node = Node { next: raw.addr_of(&ring2), v: 1 }
raw var ring2: Node = Node { next: raw.addr_of(&ring), v: 2 }
raw var self_: Node = Node { next: raw.addr_of(&self_), v: 3 }
raw var ops_ptr: raw.Ptr<Ops> = raw.addr_of(&ops_var)
raw var ops_var: Ops = OPS
raw var as_void: raw.Ptr<()> = raw.cast(raw.fn_of(add))
export var auk_ops_table: Ops = OPS

extern var environ: raw.Ptr<raw.Ptr<u8>> = "environ"
raw var env_at: raw.Ptr<raw.Ptr<raw.Ptr<u8>>> = raw.addr_of(&environ)

fn run(): int uses raw {
  var bad = 0
  counter += 2
  if pc.load() != 42 || pc.int() != raw.addr_of(&counter).int() { bad += 1 }
  if first.load() != 5 { bad += 2 }
  let a = OPS.add
  let m = OPS.mul
  if a(2, 3) != 5 || m(2, 3) != 6 { bad += 4 }
  if OPS.name.int() != pc.int() { bad += 4 }
  let t: raw.Ptr<raw.Fn<(i64, i64) => i64>> = raw.cast(raw.addr_of(&table))
  let t0 = t.at(0)
  let t1 = t.at(1)
  if t0(4, 5) != 9 || t1(4, 5) != 20 || !t.at(2).is_null() { bad += 8 }
  let s: raw.Ptr<i32> = raw.cast(raw.addr_of(&small))
  if s.at(0) != 1 || s.at(2) != 3 || s.at(3) != 0 { bad += 16 }
  if ring.next.v != 2 || ring.next.next.v != 1 || self_.next.next.v != 3 { bad += 32 }
  let o = ops_ptr.mul
  if o(6, 7) != 42 { bad += 64 }
  let back: raw.Fn<(i64, i64) => i64> = raw.cast(as_void)
  if back(1, 1) != 2 { bad += 128 }
  if env_at.load().int() != environ.int() || environ.is_null() { bad += 256 }
  let x = auk_ops_table.add
  if x(1, 2) != 3 { bad += 512 }
  bad
}

fn main(): int uses raw = run()

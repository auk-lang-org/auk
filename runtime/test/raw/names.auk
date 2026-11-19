// Locals named like modules (`facts` is also a module here), `if` arms that start with a
// literal, and another module's globals by path (`raw.addr_of(&facts.counter)`).
raw struct C { cap: i64, n: u32 }

// a literal first arm takes the other arm's type
fn grow(c: raw.Ptr<C>): u32 uses raw {
  let n = if c.n == 0 { 8 } else if c.n == 1 { 9 } else { c.n * 2 }
  n
}

fn neg(c: raw.Ptr<C>): i32 uses raw {
  let n = if c.n == 0 { -1 } else { i32(c.n) }
  n
}

// an `i64` arm: the result is an `i64`, whose arithmetic wraps
fn wraps(c: raw.Ptr<C>): bool uses raw {
  let cap = if c.cap == 0 { 0x7fffffffffffffff } else { c.cap }
  cap + 1 < 0
}

// a local wins over the module `facts` while it is in scope
fn shadow(): i64 uses raw {
  var facts = C { cap: 3, n: 0 }
  let p = raw.addr_of(&facts)
  facts.cap + p.cap
}

fn after_shadow(): i64 = facts.twice(4)

fn addr(): i64 uses raw {
  let p = raw.addr_of(&facts.counter)
  p.store(p.load() + 1)
  facts.counter = facts.counter + 1
  let e = raw.addr_of(&facts.auk_flag)
  e.load() + facts.counter
}

fn main(): int uses raw {
  var c = C { cap: 0, n: 0 }
  if grow(raw.addr_of(&c)) != 8 || neg(raw.addr_of(&c)) != -1 { return 1 }
  c.n = 5
  if grow(raw.addr_of(&c)) != 10 || neg(raw.addr_of(&c)) != 5 { return 2 }
  if !wraps(raw.addr_of(&c)) { return 3 }
  if shadow() != 6 || after_shadow() != 8 { return 4 }
  if addr() != 9 + 5 { return 5 }
  if !env_ok() { return 6 }
  0
}

fn env_ok(): bool uses raw =
  raw.addr_of(&facts.environ).load().int() == facts.environ.int() && !facts.environ.is_null()

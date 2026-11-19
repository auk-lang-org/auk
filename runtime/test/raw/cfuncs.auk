// C-facing functions: `never` (C's `_Noreturn`) from C and from an `export fn`, `()` results
// as C `void` (export fns and calls through a `raw.Fn`), parameters by address, and `raw let`s
// as match patterns.

raw var calls: i64 = 0

extern fn c_exit(code: i32): never = "void _exit(int)"

/// A C `void` function: the address of a parameter, written through.
export fn bump(by: i64) uses raw {
  let p = raw.addr_of(&by)
  p.store(p.load() * 2)
  calls += by
}

export fn stop(code: i32): never uses ffi = c_exit(code)

fn twice_through(f: raw.Fn<(i64) => ()>, x: i64) uses raw {
  f(x)
  f(x)
}

/// No `raw.unreachable()` needed after a `never` call.
fn checked(ok: bool): i64 uses raw, ffi {
  if !ok { stop(3) }
  calls
}

fn run(): int uses raw, ffi {
  bump(1)
  twice_through(raw.fn_of(bump), 5)
  if checked(true) != 22 { return 1 }
  // a `let` local's address too
  let k: i64 = 7
  let pk = raw.addr_of(&k)
  if pk.load() != 7 { return 2 }
  if auk_kinds() != 10 + 11 + 14 + 9 { return 3 }
  0
}

fn main(): int uses raw, ffi = run()

// constant patterns: an integer `raw let` in a match arm compares (C's `case`)
raw let V_NULL: u8 = 0
raw let V_INT: u8 = 1
raw let V_STR: u8 = 4

fn kind_name(k: u8): i64 = match k {
  V_NULL => 10
  V_INT => 11
  V_STR => 14
  other => i64(other)
}

export fn auk_kinds(): i64 = kind_name(0) + kind_name(1) + kind_name(4) + kind_name(9)

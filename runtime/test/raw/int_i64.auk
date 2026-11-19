// `int` and `i64` mix (the same machine type): arguments, results, struct fields, globals and
// constants, each keeping its arithmetic (`i64` wraps). The layout constants don't need
// `uses raw`.

raw struct H { rc: i64, n: int }

raw let BIG: i64 = 9223372036854775807
raw let N: int = 3
raw let SUM: i64 = N + 4
raw var h: H = H { rc: N, n: SUM }

fn wide(x: i64): int = x + 1
fn narrow(x: int): i64 = x * 2

/// No `uses raw`: only layout constants.
fn header_size(): int = int(raw.size_of<H>()) + int(raw.align_of<H>()) + int(raw.offset_of<H>(.n))

fn run(): int {
  var bad = 0
  let a: int = 5
  let b: i64 = a
  let c: int = b + 1
  if wide(a) != 6 || narrow(b) != 10 || c != 6 { bad += 1 }
  if h.rc != 3 || h.n != 7 || SUM != 7 { bad += 2 }
  let x: i64 = BIG
  if x + 1 >= 0 { bad += 4 }
  var hh = H { rc: a, n: b }
  hh.rc = hh.n + a
  if hh.rc != 10 { bad += 8 }
  if header_size() != 16 + 8 + 8 { bad += 16 }
  bad
}

fn main(): int = run()

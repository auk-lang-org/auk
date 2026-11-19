// raw.setjmp / raw.longjmp: out of nested calls, with locals changed between the two (they
// keep their last values: the function that calls setjmp is compiled without optimizations).

fn deep(buf: raw.Ptr<raw.JmpBuf>, n: int, hits: raw.Ptr<i64>): int uses raw {
  hits.store(hits.load() + 1)
  if n == 0 { raw.longjmp(buf) }
  deep(buf, n - 1, hits) + 1
}

fn run(): int uses raw {
  let buf: raw.Ptr<raw.JmpBuf> = raw.cast(raw.alloc(raw.size_of<raw.JmpBuf>()))
  var hits: i64 = 0
  var x = 1
  var y: i32 = 5
  var jumped = false
  if raw.setjmp(buf) {
    jumped = true
  } else {
    x = 41
    y = 7
    let _ = deep(buf, 20, raw.addr_of(&hits))
    x = 0
  }
  raw.free(buf)
  if !jumped { return 1 }
  if x != 41 || y != 7 { return 2 }
  if hits != 21 { return 3 }
  0
}

fn main(): int uses raw = run()

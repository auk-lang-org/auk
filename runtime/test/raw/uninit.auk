// `var x: T` without a value (C's uninitialized local): raw structs, numbers, fixed arrays; in
// optimized code and in a function that calls raw.setjmp (compiled `optnone`).
raw struct Frame { jb: raw.JmpBuf, prev: raw.Ptr<Frame> }
raw struct Pair { a: i64, b: u32 }

raw var top: raw.Ptr<Frame> = raw.null()

fn fill(p: raw.Ptr<Pair>) uses raw {
  p.a = 40
  p.b = 2
}

fn boom(fr: raw.Ptr<Frame>) uses raw { raw.longjmp(raw.field_addr(fr, .jb)) }

/// raw.setjmp: `optnone`; the frame is uninitialized but for `prev`.
fn under_setjmp(jump: bool): i64 uses raw {
  var fr: Frame
  fr.prev = top
  var n: i64 = 1
  if !raw.setjmp(raw.field_addr(raw.addr_of(&fr), .jb)) {
    top = raw.addr_of(&fr)
    n = 2
    if jump { boom(raw.addr_of(&fr)) }
    top = fr.prev
    return n
  }
  top = fr.prev
  n * 10
}

/// The same with a literal (built in the variable itself, not through temporaries).
fn under_setjmp_lit(jump: bool): i64 uses raw {
  var fr = Frame { prev: top }
  if !raw.setjmp(raw.field_addr(raw.addr_of(&fr), .jb)) {
    top = raw.addr_of(&fr)
    if jump { boom(raw.addr_of(&fr)) }
    top = fr.prev
    return 3
  }
  top = fr.prev
  if fr.prev.is_null() { 30 } else { 31 }
}

fn run(): int uses raw {
  var bad = 0
  var fr: Frame
  fr.prev = raw.null()
  if !fr.prev.is_null() { bad += 1 }
  var pr: Pair
  fill(raw.addr_of(&pr))
  if pr.a + i64(pr.b) != 42 { bad += 2 }
  var n: i64
  n = 5
  if n != 5 { bad += 4 }
  // a fixed-array local (C's `char buf[24]`)
  var buf: [u8; 24]
  let bp: raw.Ptr<u8> = raw.cast(raw.addr_of(&buf))
  bp.at(0) = 7
  bp.at(23) = 9
  if bp.at(0) != 7 || bp.at(23) != 9 { bad += 8 }
  if under_setjmp(false) != 2 || under_setjmp(true) != 20 { bad += 16 }
  if under_setjmp_lit(false) != 3 || under_setjmp_lit(true) != 30 { bad += 32 }
  if !top.is_null() { bad += 64 }
  // in a loop: each iteration's value is written before it is read
  var sum: i64 = 0
  var i: i64 = 0
  while i < 4 {
    var p: Pair
    p.a = i
    p.b = 1
    sum += p.a + i64(p.b)
    i += 1
  }
  if sum != 10 { bad += 128 }
  bad
}

fn main(): int uses raw = run()

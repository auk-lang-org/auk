// What `var x: T` costs (llvm-dis of `auk build --lib --bc`): nothing in `run_undef` and
// `scratch` (no memset), one memset and no copy for a literal under raw.setjmp (`run_lit`).
raw struct Frame { jb: raw.JmpBuf, prev: raw.Ptr<Frame> }

raw var top: raw.Ptr<Frame> = raw.null()

export fn run_undef(f: raw.Fn<(raw.Ptr<()>) => ()>, env: raw.Ptr<()>): i32 uses raw {
  var fr: Frame
  fr.prev = top
  if !raw.setjmp(raw.field_addr(raw.addr_of(&fr), .jb)) {
    top = raw.addr_of(&fr)
    f(env)
    top = fr.prev
    return 0
  }
  top = fr.prev
  1
}

export fn run_lit(f: raw.Fn<(raw.Ptr<()>) => ()>, env: raw.Ptr<()>): i32 uses raw {
  var fr = Frame { prev: top }
  if !raw.setjmp(raw.field_addr(raw.addr_of(&fr), .jb)) {
    top = raw.addr_of(&fr)
    f(env)
    top = fr.prev
    return 0
  }
  top = fr.prev
  1
}

export fn scratch(p: raw.Ptr<u8>, n: i64): u8 uses raw {
  var buf: [u8; 256]
  let b: raw.Ptr<u8> = raw.cast(raw.addr_of(&buf))
  var i: i64 = 0
  while i < n {
    b.at(i) = p.at(i)
    i += 1
  }
  b.at(3)
}

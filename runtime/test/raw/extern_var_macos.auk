// `extern var` of the block runtime's isa symbol (macOS: libSystem's libclosure), by address.

extern var global_block_isa: [u8; 0] = "_NSConcreteGlobalBlock"
extern var stack_block_isa: [u8; 0] = "_NSConcreteStackBlock"

fn run(): int uses raw {
  let g = raw.addr_of(&global_block_isa)
  let s = raw.addr_of(&stack_block_isa)
  if g.is_null() || s.is_null() { return 1 }
  if g.int() == s.int() { return 2 }
  0
}

fn main(): int uses raw = run()

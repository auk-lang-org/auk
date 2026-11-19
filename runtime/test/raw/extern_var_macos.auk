// `extern var` of the block runtime's isa symbol (macOS: libSystem's libclosure), by address;
// a global block literal (docs/lowlevel.md §10) as a constant initializer, run by libdispatch.

extern var global_block_isa: [u8; 0] = "_NSConcreteGlobalBlock"
extern var stack_block_isa: [u8; 0] = "_NSConcreteStackBlock"

raw struct BlockDesc { reserved: usize, size: usize }
raw struct GBlock { isa: raw.Ptr<()>, flags: i32, reserved: i32, invoke: raw.Ptr<()>, descriptor: raw.Ptr<BlockDesc> }

raw let BLOCK_IS_GLOBAL: i32 = 1 << 28
raw var hits: i64 = 0
raw var gdesc: BlockDesc = BlockDesc { size: raw.size_of<GBlock>() }
raw var gblock: GBlock = GBlock {
  isa: raw.cast(raw.addr_of(&global_block_isa)),
  flags: BLOCK_IS_GLOBAL,
  invoke: raw.cast(raw.fn_of(gblock_invoke)),
  descriptor: raw.addr_of(&gdesc),
}

export fn gblock_invoke(b: raw.Ptr<GBlock>) uses raw { hits += 1 }

extern fn block_copy(b: raw.Ptr<()>): raw.Ptr<()> = "void *_Block_copy(const void *)"
extern fn block_release(b: raw.Ptr<()>) = "void _Block_release(const void *)"
extern fn dispatch_sync(q: raw.Ptr<()>, b: raw.Ptr<()>) = "void dispatch_sync(void *, void *)"
extern fn dispatch_get_global_queue(id: i64, flags: u64): raw.Ptr<()> = "void *dispatch_get_global_queue(int64_t, uint64_t)"

fn run(): int uses raw, ffi {
  let g = raw.addr_of(&global_block_isa)
  let s = raw.addr_of(&stack_block_isa)
  if g.is_null() || s.is_null() { return 1 }
  if g.int() == s.int() { return 2 }
  // a global block: `_Block_copy` returns it unchanged, libdispatch calls its `invoke`
  let b: raw.Ptr<()> = raw.cast(raw.addr_of(&gblock))
  if block_copy(b).int() != b.int() { return 3 }
  block_release(b)
  dispatch_sync(dispatch_get_global_queue(0, 0), b)
  dispatch_sync(dispatch_get_global_queue(0, 0), b)
  if hits != 2 { return 4 }
  0
}

fn main(): int uses raw, ffi = run()

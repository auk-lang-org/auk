/// Per-CPU facts of the runtime's own code (cfacts has the C library's): x86-64.

/// Bytes between a function's entry stack pointer and the 16-byte-aligned stack its caller had:
/// x86-64's `call` pushes the return address (stack.auk's `redirect`).
pub raw let RET_SLOT: usize = 8

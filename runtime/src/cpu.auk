/// Per-CPU facts of the runtime's own code (cfacts has the C library's): AArch64 here,
/// `cpu.<os>-x86_64.auk` for x86-64.

/// Bytes between a function's entry stack pointer and the 16-byte-aligned stack its caller had:
/// none on AArch64, which keeps the return address in a register (stack.auk's `redirect`).
pub raw let RET_SLOT: usize = 0

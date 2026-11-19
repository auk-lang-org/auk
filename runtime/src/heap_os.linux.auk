/// heap.auk's per-OS part (Linux): the usable size of a malloc'd block (heap.c's `#else`).

extern fn malloc_usable_size(p: raw.Ptr<()>): usize = "size_t malloc_usable_size(void *)"

/// The bytes usable in the allocation at p.
pub fn usable_size(p: raw.Ptr<()>): usize uses ffi = malloc_usable_size(p)

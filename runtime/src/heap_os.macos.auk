/// heap.auk's per-OS part (macOS): the usable size of a malloc'd block (heap.c's
/// `#ifdef __APPLE__`).

extern fn malloc_size(p: raw.Ptr<()>): usize = "size_t malloc_size(const void *)"

/// The bytes usable in the allocation at p.
pub fn usable_size(p: raw.Ptr<()>): usize uses ffi = malloc_size(p)

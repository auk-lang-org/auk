/// stack.auk's per-OS half, macOS: the calling thread's stack bounds; no symbol reader of its
/// own (dladdr sees every symbol of the executable).

extern fn pthread_self(): cfacts.PthreadT = "pthread_t pthread_self(void)"
extern fn pthread_get_stackaddr_np(th: cfacts.PthreadT): raw.Ptr<()> = "void *pthread_get_stackaddr_np(pthread_t)"
extern fn pthread_get_stacksize_np(th: cfacts.PthreadT): usize = "size_t pthread_get_stacksize_np(pthread_t)"

/// elf_sym_name's buffer (unused here).
pub raw struct SymBuf { b: [u8; 1] }

/// The lowest address of the calling thread's stack (`cur` if it can't be found).
pub fn thread_stack_lo(cur: usize): usize uses raw, ffi {
  let me = pthread_self()
  let hi = usize(pthread_get_stackaddr_np(me).int())
  hi - pthread_get_stacksize_np(me)
}

/// The function symbol containing pc, from the executable's .symtab: Linux only.
pub fn elf_sym_name(pc: usize, out: raw.Ptr<u8>, cap: usize): bool uses raw, ffi = false

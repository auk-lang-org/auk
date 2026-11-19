/// stack.auk's per-OS half, Linux: the calling thread's stack bounds, and the function symbol
/// containing an address, read from the executable's own .symtab (dladdr only sees the dynamic
/// symbol table, which doesn't have Auk's local functions).

extern fn c_open(path: raw.Ptr<u8>, flags: i32, ...): i32 = "int open(const char *, int, ...)"
extern fn pthread_self(): cfacts.PthreadT = "pthread_t pthread_self(void)"
extern fn pthread_getattr_np(th: cfacts.PthreadT, a: raw.Ptr<cfacts.PthreadAttr>): i32 = "int pthread_getattr_np(pthread_t, pthread_attr_t *)"
extern fn pthread_attr_getstack(a: raw.Ptr<cfacts.PthreadAttr>, addr: raw.Ptr<raw.Ptr<()>>, size: raw.Ptr<usize>): i32 =
  "int pthread_attr_getstack(const pthread_attr_t *, void **, size_t *)"
extern fn pthread_attr_destroy(a: raw.Ptr<cfacts.PthreadAttr>): i32 = "int pthread_attr_destroy(pthread_attr_t *)"
extern fn pread(fd: i32, buf: raw.Ptr<()>, n: usize, off: i64): i64 = "ssize_t pread(int, void *, size_t, off_t)"
extern fn close(fd: i32): i32 = "int close(int)"
extern fn getauxval(t: u64): u64 = "unsigned long getauxval(unsigned long)"

/// elf_sym_name's buffer.
pub raw struct SymBuf { b: [u8; 256] }

raw let SYMS: usize = 64
raw struct Syms { s: [cfacts.Elf64Sym; 64] }

/// The lowest address of the calling thread's stack (`cur` if it can't be found).
pub fn thread_stack_lo(cur: usize): usize uses raw, ffi {
  var attr = cfacts.PthreadAttr {}
  if pthread_getattr_np(pthread_self(), raw.addr_of(&attr)) != 0 {
    return cur
  }
  var addr: raw.Ptr<()> = raw.null()
  var size: usize = 0
  pthread_attr_getstack(raw.addr_of(&attr), raw.addr_of(&addr), raw.addr_of(&size))
  pthread_attr_destroy(raw.addr_of(&attr))
  usize(addr.int())
}

/// The function symbol containing pc in the executable's own .symtab, into out (cap bytes).
/// Read with pread (async-signal-safe), nothing allocated. True when found.
pub fn elf_sym_name(pc: usize, out: raw.Ptr<u8>, cap: usize): bool uses raw, ffi {
  let fd = c_open("/proc/self/exe", cfacts.O_RDONLY | cfacts.O_CLOEXEC)
  if fd < 0 {
    return false
  }
  var found = false
  var eh = cfacts.Elf64Ehdr {}
  let ehsz = raw.size_of<cfacts.Elf64Ehdr>()
  let shsz = raw.size_of<cfacts.Elf64Shdr>()
  let symsz = raw.size_of<cfacts.Elf64Sym>()
  // e_ident's first SELFMAG bytes
  let magic: raw.Ptr<u32> = raw.cast(raw.addr_of(&eh))
  if pread(fd, raw.cast(raw.addr_of(&eh)), ehsz, 0) != i64(ehsz) || magic.load() != cfacts.ELFMAG || usize(eh.e_shentsize) != shsz {
    close(fd)
    return false
  }
  // a PIE is loaded at its program headers' address less their file offset
  let addr = if i32(eh.e_type) == cfacts.ET_DYN { pc - (usize(getauxval(u64(cfacts.AT_PHDR))) - usize(eh.e_phoff)) } else { pc }
  var sh = cfacts.Elf64Shdr {}
  var strtab = cfacts.Elf64Shdr {}
  var syms = Syms {}
  let sp: raw.Ptr<cfacts.Elf64Sym> = raw.cast(raw.addr_of(&syms))
  var i: u32 = 0
  while i < u32(eh.e_shnum) && !found {
    let at = eh.e_shoff + u64(i) * u64(shsz)
    i += 1
    if pread(fd, raw.cast(raw.addr_of(&sh)), shsz, i64(at)) != i64(shsz) || sh.sh_type != u32(cfacts.SHT_SYMTAB) {
      continue
    }
    if pread(fd, raw.cast(raw.addr_of(&strtab)), shsz, i64(eh.e_shoff + u64(sh.sh_link) * u64(shsz))) != i64(shsz) {
      break
    }
    let n = usize(sh.sh_size) / symsz
    var k: usize = 0
    while k < n && !found {
      let m = if n - k < SYMS { n - k } else { SYMS }
      if pread(fd, raw.cast(sp), m * symsz, i64(sh.sh_offset + u64(k * symsz))) != i64(m * symsz) {
        break
      }
      var j: usize = 0
      while j < m {
        let s = sp.offset(j)
        if cfacts.elf64_st_type(s.st_info) == u8(cfacts.STT_FUNC) && u64(addr) >= s.st_value && u64(addr) < s.st_value + s.st_size {
          let r = pread(fd, raw.cast(out), cap - 1, i64(strtab.sh_offset + u64(s.st_name)))
          out.at(if r > 0 { usize(r) } else { 0 }) = 0
          found = r > 0
          break
        }
        j += 1
      }
      k += SYMS
    }
  }
  close(fd)
  found
}

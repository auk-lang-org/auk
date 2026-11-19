/// Stacks: programs, tests and tasks run on threads with big stacks, and a stack overflow is a
/// panic "stack overflow" instead of a bare SIGSEGV (was runtime/c/stack.c, ported line by
/// line).
///
/// Every Auk thread (the program's main thread, a test's, each task's) calls
/// auk__stack_thread_begin first: it records the thread's stack bounds and gives it an
/// alternate signal stack. The SIGSEGV/SIGBUS handler runs there; a fault just below the
/// stack (in or past its guard pages) is an overflow:
/// - on a thread with a recovery point (`catch`, every task) it jumps back to it, like a panic
///   (catch.auk), with the message "stack overflow";
/// - otherwise it prints `panic: stack overflow` and exits 101, like any panic.
/// Any other fault goes on to the handler that was installed before (the tracer's, or the
/// compiler's own when the program runs in its process), or to the default action.
///
/// The location is the function that overflowed, by name, when the executable's symbol table
/// has it (`auk build`); code compiled in memory has no symbols, so it is `<unknown>` there. The
/// handler allocates nothing and writes with write(2).
///
/// What differs per target: the interrupted PC and SP (`cfacts.uc_pc`/`uc_sp`), the thread's
/// stack bounds and the Linux symbol reader (`stackos`, per OS), the return-address slot below
/// a function's entry SP (`cpu`, per CPU).

// the rest of the runtime (C, for now)
extern fn auk__trace_on_overflow(fn_name: raw.Ptr<u8>) = "void auk__trace_on_overflow(const char *)"
extern fn auk__dbg_thread_handoff(): i64 = "int64_t auk__dbg_thread_handoff(void)"
extern fn auk__dbg_thread_adopt(id: i64) = "void auk__dbg_thread_adopt(int64_t)"
// libc
extern fn strlen(s: raw.Ptr<u8>): usize = "size_t strlen(const char *)"
extern fn strncmp(a: raw.Ptr<u8>, b: raw.Ptr<u8>, n: usize): i32 = "int strncmp(const char *, const char *, size_t)"
extern fn c_write(fd: i32, p: raw.Ptr<()>, n: usize): i64 = "ssize_t write(int, const void *, size_t)"
extern fn c_exit(code: i32): never = "void _exit(int)"
extern fn malloc(n: usize): raw.Ptr<()> = "void *malloc(size_t)"
extern fn dladdr(addr: raw.Ptr<()>, info: raw.Ptr<cfacts.DlInfo>): i32 = "int dladdr(const void *, Dl_info *)"
extern fn signal(sig: i32, handler: raw.Ptr<()>): raw.Ptr<()> = "void *signal(int, void *)"
extern fn sigaction(sig: i32, act: raw.Ptr<cfacts.Sigaction>, old: raw.Ptr<cfacts.Sigaction>): i32 =
  "int sigaction(int, const struct sigaction *, struct sigaction *)"
extern fn sigemptyset(set: raw.Ptr<cfacts.SigSet>): i32 = "int sigemptyset(sigset_t *)"
extern fn sigaltstack(ss: raw.Ptr<cfacts.StackT>, old: raw.Ptr<cfacts.StackT>): i32 = "int sigaltstack(const stack_t *, stack_t *)"
extern fn ftrylockfile(f: raw.Ptr<()>): i32 = "int ftrylockfile(FILE *)"
extern fn funlockfile(f: raw.Ptr<()>) = "void funlockfile(FILE *)"
extern fn fflush(f: raw.Ptr<()>): i32 = "int fflush(FILE *)"
extern fn pthread_once(once: raw.Ptr<cfacts.PthreadOnce>, f: raw.Fn<() => ()>): i32 = "int pthread_once(pthread_once_t *, void (*)(void))"
extern fn pthread_attr_init(a: raw.Ptr<cfacts.PthreadAttr>): i32 = "int pthread_attr_init(pthread_attr_t *)"
extern fn pthread_attr_destroy(a: raw.Ptr<cfacts.PthreadAttr>): i32 = "int pthread_attr_destroy(pthread_attr_t *)"
extern fn pthread_attr_setstacksize(a: raw.Ptr<cfacts.PthreadAttr>, n: usize): i32 = "int pthread_attr_setstacksize(pthread_attr_t *, size_t)"
extern fn pthread_attr_setguardsize(a: raw.Ptr<cfacts.PthreadAttr>, n: usize): i32 = "int pthread_attr_setguardsize(pthread_attr_t *, size_t)"
extern fn pthread_create(th: raw.Ptr<cfacts.PthreadT>, a: raw.Ptr<cfacts.PthreadAttr>, f: raw.Fn<(raw.Ptr<()>) => raw.Ptr<()>>, arg: raw.Ptr<()>): i32 =
  "int pthread_create(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *)"
extern fn pthread_join(th: cfacts.PthreadT, ret: raw.Ptr<raw.Ptr<()>>): i32 = "int pthread_join(pthread_t, void **)"

/// Bytes below a thread's stack that count as an overflow when touched: the guard pages, and
/// a frame that jumped past them.
raw let STACK_SLACK: usize = 1048576 // 1 << 20
/// The guard below the stacks this runtime starts (a big frame can skip a small one).
raw let STACK_GUARD: usize = 262144 // 256 << 10
raw let ALT_STACK_SIZE: usize = 65536 // 64 << 10
raw let LOC_CAP: usize = 160

raw struct LocBuf { b: [u8; 160] }

raw thread var stack_lo: usize = 0
raw thread var alt_stack: raw.Ptr<()> = raw.null()
/// The overflow's location for a recovery point to pick up (catch.auk).
raw thread var overflow_loc: LocBuf = LocBuf {}

raw var old_segv: cfacts.Sigaction = cfacts.Sigaction {}
raw var old_bus: cfacts.Sigaction = cfacts.Sigaction {}
raw var install_once: cfacts.PthreadOnce = cfacts.PTHREAD_ONCE_INIT

fn put(s0: raw.Ptr<u8>) uses raw, ffi {
  var s = s0
  var n = strlen(s)
  while n > 0 {
    let w = c_write(2, raw.cast(s), n)
    if w <= 0 {
      return
    }
    s = s.offset(w)
    n -= usize(w)
  }
}

fn fault_pc(uc: raw.Ptr<()>): usize uses raw {
  if uc.is_null() {
    return 0
  }
  usize(cfacts.uc_pc(uc).load())
}

/// The Auk name of the function at pc ("dk_f12_parse" -> "parse"), into out; "<unknown>"
/// when there are no symbols.
fn fn_name(pc: usize, out: raw.Ptr<u8>, cap: usize) uses raw, ffi {
  var name: raw.Ptr<u8> = raw.null()
  var info = cfacts.DlInfo {}
  // Linux: the executable's own .symtab (dladdr only sees the dynamic symbols)
  var sym = stackos.SymBuf {}
  let symp: raw.Ptr<u8> = raw.cast(raw.addr_of(&sym))
  if pc != 0 && stackos.elf_sym_name(pc, symp, raw.size_of<stackos.SymBuf>()) {
    name = symp
  } else if pc != 0 && dladdr(raw.from_int(pc), raw.addr_of(&info)) != 0 && !info.dli_sname.is_null() {
    name = info.dli_sname
  }
  if !name.is_null() {
    if name.at(0) == 95 { // '_'
      name = name.offset(1)
    }
    if strncmp(name, "dk_f", 4) == 0 {
      var p = name.offset(4)
      while p.at(0) >= 48 && p.at(0) <= 57 { // '0'..'9'
        p = p.offset(1)
      }
      if p.at(0) == 95 {
        name = p.offset(1)
      }
    }
  }
  if name.is_null() || name.at(0) == 0 {
    name = "<unknown>"
  }
  var n = strlen(name)
  if n >= cap {
    n = cap - 1
  }
  raw.copy(out, name, n)
  out.at(n) = 0
}

fn pass_on(sig: i32, si: raw.Ptr<()>, uc: raw.Ptr<()>) uses raw, ffi {
  let old = if sig == cfacts.SIGBUS { raw.addr_of(&old_bus) } else { raw.addr_of(&old_segv) }
  // one field for C's sa_handler/sa_sigaction union
  let h = old.sa_handler
  if (old.sa_flags & cfacts.SA_SIGINFO) != 0 && !h.is_null() {
    let f: raw.Fn<(i32, raw.Ptr<()>, raw.Ptr<()>) => ()> = raw.cast(h)
    f(sig, si, uc)
    return
  }
  let hv = i64(h.int())
  if hv != cfacts.SIG_DFL && hv != cfacts.SIG_IGN && !h.is_null() {
    let f: raw.Fn<(i32) => ()> = raw.cast(h)
    f(sig)
    return
  }
  // the default action: returning re-runs the faulting instruction, which faults again
  let _ = signal(sig, raw.from_int(cfacts.SIG_DFL))
}

/// Runs on the overflowed thread's own stack after the handler returns: on to the recovery
/// point.
fn overflow_resume() uses raw, ffi {
  recover.auk__catch_throw_overflow()
}

/// Make the handler return into overflow_resume, on a little stack just above the overflow and
/// below the recovery point (the frames between are abandoned anyway). Jumping straight out of
/// the handler would leave the kernel thinking the thread is still on its alternate stack
/// (macOS), and the next overflow could not be reported.
fn redirect(uc: raw.Ptr<()>): bool uses raw, ffi {
  let lo = stack_lo
  var sp = lo + 32768 // 32 << 10
  let rp = recover.auk__catch_top_addr()
  if rp != 0 && rp - 512 < sp {
    sp = rp - 512
  }
  sp = sp / 16 * 16
  if uc.is_null() || sp <= lo {
    return false
  }
  cfacts.uc_pc(uc).store(u64(raw.cast<()>(raw.fn_of(overflow_resume)).int()))
  // x86-64: where a call would have pushed the return address
  cfacts.uc_sp(uc).store(u64(sp - cpu.RET_SLOT))
  true
}

fn flush_stdout() uses raw, ffi {
  // what the program printed so far, unless the overflow hit inside stdio
  let out = cfacts.stdout()
  if ftrylockfile(out) == 0 {
    fflush(out)
    funlockfile(out)
  }
}

/// The SIGSEGV/SIGBUS handler (sigaction's sa_sigaction).
fn on_fault(sig: i32, si: raw.Ptr<()>, uc: raw.Ptr<()>) uses raw, ffi {
  let a = usize(cfacts.si_addr(si).int())
  let lo = stack_lo
  let overflow = lo != 0 && a < lo + 4096 && a + STACK_SLACK >= lo
  if !overflow {
    pass_on(sig, si, uc)
    return
  }
  let loc: raw.Ptr<u8> = raw.cast(raw.addr_of(&overflow_loc))
  fn_name(fault_pc(uc), loc, LOC_CAP)
  if recover.auk__catch_active() != 0 {
    if redirect(uc) {
      return
    }
    recover.auk__catch_throw_overflow()
  }
  flush_stdout()
  auk__trace_on_overflow(loc)
  put("panic: stack overflow\n  at ")
  put(loc)
  put("\n")
  c_exit(101)
}

fn install() uses raw, ffi {
  var sa = cfacts.Sigaction {}
  let handler: raw.Ptr<()> = raw.cast(raw.fn_of(on_fault))
  // already in front: keep the handler it passes other faults on to
  if sigaction(cfacts.SIGSEGV, raw.null(), raw.addr_of(&sa)) == 0 && (sa.sa_flags & cfacts.SA_SIGINFO) != 0 && sa.sa_handler == handler {
    return
  }
  sa = cfacts.Sigaction {}
  sa.sa_handler = handler
  // SA_NODEFER: a recovery point jumps out of the handler, which must leave SIGSEGV
  // unblocked for the next overflow
  sa.sa_flags = cfacts.SA_SIGINFO | cfacts.SA_ONSTACK | cfacts.SA_NODEFER
  sigemptyset(raw.field_addr(raw.addr_of(&sa), .sa_mask))
  sigaction(cfacts.SIGSEGV, raw.addr_of(&sa), raw.addr_of(&old_segv))
  let _ = sigaction(cfacts.SIGBUS, raw.addr_of(&sa), raw.addr_of(&old_bus))
}

/// Put the overflow handler back in front of a crash handler installed after it (the tracer's),
/// which then gets the faults that aren't overflows. The first Auk thread installs it once, so
/// in a process whose runtime started before the program (the self-hosted compiler running the
/// program it compiled) the tracer's handler would otherwise come first, and an overflow would
/// end as a bare signal instead of a panic.
export fn auk__stack_handlers_first() uses raw, ffi {
  install()
}

/// At the start of an Auk thread: record its stack and give it an alternate signal stack.
export fn auk__stack_thread_begin() uses raw, ffi {
  pthread_once(raw.addr_of(&install_once), raw.fn_of(install))
  stack_lo = stackos.thread_stack_lo(stack_lo)
  if alt_stack.is_null() {
    alt_stack = malloc(ALT_STACK_SIZE)
    if !alt_stack.is_null() {
      var ss = cfacts.StackT {}
      ss.ss_sp = alt_stack
      ss.ss_size = u64(ALT_STACK_SIZE)
      sigaltstack(raw.addr_of(&ss), raw.null())
    }
  }
}

/// At the end of an Auk thread started by the runtime.
export fn auk__stack_thread_end() uses raw, ffi {
  stack_lo = 0
  if !alt_stack.is_null() {
    var ss = cfacts.StackT {}
    ss.ss_flags = cfacts.SS_DISABLE
    sigaltstack(raw.addr_of(&ss), raw.null())
    raw.free(alt_stack)
    alt_stack = raw.null()
  }
}

/// The location of the last overflow on this thread (for catch.auk).
pub export fn auk__stack_overflow_loc(): raw.Ptr<u8> uses raw = raw.cast(raw.addr_of(&overflow_loc))

/// Attributes for a thread with a stack of `size` bytes and a big guard.
export fn auk__stack_attr(a: raw.Ptr<()>, size: usize) uses raw, ffi {
  let attr: raw.Ptr<cfacts.PthreadAttr> = raw.cast(a)
  pthread_attr_init(attr)
  pthread_attr_setstacksize(attr, size)
  let _ = pthread_attr_setguardsize(attr, STACK_GUARD)
}

raw struct BigRun {
  f: raw.Fn<(raw.Ptr<()>) => ()>,
  arg: raw.Ptr<()>,
  dbg_id: i64,
}

fn big_entry(p: raw.Ptr<()>): raw.Ptr<()> uses raw, ffi {
  let r: raw.Ptr<BigRun> = raw.cast(p)
  auk__dbg_thread_adopt(r.dbg_id)
  auk__stack_thread_begin()
  let f = r.f
  f(r.arg)
  auk__stack_thread_end()
  raw.null()
}

/// Run f(arg) on a new thread with a stack of AUK_MAIN_STACK bytes and wait for it (on this
/// thread, with overflow reporting, when no thread can be started).
export fn auk__run_on_big_stack(f: raw.Fn<(raw.Ptr<()>) => ()>, arg: raw.Ptr<()>) uses raw, ffi {
  var r = BigRun { f, arg, dbg_id: auk__dbg_thread_handoff() }
  var attr = cfacts.PthreadAttr {}
  auk__stack_attr(raw.cast(raw.addr_of(&attr)), abi.MAIN_STACK)
  var th = cfacts.PthreadT {}
  let rc = pthread_create(raw.addr_of(&th), raw.addr_of(&attr), raw.fn_of(big_entry), raw.cast(raw.addr_of(&r)))
  pthread_attr_destroy(raw.addr_of(&attr))
  if rc != 0 {
    auk__dbg_thread_adopt(r.dbg_id)
    auk__stack_thread_begin()
    f(arg)
    return
  }
  let _ = pthread_join(th, raw.null())
}

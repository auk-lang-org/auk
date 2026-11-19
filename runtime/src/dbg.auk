/// The debugger engine (`auk run --debug`): breakpoints, stepping, pausing, stack and locals.
/// (Was runtime/c/dbg.c, ported line by line with dbg_text.auk (text helpers), dbg_info.auk (the
/// debug info, breakpoint specs), dbg_show.auk (frames, values, parts, locals) and dbg_expr.auk
/// (expressions, the eval mailbox, Ctrl-C).)
///
/// Only programs compiled with --debug call into this module. Every instrumented Auk function
/// keeps a frame record (abi.DbgFrame) on its stack: auk_dbg_enter/auk_dbg_leave link it into
/// the thread's debugger stack, each named local's address is stored in its slot when the local
/// is bound, and each statement stores its site id in `site` and calls auk_dbg_hook while
/// auk_dbg_armed is set. main calls auk_dbg_init with the debug info (sites, functions, locals,
/// types) and a table of show functions, one per local type.
///
/// A front end (`auk debug`, `auk dap`) attaches through a Unix socket named by AUK_DEBUG: the
/// program connects, sends {"ev":"ready"} and waits for `run`. Without AUK_DEBUG the program runs
/// as usual (auk_dbg_armed stays 0).
///
/// Protocol: commands are text lines, optionally prefixed with `@<seq> ` (echoed as "seq":N in
/// the reply):
///   run                         start the program (after setting breakpoints)
///   break <file>:<line>         line breakpoint (moves to the next line with code)
///   break <function>            function breakpoint (`f`, or `mod.f`)
///   break <place> if <cond>     only where the Auk expression cond is true
///   delete [id]                 remove one breakpoint, or all
///   catch all|uncaught|none     stop on panics (default uncaught: not under a recovery point)
///   pause                       stop every thread at its next statement
///   kill                        end the program
/// While stopped:
///   continue | step | next | finish     resume (step into / over / out of, on the focus thread)
///   stack [thread]              the frames, innermost first
///   vars [frame] [thread]       the frame's locals in scope, shown
///   threads                     every thread with its innermost frame
///   kids <frame> <thread> <local> [i...]   the parts of a local (or of part i, j...)
///   eval <frame> <thread> <expr>           an Auk expression's value there (an assignment
///                               `x = v` changes a var local; compiler/src/dbg_eval.auk compiles it)
/// Events are JSON lines: ready, ok, error, break, stopped, stack, vars, kids, value, threads,
/// exited. When one thread stops, every other thread stops at its next statement (all-stop); a
/// thread blocked in a call (sleep, recv, I/O) stops when it returns.
///
/// The C's five thread-locals (the frame chain's top, its depth, the debugger id, the frame_op
/// flag, the step) are one `raw thread var` struct (`cur`): one thread-local lookup per entry
/// point, and a thread the debugger knows is one pointer to it.

extern fn c_strlen(s: raw.Ptr<u8>): usize = "size_t strlen(const char *)"
extern fn strstr(s: raw.Ptr<u8>, sub: raw.Ptr<u8>): raw.Ptr<u8> = "char *strstr(const char *, const char *)"
extern fn strerror(code: i32): raw.Ptr<u8> = "char *strerror(int)"
extern fn getenv(name: raw.Ptr<u8>): raw.Ptr<u8> = "char *getenv(const char *)"
extern fn getpid(): i32 = "int getpid(void)"
extern fn socket(family: i32, kind: i32, proto: i32): i32 = "int socket(int, int, int)"
extern fn connect(fd: i32, addr: raw.Ptr<cfacts.Sockaddr>, len: u32): i32 = "int connect(int, const void *, uint32_t)"
extern fn send(fd: i32, p: raw.Ptr<()>, n: usize, flags: i32): i64 = "ssize_t send(int, const void *, size_t, int)"
extern fn c_read(fd: i32, p: raw.Ptr<()>, n: usize): i64 = "ssize_t read(int, void *, size_t)"
extern fn close(fd: i32): i32 = "int close(int)"
extern fn dup(fd: i32): i32 = "int dup(int)"
extern fn c_fflush(f: raw.Ptr<()>): i32 = "int fflush(void *)"
extern fn c_fwrite(p: raw.Ptr<u8>, size: usize, n: usize, f: raw.Ptr<()>): usize = "size_t fwrite(const void *, size_t, size_t, void *)"
extern fn setvbuf(f: raw.Ptr<()>, buf: raw.Ptr<u8>, mode: i32, size: usize): i32 = "int setvbuf(void *, char *, int, size_t)"
extern fn c_exit(code: i32): never = "void _exit(int)"
extern fn atexit(f: raw.Fn<() => ()>): i32 = "int atexit(void (*)(void))"
extern fn sched_yield(): i32 = "int sched_yield(void)"
extern fn pthread_mutex_lock(m: raw.Ptr<cfacts.PthreadMutex>): i32 = "int pthread_mutex_lock(void *)"
extern fn pthread_mutex_unlock(m: raw.Ptr<cfacts.PthreadMutex>): i32 = "int pthread_mutex_unlock(void *)"
extern fn pthread_cond_broadcast(cv: raw.Ptr<cfacts.PthreadCond>): i32 = "int pthread_cond_broadcast(void *)"
extern fn pthread_cond_wait(cv: raw.Ptr<cfacts.PthreadCond>, m: raw.Ptr<cfacts.PthreadMutex>): i32 =
  "int pthread_cond_wait(void *, void *)"
extern fn pthread_once(once: raw.Ptr<cfacts.PthreadOnce>, f: raw.Fn<() => ()>): i32 = "int pthread_once(pthread_once_t *, void (*)(void))"
extern fn pthread_key_create(key: raw.Ptr<cfacts.PthreadKey>, destructor: raw.Fn<(raw.Ptr<()>) => ()>): i32 =
  "int pthread_key_create(void *, void (*)(void *))"
// pthread_key_t by value: one integer register (an unsigned long on macOS, an unsigned int on
// Linux, whose upper half the callee ignores)
extern fn pthread_setspecific(key: u64, v: raw.Ptr<()>): i32 = "int pthread_setspecific(uint64_t, const void *)"
extern fn pthread_attr_init(a: raw.Ptr<cfacts.PthreadAttr>): i32 = "int pthread_attr_init(pthread_attr_t *)"
extern fn pthread_attr_setdetachstate(a: raw.Ptr<cfacts.PthreadAttr>, s: i32): i32 = "int pthread_attr_setdetachstate(pthread_attr_t *, int)"
extern fn pthread_attr_destroy(a: raw.Ptr<cfacts.PthreadAttr>): i32 = "int pthread_attr_destroy(void *)"
extern fn pthread_create(th: raw.Ptr<cfacts.PthreadT>, attr: raw.Ptr<cfacts.PthreadAttr>, start: raw.Fn<(raw.Ptr<()>) => raw.Ptr<()>>, arg: raw.Ptr<()>): i32 =
  "int pthread_create(void *, const void *, void *, void *)"

/// C's _IOLBF (1 on macOS and glibc).
raw let IOLBF: i32 = 1
/// C's UINT32_MAX.
raw let U32_MAX: i64 = 4294967295

/// Non-zero while the debugger wants to see statements: generated code calls auk_dbg_hook only
/// then. (C: `_Atomic int64_t`; written with sequentially consistent stores.)
export var auk_dbg_armed: i64 = 0

/// The front end is attached (an atomic bool).
raw var attached: i32 = 0
raw var next_thread: i64 = 1

raw let STEP_NONE: i32 = 0
raw let STEP_IN: i32 = 1
raw let STEP_OVER: i32 = 2
raw let STEP_OUT: i32 = 3

/// A step in progress on this thread; it lapses at the next stop (any thread's): epoch.
raw struct Step {
  kind: i32,
  epoch: u64,
  depth: i64,
  line: u32,
  site: i64,
}

/// A thread's debugger state (C: the thread-locals dbg_top, dbg_depth, dbg_tid, dbg_in_op,
/// dbg_step).
raw struct PerThread {
  /// the innermost frame
  top: raw.Ptr<abi.DbgFrame>,
  depth: i64,
  /// the debugger id (0: not registered)
  tid: i64,
  /// Set while this thread changes its frame chain (top, a frame's parent): see frame_op. Atomic.
  in_op: i32,
  step: Step,
}

raw thread var cur: PerThread = PerThread {}

raw let CATCH_ALL: i32 = 0
raw let CATCH_UNCAUGHT: i32 = 1
raw let CATCH_NONE: i32 = 2

raw struct Bp {
  id: i64,
  sites: raw.Ptr<u32>,
  nsites: i64,
  /// stop only where this Auk expression is true (null: always)
  cond: raw.Ptr<u8>,
}

/// A thread the debugger knows: its id and its state (the frame pointer, the frame_op flag).
raw struct ThreadRef {
  id: i64,
  th: raw.Ptr<PerThread>,
}

/// A command for the stopped focus thread.
raw struct Cmd {
  has_seq: bool,
  seq: i64,
  text: raw.Ptr<u8>,
}

raw var st_lock: cfacts.PthreadMutex = cfacts.PTHREAD_MUTEX_INITIALIZER
raw var st_cv: cfacts.PthreadCond = cfacts.PTHREAD_COND_INITIALIZER
raw var st_running: bool = false
raw var st_stopped: bool = false
/// st_stopped for readers without the lock (frame_op); written with it (an atomic bool)
raw var st_halt: i32 = 0
raw var st_focus: i64 = 0
/// bumped at every stop (steps lapse) and every resume (parked threads wake)
raw var st_epoch: u64 = 0
raw var st_pause_req: bool = false
/// A `pause` that came while stopped, behind this many commands not yet served (queued, or the
/// one the focus thread is serving): commands run in order, so if one of those resumes, the
/// pause applies after it (a "continue" then "pause" must stop again); if none does, the program
/// was stopped all along and the pause is a no-op.
raw var st_pause_after: i64 = 0
/// the focus thread is serving a command it took off the queue
raw var st_serving: bool = false
raw var st_stepping: bool = false
raw var st_catch_mode: i32 = CATCH_UNCAUGHT
raw var st_bps: raw.Ptr<Bp> = raw.null()
raw var st_nbps: i64 = 0
raw var st_capbps: i64 = 0
raw var st_next_bp: i64 = 1
raw var st_queue: raw.Ptr<Cmd> = raw.null()
raw var st_qhead: i64 = 0
raw var st_qlen: i64 = 0
raw var st_qcap: i64 = 0
raw var st_threads: raw.Ptr<ThreadRef> = raw.null()
raw var st_nthreads: i64 = 0
raw var st_capthreads: i64 = 0

raw var out_lock: cfacts.PthreadMutex = cfacts.PTHREAD_MUTEX_INITIALIZER
raw var out_fd: i32 = -1

fn lock(m: raw.Ptr<cfacts.PthreadMutex>) uses ffi {
  let _ = pthread_mutex_lock(m)
}

fn unlock(m: raw.Ptr<cfacts.PthreadMutex>) uses ffi {
  let _ = pthread_mutex_unlock(m)
}

fn lock_st() uses raw, ffi {
  lock(raw.addr_of(&st_lock))
}

fn unlock_st() uses raw, ffi {
  unlock(raw.addr_of(&st_lock))
}

fn wait_st() uses raw, ffi {
  let _ = pthread_cond_wait(raw.addr_of(&st_cv), raw.addr_of(&st_lock))
}

fn wake_st() uses raw, ffi {
  let _ = pthread_cond_broadcast(raw.addr_of(&st_cv))
}

fn halt(on: bool) uses raw {
  raw.atomic_store(raw.addr_of(&st_halt), if on { 1 } else { 0 }, raw.Order.SeqCst)
}

fn is_attached(): bool uses raw = raw.atomic_load(raw.addr_of(&attached), raw.Order.Relaxed) != 0

/// The breakpoint count of a site.
fn bp_at(site: i64): raw.Ptr<u32> uses raw = dbg_info.info.bp.offset(site)

/// Recompute auk_dbg_armed from the state (st_lock held).
fn rearm() uses raw {
  let on = !st_running || st_stopped || st_pause_req || st_stepping || st_nbps != 0
  raw.atomic_store(raw.addr_of(&auk_dbg_armed), if on { 1 } else { 0 }, raw.Order.SeqCst)
}

/// Wait (st_lock held) until no thread is stopped.
fn wait_not_stopped() uses raw, ffi {
  while st_stopped {
    let g = st_epoch
    while st_stopped && st_epoch == g {
      wait_st()
    }
  }
}

// Removes the thread from the debugger's list when it ends.
raw var reg_key: cfacts.PthreadKey = cfacts.PthreadKey {}
raw var reg_once: cfacts.PthreadOnce = cfacts.PTHREAD_ONCE_INIT

fn unregister(v: raw.Ptr<()>) uses raw, ffi {
  let id = v.int()
  lock_st()
  var k: i64 = 0
  var i: i64 = 0
  while i < st_nthreads {
    if st_threads.offset(i).id != id {
      st_threads.at(k) = st_threads.at(i)
      k += 1
    }
    i += 1
  }
  st_nthreads = k
  unlock_st()
}

fn make_reg_key() uses raw, ffi {
  let _ = pthread_key_create(raw.addr_of(&reg_key), raw.fn_of(unregister))
}

/// This thread's debugger id (registering it on first use).
fn tid(): i64 uses raw, ffi {
  let t = raw.addr_of(&cur)
  if t.tid != 0 {
    return t.tid
  }
  let id = raw.atomic_add(raw.addr_of(&next_thread), 1, raw.Order.SeqCst)
  register_as(id)
  id
}

/// The thread that starts main on a big stack (stack.auk) hands its debugger id to it, so main
/// stays thread 1: the id (0: none), which this thread no longer has.
pub export fn auk__dbg_thread_handoff(): i64 uses raw, ffi {
  let t = raw.addr_of(&cur)
  let id = t.tid
  if id != 0 {
    unregister(raw.from_int(id))
    let _ = pthread_setspecific(u64(reg_key.w0), raw.null())
    t.tid = 0
  }
  id
}

/// On the new thread: take over the id.
pub export fn auk__dbg_thread_adopt(id: i64) uses raw, ffi {
  if id != 0 {
    register_as(id)
  }
}

fn register_as(id: i64) uses raw, ffi {
  let t = raw.addr_of(&cur)
  t.tid = id
  let _ = pthread_once(raw.addr_of(&reg_once), raw.fn_of(make_reg_key))
  let _ = pthread_setspecific(u64(reg_key.w0), raw.from_int(id))
  lock_st()
  if st_nthreads == st_capthreads {
    st_capthreads = if st_capthreads == 0 { 8 } else { st_capthreads * 2 }
    st_threads = raw.cast(raw.realloc(st_threads, usize(st_capthreads) * raw.size_of<ThreadRef>()))
  }
  let r = st_threads.offset(st_nthreads)
  r.id = id
  r.th = t
  st_nthreads += 1
  unlock_st()
}

// A thread's frame chain is read by the stopped focus thread (`stack`, `vars`, `threads`) while
// the other threads are parked in the hook. But a thread that was blocked in a call when the
// world stopped is still running: when the call returns it pushes and pops frames until its
// next statement parks it, and a popped frame is dead stack memory. So a thread changes its
// chain only inside frame_op_begin/end: it raises its in_op flag, and while the world is stopped
// it lowers it and parks instead. The focus thread sets st_halt and then waits for a thread's
// flag to be down (settle) before reading its chain. Both sides store, then load the other's
// flag, sequentially consistent (Dekker): either the thread sees st_halt and parks, or the
// reader sees the flag up and waits for the change to finish. A thread the debugger never
// registered (tid 0) is never read, and the busy thread (serving commands, evaluating) must
// not park on itself.
//
// Not covered: the site and locals a thread returning from a blocking call writes before its
// next statement parks it. The site is one aligned 8-byte store, read relaxed (frame_site); a
// local shown at that moment may be half-updated.
fn frame_op_begin(t: raw.Ptr<PerThread>) uses raw, ffi {
  if t.tid == 0 {
    return
  }
  let flag = raw.field_addr(t, .in_op)
  loop {
    raw.atomic_store(flag, 1, raw.Order.SeqCst)
    if raw.atomic_load(raw.addr_of(&st_halt), raw.Order.SeqCst) == 0 || str.auk__dbg_busy() {
      return
    }
    raw.atomic_store(flag, 0, raw.Order.SeqCst)
    lock_st()
    wait_not_stopped()
    unlock_st()
  }
}

fn frame_op_end(t: raw.Ptr<PerThread>) uses raw {
  if t.tid != 0 {
    raw.atomic_store(raw.field_addr(t, .in_op), 0, raw.Order.Release)
  }
}

/// Wait until thread r is not changing its frame chain (st_halt set: it won't start again).
fn settle(r: raw.Ptr<ThreadRef>) uses raw, ffi {
  let flag = raw.field_addr(r.th, .in_op)
  while raw.atomic_load(flag, raw.Order.SeqCst) != 0 {
    let _ = sched_yield()
  }
}

// ---- the connection ---------------------------------------------------------------------------

fn emit(line: raw.Ptr<u8>) uses raw, ffi {
  lock(raw.addr_of(&out_lock))
  if out_fd >= 0 {
    let n = c_strlen(line)
    let b: raw.Ptr<u8> = raw.cast(raw.alloc(n + 1))
    raw.copy(b, line, n)
    b.at(n) = 0x0A
    var off: usize = 0
    while off < n + 1 {
      // send, not write: a front end that hung up must not kill the program with SIGPIPE
      // (auk__send_flags, or SO_NOSIGPIPE set at connect); the reader sees the hang-up and lets
      // it run on
      let w = send(out_fd, raw.cast(b.offset(off)), n + 1 - off, core_net.auk__send_flags)
      if w < 0 && cfacts.errno() == cfacts.EINTR {
        continue
      }
      if w <= 0 {
        let _ = close(out_fd)
        out_fd = -1
        break
      }
      off += usize(w)
    }
    raw.free(b)
  }
  unlock(raw.addr_of(&out_lock))
}

fn reply(c: raw.Ptr<Cmd>, ev: raw.Ptr<u8>, rest: raw.Ptr<u8>) uses raw, ffi {
  var t = dbg_text.Text {}
  let tp = raw.addr_of(&t)
  dbg_text.put(tp, "{{\"ev\":\"")
  dbg_text.put(tp, ev)
  dbg_text.put(tp, "\"")
  if !c.is_null() && c.has_seq {
    dbg_text.put(tp, ",\"seq\":")
    dbg_text.put_int(tp, c.seq)
  }
  dbg_text.put(tp, rest)
  dbg_text.put(tp, "}}")
  emit(t.p)
  raw.free(t.p)
}

fn reply_error(c: raw.Ptr<Cmd>, msg: raw.Ptr<u8>) uses raw, ffi {
  let e = dbg_text.esc(msg)
  var t = dbg_text.Text {}
  let tp = raw.addr_of(&t)
  dbg_text.put(tp, ",\"msg\":\"")
  dbg_text.put(tp, e)
  dbg_text.put(tp, "\"")
  reply(c, "error", t.p)
  raw.free(t.p)
  raw.free(e)
}

// ---- frames -----------------------------------------------------------------------------------

/// The innermost frame of thread t (stopped: its frames don't change); false if there is no
/// such thread.
fn thread_top(t: i64, me: i64, out: raw.Ptr<raw.Ptr<abi.DbgFrame>>): bool uses raw, ffi {
  if t == me {
    out.store(raw.addr_of(&cur).top)
    return true
  }
  lock_st()
  var found = false
  var i: i64 = 0
  while i < st_nthreads {
    let r = st_threads.offset(i)
    if r.id == t {
      settle(r)
      out.store(r.th.top)
      found = true
      break
    }
    i += 1
  }
  unlock_st()
  found
}

/// "<what><n>" (malloc'd): "no thread 3".
fn no_such(what: raw.Ptr<u8>, n: i64): raw.Ptr<u8> uses raw, ffi {
  var m = dbg_text.Text {}
  dbg_text.put(raw.addr_of(&m), what)
  dbg_text.put_int(raw.addr_of(&m), n)
  m.p
}

/// Frame n (0 = innermost) of thread t, or null with *err (malloc'd).
fn frame_at(t: i64, n: i64, me: i64, err: raw.Ptr<raw.Ptr<u8>>): raw.Ptr<abi.DbgFrame> uses raw, ffi {
  var f: raw.Ptr<abi.DbgFrame> = raw.null()
  if !thread_top(t, me, raw.addr_of(&f)) {
    err.store(no_such("no thread ", t))
    return raw.null()
  }
  var i: i64 = 0
  while i < n && !f.is_null() {
    f = f.parent
    i += 1
  }
  if f.is_null() {
    err.store(no_such("no frame ", n))
  }
  f
}

// ---- stopping ---------------------------------------------------------------------------------

/// Has this thread's step finished at site (st_lock held)?
fn step_done(site: i64): bool uses raw {
  let t = raw.addr_of(&cur)
  let s = raw.field_addr(t, .step)
  if s.kind == STEP_NONE || s.epoch != st_epoch || !st_stepping {
    return false
  }
  let inf = dbg_info.info
  let line: u32 = if site >= 0 && site < inf.nsites { inf.sites.offset(site).line } else { 0 }
  // a new line, or the same statement again (the next loop iteration)
  let moved = line != s.line || site <= s.site
  if s.kind == STEP_IN {
    return t.depth != s.depth || moved
  }
  if s.kind == STEP_OVER {
    return t.depth < s.depth || (t.depth == s.depth && moved)
  }
  if s.kind == STEP_OUT {
    return t.depth < s.depth
  }
  false
}

fn word_int(w: raw.Ptr<raw.Ptr<u8>>, nw: i64, i: i64, dflt: i64): i64 uses raw, ffi {
  var v: i64 = 0
  if i < nw && dbg_text.parse_i64(w.at(i), raw.addr_of(&v)) { v } else { dflt }
}

fn named(s: raw.Ptr<u8>, a: raw.Ptr<u8>): bool uses ffi = dbg_text.eq(s, a)

/// `stack [thread]`.
fn serve_stack(cmd: raw.Ptr<Cmd>, w: raw.Ptr<raw.Ptr<u8>>, nw: i64, me: i64) uses raw, ffi {
  let t = word_int(w, nw, 1, me)
  var top: raw.Ptr<abi.DbgFrame> = raw.null()
  if thread_top(t, me, raw.addr_of(&top)) {
    var r = dbg_text.Text {}
    let rp = raw.addr_of(&r)
    dbg_text.put(rp, ",\"thread\":")
    dbg_text.put_int(rp, t)
    dbg_text.put(rp, ",\"frames\":[")
    var first = true
    var f = top
    while !f.is_null() {
      var j = dbg_text.Text {}
      if !dbg_show.frame_json(raw.addr_of(&j), f) {
        break
      }
      if !first {
        dbg_text.put(rp, ",")
      }
      first = false
      dbg_text.put(rp, j.p)
      raw.free(j.p)
      f = f.parent
    }
    dbg_text.put(rp, "]")
    reply(cmd, "stack", r.p)
    raw.free(r.p)
  } else {
    let e = no_such("no thread ", t)
    reply_error(cmd, e)
    raw.free(e)
  }
}

/// `vars [frame] [thread]`.
fn serve_vars(cmd: raw.Ptr<Cmd>, w: raw.Ptr<raw.Ptr<u8>>, nw: i64, me: i64) uses raw, ffi {
  let n = word_int(w, nw, 1, 0)
  let t = word_int(w, nw, 2, me)
  var err: raw.Ptr<u8> = raw.null()
  let f = frame_at(t, n, me, raw.addr_of(&err))
  if !f.is_null() {
    var r = dbg_text.Text {}
    let rp = raw.addr_of(&r)
    dbg_text.put(rp, ",\"thread\":")
    dbg_text.put_int(rp, t)
    dbg_text.put(rp, ",\"frame\":")
    dbg_text.put_int(rp, n)
    dbg_text.put(rp, ",\"vars\":[")
    var nl: i64 = 0
    let ls = dbg_show.locals_of(f, raw.addr_of(&nl))
    var i: i64 = 0
    while i < nl {
      if i != 0 {
        dbg_text.put(rp, ",")
      }
      let l = ls.offset(i)
      dbg_show.item_json(rp, l.name, l.ty, l.p)
      i += 1
    }
    raw.free(ls)
    dbg_text.put(rp, "]")
    reply(cmd, "vars", r.p)
    raw.free(r.p)
  } else {
    reply_error(cmd, err)
    raw.free(err)
  }
}

/// `kids <frame> <thread> <local> [i...]`: the parts of a local, or of its part i, j...
fn serve_kids(cmd: raw.Ptr<Cmd>, w: raw.Ptr<raw.Ptr<u8>>, nw: i64, me: i64) uses raw, ffi {
  let n = word_int(w, nw, 1, 0)
  let t = word_int(w, nw, 2, me)
  let path: raw.Ptr<u32> = raw.cast(raw.alloc(usize(nw + 1) * raw.size_of<u32>()))
  var np: i64 = 0
  var i: i64 = 4
  while i < nw {
    var v: i64 = 0
    let wi = w.at(i)
    if dbg_text.parse_i64(wi, raw.addr_of(&v)) && v >= 0 && v <= U32_MAX && wi.at(0) != 0x2D && wi.at(0) != 0x2B {
      path.at(np) = u32(v)
      np += 1
    }
    i += 1
  }
  var err: raw.Ptr<u8> = raw.null()
  let f = frame_at(t, n, me, raw.addr_of(&err))
  if f.is_null() {
    reply_error(cmd, err)
    raw.free(err)
  } else if nw < 4 {
    reply_error(cmd, "kids: which local?")
  } else {
    var nl: i64 = 0
    let ls = dbg_show.locals_of(f, raw.addr_of(&nl))
    var hit: raw.Ptr<dbg_show.LocalRef> = raw.null()
    i = 0
    while i < nl && hit.is_null() {
      if dbg_text.eq(ls.offset(i).name, w.at(3)) {
        hit = ls.offset(i)
      }
      i += 1
    }
    if hit.is_null() {
      var m = dbg_text.Text {}
      let mp = raw.addr_of(&m)
      dbg_text.put(mp, "no local `")
      dbg_text.put(mp, w.at(3))
      dbg_text.put(mp, "` here")
      reply_error(cmd, m.p)
      raw.free(m.p)
    } else {
      var r = dbg_text.Text {}
      var why: raw.Ptr<u8> = raw.null()
      if dbg_show.kids_json(raw.addr_of(&r), hit.ty, hit.p, path, np, raw.addr_of(&why)) {
        reply(cmd, "kids", r.p)
      } else {
        reply_error(cmd, why)
      }
      raw.free(r.p)
    }
    raw.free(ls)
  }
  raw.free(path)
}

/// `eval <frame> <thread> <expression>`.
fn serve_eval(cmd: raw.Ptr<Cmd>, w: raw.Ptr<raw.Ptr<u8>>, nw: i64, me: i64) uses raw, ffi {
  let n = word_int(w, nw, 1, 0)
  let t = word_int(w, nw, 2, me)
  let expr = dbg_text.after_words(cmd.text, 3)
  if expr.load() == 0 {
    reply(cmd, "error", ",\"msg\":\"eval: which expression?\"")
    return
  }
  var err: raw.Ptr<u8> = raw.null()
  var value: raw.Ptr<u8> = raw.null()
  var ty: raw.Ptr<u8> = raw.null()
  let f = frame_at(t, n, me, raw.addr_of(&err))
  if !f.is_null() && dbg_expr.eval_at(f, expr, raw.addr_of(&value), raw.addr_of(&ty), raw.addr_of(&err)) {
    var r = dbg_text.Text {}
    let rp = raw.addr_of(&r)
    dbg_text.put(rp, ",\"value\":")
    dbg_text.jsonc(rp, value)
    dbg_text.put(rp, ",\"type\":")
    dbg_text.jsonc(rp, ty)
    reply(cmd, "value", r.p)
    raw.free(r.p)
  } else {
    reply_error(cmd, err)
  }
  raw.free(err)
  raw.free(value)
  raw.free(ty)
}

/// `threads`.
fn serve_threads(cmd: raw.Ptr<Cmd>) uses raw, ffi {
  lock_st()
  let nt = st_nthreads
  let ts: raw.Ptr<ThreadRef> = raw.cast(raw.alloc(usize(nt + 1) * raw.size_of<ThreadRef>()))
  raw.copy(ts, st_threads, usize(nt) * raw.size_of<ThreadRef>())
  let tops: raw.Ptr<raw.Ptr<abi.DbgFrame>> = raw.cast(raw.alloc(usize(nt + 1) * raw.size_of<raw.Ptr<abi.DbgFrame>>()))
  var i: i64 = 0
  while i < nt {
    settle(ts.offset(i))
    tops.at(i) = ts.offset(i).th.top
    i += 1
  }
  unlock_st()
  var r = dbg_text.Text {}
  let rp = raw.addr_of(&r)
  dbg_text.put(rp, ",\"threads\":[")
  i = 0
  while i < nt {
    if i != 0 {
      dbg_text.put(rp, ",")
    }
    dbg_text.put(rp, "{{\"id\":")
    dbg_text.put_int(rp, ts.offset(i).id)
    dbg_text.put(rp, ",\"frame\":")
    if !dbg_show.frame_json(rp, tops.at(i)) {
      dbg_text.put(rp, "null")
    }
    dbg_text.put(rp, "}}")
    i += 1
  }
  dbg_text.put(rp, "]")
  reply(cmd, "threads", r.p)
  raw.free(r.p)
  raw.free(ts)
  raw.free(tops)
}

/// Serve one command of the stopped focus thread: true with *kind for a resume.
fn serve(cmd: raw.Ptr<Cmd>, me: i64, kind: raw.Ptr<i32>): bool uses raw, ffi {
  var nw: i64 = 0
  let w = dbg_text.split_words(cmd.text, raw.addr_of(&nw))
  var resume = false
  let c0 = w.at(0)
  if named(c0, "continue") || named(c0, "c") {
    kind.store(STEP_NONE)
    resume = true
  } else if named(c0, "step") || named(c0, "s") {
    kind.store(STEP_IN)
    resume = true
  } else if named(c0, "next") || named(c0, "n") {
    kind.store(STEP_OVER)
    resume = true
  } else if named(c0, "finish") {
    kind.store(STEP_OUT)
    resume = true
  } else if named(c0, "stack") || named(c0, "bt") {
    serve_stack(cmd, w, nw, me)
  } else if named(c0, "vars") || named(c0, "locals") {
    serve_vars(cmd, w, nw, me)
  } else if named(c0, "kids") {
    serve_kids(cmd, w, nw, me)
  } else if named(c0, "eval") || named(c0, "e") {
    serve_eval(cmd, w, nw, me)
  } else if named(c0, "threads") {
    serve_threads(cmd)
  } else {
    var m = dbg_text.Text {}
    let mp = raw.addr_of(&m)
    dbg_text.put(mp, "unknown command `")
    dbg_text.put(mp, c0)
    dbg_text.put(mp, "`")
    reply_error(cmd, m.p)
    raw.free(m.p)
  }
  dbg_text.free_words(w, nw)
  resume
}

/// Stop the world on this thread (st_lock held, released on return), report it, and serve
/// commands until a resume. extra: more fields for the event (or null).
fn stop(me: i64, reason: raw.Ptr<u8>, extra: raw.Ptr<u8>) uses raw, ffi {
  let t = raw.addr_of(&cur)
  st_stopped = true
  halt(true)
  st_stepping = false
  st_focus = me
  st_epoch += 1
  rearm()
  var ev = dbg_text.Text {}
  let evp = raw.addr_of(&ev)
  dbg_text.put(evp, "{{\"ev\":\"stopped\",\"reason\":\"")
  dbg_text.put(evp, reason)
  dbg_text.put(evp, "\",\"thread\":")
  dbg_text.put_int(evp, me)
  if dbg_text.eq(reason, "breakpoint") && !t.top.is_null() {
    let site = u32(t.top.site)
    dbg_text.put(evp, ",\"bps\":[")
    var first = true
    var i: i64 = 0
    while i < st_nbps {
      let b = st_bps.offset(i)
      var j: i64 = 0
      while j < b.nsites {
        if b.sites.at(j) == site {
          if !first {
            dbg_text.put(evp, ",")
          }
          first = false
          dbg_text.put_int(evp, b.id)
          break
        }
        j += 1
      }
      i += 1
    }
    dbg_text.put(evp, "]")
  }
  var fr = dbg_text.Text {}
  if dbg_show.frame_json(raw.addr_of(&fr), t.top) {
    dbg_text.put(evp, ",\"frame\":")
    dbg_text.put(evp, fr.p)
  }
  raw.free(fr.p)
  if !extra.is_null() {
    dbg_text.put(evp, extra)
  }
  dbg_text.put(evp, "}}")
  emit(ev.p)
  raw.free(ev.p)
  // serve commands until one resumes
  loop {
    while st_qlen == 0 && st_stopped {
      wait_st()
    }
    if !st_stopped {
      // detached
      unlock_st()
      return
    }
    var cmd = st_queue.at(st_qhead)
    st_qhead = (st_qhead + 1) % st_qcap
    st_qlen -= 1
    st_serving = true
    unlock_st()
    let was = str.auk__dbg_set_busy(true)
    var kind = STEP_NONE
    let resume = serve(raw.addr_of(&cmd), me, raw.addr_of(&kind))
    let _ = str.auk__dbg_set_busy(was)
    lock_st()
    st_serving = false
    if st_pause_after > 0 {
      st_pause_after -= 1
      if resume {
        st_pause_req = true
        st_pause_after = 0
      }
    }
    if resume {
      if kind != STEP_NONE {
        let site: i64 = if t.top.is_null() { -1 } else { t.top.site }
        let inf = dbg_info.info
        let line: u32 = if site >= 0 && site < inf.nsites { inf.sites.offset(site).line } else { 0 }
        st_stepping = true
        let s = raw.field_addr(t, .step)
        s.kind = kind
        s.epoch = st_epoch + 1
        s.depth = t.depth
        s.line = line
        s.site = site
      }
      st_stopped = false
      halt(false)
      st_epoch += 1
      rearm()
      wake_st()
      unlock_st()
      reply(raw.addr_of(&cmd), "ok", "")
      raw.free(cmd.text)
      return
    }
    raw.free(cmd.text)
  }
}

// ---- generated code's entry points ------------------------------------------------------------

export fn auk_dbg_enter(f: raw.Ptr<abi.DbgFrame>) uses raw, ffi {
  let t = raw.addr_of(&cur)
  if t.tid == 0 && is_attached() {
    let _ = tid()
  }
  frame_op_begin(t)
  f.parent = t.top
  t.top = f
  frame_op_end(t)
  t.depth += 1
}

export fn auk_dbg_leave(f: raw.Ptr<abi.DbgFrame>) uses raw, ffi {
  let t = raw.addr_of(&cur)
  frame_op_begin(t)
  t.top = f.parent
  frame_op_end(t)
  t.depth -= 1
}

/// Does a breakpoint at site have a condition that holds (or none)? Runs Auk code, without the
/// lock. *extra gets a "cond_error" field when a condition fails to evaluate.
fn bp_hit(f: raw.Ptr<abi.DbgFrame>, site: i64, extra: raw.Ptr<raw.Ptr<u8>>): bool uses raw, ffi {
  // the conditions of the breakpoints at site, in order (null: none)
  lock_st()
  var nc: i64 = 0
  let conds: raw.Ptr<raw.Ptr<u8>> = raw.cast(raw.alloc(usize(st_nbps + 1) * raw.size_of<raw.Ptr<u8>>()))
  var i: i64 = 0
  while i < st_nbps {
    let b = st_bps.offset(i)
    var j: i64 = 0
    while j < b.nsites {
      if b.sites.at(j) == u32(site) {
        conds.at(nc) = if b.cond.is_null() { raw.null() } else { dbg_text.dup_s(b.cond) }
        nc += 1
        break
      }
      j += 1
    }
    i += 1
  }
  unlock_st()
  var hit = false
  i = 0
  while i < nc && !hit {
    let cond = conds.at(i)
    if cond.is_null() {
      hit = true
      break
    }
    let was = str.auk__dbg_set_busy(true)
    var v: raw.Ptr<u8> = raw.null()
    var ty: raw.Ptr<u8> = raw.null()
    var err: raw.Ptr<u8> = raw.null()
    let ok = dbg_expr.eval_at(f, cond, raw.addr_of(&v), raw.addr_of(&ty), raw.addr_of(&err))
    let _ = str.auk__dbg_set_busy(was)
    if ok && dbg_text.eq(v, "true") {
      hit = true
    } else if !ok {
      var m = dbg_text.Text {}
      dbg_text.put(raw.addr_of(&m), cond)
      dbg_text.put(raw.addr_of(&m), ": ")
      dbg_text.put(raw.addr_of(&m), err)
      var o = dbg_text.Text {}
      dbg_text.put(raw.addr_of(&o), ",\"cond_error\":")
      dbg_text.jsonc(raw.addr_of(&o), m.p)
      raw.free(m.p)
      extra.store(o.p)
      hit = true
    }
    raw.free(v)
    raw.free(ty)
    raw.free(err)
    i += 1
  }
  i = 0
  while i < nc {
    raw.free(conds.at(i))
    i += 1
  }
  raw.free(conds)
  hit
}

/// A statement of an instrumented function, while armed: stop here?
export fn auk_dbg_hook(f: raw.Ptr<abi.DbgFrame>) uses raw, ffi {
  if !is_attached() || str.auk__dbg_busy() || dbg_info.info.is_null() {
    return
  }
  let site = f.site
  let me = tid()
  lock_st()
  // another thread has stopped: wait until it resumes
  wait_not_stopped()
  var extra: raw.Ptr<u8> = raw.null()
  var reason: raw.Ptr<u8> = raw.null()
  if st_pause_req {
    st_pause_req = false
    reason = "pause"
  } else if site >= 0 && site < dbg_info.info.nsites && raw.atomic_load(bp_at(site), raw.Order.Relaxed) > 0 {
    unlock_st()
    let hit = bp_hit(f, site, raw.addr_of(&extra))
    lock_st()
    wait_not_stopped()
    // the breakpoint may have been deleted while another thread was stopped (the condition ran
    // without the lock, and the wait above may have spanned a stop)
    if hit && raw.atomic_load(bp_at(site), raw.Order.Relaxed) > 0 {
      reason = "breakpoint"
    } else if step_done(site) {
      reason = "step"
      raw.free(extra)
      extra = raw.null()
    } else {
      unlock_st()
      raw.free(extra)
      return
    }
  } else if step_done(site) {
    reason = "step"
  } else {
    unlock_st()
    return
  }
  stop(me, reason, extra)
  raw.free(extra)
}

/// A panic on this thread (rc.auk): stop first, if the debugger wants panics. caught: it will
/// jump to a recovery point (`catch`, a task's own).
pub export fn auk__dbg_on_panic(loc: raw.Ptr<u8>, msg: raw.Ptr<u8>, n: usize, caught: bool) uses raw, ffi {
  if !is_attached() || str.auk__dbg_busy() || dbg_info.info.is_null() {
    return
  }
  let me = tid()
  lock_st()
  let want = st_catch_mode == CATCH_ALL || (st_catch_mode == CATCH_UNCAUGHT && !caught)
  if !want || !st_running {
    unlock_st()
    return
  }
  wait_not_stopped()
  var extra = dbg_text.Text {}
  let xp = raw.addr_of(&extra)
  dbg_text.put(xp, ",\"msg\":")
  dbg_text.json(xp, msg, n)
  dbg_text.put(xp, ",\"loc\":")
  dbg_text.jsonc(xp, loc)
  if caught {
    dbg_text.put(xp, ",\"caught\":true")
  }
  stop(me, "panic", extra.p)
  raw.free(extra.p)
}

/// The debugger stack of a recovery point (`catch`, a task), restored when a panic jumps back
/// past frames that never got to leave.
pub export fn auk__dbg_save(top: raw.Ptr<raw.Ptr<()>>, depth: raw.Ptr<i64>) uses raw {
  let t = raw.addr_of(&cur)
  top.store(raw.cast(t.top))
  depth.store(t.depth)
}

pub export fn auk__dbg_restore(top: raw.Ptr<()>, depth: i64) uses raw, ffi {
  let t = raw.addr_of(&cur)
  frame_op_begin(t)
  t.top = raw.cast(top)
  frame_op_end(t)
  t.depth = depth
}

// ---- breakpoints and the reader ---------------------------------------------------------------

/// `break <spec> [if <condition>]` (st_lock held).
fn cmd_break(c: raw.Ptr<Cmd>) uses raw, ffi {
  let rest = dbg_text.after_words(c.text, 1)
  let at = strstr(rest, " if ")
  var spec: raw.Ptr<u8> = raw.null()
  var cond: raw.Ptr<u8> = raw.null()
  if !at.is_null() {
    let sp = dbg_text.dup_n(rest, usize(at.int() - rest.int()))
    spec = dbg_text.trimmed(sp)
    raw.free(sp)
    cond = dbg_text.trimmed(at.offset(4))
    if cond.load() == 0 {
      raw.free(cond)
      cond = raw.null()
    }
  } else {
    spec = dbg_text.trimmed(rest)
  }
  var n: i64 = 0
  var file: raw.Ptr<u8> = raw.null()
  var line: u32 = 0
  var err: raw.Ptr<u8> = raw.null()
  let sites = dbg_info.resolve(spec, raw.addr_of(&n), raw.addr_of(&file), raw.addr_of(&line), raw.addr_of(&err))
  raw.free(spec)
  if sites.is_null() {
    unlock_st()
    reply_error(c, err)
    raw.free(err)
    raw.free(cond)
    lock_st()
    return
  }
  var i: i64 = 0
  while i < n {
    let _ = raw.atomic_add(bp_at(i64(sites.at(i))), 1, raw.Order.SeqCst)
    i += 1
  }
  let id = st_next_bp
  st_next_bp += 1
  if st_nbps == st_capbps {
    st_capbps = if st_capbps == 0 { 8 } else { st_capbps * 2 }
    st_bps = raw.cast(raw.realloc(st_bps, usize(st_capbps) * raw.size_of<Bp>()))
  }
  let b = st_bps.offset(st_nbps)
  b.id = id
  b.sites = sites
  b.nsites = n
  b.cond = cond
  st_nbps += 1
  rearm()
  var r = dbg_text.Text {}
  let rp = raw.addr_of(&r)
  dbg_text.put(rp, ",\"id\":")
  dbg_text.put_int(rp, id)
  dbg_text.put(rp, ",\"file\":")
  dbg_text.jsonc(rp, file)
  dbg_text.put(rp, ",\"line\":")
  dbg_text.put_int(rp, i64(line))
  if !cond.is_null() {
    dbg_text.put(rp, ",\"cond\":")
    dbg_text.jsonc(rp, cond)
  }
  unlock_st()
  reply(c, "break", r.p)
  lock_st()
  raw.free(r.p)
}

/// `delete [id]` (st_lock held).
fn cmd_delete(id: i64, all: bool) uses raw {
  var k: i64 = 0
  var i: i64 = 0
  while i < st_nbps {
    let b = st_bps.offset(i)
    if all || b.id == id {
      var j: i64 = 0
      while j < b.nsites {
        let _ = raw.atomic_sub(bp_at(i64(b.sites.at(j))), 1, raw.Order.SeqCst)
        j += 1
      }
      raw.free(b.sites)
      raw.free(b.cond)
    } else {
      st_bps.at(k) = b.load()
      k += 1
    }
    i += 1
  }
  st_nbps = k
  rearm()
}

fn queue_push(c: Cmd) uses raw, ffi {
  if st_qlen == st_qcap {
    let cap: i64 = if st_qcap == 0 { 8 } else { st_qcap * 2 }
    let q: raw.Ptr<Cmd> = raw.cast(raw.alloc(usize(cap) * raw.size_of<Cmd>()))
    var i: i64 = 0
    while i < st_qlen {
      q.at(i) = st_queue.at((st_qhead + i) % st_qcap)
      i += 1
    }
    raw.free(st_queue)
    st_queue = q
    st_qcap = cap
    st_qhead = 0
  }
  st_queue.at((st_qhead + st_qlen) % st_qcap) = c
  st_qlen += 1
}

/// One line from the connection: commands that don't need a stopped thread run here; the
/// others go to the focus thread's queue.
fn handle_line(line: raw.Ptr<u8>) uses raw, ffi {
  var text = dbg_text.trimmed(line)
  var c = Cmd { has_seq: false, seq: 0, text: raw.null() }
  let cp = raw.addr_of(&c)
  if text.load() == 0x40 {
    var e = text.offset(1)
    while e.load() != 0 && !dbg_text.is_space(e.load()) {
      e = e.offset(1)
    }
    let num = dbg_text.dup_n(text.offset(1), usize(e.int() - text.int() - 1))
    var v: i64 = 0
    if dbg_text.parse_i64(num, raw.addr_of(&v)) {
      c.has_seq = true
      c.seq = v
      let rest = dbg_text.dup_s(dbg_text.after_words(text, 1))
      raw.free(text)
      text = rest
    }
    raw.free(num)
  }
  var nw: i64 = 0
  let w = dbg_text.split_words(text, raw.addr_of(&nw))
  if nw == 0 {
    dbg_text.free_words(w, nw)
    raw.free(text)
    return
  }
  c.text = text
  let c0 = w.at(0)
  lock_st()
  if named(c0, "run") {
    st_running = true
    rearm()
    wake_st()
    unlock_st()
    reply(cp, "ok", "")
  } else if named(c0, "break") || named(c0, "b") {
    cmd_break(cp)
    unlock_st()
  } else if named(c0, "delete") || named(c0, "d") {
    var id: i64 = 0
    let one = nw > 1 && dbg_text.parse_i64(w.at(1), raw.addr_of(&id))
    cmd_delete(id, !one)
    unlock_st()
    reply(cp, "ok", "")
  } else if named(c0, "catch") {
    let m: raw.Ptr<u8> = if nw > 1 { w.at(1) } else { "" }
    st_catch_mode = if named(m, "all") { CATCH_ALL } else if named(m, "none") { CATCH_NONE } else { CATCH_UNCAUGHT }
    unlock_st()
    reply(cp, "ok", "")
  } else if named(c0, "pause") {
    if !st_stopped {
      st_pause_req = true
      rearm()
    } else if st_qlen > 0 || st_serving {
      st_pause_after = st_qlen + (if st_serving { 1 } else { 0 })
    }
    unlock_st()
    reply(cp, "ok", "")
  } else if named(c0, "kill") {
    unlock_st()
    reply(cp, "ok", "")
    let _ = c_fflush(cfacts.stdout())
    c_exit(137)
  } else if st_stopped {
    queue_push(c)
    c.text = raw.null() // the queue owns it
    wake_st()
    unlock_st()
  } else {
    unlock_st()
    reply(cp, "error", ",\"msg\":\"the program is running\"")
  }
  dbg_text.free_words(w, nw)
  raw.free(c.text)
}

/// The connection's reader thread (arg: the socket).
fn reader(arg: raw.Ptr<()>): raw.Ptr<()> uses raw, ffi {
  let fd = i32(arg.int())
  var line = dbg_text.Text {}
  let lp = raw.addr_of(&line)
  var buf: [u8; 4096]
  let bp = raw.cast<u8>(raw.addr_of(&buf))
  loop {
    let r = c_read(fd, raw.cast(bp), 4096)
    if r < 0 && cfacts.errno() == cfacts.EINTR {
      continue
    }
    if r <= 0 {
      break
    }
    var i: i64 = 0
    while i < r {
      if bp.at(i) == 0x0A {
        if line.n > 0 && line.p.at(line.n - 1) == 0x0D {
          line.n -= 1
          line.p.at(line.n) = 0
        }
        let l: raw.Ptr<u8> = if line.n == 0 { "" } else { line.p }
        handle_line(l)
        line.n = 0
      } else {
        dbg_text.add(lp, bp.offset(i), 1)
      }
      i += 1
    }
  }
  if line.n > 0 {
    handle_line(line.p)
  }
  raw.free(line.p)
  // the front end went away: let the program run on
  raw.atomic_store(raw.addr_of(&attached), 0, raw.Order.SeqCst)
  lock_st()
  st_running = true
  st_stopped = false
  halt(false)
  st_pause_req = false
  st_pause_after = 0
  st_stepping = false
  st_epoch += 1
  raw.atomic_store(raw.addr_of(&auk_dbg_armed), 0, raw.Order.SeqCst)
  wake_st()
  unlock_st()
  raw.null()
}

fn at_exit() uses raw, ffi {
  if is_attached() {
    emit("{{\"ev\":\"exited\"}}")
  }
}

// ---- starting -----------------------------------------------------------------------------------

/// "auk: debugger at <path>: <reason>" on stderr.
fn debugger_at_failed(path: raw.Ptr<u8>, e: i32) uses raw, ffi {
  var m = dbg_text.Text {}
  let mp = raw.addr_of(&m)
  dbg_text.put(mp, "auk: debugger at ")
  dbg_text.put(mp, path)
  dbg_text.put(mp, ": ")
  dbg_text.put(mp, strerror(e))
  dbg_text.put(mp, "\n")
  // in one piece, as one fprintf would
  let _ = c_fwrite(m.p, 1, m.n, cfacts.stderr())
  raw.free(m.p)
}

/// Start the debugger (generated main, before anything else runs): attach to the front end named
/// by AUK_DEBUG and wait for `run`. kids: the children function of each type.
export fn auk_dbg_init(text: raw.Ptr<u8>, shows: raw.Ptr<dbg_info.ShowFn>, kids: raw.Ptr<()>) uses raw, ffi {
  let path = getenv("AUK_DEBUG")
  if path.is_null() {
    return
  }
  let fd = socket(cfacts.AF_UNIX, cfacts.SOCK_STREAM, 0)
  var addr = cfacts.SockaddrUn {}
  let ap = raw.addr_of(&addr)
  gui_os.sun_set_family(ap)
  let room = raw.size_of<cfacts.SockaddrUn>() - raw.offset_of<cfacts.SockaddrUn>(.sun_path)
  if c_strlen(path) >= room {
    debugger_at_failed(path, cfacts.ENAMETOOLONG)
    if fd >= 0 {
      let _ = close(fd)
    }
    return
  }
  raw.copy(raw.cast<u8>(raw.field_addr(ap, .sun_path)), path, c_strlen(path) + 1)
  if fd < 0 || connect(fd, raw.cast(ap), u32(raw.size_of<cfacts.SockaddrUn>())) != 0 {
    let e = cfacts.errno()
    debugger_at_failed(path, e)
    if fd >= 0 {
      let _ = close(fd)
    }
    return
  }
  gui.auk__wire_no_sigpipe(fd)
  // under a debugger, output shows up as it is written (it goes to a pipe)
  let _ = setvbuf(cfacts.stdout(), raw.null(), IOLBF, 0)
  dbg_info.info = dbg_info.parse(text, shows, raw.cast(kids))
  let rd = dup(fd)
  if rd < 0 {
    let _ = close(fd)
    return
  }
  lock(raw.addr_of(&out_lock))
  out_fd = fd
  unlock(raw.addr_of(&out_lock))
  raw.atomic_store(raw.addr_of(&attached), 1, raw.Order.SeqCst)
  let _ = atexit(raw.fn_of(at_exit))
  let _ = tid()
  lock_st()
  rearm()
  unlock_st()
  var th = cfacts.PthreadT {}
  var attr = cfacts.PthreadAttr {}
  let _ = pthread_attr_init(raw.addr_of(&attr))
  let _ = pthread_attr_setdetachstate(raw.addr_of(&attr), cfacts.PTHREAD_CREATE_DETACHED)
  let _ = pthread_create(raw.addr_of(&th), raw.addr_of(&attr), raw.fn_of(reader), raw.from_int(i64(rd)))
  let _ = pthread_attr_destroy(raw.addr_of(&attr))
  var ready = dbg_text.Text {}
  let rp = raw.addr_of(&ready)
  dbg_text.put(rp, "{{\"ev\":\"ready\",\"pid\":")
  dbg_text.put_int(rp, i64(getpid()))
  dbg_text.put(rp, "}}")
  emit(ready.p)
  raw.free(ready.p)
  lock_st()
  while !st_running {
    wait_st()
  }
  unlock_st()
}

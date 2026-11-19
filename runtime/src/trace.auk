/// Execution traces (`auk run --trace`, `auk test --trace`): a JSON Lines log of every traced
/// function call and return, error, `peek` and panic (was runtime/c/trace.c, ported line by
/// line).
///
/// Only programs compiled with tracing call into this module (the compiler wraps each traced
/// function in an auk_trace_begin/auk_trace_call/auk_trace_exit/auk_trace_ret shim and makes main
/// call auk_trace_init); every other program only pays for the auk_trace_live test in auk_peek
/// and the panic path.
///
/// Configuration (environment, read by auk_trace_init):
///   AUK_TRACE=<file> | -    run: the event stream's file, `-` = stderr.
///                           test: a directory (one `<test name>.jsonl` per test), or `-`: each
///                           test keeps its last AUK_TRACE_TAIL events in memory and the runner
///                           prints them under the test's FAIL line.
///   AUK_TRACE_LIMIT=<n>     events written before a final {"ev":"truncated"} (default 10000).
///   AUK_TRACE_TAIL=<n>      events kept for a failing test in `-` mode (default 20).
///
/// Output is buffered here (not in a FILE) so a crash handler can still write it out with
/// write(2): a SIGSEGV from a stack overflow ends the trace with {"ev":"signal"}. The
/// process-wide state is guarded by trace_lock; the signal handler reads it without locking,
/// best effort.
///
/// Each `export fn` another module of the package uses is `pub` too, and called as
/// `trace.name(…)`.

// the rest of the runtime (C)
extern fn c_open(path: raw.Ptr<u8>, flags: i32, ...): i32 = "int open(const char *, int, ...)"
// libc
extern fn c_strlen(s: raw.Ptr<u8>): usize = "size_t strlen(const char *)"
extern fn c_memchr(p: raw.Ptr<u8>, c: i32, n: usize): raw.Ptr<u8> = "void *memchr(const void *, int, size_t)"
extern fn c_write(fd: i32, p: raw.Ptr<()>, n: usize): i64 = "ssize_t write(int, const void *, size_t)"
extern fn c_close(fd: i32): i32 = "int close(int)"
extern fn c_getenv(name: raw.Ptr<u8>): raw.Ptr<u8> = "char *getenv(const char *)"
extern fn c_strtoll(s: raw.Ptr<u8>, end: raw.Ptr<raw.Ptr<u8>>, base: i32): i64 = "long long strtoll(const char *, char **, int)"
extern fn c_strerror(e: i32): raw.Ptr<u8> = "char *strerror(int)"
extern fn c_mkdir(path: raw.Ptr<u8>, mode: u32): i32 = "int mkdir(const char *, uint32_t)"
extern fn c_atexit(f: raw.Fn<() => ()>): i32 = "int atexit(void (*)(void))"
extern fn c_malloc(n: usize): raw.Ptr<()> = "void *malloc(size_t)"
extern fn c_signal(sig: i32, handler: raw.Ptr<()>): raw.Ptr<()> = "void *signal(int, void *)"
extern fn c_raise(sig: i32): i32 = "int raise(int)"
extern fn c_sigaction(sig: i32, act: raw.Ptr<cfacts.Sigaction>, old: raw.Ptr<cfacts.Sigaction>): i32 =
  "int sigaction(int, const struct sigaction *, struct sigaction *)"
extern fn c_sigemptyset(set: raw.Ptr<cfacts.SigSet>): i32 = "int sigemptyset(sigset_t *)"
extern fn c_sigaltstack(ss: raw.Ptr<cfacts.StackT>, old: raw.Ptr<cfacts.StackT>): i32 = "int sigaltstack(const stack_t *, stack_t *)"
extern fn pthread_mutex_lock(m: raw.Ptr<cfacts.PthreadMutex>): i32 = "int pthread_mutex_lock(pthread_mutex_t *)"
extern fn pthread_mutex_unlock(m: raw.Ptr<cfacts.PthreadMutex>): i32 = "int pthread_mutex_unlock(pthread_mutex_t *)"

/// Is tracing on? Read by generated code and by auk_peek and the panic path (C: `_Atomic bool`).
pub export var auk_trace_live: bool = false

/// The call site of the next traced call: generated code stores it through
/// auk__trace_site_slot.
raw thread var trace_site: raw.Ptr<u8> = raw.null()
raw thread var trace_depth: i64 = 0
/// > 0 while the tracer itself runs Auk code (a user `show`): nothing is traced
raw thread var trace_mute: i32 = 0
/// the call site of the call being traced (taken from trace_site by auk_trace_begin)
raw thread var trace_call_site: raw.Ptr<u8> = raw.null()

/// The show budget of one traced value: enough for its first VALUE_MAX chars.
raw let SHOW_BUDGET: i64 = 256
raw let VALUE_MAX: usize = 200

raw let T_OFF: i32 = 0
raw let T_STREAM: i32 = 1
raw let T_TAIL: i32 = 2

raw var trace_mode: i32 = 0
raw var trace_configured: bool = false
raw var trace_test_binary: bool = false
raw var trace_cfg: raw.Ptr<u8> = raw.null()
raw var trace_limit: i64 = 10000
raw var tail_n: i64 = 20
raw var trace_count: i64 = 0
raw var trace_lock: cfacts.PthreadMutex = cfacts.PTHREAD_MUTEX_INITIALIZER

// T_STREAM: buffered output to out_fd
raw var out_fd: i32 = -1
raw var out_unbuffered: bool = false
raw let OBUF_SIZE: usize = 65536 // 1 << 16
raw struct OBuf { b: [u8; 65536] }
raw var obuf: OBuf = OBuf {}
raw var olen: usize = 0

// T_TAIL: a ring of the last tail_n events, dumped to out_fd on exit
raw var ring: raw.Ptr<raw.Ptr<u8>> = raw.null()
raw var ring_len: raw.Ptr<usize> = raw.null()
raw var ring_cap: raw.Ptr<usize> = raw.null()

// C's function-local statics
raw var handlers_done: bool = false
raw var exit_registered: bool = false

export fn auk__trace_site_slot(): raw.Ptr<raw.Ptr<u8>> uses raw = raw.addr_of(&trace_site)

fn trace_on(): bool uses raw = raw.atomic_load(raw.addr_of(&auk_trace_live), raw.Order.Relaxed)

fn set_live(b: bool) uses raw {
  raw.atomic_store(raw.addr_of(&auk_trace_live), b, raw.Order.Relaxed)
}

// ---- line building ---------------------------------------------------------------------------

raw struct Line {
  p: raw.Ptr<u8>,
  n: usize,
  cap: usize,
}

/// Each thread's event buffer: taken by new_line, given back by emit.
raw thread var scratch: Line = Line {}

fn new_line(): Line uses raw {
  var l = scratch
  scratch.p = raw.null()
  scratch.cap = 0
  l.n = 0
  l
}

/// Room for `need` bytes. Out of line, so that put (and puts_, with a literal's length known)
/// stays small enough to inline: C's static functions were.
fn grow(l: raw.Ptr<Line>, need: usize) uses raw, ffi {
  var cap: usize = if l.cap == 0 { 256 } else { l.cap * 2 }
  while cap < need {
    cap *= 2
  }
  l.p = raw.cast(rc.auk__xrealloc(raw.cast(l.p), cap))
  l.cap = cap
}

fn put(l: raw.Ptr<Line>, s: raw.Ptr<u8>, n: usize) uses raw, ffi {
  if l.n + n > l.cap {
    grow(l, l.n + n)
  }
  raw.copy(l.p.offset(l.n), s, n)
  l.n += n
}

fn puts_(l: raw.Ptr<Line>, s: raw.Ptr<u8>) uses raw, ffi {
  put(l, s, c_strlen(s))
}

fn put_byte(l: raw.Ptr<Line>, c: u8) uses raw, ffi {
  var b = c
  put(l, raw.addr_of(&b), 1)
}

/// Decimal text of v into b (24 bytes; no allocation: used by the signal handler); returns
/// where it starts, *n its length.
fn fmt_i64(b: raw.Ptr<u8>, v: i64, n: raw.Ptr<usize>): raw.Ptr<u8> uses raw {
  var i: i64 = 24
  var u: u64 = if v < 0 { u64(0) - u64(v) } else { u64(v) }
  i -= 1
  b.at(i) = u8(48 + u % 10) // '0'
  u /= 10
  while u != 0 {
    i -= 1
    b.at(i) = u8(48 + u % 10)
    u /= 10
  }
  if v < 0 {
    i -= 1
    b.at(i) = 45 // '-'
  }
  n.store(usize(24 - i))
  b.offset(i)
}

fn put_int(l: raw.Ptr<Line>, v: i64) uses raw, ffi {
  var b: [u8; 24]
  var n: usize
  let s = fmt_i64(raw.cast<u8>(raw.addr_of(&b)), v, raw.addr_of(&n))
  put(l, s, n)
}

/// A JSON string of s[0..n) (UTF-8), cut after max chars (0: no limit) with `...` (or always,
/// with cut).
fn put_json(l: raw.Ptr<Line>, s: raw.Ptr<u8>, n: usize, max: usize, cut0: bool) uses raw, ffi {
  let hex: raw.Ptr<u8> = "0123456789abcdef"
  var cut = cut0
  put(l, "\"", 1)
  var chars: usize = 0
  var i: usize = 0
  while i < n {
    let c = s.at(i)
    if (c & 0xC0) != 0x80 {
      if max != 0 && chars == max {
        cut = true
        break
      }
      chars += 1
    }
    if c == 34 { // '"'
      put(l, "\\\"", 2)
    } else if c == 92 { // '\\'
      put(l, "\\\\", 2)
    } else if c == 10 {
      put(l, "\\n", 2)
    } else if c == 13 {
      put(l, "\\r", 2)
    } else if c == 9 {
      put(l, "\\t", 2)
    } else if c < 0x20 || c == 0x7f {
      put(l, "\\u00", 4)
      put_byte(l, hex.at(c >> 4))
      put_byte(l, hex.at(c & 15))
    } else {
      put(l, s.offset(i), 1)
    }
    i += 1
  }
  if cut {
    put(l, "...", 3)
  }
  put(l, "\"", 1)
}

/// A JSON string of a C string (NULL: "").
fn put_cjson(l: raw.Ptr<Line>, s: raw.Ptr<u8>) uses raw, ffi {
  if s.is_null() {
    put_json(l, "", 0, 0, false)
  } else {
    put_json(l, s, c_strlen(s), 0, false)
  }
}

fn put_value(l: raw.Ptr<Line>, s: raw.Ptr<abi.Str>) uses raw, ffi {
  let n = str.auk_str_byte_len(s)
  // a show that used up its budget was cut short even if it is under VALUE_MAX chars
  put_json(l, str.auk_str_cstr(s), usize(n), VALUE_MAX, n >= SHOW_BUDGET)
}

// ---- output ----------------------------------------------------------------------------------

fn write_all(fd: i32, p: raw.Ptr<u8>, n0: usize) uses raw, ffi {
  var b = p
  var n = n0
  while n > 0 {
    let w = c_write(fd, raw.cast(b), n)
    if w < 0 && cfacts.errno() == cfacts.EINTR {
      continue
    }
    if w <= 0 {
      return
    }
    b = b.offset(w)
    n -= usize(w)
  }
}

fn write_str(fd: i32, s: raw.Ptr<u8>) uses raw, ffi {
  write_all(fd, s, c_strlen(s))
}

fn obuf_ptr(): raw.Ptr<u8> uses raw = raw.cast(raw.addr_of(&obuf))

fn out_flush_locked() uses raw, ffi {
  if out_fd >= 0 && olen != 0 {
    write_all(out_fd, obuf_ptr(), olen)
  }
  olen = 0
}

fn out_bytes_locked(p: raw.Ptr<u8>, n: usize) uses raw, ffi {
  if olen + n > OBUF_SIZE {
    out_flush_locked()
  }
  if n > OBUF_SIZE {
    write_all(out_fd, p, n)
    return
  }
  raw.copy(obuf_ptr().offset(olen), p, n)
  olen += n
}

/// Record one event line (without its newline); last: the final event (a panic), recorded even
/// past the limit.
fn emit_ev(l0: Line, last: bool) uses raw, ffi {
  var l = l0
  let lp = raw.addr_of(&l)
  put(lp, "\n", 1)
  pthread_mutex_lock(raw.addr_of(&trace_lock))
  if trace_mode == T_STREAM && last {
    out_bytes_locked(l.p, l.n)
  } else if trace_mode == T_STREAM && trace_on() {
    out_bytes_locked(l.p, l.n)
    trace_count += 1
    if trace_count >= trace_limit {
      var t = Line {}
      let tp = raw.addr_of(&t)
      put(tp, "{{\"ev\":\"truncated\",\"limit\":", 26)
      put_int(tp, trace_limit)
      put(tp, "}}\n", 2)
      out_bytes_locked(t.p, t.n)
      raw.free(t.p)
      set_live(false)
    }
    if out_unbuffered {
      out_flush_locked()
    }
  } else if trace_mode == T_TAIL {
    let k = trace_count % tail_n
    if ring_cap.at(k) < l.n {
      ring.at(k) = raw.cast(rc.auk__xrealloc(raw.cast(ring.at(k)), l.n))
      ring_cap.at(k) = l.n
    }
    raw.copy(ring.at(k), l.p, l.n)
    ring_len.at(k) = l.n
    trace_count += 1
  }
  pthread_mutex_unlock(raw.addr_of(&trace_lock))
  // the line's buffer is reused by this thread's next event
  if scratch.p.is_null() {
    scratch = l
  } else {
    raw.free(l.p)
  }
}

fn emit(l: Line) uses raw, ffi {
  emit_ev(l, false)
}

fn head(l: raw.Ptr<Line>, ev: raw.Ptr<u8>) uses raw, ffi {
  put(l, "{{\"ev\":\"", 7)
  puts_(l, ev)
  put(l, "\"", 1)
}

fn field(l: raw.Ptr<Line>, name: raw.Ptr<u8>) uses raw, ffi {
  put(l, ",\"", 2)
  puts_(l, name)
  put(l, "\":", 2)
}

fn end_depth(l: raw.Ptr<Line>, d: i64) uses raw, ffi {
  field(l, "depth")
  put_int(l, d)
  put(l, "}}", 1)
}

/// Write everything recorded so far (T_TAIL: the ring, oldest first). Async-signal-safe enough
/// for the crash handler: it only uses write(2) on memory that already exists.
fn dump_locked() uses raw, ffi {
  if trace_mode == T_STREAM {
    out_flush_locked()
  } else if trace_mode == T_TAIL && out_fd >= 0 {
    let n = if trace_count < tail_n { trace_count } else { tail_n }
    if trace_count > n {
      var b: [u8; 24]
      var k: usize
      let s = fmt_i64(raw.cast<u8>(raw.addr_of(&b)), trace_count - n, raw.addr_of(&k))
      write_str(out_fd, "{{\"ev\":\"truncated\",\"skipped\":")
      write_all(out_fd, s, k)
      write_str(out_fd, "}}\n")
    }
    var i = trace_count - n
    while i < trace_count {
      let k = i % tail_n
      if !ring.at(k).is_null() {
        write_all(out_fd, ring.at(k), ring_len.at(k))
      }
      i += 1
    }
    trace_count = 0
  }
}

// ---- crash handler ---------------------------------------------------------------------------

/// A stack overflow (stack.auk's signal handler, which then exits): the trace so far, then the
/// panic. No lock and no allocation, like on_signal.
pub export fn auk__trace_on_overflow(fname: raw.Ptr<u8>) uses raw, ffi {
  if trace_mode == T_OFF {
    return
  }
  dump_locked()
  if out_fd >= 0 {
    write_str(out_fd, "{{\"ev\":\"panic\",\"msg\":\"stack overflow\",\"loc\":\"")
    write_str(out_fd, fname)
    write_str(out_fd, "\"}}\n")
  }
}

/// The handler of fatal signals (sigaction's sa_handler).
fn on_signal(sig: i32) uses raw, ffi {
  // no lock: the crashing thread may hold it; this is best effort
  dump_locked()
  if out_fd >= 0 {
    var b: [u8; 24]
    var k: usize
    let s = fmt_i64(raw.cast<u8>(raw.addr_of(&b)), i64(sig), raw.addr_of(&k))
    write_str(out_fd, "{{\"ev\":\"signal\",\"signal\":")
    write_all(out_fd, s, k)
    write_str(out_fd, "}}\n")
  }
  let _ = c_signal(sig, raw.from_int(cfacts.SIG_DFL))
  let _ = c_raise(sig)
}

fn install_handlers() uses raw, ffi {
  if handlers_done {
    return
  }
  handlers_done = true
  var ss = cfacts.StackT {}
  ss.ss_size = 65536 // 1 << 16
  ss.ss_sp = c_malloc(usize(ss.ss_size))
  if !ss.ss_sp.is_null() {
    c_sigaltstack(raw.addr_of(&ss), raw.null())
  }
  var sa = cfacts.Sigaction {}
  sa.sa_handler = raw.cast(raw.fn_of(on_signal))
  sa.sa_flags = cfacts.SA_ONSTACK | cfacts.SA_RESETHAND
  c_sigemptyset(raw.field_addr(raw.addr_of(&sa), .sa_mask))
  let sap = raw.addr_of(&sa)
  c_sigaction(cfacts.SIGSEGV, sap, raw.null())
  c_sigaction(cfacts.SIGBUS, sap, raw.null())
  c_sigaction(cfacts.SIGFPE, sap, raw.null())
  c_sigaction(cfacts.SIGILL, sap, raw.null())
  c_sigaction(cfacts.SIGABRT, sap, raw.null())
  // a stack overflow is still a panic (which ends the trace), other faults come here
  stack.auk__stack_handlers_first()
}

// ---- configuration ---------------------------------------------------------------------------

fn env_int(name: raw.Ptr<u8>, dflt: i64): i64 uses raw, ffi {
  let v = c_getenv(name)
  if v.is_null() || v.at(0) == 0 {
    return dflt
  }
  var end: raw.Ptr<u8> = raw.null()
  let n = c_strtoll(v, raw.addr_of(&end), 10)
  if end.at(0) != 0 || n <= 0 { dflt } else { n }
}

fn flush_at_exit() uses raw, ffi {
  auk__trace_flush()
}

fn start_stream(fd: i32, unbuffered: bool) uses raw, ffi {
  if !exit_registered {
    let _ = c_atexit(raw.fn_of(flush_at_exit))
  }
  exit_registered = true
  out_fd = fd
  out_unbuffered = unbuffered
  trace_mode = T_STREAM
  trace_count = 0
  set_live(true)
  install_handlers()
}

fn cannot_write(path: raw.Ptr<u8>) uses raw, ffi {
  let e = cfacts.errno()
  var m = abi.StrBuf {}
  let mp = raw.addr_of(&m)
  str.auk__sb_put_cstr(mp, "auk: cannot write the trace to ")
  str.auk__sb_put_cstr(mp, path)
  str.auk__sb_put_cstr(mp, ": ")
  str.auk__sb_put_cstr(mp, c_strerror(e))
  str.auk__sb_put_cstr(mp, "\n")
  str_fmt.auk__sb_eprint(mp)
}

/// s is "-".
fn is_dash(s: raw.Ptr<u8>): bool uses raw = s.at(0) == 45 && s.at(1) == 0

export fn auk_trace_init(tests: bool) uses raw, ffi {
  trace_configured = true
  trace_test_binary = tests
  trace_cfg = c_getenv("AUK_TRACE")
  if !trace_cfg.is_null() && trace_cfg.at(0) == 0 {
    trace_cfg = raw.null()
  }
  trace_limit = env_int("AUK_TRACE_LIMIT", 10000)
  tail_n = env_int("AUK_TRACE_TAIL", 20)
  if tests || trace_cfg.is_null() {
    return
  }
  if is_dash(trace_cfg) {
    start_stream(2, true)
    return
  }
  let fd = c_open(trace_cfg, cfacts.O_WRONLY | cfacts.O_CREAT | cfacts.O_TRUNC | cfacts.O_CLOEXEC, i32(420)) // 0644
  if fd < 0 {
    cannot_write(trace_cfg)
    return
  }
  start_stream(fd, false)
}

pub export fn auk__trace_tail_mode(): bool uses raw =
  trace_configured && trace_test_binary && !trace_cfg.is_null() && is_dash(trace_cfg)

pub export fn auk__trace_dir(): raw.Ptr<u8> uses raw {
  if trace_configured && trace_test_binary && !trace_cfg.is_null() && !is_dash(trace_cfg) {
    return trace_cfg
  }
  raw.null()
}

/// The trace file of a test in directory mode: <dir>/<name with [^A-Za-z0-9_-] as _>.jsonl
/// (malloc'd).
fn test_file(dir: raw.Ptr<u8>, name: raw.Ptr<u8>): raw.Ptr<u8> uses raw, ffi {
  let nd = c_strlen(dir)
  let nn = c_strlen(name)
  let p: raw.Ptr<u8> = raw.cast(rc.auk__xmalloc(nd + nn + 8))
  raw.copy(p, dir, nd)
  p.at(nd) = 47 // '/'
  var i: usize = 0
  while i < nn {
    let c = name.at(i)
    let keep = (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) || c == 45 || c == 95
    p.at(nd + 1 + i) = if keep { c } else { 95 }
    i += 1
  }
  let ext: raw.Ptr<u8> = ".jsonl"
  raw.copy(p.offset(nd + 1 + nn), ext, 7)
  p
}

pub export fn auk__trace_test_begin(name: raw.Ptr<u8>, tail_path: raw.Ptr<u8>) uses raw, ffi {
  if !trace_configured || !trace_test_binary || trace_cfg.is_null() {
    return
  }
  if !tail_path.is_null() {
    let fd = c_open(tail_path, cfacts.O_WRONLY | cfacts.O_CREAT | cfacts.O_TRUNC | cfacts.O_CLOEXEC, i32(384)) // 0600
    if fd < 0 {
      return
    }
    out_fd = fd
    ring = raw.cast(rc.auk__xcalloc(usize(tail_n), raw.size_of<raw.Ptr<u8>>()))
    ring_len = raw.cast(rc.auk__xcalloc(usize(tail_n), raw.size_of<usize>()))
    ring_cap = raw.cast(rc.auk__xcalloc(usize(tail_n), raw.size_of<usize>()))
    trace_mode = T_TAIL
    trace_count = 0
    set_live(true)
    install_handlers()
    return
  }
  let _ = c_mkdir(trace_cfg, 493) // 0755
  let path = test_file(trace_cfg, name)
  let fd = c_open(path, cfacts.O_WRONLY | cfacts.O_CREAT | cfacts.O_TRUNC | cfacts.O_CLOEXEC, i32(420))
  if fd < 0 {
    cannot_write(path)
  }
  raw.free(path)
  if fd >= 0 {
    start_stream(fd, false)
  }
}

/// After the test's child exited: its outcome as the trace's last event. In directory mode it is
/// appended to the test's file; in tail mode the caller prints the file (when the test failed).
pub export fn auk__trace_test_end(name: raw.Ptr<u8>, ok: bool, tail_path: raw.Ptr<u8>) uses raw, ffi {
  let path: raw.Ptr<u8> = if tail_path.is_null() { test_file(trace_cfg, name) } else { raw.null() }
  let fd = c_open(if !path.is_null() { path } else { tail_path }, cfacts.O_WRONLY | cfacts.O_APPEND | cfacts.O_CREAT | cfacts.O_CLOEXEC, i32(420))
  raw.free(path)
  if fd < 0 {
    return
  }
  var l = Line {}
  let lp = raw.addr_of(&l)
  head(lp, "test")
  field(lp, "name")
  put_cjson(lp, name)
  field(lp, "result")
  puts_(lp, if ok { "\"ok\"}}\n" } else { "\"FAIL\"}}\n" })
  write_all(fd, l.p, l.n)
  raw.free(l.p)
  let _ = c_close(fd)
}

pub export fn auk__trace_flush() uses raw, ffi {
  if trace_mode == T_OFF {
    return
  }
  pthread_mutex_lock(raw.addr_of(&trace_lock))
  dump_locked()
  let _ = pthread_mutex_unlock(raw.addr_of(&trace_lock))
}

// ---- events ----------------------------------------------------------------------------------

export fn auk_trace_begin(): bool uses raw {
  if !trace_on() || trace_mute != 0 {
    return false
  }
  trace_mute += 1
  trace_call_site = trace_site
  trace_site = raw.null()
  str.auk__set_show_left(SHOW_BUDGET)
  true
}

export fn auk_trace_call(fname: raw.Ptr<u8>, loc: raw.Ptr<u8>, n: i32, args: raw.Ptr<raw.Ptr<abi.Str>>) uses raw, ffi {
  str.auk__set_show_left(-1)
  var l = new_line()
  let lp = raw.addr_of(&l)
  head(lp, "call")
  field(lp, "fn")
  put_cjson(lp, fname)
  field(lp, "loc")
  put_cjson(lp, if trace_call_site.is_null() { loc } else { trace_call_site })
  field(lp, "args")
  put(lp, "[", 1)
  var i: i32 = 0
  while i < n {
    if i != 0 {
      put(lp, ",", 1)
    }
    put_value(lp, args.at(i))
    rc.release(raw.cast(args.at(i)))
    i += 1
  }
  put(lp, "]", 1)
  end_depth(lp, trace_depth)
  emit(l)
  trace_depth += 1
  trace_mute -= 1
}

export fn auk_trace_exit(): bool uses raw {
  trace_depth -= 1
  if !trace_on() || trace_mute != 0 {
    return false
  }
  trace_mute += 1
  str.auk__set_show_left(SHOW_BUDGET)
  true
}

export fn auk_trace_ret(fname: raw.Ptr<u8>, shown: raw.Ptr<abi.Str>) uses raw, ffi {
  str.auk__set_show_left(-1)
  var l = new_line()
  let lp = raw.addr_of(&l)
  head(lp, "ret")
  field(lp, "fn")
  put_cjson(lp, fname)
  field(lp, "value")
  if !shown.is_null() {
    put_value(lp, shown)
    rc.release(raw.cast(shown))
  } else {
    put(lp, "\"()\"", 4)
  }
  end_depth(lp, trace_depth)
  emit(l)
  trace_mute -= 1
}

export fn auk_trace_err(fname: raw.Ptr<u8>, e: raw.Ptr<abi.Err>) uses raw, ffi {
  let s = err.auk_err_show(e)
  str.auk__set_show_left(-1)
  var l = new_line()
  let lp = raw.addr_of(&l)
  head(lp, "err")
  field(lp, "fn")
  put_cjson(lp, fname)
  field(lp, "error")
  put_value(lp, s)
  rc.release(raw.cast(s))
  end_depth(lp, trace_depth)
  emit(l)
  trace_mute -= 1
}

pub export fn auk__trace_peek(loc: raw.Ptr<u8>, src_text: raw.Ptr<u8>, shown: raw.Ptr<abi.Str>) uses raw, ffi {
  if !trace_on() || trace_mute != 0 {
    return
  }
  var l = new_line()
  let lp = raw.addr_of(&l)
  head(lp, "peek")
  field(lp, "loc")
  put_cjson(lp, loc)
  field(lp, "expr")
  put_cjson(lp, src_text)
  field(lp, "value")
  put_value(lp, shown)
  end_depth(lp, trace_depth)
  emit(l)
}

/// A panic: records it and writes out the trace (the process is about to _exit). caught: the
/// panic jumps to a recovery point (`catch`, a task thread) instead of ending the process; the
/// event gets "caught":true. The message ends at its first NUL.
pub export fn auk__trace_on_panic(loc: raw.Ptr<u8>, msg: raw.Ptr<u8>, n0: usize, caught: bool) uses raw, ffi {
  if trace_mode == T_OFF {
    return
  }
  var n = n0
  let nul = c_memchr(msg, 0, n)
  if !nul.is_null() {
    n = usize(nul.int() - msg.int())
  }
  var l = new_line()
  let lp = raw.addr_of(&l)
  head(lp, "panic")
  field(lp, "msg")
  put_json(lp, msg, n, 0, false)
  field(lp, "loc")
  if loc.is_null() {
    put(lp, "\"<unknown>\"", 11)
  } else {
    put_cjson(lp, loc)
  }
  if caught {
    put(lp, ",\"caught\":true", 14)
  }
  end_depth(lp, trace_depth)
  emit_ev(l, true)
  auk__trace_flush()
}

/// This thread's call depth and mute count, saved at a recovery point (`catch`, a task) and put
/// back when a panic jumps past traced frames that never got to exit.
pub export fn auk__trace_save(depth: raw.Ptr<i64>, mute: raw.Ptr<i32>) uses raw {
  depth.store(trace_depth)
  mute.store(trace_mute)
}

pub export fn auk__trace_restore(depth: i64, mute: i32) {
  trace_depth = depth
  trace_mute = mute
}

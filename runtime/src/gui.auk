/// Windows (`uses gui`): open native windows, show pixels drawn by Auk code, and read input.
/// (Drawing into a frame natively is the pure pixels module, pixels.auk.) Was runtime/c/gui.c,
/// ported line by line; its `#if`s are gui_os (`gui_os.macos.auk`, `gui_os.linux.auk`).
///
/// A separate window process. The program never loads a window system itself. The first
/// gui.open starts a host: this same executable run again (posix_spawn, a fresh exec) with
/// AUK_GUI_HOST set, which owns every native window (gui_host). The two talk over a Unix socket
/// (the wire protocol below), and pixels go through shared memory. This keeps Apple's frameworks
/// out of processes that were forked without exec, as `auk run --live` children are (they don't
/// support that), and leaves the program's main thread alone.
///
/// - Normally the host is the program's own child, on a socket pair, and it exits (closing the
///   windows) when the program ends.
/// - Under `auk run --live`, the parent sets AUK_GUI_SESSION to a socket path. The first child
///   starts a host listening there, and later children (after a restart) connect to the same
///   host. A child that ends without saying goodbye (killed for a restart, or crashed) leaves its
///   windows open, and the next child's gui.open with the same title takes over the window. A
///   child that returns normally says goodbye (auk_gui_shutdown) and its windows close.
///
/// A window is an int id (the host's), so it can be copied between tasks. A reader thread queues
/// each window's events, which next_event takes.
///
/// Wire protocol: a message is a u32 length (of what follows), an op byte, then fields: i64/f64
/// little-endian and a string as the rest of the message. A file descriptor can ride along
/// (SCM_RIGHTS) with the first bytes of a message. The ops are in auk_rt.h (AUK_WIRE_*, abi's
/// WIRE_*).

// the rest of the runtime (C, for now)
extern fn auk__xmalloc(n: usize): raw.Ptr<()> = "void *auk__xmalloc(size_t)"
extern fn auk__xrealloc(p: raw.Ptr<()>, n: usize): raw.Ptr<()> = "void *auk__xrealloc(void *, size_t)"
extern fn auk__task_cancelled(): bool = "bool auk__task_cancelled(void)"
extern fn auk__check_cancel(loc: raw.Ptr<u8>) = "void auk__check_cancel(const char *)"
extern fn c_fcntl(fd: i32, cmd: i32, ...): i32 = "int fcntl(int, int, ...)"
// varargs on macOS, `mode_t` fixed on Linux: passed the same way on all three targets
extern fn c_shm_open(name: raw.Ptr<u8>, flags: i32, ...): i32 = "int shm_open(const char *, int, ...)"
extern var auk_ops_int: abi.ElemOps = "auk_ops_int"
// libc
extern var environ: raw.Ptr<raw.Ptr<u8>> = "environ"
extern fn getenv(name: raw.Ptr<u8>): raw.Ptr<u8> = "char *getenv(const char *)"
extern fn strlen(s: raw.Ptr<u8>): usize = "size_t strlen(const char *)"
extern fn strncmp(a: raw.Ptr<u8>, b: raw.Ptr<u8>, n: usize): i32 = "int strncmp(const char *, const char *, size_t)"
extern fn strerror(e: i32): raw.Ptr<u8> = "char *strerror(int)"
extern fn close(fd: i32): i32 = "int close(int)"
extern fn getpid(): i32 = "int getpid(void)"
extern fn getppid(): i32 = "int getppid(void)"
extern fn ftruncate(fd: i32, len: i64): i32 = "int ftruncate(int, int64_t)"
extern fn shm_unlink(name: raw.Ptr<u8>): i32 = "int shm_unlink(const char *)"
extern fn mmap(addr: raw.Ptr<()>, len: usize, prot: i32, flags: i32, fd: i32, off: i64): raw.Ptr<()> =
  "void *mmap(void *, size_t, int, int, int, int64_t)"
extern fn munmap(addr: raw.Ptr<()>, len: usize): i32 = "int munmap(void *, size_t)"
extern fn nanosleep(req: raw.Ptr<cfacts.Timespec>, rem: raw.Ptr<cfacts.Timespec>): i32 = "int nanosleep(const void *, void *)"
extern fn clock_gettime(clock: i32, ts: raw.Ptr<cfacts.Timespec>): i32 = "int clock_gettime(int, void *)"
extern fn gettimeofday(tv: raw.Ptr<cfacts.Timeval>, tz: raw.Ptr<()>): i32 = "int gettimeofday(void *, void *)"
extern fn socket(domain: i32, kind: i32, proto: i32): i32 = "int socket(int, int, int)"
extern fn socketpair(domain: i32, kind: i32, proto: i32, sv: raw.Ptr<i32>): i32 = "int socketpair(int, int, int, int *)"
extern fn connect(fd: i32, addr: raw.Ptr<()>, len: u32): i32 = "int connect(int, const void *, uint32_t)"
extern fn setsockopt(fd: i32, level: i32, name: i32, val: raw.Ptr<()>, len: u32): i32 =
  "int setsockopt(int, int, int, const void *, uint32_t)"
extern fn sendmsg(fd: i32, msg: raw.Ptr<cfacts.Msghdr>, flags: i32): i64 = "ssize_t sendmsg(int, const void *, int)"
extern fn recvmsg(fd: i32, msg: raw.Ptr<cfacts.Msghdr>, flags: i32): i64 = "ssize_t recvmsg(int, void *, int)"
extern fn posix_spawn(pid: raw.Ptr<i32>, path: raw.Ptr<u8>, acts: raw.Ptr<cfacts.PosixSpawnFileActions>, attr: raw.Ptr<cfacts.PosixSpawnAttr>,
  argv: raw.Ptr<raw.Ptr<u8>>, envp: raw.Ptr<raw.Ptr<u8>>): i32 = "int posix_spawn(int *, const char *, const void *, const void *, char **, char **)"
extern fn posix_spawnattr_init(a: raw.Ptr<cfacts.PosixSpawnAttr>): i32 = "int posix_spawnattr_init(void *)"
extern fn posix_spawnattr_destroy(a: raw.Ptr<cfacts.PosixSpawnAttr>): i32 = "int posix_spawnattr_destroy(void *)"
extern fn posix_spawnattr_setflags(a: raw.Ptr<cfacts.PosixSpawnAttr>, flags: i16): i32 = "int posix_spawnattr_setflags(void *, short)"
extern fn posix_spawn_file_actions_init(a: raw.Ptr<cfacts.PosixSpawnFileActions>): i32 = "int posix_spawn_file_actions_init(void *)"
extern fn posix_spawn_file_actions_destroy(a: raw.Ptr<cfacts.PosixSpawnFileActions>): i32 =
  "int posix_spawn_file_actions_destroy(void *)"
extern fn posix_spawn_file_actions_adddup2(a: raw.Ptr<cfacts.PosixSpawnFileActions>, fd: i32, to: i32): i32 =
  "int posix_spawn_file_actions_adddup2(void *, int, int)"
extern fn pthread_mutex_lock(m: raw.Ptr<cfacts.PthreadMutex>): i32 = "int pthread_mutex_lock(void *)"
extern fn pthread_mutex_unlock(m: raw.Ptr<cfacts.PthreadMutex>): i32 = "int pthread_mutex_unlock(void *)"
extern fn pthread_cond_broadcast(cv: raw.Ptr<cfacts.PthreadCond>): i32 = "int pthread_cond_broadcast(void *)"
extern fn pthread_cond_timedwait(cv: raw.Ptr<cfacts.PthreadCond>, m: raw.Ptr<cfacts.PthreadMutex>, until: raw.Ptr<cfacts.Timespec>): i32 =
  "int pthread_cond_timedwait(void *, void *, const void *)"
extern fn pthread_attr_init(a: raw.Ptr<cfacts.PthreadAttr>): i32 = "int pthread_attr_init(pthread_attr_t *)"
extern fn pthread_attr_destroy(a: raw.Ptr<cfacts.PthreadAttr>): i32 = "int pthread_attr_destroy(pthread_attr_t *)"
extern fn pthread_attr_setdetachstate(a: raw.Ptr<cfacts.PthreadAttr>, s: i32): i32 = "int pthread_attr_setdetachstate(pthread_attr_t *, int)"
extern fn pthread_create(th: raw.Ptr<cfacts.PthreadT>, a: raw.Ptr<cfacts.PthreadAttr>, f: raw.Fn<(raw.Ptr<()>) => raw.Ptr<()>>, arg: raw.Ptr<()>): i32 =
  "int pthread_create(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *)"

// ---- the wire protocol ---------------------------------------------------------------------

/// An f64's bits (and back).
raw union Bits {
  f: float,
  i: i64,
}

pub export fn auk__wire_put_i64(b: raw.Ptr<abi.WireBuf>, v: i64) uses raw, ffi {
  var le: u64 = 0
  let lp: raw.Ptr<u8> = raw.cast(raw.addr_of(&le))
  var i: i64 = 0
  while i < 8 {
    lp.at(i) = u8(u64(v) >> u64(8 * i))
    i += 1
  }
  str.auk__sb_put(raw.field_addr(b, .sb), lp, 8)
}

pub export fn auk__wire_put_f64(b: raw.Ptr<abi.WireBuf>, v: float) uses raw, ffi {
  auk__wire_put_i64(b, Bits { f: v }.i)
}

pub export fn auk__wire_put_str(b: raw.Ptr<abi.WireBuf>, s: raw.Ptr<u8>, n: i64) uses raw, ffi {
  str.auk__sb_put(raw.field_addr(b, .sb), s, n)
}

/// The next i64 of a message (0 past the end).
pub export fn auk__wire_i64(r: raw.Ptr<abi.WireReader>): i64 uses raw {
  var v: i64 = 0
  if r.i + 8 <= r.n {
    var u: u64 = 0
    var k: i64 = 0
    while k < 8 {
      u = u | u64(r.b.at(r.i + k)) << u64(8 * k)
      k += 1
    }
    v = i64(u)
  }
  r.i = r.i + 8
  v
}

pub export fn auk__wire_f64(r: raw.Ptr<abi.WireReader>): float uses raw = Bits { i: auk__wire_i64(r) }.f

/// Don't die of SIGPIPE when the other side has gone; get EPIPE instead.
pub export fn auk__wire_no_sigpipe(fd: i32) uses raw, ffi {
  if cfacts.HAS_SO_NOSIGPIPE {
    var one: i32 = 1
    let _ = setsockopt(fd, cfacts.SOL_SOCKET, cfacts.SO_NOSIGPIPE, raw.cast(raw.addr_of(&one)), 4)
  }
}

/// A control-message buffer for one fd (C's `union { struct cmsghdr h; uint8_t b[...]; }`: the
/// header is there for the alignment; 32 bytes hold CMSG_SPACE(sizeof(int)) on every target).
raw union CmsgOne {
  h: cfacts.Cmsghdr,
  b: [u8; 32],
}

/// The receiving side's control buffer.
raw union Cmsg64 {
  h: cfacts.Cmsghdr,
  b: [u8; 64],
}

/// Send one message, with pass (an fd, or -1) attached to its first bytes; 0 or an errno.
pub export fn auk__wire_send(fd: i32, op: u8, body: raw.Ptr<u8>, n: i64, pass0: i32): i32 uses raw, ffi {
  var pass = pass0
  let total = usize(n) + 5
  let buf: raw.Ptr<u8> = raw.cast(auk__xmalloc(total))
  let len = u32(n + 1)
  var i: u32 = 0
  while i < 4 {
    buf.at(i) = u8(len >> (8 * i))
    i += 1
  }
  buf.at(4) = op
  if n > 0 {
    raw.copy(buf.offset(5), body, usize(n))
  }
  var off: usize = 0
  var e: i32 = 0
  while off < total {
    var iov = cfacts.Iovec { iov_base: raw.cast(buf.offset(off)), iov_len: u64(total - off) }
    var msg = cfacts.Msghdr {}
    var cbuf = CmsgOne {}
    if pass >= 0 {
      gui_os.msg_set(raw.addr_of(&msg), raw.addr_of(&iov), raw.cast(raw.addr_of(&cbuf)), cfacts.cmsg_space(4))
      let c = cfacts.cmsg_firsthdr(raw.addr_of(&msg))
      gui_os.cmsg_set(c, cfacts.SOL_SOCKET, cfacts.SCM_RIGHTS, cfacts.cmsg_len(4))
      raw.copy(cfacts.cmsg_data(c), raw.cast<u8>(raw.addr_of(&pass)), 4)
    } else {
      gui_os.msg_set(raw.addr_of(&msg), raw.addr_of(&iov), raw.null(), 0)
    }
    let w = sendmsg(fd, raw.addr_of(&msg), 0)
    if w < 0 {
      if cfacts.errno() == cfacts.EINTR {
        continue
      }
      e = cfacts.errno()
      break
    }
    pass = -1
    off += usize(w)
  }
  raw.free(buf)
  e
}

/// Read exactly n bytes, picking up an fd if one comes (into *got_fd, closing an earlier one):
/// 1, 0 on EOF at the very start, or -1 (errno set).
fn read_full(fd: i32, buf: raw.Ptr<u8>, n: usize, got_fd: raw.Ptr<i32>): i32 uses raw, ffi {
  var off: usize = 0
  while off < n {
    var iov = cfacts.Iovec { iov_base: raw.cast(buf.offset(off)), iov_len: u64(n - off) }
    var msg = cfacts.Msghdr {}
    var cbuf = Cmsg64 {}
    gui_os.msg_set(raw.addr_of(&msg), raw.addr_of(&iov), raw.cast(raw.addr_of(&cbuf)), 64)
    let r = recvmsg(fd, raw.addr_of(&msg), 0)
    if r > 0 && gui_os.msg_controllen(raw.addr_of(&msg)) >= raw.size_of<cfacts.Cmsghdr>() {
      let c = cfacts.cmsg_firsthdr(raw.addr_of(&msg))
      if !c.is_null() && c.cmsg_level == cfacts.SOL_SOCKET && c.cmsg_type == cfacts.SCM_RIGHTS {
        var p: i32 = 0
        raw.copy(raw.cast<u8>(raw.addr_of(&p)), cfacts.cmsg_data(c), 4)
        if got_fd.load() >= 0 {
          let _ = close(got_fd.load())
        }
        got_fd.store(p)
      }
    }
    if r == 0 {
      if off == 0 {
        return 0
      }
      cfacts.set_errno(cfacts.EPIPE)
      return -1
    }
    if r < 0 {
      if cfacts.errno() == cfacts.EINTR {
        continue
      }
      return -1
    }
    off += usize(r)
  }
  1
}

/// The next message into *m (its body malloc'd): 1, 0 at EOF, or -1.
pub export fn auk__wire_recv(fd: i32, m: raw.Ptr<abi.WireMsg>): i32 uses raw, ffi {
  m.fd = -1
  var len: u32 = 0
  let lp: raw.Ptr<u8> = raw.cast(raw.addr_of(&len))
  var r = read_full(fd, lp, 4, raw.field_addr(m, .fd))
  if r <= 0 {
    return r
  }
  let n = u32(lp.at(0)) | u32(lp.at(1)) << 8 | u32(lp.at(2)) << 16 | u32(lp.at(3)) << 24
  if n == 0 || n > (u32(64) << 20) {
    cfacts.set_errno(cfacts.EINVAL)
    return -1
  }
  let body: raw.Ptr<u8> = raw.cast(auk__xmalloc(usize(n)))
  r = read_full(fd, body, usize(n), raw.field_addr(m, .fd))
  if r <= 0 {
    raw.free(body)
    return -1
  }
  m.op = body.at(0)
  m.body = body
  m.n = i64(n)
  // the fields start after the op byte
  m.r = abi.WireReader { b: body.offset(1), n: i64(n) - 1, i: 0 }
  1
}

// ---- windows and their events (the client side) ---------------------------------------------

raw struct Event {
  v: raw.Ptr<i64>,
  n: i64,
}

raw struct Win {
  id: i64,
  // a ring of queued events
  events: raw.Ptr<Event>,
  head: i64,
  len: i64,
  cap: i64,
  // content size in physical pixels
  w: i64,
  h: i64,
  scale: float,
}

raw var wins_lock: cfacts.PthreadMutex = cfacts.PTHREAD_MUTEX_INITIALIZER
// signalled whenever an event is queued or a window closes
raw var ev_cv: cfacts.PthreadCond = cfacts.PTHREAD_COND_INITIALIZER
raw var wins: raw.Ptr<Win> = raw.null()
raw var nwins: i64 = 0
raw var capwins: i64 = 0
// closed by this program: the host's late events for them are dropped
raw var closed_ids: raw.Ptr<i64> = raw.null()
raw var nclosed: i64 = 0
raw var capclosed: i64 = 0

fn lock(m: raw.Ptr<cfacts.PthreadMutex>) uses ffi {
  let _ = pthread_mutex_lock(m)
}

fn unlock(m: raw.Ptr<cfacts.PthreadMutex>) uses ffi {
  let _ = pthread_mutex_unlock(m)
}

fn broadcast(cv: raw.Ptr<cfacts.PthreadCond>) uses ffi {
  let _ = pthread_cond_broadcast(cv)
}

fn win_find(id: i64): raw.Ptr<Win> uses raw {
  var i: i64 = 0
  while i < nwins {
    if wins.offset(i).id == id {
      return wins.offset(i)
    }
    i += 1
  }
  raw.null()
}

fn is_closed(id: i64): bool uses raw {
  var i: i64 = 0
  while i < nclosed {
    if closed_ids.at(i) == id {
      return true
    }
    i += 1
  }
  false
}

fn closed_add(id: i64) uses raw, ffi {
  if is_closed(id) {
    return
  }
  if nclosed == capclosed {
    capclosed = if capclosed == 0 { 8 } else { capclosed * 2 }
    closed_ids = raw.cast(auk__xrealloc(raw.cast(closed_ids), usize(capclosed) * 8))
  }
  closed_ids.at(nclosed) = id
  nclosed += 1
}

fn closed_remove(id: i64) uses raw {
  var k: i64 = 0
  var i: i64 = 0
  while i < nclosed {
    if closed_ids.at(i) != id {
      closed_ids.at(k) = closed_ids.at(i)
      k += 1
    }
    i += 1
  }
  nclosed = k
}

fn win_free_events(w: raw.Ptr<Win>) uses raw {
  var i: i64 = 0
  while i < w.len {
    raw.free(w.events.offset((w.head + i) % w.cap).v)
    i += 1
  }
  raw.free(w.events)
}

fn win_remove(id: i64) uses raw {
  var k: i64 = 0
  var i: i64 = 0
  while i < nwins {
    if wins.offset(i).id == id {
      win_free_events(wins.offset(i))
    } else {
      wins.at(k) = wins.at(i)
      k += 1
    }
    i += 1
  }
  nwins = k
}

/// The window's entry, made if it is new (null for a window this program closed; wins_lock
/// held).
fn win_entry(id: i64): raw.Ptr<Win> uses raw, ffi {
  if is_closed(id) {
    return raw.null()
  }
  let found = win_find(id)
  if !found.is_null() {
    return found
  }
  if nwins == capwins {
    capwins = if capwins == 0 { 4 } else { capwins * 2 }
    wins = raw.cast(auk__xrealloc(raw.cast(wins), usize(capwins) * raw.size_of<Win>()))
  }
  let w = wins.offset(nwins)
  nwins += 1
  w.store(Win { id, scale: 1.0 })
  w
}

/// Queue an event (from the host; v is taken). A burst of motion or resizing only keeps its
/// latest.
fn push_event(id: i64, v: raw.Ptr<i64>, n: i64) uses raw, ffi {
  lock(raw.addr_of(&wins_lock))
  let w = win_entry(id)
  if w.is_null() {
    raw.free(v)
  } else {
    if n > 0 && (v.at(0) == 2 || v.at(0) == 3) && w.len > 0 {
      let last = w.events.offset((w.head + w.len - 1) % w.cap)
      if last.n > 0 && last.v.at(0) == v.at(0) {
        raw.free(last.v)
        w.len = w.len - 1
      }
    }
    if w.len == w.cap {
      let cap: i64 = if w.cap == 0 { 16 } else { w.cap * 2 }
      let evs: raw.Ptr<Event> = raw.cast(auk__xmalloc(usize(cap) * raw.size_of<Event>()))
      var i: i64 = 0
      while i < w.len {
        evs.at(i) = w.events.at((w.head + i) % w.cap)
        i += 1
      }
      raw.free(w.events)
      w.events = evs
      w.cap = cap
      w.head = 0
    }
    w.events.at((w.head + w.len) % w.cap) = Event { v, n }
    w.len = w.len + 1
  }
  unlock(raw.addr_of(&wins_lock))
  broadcast(raw.addr_of(&ev_cv))
}

// ---- the connection to the host -------------------------------------------------------------

raw var conn_lock: cfacts.PthreadMutex = cfacts.PTHREAD_MUTEX_INITIALIZER
// the host connection's fd, once connected (-1 before)
raw var conn_fd: i32 = -1
// the host has gone (EOF): every call fails from now on (C's _Atomic bool)
raw var host_dead: u8 = 0
// one request at a time waits for its reply
raw var req_lock: cfacts.PthreadMutex = cfacts.PTHREAD_MUTEX_INITIALIZER
raw var reply_lock: cfacts.PthreadMutex = cfacts.PTHREAD_MUTEX_INITIALIZER
raw var reply_cv: cfacts.PthreadCond = cfacts.PTHREAD_COND_INITIALIZER
raw var reply_body: raw.Ptr<u8> = raw.null()
raw var reply_n: i64 = 0
raw var reply_ready: bool = false

fn is_host_dead(): bool uses raw = raw.atomic_load(raw.addr_of(&host_dead), raw.Order.SeqCst) != 0

/// Per window: the last PRESENT the host finished, and an error it reported since.
raw struct Ack {
  win: i64,
  seq: i64,
  err: raw.Ptr<u8>,
}

raw var acks_lock: cfacts.PthreadMutex = cfacts.PTHREAD_MUTEX_INITIALIZER
raw var ack_cv: cfacts.PthreadCond = cfacts.PTHREAD_COND_INITIALIZER
raw var acks: raw.Ptr<Ack> = raw.null()
raw var nacks: i64 = 0
raw var capacks: i64 = 0

fn ack_find(win: i64): raw.Ptr<Ack> uses raw {
  var i: i64 = 0
  while i < nacks {
    if acks.offset(i).win == win {
      return acks.offset(i)
    }
    i += 1
  }
  raw.null()
}

fn ack_remove(win: i64) uses raw {
  var k: i64 = 0
  var i: i64 = 0
  while i < nacks {
    if acks.offset(i).win == win {
      raw.free(acks.offset(i).err)
    } else {
      acks.at(k) = acks.at(i)
      k += 1
    }
    i += 1
  }
  nacks = k
}

fn broadcast_locked(m: raw.Ptr<cfacts.PthreadMutex>, cv: raw.Ptr<cfacts.PthreadCond>) uses ffi {
  lock(m)
  broadcast(cv)
  unlock(m)
}

/// The rest of a message as a malloc'd string.
fn rest_str(r: raw.Ptr<abi.WireReader>): raw.Ptr<u8> uses raw, ffi {
  let n: i64 = if r.i < r.n { r.n - r.i } else { 0 }
  let s: raw.Ptr<u8> = raw.cast(auk__xmalloc(usize(n) + 1))
  if n > 0 {
    raw.copy(s, r.b.offset(r.i), usize(n))
  }
  s.at(n) = 0
  r.i = r.n
  s
}

/// The connection's reader: replies go to the waiting request, events to their window's queue.
fn gui_reader(arg: raw.Ptr<()>): raw.Ptr<()> uses raw, ffi {
  let fd = i32(arg.int())
  loop {
    var m = abi.WireMsg {}
    if auk__wire_recv(fd, raw.addr_of(&m)) <= 0 {
      break
    }
    if m.fd >= 0 {
      let _ = close(m.fd)
    }
    let r = raw.field_addr(raw.addr_of(&m), .r)
    if m.op == abi.WIRE_REPLY {
      lock(raw.addr_of(&reply_lock))
      raw.free(reply_body)
      reply_body = raw.cast(auk__xmalloc(usize(r.n) + 1))
      raw.copy(reply_body, r.b, usize(r.n))
      reply_n = r.n
      reply_ready = true
      broadcast(raw.addr_of(&reply_cv))
      unlock(raw.addr_of(&reply_lock))
    } else if m.op == abi.WIRE_PRESENTED {
      let id = auk__wire_i64(r)
      let seq = auk__wire_i64(r)
      let status = auk__wire_i64(r)
      var e: raw.Ptr<u8> = if status != 0 { rest_str(r) } else { raw.null() }
      lock(raw.addr_of(&acks_lock))
      let a = ack_find(id)
      if !a.is_null() {
        if seq > a.seq {
          a.seq = seq
        }
        if !e.is_null() {
          raw.free(a.err)
          a.err = e
          e = raw.null()
        }
      }
      broadcast(raw.addr_of(&ack_cv))
      unlock(raw.addr_of(&acks_lock))
      raw.free(e)
    } else if m.op == abi.WIRE_EVENT {
      let id = auk__wire_i64(r)
      let n = (r.n - r.i) / 8
      let v: raw.Ptr<i64> = raw.cast(auk__xmalloc(usize(n + 1) * 8))
      var i: i64 = 0
      while i < n {
        v.at(i) = auk__wire_i64(r)
        i += 1
      }
      push_event(id, v, n)
    } else if m.op == abi.WIRE_METRICS {
      let id = auk__wire_i64(r)
      let w = auk__wire_i64(r)
      let h = auk__wire_i64(r)
      let scale = auk__wire_f64(r)
      lock(raw.addr_of(&wins_lock))
      let win = win_entry(id)
      if !win.is_null() {
        win.w = w
        win.h = h
        win.scale = scale
      }
      unlock(raw.addr_of(&wins_lock))
    }
    raw.free(m.body)
  }
  // the host is gone, and so are its windows
  raw.atomic_store(raw.addr_of(&host_dead), 1, raw.Order.SeqCst)
  broadcast_locked(raw.addr_of(&acks_lock), raw.addr_of(&ack_cv))
  lock(raw.addr_of(&wins_lock))
  var i: i64 = 0
  while i < nwins {
    closed_add(wins.offset(i).id)
    win_free_events(wins.offset(i))
    i += 1
  }
  nwins = 0
  unlock(raw.addr_of(&wins_lock))
  lock(raw.addr_of(&conn_lock))
  conn_fd = -1
  unlock(raw.addr_of(&conn_lock))
  broadcast_locked(raw.addr_of(&wins_lock), raw.addr_of(&ev_cv))
  broadcast_locked(raw.addr_of(&reply_lock), raw.addr_of(&reply_cv))
  raw.null()
}

/// A malloc'd message "<a><b>".
fn msg2(a: raw.Ptr<u8>, b: raw.Ptr<u8>): raw.Ptr<u8> uses raw, ffi {
  let na = strlen(a)
  let nb = strlen(b)
  let s: raw.Ptr<u8> = raw.cast(auk__xmalloc(na + nb + 1))
  raw.copy(s, a, na)
  raw.copy(s.offset(na), b, nb + 1)
  s
}

/// Wait (lock held) on cv for up to ms milliseconds.
fn gui_wait_ms(cv: raw.Ptr<cfacts.PthreadCond>, m: raw.Ptr<cfacts.PthreadMutex>, ms: i64) uses raw, ffi {
  var now = cfacts.Timeval {}
  let _ = gettimeofday(raw.addr_of(&now), raw.null())
  let ns = i64(now.tv_usec) * 1000 + ms * 1000000
  var until = cfacts.Timespec { tv_sec: now.tv_sec + ns / 1000000000, tv_nsec: ns % 1000000000 }
  let _ = pthread_cond_timedwait(cv, m, raw.addr_of(&until))
}

/// A one-field buffer for C's `char exe[4096]`.
raw struct PathBuf {
  b: [u8; 4096],
}

raw struct Buf64 {
  b: [u8; 64],
}

/// C's `char *argv[2]`.
raw struct Argv {
  a0: raw.Ptr<u8>,
  a1: raw.Ptr<u8>,
}

/// Start the host: this executable again, with AUK_GUI_HOST=spec, inheriting only the standard
/// streams (and child_fd as fd 3, unless -1), so it holds none of the program's sockets or
/// files. Under --live, AUK_GUI_OWNER is the live parent (the host outlives this child). Null,
/// or why it failed (malloc'd).
fn spawn_host(spec: raw.Ptr<u8>, child_fd: i32): raw.Ptr<u8> uses raw, ffi {
  var exe_buf = PathBuf {}
  let exe: raw.Ptr<u8> = raw.cast(raw.addr_of(&exe_buf))
  if !gui_os.exe_path(exe, 4096) {
    return msg2("gui: cannot find this program's executable", "")
  }
  let env = environ
  var nenv: i64 = 0
  while !env.at(nenv).is_null() {
    nenv += 1
  }
  let envp: raw.Ptr<raw.Ptr<u8>> = raw.cast(auk__xmalloc(usize(nenv + 3) * 8))
  var k: i64 = 0
  var i: i64 = 0
  while i < nenv {
    if strncmp(env.at(i), "AUK_GUI_HOST=", 13) != 0 && strncmp(env.at(i), "AUK_GUI_OWNER=", 14) != 0 {
      envp.at(k) = env.at(i)
      k += 1
    }
    i += 1
  }
  let host = msg2("AUK_GUI_HOST=", spec)
  envp.at(k) = host
  k += 1
  var owner_buf = Buf64 {}
  let owner: raw.Ptr<u8> = raw.cast(raw.addr_of(&owner_buf))
  if child_fd < 0 {
    let pre: raw.Ptr<u8> = "AUK_GUI_OWNER="
    raw.copy(owner, pre, 14)
    let _ = str_fmt.auk__fmt_i64(owner.offset(14), i64(getppid()))
    envp.at(k) = owner
    k += 1
  }
  envp.at(k) = raw.null()
  var argv = Argv { a0: exe, a1: raw.null() }
  var attr = cfacts.PosixSpawnAttr {}
  var acts = cfacts.PosixSpawnFileActions {}
  let _ = posix_spawnattr_init(raw.addr_of(&attr))
  let _ = posix_spawn_file_actions_init(raw.addr_of(&acts))
  let _ = posix_spawnattr_setflags(raw.addr_of(&attr), i16(cfacts.POSIX_SPAWN_CLOEXEC_DEFAULT))
  gui_os.inherit_std(raw.addr_of(&acts))
  if child_fd >= 0 {
    let _ = posix_spawn_file_actions_adddup2(raw.addr_of(&acts), child_fd, 3)
  }
  var pid: i32 = 0
  let rc = posix_spawn(raw.addr_of(&pid), exe, raw.addr_of(&acts), raw.addr_of(&attr), raw.cast(raw.addr_of(&argv)), envp)
  let _ = posix_spawn_file_actions_destroy(raw.addr_of(&acts))
  let _ = posix_spawnattr_destroy(raw.addr_of(&attr))
  raw.free(host)
  raw.free(envp)
  if rc != 0 {
    return msg2("gui: cannot start the window process: ", strerror(rc))
  }
  raw.null()
}

/// A sockaddr_un for path; false if it is too long.
fn unix_addr(path: raw.Ptr<u8>, addr: raw.Ptr<cfacts.SockaddrUn>): bool uses raw, ffi {
  addr.store(cfacts.SockaddrUn {})
  let n = strlen(path)
  let cap = raw.size_of<cfacts.SockaddrUn>() - raw.offset_of<cfacts.SockaddrUn>(.sun_path)
  if n >= cap {
    return false
  }
  gui_os.sun_set_family(addr)
  raw.copy(raw.cast<u8>(raw.field_addr(addr, .sun_path)), path, n)
  true
}

fn try_connect(path: raw.Ptr<u8>): i32 uses raw, ffi {
  var addr = cfacts.SockaddrUn {}
  if !unix_addr(path, raw.addr_of(&addr)) {
    return -1
  }
  let fd = socket(cfacts.AF_UNIX, cfacts.SOCK_STREAM, 0)
  if fd < 0 {
    return -1
  }
  if connect(fd, raw.cast(raw.addr_of(&addr)), u32(raw.size_of<cfacts.SockaddrUn>())) == 0 {
    return fd
  }
  let _ = close(fd)
  -1
}

/// Connect to the `auk run --live` session's host at path, starting it first if no one is
/// listening there yet: the fd, or -1 with *why.
fn connect_session(path: raw.Ptr<u8>, why: raw.Ptr<raw.Ptr<u8>>): i32 uses raw, ffi {
  var fd = try_connect(path)
  if fd >= 0 {
    return fd
  }
  let spec = msg2("listen:", path)
  why.store(spawn_host(spec, -1))
  raw.free(spec)
  if !why.load().is_null() {
    return -1
  }
  var i: i64 = 0
  while i < 200 {
    var ts = cfacts.Timespec { tv_sec: 0, tv_nsec: 15 * 1000000 }
    let _ = nanosleep(raw.addr_of(&ts), raw.null())
    fd = try_connect(path)
    if fd >= 0 {
      return fd
    }
    i += 1
  }
  why.store(msg2("gui: the window process didn't start listening on ", path))
  -1
}

/// The host connection (connecting first): the fd, or -1 with *why (malloc'd).
fn gui_connect(why: raw.Ptr<raw.Ptr<u8>>): i32 uses raw, ffi {
  lock(raw.addr_of(&conn_lock))
  if conn_fd >= 0 {
    let cfd = conn_fd
    unlock(raw.addr_of(&conn_lock))
    return cfd
  }
  if is_host_dead() {
    unlock(raw.addr_of(&conn_lock))
    why.store(msg2("gui: the window process has stopped", ""))
    return -1
  }
  var fd: i32 = -1
  let session = getenv("AUK_GUI_SESSION")
  if !session.is_null() && session.at(0) != 0 {
    fd = connect_session(session, why)
    if fd < 0 {
      unlock(raw.addr_of(&conn_lock))
      return -1
    }
  } else {
    var sv: u64 = 0 // int sv[2]
    let svp: raw.Ptr<i32> = raw.cast(raw.addr_of(&sv))
    if socketpair(cfacts.AF_UNIX, cfacts.SOCK_STREAM, 0, svp) != 0 {
      why.store(msg2("gui: socketpair failed: ", strerror(cfacts.errno())))
      unlock(raw.addr_of(&conn_lock))
      return -1
    }
    why.store(spawn_host("fd:3", svp.at(1)))
    let _ = close(svp.at(1))
    if !why.load().is_null() {
      let _ = close(svp.at(0))
      unlock(raw.addr_of(&conn_lock))
      return -1
    }
    fd = svp.at(0)
  }
  let _ = c_fcntl(fd, cfacts.F_SETFD, cfacts.FD_CLOEXEC)
  auk__wire_no_sigpipe(fd)
  var th = cfacts.PthreadT {}
  var attr = cfacts.PthreadAttr {}
  let _ = pthread_attr_init(raw.addr_of(&attr))
  let _ = pthread_attr_setdetachstate(raw.addr_of(&attr), cfacts.PTHREAD_CREATE_DETACHED)
  let rc = pthread_create(raw.addr_of(&th), raw.addr_of(&attr), raw.fn_of(gui_reader), raw.from_int(i64(fd)))
  let _ = pthread_attr_destroy(raw.addr_of(&attr))
  if rc != 0 {
    why.store(msg2("gui: cannot start the event thread: ", strerror(rc)))
    unlock(raw.addr_of(&conn_lock))
    return -1
  }
  conn_fd = fd
  unlock(raw.addr_of(&conn_lock))
  fd
}

/// A message's bytes (C's `sb.buf == NULL ? sb.small : sb.buf`).
fn body_of(b: raw.Ptr<abi.WireBuf>): raw.Ptr<u8> uses raw {
  let sb = raw.field_addr(b, .sb)
  if sb.buf.is_null() { raw.cast(raw.field_addr(sb, .small)) } else { sb.buf }
}

/// "gui: the window process has stopped (<strerror(e)>)", malloc'd.
fn stopped(e: i32): raw.Ptr<u8> uses raw, ffi {
  let x = msg2("gui: the window process has stopped (", strerror(e))
  let s = msg2(x, ")")
  raw.free(x)
  s
}

/// Send a request and wait for its reply's result (after the status): true with *out (malloc'd,
/// *n bytes), or false with *why (malloc'd).
fn request(op: u8, body: raw.Ptr<abi.WireBuf>, out: raw.Ptr<raw.Ptr<u8>>, n: raw.Ptr<i64>, why: raw.Ptr<raw.Ptr<u8>>): bool uses raw, ffi {
  lock(raw.addr_of(&req_lock))
  let fd = gui_connect(why)
  if fd < 0 {
    unlock(raw.addr_of(&req_lock))
    return false
  }
  lock(raw.addr_of(&reply_lock))
  reply_ready = false
  unlock(raw.addr_of(&reply_lock))
  let e = auk__wire_send(fd, op, body_of(body), body.sb.len, -1)
  if e != 0 {
    unlock(raw.addr_of(&req_lock))
    why.store(stopped(e))
    return false
  }
  lock(raw.addr_of(&reply_lock))
  var ok = false
  loop {
    if reply_ready {
      reply_ready = false
      var r = abi.WireReader { b: reply_body, n: reply_n, i: 0 }
      if auk__wire_i64(raw.addr_of(&r)) == 0 {
        let len: i64 = if reply_n > 8 { reply_n - 8 } else { 0 }
        let o: raw.Ptr<u8> = raw.cast(auk__xmalloc(usize(len) + 1))
        raw.copy(o, reply_body.offset(if reply_n > 8 { i64(8) } else { reply_n }), usize(len))
        out.store(o)
        n.store(len)
        ok = true
      } else {
        why.store(rest_str(raw.addr_of(&r)))
      }
      break
    }
    if is_host_dead() {
      why.store(msg2("gui: the window process has stopped", ""))
      break
    }
    gui_wait_ms(raw.addr_of(&reply_cv), raw.addr_of(&reply_lock), 200)
  }
  unlock(raw.addr_of(&reply_lock))
  unlock(raw.addr_of(&req_lock))
  ok
}

/// Send a message that has no reply (if connected at all).
fn tell(op: u8, body: raw.Ptr<abi.WireBuf>) uses raw, ffi {
  lock(raw.addr_of(&req_lock))
  lock(raw.addr_of(&conn_lock))
  let fd = conn_fd
  unlock(raw.addr_of(&conn_lock))
  if fd >= 0 {
    let _ = auk__wire_send(fd, op, body_of(body), body.sb.len, -1)
  }
  unlock(raw.addr_of(&req_lock))
}

/// Close this program's windows: it is ending normally (`auk run --live` calls this when the
/// program returns, so its windows don't wait to be taken over by the next run).
export fn auk_gui_shutdown() uses raw, ffi {
  var b = abi.WireBuf {}
  tell(abi.WIRE_BYE, raw.addr_of(&b))
}

// ---- the Auk-facing calls -------------------------------------------------------------------

fn int_err_sb(m: raw.Ptr<abi.StrBuf>): abi.ResInt uses raw, ffi = abi.ResInt { err: str.auk__err_sb(m) }

/// Open a window with a w×h (logical points) content area; returns its id.
export fn auk_gui_open(title: raw.Ptr<abi.Str>, w: i64, h: i64): abi.ResInt uses raw, ffi {
  if w < 1 || w > 16384 || h < 1 || h > 16384 {
    var m = abi.StrBuf {}
    let mp = raw.addr_of(&m)
    str.auk__sb_put_cstr(mp, "gui.open: size ")
    str_fmt.auk_sb_int(mp, w)
    str.auk__sb_put_cstr(mp, "x")
    str_fmt.auk_sb_int(mp, h)
    str.auk__sb_put_cstr(mp, " (expected 1 to 16384 each)")
    return int_err_sb(mp)
  }
  if !gui_os.SUPPORTED {
    return abi.ResInt { err: err.auk_err_new_cstr("gui: windows are only supported on macOS so far") }
  }
  var body = abi.WireBuf {}
  let bp = raw.addr_of(&body)
  auk__wire_put_i64(bp, w)
  auk__wire_put_i64(bp, h)
  auk__wire_put_str(bp, str.auk_str_cstr(title), str.auk_str_byte_len(title))
  var out: raw.Ptr<u8> = raw.null()
  var n: i64 = 0
  var why: raw.Ptr<u8> = raw.null()
  let ok = request(abi.WIRE_OPEN, bp, raw.addr_of(&out), raw.addr_of(&n), raw.addr_of(&why))
  str.auk_sb_free(raw.field_addr(bp, .sb))
  if !ok {
    let e = err.auk_err_new_cstr(why)
    raw.free(why)
    return abi.ResInt { err: e }
  }
  var r = abi.WireReader { b: out, n, i: 0 }
  let rp = raw.addr_of(&r)
  let id = auk__wire_i64(rp)
  let pw = auk__wire_i64(rp)
  let ph = auk__wire_i64(rp)
  let scale = auk__wire_f64(rp)
  raw.free(out)
  lock(raw.addr_of(&wins_lock))
  closed_remove(id)
  let win = win_entry(id)
  if !win.is_null() {
    win.w = pw
    win.h = ph
    win.scale = scale
  }
  unlock(raw.addr_of(&wins_lock))
  abi.ResInt { ok: true, val: id }
}

// ---- presenting frames ----------------------------------------------------------------------

/// A window's frame in shared memory (0xffRRGGBB u32s), mapped here and in the host.
raw struct Shm {
  fd: i32,
  ptr: raw.Ptr<u32>,
  w: i64,
  h: i64,
}

/// A rectangle [x0, x1) × [y0, y1).
raw struct GuiRect {
  x0: i64,
  y0: i64,
  x1: i64,
  y1: i64,
}

/// Areas written into the other buffer since this one was last written: what it lacks.
raw struct Stale {
  r: [GuiRect; 9],
  n: i32,
}

/// A window's two shared frame buffers. The host reads only the one last presented, so present
/// writes the other; it returns without waiting, and waits for the host to take the last
/// present (PRESENTED) only before writing the buffer that present used.
raw struct Bufs {
  win: i64,
  w: i64,
  h: i64,
  b: [Shm; 2],
  // whether the host has the buffer's fd yet
  sent: [bool; 2],
  // whether the buffer has never been written
  blank: [bool; 2],
  stale: [Stale; 2],
  // the buffer to write next
  next: i32,
  // the last PRESENT's sequence number
  seq: i64,
}

fn shm_at(b: raw.Ptr<Bufs>, i: i32): raw.Ptr<Shm> uses raw = raw.cast<Shm>(raw.field_addr(b, .b)).offset(i)
fn sent_at(b: raw.Ptr<Bufs>, i: i32): raw.Ptr<bool> uses raw = raw.cast<bool>(raw.field_addr(b, .sent)).offset(i)
fn blank_at(b: raw.Ptr<Bufs>, i: i32): raw.Ptr<bool> uses raw = raw.cast<bool>(raw.field_addr(b, .blank)).offset(i)
fn stale_at(b: raw.Ptr<Bufs>, i: i32): raw.Ptr<Stale> uses raw = raw.cast<Stale>(raw.field_addr(b, .stale)).offset(i)
fn rect_at(s: raw.Ptr<Stale>, i: i32): raw.Ptr<GuiRect> uses raw = raw.cast<GuiRect>(raw.field_addr(s, .r)).offset(i)

raw var shms_lock: cfacts.PthreadMutex = cfacts.PTHREAD_MUTEX_INITIALIZER
raw var shms: raw.Ptr<Bufs> = raw.null()
raw var nshms: i64 = 0
raw var capshms: i64 = 0

fn shm_free(s: raw.Ptr<Shm>) uses raw, ffi {
  let _ = munmap(raw.cast(s.ptr), usize(s.w * s.h * 4))
  let _ = close(s.fd)
}

fn bufs_free(b: raw.Ptr<Bufs>) uses raw, ffi {
  shm_free(shm_at(b, 0))
  shm_free(shm_at(b, 1))
}

fn bufs_find(win: i64): raw.Ptr<Bufs> uses raw {
  var i: i64 = 0
  while i < nshms {
    if shms.offset(i).win == win {
      return shms.offset(i)
    }
    i += 1
  }
  raw.null()
}

fn bufs_remove(win: i64) uses raw, ffi {
  var k: i64 = 0
  var i: i64 = 0
  while i < nshms {
    if shms.offset(i).win == win {
      bufs_free(shms.offset(i))
    } else {
      shms.at(k) = shms.at(i)
      k += 1
    }
    i += 1
  }
  nshms = k
}

/// Close a window (a no-op for one that is already closed).
export fn auk_gui_close(win: i64) uses raw, ffi {
  lock(raw.addr_of(&wins_lock))
  closed_add(win)
  let was_open = !win_find(win).is_null()
  win_remove(win)
  broadcast(raw.addr_of(&ev_cv))
  unlock(raw.addr_of(&wins_lock))
  lock(raw.addr_of(&shms_lock))
  bufs_remove(win)
  unlock(raw.addr_of(&shms_lock))
  lock(raw.addr_of(&acks_lock))
  ack_remove(win)
  unlock(raw.addr_of(&acks_lock))
  if was_open {
    var b = abi.WireBuf {}
    auk__wire_put_i64(raw.addr_of(&b), win)
    tell(abi.WIRE_CLOSE, raw.addr_of(&b))
    str.auk_sb_free(raw.field_addr(raw.addr_of(&b), .sb))
  }
}

/// The window's content width in physical pixels (0 once it is closed).
export fn auk_gui_width(win: i64): i64 uses raw, ffi {
  lock(raw.addr_of(&wins_lock))
  let w = win_find(win)
  let v: i64 = if w.is_null() { 0 } else { w.w }
  unlock(raw.addr_of(&wins_lock))
  v
}

/// The window's content height in physical pixels (0 once it is closed).
export fn auk_gui_height(win: i64): i64 uses raw, ffi {
  lock(raw.addr_of(&wins_lock))
  let w = win_find(win)
  let v: i64 = if w.is_null() { 0 } else { w.h }
  unlock(raw.addr_of(&wins_lock))
  v
}

/// Physical pixels per logical point (2.0 on a Retina display).
export fn auk_gui_scale(win: i64): float uses raw, ffi {
  lock(raw.addr_of(&wins_lock))
  let w = win_find(win)
  let v = if w.is_null() { 1.0 } else { w.scale }
  unlock(raw.addr_of(&wins_lock))
  v
}

raw var shm_counter: i64 = 0

/// "gui.present: shared memory: <strerror(e)>", malloc'd.
fn shm_err(e: i32): raw.Ptr<u8> uses raw, ffi = msg2("gui.present: shared memory: ", strerror(e))

/// A new w×h shared buffer; false with *why (malloc'd).
fn shm_new(w: i64, h: i64, s: raw.Ptr<Shm>, why: raw.Ptr<raw.Ptr<u8>>): bool uses raw, ffi {
  let len = usize(w * h * 4)
  var name_buf = Buf64 {}
  let name: raw.Ptr<u8> = raw.cast(raw.addr_of(&name_buf))
  var nb = abi.StrBuf {}
  let nbp = raw.addr_of(&nb)
  str.auk__sb_put_cstr(nbp, "/aukgui.")
  str_fmt.auk_sb_int(nbp, i64(getpid()))
  str.auk__sb_put_cstr(nbp, ".")
  str_fmt.auk_sb_int(nbp, raw.atomic_add(raw.addr_of(&shm_counter), 1, raw.Order.SeqCst))
  str_fmt.auk__sb_take_into(nbp, name, 64)
  let fd = c_shm_open(name, cfacts.O_CREAT | cfacts.O_EXCL | cfacts.O_RDWR, u32(384))
  if fd < 0 {
    why.store(shm_err(cfacts.errno()))
    return false
  }
  let _ = shm_unlink(name)
  let _ = c_fcntl(fd, cfacts.F_SETFD, cfacts.FD_CLOEXEC)
  if ftruncate(fd, i64(len)) != 0 {
    let e = cfacts.errno()
    let _ = close(fd)
    why.store(shm_err(e))
    return false
  }
  let p = mmap(raw.null(), len, cfacts.PROT_READ | cfacts.PROT_WRITE, cfacts.MAP_SHARED, fd, 0)
  if i64(p.int()) == cfacts.MAP_FAILED {
    let e = cfacts.errno()
    let _ = close(fd)
    why.store(shm_err(e))
    return false
  }
  s.store(Shm { fd, ptr: raw.cast(p), w, h })
  true
}

/// Wait until the host has finished PRESENT seq of win; the error of any present since the last
/// wait (malloc'd), or null.
fn wait_presented(win: i64, seq: i64): raw.Ptr<u8> uses raw, ffi {
  lock(raw.addr_of(&acks_lock))
  var e: raw.Ptr<u8> = raw.null()
  loop {
    let a = ack_find(win)
    if a.is_null() {
      break
    }
    if a.seq >= seq {
      e = a.err
      a.err = raw.null()
      break
    }
    if is_host_dead() {
      e = msg2("gui: the window process has stopped", "")
      break
    }
    gui_wait_ms(raw.addr_of(&ack_cv), raw.addr_of(&acks_lock), 200)
  }
  unlock(raw.addr_of(&acks_lock))
  e
}

/// Copy rectangle r of the frame src (w per row) into dst as 0xffRRGGBB: windows show frames
/// opaque, whatever their transparency.
fn convert(dst: raw.Ptr<u32>, src: raw.Ptr<u32>, w: i64, r: GuiRect) uses raw {
  var row = r.y0
  while row < r.y1 {
    var i = row * w + r.x0
    while i < row * w + r.x1 {
      dst.at(i) = src.at(i) | 0xff000000
      i += 1
    }
    row += 1
  }
}

/// Add r to a list of areas, merging them all into one when the list gets long.
fn add_rect(s: raw.Ptr<Stale>, r: GuiRect) uses raw {
  rect_at(s, s.n).store(r)
  s.n = s.n + 1
  if s.n > 8 {
    var all = r
    var i: i32 = 0
    while i < s.n {
      let b = rect_at(s, i).load()
      all.x0 = if b.x0 < all.x0 { b.x0 } else { all.x0 }
      all.y0 = if b.y0 < all.y0 { b.y0 } else { all.y0 }
      all.x1 = if b.x1 > all.x1 { b.x1 } else { all.x1 }
      all.y1 = if b.y1 > all.y1 { b.y1 } else { all.y1 }
      i += 1
    }
    rect_at(s, 0).store(all)
    s.n = 1
  }
}

/// Present rs (n of them, clipped) of src (w×h) in win: null, or why not (malloc'd).
fn present(win: i64, src: raw.Ptr<u32>, w: i64, h: i64, rs0: raw.Ptr<GuiRect>, n0: i64): raw.Ptr<u8> uses raw, ffi {
  if !gui_os.SUPPORTED {
    return msg2("gui: windows are only supported on macOS so far", "")
  }
  var rs = rs0
  var n = n0
  lock(raw.addr_of(&shms_lock))
  var bf = bufs_find(win)
  var why: raw.Ptr<u8> = raw.null()
  if bf.is_null() || bf.w != w || bf.h != h {
    // a new size: new buffers (the host maps them as their fds arrive)
    var fresh = Bufs { win, w, h }
    let fp = raw.addr_of(&fresh)
    if !shm_new(w, h, shm_at(fp, 0), raw.addr_of(&why)) {
      unlock(raw.addr_of(&shms_lock))
      return why
    }
    if !shm_new(w, h, shm_at(fp, 1), raw.addr_of(&why)) {
      shm_free(shm_at(fp, 0))
      unlock(raw.addr_of(&shms_lock))
      return why
    }
    blank_at(fp, 0).store(true)
    blank_at(fp, 1).store(true)
    if !bf.is_null() {
      fresh.seq = bf.seq
      bufs_free(bf)
      bf.store(fresh)
    } else {
      if nshms == capshms {
        capshms = if capshms == 0 { 4 } else { capshms * 2 }
        shms = raw.cast(auk__xrealloc(raw.cast(shms), usize(capshms) * raw.size_of<Bufs>()))
      }
      shms.at(nshms) = fresh
      nshms += 1
      bf = shms.offset(nshms - 1)
    }
    lock(raw.addr_of(&acks_lock))
    if ack_find(win).is_null() {
      if nacks == capacks {
        capacks = if capacks == 0 { 4 } else { capacks * 2 }
        acks = raw.cast(auk__xrealloc(raw.cast(acks), usize(capacks) * raw.size_of<Ack>()))
      }
      acks.at(nacks) = Ack { win, seq: bf.seq, err: raw.null() }
      nacks += 1
    }
    unlock(raw.addr_of(&acks_lock))
  }
  if n == 0 {
    unlock(raw.addr_of(&shms_lock))
    return raw.null()
  }
  // until the host has taken the last present (the other buffer), it may still read this one
  why = wait_presented(win, bf.seq)
  if !why.is_null() {
    unlock(raw.addr_of(&shms_lock))
    return why
  }
  let i = bf.next
  let o = 1 - bf.next
  let dst = shm_at(bf, i).ptr
  let other = shm_at(bf, o).ptr
  var whole = GuiRect { x0: 0, y0: 0, x1: w, y1: h }
  if blank_at(bf, i).load() && blank_at(bf, o).load() {
    rs = raw.addr_of(&whole)
    n = 1
  }
  if blank_at(bf, i).load() && !blank_at(bf, o).load() {
    raw.copy(dst, other, usize(w * h) * 4)
  } else if !blank_at(bf, i).load() {
    // catch up with what the other buffer got since this one was written (apart from what this
    // present writes anyway)
    let st = stale_at(bf, i)
    var k: i32 = 0
    while k < st.n {
      let s = rect_at(st, k).load()
      var covered = false
      var j: i64 = 0
      while j < n && !covered {
        let q = rs.offset(j)
        covered = s.x0 >= q.x0 && s.y0 >= q.y0 && s.x1 <= q.x1 && s.y1 <= q.y1
        j += 1
      }
      if !covered {
        var row = s.y0
        while row < s.y1 {
          raw.copy(dst.offset(row * w + s.x0), other.offset(row * w + s.x0), usize(s.x1 - s.x0) * 4)
          row += 1
        }
      }
      k += 1
    }
  }
  let si = stale_at(bf, i)
  si.n = 0
  blank_at(bf, i).store(false)
  var j: i64 = 0
  while j < n {
    convert(dst, src, w, rs.at(j))
    add_rect(stale_at(bf, o), rs.at(j))
    j += 1
  }
  bf.seq = bf.seq + 1
  bf.next = o
  let pass: i32 = if sent_at(bf, i).load() { -1 } else { shm_at(bf, i).fd }
  sent_at(bf, i).store(true)
  var body = abi.WireBuf {}
  let bp = raw.addr_of(&body)
  auk__wire_put_i64(bp, win)
  auk__wire_put_i64(bp, w)
  auk__wire_put_i64(bp, h)
  auk__wire_put_i64(bp, i64(i))
  auk__wire_put_i64(bp, bf.seq)
  auk__wire_put_i64(bp, n)
  j = 0
  while j < n {
    let q = rs.offset(j)
    auk__wire_put_i64(bp, q.x0)
    auk__wire_put_i64(bp, q.y0)
    auk__wire_put_i64(bp, q.x1 - q.x0)
    auk__wire_put_i64(bp, q.y1 - q.y0)
    j += 1
  }
  unlock(raw.addr_of(&shms_lock))
  lock(raw.addr_of(&req_lock))
  let fd = gui_connect(raw.addr_of(&why))
  if fd >= 0 {
    let e = auk__wire_send(fd, abi.WIRE_PRESENT, body_of(bp), body.sb.len, pass)
    if e != 0 {
      why = stopped(e)
    }
  }
  unlock(raw.addr_of(&req_lock))
  str.auk_sb_free(raw.field_addr(bp, .sb))
  why
}

fn unit_err_sb(m: raw.Ptr<abi.StrBuf>): abi.ResUnit uses raw, ffi = abi.ResUnit { err: str.auk__err_sb(m) }

raw let INT64_MAX: i64 = 9223372036854775807
raw let INT64_MIN: i64 = -9223372036854775807 - 1

fn clamp_add(a: i64, b: i64, hi: i64): i64 uses raw {
  let (s0, o) = raw.add_overflow(a, b)
  let s = if o { if b > 0 { INT64_MAX } else { INT64_MIN } } else { s0 }
  if s < hi { s } else { hi }
}

/// Show the rectangles rects (flattened x, y, w, h quads) of the frame f in the window; the rest
/// of what it shows stays. Only those rectangles are copied, and they go to the window process
/// together, in one message.
export fn auk_gui_present_rects(win: i64, f: raw.Ptr<abi.Frame>, rects: raw.Ptr<abi.Arr>): abi.ResUnit uses raw, ffi {
  let w = f.w
  let h = f.hgt
  var m = abi.StrBuf {}
  let mp = raw.addr_of(&m)
  if w < 1 || h < 1 {
    str.auk__sb_put_cstr(mp, "gui.present: an empty ")
    str_fmt.auk_sb_int(mp, w)
    str.auk__sb_put_cstr(mp, "x")
    str_fmt.auk_sb_int(mp, h)
    str.auk__sb_put_cstr(mp, " frame")
    return unit_err_sb(mp)
  }
  let n = arr.auk_arr_len(rects)
  if n % 4 != 0 {
    str.auk__sb_put_cstr(mp, "gui.present_rects: ")
    str_fmt.auk_sb_int(mp, n)
    str.auk__sb_put_cstr(mp, " ints is not a list of x, y, w, h quads")
    return unit_err_sb(mp)
  }
  lock(raw.addr_of(&wins_lock))
  let open = !win_find(win).is_null()
  unlock(raw.addr_of(&wins_lock))
  if !open {
    str.auk__sb_put_cstr(mp, "gui.present: window ")
    str_fmt.auk_sb_int(mp, win)
    str.auk__sb_put_cstr(mp, " is closed")
    return unit_err_sb(mp)
  }
  let q: raw.Ptr<i64> = if n > 0 { raw.cast(rects.data) } else { raw.null() }
  let rs: raw.Ptr<GuiRect> = raw.cast(auk__xmalloc(usize(n / 4 + 1) * raw.size_of<GuiRect>()))
  var k: i64 = 0
  var i: i64 = 0
  while i + 3 < n {
    let r = GuiRect {
      x0: if q.at(i) > 0 { q.at(i) } else { 0 },
      y0: if q.at(i + 1) > 0 { q.at(i + 1) } else { 0 },
      x1: clamp_add(q.at(i), q.at(i + 2), w),
      y1: clamp_add(q.at(i + 1), q.at(i + 3), h),
    }
    if r.x0 < r.x1 && r.y0 < r.y1 {
      rs.at(k) = r
      k += 1
    }
    i += 4
  }
  let why = present(win, f.data, w, h, rs, k)
  raw.free(rs)
  if !why.is_null() {
    let e = err.auk_err_new_cstr(why)
    raw.free(why)
    return abi.ResUnit { err: e }
  }
  abi.ResUnit { ok: true }
}

fn now_ms(): i64 uses raw, ffi {
  var t = cfacts.Timespec {}
  let _ = clock_gettime(cfacts.CLOCK_MONOTONIC, raw.addr_of(&t))
  t.tv_sec * 1000 + t.tv_nsec / 1000000
}

/// The Close event, `[1]` (C's `static const int64_t close_ev[1]`).
raw var close_ev: i64 = 1

/// The next event of win as [int] (the kind, then its fields), waiting at most ms milliseconds
/// (0: don't wait, negative: until there is one). Empty if none came. A closed or unknown window
/// reports Close, so a loop over its events ends. A task waiting here can be cancelled.
export fn auk_gui_next_event(win: i64, ms: i64, loc: raw.Ptr<u8>): raw.Ptr<abi.Arr> uses raw, ffi {
  let start = now_ms()
  var v: raw.Ptr<i64> = raw.null()
  var owned: raw.Ptr<i64> = raw.null() // a queued event's ints, freed here
  var n: i64 = 0
  lock(raw.addr_of(&wins_lock))
  loop {
    let w = win_find(win)
    if w.is_null() {
      v = raw.addr_of(&close_ev)
      n = 1
      break
    }
    if w.len > 0 {
      let e = w.events.at(w.head)
      w.head = (w.head + 1) % w.cap
      w.len = w.len - 1
      owned = e.v
      v = e.v
      n = e.n
      break
    }
    var slice: i64 = 50
    if ms >= 0 {
      let left = ms - (now_ms() - start)
      if left <= 0 {
        break
      }
      slice = if left < 50 { left } else { 50 }
    }
    gui_wait_ms(raw.addr_of(&ev_cv), raw.addr_of(&wins_lock), slice)
    if auk__task_cancelled() {
      unlock(raw.addr_of(&wins_lock))
      auk__check_cancel(loc)
      lock(raw.addr_of(&wins_lock))
    }
  }
  unlock(raw.addr_of(&wins_lock))
  var out = arr.auk_arr_new(raw.addr_of(&auk_ops_int), n)
  if n > 0 {
    let d: raw.Ptr<i64> = raw.cast(arr.auk_arr_make_unique(raw.addr_of(&out)))
    raw.copy(d, v, usize(n) * 8)
    out.len = n
  }
  raw.free(owned)
  out
}

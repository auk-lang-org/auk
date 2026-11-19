/// Channels: `Chan<T>` (core.auk) wraps an AukChan * (`abi.Chan`), an unbounded FIFO shared by
/// every copy of the channel (a handle: never copied, never in a task's heap). send stores an
/// untracked deep copy of the message; recv deep-copies it again into the receiver's heap and
/// frees the stored one, so sender and receiver never share an object (heap.auk). (Was
/// runtime/c/chan.c, ported line by line; its locks are initialized with pthread_*_init calls,
/// as the C did.)

// the rest of the runtime
// _Noreturn: its callers say `raw.unreachable()` (no `never` here, TODO(dialect))
// pthreads and clocks
extern fn pthread_mutex_init(m: raw.Ptr<cfacts.PthreadMutex>, attr: raw.Ptr<()>): i32 =
  "int pthread_mutex_init(void *, const void *)"
extern fn pthread_mutex_destroy(m: raw.Ptr<cfacts.PthreadMutex>): i32 = "int pthread_mutex_destroy(void *)"
extern fn pthread_mutex_lock(m: raw.Ptr<cfacts.PthreadMutex>): i32 = "int pthread_mutex_lock(void *)"
extern fn pthread_mutex_unlock(m: raw.Ptr<cfacts.PthreadMutex>): i32 = "int pthread_mutex_unlock(void *)"
extern fn pthread_cond_init(cv: raw.Ptr<cfacts.PthreadCond>, attr: raw.Ptr<()>): i32 =
  "int pthread_cond_init(void *, const void *)"
extern fn pthread_cond_destroy(cv: raw.Ptr<cfacts.PthreadCond>): i32 = "int pthread_cond_destroy(void *)"
extern fn pthread_cond_signal(cv: raw.Ptr<cfacts.PthreadCond>): i32 = "int pthread_cond_signal(void *)"
extern fn pthread_cond_broadcast(cv: raw.Ptr<cfacts.PthreadCond>): i32 = "int pthread_cond_broadcast(void *)"
extern fn pthread_cond_wait(cv: raw.Ptr<cfacts.PthreadCond>, m: raw.Ptr<cfacts.PthreadMutex>): i32 =
  "int pthread_cond_wait(void *, void *)"
extern fn pthread_cond_timedwait(cv: raw.Ptr<cfacts.PthreadCond>, m: raw.Ptr<cfacts.PthreadMutex>, until: raw.Ptr<cfacts.Timespec>): i32 =
  "int pthread_cond_timedwait(void *, void *, const void *)"
extern fn clock_gettime(clock: i32, ts: raw.Ptr<cfacts.Timespec>): i32 = "int clock_gettime(int, void *)"
extern fn gettimeofday(tv: raw.Ptr<cfacts.Timeval>, tz: raw.Ptr<()>): i32 = "int gettimeofday(void *, void *)"

/// A new channel for elements described by proto's element ops (proto is an empty [T]).
export fn auk_chan_new(proto: raw.Ptr<abi.Arr>): raw.Ptr<abi.Chan> uses raw, ffi {
  let c: raw.Ptr<abi.Chan> = raw.cast(rc.auk__alloc(raw.size_of<abi.Chan>(), abi.K_CHAN))
  let _ = pthread_mutex_init(raw.field_addr(c, .lock), raw.null())
  let _ = pthread_cond_init(raw.field_addr(c, .cv), raw.null())
  c.ops = proto.ops
  c.size = if c.ops.size > 0 { c.ops.size } else { 1 }
  c
}

fn slot(c: raw.Ptr<abi.Chan>, i: i64): raw.Ptr<u8> uses raw =
  c.items.offset(usize((c.head + i) % c.cap) * c.size)

/// `c.send(x)`: queue a copy of *x. Panics on a closed channel.
export fn auk_chan_send(c: raw.Ptr<abi.Chan>, x: raw.Ptr<()>, loc: raw.Ptr<u8>) uses raw, ffi {
  var tmp: abi.Tmp
  let buf = rc.auk__tmp_get(raw.addr_of(&tmp), c.size)
  let old = heap.auk__heap_switch(raw.null())
  copy.auk__copy_elem(c.ops, x, raw.cast(buf))
  let _ = heap.auk__heap_switch(old)
  let _ = pthread_mutex_lock(raw.field_addr(c, .lock))
  if c.closed {
    let _ = pthread_mutex_unlock(raw.field_addr(c, .lock))
    let release = c.ops.release
    if !release.is_null() {
      release(raw.cast(buf))
    }
    rc.auk__tmp_done(raw.addr_of(&tmp))
    rc.auk__panic3(loc, "send on a closed channel", raw.null(), raw.null())
    raw.unreachable()
  }
  if c.count == c.cap {
    let cap: i64 = if c.cap == 0 { 8 } else { c.cap * 2 }
    let items: raw.Ptr<u8> = raw.cast(rc.auk__xmalloc(usize(cap) * c.size))
    var i: i64 = 0
    while i < c.count {
      raw.copy(items.offset(usize(i) * c.size), slot(c, i), c.size)
      i += 1
    }
    raw.free(c.items)
    c.items = items
    c.cap = cap
    c.head = 0
  }
  raw.copy(slot(c, c.count), buf, c.size)
  c.count += 1
  let _ = pthread_mutex_unlock(raw.field_addr(c, .lock))
  let _ = pthread_cond_signal(raw.field_addr(c, .cv))
  rc.auk__tmp_done(raw.addr_of(&tmp))
}

/// Take the oldest message (lock held, count > 0) into buf.
fn pop(c: raw.Ptr<abi.Chan>, buf: raw.Ptr<u8>) uses raw {
  raw.copy(buf, slot(c, 0), c.size)
  c.head = (c.head + 1) % c.cap
  c.count -= 1
}

/// Copy a taken message to out (into this thread's heap) and free the stored copy.
fn deliver(c: raw.Ptr<abi.Chan>, buf: raw.Ptr<u8>, out: raw.Ptr<()>) uses raw {
  copy.auk__copy_elem(c.ops, raw.cast(buf), out)
  let release = c.ops.release
  if !release.is_null() {
    let old = heap.auk__heap_switch(raw.null())
    release(raw.cast(buf))
    let _ = heap.auk__heap_switch(old)
  }
}

fn now_ms(): i64 uses raw, ffi {
  var ts = cfacts.Timespec {}
  let _ = clock_gettime(cfacts.CLOCK_MONOTONIC, raw.addr_of(&ts))
  ts.tv_sec * 1000 + ts.tv_nsec / 1000000
}

/// Wait on c.cv (lock held) for at most ms milliseconds.
fn wait_ms(c: raw.Ptr<abi.Chan>, ms: i64) uses raw, ffi {
  var now = cfacts.Timeval {}
  let _ = gettimeofday(raw.addr_of(&now), raw.null())
  let ns = i64(now.tv_usec) * 1000 + ms * 1000000
  var until = cfacts.Timespec { tv_sec: now.tv_sec + ns / 1000000000, tv_nsec: ns % 1000000000 }
  let _ = pthread_cond_timedwait(raw.field_addr(c, .cv), raw.field_addr(c, .lock), raw.addr_of(&until))
}

/// `c.recv_for(ms)` (ms < 0: `c.recv()`, no time limit): wait for a message and write a copy to
/// out; false once the channel is closed and empty, or when nothing came in time. Cancellable
/// on a task thread.
fn chan_recv(c: raw.Ptr<abi.Chan>, ms: i64, out: raw.Ptr<()>): bool uses raw, ffi {
  let end: i64 = if ms < 0 { 0 } else { now_ms() + ms }
  var tmp: abi.Tmp
  let buf = rc.auk__tmp_get(raw.addr_of(&tmp), c.size)
  let _ = pthread_mutex_lock(raw.field_addr(c, .lock))
  while true {
    if c.count > 0 {
      pop(c, buf)
      let _ = pthread_mutex_unlock(raw.field_addr(c, .lock))
      deliver(c, buf, out)
      rc.auk__tmp_done(raw.addr_of(&tmp))
      return true
    }
    let left: i64 = if ms < 0 { 50 } else { end - now_ms() }
    if c.closed || (ms >= 0 && left <= 0) {
      let _ = pthread_mutex_unlock(raw.field_addr(c, .lock))
      rc.auk__tmp_done(raw.addr_of(&tmp))
      return false
    }
    if task.auk__on_task() {
      let _ = pthread_mutex_unlock(raw.field_addr(c, .lock))
      task.auk__check_cancel("a channel receive")
      let _ = pthread_mutex_lock(raw.field_addr(c, .lock))
      wait_ms(c, if left < 50 { left } else { 50 })
    } else if ms < 0 {
      let _ = pthread_cond_wait(raw.field_addr(c, .cv), raw.field_addr(c, .lock))
    } else {
      wait_ms(c, if left < 50 { left } else { 50 })
    }
  }
  raw.unreachable()
  false
}

export fn auk_chan_recv(c: raw.Ptr<abi.Chan>, out: raw.Ptr<()>): bool uses raw, ffi = chan_recv(c, -1, out)

export fn auk_chan_recv_for(c: raw.Ptr<abi.Chan>, ms: i64, out: raw.Ptr<()>): bool uses raw, ffi =
  chan_recv(c, if ms < 0 { 0 } else { ms }, out)

/// `c.close()`: no more sends; receivers drain what is queued, then get none.
export fn auk_chan_close(c: raw.Ptr<abi.Chan>) uses raw, ffi {
  let _ = pthread_mutex_lock(raw.field_addr(c, .lock))
  c.closed = true
  let _ = pthread_mutex_unlock(raw.field_addr(c, .lock))
  let _ = pthread_cond_broadcast(raw.field_addr(c, .cv))
}

pub export fn auk__chan_free(c: raw.Ptr<abi.Chan>) uses raw, ffi {
  var i: i64 = 0
  while i < c.count {
    let release = c.ops.release
    if !release.is_null() {
      release(raw.cast(slot(c, i)))
    }
    i += 1
  }
  raw.free(c.items)
  let _ = pthread_mutex_destroy(raw.field_addr(c, .lock))
  let _ = pthread_cond_destroy(raw.field_addr(c, .cv))
  rc.auk__free_obj(raw.cast(c))
}

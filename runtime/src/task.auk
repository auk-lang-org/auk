/// Async tasks: one pthread per spawned task; await joins. (Was runtime/c/task.c, ported line by
/// line; `struct AukTask` is `abi.Task`.)
///
/// A task is linked to whoever awaits it: a panic on the task's thread ends only the task
/// (catch.auk), and `await` raises it again in the awaiter, where a `catch` can recover it. A
/// task that panicked and is dropped without being awaited ends the process, so no panic goes
/// unreported.
///
/// Cancelling a task is cooperative: `t.cancel()` sets a flag that the task checks at loop
/// back-edges (generated code reads auk_cancel_pending first, so loops pay one load while no task
/// is cancelled) and in blocking calls (sleep, await, net I/O wait in short slices). The check
/// panics "cancelled", and once a task is cancelled no `catch` inside it can keep it alive.
///
/// Tasks are linked to the tasks they start, as Erlang processes are: when a task ends with a
/// panic (a crash, or its own cancellation), every task it started that is still running is
/// cancelled, so a failed supervisor takes its whole subtree down. A normal end cancels nothing.
///
/// Every function here `uses raw`: a plain function of the runtime package with a loop would get
/// a cancellation point (a call to auk_cancel_check) at its back-edge.

// stack.auk's (not `pub` there: these resolve to its definitions)
extern fn auk__stack_thread_begin() = "void auk__stack_thread_begin(void)"
extern fn auk__stack_thread_end() = "void auk__stack_thread_end(void)"
extern fn auk__stack_attr(attr: raw.Ptr<()>, size: usize) = "void auk__stack_attr(void *, size_t)"
// the C library
extern fn c_strlen(s: raw.Ptr<u8>): usize = "size_t strlen(const char *)"
extern fn c_strerror(code: i32): raw.Ptr<u8> = "char *strerror(int)"
extern fn c_fflush(f: raw.Ptr<()>): i32 = "int fflush(void *)"
extern fn c_exit(code: i32): never = "void _exit(int)"
extern fn c_poll(fds: raw.Ptr<cfacts.Pollfd>, n: u32, ms: i32): i32 = "int poll(void *, unsigned int, int)"
extern fn c_nanosleep(req: raw.Ptr<cfacts.Timespec>, rem: raw.Ptr<cfacts.Timespec>): i32 = "int nanosleep(const void *, void *)"
extern fn gettimeofday(tv: raw.Ptr<cfacts.Timeval>, tz: raw.Ptr<()>): i32 = "int gettimeofday(void *, void *)"
extern fn pthread_create(th: raw.Ptr<cfacts.PthreadT>, attr: raw.Ptr<cfacts.PthreadAttr>, start: raw.Fn<(raw.Ptr<()>) => raw.Ptr<()>>, arg: raw.Ptr<()>): i32 =
  "int pthread_create(void *, const void *, void *, void *)"
// pthread_t by value: one word (a pointer on macOS, an unsigned long on Linux)
extern fn pthread_join(th: u64, ret: raw.Ptr<()>): i32 = "int pthread_join(uint64_t, void *)"
extern fn pthread_attr_destroy(attr: raw.Ptr<cfacts.PthreadAttr>): i32 = "int pthread_attr_destroy(void *)"
extern fn pthread_mutex_init(m: raw.Ptr<cfacts.PthreadMutex>, attr: raw.Ptr<()>): i32 =
  "int pthread_mutex_init(void *, const void *)"
extern fn pthread_mutex_destroy(m: raw.Ptr<cfacts.PthreadMutex>): i32 = "int pthread_mutex_destroy(void *)"
extern fn pthread_mutex_lock(m: raw.Ptr<cfacts.PthreadMutex>): i32 = "int pthread_mutex_lock(void *)"
extern fn pthread_mutex_unlock(m: raw.Ptr<cfacts.PthreadMutex>): i32 = "int pthread_mutex_unlock(void *)"
extern fn pthread_cond_broadcast(cv: raw.Ptr<cfacts.PthreadCond>): i32 = "int pthread_cond_broadcast(void *)"
extern fn pthread_cond_timedwait(cv: raw.Ptr<cfacts.PthreadCond>, m: raw.Ptr<cfacts.PthreadMutex>, until: raw.Ptr<cfacts.Timespec>): i32 =
  "int pthread_cond_timedwait(void *, void *, const void *)"

/// How many tasks are cancelled but still running: generated loops check a task's flag only
/// while this is non-zero.
export var auk_cancel_pending: i64 = 0

/// How many times `auk run --live` has swapped new code into this program (the driver bumps it
/// after each reload; 0 when not live).
export var auk__live_reloads: i64 = 0

/// The tasks whose code is running (for `auk run --live`: a reload that changes a type's layout
/// cancels the ones that use it). A task is on it from its start to its end, so a task on it
/// can't be freed while the list is locked.
raw var running_lock: cfacts.PthreadMutex = cfacts.PTHREAD_MUTEX_INITIALIZER
raw var running: raw.Ptr<raw.Ptr<abi.Task>> = raw.null()
raw var nrunning: i64 = 0
raw var caprunning: i64 = 0

/// Guards the cancel/done transitions; done_cv is signalled whenever a task finishes.
raw var state_lock: cfacts.PthreadMutex = cfacts.PTHREAD_MUTEX_INITIALIZER
raw var done_cv: cfacts.PthreadCond = cfacts.PTHREAD_COND_INITIALIZER
/// How long a blocking wait sleeps between cancel checks.
raw let SLICE_MS: i64 = 50

/// The task this thread runs (NULL on the main thread).
raw thread var cur_task: raw.Ptr<abi.Task> = raw.null()

// `_Atomic bool` fields: byte-wide atomics (sequentially consistent, as C's plain atomic_*)
fn is_done(t: raw.Ptr<abi.Task>): bool uses raw =
  raw.atomic_load(raw.cast<u8>(raw.field_addr(t, .done)), raw.Order.SeqCst) != 0

fn is_cancelled(t: raw.Ptr<abi.Task>): bool uses raw =
  raw.atomic_load(raw.cast<u8>(raw.field_addr(t, .cancel)), raw.Order.SeqCst) != 0

fn lock_running() uses raw, ffi {
  let _ = pthread_mutex_lock(raw.addr_of(&running_lock))
}

fn unlock_running() uses raw, ffi {
  let _ = pthread_mutex_unlock(raw.addr_of(&running_lock))
}

fn lock_state() uses raw, ffi {
  let _ = pthread_mutex_lock(raw.addr_of(&state_lock))
}

fn unlock_state() uses raw, ffi {
  let _ = pthread_mutex_unlock(raw.addr_of(&state_lock))
}

/// Cancel each running task that pick(ctx, entry, hint) selects (its thunk's address and its
/// closure hint); returns how many.
export fn auk__cancel_running(pick: raw.Fn<(raw.Ptr<()>, usize, usize) => bool>, ctx: raw.Ptr<()>): i64 uses raw, ffi {
  lock_running()
  var n: i64 = 0
  var i: i64 = 0
  while i < nrunning {
    let t = running.at(i)
    if pick(ctx, usize(raw.cast<()>(t.func).int()), t.hint) {
      auk_task_cancel(t)
      n += 1
    }
    i += 1
  }
  unlock_running()
  n
}

// ---- `auk run --live` in the self-hosted driver (compiler/src/live.auk), which can't pass a
// callback to C or store atomically: the same steps as auk__cancel_running and src/live.rs's
// `install`, split so the choice is made in Auk.

/// The (thunk address, closure hint) of each running task, as pairs into out (room for cap
/// pairs); returns how many tasks are running (more than cap: call again with more room).
export fn auk__live_running(out: raw.Ptr<i64>, cap: i64): i64 uses raw, ffi {
  lock_running()
  let n = nrunning
  var i: i64 = 0
  while i < nrunning && i < cap {
    let t = running.at(i)
    out.at(2 * i) = i64(raw.cast<()>(t.func).int())
    out.at(2 * i + 1) = i64(t.hint)
    i += 1
  }
  unlock_running()
  n
}

/// Cancel each running task whose (thunk address, closure hint) is one of the n pairs; returns
/// how many.
export fn auk__live_cancel(pairs: raw.Ptr<i64>, n: i64): i64 uses raw, ffi {
  lock_running()
  var k: i64 = 0
  var i: i64 = 0
  while i < nrunning {
    let t = running.at(i)
    var j: i64 = 0
    while j < n {
      if usize(pairs.at(2 * j)) == usize(raw.cast<()>(t.func).int()) && usize(pairs.at(2 * j + 1)) == t.hint {
        auk_task_cancel(t)
        k += 1
        break
      }
      j += 1
    }
    i += 1
  }
  unlock_running()
  k
}

/// Make a compiled module the current code: run its dk_init off any task's heap (what it makes
/// is the whole program's), then store each (slot, code address) of the n pairs into the live
/// table (a release store: the code's data is ready before a call can reach it).
export fn auk__live_install(init: raw.Fn<() => ()>, table: raw.Ptr<usize>, pairs: raw.Ptr<i64>, n: i64) uses raw, ffi {
  let old = heap.auk__heap_switch(raw.null())
  init()
  let _ = heap.auk__heap_switch(old)
  var i: i64 = 0
  while i < n {
    raw.atomic_store(table.offset(pairs.at(2 * i)), usize(pairs.at(2 * i + 1)), raw.Order.Release)
    i += 1
  }
}

/// Count a reload (`reloads()`).
export fn auk__live_reloaded() uses raw {
  let _ = raw.atomic_add(raw.addr_of(&auk__live_reloads), 1, raw.Order.SeqCst)
}

/// Has the task running on this thread been cancelled?
pub export fn auk__task_cancelled(): bool uses raw {
  let t = cur_task
  !t.is_null() && is_cancelled(t)
}

/// Is this thread a task's (so blocking calls must wake up to check for cancellation)?
pub export fn auk__on_task(): bool uses raw = !cur_task.is_null()

/// Panic "cancelled" if this thread's task was cancelled.
pub export fn auk__check_cancel(loc: raw.Ptr<u8>) uses raw, ffi {
  if auk__task_cancelled() {
    rc.auk__panic3(loc, "cancelled", raw.null(), raw.null())
  }
}

/// The loop back-edge check (called only while auk_cancel_pending is non-zero).
export fn auk_cancel_check(loc: raw.Ptr<u8>) uses raw, ffi = auk__check_cancel(loc)

/// Wait until fd is readable (or writable), waking every slice to check for cancellation. Off a
/// task thread it returns at once (the blocking call itself then waits).
export fn auk__wait_fd(fd: i32, write: bool) uses raw, ffi {
  if !auk__on_task() {
    return
  }
  while true {
    auk__check_cancel("a blocking call")
    var p = cfacts.Pollfd { fd, events: if write { cfacts.POLLOUT } else { cfacts.POLLIN } }
    if c_poll(raw.addr_of(&p), 1, i32(SLICE_MS)) != 0 {
      return
    }
  }
}

/// Sleep ms, in slices on a task thread so a cancel ends it early.
export fn auk__sleep_ms(ms: i64) uses raw, ffi {
  var left = ms
  while left > 0 {
    let step: i64 = if auk__on_task() && left > SLICE_MS { SLICE_MS } else { left }
    var ts = cfacts.Timespec { tv_sec: step / 1000, tv_nsec: (step % 1000) * 1000000 }
    while c_nanosleep(raw.addr_of(&ts), raw.addr_of(&ts)) < 0 && cfacts.errno() == cfacts.EINTR {
    }
    left -= step
    auk__check_cancel("a blocking call")
  }
}

fn running_add(t: raw.Ptr<abi.Task>) uses raw, ffi {
  lock_running()
  if nrunning == caprunning {
    caprunning = if caprunning == 0 { 16 } else { caprunning * 2 }
    running = raw.cast(rc.auk__xrealloc(raw.cast(running), usize(caprunning) * raw.size_of<raw.Ptr<abi.Task>>()))
  }
  running.at(nrunning) = t
  nrunning += 1
  unlock_running()
}

fn running_remove(t: raw.Ptr<abi.Task>) uses raw, ffi {
  lock_running()
  var k: i64 = 0
  var i: i64 = 0
  while i < nrunning {
    if running.at(i) != t {
      running.at(k) = running.at(i)
      k += 1
    }
    i += 1
  }
  nrunning = k
  unlock_running()
}

fn task_entry(p: raw.Ptr<()>): raw.Ptr<()> uses raw, ffi {
  let t: raw.Ptr<abi.Task> = raw.cast(p)
  auk__stack_thread_begin()
  cur_task = t
  let _ = heap.auk__heap_switch(raw.cast(t.heap))
  running_add(t)
  let pan = recover.auk__catch_call(t.func, t.args, t.result)
  if !pan.is_null() {
    t.panic = pan
    // the arguments' references (handles among them), then everything else the aborted code
    // left in the heap (nothing outside the heap points into it)
    let drop = t.args_drop
    if !drop.is_null() {
      drop(t.args)
    }
    let _ = heap.auk__heap_switch(raw.null())
    heap.auk__heap_sweep(raw.cast(t.heap))
    t.heap = raw.null()
  }
  let _ = heap.auk__heap_switch(raw.null())
  raw.free(t.args)
  t.args = raw.null()
  if !t.kids.is_null() {
    var i: i64 = 0
    while i < t.nkids {
      if !t.panic.is_null() {
        auk_task_cancel(t.kids.at(i))
      }
      rc.release(raw.cast(t.kids.at(i)))
      i += 1
    }
    raw.free(t.kids)
    t.kids = raw.null()
    t.nkids = 0
  }
  running_remove(t)
  lock_state()
  raw.atomic_store(raw.cast<u8>(raw.field_addr(t, .done)), 1, raw.Order.SeqCst)
  if is_cancelled(t) {
    let _ = raw.atomic_sub(raw.addr_of(&auk_cancel_pending), 1, raw.Order.SeqCst)
  }
  unlock_state()
  let _ = pthread_cond_broadcast(raw.addr_of(&done_cv))
  cur_task = raw.null()
  heap.auk__heap_thread_end()
  auk__stack_thread_end()
  raw.null()
}

/// `t.done()`: has the task finished (its result or panic is in)?
export fn auk_task_done(t: raw.Ptr<abi.Task>): bool uses raw = !t.is_null() && is_done(t)

export fn auk_live_reloads(): i64 uses raw = raw.atomic_load(raw.addr_of(&auk__live_reloads), raw.Order.SeqCst)

/// `t.cancel()`: see the top of the file. No effect on a finished task.
pub export fn auk_task_cancel(t: raw.Ptr<abi.Task>) uses raw, ffi {
  if t.is_null() {
    return
  }
  lock_state()
  if !is_done(t) && raw.atomic_swap(raw.cast<u8>(raw.field_addr(t, .cancel)), 1, raw.Order.SeqCst) == 0 {
    let _ = raw.atomic_add(raw.addr_of(&auk_cancel_pending), 1, raw.Order.SeqCst)
  }
  unlock_state()
}

/// Block until one of ts[0..n) is done (the lowest index wins); cancellable.
fn wait_any(ts: raw.Ptr<raw.Ptr<abi.Task>>, n: i64): i64 uses raw, ffi {
  lock_state()
  while true {
    var i: i64 = 0
    while i < n {
      if is_done(ts.at(i)) {
        unlock_state()
        return i
      }
      i += 1
    }
    if auk__task_cancelled() {
      unlock_state()
      auk__check_cancel("a blocking call")
      lock_state()
      continue
    }
    var now = cfacts.Timeval {}
    let _ = gettimeofday(raw.addr_of(&now), raw.null())
    let ns = i64(now.tv_usec) * 1000 + SLICE_MS * 1000000
    var until = cfacts.Timespec { tv_sec: now.tv_sec + ns / 1000000000, tv_nsec: ns % 1000000000 }
    let _ = pthread_cond_timedwait(raw.addr_of(&done_cv), raw.addr_of(&state_lock), raw.addr_of(&until))
  }
  raw.unreachable()
}

fn task_join(t: raw.Ptr<abi.Task>) uses raw, ffi {
  let _ = pthread_mutex_lock(raw.field_addr(t, .mu))
  if !t.joined {
    let _ = pthread_join(t.th.w0, raw.null())
    t.joined = true
  }
  let _ = pthread_mutex_unlock(raw.field_addr(t, .mu))
}

/// `await any ts`: wait for the first task of ts to finish and return its index. Its result goes
/// to out (as auk_task_await writes it), or, when it panicked, the panic goes to *perr as an
/// owned Err (the panic counts as seen).
export fn auk_task_await_any(ts: raw.Ptr<raw.Ptr<abi.Task>>, n: i64, out: raw.Ptr<()>, perr: raw.Ptr<raw.Ptr<abi.Err>>, loc: raw.Ptr<u8>): i64 uses raw, ffi {
  if n <= 0 {
    rc.auk__panic3(loc, "`await any` of an empty list", raw.null(), raw.null())
  }
  let i = wait_any(ts, n)
  let t = ts.at(i)
  task_join(t)
  if !t.panic.is_null() {
    t.observed = true
    perr.store(recover.auk__panic_err(t.panic))
  } else {
    auk_task_await(t, out)
  }
  i
}

export fn auk_task_spawn(
  func: raw.Fn<(raw.Ptr<()>, raw.Ptr<()>) => ()>,
  args: raw.Ptr<()>,
  args_size: usize,
  result_size: usize,
  result_ops: raw.Ptr<abi.ElemOps>,
  hp: raw.Ptr<()>,
  args_drop: raw.Fn<(raw.Ptr<()>) => ()>,
  hint: raw.Ptr<()>,
): raw.Ptr<abi.Task> uses raw, ffi {
  let t: raw.Ptr<abi.Task> = raw.cast(rc.auk__alloc(raw.size_of<abi.Task>(), abi.K_TASK))
  t.heap = hp
  t.args_drop = args_drop
  t.hint = usize(hint.int())
  let _ = pthread_mutex_init(raw.field_addr(t, .mu), raw.null())
  t.func = func
  t.args = rc.auk__xmalloc(args_size)
  if args_size != 0 {
    raw.copy(t.args, args, args_size)
  }
  t.result = rc.auk__xcalloc(1, if result_size != 0 { result_size } else { 1 })
  t.result_size = result_size
  t.ops = result_ops
  var attr = cfacts.PthreadAttr {}
  auk__stack_attr(raw.cast(raw.addr_of(&attr)), abi.TASK_STACK)
  // the link to the task that starts it (pruning the ones already finished)
  let parent = cur_task
  if !parent.is_null() {
    // the runtime's own references: not the task's (not on its heap's ledger)
    let old = heap.auk__heap_switch(raw.null())
    var k: i64 = 0
    var i: i64 = 0
    while i < parent.nkids {
      let kid = parent.kids.at(i)
      if is_done(kid) {
        rc.release(raw.cast(kid))
      } else {
        parent.kids.at(k) = kid
        k += 1
      }
      i += 1
    }
    parent.nkids = k
    if parent.nkids == parent.capkids {
      parent.capkids = if parent.capkids == 0 { 4 } else { parent.capkids * 2 }
      parent.kids = raw.cast(rc.auk__xrealloc(raw.cast(parent.kids), usize(parent.capkids) * raw.size_of<raw.Ptr<abi.Task>>()))
    }
    parent.kids.at(parent.nkids) = raw.cast(rc.retain(raw.cast(t)))
    parent.nkids += 1
    let _ = heap.auk__heap_switch(old)
  }
  let code = pthread_create(raw.field_addr(t, .th), raw.addr_of(&attr), raw.fn_of(task_entry), raw.cast(t))
  let _ = pthread_attr_destroy(raw.addr_of(&attr))
  if code != 0 {
    rc.auk__panic3("runtime", "could not start a task thread: ", c_strerror(code), raw.null())
  }
  t
}

pub export fn auk_task_await(t0: raw.Ptr<abi.Task>, out: raw.Ptr<()>) uses raw, ffi {
  var t = t0
  if auk__on_task() {
    let _ = wait_any(raw.addr_of(&t), 1)
  }
  task_join(t)
  if !t.panic.is_null() {
    // the link: the task's panic is raised again here, at its original location
    t.observed = true
    let pan = t.panic
    rc.auk__panic(pan.loc, pan.msg, c_strlen(pan.msg))
  }
  if !out.is_null() && t.result_size != 0 {
    // a deep copy into the awaiter's heap: the result stays in the task's
    if t.ops.is_null() {
      raw.copy(out, t.result, t.result_size)
    } else {
      copy.auk__copy_elem(t.ops, t.result, out)
    }
  }
}

export fn auk_task_join_all(ts: raw.Ptr<raw.Ptr<abi.Task>>, n: i64) uses raw, ffi {
  var i: i64 = 0
  while i < n {
    task_join(ts.at(i))
    i += 1
  }
}

export fn auk_task_await_all(ts: raw.Ptr<raw.Ptr<abi.Task>>, n: i64, outs: raw.Ptr<u8>) uses raw, ffi {
  auk_task_join_all(ts, n)
  var i: i64 = 0
  while i < n {
    let t = ts.at(i)
    let out: raw.Ptr<()> = if outs.is_null() { raw.null() } else { raw.cast(outs.offset(usize(i) * t.result_size)) }
    auk_task_await(t, out)
    i += 1
  }
}

pub export fn auk__task_free(t: raw.Ptr<abi.Task>) uses raw, ffi {
  task_join(t)
  if !t.panic.is_null() {
    let p = t.panic
    t.panic = raw.null()
    // a cancelled task's "cancelled" panic was asked for: not a crash to report
    if !t.observed && !is_cancelled(t) {
      // nobody awaited it: report it as an uncaught panic would be, and end the process
      let _ = c_fflush(cfacts.stdout())
      var m = abi.StrBuf {}
      let mp = raw.addr_of(&m)
      str.auk__sb_put_cstr(mp, "panic: ")
      str.auk__sb_put_cstr(mp, p.msg)
      str.auk__sb_put_cstr(mp, "\n  at ")
      str.auk__sb_put_cstr(mp, p.loc)
      str.auk__sb_put_cstr(mp, "\n  (in a task that was never awaited)\n")
      str_fmt.auk__sb_eprint(mp)
      let _ = c_fflush(cfacts.stderr())
      c_exit(101)
    }
    recover.auk__panic_free(p)
    // the result was never written: don't release it
    raw.free(t.result)
    let _ = pthread_mutex_destroy(raw.field_addr(t, .mu))
    rc.auk__free_obj(raw.cast(t))
    return
  }
  if !t.ops.is_null() {
    let release = t.ops.release
    if !release.is_null() {
      // as the task: the result's handle references are on its ledger
      let old = heap.auk__heap_switch(raw.cast(t.heap))
      release(t.result)
      let _ = heap.auk__heap_switch(old)
    }
  }
  // what is left of the task's heap: objects a `catch` inside it gave up on
  heap.auk__heap_sweep(raw.cast(t.heap))
  t.heap = raw.null()
  raw.free(t.result)
  let _ = pthread_mutex_destroy(raw.field_addr(t, .mu))
  rc.auk__free_obj(raw.cast(t))
}

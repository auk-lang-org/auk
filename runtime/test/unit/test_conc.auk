/// Concurrency stress tests (was runtime/c/test/test_conc.c): tasks (spawn, await, cancel,
/// links), channels with several senders and receivers, per-task heaps and their sweep,
/// reference counts on handles shared across threads, and the trace and debugger engines'
/// locks. They check results like the other tests, but are mostly there for `TSAN=1 sh
/// runtime/test/unit/run.sh conc` (ThreadSanitizer): each one makes threads meet in the
/// runtime's shared state as often as it can in a short run.

/// A task's arguments in a fresh heap, as generated code makes them: build(args) runs with the
/// heap current, so everything it allocates or retains is the task's.
fn heap_for(build: raw.Fn<(raw.Ptr<()>) => ()>, args: raw.Ptr<()>): raw.Ptr<()> uses ffi {
  let h = rt.auk_heap_new()
  let old = rt.auk_heap_switch(h)
  build(args)
  let _ = rt.auk_heap_switch(old)
  h
}

/// Run f(env) under a recovery point; the panic's message (kept), or null when none.
fn caught(f: raw.Fn<(raw.Ptr<()>, raw.Ptr<()>) => ()>, env: raw.Ptr<()>, out: raw.Ptr<()>): raw.Ptr<u8> uses raw, ffi {
  let e = rt.auk_catch(f, env, out)
  if e.is_null() { raw.null() } else { ut.err_text(e) }
}

/// Element i of an array of task pointers.
fn task_at(ts: raw.Ptr<raw.Ptr<abi.Task>>, i: i64): raw.Ptr<abi.Task> uses raw = ts.at(i)

// ---- tasks: spawn, await, cancel, links ----------------------------------------------------------

raw struct WorkArgs {
  /// 0 compute, 1 crash, 2 run until cancelled, 3 start kids then crash
  kind: i64,
  n: i64,
  tag: raw.Ptr<abi.Str>,
}

fn work_build(p: raw.Ptr<()>) uses raw, ffi {
  let a: raw.Ptr<WorkArgs> = raw.cast(p)
  a.tag = ut.s("w")
}

fn work_drop(p: raw.Ptr<()>) uses raw, ffi {
  let a: raw.Ptr<WorkArgs> = raw.cast(p)
  rt.auk_release(raw.cast(a.tag))
}

/// Allocate garbage in the current heap: a list of strings, some of it left for the sweep.
fn garbage(n: i64): raw.Ptr<abi.Arr> uses raw, ffi {
  var xs = rt.auk_arr_new(rt.OPS_STR, 0)
  var i: i64 = 0
  while i < n {
    var b = abi.StrBuf {}
    ut.sb_push(raw.addr_of(&b), "item ")
    rt.auk_sb_int(raw.addr_of(&b), i)
    var x = rt.auk_sb_finish(raw.addr_of(&b))
    rt.auk_arr_push(raw.addr_of(&xs), raw.cast(raw.addr_of(&x)))
    i += 1
  }
  xs
}

fn spin_thunk(args: raw.Ptr<()>, result: raw.Ptr<()>) uses raw, ffi {
  // until cancelled: a cancel check at a "back-edge" and a sleep (a blocking call)
  while true {
    if raw.atomic_load(rt.CANCEL_PENDING, raw.Order.SeqCst) != 0 {
      rt.auk_cancel_check("spin.auk:1:1")
    }
    rt.auk_time_sleep(1)
    let g = garbage(4)
    rt.auk_release(raw.cast(g))
  }
}

fn work_thunk(args: raw.Ptr<()>, result: raw.Ptr<()>) uses raw, ffi {
  let a: raw.Ptr<WorkArgs> = raw.cast(args)
  if a.kind == 0 {
    let g = garbage(a.n)
    var b = abi.StrBuf {}
    rt.auk_sb_str(raw.addr_of(&b), a.tag)
    rt.auk_sb_int(raw.addr_of(&b), rt.auk_arr_len(g))
    raw.cast<raw.Ptr<abi.Str>>(result).store(rt.auk_sb_finish(raw.addr_of(&b)))
    rt.auk_release(raw.cast(g))
  } else if a.kind == 1 {
    let _ = garbage(a.n) // left behind: the sweep frees it
    let _ = rt.auk_div(1, 0, "crash.auk:1:1")
  } else if a.kind == 2 {
    spin_thunk(args, result)
  } else {
    // two linked kids, never awaited: this task's crash cancels them, and its heap's ledger
    // gives back the references the abandoned frames held
    var i = 0
    while i < 2 {
      var k = WorkArgs { kind: 2 }
      let h = heap_for(raw.fn_of(work_build), raw.cast(raw.addr_of(&k)))
      let _ = rt.auk_task_spawn(
        raw.fn_of(work_thunk), raw.cast(raw.addr_of(&k)), raw.size_of<WorkArgs>(), raw.size_of<raw.Ptr<()>>(),
        rt.OPS_STR, h, raw.cast<()>(raw.fn_of(work_drop)), raw.null(),
      )
      i += 1
    }
    rt.auk_time_sleep(2)
    let _ = rt.auk_div(1, 0, "parent.auk:1:1")
  }
  rt.auk_release(raw.cast(a.tag))
}

raw struct AwaitEnv {
  t: raw.Ptr<abi.Task>,
}

fn await_thunk(env: raw.Ptr<()>, out: raw.Ptr<()>) uses raw, ffi {
  let e: raw.Ptr<AwaitEnv> = raw.cast(env)
  rt.auk_task_await(e.t, out)
}

/// Another thread cancelling and polling tasks while they run and finish.
raw struct Poker {
  ts: raw.Ptr<raw.Ptr<abi.Task>>,
  n: i64,
  /// C: _Atomic bool
  stop: u8,
}

fn poker(p: raw.Ptr<()>): raw.Ptr<()> uses raw, ffi {
  let k: raw.Ptr<Poker> = raw.cast(p)
  while raw.atomic_load(raw.field_addr(k, .stop), raw.Order.SeqCst) == 0 {
    var i: i64 = 0
    while i < k.n {
      if i % 4 == 2 {
        rt.auk_task_cancel(task_at(k.ts, i))
      }
      let _ = rt.auk_task_done(task_at(k.ts, i))
      i += 1
    }
  }
  raw.null()
}

raw struct Tasks12 {
  t: [raw.Ptr<abi.Task>; 12],
}

fn conc_tasks_spawn_await_cancel() uses raw, ffi {
  let n: i64 = 12
  var round = 0
  while round < 6 {
    var tsb: Tasks12
    let ts: raw.Ptr<raw.Ptr<abi.Task>> = raw.cast(raw.addr_of(&tsb))
    var i: i64 = 0
    while i < n {
      var a = WorkArgs { kind: i % 4, n: 50 + i }
      let h = heap_for(raw.fn_of(work_build), raw.cast(raw.addr_of(&a)))
      ts.at(i) = rt.auk_task_spawn(
        raw.fn_of(work_thunk), raw.cast(raw.addr_of(&a)), raw.size_of<WorkArgs>(), raw.size_of<raw.Ptr<()>>(),
        rt.OPS_STR, h, raw.cast<()>(raw.fn_of(work_drop)), raw.null(),
      )
      i += 1
    }
    var k = Poker { ts: ts, n: n, stop: 0 }
    var th = cfacts.PthreadT {}
    let _ = rt.pthread_create(raw.addr_of(&th), raw.null(), raw.fn_of(poker), raw.cast(raw.addr_of(&k)))
    // the first to finish, while the others are still running
    var first: raw.Ptr<abi.Str> = raw.null()
    var ferr: raw.Ptr<abi.Err> = raw.null()
    let w = rt.auk_task_await_any(ts, n, raw.cast(raw.addr_of(&first)), raw.addr_of(&ferr), "any.auk:1:1")
    ut.check(w >= 0 && w < n, "w >= 0 && w < N")
    if !ferr.is_null() {
      ut.rel(raw.cast(ferr))
    }
    if !first.is_null() {
      ut.rel(raw.cast(first))
    }
    i = 0
    while i < n {
      if i % 4 == 2 {
        rt.auk_task_cancel(ts.at(i))
      }
      var r: raw.Ptr<abi.Str> = raw.null()
      var env = AwaitEnv { t: ts.at(i) }
      let msg = caught(raw.fn_of(await_thunk), raw.cast(raw.addr_of(&env)), raw.cast(raw.addr_of(&r)))
      let kind = i % 4
      if kind == 0 {
        ut.check(msg.is_null(), "msg == NULL")
        let want = ut.scratch(32)
        let _ = rt.snprintf(want, 32, "w%d", i32(50 + i))
        ut.str_eq(r, want, "r")
      } else if kind == 1 || kind == 3 {
        ut.check(!msg.is_null(), "msg != NULL")
        ut.has(msg, "division by zero", "msg")
      } else {
        ut.check(!msg.is_null(), "msg != NULL")
        ut.has(msg, "cancelled", "msg")
      }
      i += 1
    }
    raw.atomic_store(raw.field_addr(raw.addr_of(&k), .stop), u8(1), raw.Order.SeqCst)
    let _ = rt.pthread_join(th.w0, raw.null())
    i = 0
    while i < n {
      ut.rel(raw.cast(ts.at(i)))
      i += 1
    }
    round += 1
  }
  ut.eq(raw.atomic_load(rt.CANCEL_PENDING, raw.Order.SeqCst), 0, "atomic_load(&auk_cancel_pending)")
}

/// A swept heap whose objects hold each other: the strings were allocated after the lists that
/// hold them (so they come first on the heap's list and are swept first), and freeing a list
/// releases its strings, which must still be there to release.
fn heap_sweep_containers() uses raw, ffi {
  let live0 = rt.auk_live_objects()
  let h = rt.auk_heap_new()
  let old = rt.auk_heap_switch(h)
  var inner = garbage(20)
  var outer = rt.auk_arr_new(rt.OPS_ARR, 0)
  rt.auk_arr_push(raw.addr_of(&outer), raw.cast(raw.addr_of(&inner)))
  let _ = rt.auk_heap_switch(old)
  rt.auk__heap_sweep(h)
  ut.eq(rt.auk_live_objects(), live0, "auk_live_objects()")
}

// ---- tasks released (and their heaps swept) on other threads ----------------------------------

raw struct ReapArgs {
  victim: raw.Ptr<abi.Task>,
}

/// Await (or not) a task started elsewhere and release it here: the victim's heap is swept on
/// this thread while other tasks allocate in theirs.
fn reap_thunk(args: raw.Ptr<()>, result: raw.Ptr<()>) uses raw, ffi {
  let a: raw.Ptr<ReapArgs> = raw.cast(args)
  var r: raw.Ptr<abi.Str> = raw.null()
  var env = AwaitEnv { t: a.victim }
  let e = rt.auk_catch(raw.fn_of(await_thunk), raw.cast(raw.addr_of(&env)), raw.cast(raw.addr_of(&r)))
  raw.cast<i64>(result).store(if e.is_null() { 1 } else { 2 })
  if !e.is_null() {
    rt.auk_release(raw.cast(e))
  }
  if !r.is_null() {
    rt.auk_release(raw.cast(r))
  }
  rt.auk_release(raw.cast(a.victim))
}

raw struct Tasks16 {
  t: [raw.Ptr<abi.Task>; 16],
}

raw struct Ints16 {
  x: [i64; 16],
}

fn conc_heap_sweep_elsewhere() uses raw, ffi {
  let n: i64 = 16
  var vb: Tasks16
  var rb: Tasks16
  let victims: raw.Ptr<raw.Ptr<abi.Task>> = raw.cast(raw.addr_of(&vb))
  let reapers: raw.Ptr<raw.Ptr<abi.Task>> = raw.cast(raw.addr_of(&rb))
  var i: i64 = 0
  while i < n {
    var a = WorkArgs { kind: i % 2, n: 200 }
    let h = heap_for(raw.fn_of(work_build), raw.cast(raw.addr_of(&a)))
    victims.at(i) = rt.auk_task_spawn(
      raw.fn_of(work_thunk), raw.cast(raw.addr_of(&a)), raw.size_of<WorkArgs>(), raw.size_of<raw.Ptr<()>>(),
      rt.OPS_STR, h, raw.cast<()>(raw.fn_of(work_drop)), raw.null(),
    )
    i += 1
  }
  i = 0
  while i < n {
    var r = ReapArgs { victim: victims.at(i) } // the reaper owns the victim now
    reapers.at(i) = rt.auk_task_spawn(
      raw.fn_of(reap_thunk), raw.cast(raw.addr_of(&r)), raw.size_of<ReapArgs>(), 8, raw.null(), raw.null(), raw.null(),
      raw.null(),
    )
    i += 1
  }
  var ob = Ints16 {}
  let outs: raw.Ptr<i64> = raw.cast(raw.addr_of(&ob))
  rt.auk_task_await_all(reapers, n, raw.cast(outs))
  i = 0
  while i < n {
    ut.eq(outs.at(i), if i % 2 == 0 { 1 } else { 2 }, "outs[i]")
    ut.rel(raw.cast(reapers.at(i)))
    i += 1
  }
}

// ---- channels ------------------------------------------------------------------------------------

raw struct ChanArgs {
  c: raw.Ptr<abi.Chan>,
  id: i64,
  n: i64,
  /// a sender that crashes after this many sends (-1: never)
  crash_at: i64,
  /// a receiver using recv_for(wait_ms) (-1: recv)
  wait_ms: i64,
}

/// the channel reference a task gets in its arguments (on its heap's ledger)
fn chan_build(p: raw.Ptr<()>) uses raw, ffi {
  let a: raw.Ptr<ChanArgs> = raw.cast(p)
  let _ = rt.auk_retain(raw.cast(a.c))
}

fn chan_drop(p: raw.Ptr<()>) uses raw, ffi {
  let a: raw.Ptr<ChanArgs> = raw.cast(p)
  rt.auk_release(raw.cast(a.c))
}

fn send_thunk(args: raw.Ptr<()>, result: raw.Ptr<()>) uses raw, ffi {
  let a: raw.Ptr<ChanArgs> = raw.cast(args)
  var i: i64 = 0
  while i < a.n {
    if i == a.crash_at {
      let _ = rt.auk_div(1, 0, "sender.auk:1:1")
    }
    var b = abi.StrBuf {}
    rt.auk_sb_int(raw.addr_of(&b), a.id * 100000 + i)
    var x = rt.auk_sb_finish(raw.addr_of(&b))
    rt.auk_chan_send(a.c, raw.cast(raw.addr_of(&x)), "send.auk:1:1")
    rt.auk_release(raw.cast(x))
    i += 1
  }
  raw.cast<i64>(result).store(a.n)
  rt.auk_release(raw.cast(a.c))
}

/// Receive until the channel is closed and empty: the count and the sum of the numbers.
raw struct RecvOut {
  count: i64,
  sum: i64,
}

fn recv_thunk(args: raw.Ptr<()>, result: raw.Ptr<()>) uses raw, ffi {
  let a: raw.Ptr<ChanArgs> = raw.cast(args)
  var o = RecvOut { count: 0, sum: 0 }
  while true {
    var x: raw.Ptr<abi.Str> = raw.null()
    var got = false
    if a.wait_ms >= 0 {
      got = rt.auk_chan_recv_for(a.c, a.wait_ms, raw.cast(raw.addr_of(&x)))
      if !got {
        // nothing in time: closed and empty ends it, otherwise wait again
        var y: raw.Ptr<abi.Str> = raw.null()
        if !rt.auk_chan_recv_for(a.c, 0, raw.cast(raw.addr_of(&y))) {
          var z: raw.Ptr<abi.Str> = raw.null()
          got = rt.auk_chan_recv(a.c, raw.cast(raw.addr_of(&z)))
          if !got {
            break
          }
          x = z
        } else {
          x = y
          got = true
        }
      }
    } else {
      got = rt.auk_chan_recv(a.c, raw.cast(raw.addr_of(&x)))
      if !got {
        break
      }
    }
    o.count += 1
    o.sum += rt.atoll(rt.auk_str_cstr(x))
    rt.auk_release(raw.cast(x))
  }
  raw.cast<RecvOut>(result).store(o)
  rt.auk_release(raw.cast(a.c))
}

raw struct Tasks5 {
  t: [raw.Ptr<abi.Task>; 5],
}

raw struct Tasks4 {
  t: [raw.Ptr<abi.Task>; 4],
}

fn spawn_chan_task(thunk: raw.Fn<(raw.Ptr<()>, raw.Ptr<()>) => ()>, a: raw.Ptr<ChanArgs>, result_size: usize): raw.Ptr<abi.Task> uses raw, ffi {
  let h = heap_for(raw.fn_of(chan_build), raw.cast(a))
  rt.auk_task_spawn(thunk, raw.cast(a), raw.size_of<ChanArgs>(), result_size, raw.null(), h, raw.cast<()>(raw.fn_of(chan_drop)), raw.null())
}

fn conc_chan_many_senders_receivers() uses raw, ffi {
  let ns: i64 = 4
  let nr: i64 = 4
  let per: i64 = 300
  let proto = rt.auk_arr_new(rt.OPS_STR, 0)
  let c = rt.auk_chan_new(proto)
  ut.rel(raw.cast(proto))
  var sb: Tasks5
  var rb: Tasks4
  let senders: raw.Ptr<raw.Ptr<abi.Task>> = raw.cast(raw.addr_of(&sb))
  let receivers: raw.Ptr<raw.Ptr<abi.Task>> = raw.cast(raw.addr_of(&rb))
  var i: i64 = 0
  while i < nr {
    var a = ChanArgs { c: c, id: i, n: 0, crash_at: -1, wait_ms: if i % 2 == 0 { -1 } else { 1 } }
    receivers.at(i) = spawn_chan_task(raw.fn_of(recv_thunk), raw.addr_of(&a), raw.size_of<RecvOut>())
    i += 1
  }
  var want_sum: i64 = 0
  i = 0
  while i < ns {
    var a = ChanArgs { c: c, id: i + 1, n: per, crash_at: -1, wait_ms: -1 }
    senders.at(i) = spawn_chan_task(raw.fn_of(send_thunk), raw.addr_of(&a), 8)
    var k: i64 = 0
    while k < per {
      want_sum += (i + 1) * 100000 + k
      k += 1
    }
    i += 1
  }
  // a sender that crashes halfway: its reference to the channel comes back through the sweep of
  // its heap's ledger
  var a9 = ChanArgs { c: c, id: 9, n: per, crash_at: per / 2, wait_ms: -1 }
  senders.at(ns) = spawn_chan_task(raw.fn_of(send_thunk), raw.addr_of(&a9), 8)
  var k: i64 = 0
  while k < per / 2 {
    want_sum += 9 * 100000 + k
    k += 1
  }
  i = 0
  while i < ns {
    var n: i64 = 0
    rt.auk_task_await(senders.at(i), raw.cast(raw.addr_of(&n)))
    ut.eq(n, per, "n")
    i += 1
  }
  var dummy: i64 = 0
  var env = AwaitEnv { t: senders.at(ns) }
  let msg = caught(raw.fn_of(await_thunk), raw.cast(raw.addr_of(&env)), raw.cast(raw.addr_of(&dummy)))
  ut.check(!msg.is_null(), "msg != NULL")
  rt.auk_chan_close(c)
  var total = RecvOut { count: 0, sum: 0 }
  i = 0
  while i < nr {
    var o = RecvOut { count: 0, sum: 0 }
    rt.auk_task_await(receivers.at(i), raw.cast(raw.addr_of(&o)))
    total.count += o.count
    total.sum += o.sum
    i += 1
  }
  ut.eq(total.count, ns * per + per / 2, "total.count")
  ut.eq(total.sum, want_sum, "total.sum")
  i = 0
  while i <= ns {
    ut.rel(raw.cast(senders.at(i)))
    i += 1
  }
  i = 0
  while i < nr {
    ut.rel(raw.cast(receivers.at(i)))
    i += 1
  }
  ut.eq(rt.auk_refcount(raw.cast(c)), 1, "auk_refcount(c)")
  ut.rel(raw.cast(c))
}

// ---- reference counts on shared handles and untracked objects --------------------------------------

raw struct RcArgs {
  /// a handle: retains go on each task's ledger
  c: raw.Ptr<abi.Chan>,
  /// an untracked string shared by reference (a task without a heap)
  s: raw.Ptr<abi.Str>,
}

fn rc_thunk(args: raw.Ptr<()>, result: raw.Ptr<()>) uses raw, ffi {
  let a: raw.Ptr<RcArgs> = raw.cast(args)
  var i = 0
  while i < 2000 {
    let _ = rt.auk_retain(raw.cast(a.c))
    let _ = rt.auk_retain(raw.cast(a.s))
    rt.auk_release(raw.cast(a.s))
    rt.auk_release(raw.cast(a.c))
    i += 1
  }
  raw.cast<i64>(result).store(rt.auk_str_len(a.s))
}

raw struct Tasks8 {
  t: [raw.Ptr<abi.Task>; 8],
}

raw struct Ints8 {
  x: [i64; 8],
}

fn conc_rc_shared_handles() uses raw, ffi {
  let n: i64 = 8
  let proto = rt.auk_arr_new(rt.OPS_INT, 0)
  let c = rt.auk_chan_new(proto)
  ut.rel(raw.cast(proto))
  let shared = ut.s("shared")
  var tb: Tasks8
  let ts: raw.Ptr<raw.Ptr<abi.Task>> = raw.cast(raw.addr_of(&tb))
  var i: i64 = 0
  while i < n {
    var a = RcArgs { c: c, s: shared }
    // half with heaps of their own (ledgers), half on the untracked heap
    let h: raw.Ptr<()> = if i % 2 == 0 { rt.auk_heap_new() } else { raw.null() }
    ts.at(i) = rt.auk_task_spawn(raw.fn_of(rc_thunk), raw.cast(raw.addr_of(&a)), raw.size_of<RcArgs>(), 8, raw.null(), h, raw.null(), raw.null())
    i += 1
  }
  var ob: Ints8
  let outs: raw.Ptr<i64> = raw.cast(raw.addr_of(&ob))
  rt.auk_task_await_all(ts, n, raw.cast(outs))
  i = 0
  while i < n {
    ut.eq(outs.at(i), 6, "outs[i]")
    ut.rel(raw.cast(ts.at(i)))
    i += 1
  }
  ut.eq(rt.auk_refcount(raw.cast(c)), 1, "auk_refcount(c)")
  ut.eq(rt.auk_refcount(raw.cast(shared)), 1, "auk_refcount(str)")
  ut.rel(raw.cast(c))
  ut.rel(raw.cast(shared))
}

// ---- the trace's lock -------------------------------------------------------------------------------

fn trace_thunk(args: raw.Ptr<()>, result: raw.Ptr<()>) uses raw, ffi {
  let id = raw.cast<i64>(args).load()
  let name: raw.Ptr<u8> = if id % 2 == 0 { "even.f" } else { "odd.f" }
  var i = 0
  while i < 200 {
    if rt.auk_trace_begin() {
      var argv = ut.s("1")
      rt.auk_trace_call(name, "t.auk:1:1", 1, raw.addr_of(&argv))
    }
    let v = ut.s("v")
    rt.auk_peek("t.auk:2:2", "x", v)
    rt.auk_release(raw.cast(v))
    if rt.auk_trace_exit() {
      rt.auk_trace_ret(name, ut.s("2"))
    }
    i += 1
  }
  if id == 0 {
    let _ = rt.auk_div(1, 0, "t.auk:3:3") // a caught panic: an event and a flush
  }
  raw.cast<i64>(result).store(id)
}

raw struct Tasks6 {
  t: [raw.Ptr<abi.Task>; 6],
}

fn trace_child(ctx: raw.Ptr<()>) uses raw, ffi {
  let path: raw.Ptr<u8> = raw.cast(ctx)
  let _ = rt.setenv("AUK_TRACE", path, 1)
  let _ = rt.setenv("AUK_TRACE_LIMIT", "1000000", 1)
  rt.auk_trace_init(false)
  let n: i64 = 6
  var tb: Tasks6
  let ts: raw.Ptr<raw.Ptr<abi.Task>> = raw.cast(raw.addr_of(&tb))
  var i: i64 = 0
  while i < n {
    ts.at(i) = rt.auk_task_spawn(raw.fn_of(trace_thunk), raw.cast(raw.addr_of(&i)), 8, 8, raw.null(), raw.null(), raw.null(), raw.null())
    i += 1
  }
  i = 0
  while i < n {
    var r: i64 = 0
    var env = AwaitEnv { t: ts.at(i) }
    let m = caught(raw.fn_of(await_thunk), raw.cast(raw.addr_of(&env)), raw.cast(raw.addr_of(&r)))
    ut.check(!m.is_null() == (i == 0), "(m != NULL) == (i == 0)")
    ut.rel(raw.cast(ts.at(i)))
    i += 1
  }
  rt.auk__trace_flush()
}

raw struct Line {
  b: [u8; 512],
}

fn conc_trace_threads() uses raw, ffi {
  let dir = ut.tmpdir_new()
  let n = rt.strlen(dir) + 32
  let path = ut.scratch(n)
  let _ = rt.snprintf(path, n, "%s/trace.jsonl", dir)
  var out: raw.Ptr<u8> = raw.null()
  let code = ut.child(raw.fn_of(trace_child), raw.cast(path), raw.addr_of(&out))
  if code != 0 {
    let m = ut.scratch(rt.strlen(out) + 64)
    let _ = rt.snprintf(m, rt.strlen(out) + 64, "child exited %d:\n%s", code, out)
    ut.fail(m)
  }
  let f = rt.fopen(path, "r")
  ut.check(!f.is_null(), "f != NULL")
  var calls: i64 = 0
  var rets: i64 = 0
  var panics: i64 = 0
  var lb: Line
  let line: raw.Ptr<u8> = raw.cast(raw.addr_of(&lb))
  while !rt.fgets(line, 512, f).is_null() {
    if !rt.strstr(line, "\"ev\":\"call\"").is_null() {
      calls += 1
    }
    if !rt.strstr(line, "\"ev\":\"ret\"").is_null() {
      rets += 1
    }
    if !rt.strstr(line, "\"ev\":\"panic\"").is_null() {
      panics += 1
    }
  }
  let _ = rt.fclose(f)
  ut.eq(calls, 6 * 200, "calls")
  ut.eq(rets, 6 * 200, "rets")
  ut.eq(panics, 2, "panics") // in the task, and again where it is awaited
}

// ---- the debugger's lock: all-stop with threads running, sleeping and stopping -------------------

/// Debug info for one function `f` with one site per line 1..4 (see parse_info in the debugger).
fn dbg_info(): raw.Ptr<u8> = "p t.auk\nf f\ns 0 0 1 1 \ns 0 0 2 1 \ns 0 0 3 1 \ns 0 0 4 1 \n"

/// set when the front end is done: the workers run until then, so a pause always finds one
/// (C: _Atomic bool)
raw var fe_done: u8 = 0

fn dbg_worker(args: raw.Ptr<()>, result: raw.Ptr<()>) uses raw, ffi {
  var n: i64 = 0
  var i: i64 = 0
  while raw.atomic_load(raw.addr_of(&fe_done), raw.Order.SeqCst) == 0 {
    n += 1
    var f = abi.DbgFrame {}
    let fp = raw.addr_of(&f)
    rt.auk_dbg_enter(fp)
    var site: i64 = 0
    while site < 4 {
      // generated code's one aligned 8-byte store (the debugger reads it relaxed)
      raw.atomic_store(raw.field_addr(fp, .site), site, raw.Order.Relaxed)
      if raw.atomic_load(rt.DBG_ARMED, raw.Order.SeqCst) != 0 {
        rt.auk_dbg_hook(fp)
      }
      // a blocking call: the thread may be "running" while another one is stopped
      if site == 2 && i % 8 == 0 {
        rt.auk_time_sleep(1)
      }
      site += 1
    }
    rt.auk_dbg_leave(fp)
    i += 1
  }
  raw.cast<i64>(result).store(n)
}

/// Read one line from fd into buf (NUL-terminated, without the newline); false at EOF.
fn read_line(fd: i32, buf: raw.Ptr<u8>, cap: usize): bool uses raw, ffi {
  var n: usize = 0
  while true {
    var ch: u8 = 0
    let r = rt.c_read(fd, raw.cast(raw.addr_of(&ch)), 1)
    if r < 0 && cfacts.errno() == cfacts.EINTR {
      continue
    }
    if r <= 0 {
      return false
    }
    if ch == 10 {
      break
    }
    if n + 1 < cap {
      buf.at(n) = ch
      n += 1
    }
  }
  buf.at(n) = 0
  true
}

fn say(fd: i32, cmd: raw.Ptr<u8>) uses raw, ffi {
  let n = rt.strlen(cmd)
  let nl: raw.Ptr<u8> = "\n"
  if rt.c_write(fd, raw.cast(cmd), n) != i64(n) || rt.c_write(fd, raw.cast(nl), 1) != 1 {
    ut.fail("write to the program failed")
  }
}

/// A "stopped" event was read (and skipped) while waiting for something else: the program is
/// stopped now, and a `pause` would be ignored.
raw var stop_seen: bool = false

raw struct EvLine {
  b: [u8; 8192],
}

/// Wait for an event containing want (skipping others, noting a stop among them).
fn expect_ev(fd: i32, want: raw.Ptr<u8>) uses raw, ffi {
  var lb: EvLine
  let line: raw.Ptr<u8> = raw.cast(raw.addr_of(&lb))
  while true {
    if !read_line(fd, line, 8192) {
      let m = ut.scratch(256)
      let _ = rt.snprintf(m, 256, "connection closed waiting for %s", want)
      ut.fail(m)
    }
    let stopped = !rt.strstr(line, "\"ev\":\"stopped\"").is_null()
    if !rt.strstr(line, want).is_null() {
      if stopped {
        stop_seen = false
      }
      return
    }
    if stopped {
      stop_seen = true
    }
  }
}

raw struct FrontEnd {
  listener: i32,
  rounds: i32,
}

raw struct Cmd {
  b: [u8; 64],
}

/// The front end: run, then pause / inspect every thread / continue, round after round, with a
/// breakpoint for part of it; then hang up (the program runs on).
fn front_end(p: raw.Ptr<()>): raw.Ptr<()> uses raw, ffi {
  let fe: raw.Ptr<FrontEnd> = raw.cast(p)
  let fd = rt.accept(fe.listener, raw.null(), raw.null())
  if fd < 0 {
    ut.fail("accept failed")
  }
  expect_ev(fd, "\"ready\"")
  say(fd, "run")
  expect_ev(fd, "\"ok\"")
  var r: i32 = 0
  while r < fe.rounds {
    if r == fe.rounds / 2 {
      say(fd, "@1 break t.auk:3")
      expect_ev(fd, "\"seq\":1")
    }
    if r == fe.rounds * 3 / 4 {
      say(fd, "@2 delete")
      expect_ev(fd, "\"seq\":2")
    }
    if !stop_seen {
      say(fd, "pause")
      expect_ev(fd, "\"stopped\"")
    }
    say(fd, "@3 threads")
    expect_ev(fd, "\"seq\":3")
    var t: i32 = 1
    while t <= 6 {
      var cb: Cmd
      let cmd: raw.Ptr<u8> = raw.cast(raw.addr_of(&cb))
      let _ = rt.snprintf(cmd, 64, "@4 stack %d", t)
      say(fd, cmd)
      expect_ev(fd, "\"seq\":4")
      t += 1
    }
    let next: raw.Ptr<u8> = if r % 3 == 0 { "step" } else { "continue" }
    say(fd, next)
    stop_seen = false
    r += 1
  }
  raw.atomic_store(raw.addr_of(&fe_done), u8(1), raw.Order.SeqCst)
  let _ = rt.close(fd)
  raw.null()
}

raw struct Tasks4b {
  t: [raw.Ptr<abi.Task>; 4],
}

fn dbg_child(ctx: raw.Ptr<()>) uses raw, ffi {
  let path: raw.Ptr<u8> = raw.cast(ctx)
  let l = rt.socket(cfacts.AF_UNIX, cfacts.SOCK_STREAM, 0)
  var addr: cfacts.SockaddrUn
  let ap = raw.addr_of(&addr)
  raw.fill(raw.cast<u8>(ap), 0, raw.size_of<cfacts.SockaddrUn>())
  // sun_family is a u8 on macOS (after sun_len), a u16 on Linux
  if raw.offset_of<cfacts.SockaddrUn>(.sun_family) == 1 {
    raw.cast<u8>(raw.field_addr(ap, .sun_family)).store(u8(cfacts.AF_UNIX))
  } else {
    raw.cast<u16>(raw.field_addr(ap, .sun_family)).store(u16(cfacts.AF_UNIX))
  }
  let sun_path: raw.Ptr<u8> = raw.cast(raw.field_addr(ap, .sun_path))
  let room = raw.size_of<cfacts.SockaddrUn>() - raw.offset_of<cfacts.SockaddrUn>(.sun_path)
  let _ = rt.snprintf(sun_path, room, "%s", path)
  if l < 0 || rt.bind(l, raw.cast(ap), u32(raw.size_of<cfacts.SockaddrUn>())) != 0 || rt.listen(l, 1) != 0 {
    let m = ut.scratch(rt.strlen(path) + 64)
    let _ = rt.snprintf(m, rt.strlen(path) + 64, "listen on %s failed", path)
    ut.fail(m)
  }
  var fe = FrontEnd { listener: l, rounds: 30 }
  var th = cfacts.PthreadT {}
  let _ = rt.pthread_create(raw.addr_of(&th), raw.null(), raw.fn_of(front_end), raw.cast(raw.addr_of(&fe)))
  let _ = rt.setenv("AUK_DEBUG", path, 1)
  rt.auk_dbg_init(dbg_info(), raw.null(), raw.null())
  let n: i64 = 4
  var tb: Tasks4b
  let ts: raw.Ptr<raw.Ptr<abi.Task>> = raw.cast(raw.addr_of(&tb))
  var i: i64 = 0
  while i < n {
    ts.at(i) = rt.auk_task_spawn(raw.fn_of(dbg_worker), raw.null(), 0, 8, raw.null(), raw.null(), raw.null(), raw.null())
    i += 1
  }
  var mine: i64 = 0
  dbg_worker(raw.null(), raw.cast(raw.addr_of(&mine)))
  let _ = rt.pthread_join(th.w0, raw.null())
  i = 0
  while i < n {
    var r: i64 = 0
    rt.auk_task_await(ts.at(i), raw.cast(raw.addr_of(&r)))
    ut.check(r > 0, "r > 0")
    ut.rel(raw.cast(ts.at(i)))
    i += 1
  }
  let _ = rt.close(l)
}

fn conc_dbg_all_stop() uses raw, ffi {
  let dir = ut.tmpdir_new()
  let n = rt.strlen(dir) + 32
  let path = ut.scratch(n)
  let _ = rt.snprintf(path, n, "%s/d.sock", dir)
  var out: raw.Ptr<u8> = raw.null()
  let code = ut.child(raw.fn_of(dbg_child), raw.cast(path), raw.addr_of(&out))
  if code != 0 {
    let m = ut.scratch(rt.strlen(out) + 64)
    let _ = rt.snprintf(m, rt.strlen(out) + 64, "child exited %d:\n%s", code, out)
    ut.fail(m)
  }
}

/// The tests, in the C file's order.
pub fn all() uses raw, ffi {
  ut.run("conc_tasks_spawn_await_cancel", raw.fn_of(conc_tasks_spawn_await_cancel))
  ut.run("heap_sweep_containers", raw.fn_of(heap_sweep_containers))
  ut.run("conc_heap_sweep_elsewhere", raw.fn_of(conc_heap_sweep_elsewhere))
  ut.run("conc_chan_many_senders_receivers", raw.fn_of(conc_chan_many_senders_receivers))
  ut.run("conc_rc_shared_handles", raw.fn_of(conc_rc_shared_handles))
  ut.run("conc_trace_threads", raw.fn_of(conc_trace_threads))
  ut.run("conc_dbg_all_stop", raw.fn_of(conc_dbg_all_stop))
}

/// Evaluating Auk expressions at a debugger stop (was the "evaluating Auk expressions" part of
/// runtime/c/dbg.c, ported line by line): the eval hook and its mailbox (served by the
/// compiler's compiler/src/dbg_eval.auk), the cache of compiled expressions, running one under a
/// recovery point; and the Ctrl-C flag of a front end written in Auk. dbg.auk is the engine.

extern fn pthread_mutex_lock(m: raw.Ptr<cfacts.PthreadMutex>): i32 = "int pthread_mutex_lock(void *)"
extern fn pthread_mutex_unlock(m: raw.Ptr<cfacts.PthreadMutex>): i32 = "int pthread_mutex_unlock(void *)"
extern fn pthread_cond_broadcast(cv: raw.Ptr<cfacts.PthreadCond>): i32 = "int pthread_cond_broadcast(void *)"
extern fn pthread_cond_wait(cv: raw.Ptr<cfacts.PthreadCond>, m: raw.Ptr<cfacts.PthreadMutex>): i32 =
  "int pthread_cond_wait(void *, void *)"
extern fn strcmp(a: raw.Ptr<u8>, b: raw.Ptr<u8>): i32 = "int strcmp(const char *, const char *)"
extern fn signal(sig: i32, handler: raw.Ptr<()>): raw.Ptr<()> = "void *signal(int, void *)"

/// C: AukDbgEvalHook. Compile expr at site of debug function func: true with *out, or false
/// with *err (malloc'd strings and arrays, kept).
pub raw type EvalHook = raw.Fn<(u32, u32, raw.Ptr<u8>, raw.Ptr<abi.DbgCompiled>, raw.Ptr<raw.Ptr<u8>>) => bool>

/// The hook (an EvalHook; null: none).
raw var eval_hook: raw.Ptr<()> = raw.null()

raw struct Eval {
  site: u32,
  expr: raw.Ptr<u8>,
  ok: bool,
  c: abi.DbgCompiled,
  err: raw.Ptr<u8>,
}

raw var evals_lock: cfacts.PthreadMutex = cfacts.PTHREAD_MUTEX_INITIALIZER
raw var evals: raw.Ptr<Eval> = raw.null()
raw var nevals: i64 = 0
raw var capevals: i64 = 0

fn lock(m: raw.Ptr<cfacts.PthreadMutex>) uses ffi {
  let _ = pthread_mutex_lock(m)
}

fn unlock(m: raw.Ptr<cfacts.PthreadMutex>) uses ffi {
  let _ = pthread_mutex_unlock(m)
}

export fn auk_dbg_set_eval_hook(h: EvalHook) uses raw {
  eval_hook = raw.cast(h)
}

// The hook as a mailbox, for a compiler written in Auk (compiler/src/dbg_eval.auk), which C
// can't call: the stopped thread posts its request and waits; the compiler's server thread
// takes it (auk_dbg_eval_next), compiles it and answers (auk_dbg_eval_ok / auk_dbg_eval_err).
// One request at a time. The answer's initializer (the expression's string literals and
// constants) runs on the requesting thread, before its first call.
raw var mb_lock: cfacts.PthreadMutex = cfacts.PTHREAD_MUTEX_INITIALIZER
raw var mb_cv: cfacts.PthreadCond = cfacts.PTHREAD_COND_INITIALIZER
/// 0: free, 1: a request waits, 2: being compiled, 3: answered
raw var mb_state: i32 = 0
raw var mb_closed: bool = false
raw var mb_func: u32 = 0
raw var mb_site: u32 = 0
raw var mb_expr: raw.Ptr<u8> = raw.null()
raw var mb_ok: bool = false
raw var mb_out: abi.DbgCompiled = abi.DbgCompiled {}
raw var mb_err: raw.Ptr<u8> = raw.null()
/// `void (*)(void)` (null: none)
raw var mb_init: raw.Ptr<()> = raw.null()

fn mb_wait() uses raw, ffi {
  let _ = pthread_cond_wait(raw.addr_of(&mb_cv), raw.addr_of(&mb_lock))
}

fn mb_wake() uses raw, ffi {
  let _ = pthread_cond_broadcast(raw.addr_of(&mb_cv))
}

fn mailbox_hook(func: u32, site: u32, expr: raw.Ptr<u8>, out: raw.Ptr<abi.DbgCompiled>, err: raw.Ptr<raw.Ptr<u8>>): bool uses raw, ffi {
  lock(raw.addr_of(&mb_lock))
  while mb_state != 0 && !mb_closed {
    mb_wait()
  }
  if mb_closed {
    unlock(raw.addr_of(&mb_lock))
    err.store(dbg_text.dup_s("this program can't evaluate expressions"))
    return false
  }
  mb_func = func
  mb_site = site
  mb_expr = dbg_text.dup_s(expr)
  mb_state = 1
  mb_wake()
  while mb_state != 3 && !mb_closed {
    mb_wait()
  }
  var ok = false
  var init: raw.Ptr<()> = raw.null()
  if mb_state == 3 {
    ok = mb_ok
    if ok {
      out.store(mb_out)
      init = mb_init
    } else {
      err.store(mb_err)
    }
  } else {
    err.store(dbg_text.dup_s("this program can't evaluate expressions"))
  }
  raw.free(mb_expr)
  mb_expr = raw.null()
  mb_err = raw.null()
  mb_state = 0
  mb_wake()
  unlock(raw.addr_of(&mb_lock))
  if !init.is_null() {
    let f: raw.Fn<() => ()> = raw.cast(init)
    f()
  }
  ok
}

/// Serve evaluations through the mailbox.
export fn auk_dbg_eval_mailbox() uses raw, ffi {
  lock(raw.addr_of(&mb_lock))
  mb_closed = false
  unlock(raw.addr_of(&mb_lock))
  eval_hook = raw.cast(raw.fn_of(mailbox_hook))
}

/// Wait for a request: 1 (then auk_dbg_eval_func/site/expr say what), or 0 once closed.
export fn auk_dbg_eval_next(): i64 uses raw, ffi {
  lock(raw.addr_of(&mb_lock))
  while mb_state != 1 && !mb_closed {
    mb_wait()
  }
  let r: i64 = if mb_closed { 0 } else { 1 }
  if r == 1 {
    mb_state = 2
  }
  unlock(raw.addr_of(&mb_lock))
  r
}

export fn auk_dbg_eval_func(): i64 = i64(mb_func)

export fn auk_dbg_eval_site(): i64 = i64(mb_site)

export fn auk_dbg_eval_expr(): raw.Ptr<u8> uses raw = if mb_expr.is_null() { "" } else { mb_expr }

fn mb_answer() uses raw, ffi {
  lock(raw.addr_of(&mb_lock))
  mb_state = 3
  mb_wake()
  unlock(raw.addr_of(&mb_lock))
}

/// The request compiled: run(slots) at the code address run, the locals' slots, the type shown;
/// init: the code's initializer.
export fn auk_dbg_eval_ok(run: raw.Ptr<()>, init: raw.Ptr<()>, slots: raw.Ptr<i64>, nslots: i64, ty: raw.Ptr<u8>) uses raw, ffi {
  mb_ok = true
  let o = raw.addr_of(&mb_out)
  o.run = raw.cast(run)
  o.slots = raw.cast(raw.alloc(usize(nslots + 1) * raw.size_of<u32>()))
  var i: i64 = 0
  while i < nslots {
    o.slots.at(i) = u32(slots.at(i))
    i += 1
  }
  o.nslots = nslots
  o.ty = dbg_text.dup_s(ty)
  mb_init = init
  mb_answer()
}

/// The request failed to compile: why.
export fn auk_dbg_eval_err(msg: raw.Ptr<u8>) uses raw, ffi {
  mb_ok = false
  mb_err = dbg_text.dup_s(msg)
  mb_answer()
}

/// No more requests: auk_dbg_eval_next returns 0, and waiting requests fail.
export fn auk_dbg_eval_close() uses raw, ffi {
  lock(raw.addr_of(&mb_lock))
  mb_closed = true
  mb_wake()
  unlock(raw.addr_of(&mb_lock))
}

// Ctrl-C for a front end written in Auk (compiler/src/debug.auk), which can't install a signal
// handler: this one sets a flag, which the front end polls. (C's `volatile sig_atomic_t`: an
// atomic int here.)
raw var sigint_seen: i32 = 0

fn on_sigint(sig: i32) uses raw {
  raw.atomic_store(raw.addr_of(&sigint_seen), 1, raw.Order.Relaxed)
}

export fn auk_dbg_catch_sigint() uses raw, ffi {
  let _ = signal(cfacts.SIGINT, raw.cast(raw.fn_of(on_sigint)))
}

/// Was Ctrl-C pressed since the last call?
export fn auk_dbg_sigint_taken(): bool uses raw = raw.atomic_swap(raw.addr_of(&sigint_seen), 0, raw.Order.Relaxed) != 0

raw struct EvalEnv {
  run: raw.Fn<(raw.Ptr<raw.Ptr<()>>) => raw.Ptr<abi.Str>>,
  args: raw.Ptr<raw.Ptr<()>>,
}

fn eval_tramp(env: raw.Ptr<()>, out: raw.Ptr<()>) uses raw {
  let e: raw.Ptr<EvalEnv> = raw.cast(env)
  let run = e.run
  let o: raw.Ptr<raw.Ptr<abi.Str>> = raw.cast(out)
  o.store(run(e.args))
}

/// Evaluate an Auk expression in frame f: true with the value shown and its type in *value and
/// *ty, or false with *err (all malloc'd).
pub fn eval_at(f: raw.Ptr<abi.DbgFrame>, expr: raw.Ptr<u8>, value: raw.Ptr<raw.Ptr<u8>>, ty: raw.Ptr<raw.Ptr<u8>>, err: raw.Ptr<raw.Ptr<u8>>): bool uses raw, ffi {
  if eval_hook.is_null() {
    err.store(dbg_text.dup_s("this program can't evaluate expressions"))
    return false
  }
  let func = u32(f.func)
  let site = u32(f.site)
  let key = dbg_text.trimmed(expr)
  // copied under the lock: another thread's append may move the table
  var e: Eval
  let ep = raw.addr_of(&e)
  var found = false
  lock(raw.addr_of(&evals_lock))
  var i: i64 = 0
  while i < nevals {
    let x = evals.offset(i)
    if x.site == site && strcmp(x.expr, key) == 0 {
      ep.store(x.load())
      found = true
      break
    }
    i += 1
  }
  unlock(raw.addr_of(&evals_lock))
  if found {
    raw.free(key)
  } else {
    raw.fill(ep, 0, raw.size_of<Eval>())
    ep.site = site
    ep.expr = key
    let hook: EvalHook = raw.cast(eval_hook)
    ep.ok = hook(func, site, key, raw.field_addr(ep, .c), raw.field_addr(ep, .err))
    lock(raw.addr_of(&evals_lock))
    if nevals == capevals {
      capevals = if capevals == 0 { 16 } else { capevals * 2 }
      evals = raw.cast(raw.realloc(evals, usize(capevals) * raw.size_of<Eval>()))
    }
    evals.at(nevals) = ep.load()
    nevals += 1
    unlock(raw.addr_of(&evals_lock))
  }
  if !ep.ok {
    err.store(dbg_text.dup_s(ep.err))
    return false
  }
  let c = raw.field_addr(ep, .c)
  let args: raw.Ptr<raw.Ptr<()>> = raw.cast(raw.alloc(usize(c.nslots + 1) * raw.size_of<raw.Ptr<()>>()))
  i = 0
  while i < c.nslots {
    let p = f.slots.at(c.slots.at(i))
    if p.is_null() {
      raw.free(args)
      err.store(dbg_text.dup_s("a variable it uses has no value yet"))
      return false
    }
    args.at(i) = p
    i += 1
  }
  var env = EvalEnv { run: c.run, args }
  var out: raw.Ptr<abi.Str> = raw.null()
  let left = str.auk__show_left()
  str.auk__set_show_left(1024)
  let p = recover.auk__catch_call(raw.fn_of(eval_tramp), raw.cast(raw.addr_of(&env)), raw.cast(raw.addr_of(&out)))
  str.auk__set_show_left(left)
  raw.free(args)
  if !p.is_null() {
    var t = dbg_text.Text {}
    dbg_text.put(raw.addr_of(&t), "panic: ")
    dbg_text.put(raw.addr_of(&t), p.msg)
    recover.auk__panic_free(p)
    err.store(t.p)
    return false
  }
  value.store(dbg_text.cut_text(str.auk_str_cstr(out), usize(str.auk_str_byte_len(out)), 1000))
  rc.release(raw.cast(out))
  ty.store(dbg_text.dup_s(c.ty))
  true
}

/// Recovery points for `catch` and task threads (was runtime/c/catch.c, ported line by line;
/// the module isn't `catch`, a keyword, so that stack.auk can call it by path).
///
/// A thread keeps a stack of recovery points (setjmp buffers); a panic (rc.c auk__panic) on a
/// thread with one records its message here and jumps back to the innermost one instead of
/// ending the process. Nothing between the jump and the recovery point is cleaned up: Auk
/// objects the aborted code owned leak (bounded per panic), and `var` state it was changing
/// stays half-changed.
///
/// This is the runtime's only use of setjmp/longjmp; keep it that way (docs/lowlevel.md,
/// section 7). C's `sigsetjmp(jb, 0)`/`siglongjmp` are `raw.setjmp`/`raw.longjmp` here: libc's
/// `_setjmp`/`_longjmp`, which don't save or restore the signal mask either.
///
/// stack.auk's stack-overflow handler reaches the same frames through `auk__catch_active`,
/// `auk__catch_top_addr` and `auk__catch_throw_overflow`.

// the rest of the runtime (C, for now)
extern fn auk__xmalloc(n: usize): raw.Ptr<()> = "void *auk__xmalloc(size_t)"
extern fn auk__trace_save(depth: raw.Ptr<i64>, mute: raw.Ptr<i32>) = "void auk__trace_save(int64_t *, int *)"
extern fn auk__trace_restore(depth: i64, mute: i32) = "void auk__trace_restore(int64_t, int)"
extern fn auk__dbg_save(top: raw.Ptr<raw.Ptr<()>>, depth: raw.Ptr<i64>) = "void auk__dbg_save(void **, int64_t *)"
extern fn auk__dbg_restore(top: raw.Ptr<()>, depth: i64) = "void auk__dbg_restore(void *, int64_t)"
extern fn auk__task_cancelled(): bool = "bool auk__task_cancelled(void)"
extern fn auk__sb_put_cstr(b: raw.Ptr<abi.StrBuf>, s: raw.Ptr<u8>) = "void auk__sb_put_cstr(void *, const char *)"
extern fn auk__err_sb(b: raw.Ptr<abi.StrBuf>): raw.Ptr<abi.Err> = "void *auk__err_sb(void *)"
// libc
extern fn strlen(s: raw.Ptr<u8>): usize = "size_t strlen(const char *)"

raw struct CatchFrame {
  jb: raw.JmpBuf,
  prev: raw.Ptr<CatchFrame>,
}

raw thread var top: raw.Ptr<CatchFrame> = raw.null()
/// The panic being carried to a recovery point (malloc'd; taken by auk__catch_take).
raw thread var caught_msg: raw.Ptr<u8> = raw.null()
raw thread var caught_loc: raw.Ptr<u8> = raw.null()
/// The panic being carried is a stack overflow (its strings are made by auk__catch_take).
raw thread var caught_overflow: bool = false

export fn auk__catch_run(f: raw.Fn<(raw.Ptr<()>, raw.Ptr<()>) => ()>, env: raw.Ptr<()>, out: raw.Ptr<()>): i32 uses raw {
  // uninitialized, as C's `CatchFrame fr` (setjmp fills jb)
  var fr: CatchFrame
  fr.prev = top
  run_at(raw.addr_of(&fr), f, env, out)
}

/// auk__catch_run's body after the frame is made. It calls raw.setjmp, so the compiler makes
/// it `optnone noinline` (its locals hold their last values after the jump back); the frame
/// itself is in the caller's memory, as in C. Split from auk__catch_run so that only this part
/// is unoptimized.
fn run_at(fr: raw.Ptr<CatchFrame>, f: raw.Fn<(raw.Ptr<()>, raw.Ptr<()>) => ()>, env: raw.Ptr<()>, out: raw.Ptr<()>): i32 uses raw {
  // _setjmp: no signal-mask syscall per catch (C's sigsetjmp savemask 0)
  if !raw.setjmp(raw.field_addr(fr, .jb)) {
    top = fr
    f(env, out)
    top = fr.prev
    return 0
  }
  top = fr.prev
  1
}

pub export fn auk__catch_active(): i32 uses raw = if top.is_null() { 0 } else { 1 }

/// Where the innermost recovery point lives (0: none).
pub export fn auk__catch_top_addr(): usize uses raw = usize(top.int())

fn copy_bytes(p: raw.Ptr<u8>, n: usize): raw.Ptr<u8> uses raw, ffi {
  let s: raw.Ptr<u8> = raw.cast(auk__xmalloc(n + 1))
  raw.copy(s, p, n)
  s.at(n) = 0
  s
}

/// _Noreturn (`never` is core's only: a `()` that never returns).
export fn auk__catch_throw(loc: raw.Ptr<u8>, msg: raw.Ptr<u8>, n: usize) uses raw, ffi {
  raw.free(caught_msg)
  raw.free(caught_loc)
  caught_msg = copy_bytes(msg, n)
  caught_loc = copy_bytes(loc, strlen(loc))
  raw.longjmp(raw.field_addr(top, .jb))
}

pub export fn auk__catch_throw_overflow(): never uses raw {
  caught_overflow = true
  raw.longjmp(raw.field_addr(top, .jb))
}

export fn auk__catch_take(msg: raw.Ptr<raw.Ptr<u8>>, loc: raw.Ptr<raw.Ptr<u8>>) uses raw, ffi {
  if caught_overflow {
    caught_overflow = false
    raw.free(caught_msg)
    raw.free(caught_loc)
    let l = stack.auk__stack_overflow_loc()
    caught_msg = copy_bytes("stack overflow", 14)
    caught_loc = copy_bytes(l, strlen(l))
  }
  msg.store(caught_msg)
  loc.store(caught_loc)
  caught_msg = raw.null()
  caught_loc = raw.null()
}

/// Run f(env, out) under a recovery point: NULL if it finished, the panic (malloc'd; free it
/// with auk__panic_free) if one jumped back. The tracer's and the debugger's per-thread state
/// is put back as it was here.
export fn auk__catch_call(f: raw.Fn<(raw.Ptr<()>, raw.Ptr<()>) => ()>, env: raw.Ptr<()>, out: raw.Ptr<()>): raw.Ptr<abi.Panic> uses raw, ffi {
  var tdepth: i64 = 0
  var tmute: i32 = 0
  var dtop: raw.Ptr<()> = raw.null()
  var ddepth: i64 = 0
  auk__trace_save(raw.addr_of(&tdepth), raw.addr_of(&tmute))
  auk__dbg_save(raw.addr_of(&dtop), raw.addr_of(&ddepth))
  if auk__catch_run(f, env, out) == 0 {
    return raw.null()
  }
  auk__trace_restore(tdepth, tmute)
  auk__dbg_restore(dtop, ddepth)
  let p: raw.Ptr<abi.Panic> = raw.cast(auk__xmalloc(raw.size_of<abi.Panic>()))
  auk__catch_take(raw.field_addr(p, .msg), raw.field_addr(p, .loc))
  if p.msg.is_null() {
    p.msg = copy_bytes("panic", 5)
    p.loc = copy_bytes("<unknown>", 9)
  }
  p
}

export fn auk__panic_free(p: raw.Ptr<abi.Panic>) uses raw {
  raw.free(p.msg)
  raw.free(p.loc)
  raw.free(p)
}

/// The Err a recovered panic becomes: "panic: <msg> at <loc>".
export fn auk__panic_err(p: raw.Ptr<abi.Panic>): raw.Ptr<abi.Err> uses raw, ffi {
  var b = abi.StrBuf {}
  let bp = raw.addr_of(&b)
  auk__sb_put_cstr(bp, "panic: ")
  auk__sb_put_cstr(bp, p.msg)
  auk__sb_put_cstr(bp, " at ")
  auk__sb_put_cstr(bp, p.loc)
  auk__err_sb(bp)
}

/// `catch e`: run the thunk (it writes e's value to out); NULL when it finished, else the panic
/// as a new (owned) Err and out untouched.
export fn auk_catch(f: raw.Fn<(raw.Ptr<()>, raw.Ptr<()>) => ()>, env: raw.Ptr<()>, out: raw.Ptr<()>): raw.Ptr<abi.Err> uses raw, ffi {
  let p = auk__catch_call(f, env, out)
  if p.is_null() {
    return raw.null()
  }
  if auk__task_cancelled() {
    // a cancelled task must end: pass the panic on to the next recovery point out (the task's
    // own, at the latest)
    auk__catch_throw(p.loc, p.msg, strlen(p.msg))
    raw.unreachable()
  }
  let e = auk__panic_err(p)
  auk__panic_free(p)
  e
}

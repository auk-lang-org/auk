/// Arithmetic, Err, Value, closures, tasks, core library and hooks (was
/// runtime/c/test/test_core.c).

raw let INT64_MAX: i64 = 9223372036854775807
raw let INT64_MIN: i64 = -9223372036854775807 - 1

fn nan(): float uses ffi = rt.auk_ffrom_bits(0x7ff8000000000000)

fn fabs(x: float): float = if x < 0.0 { 0.0 - x } else { x }

// ---- arithmetic -------------------------------------------------------------------------------

fn arith_checked() uses raw, ffi {
  ut.eq(rt.auk_add(2, 3, "t"), 5, "auk_add(2, 3, T)")
  ut.eq(rt.auk_sub(2, 3, "t"), -1, "auk_sub(2, 3, T)")
  ut.eq(rt.auk_mul(-4, 3, "t"), -12, "auk_mul(-4, 3, T)")
  ut.eq(rt.auk_div(7, 2, "t"), 3, "auk_div(7, 2, T)")
  ut.eq(rt.auk_div(-7, 2, "t"), -3, "auk_div(-7, 2, T)")
  ut.eq(rt.auk_mod(-7, 2, "t"), -1, "auk_mod(-7, 2, T)")
  ut.eq(rt.auk_mod(INT64_MIN, -1, "t"), 0, "auk_mod(INT64_MIN, -1, T)")
  ut.eq(rt.auk_pow(3, 4, "t"), 81, "auk_pow(3, 4, T)")
  ut.eq(rt.auk_pow(-2, 63, "t"), INT64_MIN, "auk_pow(-2, 63, T)")
  ut.eq(rt.auk_pow(7, 0, "t"), 1, "auk_pow(7, 0, T)")
  ut.eq(rt.auk_pow(0, 0, "t"), 1, "auk_pow(0, 0, T)")
  ut.eq(rt.auk_wadd(INT64_MAX, 1), INT64_MIN, "auk_wadd(INT64_MAX, 1)")
  ut.eq(rt.auk_wsub(INT64_MIN, 1), INT64_MAX, "auk_wsub(INT64_MIN, 1)")
  ut.eq(rt.auk_wmul(INT64_MAX, 2), -2, "auk_wmul(INT64_MAX, 2)")
  ut.eq(rt.auk_float_to_int(-2.9, "t"), -2, "auk_float_to_int(-2.9, T)")
  ut.check(rt.auk_fround(2.5) == 3.0 && rt.auk_fround(-2.5) == -3.0, "auk_fround(2.5) == 3.0 && auk_fround(-2.5) == -3.0")
  ut.check(
    rt.auk_fsqrt(16.0) == 4.0 && rt.auk_ffloor(-1.5) == -2.0 && rt.auk_fceil(1.2) == 2.0,
    "auk_fsqrt(16.0) == 4.0 && auk_ffloor(-1.5) == -2.0 && auk_fceil(1.2) == 2.0",
  )
  ut.check(rt.auk_fpow(2.0, 10.0) == 1024.0, "auk_fpow(2.0, 10.0) == 1024.0")
  ut.check(
    rt.auk_fsin(0.0) == 0.0 && rt.auk_fcos(0.0) == 1.0 && fabs(rt.auk_fatan2(1.0, 1.0) - 0.7853981633974483) < 0.000000000000001,
    "auk_fsin(0.0) == 0.0 && auk_fcos(0.0) == 1.0 && fabs(auk_fatan2(1.0, 1.0) - M_PI_4) < 1e-15",
  )
  ut.check(
    rt.auk_fexp(0.0) == 1.0 && rt.auk_fln(1.0) == 0.0 && rt.auk_flog10(1000.0) == 3.0 && rt.auk_flog2(8.0) == 3.0,
    "auk_fexp(0.0) == 1.0 && auk_fln(1.0) == 0.0 && auk_flog10(1000.0) == 3.0 && auk_flog2(8.0) == 3.0",
  )
  ut.check(
    fabs(rt.auk_ftan(0.5) - rt.tan(0.5)) < 0.000000000000001 && rt.auk_fasin(1.0) == 1.5707963267948966 &&
      rt.auk_facos(1.0) == 0.0 && rt.auk_fatan(0.0) == 0.0,
    "fabs(auk_ftan(0.5) - tan(0.5)) < 1e-15 && auk_fasin(1.0) == M_PI_2 && auk_facos(1.0) == 0.0 && auk_fatan(0.0) == 0.0",
  )
  var one_half: float = 1.5
  let bits = raw.cast<i64>(raw.addr_of(&one_half)).load()
  ut.eq(rt.auk_fbits(1.5), bits, "auk_fbits(1.5)")
  ut.check(rt.auk_ffrom_bits(rt.auk_fbits(-0.1)) == -0.1, "auk_ffrom_bits(auk_fbits(-0.1)) == -0.1")
  ut.eq(rt.auk_fbits32(0.5), 0x3f000000, "auk_fbits32(0.5)")
  ut.check(
    rt.auk_ffrom_bits32(0x3f000000) == 0.5 && rt.auk_ffrom_bits32(0xbf800000) == -1.0,
    "auk_ffrom_bits32(0x3f000000) == 0.5 && auk_ffrom_bits32(0xbf800000) == -1.0",
  )
  ut.check(rt.auk_float_cmp(nan(), 1.0) > 0 && rt.auk_float_cmp(1.0, 2.0) < 0, "auk_float_cmp(NAN, 1.0) > 0 && auk_float_cmp(1.0, 2.0) < 0")
}

fn p_add(c: raw.Ptr<()>) uses ffi {
  let _ = rt.auk_add(INT64_MAX, 1, "math.auk:1:9")
}
fn p_sub(c: raw.Ptr<()>) uses ffi {
  let _ = rt.auk_sub(INT64_MIN, 1, "math.auk:2:9")
}
fn p_mul(c: raw.Ptr<()>) uses ffi {
  let _ = rt.auk_mul(INT64_MAX / 2 + 1, 2, "x")
}
fn p_div0(c: raw.Ptr<()>) uses ffi {
  let _ = rt.auk_div(1, 0, "math.auk:4:9")
}
fn p_mod0(c: raw.Ptr<()>) uses ffi {
  let _ = rt.auk_mod(1, 0, "x")
}
fn p_div_ovf(c: raw.Ptr<()>) uses ffi {
  let _ = rt.auk_div(INT64_MIN, -1, "x")
}
fn p_neg(c: raw.Ptr<()>) uses ffi {
  let _ = rt.auk_neg(INT64_MIN, "x")
}
fn p_pow(c: raw.Ptr<()>) uses ffi {
  let _ = rt.auk_pow(2, 63, "x")
}
fn p_pow_neg(c: raw.Ptr<()>) uses ffi {
  let _ = rt.auk_pow(2, -1, "x")
}
fn p_nan(c: raw.Ptr<()>) uses ffi {
  let _ = rt.auk_float_to_int(nan(), "x")
}
fn p_big(c: raw.Ptr<()>) uses ffi {
  let _ = rt.auk_float_to_int(10000000000000000000.0, "x")
}

fn arith_panics_exit_101() uses raw, ffi {
  ut.expect_panic(raw.fn_of(p_add), raw.null(), "panic: integer overflow in `+`\n  at math.auk:1:9\n")
  ut.expect_panic(raw.fn_of(p_sub), raw.null(), "integer overflow in `-`")
  ut.expect_panic(raw.fn_of(p_mul), raw.null(), "integer overflow in `*`")
  ut.expect_panic(raw.fn_of(p_div0), raw.null(), "panic: division by zero\n  at math.auk:4:9")
  ut.expect_panic(raw.fn_of(p_mod0), raw.null(), "division by zero")
  ut.expect_panic(raw.fn_of(p_div_ovf), raw.null(), "integer overflow in `/`")
  ut.expect_panic(raw.fn_of(p_neg), raw.null(), "integer overflow")
  ut.expect_panic(raw.fn_of(p_pow), raw.null(), "integer overflow in `**`")
  ut.expect_panic(raw.fn_of(p_pow_neg), raw.null(), "negative exponent")
  ut.expect_panic(raw.fn_of(p_nan), raw.null(), "int(NaN)")
  ut.expect_panic(raw.fn_of(p_big), raw.null(), "out of range")
}

// ---- Err ----------------------------------------------------------------------------------------

/// A typed error payload with an RC field.
raw struct BadToken {
  at: i64,
  why: raw.Ptr<abi.Str>,
}

fn bt_retain(p: raw.Ptr<()>) uses raw, ffi {
  let _ = rt.auk_retain(raw.cast(raw.cast<BadToken>(p).why))
}

fn bt_release(p: raw.Ptr<()>) uses raw, ffi = rt.auk_release(raw.cast(raw.cast<BadToken>(p).why))

fn bt_show(p: raw.Ptr<()>): raw.Ptr<abi.Str> uses raw, ffi {
  let b: raw.Ptr<BadToken> = raw.cast(p)
  var sb = abi.StrBuf {}
  var head: [u8; 64]
  let hp = raw.cast<u8>(raw.addr_of(&head))
  let _ = rt.snprintf(hp, 64, "BadToken(%lld, ", b.at)
  ut.sb_push(raw.addr_of(&sb), hp)
  rt.auk_sb_str_own(raw.addr_of(&sb), rt.auk_str_quote(b.why))
  rt.auk_sb_lit(raw.addr_of(&sb), ")")
  rt.auk_sb_finish(raw.addr_of(&sb))
}

raw var bt_ops: abi.ElemOps = abi.ElemOps {
  size: raw.size_of<BadToken>(),
  retain: raw.fn_of(bt_retain),
  release: raw.fn_of(bt_release),
  show: raw.fn_of(bt_show),
}

raw let TYPE_BADTOKEN: u32 = 17
raw let TYPE_OTHER: u32 = 18

fn err_chain_and_payload() uses raw, ffi {
  let root = ut.err_msg("connection refused")
  root.code = 61
  let m1 = ut.s("fetching config")
  let mid = rt.auk_err_wrap(m1, root)
  let m2 = ut.s("startup failed")
  let top = rt.auk_err_wrap(m2, mid)
  ut.rel(raw.cast(root))
  ut.rel(raw.cast(mid))
  ut.rel(raw.cast(m1))
  ut.rel(raw.cast(m2))
  ut.str_eq(rt.auk_err_show(top), "startup failed: fetching config: connection refused", "auk_err_show(top)")
  ut.eq(top.cause.cause.code, 61, "top->cause->cause->code")
  ut.rel(raw.cast(top))

  var bt = BadToken { at: 7, why: ut.s("unexpected '}}'") }
  let e = rt.auk_err_typed(TYPE_BADTOKEN, raw.cast(raw.addr_of(&bt)), raw.addr_of(&bt_ops), raw.null())
  ut.rel(raw.cast(bt.why)) // the error holds its own reference
  ut.str_eq(rt.auk_err_show(e), "BadToken(7, \"unexpected '}}'\")", "auk_err_show(e)")
  let got: raw.Ptr<BadToken> = raw.cast(rt.auk_err_payload(e, TYPE_BADTOKEN))
  ut.check(
    !got.is_null() && got.at == 7 && rt.auk_str_eq_lit(got.why, "unexpected '}}'"),
    "got != NULL && got->at == 7 && auk_str_eq_lit(got->why, \"unexpected '}}'\")",
  )
  ut.check(rt.auk_err_payload(e, TYPE_OTHER).is_null(), "auk_err_payload(e, TYPE_OTHER) == NULL")
  let ctx = ut.s("parsing a.json")
  let w = rt.auk_err_wrap(ctx, e)
  ut.rel(raw.cast(ctx))
  ut.rel(raw.cast(e))
  ut.check(!rt.auk_err_payload(w.cause, TYPE_BADTOKEN).is_null(), "auk_err_payload(w->cause, TYPE_BADTOKEN) != NULL")
  ut.str_eq(rt.auk_err_show(w), "parsing a.json: BadToken(7, \"unexpected '}}'\")", "auk_err_show(w)")
  ut.rel(raw.cast(w))

  // a long chain frees without recursion problems
  var chain = ut.err_msg("base")
  var i = 0
  while i < 100000 {
    let n = rt.auk_err_wrap(raw.null(), chain)
    ut.rel(raw.cast(chain))
    chain = n
    i += 1
  }
  ut.rel(raw.cast(chain))
}

fn p_unwrap_err(c: raw.Ptr<()>) uses ffi = rt.auk_unwrap_err("u.auk:1:1", ut.err_msg("boom"))

fn p_unwrap_none(c: raw.Ptr<()>) uses ffi = rt.auk_unwrap_none("u.auk:2:2")

fn err_unwrap_panics() uses raw, ffi {
  ut.expect_panic(raw.fn_of(p_unwrap_err), raw.null(), "boom")
  ut.expect_panic(raw.fn_of(p_unwrap_none), raw.null(), "unwrapped `none`\n  at u.auk:2:2")
}

// ---- Value -----------------------------------------------------------------------------------------

fn value_tree() uses raw, ffi {
  var m = rt.auk_value_map_new()
  let pm = raw.addr_of(&m)
  let name = ut.s("auk")
  let vs = rt.auk_value_str(name)
  rt.auk_value_map_put(pm, "name", vs)
  rt.auk_value_release(vs)
  rt.auk_value_map_put(pm, "age", rt.auk_value_int(3))
  rt.auk_value_map_put(pm, "w", rt.auk_value_float(1.5))
  rt.auk_value_map_put(pm, "ok", rt.auk_value_bool(true))
  rt.auk_value_map_put(pm, "nil", rt.auk_value_null())
  var l = rt.auk_value_list_new()
  var one = rt.auk_value_int(1)
  var two = rt.auk_value_float(2.0)
  rt.auk_arr_push(raw.addr_of(&l), raw.cast(raw.addr_of(&one)))
  rt.auk_arr_push(raw.addr_of(&l), raw.cast(raw.addr_of(&two)))
  let vl = rt.auk_value_list(l)
  rt.auk_value_map_put(pm, "xs", vl)
  rt.auk_value_release(vl)
  let root = rt.auk_value_map(m)
  ut.str_eq(
    rt.auk_value_show(root),
    "{{\"name\": \"auk\", \"age\": 3, \"w\": 1.5, \"ok\": true, \"nil\": Null, \"xs\": [1, 2.0]}}",
    "auk_value_show(root)",
  )
  let cp = rt.auk_value_map(rt.auk_map_copy(m))
  ut.rel(raw.cast(cp.u.map)) // auk_value_map retained it
  ut.check(rt.auk_value_eq(root, cp), "auk_value_eq(root, copy)")
  ut.check(!rt.auk_value_eq(rt.auk_value_int(1), rt.auk_value_float(1.0)), "!auk_value_eq(auk_value_int(1), auk_value_float(1.0))")
  ut.check(rt.auk_value_as_float(rt.auk_value_int(2), "t") == 2.0, "auk_value_as_float(auk_value_int(2), T) == 2.0")
  var k = ut.s("age")
  let age: raw.Ptr<abi.Value> = raw.cast(rt.auk_map_at(rt.auk_value_as_map(root, "t"), raw.cast(raw.addr_of(&k)), "t"))
  ut.eq(rt.auk_value_as_int(age.load(), "t"), 3, "auk_value_as_int(*age, T)")
  ut.text_eq(rt.auk_value_tag_name(abi.V_LIST), "List", "auk_value_tag_name(AUK_V_LIST)")
  ut.rel(raw.cast(k))
  rt.auk_value_release(cp)
  rt.auk_value_release(root)
  ut.rel(raw.cast(m))
  ut.rel(raw.cast(l))
  ut.rel(raw.cast(name))
}

fn p_as_int(c: raw.Ptr<()>) uses ffi {
  let _ = rt.auk_value_as_int(rt.auk_value_bool(true), "v.auk:1:1")
}

fn value_accessor_panics() uses raw, ffi = ut.expect_panic(raw.fn_of(p_as_int), raw.null(), "expected Int, got Bool")

// ---- closures & boxes ------------------------------------------------------------------------------

raw struct GreetEnv {
  base: abi.Obj,
  greeting: raw.Ptr<abi.Str>,
  n: i64,
}

raw var drops: i64 = 0

fn greet_drop(o: raw.Ptr<abi.Obj>) uses raw, ffi {
  drops += 1
  rt.auk_release(raw.cast(raw.cast<GreetEnv>(o).greeting))
}

fn greet_fn(env: raw.Ptr<abi.Obj>, who: raw.Ptr<abi.Str>): raw.Ptr<abi.Str> uses raw, ffi {
  let e: raw.Ptr<GreetEnv> = raw.cast(env)
  var b = abi.StrBuf {}
  let pb = raw.addr_of(&b)
  rt.auk_sb_str(pb, e.greeting)
  rt.auk_sb_lit(pb, " ")
  rt.auk_sb_str(pb, who)
  var tail: [u8; 32]
  let tp = raw.cast<u8>(raw.addr_of(&tail))
  let _ = rt.snprintf(tp, 32, " x%lld", e.n)
  ut.sb_push(pb, tp)
  rt.auk_sb_finish(pb)
}

fn closures_env_rc() uses raw, ffi {
  drops = 0
  let env: raw.Ptr<GreetEnv> = raw.cast(rt.auk_obj_alloc(raw.size_of<GreetEnv>(), raw.cast<()>(raw.fn_of(greet_drop)), raw.null()))
  env.greeting = ut.s("hi")
  env.n = 2
  var c = abi.Closure { func: raw.cast<()>(raw.fn_of(greet_fn)), env: raw.cast<abi.Obj>(env) }
  var fs = rt.auk_arr_new(rt.OPS_CLOSURE, 0)
  rt.auk_arr_push(raw.addr_of(&fs), raw.cast(raw.addr_of(&c)))
  rt.auk_closure_release(c) // the array holds it now
  let c2 = raw.cast<abi.Closure>(rt.auk_arr_at(fs, 0, "t")).load()
  let who = ut.s("auk")
  let f = raw.cast<raw.Fn<(raw.Ptr<abi.Obj>, raw.Ptr<abi.Str>) => raw.Ptr<abi.Str>>>(c2.func)
  ut.str_eq(f(c2.env, who), "hi auk x2", "f(c2.env, who)")
  ut.rel(raw.cast(who))
  ut.eq(drops, 0, "drops")
  ut.rel(raw.cast(fs))
  ut.eq(drops, 1, "drops")
}

// ---- tasks -------------------------------------------------------------------------------------------

raw struct SleepArgs {
  ms: i64,
  tag: raw.Ptr<abi.Str>,
  /// where to record when the sleep started and ended (or null)
  span: raw.Ptr<i64>,
}

fn sleep_thunk(args: raw.Ptr<()>, result: raw.Ptr<()>) uses raw, ffi {
  let a: raw.Ptr<SleepArgs> = raw.cast(args)
  if !a.span.is_null() {
    a.span.at(0) = rt.auk_time_now()
  }
  rt.auk_time_sleep(a.ms)
  if !a.span.is_null() {
    a.span.at(1) = rt.auk_time_now()
  }
  var b = abi.StrBuf {}
  rt.auk_sb_str(raw.addr_of(&b), a.tag)
  rt.auk_sb_lit(raw.addr_of(&b), " done")
  raw.cast<raw.Ptr<abi.Str>>(result).store(rt.auk_sb_finish(raw.addr_of(&b)))
  rt.auk_release(raw.cast(a.tag)) // the thunk owns its args
}

fn tasks_run_concurrently() uses raw, ffi {
  let t0 = rt.auk_time_now()
  var span1: [i64; 2]
  var span2: [i64; 2]
  let s1 = raw.cast<i64>(raw.addr_of(&span1))
  let s2 = raw.cast<i64>(raw.addr_of(&span2))
  var a1 = SleepArgs { ms: 200, tag: ut.s("a"), span: s1 }
  var a2 = SleepArgs { ms: 200, tag: ut.s("b"), span: s2 }
  let sz = raw.size_of<SleepArgs>()
  let ps = raw.size_of<raw.Ptr<abi.Str>>()
  var ts: [raw.Ptr<abi.Task>; 2]
  let pts = raw.cast<raw.Ptr<abi.Task>>(raw.addr_of(&ts))
  pts.at(0) = rt.auk_task_spawn(raw.fn_of(sleep_thunk), raw.cast(raw.addr_of(&a1)), sz, ps, rt.OPS_STR, raw.null(), raw.null(), raw.null())
  pts.at(1) = rt.auk_task_spawn(raw.fn_of(sleep_thunk), raw.cast(raw.addr_of(&a2)), sz, ps, rt.OPS_STR, raw.null(), raw.null(), raw.null())
  var outs: [raw.Ptr<abi.Str>; 2]
  let po = raw.cast<raw.Ptr<abi.Str>>(raw.addr_of(&outs))
  po.at(0) = raw.null()
  po.at(1) = raw.null()
  rt.auk_task_await_all(pts, 2, raw.cast(po))
  let dt = rt.auk_time_now() - t0
  ut.check(dt >= 195, "dt >= 195")
  // concurrent: each sleep started before the other ended (not a wall-clock bound, which a
  // loaded CI machine breaks)
  if !(s1.at(0) < s2.at(1) && s2.at(0) < s1.at(1)) {
    let m = ut.scratch(256)
    let _ = rt.snprintf(
      m, 256, "the two sleeps didn't overlap: [%lld, %lld] and [%lld, %lld] (ms from start)",
      s1.at(0) - t0, s1.at(1) - t0, s2.at(0) - t0, s2.at(1) - t0,
    )
    ut.fail(m)
  }
  ut.str_eq(po.at(0), "a done", "outs[0]")
  ut.str_eq(po.at(1), "b done", "outs[1]")
  // awaiting again hands out another reference
  var again: raw.Ptr<abi.Str> = raw.null()
  rt.auk_task_await(pts.at(0), raw.cast(raw.addr_of(&again)))
  ut.str_eq(again, "a done", "again")
  ut.rel(raw.cast(pts.at(0)))
  ut.rel(raw.cast(pts.at(1)))
}

fn sum_thunk(args: raw.Ptr<()>, result: raw.Ptr<()>) uses raw, ffi {
  let n = raw.cast<i64>(args).load()
  var sum: i64 = 0
  var i: i64 = 1
  while i <= n {
    sum = rt.auk_add(sum, i, "t")
    i += 1
  }
  raw.cast<i64>(result).store(sum)
}

fn tasks_many_and_unawaited() uses raw, ffi {
  var ts: [raw.Ptr<abi.Task>; 16]
  let pts = raw.cast<raw.Ptr<abi.Task>>(raw.addr_of(&ts))
  var i: i64 = 0
  while i < 16 {
    var n: i64 = 1000 * (i + 1)
    pts.at(i) = rt.auk_task_spawn(raw.fn_of(sum_thunk), raw.cast(raw.addr_of(&n)), 8, 8, raw.null(), raw.null(), raw.null(), raw.null())
    i += 1
  }
  i = 0
  while i < 16 {
    var r: i64 = 0
    let n: i64 = 1000 * (i + 1)
    rt.auk_task_await(pts.at(i), raw.cast(raw.addr_of(&r)))
    ut.eq(r, n * (n + 1) / 2, "r")
    ut.rel(raw.cast(pts.at(i)))
    i += 1
  }
  // releasing a never-awaited task joins it and releases its result
  var a = SleepArgs { ms: 10, tag: ut.s("x") }
  let t = rt.auk_task_spawn(
    raw.fn_of(sleep_thunk), raw.cast(raw.addr_of(&a)), raw.size_of<SleepArgs>(), raw.size_of<raw.Ptr<abi.Str>>(), rt.OPS_STR,
    raw.null(), raw.null(), raw.null(),
  )
  ut.rel(raw.cast(t))
}

raw struct PushArgs {
  xs: raw.Ptr<abi.Arr>,
}

fn shared_push_thunk(args: raw.Ptr<()>, result: raw.Ptr<()>) uses raw, ffi {
  let a: raw.Ptr<PushArgs> = raw.cast(args)
  var i: i64 = 0
  while i < 1000 {
    rt.auk_arr_push(raw.field_addr(a, .xs), raw.cast(raw.addr_of(&i))) // COW: copies once
    i += 1
  }
  raw.cast<i64>(result).store(rt.auk_arr_len(a.xs))
  rt.auk_release(raw.cast(a.xs))
}

fn tasks_atomic_refcounts() uses raw, ffi {
  let xs = rt.auk_arr_new(rt.OPS_INT, 0)
  var ts: [raw.Ptr<abi.Task>; 8]
  let pts = raw.cast<raw.Ptr<abi.Task>>(raw.addr_of(&ts))
  var i = 0
  while i < 8 {
    var a = PushArgs { xs: raw.cast(ut.ret(raw.cast(xs))) }
    pts.at(i) = rt.auk_task_spawn(raw.fn_of(shared_push_thunk), raw.cast(raw.addr_of(&a)), raw.size_of<PushArgs>(), 8, raw.null(), raw.null(), raw.null(), raw.null())
    i += 1
  }
  var outs: [i64; 8]
  let po = raw.cast<i64>(raw.addr_of(&outs))
  raw.fill(raw.cast<u8>(po), 0, 64)
  rt.auk_task_await_all(pts, 8, raw.cast(po))
  i = 0
  while i < 8 {
    ut.eq(po.at(i), 1000, "outs[i]")
    ut.rel(raw.cast(pts.at(i)))
    i += 1
  }
  ut.eq(rt.auk_arr_len(xs), 0, "auk_arr_len(xs)")
  ut.eq(rt.auk_refcount(raw.cast(xs)), 1, "auk_refcount(xs)")
  ut.rel(raw.cast(xs))
}

// ---- fs ------------------------------------------------------------------------------------------------

fn fs_round_trip() uses raw, ffi {
  let tmp = ut.tmpdir_new()
  var p = ut.tmpdir_path(tmp, "hello.txt")
  let content = ut.s("line one\ndück\r\nlast")
  var w = rt.auk_fs_write(p, content)
  ut.check(w.ok, "w.ok")
  var r = rt.auk_fs_read(p)
  ut.check(r.ok && rt.auk_str_eq(r.val, content), "r.ok && auk_str_eq(r.val, content)")
  ut.eq(rt.auk_str_len(r.val), 19, "auk_str_len(r.val)")
  ut.rel(raw.cast(r.val))
  var ls = rt.auk_fs_lines(p)
  ut.check(ls.ok, "ls.ok")
  let sep = ut.s("|")
  ut.str_eq(rt.auk_arr_join(ls.val, sep), "line one|dück|last", "auk_arr_join(ls.val, sep)")
  ut.rel(raw.cast(sep))
  ut.rel(raw.cast(ls.val))
  ut.rel(raw.cast(p))
  ut.rel(raw.cast(content))

  let missing = ut.s("/definitely/not/here.txt")
  r = rt.auk_fs_read(missing)
  ut.check(!r.ok, "!r.ok")
  ut.check(r.err.code != 0, "r.err->code != 0")
  ut.has(ut.err_text(r.err), "fs.read /definitely/not/here.txt: ", "err_text(r.err)")
  ls = rt.auk_fs_lines(missing)
  ut.check(!ls.ok, "!ls.ok")
  ut.rel(raw.cast(ls.err))
  w = rt.auk_fs_write(missing, missing)
  ut.check(!w.ok, "!w.ok")
  ut.rel(raw.cast(w.err))
  ut.rel(raw.cast(missing))

  // invalid UTF-8 on disk is an Err, not a corrupt str
  let path = ut.scratch(1024)
  let _ = rt.snprintf(path, 1024, "%s/bad.bin", tmp)
  let f = rt.fopen(path, "wb")
  ut.check(!f.is_null(), "f != NULL")
  let bad = ut.bin("ok\\xFF")
  let _ = rt.fwrite(raw.cast(bad.p), 1, 3, f)
  let _ = rt.fclose(f)
  p = ut.tmpdir_path(tmp, "bad.bin")
  r = rt.auk_fs_read(p)
  ut.check(!r.ok, "!r.ok")
  ut.has(ut.err_text(r.err), "invalid UTF-8 at byte 2", "err_text(r.err)")
  ut.rel(raw.cast(p))
}

// ---- proc ----------------------------------------------------------------------------------------------

fn proc_run() uses raw, ffi {
  let echo = ut.s("echo")
  var args = rt.auk_arr_new(rt.OPS_STR, 0)
  var a1 = ut.s("hello")
  var a2 = ut.s("dück world")
  rt.auk_arr_push(raw.addr_of(&args), raw.cast(raw.addr_of(&a1)))
  rt.auk_arr_push(raw.addr_of(&args), raw.cast(raw.addr_of(&a2)))
  var r = rt.auk_proc_run(echo, args)
  ut.check(r.ok, "r.ok")
  ut.str_eq(r.val, "hello dück world\n", "r.val")
  ut.rel(raw.cast(args))
  ut.rel(raw.cast(a1))
  ut.rel(raw.cast(a2))
  ut.rel(raw.cast(echo))

  let f = ut.s("false")
  let nothing = rt.auk_arr_new(rt.OPS_STR, 0)
  r = rt.auk_proc_run(f, nothing)
  ut.check(!r.ok, "!r.ok")
  ut.eq(r.err.code, 1, "r.err->code")
  ut.str_eq(rt.auk_err_show(r.err), "proc.run false: exited with status 1", "auk_err_show(r.err)")
  ut.rel(raw.cast(r.err))
  ut.rel(raw.cast(f))

  let nope = ut.s("auk-no-such-command-xyz")
  r = rt.auk_proc_run(nope, nothing)
  ut.check(!r.ok, "!r.ok")
  ut.rel(raw.cast(r.err))
  ut.rel(raw.cast(nope))
  ut.rel(raw.cast(nothing))
}

// ---- net ----------------------------------------------------------------------------------------------

/// Accept one connection on fd; reply "echo:" + whatever the first read got.
fn echo_server(arg: raw.Ptr<()>): raw.Ptr<()> uses raw, ffi {
  let lfd = raw.cast<i32>(arg).load()
  let c = rt.accept(lfd, raw.null(), raw.null())
  if c < 0 {
    return raw.null()
  }
  var buf: [u8; 256]
  let bp = raw.cast<u8>(raw.addr_of(&buf))
  let n = rt.c_read(c, raw.cast(bp), 256)
  if n > 0 {
    let echo: raw.Ptr<u8> = "echo:"
    if rt.c_write(c, raw.cast(echo), 5) == 5 && rt.c_write(c, raw.cast(bp), usize(n)) == n {
    }
  }
  let _ = rt.close(c)
  raw.null()
}

/// sin_family is a u8 after sin_len on macOS, a u16 on Linux.
fn set_family(sa: raw.Ptr<cfacts.SockaddrIn>, fam: i32) uses raw {
  let fp = raw.field_addr(sa, .sin_family)
  if raw.offset_of<cfacts.SockaddrIn>(.sin_family) == 1 {
    raw.cast<u8>(fp).store(u8(fam))
  } else {
    raw.cast<u16>(fp).store(u16(fam))
  }
}

fn net_tcp_echo() uses raw, ffi {
  var lfd = rt.socket(cfacts.AF_INET, cfacts.SOCK_STREAM, 0)
  ut.check(lfd >= 0, "lfd >= 0")
  var sa = cfacts.SockaddrIn {}
  let psa = raw.addr_of(&sa)
  set_family(psa, cfacts.AF_INET)
  sa.sin_addr = 0x0100007f // htonl(INADDR_LOOPBACK)
  sa.sin_port = 0
  ut.check(rt.bind(lfd, raw.cast(psa), u32(raw.size_of<cfacts.SockaddrIn>())) == 0, "bind(lfd, &sa, sizeof sa) == 0")
  ut.check(rt.listen(lfd, 4) == 0, "listen(lfd, 4) == 0")
  var len = u32(raw.size_of<cfacts.SockaddrIn>())
  ut.check(rt.getsockname(lfd, raw.cast(psa), raw.addr_of(&len)) == 0, "getsockname(lfd, &sa, &len) == 0")
  let port = i64(raw.bswap(sa.sin_port))
  var th = cfacts.PthreadT {}
  ut.check(rt.pthread_create(raw.addr_of(&th), raw.null(), raw.fn_of(echo_server), raw.cast(raw.addr_of(&lfd))) == 0, "pthread_create(...) == 0")

  let host = ut.s("127.0.0.1")
  var c = rt.auk_net_tcp(host, port)
  ut.check(c.ok, "c.ok")
  let msg = ut.s("ping 🦆")
  let bytes = rt.auk_str_bytes(msg)
  let w = rt.auk_conn_write(c.val, bytes)
  ut.check(w.ok, "w.ok")
  var all = rt.auk_arr_new(rt.OPS_INT, 0)
  while true {
    let r = rt.auk_conn_read(c.val, 4)
    ut.check(r.ok, "r.ok")
    let n = rt.auk_arr_len(r.val)
    rt.auk_arr_extend(raw.addr_of(&all), r.val)
    ut.rel(raw.cast(r.val))
    if n == 0 {
      break // peer closed
    }
  }
  let st = rt.auk_str_from_utf8(all)
  ut.check(st.ok, "st.ok")
  ut.str_eq(st.val, "echo:ping 🦆", "st.val")
  rt.auk_conn_close(c.val)
  let after = rt.auk_conn_read(c.val, 10)
  ut.check(!after.ok, "!after.ok")
  ut.rel(raw.cast(after.err))
  ut.rel(raw.cast(c.val))
  ut.rel(raw.cast(all))
  ut.rel(raw.cast(bytes))
  ut.rel(raw.cast(msg))
  let _ = rt.pthread_join(th.w0, raw.null())
  let _ = rt.close(lfd)

  // nothing listening on the port any more: connection refused
  c = rt.auk_net_tcp(host, port)
  ut.check(!c.ok, "!c.ok")
  ut.rel(raw.cast(c.err))
  let bad = ut.s("no-such-host.invalid")
  c = rt.auk_net_tcp(bad, 80)
  ut.check(!c.ok, "!c.ok")
  ut.rel(raw.cast(c.err))
  ut.rel(raw.cast(bad))

  // TLS to the closed port fails cleanly too (more in test_net.auk)
  c = rt.auk_net_tls(host, port)
  ut.check(!c.ok, "!c.ok")
  ut.rel(raw.cast(c.err))
  ut.rel(raw.cast(host))
}

// ---- time, rand, env -------------------------------------------------------------------------------

raw struct Argv4 {
  a: [raw.Ptr<u8>; 4],
}

fn time_rand_env() uses raw, ffi {
  let t0 = rt.auk_time_now()
  ut.check(t0 > 1600000000000, "t0 > 1600000000000")
  rt.auk_time_sleep(20)
  ut.check(rt.auk_time_now() - t0 >= 19, "auk_time_now() - t0 >= 19")
  var seen: [bool; 7]
  let sp = raw.cast<bool>(raw.addr_of(&seen))
  raw.fill(raw.cast<u8>(sp), 0, 7)
  var i = 0
  while i < 2000 {
    let r = rt.auk_rand_int(1, 6)
    ut.check(r >= 1 && r <= 6, "r >= 1 && r <= 6")
    sp.at(r) = true
    i += 1
  }
  i = 1
  while i <= 6 {
    ut.check(sp.at(i), "seen[i]")
    i += 1
  }
  ut.eq(rt.auk_rand_int(5, 5), 5, "auk_rand_int(5, 5)")
  let _ = rt.auk_rand_int(INT64_MIN, INT64_MAX)
  let f = rt.auk_rand_float()
  ut.check(f >= 0.0 && f < 1.0, "f >= 0.0 && f < 1.0")

  let _ = rt.setenv("AUK_TEST_VAR", "quäck", 1)
  let k = ut.s("AUK_TEST_VAR")
  let k2 = ut.s("AUK_TEST_UNSET_VAR")
  let v = rt.auk_env_get(k)
  ut.check(v.some, "v.some")
  ut.str_eq(v.val, "quäck", "v.val")
  ut.check(!rt.auk_env_get(k2).some, "!auk_env_get(k2).some")
  ut.rel(raw.cast(k))
  ut.rel(raw.cast(k2))

  var argv = Argv4 {}
  let ap = raw.cast<raw.Ptr<u8>>(raw.addr_of(&argv))
  ap.at(0) = "prog"
  ap.at(1) = "a"
  ap.at(2) = "b"
  rt.auk_env_set_args(3, ap)
  let args = rt.auk_env_args()
  ut.eq(rt.auk_arr_len(args), 3, "auk_arr_len(args)")
  ut.check(rt.auk_str_eq_lit(raw.cast(ut.at_ptr(args, 2)), "b"), "auk_str_eq_lit(AT(AukStr *, args, 2), \"b\")")
  ut.rel(raw.cast(args)) // immortal: harmless
}

fn p_rand(c: raw.Ptr<()>) uses ffi {
  let _ = rt.auk_rand_int(3, 1)
}

fn rand_bad_range_panics() uses raw, ffi = ut.expect_panic(raw.fn_of(p_rand), raw.null(), "lo > hi")

// ---- hooks ------------------------------------------------------------------------------------------

fn p_requires(c: raw.Ptr<()>) uses ffi = rt.auk_requires_fail("isqrt.auk:2:12", "n >= 0")

fn p_ensures(c: raw.Ptr<()>) uses ffi = rt.auk_ensures_fail("isqrt.auk:3:11", "result * result <= n")

fn p_hole(c: raw.Ptr<()>) uses ffi = rt.auk_hole("isqrt.auk:4:3", "int")

fn p_assert_cmp(c: raw.Ptr<()>) uses ffi {
  let l = ut.s("1")
  let r = ut.s("2")
  rt.auk_assert_fail_cmp("t.auk:9:3", "a == b", l, r)
}

fn do_peek(c: raw.Ptr<()>) uses raw, ffi {
  let v = rt.auk_str_from_int(84)
  rt.auk_peek("main.auk:7", "x * 2", v)
  ut.rel(raw.cast(v))
}

fn hooks_contracts_holes_peek() uses raw, ffi {
  ut.expect_panic(raw.fn_of(p_requires), raw.null(), "panic: requires failed: n >= 0\n  at isqrt.auk:2:12\n")
  ut.expect_panic(raw.fn_of(p_ensures), raw.null(), "ensures failed: result * result <= n")
  ut.expect_panic(raw.fn_of(p_hole), raw.null(), "unfilled hole (expected int)\n  at isqrt.auk:4:3")
  ut.expect_panic(raw.fn_of(p_assert_cmp), raw.null(), "assertion failed: a == b\n  left: 1\n  right: 2")
  var out: raw.Ptr<u8> = raw.null()
  let code = ut.child(raw.fn_of(do_peek), raw.null(), raw.addr_of(&out))
  ut.eq(i64(code), 0, "code")
  ut.text_eq(out, "[main.auk:7] x * 2 = 84\n", "out")
}

// ---- auk_test_main -------------------------------------------------------------------------------

fn t_pass(): raw.Ptr<abi.Err> uses raw, ffi {
  ut.cprint("this output is hidden\n")
  raw.null()
}

fn t_panic(): raw.Ptr<abi.Err> uses raw, ffi {
  ut.cprint("before the panic\n")
  let _ = rt.auk_add(INT64_MAX, 1, "tests.auk:5:7")
  raw.null()
}

fn t_err(): raw.Ptr<abi.Err> uses ffi = ut.err_msg("fail() called")

fn runner_all(c: raw.Ptr<()>) uses raw, ffi {
  var argv = Argv4 {}
  let ap = raw.cast<raw.Ptr<u8>>(raw.addr_of(&argv))
  ap.at(0) = "tests"
  rt.auk_test_register("passes", raw.fn_of(t_pass))
  rt.auk_test_register("overflows", raw.fn_of(t_panic))
  rt.auk_test_register("returns an error", raw.fn_of(t_err))
  let code = rt.auk_test_main(1, ap)
  let _ = rt.fflush(raw.null())
  rt.c_exit(if code == 1 { 42 } else { 43 })
}

fn runner_filtered(c: raw.Ptr<()>) uses raw, ffi {
  var argv = Argv4 {}
  let ap = raw.cast<raw.Ptr<u8>>(raw.addr_of(&argv))
  ap.at(0) = "tests"
  ap.at(1) = "pass"
  rt.auk_test_register("passes", raw.fn_of(t_pass))
  rt.auk_test_register("overflows", raw.fn_of(t_panic))
  rt.c_exit(if rt.auk_test_main(2, ap) == 0 { 42 } else { 43 })
}

/// A child's exit code must be want: else fail with its output.
fn expect_code(code: i32, want: i32, out: raw.Ptr<u8>) uses raw, ffi {
  if code != want {
    let n = rt.strlen(out) + 64
    let m = ut.scratch(n)
    let _ = rt.snprintf(m, n, "exit %d; output:\n%s", code, out)
    ut.fail(m)
  }
}

fn test_runner() uses raw, ffi {
  var out: raw.Ptr<u8> = raw.null()
  var code = ut.child(raw.fn_of(runner_all), raw.null(), raw.addr_of(&out))
  expect_code(code, 42, out)
  ut.text_eq(
    out,
    "ok passes\nFAIL overflows\n    before the panic\n    panic: integer overflow in `+`\n      at tests.auk:5:7\nFAIL returns an error\n    error: fail() called\n1 passed, 2 failed\n",
    "out",
  )
  code = ut.child(raw.fn_of(runner_filtered), raw.null(), raw.addr_of(&out))
  expect_code(code, 42, out)
  ut.text_eq(out, "ok passes\n1 passed, 0 failed\n", "out")
}

// ---- auk_main_wrapper ---------------------------------------------------------------------------------

/// (an `export fn`: a function returning a raw struct has a C address only as one)
export fn ut_core_main_ok(args: raw.Ptr<abi.Arr>): abi.ResInt uses raw, ffi {
  let _ = rt.printf("argc=%lld\n", rt.auk_arr_len(args))
  abi.ResInt { ok: true, val: 7, err: raw.null() }
}

export fn ut_core_main_err(args: raw.Ptr<abi.Arr>): abi.ResInt uses raw, ffi {
  let cause = ut.err_msg("no such file")
  let m = ut.s("loading config")
  let e = rt.auk_err_wrap(m, cause)
  ut.rel(raw.cast(m))
  ut.rel(raw.cast(cause))
  abi.ResInt { ok: false, val: 0, err: e }
}

fn wrap_ok(c: raw.Ptr<()>) uses raw, ffi {
  var argv = Argv4 {}
  let ap = raw.cast<raw.Ptr<u8>>(raw.addr_of(&argv))
  ap.at(0) = "prog"
  ap.at(1) = "x"
  rt.c_exit(rt.auk_main_wrapper(2, ap, raw.fn_of(ut_core_main_ok)))
}

fn wrap_err(c: raw.Ptr<()>) uses raw, ffi {
  var argv = Argv4 {}
  let ap = raw.cast<raw.Ptr<u8>>(raw.addr_of(&argv))
  ap.at(0) = "prog"
  rt.c_exit(rt.auk_main_wrapper(1, ap, raw.fn_of(ut_core_main_err)))
}

fn main_wrapper() uses raw, ffi {
  var out: raw.Ptr<u8> = raw.null()
  var code = ut.child(raw.fn_of(wrap_ok), raw.null(), raw.addr_of(&out))
  ut.eq(i64(code), 7, "code")
  ut.text_eq(out, "argc=2\n", "out")
  code = ut.child(raw.fn_of(wrap_err), raw.null(), raw.addr_of(&out))
  ut.eq(i64(code), 1, "code")
  ut.text_eq(out, "error: loading config: no such file\n", "out")
}

fn do_print(c: raw.Ptr<()>) uses raw, ffi {
  let x = ut.s("héllo")
  rt.auk_print(x)
  rt.auk_print_lit("bye")
  ut.rel(raw.cast(x))
}

fn print_lines() uses raw, ffi {
  var out: raw.Ptr<u8> = raw.null()
  let code = ut.child(raw.fn_of(do_print), raw.null(), raw.addr_of(&out))
  ut.eq(i64(code), 0, "code")
  ut.text_eq(out, "héllo\nbye\n", "out")
}

// Compiler-emitted globals (string literals) are made immortal; the cleanup hook and the
// AUK_LEAK_CHECK leak check used by `auk test` and auk_main_wrapper.
raw var cleanup_calls: i64 = 0
raw var cleanup_global: raw.Ptr<abi.Str> = raw.null()

fn cleanup_fn() uses raw, ffi {
  cleanup_calls += 1
  ut.rel(raw.cast(cleanup_global))
  cleanup_global = raw.null()
}

fn immortal_and_leak_check() uses raw, ffi {
  let live = rt.auk_live_objects()
  let lit = ut.s("forever")
  rt.auk_make_immortal(raw.cast(lit))
  ut.eq(rt.auk_live_objects(), live, "auk_live_objects()")
  let _ = rt.auk_retain(raw.cast(lit))
  ut.rel(raw.cast(lit))
  ut.rel(raw.cast(lit))
  ut.check(rt.auk_str_eq_lit(lit, "forever"), "auk_str_eq_lit(lit, \"forever\")")
  rt.auk_make_immortal(raw.null())

  // without AUK_LEAK_CHECK the check is a no-op
  let _ = rt.unsetenv("AUK_LEAK_CHECK")
  cleanup_global = ut.s("global")
  rt.auk_set_cleanup(raw.cast<()>(raw.fn_of(cleanup_fn)))
  ut.eq(rt.auk_leak_check(), 0, "auk_leak_check()")
  ut.eq(cleanup_calls, 0, "cleanup_calls")
  // with it: the cleanup runs first, then live objects are counted
  let _ = rt.setenv("AUK_LEAK_CHECK", "1", 1)
  ut.eq(rt.auk_leak_check() - live, 0, "auk_leak_check() - live")
  ut.eq(cleanup_calls, 1, "cleanup_calls")
  ut.check(cleanup_global.is_null(), "cleanup_global == NULL")
  let _ = rt.unsetenv("AUK_LEAK_CHECK")
  rt.auk_set_cleanup(raw.null())
}

/// The tests, in the C file's order.
pub fn all() uses raw, ffi {
  ut.run("arith_checked", raw.fn_of(arith_checked))
  ut.run("arith_panics_exit_101", raw.fn_of(arith_panics_exit_101))
  ut.run("err_chain_and_payload", raw.fn_of(err_chain_and_payload))
  ut.run("err_unwrap_panics", raw.fn_of(err_unwrap_panics))
  ut.run("value_tree", raw.fn_of(value_tree))
  ut.run("value_accessor_panics", raw.fn_of(value_accessor_panics))
  ut.run("closures_env_rc", raw.fn_of(closures_env_rc))
  ut.run("tasks_run_concurrently", raw.fn_of(tasks_run_concurrently))
  ut.run("tasks_many_and_unawaited", raw.fn_of(tasks_many_and_unawaited))
  ut.run("tasks_atomic_refcounts", raw.fn_of(tasks_atomic_refcounts))
  ut.run("fs_round_trip", raw.fn_of(fs_round_trip))
  ut.run("proc_run", raw.fn_of(proc_run))
  ut.run("net_tcp_echo", raw.fn_of(net_tcp_echo))
  ut.run("time_rand_env", raw.fn_of(time_rand_env))
  ut.run("rand_bad_range_panics", raw.fn_of(rand_bad_range_panics))
  ut.run("hooks_contracts_holes_peek", raw.fn_of(hooks_contracts_holes_peek))
  ut.run("test_runner", raw.fn_of(test_runner))
  ut.run("main_wrapper", raw.fn_of(main_wrapper))
  ut.run("print_lines", raw.fn_of(print_lines))
  ut.run("immortal_and_leak_check", raw.fn_of(immortal_and_leak_check))
}

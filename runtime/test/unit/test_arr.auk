/// [T]: element lifetimes, copy-on-write, slices, sorting (was runtime/c/test/test_arr.c).

fn arr_basic_ops() uses raw, ffi {
  var a = rt.auk_arr_new(rt.OPS_INT, 0)
  let pa = raw.addr_of(&a)
  var i: i64 = 0
  while i < 100 {
    rt.auk_arr_push(pa, raw.cast(raw.addr_of(&i)))
    i += 1
  }
  ut.eq(rt.auk_arr_len(a), 100, "auk_arr_len(a)")
  ut.eq(ut.at_int(a, 99), 99, "AT(int64_t, a, 99)")
  var out: i64 = -1
  let po: raw.Ptr<()> = raw.cast(raw.addr_of(&out))
  ut.check(rt.auk_arr_pop(pa, po) && out == 99, "auk_arr_pop(&a, &out) && out == 99")
  ut.eq(rt.auk_arr_len(a), 99, "auk_arr_len(a)")
  var v: i64 = 1000
  let pv: raw.Ptr<()> = raw.cast(raw.addr_of(&v))
  rt.auk_arr_insert(pa, 0, pv, "t")
  ut.eq(ut.at_int(a, 0), 1000, "AT(int64_t, a, 0)")
  ut.eq(ut.at_int(a, 1), 0, "AT(int64_t, a, 1)")
  v = 2000
  rt.auk_arr_insert(pa, rt.auk_arr_len(a), pv, "t")
  ut.eq(ut.at_int(a, 100), 2000, "AT(int64_t, a, 100)")
  rt.auk_arr_remove(pa, 0, po, "t")
  ut.eq(out, 1000, "out")
  ut.eq(ut.at_int(a, 0), 0, "AT(int64_t, a, 0)")
  v = -5
  rt.auk_arr_set(pa, 3, pv, "t")
  ut.eq(ut.at_int(a, 3), -5, "AT(int64_t, a, 3)")
  ut.check(rt.auk_arr_get_opt(a, 3, po) && out == -5, "auk_arr_get_opt(a, 3, &out) && out == -5")
  ut.check(!rt.auk_arr_get_opt(a, 101, po), "!auk_arr_get_opt(a, 101, &out)")
  ut.check(!rt.auk_arr_get_opt(a, -1, po), "!auk_arr_get_opt(a, -1, &out)")
  rt.auk_arr_clear(pa)
  ut.eq(rt.auk_arr_len(a), 0, "auk_arr_len(a)")
  ut.check(!rt.auk_arr_pop(pa, po), "!auk_arr_pop(&a, &out)")
  ut.rel(raw.cast(a))
}

fn bounds_at(ctx: raw.Ptr<()>) uses raw, ffi {
  let _ = rt.auk_arr_at(raw.cast(ctx), 3, "list.auk:9:5")
}

fn bounds_set(ctx: raw.Ptr<()>) uses raw, ffi {
  var a: raw.Ptr<abi.Arr> = raw.cast(ctx)
  var v: i64 = 1
  rt.auk_arr_set(raw.addr_of(&a), -1, raw.cast(raw.addr_of(&v)), "list.auk:10:5")
}

fn bounds_remove(ctx: raw.Ptr<()>) uses raw, ffi {
  var a: raw.Ptr<abi.Arr> = raw.cast(ctx)
  rt.auk_arr_remove(raw.addr_of(&a), 7, raw.null(), "x")
}

fn bounds_slice(ctx: raw.Ptr<()>) uses raw, ffi {
  let _ = rt.auk_arr_slice(raw.cast(ctx), 1, 4, "x")
}

fn arr_bounds_panics() uses raw, ffi {
  let a = ut.ints4(3, 1, 2, 3, 0)
  let ctx: raw.Ptr<()> = raw.cast(a)
  ut.expect_panic(raw.fn_of(bounds_at), ctx, "index 3 out of range for length 3\n  at list.auk:9:5")
  ut.expect_panic(raw.fn_of(bounds_set), ctx, "index -1 out of range for length 3")
  ut.expect_panic(raw.fn_of(bounds_remove), ctx, "index 7 out of range")
  ut.expect_panic(raw.fn_of(bounds_slice), ctx, "slice 1..4 out of range for length 3")
  ut.rel(ctx)
}

fn arr_str_elements_lifetimes() uses raw, ffi {
  var a = rt.auk_arr_new(rt.OPS_STR, 0)
  let pa = raw.addr_of(&a)
  var sh = ut.s("shared")
  var i = 0
  while i < 10 {
    rt.auk_arr_push(pa, raw.cast(raw.addr_of(&sh)))
    i += 1
  }
  ut.eq(rt.auk_refcount(raw.cast(sh)), 11, "auk_refcount(sh)")
  var t = ut.s("other")
  rt.auk_arr_set(pa, 0, raw.cast(raw.addr_of(&t)), "t")
  ut.eq(rt.auk_refcount(raw.cast(sh)), 10, "auk_refcount(sh)")
  ut.eq(rt.auk_refcount(raw.cast(t)), 2, "auk_refcount(t)")
  // setting an element to itself
  rt.auk_arr_set(pa, 0, rt.auk_arr_at(a, 0, "t"), "t")
  ut.eq(rt.auk_refcount(raw.cast(t)), 2, "auk_refcount(t)")
  // push an element of the same array (may realloc)
  rt.auk_arr_push(pa, rt.auk_arr_at(a, 0, "t"))
  ut.eq(rt.auk_refcount(raw.cast(t)), 3, "auk_refcount(t)")
  var popped: raw.Ptr<abi.Str> = raw.null()
  ut.check(rt.auk_arr_pop(pa, raw.cast(raw.addr_of(&popped))) && popped == t, "auk_arr_pop(&a, &popped) && popped == t")
  ut.rel(raw.cast(popped))
  var got: raw.Ptr<abi.Str> = raw.null()
  ut.check(rt.auk_arr_get_opt(a, 1, raw.cast(raw.addr_of(&got))) && got == sh, "auk_arr_get_opt(a, 1, &got) && got == sh")
  ut.eq(rt.auk_refcount(raw.cast(sh)), 11, "auk_refcount(sh)")
  ut.rel(raw.cast(got))
  ut.str_eq(
    rt.auk_arr_show(a),
    "[\"other\", \"shared\", \"shared\", \"shared\", \"shared\", \"shared\", \"shared\", \"shared\", \"shared\", \"shared\"]",
    "auk_arr_show(a)",
  )
  ut.rel(raw.cast(a))
  ut.eq(rt.auk_refcount(raw.cast(sh)), 1, "auk_refcount(sh)")
  ut.eq(rt.auk_refcount(raw.cast(t)), 1, "auk_refcount(t)")
  ut.rel(raw.cast(sh))
  ut.rel(raw.cast(t))
}

fn arr_push_own_moves() uses raw, ffi {
  var a = rt.auk_arr_new(rt.OPS_STR, 0)
  var i = 0
  while i < 20 {
    var x = ut.s("owned") // refcount 1, handed to the list
    rt.auk_arr_push_own(raw.addr_of(&a), raw.cast(raw.addr_of(&x)))
    ut.eq(rt.auk_refcount(raw.cast(x)), 1, "auk_refcount(x)")
    i += 1
  }
  // a shared list is copied first; the copy takes the value
  var b: raw.Ptr<abi.Arr> = raw.cast(ut.ret(raw.cast(a)))
  var y = ut.s("new")
  rt.auk_arr_push_own(raw.addr_of(&b), raw.cast(raw.addr_of(&y)))
  ut.check(a != b, "a != b")
  ut.eq(rt.auk_arr_len(a), 20, "auk_arr_len(a)")
  ut.eq(rt.auk_arr_len(b), 21, "auk_arr_len(b)")
  ut.eq(rt.auk_refcount(raw.cast(y)), 1, "auk_refcount(y)")
  ut.eq(rt.auk_refcount(ut.at_ptr(a, 0)), 2, "auk_refcount(AT(AukStr *, a, 0))")
  ut.rel(raw.cast(b))
  ut.rel(raw.cast(a))
}

fn arr_copy_on_write() uses raw, ffi {
  let a = ut.ints4(3, 1, 2, 3, 0)
  var b: raw.Ptr<abi.Arr> = raw.cast(ut.ret(raw.cast(a))) // `let b = a`
  var v: i64 = 99
  let pv: raw.Ptr<()> = raw.cast(raw.addr_of(&v))
  rt.auk_arr_set(raw.addr_of(&b), 0, pv, "t") // mutating the shared array copies
  ut.check(a != b, "a != b")
  ut.eq(ut.at_int(a, 0), 1, "AT(int64_t, a, 0)")
  ut.eq(ut.at_int(b, 0), 99, "AT(int64_t, b, 0)")
  ut.eq(rt.auk_refcount(raw.cast(a)), 1, "auk_refcount(a)")
  let b_before = b
  rt.auk_arr_push(raw.addr_of(&b), pv) // unique now: mutates in place (no copy)
  ut.check(b == b_before || rt.auk_arr_len(b) == 4, "b == b_before || auk_arr_len(b) == 4")
  ut.eq(rt.auk_arr_len(a), 3, "auk_arr_len(a)")
  ut.eq(rt.auk_arr_len(b), 4, "auk_arr_len(b)")
  // push / pop / remove / insert / sort / reverse on a shared array
  var c: raw.Ptr<abi.Arr> = raw.cast(ut.ret(raw.cast(a)))
  let pc = raw.addr_of(&c)
  rt.auk_arr_push(pc, pv)
  rt.auk_arr_reverse(pc)
  ut.eq(ut.at_int(c, 0), 99, "AT(int64_t, c, 0)")
  ut.str_eq(rt.auk_arr_show(a), "[1, 2, 3]", "auk_arr_show(a)")
  ut.rel(raw.cast(c))
  c = raw.cast(ut.ret(raw.cast(a)))
  rt.auk_arr_remove(pc, 0, raw.null(), "t")
  ut.str_eq(rt.auk_arr_show(a), "[1, 2, 3]", "auk_arr_show(a)")
  ut.str_eq(rt.auk_arr_show(c), "[2, 3]", "auk_arr_show(c)")
  ut.rel(raw.cast(c))
  c = raw.cast(ut.ret(raw.cast(a)))
  rt.auk_arr_clear(pc)
  ut.eq(rt.auk_arr_len(a), 3, "auk_arr_len(a)")
  ut.rel(raw.cast(c))
  ut.rel(raw.cast(a))
  ut.rel(raw.cast(b))
}

fn arr_cow_nested_strings() uses raw, ffi {
  // [[str]]: copying the outer array must retain inner arrays
  var inner = rt.auk_arr_new(rt.OPS_STR, 0)
  var x = ut.s("x")
  rt.auk_arr_push(raw.addr_of(&inner), raw.cast(raw.addr_of(&x)))
  var outer = rt.auk_arr_new(rt.OPS_ARR, 0)
  rt.auk_arr_push(raw.addr_of(&outer), raw.cast(raw.addr_of(&inner)))
  rt.auk_arr_push(raw.addr_of(&outer), raw.cast(raw.addr_of(&inner)))
  var cp: raw.Ptr<abi.Arr> = raw.cast(ut.ret(raw.cast(outer)))
  let _ = rt.auk_arr_pop(raw.addr_of(&cp), raw.null())
  ut.eq(rt.auk_arr_len(outer), 2, "auk_arr_len(outer)")
  ut.eq(rt.auk_arr_len(cp), 1, "auk_arr_len(copy)")
  ut.eq(rt.auk_refcount(raw.cast(inner)), 4, "auk_refcount(inner)") // our ref + 2 in outer + 1 in copy
  ut.str_eq(rt.auk_arr_show(outer), "[[\"x\"], [\"x\"]]", "auk_arr_show(outer)")
  // mutate inner via outer[0]: COW of the element
  let slot: raw.Ptr<raw.Ptr<abi.Arr>> = raw.cast(rt.auk_arr_make_unique(raw.addr_of(&cp)))
  var y = ut.s("y")
  rt.auk_arr_push(slot, raw.cast(raw.addr_of(&y)))
  ut.str_eq(rt.auk_arr_show(cp), "[[\"x\", \"y\"]]", "auk_arr_show(copy)")
  ut.str_eq(rt.auk_arr_show(outer), "[[\"x\"], [\"x\"]]", "auk_arr_show(outer)")
  ut.check(rt.auk_arr_eq(outer, outer), "auk_arr_eq(outer, outer)")
  ut.check(!rt.auk_arr_eq(outer, cp), "!auk_arr_eq(outer, copy)")
  ut.rel(raw.cast(cp))
  ut.rel(raw.cast(outer))
  ut.rel(raw.cast(inner))
  ut.rel(raw.cast(x))
  ut.rel(raw.cast(y))
}

fn arr_slices_share() uses raw, ffi {
  var xs: [i64; 6]
  let px = raw.cast<i64>(raw.addr_of(&xs))
  var i = 0
  while i < 6 {
    px.at(i) = i64(i)
    i += 1
  }
  let a = ut.ints(px, 6)
  var sl = rt.auk_arr_slice(a, 1, 5, "t")
  ut.eq(rt.auk_arr_len(sl), 4, "auk_arr_len(sl)")
  ut.check(sl.data == a.data.offset(8), "sl->data == a->data + sizeof(int64_t)") // shares the buffer, O(1)
  ut.eq(ut.at_int(sl, 0), 1, "AT(int64_t, sl, 0)")
  var ss = rt.auk_arr_slice(sl, 1, 3, "t") // [h, ..t] of a slice
  ut.check(ss.base == a, "ss->base == a") // views always point at the owner
  ut.str_eq(rt.auk_arr_show(ss), "[2, 3]", "auk_arr_show(ss)")
  ut.eq(rt.auk_refcount(raw.cast(a)), 3, "auk_refcount(a)")
  // mutating a slice copies; the base is untouched
  var v: i64 = 42
  rt.auk_arr_set(raw.addr_of(&sl), 0, raw.cast(raw.addr_of(&v)), "t")
  ut.check(sl.base.is_null(), "sl->base == NULL")
  ut.str_eq(rt.auk_arr_show(sl), "[42, 2, 3, 4]", "auk_arr_show(sl)")
  ut.str_eq(rt.auk_arr_show(a), "[0, 1, 2, 3, 4, 5]", "auk_arr_show(a)")
  // push on a slice must not clobber the base's next element
  rt.auk_arr_push(raw.addr_of(&ss), raw.cast(raw.addr_of(&v)))
  ut.str_eq(rt.auk_arr_show(ss), "[2, 3, 42]", "auk_arr_show(ss)")
  ut.str_eq(rt.auk_arr_show(a), "[0, 1, 2, 3, 4, 5]", "auk_arr_show(a)")
  // the base stays alive while a view exists
  let tail = rt.auk_arr_slice(a, 4, 6, "t")
  ut.rel(raw.cast(a))
  ut.str_eq(rt.auk_arr_show(tail), "[4, 5]", "auk_arr_show(tail)")
  let empty = rt.auk_arr_slice(tail, 2, 2, "t")
  ut.eq(rt.auk_arr_len(empty), 0, "auk_arr_len(empty)")
  let t2 = rt.auk_arr_take(tail, 10)
  let k2 = rt.auk_arr_skip(tail, 1)
  ut.str_eq(rt.auk_arr_show(t2), "[4, 5]", "auk_arr_show(t2)")
  ut.str_eq(rt.auk_arr_show(k2), "[5]", "auk_arr_show(k2)")
  ut.rel(raw.cast(t2))
  ut.rel(raw.cast(k2))
  ut.rel(raw.cast(empty))
  ut.rel(raw.cast(tail))
  ut.rel(raw.cast(sl))
  ut.rel(raw.cast(ss))
}

/// Push the str of text onto *pa and release our reference.
fn push_word(pa: raw.Ptr<raw.Ptr<abi.Arr>>, text: raw.Ptr<u8>) uses raw, ffi {
  var w = ut.s(text)
  rt.auk_arr_push(pa, raw.cast(raw.addr_of(&w)))
  ut.rel(raw.cast(w))
}

fn arr_slices_of_strings() uses raw, ffi {
  var a = rt.auk_arr_new(rt.OPS_STR, 0)
  push_word(raw.addr_of(&a), "a")
  push_word(raw.addr_of(&a), "b")
  push_word(raw.addr_of(&a), "c")
  push_word(raw.addr_of(&a), "d")
  let v = rt.auk_arr_slice(a, 2, 4, "t")
  ut.rel(raw.cast(a))
  let c = rt.auk_arr_copy(v)
  ut.rel(raw.cast(v)) // frees the base and its strings
  ut.str_eq(rt.auk_arr_show(c), "[\"c\", \"d\"]", "auk_arr_show(c)")
  ut.rel(raw.cast(c))
}

fn arr_concat_reverse_extend() uses raw, ffi {
  var a = ut.ints4(2, 1, 2, 0, 0)
  let b = ut.ints4(3, 3, 4, 5, 0)
  let c = rt.auk_arr_concat(a, b)
  ut.str_eq(rt.auk_arr_show(c), "[1, 2, 3, 4, 5]", "auk_arr_show(c)")
  let r = rt.auk_arr_reversed(c)
  ut.str_eq(rt.auk_arr_show(r), "[5, 4, 3, 2, 1]", "auk_arr_show(r)")
  ut.str_eq(rt.auk_arr_show(c), "[1, 2, 3, 4, 5]", "auk_arr_show(c)")
  rt.auk_arr_extend(raw.addr_of(&a), a) // self-extend
  ut.str_eq(rt.auk_arr_show(a), "[1, 2, 1, 2]", "auk_arr_show(a)")
  ut.eq(rt.auk_arr_sum_int(c, "t"), 15, "auk_arr_sum_int(c, T)")
  let sep = ut.s(", ")
  ut.str_eq(rt.auk_arr_join(c, sep), "1, 2, 3, 4, 5", "auk_arr_join(c, sep)")
  ut.rel(raw.cast(sep))
  var four: i64 = 4
  var nine: i64 = 9
  var three: i64 = 3
  ut.check(rt.auk_arr_contains(c, raw.cast(raw.addr_of(&four))), "auk_arr_contains(c, &four)")
  ut.check(!rt.auk_arr_contains(c, raw.cast(raw.addr_of(&nine))), "!auk_arr_contains(c, &nine)")
  ut.check(rt.auk_arr_index_of(c, raw.cast(raw.addr_of(&three))).val == 2, "auk_arr_index_of(c, &three).val == 2")
  ut.check(rt.auk_arr_cmp(a, c) < 0 || rt.auk_arr_cmp(a, c) > 0, "auk_arr_cmp(a, c) < 0 || auk_arr_cmp(a, c) > 0")
  let p = ut.ints4(2, 1, 2, 0, 0)
  ut.check(rt.auk_arr_cmp(p, c) < 0, "auk_arr_cmp(p, c) < 0") // prefix sorts first
  ut.check(rt.auk_arr_hash(p) == rt.auk_arr_hash(b) || !rt.auk_arr_eq(p, b), "auk_arr_hash(p) == auk_arr_hash(b) || !auk_arr_eq(p, b)")
  ut.rel(raw.cast(a))
  ut.rel(raw.cast(b))
  ut.rel(raw.cast(c))
  ut.rel(raw.cast(r))
  ut.rel(raw.cast(p))
}

raw struct Pair {
  key: i64,
  seq: i64,
}

fn pair_cmp(x: raw.Ptr<()>, y: raw.Ptr<()>, ctx: raw.Ptr<()>): i32 uses raw, ffi =
  rt.auk_int_cmp(raw.cast<Pair>(x).key, raw.cast<Pair>(y).key)

raw var pair_ops: abi.ElemOps = abi.ElemOps { size: raw.size_of<Pair>() }

fn arr_sort_stable() uses raw, ffi {
  var a = rt.auk_arr_new(raw.addr_of(&pair_ops), 0)
  var x: u64 = 12345
  var i: i64 = 0
  while i < 1000 {
    x = x * 6364136223846793005 + 1442695040888963407
    var p = Pair { key: i64(x >> 59), seq: i } // lots of equal keys
    rt.auk_arr_push(raw.addr_of(&a), raw.cast(raw.addr_of(&p)))
    i += 1
  }
  let keep = ut.ret(raw.cast(a))
  rt.auk_arr_sort_with(raw.addr_of(&a), raw.fn_of(pair_cmp), raw.null())
  let ps: raw.Ptr<Pair> = raw.cast(rt.auk_arr_data(a))
  var k: i64 = 1
  while k < 1000 {
    ut.check(ps.at(k - 1).key <= ps.at(k).key, "ps[i - 1].key <= ps[i].key")
    if ps.at(k - 1).key == ps.at(k).key {
      ut.check(ps.at(k - 1).seq < ps.at(k).seq, "ps[i - 1].seq < ps[i].seq")
    }
    k += 1
  }
  ut.check(raw.cast<Pair>(rt.auk_arr_data(raw.cast(keep))).seq == 0, "((const Pair *)auk_arr_data(keep))->seq == 0") // original untouched
  ut.rel(keep)
  ut.rel(raw.cast(a))

  var w = rt.auk_arr_new(rt.OPS_STR, 0)
  push_word(raw.addr_of(&w), "pear")
  push_word(raw.addr_of(&w), "apple")
  push_word(raw.addr_of(&w), "éclair")
  push_word(raw.addr_of(&w), "fig")
  push_word(raw.addr_of(&w), "apple")
  let sorted = rt.auk_arr_sorted(w)
  ut.str_eq(rt.auk_arr_show(sorted), "[\"apple\", \"apple\", \"fig\", \"pear\", \"éclair\"]", "auk_arr_show(sorted)")
  var f = rt.auk_arr_new(rt.OPS_FLOAT, 0)
  var ds: [float; 4]
  let pd = raw.cast<float>(raw.addr_of(&ds))
  pd.at(0) = 2.5
  pd.at(1) = -1.0
  pd.at(2) = 0.1
  pd.at(3) = 10.0
  var j = 0
  while j < 4 {
    rt.auk_arr_push(raw.addr_of(&f), raw.cast(pd.offset(j)))
    j += 1
  }
  rt.auk_arr_sort(raw.addr_of(&f))
  ut.str_eq(rt.auk_arr_show(f), "[-1.0, 0.1, 2.5, 10.0]", "auk_arr_show(f)")
  ut.rel(raw.cast(w))
  ut.rel(raw.cast(sorted))
  ut.rel(raw.cast(f))
}

fn arr_literal_and_show() uses raw, ffi {
  var xs: [i64; 3]
  let px = raw.cast<i64>(raw.addr_of(&xs))
  px.at(0) = 3
  px.at(1) = 1
  px.at(2) = 2
  let a = rt.auk_arr_from(rt.OPS_INT, raw.cast(px), 3)
  ut.str_eq(rt.auk_arr_show(a), "[3, 1, 2]", "auk_arr_show(a)")
  let e = rt.auk_arr_new(rt.OPS_INT, 0)
  ut.str_eq(rt.auk_arr_show(e), "[]", "auk_arr_show(e)")
  var bs: [bool; 2]
  let pb = raw.cast<bool>(raw.addr_of(&bs))
  pb.at(0) = true
  pb.at(1) = false
  let b = rt.auk_arr_from(rt.OPS_BOOL, raw.cast(pb), 2)
  ut.str_eq(rt.auk_arr_show(b), "[true, false]", "auk_arr_show(b)")
  var cs: [u32; 2]
  let pc = raw.cast<u32>(raw.addr_of(&cs))
  pc.at(0) = 97 // 'a'
  pc.at(1) = 98 // 'b'
  let c = rt.auk_arr_from(rt.OPS_CHAR, raw.cast(pc), 2)
  let empty = ut.s("")
  ut.str_eq(rt.auk_arr_join(c, empty), "ab", "auk_arr_join(c, empty)")
  ut.rel(raw.cast(empty))
  ut.rel(raw.cast(a))
  ut.rel(raw.cast(e))
  ut.rel(raw.cast(b))
  ut.rel(raw.cast(c))
}

fn sum_overflow(ctx: raw.Ptr<()>) uses raw, ffi {
  let a = ut.ints4(2, 9223372036854775807, 1, 0, 0)
  let _ = rt.auk_arr_sum_int(a, "sum.auk:1:1")
}

fn arr_sum_overflow_panics() uses raw, ffi = ut.expect_panic(raw.fn_of(sum_overflow), raw.null(), "integer overflow")

/// The tests, in the C file's order.
pub fn all() uses raw, ffi {
  ut.run("arr_basic_ops", raw.fn_of(arr_basic_ops))
  ut.run("arr_bounds_panics", raw.fn_of(arr_bounds_panics))
  ut.run("arr_str_elements_lifetimes", raw.fn_of(arr_str_elements_lifetimes))
  ut.run("arr_push_own_moves", raw.fn_of(arr_push_own_moves))
  ut.run("arr_copy_on_write", raw.fn_of(arr_copy_on_write))
  ut.run("arr_cow_nested_strings", raw.fn_of(arr_cow_nested_strings))
  ut.run("arr_slices_share", raw.fn_of(arr_slices_share))
  ut.run("arr_slices_of_strings", raw.fn_of(arr_slices_of_strings))
  ut.run("arr_concat_reverse_extend", raw.fn_of(arr_concat_reverse_extend))
  ut.run("arr_sort_stable", raw.fn_of(arr_sort_stable))
  ut.run("arr_literal_and_show", raw.fn_of(arr_literal_and_show))
  ut.run("arr_sum_overflow_panics", raw.fn_of(arr_sum_overflow_panics))
}

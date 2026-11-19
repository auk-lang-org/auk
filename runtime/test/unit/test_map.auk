/// {K: V}: insertion order, replacement, removal, COW (was runtime/c/test/test_map.c).

fn put_si(m: raw.Ptr<raw.Ptr<abi.Map>>, k: raw.Ptr<u8>, v: i64) uses raw, ffi {
  var ks = ut.s(k)
  var vv = v
  rt.auk_map_set(m, raw.cast(raw.addr_of(&ks)), raw.cast(raw.addr_of(&vv)))
  ut.rel(raw.cast(ks))
}

fn get_si(m: raw.Ptr<abi.Map>, k: raw.Ptr<u8>, found: raw.Ptr<bool>): i64 uses raw, ffi {
  var ks = ut.s(k)
  var v: i64 = 0
  found.store(rt.auk_map_get_opt(m, raw.cast(raw.addr_of(&ks)), raw.cast(raw.addr_of(&v))))
  ut.rel(raw.cast(ks))
  v
}

fn map_insertion_order_and_replace() uses raw, ffi {
  var m = rt.auk_map_new(rt.OPS_STR, rt.OPS_INT)
  let pm = raw.addr_of(&m)
  put_si(pm, "zebra", 1)
  put_si(pm, "apple", 2)
  put_si(pm, "mango", 3)
  ut.str_eq(rt.auk_map_show(m), "{{\"zebra\": 1, \"apple\": 2, \"mango\": 3}}", "auk_map_show(m)")
  put_si(pm, "apple", 20) // replace keeps position
  ut.str_eq(rt.auk_map_show(m), "{{\"zebra\": 1, \"apple\": 20, \"mango\": 3}}", "auk_map_show(m)")
  ut.eq(rt.auk_map_len(m), 3, "auk_map_len(m)")
  var found = false
  let pf = raw.addr_of(&found)
  ut.check(get_si(m, "apple", pf) == 20 && found, "get_si(m, \"apple\", &found) == 20 && found")
  let _ = get_si(m, "nope", pf)
  ut.check(!found, "!found")
  var k = ut.s("zebra")
  let pk: raw.Ptr<()> = raw.cast(raw.addr_of(&k))
  ut.check(rt.auk_map_contains(m, pk), "auk_map_contains(m, &k)")
  var old: i64 = 0
  ut.check(rt.auk_map_remove(pm, pk, raw.cast(raw.addr_of(&old))) && old == 1, "auk_map_remove(&m, &k, &old) && old == 1")
  ut.check(!rt.auk_map_remove(pm, pk, raw.null()), "!auk_map_remove(&m, &k, NULL)")
  ut.check(!rt.auk_map_contains(m, pk), "!auk_map_contains(m, &k)")
  ut.str_eq(rt.auk_map_show(m), "{{\"apple\": 20, \"mango\": 3}}", "auk_map_show(m)")
  put_si(pm, "zebra", 9) // re-inserted keys go to the end
  ut.str_eq(rt.auk_map_show(m), "{{\"apple\": 20, \"mango\": 3, \"zebra\": 9}}", "auk_map_show(m)")
  let keys = rt.auk_map_keys(m)
  let vals = rt.auk_map_values(m)
  ut.str_eq(rt.auk_arr_show(keys), "[\"apple\", \"mango\", \"zebra\"]", "auk_arr_show(keys)")
  ut.str_eq(rt.auk_arr_show(vals), "[20, 3, 9]", "auk_arr_show(vals)")
  var it: i64 = 0
  var n: i64 = 0
  var kp: raw.Ptr<()> = raw.null()
  var vp: raw.Ptr<()> = raw.null()
  while rt.auk_map_next(m, raw.addr_of(&it), raw.addr_of(&kp), raw.addr_of(&vp)) {
    n += raw.cast<i64>(vp).load()
  }
  ut.eq(n, 32, "n")
  ut.eq(raw.cast<i64>(rt.auk_map_at(m, pk, "t")).load(), 9, "*(const int64_t *)auk_map_at(m, &k, \"t\")")
  ut.rel(raw.cast(k))
  ut.rel(raw.cast(keys))
  ut.rel(raw.cast(vals))
  ut.rel(raw.cast(m))
}

fn map_many_entries() uses raw, ffi {
  var m = rt.auk_map_new(rt.OPS_INT, rt.OPS_INT)
  let pm = raw.addr_of(&m)
  var i: i64 = 0
  let pi: raw.Ptr<()> = raw.cast(raw.addr_of(&i))
  while i < 5000 {
    var v = i * i
    rt.auk_map_set(pm, pi, raw.cast(raw.addr_of(&v)))
    i += 1
  }
  ut.eq(rt.auk_map_len(m), 5000, "auk_map_len(m)")
  i = 0
  while i < 5000 {
    ut.check(rt.auk_map_remove(pm, pi, raw.null()), "auk_map_remove(&m, &i, NULL)")
    i += 2
  }
  ut.eq(rt.auk_map_len(m), 2500, "auk_map_len(m)")
  i = 0
  while i < 5000 {
    let v: raw.Ptr<i64> = raw.cast(rt.auk_map_find(m, pi))
    if i % 2 != 0 {
      ut.check(!v.is_null() && v.load() == i * i, "v != NULL && *v == i * i")
    } else {
      ut.check(v.is_null(), "v == NULL")
    }
    i += 1
  }
  // order of the survivors is still insertion order
  var it: i64 = 0
  var prev: i64 = -1
  var k: raw.Ptr<()> = raw.null()
  while rt.auk_map_next(m, raw.addr_of(&it), raw.addr_of(&k), raw.null()) {
    ut.check(raw.cast<i64>(k).load() > prev, "*(const int64_t *)k > prev")
    prev = raw.cast<i64>(k).load()
  }
  // churn: remove/insert the same keys many times
  var round = 0
  while round < 50 {
    i = 1
    while i < 200 {
      ut.check(rt.auk_map_remove(pm, pi, raw.null()), "auk_map_remove(&m, &i, NULL)")
      rt.auk_map_set(pm, pi, pi)
      i += 2
    }
    round += 1
  }
  ut.eq(rt.auk_map_len(m), 2500, "auk_map_len(m)")
  it = 0
  let _ = rt.auk_map_next(m, raw.addr_of(&it), raw.addr_of(&k), raw.null())
  ut.eq(raw.cast<i64>(k).load(), 201, "*(const int64_t *)k") // 1..199 were moved to the end
  ut.rel(raw.cast(m))
}

fn map_copy_on_write() uses raw, ffi {
  var a = rt.auk_map_new(rt.OPS_STR, rt.OPS_STR)
  var k = ut.s("k")
  var v1 = ut.s("v1")
  var v2 = ut.s("v2")
  let pk: raw.Ptr<()> = raw.cast(raw.addr_of(&k))
  rt.auk_map_set(raw.addr_of(&a), pk, raw.cast(raw.addr_of(&v1)))
  var b: raw.Ptr<abi.Map> = raw.cast(ut.ret(raw.cast(a)))
  rt.auk_map_set(raw.addr_of(&b), pk, raw.cast(raw.addr_of(&v2)))
  ut.check(a != b, "a != b")
  ut.check(rt.auk_str_eq(raw.cast<raw.Ptr<abi.Str>>(rt.auk_map_at(a, pk, "t")).load(), v1), "auk_str_eq(*(AukStr **)auk_map_at(a, &k, \"t\"), v1)")
  ut.check(rt.auk_str_eq(raw.cast<raw.Ptr<abi.Str>>(rt.auk_map_at(b, pk, "t")).load(), v2), "auk_str_eq(*(AukStr **)auk_map_at(b, &k, \"t\"), v2)")
  var c: raw.Ptr<abi.Map> = raw.cast(ut.ret(raw.cast(a)))
  ut.check(rt.auk_map_remove(raw.addr_of(&c), pk, raw.null()), "auk_map_remove(&c, &k, NULL)")
  ut.eq(rt.auk_map_len(a), 1, "auk_map_len(a)")
  ut.eq(rt.auk_map_len(c), 0, "auk_map_len(c)")
  ut.check(!rt.auk_map_eq(a, b), "!auk_map_eq(a, b)")
  var d = rt.auk_map_copy(a)
  ut.check(rt.auk_map_eq(a, d), "auk_map_eq(a, d)")
  // value object refcounts: v1 held by a and d
  ut.eq(rt.auk_refcount(raw.cast(v1)), 3, "auk_refcount(v1)")
  // setting a value that lives inside the map itself
  rt.auk_map_set(raw.addr_of(&d), pk, rt.auk_map_at(d, pk, "t"))
  ut.eq(rt.auk_refcount(raw.cast(v1)), 3, "auk_refcount(v1)")
  ut.rel(raw.cast(a))
  ut.rel(raw.cast(b))
  ut.rel(raw.cast(c))
  ut.rel(raw.cast(d))
  ut.eq(rt.auk_refcount(raw.cast(v1)), 1, "auk_refcount(v1)")
  ut.rel(raw.cast(k))
  ut.rel(raw.cast(v1))
  ut.rel(raw.cast(v2))
}

fn map_eq_ignores_order() uses raw, ffi {
  var a = rt.auk_map_new(rt.OPS_STR, rt.OPS_INT)
  var b = rt.auk_map_new(rt.OPS_STR, rt.OPS_INT)
  put_si(raw.addr_of(&a), "x", 1)
  put_si(raw.addr_of(&a), "y", 2)
  put_si(raw.addr_of(&b), "y", 2)
  put_si(raw.addr_of(&b), "x", 1)
  ut.check(rt.auk_map_eq(a, b), "auk_map_eq(a, b)")
  put_si(raw.addr_of(&b), "x", 3)
  ut.check(!rt.auk_map_eq(a, b), "!auk_map_eq(a, b)")
  ut.rel(raw.cast(a))
  ut.rel(raw.cast(b))
}

fn missing_key(ctx: raw.Ptr<()>) uses raw, ffi {
  var k = ut.s("ghost")
  let _ = rt.auk_map_at(raw.cast(ctx), raw.cast(raw.addr_of(&k)), "m.auk:2:3")
}

fn map_missing_key_panics() uses raw, ffi {
  let m = rt.auk_map_new(rt.OPS_STR, rt.OPS_INT)
  ut.expect_panic(raw.fn_of(missing_key), raw.cast(m), "key not found: \"ghost\"\n  at m.auk:2:3")
  ut.rel(raw.cast(m))
}

fn map_nested_values() uses raw, ffi {
  // {str: [int]} with COW on the inner list
  var m = rt.auk_map_new(rt.OPS_STR, rt.OPS_ARR)
  var k = ut.s("xs")
  var xs = rt.auk_arr_new(rt.OPS_INT, 0)
  let pk: raw.Ptr<()> = raw.cast(raw.addr_of(&k))
  rt.auk_map_set(raw.addr_of(&m), pk, raw.cast(raw.addr_of(&xs)))
  let snap = ut.ret(raw.cast(m))
  let _ = rt.auk_map_make_unique(raw.addr_of(&m))
  let slot: raw.Ptr<raw.Ptr<abi.Arr>> = raw.cast(rt.auk_map_find(m, pk))
  ut.push_int(slot, 7)
  ut.str_eq(rt.auk_map_show(m), "{{\"xs\": [7]}}", "auk_map_show(m)")
  ut.str_eq(rt.auk_map_show(raw.cast(snap)), "{{\"xs\": []}}", "auk_map_show(snap)")
  ut.rel(raw.cast(m))
  ut.rel(snap)
  ut.rel(raw.cast(k))
  ut.rel(raw.cast(xs))
}

/// The tests, in the C file's order.
pub fn all() uses raw, ffi {
  ut.run("map_insertion_order_and_replace", raw.fn_of(map_insertion_order_and_replace))
  ut.run("map_many_entries", raw.fn_of(map_many_entries))
  ut.run("map_copy_on_write", raw.fn_of(map_copy_on_write))
  ut.run("map_eq_ignores_order", raw.fn_of(map_eq_ignores_order))
  ut.run("map_missing_key_panics", raw.fn_of(map_missing_key_panics))
  ut.run("map_nested_values", raw.fn_of(map_nested_values))
}

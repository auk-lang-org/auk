/// Value: the core data-tree enum (was runtime/c/value.c, ported line by line). The ABI is
/// auk_rt.h's: `AukValue` (`abi.Value`) by value, every `auk_value_*` entry point under its C
/// name.

// the rest of the runtime (C, for now)
extern fn auk_retain(p: raw.Ptr<()>): raw.Ptr<()> = "void *auk_retain(void *)"
extern fn auk_release(p: raw.Ptr<()>) = "void auk_release(void *)"
// _Noreturn: `never` is core's only (TODO(dialect)), so its callers say `raw.unreachable()`
extern fn auk__panic3(loc: raw.Ptr<u8>, a: raw.Ptr<u8>, b: raw.Ptr<u8>, c: raw.Ptr<u8>) =
  "void auk__panic3(const char *, const char *, const char *, const char *)"
extern fn auk_hash_int(x: i64): u64 = "uint64_t auk_hash_int(int64_t)"
extern fn auk_str_lit(s: raw.Ptr<u8>): raw.Ptr<abi.Str> = "void *auk_str_lit(const char *)"
extern fn auk_str_eq(a: raw.Ptr<abi.Str>, b: raw.Ptr<abi.Str>): bool = "bool auk_str_eq(const void *, const void *)"
extern fn auk_str_hash(s: raw.Ptr<abi.Str>): u64 = "uint64_t auk_str_hash(const void *)"
extern fn auk_str_from_int(v: i64): raw.Ptr<abi.Str> = "void *auk_str_from_int(int64_t)"
extern fn auk_str_from_float(v: float): raw.Ptr<abi.Str> = "void *auk_str_from_float(double)"
extern fn auk_str_from_bool(b: bool): raw.Ptr<abi.Str> = "void *auk_str_from_bool(bool)"
extern fn auk_str_quote(s: raw.Ptr<abi.Str>): raw.Ptr<abi.Str> = "void *auk_str_quote(const void *)"
extern fn auk_arr_new(ops: raw.Ptr<abi.ElemOps>, cap: i64): raw.Ptr<abi.Arr> = "void *auk_arr_new(const void *, int64_t)"
extern fn auk_arr_eq(a: raw.Ptr<abi.Arr>, b: raw.Ptr<abi.Arr>): bool = "bool auk_arr_eq(const void *, const void *)"
extern fn auk_arr_hash(a: raw.Ptr<abi.Arr>): u64 = "uint64_t auk_arr_hash(const void *)"
extern fn auk_arr_show(a: raw.Ptr<abi.Arr>): raw.Ptr<abi.Str> = "void *auk_arr_show(const void *)"
extern fn auk_map_new(k: raw.Ptr<abi.ElemOps>, v: raw.Ptr<abi.ElemOps>): raw.Ptr<abi.Map> = "void *auk_map_new(const void *, const void *)"
extern fn auk_map_set(pm: raw.Ptr<raw.Ptr<abi.Map>>, k: raw.Ptr<()>, v: raw.Ptr<()>) =
  "void auk_map_set(void *, const void *, const void *)"
extern fn auk_map_eq(a: raw.Ptr<abi.Map>, b: raw.Ptr<abi.Map>): bool = "bool auk_map_eq(const void *, const void *)"
extern fn auk_map_show(m: raw.Ptr<abi.Map>): raw.Ptr<abi.Str> = "void *auk_map_show(const void *)"
extern var auk_ops_str: abi.ElemOps = "auk_ops_str"
extern var auk_ops_float: abi.ElemOps = "auk_ops_float"
// defined in C (runtime/c/value_ops.c) until a raw global's initializer can hold function
// addresses: the element ops of `Value`, over the auk__value_elem_* functions below
extern var auk_ops_value: abi.ElemOps = "auk_ops_value"

export fn auk_value_null(): abi.Value = abi.Value { tag: abi.V_NULL }

// the whole union zeroed first: a literal's missing fields and bytes are zero
export fn auk_value_bool(b: bool): abi.Value = abi.Value { tag: abi.V_BOOL, u: abi.ValueU { b } }

export fn auk_value_int(i: i64): abi.Value = abi.Value { tag: abi.V_INT, u: abi.ValueU { i } }

export fn auk_value_float(f: float): abi.Value = abi.Value { tag: abi.V_FLOAT, u: abi.ValueU { f } }

export fn auk_value_str(s: raw.Ptr<abi.Str>): abi.Value uses raw, ffi {
  let s2: raw.Ptr<abi.Str> = if s.is_null() { auk_str_lit("") } else { raw.cast(auk_retain(raw.cast(s))) }
  abi.Value { tag: abi.V_STR, u: abi.ValueU { s: s2 } }
}

export fn auk_value_list(xs: raw.Ptr<abi.Arr>): abi.Value uses raw, ffi {
  let l: raw.Ptr<abi.Arr> = if xs.is_null() { auk_value_list_new() } else { raw.cast(auk_retain(raw.cast(xs))) }
  abi.Value { tag: abi.V_LIST, u: abi.ValueU { list: l } }
}

export fn auk_value_map(m: raw.Ptr<abi.Map>): abi.Value uses raw, ffi {
  let m2: raw.Ptr<abi.Map> = if m.is_null() { auk_value_map_new() } else { raw.cast(auk_retain(raw.cast(m))) }
  abi.Value { tag: abi.V_MAP, u: abi.ValueU { map: m2 } }
}

export fn auk_value_list_new(): raw.Ptr<abi.Arr> uses raw, ffi = auk_arr_new(raw.addr_of(&auk_ops_value), 0)

export fn auk_value_map_new(): raw.Ptr<abi.Map> uses raw, ffi =
  auk_map_new(raw.addr_of(&auk_ops_str), raw.addr_of(&auk_ops_value))

export fn auk_value_map_put(pm: raw.Ptr<raw.Ptr<abi.Map>>, key: raw.Ptr<u8>, val: abi.Value) uses raw, ffi {
  var k = auk_str_lit(key)
  var v = val
  auk_map_set(pm, raw.cast(raw.addr_of(&k)), raw.cast(raw.addr_of(&v)))
  auk_release(raw.cast(k))
}

fn value_ptr(v: abi.Value): raw.Ptr<()> uses raw {
  let t = v.tag
  if t == abi.V_STR {
    raw.cast(v.u.s)
  } else if t == abi.V_LIST {
    raw.cast(v.u.list)
  } else if t == abi.V_MAP {
    raw.cast(v.u.map)
  } else {
    raw.null()
  }
}

export fn auk_value_retain(v: abi.Value) uses raw, ffi {
  let _ = auk_retain(value_ptr(v))
}

export fn auk_value_release(v: abi.Value) uses raw, ffi = auk_release(value_ptr(v))

export fn auk_value_tag_name(t: u32): raw.Ptr<u8> {
  if t == abi.V_NULL {
    "Null"
  } else if t == abi.V_BOOL {
    "Bool"
  } else if t == abi.V_INT {
    "Int"
  } else if t == abi.V_FLOAT {
    "Float"
  } else if t == abi.V_STR {
    "Str"
  } else if t == abi.V_LIST {
    "List"
  } else if t == abi.V_MAP {
    "Map"
  } else {
    "?"
  }
}

/// `want` is "expected <Tag>, got ".
fn mismatch(loc: raw.Ptr<u8>, want: raw.Ptr<u8>, v: abi.Value) uses raw, ffi {
  auk__panic3(loc, want, auk_value_tag_name(v.tag), raw.null())
  raw.unreachable()
}

export fn auk_value_as_bool(v: abi.Value, loc: raw.Ptr<u8>): bool uses raw, ffi {
  if v.tag != abi.V_BOOL { mismatch(loc, "expected Bool, got ", v) }
  v.u.b
}

export fn auk_value_as_int(v: abi.Value, loc: raw.Ptr<u8>): i64 uses raw, ffi {
  if v.tag != abi.V_INT { mismatch(loc, "expected Int, got ", v) }
  v.u.i
}

export fn auk_value_as_float(v: abi.Value, loc: raw.Ptr<u8>): float uses raw, ffi {
  if v.tag == abi.V_INT { return float(v.u.i) }
  if v.tag != abi.V_FLOAT { mismatch(loc, "expected Float, got ", v) }
  v.u.f
}

export fn auk_value_as_str(v: abi.Value, loc: raw.Ptr<u8>): raw.Ptr<abi.Str> uses raw, ffi {
  if v.tag != abi.V_STR { mismatch(loc, "expected Str, got ", v) }
  v.u.s
}

export fn auk_value_as_list(v: abi.Value, loc: raw.Ptr<u8>): raw.Ptr<abi.Arr> uses raw, ffi {
  if v.tag != abi.V_LIST { mismatch(loc, "expected List, got ", v) }
  v.u.list
}

export fn auk_value_as_map(v: abi.Value, loc: raw.Ptr<u8>): raw.Ptr<abi.Map> uses raw, ffi {
  if v.tag != abi.V_MAP { mismatch(loc, "expected Map, got ", v) }
  v.u.map
}

export fn auk_value_eq(a: abi.Value, b: abi.Value): bool uses ffi {
  if a.tag != b.tag { return false }
  let t = a.tag
  if t == abi.V_NULL {
    true
  } else if t == abi.V_BOOL {
    a.u.b == b.u.b
  } else if t == abi.V_INT {
    a.u.i == b.u.i
  } else if t == abi.V_FLOAT {
    a.u.f == b.u.f
  } else if t == abi.V_STR {
    auk_str_eq(a.u.s, b.u.s)
  } else if t == abi.V_LIST {
    auk_arr_eq(a.u.list, b.u.list)
  } else if t == abi.V_MAP {
    auk_map_eq(a.u.map, b.u.map)
  } else {
    false
  }
}

export fn auk_value_show(v: abi.Value): raw.Ptr<abi.Str> uses ffi {
  let t = v.tag
  if t == abi.V_NULL {
    auk_str_lit("Null")
  } else if t == abi.V_BOOL {
    auk_str_from_bool(v.u.b)
  } else if t == abi.V_INT {
    auk_str_from_int(v.u.i)
  } else if t == abi.V_FLOAT {
    auk_str_from_float(v.u.f)
  } else if t == abi.V_STR {
    auk_str_quote(v.u.s)
  } else if t == abi.V_LIST {
    auk_arr_show(v.u.list)
  } else if t == abi.V_MAP {
    auk_map_show(v.u.map)
  } else {
    auk_str_lit("?")
  }
}

// the element ops of `Value` (auk_ops_value, runtime/c/value_ops.c)

export fn auk__value_elem_retain(p: raw.Ptr<()>) uses raw, ffi = auk_value_retain(raw.cast<abi.Value>(p).load())

export fn auk__value_elem_release(p: raw.Ptr<()>) uses raw, ffi = auk_value_release(raw.cast<abi.Value>(p).load())

export fn auk__value_elem_eq(a: raw.Ptr<()>, b: raw.Ptr<()>): bool uses raw, ffi =
  auk_value_eq(raw.cast<abi.Value>(a).load(), raw.cast<abi.Value>(b).load())

export fn auk__value_elem_hash(p: raw.Ptr<()>): u64 uses raw, ffi {
  let v: raw.Ptr<abi.Value> = raw.cast(p)
  let t = v.tag
  if t == abi.V_STR {
    auk_str_hash(v.u.s)
  } else if t == abi.V_LIST {
    auk_arr_hash(v.u.list)
  } else if t == abi.V_FLOAT {
    let hash = raw.addr_of(&auk_ops_float).hash
    hash(raw.cast(raw.field_addr(v, .u)))
  } else if t == abi.V_INT {
    auk_hash_int(v.u.i)
  } else if t == abi.V_BOOL {
    auk_hash_int((if v.u.b { 1 } else { 0 }) + 2)
  } else {
    u64(t) * 7919
  }
}

export fn auk__value_elem_show(p: raw.Ptr<()>): raw.Ptr<abi.Str> uses raw, ffi = auk_value_show(raw.cast<abi.Value>(p).load())

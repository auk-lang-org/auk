/// Value: the core data-tree enum (was runtime/c/value.c, ported line by line). The ABI is
/// auk_rt.h's: `AukValue` by value, every `auk_value_*` entry point under its C name.

// TODO(abi): mirrors of auk_rt.h, declared here until runtime/src/abi.auk has them. `Arr` and
// `Map` are only addressed here, so only their headers are spelled out.
raw struct Header { rc: i64, kind: u32, flags: u32 }
raw struct Str { h: Header, len_bytes: i64, len_chars: i64, is_ascii: bool, data: [u8; ..] }
raw struct Arr { h: Header }
raw struct Map { h: Header }
raw union ValueU { b: bool, i: i64, f: float, s: raw.Ptr<Str>, list: raw.Ptr<Arr>, map: raw.Ptr<Map> }
raw struct Value { tag: u32, u: ValueU }
raw struct ElemOps {
  size: usize,
  retain: raw.Fn<(raw.Ptr<()>) => ()>,
  release: raw.Fn<(raw.Ptr<()>) => ()>,
  eq: raw.Fn<(raw.Ptr<()>, raw.Ptr<()>) => bool>,
  cmp: raw.Fn<(raw.Ptr<()>, raw.Ptr<()>) => i32>,
  hash: raw.Fn<(raw.Ptr<()>) => u64>,
  show: raw.Fn<(raw.Ptr<()>) => raw.Ptr<Str>>,
  copy: raw.Fn<(raw.Ptr<()>, raw.Ptr<()>) => ()>,
}
raw assert raw.size_of<Header>() == 16 && raw.offset_of<Header>(.kind) == 8
raw assert raw.size_of<Str>() == 40 && raw.offset_of<Str>(.data) == 33
raw assert raw.size_of<Value>() == 16 && raw.offset_of<Value>(.u) == 8
raw assert raw.size_of<ElemOps>() == 64 && raw.offset_of<ElemOps>(.hash) == 40

// AUK_V_*: Value's tags
raw let V_NULL: u32 = 0
raw let V_BOOL: u32 = 1
raw let V_INT: u32 = 2
raw let V_FLOAT: u32 = 3
raw let V_STR: u32 = 4
raw let V_LIST: u32 = 5
raw let V_MAP: u32 = 6

// the rest of the runtime (C, for now)
extern fn auk_retain(p: raw.Ptr<()>): raw.Ptr<()> = "void *auk_retain(void *)"
extern fn auk_release(p: raw.Ptr<()>) = "void auk_release(void *)"
// _Noreturn: `never` is core's only (TODO(dialect)), so its callers say `raw.unreachable()`
extern fn auk__panic3(loc: raw.Ptr<u8>, a: raw.Ptr<u8>, b: raw.Ptr<u8>, c: raw.Ptr<u8>) =
  "void auk__panic3(const char *, const char *, const char *, const char *)"
extern fn auk_hash_int(x: i64): u64 = "uint64_t auk_hash_int(int64_t)"
extern fn auk_str_lit(s: raw.Ptr<u8>): raw.Ptr<Str> = "void *auk_str_lit(const char *)"
extern fn auk_str_eq(a: raw.Ptr<Str>, b: raw.Ptr<Str>): bool = "bool auk_str_eq(const void *, const void *)"
extern fn auk_str_hash(s: raw.Ptr<Str>): u64 = "uint64_t auk_str_hash(const void *)"
extern fn auk_str_from_int(v: i64): raw.Ptr<Str> = "void *auk_str_from_int(int64_t)"
extern fn auk_str_from_float(v: float): raw.Ptr<Str> = "void *auk_str_from_float(double)"
extern fn auk_str_from_bool(b: bool): raw.Ptr<Str> = "void *auk_str_from_bool(bool)"
extern fn auk_str_quote(s: raw.Ptr<Str>): raw.Ptr<Str> = "void *auk_str_quote(const void *)"
extern fn auk_arr_new(ops: raw.Ptr<ElemOps>, cap: i64): raw.Ptr<Arr> = "void *auk_arr_new(const void *, int64_t)"
extern fn auk_arr_eq(a: raw.Ptr<Arr>, b: raw.Ptr<Arr>): bool = "bool auk_arr_eq(const void *, const void *)"
extern fn auk_arr_hash(a: raw.Ptr<Arr>): u64 = "uint64_t auk_arr_hash(const void *)"
extern fn auk_arr_show(a: raw.Ptr<Arr>): raw.Ptr<Str> = "void *auk_arr_show(const void *)"
extern fn auk_map_new(k: raw.Ptr<ElemOps>, v: raw.Ptr<ElemOps>): raw.Ptr<Map> = "void *auk_map_new(const void *, const void *)"
extern fn auk_map_set(pm: raw.Ptr<raw.Ptr<Map>>, k: raw.Ptr<()>, v: raw.Ptr<()>) =
  "void auk_map_set(void *, const void *, const void *)"
extern fn auk_map_eq(a: raw.Ptr<Map>, b: raw.Ptr<Map>): bool = "bool auk_map_eq(const void *, const void *)"
extern fn auk_map_show(m: raw.Ptr<Map>): raw.Ptr<Str> = "void *auk_map_show(const void *)"
extern var auk_ops_str: ElemOps = "auk_ops_str"
extern var auk_ops_float: ElemOps = "auk_ops_float"
// defined in C (runtime/c/value_ops.c) until a raw global's initializer can hold function
// addresses: the element ops of `Value`, over the auk__value_elem_* functions below
extern var auk_ops_value: ElemOps = "auk_ops_value"

export fn auk_value_null(): Value = Value { tag: V_NULL }

// the whole union zeroed first: a literal's missing fields and bytes are zero
export fn auk_value_bool(b: bool): Value = Value { tag: V_BOOL, u: ValueU { b } }

export fn auk_value_int(i: i64): Value = Value { tag: V_INT, u: ValueU { i } }

export fn auk_value_float(f: float): Value = Value { tag: V_FLOAT, u: ValueU { f } }

export fn auk_value_str(s: raw.Ptr<Str>): Value uses raw, ffi {
  let s2: raw.Ptr<Str> = if s.is_null() { auk_str_lit("") } else { raw.cast(auk_retain(raw.cast(s))) }
  Value { tag: V_STR, u: ValueU { s: s2 } }
}

export fn auk_value_list(xs: raw.Ptr<Arr>): Value uses raw, ffi {
  let l: raw.Ptr<Arr> = if xs.is_null() { auk_value_list_new() } else { raw.cast(auk_retain(raw.cast(xs))) }
  Value { tag: V_LIST, u: ValueU { list: l } }
}

export fn auk_value_map(m: raw.Ptr<Map>): Value uses raw, ffi {
  let m2: raw.Ptr<Map> = if m.is_null() { auk_value_map_new() } else { raw.cast(auk_retain(raw.cast(m))) }
  Value { tag: V_MAP, u: ValueU { map: m2 } }
}

export fn auk_value_list_new(): raw.Ptr<Arr> uses raw, ffi = auk_arr_new(raw.addr_of(&auk_ops_value), 0)

export fn auk_value_map_new(): raw.Ptr<Map> uses raw, ffi =
  auk_map_new(raw.addr_of(&auk_ops_str), raw.addr_of(&auk_ops_value))

export fn auk_value_map_put(pm: raw.Ptr<raw.Ptr<Map>>, key: raw.Ptr<u8>, val: Value) uses raw, ffi {
  var k = auk_str_lit(key)
  var v = val
  auk_map_set(pm, raw.cast(raw.addr_of(&k)), raw.cast(raw.addr_of(&v)))
  auk_release(raw.cast(k))
}

fn value_ptr(v: Value): raw.Ptr<()> uses raw {
  let t = v.tag
  if t == V_STR {
    raw.cast(v.u.s)
  } else if t == V_LIST {
    raw.cast(v.u.list)
  } else if t == V_MAP {
    raw.cast(v.u.map)
  } else {
    raw.null()
  }
}

export fn auk_value_retain(v: Value) uses raw, ffi {
  let _ = auk_retain(value_ptr(v))
}

export fn auk_value_release(v: Value) uses raw, ffi = auk_release(value_ptr(v))

export fn auk_value_tag_name(t: u32): raw.Ptr<u8> {
  if t == V_NULL {
    "Null"
  } else if t == V_BOOL {
    "Bool"
  } else if t == V_INT {
    "Int"
  } else if t == V_FLOAT {
    "Float"
  } else if t == V_STR {
    "Str"
  } else if t == V_LIST {
    "List"
  } else if t == V_MAP {
    "Map"
  } else {
    "?"
  }
}

/// `want` is "expected <Tag>, got ".
fn mismatch(loc: raw.Ptr<u8>, want: raw.Ptr<u8>, v: Value) uses raw, ffi {
  auk__panic3(loc, want, auk_value_tag_name(v.tag), raw.null())
  raw.unreachable()
}

export fn auk_value_as_bool(v: Value, loc: raw.Ptr<u8>): bool uses raw, ffi {
  if v.tag != V_BOOL { mismatch(loc, "expected Bool, got ", v) }
  v.u.b
}

export fn auk_value_as_int(v: Value, loc: raw.Ptr<u8>): i64 uses raw, ffi {
  if v.tag != V_INT { mismatch(loc, "expected Int, got ", v) }
  v.u.i
}

export fn auk_value_as_float(v: Value, loc: raw.Ptr<u8>): float uses raw, ffi {
  if v.tag == V_INT { return float(v.u.i) }
  if v.tag != V_FLOAT { mismatch(loc, "expected Float, got ", v) }
  v.u.f
}

export fn auk_value_as_str(v: Value, loc: raw.Ptr<u8>): raw.Ptr<Str> uses raw, ffi {
  if v.tag != V_STR { mismatch(loc, "expected Str, got ", v) }
  v.u.s
}

export fn auk_value_as_list(v: Value, loc: raw.Ptr<u8>): raw.Ptr<Arr> uses raw, ffi {
  if v.tag != V_LIST { mismatch(loc, "expected List, got ", v) }
  v.u.list
}

export fn auk_value_as_map(v: Value, loc: raw.Ptr<u8>): raw.Ptr<Map> uses raw, ffi {
  if v.tag != V_MAP { mismatch(loc, "expected Map, got ", v) }
  v.u.map
}

export fn auk_value_eq(a: Value, b: Value): bool uses ffi {
  if a.tag != b.tag { return false }
  let t = a.tag
  if t == V_NULL {
    true
  } else if t == V_BOOL {
    a.u.b == b.u.b
  } else if t == V_INT {
    a.u.i == b.u.i
  } else if t == V_FLOAT {
    a.u.f == b.u.f
  } else if t == V_STR {
    auk_str_eq(a.u.s, b.u.s)
  } else if t == V_LIST {
    auk_arr_eq(a.u.list, b.u.list)
  } else if t == V_MAP {
    auk_map_eq(a.u.map, b.u.map)
  } else {
    false
  }
}

export fn auk_value_show(v: Value): raw.Ptr<Str> uses ffi {
  let t = v.tag
  if t == V_NULL {
    auk_str_lit("Null")
  } else if t == V_BOOL {
    auk_str_from_bool(v.u.b)
  } else if t == V_INT {
    auk_str_from_int(v.u.i)
  } else if t == V_FLOAT {
    auk_str_from_float(v.u.f)
  } else if t == V_STR {
    auk_str_quote(v.u.s)
  } else if t == V_LIST {
    auk_arr_show(v.u.list)
  } else if t == V_MAP {
    auk_map_show(v.u.map)
  } else {
    auk_str_lit("?")
  }
}

// the element ops of `Value` (auk_ops_value, runtime/c/value_ops.c)

export fn auk__value_elem_retain(p: raw.Ptr<()>) uses raw, ffi = auk_value_retain(raw.cast<Value>(p).load())

export fn auk__value_elem_release(p: raw.Ptr<()>) uses raw, ffi = auk_value_release(raw.cast<Value>(p).load())

export fn auk__value_elem_eq(a: raw.Ptr<()>, b: raw.Ptr<()>): bool uses raw, ffi =
  auk_value_eq(raw.cast<Value>(a).load(), raw.cast<Value>(b).load())

export fn auk__value_elem_hash(p: raw.Ptr<()>): u64 uses raw, ffi {
  let v: raw.Ptr<Value> = raw.cast(p)
  let t = v.tag
  if t == V_STR {
    auk_str_hash(v.u.s)
  } else if t == V_LIST {
    auk_arr_hash(v.u.list)
  } else if t == V_FLOAT {
    let hash = raw.addr_of(&auk_ops_float).hash
    hash(raw.cast(raw.field_addr(v, .u)))
  } else if t == V_INT {
    auk_hash_int(v.u.i)
  } else if t == V_BOOL {
    auk_hash_int((if v.u.b { 1 } else { 0 }) + 2)
  } else {
    u64(t) * 7919
  }
}

export fn auk__value_elem_show(p: raw.Ptr<()>): raw.Ptr<Str> uses raw, ffi = auk_value_show(raw.cast<Value>(p).load())

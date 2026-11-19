/// `{K: V}`: insertion-ordered hash map (an index table over an entries array), copy-on-write
/// (was runtime/c/map.c, ported line by line). The ABI is auk_rt.h's: `AukMap` (`abi.Map`) by
/// pointer, every `auk_map_*` entry point under its C name.
///
/// Entries keep insertion order: entry i's key is at entries + i * stride, its value voff bytes
/// later; hashes[i] is its full hash and dead[i] marks a removed entry (kept, for order, until a
/// compaction). The index is open addressing with linear probing over icap slots: 0 is empty,
/// TOMB a removed entry, anything else the hash's upper 32 bits over (entry + 1), so a probe
/// rejects most other keys without touching their entries.

// the rest of the runtime (C, for now)
extern fn auk_release(p: raw.Ptr<()>) = "void auk_release(void *)"
extern fn auk__alloc(size: usize, kind: u32): raw.Ptr<()> = "void *auk__alloc(size_t, uint32_t)"
extern fn auk__free_obj(p: raw.Ptr<()>) = "void auk__free_obj(void *)"
extern fn auk__xcalloc(n: usize, size: usize): raw.Ptr<u8> = "void *auk__xcalloc(size_t, size_t)"
extern fn auk__xmalloc(n: usize): raw.Ptr<u8> = "void *auk__xmalloc(size_t)"
extern fn auk__xrealloc(p: raw.Ptr<u8>, n: usize): raw.Ptr<u8> = "void *auk__xrealloc(void *, size_t)"
// _Noreturn: `never` is core's only (TODO(dialect)), so their callers say `raw.unreachable()`
extern fn auk__panic_rt(msg: raw.Ptr<u8>) = "void auk__panic_rt(const char *)"
extern fn auk__panic3(loc: raw.Ptr<u8>, a: raw.Ptr<u8>, b: raw.Ptr<u8>, c: raw.Ptr<u8>) =
  "void auk__panic3(const char *, const char *, const char *, const char *)"
extern fn auk_str_lit(s: raw.Ptr<u8>): raw.Ptr<abi.Str> = "void *auk_str_lit(const char *)"
extern fn auk_str_cstr(s: raw.Ptr<abi.Str>): raw.Ptr<u8> = "const char *auk_str_cstr(const void *)"
extern fn auk__show_exhausted(): bool = "bool auk__show_exhausted(void)"
extern fn auk_sb_char(b: raw.Ptr<abi.StrBuf>, c: u32) = "void auk_sb_char(void *, uint32_t)"
extern fn auk_sb_lit(b: raw.Ptr<abi.StrBuf>, s: raw.Ptr<u8>) = "void auk_sb_lit(void *, const char *)"
extern fn auk_sb_str_own(b: raw.Ptr<abi.StrBuf>, s: raw.Ptr<abi.Str>) = "void auk_sb_str_own(void *, void *)"
extern fn auk_sb_finish(b: raw.Ptr<abi.StrBuf>): raw.Ptr<abi.Str> = "void *auk_sb_finish(void *)"

raw let EMPTY: u64 = 0
raw let TOMB: u64 = 0xffffffffffffffff
/// The most entries a map holds (the entry number must fit the slot's low 32 bits).
raw let MAX_ENTRIES: i64 = 4294967295 - 2

fn slot_of(h: u64, e: i64): u64 = (h & ~u64(0xffffffff)) | u64(e + 1)

/// The entry a live slot points to.
fn entry_of(x: u64): i64 = i64(u32(x)) - 1

fn live(x: u64): bool = x != EMPTY && x != TOMB

pub inline export fn auk_map_len(m: raw.Ptr<abi.Map>): i64 uses raw = if m.is_null() { 0 } else { m.len }

fn round8(n: usize): i64 = i64((n + 7) / 8 * 8)

pub export fn auk_map_new(kops: raw.Ptr<abi.ElemOps>, vops: raw.Ptr<abi.ElemOps>): raw.Ptr<abi.Map> uses raw, ffi {
  if kops.is_null() || vops.is_null() {
    auk__panic_rt("auk_map_new: missing ops")
    raw.unreachable()
  }
  if kops.hash.is_null() || kops.eq.is_null() {
    auk__panic_rt("auk_map_new: key type needs hash and eq")
    raw.unreachable()
  }
  let m: raw.Ptr<abi.Map> = raw.cast(auk__alloc(raw.size_of<abi.Map>(), abi.K_MAP))
  m.kops = kops
  m.vops = vops
  // every Auk value's alignment is at most 8: the value starts at the key's size rounded up
  m.voff = round8(kops.size)
  m.stride = m.voff + round8(vops.size)
  if m.stride < 8 {
    m.stride = 8
  }
  m
}

export fn auk__map_free(m: raw.Ptr<abi.Map>) uses raw, ffi {
  let krelease = m.kops.release
  let vrelease = m.vops.release
  var i: i64 = 0
  while i < m.n {
    if !m.dead.at(i) {
      if !krelease.is_null() {
        krelease(raw.cast(abi.map_key(m, i)))
      }
      if !vrelease.is_null() {
        vrelease(raw.cast(abi.map_val(m, i)))
      }
    }
    i += 1
  }
  raw.free(m.entries)
  raw.free(m.hashes)
  raw.free(m.dead)
  raw.free(m.index)
  auk__free_obj(raw.cast(m))
}

fn rebuild_index(m: raw.Ptr<abi.Map>, icap: i64) uses raw, ffi {
  raw.free(m.index)
  m.icap = icap
  m.index = raw.cast(auk__xcalloc(usize(icap), 8))
  let mask = u64(icap) - 1
  var e: i64 = 0
  while e < m.n {
    if !m.dead.at(e) {
      let h = m.hashes.at(e)
      var s = h & mask
      while m.index.at(s) != EMPTY {
        s = (s + 1) & mask
      }
      m.index.at(s) = slot_of(h, e)
    }
    e += 1
  }
}

/// Drop dead entries (keeps order). The caller rebuilds the index.
fn compact(m: raw.Ptr<abi.Map>) uses raw {
  var k: i64 = 0
  let stride = usize(m.stride)
  var e: i64 = 0
  while e < m.n {
    if !m.dead.at(e) {
      if k != e {
        raw.copy(abi.map_key(m, k), abi.map_key(m, e), stride)
        m.hashes.at(k) = m.hashes.at(e)
        m.dead.at(k) = false
      }
      k += 1
    }
    e += 1
  }
  m.n = k
}

fn set_cap(m: raw.Ptr<abi.Map>, cap: i64) uses raw, ffi {
  if cap > MAX_ENTRIES {
    auk__panic_rt("a map can't hold more than 4294967293 entries")
    raw.unreachable()
  }
  m.entries = auk__xrealloc(m.entries, usize(cap) * usize(m.stride))
  m.hashes = raw.cast(auk__xrealloc(raw.cast(m.hashes), usize(cap) * 8))
  m.dead = raw.cast(auk__xrealloc(raw.cast(m.dead), usize(cap)))
  m.cap = cap
}

// `uses raw`: only so that its loop has no cancellation point (TODO(dialect): every function
// of the runtime package should be without them)
fn icap_for(cap: i64): i64 uses raw {
  var ic: i64 = 8
  while ic < cap * 2 {
    ic *= 2
  }
  ic
}

/// The index slot holding key k (hash h), or -1.
fn find_slot(m: raw.Ptr<abi.Map>, k: raw.Ptr<()>, h: u64): i64 uses raw {
  if m.is_null() || m.icap == 0 {
    return -1
  }
  let mask = u64(m.icap) - 1
  let eq = m.kops.eq
  let fp = h >> 32
  var s = h & mask
  loop {
    let x = m.index.at(s)
    if x == EMPTY {
      return -1
    }
    if x != TOMB && x >> 32 == fp && eq(raw.cast(abi.map_key(m, entry_of(x))), k) {
      return i64(s)
    }
    s = (s + 1) & mask
  }
}

pub inline export fn auk_map_find(m: raw.Ptr<abi.Map>, k: raw.Ptr<()>): raw.Ptr<()> uses raw {
  if m.is_null() {
    return raw.null()
  }
  let hash = m.kops.hash
  let s = find_slot(m, k, hash(k))
  if s < 0 { raw.null() } else { raw.cast(abi.map_val(m, entry_of(m.index.at(s)))) }
}

export fn auk_map_at(m: raw.Ptr<abi.Map>, k: raw.Ptr<()>, loc: raw.Ptr<u8>): raw.Ptr<()> uses raw, ffi {
  let v = auk_map_find(m, k)
  if v.is_null() {
    let ks = if !m.is_null() && !m.kops.show.is_null() {
      let show = m.kops.show
      show(k)
    } else {
      auk_str_lit("?")
    }
    // the key's text up to its first NUL byte
    auk__panic3(loc, "key not found: ", auk_str_cstr(ks), raw.null())
    raw.unreachable()
  }
  v
}

inline export fn auk_map_get_opt(m: raw.Ptr<abi.Map>, k: raw.Ptr<()>, out: raw.Ptr<()>): bool uses raw {
  let v = auk_map_find(m, k)
  if v.is_null() {
    return false
  }
  raw.copy(out, v, m.vops.size)
  let retain = m.vops.retain
  if !retain.is_null() {
    retain(out)
  }
  true
}

inline export fn auk_map_contains(m: raw.Ptr<abi.Map>, k: raw.Ptr<()>): bool uses raw = !auk_map_find(m, k).is_null()

export fn auk_map_copy(m: raw.Ptr<abi.Map>): raw.Ptr<abi.Map> uses raw, ffi {
  let c = auk_map_new(m.kops, m.vops)
  if m.len != 0 {
    set_cap(c, m.len)
    let stride = usize(m.stride)
    let kretain = m.kops.retain
    let vretain = m.vops.retain
    var e: i64 = 0
    while e < m.n {
      if !m.dead.at(e) {
        let k = c.n
        c.n += 1
        raw.copy(abi.map_key(c, k), abi.map_key(m, e), stride)
        if !kretain.is_null() {
          kretain(raw.cast(abi.map_key(c, k)))
        }
        if !vretain.is_null() {
          vretain(raw.cast(abi.map_val(c, k)))
        }
        c.hashes.at(k) = m.hashes.at(e)
        c.dead.at(k) = false
      }
      e += 1
    }
    c.len = c.n
    rebuild_index(c, icap_for(c.cap))
  }
  c
}

// rc.c's auk_refcount, auk__tmp_get/auk__tmp_done, which map.c's translation unit inlined:
// here, so that they still are (a call into the C half can't be)

fn refcount(p: raw.Ptr<abi.Map>): i64 uses raw =
  if p.is_null() { 0 } else { raw.atomic_load(raw.field_addr(raw.field_addr(p, .h), .rc), raw.Order.SeqCst) }

fn tmp_get(t: raw.Ptr<abi.Tmp>, size: usize): raw.Ptr<u8> uses raw, ffi {
  t.heap = if size <= raw.size_of<abi.Tmp>() - 8 { raw.null() } else { auk__xmalloc(size) }
  if t.heap.is_null() { t.stack } else { t.heap }
}

fn tmp_done(t: raw.Ptr<abi.Tmp>) uses raw {
  if !t.heap.is_null() { raw.free(t.heap) }
}

export fn auk_map_make_unique(pm: raw.Ptr<raw.Ptr<abi.Map>>): raw.Ptr<()> uses raw, ffi {
  let m = pm.load()
  if refcount(m) != 1 {
    pm.store(auk_map_copy(m))
    auk_release(raw.cast(m))
  }
  raw.cast(pm.load())
}

/// Scratch room for a key or a value of up to 32 bytes (every scalar, `str`, `Value`, small
/// tuples), uninitialized as `abi.Tmp` is, without tmp_get's size test.
raw struct Scratch {
  w: [u64; 4],
}

pub export fn auk_map_set(pm: raw.Ptr<raw.Ptr<abi.Map>>, k_in: raw.Ptr<()>, v_in: raw.Ptr<()>) uses raw, ffi {
  let m0 = pm.load()
  let ks = m0.kops.size
  let vs = m0.vops.size
  if ks <= raw.size_of<Scratch>() && vs <= raw.size_of<Scratch>() {
    var kb: Scratch
    var vb: Scratch
    set_via(pm, k_in, v_in, raw.cast(raw.addr_of(&kb)), raw.cast(raw.addr_of(&vb)))
    return
  }
  var kt: abi.Tmp
  var vt: abi.Tmp
  set_via(pm, k_in, v_in, tmp_get(raw.addr_of(&kt), ks), tmp_get(raw.addr_of(&vt), vs))
  tmp_done(raw.addr_of(&kt))
  tmp_done(raw.addr_of(&vt))
}

/// auk_map_set with k and v: room for the key and the value.
fn set_via(pm: raw.Ptr<raw.Ptr<abi.Map>>, k_in: raw.Ptr<()>, v_in: raw.Ptr<()>, k: raw.Ptr<u8>, v: raw.Ptr<u8>) uses raw, ffi {
  let m0 = pm.load()
  // hold copies of key and value (the value retained) before copy-on-write: they may live in
  // *pm
  let ks = m0.kops.size
  let vs = m0.vops.size
  raw.copy(k, k_in, ks)
  raw.copy(v, v_in, vs)
  let vretain = m0.vops.retain
  if !vretain.is_null() {
    vretain(raw.cast(v))
  }
  let _ = auk_map_make_unique(pm)
  let m = pm.load()
  let hash = m.kops.hash
  let h = hash(raw.cast(k))
  let s = find_slot(m, raw.cast(k), h)
  if s >= 0 {
    let e = entry_of(m.index.at(s))
    let vrelease = m.vops.release
    if !vrelease.is_null() {
      vrelease(raw.cast(abi.map_val(m, e)))
    }
    raw.copy(abi.map_val(m, e), v, vs)
  } else {
    let kretain = m.kops.retain
    if !kretain.is_null() {
      kretain(raw.cast(k))
    }
    if m.n == m.cap {
      if m.n - m.len > m.len / 2 && m.n - m.len > 0 {
        compact(m)
      }
      if m.n == m.cap {
        set_cap(m, if m.cap != 0 { m.cap * 2 } else { 4 })
      }
      rebuild_index(m, icap_for(m.cap))
    } else if m.icap == 0 {
      rebuild_index(m, icap_for(m.cap))
    }
    let e = m.n
    m.n += 1
    raw.copy(abi.map_key(m, e), k, ks)
    raw.copy(abi.map_val(m, e), v, vs)
    m.hashes.at(e) = h
    m.dead.at(e) = false
    m.len += 1
    let mask = u64(m.icap) - 1
    var slot = h & mask
    while live(m.index.at(slot)) {
      slot = (slot + 1) & mask
    }
    m.index.at(slot) = slot_of(h, e)
  }
}

export fn auk_map_remove(pm: raw.Ptr<raw.Ptr<abi.Map>>, k_in: raw.Ptr<()>, out: raw.Ptr<()>): bool uses raw, ffi {
  if !auk_map_contains(pm.load(), k_in) {
    return false
  }
  let ks = pm.load().kops.size
  var kt: abi.Tmp
  let k = tmp_get(raw.addr_of(&kt), ks)
  raw.copy(k, k_in, ks)
  let kretain = pm.load().kops.retain
  if !kretain.is_null() {
    kretain(raw.cast(k))
  }
  let _ = auk_map_make_unique(pm)
  let m = pm.load()
  let hash = m.kops.hash
  let s = find_slot(m, raw.cast(k), hash(raw.cast(k)))
  let e = entry_of(m.index.at(s))
  m.index.at(s) = TOMB
  m.dead.at(e) = true
  m.len -= 1
  let krelease = m.kops.release
  if !krelease.is_null() {
    krelease(raw.cast(abi.map_key(m, e)))
  }
  let vrelease = m.vops.release
  if !out.is_null() {
    raw.copy(out, abi.map_val(m, e), m.vops.size)
  } else if !vrelease.is_null() {
    vrelease(raw.cast(abi.map_val(m, e)))
  }
  if m.n - m.len > 16 && m.n - m.len > m.len {
    compact(m)
    rebuild_index(m, icap_for(m.cap))
  }
  if !krelease.is_null() {
    krelease(raw.cast(k))
  }
  tmp_done(raw.addr_of(&kt))
  true
}

inline export fn auk_map_next(
  m: raw.Ptr<abi.Map>,
  it: raw.Ptr<i64>,
  k: raw.Ptr<raw.Ptr<()>>,
  v: raw.Ptr<raw.Ptr<()>>,
): bool uses raw {
  if m.is_null() {
    return false
  }
  while it.load() < m.n {
    let e = it.load()
    it.store(e + 1)
    if m.dead.at(e) {
      continue
    }
    if !k.is_null() {
      k.store(raw.cast(abi.map_key(m, e)))
    }
    if !v.is_null() {
      v.store(raw.cast(abi.map_val(m, e)))
    }
    return true
  }
  false
}

export fn auk_map_keys(m: raw.Ptr<abi.Map>): raw.Ptr<abi.Arr> uses raw, ffi {
  var a = arr.auk_arr_new(m.kops, m.len)
  var it: i64 = 0
  var k: raw.Ptr<()> = raw.null()
  while auk_map_next(m, raw.addr_of(&it), raw.addr_of(&k), raw.null()) {
    arr.auk_arr_push(raw.addr_of(&a), k)
  }
  a
}

export fn auk_map_values(m: raw.Ptr<abi.Map>): raw.Ptr<abi.Arr> uses raw, ffi {
  var a = arr.auk_arr_new(m.vops, m.len)
  var it: i64 = 0
  var v: raw.Ptr<()> = raw.null()
  while auk_map_next(m, raw.addr_of(&it), raw.null(), raw.addr_of(&v)) {
    arr.auk_arr_push(raw.addr_of(&a), v)
  }
  a
}

pub export fn auk_map_eq(a: raw.Ptr<abi.Map>, b: raw.Ptr<abi.Map>): bool uses raw, ffi {
  if a.int() == b.int() {
    return true
  }
  if auk_map_len(a) != auk_map_len(b) {
    return false
  }
  if a.is_null() || b.is_null() {
    return true // both empty
  }
  var it: i64 = 0
  var k: raw.Ptr<()> = raw.null()
  var v: raw.Ptr<()> = raw.null()
  while auk_map_next(a, raw.addr_of(&it), raw.addr_of(&k), raw.addr_of(&v)) {
    let w = auk_map_find(b, k)
    let eq = a.vops.eq
    if w.is_null() || eq.is_null() || !eq(v, w) {
      return false
    }
  }
  true
}

pub export fn auk_map_show(m: raw.Ptr<abi.Map>): raw.Ptr<abi.Str> uses raw, ffi {
  var b = abi.StrBuf {}
  let pb = raw.addr_of(&b)
  auk_sb_char(pb, 123) // '{'
  var it: i64 = 0
  var k: raw.Ptr<()> = raw.null()
  var v: raw.Ptr<()> = raw.null()
  var first = true
  while !auk__show_exhausted() && auk_map_next(m, raw.addr_of(&it), raw.addr_of(&k), raw.addr_of(&v)) {
    if !first {
      auk_sb_lit(pb, ", ")
    }
    first = false
    let kshow = m.kops.show
    let vshow = m.vops.show
    if kshow.is_null() || vshow.is_null() {
      auk__panic_rt("show: key or value type has no show")
      raw.unreachable()
    }
    auk_sb_str_own(pb, kshow(k))
    auk_sb_lit(pb, ": ")
    auk_sb_str_own(pb, vshow(v))
  }
  auk_sb_char(pb, 125) // '}'
  auk_sb_finish(pb)
}

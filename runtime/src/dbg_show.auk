/// The debugger's frames, locals and parts (was the "frames, locals and parts" part of
/// runtime/c/dbg.c, ported line by line): a frame as JSON, a value shown with the show budget,
/// the walk of a value's parts (generated children functions report them through
/// auk_dbg_kid/_kid_arr/_kid_map), the locals in scope at a frame's statement. dbg.auk is the
/// engine.

extern fn strcmp(a: raw.Ptr<u8>, b: raw.Ptr<u8>): i32 = "int strcmp(const char *, const char *)"

/// A frame's current site: generated code stores it (one aligned 8-byte store) at each
/// statement, and the thread may be running (see dbg.auk's frame_op), so it is read in one load.
pub fn frame_site(f: raw.Ptr<abi.DbgFrame>): i64 uses raw = raw.atomic_load(raw.field_addr(f, .site), raw.Order.Relaxed)

/// {"fn":..,"file":..,"line":..,"col":..} of a frame into t; false for no frame.
pub fn frame_json(t: raw.Ptr<dbg_text.Text>, f: raw.Ptr<abi.DbgFrame>): bool uses raw, ffi {
  let inf = dbg_info.info
  if f.is_null() || inf.is_null() {
    return false
  }
  let func = f.func
  let site = frame_site(f)
  dbg_text.put(t, "{{\"fn\":")
  let name: raw.Ptr<u8> = if func >= 0 && func < inf.nfns { inf.fns.offset(func).name } else { "?" }
  dbg_text.jsonc(t, name)
  if site >= 0 && site < inf.nsites {
    let s = inf.sites.offset(site)
    dbg_text.put(t, ",\"file\":")
    dbg_text.jsonc(t, inf.files.at(s.file))
    dbg_text.put(t, ",\"line\":")
    dbg_text.put_int(t, i64(s.line))
    dbg_text.put(t, ",\"col\":")
    dbg_text.put_int(t, i64(s.col))
  }
  dbg_text.put(t, "}}")
  true
}

/// How many bytes of a value's text are shown.
raw let SHOW_MAX: i64 = 1000

/// A value of type ty at p, shown (cut to about 1000 bytes; malloc'd).
fn show_value(ty: u32, p: raw.Ptr<()>): raw.Ptr<u8> uses raw, ffi {
  let left = str.auk__show_left()
  str.auk__set_show_left(SHOW_MAX + 24)
  let show = dbg_info.info.shows.at(ty)
  let s = show(p)
  str.auk__set_show_left(left)
  let r = dbg_text.cut_text(str.auk_str_cstr(s), usize(str.auk_str_byte_len(s)), usize(SHOW_MAX))
  rc.release(raw.cast(s))
  r
}

/// At most this many parts of one value are listed.
raw let KIDS_MAX: i64 = 1000

/// The walk of a value's parts: down path (a part index per level), then listing the parts of
/// the value reached.
raw struct KidCtx {
  path: raw.Ptr<u32>,
  npath: i64,
  depth: i64,
  counter: u32,
  listing: bool,
  /// listing only counts (in more)
  count_only: bool,
  found: bool,
  done: bool,
  out: dbg_text.Text,
  nout: i64,
  more: i64,
}

/// Does this value have parts (a variant with fields, a non-empty list...)?
fn has_parts(ty: u32, p: raw.Ptr<()>): bool uses raw {
  let k = dbg_info.info.kids.at(ty)
  if k.is_null() {
    return false
  }
  var c = KidCtx { listing: true, count_only: true, found: true }
  k(p, raw.cast(raw.addr_of(&c)))
  raw.free(c.out.p)
  c.more > 0
}

/// {"name","type","value"[,"kids":true]} of a value of type ty at p.
pub fn item_json(t: raw.Ptr<dbg_text.Text>, name: raw.Ptr<u8>, ty: u32, p: raw.Ptr<()>) uses raw, ffi {
  let inf = dbg_info.info
  let value = show_value(ty, p)
  dbg_text.put(t, "{{\"name\":")
  dbg_text.jsonc(t, name)
  dbg_text.put(t, ",\"type\":")
  let tyname: raw.Ptr<u8> = if i64(ty) < inf.ntypes { inf.types.at(ty) } else { "?" }
  dbg_text.jsonc(t, tyname)
  dbg_text.put(t, ",\"value\":")
  dbg_text.jsonc(t, value)
  if has_parts(ty, p) {
    dbg_text.put(t, ",\"kids\":true")
  }
  dbg_text.put(t, "}}")
  raw.free(value)
}

// Where a part's name comes from (computed only when it is listed).
raw let NAME_TEXT: i32 = 0
raw let NAME_INDEX: i32 = 1
raw let NAME_KEY: i32 = 2

raw struct PartName {
  kind: i32,
  text: raw.Ptr<u8>,
  index: i64,
  map: raw.Ptr<abi.Map>,
  key: raw.Ptr<()>,
}

fn part_name(n: raw.Ptr<PartName>): raw.Ptr<u8> uses raw, ffi {
  if n.kind == NAME_TEXT {
    return dbg_text.dup_s(n.text)
  }
  if n.kind == NAME_INDEX {
    var b: [u8; 24]
    let bp = raw.cast<u8>(raw.addr_of(&b))
    let _ = str_fmt.auk__fmt_i64(bp, n.index)
    return dbg_text.dup_s(bp)
  }
  let show = n.map.kops.show
  if show.is_null() {
    return dbg_text.dup_s("?")
  }
  let s = show(n.key)
  let r = dbg_text.dup_n(str.auk_str_cstr(s), usize(str.auk_str_byte_len(s)))
  rc.release(raw.cast(s))
  r
}

/// One part (index counter) of the value being walked.
fn kid(c: raw.Ptr<KidCtx>, name: raw.Ptr<PartName>, ty: u32, p: raw.Ptr<()>) uses raw, ffi {
  if c.done {
    return
  }
  if c.listing {
    if c.count_only || c.nout >= KIDS_MAX {
      c.more += 1
      // one part is enough to know there are some
      c.done = c.count_only
    } else {
      let nm = part_name(name)
      var item = dbg_text.Text {}
      item_json(raw.addr_of(&item), nm, ty, p)
      if c.nout != 0 {
        dbg_text.put(raw.field_addr(c, .out), ",")
      }
      dbg_text.put(raw.field_addr(c, .out), item.p)
      c.nout += 1
      raw.free(item.p)
      raw.free(nm)
    }
    return
  }
  let i = c.counter
  c.counter += 1
  if i != c.path.at(c.depth) {
    return
  }
  // the part on the path: walk into it (only one path, so the walk ends after it)
  let k = dbg_info.info.kids.at(ty)
  if k.is_null() {
    c.done = true
    return
  }
  if c.depth + 1 == c.npath {
    c.listing = true
    c.found = true
  } else {
    c.depth += 1
    c.counter = 0
  }
  k(p, raw.cast(c))
  c.listing = false
  c.done = true
}

/// Generated children functions report a named part.
export fn auk_dbg_kid(ctx: raw.Ptr<()>, name: raw.Ptr<u8>, ty: i64, p: raw.Ptr<()>) uses raw, ffi {
  var n = PartName { kind: NAME_TEXT, text: name }
  kid(raw.cast(ctx), raw.addr_of(&n), u32(ty), p)
}

/// The elements of a list (elem bytes each).
export fn auk_dbg_kid_arr(ctx: raw.Ptr<()>, list: raw.Ptr<()>, ty: i64, elem: i64) uses raw, ffi {
  let a: raw.Ptr<abi.Arr> = raw.cast(list)
  let c: raw.Ptr<KidCtx> = raw.cast(ctx)
  if a.is_null() || c.done {
    return
  }
  if !c.listing {
    // walking through: straight to the element on the path
    let i = i64(c.path.at(c.depth))
    if i < a.len {
      c.counter = u32(i)
      var n = PartName { kind: NAME_INDEX, index: i }
      kid(c, raw.addr_of(&n), u32(ty), raw.cast(a.data.offset(i * elem)))
    } else {
      c.done = true
    }
    return
  }
  var shown: i64 = 0
  if !c.count_only {
    let room = KIDS_MAX - c.nout
    shown = if a.len < room { a.len } else if room > 0 { room } else { 0 }
  }
  var i: i64 = 0
  while i < shown {
    var n = PartName { kind: NAME_INDEX, index: i }
    kid(c, raw.addr_of(&n), u32(ty), raw.cast(a.data.offset(i * elem)))
    i += 1
  }
  c.more += a.len - shown
}

/// The entries of a map: each value, named by its key shown.
export fn auk_dbg_kid_map(ctx: raw.Ptr<()>, mp: raw.Ptr<()>, ty: i64) uses raw, ffi {
  let m: raw.Ptr<abi.Map> = raw.cast(mp)
  if m.is_null() {
    return
  }
  var it: i64 = 0
  var k: raw.Ptr<()> = raw.null()
  var v: raw.Ptr<()> = raw.null()
  while map.auk_map_next(m, raw.addr_of(&it), raw.addr_of(&k), raw.addr_of(&v)) {
    var n = PartName { kind: NAME_KEY, map: m, key: k }
    kid(raw.cast(ctx), raw.addr_of(&n), u32(ty), v)
  }
}

/// A local in scope at a frame's current statement.
pub raw struct LocalRef {
  name: raw.Ptr<u8>,
  ty: u32,
  p: raw.Ptr<()>,
}

/// The locals in scope at a frame's current statement, in binding order (malloc'd, *n of them).
/// A shadowed name gives only its latest binding.
pub fn locals_of(f: raw.Ptr<abi.DbgFrame>, n: raw.Ptr<i64>): raw.Ptr<LocalRef> uses raw, ffi {
  n.store(0)
  let inf = dbg_info.info
  let site = frame_site(f)
  if inf.is_null() || f.func < 0 || f.func >= inf.nfns || site < 0 || site >= inf.nsites {
    return raw.null()
  }
  let fi = inf.fns.offset(f.func)
  let s = inf.sites.offset(site)
  let out: raw.Ptr<LocalRef> = raw.cast(raw.alloc(usize(s.nvis + 1) * raw.size_of<LocalRef>()))
  var k: i64 = 0
  var i = s.nvis - 1
  while i >= 0 {
    let slot = s.vis.at(i)
    if i64(slot) < fi.nlocals {
      let name = fi.locals.offset(slot).name
      var seen = strcmp(name, "_") == 0
      var j: i64 = 0
      while j < k && !seen {
        seen = strcmp(out.offset(j).name, name) == 0
        j += 1
      }
      let p = f.slots.at(slot)
      if !seen && !p.is_null() {
        let o = out.offset(k)
        o.name = name
        o.ty = fi.locals.offset(slot).ty
        o.p = p
        k += 1
      }
    }
    i -= 1
  }
  // back into binding order
  i = 0
  while i < k / 2 {
    let t = out.at(i)
    out.at(i) = out.at(k - 1 - i)
    out.at(k - 1 - i) = t
    i += 1
  }
  n.store(k)
  out
}

/// ,"kids":[...] (and "more":N) for the parts of the value at p reached by path into t; false
/// with *err (a constant).
pub fn kids_json(t: raw.Ptr<dbg_text.Text>, ty: u32, p: raw.Ptr<()>, path: raw.Ptr<u32>, npath: i64, err: raw.Ptr<raw.Ptr<u8>>): bool uses raw, ffi {
  let k = dbg_info.info.kids.at(ty)
  if k.is_null() {
    err.store("the value has no parts")
    return false
  }
  var c = KidCtx { path, npath, listing: npath == 0, found: npath == 0 }
  k(p, raw.cast(raw.addr_of(&c)))
  if !c.found {
    raw.free(c.out.p)
    err.store("no such part")
    return false
  }
  dbg_text.put(t, ",\"kids\":[")
  if !c.out.p.is_null() {
    dbg_text.put(t, c.out.p)
  }
  dbg_text.put(t, "]")
  if c.more > 0 {
    dbg_text.put(t, ",\"more\":")
    dbg_text.put_int(t, c.more)
  }
  raw.free(c.out.p)
  true
}

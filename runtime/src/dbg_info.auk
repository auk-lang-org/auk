/// The debugger's debug info (was the "debug info" parts of runtime/c/dbg.c, ported line by
/// line): the program's files, types, functions with their locals, and sites, parsed from the
/// text generated main passes to auk_dbg_init (`dbg_tables` in compiler/src/mir/build.auk); the
/// per-site breakpoint counts; and resolving a breakpoint spec (`file:line` or a function) to
/// sites. dbg.auk is the engine.

extern fn c_strlen(s: raw.Ptr<u8>): usize = "size_t strlen(const char *)"
extern fn strcmp(a: raw.Ptr<u8>, b: raw.Ptr<u8>): i32 = "int strcmp(const char *, const char *)"
extern fn strchr(s: raw.Ptr<u8>, c: i32): raw.Ptr<u8> = "char *strchr(const char *, int)"
extern fn strrchr(s: raw.Ptr<u8>, c: i32): raw.Ptr<u8> = "char *strrchr(const char *, int)"
extern fn realpath(path: raw.Ptr<u8>, out: raw.Ptr<u8>): raw.Ptr<u8> = "char *realpath(const char *, char *)"

/// `AukStr *show(void *value)`: a local's value shown (debug `Show`), one per type.
pub raw type ShowFn = raw.Fn<(raw.Ptr<()>) => raw.Ptr<abi.Str>>
/// `void kids(void *value, void *ctx)`: reports each part through auk_dbg_kid.
pub raw type KidsFn = raw.Fn<(raw.Ptr<()>, raw.Ptr<()>) => ()>

pub raw struct Site {
  func: u32,
  file: u32,
  line: u32,
  col: u32,
  vis: raw.Ptr<u32>,
  nvis: i64,
}

pub raw struct Local {
  name: raw.Ptr<u8>,
  ty: u32,
}

pub raw struct FnInfo {
  name: raw.Ptr<u8>,
  locals: raw.Ptr<Local>,
  nlocals: i64,
  caplocals: i64,
}

pub raw struct Info {
  files: raw.Ptr<raw.Ptr<u8>>,
  nfiles: i64,
  types: raw.Ptr<raw.Ptr<u8>>,
  ntypes: i64,
  fns: raw.Ptr<FnInfo>,
  nfns: i64,
  sites: raw.Ptr<Site>,
  nsites: i64,
  shows: raw.Ptr<ShowFn>,
  /// the children function of each type (null: a type without parts)
  kids: raw.Ptr<KidsFn>,
  /// breakpoints set at each site (a count: several breakpoints may share one); atomic
  bp: raw.Ptr<u32>,
}

/// The program's debug info (null until auk_dbg_init attaches).
pub raw var info: raw.Ptr<Info> = raw.null()

/// C's UINT32_MAX.
raw let U32_MAX: i64 = 4294967295

fn push_str(a: raw.Ptr<raw.Ptr<raw.Ptr<u8>>>, n: raw.Ptr<i64>, s: raw.Ptr<u8>) uses raw, ffi {
  let arr: raw.Ptr<raw.Ptr<u8>> = raw.cast(raw.realloc(a.load(), usize(n.load() + 1) * raw.size_of<raw.Ptr<u8>>()))
  a.store(arr)
  arr.at(n.load()) = dbg_text.dup_s(s)
  n.store(n.load() + 1)
}

fn to_u32(s: raw.Ptr<u8>): u32 uses raw, ffi {
  var v: i64 = 0
  if dbg_text.parse_i64(s, raw.addr_of(&v)) && v >= 0 && v <= U32_MAX && s.load() != 0x2B { u32(v) } else { 0 }
}

/// Parse the debug info text (see dbg_tables in compiler/src/mir/build.auk).
pub fn parse(text: raw.Ptr<u8>, shows: raw.Ptr<ShowFn>, kids: raw.Ptr<KidsFn>): raw.Ptr<Info> uses raw, ffi {
  let inf: raw.Ptr<Info> = raw.cast(dbg_text.zalloc(raw.size_of<Info>()))
  inf.shows = shows
  inf.kids = kids
  var capsites: i64 = 0
  var p = text
  while p.load() != 0 {
    let e = strchr(p, 0x0A)
    let n: usize = if e.is_null() { c_strlen(p) } else { usize(e.int() - p.int()) }
    let line = dbg_text.dup_n(p, n)
    if n > 0 && line.at(n - 1) == 0x0D {
      line.at(n - 1) = 0
    }
    let sp = strchr(line, 0x20)
    if !sp.is_null() {
      sp.store(0)
      let k = line
      let rest = sp.offset(1)
      if dbg_text.eq(k, "p") {
        push_str(raw.field_addr(inf, .files), raw.field_addr(inf, .nfiles), rest)
      } else if dbg_text.eq(k, "t") {
        push_str(raw.field_addr(inf, .types), raw.field_addr(inf, .ntypes), rest)
      } else if dbg_text.eq(k, "f") {
        inf.fns = raw.cast(raw.realloc(inf.fns, usize(inf.nfns + 1) * raw.size_of<FnInfo>()))
        let f = inf.fns.offset(inf.nfns)
        inf.nfns += 1
        raw.fill(f, 0, raw.size_of<FnInfo>())
        f.name = dbg_text.dup_s(rest)
      } else if dbg_text.eq(k, "v") && inf.nfns > 0 {
        let sp2 = strchr(rest, 0x20)
        let t = if sp2.is_null() { dbg_text.dup_s(rest) } else { dbg_text.dup_n(rest, usize(sp2.int() - rest.int())) }
        let name: raw.Ptr<u8> = if sp2.is_null() { "?" } else { sp2.offset(1) }
        let f = inf.fns.offset(inf.nfns - 1)
        if f.nlocals == f.caplocals {
          f.caplocals = if f.caplocals == 0 { 8 } else { f.caplocals * 2 }
          f.locals = raw.cast(raw.realloc(f.locals, usize(f.caplocals) * raw.size_of<Local>()))
        }
        let l = f.locals.offset(f.nlocals)
        l.name = dbg_text.dup_s(name)
        l.ty = to_u32(t)
        f.nlocals += 1
        raw.free(t)
      } else if dbg_text.eq(k, "s") {
        // func file line col vis,vis,... (split on single spaces)
        var fields: [raw.Ptr<u8>; 5]
        let fp = raw.cast<raw.Ptr<u8>>(raw.addr_of(&fields))
        var i: i64 = 0
        while i < 5 {
          fp.at(i) = raw.null()
          i += 1
        }
        var q = rest
        i = 0
        while i < 5 && !q.is_null() {
          fp.at(i) = q
          let s2 = strchr(q, 0x20)
          if !s2.is_null() {
            s2.store(0)
            q = s2.offset(1)
          } else {
            q = raw.null()
          }
          i += 1
        }
        if inf.nsites == capsites {
          capsites = if capsites == 0 { 64 } else { capsites * 2 }
          inf.sites = raw.cast(raw.realloc(inf.sites, usize(capsites) * raw.size_of<Site>()))
        }
        let s = inf.sites.offset(inf.nsites)
        inf.nsites += 1
        raw.fill(s, 0, raw.size_of<Site>())
        s.func = if !fp.at(0).is_null() { to_u32(fp.at(0)) } else { 0 }
        s.file = if !fp.at(1).is_null() { to_u32(fp.at(1)) } else { 0 }
        s.line = if !fp.at(2).is_null() { to_u32(fp.at(2)) } else { 0 }
        s.col = if !fp.at(3).is_null() { to_u32(fp.at(3)) } else { 0 }
        if !fp.at(4).is_null() {
          let len = c_strlen(fp.at(4))
          s.vis = raw.cast(raw.alloc((len + 2) * raw.size_of<u32>()))
          var v = fp.at(4)
          while !v.is_null() {
            let comma = strchr(v, 0x2C)
            if !comma.is_null() {
              comma.store(0)
            }
            var x: i64 = 0
            if dbg_text.parse_i64(v, raw.addr_of(&x)) && x >= 0 && x <= U32_MAX && v.load() != 0x2B {
              s.vis.at(s.nvis) = u32(x)
              s.nvis += 1
            }
            v = if comma.is_null() { raw.null() } else { comma.offset(1) }
          }
        }
      }
    }
    raw.free(line)
    if e.is_null() {
      break
    }
    p = e.offset(1)
  }
  inf.bp = raw.cast(dbg_text.zalloc(usize(inf.nsites + 1) * raw.size_of<u32>()))
  inf
}

/// The sites of a breakpoint spec (file:line or a function name), with its file and resolved
/// line; null with *err (malloc'd).
pub fn resolve(spec: raw.Ptr<u8>, nsites: raw.Ptr<i64>, file_out: raw.Ptr<raw.Ptr<u8>>, line_out: raw.Ptr<u32>, err: raw.Ptr<raw.Ptr<u8>>): raw.Ptr<u32> uses raw, ffi {
  let inf = info
  let colon = strrchr(spec, 0x3A)
  var line: i64 = 0
  if !colon.is_null() && dbg_text.parse_i64(colon.offset(1), raw.addr_of(&line)) && colon.at(1) != 0x2D && colon.at(1) != 0x2B && line >= 0 && line <= U32_MAX {
    let file = dbg_text.dup_n(spec, usize(colon.int() - spec.int()))
    var real: [u8; 4096]
    let realp = raw.cast<u8>(raw.addr_of(&real))
    let want = if !realpath(file, realp).is_null() { realp } else { file }
    var slash = dbg_text.Text {}
    dbg_text.put(raw.addr_of(&slash), "/")
    dbg_text.put(raw.addr_of(&slash), file)
    let inp: raw.Ptr<bool> = raw.cast(dbg_text.zalloc((usize(inf.nfiles) + 1) * raw.size_of<bool>()))
    var any = false
    var i: i64 = 0
    while i < inf.nfiles {
      let f = inf.files.at(i)
      let hit = strcmp(f, want) == 0 || dbg_text.ends_with(f, slash.p) || strcmp(f, file) == 0
      inp.at(i) = hit
      any = any || hit
      i += 1
    }
    raw.free(slash.p)
    var m = dbg_text.Text {}
    let mp = raw.addr_of(&m)
    if !any {
      dbg_text.put(mp, "no code in `")
      dbg_text.put(mp, file)
      dbg_text.put(mp, "`")
      err.store(m.p)
      raw.free(inp)
      raw.free(file)
      return raw.null()
    }
    var best: i64 = -1
    i = 0
    while i < inf.nsites {
      let s = inf.sites.offset(i)
      if inp.at(s.file) && i64(s.line) >= line && (best < 0 || i64(s.line) < best) {
        best = i64(s.line)
      }
      i += 1
    }
    if best < 0 {
      dbg_text.put(mp, "no code at or after ")
      dbg_text.put(mp, file)
      dbg_text.put(mp, ":")
      dbg_text.put_int(mp, line)
      err.store(m.p)
      raw.free(inp)
      raw.free(file)
      return raw.null()
    }
    // the first statement on that line in each function (instance)
    let sites: raw.Ptr<u32> = raw.cast(raw.alloc(usize(inf.nsites) * raw.size_of<u32>()))
    let fns: raw.Ptr<u32> = raw.cast(raw.alloc(usize(inf.nsites) * raw.size_of<u32>()))
    var k: i64 = 0
    i = 0
    while i < inf.nsites {
      let s = inf.sites.offset(i)
      if inp.at(s.file) && i64(s.line) == best {
        var seen = false
        var j: i64 = 0
        while j < k && !seen {
          seen = fns.at(j) == s.func
          j += 1
        }
        if !seen {
          fns.at(k) = s.func
          sites.at(k) = u32(i)
          k += 1
        }
      }
      i += 1
    }
    raw.free(fns)
    raw.free(inp)
    raw.free(file)
    nsites.store(k)
    file_out.store(inf.files.at(inf.sites.offset(sites.at(0)).file))
    line_out.store(u32(best))
    return sites
  }
  var dot = dbg_text.Text {}
  dbg_text.put(raw.addr_of(&dot), ".")
  dbg_text.put(raw.addr_of(&dot), spec)
  let sites: raw.Ptr<u32> = raw.cast(raw.alloc(usize(inf.nfns + 1) * raw.size_of<u32>()))
  var k: i64 = 0
  var fi: i64 = 0
  while fi < inf.nfns {
    let name = inf.fns.offset(fi).name
    if strcmp(name, spec) == 0 || dbg_text.ends_with(name, dot.p) {
      var i: i64 = 0
      while i < inf.nsites {
        if i64(inf.sites.offset(i).func) == fi {
          sites.at(k) = u32(i)
          k += 1
          break
        }
        i += 1
      }
    }
    fi += 1
  }
  raw.free(dot.p)
  if k == 0 {
    raw.free(sites)
    var m = dbg_text.Text {}
    dbg_text.put(raw.addr_of(&m), "no function `")
    dbg_text.put(raw.addr_of(&m), spec)
    dbg_text.put(raw.addr_of(&m), "`")
    err.store(m.p)
    return raw.null()
  }
  let s = inf.sites.offset(sites.at(0))
  nsites.store(k)
  file_out.store(inf.files.at(s.file))
  line_out.store(s.line)
  sites
}

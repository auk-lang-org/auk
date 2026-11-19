/// The core library's `fs` (was runtime/c/core.c, ported line by line): whole-file reads and
/// writes through stdio, directories, rename, temporary directories. Every error message is
/// C's: "<what> <path>: <strerror>" with the errno as the code.

// the rest of the runtime (C, for now)
extern fn auk__xmalloc(n: usize): raw.Ptr<()> = "void *auk__xmalloc(size_t)"
extern fn auk__xrealloc(p: raw.Ptr<()>, n: usize): raw.Ptr<()> = "void *auk__xrealloc(void *, size_t)"
extern fn auk_release(p: raw.Ptr<()>) = "void auk_release(void *)"
extern fn auk_str_try_from_bytes(p: raw.Ptr<u8>, n: i64): abi.ResStr = "AukRes_str auk_str_try_from_bytes(const char *, int64_t)"
// libc
extern fn fopen(path: raw.Ptr<u8>, mode: raw.Ptr<u8>): raw.Ptr<()> = "void *fopen(const char *, const char *)"
extern fn fclose(f: raw.Ptr<()>): i32 = "int fclose(void *)"
extern fn fwrite(p: raw.Ptr<()>, size: usize, n: usize, f: raw.Ptr<()>): usize = "size_t fwrite(const void *, size_t, size_t, void *)"
extern fn stat(path: raw.Ptr<u8>, st: raw.Ptr<cfacts.Stat>): i32 = "int stat(const char *, void *)"
extern fn lstat(path: raw.Ptr<u8>, st: raw.Ptr<cfacts.Stat>): i32 = "int lstat(const char *, void *)"
extern fn opendir(path: raw.Ptr<u8>): raw.Ptr<()> = "void *opendir(const char *)"
extern fn readdir(d: raw.Ptr<()>): raw.Ptr<cfacts.Dirent> = "void *readdir(void *)"
extern fn closedir(d: raw.Ptr<()>): i32 = "int closedir(void *)"
extern fn mkdir(path: raw.Ptr<u8>, mode: u32): i32 = "int mkdir(const char *, uint32_t)"
extern fn rmdir(path: raw.Ptr<u8>): i32 = "int rmdir(const char *)"
extern fn unlink(path: raw.Ptr<u8>): i32 = "int unlink(const char *)"
extern fn rename(from: raw.Ptr<u8>, to: raw.Ptr<u8>): i32 = "int rename(const char *, const char *)"
extern fn mkdtemp(tmpl: raw.Ptr<u8>): raw.Ptr<u8> = "char *mkdtemp(char *)"
extern fn getenv(name: raw.Ptr<u8>): raw.Ptr<u8> = "char *getenv(const char *)"
extern fn strlen(s: raw.Ptr<u8>): usize = "size_t strlen(const char *)"
extern fn strcmp(a: raw.Ptr<u8>, b: raw.Ptr<u8>): i32 = "int strcmp(const char *, const char *)"
extern fn strerror(err: i32): raw.Ptr<u8> = "char *strerror(int)"
extern fn qsort(base: raw.Ptr<()>, n: usize, size: usize, cmp: raw.Fn<(raw.Ptr<()>, raw.Ptr<()>) => i32>) =
  "void qsort(void *, size_t, size_t, void *)"

export fn auk_fs_read(path: raw.Ptr<abi.Str>): abi.ResStr uses raw, ffi {
  let f = fopen(str.auk_str_cstr(path), "rb")
  if f.is_null() {
    return core_util.str_err(err.auk__err_errno("fs.read", path, cfacts.errno()))
  }
  var b = core_util.Bytes {}
  let e = core_util.slurp(f, raw.addr_of(&b))
  fclose(f)
  if e != 0 {
    raw.free(b.p)
    return core_util.str_err(err.auk__err_errno("fs.read", path, e))
  }
  var r = auk_str_try_from_bytes(b.p, b.n)
  raw.free(b.p)
  if !r.ok {
    // "fs.read <path>: invalid UTF-8 at byte N"
    var m = abi.StrBuf {}
    let mp = raw.addr_of(&m)
    str.auk__sb_put_cstr(mp, "fs.read ")
    str.auk__sb_put_cstr(mp, str.auk_str_cstr(path))
    let e2 = str.auk__err_sb(mp)
    e2.cause = r.err // moves the reference
    r.err = e2
  }
  r
}

fn write_file(what: raw.Ptr<u8>, mode: raw.Ptr<u8>, path: raw.Ptr<abi.Str>, p: raw.Ptr<()>, n: i64): abi.ResUnit uses raw, ffi {
  let f = fopen(str.auk_str_cstr(path), mode)
  if f.is_null() {
    return core_util.unit_err(err.auk__err_errno(what, path, cfacts.errno()))
  }
  var e: i32 = 0
  if n > 0 && fwrite(p, 1, usize(n), f) != usize(n) {
    let x = cfacts.errno()
    e = if x != 0 { x } else { cfacts.EIO }
  }
  if fclose(f) != 0 && e == 0 {
    e = cfacts.errno()
  }
  if e != 0 {
    return core_util.unit_err(err.auk__err_errno(what, path, e))
  }
  core_util.unit_ok()
}

export fn auk_fs_write(path: raw.Ptr<abi.Str>, content: raw.Ptr<abi.Str>): abi.ResUnit uses raw, ffi =
  write_file("fs.write", "wb", path, raw.cast(str.auk_str_cstr(content)), str.auk_str_byte_len(content))

export fn auk_fs_append(path: raw.Ptr<abi.Str>, text: raw.Ptr<abi.Str>): abi.ResUnit uses raw, ffi =
  write_file("fs.append", "ab", path, raw.cast(str.auk_str_cstr(text)), str.auk_str_byte_len(text))

export fn auk_fs_lines(path: raw.Ptr<abi.Str>): abi.ResArr uses raw, ffi {
  let r = auk_fs_read(path)
  if !r.ok {
    return core_util.arr_err(r.err)
  }
  let lines = str.auk_str_lines(r.val)
  auk_release(raw.cast(r.val))
  core_util.arr_ok(lines)
}

fn stat_is(path: raw.Ptr<abi.Str>, want_dir: bool): bool uses raw, ffi {
  var st = cfacts.Stat {}
  if stat(str.auk_str_cstr(path), raw.addr_of(&st)) != 0 {
    return false
  }
  !want_dir || cfacts.s_isdir(u32(st.st_mode))
}

export fn auk_fs_exists(path: raw.Ptr<abi.Str>): bool uses raw, ffi = stat_is(path, false)

export fn auk_fs_is_dir(path: raw.Ptr<abi.Str>): bool uses raw, ffi = stat_is(path, true)

fn cmp_names(a: raw.Ptr<()>, b: raw.Ptr<()>): i32 uses raw, ffi {
  let pa: raw.Ptr<raw.Ptr<u8>> = raw.cast(a)
  let pb: raw.Ptr<raw.Ptr<u8>> = raw.cast(b)
  strcmp(pa.load(), pb.load())
}

export fn auk_fs_list(dir: raw.Ptr<abi.Str>): abi.ResArr uses raw, ffi {
  let d = opendir(str.auk_str_cstr(dir))
  if d.is_null() {
    return core_util.arr_err(err.auk__err_errno("fs.list", dir, cfacts.errno()))
  }
  var names: raw.Ptr<raw.Ptr<u8>> = raw.null()
  var n: i64 = 0
  var cap: i64 = 0
  cfacts.set_errno(0)
  loop {
    let ent = readdir(d)
    if ent.is_null() {
      break
    }
    let name: raw.Ptr<u8> = raw.cast(raw.field_addr(ent, .d_name))
    if strcmp(name, ".") == 0 || strcmp(name, "..") == 0 {
      continue
    }
    if n == cap {
      cap = if cap == 0 { 16 } else { cap * 2 }
      names = raw.cast(auk__xrealloc(raw.cast(names), usize(cap) * raw.size_of<raw.Ptr<u8>>()))
    }
    let len = strlen(name)
    let copy: raw.Ptr<u8> = raw.cast(auk__xmalloc(len + 1))
    raw.copy(copy, name, len + 1)
    names.at(n) = copy
    n += 1
  }
  let e = cfacts.errno()
  closedir(d)
  if e != 0 {
    var i: i64 = 0
    while i < n {
      raw.free(names.at(i))
      i += 1
    }
    raw.free(names)
    return core_util.arr_err(err.auk__err_errno("fs.list", dir, e))
  }
  if n > 1 {
    qsort(raw.cast(names), usize(n), raw.size_of<raw.Ptr<u8>>(), raw.fn_of(cmp_names)) // strcmp order
  }
  var a = arr.auk_arr_new(str.ops_str(), n)
  var i: i64 = 0
  while i < n {
    var s = str.auk_str_lit(names.at(i))
    arr.auk_arr_push(raw.addr_of(&a), raw.cast(raw.addr_of(&s)))
    auk_release(raw.cast(s))
    raw.free(names.at(i))
    i += 1
  }
  raw.free(names)
  core_util.arr_ok(a)
}

export fn auk_fs_mkdir(path: raw.Ptr<abi.Str>): abi.ResUnit uses raw, ffi {
  let p0 = str.auk_str_cstr(path)
  let len = strlen(p0)
  if len == 0 {
    return core_util.unit_err(err.auk__err_errno("fs.mkdir", path, cfacts.ENOENT))
  }
  let buf: raw.Ptr<u8> = raw.cast(auk__xmalloc(len + 1))
  raw.copy(buf, p0, len + 1)
  var e: i32 = 0
  // create each prefix that ends before a '/', then the whole path
  var i: usize = 1
  while i <= len && e == 0 {
    if i == len || buf.at(i) == 47 { // '/'
      let saved = buf.at(i)
      buf.at(i) = 0
      if mkdir(buf, 511) != 0 { // 0777
        let x = cfacts.errno()
        var st = cfacts.Stat {}
        if x != cfacts.EEXIST {
          e = x
        } else if stat(buf, raw.addr_of(&st)) != 0 {
          e = cfacts.errno()
        } else if !cfacts.s_isdir(u32(st.st_mode)) {
          e = cfacts.ENOTDIR
        }
      }
      buf.at(i) = saved
    }
    i += 1
  }
  raw.free(buf)
  if e != 0 {
    return core_util.unit_err(err.auk__err_errno("fs.mkdir", path, e))
  }
  core_util.unit_ok()
}

export fn auk_fs_remove(path: raw.Ptr<abi.Str>): abi.ResUnit uses raw, ffi {
  let p = str.auk_str_cstr(path)
  var st = cfacts.Stat {}
  var rc = lstat(p, raw.addr_of(&st))
  if rc == 0 {
    rc = if cfacts.s_isdir(u32(st.st_mode)) { rmdir(p) } else { unlink(p) }
  }
  if rc != 0 {
    return core_util.unit_err(err.auk__err_errno("fs.remove", path, cfacts.errno()))
  }
  core_util.unit_ok()
}

export fn auk_fs_rename(from: raw.Ptr<abi.Str>, to: raw.Ptr<abi.Str>): abi.ResUnit uses raw, ffi {
  if rename(str.auk_str_cstr(from), str.auk_str_cstr(to)) != 0 {
    let e = cfacts.errno()
    var m = abi.StrBuf {}
    let mp = raw.addr_of(&m)
    str.auk__sb_put_cstr(mp, "fs.rename ")
    str.auk__sb_put_cstr(mp, str.auk_str_cstr(from))
    str.auk__sb_put_cstr(mp, " -> ")
    str.auk__sb_put_cstr(mp, str.auk_str_cstr(to))
    str.auk__sb_put_cstr(mp, ": ")
    str.auk__sb_put_cstr(mp, strerror(e))
    return core_util.unit_err(core_util.err_code_sb(mp, e))
  }
  core_util.unit_ok()
}

export fn auk_fs_temp_dir(): abi.ResStr uses raw, ffi {
  var base = getenv("TMPDIR")
  if base.is_null() || base.at(0) == 0 {
    base = "/tmp"
  }
  var bl = strlen(base)
  while bl > 1 && base.at(bl - 1) == 47 { // '/'
    bl -= 1
  }
  let suffix: raw.Ptr<u8> = "/auk-XXXXXX"
  let ns = strlen(suffix) + 1
  let tmpl: raw.Ptr<u8> = raw.cast(auk__xmalloc(bl + ns))
  raw.copy(tmpl, base, bl)
  raw.copy(tmpl.offset(bl), suffix, ns)
  if mkdtemp(tmpl).is_null() { // mode 0700, a fresh name
    let e = cfacts.errno()
    var m = abi.StrBuf {}
    let mp = raw.addr_of(&m)
    str.auk__sb_put_cstr(mp, "fs.temp_dir ")
    str.auk__sb_put_cstr(mp, tmpl)
    str.auk__sb_put_cstr(mp, ": ")
    str.auk__sb_put_cstr(mp, strerror(e))
    raw.free(tmpl)
    return core_util.str_err(core_util.err_code_sb(mp, e))
  }
  let s = str.auk_str_lit(tmpl)
  raw.free(tmpl)
  abi.ResStr { ok: true, val: s }
}

export fn auk_fs_read_bytes(path: raw.Ptr<abi.Str>): abi.ResArr uses raw, ffi {
  let f = fopen(str.auk_str_cstr(path), "rb")
  if f.is_null() {
    return core_util.arr_err(err.auk__err_errno("fs.read_bytes", path, cfacts.errno()))
  }
  var b = core_util.Bytes {}
  let e = core_util.slurp(f, raw.addr_of(&b))
  fclose(f)
  if e != 0 {
    raw.free(b.p)
    return core_util.arr_err(err.auk__err_errno("fs.read_bytes", path, e))
  }
  let a = core_util.auk__bytes_to_arr(b.p, b.n)
  raw.free(b.p)
  core_util.arr_ok(a)
}

export fn auk_fs_write_bytes(path: raw.Ptr<abi.Str>, bytes: raw.Ptr<abi.Arr>): abi.ResUnit uses raw, ffi {
  var n: i64 = 0
  var bad_i: i64 = 0
  var bad_x: i64 = 0
  let buf = core_util.arr_to_bytes(bytes, raw.addr_of(&n), raw.addr_of(&bad_i), raw.addr_of(&bad_x))
  if buf.is_null() {
    // checked before the file is touched
    var m = abi.StrBuf {}
    let mp = raw.addr_of(&m)
    str.auk__sb_put_cstr(mp, "fs.write_bytes ")
    str.auk__sb_put_cstr(mp, str.auk_str_cstr(path))
    str.auk__sb_put_cstr(mp, ": byte ")
    str_fmt.auk_sb_int(mp, bad_x)
    str.auk__sb_put_cstr(mp, " at index ")
    str_fmt.auk_sb_int(mp, bad_i)
    str.auk__sb_put_cstr(mp, " is out of range 0..255")
    return core_util.unit_err(str.auk__err_sb(mp))
  }
  let r = write_file("fs.write_bytes", "wb", path, raw.cast(buf), n)
  raw.free(buf)
  r
}

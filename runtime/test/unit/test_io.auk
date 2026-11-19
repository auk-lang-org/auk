/// Console I/O (stdin, eprint, exit), filesystem extras, binary files and secure random (was
/// runtime/c/test/test_io.c).

// ---- stdin -------------------------------------------------------------------------------------

/// Feed the n bytes at t to this (child) process's stdin through a pipe.
fn feed_stdin(t: raw.Ptr<u8>, n: i64) uses raw, ffi {
  var fds: [i32; 2]
  let pf = raw.cast<i32>(raw.addr_of(&fds))
  ut.check(rt.pipe(pf) == 0, "pipe(fds) == 0")
  ut.check(rt.c_write(pf.at(1), raw.cast(t), usize(n)) == n, "write(fds[1], t, n) == (ssize_t)n")
  let _ = rt.close(pf.at(1))
  let _ = rt.dup2(pf.at(0), 0)
  let _ = rt.close(pf.at(0))
  rt.clearerr(core_os.stdin())
}

/// C's FEED(lit): the bytes of a literal (`\x` escapes as ut.bin reads them).
fn feed(lit: raw.Ptr<u8>) uses raw, ffi {
  let b = ut.bin(lit)
  feed_stdin(b.p, b.n)
}

fn stdin_lines(ctx: raw.Ptr<()>) uses raw, ffi {
  let live0 = raw.cast<i64>(ctx).load()
  feed("one\r\ntwo\n\nlast")
  let a = rt.auk_env_read_line()
  let b = rt.auk_env_read_line()
  let _ = rt.printf("[%s][%s]", ut.text(a.val), ut.text(b.val))
  ut.rel(raw.cast(a.val))
  ut.rel(raw.cast(b.val))
  let rest = rt.auk_env_lines() // "", "last"
  let _ = rt.printf("%lld", rt.auk_arr_len(rest))
  ut.rel(raw.cast(rest))
  let eof = rt.auk_env_read_line()
  let _ = rt.printf(" eof=%d", !eof.some)
  let none_ = rt.auk_env_lines()
  let _ = rt.printf(" %lld", rt.auk_arr_len(none_))
  ut.rel(raw.cast(none_))
  if rt.auk_live_objects() != live0 {
    ut.cprint(" LEAK")
  }
}

fn stdin_all(ctx: raw.Ptr<()>) uses raw, ffi {
  feed("x\n")
  let a = rt.auk_env_read_line()
  ut.rel(raw.cast(a.val))
  feed("hé\nllo")
  let r = rt.auk_env_read_all()
  let rt_: raw.Ptr<u8> = if r.ok { ut.text(r.val) } else { "" }
  let _ = rt.printf("ok=%d [%s]", r.ok, rt_)
  ut.rel(raw.cast(r.val))
  feed("bad \\xFF\n")
  let bad = rt.auk_env_read_all()
  let bt: raw.Ptr<u8> = if bad.ok { "" } else { ut.err_text(bad.err) }
  let _ = rt.printf(" | ok=%d %s", bad.ok, bt)
  feed("a\\xFFb\n")
  let lossy = rt.auk_env_read_line()
  let _ = rt.printf(" | %s", ut.text(lossy.val))
  ut.rel(raw.cast(lossy.val))
}

fn stdin_read_line_lines_and_all() uses raw, ffi {
  var live0 = rt.auk_live_objects()
  var out: raw.Ptr<u8> = raw.null()
  var code = ut.child(raw.fn_of(stdin_lines), raw.cast(raw.addr_of(&live0)), raw.addr_of(&out))
  ut.eq(i64(code), 0, "code")
  ut.text_eq(out, "[one][two]2 eof=1 0", "out")
  code = ut.child(raw.fn_of(stdin_all), raw.null(), raw.addr_of(&out))
  ut.eq(i64(code), 0, "code")
  let want: raw.Ptr<u8> = "ok=1 [hé\nllo]"
  if rt.strncmp(out, want, rt.strlen(want)) != 0 {
    let n = rt.strlen(out) + 64
    let m = ut.scratch(n)
    let _ = rt.snprintf(m, n, "unexpected output: %s", out)
    ut.fail(m)
  }
  ut.has(out, "| ok=0 env.read_all: stdin: invalid UTF-8", "out")
  ut.has(out, "| a\u{FFFD}b", "out") // a U+FFFD b
}

// ---- eprint / exit -----------------------------------------------------------------------------

fn eprint_child(ctx: raw.Ptr<()>) uses raw, ffi {
  // stderr goes to a pipe of its own, so the parent can tell the streams apart
  var fds: [i32; 2]
  let pf = raw.cast<i32>(raw.addr_of(&fds))
  ut.check(rt.pipe(pf) == 0, "pipe(fds) == 0")
  let _ = rt.dup2(pf.at(1), 2)
  let _ = rt.close(pf.at(1))
  let x = ut.s("to stderr")
  rt.auk_print_lit("to stdout")
  rt.auk_eprint(x)
  ut.rel(raw.cast(x))
  let _ = rt.fflush(cfacts.stderr())
  var buf: [u8; 64]
  let pb = raw.cast<u8>(raw.addr_of(&buf))
  let n = rt.c_read(pf.at(0), raw.cast(pb), 63)
  pb.at(if n < 0 { 0 } else { n }) = 0
  let _ = rt.printf("err=%s", pb)
}

fn eprint_goes_to_stderr() uses raw, ffi {
  var out: raw.Ptr<u8> = raw.null()
  let code = ut.child(raw.fn_of(eprint_child), raw.null(), raw.addr_of(&out))
  ut.eq(i64(code), 0, "code")
  ut.text_eq(out, "to stdout\nerr=to stderr\n", "out")
}

fn exit_child(ctx: raw.Ptr<()>) uses raw, ffi {
  ut.cprint("unflushed")
  rt.auk_proc_exit(raw.cast<i64>(ctx).load(), "t.auk:1:1")
}

raw var exit_global: raw.Ptr<abi.Str> = raw.null()

fn exit_cleanup() uses raw, ffi {
  ut.rel(raw.cast(exit_global))
  exit_global = raw.null()
}

fn exit_leak_child(ctx: raw.Ptr<()>) uses raw, ffi {
  let leak = raw.cast<bool>(ctx).load()
  let _ = rt.setenv("AUK_LEAK_CHECK", "1", 1)
  // count only this child's objects, not what the forked parent's earlier tests left live
  rt.auk_leak_baseline()
  exit_global = ut.s("global") // released by the cleanup
  rt.auk_set_cleanup(raw.cast<()>(raw.fn_of(exit_cleanup)))
  let leaked: raw.Ptr<abi.Str> = if leak { ut.s("leaked") } else { raw.null() }
  rt.auk_proc_exit(3, "t.auk:1:1")
}

fn proc_exit_flushes_and_checks_leaks() uses raw, ffi {
  var out: raw.Ptr<u8> = raw.null()
  let po = raw.addr_of(&out)
  var c7: i64 = 7
  var c0: i64 = 0
  var c256: i64 = 256
  var cneg: i64 = -1
  var code = ut.child(raw.fn_of(exit_child), raw.cast(raw.addr_of(&c7)), po)
  ut.eq(i64(code), 7, "code")
  ut.text_eq(out, "unflushed", "out")
  code = ut.child(raw.fn_of(exit_child), raw.cast(raw.addr_of(&c0)), po)
  ut.eq(i64(code), 0, "code")
  ut.expect_panic(raw.fn_of(exit_child), raw.cast(raw.addr_of(&c256)), "proc.exit(256): code out of range 0..255\n  at t.auk:1:1")
  ut.expect_panic(raw.fn_of(exit_child), raw.cast(raw.addr_of(&cneg)), "out of range")
  var no = false
  var yes = true
  code = ut.child(raw.fn_of(exit_leak_child), raw.cast(raw.addr_of(&no)), po)
  if code != 3 {
    exit_fail(code, out)
  }
  ut.text_eq(out, "", "out")
  code = ut.child(raw.fn_of(exit_leak_child), raw.cast(raw.addr_of(&yes)), po)
  if code != 102 {
    exit_fail(code, out)
  }
  ut.has(out, "leak: 1 runtime object(s) still live at exit", "out")
}

/// C's `t_fail(…, "exit %d; output:\n%s", code, out)`.
fn exit_fail(code: i32, out: raw.Ptr<u8>): never uses raw, ffi {
  let n = rt.strlen(out) + 64
  let m = ut.scratch(n)
  let _ = rt.snprintf(m, n, "exit %d; output:\n%s", code, out)
  ut.fail(m)
}

// ---- fs extras ---------------------------------------------------------------------------------

/// C's CHECK_OK(r, what): r must be ok.
fn check_ok(r: abi.ResUnit, what: raw.Ptr<u8>) uses raw, ffi {
  if !r.ok {
    let t = ut.err_text(r.err)
    let n = rt.strlen(t) + rt.strlen(what) + 64
    let m = ut.scratch(n)
    let _ = rt.snprintf(m, n, "%s failed: %s", what, t)
    ut.fail(m)
  }
}

fn fs_dirs_list_rename_remove() uses raw, ffi {
  let tmp = ut.tmpdir_new()
  let root = ut.tmpdir_path(tmp, "fsx")
  let deep = ut.tmpdir_path(tmp, "fsx/a/b/c")
  let f1 = ut.tmpdir_path(tmp, "fsx/b.txt")
  let f2 = ut.tmpdir_path(tmp, "fsx/a.txt")
  let f3 = ut.tmpdir_path(tmp, "fsx/z.txt")
  let missing = ut.tmpdir_path(tmp, "fsx/missing")
  ut.check(!rt.auk_fs_exists(root), "!auk_fs_exists(root)")
  check_ok(rt.auk_fs_mkdir(deep), "mkdir -p")
  check_ok(rt.auk_fs_mkdir(deep), "mkdir existing")
  ut.check(rt.auk_fs_is_dir(deep) && rt.auk_fs_exists(deep), "auk_fs_is_dir(deep) && auk_fs_exists(deep)")
  let x = ut.s("x")
  let yn = ut.s("y\n")
  let empty = ut.s("")
  check_ok(rt.auk_fs_append(f1, x), "append new")
  check_ok(rt.auk_fs_append(f1, yn), "append more")
  let rd = rt.auk_fs_read(f1)
  ut.check(rd.ok, "rd.ok")
  ut.str_eq(rd.val, "xy\n", "rd.val")
  ut.check(rt.auk_fs_exists(f1) && !rt.auk_fs_is_dir(f1), "auk_fs_exists(f1) && !auk_fs_is_dir(f1)")
  check_ok(rt.auk_fs_write(f2, empty), "write")

  let bad = rt.auk_fs_mkdir(f1) // a file is in the way
  ut.check(!bad.ok, "!bad.ok")
  ut.has(ut.text(bad.err.msg), "fs.mkdir", "text(bad.err->msg)")
  ut.rel(raw.cast(bad.err))

  let ls = rt.auk_fs_list(root)
  ut.check(ls.ok, "ls.ok")
  ut.str_eq(rt.auk_arr_show(ls.val), "[\"a\", \"a.txt\", \"b.txt\"]", "auk_arr_show(ls.val)")
  ut.rel(raw.cast(ls.val))

  check_ok(rt.auk_fs_rename(f1, f3), "rename")
  ut.check(!rt.auk_fs_exists(f1) && rt.auk_fs_exists(f3), "!auk_fs_exists(f1) && auk_fs_exists(f3)")
  let rn = rt.auk_fs_rename(f1, f3)
  ut.check(!rn.ok, "!rn.ok")
  var m = ut.err_text(rn.err)
  ut.has(m, "fs.rename ", "m")
  ut.has(m, " -> ", "m")

  var rm = rt.auk_fs_remove(root) // not empty
  ut.check(!rm.ok, "!rm.ok")
  ut.rel(raw.cast(rm.err))
  check_ok(rt.auk_fs_remove(f3), "remove file")
  check_ok(rt.auk_fs_remove(deep), "remove empty dir")
  ut.check(!rt.auk_fs_exists(f3) && !rt.auk_fs_exists(deep), "!auk_fs_exists(f3) && !auk_fs_exists(deep)")
  rm = rt.auk_fs_remove(missing)
  ut.check(!rm.ok && rm.err.code == i64(cfacts.ENOENT), "!rm.ok && rm.err->code == ENOENT")
  ut.rel(raw.cast(rm.err))

  let none_ = rt.auk_fs_list(missing)
  ut.check(!none_.ok, "!none.ok")
  m = ut.err_text(none_.err)
  ut.has(m, "fs.list ", "m")
  ut.has(m, "missing", "m")

  let nested = ut.tmpdir_path(tmp, "fsx/no/such/f")
  let ap = rt.auk_fs_append(nested, x)
  ut.check(!ap.ok, "!ap.ok")
  ut.rel(raw.cast(ap.err))
  ut.rel(raw.cast(nested))
  ut.rel(raw.cast(x))
  ut.rel(raw.cast(yn))
  ut.rel(raw.cast(empty))
  ut.rel(raw.cast(root))
  ut.rel(raw.cast(deep))
  ut.rel(raw.cast(f1))
  ut.rel(raw.cast(f2))
  ut.rel(raw.cast(f3))
  ut.rel(raw.cast(missing))
}

fn fs_temp_dir_is_fresh() uses raw, ffi {
  let a = rt.auk_fs_temp_dir()
  let b = rt.auk_fs_temp_dir()
  ut.check(a.ok && b.ok, "a.ok && b.ok")
  ut.check(!rt.auk_str_eq(a.val, b.val), "!auk_str_eq(a.val, b.val)")
  ut.check(rt.auk_fs_is_dir(a.val) && rt.auk_fs_is_dir(b.val), "auk_fs_is_dir(a.val) && auk_fs_is_dir(b.val)")
  var st: cfacts.Stat
  ut.check(rt.stat(ut.text(a.val), raw.addr_of(&st)) == 0, "stat(text(a.val), &st) == 0")
  ut.eq(i64(st.st_mode) & 511, 448, "st.st_mode & 0777") // 0700
  let ls = rt.auk_fs_list(a.val)
  ut.check(ls.ok && rt.auk_arr_len(ls.val) == 0, "ls.ok && auk_arr_len(ls.val) == 0")
  ut.rel(raw.cast(ls.val))
  check_ok(rt.auk_fs_remove(a.val), "remove a")
  check_ok(rt.auk_fs_remove(b.val), "remove b")
  ut.rel(raw.cast(a.val))
  ut.rel(raw.cast(b.val))
}

fn fs_bytes_round_trip() uses raw, ffi {
  let tmp = ut.tmpdir_new()
  let p = ut.tmpdir_path(tmp, "bytes.bin")
  var a = rt.auk_arr_new(rt.OPS_INT, 256)
  var i: i64 = 0
  while i < 256 {
    ut.push_int(raw.addr_of(&a), (i * 7 + 3) % 256)
    i += 1
  }
  check_ok(rt.auk_fs_write_bytes(p, a), "write_bytes")
  var r = rt.auk_fs_read_bytes(p)
  ut.check(r.ok, "r.ok")
  ut.check(rt.auk_arr_eq(r.val, a), "auk_arr_eq(r.val, a)")
  ut.rel(raw.cast(r.val))

  // out of range: an Err, and the file is left alone
  ut.push_int(raw.addr_of(&a), 256)
  var w = rt.auk_fs_write_bytes(p, a)
  ut.check(!w.ok, "!w.ok")
  ut.has(ut.err_text(w.err), "byte 256 at index 256 is out of range 0..255", "err_text(w.err)")
  r = rt.auk_fs_read_bytes(p)
  ut.check(r.ok && rt.auk_arr_len(r.val) == 256, "r.ok && auk_arr_len(r.val) == 256")
  ut.rel(raw.cast(r.val))
  var b = rt.auk_arr_new(rt.OPS_INT, 1)
  ut.push_int(raw.addr_of(&b), -1)
  w = rt.auk_fs_write_bytes(p, b)
  ut.check(!w.ok, "!w.ok")
  ut.rel(raw.cast(w.err))
  ut.rel(raw.cast(b))

  let empty = rt.auk_arr_new(rt.OPS_INT, 0)
  check_ok(rt.auk_fs_write_bytes(p, empty), "write empty")
  r = rt.auk_fs_read_bytes(p)
  ut.check(r.ok && rt.auk_arr_len(r.val) == 0, "r.ok && auk_arr_len(r.val) == 0")
  ut.rel(raw.cast(r.val))
  ut.rel(raw.cast(empty))

  let missing = ut.tmpdir_path(tmp, "nope.bin")
  r = rt.auk_fs_read_bytes(missing)
  ut.check(!r.ok && r.err.code == i64(cfacts.ENOENT), "!r.ok && r.err->code == ENOENT")
  ut.rel(raw.cast(r.err))
  ut.rel(raw.cast(missing))
  ut.rel(raw.cast(a))
  ut.rel(raw.cast(p))
}

// ---- secure random -----------------------------------------------------------------------------

fn p_rand_bytes(c: raw.Ptr<()>) uses ffi {
  let _ = rt.auk_rand_bytes(-1, "r.auk:2:3")
}

fn rand_bytes_and_seed() uses raw, ffi {
  var a = rt.auk_rand_bytes(32, "t")
  var b = rt.auk_rand_bytes(32, "t")
  ut.eq(rt.auk_arr_len(a), 32, "auk_arr_len(a)")
  var i: i64 = 0
  while i < 32 {
    let y = ut.int_elems(a).at(i)
    ut.check(y >= 0 && y <= 255, "int_elems(a)[i] >= 0 && int_elems(a)[i] <= 255")
    i += 1
  }
  ut.check(!rt.auk_arr_eq(a, b), "!auk_arr_eq(a, b)") // 2^-256
  ut.rel(raw.cast(a))
  ut.rel(raw.cast(b))
  let z = rt.auk_rand_bytes(0, "t")
  ut.eq(rt.auk_arr_len(z), 0, "auk_arr_len(z)")
  ut.rel(raw.cast(z))
  let big = rt.auk_rand_bytes(4096, "t") // more than getentropy's 256-byte limit
  var seen: [bool; 256]
  let ps = raw.cast<bool>(raw.addr_of(&seen))
  raw.fill(raw.cast<u8>(ps), 0, 256)
  var distinct = 0
  i = 0
  while i < 4096 {
    let y = ut.int_elems(big).at(i)
    if !ps.at(y) {
      ps.at(y) = true
      distinct += 1
    }
    i += 1
  }
  ut.check(distinct > 200, "distinct > 200")
  ut.rel(raw.cast(big))
  ut.expect_panic(raw.fn_of(p_rand_bytes), raw.null(), "rand.bytes(-1): negative count\n  at r.auk:2:3")

  // a seed makes rand.int/rand.float repeatable
  rt.auk_rand_seed(42)
  var s1: [i64; 8]
  let p1 = raw.cast<i64>(raw.addr_of(&s1))
  i = 0
  while i < 8 {
    p1.at(i) = rt.auk_rand_int(0, 1000000)
    i += 1
  }
  let f1 = rt.auk_rand_float()
  rt.auk_rand_seed(42)
  i = 0
  while i < 8 {
    ut.eq(rt.auk_rand_int(0, 1000000), p1.at(i), "auk_rand_int(0, 1000000)")
    i += 1
  }
  ut.check(rt.auk_rand_float() == f1, "auk_rand_float() == f1")
  rt.auk_rand_seed(43)
  var differ = false
  i = 0
  while i < 8 {
    differ = differ || rt.auk_rand_int(0, 1000000) != p1.at(i)
    i += 1
  }
  ut.check(differ, "differ")
  // ... but never the CSPRNG
  rt.auk_rand_seed(42)
  a = rt.auk_rand_bytes(16, "t")
  rt.auk_rand_seed(42)
  b = rt.auk_rand_bytes(16, "t")
  ut.check(!rt.auk_arr_eq(a, b), "!auk_arr_eq(a, b)")
  ut.rel(raw.cast(a))
  ut.rel(raw.cast(b))
}

/// The tests, in the C file's order.
pub fn all() uses raw, ffi {
  ut.run("stdin_read_line_lines_and_all", raw.fn_of(stdin_read_line_lines_and_all))
  ut.run("eprint_goes_to_stderr", raw.fn_of(eprint_goes_to_stderr))
  ut.run("proc_exit_flushes_and_checks_leaks", raw.fn_of(proc_exit_flushes_and_checks_leaks))
  ut.run("fs_dirs_list_rename_remove", raw.fn_of(fs_dirs_list_rename_remove))
  ut.run("fs_temp_dir_is_fresh", raw.fn_of(fs_temp_dir_is_fresh))
  ut.run("fs_bytes_round_trip", raw.fn_of(fs_bytes_round_trip))
  ut.run("rand_bytes_and_seed", raw.fn_of(rand_bytes_and_seed))
}

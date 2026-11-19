/// The harness of the runtime's unit tests (the port of runtime/c/test/test.h and test_main.c).
///
/// Every test is a `fn name() uses raw, ffi` that ut_main.auk passes to `run`. Each one runs in a
/// forked child process with its stdout and stderr in a pipe: a crash, a panic or a failed
/// check ends only that child, and the runner prints what it wrote, then `ok <name>` or
/// `FAIL <name>`, and at the end `<n> passed, <m> failed`. In the child, after the test,
/// auk_live_objects() must be back where it was (the leak check), and when the program was
/// built with AddressSanitizer, LeakSanitizer's check must find nothing. A failed check prints
/// what failed and ends the process with exit code 98 (the test's, or a `child`'s).

// ---- failing ---------------------------------------------------------------------------------

/// The test running in this process (a C string of ut_main.auk).
raw var current: raw.Ptr<u8> = raw.null()

/// Report a failed check (`    <test>: <msg>`) and end this process with 98.
pub fn fail(msg: raw.Ptr<u8>): never uses raw, ffi {
  let _ = rt.fflush(raw.null())
  let _ = rt.fprintf(cfacts.stderr(), "    %s: %s\n", current, msg)
  let _ = rt.fflush(raw.null())
  rt.c_exit(98)
}

/// `CHECK(c)`: what is the condition's text.
pub fn check(c: bool, what: raw.Ptr<u8>) uses raw, ffi {
  if !c {
    let m = scratch(1024)
    let _ = rt.snprintf(m, 1024, "check failed: %s", what)
    fail(m)
  }
}

/// `CHECK_INT(got, want)`: two int64 values must be equal.
pub fn eq(got: i64, want: i64, what: raw.Ptr<u8>) uses raw, ffi {
  if got != want {
    let m = scratch(1024)
    let _ = rt.snprintf(m, 1024, "%s: got %lld, want %lld", what, got, want)
    fail(m)
  }
}

/// `CHECK_TEXT(got, want)`: two C strings must be equal.
pub fn text_eq(got: raw.Ptr<u8>, want: raw.Ptr<u8>, what: raw.Ptr<u8>) uses raw, ffi {
  if rt.strcmp(got, want) != 0 {
    let n = rt.strlen(got) + rt.strlen(want) + 1024
    let m = scratch(n)
    let _ = rt.snprintf(m, n, "%s: got \"%s\", want \"%s\"", what, got, want)
    fail(m)
  }
}

/// `CHECK_HAS(got, needle)`: got must contain needle.
pub fn has(got: raw.Ptr<u8>, needle: raw.Ptr<u8>, what: raw.Ptr<u8>) uses raw, ffi {
  if rt.strstr(got, needle).is_null() {
    let n = rt.strlen(got) + rt.strlen(needle) + 1024
    let m = scratch(n)
    let _ = rt.snprintf(m, n, "%s: \"%s\" lacks \"%s\"", what, got, needle)
    fail(m)
  }
}

/// `CHECK_STR(owned, want)`: an OWNED str must be want (bytes and byte length); releases it.
pub fn str_eq(owned: raw.Ptr<abi.Str>, want: raw.Ptr<u8>, what: raw.Ptr<u8>) uses raw, ffi {
  let blen = rt.auk_str_byte_len(owned)
  let got = copy_bytes(rt.auk_str_cstr(owned), usize(blen))
  rel(raw.cast(owned))
  if usize(blen) != rt.strlen(want) || raw.compare(got, want, usize(blen)) != 0 {
    let n = usize(blen) + rt.strlen(want) + 1024
    let m = scratch(n)
    let _ = rt.snprintf(m, n, "%s: got \"%s\", want \"%s\"", what, got, want)
    fail(m)
  }
}

// ---- scratch memory --------------------------------------------------------------------------

raw var kept: raw.Ptr<raw.Ptr<()>> = raw.null()
raw var nkept: i64 = 0
raw var capkept: i64 = 0

/// Keep a malloc'd pointer until the current test ends (then it is freed). Returns p.
pub fn keep(p: raw.Ptr<()>): raw.Ptr<()> uses raw {
  if nkept == capkept {
    capkept = if capkept == 0 { 16 } else { capkept * 2 }
    kept = raw.cast(raw.realloc(raw.cast<()>(kept), usize(capkept) * raw.size_of<raw.Ptr<()>>()))
  }
  kept.at(nkept) = p
  nkept += 1
  p
}

/// n kept, zeroed bytes.
pub fn scratch(n: usize): raw.Ptr<u8> uses raw {
  let p: raw.Ptr<u8> = raw.cast(raw.alloc(n))
  raw.fill(p, 0, n)
  raw.cast(keep(raw.cast(p)))
}

/// A kept copy of n bytes (NUL-terminated).
pub fn copy_bytes(p: raw.Ptr<u8>, n: usize): raw.Ptr<u8> uses raw {
  let c = scratch(n + 1)
  if n > 0 {
    raw.copy(c, p, n)
  }
  c
}

fn free_kept() uses raw {
  var i: i64 = 0
  while i < nkept {
    raw.free(kept.at(i))
    i += 1
  }
  raw.free(raw.cast<()>(kept))
  kept = raw.null()
  nkept = 0
  capkept = 0
}

/// Bytes C would write as a literal with `\x` escapes (`"a\xFF" "b"`): `bin("a\\xFFb")` (two
/// hex digits after each `\x`; everything else as it is). Kept, NUL-terminated.
pub raw struct Bytes {
  p: raw.Ptr<u8>,
  n: i64,
}

fn hex_digit(c: u8): u8 = if c >= 48 && c <= 57 { c - 48 } else if c >= 97 { c - 87 } else { c - 55 }

pub fn bin(spec: raw.Ptr<u8>): Bytes uses raw, ffi {
  let len = rt.strlen(spec)
  let b = scratch(len + 1)
  var i: usize = 0
  var n: i64 = 0
  while i < len {
    if spec.at(i) == 92 && i + 3 < len + 1 && spec.at(i + 1) == 120 { // "\x"
      b.at(n) = hex_digit(spec.at(i + 2)) * 16 + hex_digit(spec.at(i + 3))
      i += 4
    } else {
      b.at(n) = spec.at(i)
      i += 1
    }
    n += 1
  }
  Bytes { p: b, n: n }
}

// ---- runtime helpers ---------------------------------------------------------------------------

/// An owned str from text (auk_str_lit).
pub fn s(t: raw.Ptr<u8>): raw.Ptr<abi.Str> uses ffi = rt.auk_str_lit(t)

/// Release / retain any runtime object (retain returns it).
pub fn rel(p: raw.Ptr<()>) uses ffi = rt.auk_release(p)
pub fn ret(p: raw.Ptr<()>): raw.Ptr<()> uses ffi = rt.auk_retain(p)

/// The text of a (borrowed) str (null is "").
pub fn text(p: raw.Ptr<abi.Str>): raw.Ptr<u8> uses ffi = rt.auk_str_cstr(p)

/// A new error with the message msg (owned).
pub fn err_msg(msg: raw.Ptr<u8>): raw.Ptr<abi.Err> uses ffi = rt.auk__err_bytes(msg, rt.strlen(msg))

/// The shown text of an owned error (kept), releasing the error.
pub fn err_text(e: raw.Ptr<abi.Err>): raw.Ptr<u8> uses raw, ffi {
  let m = rt.auk_err_show(e)
  let t = copy_bytes(rt.auk_str_cstr(m), usize(rt.auk_str_byte_len(m)))
  rel(raw.cast(m))
  rel(raw.cast(e))
  t
}

/// An int array of the n values at xs.
pub fn ints(xs: raw.Ptr<i64>, n: i64): raw.Ptr<abi.Arr> uses raw, ffi {
  var a = rt.auk_arr_new(rt.OPS_INT, 0)
  var i: i64 = 0
  while i < n {
    rt.auk_arr_push(raw.addr_of(&a), raw.cast(xs.offset(i)))
    i += 1
  }
  a
}

/// An int array of up to four values (C's `ints((int64_t[]){…}, n)`).
pub fn ints4(n: i64, a: i64, b: i64, c: i64, d: i64): raw.Ptr<abi.Arr> uses raw, ffi {
  var xs: [i64; 4]
  let p = raw.cast<i64>(raw.addr_of(&xs))
  p.at(0) = a
  p.at(1) = b
  p.at(2) = c
  p.at(3) = d
  ints(p, n)
}

/// The elements of an int array (null when empty).
pub fn int_elems(a: raw.Ptr<abi.Arr>): raw.Ptr<i64> uses raw, ffi =
  if rt.auk_arr_len(a) == 0 { raw.null() } else { raw.cast(rt.auk_arr_data(a)) }

/// Element i of an array, as a T (C's `AT(T, a, i)`: auk_arr_at with location "t").
pub fn at_int(a: raw.Ptr<abi.Arr>, i: i64): i64 uses raw, ffi = raw.cast<i64>(rt.auk_arr_at(a, i, "t")).load()
pub fn at_ptr(a: raw.Ptr<abi.Arr>, i: i64): raw.Ptr<()> uses raw, ffi = raw.cast<raw.Ptr<()>>(rt.auk_arr_at(a, i, "t")).load()
pub fn at_u32(a: raw.Ptr<abi.Arr>, i: i64): u32 uses raw, ffi = raw.cast<u32>(rt.auk_arr_at(a, i, "t")).load()

/// Push an int (C's `PUSH(int64_t, pa, v)`).
pub fn push_int(pa: raw.Ptr<raw.Ptr<abi.Arr>>, v: i64) uses raw, ffi {
  var x = v
  rt.auk_arr_push(pa, raw.cast(raw.addr_of(&x)))
}

/// Write text to the C library's stdout (what the runtime's own output goes through).
pub fn cprint(t: raw.Ptr<u8>) uses raw, ffi {
  let _ = rt.fputs(t, cfacts.stdout())
}

/// Append text to a string builder.
pub fn sb_push(b: raw.Ptr<abi.StrBuf>, t: raw.Ptr<u8>) uses ffi = rt.auk_sb_bytes(b, t, i64(rt.strlen(t)))

// ---- child processes ---------------------------------------------------------------------------

raw struct Fds {
  r: i32,
  w: i32,
}

/// Read all of fd into a kept, NUL-terminated buffer.
fn read_all(fd: i32): raw.Ptr<u8> uses raw, ffi {
  var cap: usize = 8192
  var n: usize = 0
  var buf: raw.Ptr<u8> = raw.cast(raw.alloc(cap))
  while true {
    if cap - n < 4096 {
      cap *= 2
      buf = raw.cast(raw.realloc(raw.cast<()>(buf), cap))
    }
    let r = rt.c_read(fd, raw.cast(buf.offset(n)), cap - n - 1)
    if r < 0 && cfacts.errno() == cfacts.EINTR {
      continue
    }
    if r <= 0 {
      break
    }
    n += usize(r)
  }
  buf.at(n) = 0
  raw.cast(keep(raw.cast(buf)))
}

/// Does output carry a sanitizer's report?
fn sanitizer_report(out: raw.Ptr<u8>): bool uses raw, ffi =
  !rt.strstr(out, "WARNING: ThreadSanitizer").is_null() || !rt.strstr(out, "ERROR: AddressSanitizer").is_null() ||
    !rt.strstr(out, "ERROR: LeakSanitizer").is_null() || !rt.strstr(out, "runtime error:").is_null()

/// The exit code of a waitpid status (128 + the signal when killed).
fn code_of(status: i32): i32 =
  if cfacts.wifexited(status) { cfacts.wexitstatus(status) } else { 128 + cfacts.wtermsig(status) }

/// Fork; the child runs f(ctx) with stdout and stderr both going into one pipe, then
/// _exit(0)s (a failed check in it exits 98). Returns the child's exit code (or 128+signal)
/// and sets *out to its output (kept). A sanitizer's report in the output fails the caller.
pub fn child(f: raw.Fn<(raw.Ptr<()>) => ()>, ctx: raw.Ptr<()>, out: raw.Ptr<raw.Ptr<u8>>): i32 uses raw, ffi {
  var fds = Fds {}
  let _ = rt.fflush(raw.null())
  if rt.pipe(raw.cast(raw.addr_of(&fds))) != 0 {
    fail("pipe failed")
  }
  let pid = rt.fork()
  if pid < 0 {
    fail("fork failed")
  }
  if pid == 0 {
    let _ = rt.close(fds.r)
    let _ = rt.dup2(fds.w, 1)
    let _ = rt.dup2(fds.w, 2)
    let _ = rt.close(fds.w)
    f(ctx)
    let _ = rt.fflush(raw.null())
    rt.c_exit(0)
  }
  let _ = rt.close(fds.w)
  let buf = read_all(fds.r)
  let _ = rt.close(fds.r)
  out.store(buf)
  var status: i32 = 0
  while rt.waitpid(pid, raw.addr_of(&status), 0) < 0 && cfacts.errno() == cfacts.EINTR {
  }
  // a sanitizer report in a child (which _exits, so it can't change its exit code) fails the
  // test that made it
  if sanitizer_report(buf) {
    let n = rt.strlen(buf) + 64
    let m = scratch(n)
    let _ = rt.snprintf(m, n, "sanitizer report in a child process:\n%s", buf)
    fail(m)
  }
  code_of(status)
}

/// f(ctx) must panic (exit 101, `panic: ` in the output) with output containing needle.
pub fn expect_panic(f: raw.Fn<(raw.Ptr<()>) => ()>, ctx: raw.Ptr<()>, needle: raw.Ptr<u8>) uses raw, ffi {
  var out: raw.Ptr<u8> = raw.null()
  let code = child(f, ctx, raw.addr_of(&out))
  let n = rt.strlen(out) + rt.strlen(needle) + 128
  let m = scratch(n)
  if code != 101 {
    let _ = rt.snprintf(m, n, "expected exit 101 (panic), got %d; output:\n%s", code, out)
    fail(m)
  }
  if rt.strstr(out, "panic: ").is_null() {
    let _ = rt.snprintf(m, n, "no 'panic:' in output:\n%s", out)
    fail(m)
  }
  if rt.strstr(out, needle).is_null() {
    let _ = rt.snprintf(m, n, "panic output lacks \"%s\":\n%s", needle, out)
    fail(m)
  }
}

// ---- scratch directories -------------------------------------------------------------------------

raw struct Dirs {
  d: [raw.Ptr<u8>; 8],
}

raw var dirs: Dirs = Dirs {}
raw var ndirs: i64 = 0

/// A fresh scratch directory (a kept path), removed with everything in it when the test ends.
pub fn tmpdir_new(): raw.Ptr<u8> uses raw, ffi {
  var base = rt.getenv("TMPDIR")
  if base.is_null() || base.at(0) == 0 {
    base = "/tmp"
  }
  var bl = rt.strlen(base)
  while bl > 1 && base.at(bl - 1) == 47 { // '/'
    bl -= 1
  }
  let tmpl = scratch(bl + 32)
  let _ = rt.snprintf(tmpl, bl + 32, "%.*s/aukrt-XXXXXX", i32(bl), base)
  if ndirs == 8 {
    fail("too many scratch directories")
  }
  if rt.mkdtemp(tmpl).is_null() {
    fail("mkdtemp failed")
  }
  raw.cast<raw.Ptr<u8>>(raw.addr_of(&dirs)).at(ndirs) = tmpl
  ndirs += 1
  tmpl
}

/// Remove path and, if it is a directory, everything in it (no symbolic links followed).
fn remove_tree(path: raw.Ptr<u8>) uses raw, ffi {
  var st: cfacts.Stat
  if rt.lstat(path, raw.addr_of(&st)) != 0 {
    return
  }
  if !cfacts.s_isdir(u32(st.st_mode)) {
    let _ = rt.unlink(path)
    return
  }
  let d = rt.opendir(path)
  if !d.is_null() {
    while true {
      let ent = rt.readdir(d)
      if ent.is_null() {
        break
      }
      let name: raw.Ptr<u8> = raw.cast(raw.field_addr(ent, .d_name))
      if rt.strcmp(name, ".") == 0 || rt.strcmp(name, "..") == 0 {
        continue
      }
      let n = rt.strlen(path) + rt.strlen(name) + 2
      let sub: raw.Ptr<u8> = raw.cast(raw.alloc(n))
      let _ = rt.snprintf(sub, n, "%s/%s", path, name)
      remove_tree(sub)
      raw.free(raw.cast<()>(sub))
    }
    let _ = rt.closedir(d)
  }
  let _ = rt.rmdir(path)
}

/// Remove the scratch directories of the test that just ended.
fn remove_dirs() uses raw, ffi {
  var i: i64 = 0
  while i < ndirs {
    remove_tree(raw.cast<raw.Ptr<u8>>(raw.addr_of(&dirs)).at(i))
    i += 1
  }
  ndirs = 0
}

/// An owned str naming name inside dir.
pub fn tmpdir_path(dir: raw.Ptr<u8>, name: raw.Ptr<u8>): raw.Ptr<abi.Str> uses raw, ffi {
  let n = rt.strlen(dir) + rt.strlen(name) + 2
  let p = scratch(n)
  let _ = rt.snprintf(p, n, "%s/%s", dir, name)
  s(p)
}

// ---- network -----------------------------------------------------------------------------------

fn probe(ai: raw.Ptr<cfacts.Addrinfo>): bool uses raw, ffi {
  let fd = rt.socket(ai.ai_family, ai.ai_socktype, ai.ai_protocol)
  if fd < 0 {
    return false
  }
  let _ = rt.fcntl(fd, cfacts.F_SETFL, rt.fcntl(fd, cfacts.F_GETFL) | cfacts.O_NONBLOCK)
  var ok = false
  if rt.connect(fd, raw.cast(ai.ai_addr), u32(ai.ai_addrlen)) == 0 {
    ok = true
  } else if cfacts.errno() == cfacts.EINPROGRESS {
    var p = cfacts.Pollfd { fd: fd, events: cfacts.POLLOUT }
    if rt.poll(raw.addr_of(&p), 1, 3000) == 1 {
      var e: i32 = 0
      var len: u32 = 4
      ok = rt.getsockopt(fd, cfacts.SOL_SOCKET, cfacts.SO_ERROR, raw.cast(raw.addr_of(&e)), raw.addr_of(&len)) == 0 && e == 0
    }
  }
  let _ = rt.close(fd)
  ok
}

/// Should tests reach real hosts? AUK_NET_TESTS=1/0 decides; unset, probe example.com:443 with a
/// 3s connect timeout.
pub fn net_tests(): bool uses raw, ffi {
  let v = rt.getenv("AUK_NET_TESTS")
  if !v.is_null() {
    return rt.strcmp(v, "1") == 0
  }
  var hints = cfacts.Addrinfo { ai_socktype: cfacts.SOCK_STREAM }
  var res: raw.Ptr<cfacts.Addrinfo> = raw.null()
  if rt.getaddrinfo("example.com", "443", raw.addr_of(&hints), raw.addr_of(&res)) != 0 {
    return false
  }
  var ok = false
  var ai = res
  while !ai.is_null() && !ok {
    ok = probe(ai)
    ai = ai.ai_next
  }
  rt.freeaddrinfo(res)
  ok
}

// ---- the runner ----------------------------------------------------------------------------------

raw var filter: raw.Ptr<u8> = raw.null()
raw var passed: i64 = 0
raw var failed: i64 = 0

/// Only the tests whose name contains f run (null: all).
pub fn set_filter(f: raw.Ptr<u8>) uses raw {
  filter = f
}

/// LeakSanitizer's check of this process, when the program has one (an AddressSanitizer
/// build): true if it found leaks (and reported them).
fn lsan_leaks(): bool uses raw, ffi {
  let f = rt.dlsym(raw.from_int(cfacts.RTLD_DEFAULT), "__lsan_do_recoverable_leak_check")
  if f.is_null() {
    return false
  }
  let check: raw.Fn<() => i32> = raw.cast(f)
  check() != 0
}

/// The child's side of `run`: the test, then the leak checks.
fn run_child(name: raw.Ptr<u8>, f: raw.Fn<() => ()>): never uses raw, ffi {
  current = name
  let live0 = rt.auk_live_objects()
  f()
  let live1 = rt.auk_live_objects()
  remove_dirs()
  free_kept()
  let _ = rt.fflush(raw.null())
  if live1 != live0 {
    let _ = rt.fprintf(cfacts.stderr(), "    leak check: %lld live objects before, %lld after\n", live0, live1)
    let _ = rt.fflush(raw.null())
    rt.c_exit(1)
  }
  if lsan_leaks() {
    let _ = rt.fflush(raw.null())
    rt.c_exit(1)
  }
  rt.c_exit(0)
}

/// Run one test in a child process; print its output (on stderr), then `ok <name>` or
/// `FAIL <name>`.
pub fn run(name: raw.Ptr<u8>, f: raw.Fn<() => ()>) uses raw, ffi {
  if !filter.is_null() && rt.strstr(name, filter).is_null() {
    return
  }
  var fds = Fds {}
  let _ = rt.fflush(raw.null())
  if rt.pipe(raw.cast(raw.addr_of(&fds))) != 0 {
    fail("pipe failed")
  }
  let pid = rt.fork()
  if pid < 0 {
    fail("fork failed")
  }
  if pid == 0 {
    let _ = rt.close(fds.r)
    let _ = rt.dup2(fds.w, 1)
    let _ = rt.dup2(fds.w, 2)
    let _ = rt.close(fds.w)
    run_child(name, f)
  }
  let _ = rt.close(fds.w)
  let out = read_all(fds.r)
  let _ = rt.close(fds.r)
  var status: i32 = 0
  while rt.waitpid(pid, raw.addr_of(&status), 0) < 0 && cfacts.errno() == cfacts.EINTR {
  }
  let errf = cfacts.stderr()
  let _ = rt.fputs(out, errf)
  var ok = cfacts.wifexited(status) && cfacts.wexitstatus(status) == 0
  if ok && sanitizer_report(out) {
    let _ = rt.fputs("    a sanitizer reported (above)\n", errf)
    ok = false
  }
  if cfacts.wifsignaled(status) {
    let _ = rt.fprintf(errf, "    (killed by signal %d)\n", cfacts.wtermsig(status))
  } else if !ok && cfacts.wexitstatus(status) != 98 && cfacts.wexitstatus(status) != 1 {
    let _ = rt.fprintf(errf, "    (exit %d)\n", cfacts.wexitstatus(status))
  }
  let _ = rt.fflush(errf)
  free_kept()
  let word: raw.Ptr<u8> = if ok { "ok" } else { "FAIL" }
  let _ = rt.printf("%s %s\n", word, name)
  let _ = rt.fflush(raw.null())
  if ok {
    passed += 1
  } else {
    failed += 1
  }
}

/// Print the summary; the program's exit code.
pub fn summary(): i32 uses raw, ffi {
  let _ = rt.printf("%lld passed, %lld failed\n", passed, failed)
  let _ = rt.fflush(raw.null())
  if failed == 0 { 0 } else { 1 }
}

/// Contracts, holes, assert, peek, the test registry and runner, and the program entry (was
/// runtime/c/testing.c, ported line by line).

// the rest of the runtime (C, or another module's `export fn`, which such an `extern fn` resolves to)
extern fn auk__panic_sb(loc: raw.Ptr<u8>, b: raw.Ptr<abi.StrBuf>): never = "void auk__panic_sb(const char *, void *)"
extern fn auk_leak_check(): i64 = "int64_t auk_leak_check(void)"
extern fn auk__sb_put_cstr(b: raw.Ptr<abi.StrBuf>, s: raw.Ptr<u8>) = "void auk__sb_put_cstr(void *, const char *)"
extern fn auk_sb_str(b: raw.Ptr<abi.StrBuf>, s: raw.Ptr<abi.Str>) = "void auk_sb_str(void *, const void *)"
extern fn auk_sb_int(b: raw.Ptr<abi.StrBuf>, v: i64) = "void auk_sb_int(void *, int64_t)"
extern fn auk__sb_take_into(b: raw.Ptr<abi.StrBuf>, out: raw.Ptr<u8>, cap: usize) = "void auk__sb_take_into(void *, char *, size_t)"
extern fn auk__sb_cstr(b: raw.Ptr<abi.StrBuf>): raw.Ptr<u8> = "const char *auk__sb_cstr(void *)"
extern fn auk_sb_free(b: raw.Ptr<abi.StrBuf>) = "void auk_sb_free(void *)"
extern fn auk_str_cstr(s: raw.Ptr<abi.Str>): raw.Ptr<u8> = "const char *auk_str_cstr(const void *)"
extern fn auk_str_byte_len(s: raw.Ptr<abi.Str>): i64 = "int64_t auk_str_byte_len(const void *)"
extern fn auk__fmt_i64(out: raw.Ptr<u8>, v: i64): i32 = "int auk__fmt_i64(char *, int64_t)"
extern fn auk_env_set_args(argc: i32, argv: raw.Ptr<raw.Ptr<u8>>) = "void auk_env_set_args(int, char **)"
extern fn auk_env_args(): raw.Ptr<abi.Arr> = "void *auk_env_args(void)"
// libc
extern fn strlen(s: raw.Ptr<u8>): usize = "size_t strlen(const char *)"
extern fn strstr(s: raw.Ptr<u8>, sub: raw.Ptr<u8>): raw.Ptr<u8> = "char *strstr(const char *, const char *)"
extern fn strerror(err: i32): raw.Ptr<u8> = "char *strerror(int)"
extern fn memchr(p: raw.Ptr<()>, c: i32, n: usize): raw.Ptr<()> = "void *memchr(const void *, int, size_t)"
extern fn getenv(name: raw.Ptr<u8>): raw.Ptr<u8> = "char *getenv(const char *)"
extern fn fopen(path: raw.Ptr<u8>, mode: raw.Ptr<u8>): raw.Ptr<()> = "FILE *fopen(const char *, const char *)"
extern fn fclose(f: raw.Ptr<()>): i32 = "int fclose(FILE *)"
extern fn fileno(f: raw.Ptr<()>): i32 = "int fileno(FILE *)"
extern fn fflush(f: raw.Ptr<()>): i32 = "int fflush(FILE *)"
extern fn fputc(c: i32, f: raw.Ptr<()>): i32 = "int fputc(int, FILE *)"
extern fn fputs(s: raw.Ptr<u8>, f: raw.Ptr<()>): i32 = "int fputs(const char *, FILE *)"
extern fn fwrite(p: raw.Ptr<()>, size: usize, n: usize, f: raw.Ptr<()>): usize = "size_t fwrite(const void *, size_t, size_t, FILE *)"
extern fn flockfile(f: raw.Ptr<()>) = "void flockfile(FILE *)"
extern fn funlockfile(f: raw.Ptr<()>) = "void funlockfile(FILE *)"
extern fn c_read(fd: i32, p: raw.Ptr<()>, n: usize): i64 = "ssize_t read(int, void *, size_t)"
extern fn close(fd: i32): i32 = "int close(int)"
extern fn dup2(fd: i32, to: i32): i32 = "int dup2(int, int)"
extern fn pipe(fds: raw.Ptr<i32>): i32 = "int pipe(int *)"
extern fn fork(): i32 = "int fork(void)" // pid_t: i32
extern fn getpid(): i32 = "int getpid(void)"
extern fn waitpid(pid: i32, status: raw.Ptr<i32>, options: i32): i32 = "int waitpid(int, int *, int)"
extern fn unlink(path: raw.Ptr<u8>): i32 = "int unlink(const char *)"
extern fn c_exit(code: i32): never = "void _exit(int)"
extern fn pthread_mutex_lock(m: raw.Ptr<cfacts.PthreadMutex>): i32 = "int pthread_mutex_lock(pthread_mutex_t *)"
extern fn pthread_mutex_unlock(m: raw.Ptr<cfacts.PthreadMutex>): i32 = "int pthread_mutex_unlock(pthread_mutex_t *)"

export fn auk_requires_fail(loc: raw.Ptr<u8>, cond_text: raw.Ptr<u8>): never uses raw, ffi =
  rc.auk__panic3(loc, "requires failed: ", cond_text, raw.null())

export fn auk_ensures_fail(loc: raw.Ptr<u8>, cond_text: raw.Ptr<u8>): never uses raw, ffi =
  rc.auk__panic3(loc, "ensures failed: ", cond_text, raw.null())

export fn auk_hole(loc: raw.Ptr<u8>, expected: raw.Ptr<u8>): never uses raw, ffi =
  rc.auk__panic3(loc, "unfilled hole (expected ", expected, ")")

export fn auk_assert_fail(loc: raw.Ptr<u8>, cond_text: raw.Ptr<u8>): never uses raw, ffi =
  rc.auk__panic3(loc, "assertion failed: ", cond_text, raw.null())

export fn auk_assert_fail_cmp(loc: raw.Ptr<u8>, cond_text: raw.Ptr<u8>, left: raw.Ptr<abi.Str>, right: raw.Ptr<abi.Str>): never uses raw, ffi {
  var m = abi.StrBuf {}
  let mp = raw.addr_of(&m)
  auk__sb_put_cstr(mp, "assertion failed: ")
  auk__sb_put_cstr(mp, cond_text)
  auk__sb_put_cstr(mp, "\n  left: ")
  auk_sb_str(mp, left)
  auk__sb_put_cstr(mp, "\n  right: ")
  auk_sb_str(mp, right)
  auk__panic_sb(loc, mp)
}

export fn auk_peek(loc: raw.Ptr<u8>, src_text: raw.Ptr<u8>, shown: raw.Ptr<abi.Str>) uses raw, ffi {
  let errf = cfacts.stderr()
  fflush(cfacts.stdout())
  flockfile(errf)
  fputc(91, errf) // '['
  fputs(loc, errf)
  fputs("] ", errf)
  fputs(src_text, errf)
  fputs(" = ", errf)
  fwrite(raw.cast(auk_str_cstr(shown)), 1, usize(auk_str_byte_len(shown)), errf)
  fputc(10, errf) // '\n'
  funlockfile(errf)
  if raw.atomic_load(raw.addr_of(&trace.auk_trace_live), raw.Order.Relaxed) {
    trace.auk__trace_peek(loc, src_text, shown)
  }
}

// ---- tests -------------------------------------------------------------------------------

raw struct TestEntry {
  /// a static string of the generated program
  name: raw.Ptr<u8>,
  /// C: AukTestFn
  func: raw.Fn<() => raw.Ptr<abi.Err>>,
}

raw var tests_lock: cfacts.PthreadMutex = cfacts.PTHREAD_MUTEX_INITIALIZER
raw var tests: raw.Ptr<TestEntry> = raw.null()
raw var ntests: i64 = 0
raw var captests: i64 = 0

export fn auk_test_register(name: raw.Ptr<u8>, func: raw.Fn<() => raw.Ptr<abi.Err>>) uses raw, ffi {
  pthread_mutex_lock(raw.addr_of(&tests_lock))
  if ntests == captests {
    captests = if captests == 0 { 16 } else { captests * 2 }
    tests = raw.cast(rc.auk__xrealloc(raw.cast(tests), usize(captests) * raw.size_of<TestEntry>()))
  }
  let t = tests.offset(ntests)
  t.name = name
  t.func = func
  ntests += 1
  let _ = pthread_mutex_unlock(raw.addr_of(&tests_lock))
}

/// Each line of p[0..n) as `    <line>\n` (a line ends at a NUL byte too).
fn print_indented(p: raw.Ptr<u8>, n: usize) uses raw, ffi {
  let out = cfacts.stdout()
  var i: usize = 0
  while i < n {
    var j = i
    while j < n && p.at(j) != 10 { // '\n'
      j += 1
    }
    var len = j - i
    let nul = memchr(raw.cast(p.offset(i)), 0, len)
    if !nul.is_null() {
      len = usize(nul.int() - p.offset(i).int())
    }
    fputs("    ", out)
    fwrite(raw.cast(p.offset(i)), 1, len, out)
    fputc(10, out)
    i = j + 1
  }
}

/// Read all of fd into a malloc'd buffer (*n bytes).
fn read_fd(fd: i32, n: raw.Ptr<usize>): raw.Ptr<u8> uses raw, ffi {
  var cap: usize = 4096
  var len: usize = 0
  var b: raw.Ptr<u8> = raw.cast(rc.auk__xmalloc(cap))
  while true {
    if len == cap {
      cap *= 2
      b = raw.cast(rc.auk__xrealloc(raw.cast(b), cap))
    }
    let r = c_read(fd, raw.cast(b.offset(len)), cap - len)
    if r < 0 && cfacts.errno() == cfacts.EINTR {
      continue
    }
    if r <= 0 {
      break
    }
    len += usize(r)
  }
  n.store(len)
  b
}

/// Print a test's trace tail (tail mode) under its FAIL line.
fn print_trace(path: raw.Ptr<u8>) uses raw, ffi {
  let f = fopen(path, "rb")
  if f.is_null() {
    return
  }
  var n: usize = 0
  let b = read_fd(fileno(f), raw.addr_of(&n))
  fclose(f)
  if n != 0 {
    fputs("    trace (last events, oldest first):\n", cfacts.stdout())
    print_indented(b, n)
  }
  raw.free(b)
}

fn sys_fail(what: raw.Ptr<u8>): never uses raw, ffi =
  rc.auk__panic3("auk test", what, ": ", strerror(cfacts.errno()))

raw struct TestRun {
  func: raw.Fn<() => raw.Ptr<abi.Err>>,
  err: raw.Ptr<abi.Err>,
}

fn run_test(p: raw.Ptr<()>) uses raw {
  let r: raw.Ptr<TestRun> = raw.cast(p)
  let f = r.func
  r.err = f()
}

raw struct PathBuf { b: [u8; 1024] }
raw struct NumBuf { b: [u8; 24] }
raw struct Fds { r: i32, w: i32 }

export fn auk_test_main(argc: i32, argv: raw.Ptr<raw.Ptr<u8>>): i32 uses raw, ffi {
  auk_env_set_args(argc, argv)
  let filter: raw.Ptr<u8> = if argc > 1 { argv.at(1) } else { raw.null() }
  let out = cfacts.stdout()
  let errf = cfacts.stderr()
  var passed: i64 = 0
  var failed: i64 = 0
  let tail = trace.auk__trace_tail_mode()
  let traced = tail || !trace.auk__trace_dir().is_null()
  var tail_buf = PathBuf {}
  let tail_path: raw.Ptr<u8> = raw.cast(raw.addr_of(&tail_buf))
  if tail {
    let tmp = getenv("TMPDIR")
    var m = abi.StrBuf {}
    let mp = raw.addr_of(&m)
    auk__sb_put_cstr(mp, if !tmp.is_null() && tmp.at(0) != 0 { tmp } else { "/tmp" })
    auk__sb_put_cstr(mp, "/auk-trace-")
    auk_sb_int(mp, i64(getpid()))
    auk__sb_put_cstr(mp, ".jsonl")
    auk__sb_take_into(mp, tail_path, raw.size_of<PathBuf>())
  }
  let tail_ptr: raw.Ptr<u8> = if tail { tail_path } else { raw.null() }
  pthread_mutex_lock(raw.addr_of(&tests_lock))
  let n = ntests
  let list: raw.Ptr<TestEntry> = raw.cast(rc.auk__xmalloc(usize(n + 1) * raw.size_of<TestEntry>()))
  raw.copy(list, tests, usize(n) * raw.size_of<TestEntry>())
  pthread_mutex_unlock(raw.addr_of(&tests_lock))
  var k: i64 = 0
  while k < n {
    let t = list.offset(k)
    k += 1
    if !filter.is_null() && filter.at(0) != 0 && strstr(t.name, filter).is_null() {
      continue
    }
    fflush(out)
    fflush(errf)
    var fds = Fds {}
    if pipe(raw.cast(raw.addr_of(&fds))) < 0 {
      sys_fail("pipe")
    }
    let pid = fork()
    if pid < 0 {
      sys_fail("fork")
    }
    if pid == 0 {
      close(fds.r)
      dup2(fds.w, 1)
      dup2(fds.w, 2)
      close(fds.w)
      if traced {
        trace.auk__trace_test_begin(t.name, tail_ptr)
      }
      var tr = TestRun { func: t.func }
      stack.auk__run_on_big_stack(raw.fn_of(run_test), raw.cast(raw.addr_of(&tr)))
      let e = tr.err
      if !e.is_null() {
        let s = err.auk_err_show(e)
        fflush(out)
        fputs("error: ", errf)
        fwrite(raw.cast(auk_str_cstr(s)), 1, usize(auk_str_byte_len(s)), errf)
        fputc(10, errf)
        fflush(errf)
        trace.auk__trace_flush()
        c_exit(1)
      }
      trace.auk__trace_flush()
      if auk_leak_check() != 0 {
        c_exit(1)
      }
      fflush(out)
      fflush(errf)
      c_exit(0)
    }
    close(fds.w)
    var olen: usize = 0
    let output = read_fd(fds.r, raw.addr_of(&olen))
    close(fds.r)
    var status: i32 = 0
    while waitpid(pid, raw.addr_of(&status), 0) < 0 && cfacts.errno() == cfacts.EINTR {
    }
    let ok = cfacts.wifexited(status) && cfacts.wexitstatus(status) == 0
    if traced {
      trace.auk__trace_test_end(t.name, ok, tail_ptr)
    }
    if ok {
      passed += 1
      fputs("ok ", out)
      fputs(t.name, out)
      fputc(10, out)
    } else {
      failed += 1
      fputs("FAIL ", out)
      fputs(t.name, out)
      fputc(10, out)
      if olen != 0 {
        print_indented(output, olen)
      }
      if cfacts.wifsignaled(status) {
        var sig = NumBuf {}
        let sp: raw.Ptr<u8> = raw.cast(raw.addr_of(&sig))
        auk__fmt_i64(sp, i64(cfacts.wtermsig(status)))
        fputs("    (killed by signal ", out)
        fputs(sp, out)
        fputs(")\n", out)
      }
      if tail {
        print_trace(tail_path)
      }
    }
    raw.free(output)
    if tail {
      unlink(tail_path)
    }
  }
  raw.free(list)
  var m = abi.StrBuf {}
  let mp = raw.addr_of(&m)
  auk_sb_int(mp, passed)
  auk__sb_put_cstr(mp, " passed, ")
  auk_sb_int(mp, failed)
  auk__sb_put_cstr(mp, " failed\n")
  fputs(auk__sb_cstr(mp), out)
  auk_sb_free(mp)
  fflush(out)
  if failed != 0 { 1 } else { 0 }
}

// ---- program entry -----------------------------------------------------------------------

raw struct MainRun {
  /// C: AukMainFn
  func: raw.Fn<(raw.Ptr<abi.Arr>) => abi.ResInt>,
  args: raw.Ptr<abi.Arr>,
  r: abi.ResInt,
}

/// Non-zero while the program's `main` may end without freeing what it still holds: the values
/// in its locals that can't reach a handle (generated code tests this before releasing them at
/// `main`'s normal exit; the process is about to end, and handles still get released: a task's
/// release waits for it). Set only for the process's own `main`, not a program the compiler runs
/// in its process (`auk run`, `dive`), and never under AUK_LEAK_CHECK, which counts every object.
export var auk_exit_fast: i64 = 0

/// How many auk_main_wrapper calls are running (the compiler's own, then a program it runs).
raw var main_depth: i64 = 0

fn run_main(p: raw.Ptr<()>) uses raw {
  let m: raw.Ptr<MainRun> = raw.cast(p)
  let f = m.func
  m.r = f(m.args)
}

export fn auk_main_wrapper(argc: i32, argv: raw.Ptr<raw.Ptr<u8>>, user_main: raw.Fn<(raw.Ptr<abi.Arr>) => abi.ResInt>): i32 uses raw, ffi {
  // started by a `gui.open` of this same program to own its windows (gui_host)
  if !getenv("AUK_GUI_HOST").is_null() {
    return gui_host.auk__gui_host_main()
  }
  auk_env_set_args(argc, argv)
  main_depth += 1
  let fast = auk_exit_fast
  auk_exit_fast = if main_depth == 1 && getenv("AUK_LEAK_CHECK").is_null() { 1 } else { 0 }
  // on a thread with a big stack, where an overflow is a panic
  var m = MainRun { func: user_main, args: auk_env_args() }
  stack.auk__run_on_big_stack(raw.fn_of(run_main), raw.cast(raw.addr_of(&m)))
  auk_exit_fast = fast
  main_depth -= 1
  let r = m.r
  let out = cfacts.stdout()
  let errf = cfacts.stderr()
  fflush(out)
  if !r.ok {
    let s = err.auk_err_show(r.err)
    fputs("error: ", errf)
    fwrite(raw.cast(auk_str_cstr(s)), 1, usize(auk_str_byte_len(s)), errf)
    fputc(10, errf)
    rc.release(raw.cast(s))
    rc.release(raw.cast(r.err))
    fflush(errf)
    return if auk_leak_check() != 0 { 102 } else { 1 }
  }
  if auk_leak_check() != 0 {
    return 102
  }
  i32(r.val)
}

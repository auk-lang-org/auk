/// The core library's `print` and `env` (was runtime/c/core.c, ported line by line): lines to
/// stdout and stderr, environment variables, the program's arguments, terminals, and stdin.

// the rest of the runtime (C, for now)
extern fn auk_release(p: raw.Ptr<()>) = "void auk_release(void *)"
extern fn auk__make_immortal(p: raw.Ptr<()>) = "void auk__make_immortal(void *)"
extern fn auk_str_try_from_bytes(p: raw.Ptr<u8>, n: i64): abi.ResStr = "AukRes_str auk_str_try_from_bytes(const char *, int64_t)"
extern fn auk__c_ioctl_ptr(fd: i32, request: u64, arg: raw.Ptr<()>): i32 = "int auk__c_ioctl_ptr(int, unsigned long, void *)"
// libc
extern fn fwrite(p: raw.Ptr<()>, size: usize, n: usize, f: raw.Ptr<()>): usize = "size_t fwrite(const void *, size_t, size_t, void *)"
extern fn fputc(c: i32, f: raw.Ptr<()>): i32 = "int fputc(int, void *)"
extern fn fflush(f: raw.Ptr<()>): i32 = "int fflush(void *)"
extern fn flockfile(f: raw.Ptr<()>) = "void flockfile(void *)"
extern fn funlockfile(f: raw.Ptr<()>) = "void funlockfile(void *)"
extern fn clearerr(f: raw.Ptr<()>) = "void clearerr(void *)"
extern fn getline(line: raw.Ptr<raw.Ptr<u8>>, cap: raw.Ptr<usize>, f: raw.Ptr<()>): i64 = "ssize_t getline(char **, size_t *, void *)"
extern fn getenv(name: raw.Ptr<u8>): raw.Ptr<u8> = "char *getenv(const char *)"
extern fn strlen(s: raw.Ptr<u8>): usize = "size_t strlen(const char *)"
extern fn strtoll(s: raw.Ptr<u8>, end: raw.Ptr<raw.Ptr<u8>>, base: i32): i64 = "long long strtoll(const char *, char **, int)"
extern fn isatty(fd: i32): i32 = "int isatty(int)"
extern fn pthread_mutex_lock(m: raw.Ptr<cfacts.PthreadMutex>): i32 = "int pthread_mutex_lock(void *)"
extern fn pthread_mutex_unlock(m: raw.Ptr<cfacts.PthreadMutex>): i32 = "int pthread_mutex_unlock(void *)"

// ---- print ----

fn write_line(f: raw.Ptr<()>, p: raw.Ptr<()>, n: usize) uses ffi {
  flockfile(f)
  fwrite(p, 1, n, f)
  fputc(10, f) // '\n'
  funlockfile(f)
}

export fn auk_print(s: raw.Ptr<abi.Str>) uses raw, ffi {
  write_line(cfacts.stdout(), raw.cast(str.auk_str_cstr(s)), usize(str.auk_str_byte_len(s)))
}

export fn auk_print_lit(cstr: raw.Ptr<u8>) uses raw, ffi {
  if cstr.is_null() {
    let empty: raw.Ptr<u8> = ""
    write_line(cfacts.stdout(), raw.cast(empty), 0)
  } else {
    write_line(cfacts.stdout(), raw.cast(cstr), strlen(cstr))
  }
}

export fn auk_eprint(s: raw.Ptr<abi.Str>) uses raw, ffi {
  fflush(cfacts.stdout())
  write_line(cfacts.stderr(), raw.cast(str.auk_str_cstr(s)), usize(str.auk_str_byte_len(s)))
}

// ---- env ----

raw var args_lock: cfacts.PthreadMutex = cfacts.PTHREAD_MUTEX_INITIALIZER
raw var args: raw.Ptr<abi.Arr> = raw.null()

export fn auk_env_get(key: raw.Ptr<abi.Str>): abi.OptStr uses raw, ffi {
  let v = getenv(str.auk_str_cstr(key))
  if v.is_null() {
    return abi.OptStr {}
  }
  abi.OptStr { some: true, val: str.auk_str_lit(v) }
}

export fn auk_env_set_args(argc: i32, argv: raw.Ptr<raw.Ptr<u8>>) uses raw, ffi {
  var a = arr.auk_arr_new(str.ops_str(), i64(argc))
  var i: i32 = 0
  while i < argc {
    var s = str.auk_str_lit(argv.at(i))
    arr.auk_arr_push(raw.addr_of(&a), raw.cast(raw.addr_of(&s)))
    auk_release(raw.cast(s))
    auk__make_immortal(raw.cast(s))
    i += 1
  }
  auk__make_immortal(raw.cast(a))
  // a previous array is immortal and simply abandoned
  pthread_mutex_lock(raw.addr_of(&args_lock))
  args = a
  let _ = pthread_mutex_unlock(raw.addr_of(&args_lock))
}

export fn auk_env_args(): raw.Ptr<abi.Arr> uses raw, ffi {
  pthread_mutex_lock(raw.addr_of(&args_lock))
  if args.is_null() {
    args = arr.auk_arr_new(str.ops_str(), 0)
    auk__make_immortal(raw.cast(args))
  }
  let a = args
  pthread_mutex_unlock(raw.addr_of(&args_lock))
  a
}

/// Whether file descriptor fd (0 stdin, 1 stdout, 2 stderr) is a terminal.
export fn auk_env_is_terminal(fd: i64): bool uses ffi = fd >= 0 && fd <= 2 && isatty(i32(fd)) == 1

/// C's isspace in the "C" locale: ' ' and '\t'..'\r'.
fn is_space(c: u8): bool = c == 32 || (c >= 9 && c <= 13)

/// The terminal's width in columns: from stdout, stderr or stdin (the first that is a terminal),
/// else $COLUMNS, else none.
export fn auk_env_columns(): abi.OptInt uses raw, ffi {
  var k: i32 = 0
  while k < 3 {
    let fd: i32 = if k == 0 { 1 } else if k == 1 { 2 } else { 0 }
    var ws = cfacts.Winsize {}
    if auk__c_ioctl_ptr(fd, cfacts.TIOCGWINSZ, raw.cast(raw.addr_of(&ws))) == 0 && ws.ws_col > 0 {
      return abi.OptInt { some: true, val: i64(ws.ws_col) }
    }
    k += 1
  }
  var r = abi.OptInt {}
  var v = getenv("COLUMNS")
  if !v.is_null() {
    // a whole number, surrounding whitespace allowed
    while is_space(v.load()) {
      v = v.offset(1)
    }
    var end: raw.Ptr<u8> = raw.null()
    cfacts.set_errno(0)
    let n = strtoll(v, raw.addr_of(&end), 10)
    if end != v && cfacts.errno() == 0 {
      while is_space(end.load()) {
        end = end.offset(1)
      }
      if end.load() == 0 && n > 0 {
        r.some = true
        r.val = n
      }
    }
  }
  r
}

// stdin: read through stdio (one buffer shared by read_line, read_all and lines). Stdout is
// flushed first, so a prompt printed without a newline-terminated flush still shows.

export fn auk_env_read_line(): abi.OptStr uses raw, ffi {
  fflush(cfacts.stdout())
  var line: raw.Ptr<u8> = raw.null()
  var cap: usize = 0
  var n = getline(raw.addr_of(&line), raw.addr_of(&cap), core_os.stdin())
  if n < 0 {
    raw.free(line)
    return abi.OptStr {}
  }
  if n > 0 && line.at(n - 1) == 10 { // '\n'
    n -= 1
  }
  if n > 0 && line.at(n - 1) == 13 { // '\r'
    n -= 1
  }
  let s = str.auk_str_from_bytes(line, n) // invalid UTF-8 becomes U+FFFD
  raw.free(line)
  abi.OptStr { some: true, val: s }
}

export fn auk_env_read_all(): abi.ResStr uses raw, ffi {
  fflush(cfacts.stdout())
  let stdin = core_os.stdin()
  var b = core_util.Bytes {}
  let e = core_util.slurp(stdin, raw.addr_of(&b))
  if e != 0 {
    raw.free(b.p)
    clearerr(stdin)
    return core_util.str_err(err.auk__err_errno("env.read_all: stdin", raw.null(), e))
  }
  var r = auk_str_try_from_bytes(b.p, b.n)
  raw.free(b.p)
  if !r.ok {
    let e2 = err.auk_err_new_cstr("env.read_all: stdin")
    e2.cause = r.err // moves the reference
    r.err = e2
  }
  r
}

export fn auk_env_lines(): raw.Ptr<abi.Arr> uses raw, ffi {
  fflush(cfacts.stdout())
  let stdin = core_os.stdin()
  var b = core_util.Bytes {}
  if core_util.slurp(stdin, raw.addr_of(&b)) != 0 {
    clearerr(stdin) // keep what was read before the error
  }
  let s = str.auk_str_from_bytes(b.p, b.n)
  raw.free(b.p)
  let a = str.auk_str_lines(s)
  auk_release(raw.cast(s))
  a
}

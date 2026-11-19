/// The core library's `proc` (was runtime/c/core.c, ported line by line): run a program
/// (posix_spawnp, its stdout through a pipe), exit.

// the rest of the runtime (C, for now)
extern fn auk__xmalloc(n: usize): raw.Ptr<()> = "void *auk__xmalloc(size_t)"
extern fn auk_release(p: raw.Ptr<()>) = "void auk_release(void *)"
extern fn auk_arr_len(a: raw.Ptr<abi.Arr>): i64 = "int64_t auk_arr_len(const void *)"
extern fn auk__wait_fd(fd: i32, write: bool) = "void auk__wait_fd(int, bool)"
extern fn auk__trace_flush() = "void auk__trace_flush(void)"
extern fn auk_leak_check(): i64 = "int64_t auk_leak_check(void)"
extern fn auk__c_fcntl(fd: i32, cmd: i32, arg: i32): i32 = "int auk__c_fcntl(int, int, int)"
// libc
extern fn pipe(fds: raw.Ptr<i32>): i32 = "int pipe(int *)"
extern fn read(fd: i32, buf: raw.Ptr<()>, n: usize): i64 = "ssize_t read(int, void *, size_t)"
extern fn close(fd: i32): i32 = "int close(int)"
extern fn fflush(f: raw.Ptr<()>): i32 = "int fflush(void *)"
extern fn waitpid(pid: i32, status: raw.Ptr<i32>, options: i32): i32 = "int waitpid(int, int *, int)"
extern fn c_exit(code: i32): never = "void _exit(int)"
extern fn posix_spawn_file_actions_init(fa: raw.Ptr<cfacts.PosixSpawnFileActions>): i32 =
  "int posix_spawn_file_actions_init(void *)"
extern fn posix_spawn_file_actions_destroy(fa: raw.Ptr<cfacts.PosixSpawnFileActions>): i32 =
  "int posix_spawn_file_actions_destroy(void *)"
extern fn posix_spawn_file_actions_adddup2(fa: raw.Ptr<cfacts.PosixSpawnFileActions>, fd: i32, to: i32): i32 =
  "int posix_spawn_file_actions_adddup2(void *, int, int)"
extern fn posix_spawn_file_actions_addclose(fa: raw.Ptr<cfacts.PosixSpawnFileActions>, fd: i32): i32 =
  "int posix_spawn_file_actions_addclose(void *, int)"
extern fn posix_spawnp(pid: raw.Ptr<i32>, file: raw.Ptr<u8>, fa: raw.Ptr<cfacts.PosixSpawnFileActions>, attr: raw.Ptr<()>,
  argv: raw.Ptr<raw.Ptr<u8>>, envp: raw.Ptr<raw.Ptr<u8>>): i32 =
  "int posix_spawnp(int *, const char *, const void *, const void *, void *, void *)"
extern var environ: raw.Ptr<raw.Ptr<u8>> = "environ"

/// A pipe's two ends (C's `int fds[2]`).
raw struct Pipe {
  r: i32,
  w: i32,
}

export fn auk_proc_run(cmd: raw.Ptr<abi.Str>, args_in: raw.Ptr<abi.Arr>): abi.ResStr uses raw, ffi {
  let n = auk_arr_len(args_in)
  let argv: raw.Ptr<raw.Ptr<u8>> = raw.cast(auk__xmalloc(usize(n + 2) * raw.size_of<raw.Ptr<u8>>()))
  argv.at(0) = str.auk_str_cstr(cmd)
  if n > 0 {
    let xs: raw.Ptr<raw.Ptr<abi.Str>> = raw.cast(args_in.data)
    var i: i64 = 0
    while i < n {
      argv.at(i + 1) = str.auk_str_cstr(xs.at(i))
      i += 1
    }
  }
  argv.at(n + 1) = raw.null()
  var fds = Pipe {}
  if pipe(raw.cast(raw.addr_of(&fds))) < 0 {
    raw.free(argv)
    return core_util.str_err(err.auk__err_errno("proc.run", cmd, cfacts.errno()))
  }
  auk__c_fcntl(fds.r, cfacts.F_SETFD, cfacts.FD_CLOEXEC)
  var fa = cfacts.PosixSpawnFileActions {}
  let fap = raw.addr_of(&fa)
  posix_spawn_file_actions_init(fap)
  posix_spawn_file_actions_adddup2(fap, fds.w, 1)
  posix_spawn_file_actions_addclose(fap, fds.w)
  var pid: i32 = 0
  fflush(cfacts.stdout())
  let rc = posix_spawnp(raw.addr_of(&pid), str.auk_str_cstr(cmd), fap, raw.null(), argv, environ)
  posix_spawn_file_actions_destroy(fap)
  raw.free(argv)
  close(fds.w)
  if rc != 0 {
    close(fds.r)
    return core_util.str_err(err.auk__err_errno("proc.run", cmd, rc))
  }
  var b = core_util.Bytes {}
  let buf: raw.Ptr<u8> = raw.cast(auk__xmalloc(65536))
  loop {
    auk__wait_fd(fds.r, false)
    let r = read(fds.r, raw.cast(buf), 65536)
    if r < 0 && cfacts.errno() == cfacts.EINTR {
      continue
    }
    if r <= 0 {
      break
    }
    core_util.bytes_add(raw.addr_of(&b), buf, r)
  }
  raw.free(buf)
  close(fds.r)
  var status: i32 = 0
  while waitpid(pid, raw.addr_of(&status), 0) < 0 {
    if cfacts.errno() != cfacts.EINTR {
      status = -1
      break
    }
  }
  let out = str.auk_str_from_bytes(b.p, b.n)
  raw.free(b.p)
  if status == -1 || !cfacts.wifexited(status) || cfacts.wexitstatus(status) != 0 {
    var m = abi.StrBuf {}
    let mp = raw.addr_of(&m)
    str.auk__sb_put_cstr(mp, "proc.run ")
    str.auk__sb_put_cstr(mp, str.auk_str_cstr(cmd))
    var e: raw.Ptr<abi.Err> = raw.null()
    if status != -1 && cfacts.wifexited(status) {
      let st = cfacts.wexitstatus(status)
      str.auk__sb_put_cstr(mp, ": exited with status ")
      str_fmt.auk_sb_int(mp, i64(st))
      e = core_util.err_code_sb(mp, st)
    } else if status != -1 && cfacts.wifsignaled(status) {
      let sig = cfacts.wtermsig(status)
      str.auk__sb_put_cstr(mp, ": killed by signal ")
      str_fmt.auk_sb_int(mp, i64(sig))
      e = core_util.err_code_sb(mp, 128 + sig)
    } else {
      str.auk__sb_put_cstr(mp, ": could not wait for the process")
      e = str.auk__err_sb(mp)
    }
    auk_release(raw.cast(out))
    return core_util.str_err(e)
  }
  abi.ResStr { ok: true, val: out }
}

export fn auk_proc_exit(code: i64, loc: raw.Ptr<u8>): never uses raw, ffi {
  if code < 0 || code > 255 {
    var m = abi.StrBuf {}
    let mp = raw.addr_of(&m)
    str.auk__sb_put_cstr(mp, "proc.exit(")
    str_fmt.auk_sb_int(mp, code)
    str.auk__sb_put_cstr(mp, "): code out of range 0..255")
    str.auk__panic_sb(loc, mp)
  }
  fflush(cfacts.stdout())
  fflush(cfacts.stderr())
  auk__trace_flush()
  if auk_leak_check() != 0 {
    c_exit(102)
  }
  // _exit, like a panic: async tasks may still be running on other threads
  c_exit(i32(code))
}

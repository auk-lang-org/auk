/// The few POSIX calls the driver needs that the prelude doesn't have: writing text as is,
/// exiting as a C program does, and forked children with redirected streams (src/mir/exec.rs).

extern fn c_write(fd: int, s: str, n: int): int = "long write(int, const char *, size_t)"
extern fn c_fflush(f: ffi.Ptr): int = "int fflush(void *)"
extern fn c_exit(code: int) = "void exit(int)"
extern fn c__exit(code: int) = "void _exit(int)"
extern fn c_fork(): int = "int fork(void)"
extern fn c_creat(path: str, mode: int): int = "int creat(const char *, int)"
extern fn c_dup2(a: int, b: int): int = "int dup2(int, int)"
extern fn c_close(fd: int): int = "int close(int)"
extern fn c_waitpid(pid: int, status: ffi.Ptr, flags: int): int = "int waitpid(int, void *, int)"
extern fn c_getpid(): int = "int getpid(void)"

/// Write `s` to stdout as is (`print` adds a newline), after what `print` buffered.
pub fn print_raw(s: str) uses ffi { write_all(1, s) }

/// Write `s` to stderr as is.
pub fn eprint_raw(s: str) uses ffi { write_all(2, s) }

fn write_all(fd: int, s: str) uses ffi {
  let _ = c_fflush(ffi.null)
  if s.byte_len() > 0 && c_write(fd, s, s.byte_len()) < 0 && fd == 1 {
    eprint("error: writing the output failed")
  }
}

/// End the process as a C program returning from `main` would: flush C stdio, run the `atexit`
/// handlers (a traced program's tracer), exit with `code`.
pub fn exit(code: int) uses ffi {
  let _ = c_fflush(ffi.null)
  c_exit(code)
}

/// Flush C stdio (before forking, so a child doesn't write what the parent buffered).
pub fn flush() uses ffi { let _ = c_fflush(ffi.null) }

/// This process's id.
pub fn pid(): int uses ffi = c_getpid()

/// Where a forked child's standard streams go: a file to create (or `/dev/null`), none to keep
/// the parent's.
pub struct Redirect { stdout: str?, stderr: str? }

/// Run `body` in a forked child with its streams redirected and wait for it: its exit code, or
/// none when it was killed by a signal. The child exits with what `body` returns: as a C
/// program does (`full_exit`: `atexit` handlers run, a traced program's tracer among them), or
/// at once (`_exit`, as src/mir/exec.rs's `run_forked`).
pub fn run_forked(r: Redirect, full_exit: bool, body: () => int): int?! uses ffi {
  let out = open_for(r.stdout)?
  let err = open_for(r.stderr)?
  flush()
  let pid = c_fork()
  if pid < 0 { return fail("error: fork failed\n") }
  if pid == 0 {
    if out >= 0 { let _ = c_dup2(out, 1) }
    if err >= 0 { let _ = c_dup2(err, 2) }
    let code = body()
    flush()
    if full_exit { c_exit(code) }
    c__exit(code)
  }
  if out >= 0 { let _ = c_close(out) }
  if err >= 0 { let _ = c_close(err) }
  wait(pid)
}

fn open_for(p: str?): int! uses ffi {
  match p {
    some(path) => {
      let fd = c_creat(path, 420)
      if fd < 0 { return fail("error: cannot create {path}\n") }
      fd
    }
    none => -1
  }
}

/// Wait for child `pid`: its exit code, or none if a signal killed it.
pub fn wait(pid: int): int?! uses ffi {
  let st = ffi.alloc(8)
  ffi.write_i64(st, 0, 0)
  // a failure is EINTR (a signal arrived) unless it keeps failing
  var tries = 0
  loop {
    let r = c_waitpid(pid, st, 0)
    if r == pid { break }
    tries += 1
    if tries > 1000 {
      ffi.free(st)
      return fail("error: waitpid failed\n")
    }
  }
  let status = ffi.read_i32(st, 0)
  ffi.free(st)
  // WIFEXITED: no signal bits; WEXITSTATUS: the second byte
  if (status & 127) == 0 { some((status >> 8) & 255) } else { none }
}

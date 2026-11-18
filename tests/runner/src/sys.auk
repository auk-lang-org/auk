/// Child processes with piped streams, through C (`ffi`): what the runner needs beyond core's
/// `proc.run` (which takes no stdin, keeps no stderr or status): `posix_spawnp` with the
/// streams on pipes, an environment and a working directory of the child's own, and `poll` to
/// feed stdin and drain stdout and stderr at once (Rust's `Command::output`, `spawn`).
///
/// Every pipe end of ours is close-on-exec, and on macOS the child starts with only fds 0-2
/// (`POSIX_SPAWN_CLOEXEC_DEFAULT`), so a child started by one test task never holds another
/// test's pipes open. The child is the leader of its own process group, so a timeout kills
/// what it started too. SIGPIPE is ignored in the runner (a child that exits without reading
/// its stdin is not fatal) and reset to the default in every child, as Rust's `Command` does.

/// A started child: its pid, our ends of its pipes (-1 when closed or not piped), and what it
/// has written so far.
pub struct Child {
  pid: int,
  stdin: int,
  out: int,
  err: int,
  obuf: [int],
  ebuf: [int],
  /// The raw wait status once reaped.
  status: int?,
}

/// What a finished child left: its exit code (none if a signal ended it), the signal, its
/// output (bytes) and whether the runner killed it after a timeout.
pub struct Exit {
  code: int?,
  signal: int?,
  stdout: [int],
  stderr: [int],
  timed_out: bool,
}

pub fn linux(): bool uses ffi = paths.os() == "linux"

/// Ignore SIGPIPE in this process (once, at start).
pub fn ignore_sigpipe() uses ffi { let _ = c_signal(13, ffi.ptr(1)) }

/// Change this process's working directory.
pub fn chdir(dir: str): bool uses ffi = c_chdir(dir) == 0

/// This process's id.
pub fn pid(): int uses ffi = c_getpid()

/// This process's environment as `KEY=value` strings.
pub fn environ(): [str] uses ffi {
  let base = match ffi.symbol("environ") {
    some(e) => ffi.read_ptr(e, 0)
    none => return []
  }
  var out: [str] = []
  var i = 0
  loop {
    let p = ffi.read_ptr(base, 8 * i)
    if ffi.is_null(p) { break }
    out.push(ffi.cstr(p))
    i += 1
  }
  out
}

/// Start `argv` (found on PATH) with environment `envp` (`KEY=value`), in `cwd` if given. Its
/// stdin is a pipe if `pipe_in` (else /dev/null); stdout and stderr are pipes.
pub fn spawn(argv: [str], envp: [str], cwd: str?, pipe_in: bool): Child! uses ffi {
  let lin = linux()
  let (in_r, in_w) = if pipe_in { make_pipe()? } else { (-1, -1) }
  let (out_r, out_w) = make_pipe()?
  let (err_r, err_w) = make_pipe()?
  let fa = ffi.alloc(1024)
  let attr = ffi.alloc(1024)
  let _ = c_fa_init(fa)
  if pipe_in { let _ = c_fa_dup2(fa, in_r, 0) } else { let _ = c_fa_open(fa, 0, "/dev/null", 0, 0) }
  let _ = c_fa_dup2(fa, out_w, 1)
  let _ = c_fa_dup2(fa, err_w, 2)
  match cwd {
    some(d) => { let _ = c_fa_chdir(fa, d) }
    none => {}
  }
  let _ = c_attr_init(attr)
  // the default disposition of SIGPIPE (13) in the child
  let set = ffi.alloc(256)
  let _ = c_sigemptyset(set)
  let _ = c_sigaddset(set, 13)
  let _ = c_attr_sigdefault(attr, set)
  // SETPGROUP | SETSIGDEF, and on macOS CLOEXEC_DEFAULT
  let flags = 2 | 4 | if lin { 0 } else { 0x4000 }
  let _ = c_attr_flags(attr, flags)
  let _ = c_attr_pgroup(attr, 0)
  let av = c_array(argv)
  let ev = c_array(envp)
  var pid = 0
  let r = c_spawnp(&pid, argv[0], fa, attr, av.0, ev.0)
  let _ = c_fa_destroy(fa)
  let _ = c_attr_destroy(attr)
  free_array(av)
  free_array(ev)
  ffi.free(fa)
  ffi.free(attr)
  ffi.free(set)
  for fd in [in_r, out_w, err_w] { if fd >= 0 { let _ = c_close(fd) } }
  if r != 0 {
    for fd in [in_w, out_r, err_r] { if fd >= 0 { let _ = c_close(fd) } }
    return fail("cannot start `{argv[0]}`: {c_strerror(r)} (os error {r})")
  }
  Child { pid, stdin: in_w, out: out_r, err: err_r, obuf: [], ebuf: [], status: none }
}

/// A pipe whose two ends are close-on-exec: (read end, write end).
fn make_pipe(): (int, int)! uses ffi {
  let p = ffi.alloc(8)
  let r = c_pipe(p)
  let (a, b) = (ffi.read_i32(p, 0), ffi.read_i32(p, 4))
  ffi.free(p)
  if r != 0 { return fail("pipe failed") }
  let fioclex = if linux() { 0x5451 } else { 0x20006601 }
  let _ = c_ioctl(a, fioclex)
  let _ = c_ioctl(b, fioclex)
  (a, b)
}

/// NUL-terminated copies of `xs` and a NULL-ended array of them.
fn c_array(xs: [str]): (ffi.Ptr, [ffi.Ptr]) uses ffi {
  let ptrs = xs.map(a => ffi.from_bytes(a.bytes() + [0]))
  let av = ffi.alloc(8 * (ptrs.len() + 1))
  for i, p in ptrs { ffi.write_ptr(av, 8 * i, p) }
  ffi.write_ptr(av, 8 * ptrs.len(), ffi.null)
  (av, ptrs)
}

fn free_array(a: (ffi.Ptr, [ffi.Ptr])) uses ffi {
  for p in a.1 { ffi.free(p) }
  ffi.free(a.0)
}

/// Close the child's stdin (it sees end of input).
pub fn close_stdin(c: var Child) uses ffi {
  if c.stdin >= 0 {
    let _ = c_close(c.stdin)
    c.stdin = -1
  }
}

/// Write `data` to the child's stdin, reading its output meanwhile (so neither side blocks).
/// False if the child stopped reading (its stdin is then closed) or `ms` passed.
pub fn write(c: var Child, data: [int], ms: int): bool uses ffi, time {
  if c.stdin < 0 { return false }
  let deadline = time.now() + ms
  var at = 0
  while at < data.len() {
    let left = deadline - time.now()
    if left <= 0 { return false }
    let ready = poll_once(&c, true, left)
    if ready {
      // POLLOUT: a pipe takes at least PIPE_BUF (512) bytes without blocking
      let n = min(512, data.len() - at)
      let buf = ffi.from_bytes(data[at..at + n])
      let w = c_write(c.stdin, buf, n)
      ffi.free(buf)
      if w <= 0 {
        close_stdin(&c)
        return false
      }
      at += w
    }
  }
  true
}

/// Wait up to `ms` for output (or for room in stdin when `want_write`), appending what stdout
/// and stderr have to the buffers. Returns whether stdin can take bytes now.
fn poll_once(c: var Child, want_write: bool, ms: int): bool uses ffi {
  let fds = ffi.alloc(24)
  var n = 0
  var slots: [int] = []
  for (fd, ev) in [(c.out, 1), (c.err, 1), (if want_write { c.stdin } else { -1 }, 4)] {
    if fd >= 0 {
      ffi.write_i32(fds, 8 * n, fd)
      ffi.write_i32(fds, 8 * n + 4, ev)
      slots.push(fd)
      n += 1
    }
  }
  if n == 0 {
    ffi.free(fds)
    return false
  }
  let r = c_poll(fds, n, max(0, ms))
  var writable = false
  if r > 0 {
    for i, fd in slots {
      let rev = (ffi.read_i32(fds, 8 * i + 4) >> 16) & 0xffff
      if rev == 0 { continue }
      if fd == c.stdin {
        // POLLOUT, or POLLERR/POLLHUP: the reader is gone (the write then fails)
        writable = true
      } else {
        let got = read_some(fd)
        match got {
          some(bytes) => if fd == c.out {
            for b in bytes { c.obuf.push(b) }
          } else {
            for b in bytes { c.ebuf.push(b) }
          }
          none => {
            let _ = c_close(fd)
            if fd == c.out { c.out = -1 } else { c.err = -1 }
          }
        }
      }
    }
  }
  ffi.free(fds)
  writable
}

/// Up to 64 KiB from `fd`; none at end of file (or an error).
fn read_some(fd: int): [int]? uses ffi {
  let buf = ffi.alloc(65536)
  let n = c_read(fd, buf, 65536)
  let out = if n > 0 { some(ffi.bytes(buf, n)) } else { none }
  ffi.free(buf)
  out
}

/// Read output for up to `ms` (or until both streams are closed). False when nothing is open.
pub fn pump(c: var Child, ms: int): bool uses ffi {
  if c.out < 0 && c.err < 0 { return false }
  let _ = poll_once(&c, false, ms)
  true
}

/// Take the first line (without its `\n`) from what the child wrote to stdout, waiting up to
/// `ms` for it; at end of output, what is left (none if nothing).
pub fn read_line(c: var Child, ms: int): str? uses ffi, time {
  let deadline = time.now() + ms
  loop {
    match c.obuf.find_index(b => b == 10) {
      some(i) => {
        let line = c.obuf[0..i]
        c.obuf = c.obuf[i + 1..c.obuf.len()]
        return lossy(line)
      }
      none => {}
    }
    let left = deadline - time.now()
    if c.out < 0 || left <= 0 {
      if c.out < 0 && c.obuf.len() > 0 {
        let rest = c.obuf
        c.obuf = []
        return lossy(rest)
      }
      return none
    }
    let _ = poll_once(&c, false, left)
  }
}

/// Take `n` bytes of stdout, waiting up to `ms` for them (none if they don't come).
pub fn read_exact(c: var Child, n: int, ms: int): [int]? uses ffi, time {
  let deadline = time.now() + ms
  while c.obuf.len() < n {
    let left = deadline - time.now()
    if c.out < 0 || left <= 0 { return none }
    let _ = poll_once(&c, false, left)
  }
  let got = c.obuf[0..n]
  c.obuf = c.obuf[n..c.obuf.len()]
  got
}

/// Whether the child has exited (reaping it if so), without waiting.
pub fn try_wait(c: var Child): bool uses ffi {
  if c.status is some(_) { return true }
  var st = 0
  if c_waitpid(c.pid, &st, 1) == c.pid {
    c.status = some(st)
    return true
  }
  false
}

/// Kill the child's process group (and the child).
pub fn kill(c: var Child) uses ffi {
  if c.status is some(_) { return }
  let _ = c_kill(-c.pid, 9)
  let _ = c_kill(c.pid, 9)
}

/// Close stdin, read the rest of the output and wait for the child, at most `ms` (then its
/// process group is killed).
pub fn finish(c: var Child, ms: int): Exit uses ffi, time {
  close_stdin(&c)
  let deadline = time.now() + ms
  var timed_out = false
  while c.out >= 0 || c.err >= 0 {
    let left = deadline - time.now()
    if left <= 0 {
      timed_out = true
      kill(&c)
      break
    }
    let _ = poll_once(&c, false, min(left, 1000))
  }
  if c.out >= 0 {
    let _ = c_close(c.out)
    c.out = -1
  }
  if c.err >= 0 {
    let _ = c_close(c.err)
    c.err = -1
  }
  // the streams are closed; the child may still run (it closed them, or was killed)
  while !try_wait(&c) {
    if !timed_out && time.now() > deadline {
      timed_out = true
      kill(&c)
    }
    time.sleep(5)
  }
  let st = c.status else 0
  let sig = st & 0x7f
  Exit {
    code: if sig == 0 { some((st >> 8) & 0xff) } else { none },
    signal: if sig == 0 { none } else { some(sig) },
    stdout: c.obuf,
    stderr: c.ebuf,
    timed_out,
  }
}

/// Bytes as text, invalid UTF-8 replaced by U+FFFD (`String::from_utf8_lossy`).
pub fn lossy(b: [int]): str {
  match str.from_utf8(b) {
    ok(s) => return s
    err(_) => {}
  }
  var out: [char] = []
  var i = 0
  while i < b.len() {
    let c = b[i]
    if c < 0x80 {
      out.push(char(c)!)
      i += 1
      continue
    }
    // the sequence's length and the range of its second byte
    let (n, lo, hi) = if c >= 0xc2 && c <= 0xdf {
      (2, 0x80, 0xbf)
    } else if c == 0xe0 {
      (3, 0xa0, 0xbf)
    } else if c == 0xed {
      (3, 0x80, 0x9f)
    } else if c >= 0xe1 && c <= 0xef {
      (3, 0x80, 0xbf)
    } else if c == 0xf0 {
      (4, 0x90, 0xbf)
    } else if c == 0xf4 {
      (4, 0x80, 0x8f)
    } else if c >= 0xf1 && c <= 0xf3 {
      (4, 0x80, 0xbf)
    } else {
      (0, 0, 0)
    }
    if n == 0 {
      out.push('\u{FFFD}')
      i += 1
      continue
    }
    // the longest valid prefix of the sequence is one replacement character
    var j = 1
    var good = true
    while j < n && good {
      let b2 = b.get(i + j) else -1
      let (l, h) = if j == 1 { (lo, hi) } else { (0x80, 0xbf) }
      if b2 < l || b2 > h { good = false } else { j += 1 }
    }
    if good {
      out = out + str.from_utf8(b[i..i + n])!.chars()
      i += n
    } else {
      out.push('\u{FFFD}')
      i += j
    }
  }
  str(out)
}

// ---- unix sockets (the debugger's AUK_DEBUG connection) ----

/// Connect to the unix socket at `path`: a file descriptor, or none.
pub fn unix_connect(path: str): int? uses ffi {
  let fd = c_socket(1, 1, 0)
  if fd < 0 { return none }
  let _ = c_ioctl(fd, if linux() { 0x5451 } else { 0x20006601 })
  let addr = ffi.alloc(112)
  for i in 0..112 { ffi.write_u8(addr, i, 0) }
  let bytes = path.bytes()
  if linux() {
    ffi.write_u8(addr, 0, 1)  // sa_family_t (u16, little-endian) AF_UNIX
    for i, b in bytes { ffi.write_u8(addr, 2 + i, b) }
  } else {
    ffi.write_u8(addr, 0, 106)  // sun_len
    ffi.write_u8(addr, 1, 1)    // AF_UNIX
    for i, b in bytes { ffi.write_u8(addr, 2 + i, b) }
  }
  let r = c_connect(fd, addr, 110)
  ffi.free(addr)
  if r != 0 {
    let _ = c_close(fd)
    return none
  }
  fd
}

/// Write all of `data` to `fd`.
pub fn fd_write(fd: int, data: [int]): bool uses ffi {
  let buf = ffi.from_bytes(data)
  var at = 0
  var ok = true
  while at < data.len() {
    let w = c_write(fd, ffi.offset(buf, at), data.len() - at)
    if w <= 0 {
      ok = false
      break
    }
    at += w
  }
  ffi.free(buf)
  ok
}

/// Wait up to `ms` for `fd` to be readable, then read what it has: none on timeout, `[]` at end
/// of file.
pub fn fd_read(fd: int, ms: int): [int]? uses ffi {
  let p = ffi.alloc(8)
  ffi.write_i32(p, 0, fd)
  ffi.write_i32(p, 4, 1)
  let r = c_poll(p, 1, max(0, ms))
  ffi.free(p)
  if r <= 0 { return none }
  read_some(fd) else []
}

pub fn fd_close(fd: int) uses ffi { let _ = c_close(fd) }

extern fn c_signal(sig: int, h: ffi.Ptr): ffi.Ptr = "void *signal(int, void *)"
extern fn c_chdir(p: str): int = "int chdir(const char *)"
extern fn c_getpid(): int = "int getpid(void)"
extern fn c_pipe(fds: ffi.Ptr): int = "int pipe(int *)"
extern fn c_close(fd: int): int = "int close(int)"
extern fn c_read(fd: int, buf: ffi.Ptr, n: int): int = "long read(int, void *, size_t)"
extern fn c_write(fd: int, buf: ffi.Ptr, n: int): int = "long write(int, const void *, size_t)"
extern fn c_poll(fds: ffi.Ptr, n: int, ms: int): int = "int poll(void *, unsigned int, int)"
extern fn c_ioctl(fd: int, req: int): int = "int ioctl(int, unsigned long)"
extern fn c_waitpid(pid: int, status: var int, flags: int): int = "int waitpid(int, int *, int)"
extern fn c_kill(pid: int, sig: int): int = "int kill(int, int)"
extern fn c_strerror(e: int): str = "char *strerror(int)"
extern fn c_socket(d: int, t: int, p: int): int = "int socket(int, int, int)"

extern fn c_connect(
  fd: int,
  addr: ffi.Ptr,
  n: int,
): int = "int connect(int, const void *, unsigned int)"

extern fn c_sigemptyset(s: ffi.Ptr): int = "int sigemptyset(void *)"
extern fn c_sigaddset(s: ffi.Ptr, sig: int): int = "int sigaddset(void *, int)"
extern fn c_fa_init(fa: ffi.Ptr): int = "int posix_spawn_file_actions_init(void *)"
extern fn c_fa_destroy(fa: ffi.Ptr): int = "int posix_spawn_file_actions_destroy(void *)"

extern fn c_fa_open(
  fa: ffi.Ptr,
  fd: int,
  path: str,
  flags: int,
  mode: int,
): int = "int posix_spawn_file_actions_addopen(void *, int, const char *, int, int)"

extern fn c_fa_dup2(
  fa: ffi.Ptr,
  fd: int,
  to: int,
): int = "int posix_spawn_file_actions_adddup2(void *, int, int)"

extern fn c_fa_chdir(
  fa: ffi.Ptr,
  dir: str,
): int = "int posix_spawn_file_actions_addchdir_np(void *, const char *)"

extern fn c_attr_init(a: ffi.Ptr): int = "int posix_spawnattr_init(void *)"
extern fn c_attr_destroy(a: ffi.Ptr): int = "int posix_spawnattr_destroy(void *)"
extern fn c_attr_flags(a: ffi.Ptr, flags: int): int = "int posix_spawnattr_setflags(void *, short)"
extern fn c_attr_pgroup(a: ffi.Ptr, g: int): int = "int posix_spawnattr_setpgroup(void *, int)"

extern fn c_attr_sigdefault(
  a: ffi.Ptr,
  s: ffi.Ptr,
): int = "int posix_spawnattr_setsigdefault(void *, const void *)"

extern fn c_spawnp(
  pid: var int,
  file: str,
  fa: ffi.Ptr,
  attr: ffi.Ptr,
  argv: ffi.Ptr,
  envp: ffi.Ptr,
): int = "int posix_spawnp(int *, const char *, void *, void *, void *, void *)"

/// Set an environment variable of this process (before any task starts).
pub fn setenv(k: str, v: str) uses ffi { let _ = c_setenv(k, v, 1) }

/// The number of CPUs online.
pub fn cpus(): int uses ffi = max(1, c_sysconf(if linux() { 84 } else { 58 }))

extern fn c_setenv(
  k: str,
  v: str,
  overwrite: int,
): int = "int setenv(const char *, const char *, int)"

extern fn c_sysconf(n: int): int = "long sysconf(int)"

/// An Err with message `msg` (for `t.fail`: t.auk's own `fail` shadows core's there, and
/// `core.fail(msg)` makes a typed error whose message is empty).
pub fn fail_with(msg: str): ()! = fail(msg)

/// An environment variable (C `getenv`; for helpers that use `ffi` but not `env`).
pub fn getenv(k: str): str? uses ffi = c_getenv(k)

extern fn c_getenv(k: str): str? = "char *getenv(const char *)"

/// The core library's `net` (was runtime/c/core.c, ported line by line): TCP connections
/// (getaddrinfo, connect), listeners (bind, listen, accept), reads and writes that wait for
/// the socket through the task scheduler (`auk__wait_fd`). tls.c (still C) makes its
/// connections through `auk__tcp_connect` and `auk__conn_new`, and `auk_conn_read`/`write`
/// hand a TLS connection to it.

// the rest of the runtime (C, for now)
extern fn auk__xmalloc(n: usize): raw.Ptr<()> = "void *auk__xmalloc(size_t)"
extern fn auk__alloc(size: usize, kind: u32): raw.Ptr<()> = "void *auk__alloc(size_t, uint32_t)"
extern fn auk__free_obj(p: raw.Ptr<()>) = "void auk__free_obj(void *)"
extern fn auk__wait_fd(fd: i32, write: bool) = "void auk__wait_fd(int, bool)"
extern fn auk__tls_read(tls: raw.Ptr<()>, max: i64): abi.ResArr = "AukRes_arr auk__tls_read(void *, int64_t)"
extern fn auk__tls_write(tls: raw.Ptr<()>, buf: raw.Ptr<u8>, n: i64): abi.ResUnit =
  "AukRes_unit auk__tls_write(void *, const uint8_t *, int64_t)"
extern fn auk__tls_free(tls: raw.Ptr<()>) = "void auk__tls_free(void *)"
extern fn c_fcntl(fd: i32, cmd: i32, ...): i32 = "int fcntl(int, int, ...)"
// libc
extern fn getaddrinfo(host: raw.Ptr<u8>, port: raw.Ptr<u8>, hints: raw.Ptr<cfacts.Addrinfo>, res: raw.Ptr<raw.Ptr<cfacts.Addrinfo>>): i32 =
  "int getaddrinfo(const char *, const char *, const void *, void *)"
extern fn freeaddrinfo(ai: raw.Ptr<cfacts.Addrinfo>) = "void freeaddrinfo(void *)"
extern fn gai_strerror(e: i32): raw.Ptr<u8> = "const char *gai_strerror(int)"
extern fn strerror(err: i32): raw.Ptr<u8> = "char *strerror(int)"
extern fn socket(family: i32, kind: i32, proto: i32): i32 = "int socket(int, int, int)"
extern fn connect(fd: i32, addr: raw.Ptr<cfacts.Sockaddr>, len: u32): i32 = "int connect(int, const void *, uint32_t)"
extern fn bind(fd: i32, addr: raw.Ptr<cfacts.Sockaddr>, len: u32): i32 = "int bind(int, const void *, uint32_t)"
extern fn listen(fd: i32, backlog: i32): i32 = "int listen(int, int)"
extern fn accept(fd: i32, addr: raw.Ptr<()>, len: raw.Ptr<u32>): i32 = "int accept(int, void *, uint32_t *)"
extern fn setsockopt(fd: i32, level: i32, name: i32, v: raw.Ptr<()>, len: u32): i32 =
  "int setsockopt(int, int, int, const void *, uint32_t)"
extern fn getsockname(fd: i32, addr: raw.Ptr<()>, len: raw.Ptr<u32>): i32 = "int getsockname(int, void *, uint32_t *)"
extern fn recv(fd: i32, buf: raw.Ptr<()>, n: usize, flags: i32): i64 = "ssize_t recv(int, void *, size_t, int)"
extern fn send(fd: i32, buf: raw.Ptr<()>, n: usize, flags: i32): i64 = "ssize_t send(int, const void *, size_t, int)"
extern fn close(fd: i32): i32 = "int close(int)"

/// Flags for send(2) on a connected socket: no SIGPIPE where the platform has MSG_NOSIGNAL (0
/// where it hasn't); elsewhere the socket carries SO_NOSIGPIPE. C: `const int` (dbg.c reads it).
pub export var auk__send_flags: i32 = cfacts.MSG_NOSIGNAL

fn conn_open(c: raw.Ptr<abi.Conn>): bool uses raw = !c.is_null() && (c.fd >= 0 || !c.tls.is_null())

/// Socket options every connected socket gets.
fn conn_sockopts(fd: i32) uses raw, ffi {
  if cfacts.HAS_SO_NOSIGPIPE {
    var one: i32 = 1
    setsockopt(fd, cfacts.SOL_SOCKET, cfacts.SO_NOSIGPIPE, raw.cast(raw.addr_of(&one)), 4)
  }
  let _ = c_fcntl(fd, cfacts.F_SETFD, cfacts.FD_CLOEXEC)
}

/// Resolve host:port and connect a TCP socket (with the connected-socket options set): the fd,
/// or -1 with the reason in *why (static text) and an errno in *err (0 for a DNS failure).
export fn auk__tcp_connect(host: raw.Ptr<u8>, port: raw.Ptr<u8>, why: raw.Ptr<raw.Ptr<u8>>, errp: raw.Ptr<i32>): i32 uses raw, ffi {
  var hints = cfacts.Addrinfo { ai_family: cfacts.AF_UNSPEC, ai_socktype: cfacts.SOCK_STREAM }
  var res: raw.Ptr<cfacts.Addrinfo> = raw.null()
  let gai = getaddrinfo(host, port, raw.addr_of(&hints), raw.addr_of(&res))
  if gai != 0 {
    why.store(gai_strerror(gai))
    errp.store(0)
    return -1
  }
  var fd: i32 = -1
  var e: i32 = 0
  var ai = res
  while !ai.is_null() {
    fd = socket(ai.ai_family, ai.ai_socktype, ai.ai_protocol)
    if fd < 0 {
      e = cfacts.errno()
    } else {
      var rc = connect(fd, ai.ai_addr, ai.ai_addrlen)
      while rc < 0 && cfacts.errno() == cfacts.EINTR {
        rc = connect(fd, ai.ai_addr, ai.ai_addrlen)
      }
      if rc == 0 {
        break
      }
      e = cfacts.errno()
      close(fd)
      fd = -1
    }
    ai = ai.ai_next
  }
  freeaddrinfo(res)
  if fd < 0 {
    why.store(strerror(e))
    errp.store(e)
    return -1
  }
  conn_sockopts(fd)
  fd
}

/// A new open AukConn over fd.
export fn auk__conn_new(fd: i32): raw.Ptr<abi.Conn> uses raw, ffi {
  let c: raw.Ptr<abi.Conn> = raw.cast(auk__alloc(raw.size_of<abi.Conn>(), abi.K_CONN))
  c.fd = fd
  c
}

fn conn_err(e: raw.Ptr<abi.Err>): abi.ResConn = abi.ResConn { err: e }

/// "<what> <host>:<port>: " into m.
fn host_port(m: raw.Ptr<abi.StrBuf>, what: raw.Ptr<u8>, host: raw.Ptr<abi.Str>, port: i64) uses raw, ffi {
  str.auk__sb_put_cstr(m, what)
  str.auk__sb_put_cstr(m, " ")
  str.auk__sb_put_cstr(m, str.auk_str_cstr(host))
  str.auk__sb_put_cstr(m, ":")
  str_fmt.auk_sb_int(m, port)
  str.auk__sb_put_cstr(m, ": ")
}

/// A port's decimal digits (C's `char ports[24]`).
raw struct PortBuf {
  b: [u8; 24],
}

export fn auk_net_tcp(host: raw.Ptr<abi.Str>, port: i64): abi.ResConn uses raw, ffi {
  var m = abi.StrBuf {}
  let mp = raw.addr_of(&m)
  host_port(mp, "net.tcp", host, port)
  if port < 0 || port > 65535 {
    str.auk__sb_put_cstr(mp, "invalid port")
    return conn_err(str.auk__err_sb(mp))
  }
  var pb = PortBuf {}
  let ports: raw.Ptr<u8> = raw.cast(raw.addr_of(&pb))
  str_fmt.auk__fmt_i64(ports, port)
  var why: raw.Ptr<u8> = raw.null()
  var code: i32 = 0
  let fd = auk__tcp_connect(str.auk_str_cstr(host), ports, raw.addr_of(&why), raw.addr_of(&code))
  if fd < 0 {
    str.auk__sb_put_cstr(mp, why)
    return conn_err(if code != 0 { core_util.err_code_sb(mp, code) } else { str.auk__err_sb(mp) })
  }
  str.auk_sb_free(mp)
  abi.ResConn { ok: true, val: auk__conn_new(fd) }
}

export fn auk__listener_free(l: raw.Ptr<abi.Listener>) uses raw, ffi {
  auk_listener_close(l)
  auk__free_obj(raw.cast(l))
}

fn listener_err(e: raw.Ptr<abi.Err>): abi.ResListener = abi.ResListener { err: e }

export fn auk_net_listen(host: raw.Ptr<abi.Str>, port: i64): abi.ResListener uses raw, ffi {
  let h = str.auk_str_cstr(host)
  var m = abi.StrBuf {}
  let mp = raw.addr_of(&m)
  host_port(mp, "net.listen", host, port)
  if port < 0 || port > 65535 {
    str.auk__sb_put_cstr(mp, "invalid port")
    return listener_err(str.auk__err_sb(mp))
  }
  var pb = PortBuf {}
  let ports: raw.Ptr<u8> = raw.cast(raw.addr_of(&pb))
  str_fmt.auk__fmt_i64(ports, port)
  var hints = cfacts.Addrinfo {
    ai_family: cfacts.AF_UNSPEC,
    ai_socktype: cfacts.SOCK_STREAM,
    ai_flags: cfacts.AI_PASSIVE,
  }
  var res: raw.Ptr<cfacts.Addrinfo> = raw.null()
  let gai = getaddrinfo(if h.at(0) != 0 { h } else { raw.null() }, ports, raw.addr_of(&hints), raw.addr_of(&res))
  if gai != 0 {
    str.auk__sb_put_cstr(mp, gai_strerror(gai))
    return listener_err(str.auk__err_sb(mp))
  }
  var fd: i32 = -1
  var e: i32 = 0
  var ai = res
  while !ai.is_null() {
    fd = socket(ai.ai_family, ai.ai_socktype, ai.ai_protocol)
    if fd < 0 {
      e = cfacts.errno()
    } else {
      var one: i32 = 1
      setsockopt(fd, cfacts.SOL_SOCKET, cfacts.SO_REUSEADDR, raw.cast(raw.addr_of(&one)), 4)
      if bind(fd, ai.ai_addr, ai.ai_addrlen) == 0 && listen(fd, 128) == 0 {
        break
      }
      e = cfacts.errno()
      close(fd)
      fd = -1
    }
    ai = ai.ai_next
  }
  freeaddrinfo(res)
  if fd < 0 {
    str.auk__sb_put_cstr(mp, strerror(e))
    return listener_err(core_util.err_code_sb(mp, e))
  }
  str.auk_sb_free(mp)
  let _ = c_fcntl(fd, cfacts.F_SETFD, cfacts.FD_CLOEXEC)
  var ss = cfacts.SockaddrStorage {}
  var len: u32 = u32(raw.size_of<cfacts.SockaddrStorage>())
  var bound = port
  if getsockname(fd, raw.cast(raw.addr_of(&ss)), raw.addr_of(&len)) == 0 {
    let fam = i32(ss.ss_family)
    if fam == cfacts.AF_INET {
      let sin: raw.Ptr<cfacts.SockaddrIn> = raw.cast(raw.addr_of(&ss))
      bound = i64(raw.bswap(sin.sin_port)) // ntohs
    } else if fam == cfacts.AF_INET6 {
      let sin6: raw.Ptr<cfacts.SockaddrIn6> = raw.cast(raw.addr_of(&ss))
      bound = i64(raw.bswap(sin6.sin6_port))
    }
  }
  let l: raw.Ptr<abi.Listener> = raw.cast(auk__alloc(raw.size_of<abi.Listener>(), abi.K_LISTENER))
  l.fd = fd
  l.port = bound
  abi.ResListener { ok: true, val: l }
}

export fn auk_listener_accept(l: raw.Ptr<abi.Listener>): abi.ResConn uses raw, ffi {
  if l.is_null() || l.fd < 0 {
    return conn_err(err.auk_err_new_cstr("net accept: listener is closed"))
  }
  var fd: i32 = -1
  loop {
    auk__wait_fd(l.fd, false)
    fd = accept(l.fd, raw.null(), raw.null())
    if fd >= 0 {
      break
    }
    let e = cfacts.errno()
    if e != cfacts.EINTR && e != cfacts.ECONNABORTED {
      break
    }
  }
  if fd < 0 {
    return conn_err(err.auk__err_errno("net accept", raw.null(), cfacts.errno()))
  }
  conn_sockopts(fd)
  abi.ResConn { ok: true, val: auk__conn_new(fd) }
}

export fn auk_listener_port(l: raw.Ptr<abi.Listener>): i64 uses raw = if l.is_null() { 0 } else { l.port }

export fn auk_listener_close(l: raw.Ptr<abi.Listener>) uses raw, ffi {
  if !l.is_null() && l.fd >= 0 {
    close(l.fd)
    l.fd = -1
  }
}

export fn auk_conn_read(c: raw.Ptr<abi.Conn>, max0: i64): abi.ResArr uses raw, ffi {
  if !conn_open(c) {
    return core_util.arr_err(err.auk_err_new_cstr("net read: connection is closed"))
  }
  if max0 <= 0 {
    return core_util.arr_err(err.auk_err_new_cstr("net read: max must be positive"))
  }
  let max: i64 = if max0 > 16777216 { 16777216 } else { max0 } // 1 << 24
  if !c.tls.is_null() {
    return auk__tls_read(c.tls, max)
  }
  let buf: raw.Ptr<u8> = raw.cast(auk__xmalloc(usize(max)))
  var n: i64 = 0
  loop {
    auk__wait_fd(c.fd, false)
    n = recv(c.fd, raw.cast(buf), usize(max), 0)
    if n >= 0 || cfacts.errno() != cfacts.EINTR {
      break
    }
  }
  if n < 0 {
    let e = cfacts.errno()
    raw.free(buf)
    return core_util.arr_err(err.auk__err_errno("net read", raw.null(), e))
  }
  let a = core_util.auk__bytes_to_arr(buf, n)
  raw.free(buf)
  core_util.arr_ok(a)
}

export fn auk_conn_write(c: raw.Ptr<abi.Conn>, bytes: raw.Ptr<abi.Arr>): abi.ResUnit uses raw, ffi {
  if !conn_open(c) {
    return core_util.unit_err(err.auk_err_new_cstr("net write: connection is closed"))
  }
  var n: i64 = 0
  var bad_i: i64 = 0
  var bad_x: i64 = 0
  let buf = core_util.arr_to_bytes(bytes, raw.addr_of(&n), raw.addr_of(&bad_i), raw.addr_of(&bad_x))
  if buf.is_null() {
    var m = abi.StrBuf {}
    let mp = raw.addr_of(&m)
    str.auk__sb_put_cstr(mp, "net write: byte ")
    str_fmt.auk_sb_int(mp, bad_x)
    str.auk__sb_put_cstr(mp, " out of range 0..255")
    return core_util.unit_err(str.auk__err_sb(mp))
  }
  if !c.tls.is_null() {
    let r = auk__tls_write(c.tls, buf, n)
    raw.free(buf)
    return r
  }
  var off: i64 = 0
  while off < n {
    auk__wait_fd(c.fd, true)
    let w = send(c.fd, raw.cast(buf.offset(off)), usize(n - off), auk__send_flags)
    if w < 0 {
      let e = cfacts.errno()
      if e != cfacts.EINTR {
        raw.free(buf)
        return core_util.unit_err(err.auk__err_errno("net write", raw.null(), e))
      }
    } else {
      off += w
    }
  }
  raw.free(buf)
  core_util.unit_ok()
}

export fn auk_conn_close(c: raw.Ptr<abi.Conn>) uses raw, ffi {
  if !c.is_null() && !c.tls.is_null() {
    auk__tls_free(c.tls) // before the socket closes: it may send close_notify
    c.tls = raw.null()
  }
  if !c.is_null() && c.fd >= 0 {
    close(c.fd)
    c.fd = -1
  }
}

export fn auk__conn_free(c: raw.Ptr<abi.Conn>) uses raw, ffi {
  auk_conn_close(c)
  auk__free_obj(raw.cast(c))
}

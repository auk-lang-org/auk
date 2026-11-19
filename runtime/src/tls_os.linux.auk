/// TLS sessions on Linux: OpenSSL through dlopen (was the `#else` half of runtime/c/tls.c, ported
/// line by line; tls.auk has the overview and the shared checks). libssl (and, through its
/// dependencies, libcrypto) is loaded on first use, so nothing is needed at build time; its
/// entry points are a table of function pointers filled with dlsym.

// the rest of the runtime (C, for now)
extern fn auk__wait_fd(fd: i32, write: bool) = "void auk__wait_fd(int, bool)"
extern fn auk__tcp_connect(host: raw.Ptr<u8>, port: raw.Ptr<u8>, why: raw.Ptr<raw.Ptr<u8>>, code: raw.Ptr<i32>): i32 =
  "int auk__tcp_connect(const char *, const char *, void *, void *)"
extern fn auk__conn_new(fd: i32): raw.Ptr<abi.Conn> = "void *auk__conn_new(int)"
extern fn auk__bytes_to_arr(b: raw.Ptr<u8>, n: i64): raw.Ptr<abi.Arr> = "void *auk__bytes_to_arr(const uint8_t *, int64_t)"
extern fn auk_release(p: raw.Ptr<()>) = "void auk_release(void *)"
// libc
extern fn strerror(e: i32): raw.Ptr<u8> = "char *strerror(int)"
extern fn close(fd: i32): i32 = "int close(int)"
extern fn dlopen(name: raw.Ptr<u8>, mode: i32): raw.Ptr<()> = "void *dlopen(const char *, int)"
extern fn dlsym(lib: raw.Ptr<()>, name: raw.Ptr<u8>): raw.Ptr<()> = "void *dlsym(void *, const char *)"
extern fn pthread_once(once: raw.Ptr<cfacts.PthreadOnce>, init: raw.Ptr<()>): i32 = "int pthread_once(void *, void *)"

/// The libssl (and libcrypto) entry points used here (OpenSSL's names after the `_`).
raw struct SslApi {
  tls_client_method: raw.Fn<() => raw.Ptr<()>>,
  ssl_ctx_new: raw.Fn<(raw.Ptr<()>) => raw.Ptr<()>>,
  ssl_ctx_set_default_verify_paths: raw.Fn<(raw.Ptr<()>) => i32>,
  ssl_ctx_set_verify: raw.Fn<(raw.Ptr<()>, i32, raw.Ptr<()>) => ()>,
  ssl_ctx_ctrl: raw.Fn<(raw.Ptr<()>, i32, i64, raw.Ptr<()>) => i64>,
  ssl_new: raw.Fn<(raw.Ptr<()>) => raw.Ptr<()>>,
  ssl_free: raw.Fn<(raw.Ptr<()>) => ()>,
  ssl_set_fd: raw.Fn<(raw.Ptr<()>, i32) => i32>,
  ssl_ctrl: raw.Fn<(raw.Ptr<()>, i32, i64, raw.Ptr<()>) => i64>,
  ssl_set1_host: raw.Fn<(raw.Ptr<()>, raw.Ptr<u8>) => i32>,
  ssl_connect: raw.Fn<(raw.Ptr<()>) => i32>,
  ssl_read: raw.Fn<(raw.Ptr<()>, raw.Ptr<u8>, i32) => i32>,
  ssl_write: raw.Fn<(raw.Ptr<()>, raw.Ptr<u8>, i32) => i32>,
  ssl_shutdown: raw.Fn<(raw.Ptr<()>) => i32>,
  ssl_get_error: raw.Fn<(raw.Ptr<()>, i32) => i32>,
  ssl_get_verify_result: raw.Fn<(raw.Ptr<()>) => i64>,
  x509_verify_cert_error_string: raw.Fn<(i64) => raw.Ptr<u8>>,
  err_get_error: raw.Fn<() => u64>,
  err_peek_error: raw.Fn<() => u64>,
  err_error_string_n: raw.Fn<(u64, raw.Ptr<u8>, usize) => ()>,
  err_clear_error: raw.Fn<() => ()>,
}

raw var ssl: SslApi = SslApi {}
raw var ssl_ctx: raw.Ptr<()> = raw.null()
raw var ssl_unavailable: raw.Ptr<u8> = raw.null()
raw var ssl_once: cfacts.PthreadOnce = cfacts.PTHREAD_ONCE_INIT

// OpenSSL's constants
raw let SSL_VERIFY_PEER: i32 = 1
raw let SSL_CTRL_SET_MIN_PROTO_VERSION: i32 = 123
raw let SSL_CTRL_SET_TLSEXT_HOSTNAME: i32 = 55
raw let SSL_CTRL_SET_GROUPS_LIST: i32 = 92
raw let SSL_R_UNEXPECTED_EOF_WHILE_READING: u64 = 294
raw let TLSEXT_NAMETYPE_HOST_NAME: i64 = 0
raw let TLS1_2_VERSION: i64 = 771 // 0x0303
raw let SSL_ERROR_SSL: i32 = 1
raw let SSL_ERROR_WANT_READ: i32 = 2
raw let SSL_ERROR_WANT_WRITE: i32 = 3
raw let SSL_ERROR_SYSCALL: i32 = 5
raw let SSL_ERROR_ZERO_RETURN: i32 = 6
raw let X509_V_OK: i64 = 0
raw let X509_V_ERR_CERT_NOT_YET_VALID: i64 = 9
raw let X509_V_ERR_CERT_HAS_EXPIRED: i64 = 10
raw let X509_V_ERR_DEPTH_ZERO_SELF_SIGNED_CERT: i64 = 18
raw let X509_V_ERR_SELF_SIGNED_CERT_IN_CHAIN: i64 = 19
raw let X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT_LOCALLY: i64 = 20
raw let X509_V_ERR_CERT_REVOKED: i64 = 23
raw let X509_V_ERR_INVALID_PURPOSE: i64 = 26
raw let X509_V_ERR_HOSTNAME_MISMATCH: i64 = 62
raw let X509_V_ERR_IP_ADDRESS_MISMATCH: i64 = 64

// The calls through the table (a function pointer in a global's field is called from a local).

fn ssl_get_error(s: raw.Ptr<()>, ret: i32): i32 uses raw {
  let f = ssl.ssl_get_error
  f(s, ret)
}

fn ssl_get_verify_result(s: raw.Ptr<()>): i64 uses raw {
  let f = ssl.ssl_get_verify_result
  f(s)
}

fn ssl_ctrl(s: raw.Ptr<()>, cmd: i32, larg: i64, parg: raw.Ptr<()>): i64 uses raw {
  let f = ssl.ssl_ctrl
  f(s, cmd, larg, parg)
}

fn ssl_free(s: raw.Ptr<()>) uses raw {
  let f = ssl.ssl_free
  f(s)
}

fn sym(lib: raw.Ptr<()>, name: raw.Ptr<u8>, ok: raw.Ptr<bool>): raw.Ptr<()> uses raw, ffi {
  let p = dlsym(lib, name)
  if p.is_null() {
    ok.store(false)
  }
  p
}

/// The names ssl_load tries, in order.
fn lib_name(i: i32): raw.Ptr<u8> {
  if i == 0 {
    "libssl.so.3"
  } else if i == 1 {
    "libssl.so.1.1"
  } else if i == 2 {
    "libssl.so"
  } else {
    "libssl.3.dylib"
  }
}

/// pthread_once's initializer: load libssl and make the shared context.
fn ssl_load() uses raw, ffi {
  var lib: raw.Ptr<()> = raw.null()
  var i: i32 = 0
  while i < 4 && lib.is_null() {
    lib = dlopen(lib_name(i), cfacts.RTLD_NOW | cfacts.RTLD_LOCAL)
    i += 1
  }
  if lib.is_null() {
    ssl_unavailable = "tls unavailable: libssl not found"
    return
  }
  var ok = true
  let okp = raw.addr_of(&ok)
  let api = raw.addr_of(&ssl)
  api.tls_client_method = raw.cast(sym(lib, "TLS_client_method", okp))
  api.ssl_ctx_new = raw.cast(sym(lib, "SSL_CTX_new", okp))
  api.ssl_ctx_set_default_verify_paths = raw.cast(sym(lib, "SSL_CTX_set_default_verify_paths", okp))
  api.ssl_ctx_set_verify = raw.cast(sym(lib, "SSL_CTX_set_verify", okp))
  api.ssl_ctx_ctrl = raw.cast(sym(lib, "SSL_CTX_ctrl", okp))
  api.ssl_new = raw.cast(sym(lib, "SSL_new", okp))
  api.ssl_free = raw.cast(sym(lib, "SSL_free", okp))
  api.ssl_set_fd = raw.cast(sym(lib, "SSL_set_fd", okp))
  api.ssl_ctrl = raw.cast(sym(lib, "SSL_ctrl", okp))
  api.ssl_set1_host = raw.cast(sym(lib, "SSL_set1_host", okp))
  api.ssl_connect = raw.cast(sym(lib, "SSL_connect", okp))
  api.ssl_read = raw.cast(sym(lib, "SSL_read", okp))
  api.ssl_write = raw.cast(sym(lib, "SSL_write", okp))
  api.ssl_shutdown = raw.cast(sym(lib, "SSL_shutdown", okp))
  api.ssl_get_error = raw.cast(sym(lib, "SSL_get_error", okp))
  api.ssl_get_verify_result = raw.cast(sym(lib, "SSL_get_verify_result", okp))
  api.x509_verify_cert_error_string = raw.cast(sym(lib, "X509_verify_cert_error_string", okp))
  api.err_get_error = raw.cast(sym(lib, "ERR_get_error", okp))
  api.err_peek_error = raw.cast(sym(lib, "ERR_peek_error", okp))
  api.err_error_string_n = raw.cast(sym(lib, "ERR_error_string_n", okp))
  api.err_clear_error = raw.cast(sym(lib, "ERR_clear_error", okp))
  if !ok {
    ssl_unavailable = "tls unavailable: libssl is missing functions (OpenSSL 1.1 or later is needed)"
    return
  }
  let method = api.tls_client_method
  let ctx_new = api.ssl_ctx_new
  let verify_paths = api.ssl_ctx_set_default_verify_paths
  ssl_ctx = ctx_new(method())
  if ssl_ctx.is_null() || verify_paths(ssl_ctx) != 1 {
    ssl_unavailable = "tls unavailable: cannot set up OpenSSL"
    return
  }
  let set_verify = api.ssl_ctx_set_verify
  set_verify(ssl_ctx, SSL_VERIFY_PEER, raw.null())
  let ctx_ctrl = api.ssl_ctx_ctrl
  let _ = ctx_ctrl(ssl_ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_2_VERSION, raw.null())
}

fn x509_reason(v: i64): raw.Ptr<u8> uses raw {
  if v == X509_V_ERR_CERT_HAS_EXPIRED {
    "certificate has expired"
  } else if v == X509_V_ERR_CERT_NOT_YET_VALID {
    "certificate is not yet valid"
  } else if v == X509_V_ERR_CERT_REVOKED {
    "certificate has been revoked"
  } else if v == X509_V_ERR_DEPTH_ZERO_SELF_SIGNED_CERT || v == X509_V_ERR_SELF_SIGNED_CERT_IN_CHAIN ||
    v == X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT_LOCALLY {
    "certificate is not trusted (self-signed or no trusted root)"
  } else if v == X509_V_ERR_HOSTNAME_MISMATCH || v == X509_V_ERR_IP_ADDRESS_MISMATCH {
    "certificate does not match the host name"
  } else if v == X509_V_ERR_INVALID_PURPOSE {
    "certificate is not valid for a TLS server"
  } else {
    let f = ssl.x509_verify_cert_error_string
    f(v)
  }
}

raw struct SslTls {
  s: raw.Ptr<()>,
  fd: i32,
  eof: bool,
}

/// C's `char buf[256]` (an OpenSSL error string).
raw struct Buf256 {
  b: [u8; 256],
}

/// An Err for a failed SSL call (ret, from SSL_get_error) after "<prefix>"; prefix consumed.
fn ssl_err(prefix: raw.Ptr<abi.StrBuf>, s: raw.Ptr<()>, ret: i32, saved_errno: i32): raw.Ptr<abi.Err> uses raw, ffi {
  let e = ssl_get_error(s, ret)
  if e == SSL_ERROR_SYSCALL && saved_errno != 0 {
    return tls.prefixed(prefix, ": ", strerror(saved_errno), saved_errno)
  }
  if e == SSL_ERROR_SYSCALL || e == SSL_ERROR_ZERO_RETURN {
    return tls.prefixed(prefix, ": TLS error: the connection closed during the handshake", raw.null(), 0)
  }
  let v = ssl_get_verify_result(s)
  if v != X509_V_OK {
    return tls.prefixed(prefix, ": certificate verification failed: ", x509_reason(v), 0)
  }
  let get_error = ssl.err_get_error
  let code = get_error()
  var buf = Buf256 {}
  let b: raw.Ptr<u8> = raw.cast(raw.addr_of(&buf))
  let protocol_error: raw.Ptr<u8> = "protocol error"
  raw.copy(b, protocol_error, 15)
  if code != 0 {
    let error_string = ssl.err_error_string_n
    error_string(code, b, raw.size_of<Buf256>())
  }
  tls.prefixed(prefix, ": TLS error: ", b, 0)
}

raw let DRIVE_CONNECT: i32 = 0
raw let DRIVE_READ: i32 = 1
raw let DRIVE_WRITE: i32 = 2

/// Run op (connect, read or write) on t until it stops wanting I/O; its result, or -1 with *saved
/// the errno.
fn ssl_drive(t: raw.Ptr<SslTls>, which: i32, buf: raw.Ptr<u8>, n: i32, saved: raw.Ptr<i32>): i32 uses raw, ffi {
  let clear = ssl.err_clear_error
  let connect = ssl.ssl_connect
  let read = ssl.ssl_read
  let write = ssl.ssl_write
  loop {
    clear()
    cfacts.set_errno(0)
    let r = if which == DRIVE_CONNECT { connect(t.s) } else if which == DRIVE_READ { read(t.s, buf, n) } else { write(t.s, buf, n) }
    saved.store(cfacts.errno())
    if r > 0 {
      return r
    }
    let e = ssl_get_error(t.s, r)
    if e == SSL_ERROR_WANT_READ {
      auk__wait_fd(t.fd, false)
    } else if e == SSL_ERROR_WANT_WRITE {
      auk__wait_fd(t.fd, true)
    } else if !(e == SSL_ERROR_SYSCALL && saved.load() == cfacts.EINTR) {
      return r
    }
  }
}

/// A connected, handshaken session, or null with *err_out. classic: offer only classical key
/// exchange groups (see auk_net_tls). *retry says the handshake ended in an EOF or reset before
/// any certificate verdict, which a classical retry may get past.
fn ssl_open(h: raw.Ptr<u8>, ports: raw.Ptr<u8>, port: i64, classic: bool, err_out: raw.Ptr<raw.Ptr<abi.Err>>, retry: raw.Ptr<bool>): raw.Ptr<SslTls> uses raw, ffi {
  retry.store(false)
  var why: raw.Ptr<u8> = raw.null()
  var code: i32 = 0
  let fd = auk__tcp_connect(h, ports, raw.addr_of(&why), raw.addr_of(&code))
  if fd < 0 {
    err_out.store(tls.host_err(h, port, ": ", why, code))
    return raw.null()
  }
  let t: raw.Ptr<SslTls> = raw.cast(raw.alloc(raw.size_of<SslTls>()))
  raw.fill(t, 0, raw.size_of<SslTls>())
  t.fd = fd
  let new_ssl = ssl.ssl_new
  t.s = new_ssl(ssl_ctx)
  let set_fd = ssl.ssl_set_fd
  let _ = set_fd(t.s, fd)
  if classic {
    let groups: raw.Ptr<u8> = "X25519:P-256:P-384"
    let _ = ssl_ctrl(t.s, SSL_CTRL_SET_GROUPS_LIST, 0, raw.cast(groups))
  }
  if !tls.is_ip(h) {
    // SNI for DNS names only
    let _ = ssl_ctrl(t.s, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_HOST_NAME, raw.cast(h))
  }
  let set1_host = ssl.ssl_set1_host
  let _ = set1_host(t.s, h)
  var saved: i32 = 0
  let r = ssl_drive(t, DRIVE_CONNECT, raw.null(), 0, raw.addr_of(&saved))
  if r > 0 {
    return t
  }
  let e = ssl_get_error(t.s, r)
  let peek = ssl.err_peek_error
  let top = peek()
  let eof = e == SSL_ERROR_SYSCALL || (e == SSL_ERROR_SSL && (top & 4095) == SSL_R_UNEXPECTED_EOF_WHILE_READING)
  retry.store(eof && ssl_get_verify_result(t.s) == X509_V_OK && (saved == 0 || saved == cfacts.ECONNRESET))
  var m = abi.StrBuf {}
  tls.tls_prefix(raw.addr_of(&m), h, port)
  err_out.store(ssl_err(raw.addr_of(&m), t.s, r, saved))
  ssl_free(t.s)
  let _ = close(fd)
  raw.free(t)
  raw.null()
}

pub export fn auk_net_tls(host: raw.Ptr<abi.Str>, port: i64): abi.ResConn uses raw, ffi {
  let h = str.auk_str_cstr(host)
  let bad = tls.check_args(h, port)
  if !bad.is_null() {
    return tls.conn_err(bad)
  }
  let _ = pthread_once(raw.addr_of(&ssl_once), raw.cast(raw.fn_of(ssl_load)))
  if !ssl_unavailable.is_null() {
    return tls.conn_err(tls.host_err(h, port, ": ", ssl_unavailable, 0))
  }
  var ports_buf = tls.Buf24 {}
  let ports: raw.Ptr<u8> = raw.cast(raw.addr_of(&ports_buf))
  let _ = str_fmt.auk__fmt_i64(ports, port)
  var e: raw.Ptr<abi.Err> = raw.null()
  var retry = false
  var t = ssl_open(h, ports, port, false, raw.addr_of(&e), raw.addr_of(&retry))
  if t.is_null() && retry {
    // Some servers (TLS 1.2-only ones among them) drop a ClientHello that offers a post-quantum
    // key share (X25519MLKEM768, OpenSSL 3.5's default): it spans two TCP segments. An EOF or
    // reset before any certificate verdict gets one more try offering only classical groups,
    // still TLS 1.3 when the server has it, with full verification.
    auk_release(raw.cast(e))
    t = ssl_open(h, ports, port, true, raw.addr_of(&e), raw.addr_of(&retry))
  }
  if t.is_null() {
    return tls.conn_err(e)
  }
  let c = auk__conn_new(t.fd)
  c.tls = raw.cast(t)
  abi.ResConn { ok: true, val: c }
}

fn empty_arr(): abi.ResArr uses raw, ffi = abi.ResArr { ok: true, val: auk__bytes_to_arr(raw.null(), 0) }

pub export fn auk__tls_read(p: raw.Ptr<()>, max: i64): abi.ResArr uses raw, ffi {
  let t: raw.Ptr<SslTls> = raw.cast(p)
  if t.eof {
    return empty_arr()
  }
  let buf: raw.Ptr<u8> = raw.cast(raw.alloc(if max > 0 { max } else { 1 }))
  var saved: i32 = 0
  let r = ssl_drive(t, DRIVE_READ, buf, i32(max), raw.addr_of(&saved))
  if r <= 0 {
    let e = ssl_get_error(t.s, r)
    let res = if e == SSL_ERROR_ZERO_RETURN || (e == SSL_ERROR_SYSCALL && saved == 0) {
      // close_notify, or the peer closed the stream without one: EOF
      t.eof = true
      empty_arr()
    } else if e == SSL_ERROR_SYSCALL {
      abi.ResArr { err: tls.errno_err("net read", saved) }
    } else {
      var m = abi.StrBuf {}
      str.auk__sb_put_cstr(raw.addr_of(&m), "net read")
      abi.ResArr { err: ssl_err(raw.addr_of(&m), t.s, r, saved) }
    }
    raw.free(buf)
    return res
  }
  let res = abi.ResArr { ok: true, val: auk__bytes_to_arr(buf, i64(r)) }
  raw.free(buf)
  res
}

pub export fn auk__tls_write(p: raw.Ptr<()>, buf: raw.Ptr<u8>, n: i64): abi.ResUnit uses raw, ffi {
  let t: raw.Ptr<SslTls> = raw.cast(p)
  var off: i64 = 0
  while off < n {
    let chunk: i32 = if n - off > 1073741824 { 1073741824 } else { i32(n - off) }
    var saved: i32 = 0
    let r = ssl_drive(t, DRIVE_WRITE, buf.offset(off), chunk, raw.addr_of(&saved))
    if r <= 0 {
      if ssl_get_error(t.s, r) == SSL_ERROR_SYSCALL && saved != 0 {
        return abi.ResUnit { err: tls.errno_err("net write", saved) }
      }
      var m = abi.StrBuf {}
      str.auk__sb_put_cstr(raw.addr_of(&m), "net write")
      return abi.ResUnit { err: ssl_err(raw.addr_of(&m), t.s, r, saved) }
    }
    off += i64(r)
  }
  abi.ResUnit { ok: true }
}

/// Closes the session (best-effort close_notify; the caller then closes the socket) and frees it.
pub export fn auk__tls_free(p: raw.Ptr<()>) uses raw, ffi {
  let t: raw.Ptr<SslTls> = raw.cast(p)
  if t.is_null() {
    return
  }
  let shutdown = ssl.ssl_shutdown
  let _ = shutdown(t.s)
  ssl_free(t.s)
  raw.free(t)
}

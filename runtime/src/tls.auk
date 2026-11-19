/// TLS client sessions for `net.tls`: what every platform shares (was the top of runtime/c/tls.c,
/// ported line by line). The sessions themselves are `tls_os.<os>.auk`, which defines the
/// entry points (`auk_net_tls`, `auk__tls_read`, `auk__tls_write`, `auk__tls_free`):
///  - macOS (`tls_os.macos.auk`): Network.framework (an nw_connection with TLS 1.2 or later),
///    wrapped synchronously with dispatch semaphores to fit the blocking connection API (a task
///    is a thread). Waits wake every 50 ms so a cancelled task still ends. The certificate check
///    is the system's own trust evaluation (Security.framework, an SSL policy for the host), run
///    in a verify block so the reason for a refusal can be reported. A connection reset before
///    the server's certificate arrived is retried once as a TLS 1.2 fallback. The blocks are
///    built by hand (docs/lowlevel.md, section 10).
///  - Linux (`tls_os.linux.auk`): OpenSSL 3 or 1.1 (libssl), loaded with dlopen on first use, so
///    nothing is needed at build time. Without libssl at run time, net.tls is an Err ("tls
///    unavailable: libssl not found").
///
/// Verification is always on and cannot be turned off: the server's chain is checked against
/// the system trust store and its certificate against host (SNI is sent for DNS names). A
/// failure is an Err "net.tls <host>:<port>: certificate verification failed: <reason>".

extern fn inet_pton(af: i32, src: raw.Ptr<u8>, dst: raw.Ptr<()>): i32 = "int inet_pton(int, const char *, void *)"
extern fn strlen(s: raw.Ptr<u8>): usize = "size_t strlen(const char *)"

/// C's `unsigned char addr[16]` (inet_pton's output).
raw struct Addr16 {
  b: [u8; 16],
}

/// C's `char ports[24]` (a port number as text).
pub raw struct Buf24 {
  b: [u8; 24],
}

/// "net.tls <host>:<port>" into m.
pub fn tls_prefix(m: raw.Ptr<abi.StrBuf>, host: raw.Ptr<u8>, port: i64) uses raw, ffi {
  str.auk__sb_put_cstr(m, "net.tls ")
  str.auk__sb_put_cstr(m, host)
  str.auk__sb_put_cstr(m, ":")
  str_fmt.auk_sb_int(m, port)
}

/// An Err "<prefix><a><b>" (prefix consumed), with code (0: none). b may be null.
pub fn prefixed(prefix: raw.Ptr<abi.StrBuf>, a: raw.Ptr<u8>, b: raw.Ptr<u8>, code: i32): raw.Ptr<abi.Err> uses raw, ffi {
  str.auk__sb_put_cstr(prefix, a)
  if !b.is_null() {
    str.auk__sb_put_cstr(prefix, b)
  }
  let e = str.auk__err_sb(prefix)
  e.code = i64(code)
  e
}

/// "<prefix of host:port><a><b>" as an Err.
pub fn host_err(host: raw.Ptr<u8>, port: i64, a: raw.Ptr<u8>, b: raw.Ptr<u8>, code: i32): raw.Ptr<abi.Err> uses raw, ffi {
  var m = abi.StrBuf {}
  tls_prefix(raw.addr_of(&m), host, port)
  prefixed(raw.addr_of(&m), a, b, code)
}

pub fn conn_err(e: raw.Ptr<abi.Err>): abi.ResConn = abi.ResConn { err: e }

/// Is h an IPv4 or IPv6 address?
pub fn is_ip(h: raw.Ptr<u8>): bool uses raw, ffi {
  var addr = Addr16 {}
  inet_pton(cfacts.AF_INET, h, raw.cast(raw.addr_of(&addr))) == 1 ||
    inet_pton(cfacts.AF_INET6, h, raw.cast(raw.addr_of(&addr))) == 1
}

/// Is host a name a certificate can be checked against: an IP address, or a DNS name (labels of
/// letters, digits, '-' and '_', 1 to 63 long, not starting or ending with '-'; at most 253 in
/// all; one trailing dot allowed)?
fn valid_host(h: raw.Ptr<u8>): bool uses raw, ffi {
  if is_ip(h) {
    return true
  }
  var n = strlen(h)
  if n > 0 && h.at(n - 1) == 46 { // '.'
    n -= 1
  }
  if n == 0 || n > 253 {
    return false
  }
  var label: usize = 0
  var i: usize = 0
  while i <= n {
    let c: u8 = if i < n { h.at(i) } else { 46 }
    i += 1
    if c == 46 {
      if label == 0 || label > 63 || h.at(i - 2) == 45 { // '-'
        return false
      }
      label = 0
    } else {
      let ok = (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) || c == 95 || c == 45
      if !ok || (label == 0 && c == 45) {
        return false
      }
      label += 1
    }
  }
  true
}

/// The checks every backend shares: an Err, or null to go on.
pub fn check_args(h: raw.Ptr<u8>, port: i64): raw.Ptr<abi.Err> uses raw, ffi {
  if !(port > 0 && port <= 65535) {
    return host_err(h, port, ": invalid port", raw.null(), 0)
  }
  if h.at(0) == 0 {
    return host_err(h, port, ": empty host", raw.null(), 0)
  }
  if !valid_host(h) {
    return host_err(h, port, ": invalid host name", raw.null(), 0)
  }
  raw.null()
}

/// An Err "<what>: <reason>" for errno-style code (auk__err_errno's message, no subject).
pub fn errno_err(what: raw.Ptr<u8>, code: i32): raw.Ptr<abi.Err> uses raw, ffi = err.auk__err_errno(what, raw.null(), code)

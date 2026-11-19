/// TLS sessions on macOS: Network.framework (was the `#if defined(__APPLE__)` half of
/// runtime/c/tls.c, ported line by line; tls.auk has the overview and the shared checks).
///
/// Network.framework, Security.framework and libdispatch take blocks as callbacks. The dialect has
/// no `^{ … }`, so each block is a raw struct laid out per Clang's Block ABI (docs/lowlevel.md,
/// section 10, proven by runtime/c/test/spike/blocks.c), and the SDK functions that take blocks
/// are declared here with `raw.Ptr<()>` for each (the SDK headers hide them without -fblocks).
///
///   block (tls.c)                              captures      kind here
///   nw_parameters_create_secure_tcp tls cfg    t, fallback   stack literal (the framework copies)
///   sec_protocol_options_set_verify_block      t             stack literal (the framework copies)
///   nw_parameters_create_secure_tcp tcp cfg    -             global literal
///   nw_connection_set_state_changed_handler    t             stack literal (the framework copies)
///   dispatch_sync (read the outcome)           t, out        stack literal (never copied)
///   nw_connection_receive completion           op            stack literal + copy/dispose
///   dispatch_data_apply applier                op            stack literal (never copied)
///   nw_connection_send completion              op            stack literal + copy/dispose
///
/// `t` lives until auk__tls_free, which waits for the cancelled state, so the blocks that capture
/// it own nothing. An op (one receive or send) is reference counted by the copies of its
/// completion block (the copy helper retains, the dispose helper releases) plus the waiting
/// caller's own reference: a cancelled wait walks away from it, and the framework's copy frees it
/// whenever it is released, called or not (tls.c counted two references by hand).

// the rest of the runtime (C, for now)
extern fn auk__on_task(): bool = "bool auk__on_task(void)"
extern fn auk__task_cancelled(): bool = "bool auk__task_cancelled(void)"
extern fn auk__check_cancel(loc: raw.Ptr<u8>) = "void auk__check_cancel(const char *)"
extern fn auk__conn_new(fd: i32): raw.Ptr<abi.Conn> = "void *auk__conn_new(int)"
extern fn auk__bytes_to_arr(b: raw.Ptr<u8>, n: i64): raw.Ptr<abi.Arr> = "void *auk__bytes_to_arr(const uint8_t *, int64_t)"
// libc
extern fn strerror(e: i32): raw.Ptr<u8> = "char *strerror(int)"
extern fn strlen(s: raw.Ptr<u8>): usize = "size_t strlen(const char *)"
extern fn getaddrinfo(node: raw.Ptr<u8>, service: raw.Ptr<u8>, hints: raw.Ptr<cfacts.Addrinfo>, res: raw.Ptr<raw.Ptr<cfacts.Addrinfo>>): i32 =
  "int getaddrinfo(const char *, const char *, const void *, void *)"
extern fn freeaddrinfo(res: raw.Ptr<cfacts.Addrinfo>) = "void freeaddrinfo(void *)"
extern fn gai_strerror(e: i32): raw.Ptr<u8> = "const char *gai_strerror(int)"

// libdispatch (the block-taking ones with `void *` blocks, as the headers hide them)
extern fn dispatch_retain(o: raw.Ptr<()>) = "void dispatch_retain(void *)"
extern fn dispatch_release(o: raw.Ptr<()>) = "void dispatch_release(void *)"
extern fn dispatch_queue_create(label: raw.Ptr<u8>, attr: raw.Ptr<()>): raw.Ptr<()> =
  "void *dispatch_queue_create(const char *, void *)"
extern fn dispatch_semaphore_create(value: i64): raw.Ptr<()> = "void *dispatch_semaphore_create(long)"
extern fn dispatch_semaphore_signal(s: raw.Ptr<()>): i64 = "long dispatch_semaphore_signal(void *)"
extern fn dispatch_semaphore_wait(s: raw.Ptr<()>, timeout: u64): i64 = "long dispatch_semaphore_wait(void *, uint64_t)"
extern fn dispatch_time(at: u64, delta: i64): u64 = "uint64_t dispatch_time(uint64_t, int64_t)"
extern fn dispatch_sync(q: raw.Ptr<()>, block: raw.Ptr<()>) = "void dispatch_sync(void *, void *)"
extern fn dispatch_data_create(buf: raw.Ptr<u8>, size: usize, q: raw.Ptr<()>, destructor: raw.Ptr<()>): raw.Ptr<()> =
  "void *dispatch_data_create(const void *, size_t, void *, void *)"
extern fn dispatch_data_get_size(d: raw.Ptr<()>): usize = "size_t dispatch_data_get_size(void *)"
extern fn dispatch_data_apply(d: raw.Ptr<()>, applier: raw.Ptr<()>): bool = "bool dispatch_data_apply(void *, void *)"

// Network.framework
extern fn nw_release(o: raw.Ptr<()>) = "void nw_release(void *)"
extern fn nw_endpoint_create_host(host: raw.Ptr<u8>, port: raw.Ptr<u8>): raw.Ptr<()> =
  "void *nw_endpoint_create_host(const char *, const char *)"
extern fn nw_parameters_create_secure_tcp(configure_tls: raw.Ptr<()>, configure_tcp: raw.Ptr<()>): raw.Ptr<()> =
  "void *nw_parameters_create_secure_tcp(void *, void *)"
extern fn nw_tls_copy_sec_protocol_options(o: raw.Ptr<()>): raw.Ptr<()> = "void *nw_tls_copy_sec_protocol_options(void *)"
extern fn nw_tcp_options_set_connection_timeout(o: raw.Ptr<()>, secs: u32) =
  "void nw_tcp_options_set_connection_timeout(void *, uint32_t)"
extern fn nw_connection_create(ep: raw.Ptr<()>, params: raw.Ptr<()>): raw.Ptr<()> = "void *nw_connection_create(void *, void *)"
extern fn nw_connection_set_queue(c: raw.Ptr<()>, q: raw.Ptr<()>) = "void nw_connection_set_queue(void *, void *)"
extern fn nw_connection_set_state_changed_handler(c: raw.Ptr<()>, handler: raw.Ptr<()>) =
  "void nw_connection_set_state_changed_handler(void *, void *)"
extern fn nw_connection_start(c: raw.Ptr<()>) = "void nw_connection_start(void *)"
extern fn nw_connection_cancel(c: raw.Ptr<()>) = "void nw_connection_cancel(void *)"
extern fn nw_connection_receive(c: raw.Ptr<()>, min: u32, max: u32, completion: raw.Ptr<()>) =
  "void nw_connection_receive(void *, uint32_t, uint32_t, void *)"
extern fn nw_connection_send(c: raw.Ptr<()>, content: raw.Ptr<()>, ctx: raw.Ptr<()>, is_complete: bool, completion: raw.Ptr<()>) =
  "void nw_connection_send(void *, void *, void *, bool, void *)"
extern fn nw_error_get_error_domain(e: raw.Ptr<()>): i32 = "int nw_error_get_error_domain(void *)"
extern fn nw_error_get_error_code(e: raw.Ptr<()>): i32 = "int nw_error_get_error_code(void *)"
/// NW_CONNECTION_DEFAULT_STREAM_CONTEXT
extern var nw_default_stream: raw.Ptr<()> = "_nw_content_context_default_stream"

// Security.framework and CoreFoundation
extern fn sec_protocol_options_set_min_tls_protocol_version(o: raw.Ptr<()>, v: u16) =
  "void sec_protocol_options_set_min_tls_protocol_version(void *, uint16_t)"
extern fn sec_protocol_options_set_max_tls_protocol_version(o: raw.Ptr<()>, v: u16) =
  "void sec_protocol_options_set_max_tls_protocol_version(void *, uint16_t)"
extern fn sec_protocol_options_set_tls_is_fallback_attempt(o: raw.Ptr<()>, on: bool) =
  "void sec_protocol_options_set_tls_is_fallback_attempt(void *, bool)"
extern fn sec_protocol_options_set_verify_block(o: raw.Ptr<()>, verify: raw.Ptr<()>, q: raw.Ptr<()>) =
  "void sec_protocol_options_set_verify_block(void *, void *, void *)"
extern fn sec_trust_copy_ref(t: raw.Ptr<()>): raw.Ptr<()> = "void *sec_trust_copy_ref(void *)"
extern fn SecPolicyCreateSSL(server: bool, host: raw.Ptr<()>): raw.Ptr<()> = "void *SecPolicyCreateSSL(bool, void *)"
extern fn SecTrustSetPolicies(t: raw.Ptr<()>, policies: raw.Ptr<()>): i32 = "int SecTrustSetPolicies(void *, void *)"
extern fn SecTrustEvaluateWithError(t: raw.Ptr<()>, e: raw.Ptr<raw.Ptr<()>>): bool = "bool SecTrustEvaluateWithError(void *, void *)"
extern fn CFStringCreateWithCString(alloc: raw.Ptr<()>, s: raw.Ptr<u8>, enc: u32): raw.Ptr<()> =
  "void *CFStringCreateWithCString(void *, const char *, uint32_t)"
extern fn CFStringGetCString(s: raw.Ptr<()>, buf: raw.Ptr<u8>, size: i64, enc: u32): bool =
  "bool CFStringGetCString(void *, char *, int64_t, uint32_t)"
extern fn CFErrorGetCode(e: raw.Ptr<()>): i64 = "int64_t CFErrorGetCode(void *)"
extern fn CFErrorCopyDescription(e: raw.Ptr<()>): raw.Ptr<()> = "void *CFErrorCopyDescription(void *)"
extern fn CFRelease(o: raw.Ptr<()>) = "void CFRelease(const void *)"

// the SDK's constants
raw let NW_DOMAIN_POSIX: i32 = 1 // nw_error_domain_posix
raw let NW_DOMAIN_DNS: i32 = 2 // nw_error_domain_dns
raw let NW_DOMAIN_TLS: i32 = 3 // nw_error_domain_tls
raw let NW_STATE_WAITING: i32 = 1 // nw_connection_state_waiting
raw let NW_STATE_READY: i32 = 3 // nw_connection_state_ready
raw let NW_STATE_FAILED: i32 = 4 // nw_connection_state_failed
raw let NW_STATE_CANCELLED: i32 = 5 // nw_connection_state_cancelled
raw let TLS_V12: u16 = 771 // tls_protocol_version_TLSv12 (0x0303)
raw let CF_UTF8: u32 = 134217984 // kCFStringEncodingUTF8 (0x08000100)
raw let NSEC_PER_MSEC: i64 = 1000000

// ---- blocks (docs/lowlevel.md, section 10) ---------------------------------------------------

/// The Block ABI's literal flags (the refcount bits and BLOCK_NEEDS_FREE are the runtime's).
/// No BLOCK_HAS_SIGNATURE (1 << 30): a C string isn't a constant in a global's initializer,
/// so the descriptors carry no signature, and nothing these blocks are given to reads one (the
/// spike checks that too: SPIKE_NO_SIGNATURE). Clang's encodings are noted at each descriptor.
raw let BLOCK_HAS_COPY_DISPOSE: i32 = 33554432 // 1 << 25
raw let BLOCK_IS_GLOBAL: i32 = 268435456 // 1 << 28

/// The `isa`s of block literals: their addresses (libSystem's data symbols).
extern var stack_block_isa: [u8; 0] = "_NSConcreteStackBlock"
extern var global_block_isa: [u8; 0] = "_NSConcreteGlobalBlock"

/// Every block starts with this; invoke's first argument is the block itself.
raw struct BlockHdr {
  isa: raw.Ptr<()>,
  flags: i32,
  reserved: i32,
  invoke: raw.Ptr<()>,
  descriptor: raw.Ptr<()>,
}

/// A descriptor without helpers.
raw struct BlockDesc {
  reserved: usize,
  size: usize, // of the whole literal: _Block_copy memmoves this many bytes
  signature: raw.Ptr<u8>,
  layout: raw.Ptr<u8>,
}

/// A descriptor with helpers (flags have BLOCK_HAS_COPY_DISPOSE).
raw struct BlockDescCD {
  reserved: usize,
  size: usize,
  copy: raw.Fn<(raw.Ptr<()>, raw.Ptr<()>) => ()>, // (the new heap copy, the source) after the memmove
  dispose: raw.Fn<(raw.Ptr<()>) => ()>, // before the heap copy is freed
  signature: raw.Ptr<u8>,
  layout: raw.Ptr<u8>,
}

raw assert raw.size_of<BlockHdr>() == 32 && raw.offset_of<BlockHdr>(.invoke) == 16
raw assert raw.size_of<BlockDescCD>() == 48 && raw.offset_of<BlockDescCD>(.signature) == 32

/// A stack literal's header.
fn stack_hdr(invoke: raw.Ptr<()>, desc: raw.Ptr<()>, helpers: bool): BlockHdr uses raw = BlockHdr {
  isa: raw.cast(raw.addr_of(&stack_block_isa)),
  flags: if helpers { BLOCK_HAS_COPY_DISPOSE } else { 0 },
  invoke: invoke,
  descriptor: desc,
}

/// Invoke a block someone else made (sec_protocol_verify_complete_t: `void (^)(bool)`).
fn call_bool_block(blk: raw.Ptr<BlockHdr>, v: bool) uses raw {
  let f: raw.Fn<(raw.Ptr<BlockHdr>, bool) => ()> = raw.cast(blk.invoke)
  f(blk, v)
}

// ---- the session ---------------------------------------------------------------------------

/// C's `char why[256]` (why the trust evaluation failed).
raw struct Why {
  b: [u8; 256],
}

raw struct NwTls {
  conn: raw.Ptr<()>,
  q: raw.Ptr<()>,
  ready: raw.Ptr<()>, // the first ready / waiting / failed state
  gone: raw.Ptr<()>, // the cancelled state
  // written on q only
  reported: bool,
  ok: bool,
  saw_cert: bool, // the verify block ran: the server got as far as its certificate
  domain: i32,
  code: i32,
  why: Why,
  host: raw.Ptr<u8>,
  // the caller's thread only
  eof: bool,
  pending: bool, // an error that arrived with the last data, reported by the next read
  pend_domain: i32,
  pend_code: i32,
}

/// The outcome of a handshake, read on the connection's queue.
raw struct NwOutcome {
  ok: bool,
  saw_cert: bool,
  domain: i32,
  code: i32,
  why: Why,
}

fn why_of(w: raw.Ptr<Why>): raw.Ptr<u8> uses raw = raw.cast(w)

/// Signal s from a callback; the retain keeps s alive though the waiter may release it.
fn nw_post(s: raw.Ptr<()>) uses ffi {
  dispatch_retain(s)
  let _ = dispatch_semaphore_signal(s)
  dispatch_release(s)
}

/// Wait for s, waking every 50 ms on a task thread to check for cancellation; false if the task
/// was cancelled (the caller cleans up, then calls auk__check_cancel).
fn nw_wait(s: raw.Ptr<()>): bool uses raw, ffi {
  if !auk__on_task() {
    let _ = dispatch_semaphore_wait(s, cfacts.DISPATCH_TIME_FOREVER)
    return true
  }
  loop {
    if dispatch_semaphore_wait(s, dispatch_time(cfacts.DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC)) == 0 {
      return true
    }
    if auk__task_cancelled() {
      return false
    }
  }
}

/// A cancelled wait: auk__check_cancel panics ("cancelled"), so it never returns here.
fn cancelled() uses raw, ffi {
  auk__check_cancel("a blocking call")
  raw.trap()
}

/// The reason of a certificate refusal (a Security.framework error code), or null.
fn cert_reason(code: i32): raw.Ptr<u8> uses raw {
  if code == -67818 { // errSecCertificateExpired
    "certificate has expired"
  } else if code == -67819 { // errSecCertificateNotValidYet
    "certificate is not yet valid"
  } else if code == -67820 { // errSecCertificateRevoked
    "certificate has been revoked"
  } else if code == -67602 { // errSecHostNameMismatch
    "certificate does not match the host name"
  } else if code == -67843 || code == -25318 { // errSecNotTrusted, errSecCreateChainFailed
    "certificate is not trusted (self-signed or no trusted root)"
  } else if code == -67609 { // errSecInvalidExtendedKeyUsage
    "certificate is not valid for a TLS server"
  } else {
    raw.null()
  }
}

/// The text of a TLS OSStatus (SecureTransport codes) about the certificate, or null.
fn tls_verify_status(code: i32): raw.Ptr<u8> uses raw {
  if code == -9807 {
    "invalid certificate chain"
  } else if code == -9808 {
    "bad certificate"
  } else if code == -9812 {
    "certificate chain ends in an unknown root"
  } else if code == -9813 {
    "certificate is not trusted (self-signed or no trusted root)"
  } else if code == -9814 {
    "certificate has expired"
  } else if code == -9815 {
    "certificate is not yet valid"
  } else if code == -9843 {
    "certificate does not match the host name"
  } else {
    raw.null()
  }
}

/// The text of any other TLS OSStatus, or null.
fn tls_other_status(code: i32): raw.Ptr<u8> uses raw {
  if code == -9800 {
    "protocol error"
  } else if code == -9801 {
    "no cipher suite in common"
  } else if code == -9802 {
    "fatal alert from the server"
  } else if code == -9805 {
    "the server closed the connection"
  } else if code == -9806 {
    "the connection closed during the handshake"
  } else if code == -9816 {
    "the server closed the connection without close_notify"
  } else if code == -9824 || code == -9836 {
    "the server's TLS version is not supported"
  } else {
    raw.null()
  }
}

/// An Err "<prefix>: <reason>" for an nw_error (domain, code); prefix consumed.
fn nw_err(prefix: raw.Ptr<abi.StrBuf>, domain: i32, code: i32): raw.Ptr<abi.Err> uses raw, ffi {
  if domain == NW_DOMAIN_POSIX {
    return tls.prefixed(prefix, ": ", strerror(code), code)
  }
  if domain == NW_DOMAIN_DNS {
    str.auk__sb_put_cstr(prefix, ": cannot resolve the host (DNS error ")
    str_fmt.auk_sb_int(prefix, i64(code))
    return tls.prefixed(prefix, ")", raw.null(), 0)
  }
  if domain == NW_DOMAIN_TLS {
    let v = tls_verify_status(code)
    if !v.is_null() {
      return tls.prefixed(prefix, ": certificate verification failed: ", v, 0)
    }
    let what = tls_other_status(code)
    if !what.is_null() {
      return tls.prefixed(prefix, ": TLS error: ", what, 0)
    }
    str.auk__sb_put_cstr(prefix, ": TLS error (OSStatus ")
    str_fmt.auk_sb_int(prefix, i64(code))
    return tls.prefixed(prefix, ")", raw.null(), 0)
  }
  tls.prefixed(prefix, ": connection failed", raw.null(), 0)
}

/// "<what>: <reason>" for an nw_error.
fn what_err(what: raw.Ptr<u8>, domain: i32, code: i32): raw.Ptr<abi.Err> uses raw, ffi {
  var m = abi.StrBuf {}
  str.auk__sb_put_cstr(raw.addr_of(&m), what)
  nw_err(raw.addr_of(&m), domain, code)
}

fn nw_tls_free(t: raw.Ptr<NwTls>) uses raw, ffi {
  nw_connection_cancel(t.conn)
  let _ = dispatch_semaphore_wait(t.gone, cfacts.DISPATCH_TIME_FOREVER)
  nw_release(t.conn)
  raw.free(t.host)
  dispatch_release(t.q)
  dispatch_release(t.ready)
  dispatch_release(t.gone)
  raw.free(t)
}

/// Resolve host:port first, so a name that doesn't resolve fails as plain TCP does.
fn resolve_first(h: raw.Ptr<u8>, ports: raw.Ptr<u8>, port: i64): raw.Ptr<abi.Err> uses raw, ffi {
  var hints = cfacts.Addrinfo { ai_family: cfacts.AF_UNSPEC, ai_socktype: cfacts.SOCK_STREAM }
  var res: raw.Ptr<cfacts.Addrinfo> = raw.null()
  let gai = getaddrinfo(h, ports, raw.addr_of(&hints), raw.addr_of(&res))
  if gai != 0 {
    return tls.host_err(h, port, ": ", gai_strerror(gai), 0)
  }
  freeaddrinfo(res)
  raw.null()
}

// --- the TLS configure block: void (^)(nw_protocol_options_t), captures t, fallback

raw struct TlsCfgBlock {
  h: BlockHdr,
  t: raw.Ptr<NwTls>,
  fallback: bool,
}

raw var tls_cfg_desc: BlockDesc = BlockDesc { size: raw.size_of<TlsCfgBlock>() } // signature "v16@?0^{nw_protocol_options=}8"

fn tls_cfg_invoke(b: raw.Ptr<TlsCfgBlock>, opts: raw.Ptr<()>) uses raw, ffi {
  let t = b.t
  let sec = nw_tls_copy_sec_protocol_options(opts)
  sec_protocol_options_set_min_tls_protocol_version(sec, TLS_V12)
  if b.fallback {
    sec_protocol_options_set_max_tls_protocol_version(sec, TLS_V12)
    // TLS_FALLBACK_SCSV (RFC 7507): a server that does speak TLS 1.3 refuses this hello, so
    // forged resets can't downgrade a connection to it
    sec_protocol_options_set_tls_is_fallback_attempt(sec, true)
  }
  // a literal in this frame: the framework copies it, so it may die when this returns
  var vb = VerifyBlock { h: stack_hdr(raw.cast(raw.fn_of(verify_invoke)), raw.cast(raw.addr_of(&verify_desc)), false), t: t }
  sec_protocol_options_set_verify_block(sec, raw.cast(raw.addr_of(&vb)), t.q)
  nw_release(sec)
}

// --- the TCP configure block: no captures, so a global literal (never copied, never freed)

fn tcp_cfg_invoke(b: raw.Ptr<BlockHdr>, opts: raw.Ptr<()>) uses ffi {
  nw_tcp_options_set_connection_timeout(opts, 30)
}

raw var tcp_cfg_desc: BlockDesc = BlockDesc { size: raw.size_of<BlockHdr>() } // signature "v16@?0^{nw_protocol_options=}8"
raw var tcp_cfg_block: BlockHdr = BlockHdr {
  isa: raw.cast(raw.addr_of(&global_block_isa)),
  flags: BLOCK_IS_GLOBAL,
  invoke: raw.cast(raw.fn_of(tcp_cfg_invoke)),
  descriptor: raw.cast(raw.addr_of(&tcp_cfg_desc)),
}

// --- the verify block: void (^)(sec_protocol_metadata_t, sec_trust_t, sec_protocol_verify_complete_t),
// captures t. The endpoint's host is sent as SNI. The block runs the system's own evaluation (the
// system trust store plus an SSL server policy pinned to host), the same check the default does,
// but it lets us report why a certificate was refused.

raw struct VerifyBlock {
  h: BlockHdr,
  t: raw.Ptr<NwTls>,
}

raw var verify_desc: BlockDesc = BlockDesc {
  size: raw.size_of<VerifyBlock>(),
  // signature "v32@?0^{sec_protocol_metadata=}8^{sec_trust=}16@?<v@?B>24"
}

fn verify_invoke(b: raw.Ptr<VerifyBlock>, md: raw.Ptr<()>, trust_ref: raw.Ptr<()>, complete: raw.Ptr<BlockHdr>) uses raw, ffi {
  let t = b.t
  t.saw_cert = true
  let why = why_of(raw.field_addr(t, .why))
  let trust = sec_trust_copy_ref(trust_ref)
  let name = CFStringCreateWithCString(raw.null(), t.host, CF_UTF8)
  let policy = SecPolicyCreateSSL(true, name)
  var cf_err: raw.Ptr<()> = raw.null()
  let ok = !name.is_null() && !policy.is_null() && SecTrustSetPolicies(trust, policy) == 0 &&
    SecTrustEvaluateWithError(trust, raw.addr_of(&cf_err))
  if !ok {
    let r: raw.Ptr<u8> = if !cf_err.is_null() { cert_reason(i32(CFErrorGetCode(cf_err))) } else { raw.null() }
    if !r.is_null() {
      str_fmt.auk__cstr_copy(why, raw.size_of<Why>(), r)
    } else {
      str_fmt.auk__cstr_copy(why, raw.size_of<Why>(), "the system trust evaluation failed")
      let d: raw.Ptr<()> = if !cf_err.is_null() { CFErrorCopyDescription(cf_err) } else { raw.null() }
      if !d.is_null() {
        let _ = CFStringGetCString(d, why, i64(raw.size_of<Why>()), CF_UTF8)
        CFRelease(d)
      }
    }
  }
  if !cf_err.is_null() {
    CFRelease(cf_err)
  }
  if !policy.is_null() {
    CFRelease(policy)
  }
  if !name.is_null() {
    CFRelease(name)
  }
  CFRelease(trust)
  call_bool_block(complete, ok)
}

// --- the state handler: void (^)(nw_connection_state_t, nw_error_t), captures t

raw struct StateBlock {
  h: BlockHdr,
  t: raw.Ptr<NwTls>,
}

raw var state_desc: BlockDesc = BlockDesc { size: raw.size_of<StateBlock>() } // signature "v20@?0i8^{nw_error=}12"

fn state_invoke(b: raw.Ptr<StateBlock>, st: i32, e: raw.Ptr<()>) uses raw, ffi {
  let t = b.t
  if st == NW_STATE_CANCELLED {
    nw_post(t.gone)
    return
  }
  let done = st == NW_STATE_READY || st == NW_STATE_WAITING || st == NW_STATE_FAILED
  if !done || t.reported {
    return
  }
  t.reported = true
  t.ok = st == NW_STATE_READY
  if !e.is_null() {
    t.domain = nw_error_get_error_domain(e)
    t.code = nw_error_get_error_code(e)
  }
  nw_post(t.ready)
}

// --- dispatch_sync's block (read the outcome on the queue): void (^)(void), captures t, out

raw struct ReadOutBlock {
  h: BlockHdr,
  t: raw.Ptr<NwTls>,
  out: raw.Ptr<NwOutcome>,
}

raw var read_out_desc: BlockDesc = BlockDesc { size: raw.size_of<ReadOutBlock>() } // signature "v8@?0"

fn read_out_invoke(b: raw.Ptr<ReadOutBlock>) uses raw {
  let t = b.t
  let out = b.out
  raw.copy(raw.field_addr(out, .why), raw.field_addr(t, .why), raw.size_of<Why>())
  out.ok = t.ok
  out.saw_cert = t.saw_cert
  out.domain = t.domain
  out.code = t.code
}

/// Connect to h:ports and run the handshake (waiting for its outcome, cancellably). fallback: the
/// TLS 1.2 retry (see auk_net_tls).
fn nw_connect(h: raw.Ptr<u8>, ports: raw.Ptr<u8>, fallback: bool, out: raw.Ptr<NwOutcome>): raw.Ptr<NwTls> uses raw, ffi {
  let t: raw.Ptr<NwTls> = raw.cast(raw.alloc(raw.size_of<NwTls>()))
  raw.fill(t, 0, raw.size_of<NwTls>())
  t.q = dispatch_queue_create("auk.net.tls", raw.null())
  t.ready = dispatch_semaphore_create(0)
  t.gone = dispatch_semaphore_create(0)
  let n = strlen(h) + 1
  t.host = raw.cast(raw.alloc(n))
  raw.copy(t.host, h, n)
  let ep = nw_endpoint_create_host(h, ports)
  var cfg = TlsCfgBlock {
    h: stack_hdr(raw.cast(raw.fn_of(tls_cfg_invoke)), raw.cast(raw.addr_of(&tls_cfg_desc)), false),
    t: t,
    fallback: fallback,
  }
  let params = nw_parameters_create_secure_tcp(raw.cast(raw.addr_of(&cfg)), raw.cast(raw.addr_of(&tcp_cfg_block)))
  t.conn = nw_connection_create(ep, params)
  nw_release(ep)
  nw_release(params)
  nw_connection_set_queue(t.conn, t.q)
  var sb = StateBlock { h: stack_hdr(raw.cast(raw.fn_of(state_invoke)), raw.cast(raw.addr_of(&state_desc)), false), t: t }
  nw_connection_set_state_changed_handler(t.conn, raw.cast(raw.addr_of(&sb)))
  nw_connection_start(t.conn)
  if !nw_wait(t.ready) {
    nw_tls_free(t)
    cancelled()
  }
  // read the outcome on the queue (dispatch_sync never copies: a stack literal is enough)
  var rb = ReadOutBlock {
    h: stack_hdr(raw.cast(raw.fn_of(read_out_invoke)), raw.cast(raw.addr_of(&read_out_desc)), false),
    t: t,
    out: out,
  }
  dispatch_sync(t.q, raw.cast(raw.addr_of(&rb)))
  t
}

pub export fn auk_net_tls(host: raw.Ptr<abi.Str>, port: i64): abi.ResConn uses raw, ffi {
  let h = str.auk_str_cstr(host)
  let bad = tls.check_args(h, port)
  if !bad.is_null() {
    return tls.conn_err(bad)
  }
  var ports_buf = tls.Buf24 {}
  let ports: raw.Ptr<u8> = raw.cast(raw.addr_of(&ports_buf))
  let _ = str_fmt.auk__fmt_i64(ports, port)
  let unresolved = resolve_first(h, ports, port)
  if !unresolved.is_null() {
    return tls.conn_err(unresolved)
  }
  var o = NwOutcome {}
  var t = nw_connect(h, ports, false, raw.addr_of(&o))
  // Network.framework's TLS 1.3 hello offers a post-quantum key share (X25519MLKEM768) and is
  // about 1.5 KB, two TCP segments; some servers and middleboxes reset such a connection, some
  // of the time (badssl.com's hosts: about half the attempts; OpenSSL offering the same group
  // sees the same resets, with X25519 alone none). Network.framework has no setting for the key
  // shares, so a reset before the server's certificate arrived is retried once as a TLS 1.2
  // hello (no key share, one segment), marked as a fallback.
  if !o.ok && !o.saw_cert && o.domain == NW_DOMAIN_POSIX && o.code == cfacts.ECONNRESET {
    nw_tls_free(t)
    o = NwOutcome {}
    t = nw_connect(h, ports, true, raw.addr_of(&o))
  }
  if !o.ok {
    nw_tls_free(t)
    var m = abi.StrBuf {}
    tls.tls_prefix(raw.addr_of(&m), h, port)
    let why = why_of(raw.field_addr(raw.addr_of(&o), .why))
    if why.at(0) != 0 {
      return tls.conn_err(tls.prefixed(raw.addr_of(&m), ": certificate verification failed: ", why, 0))
    }
    return tls.conn_err(nw_err(raw.addr_of(&m), o.domain, o.code))
  }
  let c = auk__conn_new(-1)
  c.tls = raw.cast(t)
  abi.ResConn { ok: true, val: c }
}

/// Errors that just mean the peer has closed the stream.
fn nw_is_eof(domain: i32, code: i32): bool =
  (domain == NW_DOMAIN_POSIX && code == cfacts.ENODATA) || (domain == NW_DOMAIN_TLS && (code == -9805 || code == -9816))

/// One receive or send in flight, shared by the waiting thread (one reference) and each copy of
/// its completion block (one each: the copy helper takes it, the dispose helper drops it).
raw struct NwOp {
  refs: i32,
  done: raw.Ptr<()>,
  buf: raw.Ptr<u8>,
  n: usize,
  fin: bool,
  failed: bool,
  domain: i32,
  code: i32,
}

fn nw_op_new(): raw.Ptr<NwOp> uses raw, ffi {
  let op: raw.Ptr<NwOp> = raw.cast(raw.alloc(raw.size_of<NwOp>()))
  raw.fill(op, 0, raw.size_of<NwOp>())
  raw.atomic_store(raw.field_addr(op, .refs), 1, raw.Order.SeqCst) // the caller's
  op.done = dispatch_semaphore_create(0)
  op
}

fn nw_op_drop(op: raw.Ptr<NwOp>) uses raw, ffi {
  if raw.atomic_sub(raw.field_addr(op, .refs), 1, raw.Order.AcqRel) == 1 {
    dispatch_release(op.done)
    raw.free(op.buf)
    raw.free(op)
  }
}

/// The completion blocks (receive, send) and the data applier: captures op.
raw struct OpBlock {
  h: BlockHdr,
  op: raw.Ptr<NwOp>,
}

/// The copy helper: the new heap copy holds a reference (the literal holds none).
fn op_copy(dst: raw.Ptr<()>, src: raw.Ptr<()>) uses raw {
  let b: raw.Ptr<OpBlock> = raw.cast(dst)
  let _ = raw.atomic_add(raw.field_addr(b.op, .refs), 1, raw.Order.Relaxed)
}

/// The dispose helper: the heap copy is going away.
fn op_dispose(blk: raw.Ptr<()>) uses raw, ffi {
  let b: raw.Ptr<OpBlock> = raw.cast(blk)
  nw_op_drop(b.op)
}

// --- dispatch_data_apply's applier: bool (^)(dispatch_data_t, size_t, const void *, size_t)

raw var apply_desc: BlockDesc = BlockDesc { size: raw.size_of<OpBlock>() } // signature "B40@?0^{dispatch_data_s=}8Q16r^v24Q32"

fn apply_invoke(b: raw.Ptr<OpBlock>, region: raw.Ptr<()>, off: usize, bytes: raw.Ptr<u8>, len: usize): bool uses raw {
  raw.copy(b.op.buf.offset(off), bytes, len)
  true
}

// --- the receive completion: void (^)(dispatch_data_t, nw_content_context_t, bool, nw_error_t)

raw var recv_desc: BlockDescCD = BlockDescCD {
  size: raw.size_of<OpBlock>(),
  copy: raw.fn_of(op_copy),
  dispose: raw.fn_of(op_dispose),
  // signature "v36@?0^{dispatch_data_s=}8^{nw_content_context=}16B24^{nw_error=}28"
}

fn recv_invoke(b: raw.Ptr<OpBlock>, content: raw.Ptr<()>, ctx: raw.Ptr<()>, complete: bool, e: raw.Ptr<()>) uses raw, ffi {
  let op = b.op
  if !content.is_null() {
    op.n = dispatch_data_get_size(content)
    op.buf = raw.cast(raw.alloc(if op.n != 0 { op.n } else { 1 }))
    // dispatch_data_apply never copies its applier: a stack literal
    var ab = OpBlock { h: stack_hdr(raw.cast(raw.fn_of(apply_invoke)), raw.cast(raw.addr_of(&apply_desc)), false), op: op }
    let _ = dispatch_data_apply(content, raw.cast(raw.addr_of(&ab)))
  }
  op.fin = complete
  if !e.is_null() {
    op.failed = true
    op.domain = nw_error_get_error_domain(e)
    op.code = nw_error_get_error_code(e)
  }
  nw_post(op.done)
}

// --- the send completion: void (^)(nw_error_t)

raw var send_desc: BlockDescCD = BlockDescCD {
  size: raw.size_of<OpBlock>(),
  copy: raw.fn_of(op_copy),
  dispose: raw.fn_of(op_dispose),
  // signature "v16@?0^{nw_error=}8"
}

fn send_invoke(b: raw.Ptr<OpBlock>, e: raw.Ptr<()>) uses raw, ffi {
  let op = b.op
  if !e.is_null() {
    op.failed = true
    op.domain = nw_error_get_error_domain(e)
    op.code = nw_error_get_error_code(e)
  }
  nw_post(op.done)
}

fn empty_arr(): abi.ResArr uses raw, ffi = abi.ResArr { ok: true, val: auk__bytes_to_arr(raw.null(), 0) }

pub export fn auk__tls_read(p: raw.Ptr<()>, max: i64): abi.ResArr uses raw, ffi {
  let t: raw.Ptr<NwTls> = raw.cast(p)
  if t.pending {
    t.pending = false
    t.eof = true
    return abi.ResArr { err: what_err("net read", t.pend_domain, t.pend_code) }
  }
  if t.eof {
    return empty_arr()
  }
  let op = nw_op_new()
  // a literal: the framework copies it (each copy holding a reference to op)
  var rb = OpBlock { h: stack_hdr(raw.cast(raw.fn_of(recv_invoke)), raw.cast(raw.addr_of(&recv_desc)), true), op: op }
  nw_connection_receive(t.conn, 1, u32(max), raw.cast(raw.addr_of(&rb)))
  if !nw_wait(op.done) {
    nw_op_drop(op)
    cancelled()
  }
  if op.failed && !nw_is_eof(op.domain, op.code) {
    if op.n == 0 {
      t.eof = true
      let e = if op.domain == NW_DOMAIN_POSIX && op.code != 0 {
        tls.errno_err("net read", op.code)
      } else {
        what_err("net read", op.domain, op.code)
      }
      nw_op_drop(op)
      return abi.ResArr { err: e }
    }
    t.pending = true
    t.pend_domain = op.domain
    t.pend_code = op.code
  } else if op.fin || op.failed || op.n == 0 {
    t.eof = true
  }
  let r = abi.ResArr { ok: true, val: auk__bytes_to_arr(op.buf, i64(op.n)) }
  nw_op_drop(op)
  r
}

pub export fn auk__tls_write(p: raw.Ptr<()>, buf: raw.Ptr<u8>, n: i64): abi.ResUnit uses raw, ffi {
  let t: raw.Ptr<NwTls> = raw.cast(p)
  if n <= 0 {
    return abi.ResUnit { ok: true }
  }
  // no destructor (DISPATCH_DATA_DESTRUCTOR_DEFAULT): it copies buf
  let data = dispatch_data_create(buf, usize(n), raw.null(), raw.null())
  let op = nw_op_new()
  var sb = OpBlock { h: stack_hdr(raw.cast(raw.fn_of(send_invoke)), raw.cast(raw.addr_of(&send_desc)), true), op: op }
  nw_connection_send(t.conn, data, nw_default_stream, false, raw.cast(raw.addr_of(&sb)))
  dispatch_release(data)
  if !nw_wait(op.done) {
    nw_op_drop(op)
    cancelled()
  }
  let r = if op.failed {
    if op.domain == NW_DOMAIN_POSIX && op.code != 0 {
      abi.ResUnit { err: tls.errno_err("net write", op.code) }
    } else {
      abi.ResUnit { err: what_err("net write", op.domain, op.code) }
    }
  } else {
    abi.ResUnit { ok: true }
  }
  nw_op_drop(op)
  r
}

/// Closes the session (the framework sends close_notify) and frees it.
pub export fn auk__tls_free(p: raw.Ptr<()>) uses raw, ffi {
  if !p.is_null() {
    nw_tls_free(raw.cast(p))
  }
}

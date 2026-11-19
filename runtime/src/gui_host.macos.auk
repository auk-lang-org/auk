/// The window process (gui.auk explains why there is one), on macOS; was runtime/c/gui_host.c,
/// ported line by line. A program's first gui.open runs its own executable again with
/// AUK_GUI_HOST set. auk_main_wrapper (and the auk command) see that variable and call
/// auk__gui_host_main instead of running the program. (gui_host.linux.auk only says no.)
///
/// The host's main thread runs AppKit. One thread per client reads its requests and hands them
/// to the main thread as jobs (a CFRunLoop source). All window state lives on the main thread,
/// and every reply and event is written from there, so the messages to a client stay in order.
///
/// Each window maps the client's two shared frame buffers. Its view hosts a CALayer whose
/// contents are one of two IOSurfaces, which the compositor shows directly (no drawRect:). A
/// PRESENT copies the rectangle that changed (plus what the back surface missed since it was
/// last shown) from the buffer the client just wrote into the back surface, flips the layer to
/// it, and answers PRESENTED. The client then writes its other buffer.
///
/// - AUK_GUI_HOST=fd:N: one client on fd N (a socket pair). Exit when it closes.
/// - AUK_GUI_HOST=listen:PATH (`auk run --live`): accept clients on a Unix socket. When a client
///   goes away without BYE, its windows stay open as orphans. A later client's OPEN with the
///   same title takes one over, and the next client to leave closes the rest. Exit when
///   AUK_GUI_OWNER (the live parent's pid) is gone.
///
/// AppKit, CoreFoundation, CoreGraphics and IOSurface are loaded with dlopen, and Objective-C is
/// driven through the runtime's C functions: objc_msgSend called through a `raw.Fn` of each
/// method's exact type (on arm64 it isn't variadic), and the view class's methods are private
/// functions given to class_addMethod by `raw.fn_of`.

// the rest of the runtime (C, for now)
extern fn auk__xmalloc(n: usize): raw.Ptr<()> = "void *auk__xmalloc(size_t)"
extern fn auk__xrealloc(p: raw.Ptr<()>, n: usize): raw.Ptr<()> = "void *auk__xrealloc(void *, size_t)"
extern fn auk__xcalloc(n: usize, size: usize): raw.Ptr<()> = "void *auk__xcalloc(size_t, size_t)"
extern fn auk_release(p: raw.Ptr<()>) = "void auk_release(void *)"
extern fn auk__c_fcntl(fd: i32, cmd: i32, arg: i32): i32 = "int auk__c_fcntl(int, int, int)"
// libc and libm
extern fn dlopen(path: raw.Ptr<u8>, mode: i32): raw.Ptr<()> = "void *dlopen(const char *, int)"
extern fn dlsym(handle: raw.Ptr<()>, name: raw.Ptr<u8>): raw.Ptr<()> = "void *dlsym(void *, const char *)"
extern fn dlerror(): raw.Ptr<u8> = "char *dlerror(void)"
extern fn getenv(name: raw.Ptr<u8>): raw.Ptr<u8> = "char *getenv(const char *)"
extern fn unsetenv(name: raw.Ptr<u8>): i32 = "int unsetenv(const char *)"
extern fn strlen(s: raw.Ptr<u8>): usize = "size_t strlen(const char *)"
extern fn strcmp(a: raw.Ptr<u8>, b: raw.Ptr<u8>): i32 = "int strcmp(const char *, const char *)"
extern fn strncmp(a: raw.Ptr<u8>, b: raw.Ptr<u8>, n: usize): i32 = "int strncmp(const char *, const char *, size_t)"
extern fn strerror(e: i32): raw.Ptr<u8> = "char *strerror(int)"
extern fn strtol(s: raw.Ptr<u8>, end: raw.Ptr<raw.Ptr<u8>>, base: i32): i64 = "long strtol(const char *, char **, int)"
extern fn close(fd: i32): i32 = "int close(int)"
extern fn unlink(path: raw.Ptr<u8>): i32 = "int unlink(const char *)"
extern fn kill(pid: i32, sig: i32): i32 = "int kill(int, int)"
extern fn exit_now(code: i32): never = "void _exit(int)"
extern fn mmap(addr: raw.Ptr<()>, len: usize, prot: i32, flags: i32, fd: i32, off: i64): raw.Ptr<()> =
  "void *mmap(void *, size_t, int, int, int, int64_t)"
extern fn munmap(addr: raw.Ptr<()>, len: usize): i32 = "int munmap(void *, size_t)"
extern fn nanosleep(req: raw.Ptr<cfacts.Timespec>, rem: raw.Ptr<cfacts.Timespec>): i32 = "int nanosleep(const void *, void *)"
extern fn clock_gettime(clock: i32, ts: raw.Ptr<cfacts.Timespec>): i32 = "int clock_gettime(int, void *)"
extern fn socket(domain: i32, kind: i32, proto: i32): i32 = "int socket(int, int, int)"
extern fn bind(fd: i32, addr: raw.Ptr<()>, len: u32): i32 = "int bind(int, const void *, uint32_t)"
extern fn listen(fd: i32, backlog: i32): i32 = "int listen(int, int)"
extern fn accept(fd: i32, addr: raw.Ptr<()>, len: raw.Ptr<u32>): i32 = "int accept(int, void *, uint32_t *)"
extern fn shutdown(fd: i32, how: i32): i32 = "int shutdown(int, int)"
extern fn fopen(path: raw.Ptr<u8>, mode: raw.Ptr<u8>): raw.Ptr<()> = "FILE *fopen(const char *, const char *)"
extern fn fclose(f: raw.Ptr<()>): i32 = "int fclose(FILE *)"
extern fn fputs(s: raw.Ptr<u8>, f: raw.Ptr<()>): i32 = "int fputs(const char *, FILE *)"
extern fn fwrite(p: raw.Ptr<()>, size: usize, n: usize, f: raw.Ptr<()>): usize = "size_t fwrite(const void *, size_t, size_t, FILE *)"
extern fn round(x: float): float = "double round(double)"
extern fn floor(x: float): float = "double floor(double)"
extern fn pthread_mutex_lock(m: raw.Ptr<cfacts.PthreadMutex>): i32 = "int pthread_mutex_lock(void *)"
extern fn pthread_mutex_unlock(m: raw.Ptr<cfacts.PthreadMutex>): i32 = "int pthread_mutex_unlock(void *)"
extern fn pthread_attr_init(a: raw.Ptr<cfacts.PthreadAttr>): i32 = "int pthread_attr_init(pthread_attr_t *)"
extern fn pthread_attr_destroy(a: raw.Ptr<cfacts.PthreadAttr>): i32 = "int pthread_attr_destroy(pthread_attr_t *)"
extern fn pthread_attr_setdetachstate(a: raw.Ptr<cfacts.PthreadAttr>, s: i32): i32 = "int pthread_attr_setdetachstate(pthread_attr_t *, int)"
extern fn pthread_create(th: raw.Ptr<cfacts.PthreadT>, a: raw.Ptr<cfacts.PthreadAttr>, f: raw.Fn<(raw.Ptr<()>) => raw.Ptr<()>>, arg: raw.Ptr<()>): i32 =
  "int pthread_create(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *)"

/// A malloc'd copy of the message s.
fn msg_dup(s: raw.Ptr<u8>): raw.Ptr<u8> uses raw, ffi {
  var m = abi.StrBuf {}
  str.auk__sb_put_cstr(raw.addr_of(&m), s)
  str_fmt.auk__sb_take_cstr(raw.addr_of(&m))
}

/// a, b and a newline on stderr, in one write.
fn eprint_line(a: raw.Ptr<u8>, b: raw.Ptr<u8>) uses raw, ffi {
  var m = abi.StrBuf {}
  let mp = raw.addr_of(&m)
  str.auk__sb_put_cstr(mp, a)
  str.auk__sb_put_cstr(mp, b)
  str.auk__sb_put_cstr(mp, "\n")
  str_fmt.auk__sb_eprint(mp)
}

/// "gui.present: cannot make a <w>x<h> surface" on stderr.
fn no_surface(w: usize, h: usize) uses raw, ffi {
  var m = abi.StrBuf {}
  let mp = raw.addr_of(&m)
  str.auk__sb_put_cstr(mp, "gui.present: cannot make a ")
  str_fmt.auk__sb_u64(mp, u64(w))
  str.auk__sb_put_cstr(mp, "x")
  str_fmt.auk__sb_u64(mp, u64(h))
  str.auk__sb_put_cstr(mp, " surface\n")
  str_fmt.auk__sb_eprint(mp)
}

raw type Id = raw.Ptr<()>
raw type Sel = raw.Ptr<()>
raw type Class = raw.Ptr<()>

raw struct HPoint {
  x: float,
  y: float,
}

raw struct HSize {
  w: float,
  h: float,
}

raw struct HRect {
  o: HPoint,
  s: HSize,
}

fn hrect(x: float, y: float, w: float, h: float): HRect = HRect { o: HPoint { x, y }, s: HSize { w, h } }

/// C: CFRunLoopSourceContext
raw struct SourceContext {
  version: i64,
  info: raw.Ptr<()>,
  retain: raw.Ptr<()>,
  release: raw.Ptr<()>,
  copy_description: raw.Ptr<()>,
  equal: raw.Ptr<()>,
  hash: raw.Ptr<()>,
  schedule: raw.Ptr<()>,
  cancel: raw.Ptr<()>,
  perform: raw.Fn<(raw.Ptr<()>) => ()>,
}

/// The system functions, from dlopen'ed libraries.
raw struct Sys {
  get_class: raw.Fn<(raw.Ptr<u8>) => Class>,
  sel_register: raw.Fn<(raw.Ptr<u8>) => Sel>,
  msg_send: raw.Ptr<()>,
  alloc_class_pair: raw.Fn<(Class, raw.Ptr<u8>, usize) => Class>,
  add_method: raw.Fn<(Class, Sel, raw.Ptr<()>, raw.Ptr<u8>) => bool>,
  register_class_pair: raw.Fn<(Class) => ()>,
  pool_push: raw.Fn<() => raw.Ptr<()>>,
  pool_pop: raw.Fn<(raw.Ptr<()>) => ()>,
  run_loop_main: raw.Fn<() => raw.Ptr<()>>,
  source_create: raw.Fn<(raw.Ptr<()>, i64, raw.Ptr<SourceContext>) => raw.Ptr<()>>,
  add_source: raw.Fn<(raw.Ptr<()>, raw.Ptr<()>, raw.Ptr<()>) => ()>,
  source_signal: raw.Fn<(raw.Ptr<()>) => ()>,
  wake_up: raw.Fn<(raw.Ptr<()>) => ()>,
  common_modes: raw.Ptr<()>,
  color_space: raw.Ptr<()>,
  cf_release: raw.Fn<(raw.Ptr<()>) => ()>,
  color_space_plist: raw.Fn<(raw.Ptr<()>) => raw.Ptr<()>>,
  surface_create: raw.Fn<(Id) => raw.Ptr<()>>,
  surface_lock: raw.Fn<(raw.Ptr<()>, u32, raw.Ptr<u32>) => i32>,
  surface_unlock: raw.Fn<(raw.Ptr<()>, u32, raw.Ptr<u32>) => i32>,
  surface_base: raw.Fn<(raw.Ptr<()>) => raw.Ptr<u8>>,
  surface_row_bytes: raw.Fn<(raw.Ptr<()>) => usize>,
  surface_in_use: raw.Fn<(raw.Ptr<()>) => bool>,
  surface_set_value: raw.Fn<(raw.Ptr<()>, Id, raw.Ptr<()>) => ()>,
  // for AUK_GUI_SNAP (tests): an image of one of this process's own windows (or null)
  window_image: raw.Fn<(HRect, u32, u32, u32) => raw.Ptr<()>>,
  image_provider: raw.Fn<(raw.Ptr<()>) => raw.Ptr<()>>,
  provider_copy_data: raw.Fn<(raw.Ptr<()>) => raw.Ptr<()>>,
  image_width: raw.Fn<(raw.Ptr<()>) => usize>,
  image_height: raw.Fn<(raw.Ptr<()>) => usize>,
  image_row_bytes: raw.Fn<(raw.Ptr<()>) => usize>,
  data_ptr: raw.Fn<(raw.Ptr<()>) => raw.Ptr<u8>>,
}

raw var sys: Sys = Sys {}

fn open_lib(path: raw.Ptr<u8>, why: raw.Ptr<raw.Ptr<u8>>): raw.Ptr<()> uses raw, ffi {
  let h = dlopen(path, cfacts.RTLD_NOW | cfacts.RTLD_GLOBAL)
  if h.is_null() && why.load().is_null() {
    var m = abi.StrBuf {}
    let mp = raw.addr_of(&m)
    str.auk__sb_put_cstr(mp, "gui: cannot load ")
    str.auk__sb_put_cstr(mp, path)
    str.auk__sb_put_cstr(mp, ": ")
    str.auk__sb_put_cstr(mp, dlerror())
    why.store(str_fmt.auk__sb_take_cstr(mp))
  }
  h
}

fn need(lib: raw.Ptr<()>, name: raw.Ptr<u8>, why: raw.Ptr<raw.Ptr<u8>>): raw.Ptr<()> uses raw, ffi {
  let p = if lib.is_null() { raw.null() } else { dlsym(lib, name) }
  if p.is_null() && why.load().is_null() {
    var m = abi.StrBuf {}
    let mp = raw.addr_of(&m)
    str.auk__sb_put_cstr(mp, "gui: missing system function ")
    str.auk__sb_put_cstr(mp, name)
    why.store(str_fmt.auk__sb_take_cstr(mp))
  }
  p
}

/// Load the system libraries: null, or why not (malloc'd).
fn load_sys(): raw.Ptr<u8> uses raw, ffi {
  var why: raw.Ptr<u8> = raw.null()
  let e = raw.addr_of(&why)
  let objc = open_lib("/usr/lib/libobjc.A.dylib", e)
  let cf = open_lib("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", e)
  let cg = open_lib("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", e)
  let _ = open_lib("/System/Library/Frameworks/AppKit.framework/AppKit", e)
  let ios = open_lib("/System/Library/Frameworks/IOSurface.framework/IOSurface", e)
  if !why.is_null() {
    return why
  }
  let color_space_named: raw.Fn<(raw.Ptr<()>) => raw.Ptr<()>> = raw.cast(need(cg, "CGColorSpaceCreateWithName", e))
  let srgb: raw.Ptr<raw.Ptr<()>> = raw.cast(need(cg, "kCGColorSpaceSRGB", e))
  let s = raw.addr_of(&sys)
  s.get_class = raw.cast(need(objc, "objc_getClass", e))
  s.sel_register = raw.cast(need(objc, "sel_registerName", e))
  s.msg_send = need(objc, "objc_msgSend", e)
  s.alloc_class_pair = raw.cast(need(objc, "objc_allocateClassPair", e))
  s.add_method = raw.cast(need(objc, "class_addMethod", e))
  s.register_class_pair = raw.cast(need(objc, "objc_registerClassPair", e))
  s.pool_push = raw.cast(need(objc, "objc_autoreleasePoolPush", e))
  s.pool_pop = raw.cast(need(objc, "objc_autoreleasePoolPop", e))
  s.run_loop_main = raw.cast(need(cf, "CFRunLoopGetMain", e))
  s.source_create = raw.cast(need(cf, "CFRunLoopSourceCreate", e))
  s.add_source = raw.cast(need(cf, "CFRunLoopAddSource", e))
  s.source_signal = raw.cast(need(cf, "CFRunLoopSourceSignal", e))
  s.wake_up = raw.cast(need(cf, "CFRunLoopWakeUp", e))
  let modes: raw.Ptr<raw.Ptr<()>> = raw.cast(need(cf, "kCFRunLoopCommonModes", e))
  s.cf_release = raw.cast(need(cf, "CFRelease", e))
  s.color_space_plist = raw.cast(need(cg, "CGColorSpaceCopyPropertyList", e))
  s.surface_create = raw.cast(need(ios, "IOSurfaceCreate", e))
  s.surface_lock = raw.cast(need(ios, "IOSurfaceLock", e))
  s.surface_unlock = raw.cast(need(ios, "IOSurfaceUnlock", e))
  s.surface_base = raw.cast(need(ios, "IOSurfaceGetBaseAddress", e))
  s.surface_row_bytes = raw.cast(need(ios, "IOSurfaceGetBytesPerRow", e))
  s.surface_in_use = raw.cast(need(ios, "IOSurfaceIsInUse", e))
  s.surface_set_value = raw.cast(need(ios, "IOSurfaceSetValue", e))
  s.window_image = raw.cast(dlsym(cg, "CGWindowListCreateImage"))
  s.image_provider = raw.cast(need(cg, "CGImageGetDataProvider", e))
  s.provider_copy_data = raw.cast(need(cg, "CGDataProviderCopyData", e))
  s.image_width = raw.cast(need(cg, "CGImageGetWidth", e))
  s.image_height = raw.cast(need(cg, "CGImageGetHeight", e))
  s.image_row_bytes = raw.cast(need(cg, "CGImageGetBytesPerRow", e))
  s.data_ptr = raw.cast(need(cf, "CFDataGetBytePtr", e))
  if !why.is_null() {
    return why
  }
  s.common_modes = modes.load()
  s.color_space = color_space_named(srgb.load())
  raw.null()
}

fn sel(name: raw.Ptr<u8>): Sel {
  let f = sys.sel_register
  f(name)
}

fn cls(name: raw.Ptr<u8>): Class {
  let f = sys.get_class
  f(name)
}

fn cf_release(p: raw.Ptr<()>) {
  let f = sys.cf_release
  f(p)
}

// objc_msgSend, typed: one function per method signature used here.

fn m_id(o: Id, s: raw.Ptr<u8>): Id uses raw {
  let f: raw.Fn<(Id, Sel) => Id> = raw.cast(sys.msg_send)
  f(o, sel(s))
}

fn m_void(o: Id, s: raw.Ptr<u8>) uses raw {
  let f: raw.Fn<(Id, Sel) => ()> = raw.cast(sys.msg_send)
  f(o, sel(s))
}

fn m_void_id(o: Id, s: raw.Ptr<u8>, a: Id) uses raw {
  let f: raw.Fn<(Id, Sel, Id) => ()> = raw.cast(sys.msg_send)
  f(o, sel(s), a)
}

fn m_void_id_id(o: Id, s: raw.Ptr<u8>, a: Id, b: Id) uses raw {
  let f: raw.Fn<(Id, Sel, Id, Id) => ()> = raw.cast(sys.msg_send)
  f(o, sel(s), a, b)
}

fn m_bool_id(o: Id, s: raw.Ptr<u8>, a: Id): bool uses raw {
  let f: raw.Fn<(Id, Sel, Id) => bool> = raw.cast(sys.msg_send)
  f(o, sel(s), a)
}

fn m_void_bool(o: Id, s: raw.Ptr<u8>, a: bool) uses raw {
  let f: raw.Fn<(Id, Sel, bool) => ()> = raw.cast(sys.msg_send)
  f(o, sel(s), a)
}

fn m_bool_isize(o: Id, s: raw.Ptr<u8>, a: i64): bool uses raw {
  let f: raw.Fn<(Id, Sel, i64) => bool> = raw.cast(sys.msg_send)
  f(o, sel(s), a)
}

fn m_bool(o: Id, s: raw.Ptr<u8>): bool uses raw {
  let f: raw.Fn<(Id, Sel) => bool> = raw.cast(sys.msg_send)
  f(o, sel(s))
}

fn m_void_ptr(o: Id, s: raw.Ptr<u8>, a: raw.Ptr<()>) uses raw {
  let f: raw.Fn<(Id, Sel, raw.Ptr<()>) => ()> = raw.cast(sys.msg_send)
  f(o, sel(s), a)
}

fn m_ptr(o: Id, s: raw.Ptr<u8>): raw.Ptr<()> uses raw {
  let f: raw.Fn<(Id, Sel) => raw.Ptr<()>> = raw.cast(sys.msg_send)
  f(o, sel(s))
}

fn m_void_f64(o: Id, s: raw.Ptr<u8>, a: float) uses raw {
  let f: raw.Fn<(Id, Sel, float) => ()> = raw.cast(sys.msg_send)
  f(o, sel(s), a)
}

fn m_f64(o: Id, s: raw.Ptr<u8>): float uses raw {
  let f: raw.Fn<(Id, Sel) => float> = raw.cast(sys.msg_send)
  f(o, sel(s))
}

fn m_isize(o: Id, s: raw.Ptr<u8>): i64 uses raw {
  let f: raw.Fn<(Id, Sel) => i64> = raw.cast(sys.msg_send)
  f(o, sel(s))
}

fn m_usize(o: Id, s: raw.Ptr<u8>): usize uses raw {
  let f: raw.Fn<(Id, Sel) => usize> = raw.cast(sys.msg_send)
  f(o, sel(s))
}

fn m_u16(o: Id, s: raw.Ptr<u8>): u16 uses raw {
  let f: raw.Fn<(Id, Sel) => u16> = raw.cast(sys.msg_send)
  f(o, sel(s))
}

fn m_cstr(o: Id, s: raw.Ptr<u8>): raw.Ptr<u8> uses raw {
  let f: raw.Fn<(Id, Sel) => raw.Ptr<u8>> = raw.cast(sys.msg_send)
  f(o, sel(s))
}

fn m_id_cstr(o: Id, s: raw.Ptr<u8>, a: raw.Ptr<u8>): Id uses raw {
  let f: raw.Fn<(Id, Sel, raw.Ptr<u8>) => Id> = raw.cast(sys.msg_send)
  f(o, sel(s), a)
}

fn m_id_i64(o: Id, s: raw.Ptr<u8>, a: i64): Id uses raw {
  let f: raw.Fn<(Id, Sel, i64) => Id> = raw.cast(sys.msg_send)
  f(o, sel(s), a)
}

fn m_id_rect(o: Id, s: raw.Ptr<u8>, a: HRect): Id uses raw {
  let f: raw.Fn<(Id, Sel, HRect) => Id> = raw.cast(sys.msg_send)
  f(o, sel(s), a)
}

fn m_window_init(o: Id, r: HRect, style: usize, backing: usize, defer: bool): Id uses raw {
  let f: raw.Fn<(Id, Sel, HRect, usize, usize, bool) => Id> = raw.cast(sys.msg_send)
  f(o, sel("initWithContentRect:styleMask:backing:defer:"), r, style, backing, defer)
}

fn m_menu_item_init(o: Id, title: Id, action: Sel, key: Id): Id uses raw {
  let f: raw.Fn<(Id, Sel, Id, Sel, Id) => Id> = raw.cast(sys.msg_send)
  f(o, sel("initWithTitle:action:keyEquivalent:"), title, action, key)
}

fn m_rect(o: Id, s: raw.Ptr<u8>): HRect uses raw {
  let f: raw.Fn<(Id, Sel) => HRect> = raw.cast(sys.msg_send)
  f(o, sel(s))
}

fn m_point(o: Id, s: raw.Ptr<u8>): HPoint uses raw {
  let f: raw.Fn<(Id, Sel) => HPoint> = raw.cast(sys.msg_send)
  f(o, sel(s))
}

fn m_point_convert(o: Id, p: HPoint, from: Id): HPoint uses raw {
  let f: raw.Fn<(Id, Sel, HPoint, Id) => HPoint> = raw.cast(sys.msg_send)
  f(o, sel("convertPoint:fromView:"), p, from)
}

/// An NSString of s[0..n) (embedded NULs dropped).
fn ns_string_n(s: raw.Ptr<u8>, n: usize): Id uses raw, ffi {
  let c: raw.Ptr<u8> = raw.cast(auk__xmalloc(n + 1))
  var k: usize = 0
  var i: usize = 0
  while i < n {
    if s.at(i) != 0 {
      c.at(k) = s.at(i)
      k += 1
    }
    i += 1
  }
  c.at(k) = 0
  let r = m_id_cstr(cls("NSString"), "stringWithUTF8String:", c)
  raw.free(c)
  r
}

fn ns_string(s: raw.Ptr<u8>): Id uses raw, ffi = ns_string_n(s, strlen(s))

fn app(): Id uses raw = m_id(cls("NSApplication"), "sharedApplication")

// ---- AUK_GUI_TRACE=1: time copying into surfaces, waiting for the main thread, and handling
// requests, and print the averages to stderr every half second ----------------------------------

raw var trace_on: bool = false
/// (count, total µs, max µs) for copy, wait, handle (C's `_Atomic uint64_t trace_s[9]`)
raw struct TraceS {
  s: [u64; 9],
}
raw var trace_s: TraceS = TraceS {}
raw var trace_lock: cfacts.PthreadMutex = cfacts.PTHREAD_MUTEX_INITIALIZER
raw var trace_last: i64 = 0

fn trace_slot(i: i64): raw.Ptr<u64> uses raw = raw.cast<u64>(raw.addr_of(&trace_s)).offset(i)

fn now_us(): i64 uses raw, ffi {
  var ts = cfacts.Timespec {}
  let _ = clock_gettime(cfacts.CLOCK_MONOTONIC, raw.addr_of(&ts))
  ts.tv_sec * 1000000 + ts.tv_nsec / 1000
}

fn trace_name(i: i64): raw.Ptr<u8> = if i == 0 { "copy" } else if i == 1 { "wait" } else { "handle" }

fn trace_add(kind: i64, t0: i64) uses raw, ffi {
  let us = u64(now_us() - t0)
  let _ = raw.atomic_add(trace_slot(kind * 3), 1, raw.Order.SeqCst)
  let _ = raw.atomic_add(trace_slot(kind * 3 + 1), us, raw.Order.SeqCst)
  var m = raw.atomic_load(trace_slot(kind * 3 + 2), raw.Order.SeqCst)
  while us > m {
    let (old, ok) = raw.atomic_cas(trace_slot(kind * 3 + 2), m, us, raw.Order.SeqCst, raw.Order.SeqCst)
    if ok {
      break
    }
    m = old
  }
  let _ = pthread_mutex_lock(raw.addr_of(&trace_lock))
  let now = now_us()
  if trace_last == 0 || now - trace_last >= 500000 {
    trace_last = now
    var line = abi.StrBuf {}
    let lp = raw.addr_of(&line)
    str.auk__sb_put_cstr(lp, "gui trace:")
    var i: i64 = 0
    while i < 3 {
      let n = raw.atomic_swap(trace_slot(i * 3), 0, raw.Order.SeqCst)
      let tot = raw.atomic_swap(trace_slot(i * 3 + 1), 0, raw.Order.SeqCst)
      let max = raw.atomic_swap(trace_slot(i * 3 + 2), 0, raw.Order.SeqCst)
      if n > 0 {
        str.auk__sb_put_cstr(lp, " ")
        str.auk__sb_put_cstr(lp, trace_name(i))
        str.auk__sb_put_cstr(lp, " ")
        str_fmt.auk__sb_u64(lp, n)
        str.auk__sb_put_cstr(lp, "x avg ")
        str_fmt.auk__sb_u64(lp, tot / n)
        str.auk__sb_put_cstr(lp, " µs max ")
        str_fmt.auk__sb_u64(lp, max)
        str.auk__sb_put_cstr(lp, " µs;")
      }
      i += 1
    }
    str.auk__sb_put_cstr(lp, "\n")
    str_fmt.auk__sb_eprint(lp)
  }
  let _ = pthread_mutex_unlock(raw.addr_of(&trace_lock))
}

// ---- jobs: from the client threads to the main thread ----------------------------------------

raw let JOB_ADD_CLIENT: i32 = 0
raw let JOB_HANDLE: i32 = 1
raw let JOB_GONE: i32 = 2
raw let JOB_RETRY: i32 = 3

raw struct Job {
  kind: i32,
  client: u64,
  fd: i32,
  id: i64,
  msg: abi.WireMsg,
  t0: i64,
  next: raw.Ptr<Job>,
}

raw var jobs_lock: cfacts.PthreadMutex = cfacts.PTHREAD_MUTEX_INITIALIZER
raw var jobs_head: raw.Ptr<Job> = raw.null()
raw var jobs_tail: raw.Ptr<Job> = raw.null()
raw var wake_source: raw.Ptr<()> = raw.null()
raw var wake_loop: raw.Ptr<()> = raw.null()

fn submit(j: raw.Ptr<Job>) uses raw, ffi {
  j.next = raw.null()
  let _ = pthread_mutex_lock(raw.addr_of(&jobs_lock))
  if jobs_tail.is_null() {
    jobs_head = j
  } else {
    jobs_tail.next = j
  }
  jobs_tail = j
  let _ = pthread_mutex_unlock(raw.addr_of(&jobs_lock))
  if !wake_source.is_null() {
    let signal = sys.source_signal
    signal(wake_source)
    let wake = sys.wake_up
    wake(wake_loop)
  }
}

fn new_job(kind: i32): raw.Ptr<Job> uses raw, ffi {
  let j: raw.Ptr<Job> = raw.cast(auk__xcalloc(1, raw.size_of<Job>()))
  j.kind = kind
  j.fd = -1
  j
}

// ---- state (main thread only) ----------------------------------------------------------------

/// A mapped shared frame buffer: fw×fh 0xffRRGGBB.
raw struct HBuf {
  ptr: raw.Ptr<u32>,
  fw: usize,
  fh: usize,
  fd: i32,
}

/// An IOSurface of w×h BGRA pixels (0xffRRGGBB as little-endian u32s).
raw struct HSurf {
  s: raw.Ptr<()>,
  w: usize,
  h: usize,
}

raw struct Area {
  x0: usize,
  y0: usize,
  x1: usize,
  y1: usize,
}

raw struct Areas {
  a: [Area; 9],
  n: i32,
}

fn area_at(v: raw.Ptr<Areas>, i: i32): raw.Ptr<Area> uses raw = raw.cast<Area>(raw.field_addr(v, .a)).offset(i)

/// Add r to a list of areas, merging them all into one when the list gets long.
fn add_area(v: raw.Ptr<Areas>, r: Area) uses raw {
  area_at(v, v.n).store(r)
  v.n = v.n + 1
  if v.n > 8 {
    var all = r
    var i: i32 = 0
    while i < v.n {
      let b = area_at(v, i).load()
      all.x0 = if b.x0 < all.x0 { b.x0 } else { all.x0 }
      all.y0 = if b.y0 < all.y0 { b.y0 } else { all.y0 }
      all.x1 = if b.x1 > all.x1 { b.x1 } else { all.x1 }
      all.y1 = if b.y1 > all.y1 { b.y1 } else { all.y1 }
      i += 1
    }
    area_at(v, 0).store(all)
    v.n = 1
  }
}

raw struct HWin {
  id: i64,
  win: Id,
  view: Id,
  title: raw.Ptr<u8>,
  // the client it belongs to, or (as an orphan) the generation of the one it did
  orphan: bool,
  owner: u64,
  // the client's two shared frame buffers, and the one it last presented (-1: none)
  bufs: [HBuf; 2],
  has_buf: [bool; 2],
  front: i32,
  // the view's layer and its two IOSurfaces: the compositor shows one (shown) while a present
  // updates the other, then the layer flips to it
  layer: Id,
  surfs: [HSurf; 2],
  has_surfs: bool,
  shown: i32,
  // areas the other surface got since this one was last updated: what it lacks
  stale: [Areas; 2],
  // areas presented but not shown yet (the back surface was still in use), to copy from the
  // client's latest buffer; and whether a retry is scheduled
  pending: Areas,
  retry: bool,
}

fn buf_at(w: raw.Ptr<HWin>, i: i32): raw.Ptr<HBuf> uses raw = raw.cast<HBuf>(raw.field_addr(w, .bufs)).offset(i)
fn has_buf_at(w: raw.Ptr<HWin>, i: i32): raw.Ptr<bool> uses raw = raw.cast<bool>(raw.field_addr(w, .has_buf)).offset(i)
fn surf_at(w: raw.Ptr<HWin>, i: i32): raw.Ptr<HSurf> uses raw = raw.cast<HSurf>(raw.field_addr(w, .surfs)).offset(i)
fn stale_at(w: raw.Ptr<HWin>, i: i32): raw.Ptr<Areas> uses raw = raw.cast<Areas>(raw.field_addr(w, .stale)).offset(i)

raw struct HClient {
  id: u64,
  fd: i32,
}

raw var hwins: raw.Ptr<HWin> = raw.null()
raw var nhwins: i64 = 0
raw var caphwins: i64 = 0
raw var clients: raw.Ptr<HClient> = raw.null()
raw var nclients: i64 = 0
raw var capclients: i64 = 0
raw var next_win: i64 = 1
// one client at a time (fd mode): exit when it leaves
raw var single_client: bool = false

fn hwin(id: i64): raw.Ptr<HWin> uses raw {
  var i: i64 = 0
  while i < nhwins {
    if hwins.offset(i).id == id {
      return hwins.offset(i)
    }
    i += 1
  }
  raw.null()
}

fn view_id(view: Id): i64 uses raw {
  var i: i64 = 0
  while i < nhwins {
    if hwins.offset(i).view.int() == view.int() {
      return hwins.offset(i).id
    }
    i += 1
  }
  0
}

fn client_fd(client: u64): i32 uses raw {
  var i: i64 = 0
  while i < nclients {
    if clients.offset(i).id == client {
      return clients.offset(i).fd
    }
    i += 1
  }
  -1
}

fn send_to(client: u64, op: u8, b: raw.Ptr<abi.WireBuf>) uses raw, ffi {
  let fd = client_fd(client)
  let sb = raw.field_addr(b, .sb)
  if fd >= 0 {
    let body: raw.Ptr<u8> = if sb.buf.is_null() { raw.cast(raw.field_addr(sb, .small)) } else { sb.buf }
    let _ = gui.auk__wire_send(fd, op, body, sb.len, -1)
  }
  str.auk_sb_free(sb)
}

fn reply_err(client: u64, msg: raw.Ptr<u8>) uses raw, ffi {
  var b = abi.WireBuf {}
  gui.auk__wire_put_i64(raw.addr_of(&b), 1)
  gui.auk__wire_put_str(raw.addr_of(&b), msg, i64(strlen(msg)))
  send_to(client, abi.WIRE_REPLY, raw.addr_of(&b))
}

/// A one-field buffer for an event's few ints (C's `int64_t e[5]`).
raw struct Ev5 {
  e: [i64; 5],
}

/// An event of up to five ints.
fn ev(id: i64, n: i32, a: i64, b: i64, c: i64, d: i64, e: i64) uses raw, ffi {
  var v = Ev5 {}
  let p: raw.Ptr<i64> = raw.cast(raw.addr_of(&v))
  p.at(0) = a
  p.at(1) = b
  p.at(2) = c
  p.at(3) = d
  p.at(4) = e
  event(id, p, n)
}

/// Send an event to the window's client (an orphan has none; its close button closes it).
fn event(id: i64, e: raw.Ptr<i64>, n: i32) uses raw, ffi {
  let w = hwin(id)
  if w.is_null() {
    return
  }
  if !w.orphan {
    var b = abi.WireBuf {}
    gui.auk__wire_put_i64(raw.addr_of(&b), id)
    var i: i32 = 0
    while i < n {
      gui.auk__wire_put_i64(raw.addr_of(&b), e.at(i))
      i += 1
    }
    send_to(w.owner, abi.WIRE_EVENT, raw.addr_of(&b))
  } else if n == 1 && e.at(0) == 1 {
    close_win(id)
  }
}

// ---- surfaces and presenting -------------------------------------------------------------------

fn set_num(d: Id, key: raw.Ptr<u8>, v: i64) uses raw, ffi {
  m_void_id_id(d, "setObject:forKey:", m_id_i64(cls("NSNumber"), "numberWithLongLong:", v), ns_string(key))
}

fn surf_new(w: usize, h: usize, out: raw.Ptr<HSurf>): bool uses raw, ffi {
  let d = m_id(cls("NSMutableDictionary"), "dictionary")
  set_num(d, "IOSurfaceWidth", i64(w))
  set_num(d, "IOSurfaceHeight", i64(h))
  set_num(d, "IOSurfaceBytesPerElement", 4)
  set_num(d, "IOSurfacePixelFormat", 0x42475241)
  let create = sys.surface_create
  let s = create(d)
  if s.is_null() {
    return false
  }
  // the pixels are sRGB, so the compositor converts them for the display
  let plist = sys.color_space_plist
  let cs = plist(sys.color_space)
  if !cs.is_null() {
    let set_value = sys.surface_set_value
    set_value(s, ns_string("IOSurfaceColorSpace"), cs)
    cf_release(cs)
  }
  out.store(HSurf { s, w, h })
  true
}

fn buf_free(b: raw.Ptr<HBuf>) uses raw, ffi {
  let _ = munmap(raw.cast(b.ptr), b.fw * b.fh * 4)
  let _ = close(b.fd)
}

fn backing_scale(view: Id): float uses raw {
  let win = m_id(view, "window")
  if win.is_null() { 1.0 } else { m_f64(win, "backingScaleFactor") }
}

fn area_inside(a: Area, v: raw.Ptr<Areas>): bool uses raw {
  var i: i32 = 0
  while i < v.n {
    let r = area_at(v, i).load()
    if a.x0 >= r.x0 && a.y0 >= r.y0 && a.x1 <= r.x1 && a.y1 <= r.y1 {
      return true
    }
    i += 1
  }
  false
}

/// Copy area a of src (fw per row) into the surface memory base (rb bytes per row).
fn copy_area(base: raw.Ptr<u8>, rb: usize, src: raw.Ptr<u32>, fw: usize, a: Area) uses raw {
  var row = a.y0
  while row < a.y1 {
    raw.copy(base.offset(row * rb + a.x0 * 4), raw.cast<u8>(src.offset(row * fw + a.x0)), (a.x1 - a.x0) * 4)
    row += 1
  }
}

/// Bring the back surface up to date from the client's latest buffer and flip the layer to it.
/// Returns true if something is still pending because the compositor still had that surface.
fn show_now(id: i64): bool uses raw, ffi {
  var win = hwin(id)
  if win.is_null() || win.front < 0 || !has_buf_at(win, win.front).load() {
    return false
  }
  let scale = backing_scale(win.view)
  win = hwin(id) // AppKit may have called back into the view
  if win.is_null() {
    return false
  }
  let src = buf_at(win, win.front)
  let fw = src.fw
  let fh = src.fh
  // new surfaces for a new size; they lack everything
  if !win.has_surfs || surf_at(win, 0).w != fw || surf_at(win, 0).h != fh {
    var a = HSurf {}
    var b = HSurf {}
    if !surf_new(fw, fh, raw.addr_of(&a)) {
      no_surface(fw, fh)
      return false
    }
    if !surf_new(fw, fh, raw.addr_of(&b)) {
      cf_release(a.s)
      no_surface(fw, fh)
      return false
    }
    if win.has_surfs {
      cf_release(surf_at(win, 0).s)
      cf_release(surf_at(win, 1).s)
    }
    surf_at(win, 0).store(a)
    surf_at(win, 1).store(b)
    win.has_surfs = true
    let all = Area { x0: 0, y0: 0, x1: fw, y1: fh }
    let s0 = stale_at(win, 0)
    s0.n = 0
    let s1 = stale_at(win, 1)
    s1.n = 0
    add_area(stale_at(win, 0), all)
    add_area(stale_at(win, 1), all)
    let pending = raw.field_addr(win, .pending)
    pending.n = 0
    add_area(pending, all)
  }
  let pending = raw.field_addr(win, .pending)
  if pending.n == 0 {
    return false
  }
  let back = 1 - win.shown
  let surf = surf_at(win, back)
  // the compositor keeps the surface it showed last until the next refresh
  let in_use = sys.surface_in_use
  if in_use(surf.s) {
    return true
  }
  let lock_surface = sys.surface_lock
  let _ = lock_surface(surf.s, 0, raw.null())
  let base_of = sys.surface_base
  let base = base_of(surf.s)
  let row_bytes = sys.surface_row_bytes
  let rb = row_bytes(surf.s)
  let stale = stale_at(win, back)
  var i: i32 = 0
  while i < stale.n {
    let a = area_at(stale, i).load()
    if !area_inside(a, pending) {
      copy_area(base, rb, src.ptr, fw, a)
    }
    i += 1
  }
  i = 0
  while i < pending.n {
    copy_area(base, rb, src.ptr, fw, area_at(pending, i).load())
    i += 1
  }
  let unlock_surface = sys.surface_unlock
  let _ = unlock_surface(surf.s, 0, raw.null())
  stale.n = 0
  i = 0
  while i < pending.n {
    add_area(stale_at(win, win.shown), area_at(pending, i).load())
    i += 1
  }
  pending.n = 0
  win.shown = back
  let layer = win.layer
  let contents = surf.s
  m_void_f64(layer, "setContentsScale:", scale)
  m_void_ptr(layer, "setContents:", contents)
  false
}

/// show_now, timed for AUK_GUI_TRACE.
fn show(id: i64): bool uses raw, ffi {
  let t0 = now_us()
  let again = show_now(id)
  if trace_on {
    trace_add(0, t0)
  }
  again
}

fn sleep_ns(ns: i64) uses raw, ffi {
  var ts = cfacts.Timespec { tv_sec: 0, tv_nsec: ns }
  let _ = nanosleep(raw.addr_of(&ts), raw.null())
}

fn retry_thread(arg: raw.Ptr<()>): raw.Ptr<()> uses raw, ffi {
  sleep_ns(1000000)
  let j = new_job(JOB_RETRY)
  j.id = i64(arg.int())
  submit(j)
  raw.null()
}

/// Run f(arg) on a new detached thread.
fn spawn_detached(f: raw.Fn<(raw.Ptr<()>) => raw.Ptr<()>>, arg: raw.Ptr<()>) uses raw, ffi {
  var th = cfacts.PthreadT {}
  var attr = cfacts.PthreadAttr {}
  let _ = pthread_attr_init(raw.addr_of(&attr))
  let _ = pthread_attr_setdetachstate(raw.addr_of(&attr), cfacts.PTHREAD_CREATE_DETACHED)
  let _ = pthread_create(raw.addr_of(&th), raw.addr_of(&attr), f, arg)
  let _ = pthread_attr_destroy(raw.addr_of(&attr))
}

/// Try show again shortly (once per window at a time).
fn schedule_retry(id: i64) uses raw, ffi {
  let w = hwin(id)
  if w.is_null() || w.retry {
    return
  }
  w.retry = true
  spawn_detached(raw.fn_of(retry_thread), raw.from_int(id))
}

/// Take a present: remember the area that changed and show it now if the back surface is free,
/// or as soon as it is. Either way the client may write its other buffer at once: from here on
/// this process reads only buffer buf, which the client leaves alone until its next present is
/// answered. Null, or why not (malloc'd).
fn present(client: u64, id: i64, fw64: i64, fh64: i64, buf: i64, rects: raw.Ptr<i64>, n: i64, fd: i32): raw.Ptr<u8> uses raw, ffi {
  let fw: usize = if fw64 > 0 { usize(fw64) } else { 0 }
  let fh: usize = if fh64 > 0 { usize(fh64) } else { 0 }
  var len_ok = fw > 0 && fh > 0
  var len: usize = 0
  if len_ok {
    let (l1, o1) = raw.mul_overflow(fw, fh)
    let (l2, o2) = raw.mul_overflow(l1, usize(4))
    len_ok = !o1 && !o2
    len = l2
  }
  if !len_ok || buf < 0 || buf > 1 {
    if fd >= 0 {
      let _ = close(fd)
    }
    return msg_dup("gui.present: bad frame")
  }
  let i = i32(buf)
  let win = hwin(id)
  if win.is_null() || win.orphan || win.owner != client {
    if fd >= 0 {
      let _ = close(fd)
    }
    var m = abi.StrBuf {}
    let mp = raw.addr_of(&m)
    str.auk__sb_put_cstr(mp, "gui.present: window ")
    str_fmt.auk_sb_int(mp, id)
    str.auk__sb_put_cstr(mp, " is closed")
    return str_fmt.auk__sb_take_cstr(mp)
  }
  if fd >= 0 {
    let p = mmap(raw.null(), len, cfacts.PROT_READ, cfacts.MAP_SHARED, fd, 0)
    if i64(p.int()) == cfacts.MAP_FAILED {
      let er = cfacts.errno()
      let _ = close(fd)
      var m = abi.StrBuf {}
      let mp = raw.addr_of(&m)
      str.auk__sb_put_cstr(mp, "gui.present: cannot map the frame: ")
      str.auk__sb_put_cstr(mp, strerror(er))
      return str_fmt.auk__sb_take_cstr(mp)
    }
    if has_buf_at(win, i).load() {
      buf_free(buf_at(win, i))
    }
    buf_at(win, i).store(HBuf { ptr: raw.cast(p), fw, fh, fd })
    has_buf_at(win, i).store(true)
  }
  if !has_buf_at(win, i).load() || buf_at(win, i).fw != fw || buf_at(win, i).fh != fh {
    return msg_dup("gui.present: no frame memory of that size")
  }
  if win.front >= 0 && has_buf_at(win, win.front).load() && (buf_at(win, win.front).fw != fw || buf_at(win, win.front).fh != fh) {
    let pend = raw.field_addr(win, .pending)
    pend.n = 0 // a new size: the new surfaces get everything anyway
  }
  win.front = i
  var k: i64 = 0
  while k < n {
    let x = rects.at(k * 4)
    let y = rects.at(k * 4 + 1)
    let w = rects.at(k * 4 + 2)
    let h = rects.at(k * 4 + 3)
    let xe: i64 = if x + w > 0 { x + w } else { 0 }
    let ye: i64 = if y + h > 0 { y + h } else { 0 }
    let a = Area {
      x0: if x > 0 { usize(x) } else { 0 },
      y0: if y > 0 { usize(y) } else { 0 },
      x1: if usize(xe) < fw { usize(xe) } else { fw },
      y1: if usize(ye) < fh { usize(ye) } else { fh },
    }
    if a.x0 < a.x1 && a.y0 < a.y1 {
      add_area(raw.field_addr(win, .pending), a)
    }
    k += 1
  }
  if show(id) {
    schedule_retry(id)
  }
  raw.null()
}

/// C's INFINITY.
raw union Bits {
  f: float,
  i: i64,
}

raw struct Rgb {
  b: [u8; 4],
}

/// Save an image of win as it is on screen to path (a binary PPM), for tests.
fn snapshot(win: Id, path: raw.Ptr<u8>) uses raw, ffi {
  let window_image = sys.window_image
  if window_image.is_null() {
    let _ = fputs("gui: AUK_GUI_SNAP: no CGWindowListCreateImage on this system\n", cfacts.stderr())
    return
  }
  m_void(cls("CATransaction"), "flush")
  sleep_ns(100 * 1000000)
  let num = u32(m_isize(win, "windowNumber"))
  let inf = Bits { i: 0x7ff0000000000000 }.f
  let null_rect = hrect(inf, inf, 0.0, 0.0)
  // including only this window, its contents without the frame, at full resolution
  let img = window_image(null_rect, 8, num, 1 | 8)
  if img.is_null() {
    let _ = fputs("gui: AUK_GUI_SNAP: could not capture the window\n", cfacts.stderr())
    return
  }
  let image_width = sys.image_width
  let image_height = sys.image_height
  let image_row_bytes = sys.image_row_bytes
  let image_provider = sys.image_provider
  let provider_copy_data = sys.provider_copy_data
  let w = image_width(img)
  let h = image_height(img)
  let rb = image_row_bytes(img)
  let data = provider_copy_data(image_provider(img))
  if !data.is_null() {
    let data_ptr = sys.data_ptr
    let p = data_ptr(data)
    let f = fopen(path, "wb")
    if !f.is_null() {
      var hd = abi.StrBuf {}
      let hp = raw.addr_of(&hd)
      str.auk__sb_put_cstr(hp, "P6\n")
      str_fmt.auk__sb_u64(hp, u64(w))
      str.auk__sb_put_cstr(hp, " ")
      str_fmt.auk__sb_u64(hp, u64(h))
      str.auk__sb_put_cstr(hp, "\n255\n")
      let _ = fputs(str_fmt.auk__sb_cstr(hp), f)
      str.auk_sb_free(hp)
      var rgb = Rgb {}
      let q: raw.Ptr<u8> = raw.cast(raw.addr_of(&rgb))
      var y: usize = 0
      while y < h {
        var x: usize = 0
        while x < w {
          let px = p.offset(y * rb + x * 4)
          // BGRA in memory
          q.at(0) = px.at(2)
          q.at(1) = px.at(1)
          q.at(2) = px.at(0)
          let _ = fwrite(raw.cast(q), 1, 3, f)
          x += 1
        }
        y += 1
      }
      let _ = fclose(f)
    }
    cf_release(data)
  }
  cf_release(img)
}

fn close_win(id: i64) uses raw, ffi {
  var w = hwin(id)
  if w.is_null() {
    return
  }
  let snap = getenv("AUK_GUI_SNAP")
  if !snap.is_null() {
    // show what's pending first
    var i: i64 = 0
    while i < 50 {
      if !show(id) {
        break
      }
      sleep_ns(1000000)
      i += 1
    }
    w = hwin(id)
    if w.is_null() {
      return
    }
  }
  var c = w.load()
  let cp = raw.addr_of(&c)
  // take it off the list before AppKit runs (it may call back into the view)
  w.store(hwins.at(nhwins - 1))
  nhwins -= 1
  if !snap.is_null() {
    snapshot(c.win, snap)
  }
  m_void_id(c.win, "setDelegate:", raw.null())
  m_void(c.win, "close")
  m_void(c.win, "release")
  m_void(c.view, "release")
  m_void(c.layer, "release")
  var i: i32 = 0
  while i < 2 {
    if has_buf_at(cp, i).load() {
      buf_free(buf_at(cp, i))
    }
    i += 1
  }
  if c.has_surfs {
    cf_release(surf_at(cp, 0).s)
    cf_release(surf_at(cp, 1).s)
  }
  raw.free(c.title)
}

// ---- the view class: draws the window's buffer, reports input ----------------------------------

/// Shift, Control, Option, Command as bits 1, 2, 4, 8.
fn mods(e: Id): i64 uses raw {
  let f = m_usize(e, "modifierFlags")
  var m: i64 = 0
  if (f & (usize(1) << 17)) != 0 {
    m = m | 1
  }
  if (f & (usize(1) << 18)) != 0 {
    m = m | 2
  }
  if (f & (usize(1) << 19)) != 0 {
    m = m | 4
  }
  if (f & (usize(1) << 20)) != 0 {
    m = m | 8
  }
  m
}

/// Content size in physical pixels, and the scale.
fn metrics(view: Id, w: raw.Ptr<i64>, h: raw.Ptr<i64>, scale: raw.Ptr<float>) uses raw, ffi {
  if view.is_null() {
    w.store(0)
    h.store(0)
    scale.store(1.0)
    return
  }
  let r = m_rect(view, "bounds")
  scale.store(backing_scale(view))
  w.store(i64(round(r.s.w * scale.load())))
  h.store(i64(round(r.s.h * scale.load())))
}

/// Where the mouse is, in physical pixels from the content's top-left.
fn location(view: Id, e: Id, x: raw.Ptr<i64>, y: raw.Ptr<i64>) uses raw, ffi {
  var p = m_point(e, "locationInWindow")
  p = m_point_convert(view, p, raw.null())
  let scale = backing_scale(view)
  x.store(i64(floor(p.x * scale)))
  y.store(i64(floor(p.y * scale)))
}

fn v_yes(self: Id, cmd: Sel): bool = true

fn v_yes1(self: Id, cmd: Sel, a: Id): bool = true

fn v_mouse_down(self: Id, cmd: Sel, e: Id) uses raw, ffi {
  let id = view_id(self)
  if id != 0 {
    var x: i64 = 0
    var y: i64 = 0
    location(self, e, raw.addr_of(&x), raw.addr_of(&y))
    ev(id, 5, 4, m_isize(e, "buttonNumber"), x, y, mods(e))
  }
}

fn v_mouse_up(self: Id, cmd: Sel, e: Id) uses raw, ffi {
  let id = view_id(self)
  if id != 0 {
    var x: i64 = 0
    var y: i64 = 0
    location(self, e, raw.addr_of(&x), raw.addr_of(&y))
    ev(id, 5, 5, m_isize(e, "buttonNumber"), x, y, mods(e))
  }
}

fn v_mouse_moved(self: Id, cmd: Sel, e: Id) uses raw, ffi {
  let id = view_id(self)
  if id != 0 {
    var x: i64 = 0
    var y: i64 = 0
    location(self, e, raw.addr_of(&x), raw.addr_of(&y))
    ev(id, 3, 3, x, y, 0, 0)
  }
}

fn v_scroll(self: Id, cmd: Sel, e: Id) uses raw, ffi {
  let id = view_id(self)
  if id != 0 {
    var dx = m_f64(e, "scrollingDeltaX")
    var dy = m_f64(e, "scrollingDeltaY")
    if !m_bool(e, "hasPreciseScrollingDeltas") {
      // a wheel's notches: about a line each
      dx = dx * 16.0
      dy = dy * 16.0
    }
    let scale = backing_scale(self)
    ev(id, 3, 6, i64(dx * scale * 100.0), i64(dy * scale * 100.0), 0, 0)
  }
}

/// Decode the UTF-8 char at s (valid text); *len gets its length.
fn decode_char(s: raw.Ptr<u8>, len: raw.Ptr<i64>): u32 uses raw {
  let s0 = u32(s.at(0))
  if s0 < 0x80 {
    len.store(1)
    return s0
  }
  if s0 < 0xE0 {
    len.store(2)
    return ((s0 & 0x1F) << 6) | (u32(s.at(1)) & 0x3F)
  }
  if s0 < 0xF0 {
    len.store(3)
    return ((s0 & 0x0F) << 12) | ((u32(s.at(1)) & 0x3F) << 6) | (u32(s.at(2)) & 0x3F)
  }
  len.store(4)
  ((s0 & 0x07) << 18) | ((u32(s.at(1)) & 0x3F) << 12) | ((u32(s.at(2)) & 0x3F) << 6) | (u32(s.at(3)) & 0x3F)
}

fn v_key_down(self: Id, cmd: Sel, e: Id) uses raw, ffi {
  let id = view_id(self)
  if id == 0 {
    return
  }
  let m = mods(e)
  ev(id, 4, 7, i64(m_u16(e, "keyCode")), m, if m_bool(e, "isARepeat") { 1 } else { 0 }, 0)
  // typed text: not with Control or Command, and not control characters or the function keys'
  // private-use characters (arrows, F1...)
  if (m & (2 | 8)) != 0 {
    return
  }
  let chars = m_id(e, "characters")
  let s: raw.Ptr<u8> = if chars.is_null() { raw.null() } else { m_cstr(chars, "UTF8String") }
  if s.is_null() {
    return
  }
  let n = strlen(s)
  let text: raw.Ptr<i64> = raw.cast(auk__xmalloc((n + 2) * 8))
  var k: i64 = 0
  text.at(k) = 9
  k += 1
  var i: usize = 0
  while i < n {
    var len: i64 = 0
    let c = decode_char(s.offset(i), raw.addr_of(&len))
    if c >= 0x20 && c != 0x7f && !(c >= 0xf700 && c <= 0xf8ff) {
      var b: i64 = 0
      while b < len {
        text.at(k) = i64(s.at(i + usize(b)))
        k += 1
        b += 1
      }
    }
    i += usize(len)
  }
  if k > 1 {
    event(id, text, i32(k))
  }
  raw.free(text)
}

fn v_key_up(self: Id, cmd: Sel, e: Id) uses raw, ffi {
  let id = view_id(self)
  if id != 0 {
    ev(id, 3, 8, i64(m_u16(e, "keyCode")), mods(e), 0, 0)
  }
}

/// The close button asks; the program decides (by calling gui.close).
fn v_should_close(self: Id, cmd: Sel, sender: Id): bool uses raw, ffi {
  let id = view_id(self)
  if id != 0 {
    ev(id, 1, 1, 0, 0, 0, 0)
  }
  false
}

fn v_quit(self: Id, cmd: Sel, sender: Id) uses raw, ffi {
  let n = nhwins
  let ids: raw.Ptr<i64> = raw.cast(auk__xmalloc(usize(n + 1) * 8))
  var i: i64 = 0
  while i < n {
    ids.at(i) = hwins.offset(i).id
    i += 1
  }
  i = 0
  while i < n {
    ev(ids.at(i), 1, 1, 0, 0, 0, 0)
    i += 1
  }
  raw.free(ids)
}

fn v_did_resize(self: Id, cmd: Sel, note: Id) uses raw, ffi {
  let id = view_id(self)
  if id == 0 {
    return
  }
  var w: i64 = 0
  var h: i64 = 0
  var scale = 1.0
  metrics(self, raw.addr_of(&w), raw.addr_of(&h), raw.addr_of(&scale))
  let win = hwin(id)
  if !win.is_null() && !win.orphan {
    var b = abi.WireBuf {}
    let bp = raw.addr_of(&b)
    gui.auk__wire_put_i64(bp, id)
    gui.auk__wire_put_i64(bp, w)
    gui.auk__wire_put_i64(bp, h)
    gui.auk__wire_put_f64(bp, scale)
    send_to(win.owner, abi.WIRE_METRICS, bp)
    ev(id, 3, 2, w, h, 0, 0)
  }
}

fn v_did_become_key(self: Id, cmd: Sel, note: Id) uses raw, ffi {
  let id = view_id(self)
  if id != 0 {
    ev(id, 2, 10, 1, 0, 0, 0)
  }
}

fn v_did_resign_key(self: Id, cmd: Sel, note: Id) uses raw, ffi {
  let id = view_id(self)
  if id != 0 {
    ev(id, 2, 10, 0, 0, 0, 0)
  }
}

raw var the_view_class: Class = raw.null()

fn add_method(c: Class, name: raw.Ptr<u8>, imp: raw.Ptr<()>, types: raw.Ptr<u8>) {
  let f = sys.add_method
  let _ = f(c, sel(name), imp, types)
}

fn view_class(): Class uses raw, ffi {
  if !the_view_class.is_null() {
    return the_view_class
  }
  let alloc_class_pair = sys.alloc_class_pair
  let c = alloc_class_pair(cls("NSView"), "AukGuiView", 0)
  let yes: raw.Ptr<()> = raw.cast(raw.fn_of(v_yes))
  add_method(c, "isFlipped", yes, "B@:")
  add_method(c, "isOpaque", yes, "B@:")
  add_method(c, "acceptsFirstResponder", yes, "B@:")
  add_method(c, "acceptsFirstMouse:", raw.cast(raw.fn_of(v_yes1)), "B@:@")
  let down: raw.Ptr<()> = raw.cast(raw.fn_of(v_mouse_down))
  let up: raw.Ptr<()> = raw.cast(raw.fn_of(v_mouse_up))
  add_method(c, "mouseDown:", down, "v@:@")
  add_method(c, "mouseUp:", up, "v@:@")
  add_method(c, "rightMouseDown:", down, "v@:@")
  add_method(c, "rightMouseUp:", up, "v@:@")
  add_method(c, "otherMouseDown:", down, "v@:@")
  add_method(c, "otherMouseUp:", up, "v@:@")
  let moved: raw.Ptr<()> = raw.cast(raw.fn_of(v_mouse_moved))
  add_method(c, "mouseMoved:", moved, "v@:@")
  add_method(c, "mouseDragged:", moved, "v@:@")
  add_method(c, "rightMouseDragged:", moved, "v@:@")
  add_method(c, "otherMouseDragged:", moved, "v@:@")
  add_method(c, "scrollWheel:", raw.cast(raw.fn_of(v_scroll)), "v@:@")
  add_method(c, "keyDown:", raw.cast(raw.fn_of(v_key_down)), "v@:@")
  add_method(c, "keyUp:", raw.cast(raw.fn_of(v_key_up)), "v@:@")
  add_method(c, "windowShouldClose:", raw.cast(raw.fn_of(v_should_close)), "B@:@")
  add_method(c, "windowDidResize:", raw.cast(raw.fn_of(v_did_resize)), "v@:@")
  add_method(c, "windowDidChangeBackingProperties:", raw.cast(raw.fn_of(v_did_resize)), "v@:@")
  add_method(c, "windowDidBecomeKey:", raw.cast(raw.fn_of(v_did_become_key)), "v@:@")
  add_method(c, "windowDidResignKey:", raw.cast(raw.fn_of(v_did_resign_key)), "v@:@")
  add_method(c, "aukQuit:", raw.cast(raw.fn_of(v_quit)), "v@:@")
  let register_class_pair = sys.register_class_pair
  register_class_pair(c)
  the_view_class = c
  c
}

// ---- windows -----------------------------------------------------------------------------------

/// A new window for client: its id, or 0 with *why (static text).
fn new_window(client: u64, title: raw.Ptr<u8>, w: i64, h: i64, why: raw.Ptr<raw.Ptr<u8>>): i64 uses raw, ffi {
  let r = hrect(0.0, 0.0, float(w), float(h))
  // titled, closable, miniaturizable, resizable; buffered backing
  let win = m_window_init(m_id(cls("NSWindow"), "alloc"), r, 15, 2, false)
  if win.is_null() {
    why.store("gui.open: AppKit could not create a window")
    return 0
  }
  m_void_bool(win, "setReleasedWhenClosed:", false)
  let view = m_id_rect(m_id(view_class(), "alloc"), "initWithFrame:", r)
  // a layer-hosting view: AppKit leaves the layer's contents to us, and the compositor shows an
  // IOSurface straight from them
  let layer = m_id(m_id(cls("CALayer"), "alloc"), "init")
  m_void_id(layer, "setContentsGravity:", ns_string("topLeft"))
  m_void_bool(layer, "setOpaque:", true)
  let white = m_id(cls("NSColor"), "whiteColor")
  m_void_ptr(layer, "setBackgroundColor:", m_ptr(white, "CGColor"))
  // no fade when the contents change
  let nul = m_id(cls("NSNull"), "null")
  let actions = m_id(cls("NSMutableDictionary"), "dictionary")
  m_void_id_id(actions, "setObject:forKey:", nul, ns_string("contents"))
  m_void_id_id(actions, "setObject:forKey:", nul, ns_string("contentsScale"))
  m_void_id_id(actions, "setObject:forKey:", nul, ns_string("bounds"))
  m_void_id_id(actions, "setObject:forKey:", nul, ns_string("position"))
  m_void_id(layer, "setActions:", actions)
  m_void_id(view, "setLayer:", layer)
  m_void_bool(view, "setWantsLayer:", true)
  if nhwins == caphwins {
    caphwins = if caphwins == 0 { 4 } else { caphwins * 2 }
    hwins = raw.cast(auk__xrealloc(raw.cast(hwins), usize(caphwins) * raw.size_of<HWin>()))
  }
  let hw = hwins.offset(nhwins)
  nhwins += 1
  let id = next_win
  next_win += 1
  let tn = strlen(title)
  let t: raw.Ptr<u8> = raw.cast(auk__xmalloc(tn + 1))
  raw.copy(t, title, tn + 1)
  hw.store(HWin { id, win, view, title: t, owner: client, front: -1, layer })
  m_void_id(win, "setContentView:", view)
  m_void_id(win, "setDelegate:", view)
  m_void_bool(win, "setAcceptsMouseMovedEvents:", true)
  m_void_id(win, "setTitle:", ns_string(title))
  m_void(win, "center")
  m_void_id(win, "makeKeyAndOrderFront:", raw.null())
  let _ = m_bool_id(win, "makeFirstResponder:", view)
  m_void_bool(app(), "activateIgnoringOtherApps:", true)
  id
}

fn open_win(client: u64, title: raw.Ptr<u8>, w: i64, h: i64) uses raw, ffi {
  // take over an orphan with this title (the program was restarted by `auk run --live`)
  var adopt: i64 = 0
  var i: i64 = 0
  while i < nhwins {
    let x = hwins.offset(i)
    if x.orphan && strcmp(x.title, title) == 0 && (adopt == 0 || x.id < adopt) {
      adopt = x.id
    }
    i += 1
  }
  var id = adopt
  if adopt != 0 {
    // it keeps showing the old program's last frame until the new one presents
    let x = hwin(adopt)
    x.orphan = false
    x.owner = client
  } else {
    var why: raw.Ptr<u8> = raw.null()
    id = new_window(client, title, w, h, raw.addr_of(&why))
    if id == 0 {
      reply_err(client, why)
      return
    }
  }
  let x = hwin(id)
  let view: Id = if x.is_null() { raw.null() } else { x.view }
  var pw: i64 = 0
  var ph: i64 = 0
  var scale = 1.0
  metrics(view, raw.addr_of(&pw), raw.addr_of(&ph), raw.addr_of(&scale))
  var b = abi.WireBuf {}
  let bp = raw.addr_of(&b)
  gui.auk__wire_put_i64(bp, 0)
  gui.auk__wire_put_i64(bp, id)
  gui.auk__wire_put_i64(bp, pw)
  gui.auk__wire_put_i64(bp, ph)
  gui.auk__wire_put_f64(bp, scale)
  send_to(client, abi.WIRE_REPLY, bp)
  if adopt != 0 && !view.is_null() {
    let win = m_id(view, "window")
    m_void_id(win, "makeKeyAndOrderFront:", raw.null())
  }
}

/// A client left: with bye, its windows close; without, they become orphans. Orphans of earlier
/// clients close either way: this client had its chance to take them over.
fn gone(client: u64, bye: bool) uses raw, ffi {
  let fd = client_fd(client)
  if fd < 0 {
    return
  }
  if single_client {
    exit_now(0)
  }
  var k: i64 = 0
  var i: i64 = 0
  while i < nclients {
    if clients.offset(i).id != client {
      clients.at(k) = clients.at(i)
      k += 1
    }
    i += 1
  }
  nclients = k
  let close_ids: raw.Ptr<i64> = raw.cast(auk__xmalloc(usize(nhwins + 1) * 8))
  var nc: i64 = 0
  i = 0
  while i < nhwins {
    let w = hwins.offset(i)
    if !w.orphan && w.owner == client {
      if bye {
        close_ids.at(nc) = w.id
        nc += 1
      } else {
        w.orphan = true
      }
    } else if w.orphan && w.owner < client {
      close_ids.at(nc) = w.id
      nc += 1
    }
    i += 1
  }
  let _ = shutdown(fd, cfacts.SHUT_RDWR)
  let _ = close(fd)
  i = 0
  while i < nc {
    close_win(close_ids.at(i))
    i += 1
  }
  raw.free(close_ids)
}

fn handle(client: u64, m: raw.Ptr<abi.WireMsg>) uses raw, ffi {
  let r = raw.field_addr(m, .r)
  if m.op == abi.WIRE_OPEN {
    let w = gui.auk__wire_i64(r)
    let h = gui.auk__wire_i64(r)
    let n: i64 = if r.i < r.n { r.n - r.i } else { 0 }
    let title: raw.Ptr<u8> = raw.cast(auk__xmalloc(usize(n) + 1))
    raw.copy(title, r.b.offset(if r.i < r.n { r.i } else { r.n }), usize(n))
    title.at(n) = 0
    // invalid UTF-8 shown repaired, as the Rust host's lossy text did
    let t = str.auk_str_from_bytes(title, n)
    open_win(client, str.auk_str_cstr(t), w, h)
    auk_release(raw.cast(t))
    raw.free(title)
  } else if m.op == abi.WIRE_CLOSE {
    let id = gui.auk__wire_i64(r)
    let w = hwin(id)
    if !w.is_null() && !w.orphan && w.owner == client {
      close_win(id)
    }
  } else if m.op == abi.WIRE_PRESENT {
    let id = gui.auk__wire_i64(r)
    let fw = gui.auk__wire_i64(r)
    let fh = gui.auk__wire_i64(r)
    let buf = gui.auk__wire_i64(r)
    let seq = gui.auk__wire_i64(r)
    let n0 = gui.auk__wire_i64(r)
    let n: i64 = if n0 < 0 { 0 } else if n0 > 4096 { 4096 } else { n0 }
    let rects: raw.Ptr<i64> = raw.cast(auk__xmalloc(usize(n * 4 + 1) * 8))
    var k: i64 = 0
    while k < n * 4 {
      rects.at(k) = gui.auk__wire_i64(r)
      k += 1
    }
    let why = present(client, id, fw, fh, buf, rects, n, m.fd)
    m.fd = -1 // present took it
    raw.free(rects)
    var b = abi.WireBuf {}
    let bp = raw.addr_of(&b)
    gui.auk__wire_put_i64(bp, id)
    gui.auk__wire_put_i64(bp, seq)
    gui.auk__wire_put_i64(bp, if why.is_null() { 0 } else { 1 })
    if !why.is_null() {
      gui.auk__wire_put_str(bp, why, i64(strlen(why)))
      raw.free(why)
    }
    send_to(client, abi.WIRE_PRESENTED, bp)
  } else if m.op == abi.WIRE_BYE {
    gone(client, true)
  }
  if m.fd >= 0 {
    let _ = close(m.fd)
  }
}

fn run_jobs(info: raw.Ptr<()>) uses raw, ffi {
  loop {
    let _ = pthread_mutex_lock(raw.addr_of(&jobs_lock))
    let j = jobs_head
    if !j.is_null() {
      jobs_head = j.next
      if jobs_head.is_null() {
        jobs_tail = raw.null()
      }
    }
    let _ = pthread_mutex_unlock(raw.addr_of(&jobs_lock))
    if j.is_null() {
      return
    }
    let pool_push = sys.pool_push
    let pool = pool_push()
    if j.kind == JOB_ADD_CLIENT {
      if nclients == capclients {
        capclients = if capclients == 0 { 4 } else { capclients * 2 }
        clients = raw.cast(auk__xrealloc(raw.cast(clients), usize(capclients) * raw.size_of<HClient>()))
      }
      clients.at(nclients) = HClient { id: j.client, fd: j.fd }
      nclients += 1
    } else if j.kind == JOB_HANDLE {
      if trace_on {
        trace_add(1, j.t0)
      }
      let t1 = now_us()
      handle(j.client, raw.field_addr(j, .msg))
      raw.free(j.msg.body)
      if trace_on {
        trace_add(2, t1)
      }
    } else if j.kind == JOB_GONE {
      gone(j.client, false)
    } else if j.kind == JOB_RETRY {
      let w = hwin(j.id)
      if !w.is_null() {
        w.retry = false
      }
      if show(j.id) {
        schedule_retry(j.id)
      }
    }
    let pool_pop = sys.pool_pop
    pool_pop(pool)
    raw.free(j)
  }
}

// ---- running -----------------------------------------------------------------------------------

raw var next_client: u64 = 1

/// A client's requests, read on a thread of its own and run on the main thread.
fn client_reader(arg: raw.Ptr<()>): raw.Ptr<()> uses raw, ffi {
  let add: raw.Ptr<Job> = raw.cast(arg)
  let fd = add.fd
  let id = add.client
  submit(add)
  loop {
    let j = new_job(JOB_HANDLE)
    if gui.auk__wire_recv(fd, raw.field_addr(j, .msg)) <= 0 {
      raw.free(j)
      break
    }
    j.client = id
    j.t0 = now_us()
    submit(j)
  }
  let g = new_job(JOB_GONE)
  g.client = id
  submit(g)
  raw.null()
}

fn add_client(fd: i32) uses raw, ffi {
  gui.auk__wire_no_sigpipe(fd)
  let _ = auk__c_fcntl(fd, cfacts.F_SETFD, cfacts.FD_CLOEXEC)
  let j = new_job(JOB_ADD_CLIENT)
  j.client = raw.atomic_add(raw.addr_of(&next_client), 1, raw.Order.SeqCst)
  j.fd = fd
  spawn_detached(raw.fn_of(client_reader), raw.cast(j))
}

raw var listen_path: raw.Ptr<u8> = raw.null()
raw var listen_owner: i32 = 0
raw var listen_fd: i32 = -1

fn owner_watch(arg: raw.Ptr<()>): raw.Ptr<()> uses raw, ffi {
  loop {
    sleep_ns(300 * 1000000)
    if listen_owner <= 0 || kill(listen_owner, 0) != 0 {
      let _ = unlink(listen_path)
      exit_now(0)
    }
  }
  raw.null()
}

fn accept_loop(arg: raw.Ptr<()>): raw.Ptr<()> uses raw, ffi {
  loop {
    let c = accept(listen_fd, raw.null(), raw.null())
    if c >= 0 {
      add_client(c)
    }
  }
  raw.null()
}

raw let INT32_MAX: i64 = 2147483647

/// Accept clients on path; exit once the live parent (AUK_GUI_OWNER) is gone. Null, or why not
/// (malloc'd).
fn listen_on(path: raw.Ptr<u8>): raw.Ptr<u8> uses raw, ffi {
  var addr = cfacts.SockaddrUn {}
  let n = strlen(path)
  if n >= raw.size_of<cfacts.SockaddrUn>() - raw.offset_of<cfacts.SockaddrUn>(.sun_path) {
    var m = abi.StrBuf {}
    let mp = raw.addr_of(&m)
    str.auk__sb_put_cstr(mp, "gui host: socket path too long: ")
    str.auk__sb_put_cstr(mp, path)
    return str_fmt.auk__sb_take_cstr(mp)
  }
  gui_os.sun_set_family(raw.addr_of(&addr))
  raw.copy(raw.cast<u8>(raw.field_addr(raw.addr_of(&addr), .sun_path)), path, n)
  let fd = socket(cfacts.AF_UNIX, cfacts.SOCK_STREAM, 0)
  let _ = unlink(path)
  if fd < 0 || bind(fd, raw.cast(raw.addr_of(&addr)), u32(raw.size_of<cfacts.SockaddrUn>())) != 0 || listen(fd, 8) != 0 {
    let er = cfacts.errno()
    var m = abi.StrBuf {}
    let mp = raw.addr_of(&m)
    str.auk__sb_put_cstr(mp, "gui host: cannot listen on ")
    str.auk__sb_put_cstr(mp, path)
    str.auk__sb_put_cstr(mp, ": ")
    str.auk__sb_put_cstr(mp, strerror(er))
    return str_fmt.auk__sb_take_cstr(mp)
  }
  listen_fd = fd
  listen_path = raw.cast(auk__xmalloc(n + 1))
  raw.copy(listen_path, path, n + 1)
  let o = getenv("AUK_GUI_OWNER")
  var end: raw.Ptr<u8> = raw.null()
  let v: i64 = if o.is_null() { 0 } else { strtol(o, raw.addr_of(&end), 10) }
  listen_owner = if !o.is_null() && end.int() != o.int() && end.load() == 0 && v > 0 && v <= INT32_MAX { i32(v) } else { 0 }
  spawn_detached(raw.fn_of(owner_watch), raw.null())
  spawn_detached(raw.fn_of(accept_loop), raw.null())
  raw.null()
}

/// A menu bar with the application menu's Quit (⌘Q). Quitting asks every window to close (a Close
/// event each) rather than ending anything: the program decides.
fn menu(nsapp: Id) uses raw, ffi {
  let bar = m_id(m_id(cls("NSMenu"), "new"), "autorelease")
  let item = m_id(m_id(cls("NSMenuItem"), "new"), "autorelease")
  m_void_id(bar, "addItem:", item)
  let app_menu = m_id(m_id(cls("NSMenu"), "new"), "autorelease")
  let quit = m_menu_item_init(m_id(cls("NSMenuItem"), "alloc"), ns_string("Quit"), sel("aukQuit:"), ns_string("q"))
  let target = m_id(m_id(view_class(), "alloc"), "init")
  m_void_id(quit, "setTarget:", target)
  m_void_id(app_menu, "addItem:", m_id(quit, "autorelease"))
  m_void_id(item, "setSubmenu:", app_menu)
  m_void_id(nsapp, "setMainMenu:", bar)
}

fn start_app() uses raw, ffi {
  let nsapp = app()
  let _ = m_bool_isize(nsapp, "setActivationPolicy:", 0) // regular: a dock icon and a menu bar
  menu(nsapp)
  var ctx = SourceContext { perform: raw.fn_of(run_jobs) }
  let source_create = sys.source_create
  let source = source_create(raw.null(), 0, raw.addr_of(&ctx))
  let run_loop_main = sys.run_loop_main
  let rl = run_loop_main()
  let add_source = sys.add_source
  add_source(rl, source, sys.common_modes)
  wake_loop = rl
  wake_source = source
}

fn host_run(spec: raw.Ptr<u8>): i32 uses raw, ffi {
  let t = getenv("AUK_GUI_TRACE")
  trace_on = !t.is_null() && strcmp(t, "1") == 0
  var why = load_sys()
  if !why.is_null() {
    eprint_line(why, "")
    raw.free(why)
    return 1
  }
  start_app()
  if strncmp(spec, "fd:", 3) == 0 {
    var end: raw.Ptr<u8> = raw.null()
    let fd = strtol(spec.offset(3), raw.addr_of(&end), 10)
    if end.int() == spec.offset(3).int() || end.load() != 0 || fd < 0 || fd > INT32_MAX {
      eprint_line("gui host: bad AUK_GUI_HOST=", spec)
      return 1
    }
    single_client = true
    add_client(i32(fd))
  } else if strncmp(spec, "listen:", 7) == 0 {
    why = listen_on(spec.offset(7))
    if !why.is_null() {
      eprint_line(why, "")
      raw.free(why)
      return 1
    }
  } else {
    eprint_line("gui host: bad AUK_GUI_HOST=", spec)
    return 1
  }
  m_void(app(), "run")
  0
}

/// Run the window process. Returns an exit code only if it can't start.
pub export fn auk__gui_host_main(): i32 uses raw, ffi {
  let v = getenv("AUK_GUI_HOST")
  let n: usize = if v.is_null() { 0 } else { strlen(v) }
  let spec: raw.Ptr<u8> = raw.cast(auk__xmalloc(n + 1))
  if n > 0 {
    raw.copy(spec, v, n)
  }
  spec.at(n) = 0
  let _ = unsetenv("AUK_GUI_HOST")
  let r = host_run(spec)
  raw.free(spec)
  r
}

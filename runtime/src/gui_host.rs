//! The window process (gui.rs explains why there is one). A program's first `gui.open` runs its
//! own executable again with `DUCK_GUI_HOST` set. `duck_main_wrapper` (and the `duck` command)
//! see that variable and call `host_main` instead of running the program.
//!
//! The host's main thread runs AppKit. One thread per client reads its requests and hands them
//! to the main thread as jobs (a CFRunLoop source). All window state lives on the main thread,
//! and every reply and event is written from there, so the messages to a client stay in order.
//!
//! Each window maps the client's two shared frame buffers. Its view hosts a CALayer whose
//! contents are one of two IOSurfaces, which the compositor shows directly (no `drawRect:`). A
//! `PRESENT` copies the rectangle that changed (plus what the back surface missed since it was
//! last shown) from the buffer the client just wrote into the back surface, flips the layer to
//! it, and answers `PRESENTED`. The client then writes its other buffer.
//!
//! - `DUCK_GUI_HOST=fd:N`: one client on fd N (a socket pair). Exit when it closes.
//! - `DUCK_GUI_HOST=listen:PATH` (`duck run --live`): accept clients on a Unix socket. When a
//!   client goes away without `BYE`, its windows stay open as *orphans*. A later client's
//!   `OPEN` with the same title takes one over, and the next client to leave closes the rest.
//!   Exit when `DUCK_GUI_OWNER` (the live parent's pid) is gone.

/// Run the window process. Returns an exit code only if it can't start.
pub fn host_main() -> i32 {
    let spec = std::env::var("DUCK_GUI_HOST").unwrap_or_default();
    unsafe {
        std::env::remove_var("DUCK_GUI_HOST");
    }
    #[cfg(target_os = "macos")]
    {
        mac::run(&spec)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = spec;
        eprintln!("gui: windows are only supported on macOS so far");
        1
    }
}

#[cfg(target_os = "macos")]
mod mac {
    use std::cell::RefCell;
    use std::collections::{HashMap, VecDeque};
    use std::ffi::{CStr, CString, c_char, c_int, c_void};
    use std::ptr::null_mut;
    use std::sync::{Mutex, MutexGuard, OnceLock};
    use std::time::Duration;

    use crate::gui::wire;

    type Id = *mut c_void;
    type Sel = *mut c_void;
    type Class = *mut c_void;

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct Point {
        x: f64,
        y: f64,
    }

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct Size {
        w: f64,
        h: f64,
    }

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct Rect {
        o: Point,
        s: Size,
    }

    fn rect(x: f64, y: f64, w: f64, h: f64) -> Rect {
        Rect { o: Point { x, y }, s: Size { w, h } }
    }

    #[repr(C)]
    struct SourceContext {
        version: isize,
        info: *mut c_void,
        retain: *const c_void,
        release: *const c_void,
        copy_description: *const c_void,
        equal: *const c_void,
        hash: *const c_void,
        schedule: *const c_void,
        cancel: *const c_void,
        perform: unsafe extern "C" fn(*mut c_void),
    }

    /// The system functions, from `dlopen`ed libraries.
    struct Sys {
        get_class: unsafe extern "C" fn(*const c_char) -> Class,
        sel_register: unsafe extern "C" fn(*const c_char) -> Sel,
        msg_send: *mut c_void,
        alloc_class_pair: unsafe extern "C" fn(Class, *const c_char, usize) -> Class,
        add_method: unsafe extern "C" fn(Class, Sel, *const c_void, *const c_char) -> bool,
        register_class_pair: unsafe extern "C" fn(Class),
        pool_push: unsafe extern "C" fn() -> *mut c_void,
        pool_pop: unsafe extern "C" fn(*mut c_void),
        run_loop_main: unsafe extern "C" fn() -> *mut c_void,
        source_create: unsafe extern "C" fn(*const c_void, isize, *mut SourceContext) -> *mut c_void,
        add_source: unsafe extern "C" fn(*mut c_void, *mut c_void, *const c_void),
        source_signal: unsafe extern "C" fn(*mut c_void),
        wake_up: unsafe extern "C" fn(*mut c_void),
        common_modes: *const c_void,
        color_space: *mut c_void,
        cf_release: unsafe extern "C" fn(*const c_void),
        color_space_plist: unsafe extern "C" fn(*mut c_void) -> *const c_void,
        surface_create: unsafe extern "C" fn(Id) -> *mut c_void,
        surface_lock: unsafe extern "C" fn(*mut c_void, u32, *mut u32) -> c_int,
        surface_unlock: unsafe extern "C" fn(*mut c_void, u32, *mut u32) -> c_int,
        surface_base: unsafe extern "C" fn(*mut c_void) -> *mut c_void,
        surface_row_bytes: unsafe extern "C" fn(*mut c_void) -> usize,
        surface_in_use: unsafe extern "C" fn(*mut c_void) -> bool,
        surface_set_value: unsafe extern "C" fn(*mut c_void, Id, *const c_void),
        // for DUCK_GUI_SNAP (tests): an image of one of this process's own windows
        window_image: Option<unsafe extern "C" fn(Rect, u32, u32, u32) -> *mut c_void>,
        image_provider: unsafe extern "C" fn(*mut c_void) -> *mut c_void,
        provider_copy_data: unsafe extern "C" fn(*mut c_void) -> *const c_void,
        image_width: unsafe extern "C" fn(*mut c_void) -> usize,
        image_height: unsafe extern "C" fn(*mut c_void) -> usize,
        image_row_bytes: unsafe extern "C" fn(*mut c_void) -> usize,
        data_ptr: unsafe extern "C" fn(*const c_void) -> *const u8,
    }

    unsafe impl Send for Sys {}
    unsafe impl Sync for Sys {}

    static SYS: OnceLock<Sys> = OnceLock::new();

    unsafe fn load() -> Result<Sys, String> {
        unsafe {
            let open = |path: &CStr| -> Result<*mut c_void, String> {
                let h = libc::dlopen(path.as_ptr(), libc::RTLD_NOW | libc::RTLD_GLOBAL);
                if h.is_null() {
                    let why = CStr::from_ptr(libc::dlerror()).to_string_lossy().into_owned();
                    Err(format!("gui: cannot load {}: {why}", path.to_string_lossy()))
                } else {
                    Ok(h)
                }
            };
            let objc = open(c"/usr/lib/libobjc.A.dylib")?;
            let cf = open(c"/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")?;
            let cg = open(c"/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")?;
            open(c"/System/Library/Frameworks/AppKit.framework/AppKit")?;
            let ios = open(c"/System/Library/Frameworks/IOSurface.framework/IOSurface")?;
            let sym = |lib: *mut c_void, name: &CStr| -> Result<*mut c_void, String> {
                let p = libc::dlsym(lib, name.as_ptr());
                if p.is_null() { Err(format!("gui: missing system function {}", name.to_string_lossy())) } else { Ok(p) }
            };
            macro_rules! f {
                ($lib:expr, $name:literal) => {
                    std::mem::transmute(sym($lib, $name)?)
                };
            }
            let color_space_named: unsafe extern "C" fn(*const c_void) -> *mut c_void = f!(cg, c"CGColorSpaceCreateWithName");
            let srgb = *(sym(cg, c"kCGColorSpaceSRGB")? as *const *const c_void);
            Ok(Sys {
                get_class: f!(objc, c"objc_getClass"),
                sel_register: f!(objc, c"sel_registerName"),
                msg_send: sym(objc, c"objc_msgSend")?,
                alloc_class_pair: f!(objc, c"objc_allocateClassPair"),
                add_method: f!(objc, c"class_addMethod"),
                register_class_pair: f!(objc, c"objc_registerClassPair"),
                pool_push: f!(objc, c"objc_autoreleasePoolPush"),
                pool_pop: f!(objc, c"objc_autoreleasePoolPop"),
                run_loop_main: f!(cf, c"CFRunLoopGetMain"),
                source_create: f!(cf, c"CFRunLoopSourceCreate"),
                add_source: f!(cf, c"CFRunLoopAddSource"),
                source_signal: f!(cf, c"CFRunLoopSourceSignal"),
                wake_up: f!(cf, c"CFRunLoopWakeUp"),
                common_modes: *(sym(cf, c"kCFRunLoopCommonModes")? as *const *const c_void),
                color_space: color_space_named(srgb),
                cf_release: f!(cf, c"CFRelease"),
                color_space_plist: f!(cg, c"CGColorSpaceCopyPropertyList"),
                surface_create: f!(ios, c"IOSurfaceCreate"),
                surface_lock: f!(ios, c"IOSurfaceLock"),
                surface_unlock: f!(ios, c"IOSurfaceUnlock"),
                surface_base: f!(ios, c"IOSurfaceGetBaseAddress"),
                surface_row_bytes: f!(ios, c"IOSurfaceGetBytesPerRow"),
                surface_in_use: f!(ios, c"IOSurfaceIsInUse"),
                surface_set_value: f!(ios, c"IOSurfaceSetValue"),
                window_image: sym(cg, c"CGWindowListCreateImage").ok().map(|p| std::mem::transmute(p)),
                image_provider: f!(cg, c"CGImageGetDataProvider"),
                provider_copy_data: f!(cg, c"CGDataProviderCopyData"),
                image_width: f!(cg, c"CGImageGetWidth"),
                image_height: f!(cg, c"CGImageGetHeight"),
                image_row_bytes: f!(cg, c"CGImageGetBytesPerRow"),
                data_ptr: f!(cf, c"CFDataGetBytePtr"),
            })
        }
    }

    fn sys() -> &'static Sys {
        SYS.get().expect("gui host: AppKit not loaded")
    }

    fn sel(name: &CStr) -> Sel {
        unsafe { (sys().sel_register)(name.as_ptr()) }
    }

    fn class(name: &CStr) -> Class {
        unsafe { (sys().get_class)(name.as_ptr()) }
    }

    /// `[obj sel args...]` with the method's exact C signature (arm64 objc_msgSend isn't
    /// variadic; it must be called through the right function type).
    macro_rules! msg {
        ($ret:ty; $obj:expr, $sel:literal $(, $a:expr => $t:ty)*) => {{
            let f: unsafe extern "C" fn(Id, Sel $(, $t)*) -> $ret = std::mem::transmute(sys().msg_send);
            f($obj as Id, sel($sel) $(, $a)*)
        }};
    }

    unsafe fn ns_string(s: &str) -> Id {
        let c = CString::new(s.replace('\0', "")).unwrap_or_default();
        unsafe { msg![Id; class(c"NSString"), c"stringWithUTF8String:", c.as_ptr() => *const c_char] }
    }

    unsafe fn string_of(ns: Id) -> String {
        if ns.is_null() {
            return String::new();
        }
        unsafe {
            let p = msg![*const c_char; ns, c"UTF8String"];
            if p.is_null() { String::new() } else { CStr::from_ptr(p).to_string_lossy().into_owned() }
        }
    }

    unsafe fn app() -> Id {
        unsafe { msg![Id; class(c"NSApplication"), c"sharedApplication"] }
    }

    // ---- jobs: from the client threads to the main thread ----

    type Job = Box<dyn FnOnce() + Send>;

    struct Defer<F: FnMut()>(F);
    impl<F: FnMut()> Drop for Defer<F> {
        fn drop(&mut self) {
            (self.0)()
        }
    }

    static JOBS: Mutex<VecDeque<Job>> = Mutex::new(VecDeque::new());
    static WAKEUP: OnceLock<(usize, usize)> = OnceLock::new();

    fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
        m.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// `DUCK_GUI_TRACE=1`: time copying into surfaces, waiting for the main thread, and handling
    /// requests, and print the averages to stderr every half second.
    mod trace {
        use std::sync::atomic::{AtomicBool, AtomicU64, Ordering::Relaxed};
        use std::time::Instant;
        pub static ON: AtomicBool = AtomicBool::new(false);
        // (count, total µs, max µs) for draw, wait, handle
        static S: [AtomicU64; 9] = [const { AtomicU64::new(0) }; 9];
        static LAST: std::sync::Mutex<Option<Instant>> = std::sync::Mutex::new(None);
        pub fn on() -> bool {
            ON.load(Relaxed)
        }
        pub fn add(kind: usize, t0: Instant) {
            let us = t0.elapsed().as_micros() as u64;
            S[kind * 3].fetch_add(1, Relaxed);
            S[kind * 3 + 1].fetch_add(us, Relaxed);
            S[kind * 3 + 2].fetch_max(us, Relaxed);
            let mut last = LAST.lock().unwrap_or_else(|e| e.into_inner());
            let now = Instant::now();
            if last.is_none_or(|l| now - l >= std::time::Duration::from_millis(500)) {
                *last = Some(now);
                let mut line = String::from("gui trace:");
                for (k, name) in ["copy", "wait", "handle"].iter().enumerate() {
                    let n = S[k * 3].swap(0, Relaxed);
                    let tot = S[k * 3 + 1].swap(0, Relaxed);
                    let max = S[k * 3 + 2].swap(0, Relaxed);
                    if n > 0 {
                        line += &format!(" {name} {n}x avg {} µs max {max} µs;", tot / n);
                    }
                }
                eprintln!("{line}");
            }
        }
    }

    fn submit(job: Job) {
        lock(&JOBS).push_back(job);
        if let Some(&(source, run_loop)) = WAKEUP.get() {
            unsafe {
                (sys().source_signal)(source as *mut c_void);
                (sys().wake_up)(run_loop as *mut c_void);
            }
        }
    }

    unsafe extern "C" fn run_jobs(_: *mut c_void) {
        loop {
            let Some(job) = lock(&JOBS).pop_front() else { return };
            unsafe {
                let pool = (sys().pool_push)();
                job();
                (sys().pool_pop)(pool);
            }
        }
    }

    // ---- state (main thread only) ----

    /// A mapped shared frame buffer: `fw`×`fh` 0xffRRGGBB.
    struct Buf {
        ptr: *mut u32,
        fw: usize,
        fh: usize,
        fd: c_int,
    }

    impl Drop for Buf {
        fn drop(&mut self) {
            unsafe {
                libc::munmap(self.ptr.cast(), self.fw * self.fh * 4);
                libc::close(self.fd);
            }
        }
    }

    /// An IOSurface of `w`×`h` BGRA pixels (0xffRRGGBB as little-endian u32s).
    struct Surface {
        s: *mut c_void,
        w: usize,
        h: usize,
    }

    impl Drop for Surface {
        fn drop(&mut self) {
            unsafe { (sys().cf_release)(self.s) };
        }
    }

    impl Surface {
        unsafe fn new(w: usize, h: usize) -> Result<Surface, String> {
            unsafe {
                let num = |v: i64| msg![Id; class(c"NSNumber"), c"numberWithLongLong:", v => i64];
                let d = msg![Id; class(c"NSMutableDictionary"), c"dictionary"];
                for (k, v) in [("IOSurfaceWidth", w as i64), ("IOSurfaceHeight", h as i64), ("IOSurfaceBytesPerElement", 4), ("IOSurfacePixelFormat", 0x4247_5241)] {
                    msg![(); d, c"setObject:forKey:", num(v) => Id, ns_string(k) => Id];
                }
                let s = (sys().surface_create)(d);
                if s.is_null() {
                    return Err(format!("gui.present: cannot make a {w}x{h} surface"));
                }
                // the pixels are sRGB, so the compositor converts them for the display
                let cs = (sys().color_space_plist)(sys().color_space);
                if !cs.is_null() {
                    (sys().surface_set_value)(s, ns_string("IOSurfaceColorSpace"), cs);
                    (sys().cf_release)(cs);
                }
                Ok(Surface { s, w, h })
            }
        }
    }

    /// Add `r` to a list of areas, merging them all into one when the list gets long.
    fn add_area(v: &mut Vec<(usize, usize, usize, usize)>, r: (usize, usize, usize, usize)) {
        v.push(r);
        if v.len() > 8 {
            let all = v.iter().fold(r, |a, b| (a.0.min(b.0), a.1.min(b.1), a.2.max(b.2), a.3.max(b.3)));
            *v = vec![all];
        }
    }

    struct HWin {
        win: Id,
        view: Id,
        title: String,
        /// The client it belongs to, or (as an orphan) the generation of the one it did.
        owner: Owner,
        /// The client's two shared frame buffers, and the one it last presented.
        bufs: [Option<Buf>; 2],
        front: Option<usize>,
        /// The view's layer and its two IOSurfaces: the compositor shows one (`shown`) while a
        /// present updates the other, then the layer flips to it.
        layer: Id,
        surfs: [Option<Surface>; 2],
        shown: usize,
        /// Areas the other surface got since this one was last updated: what it lacks.
        stale: [Vec<(usize, usize, usize, usize)>; 2],
        /// Areas presented but not shown yet (the back surface was still in use), to copy from
        /// the client's latest buffer; and whether a retry is scheduled.
        pending: Vec<(usize, usize, usize, usize)>,
        retry: bool,
    }

    #[derive(Clone, Copy, PartialEq)]
    enum Owner {
        Client(u64),
        Orphan(u64),
    }

    struct Client {
        fd: c_int,
    }

    #[derive(Default)]
    struct State {
        wins: HashMap<i64, HWin>,
        by_view: HashMap<usize, i64>,
        clients: HashMap<u64, Client>,
        next_win: i64,
        /// One client at a time (fd mode): exit when it leaves.
        single: bool,
    }

    thread_local! {
        static ST: RefCell<State> = RefCell::new(State { next_win: 1, ..State::default() });
    }

    /// Use the state. Never call AppKit inside: it can call back into the view synchronously.
    fn st<R>(f: impl FnOnce(&mut State) -> R) -> R {
        ST.with(|s| f(&mut s.borrow_mut()))
    }

    fn send_to(client: u64, op: u8, body: wire::W) {
        if let Some(fd) = st(|s| s.clients.get(&client).map(|c| c.fd)) {
            let _ = wire::send(fd, op, &body.0, None);
        }
    }

    fn reply_ok(client: u64, body: wire::W) {
        let mut b = wire::W::default().i64(0);
        b.0.extend(body.0);
        send_to(client, wire::REPLY, b);
    }

    fn reply_err(client: u64, msg: &str) {
        send_to(client, wire::REPLY, wire::W::default().i64(1).str(msg));
    }

    /// Send an event to the window's client (an orphan has none; its close button closes it).
    fn event(id: i64, ev: &[i64]) {
        let owner = st(|s| s.wins.get(&id).map(|w| w.owner));
        match owner {
            Some(Owner::Client(c)) => {
                let mut b = wire::W::default().i64(id);
                for &v in ev {
                    b = b.i64(v);
                }
                send_to(c, wire::EVENT, b);
            }
            Some(Owner::Orphan(_)) if ev == [1] => unsafe { close_win(id) },
            _ => {}
        }
    }

    // ---- running ----

    pub fn run(spec: &str) -> i32 {
        if std::env::var_os("DUCK_GUI_TRACE").is_some_and(|v| v == "1") {
            trace::ON.store(true, std::sync::atomic::Ordering::Relaxed);
        }
        let sys = match unsafe { load() } {
            Ok(s) => s,
            Err(e) => {
                eprintln!("{e}");
                return 1;
            }
        };
        let _ = SYS.set(sys);
        unsafe { start_app() };
        if let Some(n) = spec.strip_prefix("fd:") {
            let Ok(fd) = n.parse::<c_int>() else {
                eprintln!("gui host: bad DUCK_GUI_HOST={spec}");
                return 1;
            };
            st(|s| s.single = true);
            add_client(fd);
        } else if let Some(path) = spec.strip_prefix("listen:") {
            if let Err(e) = listen(path) {
                eprintln!("{e}");
                return 1;
            }
        } else {
            eprintln!("gui host: bad DUCK_GUI_HOST={spec}");
            return 1;
        }
        unsafe { msg![(); app(), c"run"] };
        0
    }

    unsafe fn start_app() {
        unsafe {
            let s = sys();
            let nsapp = app();
            msg![bool; nsapp, c"setActivationPolicy:", 0isize => isize]; // regular: a dock icon and a menu bar
            menu(nsapp);
            let mut ctx = SourceContext {
                version: 0,
                info: null_mut(),
                retain: std::ptr::null(),
                release: std::ptr::null(),
                copy_description: std::ptr::null(),
                equal: std::ptr::null(),
                hash: std::ptr::null(),
                schedule: std::ptr::null(),
                cancel: std::ptr::null(),
                perform: run_jobs,
            };
            let source = (s.source_create)(std::ptr::null(), 0, &mut ctx);
            let run_loop = (s.run_loop_main)();
            (s.add_source)(run_loop, source, s.common_modes);
            let _ = WAKEUP.set((source as usize, run_loop as usize));
        }
    }

    /// Accept clients on `path`; exit once the live parent (`DUCK_GUI_OWNER`) is gone.
    fn listen(path: &str) -> Result<(), String> {
        let fd = unsafe {
            let fd = libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0);
            let (addr, len) = crate::gui::unix_addr(path).ok_or_else(|| format!("gui host: socket path too long: {path}"))?;
            let c = CString::new(path).unwrap_or_default();
            libc::unlink(c.as_ptr());
            if fd < 0 || libc::bind(fd, (&raw const addr).cast(), len) != 0 || libc::listen(fd, 8) != 0 {
                return Err(format!("gui host: cannot listen on {path}: {}", std::io::Error::last_os_error()));
            }
            fd
        };
        let owner: i32 = std::env::var("DUCK_GUI_OWNER").ok().and_then(|s| s.parse().ok()).unwrap_or(0);
        let p = path.to_string();
        std::thread::spawn(move || {
            loop {
                std::thread::sleep(Duration::from_millis(300));
                if owner <= 0 || unsafe { libc::kill(owner, 0) } != 0 {
                    let c = CString::new(p.as_str()).unwrap_or_default();
                    unsafe {
                        libc::unlink(c.as_ptr());
                        libc::_exit(0);
                    }
                }
            }
        });
        std::thread::spawn(move || {
            loop {
                let c = unsafe { libc::accept(fd, null_mut(), null_mut()) };
                if c >= 0 {
                    add_client(c);
                }
            }
        });
        Ok(())
    }

    static NEXT_CLIENT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

    /// Read a client's requests on a thread of its own, running each on the main thread.
    fn add_client(fd: c_int) {
        wire::no_sigpipe(fd);
        unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) };
        let id = NEXT_CLIENT.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        submit(Box::new(move || st(|s| drop(s.clients.insert(id, Client { fd })))));
        std::thread::spawn(move || {
            loop {
                match wire::recv(fd) {
                    Ok(Some(m)) => {
                        let (op, body, fdp) = (m.op, m.body, m.fd);
                        let t0 = std::time::Instant::now();
                        submit(Box::new(move || unsafe {
                            if trace::on() {
                                trace::add(1, t0);
                            }
                            let t1 = std::time::Instant::now();
                            handle(id, op, &body, fdp);
                            if trace::on() {
                                trace::add(2, t1);
                            }
                        }));
                    }
                    _ => break,
                }
            }
            submit(Box::new(move || unsafe { gone(id, false) }));
        });
    }

    unsafe fn handle(client: u64, op: u8, body: &[u8], fd: Option<c_int>) {
        let mut r = wire::R::new(body);
        unsafe {
            match op {
                wire::OPEN => {
                    let (w, h) = (r.i64(), r.i64());
                    let title = r.rest_str();
                    open(client, &title, w, h);
                }
                wire::CLOSE => {
                    let id = r.i64();
                    if st(|s| s.wins.get(&id).is_some_and(|w| w.owner == Owner::Client(client))) {
                        close_win(id);
                    }
                }
                wire::PRESENT => {
                    let (id, fw, fh, buf, seq, n) = (r.i64(), r.i64(), r.i64(), r.i64(), r.i64(), r.i64());
                    let rects: Vec<_> = (0..n.clamp(0, 4096)).map(|_| (r.i64(), r.i64(), r.i64(), r.i64())).collect();
                    let done = wire::W::default().i64(id).i64(seq);
                    match present(client, id, (fw as usize, fh as usize), buf, &rects, fd) {
                        Ok(()) => send_to(client, wire::PRESENTED, done.i64(0)),
                        Err(e) => send_to(client, wire::PRESENTED, done.i64(1).str(&e)),
                    }
                }
                wire::BYE => gone(client, true),
                _ => {}
            }
        }
    }

    /// A client left: with `bye`, its windows close; without, they become orphans. Orphans of
    /// earlier clients close either way: this client had its chance to take them over.
    unsafe fn gone(client: u64, bye: bool) {
        let (fd, single) = st(|s| (s.clients.get(&client).map(|c| c.fd), s.single));
        let Some(fd) = fd else { return };
        if single {
            unsafe { libc::_exit(0) };
        }
        let mut close = Vec::new();
        st(|s| {
            s.clients.remove(&client);
            for (&id, w) in s.wins.iter_mut() {
                match w.owner {
                    Owner::Client(c) if c == client => {
                        if bye {
                            close.push(id);
                        } else {
                            w.owner = Owner::Orphan(client);
                        }
                    }
                    Owner::Orphan(g) if g < client => close.push(id),
                    _ => {}
                }
            }
        });
        unsafe {
            libc::shutdown(fd, libc::SHUT_RDWR);
            libc::close(fd);
            for id in close {
                close_win(id);
            }
        }
    }

    unsafe fn open(client: u64, title: &str, w: i64, h: i64) {
        // take over an orphan with this title (the program was restarted by `duck run --live`)
        let adopt = st(|s| {
            let id = s.wins.iter().filter(|(_, x)| matches!(x.owner, Owner::Orphan(_)) && x.title == title).map(|(&id, _)| id).min()?;
            let x = s.wins.get_mut(&id)?;
            // it keeps showing the old program's last frame until the new one presents
            x.owner = Owner::Client(client);
            Some((id, x.view))
        });
        unsafe {
            let id = match adopt {
                Some((id, _)) => id,
                None => match new_window(client, title, w, h) {
                    Ok(id) => id,
                    Err(e) => return reply_err(client, &e),
                },
            };
            let view = st(|s| s.wins.get(&id).map(|x| x.view)).unwrap_or(null_mut());
            let (pw, ph, scale) = metrics(view);
            reply_ok(client, wire::W::default().i64(id).i64(pw).i64(ph).f64(scale));
            if adopt.is_some() {
                let win = msg![Id; view, c"window"];
                msg![(); win, c"makeKeyAndOrderFront:", null_mut::<c_void>() => Id];
            }
        }
    }

    unsafe fn new_window(client: u64, title: &str, w: i64, h: i64) -> Result<i64, String> {
        unsafe {
            let r = rect(0.0, 0.0, w as f64, h as f64);
            // titled, closable, miniaturizable, resizable; buffered backing
            let win = msg![Id; msg![Id; class(c"NSWindow"), c"alloc"], c"initWithContentRect:styleMask:backing:defer:",
                r => Rect, 15usize => usize, 2usize => usize, false => bool];
            if win.is_null() {
                return Err("gui.open: AppKit could not create a window".into());
            }
            msg![(); win, c"setReleasedWhenClosed:", false => bool];
            let view = msg![Id; msg![Id; view_class(), c"alloc"], c"initWithFrame:", r => Rect];
            // a layer-hosting view: AppKit leaves the layer's contents to us, and the compositor
            // shows an IOSurface straight from them
            let layer = msg![Id; msg![Id; class(c"CALayer"), c"alloc"], c"init"];
            msg![(); layer, c"setContentsGravity:", ns_string("topLeft") => Id];
            msg![(); layer, c"setOpaque:", true => bool];
            let white = msg![Id; class(c"NSColor"), c"whiteColor"];
            msg![(); layer, c"setBackgroundColor:", msg![*mut c_void; white, c"CGColor"] => *mut c_void];
            // no fade when the contents change
            let none = msg![Id; class(c"NSNull"), c"null"];
            let actions = msg![Id; class(c"NSMutableDictionary"), c"dictionary"];
            for k in ["contents", "contentsScale", "bounds", "position"] {
                msg![(); actions, c"setObject:forKey:", none => Id, ns_string(k) => Id];
            }
            msg![(); layer, c"setActions:", actions => Id];
            msg![(); view, c"setLayer:", layer => Id];
            msg![(); view, c"setWantsLayer:", true => bool];
            let id = st(|s| {
                let id = s.next_win;
                s.next_win += 1;
                s.by_view.insert(view as usize, id);
                s.wins.insert(id, HWin {
                    win,
                    view,
                    title: title.to_string(),
                    owner: Owner::Client(client),
                    bufs: [None, None],
                    front: None,
                    layer,
                    surfs: [None, None],
                    shown: 0,
                    stale: [vec![], vec![]],
                    pending: vec![],
                    retry: false,
                });
                id
            });
            msg![(); win, c"setContentView:", view => Id];
            msg![(); win, c"setDelegate:", view => Id];
            msg![(); win, c"setAcceptsMouseMovedEvents:", true => bool];
            msg![(); win, c"setTitle:", ns_string(title) => Id];
            msg![(); win, c"center"];
            msg![(); win, c"makeKeyAndOrderFront:", null_mut::<c_void>() => Id];
            msg![bool; win, c"makeFirstResponder:", view => Id];
            msg![(); app(), c"activateIgnoringOtherApps:", true => bool];
            Ok(id)
        }
    }

    unsafe fn close_win(id: i64) {
        let Some(w) = st(|s| {
            let w = s.wins.remove(&id)?;
            s.by_view.remove(&(w.view as usize));
            Some(w)
        }) else {
            return;
        };
        unsafe {
            if let Some(path) = std::env::var_os("DUCK_GUI_SNAP") {
                // show what's pending first
                st(|s| s.wins.insert(id, w));
                for _ in 0..50 {
                    if !show(id) {
                        break;
                    }
                    std::thread::sleep(Duration::from_millis(1));
                }
                let Some(w) = st(|s| s.wins.remove(&id)) else { return };
                snapshot(w.win, std::path::Path::new(&path));
                msg![(); w.win, c"setDelegate:", null_mut::<c_void>() => Id];
                msg![(); w.win, c"close"];
                msg![(); w.win, c"release"];
                msg![(); w.view, c"release"];
                msg![(); w.layer, c"release"];
                return;
            }
            msg![(); w.win, c"setDelegate:", null_mut::<c_void>() => Id];
            msg![(); w.win, c"close"];
            msg![(); w.win, c"release"];
            msg![(); w.view, c"release"];
            msg![(); w.layer, c"release"];
        }
    }

    /// Save an image of `win` as it is on screen to `path` (a binary PPM), for tests.
    unsafe fn snapshot(win: Id, path: &std::path::Path) {
        unsafe {
            let s = sys();
            let Some(capture) = s.window_image else {
                eprintln!("gui: DUCK_GUI_SNAP: no CGWindowListCreateImage on this system");
                return;
            };
            let flush: unsafe extern "C" fn(Id, Sel) = std::mem::transmute(s.msg_send);
            flush(class(c"CATransaction") as Id, sel(c"flush"));
            std::thread::sleep(Duration::from_millis(100));
            let num = msg![isize; win, c"windowNumber"] as u32;
            let null = rect(f64::INFINITY, f64::INFINITY, 0.0, 0.0);
            // including only this window, its contents without the frame, at full resolution
            let img = capture(null, 8, num, 1 | 8);
            if img.is_null() {
                eprintln!("gui: DUCK_GUI_SNAP: could not capture the window");
                return;
            }
            let (w, h, rb) = ((s.image_width)(img), (s.image_height)(img), (s.image_row_bytes)(img));
            let data = (s.provider_copy_data)((s.image_provider)(img));
            if !data.is_null() {
                let p = (s.data_ptr)(data);
                let mut out = format!("P6\n{w} {h}\n255\n").into_bytes();
                for y in 0..h {
                    for x in 0..w {
                        let px = p.add(y * rb + x * 4);
                        // BGRA in memory
                        out.extend_from_slice(&[*px.add(2), *px.add(1), *px]);
                    }
                }
                let _ = std::fs::write(path, out);
                (s.cf_release)(data);
            }
            (s.cf_release)(img);
        }
    }

    /// Copy a rectangle of the client's frame into the window's buffer and redraw that part.
    /// Take a present: remember the area that changed and show it now if the back surface is
    /// free, or as soon as it is. Either way the client may write its other buffer at once: from
    /// here on this process reads only buffer `buf`, which the client leaves alone until its
    /// next present is answered.
    unsafe fn present(client: u64, id: i64, (fw, fh): (usize, usize), buf: i64, rects: &[(i64, i64, i64, i64)], fd: Option<c_int>) -> Result<(), String> {
        let close = |fd: Option<c_int>| {
            if let Some(fd) = fd {
                unsafe { libc::close(fd) };
            }
        };
        let len = fw.checked_mul(fh).and_then(|n| n.checked_mul(4)).filter(|&n| n > 0);
        let (Some(len), Ok(i @ 0..=1)) = (len, usize::try_from(buf)) else {
            close(fd);
            return Err("gui.present: bad frame".into());
        };
        let clip = |&(x, y, w, h): &(i64, i64, i64, i64)| (x.max(0) as usize, y.max(0) as usize, ((x + w).max(0) as usize).min(fw), ((y + h).max(0) as usize).min(fh));
        st(|s| -> Result<(), String> {
            let Some(win) = s.wins.get_mut(&id).filter(|w| w.owner == Owner::Client(client)) else {
                close(fd);
                return Err(format!("gui.present: window {id} is closed"));
            };
            if let Some(fd) = fd {
                let p = unsafe { libc::mmap(null_mut(), len, libc::PROT_READ, libc::MAP_SHARED, fd, 0) };
                if p == libc::MAP_FAILED {
                    unsafe { libc::close(fd) };
                    return Err(format!("gui.present: cannot map the frame: {}", std::io::Error::last_os_error()));
                }
                win.bufs[i] = Some(Buf { ptr: p.cast(), fw, fh, fd });
            }
            if !win.bufs[i].as_ref().is_some_and(|b| (b.fw, b.fh) == (fw, fh)) {
                return Err("gui.present: no frame memory of that size".into());
            }
            if win.front.and_then(|f| win.bufs[f].as_ref()).is_some_and(|b| (b.fw, b.fh) != (fw, fh)) {
                win.pending.clear(); // a new size: the new surfaces get everything anyway
            }
            win.front = Some(i);
            for r in rects.iter().map(clip) {
                if r.0 < r.2 && r.1 < r.3 {
                    add_area(&mut win.pending, r);
                }
            }
            Ok(())
        })?;
        if unsafe { show(id) } {
            schedule_retry(id);
        }
        Ok(())
    }

    /// Try `show` again shortly (once per window at a time).
    fn schedule_retry(id: i64) {
        let first = st(|s| s.wins.get_mut(&id).is_some_and(|w| !std::mem::replace(&mut w.retry, true)));
        if first {
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(1));
                submit(Box::new(move || {
                    st(|s| s.wins.get_mut(&id).map(|w| w.retry = false));
                    if unsafe { show(id) } {
                        schedule_retry(id);
                    }
                }));
            });
        }
    }

    /// Bring the back surface up to date from the client's latest buffer and flip the layer to
    /// it. Returns true if something is still pending because the compositor still had that
    /// surface.
    unsafe fn show(id: i64) -> bool {
        let t0 = std::time::Instant::now();
        let _t = Defer(move || {
            if trace::on() {
                trace::add(0, t0);
            }
        });
        // AppKit isn't called while the state is borrowed: it may call back into the view
        let Some(view) = st(|s| s.wins.get(&id).map(|w| w.view)) else { return false };
        let scale = unsafe { backing_scale(view) };
        let flip = st(|s| -> Result<Option<(Id, *mut c_void)>, String> {
            let Some(win) = s.wins.get_mut(&id) else { return Ok(None) };
            let Some(src) = win.front.and_then(|f| win.bufs[f].as_ref()) else { return Ok(None) };
            let (fw, fh) = (src.fw, src.fh);
            // new surfaces for a new size; they lack everything
            if !win.surfs[0].as_ref().is_some_and(|s| (s.w, s.h) == (fw, fh)) {
                win.surfs = [Some(unsafe { Surface::new(fw, fh)? }), Some(unsafe { Surface::new(fw, fh)? })];
                win.stale = [vec![(0, 0, fw, fh)], vec![(0, 0, fw, fh)]];
                win.pending = vec![(0, 0, fw, fh)];
            }
            if win.pending.is_empty() {
                return Ok(None);
            }
            let back = 1 - win.shown;
            let surf = win.surfs[back].as_ref().unwrap();
            unsafe {
                // the compositor keeps the surface it showed last until the next refresh
                if (sys().surface_in_use)(surf.s) {
                    return Ok(Some((null_mut(), null_mut())));
                }
                (sys().surface_lock)(surf.s, 0, null_mut());
                let base = (sys().surface_base)(surf.s) as *mut u8;
                let rb = (sys().surface_row_bytes)(surf.s);
                let copy = |(x0, y0, x1, y1): (usize, usize, usize, usize)| {
                    for row in y0..y1 {
                        let from = src.ptr.add(row * fw + x0);
                        let to = base.add(row * rb + x0 * 4) as *mut u32;
                        std::ptr::copy_nonoverlapping(from, to, x1 - x0);
                    }
                };
                let inside = |a: &(usize, usize, usize, usize)| win.pending.iter().any(|r| a.0 >= r.0 && a.1 >= r.1 && a.2 <= r.2 && a.3 <= r.3);
                for a in win.stale[back].iter().filter(|a| !inside(a)) {
                    copy(*a);
                }
                for &a in &win.pending {
                    copy(a);
                }
                (sys().surface_unlock)(surf.s, 0, null_mut());
            }
            win.stale[back].clear();
            let shown = win.shown;
            for a in std::mem::take(&mut win.pending) {
                add_area(&mut win.stale[shown], a);
            }
            win.shown = back;
            Ok(Some((win.layer, surf.s)))
        });
        match flip {
            Ok(Some((layer, _))) if layer.is_null() => true,
            Ok(Some((layer, surf))) => {
                unsafe {
                    msg![(); layer, c"setContentsScale:", scale => f64];
                    msg![(); layer, c"setContents:", surf => *mut c_void];
                }
                false
            }
            Ok(None) => false,
            Err(e) => {
                eprintln!("{e}");
                false
            }
        }
    }

    // ---- menu ----

    /// A menu bar with the application menu's Quit (⌘Q). Quitting asks every window to close
    /// (a `Close` event each) rather than ending anything: the program decides.
    unsafe fn menu(nsapp: Id) {
        unsafe {
            let bar = msg![Id; msg![Id; class(c"NSMenu"), c"new"], c"autorelease"];
            let item = msg![Id; msg![Id; class(c"NSMenuItem"), c"new"], c"autorelease"];
            msg![(); bar, c"addItem:", item => Id];
            let app_menu = msg![Id; msg![Id; class(c"NSMenu"), c"new"], c"autorelease"];
            let quit = msg![Id; msg![Id; class(c"NSMenuItem"), c"alloc"], c"initWithTitle:action:keyEquivalent:",
                ns_string("Quit") => Id, sel(c"duckQuit:") => Sel, ns_string("q") => Id];
            let target = msg![Id; msg![Id; view_class(), c"alloc"], c"init"];
            msg![(); quit, c"setTarget:", target => Id];
            msg![(); app_menu, c"addItem:", msg![Id; quit, c"autorelease"] => Id];
            msg![(); item, c"setSubmenu:", app_menu => Id];
            msg![(); nsapp, c"setMainMenu:", bar => Id];
        }
    }

    // ---- the view class: draws the window's buffer, reports input ----

    static VIEW_CLASS: OnceLock<usize> = OnceLock::new();

    fn view_class() -> Class {
        *VIEW_CLASS.get_or_init(|| unsafe {
            let s = sys();
            let cls = (s.alloc_class_pair)(class(c"NSView"), c"DuckGuiView".as_ptr(), 0);
            let add = |name: &CStr, imp: *const c_void, types: &CStr| {
                (s.add_method)(cls, sel(name), imp, types.as_ptr());
            };
            add(c"isFlipped", yes as *const c_void, c"B@:");
            add(c"isOpaque", yes as *const c_void, c"B@:");
            add(c"acceptsFirstResponder", yes as *const c_void, c"B@:");
            add(c"acceptsFirstMouse:", yes1 as *const c_void, c"B@:@");
            for name in [c"mouseDown:", c"rightMouseDown:", c"otherMouseDown:"] {
                add(name, mouse_down as *const c_void, c"v@:@");
            }
            for name in [c"mouseUp:", c"rightMouseUp:", c"otherMouseUp:"] {
                add(name, mouse_up as *const c_void, c"v@:@");
            }
            for name in [c"mouseMoved:", c"mouseDragged:", c"rightMouseDragged:", c"otherMouseDragged:"] {
                add(name, mouse_moved as *const c_void, c"v@:@");
            }
            add(c"scrollWheel:", scroll as *const c_void, c"v@:@");
            add(c"keyDown:", key_down as *const c_void, c"v@:@");
            add(c"keyUp:", key_up as *const c_void, c"v@:@");
            add(c"windowShouldClose:", should_close as *const c_void, c"B@:@");
            add(c"windowDidResize:", did_resize as *const c_void, c"v@:@");
            add(c"windowDidChangeBackingProperties:", did_resize as *const c_void, c"v@:@");
            add(c"windowDidBecomeKey:", did_become_key as *const c_void, c"v@:@");
            add(c"windowDidResignKey:", did_resign_key as *const c_void, c"v@:@");
            add(c"duckQuit:", quit as *const c_void, c"v@:@");
            (s.register_class_pair)(cls);
            cls as usize
        }) as Class
    }

    extern "C" fn yes(_: Id, _: Sel) -> bool {
        true
    }

    extern "C" fn yes1(_: Id, _: Sel, _: Id) -> bool {
        true
    }

    fn view_id(view: Id) -> Option<i64> {
        st(|s| s.by_view.get(&(view as usize)).copied())
    }

    /// Shift, Control, Option, Command as bits 1, 2, 4, 8.
    unsafe fn mods(ev: Id) -> i64 {
        let f = unsafe { msg![usize; ev, c"modifierFlags"] };
        let mut m = 0;
        for (bit, flag) in [(1, 1 << 17), (2, 1 << 18), (4, 1 << 19), (8, 1 << 20)] {
            if f & flag != 0 {
                m |= bit;
            }
        }
        m
    }

    unsafe fn backing_scale(view: Id) -> f64 {
        unsafe {
            let win = msg![Id; view, c"window"];
            if win.is_null() { 1.0 } else { msg![f64; win, c"backingScaleFactor"] }
        }
    }

    /// Content size in physical pixels, and the scale.
    unsafe fn metrics(view: Id) -> (i64, i64, f64) {
        if view.is_null() {
            return (0, 0, 1.0);
        }
        unsafe {
            let r = msg![Rect; view, c"bounds"];
            let scale = backing_scale(view);
            ((r.s.w * scale).round() as i64, (r.s.h * scale).round() as i64, scale)
        }
    }

    /// Where the mouse is, in physical pixels from the content's top-left.
    unsafe fn location(view: Id, ev: Id) -> (i64, i64) {
        unsafe {
            let p = msg![Point; ev, c"locationInWindow"];
            let p = msg![Point; view, c"convertPoint:fromView:", p => Point, null_mut::<c_void>() => Id];
            let scale = backing_scale(view);
            ((p.x * scale).floor() as i64, (p.y * scale).floor() as i64)
        }
    }

    extern "C" fn mouse_down(this: Id, _: Sel, ev: Id) {
        if let Some(id) = view_id(this) {
            unsafe {
                let (x, y) = location(this, ev);
                event(id, &[4, msg![isize; ev, c"buttonNumber"] as i64, x, y, mods(ev)]);
            }
        }
    }

    extern "C" fn mouse_up(this: Id, _: Sel, ev: Id) {
        if let Some(id) = view_id(this) {
            unsafe {
                let (x, y) = location(this, ev);
                event(id, &[5, msg![isize; ev, c"buttonNumber"] as i64, x, y, mods(ev)]);
            }
        }
    }

    extern "C" fn mouse_moved(this: Id, _: Sel, ev: Id) {
        if let Some(id) = view_id(this) {
            unsafe {
                let (x, y) = location(this, ev);
                event(id, &[3, x, y]);
            }
        }
    }

    extern "C" fn scroll(this: Id, _: Sel, ev: Id) {
        if let Some(id) = view_id(this) {
            unsafe {
                let (mut dx, mut dy) = (msg![f64; ev, c"scrollingDeltaX"], msg![f64; ev, c"scrollingDeltaY"]);
                if !msg![bool; ev, c"hasPreciseScrollingDeltas"] {
                    // a wheel's notches: about a line each
                    dx *= 16.0;
                    dy *= 16.0;
                }
                let scale = backing_scale(this);
                event(id, &[6, (dx * scale * 100.0) as i64, (dy * scale * 100.0) as i64]);
            }
        }
    }

    extern "C" fn key_down(this: Id, _: Sel, ev: Id) {
        if let Some(id) = view_id(this) {
            unsafe {
                let m = mods(ev);
                event(id, &[7, msg![u16; ev, c"keyCode"] as i64, m, msg![bool; ev, c"isARepeat"] as i64]);
                // typed text: not with Control or Command, and not control characters or the
                // function keys' private-use characters (arrows, F1...)
                if m & (2 | 8) == 0 {
                    let s: String = string_of(msg![Id; ev, c"characters"])
                        .chars()
                        .filter(|&c| c >= ' ' && c != '\u{7f}' && !('\u{f700}'..='\u{f8ff}').contains(&c))
                        .collect();
                    if !s.is_empty() {
                        let mut e = vec![9];
                        e.extend(s.bytes().map(|b| b as i64));
                        event(id, &e);
                    }
                }
            }
        }
    }

    extern "C" fn key_up(this: Id, _: Sel, ev: Id) {
        if let Some(id) = view_id(this) {
            unsafe { event(id, &[8, msg![u16; ev, c"keyCode"] as i64, mods(ev)]) };
        }
    }

    /// The close button asks; the program decides (by calling `gui.close`).
    extern "C" fn should_close(this: Id, _: Sel, _: Id) -> bool {
        if let Some(id) = view_id(this) {
            event(id, &[1]);
        }
        false
    }

    extern "C" fn quit(_: Id, _: Sel, _: Id) {
        let ids: Vec<i64> = st(|s| s.wins.keys().copied().collect());
        for id in ids {
            event(id, &[1]);
        }
    }

    extern "C" fn did_resize(this: Id, _: Sel, _: Id) {
        if let Some(id) = view_id(this) {
            let (w, h, scale) = unsafe { metrics(this) };
            let owner = st(|s| s.wins.get(&id).map(|w| w.owner));
            if let Some(Owner::Client(c)) = owner {
                send_to(c, wire::METRICS, wire::W::default().i64(id).i64(w).i64(h).f64(scale));
                event(id, &[2, w, h]);
            }
        }
    }

    extern "C" fn did_become_key(this: Id, _: Sel, _: Id) {
        if let Some(id) = view_id(this) {
            event(id, &[10, 1]);
        }
    }

    extern "C" fn did_resign_key(this: Id, _: Sel, _: Id) {
        if let Some(id) = view_id(this) {
            event(id, &[10, 0]);
        }
    }
}

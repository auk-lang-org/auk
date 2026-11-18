//! Windows (`uses gui`): open native windows, show pixels drawn by Auk code, and read input.
//! (Drawing into a frame natively is the pure `pixels` module, pixels.rs.)
//!
//! **A separate window process.** The program never loads a window system itself. The first
//! `gui.open` starts a *host*: this same executable run again (`posix_spawn`, a fresh exec)
//! with `AUK_GUI_HOST` set, which owns every native window (gui_host.rs). The two talk over a
//! Unix socket (the `wire` protocol below), and pixels go through shared memory. This keeps
//! Apple's frameworks out of processes that were forked without exec, as `auk run --live`
//! children are (they don't support that), and leaves the program's main thread alone.
//!
//! - Normally the host is the program's own child, on a socket pair, and it exits (closing the
//!   windows) when the program ends.
//! - Under `auk run --live`, the parent sets `AUK_GUI_SESSION` to a socket path. The first
//!   child starts a host listening there, and later children (after a restart) connect to the
//!   same host. A child that ends without saying goodbye (killed for a restart, or crashed)
//!   leaves its windows open, and the next child's `gui.open` with the same title takes over
//!   the window. A child that returns normally says goodbye (`shutdown`) and its windows close.
//!
//! A window is an int id (the host's), so it can be copied between tasks. A reader thread
//! queues each window's events, which `next_event` takes.

use std::collections::{HashMap, HashSet, VecDeque};
use std::ffi::{CString, c_char, c_int};
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::{Condvar, Mutex, MutexGuard};
use std::time::Duration;

use crate::err::err_msg;
use crate::*;

// ---- the wire protocol (shared with gui_host.rs) --------------------------------------------

/// Messages are a u32 length (of what follows), an op byte, then fields: i64/f64 little-endian
/// and a string as the rest of the message. A file descriptor can ride along (SCM_RIGHTS) with
/// the first bytes of a message.
pub(crate) mod wire {
    use std::io;

    /// Client → host: `w, h, title` → REPLY `id, w, h, scale` (physical pixels).
    pub const OPEN: u8 = 1;
    /// Client → host: `id`. No reply.
    pub const CLOSE: u8 = 2;
    /// Client → host: `id, fw, fh, buf, seq, n`, then `n` rectangles `x, y, w, h`: show shared
    /// buffer `buf` (0 or 1, an `fw`×`fh` frame of 0xffRRGGBB; its fd comes along whenever it is
    /// new), of which those rectangles changed. → PRESENTED as soon as the host has taken it: from then on it reads
    /// only this buffer (until the next PRESENT), so the client may write the other one.
    pub const PRESENT: u8 = 3;
    /// Client → host: close my windows; I'm ending normally. No reply.
    pub const BYE: u8 = 4;
    /// Host → client: `status` (0 ok, 1 error), then the result, or the error message.
    pub const REPLY: u8 = 100;
    /// Host → client: `id`, then the event's ints (as `gui.next_event` decodes them).
    pub const EVENT: u8 = 101;
    /// Host → client: `id, w, h, scale`: the window's current size.
    pub const METRICS: u8 = 102;
    /// Host → client: `id, seq, status` (0 ok, 1 error, then the message): PRESENT `seq` is done.
    pub const PRESENTED: u8 = 103;

    pub struct Msg {
        pub op: u8,
        pub body: Vec<u8>,
        pub fd: Option<i32>,
    }

    #[derive(Default)]
    pub struct W(pub Vec<u8>);

    impl W {
        pub fn i64(mut self, v: i64) -> W {
            self.0.extend_from_slice(&v.to_le_bytes());
            self
        }
        pub fn f64(self, v: f64) -> W {
            self.i64(v.to_bits() as i64)
        }
        pub fn str(mut self, s: &str) -> W {
            self.0.extend_from_slice(s.as_bytes());
            self
        }
    }

    pub struct R<'a> {
        b: &'a [u8],
        i: usize,
    }

    impl<'a> R<'a> {
        pub fn new(b: &'a [u8]) -> R<'a> {
            R { b, i: 0 }
        }
        /// The next i64 (0 past the end).
        pub fn i64(&mut self) -> i64 {
            let v = self.b.get(self.i..self.i + 8).map_or(0, |s| i64::from_le_bytes(s.try_into().unwrap()));
            self.i += 8;
            v
        }
        pub fn f64(&mut self) -> f64 {
            f64::from_bits(self.i64() as u64)
        }
        pub fn rest_str(&mut self) -> String {
            let s = String::from_utf8_lossy(self.b.get(self.i..).unwrap_or(&[])).into_owned();
            self.i = self.b.len();
            s
        }
        pub fn rest_i64s(&mut self) -> Vec<i64> {
            let mut v = Vec::new();
            while self.i + 8 <= self.b.len() {
                v.push(self.i64());
            }
            v
        }
    }

    /// Don't die of SIGPIPE when the other side has gone; get EPIPE instead.
    pub fn no_sigpipe(fd: i32) {
        let one: libc::c_int = 1;
        unsafe {
            libc::setsockopt(fd, libc::SOL_SOCKET, libc::SO_NOSIGPIPE, (&raw const one).cast(), size_of::<libc::c_int>() as u32);
        }
    }

    /// Send one message, with `pass` (an fd) attached to its first bytes.
    pub fn send(fd: i32, op: u8, body: &[u8], pass: Option<i32>) -> io::Result<()> {
        let mut buf = Vec::with_capacity(body.len() + 5);
        buf.extend_from_slice(&((body.len() + 1) as u32).to_le_bytes());
        buf.push(op);
        buf.extend_from_slice(body);
        let mut off = 0;
        let mut pass = pass;
        while off < buf.len() {
            let n = unsafe {
                let mut iov = libc::iovec { iov_base: buf[off..].as_ptr() as *mut _, iov_len: buf.len() - off };
                let mut msg: libc::msghdr = std::mem::zeroed();
                msg.msg_iov = &mut iov;
                msg.msg_iovlen = 1;
                let mut cbuf = [0u8; 64];
                if let Some(p) = pass {
                    msg.msg_control = cbuf.as_mut_ptr().cast();
                    msg.msg_controllen = libc::CMSG_SPACE(size_of::<i32>() as u32) as _;
                    let c = libc::CMSG_FIRSTHDR(&msg);
                    (*c).cmsg_level = libc::SOL_SOCKET;
                    (*c).cmsg_type = libc::SCM_RIGHTS;
                    (*c).cmsg_len = libc::CMSG_LEN(size_of::<i32>() as u32) as _;
                    std::ptr::write_unaligned(libc::CMSG_DATA(c) as *mut i32, p);
                }
                libc::sendmsg(fd, &msg, 0)
            };
            if n < 0 {
                let e = io::Error::last_os_error();
                if e.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(e);
            }
            pass = None;
            off += n as usize;
        }
        Ok(())
    }

    /// Read exactly `buf.len()` bytes, picking up an fd if one comes. Ok(false) on EOF at the
    /// very start.
    fn read_full(fd: i32, buf: &mut [u8], got_fd: &mut Option<i32>) -> io::Result<bool> {
        let mut off = 0;
        while off < buf.len() {
            let n = unsafe {
                let mut iov = libc::iovec { iov_base: buf[off..].as_mut_ptr().cast(), iov_len: buf.len() - off };
                let mut msg: libc::msghdr = std::mem::zeroed();
                msg.msg_iov = &mut iov;
                msg.msg_iovlen = 1;
                let mut cbuf = [0u8; 64];
                msg.msg_control = cbuf.as_mut_ptr().cast();
                msg.msg_controllen = cbuf.len() as _;
                let n = libc::recvmsg(fd, &mut msg, 0);
                if n > 0 && msg.msg_controllen as usize >= size_of::<libc::cmsghdr>() {
                    let c = libc::CMSG_FIRSTHDR(&msg);
                    if !c.is_null() && (*c).cmsg_level == libc::SOL_SOCKET && (*c).cmsg_type == libc::SCM_RIGHTS {
                        let p = std::ptr::read_unaligned(libc::CMSG_DATA(c) as *const i32);
                        if let Some(old) = got_fd.replace(p) {
                            libc::close(old);
                        }
                    }
                }
                n
            };
            if n == 0 {
                if off == 0 {
                    return Ok(false);
                }
                return Err(io::ErrorKind::UnexpectedEof.into());
            }
            if n < 0 {
                let e = io::Error::last_os_error();
                if e.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(e);
            }
            off += n as usize;
        }
        Ok(true)
    }

    /// The next message; None at EOF.
    pub fn recv(fd: i32) -> io::Result<Option<Msg>> {
        let mut got_fd = None;
        let mut len = [0u8; 4];
        if !read_full(fd, &mut len, &mut got_fd)? {
            return Ok(None);
        }
        let n = u32::from_le_bytes(len) as usize;
        if n == 0 || n > 64 << 20 {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "gui: bad message length"));
        }
        let mut body = vec![0u8; n];
        if !read_full(fd, &mut body, &mut got_fd)? {
            return Err(io::ErrorKind::UnexpectedEof.into());
        }
        let op = body.remove(0);
        Ok(Some(Msg { op, body, fd: got_fd }))
    }
}

// ---- windows and their events (the client side) ---------------------------------------------

struct Win {
    events: VecDeque<Vec<i64>>,
    /// Content size in physical pixels.
    w: i64,
    h: i64,
    scale: f64,
}

#[derive(Default)]
struct Wins {
    open: HashMap<i64, Win>,
    /// Closed by this program: the host's late events for them are dropped.
    closed: HashSet<i64>,
}

static WINS: Mutex<Option<Wins>> = Mutex::new(None);
/// Signalled whenever an event is queued or a window closes.
static EV_CV: Condvar = Condvar::new();

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

fn with_wins<R>(f: impl FnOnce(&mut Wins) -> R) -> R {
    f(lock(&WINS).get_or_insert_with(Wins::default))
}

fn win_entry(ws: &mut Wins, id: i64) -> Option<&mut Win> {
    if ws.closed.contains(&id) {
        return None;
    }
    Some(ws.open.entry(id).or_insert_with(|| Win { events: VecDeque::new(), w: 0, h: 0, scale: 1.0 }))
}

/// Queue an event (from the host). A burst of motion or resizing only keeps its latest.
fn push_event(id: i64, ev: Vec<i64>) {
    with_wins(|ws| {
        if let Some(w) = win_entry(ws, id) {
            if let (Some(&k), Some(last)) = (ev.first(), w.events.back())
                && (k == 2 || k == 3)
                && last.first() == Some(&k)
            {
                w.events.pop_back();
            }
            w.events.push_back(ev);
        }
    });
    EV_CV.notify_all();
}

// ---- the connection to the host --------------------------------------------------------------

/// The host connection's fd, once connected.
static CONN: Mutex<Option<i32>> = Mutex::new(None);
/// The host has gone (EOF): every call fails from now on.
static DEAD: AtomicBool = AtomicBool::new(false);
/// One request at a time waits for its reply.
static REQ: Mutex<()> = Mutex::new(());
static REPLY: Mutex<Option<Vec<u8>>> = Mutex::new(None);
static REPLY_CV: Condvar = Condvar::new();

#[cfg(target_os = "macos")]
fn connect() -> Result<i32, String> {
    let mut c = lock(&CONN);
    if let Some(fd) = *c {
        return Ok(fd);
    }
    if DEAD.load(Ordering::SeqCst) {
        return Err("gui: the window process has stopped".into());
    }
    let fd = match std::env::var("AUK_GUI_SESSION") {
        Ok(path) if !path.is_empty() => connect_session(&path)?,
        _ => {
            let mut sv = [0 as c_int; 2];
            if unsafe { libc::socketpair(libc::AF_UNIX, libc::SOCK_STREAM, 0, sv.as_mut_ptr()) } != 0 {
                return Err(format!("gui: socketpair failed: {}", std::io::Error::last_os_error()));
            }
            let r = spawn_host(&format!("fd:{}", 3), Some(sv[1]));
            unsafe { libc::close(sv[1]) };
            if let Err(e) = r {
                unsafe { libc::close(sv[0]) };
                return Err(e);
            }
            sv[0]
        }
    };
    unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) };
    wire::no_sigpipe(fd);
    std::thread::Builder::new()
        .name("auk gui".into())
        .spawn(move || reader(fd))
        .map_err(|e| format!("gui: cannot start the event thread: {e}"))?;
    *c = Some(fd);
    Ok(fd)
}

/// Connect to the `auk run --live` session's host at `path`, starting it first if no one is
/// listening there yet.
#[cfg(target_os = "macos")]
fn connect_session(path: &str) -> Result<i32, String> {
    let try_connect = || -> Option<i32> {
        unsafe {
            let fd = libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0);
            if fd < 0 {
                return None;
            }
            let (addr, len) = unix_addr(path)?;
            if libc::connect(fd, (&raw const addr).cast(), len) == 0 {
                Some(fd)
            } else {
                libc::close(fd);
                None
            }
        }
    };
    if let Some(fd) = try_connect() {
        return Ok(fd);
    }
    spawn_host(&format!("listen:{path}"), None)?;
    for _ in 0..200 {
        std::thread::sleep(Duration::from_millis(15));
        if let Some(fd) = try_connect() {
            return Ok(fd);
        }
    }
    Err(format!("gui: the window process didn't start listening on {path}"))
}

/// A `sockaddr_un` for `path`.
pub(crate) fn unix_addr(path: &str) -> Option<(libc::sockaddr_un, libc::socklen_t)> {
    let mut addr: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    let b = path.as_bytes();
    if b.len() >= addr.sun_path.len() {
        return None;
    }
    addr.sun_family = libc::AF_UNIX as _;
    for (i, &c) in b.iter().enumerate() {
        addr.sun_path[i] = c as c_char;
    }
    Some((addr, size_of::<libc::sockaddr_un>() as libc::socklen_t))
}

#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn posix_spawn_file_actions_addinherit_np(actions: *mut libc::posix_spawn_file_actions_t, fd: c_int) -> c_int;
}

/// Start the host: this executable again, with `AUK_GUI_HOST=spec`, inheriting only the
/// standard streams (and `child_fd` as fd 3), so it holds none of the program's sockets or
/// files. Under `--live`, `AUK_GUI_OWNER` is the live parent (the host outlives this child).
#[cfg(target_os = "macos")]
fn spawn_host(spec: &str, child_fd: Option<c_int>) -> Result<(), String> {
    unsafe {
        let mut buf = vec![0 as c_char; 4096];
        let mut size = buf.len() as u32;
        #[allow(deprecated)]
        if libc::_NSGetExecutablePath(buf.as_mut_ptr(), &mut size) != 0 {
            return Err("gui: cannot find this program's executable".into());
        }
        let exe = std::ffi::CStr::from_ptr(buf.as_ptr()).to_owned();
        let mut env: Vec<CString> = std::env::vars_os()
            .filter(|(k, _)| k != "AUK_GUI_HOST" && k != "AUK_GUI_OWNER")
            .filter_map(|(k, v)| {
                let mut kv = k.into_encoded_bytes();
                kv.push(b'=');
                kv.extend(v.into_encoded_bytes());
                CString::new(kv).ok()
            })
            .collect();
        env.push(CString::new(format!("AUK_GUI_HOST={spec}")).unwrap_or_default());
        if child_fd.is_none() {
            env.push(CString::new(format!("AUK_GUI_OWNER={}", libc::getppid())).unwrap_or_default());
        }
        let mut envp: Vec<*mut c_char> = env.iter().map(|c| c.as_ptr() as *mut c_char).collect();
        envp.push(std::ptr::null_mut());
        let argv = [exe.as_ptr() as *mut c_char, std::ptr::null_mut()];

        let mut attr: libc::posix_spawnattr_t = std::mem::zeroed();
        let mut acts: libc::posix_spawn_file_actions_t = std::mem::zeroed();
        libc::posix_spawnattr_init(&mut attr);
        libc::posix_spawn_file_actions_init(&mut acts);
        libc::posix_spawnattr_setflags(&mut attr, libc::POSIX_SPAWN_CLOEXEC_DEFAULT as libc::c_short);
        for fd in 0..3 {
            posix_spawn_file_actions_addinherit_np(&mut acts, fd);
        }
        if let Some(fd) = child_fd {
            libc::posix_spawn_file_actions_adddup2(&mut acts, fd, 3);
        }
        let mut pid = 0;
        let rc = libc::posix_spawn(&mut pid, exe.as_ptr(), &acts, &attr, argv.as_ptr(), envp.as_ptr());
        libc::posix_spawn_file_actions_destroy(&mut acts);
        libc::posix_spawnattr_destroy(&mut attr);
        if rc != 0 {
            return Err(format!("gui: cannot start the window process: {}", std::io::Error::from_raw_os_error(rc)));
        }
        Ok(())
    }
}

/// The connection's reader: replies go to the waiting request, events to their window's queue.
fn reader(fd: i32) {
    loop {
        match wire::recv(fd) {
            Ok(Some(m)) => {
                if let Some(extra) = m.fd {
                    unsafe { libc::close(extra) };
                }
                let mut r = wire::R::new(&m.body);
                match m.op {
                    wire::REPLY => {
                        *lock(&REPLY) = Some(m.body);
                        REPLY_CV.notify_all();
                    }
                    wire::PRESENTED => {
                        let (id, seq, status) = (r.i64(), r.i64(), r.i64());
                        let e = (status != 0).then(|| r.rest_str());
                        if let Some(a) = lock(&ACKS).get_mut(&id) {
                            a.0 = a.0.max(seq);
                            if e.is_some() {
                                a.1 = e;
                            }
                        }
                        ACK_CV.notify_all();
                    }
                    wire::EVENT => {
                        let id = r.i64();
                        push_event(id, r.rest_i64s());
                    }
                    wire::METRICS => {
                        let (id, w, h, scale) = (r.i64(), r.i64(), r.i64(), r.f64());
                        with_wins(|ws| {
                            if let Some(win) = win_entry(ws, id) {
                                (win.w, win.h, win.scale) = (w, h, scale);
                            }
                        });
                    }
                    _ => {}
                }
            }
            _ => break,
        }
    }
    // the host is gone, and so are its windows
    DEAD.store(true, Ordering::SeqCst);
    ACK_CV.notify_all();
    with_wins(|ws| {
        let ids: Vec<i64> = ws.open.keys().copied().collect();
        ws.closed.extend(ids);
        ws.open.clear();
    });
    *lock(&CONN) = None;
    EV_CV.notify_all();
    REPLY_CV.notify_all();
}

/// Send a request and wait for its reply's result (after the status).
#[cfg(target_os = "macos")]
fn request(op: u8, body: wire::W, pass: Option<i32>) -> Result<Vec<u8>, String> {
    let _one = lock(&REQ);
    let fd = connect()?;
    *lock(&REPLY) = None;
    wire::send(fd, op, &body.0, pass).map_err(|e| format!("gui: the window process has stopped ({e})"))?;
    let mut r = lock(&REPLY);
    loop {
        if let Some(b) = r.take() {
            let mut rd = wire::R::new(&b);
            return if rd.i64() == 0 { Ok(b.get(8..).unwrap_or(&[]).to_vec()) } else { Err(rd.rest_str()) };
        }
        if DEAD.load(Ordering::SeqCst) {
            return Err("gui: the window process has stopped".into());
        }
        r = REPLY_CV.wait_timeout(r, Duration::from_millis(200)).unwrap_or_else(|e| e.into_inner()).0;
    }
}

/// Send a message that has no reply (if connected at all).
fn tell(op: u8, body: wire::W) {
    let _one = lock(&REQ);
    if let Some(fd) = *lock(&CONN) {
        let _ = wire::send(fd, op, &body.0, None);
    }
}

/// Close this program's windows: it is ending normally (`auk run --live` calls this when the
/// program returns, so its windows don't wait to be taken over by the next run).
pub fn shutdown() {
    tell(wire::BYE, wire::W::default());
}

// ---- the Auk-facing calls ------------------------------------------------------------------

/// Open a window with a `w`×`h` (logical points) content area; returns its id.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_gui_open(title: *const AukStr, w: i64, h: i64) -> AukRes_int {
    if !(1..=16384).contains(&w) || !(1..=16384).contains(&h) {
        return AukRes::err(err_msg(&format!("gui.open: size {w}x{h} (expected 1 to 16384 each)")));
    }
    let title = unsafe { sstr(title) }.to_string();
    match open(&title, w, h) {
        Ok(id) => AukRes::ok(id),
        Err(e) => AukRes::err(err_msg(&e)),
    }
}

#[cfg(target_os = "macos")]
fn open(title: &str, w: i64, h: i64) -> Result<i64, String> {
    let b = request(wire::OPEN, wire::W::default().i64(w).i64(h).str(title), None)?;
    let mut r = wire::R::new(&b);
    let (id, pw, ph, scale) = (r.i64(), r.i64(), r.i64(), r.f64());
    with_wins(|ws| {
        ws.closed.remove(&id);
        if let Some(win) = win_entry(ws, id) {
            (win.w, win.h, win.scale) = (pw, ph, scale);
        }
    });
    Ok(id)
}

#[cfg(not(target_os = "macos"))]
fn open(_title: &str, _w: i64, _h: i64) -> Result<i64, String> {
    Err("gui: windows are only supported on macOS so far".into())
}

/// Close a window (a no-op for one that is already closed).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_gui_close(win: i64) {
    let was_open = with_wins(|ws| {
        ws.closed.insert(win);
        ws.open.remove(&win).is_some()
    });
    EV_CV.notify_all();
    if let Some(b) = lock(&SHMS).remove(&win) {
        b.free();
    }
    lock(&ACKS).remove(&win);
    if was_open {
        tell(wire::CLOSE, wire::W::default().i64(win));
    }
}

/// The window's content width in physical pixels (0 once it is closed).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_gui_width(win: i64) -> i64 {
    with_wins(|ws| ws.open.get(&win).map_or(0, |w| w.w))
}

/// The window's content height in physical pixels (0 once it is closed).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_gui_height(win: i64) -> i64 {
    with_wins(|ws| ws.open.get(&win).map_or(0, |w| w.h))
}

/// Physical pixels per logical point (2.0 on a Retina display).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_gui_scale(win: i64) -> f64 {
    with_wins(|ws| ws.open.get(&win).map_or(1.0, |w| w.scale))
}

/// A window's frame in shared memory (0xffRRGGBB u32s), mapped here and in the host.
struct Shm {
    fd: c_int,
    ptr: *mut u32,
    w: i64,
    h: i64,
}

unsafe impl Send for Shm {}

impl Shm {
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    fn new(w: i64, h: i64) -> Result<Shm, String> {
        static N: AtomicI64 = AtomicI64::new(0);
        let len = (w * h * 4) as usize;
        unsafe {
            let name = CString::new(format!("/aukgui.{}.{}", libc::getpid(), N.fetch_add(1, Ordering::SeqCst))).unwrap_or_default();
            let fd = libc::shm_open(name.as_ptr(), libc::O_CREAT | libc::O_EXCL | libc::O_RDWR, 0o600 as libc::c_uint);
            if fd < 0 {
                return Err(format!("gui.present: shared memory: {}", std::io::Error::last_os_error()));
            }
            libc::shm_unlink(name.as_ptr());
            libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC);
            if libc::ftruncate(fd, len as libc::off_t) != 0 {
                let e = std::io::Error::last_os_error();
                libc::close(fd);
                return Err(format!("gui.present: shared memory: {e}"));
            }
            let p = libc::mmap(std::ptr::null_mut(), len, libc::PROT_READ | libc::PROT_WRITE, libc::MAP_SHARED, fd, 0);
            if p == libc::MAP_FAILED {
                let e = std::io::Error::last_os_error();
                libc::close(fd);
                return Err(format!("gui.present: shared memory: {e}"));
            }
            Ok(Shm { fd, ptr: p.cast(), w, h })
        }
    }

    fn free(self) {
        unsafe {
            libc::munmap(self.ptr.cast(), (self.w * self.h * 4) as usize);
            libc::close(self.fd);
        }
    }
}

/// A rectangle `(x0, y0, x1, y1)`, end-exclusive.
type Rect = (i64, i64, i64, i64);

/// A window's two shared frame buffers. The host reads only the one last presented, so
/// `present` writes the other; it returns without waiting, and waits for the host to take the
/// last present (PRESENTED) only before writing the buffer that present used.
struct Bufs {
    w: i64,
    h: i64,
    b: [Shm; 2],
    /// Whether the host has the buffer's fd yet.
    sent: [bool; 2],
    /// Whether the buffer has never been written.
    blank: [bool; 2],
    /// Areas written into the other buffer since this one was last written: what it lacks.
    stale: [Vec<Rect>; 2],
    /// The buffer to write next.
    next: usize,
    /// The last PRESENT's sequence number.
    seq: i64,
}

impl Bufs {
    fn free(self) {
        let [a, b] = self.b;
        a.free();
        b.free();
    }
}

static SHMS: std::sync::LazyLock<Mutex<HashMap<i64, Bufs>>> = std::sync::LazyLock::new(|| Mutex::new(HashMap::new()));
/// Per window: the last PRESENT the host finished, and an error it reported since.
static ACKS: std::sync::LazyLock<Mutex<HashMap<i64, (i64, Option<String>)>>> = std::sync::LazyLock::new(|| Mutex::new(HashMap::new()));
static ACK_CV: Condvar = Condvar::new();

/// Wait until the host has finished PRESENT `seq` of `win`; the error of any present since the
/// last wait.
fn wait_presented(win: i64, seq: i64) -> Result<(), String> {
    let mut a = lock(&ACKS);
    loop {
        let Some(e) = a.get_mut(&win) else { return Ok(()) };
        if e.0 >= seq {
            return e.1.take().map_or(Ok(()), Err);
        }
        if DEAD.load(Ordering::SeqCst) {
            return Err("gui: the window process has stopped".into());
        }
        a = ACK_CV.wait_timeout(a, Duration::from_millis(200)).unwrap_or_else(|e| e.into_inner()).0;
    }
}

/// Copy rectangle `(x0, y0, x1, y1)` of the frame `src` (`w` per row) into `dst` as 0xffRRGGBB:
/// windows show frames opaque, whatever their transparency.
fn convert(dst: &mut [u32], src: &[u32], w: usize, (x0, y0, x1, y1): (usize, usize, usize, usize)) {
    for row in y0..y1 {
        let (a, b) = (row * w + x0, row * w + x1);
        for (d, &p) in dst[a..b].iter_mut().zip(&src[a..b]) {
            *d = p | 0xff00_0000;
        }
    }
}

/// Add `r` to a list of areas, merging them all into one when the list gets long.
fn add_rect(v: &mut Vec<Rect>, r: Rect) {
    v.push(r);
    if v.len() > 8 {
        let all = v.iter().fold(r, |a, b| (a.0.min(b.0), a.1.min(b.1), a.2.max(b.2), a.3.max(b.3)));
        *v = vec![all];
    }
}

/// Show the rectangles `rects` (flattened `x, y, w, h` quads) of the frame `f` in the window;
/// the rest of what it shows stays. Only those rectangles are copied, and they go to the window
/// process together, in one message.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_gui_present_rects(win: i64, f: *const AukFrame, rects: *const AukArr) -> AukRes_unit {
    let (w, h) = unsafe { ((*f).w, (*f).hgt) };
    if w < 1 || h < 1 {
        return AukRes::err(err_msg(&format!("gui.present: an empty {w}x{h} frame")));
    }
    let n = if rects.is_null() { 0 } else { unsafe { (*rects).len } };
    if n % 4 != 0 {
        return AukRes::err(err_msg(&format!("gui.present_rects: {n} ints is not a list of x, y, w, h quads")));
    }
    if with_wins(|ws| !ws.open.contains_key(&win)) {
        return AukRes::err(err_msg(&format!("gui.present: window {win} is closed")));
    }
    let q: &[i64] = if n == 0 { &[] } else { unsafe { std::slice::from_raw_parts((*rects).data as *const i64, n as usize) } };
    let rs: Vec<Rect> = q.chunks_exact(4).map(|r| (r[0].max(0), r[1].max(0), r[0].saturating_add(r[2]).min(w), r[1].saturating_add(r[3]).min(h))).filter(|r| r.0 < r.2 && r.1 < r.3).collect();
    match present(win, unsafe { crate::pixels::pixels(f) }, w, h, rs) {
        Ok(()) => AukRes::ok(0),
        Err(e) => AukRes::err(err_msg(&e)),
    }
}

#[cfg(target_os = "macos")]
fn present(win: i64, src: &[u32], w: i64, h: i64, rs: Vec<Rect>) -> Result<(), String> {
    let mut shms = lock(&SHMS);
    if !matches!(shms.get(&win), Some(b) if b.w == w && b.h == h) {
        // a new size: new buffers (the host maps them as their fds arrive)
        let fresh = Bufs { w, h, b: [Shm::new(w, h)?, Shm::new(w, h)?], sent: [false; 2], blank: [true; 2], stale: [vec![], vec![]], next: 0, seq: 0 };
        let seq = match shms.insert(win, fresh) {
            Some(old) => {
                let seq = old.seq;
                old.free();
                seq
            }
            None => 0,
        };
        shms.get_mut(&win).unwrap().seq = seq;
        lock(&ACKS).entry(win).or_insert((seq, None));
    }
    let bf = shms.get_mut(&win).unwrap();
    if rs.is_empty() {
        return Ok(());
    }
    // until the host has taken the last present (the other buffer), it may still read this one
    wait_presented(win, bf.seq)?;
    let (i, o) = (bf.next, 1 - bf.next);
    let n = (w * h) as usize;
    let dst = unsafe { std::slice::from_raw_parts_mut(bf.b[i].ptr, n) };
    let other = unsafe { std::slice::from_raw_parts(bf.b[o].ptr, n) };
    let rs = if bf.blank[i] && bf.blank[o] { vec![(0, 0, w, h)] } else { rs };
    if bf.blank[i] && !bf.blank[o] {
        dst.copy_from_slice(other);
    } else if !bf.blank[i] {
        // catch up with what the other buffer got since this one was written (apart from what
        // this present writes anyway)
        for &(sx0, sy0, sx1, sy1) in &bf.stale[i] {
            if rs.iter().any(|r| sx0 >= r.0 && sy0 >= r.1 && sx1 <= r.2 && sy1 <= r.3) {
                continue;
            }
            for row in sy0..sy1 {
                let (a, b) = ((row * w + sx0) as usize, (row * w + sx1) as usize);
                dst[a..b].copy_from_slice(&other[a..b]);
            }
        }
    }
    bf.stale[i].clear();
    bf.blank[i] = false;
    for &(x0, y0, x1, y1) in &rs {
        convert(dst, src, w as usize, (x0 as usize, y0 as usize, x1 as usize, y1 as usize));
        add_rect(&mut bf.stale[o], (x0, y0, x1, y1));
    }
    bf.seq += 1;
    bf.next = o;
    let pass = (!bf.sent[i]).then_some(bf.b[i].fd);
    bf.sent[i] = true;
    let mut body = wire::W::default().i64(win).i64(w).i64(h).i64(i as i64).i64(bf.seq).i64(rs.len() as i64);
    for &(x0, y0, x1, y1) in &rs {
        body = body.i64(x0).i64(y0).i64(x1 - x0).i64(y1 - y0);
    }
    let _one = lock(&REQ);
    let fd = connect()?;
    wire::send(fd, wire::PRESENT, &body.0, pass).map_err(|e| format!("gui: the window process has stopped ({e})"))
}

#[cfg(not(target_os = "macos"))]
fn present(_win: i64, _src: &[u32], _w: i64, _h: i64, _rs: Vec<Rect>) -> Result<(), String> {
    Err("gui: windows are only supported on macOS so far".into())
}

/// The next event of `win` as `[int]` (the kind, then its fields), waiting at most `ms`
/// milliseconds (0: don't wait, negative: until there is one). Empty if none came. A closed or
/// unknown window reports `Close`, so a loop over its events ends. A task waiting here can be
/// cancelled.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_gui_next_event(win: i64, ms: i64, loc: *const c_char) -> *mut AukArr {
    let deadline = (ms >= 0).then(|| std::time::Instant::now() + Duration::from_millis(ms as u64));
    let mut g = lock(&WINS);
    let found = loop {
        let ws = g.get_or_insert_with(Wins::default);
        match ws.open.get_mut(&win) {
            None => break Some(vec![1]),
            Some(w) => {
                if let Some(ev) = w.events.pop_front() {
                    break Some(ev);
                }
            }
        }
        let now = std::time::Instant::now();
        let slice = match deadline {
            Some(d) if d <= now => break None,
            Some(d) => (d - now).min(Duration::from_millis(50)),
            None => Duration::from_millis(50),
        };
        g = EV_CV.wait_timeout(g, slice).unwrap_or_else(|e| e.into_inner()).0;
        if crate::task::cancelled() {
            drop(g);
            crate::task::check_cancel(loc);
            g = lock(&WINS);
        }
    };
    drop(g);
    int_arr(&found.unwrap_or_default())
}

fn int_arr(v: &[i64]) -> *mut AukArr {
    unsafe {
        let mut out = crate::arr::auk_arr_new(&crate::rc::auk_ops_int, v.len() as i64);
        let d = crate::arr::auk_arr_make_unique(&mut out) as *mut i64;
        std::ptr::copy_nonoverlapping(v.as_ptr(), d, v.len());
        (*out).len = v.len() as i64;
        out
    }
}

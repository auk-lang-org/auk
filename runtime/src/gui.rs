//! Windows: the client side is now in C (`runtime/c/gui.c`, which explains the window process).
//! The wire protocol and `unix_addr` stay here for gui_host.rs until it is ported.

use std::ffi::c_char;

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

unsafe extern "C" {
    safe fn auk_gui_shutdown();
}

/// Close this program's windows: it is ending normally (`auk run --live` calls this when the
/// program returns, so its windows don't wait to be taken over by the next run).
pub fn shutdown() {
    auk_gui_shutdown()
}

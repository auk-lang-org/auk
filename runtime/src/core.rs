//! Core library: print, fs, net, time, rand, env (with stdin), proc (was core.c).

use std::ffi::{CStr, CString, c_char, c_int};
use std::ptr::null_mut;
use std::sync::Mutex;

use crate::arr::{duck_arr_make_unique, duck_arr_new, duck_arr_push};
use crate::err::{duck__err_errno, err_msg};
use crate::rc::{duck__alloc, duck__free_obj, duck__make_immortal, duck_ops_int, duck_ops_str, release};
use crate::str::{duck_str_from_bytes, duck_str_lines, duck_str_lit, duck_str_try_from_bytes};
use crate::*;

unsafe extern "C" {
    static environ: *const *mut c_char;
    fn flockfile(f: *mut libc::FILE);
    fn funlockfile(f: *mut libc::FILE);
}

// ---- small helpers -----------------------------------------------------------------------

/// `duck_str_cstr`: the NUL-terminated bytes of s ("" for NULL).
pub unsafe fn cs(s: *const DuckStr) -> *const c_char {
    if s.is_null() { c"".as_ptr() } else { unsafe { (&raw const (*s).data).cast() } }
}

/// The text `%s` of `duck_str_cstr(s)` prints (up to the first NUL).
pub unsafe fn ctext<'a>(s: *const DuckStr) -> std::borrow::Cow<'a, str> {
    unsafe { cstr(cs(s)) }
}

pub fn errno() -> c_int {
    std::io::Error::last_os_error().raw_os_error().unwrap_or(0)
}

fn set_errno(v: c_int) {
    #[cfg(any(target_os = "macos", target_os = "ios", target_os = "freebsd"))]
    unsafe {
        *libc::__error() = v
    };
    #[cfg(target_os = "android")]
    unsafe {
        *libc::__errno() = v
    };
    #[cfg(not(any(target_os = "macos", target_os = "ios", target_os = "freebsd", target_os = "android")))]
    unsafe {
        *libc::__errno_location() = v
    };
}

pub fn strerror(e: c_int) -> String {
    unsafe { cstr(libc::strerror(e)).into_owned() }
}

/// An Err with message `msg` and code `code`.
pub unsafe fn err_code(msg: &str, code: c_int) -> *mut DuckErr {
    let e = err_msg(msg);
    unsafe { (*e).code = code as i64 };
    e
}

/// Bytes as a fresh `[int]` (0..255).
pub unsafe fn bytes_to_arr(b: &[u8]) -> *mut DuckArr {
    let n = b.len() as i64;
    unsafe {
        let mut a = duck_arr_new(&duck_ops_int, n);
        let d = duck_arr_make_unique(&mut a) as *mut i64;
        for (i, &x) in b.iter().enumerate() {
            *d.add(i) = x as i64;
        }
        (*a).len = n;
        a
    }
}

/// The elements of an `[int]`, as a slice.
unsafe fn int_slice<'a>(a: *const DuckArr) -> &'a [i64] {
    if a.is_null() || unsafe { (*a).len } == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts((*a).data as *const i64, (*a).len as usize) }
    }
}

/// An `[int]` as bytes, or the first (index, value) outside 0..255.
unsafe fn arr_to_bytes(a: *const DuckArr) -> Result<Vec<u8>, (usize, i64)> {
    let xs = unsafe { int_slice(a) };
    let mut buf = Vec::with_capacity(xs.len());
    for (i, &x) in xs.iter().enumerate() {
        if !(0..=255).contains(&x) {
            return Err((i, x));
        }
        buf.push(x as u8);
    }
    Ok(buf)
}

/// Read all of f into b; returns 0 or an errno.
unsafe fn slurp(f: *mut libc::FILE, b: &mut Vec<u8>) -> c_int {
    let mut buf = vec![0u8; 65536];
    loop {
        let n = unsafe { libc::fread(buf.as_mut_ptr().cast(), 1, buf.len(), f) };
        if n == 0 {
            break;
        }
        b.extend_from_slice(&buf[..n]);
    }
    if unsafe { libc::ferror(f) } != 0 {
        let e = errno();
        if e != 0 { e } else { libc::EIO }
    } else {
        0
    }
}

// ---- print -------------------------------------------------------------------------------

fn write_line(f: *mut libc::FILE, b: &[u8]) {
    unsafe { flockfile(f) };
    fwrite_bytes(f, b);
    fwrite_bytes(f, b"\n");
    unsafe { funlockfile(f) };
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_print(s: *const DuckStr) {
    write_line(c_stdout(), unsafe { sbytes(s) });
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_print_lit(cstr: *const c_char) {
    write_line(c_stdout(), unsafe { cbytes(cstr) });
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_eprint(s: *const DuckStr) {
    unsafe { libc::fflush(c_stdout()) };
    write_line(c_stderr(), unsafe { sbytes(s) });
}

// ---- fs ----------------------------------------------------------------------------------

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_fs_read(path: *const DuckStr) -> DuckRes_str {
    unsafe {
        let f = libc::fopen(cs(path), c"rb".as_ptr());
        if f.is_null() {
            return err_ptr(duck__err_errno(c"fs.read".as_ptr(), path, errno()));
        }
        let mut b = Vec::new();
        let mut buf = vec![0u8; 65536];
        loop {
            let n = libc::fread(buf.as_mut_ptr().cast(), 1, buf.len(), f);
            if n == 0 {
                break;
            }
            b.extend_from_slice(&buf[..n]);
        }
        let err = if libc::ferror(f) != 0 { errno() } else { 0 };
        libc::fclose(f);
        if err != 0 {
            return err_ptr(duck__err_errno(c"fs.read".as_ptr(), path, err));
        }
        let mut r = duck_str_try_from_bytes(b.as_ptr().cast(), b.len() as i64);
        if !r.ok {
            // "fs.read <path>: invalid UTF-8 at byte N"
            let e = err_msg(&format!("fs.read {}", ctext(path)));
            (*e).cause = r.err; // moves the reference
            r.err = e;
        }
        r
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_fs_write(path: *const DuckStr, content: *const DuckStr) -> DuckRes_unit {
    unsafe { write_file(c"fs.write", c"wb", path, sbytes(content)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_fs_lines(path: *const DuckStr) -> DuckRes_arr {
    unsafe {
        let r = duck_fs_read(path);
        if !r.ok {
            return err_ptr(r.err);
        }
        let lines = duck_str_lines(r.val);
        release(r.val);
        DuckRes::ok(lines)
    }
}

fn is_dir_mode(m: libc::mode_t) -> bool {
    (m & libc::S_IFMT) == libc::S_IFDIR
}

unsafe fn stat_is(path: *const DuckStr, want_dir: bool) -> bool {
    unsafe {
        let mut st: libc::stat = std::mem::zeroed();
        if libc::stat(cs(path), &mut st) != 0 {
            return false;
        }
        !want_dir || is_dir_mode(st.st_mode)
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_fs_exists(path: *const DuckStr) -> bool {
    unsafe { stat_is(path, false) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_fs_is_dir(path: *const DuckStr) -> bool {
    unsafe { stat_is(path, true) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_fs_list(dir: *const DuckStr) -> DuckRes_arr {
    unsafe {
        let d = libc::opendir(cs(dir));
        if d.is_null() {
            return err_ptr(duck__err_errno(c"fs.list".as_ptr(), dir, errno()));
        }
        let mut names: Vec<CString> = Vec::new();
        set_errno(0);
        loop {
            let ent = libc::readdir(d);
            if ent.is_null() {
                break;
            }
            let nm = CStr::from_ptr((*ent).d_name.as_ptr());
            if nm == c"." || nm == c".." {
                continue;
            }
            names.push(nm.to_owned());
        }
        let err = errno();
        libc::closedir(d);
        if err != 0 {
            return err_ptr(duck__err_errno(c"fs.list".as_ptr(), dir, err));
        }
        names.sort_by(|a, b| a.as_bytes().cmp(b.as_bytes())); // strcmp order
        let mut a = duck_arr_new(&duck_ops_str, names.len() as i64);
        for nm in &names {
            let s = duck_str_lit(nm.as_ptr());
            duck_arr_push(&mut a, (&raw const s).cast());
            release(s);
        }
        DuckRes::ok(a)
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_fs_mkdir(path: *const DuckStr) -> DuckRes_unit {
    unsafe {
        let mut buf = CStr::from_ptr(cs(path)).to_bytes_with_nul().to_vec();
        let len = buf.len() - 1;
        if len == 0 {
            return DuckRes::err(duck__err_errno(c"fs.mkdir".as_ptr(), path, libc::ENOENT));
        }
        let mut err = 0;
        // Create each prefix that ends before a '/', then the whole path.
        let mut i = 1;
        while i <= len && err == 0 {
            if i < len && buf[i] != b'/' {
                i += 1;
                continue;
            }
            let saved = buf[i];
            buf[i] = 0;
            let p = buf.as_ptr().cast::<c_char>();
            if libc::mkdir(p, 0o777 as libc::mode_t) != 0 {
                let mut st: libc::stat = std::mem::zeroed();
                let e = errno();
                if e != libc::EEXIST {
                    err = e;
                } else if libc::stat(p, &mut st) != 0 {
                    err = errno();
                } else if !is_dir_mode(st.st_mode) {
                    err = libc::ENOTDIR;
                }
            }
            buf[i] = saved;
            i += 1;
        }
        if err != 0 {
            return DuckRes::err(duck__err_errno(c"fs.mkdir".as_ptr(), path, err));
        }
        DuckRes::ok(0)
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_fs_remove(path: *const DuckStr) -> DuckRes_unit {
    unsafe {
        let p = cs(path);
        let mut st: libc::stat = std::mem::zeroed();
        let mut rc = libc::lstat(p, &mut st);
        if rc == 0 {
            rc = if is_dir_mode(st.st_mode) { libc::rmdir(p) } else { libc::unlink(p) };
        }
        if rc != 0 {
            return DuckRes::err(duck__err_errno(c"fs.remove".as_ptr(), path, errno()));
        }
        DuckRes::ok(0)
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_fs_rename(from: *const DuckStr, to: *const DuckStr) -> DuckRes_unit {
    unsafe {
        if libc::rename(cs(from), cs(to)) != 0 {
            let err = errno();
            let msg = format!("fs.rename {} -> {}: {}", ctext(from), ctext(to), strerror(err));
            return DuckRes::err(err_code(&msg, err));
        }
        DuckRes::ok(0)
    }
}

unsafe fn write_file(what: &CStr, mode: &CStr, path: *const DuckStr, b: &[u8]) -> DuckRes_unit {
    unsafe {
        let f = libc::fopen(cs(path), mode.as_ptr());
        if f.is_null() {
            return DuckRes::err(duck__err_errno(what.as_ptr(), path, errno()));
        }
        let mut err = 0;
        if !b.is_empty() && libc::fwrite(b.as_ptr().cast(), 1, b.len(), f) != b.len() {
            let e = errno();
            err = if e != 0 { e } else { libc::EIO };
        }
        if libc::fclose(f) != 0 && err == 0 {
            err = errno();
        }
        if err != 0 {
            return DuckRes::err(duck__err_errno(what.as_ptr(), path, err));
        }
        DuckRes::ok(0)
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_fs_append(path: *const DuckStr, text: *const DuckStr) -> DuckRes_unit {
    unsafe { write_file(c"fs.append", c"ab", path, sbytes(text)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_fs_temp_dir() -> DuckRes_str {
    unsafe {
        let env = libc::getenv(c"TMPDIR".as_ptr());
        let mut base: &[u8] = if env.is_null() { b"" } else { CStr::from_ptr(env).to_bytes() };
        if base.is_empty() {
            base = b"/tmp";
        }
        let mut bl = base.len();
        while bl > 1 && base[bl - 1] == b'/' {
            bl -= 1;
        }
        let mut tmpl = base[..bl].to_vec();
        tmpl.extend_from_slice(b"/duck-XXXXXX\0");
        if libc::mkdtemp(tmpl.as_mut_ptr().cast()).is_null() {
            // mode 0700, a fresh name
            let err = errno();
            let t = String::from_utf8_lossy(&tmpl[..tmpl.len() - 1]);
            return err_ptr(err_code(&format!("fs.temp_dir {}: {}", t, strerror(err)), err));
        }
        DuckRes::ok(duck_str_lit(tmpl.as_ptr().cast()))
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_fs_read_bytes(path: *const DuckStr) -> DuckRes_arr {
    unsafe {
        let f = libc::fopen(cs(path), c"rb".as_ptr());
        if f.is_null() {
            return err_ptr(duck__err_errno(c"fs.read_bytes".as_ptr(), path, errno()));
        }
        let mut b = Vec::new();
        let err = slurp(f, &mut b);
        libc::fclose(f);
        if err != 0 {
            return err_ptr(duck__err_errno(c"fs.read_bytes".as_ptr(), path, err));
        }
        DuckRes::ok(bytes_to_arr(&b))
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_fs_write_bytes(path: *const DuckStr, bytes: *const DuckArr) -> DuckRes_unit {
    unsafe {
        match arr_to_bytes(bytes) {
            // checked before the file is touched
            Err((i, x)) => DuckRes::err(err_msg(&format!(
                "fs.write_bytes {}: byte {} at index {} is out of range 0..255",
                ctext(path),
                x,
                i
            ))),
            Ok(buf) => write_file(c"fs.write_bytes", c"wb", path, &buf),
        }
    }
}

// ---- net ---------------------------------------------------------------------------------

/// Flags for send(2) on a connected socket (no SIGPIPE where the platform has MSG_NOSIGNAL;
/// elsewhere the socket carries SO_NOSIGPIPE).
#[cfg(any(
    target_os = "linux",
    target_os = "android",
    target_os = "freebsd",
    target_os = "netbsd",
    target_os = "openbsd",
    target_os = "dragonfly"
))]
pub const SEND_FLAGS: c_int = libc::MSG_NOSIGNAL;
#[cfg(not(any(
    target_os = "linux",
    target_os = "android",
    target_os = "freebsd",
    target_os = "netbsd",
    target_os = "openbsd",
    target_os = "dragonfly"
)))]
pub const SEND_FLAGS: c_int = 0;

pub unsafe fn duck__conn_free(c: *mut DuckConn) {
    unsafe {
        duck_conn_close(c);
        duck__free_obj(c.cast());
    }
}

unsafe fn conn_open(c: *const DuckConn) -> bool {
    !c.is_null() && unsafe { (*c).fd >= 0 || !(*c).tls.is_null() }
}

/// Socket options every connected socket gets.
fn conn_sockopts(fd: c_int) {
    #[cfg(any(target_os = "macos", target_os = "ios", target_os = "freebsd"))]
    unsafe {
        let one: c_int = 1;
        libc::setsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_NOSIGPIPE,
            (&raw const one).cast(),
            size_of::<c_int>() as libc::socklen_t,
        );
    }
    unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) };
}

/// Resolve host:port and connect a TCP socket (with the connected-socket options set).
/// On failure: the reason text (gai_strerror or strerror) and an errno (0 for a DNS failure).
pub unsafe fn tcp_connect(host: *const c_char, ports: &CStr) -> Result<c_int, (String, c_int)> {
    unsafe {
        let mut hints: libc::addrinfo = std::mem::zeroed();
        hints.ai_family = libc::AF_UNSPEC;
        hints.ai_socktype = libc::SOCK_STREAM;
        let mut res: *mut libc::addrinfo = null_mut();
        let gai = libc::getaddrinfo(host, ports.as_ptr(), &hints, &mut res);
        if gai != 0 {
            return Err((cstr(libc::gai_strerror(gai)).into_owned(), 0));
        }
        let mut fd = -1;
        let mut err = 0;
        let mut ai = res;
        while !ai.is_null() {
            fd = libc::socket((*ai).ai_family, (*ai).ai_socktype, (*ai).ai_protocol);
            if fd < 0 {
                err = errno();
                ai = (*ai).ai_next;
                continue;
            }
            let mut rc;
            loop {
                rc = libc::connect(fd, (*ai).ai_addr, (*ai).ai_addrlen);
                if !(rc < 0 && errno() == libc::EINTR) {
                    break;
                }
            }
            if rc == 0 {
                break;
            }
            err = errno();
            libc::close(fd);
            fd = -1;
            ai = (*ai).ai_next;
        }
        libc::freeaddrinfo(res);
        if fd < 0 {
            return Err((strerror(err), err));
        }
        conn_sockopts(fd);
        Ok(fd)
    }
}

/// A new open DuckConn over fd.
pub unsafe fn conn_new(fd: c_int) -> *mut DuckConn {
    unsafe {
        let c = duck__alloc(size_of::<DuckConn>(), DUCK_K_CONN) as *mut DuckConn;
        (*c).fd = fd;
        c
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_net_tcp(host: *const DuckStr, port: i64) -> DuckRes_conn {
    unsafe {
        if !(0..=65535).contains(&port) {
            return err_ptr(err_msg(&format!("net.tcp {}:{}: invalid port", ctext(host), port)));
        }
        let ports = CString::new(port.to_string()).unwrap();
        match tcp_connect(cs(host), &ports) {
            Ok(fd) => DuckRes::ok(conn_new(fd)),
            Err((why, code)) => {
                let msg = format!("net.tcp {}:{}: {}", ctext(host), port, why);
                err_ptr(if code != 0 { err_code(&msg, code) } else { err_msg(&msg) })
            }
        }
    }
}

pub unsafe fn duck__listener_free(l: *mut DuckListener) {
    unsafe {
        duck_listener_close(l);
        duck__free_obj(l.cast());
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_net_listen(host: *const DuckStr, port: i64) -> DuckRes_listener {
    unsafe {
        let h = cs(host);
        let ht = ctext(host);
        if !(0..=65535).contains(&port) {
            return err_ptr(err_msg(&format!("net.listen {ht}:{port}: invalid port")));
        }
        let ports = CString::new(port.to_string()).unwrap();
        let mut hints: libc::addrinfo = std::mem::zeroed();
        hints.ai_family = libc::AF_UNSPEC;
        hints.ai_socktype = libc::SOCK_STREAM;
        hints.ai_flags = libc::AI_PASSIVE;
        let mut res: *mut libc::addrinfo = null_mut();
        let gai = libc::getaddrinfo(if *h != 0 { h } else { std::ptr::null() }, ports.as_ptr(), &hints, &mut res);
        if gai != 0 {
            return err_ptr(err_msg(&format!("net.listen {ht}:{port}: {}", cstr(libc::gai_strerror(gai)))));
        }
        let mut fd = -1;
        let mut err = 0;
        let mut ai = res;
        while !ai.is_null() {
            fd = libc::socket((*ai).ai_family, (*ai).ai_socktype, (*ai).ai_protocol);
            if fd < 0 {
                err = errno();
                ai = (*ai).ai_next;
                continue;
            }
            let one: c_int = 1;
            libc::setsockopt(
                fd,
                libc::SOL_SOCKET,
                libc::SO_REUSEADDR,
                (&raw const one).cast(),
                size_of::<c_int>() as libc::socklen_t,
            );
            if libc::bind(fd, (*ai).ai_addr, (*ai).ai_addrlen) == 0 && libc::listen(fd, 128) == 0 {
                break;
            }
            err = errno();
            libc::close(fd);
            fd = -1;
            ai = (*ai).ai_next;
        }
        libc::freeaddrinfo(res);
        if fd < 0 {
            return err_ptr(err_code(&format!("net.listen {ht}:{port}: {}", strerror(err)), err));
        }
        libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC);
        let mut ss: libc::sockaddr_storage = std::mem::zeroed();
        let mut len = size_of::<libc::sockaddr_storage>() as libc::socklen_t;
        let mut bound = port;
        if libc::getsockname(fd, (&raw mut ss).cast(), &mut len) == 0 {
            if ss.ss_family as c_int == libc::AF_INET {
                bound = u16::from_be((*(&raw const ss as *const libc::sockaddr_in)).sin_port) as i64;
            } else if ss.ss_family as c_int == libc::AF_INET6 {
                bound = u16::from_be((*(&raw const ss as *const libc::sockaddr_in6)).sin6_port) as i64;
            }
        }
        let l = duck__alloc(size_of::<DuckListener>(), DUCK_K_LISTENER) as *mut DuckListener;
        (*l).fd = fd;
        (*l).port = bound;
        DuckRes::ok(l)
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_listener_accept(l: *mut DuckListener) -> DuckRes_conn {
    unsafe {
        if l.is_null() || (*l).fd < 0 {
            return err_ptr(err_msg("net accept: listener is closed"));
        }
        let mut fd;
        loop {
            fd = libc::accept((*l).fd, null_mut(), null_mut());
            if !(fd < 0 && (errno() == libc::EINTR || errno() == libc::ECONNABORTED)) {
                break;
            }
        }
        if fd < 0 {
            return err_ptr(duck__err_errno(c"net accept".as_ptr(), std::ptr::null(), errno()));
        }
        conn_sockopts(fd);
        DuckRes::ok(conn_new(fd))
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_listener_port(l: *const DuckListener) -> i64 {
    if l.is_null() { 0 } else { unsafe { (*l).port } }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_listener_close(l: *mut DuckListener) {
    unsafe {
        if !l.is_null() && (*l).fd >= 0 {
            libc::close((*l).fd);
            (*l).fd = -1;
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_conn_read(c: *mut DuckConn, max: i64) -> DuckRes_arr {
    unsafe {
        if !conn_open(c) {
            return err_ptr(err_msg("net read: connection is closed"));
        }
        if max <= 0 {
            return err_ptr(err_msg("net read: max must be positive"));
        }
        let max = max.min(1 << 24);
        if !(*c).tls.is_null() {
            return crate::tls::duck__tls_read((*c).tls, max);
        }
        let mut buf = vec![0u8; max as usize];
        let mut n;
        loop {
            n = libc::recv((*c).fd, buf.as_mut_ptr().cast(), max as usize, 0);
            if !(n < 0 && errno() == libc::EINTR) {
                break;
            }
        }
        if n < 0 {
            return err_ptr(duck__err_errno(c"net read".as_ptr(), std::ptr::null(), errno()));
        }
        DuckRes::ok(bytes_to_arr(&buf[..n as usize]))
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_conn_write(c: *mut DuckConn, bytes: *const DuckArr) -> DuckRes_unit {
    unsafe {
        if !conn_open(c) {
            return DuckRes::err(err_msg("net write: connection is closed"));
        }
        let buf = match arr_to_bytes(bytes) {
            Ok(b) => b,
            Err((_, x)) => return DuckRes::err(err_msg(&format!("net write: byte {x} out of range 0..255"))),
        };
        if !(*c).tls.is_null() {
            return crate::tls::duck__tls_write((*c).tls, buf.as_ptr(), buf.len() as i64);
        }
        let mut off = 0usize;
        while off < buf.len() {
            let w = libc::send((*c).fd, buf.as_ptr().add(off).cast(), buf.len() - off, SEND_FLAGS);
            if w < 0 {
                let err = errno();
                if err == libc::EINTR {
                    continue;
                }
                return DuckRes::err(duck__err_errno(c"net write".as_ptr(), std::ptr::null(), err));
            }
            off += w as usize;
        }
        DuckRes::ok(0)
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_conn_close(c: *mut DuckConn) {
    unsafe {
        if !c.is_null() && !(*c).tls.is_null() {
            crate::tls::duck__tls_free((*c).tls); // before the socket closes: it may send close_notify
            (*c).tls = null_mut();
        }
        if !c.is_null() && (*c).fd >= 0 {
            libc::close((*c).fd);
            (*c).fd = -1;
        }
    }
}

// ---- time --------------------------------------------------------------------------------

#[unsafe(no_mangle)]
pub extern "C" fn duck_time_now() -> i64 {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    unsafe { libc::clock_gettime(libc::CLOCK_REALTIME, &mut ts) };
    ts.tv_sec as i64 * 1000 + ts.tv_nsec as i64 / 1_000_000
}

#[unsafe(no_mangle)]
pub extern "C" fn duck_time_sleep(ms: i64) {
    if ms <= 0 {
        return;
    }
    let mut ts = libc::timespec { tv_sec: (ms / 1000) as libc::time_t, tv_nsec: ((ms % 1000) * 1_000_000) as _ };
    while unsafe { libc::nanosleep(&ts, &mut ts) } < 0 && errno() == libc::EINTR {}
}

// ---- rand (xoshiro256**, seeded from the OS CSPRNG) --------------------------------------

/// Fill buf from the OS CSPRNG; false if none is available.
fn os_random(buf: &mut [u8]) -> bool {
    #[cfg(any(
        target_os = "macos",
        target_os = "ios",
        target_os = "freebsd",
        target_os = "openbsd",
        target_os = "netbsd"
    ))]
    {
        if !buf.is_empty() {
            unsafe { libc::arc4random_buf(buf.as_mut_ptr().cast(), buf.len()) };
        }
        true
    }
    #[cfg(not(any(
        target_os = "macos",
        target_os = "ios",
        target_os = "freebsd",
        target_os = "openbsd",
        target_os = "netbsd"
    )))]
    {
        let mut p = 0usize;
        #[cfg(any(target_os = "linux", target_os = "android"))]
        {
            while p < buf.len() {
                let r = unsafe { libc::getrandom(buf[p..].as_mut_ptr().cast(), buf.len() - p, 0) };
                if r < 0 {
                    if errno() == libc::EINTR {
                        continue;
                    }
                    break; // ENOSYS (old kernel): fall back to /dev/urandom
                }
                p += r as usize;
            }
            if p == buf.len() {
                return true;
            }
        }
        let fd = unsafe { libc::open(c"/dev/urandom".as_ptr(), libc::O_RDONLY | libc::O_CLOEXEC) };
        if fd < 0 {
            return false;
        }
        while p < buf.len() {
            let r = unsafe { libc::read(fd, buf[p..].as_mut_ptr().cast(), buf.len() - p) };
            if r < 0 && errno() == libc::EINTR {
                continue;
            }
            if r <= 0 {
                break;
            }
            p += r as usize;
        }
        unsafe { libc::close(fd) };
        p == buf.len()
    }
}

struct RandState {
    s: [u64; 4],
    seeded: bool,
}

static RAND: Mutex<RandState> = Mutex::new(RandState { s: [0; 4], seeded: false });

fn rand_next() -> u64 {
    let mut g = RAND.lock().unwrap_or_else(|e| e.into_inner());
    if !g.seeded {
        let mut b = [0u8; 32];
        if os_random(&mut b) {
            for i in 0..4 {
                g.s[i] = u64::from_ne_bytes(b[i * 8..i * 8 + 8].try_into().unwrap());
            }
        } else {
            let t = (duck_time_now() as u64) ^ ((unsafe { libc::getpid() } as u64) << 32);
            for i in 0..4 {
                g.s[i] = crate::rc::duck_hash_int(t.wrapping_add(i as u64) as i64);
            }
        }
        if g.s.iter().all(|&x| x == 0) {
            g.s[0] = 1;
        }
        g.seeded = true;
    }
    let s = &mut g.s;
    let r = s[1].wrapping_mul(5).rotate_left(7).wrapping_mul(9);
    let t = s[1] << 17;
    s[2] ^= s[0];
    s[3] ^= s[1];
    s[1] ^= s[2];
    s[0] ^= s[3];
    s[2] ^= t;
    s[3] = s[3].rotate_left(45);
    r
}

#[unsafe(no_mangle)]
pub extern "C" fn duck_rand_int(lo: i64, hi: i64) -> i64 {
    if lo > hi {
        rt_panic!(c"rand.int".as_ptr(), "rand.int({}, {}): lo > hi", lo, hi);
    }
    let span = (hi as u64).wrapping_sub(lo as u64).wrapping_add(1); // 0 means the full 2^64 range
    if span == 0 {
        return rand_next() as i64;
    }
    let limit = u64::MAX - u64::MAX % span;
    let mut x;
    loop {
        x = rand_next();
        if x < limit {
            break;
        }
    }
    (lo as u64).wrapping_add(x % span) as i64
}

#[unsafe(no_mangle)]
pub extern "C" fn duck_rand_float() -> f64 {
    (rand_next() >> 11) as f64 * (1.0 / 9007199254740992.0) // 0x1.0p-53
}

#[unsafe(no_mangle)]
pub extern "C" fn duck_rand_seed(seed: i64) {
    let mut x = seed as u64;
    let mut g = RAND.lock().unwrap_or_else(|e| e.into_inner());
    for i in 0..4 {
        // splitmix64
        x = x.wrapping_add(0x9E3779B97F4A7C15);
        let mut z = x;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        g.s[i] = z ^ (z >> 31);
    }
    if g.s.iter().all(|&x| x == 0) {
        g.s[0] = 1;
    }
    g.seeded = true;
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_rand_bytes(n: i64, loc: *const c_char) -> *mut DuckArr {
    if n < 0 {
        rt_panic!(loc, "rand.bytes({}): negative count", n);
    }
    let mut buf = vec![0u8; n as usize];
    if !os_random(&mut buf) {
        rt_panic!(loc, "rand.bytes: no OS random source available");
    }
    unsafe { bytes_to_arr(&buf) }
}

// ---- env ---------------------------------------------------------------------------------

struct ArgsPtr(*mut DuckArr);
unsafe impl Send for ArgsPtr {}

static ARGS: Mutex<ArgsPtr> = Mutex::new(ArgsPtr(null_mut()));

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_env_get(key: *const DuckStr) -> DuckOpt_str {
    unsafe {
        let v = libc::getenv(cs(key));
        if v.is_null() {
            return none_ptr();
        }
        DuckOpt::some(duck_str_lit(v))
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_env_set_args(argc: c_int, argv: *mut *mut c_char) {
    unsafe {
        let mut a = duck_arr_new(&duck_ops_str, argc as i64);
        for i in 0..argc.max(0) as usize {
            let s = duck_str_lit(*argv.add(i));
            duck_arr_push(&mut a, (&raw const s).cast());
            release(s);
            duck__make_immortal(s.cast());
        }
        duck__make_immortal(a.cast());
        // a previous array is immortal and simply abandoned
        ARGS.lock().unwrap_or_else(|e| e.into_inner()).0 = a;
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_env_args() -> *mut DuckArr {
    let mut g = ARGS.lock().unwrap_or_else(|e| e.into_inner());
    if g.0.is_null() {
        unsafe {
            g.0 = duck_arr_new(&duck_ops_str, 0);
            duck__make_immortal(g.0.cast());
        }
    }
    g.0
}

// stdin: read through stdio (one buffer shared by read_line, read_all and lines). Stdout is
// flushed first, so a prompt printed without a newline-terminated flush still shows.

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_env_read_line() -> DuckOpt_str {
    unsafe {
        libc::fflush(c_stdout());
        let mut line: *mut c_char = null_mut();
        let mut cap: libc::size_t = 0;
        let mut n = libc::getline(&mut line, &mut cap, c_stdin());
        if n < 0 {
            libc::free(line.cast());
            return none_ptr();
        }
        if n > 0 && *line.add(n as usize - 1) == b'\n' as c_char {
            n -= 1;
        }
        if n > 0 && *line.add(n as usize - 1) == b'\r' as c_char {
            n -= 1;
        }
        let s = duck_str_from_bytes(line, n as i64); // invalid UTF-8 becomes U+FFFD
        libc::free(line.cast());
        DuckOpt::some(s)
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_env_read_all() -> DuckRes_str {
    unsafe {
        libc::fflush(c_stdout());
        let mut b = Vec::new();
        let err = slurp(c_stdin(), &mut b);
        if err != 0 {
            libc::clearerr(c_stdin());
            return err_ptr(duck__err_errno(c"env.read_all: stdin".as_ptr(), std::ptr::null(), err));
        }
        let mut r = duck_str_try_from_bytes(b.as_ptr().cast(), b.len() as i64);
        if !r.ok {
            let e = err_msg("env.read_all: stdin");
            (*e).cause = r.err; // moves the reference
            r.err = e;
        }
        r
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_env_lines() -> *mut DuckArr {
    unsafe {
        libc::fflush(c_stdout());
        let mut b = Vec::new();
        if slurp(c_stdin(), &mut b) != 0 {
            libc::clearerr(c_stdin()); // keep what was read before the error
        }
        let s = duck_str_from_bytes(b.as_ptr().cast(), b.len() as i64);
        let a = duck_str_lines(s);
        release(s);
        a
    }
}

// ---- proc --------------------------------------------------------------------------------

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_proc_run(cmd: *const DuckStr, args: *const DuckArr) -> DuckRes_str {
    unsafe {
        let n = if args.is_null() { 0 } else { (*args).len as usize };
        let mut argv: Vec<*mut c_char> = Vec::with_capacity(n + 2);
        argv.push(cs(cmd) as *mut c_char);
        let as_ = if n == 0 { std::ptr::null() } else { (*args).data as *const *const DuckStr };
        for i in 0..n {
            argv.push(cs(*as_.add(i)) as *mut c_char);
        }
        argv.push(null_mut());
        let mut fds = [0 as c_int; 2];
        if libc::pipe(fds.as_mut_ptr()) < 0 {
            return err_ptr(duck__err_errno(c"proc.run".as_ptr(), cmd, errno()));
        }
        libc::fcntl(fds[0], libc::F_SETFD, libc::FD_CLOEXEC);
        let mut fa: libc::posix_spawn_file_actions_t = std::mem::zeroed();
        libc::posix_spawn_file_actions_init(&mut fa);
        libc::posix_spawn_file_actions_adddup2(&mut fa, fds[1], 1);
        libc::posix_spawn_file_actions_addclose(&mut fa, fds[1]);
        let mut pid: libc::pid_t = 0;
        libc::fflush(c_stdout());
        let rc = libc::posix_spawnp(&mut pid, cs(cmd), &fa, std::ptr::null(), argv.as_ptr(), environ);
        libc::posix_spawn_file_actions_destroy(&mut fa);
        drop(argv);
        libc::close(fds[1]);
        if rc != 0 {
            libc::close(fds[0]);
            return err_ptr(duck__err_errno(c"proc.run".as_ptr(), cmd, rc));
        }
        let mut b = Vec::new();
        let mut buf = vec![0u8; 65536];
        loop {
            let r = libc::read(fds[0], buf.as_mut_ptr().cast(), buf.len());
            if r < 0 && errno() == libc::EINTR {
                continue;
            }
            if r <= 0 {
                break;
            }
            b.extend_from_slice(&buf[..r as usize]);
        }
        libc::close(fds[0]);
        let mut status: c_int = 0;
        while libc::waitpid(pid, &mut status, 0) < 0 {
            if errno() != libc::EINTR {
                status = -1;
                break;
            }
        }
        let out = duck_str_from_bytes(b.as_ptr().cast(), b.len() as i64);
        if status == -1 || !libc::WIFEXITED(status) || libc::WEXITSTATUS(status) != 0 {
            let ct = ctext(cmd);
            let e = if status != -1 && libc::WIFEXITED(status) {
                let st = libc::WEXITSTATUS(status);
                err_code(&format!("proc.run {ct}: exited with status {st}"), st)
            } else if status != -1 && libc::WIFSIGNALED(status) {
                let sig = libc::WTERMSIG(status);
                err_code(&format!("proc.run {ct}: killed by signal {sig}"), 128 + sig)
            } else {
                err_msg(&format!("proc.run {ct}: could not wait for the process"))
            };
            release(out);
            return err_ptr(e);
        }
        DuckRes::ok(out)
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_proc_exit(code: i64, loc: *const c_char) -> ! {
    if !(0..=255).contains(&code) {
        rt_panic!(loc, "proc.exit({}): code out of range 0..255", code);
    }
    unsafe {
        libc::fflush(c_stdout());
        libc::fflush(c_stderr());
        crate::trace::duck__trace_flush();
        if crate::rc::duck_leak_check() != 0 {
            libc::_exit(102);
        }
        // _exit, like a panic: async tasks may still be running on other threads.
        libc::_exit(code as c_int)
    }
}

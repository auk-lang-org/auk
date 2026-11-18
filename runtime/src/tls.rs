//! TLS client sessions for `net.tls` (was tls.c).
//!
//! Auk never implements cryptography itself. The C runtime drove the platform's TLS stack
//! (Network.framework on macOS, a dlopen'ed OpenSSL elsewhere); this port uses one portable
//! implementation instead: rustls (with the `ring` crypto provider) and the Mozilla root
//! store from `webpki-roots`, so it needs nothing installed at build or run time.
//!
//! Verification is always on and cannot be turned off: the server's chain is checked against
//! the bundled roots and its certificate against `host` (SNI is sent for DNS names). A failure
//! is an Err "net.tls <host>:<port>: certificate verification failed: <reason>".
//!
//! The session drives the TCP socket the AukConn owns (`c->fd`), as the OpenSSL backend did:
//! auk_conn_close frees the session (sending close_notify) and then closes the socket. Socket
//! I/O uses send(MSG_NOSIGNAL) / SO_NOSIGPIPE, so a peer reset never raises SIGPIPE.

use std::ffi::{CString, c_int, c_void};
use std::io::{self, Read, Write};
use std::sync::{Arc, OnceLock};

use rustls::pki_types::ServerName;
use rustls::{CertificateError, ClientConfig, ClientConnection, RootCertStore};

use crate::core::{SEND_FLAGS, conn_new, ctext, cs, err_code, errno, strerror, tcp_connect};
use crate::err::{auk__err_errno, err_msg};
use crate::*;

/// The connected socket, read and written with recv/send (EINTR retried).
struct FdIo(c_int);

impl Read for FdIo {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        loop {
            crate::task::wait_fd(self.0, false);
            let n = unsafe { libc::recv(self.0, buf.as_mut_ptr().cast(), buf.len(), 0) };
            if n >= 0 {
                return Ok(n as usize);
            }
            let e = errno();
            if e != libc::EINTR {
                return Err(io::Error::from_raw_os_error(e));
            }
        }
    }
}

impl Write for FdIo {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        loop {
            crate::task::wait_fd(self.0, true);
            let n = unsafe { libc::send(self.0, buf.as_ptr().cast(), buf.len(), SEND_FLAGS) };
            if n >= 0 {
                return Ok(n as usize);
            }
            let e = errno();
            if e != libc::EINTR {
                return Err(io::Error::from_raw_os_error(e));
            }
        }
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

struct RustlsTls {
    conn: ClientConnection,
    io: FdIo,
    eof: bool,
}

/// Why a TLS operation failed.
enum Fail {
    Io(io::Error),
    Tls(rustls::Error),
    /// The peer closed the TCP stream mid-handshake.
    Eof,
}

impl From<io::Error> for Fail {
    fn from(e: io::Error) -> Self {
        // rustls reports protocol errors met while reading through io::Error(InvalidData).
        match e.get_ref().and_then(|x| x.downcast_ref::<rustls::Error>()) {
            Some(t) => Fail::Tls(t.clone()),
            None => Fail::Io(e),
        }
    }
}

fn cert_reason(e: &CertificateError) -> String {
    match e {
        CertificateError::BadEncoding => "bad certificate".into(),
        CertificateError::Expired | CertificateError::ExpiredContext { .. } => "certificate has expired".into(),
        CertificateError::NotValidYet | CertificateError::NotValidYetContext { .. } => {
            "certificate is not yet valid".into()
        }
        CertificateError::Revoked => "certificate has been revoked".into(),
        CertificateError::UnknownIssuer => "certificate is not trusted (self-signed or no trusted root)".into(),
        CertificateError::NotValidForName | CertificateError::NotValidForNameContext { .. } => {
            "certificate does not match the host name".into()
        }
        CertificateError::BadSignature => "certificate has a bad signature".into(),
        CertificateError::InvalidPurpose | CertificateError::InvalidPurposeContext { .. } => {
            "certificate is not valid for a TLS server".into()
        }
        other => format!("{other}"),
    }
}

/// "<prefix>: <reason>" for a failure.
unsafe fn fail_err(prefix: &str, f: Fail) -> *mut AukErr {
    match f {
        Fail::Io(e) => match e.raw_os_error() {
            Some(code) if code != 0 => unsafe { err_code(&format!("{prefix}: {}", strerror(code)), code) },
            _ => err_msg(&format!("{prefix}: TLS error: {e}")),
        },
        Fail::Tls(rustls::Error::InvalidCertificate(c)) => {
            err_msg(&format!("{prefix}: certificate verification failed: {}", cert_reason(&c)))
        }
        Fail::Tls(rustls::Error::AlertReceived(a)) => {
            err_msg(&format!("{prefix}: TLS error: fatal alert from the server ({a:?})"))
        }
        Fail::Tls(e) => err_msg(&format!("{prefix}: TLS error: {e}")),
        Fail::Eof => err_msg(&format!("{prefix}: TLS error: the connection closed during the handshake")),
    }
}

fn config() -> Arc<ClientConfig> {
    static CFG: OnceLock<Arc<ClientConfig>> = OnceLock::new();
    CFG.get_or_init(|| {
        let roots = RootCertStore { roots: webpki_roots::TLS_SERVER_ROOTS.to_vec() };
        let cfg = ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_safe_default_protocol_versions() // TLS 1.2 and 1.3
            .expect("the ring provider supports the default TLS versions")
            .with_root_certificates(roots)
            .with_no_client_auth();
        Arc::new(cfg)
    })
    .clone()
}

impl RustlsTls {
    /// Send whatever TLS records are queued.
    fn flush(&mut self) -> Result<(), Fail> {
        while self.conn.wants_write() {
            self.conn.write_tls(&mut self.io)?;
        }
        Ok(())
    }

    /// Read one batch of records from the socket and process them; false at TCP EOF.
    fn pump(&mut self) -> Result<bool, Fail> {
        let n = self.conn.read_tls(&mut self.io)?;
        if let Err(e) = self.conn.process_new_packets() {
            let _ = self.flush(); // best-effort: the alert describing the failure
            return Err(Fail::Tls(e));
        }
        Ok(n > 0)
    }

    fn handshake(&mut self) -> Result<(), Fail> {
        while self.conn.is_handshaking() {
            self.flush()?;
            if !self.conn.is_handshaking() {
                break;
            }
            if self.conn.wants_read() && !self.pump()? {
                return Err(Fail::Eof);
            }
        }
        self.flush()
    }

    /// Up to buf.len() bytes of plaintext; 0 at EOF.
    fn read(&mut self, buf: &mut [u8]) -> Result<usize, Fail> {
        loop {
            match self.conn.reader().read(buf) {
                Ok(n) => return Ok(n), // 0: close_notify
                // the peer closed the stream without close_notify: also EOF
                Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(0),
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                Err(e) => return Err(e.into()),
            }
            self.flush()?;
            self.pump()?; // a TCP EOF is reported by the next reader().read
        }
    }

    fn write_all(&mut self, mut buf: &[u8]) -> Result<(), Fail> {
        while !buf.is_empty() {
            let n = self.conn.writer().write(buf)?;
            buf = &buf[n..];
            self.flush()?;
        }
        self.flush()
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_net_tls(host: *const AukStr, port: i64) -> AukRes_conn {
    unsafe {
        let ht = ctext(host);
        if !(port > 0 && port <= 65535) {
            return err_ptr(err_msg(&format!("net.tls {ht}:{port}: invalid port")));
        }
        if ht.is_empty() {
            return err_ptr(err_msg(&format!("net.tls :{port}: empty host")));
        }
        let prefix = format!("net.tls {ht}:{port}");
        // An IP literal is checked against the certificate's IP addresses (and sent no SNI).
        let name = match ServerName::try_from(ht.to_string()) {
            Ok(n) => n,
            Err(_) => return err_ptr(err_msg(&format!("{prefix}: invalid host name"))),
        };
        let ports = CString::new(port.to_string()).unwrap();
        let fd = match tcp_connect(cs(host), &ports) {
            Ok(fd) => fd,
            Err((why, code)) => {
                let msg = format!("{prefix}: {why}");
                return err_ptr(if code != 0 { err_code(&msg, code) } else { err_msg(&msg) });
            }
        };
        let conn = match ClientConnection::new(config(), name) {
            Ok(c) => c,
            Err(e) => {
                libc::close(fd);
                return err_ptr(fail_err(&prefix, Fail::Tls(e)));
            }
        };
        let mut t = Box::new(RustlsTls { conn, io: FdIo(fd), eof: false });
        if let Err(f) = t.handshake() {
            drop(t);
            libc::close(fd);
            return err_ptr(fail_err(&prefix, f));
        }
        let c = conn_new(fd);
        (*c).tls = Box::into_raw(t).cast();
        AukRes::ok(c)
    }
}

pub unsafe fn auk__tls_read(tls: *mut c_void, max: i64) -> AukRes_arr {
    let t = unsafe { &mut *(tls as *mut RustlsTls) };
    if t.eof {
        return AukRes::ok(unsafe { crate::core::bytes_to_arr(&[]) });
    }
    let mut buf = vec![0u8; max.max(0) as usize];
    match t.read(&mut buf) {
        Ok(n) => {
            if n == 0 {
                t.eof = true;
            }
            AukRes::ok(unsafe { crate::core::bytes_to_arr(&buf[..n]) })
        }
        Err(Fail::Io(e)) if e.raw_os_error().is_some_and(|c| c != 0) => {
            err_ptr(unsafe { auk__err_errno(c"net read".as_ptr(), std::ptr::null(), e.raw_os_error().unwrap()) })
        }
        Err(f) => err_ptr(unsafe { fail_err("net read", f) }),
    }
}

pub unsafe fn auk__tls_write(tls: *mut c_void, buf: *const u8, n: i64) -> AukRes_unit {
    let t = unsafe { &mut *(tls as *mut RustlsTls) };
    if n <= 0 {
        return AukRes::ok(0);
    }
    let b = unsafe { std::slice::from_raw_parts(buf, n as usize) };
    match t.write_all(b) {
        Ok(()) => AukRes::ok(0),
        Err(Fail::Io(e)) if e.raw_os_error().is_some_and(|c| c != 0) => {
            AukRes::err(unsafe { auk__err_errno(c"net write".as_ptr(), std::ptr::null(), e.raw_os_error().unwrap()) })
        }
        Err(f) => AukRes::err(unsafe { fail_err("net write", f) }),
    }
}

/// Closes the session (best-effort close_notify; the caller then closes the socket) and frees it.
pub unsafe fn auk__tls_free(tls: *mut c_void) {
    if tls.is_null() {
        return;
    }
    let mut t = unsafe { Box::from_raw(tls as *mut RustlsTls) };
    t.conn.send_close_notify();
    let _ = t.flush();
}

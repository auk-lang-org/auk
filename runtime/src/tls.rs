//! TLS sessions: now in C (`runtime/c/tls.c`, Network.framework on macOS, OpenSSL elsewhere).

use crate::*;

unsafe extern "C" {
    pub unsafe fn auk_net_tls(host: *const AukStr, port: i64) -> AukRes_conn;
}

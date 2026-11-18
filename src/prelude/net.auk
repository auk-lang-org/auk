/// TCP and TLS connections, and TCP listeners (`uses net`). Non-blocking inside an `async fn`.

pub extern type Conn = "AukConn *"
pub extern fn tcp(host: str, port: int): Conn! uses net = "auk_net_tcp"
/// A TLS client connection. The server's certificate is always verified (system trust store,
/// and the name against `host`); a bad one is an Err "certificate verification failed: ...".
pub extern fn tls(host: str, port: int): Conn! uses net = "auk_net_tls"
/// Up to `max` bytes (ints 0..255); empty means the peer closed the connection.
pub extern fn read(c: var Conn, max: int): [int]! uses net = "auk_conn_read"
/// Write every byte.
pub extern fn write(c: var Conn, data: [int]): ()! uses net = "auk_conn_write"
pub extern fn close(c: var Conn) uses net = "auk_conn_close"

/// A listening TCP socket.
pub extern type Listener = "AukListener *"
/// Listen on `host` ("" for every interface) and `port` (0 picks a free port; see `port(l)`).
pub extern fn listen(host: str, port: int): Listener! uses net = "auk_net_listen"
/// Wait for the next incoming connection.
pub extern fn accept(l: Listener): Conn! uses net = "auk_listener_accept"
/// The port `l` is bound to.
pub extern fn port(l: Listener): int uses net = "auk_listener_port"
pub extern fn close(l: var Listener) uses net = "auk_listener_close"

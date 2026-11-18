/// prelude-only forms
pub extern type Err = "AukErr *"
extern type Conn = "AukConn *"
pub extern fn len(s: str): int = "auk_str_len"
pub extern fn enum<T>(xs: [T]): [(int, T)] = "@enum"
extern async fn x(): int = "y"
fn match(a: int): int = a

extern type Db = "sqlite3 *"
extern type Stmt = "sqlite3_stmt *"
extern fn finalize(s: Stmt): int = "int sqlite3_finalize(sqlite3_stmt *)"
fn f(d: Db): int uses ffi = finalize(d)
fn main() {}

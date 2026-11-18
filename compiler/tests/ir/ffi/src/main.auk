// The system sqlite3 through `[link] libs = ["sqlite3"]` (tests/ffi.rs): an in-memory database,
// opened, written, queried and closed.

extern type Db = "sqlite3 *"
extern type Stmt = "sqlite3_stmt *"

extern fn version(): str = "const char *sqlite3_libversion(void)"
extern fn open(path: str, db: var Db?, flags: int, vfs: str?): int = "int sqlite3_open_v2(const char *filename, sqlite3 **ppDb, int flags, const char *zVfs)"
extern fn close(db: Db): int = "int sqlite3_close(sqlite3 *)"
extern fn exec(db: Db, sql: str, cb: ffi.Ptr, arg: ffi.Ptr, err: var str?): int =
  "int sqlite3_exec(sqlite3 *, const char *, void *, void *, char **errmsg) +free(sqlite3_free)"
extern fn prepare(db: Db, sql: str, n: int, stmt: var Stmt?, tail: var ffi.Ptr): int =
  "int sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte, sqlite3_stmt **ppStmt, const char **pzTail)"
extern fn bind_int(s: Stmt, i: int, v: int): int = "int sqlite3_bind_int64(sqlite3_stmt *, int, int64_t)"
extern fn bind_blob(s: Stmt, i: int, b: [int], n: int, d: ffi.Ptr): int = "int sqlite3_bind_blob(sqlite3_stmt *, int, const void *, int n, void *)"
extern fn step(s: Stmt): int = "int sqlite3_step(sqlite3_stmt *)"
extern fn column_int(s: Stmt, i: int): int = "int64_t sqlite3_column_int64(sqlite3_stmt *, int iCol)"
extern fn column_double(s: Stmt, i: int): float = "double sqlite3_column_double(sqlite3_stmt *, int iCol)"
extern fn column_text(s: Stmt, i: int): str? = "const unsigned char *sqlite3_column_text(sqlite3_stmt *, int iCol)"
extern fn column_blob(s: Stmt, i: int): ffi.Ptr = "const void *sqlite3_column_blob(sqlite3_stmt *, int iCol)"
extern fn column_bytes(s: Stmt, i: int): int = "int sqlite3_column_bytes(sqlite3_stmt *, int iCol)"
extern fn finalize(s: Stmt): int = "int sqlite3_finalize(sqlite3_stmt *)"
extern fn errmsg(db: Db): str = "const char *sqlite3_errmsg(sqlite3 *)"

let ROW = 100
let READWRITE_CREATE = 6

// (compiler/tests/ir: plus libc, casts, `#embed` and a call through a C function pointer)
extern type Buf = "struct buf *"
extern fn c_abs(n: int): int = "int abs(int)"
extern fn strlen(s: str): int = "size_t strlen(const char *)"
extern fn getenv(k: str): str? = "char *getenv(const char *)"
extern fn malloc(n: int): ffi.Ptr? = "void *malloc(size_t)"
extern fn free(p: ffi.Ptr) = "void free(void *)"
extern fn buf_at(p: ffi.Ptr): Buf = "(struct buf *)"
extern fn buf_ptr(b: Buf): ffi.Ptr = "(void *)"
extern fn maybe_buf(p: ffi.Ptr?): Buf? = "(struct buf *)"
extern fn note(): str = "#embed data/note.txt"
extern fn note_bytes(): [int] = "#embed data/note.txt"
extern fn note_len(): int = "#embed data/note.txt"
extern fn note_at(): ffi.Ptr = "#embed data/note.txt"
extern fn call_abs(f: ffi.Ptr, x: int): int = "int (*)(int)"

fn extras() uses ffi {
  print("{c_abs(-5)} {strlen("héllo")} {getenv("AUK_IR_NOT_SET") else "unset"}")
  let p = malloc(16)!
  let b = buf_at(p)
  print("{ffi.addr(buf_ptr(b)) == ffi.addr(p)} {maybe_buf(some(p)) != none} {maybe_buf(none) == none}")
  free(p)
  print("{note()} {note_bytes().len()} {note_len()} {ffi.addr(note_at()) != 0}")
  print(call_abs(ffi.symbol("abs") else ffi.null, -3))
}

fn main(): ()! uses ffi {
  extras()
  print("version ok {version().split(".").len() == 3}")
  var h: Db? = none
  if open(":memory:", &h, READWRITE_CREATE, none) != 0 { fail("open failed") }
  let db = h!
  var err: str? = none
  exec(db, "create table t(n integer, x real, s text, b blob)", ffi.null, ffi.null, &err)
  exec(db, "insert into t values (1, 1.5, 'one', null), (2, 2.5, null, null)", ffi.null, ffi.null, &err)
  print("err {err else "none"}")
  let rc = exec(db, "select nope", ffi.null, ffi.null, &err)
  print("bad sql {rc} {err else "none"} / {errmsg(db)}")
  var s: Stmt? = none
  var tail = ffi.null
  prepare(db, "insert into t(n, b) values (?, ?)", -1, &s, &tail)
  bind_int(s!, 1, 3)
  bind_blob(s!, 2, [0, 255, 7], 3, ffi.ptr(-1))
  print("insert {step(s!)}")
  finalize(s!)
  prepare(db, "select n, x, s, b from t order by n", -1, &s, &tail)
  let st = s!
  while step(st) == ROW {
    let b = ffi.bytes(column_blob(st, 3), column_bytes(st, 3))
    print("row {column_int(st, 0)} {column_double(st, 1)} {column_text(st, 2) else "NULL"} {b}")
  }
  finalize(st)
  print("close {close(db)}")
}

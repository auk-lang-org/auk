//! User-level FFI (docs/ffi-plan.md), end to end through the real binary:
//! - every marshalling case against a small C library built here (tests/fixtures/ffi/testlib.c,
//!   linked by path through `[link] libs`), in the JIT and in `auk build`, under the leak check;
//! - libc functions already in the process, with no `[link]` at all;
//! - the system sqlite3 by library name: an in-memory database opened, written, read, closed;
//! - the `ffi` effect gate (E0036), prototype/type mismatches (E0040), distinct handle types,
//!   implied `uses ffi`, and missing libraries and symbols.

use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::OnceLock;
use std::fs;

fn auk(args: &[&str]) -> Output {
    let mut c = Command::new(env!("CARGO_BIN_EXE_auk"));
    c.env_remove("AUK_LEAK_CHECK");
    c.args(args).output().unwrap()
}

fn text(o: &Output) -> (String, String) {
    (String::from_utf8_lossy(&o.stdout).into_owned(), String::from_utf8_lossy(&o.stderr).into_owned())
}

fn scratch(name: &str) -> PathBuf {
    let d = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("ffi").join(name);
    let _ = fs::remove_dir_all(&d);
    fs::create_dir_all(d.join("src")).unwrap();
    d
}

/// A project in a fresh directory: `effects` and `[link] libs` in raft.toml, `main` as
/// src/main.auk. Returns the main file.
fn project(name: &str, effects: &str, libs: &[&str], main: &str) -> PathBuf {
    let d = scratch(name);
    let mut toml = format!("[package]\nname = \"{name}\"\nversion = \"0.1.0\"\neffects = [{effects}]\n");
    if !libs.is_empty() {
        let ls: Vec<String> = libs.iter().map(|l| format!("\"{l}\"")).collect();
        toml += &format!("\n[link]\nlibs = [{}]\n", ls.join(", "));
    }
    fs::write(d.join("raft.toml"), toml).unwrap();
    let f = d.join("src/main.auk");
    fs::write(&f, main).unwrap();
    f
}

/// tests/fixtures/ffi/testlib.c as a shared library (built once).
fn testlib() -> &'static Path {
    static LIB: OnceLock<PathBuf> = OnceLock::new();
    LIB.get_or_init(|| {
        let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("ffi-lib");
        fs::create_dir_all(&dir).unwrap();
        let mac = cfg!(target_os = "macos");
        let lib = dir.join(if mac { "libauktest.dylib" } else { "libauktest.so" });
        let out = Command::new("cc")
            .args(if mac { &["-dynamiclib"][..] } else { &["-shared", "-fPIC"][..] })
            .arg("tests/fixtures/ffi/testlib.c")
            .arg("-o")
            .arg(&lib)
            .output()
            .expect("cc");
        assert!(out.status.success(), "building testlib.c failed:\n{}", String::from_utf8_lossy(&out.stderr));
        lib
    })
}

fn run(main: &Path, args: &[&str], leak_check: bool) -> Output {
    let mut c = Command::new(env!("CARGO_BIN_EXE_auk"));
    c.arg("run").arg(main).args(args);
    if leak_check {
        c.env("AUK_LEAK_CHECK", "1");
    } else {
        c.env_remove("AUK_LEAK_CHECK");
    }
    c.output().unwrap()
}

fn run_ok(main: &Path) -> String {
    let o = run(main, &[], true);
    let (out, err) = text(&o);
    assert!(o.status.success(), "auk run {} failed ({:?}):\n{out}\n{err}", main.display(), o.status.code());
    out
}

/// `auk build` the program and run the executable.
fn build_ok(main: &Path) -> String {
    let exe = main.parent().unwrap().join("prog");
    let o = auk(&["build", main.to_str().unwrap(), "-o", exe.to_str().unwrap()]);
    assert!(o.status.success(), "auk build failed:\n{}", text(&o).1);
    let o = Command::new(&exe).output().unwrap();
    assert!(o.status.success(), "{}", text(&o).1);
    text(&o).0
}

const MARSHALLED: &str = "\
ints -56 255 4464 65534 -1 4294967295 -1 42 66
scalars false true 1.5 66534.75
hi Auk ✓
none
null param 1 0
owned freed 1
out 42 ok freed 2
out -2 none freed 2
scaled 4.5 6.0 true
made 1 0
maybe true 3
id_or 5 7
sum 27 same true false
reversed [11, 9, 7]
hex 0x0
fill [10, 19, -32] kept [1, 2, -3]
floats 0.75 [0.5, 1.5] 3000000000003 2
empty [] 0
checksum 1026
bytes [250, 251, 252] [1, 2, 255, 0]
cstr hi
fnptr 42 4.5 hi ptr
";

fn marshalling_project(name: &str) -> PathBuf {
    let lib = testlib().display().to_string();
    project(name, "\"ffi\"", &[&lib], &fs::read_to_string("tests/fixtures/ffi/main.auk").unwrap())
}

#[test]
fn every_marshalling_case_in_the_jit() {
    let main = marshalling_project("marshal_jit");
    assert_eq!(run_ok(&main), MARSHALLED);
}

#[test]
fn every_marshalling_case_built_native() {
    let main = marshalling_project("marshal_build");
    assert_eq!(build_ok(&main), MARSHALLED);
}

#[test]
fn null_for_a_str_result_panics() {
    let main = marshalling_project("marshal_null");
    let o = run(&main, &["x"], false);
    let (_, err) = text(&o);
    assert_eq!(o.status.code(), Some(101), "{err}");
    assert!(err.contains("t_null_str returned NULL where a `str` was expected (declare the result `str?`)"), "{err}");
}

const LIBC: &str = r#"
extern fn c_abs(n: int): int = "int abs(int)"
extern fn strlen(s: str): int = "size_t strlen(const char *)"
extern fn getenv(k: str): str? = "char *getenv(const char *)"
extern fn malloc(n: int): ffi.Ptr? = "void *malloc(size_t)"
extern fn free(p: ffi.Ptr) = "void free(void *)"

fn main() uses ffi {
  print("{c_abs(-5)} {c_abs(4294967296 + 7)} {strlen("héllo")}")
  print("{getenv("AUK_FFI_TEST") else "unset"} {getenv("AUK_FFI_NOT_SET") else "unset"}")
  let p = malloc(16)!
  ffi.write_i64(p, 8, 99)
  ffi.write_u8(p, 0, 300)
  print("{p.is_null()} {p == ffi.null} {ffi.null.is_null()} {ffi.read_i64(p, 8)} {ffi.read_u8(p, 0)}")
  free(p)
}
"#;

#[test]
fn libc_functions_already_in_the_process() {
    let main = project("libc", "\"ffi\"", &[], LIBC);
    let o = Command::new(env!("CARGO_BIN_EXE_auk")).arg("run").arg(&main).env("AUK_FFI_TEST", "set").env("AUK_LEAK_CHECK", "1").output().unwrap();
    let (out, err) = text(&o);
    assert!(o.status.success(), "{err}");
    assert_eq!(out, "5 7 6\nset unset\nfalse false true 99 44\n");
    let exe = main.parent().unwrap().join("prog");
    assert!(auk(&["build", main.to_str().unwrap(), "-o", exe.to_str().unwrap()]).status.success());
    let o = Command::new(&exe).env("AUK_FFI_TEST", "set").output().unwrap();
    assert_eq!(text(&o).0, out);
}

const SQLITE_OUT: &str = "\
version ok true
err none
bad sql 1 no such column: nope / no such column: nope
insert 101
row 1 1.5 one []
row 2 2.5 NULL []
row 3 0.0 NULL [0, 255, 7]
close 0
";

/// Is libsqlite3 loadable here? (macOS ships it; Linux needs the package, else the test skips.)
fn have_sqlite() -> bool {
    cfg!(target_os = "macos") || ["/usr/lib/x86_64-linux-gnu/libsqlite3.so", "/usr/lib/aarch64-linux-gnu/libsqlite3.so", "/usr/lib/libsqlite3.so"].iter().any(|p| Path::new(p).exists())
}

#[test]
fn sqlite_by_library_name() {
    if !have_sqlite() {
        eprintln!("skipping: no libsqlite3");
        return;
    }
    let main = project("sqlite", "\"ffi\"", &["sqlite3"], &fs::read_to_string("tests/fixtures/ffi/sqlite.auk").unwrap());
    assert_eq!(run_ok(&main), SQLITE_OUT);
    assert_eq!(build_ok(&main), SQLITE_OUT);
}

// ---- diagnostics ----

/// `auk check` on a project: (exit ok, stderr).
fn check(name: &str, effects: &str, main: &str) -> (bool, String) {
    let f = project(name, effects, &[], main);
    let o = auk(&["check", f.to_str().unwrap()]);
    (o.status.success(), text(&o).1)
}

#[test]
fn extern_needs_the_ffi_effect_in_raft_toml() {
    let (ok, err) = check("gate", "\"env\"", "extern fn c_abs(n: int): int = \"int abs(int)\"\nfn main() uses ffi { print(c_abs(-1)) }\n");
    assert!(!ok);
    assert!(err.contains("error[E0036]: `extern` declarations need the `ffi` effect in the package's raft.toml"), "{err}");
    assert!(err.contains("help: add \"ffi\" to `effects` under [package]"), "{err}");
    let (ok, err) = check("gate_type", "", "extern type Db = \"sqlite3 *\"\nfn main() {}\n");
    assert!(!ok && err.contains("error[E0036]"), "{err}");
}

#[test]
fn a_dependency_needs_ffi_in_its_own_manifest() {
    let d = scratch("dep_app");
    let dep = d.join(".raft/cdep");
    fs::create_dir_all(dep.join("src")).unwrap();
    fs::write(dep.join("raft.toml"), "[package]\nname = \"cdep\"\nversion = \"0.1.0\"\neffects = []\n").unwrap();
    fs::write(dep.join("src/lib.auk"), "pub extern fn c_abs(n: int): int = \"int abs(int)\"\n").unwrap();
    fs::write(d.join("raft.toml"), "[package]\nname = \"dep_app\"\nversion = \"0.1.0\"\neffects = [\"ffi\"]\n\n[deps]\ncdep = \"*\"\n").unwrap();
    fs::write(d.join("src/main.auk"), "fn main() uses ffi { print(cdep.c_abs(-1)) }\n").unwrap();
    let o = auk(&["check", d.join("src/main.auk").to_str().unwrap()]);
    let err = text(&o).1;
    assert!(!o.status.success() && err.contains("cdep/src/lib.auk:1:15: error[E0036]"), "{err}");
}

#[test]
fn callers_need_uses_ffi() {
    let (ok, err) = check("uses", "\"ffi\"", "extern fn c_abs(n: int): int = \"int abs(int)\"\nfn f(): int = c_abs(-1)\nfn main() uses ffi { print(f()) }\n");
    assert!(!ok);
    assert!(err.contains("error[E0410]: `f` uses the effect `ffi` but doesn't declare it"), "{err}");
}

#[test]
fn prototypes_that_dont_fit() {
    let src = r#"extern type Db = "sqlite3 *"
extern fn a(s: str): int = "int f(char *)"
extern fn b(x: int): int = "int f(int, int)"
extern fn c(x: float): int = "int f(int)"
extern fn d(x: Db): int = "int f(sqlite3_stmt *)"
extern fn e(x: int): int = "int f(LLVMBool)"
extern fn g(x: int): int = "int printf(const char *, ...)"
extern fn h(x: int) = "void qsort(int (*cmp)(const void *, const void *))"
extern fn i(x: int): str = "int f(int) +free(free)"
extern fn j(x: str): int = "size_t strlen(const char *) +free(free)"
extern fn k(x: var str): int = "int f(char **)"
extern fn l(): [int] = "int *f(void)"
extern fn m<T>(x: T): int = "int f(int)"
extern type Bad = "int"
extern fn n(x: int): int = "int (*)(int)"
extern fn o(f: int, x: int): int = "int (*)(int)"
fn main() {}
"#;
    let (ok, err) = check("e0040", "\"ffi\"", src);
    assert!(!ok);
    for want in [
        "2:16: error[E0040]: parameter 1 of `a` is `str`, which doesn't fit the C type `char *`",
        "3:28: error[E0040]: `b` has 1 parameter(s), but the C prototype of `f` has 2",
        "4:16: error[E0040]: parameter 1 of `c` is `float`, which doesn't fit the C type `int`",
        "this type is the C type `sqlite3 *`, not `sqlite3_stmt *`",
        "`LLVMBool` is a C type name the FFI doesn't know",
        "variadic C functions (`...`) aren't supported",
        "function pointers (callbacks from C into Auk) aren't supported",
        "`i` returns `str`, which doesn't fit the C result type `int`",
        "`+free` in `j`'s prototype, but it hands over no `char *` string",
        "an out-parameter string is `var str?`",
        "a C function can't return a list",
        "the C function `m` can't be generic",
        "`int` can't be an `extern type`",
        "`n` has 1 parameter(s), but a call through a function pointer with this prototype takes 2",
        "parameter 1 of `o` is `int`, which doesn't fit the C type `void *`",
    ] {
        assert!(err.contains(want), "missing {want:?} in:\n{err}");
    }
    assert_eq!(err.matches("error[E0040]").count(), 15, "{err}");
}

#[test]
fn handle_types_dont_mix() {
    let src = r#"extern type Db = "sqlite3 *"
extern type Stmt = "sqlite3_stmt *"
extern fn finalize(s: Stmt): int = "int sqlite3_finalize(sqlite3_stmt *)"
fn f(d: Db): int uses ffi = finalize(d)
fn main() {}
"#;
    let (ok, err) = check("handles", "\"ffi\"", src);
    assert!(!ok && err.contains("error[E0200]: expected `Stmt`, found `Db`"), "{err}");
}

#[test]
fn missing_libraries_and_symbols_are_named() {
    let main = project("missing_sym", "\"ffi\"", &[], "extern fn nope(): int = \"int auk_no_such_c_function(void)\"\nfn main() uses ffi { print(nope()) }\n");
    let (_, err) = text(&run(&main, &[], false));
    assert!(err.contains("error: C function `auk_no_such_c_function` not found (no libraries are linked)"), "{err}");
    let main = project("missing_lib", "\"ffi\"", &["auk_no_such_lib"], "fn main() {}\n");
    let o = run(&main, &[], false);
    let (_, err) = text(&o);
    assert!(!o.status.success() && err.contains("error: cannot load the C library `auk_no_such_lib`"), "{err}");
    let o = auk(&["build", main.to_str().unwrap(), "-o", main.parent().unwrap().join("p").to_str().unwrap()]);
    assert!(!o.status.success(), "linking a missing library succeeded");
}

/// `"(T)"` casts between `ffi.Ptr` and an `extern type`, both ways (no call), in the JIT and built.
const CASTS: &str = r#"
extern type Buf = "struct buf *"
extern fn buf_new(n: int): Buf? = "struct buf *malloc(size_t)"
extern fn buf_free(b: Buf) = "void free(struct buf *)"
extern fn buf_ptr(b: Buf): ffi.Ptr = "(void *)"
extern fn buf_at(p: ffi.Ptr): Buf = "(struct buf *)"
extern fn maybe_buf(p: ffi.Ptr?): Buf? = "(struct buf *)"

fn main() uses ffi {
  let b = buf_new(16)!
  let p = buf_ptr(b)
  ffi.write_i64(p, 8, 77)
  let back = buf_at(ffi.offset(p, 0))
  print("{ffi.read_i64(buf_ptr(back), 8)} {ffi.addr(buf_ptr(back)) == ffi.addr(p)}")
  print("{maybe_buf(none) == none} {maybe_buf(some(p)) != none}")
  buf_free(back)
}
"#;

#[test]
fn casts_between_handles_and_pointers() {
    let main = project("casts", "\"ffi\"", &[], CASTS);
    let out = run_ok(&main);
    assert_eq!(out, "77 true\ntrue true\n");
    assert_eq!(build_ok(&main), out);
    let bad = r#"extern type Db = "sqlite3 *"
extern fn a(x: int): ffi.Ptr = "(void *)"
extern fn b(x: ffi.Ptr): Db = "(void *)"
extern fn c(x: ffi.Ptr, y: ffi.Ptr): Db = "(sqlite3 *)"
extern fn d(x: ffi.Ptr): int = "(int)"
fn main() {}
"#;
    let (ok, err) = check("bad_casts", "\"ffi\"", bad);
    assert!(!ok);
    for want in [
        "parameter 1 of `a` is `int`",
        "a cast `(T)` converts an opaque pointer",
        "`b` returns `Db`, which doesn't fit the C result type `void *`",
        "`c` has 2 parameter(s), but a cast takes 1",
        "a cast converts between pointer types; `int` isn't one",
    ] {
        assert!(err.contains(want), "missing {want:?} in:\n{err}");
    }
}

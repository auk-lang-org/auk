/// tests/ffi.rs: user-level FFI (design/ffi-plan.md), end to end through the real binary:
/// - every marshalling case against a small C library built here (tests/fixtures/ffi/testlib.c,
///   linked by path through `[link] libs`), in the JIT and in `auk build`, under the leak check;
/// - libc functions already in the process, with no `[link]` at all;
/// - the system sqlite3 by library name: an in-memory database opened, written, read, closed;
/// - the `ffi` effect gate (E0036), prototype/type mismatches (E0040), distinct handle types,
///   implied `uses ffi`, and missing libraries and symbols.

pub fn tests(): [t.Test] uses env, fs, ffi, time = [
  t.test("every_marshalling_case_in_the_jit", every_marshalling_case_in_the_jit),
  t.test("every_marshalling_case_built_native", every_marshalling_case_built_native),
  t.test("null_for_a_str_result_panics", null_for_a_str_result_panics),
  t.test("libc_functions_already_in_the_process", libc_functions_already_in_the_process),
  t.test("sqlite_by_library_name", sqlite_by_library_name),
  t.test("extern_needs_the_ffi_effect_in_raft_toml", extern_needs_the_ffi_effect_in_raft_toml),
  t.test("a_dependency_needs_ffi_in_its_own_manifest", a_dependency_needs_ffi_in_its_own_manifest),
  t.test("callers_need_uses_ffi", callers_need_uses_ffi),
  t.test("prototypes_that_dont_fit", prototypes_that_dont_fit),
  t.test("handle_types_dont_mix", handle_types_dont_mix),
  t.test("missing_libraries_and_symbols_are_named", missing_libraries_and_symbols_are_named),
  t.test("runtime_symbols_by_name", runtime_symbols_by_name),
  t.test("embedded_files", embedded_files),
  t.test("casts_between_handles_and_pointers", casts_between_handles_and_pointers),
]

extern fn c_mkdtemp(t: ffi.Ptr): ffi.Ptr? = "char *mkdtemp(char *)"

fn auk(args: [str]): cmd.Out uses env, ffi, time =
  t.auk().unsetenv("AUK_LEAK_CHECK").args(args).output()

fn scratch(name: str): str uses env, fs, ffi {
  let d = t.scratch("ffi/{name}")
  t.must(fs.mkdir(paths.join(d, "src")), "mkdir")
  d
}

/// A project in a fresh directory: `effects` and `[link] libs` in raft.toml, `main` as
/// src/main.auk. Returns the main file.
fn project(name: str, effects: str, libs: [str], main: str): str uses env, fs, ffi {
  let d = scratch(name)
  var toml = "[package]\nname = \"{name}\"\nversion = \"0.1.0\"\neffects = [{effects}]\n"
  if libs.len() > 0 {
    let ls = libs.map(l => "\"{l}\"")
    toml = toml + "\n[link]\nlibs = [{ls.join(", ")}]\n"
  }
  t.write(paths.join(d, "raft.toml"), toml)
  let f = paths.join(d, "src/main.auk")
  t.write(f, main)
  f
}

/// tests/fixtures/ffi/testlib.c as a shared library (built once: tests run concurrently, so one
/// that finds it missing builds it in a directory of its own and renames it into place).
fn testlib(): str uses env, fs, ffi, time {
  let dir = paths.join(t.tmp_base(), "ffi-lib")
  let mac = t.macos()
  let lib = paths.join(dir, if mac { "libauktest.dylib" } else { "libauktest.so" })
  if fs.exists(lib) { return lib }
  t.must(fs.mkdir(dir), "mkdir {dir}")
  let tpl = paths.join(dir, "build-XXXXXX")
  let p = ffi.from_bytes(tpl.bytes() + [0])
  let r = c_mkdtemp(p)
  let tmp = ffi.cstr(p)
  ffi.free(p)
  if r is none { t.fail("mkdtemp {tpl} failed") }
  let built = paths.join(tmp, paths.file_name(lib))
  // (built elsewhere and renamed, so on macOS its install name is set to where it ends up)
  let out = cmd
    .new("cc")
    .args(if mac { ["-dynamiclib", "-Wl,-install_name,{lib}"] } else { ["-shared", "-fPIC"] })
    .arg("tests/fixtures/ffi/testlib.c")
    .arg("-o")
    .arg(built)
    .output()
  t.check(out.success(), "building testlib.c failed:\n{out.stderr}")
  t.must(fs.rename(built, lib), "rename {built}")
  t.rm_rf(tmp)
  lib
}

fn run(main: str, args: [str], leak_check: bool): cmd.Out uses env, ffi, time {
  let c = t.auk().arg("run").arg(main).args(args)
  if leak_check { c.setenv("AUK_LEAK_CHECK", "1") } else { c.unsetenv("AUK_LEAK_CHECK") }.output()
}

fn run_ok(main: str): str uses env, ffi, time {
  let o = run(main, [], true)
  t.check(o.success(), "auk run {main} failed ({o.code}):\n{o.stdout}\n{o.stderr}")
  o.stdout
}

fn dir_of(p: str): str = paths.parent(p) else "."

/// `auk build` the program and run the executable.
fn build_ok(main: str): str uses env, ffi, time {
  let exe = paths.join(dir_of(main), "prog")
  let o = auk(["build", main, "-o", exe])
  t.check(o.success(), "auk build failed:\n{o.stderr}")
  let o = cmd.new(exe).output()
  t.check(o.success(), o.stderr)
  o.stdout
}

let MARSHALLED = """
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
  """

fn marshalling_project(name: str): str uses env, fs, ffi, time {
  let lib = testlib()
  project(name, "\"ffi\"", [lib], t.read("tests/fixtures/ffi/main.auk"))
}

fn every_marshalling_case_in_the_jit() uses env, fs, ffi, time {
  let main = marshalling_project("marshal_jit")
  t.eq(run_ok(main), MARSHALLED, "")
}

fn every_marshalling_case_built_native() uses env, fs, ffi, time {
  let main = marshalling_project("marshal_build")
  t.eq(build_ok(main), MARSHALLED, "")
}

fn null_for_a_str_result_panics() uses env, fs, ffi, time {
  let main = marshalling_project("marshal_null")
  let o = run(main, ["x"], false)
  t.check(o.code == some(101), o.stderr)
  t.check(
    o.stderr.contains("t_null_str returned NULL where a `str` was expected (declare the result `str?`)"),
    o.stderr,
  )
}

let LIBC = r"""

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
  """

fn libc_functions_already_in_the_process() uses env, fs, ffi, time {
  let main = project("libc", "\"ffi\"", [], LIBC)
  let o = t
    .auk()
    .arg("run")
    .arg(main)
    .setenv("AUK_FFI_TEST", "set")
    .setenv("AUK_LEAK_CHECK", "1")
    .output()
  t.check(o.success(), o.stderr)
  t.eq(o.stdout, "5 7 6\nset unset\nfalse false true 99 44\n", "")
  let exe = paths.join(dir_of(main), "prog")
  assert auk(["build", main, "-o", exe]).success()
  let o2 = cmd.new(exe).setenv("AUK_FFI_TEST", "set").output()
  t.eq(o2.stdout, o.stdout, "")
}

let SQLITE_OUT = """
  version ok true
  err none
  bad sql 1 no such column: nope / no such column: nope
  insert 101
  row 1 1.5 one []
  row 2 2.5 NULL []
  row 3 0.0 NULL [0, 255, 7]
  close 0
  """

/// Is libsqlite3 loadable here? (macOS ships it; Linux needs the package, else the test skips.)
fn have_sqlite(): bool uses fs, ffi {
  t.macos() ||
    [
      "/usr/lib/x86_64-linux-gnu/libsqlite3.so",
      "/usr/lib/aarch64-linux-gnu/libsqlite3.so",
      "/usr/lib/libsqlite3.so",
    ].any(p => fs.exists(p))
}

fn sqlite_by_library_name() uses env, fs, ffi, time {
  if !have_sqlite() {
    eprint("skipping: no libsqlite3")
    return
  }
  let main = project("sqlite", "\"ffi\"", ["sqlite3"], t.read("tests/fixtures/ffi/sqlite.auk"))
  t.eq(run_ok(main), SQLITE_OUT, "")
  t.eq(build_ok(main), SQLITE_OUT, "")
}

// ---- diagnostics ----

/// `auk check` on a project: (exit ok, stderr).
fn check(name: str, effects: str, main: str): (bool, str) uses env, fs, ffi, time {
  let f = project(name, effects, [], main)
  let o = auk(["check", f])
  (o.success(), o.stderr)
}

fn extern_needs_the_ffi_effect_in_raft_toml() uses env, fs, ffi, time {
  let (ok, err) = check(
    "gate",
    "\"env\"",
    "extern fn c_abs(n: int): int = \"int abs(int)\"\nfn main() uses ffi {{ print(c_abs(-1)) }}\n",
  )
  assert !ok
  t.check(
    err.contains("error[E0036]: `extern` declarations need the `ffi` effect in the package's raft.toml"),
    err,
  )
  t.check(err.contains("help: add \"ffi\" to `effects` under [package]"), err)
  let (ok, err) = check("gate_type", "", "extern type Db = \"sqlite3 *\"\nfn main() {{}}\n")
  t.check(!ok && err.contains("error[E0036]"), err)
}

fn a_dependency_needs_ffi_in_its_own_manifest() uses env, fs, ffi, time {
  let d = scratch("dep_app")
  let dep = paths.join(d, ".raft/cdep")
  t.write(
    paths.join(dep, "raft.toml"),
    "[package]\nname = \"cdep\"\nversion = \"0.1.0\"\neffects = []\n",
  )
  t.write(paths.join(dep, "src/lib.auk"), "pub extern fn c_abs(n: int): int = \"int abs(int)\"\n")
  t.write(
    paths.join(d, "raft.toml"),
    "[package]\nname = \"dep_app\"\nversion = \"0.1.0\"\neffects = [\"ffi\"]\n\n[deps]\ncdep = \"*\"\n",
  )
  t.write(paths.join(d, "src/main.auk"), "fn main() uses ffi {{ print(cdep.c_abs(-1)) }}\n")
  let o = auk(["check", paths.join(d, "src/main.auk")])
  t.check(!o.success() && o.stderr.contains("cdep/src/lib.auk:1:15: error[E0036]"), o.stderr)
}

fn callers_need_uses_ffi() uses env, fs, ffi, time {
  let (ok, err) = check(
    "uses",
    "\"ffi\"",
    "extern fn c_abs(n: int): int = \"int abs(int)\"\nfn f(): int = c_abs(-1)\nfn main() uses ffi {{ print(f()) }}\n",
  )
  assert !ok
  t.check(err.contains("error[E0410]: `f` uses the effect `ffi` but doesn't declare it"), err)
}

fn prototypes_that_dont_fit() uses env, fs, ffi, time {
  let src = r"""
    extern type Db = "sqlite3 *"
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
    """
  let (ok, err) = check("e0040", "\"ffi\"", src)
  assert !ok
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
    t.check(err.contains(want), "missing {want.show()} in:\n{err}")
  }
  t.check(t.count(err, "error[E0040]") == 15, err)
}

fn handle_types_dont_mix() uses env, fs, ffi, time {
  let src = r"""
    extern type Db = "sqlite3 *"
    extern type Stmt = "sqlite3_stmt *"
    extern fn finalize(s: Stmt): int = "int sqlite3_finalize(sqlite3_stmt *)"
    fn f(d: Db): int uses ffi = finalize(d)
    fn main() {}
    """
  let (ok, err) = check("handles", "\"ffi\"", src)
  t.check(!ok && err.contains("error[E0200]: expected `Stmt`, found `Db`"), err)
}

fn missing_libraries_and_symbols_are_named() uses env, fs, ffi, time {
  let main = project(
    "missing_sym",
    "\"ffi\"",
    [],
    "extern fn nope(): int = \"int auk_no_such_c_function(void)\"\nfn main() uses ffi {{ print(nope()) }}\n",
  )
  let err = run(main, [], false).stderr
  t.check(
    err.contains("error: C function `auk_no_such_c_function` not found (no libraries are linked)"),
    err,
  )
  let main = project("missing_lib", "\"ffi\"", ["auk_no_such_lib"], "fn main() {{}}\n")
  let o = run(main, [], false)
  t.check(
    !o.success() && o.stderr.contains("error: cannot load the C library `auk_no_such_lib`"),
    o.stderr,
  )
  let o = auk(["build", main, "-o", paths.join(dir_of(main), "p")])
  t.check(!o.success(), "linking a missing library succeeded")
}

/// `ffi.symbol` finds the runtime in this process, as a compiler written in Auk does for the
/// code it JIT-compiles: in `auk run` (the compiler's process) and in an executable from
/// `auk build` (which exports the runtime's symbols); runtime functions called by address.
let SYMBOLS = r"""

  extern fn make_str(f: ffi.Ptr, s: str, n: int): ffi.Ptr = "void *(*)(const char *, int64_t)"
  extern fn str_len(f: ffi.Ptr, s: ffi.Ptr): int = "int64_t (*)(void *)"
  extern fn release(f: ffi.Ptr, p: ffi.Ptr) = "void (*)(void *)"

  fn main() uses ffi {
    let s = make_str(ffi.symbol("auk_str_from_bytes")!, "héllo", 6)
    print(str_len(ffi.symbol("auk_str_len")!, s))
    release(ffi.symbol("auk_release")!, s)
    print("{ffi.symbol("strlen") != none} {ffi.symbol("auk_no_such_symbol") == none}")
  }
  """

fn runtime_symbols_by_name() uses env, fs, ffi, time {
  let main = project("symbols", "\"ffi\"", [], SYMBOLS)
  let out = run_ok(main)
  t.eq(out, "5\ntrue true\n", "")
  t.eq(build_ok(main), out, "")
}

/// `"#embed path"`: a file read at compile time, as `[int]`, `ffi.Ptr` + `int` and `str`; the
/// built executable still has it after the file is gone, and writes the bytes back unchanged.
let EMBED = r"""

  extern fn blob(): [int] = "#embed data/all.bin"
  extern fn blob_at(): ffi.Ptr = "#embed data/all.bin"
  extern fn blob_len(): int = "#embed data/all.bin"
  extern fn note(): str = "#embed data/note.txt"

  fn main(args: [str]): ()! uses ffi, fs {
    let b = blob()
    print("{b.len()} {blob_len()} {b[0]} {b[255]} {b == ffi.bytes(blob_at(), blob_len())}")
    print("{ffi.read_u8(blob_at(), 10)} {note().trim()} {note().byte_len()}")
    fs.write_bytes(args[1], b)?
  }
  """

fn embedded_files() uses env, fs, ffi, time {
  let main = project("embed", "\"ffi\", \"fs\"", [], EMBED)
  let base = dir_of(main)
  let dir = paths.join(base, "data")
  t.must(fs.mkdir(dir), "mkdir")
  let all = (0..256).map(i => i)
  t.must(fs.write_bytes(paths.join(dir, "all.bin"), all), "write")
  t.write(paths.join(dir, "note.txt"), "héllo ✓\n")
  let want = "256 256 0 255 true\n10 héllo ✓ 11\n"
  let out = paths.join(base, "out.bin")
  let o = run(main, [out], true)
  t.check(o.success(), o.stderr)
  t.eq(o.stdout, want, "")
  assert t.must(fs.read_bytes(out), "read") == all
  let exe = paths.join(base, "prog")
  let o = auk(["build", main, "-o", exe])
  t.check(o.success(), o.stderr)
  t.rm_rf(dir)
  t.must(fs.remove(out), "remove")
  let o = cmd.new(exe).arg(out).output()
  t.eq(o.stdout, want, o.stderr)
  assert t.must(fs.read_bytes(out), "read") == all

  // errors: a missing file, a type that isn't a form of a file, parameters, non-UTF-8 text
  let bad = r"""
    extern fn a(): [int] = "#embed nope.bin"
    extern fn b(): float = "#embed bad.txt"
    extern fn c(x: int): int = "#embed bad.txt"
    extern fn d(): str = "#embed bad.txt"
    fn main() {}
    """
  let d = scratch("embed_bad")
  t.write(
    paths.join(d, "raft.toml"),
    "[package]\nname = \"embed_bad\"\nversion = \"0.1.0\"\neffects = [\"ffi\"]\n",
  )
  t.write(paths.join(d, "src/main.auk"), bad)
  t.must(fs.write_bytes(paths.join(d, "src/bad.txt"), [0x66, 0xff, 0x0a]), "write")
  let o = auk(["check", paths.join(d, "src/main.auk")])
  assert !o.success()
  for want in [
    "`a`: cannot read the file to embed",
    "`b` returns `float`, which isn't a form of an embedded file",
    "`c` embeds a file, so it takes no parameters",
    "`d` embeds `bad.txt` as a `str`, but it isn't UTF-8 (at byte 1)",
  ] {
    t.check(o.stderr.contains(want), "missing {want.show()} in:\n{o.stderr}")
  }
}

/// `"(T)"` casts between `ffi.Ptr` and an `extern type`, both ways (no call), in the JIT and built.
let CASTS = r"""

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
  """

fn casts_between_handles_and_pointers() uses env, fs, ffi, time {
  let main = project("casts", "\"ffi\"", [], CASTS)
  let out = run_ok(main)
  t.eq(out, "77 true\ntrue true\n", "")
  t.eq(build_ok(main), out, "")
  let bad = r"""
    extern type Db = "sqlite3 *"
    extern fn a(x: int): ffi.Ptr = "(void *)"
    extern fn b(x: ffi.Ptr): Db = "(void *)"
    extern fn c(x: ffi.Ptr, y: ffi.Ptr): Db = "(sqlite3 *)"
    extern fn d(x: ffi.Ptr): int = "(int)"
    fn main() {}
    """
  let (ok, err) = check("bad_casts", "\"ffi\"", bad)
  assert !ok
  for want in [
    "parameter 1 of `a` is `int`",
    "a cast `(T)` converts an opaque pointer",
    "`b` returns `Db`, which doesn't fit the C result type `void *`",
    "`c` has 2 parameter(s), but a cast takes 1",
    "a cast converts between pointer types; `int` isn't one",
  ] {
    t.check(err.contains(want), "missing {want.show()} in:\n{err}")
  }
}

/// The runtime's dialect (docs/lowlevel.md, Phase 7a), end to end through the real binary: each
/// program in runtime/test/raw/ runs in a project of the runtime package (`name = "auk_rt"`),
/// in the JIT and built (O2): fixed-width arithmetic, pointers on malloc'd memory, unions read
/// through two fields, globals and constants, setjmp/longjmp out of nested calls, export fns by
/// value; a library (`auk build --lib`) linked with C that checks layouts against C's, calls
/// both ways and thread-locals across pthreads; its bitcode (`--bc`); C data (`extern var`);
/// the gate (E0418), the no-RC type rule (E0419), compile-time constants (E0421); `auk fmt`
/// and `auk check` on the dialect; runtime/src/abi.auk and cfacts against C (runtime/test/abi).

pub fn tests(): [t.Test] uses env, fs, ffi, time = [
  t.test("fixed_width_arithmetic_wraps", fixed_width_arithmetic_wraps),
  t.test("pointers_on_malloced_memory", pointers_on_malloced_memory),
  t.test("unions_and_casts_at_o2", unions_and_casts_at_o2),
  t.test("globals_constants_and_raw_assert", globals_constants_and_raw_assert),
  t.test("addresses_in_constant_initializers", addresses_in_constant_initializers),
  t.test("constants_of_other_modules", constants_of_other_modules),
  t.test("int_and_i64_mix", int_and_i64_mix),
  t.test("raw_type_aliases", raw_type_aliases),
  t.test("never_void_and_parameter_addresses", never_void_and_parameter_addresses),
  t.test("a_library_without_exports_is_empty", a_library_without_exports_is_empty),
  t.test("thread_vars_are_refused_by_the_jit", thread_vars_are_refused_by_the_jit),
  t.test("setjmp_longjmp_out_of_nested_calls", setjmp_longjmp_out_of_nested_calls),
  t.test("export_fns_by_value_and_fn_pointers", export_fns_by_value_and_fn_pointers),
  t.test("a_library_called_from_c", a_library_called_from_c),
  t.test("c_abi_of_raw_structs_matches_cc", c_abi_of_raw_structs_matches_cc),
  t.test("library_bitcode_keeps_exports", library_bitcode_keeps_exports),
  t.test("extern_vars_read_c_data", extern_vars_read_c_data),
  t.test("raw_is_only_for_the_runtime_e0418", raw_is_only_for_the_runtime_e0418),
  t.test("refcounted_types_in_raw_code_e0419", refcounted_types_in_raw_code_e0419),
  t.test("constants_and_raw_assert_e0421", constants_and_raw_assert_e0421),
  t.test("fmt_and_check_handle_the_dialect", fmt_and_check_handle_the_dialect),
  t.test("overflow_and_bit_intrinsics", overflow_and_bit_intrinsics),
  t.test("per_target_module_files", per_target_module_files),
  t.test("per_target_variants_agree_e0422", per_target_variants_agree_e0422),
  t.test("abi_and_cfacts_match_c", abi_and_cfacts_match_c),
  t.test("uninitialized_locals", uninitialized_locals),
  t.test("noinline_export_fns", noinline_export_fns),
  t.test("no_cancellation_points_in_the_runtime", no_cancellation_points_in_the_runtime),
]

let TOML = "[package]\nname = \"auk_rt\"\nversion = \"0.1.0\"\neffects = [\"raw\", \"ffi\"]\n"

fn auk(args: [str]): cmd.Out uses env, ffi, time = t.auk().unsetenv("AUK_LEAK_CHECK").args(args).output()

/// A project of the runtime package in a fresh directory, `src` as src/main.auk (`toml` its
/// raft.toml). Returns the main file.
fn project_with(name: str, toml: str, src: str): str uses env, fs, ffi {
  let d = t.scratch("raw/{name}")
  t.write(paths.join(d, "raft.toml"), toml)
  let f = paths.join(d, "src/main.auk")
  t.write(f, src)
  f
}

fn project(name: str, src: str): str uses env, fs, ffi = project_with(name, TOML, src)

/// runtime/test/raw/<file> in a runtime project.
fn fixture(name: str, file: str): str uses env, fs, ffi = project(name, t.read("runtime/test/raw/{file}"))

fn dir_of(p: str): str = paths.parent(paths.parent(p) else ".") else "."

/// `auk run` (and `-O`) and `auk build` of a program whose exit code is 0 when every check
/// passed (the code says which failed); returns the JIT's stdout.
fn passes(main: str): str uses env, ffi, time {
  let o = auk(["run", main])
  t.check(o.success(), "auk run {main}: {o.code}\n{o.stdout}{o.stderr}")
  let o2 = auk(["run", "-O", main])
  t.check(o2.success(), "auk run -O {main}: {o2.code}\n{o2.stdout}{o2.stderr}")
  built_passes(main)
  o.stdout
}

fn built_passes(main: str) uses env, ffi, time {
  let exe = paths.join(dir_of(main), "prog")
  let b = auk(["build", main, "-o", exe])
  t.check(b.success(), "auk build {main}:\n{b.stderr}")
  let r = cmd.new(exe).output()
  t.check(r.success(), "built {main}: {r.code}\n{r.stdout}{r.stderr}")
}

/// The diagnostic codes of `auk check --json`.
fn codes(main: str): [str] uses env, ffi, time {
  let out = auk(["check", main, "--json"]).stdout
  out.split("\"code\":\"").skip(1).map(s => s[0..5])
}

fn fixed_width_arithmetic_wraps() uses env, fs, ffi, time {
  let main = fixture("arith", "arith.auk")
  t.eq(passes(main), "4 -2147483648 4 -3 8 3.0 44 true -56\n6\ncmp ok\nleft ok\n", "")
}

fn pointers_on_malloced_memory() uses env, fs, ffi, time { let _ = passes(fixture("ptr", "ptr.auk")) }

fn unions_and_casts_at_o2() uses env, fs, ffi, time { let _ = passes(fixture("union", "union.auk")) }

fn globals_constants_and_raw_assert() uses env, fs, ffi, time {
  built_passes(fixture("globals", "globals.auk"))
}

fn addresses_in_constant_initializers() uses env, fs, ffi, time { let _ = passes(fixture("const_addr", "const_addr.auk")) }

/// `pub raw let`s (and functions, globals) of another module in constant initializers.
fn constants_of_other_modules() uses env, fs, ffi, time {
  let main = project("xmod", r"""
    raw var lock: facts.Mutex = facts.MUTEX_INIT
    raw let X = facts.K_STR + 1
    raw var tab: [u32; 2] = [facts.K_STR, X]
    raw var f: raw.Fn<(i64) => i64> = raw.fn_of(facts.twice)
    raw var pc: raw.Ptr<i64> = raw.addr_of(&facts.counter)
    fn main(): int uses raw {
      if lock.sig != 0x32AAABA7 || lock.opaque.is_null() || X != 5 || f(4) != 8 { return 1 }
      if pc.load() != 7 { return 2 }
      0
    }
    """)
  t.write(paths.join(paths.parent(main) else ".", "facts.auk"), r"""
    pub raw struct Mutex { sig: i64, opaque: raw.Ptr<()> }
    pub raw let MUTEX_INIT: Mutex = Mutex { sig: 0x32AAABA7, opaque: raw.cast(raw.addr_of(&counter)) }
    pub raw let K_STR: u32 = 4
    raw let HIDDEN: u32 = 1
    pub raw var counter: i64 = 7
    pub fn twice(x: i64): i64 = x * 2
    """)
  let _ = passes(main)
  // a private one is E0120
  t.write(main, "raw let H = facts.HIDDEN\nfn main() {{}}\n")
  t.check(codes(main).contains("E0120"), "{codes(main)}")
}

fn int_and_i64_mix() uses env, fs, ffi, time { let _ = passes(fixture("int_i64", "int_i64.auk")) }

/// `raw type` aliases, also of another module (alias.auk, with a `facts` module).
fn raw_type_aliases() uses env, fs, ffi, time {
  let main = fixture("alias", "alias.auk")
  t.write(paths.join(paths.parent(main) else ".", "facts.auk"), "pub raw type ModeT = u16\npub raw let S_IFDIR: ModeT = 0x4000\n")
  let _ = passes(main)
  // only raw types; not outside the runtime
  let bad = project("alias_rc", "raw type S = str\nfn main() {{}}\n")
  t.eq("{codes(bad)}", "[\"E0419\"]", "")
  let plain = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n"
  let gate = project_with("alias_gate", plain, "raw type N = int\nfn main() {{}}\n")
  t.eq("{codes(gate)}", "[\"E0418\"]", "")
}

/// `never` and `()` results as C's `_Noreturn` and `void`; `raw.addr_of(&param)`.
fn never_void_and_parameter_addresses() uses env, fs, ffi, time {
  let main = fixture("cfuncs", "cfuncs.auk")
  let _ = passes(main)
  let dis = llvm_dis() else return
  let bc = paths.join(dir_of(main), "cfuncs.bc")
  let b = auk(["build", "--lib", "--bc", main, "-o", bc])
  t.check(b.success(), b.stderr)
  let ll = cmd.new(dis).args([bc, "-o", "-"]).output().stdout
  t.has(ll, "define void @bump(i64")
  t.has(ll, "define void @stop(i32")
}

/// Plumbing can be committed before its first `export fn`: an empty library.
fn a_library_without_exports_is_empty() uses env, fs, ffi, time {
  let main = project("lib_empty", "raw let K: i32 = 1\nfn helper(): i32 = K\n")
  let obj = paths.join(dir_of(main), "empty.o")
  let b = auk(["build", "--lib", main, "-o", obj])
  t.check(b.success(), b.stderr)
  t.check(fs.exists(obj), "no {obj}")
}

fn thread_vars_are_refused_by_the_jit() uses env, fs, ffi, time {
  let main = fixture("tls_jit", "globals.auk")
  let o = auk(["run", main])
  t.check(!o.success(), o.stdout)
  t.has(o.stderr, "`raw thread var`")
}

fn setjmp_longjmp_out_of_nested_calls() uses env, fs, ffi, time { let _ = passes(fixture("sjlj", "sjlj.auk")) }

fn export_fns_by_value_and_fn_pointers() uses env, fs, ffi, time { let _ = passes(fixture("abi", "abi.auk")) }

fn a_library_called_from_c() uses env, fs, ffi, time {
  t.skip_if_lacks("cc", "a C compiler to link the library with")
  let main = fixture("lib", "lib.auk")
  let d = dir_of(main)
  let obj = paths.join(d, "lib.o")
  let b = auk(["build", "--lib", main, "-o", obj])
  t.check(b.success(), "auk build --lib:\n{b.stderr}")
  let exe = paths.join(d, "prog")
  let libs = if t.macos() { [] } else { ["-lpthread"] }
  let c = cmd.new("cc").args(["runtime/test/raw/lib_main.c", obj, "-o", exe] + libs).output()
  t.check(c.success(), "cc:\n{c.stderr}")
  let r = cmd.new(exe).output()
  t.eq(r.stdout, "ok\n", r.stderr)
  // the symbols: the exports, by their names; no `main`
  if t.have("nm") {
    let syms = cmd.new("nm").arg(obj).output().stdout
    for s in ["auk_bump", "auk_v2_add", "auk_mk_big", "auk_flag", "auk_ops"] { t.has(syms, s) }
    t.lacks_text(syms, " T _main\n")
    t.lacks_text(syms, " T main\n")
  }
}

/// Raw structs by value across C calls both ways (cabi.auk with cabi_main.c, compiled by cc):
/// float members (x86-64 SSE eightbytes, AArch64 HFAs), mixed eightbytes, aggregates in
/// memory, and registers running out partway through the arguments.
fn c_abi_of_raw_structs_matches_cc() uses env, fs, ffi, time {
  t.skip_if_lacks("cc", "a C compiler to link the library with")
  let main = fixture("cabi", "cabi.auk")
  let d = dir_of(main)
  let obj = paths.join(d, "cabi.o")
  let b = auk(["build", "--lib", main, "-o", obj])
  t.check(b.success(), "auk build --lib:\n{b.stderr}")
  let exe = paths.join(d, "prog")
  let c = cmd.new("cc").args(["runtime/test/raw/cabi_main.c", obj, "-o", exe]).output()
  t.check(c.success(), "cc:\n{c.stderr}")
  let r = cmd.new(exe).output()
  t.eq(r.stdout, "ok\n", r.stderr)
}

/// `llvm-dis` next to the `clang` build.sh uses, if any.
fn llvm_dis(): str? uses ffi, time {
  let o = cmd.new("sh").args(["-c", "command -v llvm-dis || ls /opt/homebrew/opt/llvm/bin/llvm-dis 2>/dev/null || ls /usr/lib/llvm-23/bin/llvm-dis 2>/dev/null"]).output()
  let p = o.stdout.trim()
  if p == "" { none } else { p.lines()[0] }
}

fn library_bitcode_keeps_exports() uses env, fs, ffi, time {
  let main = fixture("lib_bc", "lib.auk")
  let bc = paths.join(dir_of(main), "lib.bc")
  let b = auk(["build", "--lib", "--bc", main, "-o", bc])
  t.check(b.success(), "auk build --lib --bc:\n{b.stderr}")
  let bytes = t.must(fs.read_bytes(bc), "read {bc}")
  t.check(bytes.take(4) == [0x42, 0x43, 0xc0, 0xde] || bytes.take(4) == [0xde, 0xc0, 0x17, 0x0b], "not bitcode")
  let dis = llvm_dis() else return t.skip("llvm-dis not found")
  let ll = cmd.new(dis).args([bc, "-o", "-"]).output().stdout
  // an `inline export fn` is an ordinary external definition, marked `inlinehint` (for rtlink)
  t.has(ll, "define ")
  t.has(ll, "@auk_str_len(")
  t.has(ll, "inlinehint")
  t.lacks_text(ll, "define internal i64 @auk_str_len")
  // a `raw var` is internal, a `raw thread var` thread-local (rtlink keeps their users out of
  // programs), an `export var` external
  t.has(ll, "thread_local")
  t.has(ll, "@auk_flag = ")
  t.lacks_text(ll, "@auk_flag = internal")
  t.has(ll, "internal thread_local")
}

fn extern_vars_read_c_data() uses env, fs, ffi, time {
  let _ = passes(fixture("extern_var", "extern_var.auk"))
  if t.macos() { let _ = passes(fixture("extern_var_macos", "extern_var_macos.auk")) }
  // reading C data needs `uses raw`
  let main = project("extern_var_effect", r"""
    extern var environ: raw.Ptr<raw.Ptr<u8>> = "environ"
    fn f(): bool = environ.is_null()
    fn main() {}
    """)
  t.check(codes(main).contains("E0410"), "{codes(main)}")
}

fn raw_is_only_for_the_runtime_e0418() uses env, fs, ffi, time {
  let plain = "[package]\nname = \"app\"\nversion = \"0.1.0\"\neffects = [\"ffi\"]\n"
  let srcs = [
    "fn f() uses raw {{}}\nfn main() {{}}\n",
    "raw struct S {{ a: int }}\nfn main() {{}}\n",
    "raw var n: int = 0\nfn main() {{}}\n",
    "export fn f(): int = 1\nfn main() {{}}\n",
  ]
  for i, src in srcs {
    let main = project_with("gate{i}", plain, src)
    t.eq("{codes(main)}", "[\"E0418\"]", src)
  }
  // a manifest other than the runtime's can't list `raw`
  let listed = "[package]\nname = \"app\"\nversion = \"0.1.0\"\neffects = [\"raw\"]\n"
  let main = project_with("gate_toml", listed, "fn main() {{}}\n")
  t.check(codes(main).contains("E0418"), "{codes(main)}")
  // ordinary code doesn't see the `raw` module or the fixed-width types
  let main2 = project_with("gate_names", plain, "fn main() {{ let x: u8 = 1 }}\n")
  t.eq("{codes(main2)}", "[\"E0104\"]", "")
}

fn refcounted_types_in_raw_code_e0419() uses env, fs, ffi, time {
  let srcs = [
    "fn f(p: raw.Ptr<i64>): i64 uses raw {{\n  let s = \"no\"\n  p.load()\n}}\nfn main() {{}}\n",
    "fn f(xs: [int], p: raw.Ptr<i64>): i64 uses raw = p.load()\nfn main() {{}}\n",
    "raw struct S {{ name: str }}\nfn main() {{}}\n",
    "struct P {{ x: int }}\nfn f(p: raw.Ptr<P>, q: P): i64 uses raw = 0\nfn main() {{}}\n",
  ]
  for i, src in srcs {
    let main = project("rc{i}", src)
    t.eq("{codes(main)}", "[\"E0419\"]", src)
  }
}

fn constants_and_raw_assert_e0421() uses env, fs, ffi, time {
  let srcs = [
    "raw struct H {{ a: i64, b: u32 }}\nraw assert raw.size_of<H>() == 12\nfn main() {{}}\n",
    "fn g(): i64 = 1\nraw var n: i64 = g()\nfn main() {{}}\n",
    "fn f(p: raw.Ptr<i64>, o: raw.Order): i64 uses raw = raw.atomic_load(p, o)\nfn main() {{}}\n",
    "fn f(p: raw.Ptr<i64>): i64 uses raw = raw.atomic_load(p, raw.Order.Release)\nfn main() {{}}\n",
    // addresses: not of a thread-local or a `raw let`, only of functions by name
    "raw thread var t: i64 = 0\nraw var p: raw.Ptr<i64> = raw.addr_of(&t)\nfn main() {{}}\n",
    "raw let K: i64 = 1\nraw var p: raw.Ptr<i64> = raw.addr_of(&K)\nfn main() {{}}\n",
    "raw var f: raw.Fn<() => i64> = raw.fn_of(nope)\nfn main() {{}}\n",
  ]
  for i, src in srcs {
    let main = project("const{i}", src)
    t.eq("{codes(main)}", "[\"E0421\"]", src)
  }
  // a literal that doesn't fit is E0210, as for a local (arithmetic still wraps)
  for i, src in ["raw let Y: u8 = 300\nfn main() {{}}\n", "raw var Z: u8 = -1\nfn main() {{}}\n", "raw let W: i8 = -129\nfn main() {{}}\n"] {
    let main = project("lit{i}", src)
    t.eq("{codes(main)}", "[\"E0210\"]", src)
  }
  let ok = project("lit_ok", "raw let W: i8 = -128\nraw let V: u8 = 250 + 10\nraw assert V == 4\nfn main() {{}}\n")
  t.eq("{codes(ok)}", "[]", "")
}

fn fmt_and_check_handle_the_dialect() uses env, fs, ffi, time {
  for f in ["lib.auk", "ptr.auk", "globals.auk", "union.auk", "sjlj.auk", "const_addr.auk", "int_i64.auk"] {
    let src = t.read("runtime/test/raw/{f}")
    let o = t.auk().args(["fmt", "-"]).stdin(src).output()
    t.check(o.success(), "auk fmt {f}:\n{o.stderr}")
    // formatting is stable
    let o2 = t.auk().args(["fmt", "-"]).stdin(o.stdout).output()
    t.eq(o2.stdout, o.stdout, "auk fmt {f} twice")
    let main = project("fmt_{f.strip_suffix(".auk") else f}", o.stdout)
    t.eq("{codes(main)}", "[]", "auk check of formatted {f}")
    let d = auk(["dump", "ast", main])
    t.check(d.success(), "auk dump ast {f}:\n{d.stderr}")
  }
}

fn overflow_and_bit_intrinsics() uses env, fs, ffi, time { let _ = passes(fixture("bits", "bits.auk")) }

/// `plat.macos.auk`, `plat.linux.auk`, `plat.<os>-<arch>.auk` and `plat.auk`: only the most
/// specific match of this machine is the module `plat` (the runtime package only).
fn per_target_module_files() uses env, fs, ffi, time {
  let main = project("targets", r"""
    fn main() { print(plat.name()) }
    """)
  let src = paths.parent(main) else "."
  let os = paths.os()
  let arch = cmd.new("uname").arg("-m").output().stdout.trim()
  let a = if arch == "aarch64" { "arm64" } else { arch }
  t.write(paths.join(src, "plat.auk"), "pub fn name(): str = \"plain\"\n")
  t.write(paths.join(src, "plat.macos.auk"), "pub fn name(): str = \"macos\"\n")
  t.write(paths.join(src, "plat.linux.auk"), "pub fn name(): str = \"linux\"\n")
  t.write(paths.join(src, "plat.plan9.auk"), "pub fn name(): str = \"plan9\"\n")
  let o = auk(["run", main])
  t.eq(o.stdout, "{os}\n", o.stderr)
  // the `<os>-<arch>` file wins over `<os>`
  t.write(paths.join(src, "plat.{os}-{a}.auk"), "pub fn name(): str = \"{os}-{a}\"\n")
  let o2 = auk(["run", main])
  t.eq(o2.stdout, "{os}-{a}\n", o2.stderr)
  // with neither, the plain file
  t.rm_rf(paths.join(src, "plat.{os}.auk"))
  t.rm_rf(paths.join(src, "plat.{os}-{a}.auk"))
  let o3 = auk(["run", main])
  t.eq(o3.stdout, "plain\n", o3.stderr)
}

/// runtime/src/abi.auk and this platform's cfacts.<os>-<arch>.auk against C: their raw asserts,
/// every size, offset, constant and initializer through an `auk build --lib` probe linked with
/// C (the real auk_rt.h and system headers), and the same public items on every platform.
fn abi_and_cfacts_match_c() uses env, fs, ffi, time {
  t.skip_if_lacks("cc", "a C compiler to link the probe with")
  let o = cmd.new("bash").args(["runtime/test/abi/run.sh", t.auk_bin()]).unsetenv("AUK_LEAK_CHECK").output()
  t.check(o.success(), "runtime/test/abi/run.sh:\n{o.stdout}{o.stderr}")
  t.has(o.stdout, "ok: abi.auk and cfacts.")
}

/// What the package uses from a module with per-target files must be in the variant of every
/// target that uses it, with one signature; a target's own items may be its alone; the other
/// targets' files are parsed too (E0422).
fn per_target_variants_agree_e0422() uses env, fs, ffi, time {
  let main = project("variants", "fn main() {{ print(plat.name()) }}\n")
  let src = paths.parent(main) else "."
  t.write(paths.join(src, "plat.macos.auk"), "pub fn name(): str = \"macos\"\npub raw let ONLY_MAC: i32 = 1\n")
  t.write(paths.join(src, "plat.linux.auk"), "pub fn name(): str = \"linux\"\npub raw let ELF: i32 = 2\n")
  // each target's own file uses its own extras
  t.write(paths.join(src, "hooks.macos.auk"), "pub fn f(): i32 = plat.ONLY_MAC\n")
  t.write(paths.join(src, "hooks.linux.auk"), "pub fn f(): i32 = plat.ELF\n")
  t.eq("{codes(main)}", "[]", "")
  // shared code using one target's extra
  t.write(main, "fn main() {{ print(plat.name())\n let _ = plat.ONLY_MAC }}\n")
  t.eq("{codes(main)}", "[\"E0422\"]", "once, for linux-arm64 and linux-x86_64")
  let o = auk(["check", main])
  t.has(o.stderr, "`plat.ONLY_MAC` isn't declared in `plat.linux.auk`")
  // a signature that differs
  t.write(main, "fn main() {{ print(plat.name()) }}\n")
  let other = if paths.os() == "macos" { "plat.linux.auk" } else { "plat.macos.auk" }
  t.write(paths.join(src, other), "pub fn name(): int = 1\npub raw let ELF: i32 = 2\npub raw let ONLY_MAC: i32 = 1\n")
  t.eq("{codes(main)}", "[\"E0422\"]", "")
  t.has(auk(["check", main]).stderr, "`name` is `fn name(): int` here but `fn name(): str`")
  // another target's file that doesn't parse
  t.write(paths.join(src, other), "pub fn name(: str = 1\n")
  t.check(codes(main).len() > 0, "a parse error in {other}")
}

/// `var x: T` without a value: undefined contents (C's uninitialized local), for raw types in
/// the runtime package only; nothing zeroes it, and a literal in an `optnone` function is
/// built in its variable (one memset, no copies).
fn uninitialized_locals() uses env, fs, ffi, time {
  let _ = passes(fixture("uninit", "uninit.auk"))
  let src = t.read("runtime/test/raw/uninit.auk")
  let o = t.auk().args(["fmt", "-"]).stdin(src).output()
  t.eq(o.stdout, src, "auk fmt keeps `var x: T`")
  // only raw types, only in the runtime
  t.eq("{codes(project("uninit_rc", "fn main() {{\n  var s: str\n  s = \"a\"\n  print(s)\n}}\n"))}", "[\"E0419\"]", "")
  let plain = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n"
  let gate = project_with("uninit_gate", plain, "fn main() {{\n  var n: int\n  n = 1\n  print(n)\n}}\n")
  t.eq("{codes(gate)}", "[\"E0418\"]", "")
  let dis = llvm_dis() else return t.skip("llvm-dis not found")
  let main = fixture("uninit_lib", "uninit_lib.auk")
  let bc = paths.join(dir_of(main), "u.bc")
  let b = auk(["build", "--lib", "--bc", main, "-o", bc])
  t.check(b.success(), b.stderr)
  let ll = cmd.new(dis).args([bc, "-o", "-"]).output().stdout
  let body = (name: str) => ll.split("@{name}(")[1].split("\n}}\n")[0]
  t.lacks_text(body("run_undef"), "llvm.memset")
  t.lacks_text(body("run_undef"), "llvm.memcpy")
  t.lacks_text(body("scratch"), "llvm.memset")
  t.has(body("run_lit"), "llvm.memset")
  t.lacks_text(body("run_lit"), "llvm.memcpy")
}

/// `noinline export fn`: LLVM's `noinline` (and `auk fmt` keeps it); outside the runtime, E0418.
fn noinline_export_fns() uses env, fs, ffi, time {
  let src = "noinline export fn auk_big(n: i64): i64 = n * 3\nexport fn auk_small(n: i64): i64 = auk_big(n) + 1\n"
  let o = t.auk().args(["fmt", "-"]).stdin(src).output()
  t.eq(o.stdout, src, "auk fmt keeps `noinline export fn`")
  let main = project("noinline", src + "fn main(): int = int(auk_small(2)) - 7\n")
  let _ = passes(main)
  let plain = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n"
  let gate = project_with("noinline_gate", plain, "noinline export fn f(): int = 1\nfn main() {{}}\n")
  t.eq("{codes(gate)}", "[\"E0418\"]", "")
  let dis = llvm_dis() else return t.skip("llvm-dis not found")
  let bc = paths.join(dir_of(main), "n.bc")
  let b = auk(["build", "--lib", "--bc", main, "-o", bc])
  t.check(b.success(), b.stderr)
  let ll = cmd.new(dis).args([bc, "-o", "-"]).output().stdout
  // the call stays a call at O2
  t.has(ll.split("@auk_small(")[1].split("\n}}\n")[0], "call i64 @auk_big(")
  t.has(ll, "noinline")
}

/// No cancellation points in the runtime package: neither in `uses raw` functions nor in its
/// plain helpers (an ordinary package keeps one per loop iteration).
fn no_cancellation_points_in_the_runtime() uses env, fs, ffi, time {
  let src = "fn count(n: int): int {{\n  var i = 0\n  while i < n {{ i += 1 }}\n  i\n}}\n\nfn main() {{ print(count(3)) }}\n"
  let main = project("no_cancel", src)
  let body = (ir: str) => ir.split("_count(int64_t v0) {{")[1].split("\n}}\n")[0]
  let o = auk(["ir", main])
  t.check(o.success(), o.stderr)
  t.lacks_text(body(o.stdout), "auk_cancel_check")
  let plain = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n"
  let app = project_with("cancel_app", plain, src)
  t.has(body(auk(["ir", app]).stdout), "auk_cancel_check")
}

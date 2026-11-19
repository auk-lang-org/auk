/// `auk build`'s back half (src/build.rs `build_native`): the program compiled to an object file
/// (O2, with the runtime's inlinable functions) and linked with the runtime library
/// (`libauk_rt.a`, embedded in the compiler: build.sh builds it into `target/auk-rt/`) by the
/// system linker itself, no C compiler driver (self-host-plan 7d): Apple's `ld` with the SDK on
/// macOS, `ld.lld` (or GNU `ld`) with glibc's start files on Linux. `AUK_LINKER` names a C
/// compiler driver (`cc`) to link with instead. With debug info (`-g`, the MIR carries source
/// locations) on macOS, LLVM's `dsymutil` gathers the DWARF into `<out>.dSYM`.
///
/// build.sh's `link_exe` links the seed the same way: keep the two in step.

extern fn runtime_lib(): ffi.Ptr = "#embed ../../target/auk-rt/libauk_rt.a"
extern fn runtime_lib_len(): int = "#embed ../../target/auk-rt/libauk_rt.a"

extern fn c_creat(path: str, mode: int): int = "int creat(const char *, int)"
extern fn c_write(fd: int, p: ffi.Ptr, n: int): int = "long write(int, void *, size_t)"
extern fn c_close(fd: int): int = "int close(int)"

/// Write `n` bytes at `p` to a new file `path`.
fn write_mem(path: str, p: ffi.Ptr, n: int): ()! uses ffi {
  let fd = c_creat(path, 420)
  if fd < 0 { return fail("error: cannot write {path}\n") }
  var at = 0
  while at < n {
    let w = c_write(fd, ffi.offset(p, at), n - at)
    if w <= 0 {
      c_close(fd)
      return fail("error: cannot write {path}\n")
    }
    at += w
  }
  let _ = c_close(fd)
}

extern fn c_dladdr(addr: ffi.Ptr, info: ffi.Ptr): int = "int dladdr(const void *, void *)"

/// Libraries the runtime needs besides libc and libm: the system TLS (macOS), dlopen and threads
/// (Linux; part of libSystem on macOS).
fn link_libs(macos: bool): [str] = if macos {
  ["-framework", "CoreFoundation", "-framework", "Security", "-framework", "Network"]
} else {
  ["-ldl", "-lpthread"]
}

/// Linker arguments for the C libraries of `[link] libs`: `-l<name>` (a name with a `/` is a
/// path to the library), plus Homebrew's library directories on macOS.
fn user_libs(links: [str], macos: bool): [str]! uses fs, env, proc {
  var out: [str] = []
  if links.len() == 0 { return out }
  if macos {
    for d in ["/opt/homebrew/lib", "/usr/local/lib"] {
      if fs.is_dir(d) { out.push("-L{d}") }
    }
  }
  for l0 in links {
    let l = orcjit.expand_link(l0)?
    out.push(if l.contains("/") { l } else { "-l{l}" })
  }
  out
}

/// The path of `name` on the PATH, or none.
fn on_path(name: str): str? uses fs, env {
  for d in (env.get("PATH") else "").split(":") {
    let p = paths.join(if d == "" { "." } else { d }, name)
    if paths.is_file(p) { return some(p) }
  }
  none
}

/// The bin directory of the LLVM this compiler runs on, as `llvm-config --bindir` names it:
/// next to the `lib/` its libLLVM was loaded from (`dladdr`). None when the library isn't in
/// LLVM's own tree (Debian's is in /usr/lib/<multiarch>).
fn llvm_bindir(): str? uses fs, ffi {
  let f = ffi.symbol("LLVMContextCreate")?
  let info = ffi.alloc(64)
  let name = if c_dladdr(f, info) != 0 && !ffi.is_null(ffi.read_ptr(info, 0)) {
    some(ffi.cstr(ffi.read_ptr(info, 0)))
  } else {
    none
  }
  ffi.free(info)
  let lib = paths.canonicalize(name?)?
  let bin = paths.join(paths.parent(paths.parent(lib)?)?, "bin")
  if fs.is_dir(bin) { some(bin) } else { none }
}

/// LLVM's tool `name` (`dsymutil`, `ld.lld`) from LLVM's bin directory, else `name` (looked up on
/// the PATH when it runs).
fn llvm_tool(name: str): str uses fs, ffi {
  match llvm_bindir() {
    some(b) => {
      let p = paths.join(b, name)
      if paths.is_file(p) { p } else { name }
    }
    none => name
  }
}

// ---- macOS: Apple's ld (ld-prime, from the Command Line Tools or Xcode) ----------------------

/// The macOS SDK the linker takes libSystem's and the frameworks' stubs from: `$SDKROOT`, else
/// the one in the selected developer directory (`xcode-select`'s link), else the Command Line
/// Tools', else what `xcrun` says.
fn macos_sdk(): str! uses fs, env, proc, ffi {
  let root = env.get("SDKROOT") else ""
  if root != "" && fs.is_dir(root) { return root }
  var devs: [str] = []
  match paths.canonicalize("/var/db/xcode_select_link") {
    some(d) => devs.push(d)
    none => {}
  }
  devs.push("/Library/Developer/CommandLineTools")
  for d in devs {
    for s in ["Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk", "SDKs/MacOSX.sdk"] {
      let p = paths.join(d, s)
      if fs.is_dir(p) { return p }
    }
  }
  let p = (proc.run("xcrun", ["--sdk", "macosx", "--show-sdk-path"]) else "").trim()
  if p != "" && fs.is_dir(p) { return p }
  fail("error: linking needs the macOS SDK: install the Command Line Tools (xcode-select --install) or set SDKROOT\n")
}

/// The trimmed text between the first `open` and the next `close` after `key` in `text`.
fn value_after(text: str, key: str, open: str, close: str): str? {
  let i = text.find(key)?
  let rest = text[i + key.len()..text.len()]
  let a = rest.find(open)? + open.len()
  let tail = rest[a..rest.len()]
  let v = tail[0..tail.find(close)?].trim()
  if v == "" { none } else { some(v) }
}

/// The SDK's version (its `SDKSettings.json`). The executable records it: frameworks keep the
/// behavior of the SDK a program was built with.
fn sdk_version(sdk: str): str? uses fs {
  let json = fs.read(paths.join(sdk, "SDKSettings.json")) else return none
  value_after(json, "\"Version\"", "\"", "\"")
}

/// The oldest macOS the executable runs on: `$MACOSX_DEPLOYMENT_TARGET`, else this Mac's version
/// (its major and minor, as `cc` picks it; the code is compiled for this Mac).
fn macos_min(sdk_v: str): str uses fs, env {
  let v = env.get("MACOSX_DEPLOYMENT_TARGET") else ""
  if v != "" { return v }
  let plist = fs.read("/System/Library/CoreServices/SystemVersion.plist") else return sdk_v
  let host = value_after(plist, "<key>ProductVersion</key>", "<string>", "</string>") else sdk_v
  host.split(".").take(2).join(".")  // 27.2.1 -> 27.2, as cc
}

/// Apple's `ld`, called as `cc` calls it: the architecture, the platform's minimum and SDK
/// versions, the SDK as the root of the library search, and libSystem (which brings the C start
/// code: no crt objects on macOS).
fn macos_ld(inputs: [str], out: str): (str, [str])! uses fs, env, proc, ffi {
  let sdk = macos_sdk()?
  let sdk_v = sdk_version(sdk) else "0.0"
  let args = [
    "-arch",
    paths.arch(),
    "-platform_version",
    "macos",
    macos_min(sdk_v),
    sdk_v,
    "-syslibroot",
    sdk,
    "-o",
    out,
  ] +
    inputs +
    ["-lSystem", "-export_dynamic"]
  ("ld", args)
}

// ---- Linux: ld.lld or GNU ld, with the C library's start files -------------------------------

/// The little-endian unsigned number of `n` bytes at `at` in `b`.
fn le(b: [int], at: int, n: int): int {
  var v = 0
  var k = n - 1
  while k >= 0 {
    v = v * 256 + b[at + k]
    k -= 1
  }
  v
}

/// The ELF interpreter (`PT_INTERP`) of the 64-bit executable `p`.
fn elf_interp(p: str): str? uses fs {
  let b = fs.read_bytes(p) else return none
  if b.len() < 64 || b[0] != 127 || b[4] != 2 { return none }
  let (phoff, phsize, phnum) = (le(b, 32, 8), le(b, 54, 2), le(b, 56, 2))
  for i in 0..phnum {
    let h = phoff + i * phsize
    if h + 56 <= b.len() && le(b, h, 4) == 3 {
      let (off, n) = (le(b, h + 8, 8), le(b, h + 32, 8))
      if n < 2 || off + n > b.len() { return none }
      return match str.from_utf8(b.skip(off).take(n - 1)) {
        ok(s) => some(s)
        err(_) => none
      }
    }
  }
  none
}

/// The library directories, in the order `cc` searches them: Debian's multiarch ones, then the
/// 64-bit and plain ones (Fedora's /usr/lib64, Arch's /usr/lib).
fn linux_lib_dirs(): [str] uses fs, ffi {
  let multi = linux_multiarch()
  var out: [str] = []
  for d in ["/usr/lib/{multi}", "/lib/{multi}", "/usr/lib64", "/lib64", "/usr/lib", "/lib"] {
    if fs.is_dir(d) { out.push(d) }
  }
  out
}

/// Debian's name for this machine's library directories (`x86_64-linux-gnu`).
fn linux_multiarch(): str uses ffi = if paths.arch() == "arm64" {
  "aarch64-linux-gnu"
} else {
  "{paths.arch()}-linux-gnu"
}

/// GCC's `crtbeginS.o` and `crtendS.o` (the newest GCC's), for GNU ld: they define
/// `__dso_handle`, which glibc's `atexit` refers to (ld.lld defines it itself).
fn gcc_crt(): (str, str)? uses fs, ffi {
  let base = "/usr/lib/gcc/{linux_multiarch()}"
  let versions = fs.list(base) else return none
  var i = versions.len() - 1
  while i >= 0 {
    let d = paths.join(base, versions[i])
    if paths.is_file(paths.join(d, "crtbeginS.o")) && paths.is_file(paths.join(d, "crtendS.o")) {
      return some((paths.join(d, "crtbeginS.o"), paths.join(d, "crtendS.o")))
    }
    i -= 1
  }
  none
}

/// The dynamic linker: glibc's path from the psABI (the same on every distribution), else the
/// one `/bin/sh` names.
fn linux_interp(): str! uses fs, ffi {
  let abi = if paths.arch() == "arm64" {
    "/lib/ld-linux-aarch64.so.1"
  } else {
    "/lib64/ld-linux-x86-64.so.2"
  }
  if fs.exists(abi) { return abi }
  elf_interp("/bin/sh") else fail("error: linking: cannot find the dynamic linker ({abi})\n")
}

/// The linker: LLVM's `ld.lld` (from LLVM's bin directory, else the PATH), else GNU `ld`.
fn linux_linker(): str! uses fs, env, ffi {
  let lld = llvm_tool("ld.lld")
  if lld.contains("/") { return lld }
  match on_path("ld.lld") {
    some(p) => return p
    none => {}
  }
  match on_path("ld") {
    some(p) => p
    none =>
      fail("error: no linker: install LLVM's lld (ld.lld) or binutils (ld), or set AUK_LINKER=cc\n")
  }
}

/// `ld.lld` or GNU `ld`, called as `cc` calls it: a position-independent executable (the code is
/// PIC) with the C library's start files (`Scrt1.o`, `crti.o`, `crtn.o`: libc6-dev; GNU ld also
/// GCC's `crtbeginS.o`/`crtendS.o`), its dynamic linker and directories, the symbols exported
/// (`--export-dynamic`).
fn linux_ld(inputs: [str], out: str): (str, [str])! uses fs, env, ffi {
  let dirs = linux_lib_dirs()
  let crt = match dirs.find(d => paths.is_file(paths.join(d, "Scrt1.o"))) {
    some(d) => d
    none => return fail("error: linking needs the C library's start files (Scrt1.o): install libc6-dev (or glibc-devel)\n")
  }
  var args = [
    "--eh-frame-hdr",
    "-pie",
    "-z",
    "relro",
    "-z",
    "now",
    "--export-dynamic",
    "-dynamic-linker",
    linux_interp()?,
    "-o",
    out,
    paths.join(crt, "Scrt1.o"),
    paths.join(crt, "crti.o"),
  ]
  let linker = linux_linker()?
  let gnu = !paths.file_name(linker).starts_with("ld.lld")
  let (begin, end) = if gnu {
    match gcc_crt() {
      some((b, e)) => ([b], [e])
      none => return fail("error: linking with GNU ld needs GCC's crtbeginS.o (libgcc's development files); or install LLVM's lld (ld.lld)\n")
    }
  } else {
    ([], [])
  }
  args = args + begin
  for d in dirs { args.push("-L{d}") }
  args = args + inputs + ["-lm", "-lc"] + end + [paths.join(crt, "crtn.o")]
  (linker, args)
}

/// The linker and its arguments for the objects and libraries `inputs`: the system linker
/// (above), or the C compiler driver `$AUK_LINKER` names (`cc`, `clang`), with a driver's flags.
fn link_command(inputs: [str], out: str, macos: bool): (str, [str])! uses fs, env, proc, ffi {
  let driver = env.get("AUK_LINKER") else ""
  if driver != "" {
    let export = if macos { "-Wl,-export_dynamic" } else { "-rdynamic" }
    return (driver, inputs + ["-lm", "-lpthread", export, "-o", out])
  }
  if macos { macos_ld(inputs, out) } else { linux_ld(inputs, out) }
}

/// Compile `prog` (the MIR of a release build: `auk dump mir --release [-g]`) and link it into
/// the executable `out`.
pub fn build(prog: mir.Program, info: mir.types.TyInfo, out: str): ()! uses fs, env, proc, ffi {
  let obj = match backend.object(prog, info, true) {
    ok(o) => o
    err(e) => return fail("error: code generation failed (this is an auk compiler bug): {e}\n")
  }
  let macos = paths.os() == "macos"
  let dir = fs.temp_dir()?
  let o = paths.join(dir, "prog.o")
  let lib = paths.join(dir, "libauk_rt.a")
  let res = link(prog, obj, o, lib, out, macos)
  let _ = fs.remove(o)
  let _ = fs.remove(lib)
  let _ = fs.remove(dir)
  res
}

fn link(
  prog: mir.Program,
  obj: [int],
  o: str,
  lib: str,
  out: str,
  macos: bool,
): ()! uses fs, env, proc, ffi {
  match fs.write_bytes(o, obj) {
    ok(_) => {}
    err(e) => return fail("error: cannot write {o}: {e}\n")
  }
  write_mem(lib, runtime_lib(), runtime_lib_len())?
  let inputs = [o, lib] + user_libs(prog.links, macos)? + link_libs(macos)
  let (linker, args) = link_command(inputs, out, macos)?
  match proc.run(linker, args) {
    ok(_) => {}
    err(e) => return fail("error: linking failed: {e}\n")
  }
  // the macOS linker leaves DWARF in the object file (deleted after): gather it first
  if prog.locs.len() > 0 && macos {
    match proc.run(llvm_tool("dsymutil"), [out]) {
      ok(_) => {}
      err(e) => return fail("error: dsymutil failed: {e}\n")
    }
  }
}

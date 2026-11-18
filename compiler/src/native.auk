/// `auk build`'s back half (src/build.rs `build_native`): the program compiled to an object file
/// (O2, with the runtime's inlinable functions) and linked with the runtime library
/// (`libauk_rt.a`, embedded in the compiler: build.rs copies it to `target/auk-rt/`) by the
/// system linker driver (`cc`; `AUK_LINKER` overrides it). With debug info (`-g`, the MIR
/// carries source locations) on macOS, `dsymutil` gathers the DWARF into `<out>.dSYM`.

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

/// Libraries the runtime needs besides libc and libm: the system TLS (tls.c), and dlopen.
fn link_libs(macos: bool): [str] = if macos {
  ["-framework", "CoreFoundation", "-framework", "Security", "-framework", "Network"]
} else {
  ["-ldl", "-lpthread"]
}

/// Export the executable's symbols (the runtime's `auk_*` among them) to `dlsym`, so
/// `ffi.symbol("auk_str_len")` finds them.
fn export_dynamic(macos: bool): str = if macos { "-Wl,-export_dynamic" } else { "-rdynamic" }

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
  let linker = env.get("AUK_LINKER") else "cc"
  let args = [o, lib] + user_libs(prog.links, macos)? + link_libs(macos) + [
    "-lm",
    "-lpthread",
    export_dynamic(macos),
    "-o",
    out,
  ]
  match proc.run(linker, args) {
    ok(_) => {}
    err(e) => return fail("error: linking failed: {e}\n")
  }
  // the macOS linker leaves DWARF in the object file (deleted after): gather it first
  if prog.locs.len() > 0 && macos {
    match proc.run("dsymutil", [out]) {
      ok(_) => {}
      err(e) => return fail("error: dsymutil failed: {e}\n")
    }
  }
}

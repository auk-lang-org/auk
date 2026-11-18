//! Builds the runtime (`runtime/c`, C) three ways, with the clang of the LLVM the back end links
//! (`LLVM_SYS_231_PREFIX`, see .cargo/config.toml):
//! - `OUT_DIR/libauk_rt.a`, linked into the compiler (the JIT resolves generated code's runtime
//!   calls in this process) and embedded in it (`include_bytes!`) to link into every program
//!   `auk build` makes;
//! - `OUT_DIR/auk_rt.bc`, its LLVM bitcode, which `auk build` links into a program so small
//!   runtime functions can inline;
//! - `OUT_DIR/rt_symbols.rs`, the table of its entry points (the `AUK_API` lines of auk_rt.h)
//!   and their addresses, for the JIT.
//!
//! The C compiles as one translation unit (a file that includes every source), so calls between
//! the runtime's files inline. Files marked `auk: own translation unit` (they include system
//! framework headers, whose names would clash with the runtime's) are compiled on their own.
//!
//! `AUK_RT_SANITIZE=address` builds the library with AddressSanitizer and UBSan and links the
//! sanitizer runtime into the compiler, so JIT-run programs (`auk run`, `auk test`) use the
//! instrumented runtime; `auk build` programs link it too when the linker adds the sanitizer
//! runtime (`AUK_LINKER=runtime/c/test/asan-cc.sh`). The bitcode stays uninstrumented (copies
//! of small functions inlined into `auk build` programs are not checked; `AUK_NO_RT_INLINE=1`
//! keeps every call in the library). See docs/compiler.md, Testing.

use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let apple = env::var("CARGO_CFG_TARGET_VENDOR").as_deref() == Ok("apple");
    println!("cargo:rerun-if-changed=runtime/c");
    println!("cargo:rerun-if-env-changed=LLVM_SYS_231_PREFIX");
    println!("cargo:rerun-if-env-changed=AUK_RT_SANITIZE");
    let prefix = PathBuf::from(env::var("LLVM_SYS_231_PREFIX").expect("LLVM_SYS_231_PREFIX (see .cargo/config.toml)"));
    let cdir = manifest.join("runtime/c");
    let units = units(&cdir, &out);
    // blocks on Apple: Network.framework's callbacks (tls.c); glibc hides POSIX/BSD declarations
    // (unsetenv, ...) under plain -std=c11 unless asked for them
    let platform_flags: &[&str] = if apple { &["-fblocks"] } else { &["-D_GNU_SOURCE"] };

    // the static library (cc also links it into this crate's binaries)
    let mut b = cc::Build::new();
    b.compiler(prefix.join("bin/clang"))
        .files(&units)
        .include(&cdir)
        .std("c11")
        .opt_level(2)
        .flag("-fno-strict-aliasing")
        .flag("-fno-stack-protector")
        .flag("-Wall")
        .flag("-Wextra")
        .flag("-Wno-unused-parameter");
    for f in platform_flags {
        b.flag(f);
    }
    if apple {
        for fw in ["Network", "Security", "CoreFoundation"] {
            println!("cargo:rustc-link-lib=framework={fw}");
        }
    }
    match env::var("AUK_RT_SANITIZE").as_deref() {
        Err(_) | Ok("") => {}
        Ok("address") => {
            b.flag("-fsanitize=address,undefined").flag("-fno-omit-frame-pointer");
            sanitizer_runtime(&prefix, apple);
        }
        Ok(other) => panic!("AUK_RT_SANITIZE={other}: only `address` (AddressSanitizer + UBSan) is supported"),
    }
    b.compile("auk_rt");

    // the bitcode
    let mut bcs = Vec::new();
    for (i, u) in units.iter().enumerate() {
        let o = out.join(format!("rt_{i}.bc"));
        let status = Command::new(prefix.join("bin/clang"))
            .args(["-c", "-emit-llvm", "-O2", "-std=c11", "-fno-strict-aliasing", "-fno-stack-protector"])
            .args(platform_flags)
            .arg("-I")
            .arg(&cdir)
            .arg(u)
            .arg("-o")
            .arg(&o)
            .status()
            .expect("could not run clang");
        assert!(status.success(), "compiling the runtime to bitcode failed: {}", u.display());
        bcs.push(o);
    }
    let status = Command::new(prefix.join("bin/llvm-link")).args(&bcs).arg("-o").arg(out.join("auk_rt.bc")).status().expect("could not run llvm-link");
    assert!(status.success(), "llvm-link of the runtime bitcode failed");

    symbols(&cdir.join("auk_rt.h"), &out.join("rt_symbols.rs"));
}

/// Link the AddressSanitizer runtime (with UBSan's handlers) of the clang that compiled the
/// library into the compiler's binaries: on macOS its dylib, found through an rpath; elsewhere
/// through the C compiler driver that links.
fn sanitizer_runtime(prefix: &Path, apple: bool) {
    if !apple {
        println!("cargo:rustc-link-arg=-fsanitize=address,undefined");
        return;
    }
    let out = Command::new(prefix.join("bin/clang")).arg("--print-runtime-dir").output().expect("could not run clang");
    let dir = String::from_utf8(out.stdout).unwrap().trim().to_string();
    assert!(Path::new(&dir).join("libclang_rt.asan_osx_dynamic.dylib").exists(), "no AddressSanitizer runtime in {dir}");
    println!("cargo:rustc-link-search=native={dir}");
    println!("cargo:rustc-link-lib=dylib=clang_rt.asan_osx_dynamic");
    println!("cargo:rustc-link-arg=-Wl,-rpath,{dir}");
}

/// The translation units: the files marked to stand alone, then one that includes the rest.
fn units(cdir: &Path, out: &Path) -> Vec<PathBuf> {
    let mut files: Vec<PathBuf> = std::fs::read_dir(cdir).unwrap().map(|e| e.unwrap().path()).filter(|p| p.extension().is_some_and(|e| e == "c")).collect();
    files.sort();
    let mut unity = String::new();
    let mut units = Vec::new();
    for f in &files {
        if std::fs::read_to_string(f).unwrap().contains("auk: own translation unit") {
            units.push(f.clone());
        } else {
            unity += &format!("#include \"{}\"\n", f.display());
        }
    }
    let all = out.join("auk_rt_all.c");
    std::fs::write(&all, unity).unwrap();
    units.push(all);
    units
}

/// Write the table of the runtime's entry points (the `AUK_API` lines of auk_rt.h: functions,
/// and `extern` data) with their addresses in the runtime linked into the compiler: the JIT
/// resolves generated code's runtime calls with it.
fn symbols(header: &Path, out: &Path) {
    let mut decls = String::new();
    let mut body = String::new();
    for line in std::fs::read_to_string(header).unwrap().lines() {
        let Some(rest) = line.trim().strip_prefix("AUK_API ") else { continue };
        let name_end = rest.find(['(', ';']).unwrap_or(rest.len());
        let name = rest[..name_end].rsplit(|c: char| c.is_whitespace() || c == '*').next().unwrap();
        if rest.starts_with("extern ") {
            decls += &format!("    static {name}: u8;\n");
            body += &format!("        (\"{name}\", (&raw const {name}).cast::<u8>()),\n");
        } else {
            decls += &format!("    fn {name}();\n");
            body += &format!("        (\"{name}\", {name} as *const u8),\n");
        }
    }
    let code = format!(
        "unsafe extern \"C\" {{\n{decls}}}\n\n/// The runtime's exported symbols and their addresses.\npub fn rt_symbols() -> Vec<(&'static str, *const u8)> {{\n    vec![\n{body}    ]\n}}\n"
    );
    std::fs::write(out, code).unwrap();
}

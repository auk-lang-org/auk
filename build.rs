//! Builds the runtime (`runtime/`, the `auk_rt` crate) as a static library and puts it in
//! `OUT_DIR/libauk_rt.a`, which the compiler embeds (`include_bytes!`) and links into every
//! program it builds, plus the runtime's own LLVM bitcode (`OUT_DIR/auk_rt.bc`, one codegen
//! unit), which `auk build` links into the program so small runtime functions can inline. A nested `cargo build` with its own target directory (so it never waits
//! on the outer build's lock) and the `rt` profile (release, `panic = "abort"`).

use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let target = env::var("TARGET").unwrap();
    println!("cargo:rerun-if-changed=runtime/src");
    println!("cargo:rerun-if-changed=runtime/c");
    println!("cargo:rerun-if-changed=runtime/Cargo.toml");
    println!("cargo:rerun-if-changed=Cargo.lock");

    let cargo = env::var("CARGO").unwrap_or_else(|_| "cargo".into());
    let tdir = out.join("rt-target");
    let mut cmd = Command::new(cargo);
    cmd.current_dir(&manifest)
        .args(["rustc", "-p", "auk_rt", "--lib", "--crate-type", "staticlib", "--profile", "rt", "--target", &target])
        .arg("--target-dir")
        .arg(&tdir)
        .args(["--", "--emit=link,llvm-bc", "-C", "codegen-units=1"]);
    // Don't leak the outer build's settings (e.g. RUSTFLAGS for coverage) into the runtime.
    for (k, _) in env::vars() {
        if k.starts_with("CARGO_") && k != "CARGO_HOME" || k == "RUSTFLAGS" || k == "RUSTC_WRAPPER" {
            cmd.env_remove(&k);
        }
    }
    if env::var_os("CARGO_ENCODED_RUSTFLAGS").is_some() {
        cmd.env_remove("CARGO_ENCODED_RUSTFLAGS");
    }
    let status = cmd.status().expect("could not run cargo to build the runtime");
    assert!(status.success(), "building the runtime (auk_rt) failed");
    let lib = tdir.join(&target).join("rt").join("libauk_rt.a");
    std::fs::copy(&lib, out.join("libauk_rt.a")).unwrap_or_else(|e| panic!("copying {}: {e}", lib.display()));
    // the bitcode is `deps/auk_rt-<hash>.bc`: the newest one
    let deps = tdir.join(&target).join("rt").join("deps");
    let bc = std::fs::read_dir(&deps)
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|e| e == "bc") && p.file_name().unwrap().to_string_lossy().starts_with("auk_rt-"))
        .max_by_key(|p| p.metadata().and_then(|m| m.modified()).unwrap())
        .unwrap_or_else(|| panic!("no auk_rt bitcode in {}", deps.display()));
    c_bitcode(&manifest.join("runtime/c"), &bc, &out);
    symbols(&manifest.join("runtime/src"), &manifest.join("runtime/c/auk_rt.h"), &out.join("rt_symbols.rs"));
}

/// Write the table of the runtime's exported symbols (`#[unsafe(no_mangle)]` functions and
/// statics) with their addresses in the `auk_rt` library linked into the compiler: the JIT
/// resolves generated code's runtime calls with it.
fn symbols(src: &std::path::Path, header: &std::path::Path, out: &std::path::Path) {
    let mut files: Vec<_> = std::fs::read_dir(src).unwrap().map(|e| e.unwrap().path()).filter(|p| p.extension().is_some_and(|e| e == "rs")).collect();
    files.sort();
    let mut body = String::new();
    for f in files {
        let module = f.file_stem().unwrap().to_string_lossy().into_owned();
        let text = std::fs::read_to_string(&f).unwrap();
        let mut pending = false;
        for line in text.lines() {
            let t = line.trim();
            if t.starts_with("#[unsafe(no_mangle)]") {
                pending = true;
                continue;
            }
            if !pending || t.starts_with("#[") || t.starts_with("//") {
                continue;
            }
            pending = false;
            let words: Vec<&str> = t.split(|c: char| c.is_whitespace() || c == '(' || c == ':' || c == '<').filter(|w| !w.is_empty()).collect();
            if let Some(i) = words.iter().position(|w| *w == "fn") {
                let name = words[i + 1];
                body += &format!("        (\"{name}\", auk_rt::{module}::{name} as *const u8),\n");
            } else if let Some(i) = words.iter().position(|w| *w == "static") {
                let name = if words[i + 1] == "mut" { words[i + 2] } else { words[i + 1] };
                body += &format!("        (\"{name}\", (&raw const auk_rt::{module}::{name}).cast::<u8>()),\n");
            }
        }
    }
    // the C runtime's entry points: `AUK_API` lines in auk_rt.h
    let mut decls = String::new();
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

/// Compile the C runtime to bitcode with the back end's clang and link it with the Rust part's
/// (`rust_bc`) into `OUT_DIR/auk_rt.bc`.
fn c_bitcode(cdir: &std::path::Path, rust_bc: &std::path::Path, out: &std::path::Path) {
    println!("cargo:rerun-if-env-changed=LLVM_SYS_231_PREFIX");
    let prefix = PathBuf::from(env::var("LLVM_SYS_231_PREFIX").expect("LLVM_SYS_231_PREFIX (see .cargo/config.toml)"));
    let mut files: Vec<PathBuf> =
        std::fs::read_dir(cdir).unwrap().map(|e| e.unwrap().path()).filter(|p| p.extension().is_some_and(|e| e == "c")).collect();
    files.sort();
    // one translation unit, as runtime/build.rs compiles it
    let mut unity = String::new();
    for f in &files {
        unity += &format!("#include \"{}\"\n", f.display());
    }
    let all = out.join("c_all.c");
    std::fs::write(&all, unity).unwrap();
    let o = out.join("c_all.bc");
    let status = Command::new(prefix.join("bin/clang"))
        .args(["-c", "-emit-llvm", "-O2", "-std=c11", "-fno-strict-aliasing", "-I"])
        .arg(cdir)
        .arg(&all)
        .arg("-o")
        .arg(&o)
        .status()
        .expect("could not run clang");
    assert!(status.success(), "compiling the C runtime to bitcode failed");
    let bcs = [rust_bc.to_path_buf(), o];
    let status = Command::new(prefix.join("bin/llvm-link")).args(&bcs).arg("-o").arg(out.join("auk_rt.bc")).status().expect("could not run llvm-link");
    assert!(status.success(), "llvm-link of the runtime bitcode failed");
}

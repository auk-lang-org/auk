//! Builds the runtime (`runtime/`, the `duck_rt` crate) as a static library and puts it in
//! `OUT_DIR/libduck_rt.a`, which the compiler embeds (`include_bytes!`) and links into every
//! program it builds. A nested `cargo build` with its own target directory (so it never waits
//! on the outer build's lock) and the `rt` profile (release, `panic = "abort"`).

use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let target = env::var("TARGET").unwrap();
    println!("cargo:rerun-if-changed=runtime/src");
    println!("cargo:rerun-if-changed=runtime/Cargo.toml");
    println!("cargo:rerun-if-changed=Cargo.lock");

    let cargo = env::var("CARGO").unwrap_or_else(|_| "cargo".into());
    let tdir = out.join("rt-target");
    let mut cmd = Command::new(cargo);
    cmd.current_dir(&manifest)
        .args(["build", "-p", "duck_rt", "--lib", "--profile", "rt", "--target", &target])
        .arg("--target-dir")
        .arg(&tdir);
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
    assert!(status.success(), "building the runtime (duck_rt) failed");
    let lib = tdir.join(&target).join("rt").join("libduck_rt.a");
    std::fs::copy(&lib, out.join("libduck_rt.a")).unwrap_or_else(|e| panic!("copying {}: {e}", lib.display()));
    symbols(&manifest.join("runtime/src"), &out.join("rt_symbols.rs"));
}

/// Write the table of the runtime's exported symbols (`#[unsafe(no_mangle)]` functions and
/// statics) with their addresses in the `duck_rt` library linked into the compiler: the JIT
/// resolves generated code's runtime calls with it.
fn symbols(src: &std::path::Path, out: &std::path::Path) {
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
                body += &format!("        (\"{name}\", duck_rt::{module}::{name} as *const u8),\n");
            } else if let Some(i) = words.iter().position(|w| *w == "static") {
                let name = if words[i + 1] == "mut" { words[i + 2] } else { words[i + 1] };
                body += &format!("        (\"{name}\", (&raw const duck_rt::{module}::{name}).cast::<u8>()),\n");
            }
        }
    }
    let code = format!("/// The runtime's exported symbols and their addresses.\npub fn rt_symbols() -> Vec<(&'static str, *const u8)> {{\n    vec![\n{body}    ]\n}}\n");
    std::fs::write(out, code).unwrap();
}

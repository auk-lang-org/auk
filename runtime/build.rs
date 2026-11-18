//! Compiles the runtime's C sources (`c/*.c`) into a static library bundled with this crate.
//! The compiler is the clang of the LLVM the back end links (`LLVM_SYS_231_PREFIX`), so the
//! runtime bitcode the root build.rs makes from the same sources is readable by that LLVM.
use std::path::PathBuf;

fn main() {
    println!("cargo:rerun-if-changed=c");
    println!("cargo:rerun-if-env-changed=LLVM_SYS_231_PREFIX");
    let mut files: Vec<PathBuf> = std::fs::read_dir("c")
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|e| e == "c"))
        .collect();
    files.sort();
    // One translation unit (a file that includes every source): calls between the runtime's
    // files inline, as they did when the runtime was one Rust crate.
    let out = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    let dir = std::fs::canonicalize("c").unwrap();
    // Files marked `auk: own translation unit` (they include system framework headers, whose
    // names would clash with the runtime's) are compiled on their own.
    let mut unity = String::new();
    let mut own = Vec::new();
    for f in &files {
        let path = dir.join(f.file_name().unwrap());
        if std::fs::read_to_string(&path).unwrap().contains("auk: own translation unit") {
            own.push(path);
        } else {
            unity += &format!("#include \"{}\"\n", path.display());
        }
    }
    let all = out.join("auk_rt_all.c");
    std::fs::write(&all, unity).unwrap();
    let mut b = cc::Build::new();
    if let Ok(prefix) = std::env::var("LLVM_SYS_231_PREFIX") {
        b.compiler(PathBuf::from(prefix).join("bin/clang"));
    }
    b.file(&all).files(&own)
        .include("c")
        .std("c11")
        .opt_level(2)
        .flag("-fno-strict-aliasing")
        .flag("-fno-stack-protector")
        .flag("-Wall")
        .flag("-Wextra")
        .flag("-Wno-unused-parameter");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        // blocks: Network.framework's callbacks (tls.c)
        b.flag("-fblocks");
        for fw in ["Network", "Security", "CoreFoundation"] {
            println!("cargo:rustc-link-lib=framework={fw}");
        }
    }
    b.compile("auk_rt_c");
}

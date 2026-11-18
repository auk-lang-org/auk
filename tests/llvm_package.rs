//! The `llvm` binding package (packages/llvm, docs/self-host-plan.md 2c): its tests pass under the
//! leak checker (a module built in Auk, verified, printed, emitted, run in ORC LLJIT and called,
//! plus a piece of codegen.rs ported), and its example runs in the JIT and as an executable, which
//! itself links an object file with `cc`.

use std::path::Path;
use std::process::Command;

#[test]
fn llvm_package_tests_pass_without_leaks() {
    let o = Command::new(env!("CARGO_BIN_EXE_auk")).args(["test", "packages/llvm/src/lib.auk"]).env("AUK_LEAK_CHECK", "1").output().unwrap();
    let out = String::from_utf8_lossy(&o.stdout);
    assert!(o.status.success() && out.ends_with(" passed, 0 failed\n"), "{out}\n{}", String::from_utf8_lossy(&o.stderr));
    assert!(!out.contains("FAIL") && !out.contains("leak:"), "{out}");
    assert!(out.contains("ok JIT add with ORC LLJIT and call it"), "{out}");
}

const EXPECTED: &str = "JIT: add(40, 2) = 42\nbuilt: add(40, 2) = 42\n";

#[test]
fn llvm_example_runs_and_builds() {
    let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("packages/llvm/example");
    // a copy, so the run's files (out/, .raft/) stay out of the source tree
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join("llvm-example");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("src")).unwrap();
    let toml = std::fs::read_to_string(src.join("raft.toml")).unwrap();
    let pkg = src.parent().unwrap().display().to_string();
    std::fs::write(dir.join("raft.toml"), toml.replace("path = \"..\"", &format!("path = \"{pkg}\""))).unwrap();
    std::fs::copy(src.join("src/main.auk"), dir.join("src/main.auk")).unwrap();
    let o = Command::new(env!("CARGO_BIN_EXE_raft")).arg("install").current_dir(&dir).output().unwrap();
    assert!(o.status.success(), "raft install: {}", String::from_utf8_lossy(&o.stderr));

    let o = Command::new(env!("CARGO_BIN_EXE_auk")).args(["run", "src/main.auk"]).current_dir(&dir).output().unwrap();
    let out = String::from_utf8_lossy(&o.stdout);
    assert!(o.status.success(), "{out}\n{}", String::from_utf8_lossy(&o.stderr));
    assert!(out.contains("define i64 @add(i64 %0, i64 %1) {\nentry:\n  %sum = add i64 %0, %1\n  ret i64 %sum\n}"), "{out}");
    assert!(out.ends_with(EXPECTED), "{out}");
    let bc = std::fs::read(dir.join("out/add.bc")).unwrap();
    // raw bitcode, or (for a Darwin triple) the bitcode wrapper around it
    assert!(&bc[..4] == b"BC\xc0\xde" || &bc[..4] == b"\xde\xc0\x17\x0b", "{:x?}", &bc[..4]);

    let o = Command::new(env!("CARGO_BIN_EXE_auk")).args(["build", "src/main.auk", "-o", "out/example"]).current_dir(&dir).output().unwrap();
    assert!(o.status.success(), "auk build: {}", String::from_utf8_lossy(&o.stderr));
    let o = Command::new(dir.join("out/example")).current_dir(&dir).output().unwrap();
    let out = String::from_utf8_lossy(&o.stdout);
    assert!(o.status.success() && out.ends_with(EXPECTED), "{out}");
}

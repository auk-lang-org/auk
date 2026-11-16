//! Builds the C runtime (`runtime/*.c`) together with its C unit tests
//! (`runtime/test/*.c`) using clang and runs them: once optimized
//! (`-O2 -Wall -Wextra -Werror`), and once with AddressSanitizer +
//! UndefinedBehaviorSanitizer when the toolchain supports them.
//! `CLANG` overrides the compiler.
//!
//! The TLS tests in runtime/test/test_net.c reach real hosts only when the C binary sees
//! `DUCK_NET_TESTS=1`. Set it yourself to require them, `DUCK_NET_TESTS=0` to skip them; when
//! it is unset they run if example.com:443 answers within a few seconds (as in tests/net.rs).

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

fn clang() -> String {
    env::var("CLANG").unwrap_or_else(|_| "clang".to_string())
}

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn out_dir() -> PathBuf {
    let d = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("duck-runtime");
    fs::create_dir_all(&d).unwrap();
    d
}

fn c_files(dir: &Path) -> Vec<PathBuf> {
    let mut v: Vec<_> = fs::read_dir(dir)
        .unwrap_or_else(|e| panic!("reading {}: {e}", dir.display()))
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|e| e == "c"))
        .collect();
    v.sort();
    v
}

const BASE_FLAGS: &[&str] = &["-std=c11", "-pthread", "-Wall", "-Wextra", "-Werror"];

/// As `build::LINK_LIBS` (runtime/tls.c's platform TLS stack).
const LINK_LIBS: &[&str] = if cfg!(target_os = "macos") {
    &["-framework", "Network", "-framework", "Security", "-framework", "CoreFoundation"]
} else {
    &["-ldl"]
};

/// Compiles the runtime plus its tests into `exe` with extra `flags`.
fn build(exe: &Path, flags: &[&str]) {
    let rt = root().join("runtime");
    let mut cmd = Command::new(clang());
    cmd.args(BASE_FLAGS).args(flags).arg("-I").arg(&rt);
    cmd.args(c_files(&rt)).args(c_files(&rt.join("test")));
    cmd.args(LINK_LIBS).arg("-lm").arg("-o").arg(exe);
    let out = cmd.output().unwrap_or_else(|e| panic!("could not run {}: {e}", clang()));
    assert!(
        out.status.success(),
        "compiling the runtime failed ({:?}):\n{}{}",
        flags,
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
}

/// Should tests reach real hosts? `DUCK_NET_TESTS=1`/`0` decides; unset, probe example.com:443.
fn net_tests() -> bool {
    use std::net::{TcpStream, ToSocketAddrs};
    use std::time::Duration;
    match env::var("DUCK_NET_TESTS").as_deref() {
        Ok("1") => true,
        Ok(_) => false,
        Err(_) => ("example.com", 443)
            .to_socket_addrs()
            .is_ok_and(|mut a| a.any(|a| TcpStream::connect_timeout(&a, Duration::from_secs(3)).is_ok())),
    }
}

/// Runs the test binary and asserts that every test passed.
fn run(exe: &Path, label: &str) {
    let out = Command::new(exe)
        .env("DUCK_NET_TESTS", if net_tests() { "1" } else { "0" })
        .env("ASAN_OPTIONS", "detect_odr_violation=0:abort_on_error=0")
        .env("UBSAN_OPTIONS", "print_stacktrace=1:halt_on_error=1")
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(out.status.success(), "runtime tests failed [{label}]:\n{stdout}\n{stderr}");
    let summary = stdout.lines().last().unwrap_or("");
    assert!(summary.ends_with(" 0 failed"), "[{label}] unexpected summary: {summary:?}\n{stdout}");
    assert!(!stdout.contains("\nFAIL "), "[{label}]\n{stdout}");
    let passed: usize = summary.split(' ').next().unwrap().parse().unwrap();
    assert!(passed >= 40, "[{label}] only {passed} tests ran:\n{stdout}");
}

/// Does this toolchain build and run a program with the given sanitizers?
fn sanitizers_work(flags: &[&str]) -> bool {
    let dir = out_dir();
    let src = dir.join("probe.c");
    fs::write(&src, "#include <stdlib.h>\nint main(void) { char *p = malloc(4); p[0] = 1; int r = p[0] - 1; free(p); return r; }\n")
        .unwrap();
    let exe = dir.join("probe");
    let ok = Command::new(clang())
        .args(flags)
        .arg(&src)
        .arg("-o")
        .arg(&exe)
        .output()
        .is_ok_and(|o| o.status.success());
    ok && Command::new(&exe).output().is_ok_and(|o| o.status.success())
}

#[test]
fn runtime_header_is_clean() {
    // duck.h must compile on its own, even under -Wpedantic, as generated code includes it.
    let dir = out_dir();
    let src = dir.join("header_only.c");
    fs::write(&src, "#include \"duck.h\"\nint main(void) { return (int)duck_add(1, -1, \"x\"); }\n").unwrap();
    let out = Command::new(clang())
        .args(BASE_FLAGS)
        .args(["-Wpedantic", "-fsyntax-only", "-I"])
        .arg(root().join("runtime"))
        .arg(&src)
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
}

#[test]
fn runtime_unit_tests_optimized() {
    let exe = out_dir().join("rt_test_o2");
    build(&exe, &["-O2"]);
    run(&exe, "-O2");
}

#[test]
fn runtime_unit_tests_sanitized() {
    let san = ["-fsanitize=address,undefined"];
    if !sanitizers_work(&san) {
        eprintln!("note: {} lacks working ASan/UBSan here; skipping the sanitized run", clang());
        return;
    }
    let exe = out_dir().join("rt_test_asan");
    build(
        &exe,
        &["-O1", "-g", "-fno-omit-frame-pointer", "-fsanitize=address,undefined", "-fno-sanitize-recover=undefined"],
    );
    run(&exe, "asan+ubsan");
}

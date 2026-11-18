/// tests/llvm_package.rs: the `llvm` binding package (packages/llvm, docs/self-host-plan.md 2c):
/// its tests pass under the leak checker (a module built in Auk, verified, printed, emitted, run
/// in ORC LLJIT and called, plus a piece of codegen.rs ported), and its example runs in the JIT
/// and as an executable, which itself links an object file with `cc`.

pub fn tests(): [t.Test] uses env, fs, ffi, time = [
  t.test("llvm_package_tests_pass_without_leaks", llvm_package_tests_pass_without_leaks),
  t.test("llvm_example_runs_and_builds", llvm_example_runs_and_builds),
]

fn llvm_package_tests_pass_without_leaks() uses env, ffi, time {
  let o = t.auk().args(["test", "packages/llvm/src/lib.auk"]).setenv("AUK_LEAK_CHECK", "1").output()
  let out = o.stdout
  t.check(o.success() && out.ends_with(" passed, 0 failed\n"), "{out}\n{o.stderr}")
  t.check(!out.contains("FAIL") && !out.contains("leak:"), out)
  t.check(out.contains("ok JIT add with ORC LLJIT and call it"), out)
}

let EXPECTED = "JIT: add(40, 2) = 42\nbuilt: add(40, 2) = 42\n"

fn llvm_example_runs_and_builds() uses env, fs, ffi, time {
  let src = t.abs("packages/llvm/example")
  // a copy, so the run's files (out/, .raft/) stay out of the source tree
  let dir = t.scratch("llvm-example")
  let toml = t.read(paths.join(src, "raft.toml"))
  let pkg = paths.parent(src) else ""
  t.write(paths.join(dir, "raft.toml"), toml.replace("path = \"..\"", "path = \"{pkg}\""))
  t.write(paths.join(dir, "src/main.auk"), t.read(paths.join(src, "src/main.auk")))
  let o = t.raft().arg("install").cwd(dir).output()
  t.check(o.success(), "raft install: {o.stderr}")

  let o = t.auk().args(["run", "src/main.auk"]).cwd(dir).output()
  let out = o.stdout
  t.check(o.success(), "{out}\n{o.stderr}")
  t.check(
    out.contains("define i64 @add(i64 %0, i64 %1) {{\nentry:\n  %sum = add i64 %0, %1\n  ret i64 %sum\n}}"),
    out,
  )
  t.check(out.ends_with(EXPECTED), out)
  let bc = t.must(fs.read_bytes(paths.join(dir, "out/add.bc")), "read add.bc")
  // raw bitcode, or (for a Darwin triple) the bitcode wrapper around it
  let head = bc.take(4)
  t.check(head == [0x42, 0x43, 0xc0, 0xde] || head == [0xde, 0xc0, 0x17, 0x0b], "{head}")

  let o = t.auk().args(["build", "src/main.auk", "-o", "out/example"]).cwd(dir).output()
  t.check(o.success(), "auk build: {o.stderr}")
  let o = cmd.new(paths.join(dir, "out/example")).cwd(dir).output()
  t.check(o.success() && o.stdout.ends_with(EXPECTED), o.stdout)
}

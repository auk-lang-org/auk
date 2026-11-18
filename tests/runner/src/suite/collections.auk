/// tests/collections.rs: the core collection extras written in Auk (compiler/prelude/core.auk):
/// `chunks`, `windows`, `flat_map`, `group_by` and `unique`, tested by
/// tests/fixtures/collections.auk under the leak checker, plus the `requires n > 0` panics.

pub fn tests(): [t.Test] uses env, fs, ffi, time = [
  t.test("collection_extras_pass_their_tests", collection_extras_pass_their_tests),
  t.test("chunks_and_windows_need_a_positive_size", chunks_and_windows_need_a_positive_size),
]

fn auk_cmd(): cmd.Cmd uses env, ffi = t.auk().setenv("AUK_LEAK_CHECK", "1")

fn collection_extras_pass_their_tests() uses env, ffi, time {
  let o = auk_cmd().args(["test", "tests/fixtures/collections.auk"]).output()
  t.check(o.success(), "{o.stdout}\n{o.stderr}")
  t.eq(
    o.stdout,
    "ok chunks\nok windows\nok flat_map\nok group_by\nok unique\n5 passed, 0 failed\n",
    o.stderr,
  )
}

fn chunks_and_windows_need_a_positive_size() uses env, fs, ffi, time {
  let d = paths.join(t.tmp_base(), "collections")
  let _ = fs.mkdir(d)
  for f in ["chunks", "windows"] {
    let p = paths.join(d, "{f}.auk")
    t.write(p, "fn main() {{\n  print([1, 2].{f}(0))\n}}\n")
    let o = auk_cmd().arg("run").arg(p).output()
    t.check(o.code == some(101), o.stderr)
    t.check(o.stderr.starts_with("panic: requires failed: n > 0\n"), o.stderr)
  }
}

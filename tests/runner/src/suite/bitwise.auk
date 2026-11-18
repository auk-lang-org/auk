/// tests/bitwise.rs: bitwise operators on `int` (`& | ^ ~ << >>` and their `&=`-style
/// assignments): truth tables, precedence and compound assignment in tests/fixtures/bitwise.auk,
/// SHA-256 written in Auk in tests/fixtures/sha256.auk (both under the leak checker),
/// shift-range panics, and the checker's and parser's diagnostics with their fix-its.

pub fn tests(): [t.Test] uses env, ffi, time, fs = [
  t.test("operators_pass_their_tests", operators_pass_their_tests),
  t.test("sha256_in_auk_matches_the_known_digests", sha256_in_auk_matches_the_known_digests),
  t.test("fixtures_are_fmt_clean", fixtures_are_fmt_clean),
  t.test("shift_amounts_outside_0_to_63_panic", shift_amounts_outside_0_to_63_panic),
  t.test("units_are_rejected_with_an_int_fix", units_are_rejected_with_an_int_fix),
  t.test("non_int_operands_are_rejected", non_int_operands_are_rejected),
  t.test("bitwise_next_to_a_comparison_needs_parentheses", bitwise_next_to_a_comparison_needs_parentheses),
]

fn auk_cmd(): cmd.Cmd uses env, ffi = t.auk().setenv("AUK_LEAK_CHECK", "1")

fn scratch(name: str, src: str): str uses env, fs, ffi {
  let d = paths.join(t.tmp_base(), "bitwise")
  let _ = fs.mkdir(d)
  let p = paths.join(d, "{name}.auk")
  t.write(p, src)
  p
}

fn operators_pass_their_tests() uses env, ffi, time {
  let o = auk_cmd().args(["test", "tests/fixtures/bitwise.auk"]).output()
  t.check(o.success(), "{o.stdout}\n{o.stderr}")
  t.eq(o.stdout, "ok and or xor truth tables\nok not\nok shifts\nok precedence\nok compound assignment\nok bytes\n6 passed, 0 failed\n", o.stderr)
}

fn sha256_in_auk_matches_the_known_digests() uses env, ffi, time {
  let o = auk_cmd().args(["test", "tests/fixtures/sha256.auk"]).output()
  t.check(o.success(), "{o.stdout}\n{o.stderr}")
  t.eq(o.stdout, "ok sha256 of the empty string\nok sha256 of abc\nok sha256 of a two-block message\n3 passed, 0 failed\n", o.stderr)
}

fn fixtures_are_fmt_clean() uses env, ffi, time {
  let o = auk_cmd().args(["fmt", "--check", "tests/fixtures/bitwise.auk", "tests/fixtures/sha256.auk"]).output()
  t.check(o.success(), o.describe())
}

fn shift_amounts_outside_0_to_63_panic() uses env, fs, ffi, time {
  for (name, expr, n) in [
    ("shl64", "1 << n", "64"),
    ("shl_neg", "1 << n", "-1"),
    ("shr64", "-8 >> n", "64"),
    ("shr_big", "8 >> n", "1000"),
    ("shl_eq", "{{\n    var x = 1\n    x <<= n\n    x\n  }}", "65"),
  ] {
    let src = "fn main(args: [str]) {{\n  let n = int.parse(\"{n}\")!\n  print({expr})\n}}\n"
    let o = auk_cmd().arg("run").arg(scratch(name, src)).output()
    t.check(o.code == some(101), "{name}: {o.describe()}")
    t.check(o.stderr.starts_with("panic: shift amount {n} is outside 0..63\n"), "{name}: {o.stderr}")
    t.check(o.stderr.contains("{name}.auk:"), "{name}: the panic points at the shift: {o.stderr}")
  }
  // 0 and 63 are fine
  let src = "fn main() {{\n  let n = int.parse(\"63\")!\n  print(\"{{1 << n}} {{-1 >> n}} {{5 << 0}} {{5 >> 0}}\")\n}}\n"
  let o = auk_cmd().arg("run").arg(scratch("edges", src)).output()
  t.check(o.success(), o.stderr)
  t.eq(o.stdout, "-9223372036854775808 -1 5 5\n", "")
}

/// `auk check --json` on `src`.
fn check(name: str, src: str): str uses env, fs, ffi, time {
  let p = scratch(name, src)
  auk_cmd().args(["check", p, "--json"]).output().stdout
}

fn units_are_rejected_with_an_int_fix() uses env, fs, ffi, time {
  let out = check("unit", "fn f(n: int<B>): int = n & 0xff\n")
  t.check(out.contains("\"code\":\"E0293\""), out)
  t.check(out.contains("`&` works on bits, but this is `int<B>`, a value with a unit"), out)
  t.check(out.contains("\"fixes\":[{{\"line\":1,\"col\":24,\"end_line\":1,\"end_col\":24,\"text\":\"int(\"}},{{\"line\":1,\"col\":25,\"end_line\":1,\"end_col\":25,\"text\":\")\"}}]"), out)
  // every operator, either side, and compound assignment (no fix on an assignment target)
  for i, body in ["1 | n", "n ^ 1", "~n", "n << 1", "1 >> n"] {
    let out = check("unit{i}", "fn f(n: int<B>): int = {body}\n")
    t.check(out.contains("\"code\":\"E0293\""), "{body}: {out}")
  }
  let out = check("unit_assign", "fn f() {{\n  var d = 3<m>\n  d <<= 1\n}}\n")
  t.check(out.contains("\"code\":\"E0293\"") && out.contains("\"fixes\":[]"), out)
  let out = check("unit_float", "fn f(d: float<m>): int = d & 1\n")
  t.check(out.contains("\"code\":\"E0293\"") && out.contains("\"fixes\":[]"), out)
  // stripping the unit is fine
  let out = check("unit_ok", "fn f(n: int<B>): int = int(n) & 0xff\n")
  t.check(out.contains("\"ok\":true"), out)
}

fn non_int_operands_are_rejected() uses env, fs, ffi, time {
  let out = check("bool", "fn f(a: bool, b: bool): bool = a | b\n")
  t.check(out.contains("\"code\":\"E0260\"") && out.contains("for booleans use `||`"), out)
  t.check(t.count(out, "\"code\":") == 1, "one error, no cascade: {out}")
  let out = check("not_bool", "fn f(a: bool): bool = ~a\n")
  t.check(out.contains("for booleans use `!`"), out)
  let out = check("float", "fn f(x: float): int = x >> 1\n")
  t.check(out.contains("can't apply `>>` to `float`"), out)
  let out = check("str_assign", "fn f() {{\n  var s = \"a\"\n  s |= 1\n}}\n")
  t.check(out.contains("can't apply `|=` to `str`"), out)
}

fn bitwise_next_to_a_comparison_needs_parentheses() uses env, fs, ffi, time {
  let out = check("mix", "fn even(x: int): bool = x & 1 == 0\n")
  t.check(out.contains("\"code\":\"E0038\""), out)
  t.check(out.contains("\"fixes\":[{{\"line\":1,\"col\":25,\"end_line\":1,\"end_col\":25,\"text\":\"(\"}},{{\"line\":1,\"col\":30,\"end_line\":1,\"end_col\":30,\"text\":\")\"}}]"), out)
  // applying the fix checks clean
  let out = check("mix_fixed", "fn even(x: int): bool = (x & 1) == 0\n")
  t.check(out.contains("\"ok\":true"), out)
}

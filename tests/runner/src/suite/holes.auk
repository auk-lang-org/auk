/// tests/holes.rs: `auk holes`: the brief for every `??` hole (expected type, scope, contracts,
/// tests), as text and as JSON, for a single file and for a project with a hole in a submodule.

pub fn tests(): [t.Test] uses env, fs, ffi, time = [
  t.test("hatch_example_has_three_holes", hatch_example_has_three_holes),
  t.test("text_brief", text_brief),
  t.test("no_holes", no_holes),
  t.test("project_hole_in_a_submodule", project_hole_in_a_submodule),
  t.test("type_errors_fail_but_still_brief", type_errors_fail_but_still_brief),
]

fn auk(args: [str]): cmd.Out uses env, ffi, time = t.auk().args(args).cwd(t.root()).output()

fn parse(s: str): json.Json = match json.parse(s) {
  ok(j) => j
  err(Bad(e)) => t.bail("bad JSON ({e}): {s}")
}

fn holes_json(file: str): json.Json uses env, ffi, time {
  let o = auk(["holes", file, "--json"])
  t.check(o.success(), "auk holes failed:\n{o.stdout}\n{o.stderr}")
  parse(o.stdout)
}

fn strs(j: json.Json): [str] = j.as_arr().map(x => x.as_str()!)

fn scope(h: json.Json): [(str, str)] =
  h.get("scope").as_arr().map(v => (v.get("name").as_str()!, v.get("type").as_str()!))

fn scratch(name: str): str uses env, fs, ffi = t.scratch("holes/{name}")

fn hatch_example_has_three_holes() uses env, ffi, time {
  let j = holes_json("examples/hatch.auk")
  assert j.get("ok") == json.Json.Bool(true)
  let hs = j.get("holes").as_arr()
  t.check(hs.len() == 3, j.text())
  assert hs.map(h => h.get("expected").as_str()!) == ["float", "[int]", "int!DurErr"]
  assert hs.map(h => h.at(["function", "name"]).as_str()!) == ["median", "dedup", "seconds"]
  for i, h in hs {
    assert h.get("index").as_i64() == some(i + 1)
    assert h.get("file").as_str() == some("examples/hatch.auk")
    t.check(h.get("body") == json.Json.Bool(true), "each hole is a whole `{{ ?? }}` body")
    assert h.get("end_col").as_i64() == some(h.get("col").as_i64()! + 2)
  }

  let median = hs[0]
  assert (median.get("line").as_i64(), median.get("col").as_i64()) == (some(6), some(3))
  assert median.get("context").as_str() == some("fn median")
  assert median.at(["function", "signature"]).as_str() == some("fn median(xs: [float]): float")
  assert median.at(["function", "doc"]).as_str() == some("Median of a non-empty list.")
  assert strs(median.at(["function", "requires"])) == ["xs.len() > 0"]
  assert median.at(["function", "ensures"]).as_arr().len() == 0
  assert scope(median) == [("xs", "[float]")]
  let tests = median.get("tests").as_arr()
  assert tests.len() == 1
  assert tests[0].get("name").as_str() == some("median")
  assert tests[0].get("source").as_str() ==
    some("test \"median\" {{\n  assert median([3.0, 1.0, 2.0]) == 2.0\n  assert median([4.0, 1.0, 3.0, 2.0]) == 2.5\n}}")
  let others = median.get("module_fns").as_arr().map(f => f.get("signature").as_str()!)
  assert others == ["fn dedup(xs: [int]): [int]", "fn seconds(s: str): int!DurErr"]
  assert median.get("module_types").as_arr()[0].get("source").as_str() ==
    some("enum DurErr {{ Empty, BadUnit(c: char), NoNumber }}")

  let dedup = hs[1]
  assert strs(dedup.at(["function", "ensures"])) == ["result.len() <= xs.len()"]
  assert scope(dedup) == [("xs", "[int]")]
  t.check(
    dedup
      .get("tests")
      .as_arr()[0]
      .get("source")
      .as_str()!
      .contains("assert dedup([3, 1, 3, 2, 1]) == [3, 1, 2]"),
    "dedup test",
  )

  let seconds = hs[2]
  t.check(seconds.at(["function", "doc"]).is_null(), "the doc above `enum DurErr` is not seconds'")
  assert strs(seconds.at(["function", "ensures"])) == ["result >= 0"]
  assert scope(seconds) == [("s", "str")]
  let src = seconds.get("tests").as_arr()[0].get("source").as_str()!
  t.check(
    src.starts_with("test \"seconds\" {{") &&
      src.contains("assert seconds(\"5x\") is err(BadUnit('x'))"),
    src,
  )
}

fn text_brief() uses env, ffi, time {
  let o = auk(["holes", "examples/hatch.auk"])
  assert o.success()
  for want in [
    "hole 1 at examples/hatch.auk:6:3 in fn median\n  expected type: float\n",
    "    /// Median of a non-empty list.\n    fn median(xs: [float]): float\n      requires xs.len() > 0\n",
    "  in scope:\n    xs: [float]\n",
    "  tests that call it:\n    test \"median\" {{\n      assert median([3.0, 1.0, 2.0]) == 2.0\n",
    "hole 3 at examples/hatch.auk:18:3 in fn seconds\n  expected type: int!DurErr\n",
    "      ensures result >= 0\n",
  ] {
    t.check(o.stdout.contains(want), "missing {want.show()} in:\n{o.stdout}")
  }
}

fn no_holes() uses env, ffi, time {
  let o = auk(["holes", "examples/fib.auk", "--json"])
  let j = parse(o.stdout)
  assert o.success()
  assert j.get("holes").as_arr().len() == 0
}

fn project_hole_in_a_submodule() uses env, fs, ffi, time {
  let d = scratch("proj")
  t.write(paths.join(d, "raft.toml"), "[package]\nname = \"proj\"\nversion = \"0.1.0\"\n")
  t.write(
    paths.join(d, "src/main.auk"),
    "fn main() {{\n  print(geo.scale([1, 2], 3))\n}}\n\ntest \"scale\" {{\n  assert geo.scale([1], 2) == [4]\n}}\n\ntest \"other\" {{\n  assert 1 + 1 == 2\n}}\n",
  )
  t.write(
    paths.join(d, "src/geo.auk"),
    "/// Multiply by twice `f`.\npub fn scale(xs: [int], f: int): [int] {{\n  let k = f * 2\n  for i in 0..3 {{\n    let gone = i\n  }}\n  xs.map(x => {{\n    let y = x * k\n    ??\n  }})\n}}\n\nfn helper(s: str): int = s.len()\n",
  )
  let main = paths.join(d, "src/main.auk")
  let j = holes_json(main)
  let hs = j.get("holes").as_arr()
  t.check(hs.len() == 1, j.text())
  let h = hs[0]
  t.check(h.get("file").as_str()!.ends_with("src/geo.auk"), h.text())
  assert (h.get("line").as_i64(), h.get("col").as_i64()) == (some(9), some(5))
  assert h.get("expected").as_str() == some("int")
  assert h.get("body") == json.Json.Bool(false)
  assert h.at(["function", "signature"]).as_str() == some("pub fn scale(xs: [int], f: int): [int]")
  assert h.at(["function", "doc"]).as_str() == some("Multiply by twice `f`.")
  let names = scope(h).map(p => "{p.0}: {p.1}")
  t.check(
    names == ["xs: [int]", "f: int", "k: int", "x: int", "y: int"],
    "`i` and `gone` are out of scope: {names}",
  )
  let tests = h.get("tests").as_arr().map(x => x.get("name").as_str()!)
  t.check(tests == ["scale"], "only the test that calls `geo.scale`: {tests}")
  let others = h.get("module_fns").as_arr().map(f => f.get("signature").as_str()!)
  assert others == ["fn helper(s: str): int"]
}

fn type_errors_fail_but_still_brief() uses env, fs, ffi, time {
  let d = scratch("broken")
  let f = paths.join(d, "b.auk")
  t.write(f, "fn f(n: int): int {{\n  let s: str = 1\n  ??\n}}\n")
  let o = auk(["holes", f, "--json"])
  assert o.code == some(1)
  let j = parse(o.stdout)
  assert j.get("ok") == json.Json.Bool(false)
  assert j.get("holes").as_arr().len() == 1
  t.check(o.stderr.contains("E0200"), o.stderr)
}

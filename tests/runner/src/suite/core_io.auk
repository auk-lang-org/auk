/// tests/core_io.rs: core console and file I/O end to end: stdin (`env.read_line`,
/// `env.read_all`, `env.lines`), `eprint`, `proc.exit`, the `fs` extras, binary files, and
/// `rand.bytes`, `rand.shuffle`, `rand.choice` and `rand.seed`. Every program runs under
/// `AUK_LEAK_CHECK`.

pub fn tests(): [t.Test] uses env, fs, ffi, time = [
  t.test("stdin_lines_are_counted", stdin_lines_are_counted),
  t.test("stdin_read_line_then_the_rest", stdin_read_line_then_the_rest),
  t.test("eprint_goes_to_stderr_only", eprint_goes_to_stderr_only),
  t.test("exit_codes_flush_and_pass_the_leak_check", exit_codes_flush_and_pass_the_leak_check),
  t.test("fs_round_trip_in_a_temp_dir", fs_round_trip_in_a_temp_dir),
  t.test("bytes_round_trip", bytes_round_trip),
  t.test("secure_and_seeded_random", secure_and_seeded_random),
  t.test("new_effectful_functions_need_their_effect", new_effectful_functions_need_their_effect),
]

fn scratch(name: str): str uses env, fs, ffi = t.scratch("core_io/{name}")

fn auk_cmd(): cmd.Cmd uses env, ffi = t.auk().setenv("AUK_LEAK_CHECK", "1")

/// `auk run` a program (written to its own scratch dir) with `args`, feeding it `stdin`.
fn run(name: str, src: str, args: [str], stdin: str): cmd.Out uses env, fs, ffi, time {
  let d = scratch(name)
  let p = paths.join(d, "main.auk")
  t.write(p, src)
  auk_cmd().arg("run").arg(p).args(args).cwd(d).stdin(stdin).output()
}

/// Runs successfully and prints `want` (and nothing on stderr).
fn expect(name: str, src: str, stdin: str, want: str) uses env, fs, ffi, time {
  let o = run(name, src, [], stdin)
  t.check(o.success(), "{name} failed ({o.code}):\n{o.stdout}\n{o.stderr}")
  t.eq(o.stdout, want, "{name} stderr:\n{o.stderr}")
  t.eq(o.stderr, "", name)
}

fn stdin_lines_are_counted() uses env, fs, ffi, time {
  let src = "fn main() uses env {{\n  let xs = env.lines()\n  print(\"{{xs.len()}} {{xs}}\")\n}}\n"
  expect("lines", src, "a\nbb\r\n\nlast", "4 [\"a\", \"bb\", \"\", \"last\"]\n")
  expect("lines_empty", src, "", "0 []\n")
}

fn stdin_read_line_then_the_rest() uses env, fs, ffi, time {
  let src = "fn main(): ()! uses env {{\n  var n = 0\n  while n < 2 {{\n    let l = env.read_line() else {{ break }}\n    print(\"line {{l.len()}}: {{l}}\")\n    n += 1\n  }}\n  print(\"rest: {{(env.read_all()?).trim()}}\")\n  print(env.read_line())\n  print((env.read_all()?).len())\n}}\n"
  expect(
    "read_line",
    src,
    "héllo\r\nworld\nthe\nend\n",
    "line 5: héllo\nline 5: world\nrest: the\nend\nnone\n0\n",
  )
  // invalid UTF-8 (raw bytes, so not through `run`)
  let d = scratch("read_all_bad_utf8")
  t.write(paths.join(d, "main.auk"), "fn main(): ()! uses env {{ print(env.read_all()?) }}\n")
  let o = auk_cmd()
    .arg("run")
    .arg(paths.join(d, "main.auk"))
    .stdin_bytes("bad ".bytes() + [0xff, 10])
    .output()
  assert o.code == some(1)
  t.check(o.stderr.starts_with("error: env.read_all: stdin: invalid UTF-8"), o.stderr)
}

fn eprint_goes_to_stderr_only() uses env, fs, ffi, time {
  let src = "struct P {{ x: int }}\nfn main() {{\n  print(\"out\")\n  eprint(\"err {{1 + 1}}\")\n  eprint(P {{ x: 3 }})\n  print(\"out2\")\n}}\n"
  let o = run("eprint", src, [], "")
  t.check(o.success(), o.stderr)
  assert o.stdout == "out\nout2\n"
  assert o.stderr == "err 2\nP {{ x: 3 }}\n"
}

fn exit_codes_flush_and_pass_the_leak_check() uses env, fs, ffi, time {
  // from main, with live heap values: they're released first, so the leak check passes
  let src = "fn main(): int uses proc {{\n  let xs = [\"a\", \"b\"]\n  let m = {{\"k\": xs}}\n  print(\"before {{m}}\")\n  if xs.len() == 2 {{ proc.exit(3) }}\n  print(\"after\")\n  0\n}}\n"
  let o = run("exit3", src, [], "")
  t.check(o.code == some(3), o.stderr)
  assert o.stdout == "before {{\"k\": [\"a\", \"b\"]}}\n"
  assert o.stderr == ""
  // never-typed: it fills any type, e.g. a `let ... else`
  let src = "fn main() uses env, proc {{\n  let home = env.get(\"AUK_NO_SUCH_VAR\") else proc.exit(0)\n  print(home)\n}}\n"
  let o = run("exit0", src, [], "")
  assert o.code == some(0)
  assert o.text() == ("", "")
  let src = "fn die(n: int): int uses proc = proc.exit(n)\nfn main() uses proc {{\n  eprint(\"bye\")\n  print(die(42))\n}}\n"
  let o = run("exit42", src, [], "")
  assert o.code == some(42)
  assert o.stderr == "bye\n"
  let o = run("exit_range", "fn main() uses proc {{ proc.exit(256) }}\n", [], "")
  assert o.code == some(101)
  t.check(o.stderr.starts_with("panic: proc.exit(256): code out of range 0..255\n  at "), o.stderr)
}

fn fs_round_trip_in_a_temp_dir() uses env, fs, ffi, time {
  let src = r"""
    fn main(): ()! uses fs {
      let d = fs.temp_dir()?
      assert fs.is_dir(d) && (fs.list(d)?).len() == 0
      fs.mkdir("{d}/x/y/z")?
      fs.mkdir("{d}/x/y")?
      fs.write("{d}/b.txt", "one\n")?
      fs.append("{d}/b.txt", "two\n")?
      fs.append("{d}/a.txt", "new")?
      print(fs.list(d)?)
      print(fs.lines("{d}/b.txt")?)
      fs.rename("{d}/a.txt", "{d}/x/c.txt")?
      print("{fs.exists("{d}/a.txt")} {fs.exists("{d}/x/c.txt")} {fs.is_dir("{d}/x/c.txt")}")
      print(fs.remove("{d}/x") is err(_))
      print(fs.list("{d}/nope") is err(_))
      fs.remove("{d}/x/c.txt")?
      fs.remove("{d}/x/y/z")?
      fs.remove("{d}/x/y")?
      fs.remove("{d}/x")?
      fs.remove("{d}/b.txt")?
      fs.remove(d)?
      print(fs.exists(d))
    }
    """
  expect(
    "fs",
    src,
    "",
    "[\"a.txt\", \"b.txt\", \"x\"]\n[\"one\", \"two\"]\nfalse true false\ntrue\ntrue\nfalse\n",
  )
}

fn bytes_round_trip() uses env, fs, ffi, time {
  let src = r"""
    fn main(): ()! uses fs {
      let d = fs.temp_dir()?
      let p = "{d}/data.bin"
      let bs = (0..256).map(i => (i * 7 + 3) % 256)
      fs.write_bytes(p, bs)?
      let back = fs.read_bytes(p)?
      print("{back.len()} {back == bs} {back.take(3)}")
      print(fs.write_bytes(p, [1, 300]) else e => print("{e}"))
      print((fs.read_bytes(p)?).len())
      fs.write_bytes(p, "hé".bytes())?
      print(fs.read(p)?)
      fs.remove(p)?
      fs.remove(d)?
    }
    """
  let o = run("bytes", src, [], "")
  t.check(o.success(), "{o.stdout}\n{o.stderr}")
  let lines = o.stdout.lines()
  assert lines[0] == "256 true [3, 10, 17]"
  t.check(
    lines[1].starts_with("fs.write_bytes ") &&
      lines[1].ends_with("data.bin: byte 300 at index 1 is out of range 0..255"),
    o.stdout,
  )
  assert lines.skip(3) == ["256", "hé"]
}

fn secure_and_seeded_random() uses env, fs, ffi, time {
  let src = r"""
    fn main() uses rand {
      let a = rand.bytes(32)
      let b = rand.bytes(32)
      print("{a.len()} {a != b} {a.all(x => x >= 0 && x <= 255)}")
      let xs = [1, 2, 3, 4, 5, 6, 7, 8]
      let s = rand.shuffle(xs)
      print("{s.sort() == xs} {xs}")
      rand.seed(7)
      let s1 = rand.shuffle(xs)
      let c1 = rand.choice(xs)
      rand.seed(7)
      print("{rand.shuffle(xs) == s1} {rand.choice(xs) == c1}")
      let none_: [str] = []
      print(rand.choice(none_))
      print(rand.choice(["only"]))
      print(rand.shuffle(none_))
    }
    """
  expect(
    "rand",
    src,
    "",
    "32 true true\ntrue [1, 2, 3, 4, 5, 6, 7, 8]\ntrue true\nnone\nsome(\"only\")\n[]\n",
  )
}

fn new_effectful_functions_need_their_effect() uses env, fs, ffi, time {
  let d = scratch("effects")
  let cases = [
    ("list", "fn names(d: str): [str]! = fs.list(d)\nfn main() {{ print(names(\".\")) }}\n", "fs"),
    ("stdin", "fn first(): str? = env.read_line()\nfn main() {{ print(first()) }}\n", "env"),
    ("exit", "fn quit() {{ proc.exit(1) }}\nfn main() {{ quit() }}\n", "proc"),
    ("bytes", "fn token(): [int] = rand.bytes(16)\nfn main() {{ print(token()) }}\n", "rand"),
    (
      "shuffle",
      "fn mix(xs: [int]): [int] = rand.shuffle(xs)\nfn main() {{ print(mix([1])) }}\n",
      "rand",
    ),
  ]
  for (name, src, effect) in cases {
    let p = paths.join(d, "{name}.auk")
    t.write(p, src)
    let o = auk_cmd().arg("check").arg(p).output()
    let err = o.stderr + o.stdout
    t.check(!o.success(), "{name}: expected E0410")
    t.check(err.contains("E0410") && err.contains("uses {effect}"), "{name}:\n{err}")
  }
  // `eprint`, like `print`, needs no effect
  let p = paths.join(d, "eprint.auk")
  t.write(p, "fn warn(s: str) {{ eprint(\"warning: {{s}}\") }}\nfn main() {{ warn(\"x\") }}\n")
  let o = auk_cmd().arg("check").arg(p).output()
  t.check(o.success(), o.stderr)
}

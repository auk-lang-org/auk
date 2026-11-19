/// tests/gaps.rs: language gaps found by the self-hosting pilot (design/pilot-report.md,
/// self-host-plan 2d): bare variants through `T?`/`T!`/`T!E`, or-patterns, `var` parameters in
/// function types, stack overflow reporting, and the small string/number helpers.

pub fn tests(): [t.Test] uses env, fs, ffi, time = [
  t.test(
    "bare_variants_resolve_through_optional_and_result",
    bare_variants_resolve_through_optional_and_result,
  ),
  t.test(
    "value_variant_is_never_picked_against_the_expected_enum",
    value_variant_is_never_picked_against_the_expected_enum,
  ),
  t.test(
    "value_variant_without_expected_type_is_ambiguous",
    value_variant_without_expected_type_is_ambiguous,
  ),
  t.test("value_variants_alone_still_work", value_variants_alone_still_work),
  t.test("or_patterns_match_and_bind", or_patterns_match_and_bind),
  t.test(
    "or_pattern_alternatives_bind_the_same_names",
    or_pattern_alternatives_bind_the_same_names,
  ),
  t.test(
    "or_patterns_in_exhaustiveness_and_reachability",
    or_patterns_in_exhaustiveness_and_reachability,
  ),
  t.test("or_patterns_format", or_patterns_format),
  t.test("var_parameters_in_function_types", var_parameters_in_function_types),
  t.test(
    "var_parameters_in_function_types_are_checked",
    var_parameters_in_function_types_are_checked,
  ),
  t.test("stack_overflow_is_a_panic", stack_overflow_is_a_panic),
  t.test(
    "stack_overflow_in_a_built_program_names_the_function",
    stack_overflow_in_a_built_program_names_the_function,
  ),
  t.test("stack_overflow_fails_one_test", stack_overflow_fails_one_test),
  t.test("string_trimming_and_stripping", string_trimming_and_stripping),
  t.test("radix_parsing", radix_parsing),
  t.test("hex_octal_binary_formats", hex_octal_binary_formats),
  t.test("tuple_assignment", tuple_assignment),
]

extern fn c_mkdtemp(t: ffi.Ptr): ffi.Ptr? = "char *mkdtemp(char *)"

fn auk(args: [str]): cmd.Out uses env, ffi, time =
  t.auk().unsetenv("AUK_LEAK_CHECK").args(args).output()

/// A fresh, unique directory under `<tmp>/gaps` (Rust's numbered `gaps/<n>`).
fn scratch(): str uses env, fs, ffi {
  let base = paths.join(t.tmp_base(), "gaps")
  t.must(fs.mkdir(base), "mkdir {base}")
  let tpl = paths.join(base, "XXXXXX")
  let p = ffi.from_bytes(tpl.bytes() + [0])
  let r = c_mkdtemp(p)
  let d = ffi.cstr(p)
  ffi.free(p)
  if r is none { t.fail("mkdtemp {tpl} failed") }
  d
}

/// A project with `files` (path, source) under `src/`; returns the path of `src/main.auk`.
fn project(files: [(str, str)]): str uses env, fs, ffi {
  let d = scratch()
  t.write(paths.join(d, "raft.toml"), "[package]\nname = \"app\"\nversion = \"0.1.0\"\n")
  for (p, s) in files { t.write(paths.join(d, "src/{p}"), s) }
  paths.join(d, "src/main.auk")
}

fn file(src: str): str uses env, fs, ffi {
  let p = paths.join(scratch(), "t.auk")
  t.write(p, src)
  p
}

/// `auk run`: stdout, asserting success.
fn run_ok(p: str): str uses env, ffi, time {
  let o = auk(["run", p])
  t.check(o.success(), "auk run failed:\n{o.stdout}\n{o.stderr}")
  o.stdout
}

/// `auk check`: stderr, asserting failure.
fn check_err(p: str): str uses env, ffi, time {
  let o = auk(["check", p])
  t.check(!o.success(), "expected errors, got none")
  o.stderr
}

fn check_ok(p: str) uses env, ffi, time {
  let o = auk(["check", p])
  t.check(o.success(), "auk check failed:\n{o.stderr}")
}

// ---- 1. bare variants of another module's enum through `T?` / `T!` / `T!E` ----

let TOK =
  "pub enum Tok {{ Fn, Float(f: float), Int(n: int), Eof }}\npub enum Fail {{ Bad(m: str) }}\n"

fn bare_variants_resolve_through_optional_and_result() uses env, fs, ffi, time {
  let main = r"""

    fn a(): tok.Tok? = Fn
    fn b(): tok.Tok! = Float(1.5)
    fn c(): tok.Tok!tok.Fail = Int(3)
    fn d(x: bool): tok.Tok!tok.Fail = if x { Eof } else { fail(Bad("no")) }
    fn e(x: int): tok.Tok!tok.Fail {
      if x > 0 { return Int(x) }
      match x { 0 => Fn, _ => Float(-1.0) }
    }
    fn f(): Value? = Int(7)
    fn main() {
      let xs: [tok.Tok] = [Eof, Int(2)]
      print("{a()} {b()} {c()} {d(true)} {e(4)} {e(0)} {e(-1)} {f()} {xs}")
    }
    """
  let p = project([("tok.auk", TOK), ("main.auk", main)])
  t.eq(
    run_ok(p),
    "some(Fn) ok(Float(1.5)) ok(Int(3)) ok(Eof) ok(Int(4)) ok(Fn) ok(Float(-1.0)) some(7) [Eof, Int(2)]\n",
    "",
  )
}

fn value_variant_is_never_picked_against_the_expected_enum() uses env, fs, ffi, time {
  let p = project([
    ("tok.auk", TOK),
    ("main.auk", "fn g(): tok.Tok = Str(\"x\")\nfn main() {{ print(g()) }}\n"),
  ])
  let err = check_err(p)
  t.check(err.contains("error[E0117]: `Tok` has no variant `Str`"), err)
  t.check(err.contains("write `Value.Str` for that"), err)
}

fn value_variant_without_expected_type_is_ambiguous() uses env, fs, ffi, time {
  let p = project([
    ("tok.auk", TOK),
    ("main.auk", "fn main() {{\n  let t = Float(1.5)\n  print(t)\n}}\n"),
  ])
  let err = check_err(p)
  t.check(
    err.contains("error[E0117]: `Float` could be `tok.Float` (a `Tok`) or core's `Value.Float`"),
    err,
  )
  t.check(err.contains("fix: replace the text at 2:11 with `tok.Float`"), err)
  // explicit forms are fine
  let p = project([
    ("tok.auk", TOK),
    (
      "main.auk",
      "fn main() {{\n  let t = tok.Float(1.5)\n  let v = Value.Float(2.0)\n  let w: Value = Int(3)\n  print(\"{{t}} {{v}} {{w}}\")\n}}\n",
    ),
  ])
  t.eq(run_ok(p), "Float(1.5) 2.0 3\n", "")
}

fn value_variants_alone_still_work() uses env, fs, ffi, time {
  // no enum of this program has a variant `Int`: a bare `Int(..)` is core's `Value.Int`
  let p = file("fn main() {{\n  let v = Int(3)\n  let w = List([Str(\"a\"), Null])\n  print(\"{{v}} {{w}}\")\n}}\n")
  check_ok(p)
}

// ---- 2. or-patterns ----

/// `auk run` under the leak check: stdout, asserting success and no leaks.
fn run_leak_free(p: str): str uses env, ffi, time {
  let o = t.auk().args(["run", p]).setenv("AUK_LEAK_CHECK", "1").output()
  t.check(o.success() && o.stderr == "", "auk run failed or leaked:\n{o.stdout}\n{o.stderr}")
  o.stdout
}

let OR_PROGRAM = r"""
  enum Tok { LParen, RParen, LBracket, RBracket, Ident(s: str), Kw(s: str), Num(n: int), Eof }
  enum Shape { Circle(r: float), Square(side: float), Rect(w: float, h: float), Dot }
  struct P { name: str, age: int }

  fn closes(t: Tok): bool = match t {
    RParen | RBracket => true
    _ => false
  }

  fn text(t: Tok): str = match t {
    Ident(s) | Kw(s) => s
    Num(n) => "{n}"
    LParen | RParen | LBracket |
      RBracket => "bracket"
    Eof => "eof"
  }

  fn size(s: Shape): float = match s {
    Circle(x) | Square(x) | Rect(x, _) => x
    Dot => 0.0
  }

  fn small(n: int): str = match n { 0 | 1 | 2 => "small", _ => "big" }

  fn names(xs: [P]): str = match xs {
    [P { name, .. }] | [_, P { name, .. }] => name
    _ => "?"
  }

  fn list_rest(xs: [str]): [str] = match xs {
    ["a", ..rest] | ["b", ..rest] => rest
    _ => []
  }

  fn opt(x: int?): int = match x {
    some(0) | none => -1
    some(n) => n
  }

  fn guarded(t: Tok): str = match t {
    Ident(s) | Kw(s) when s.len() > 2 => "long {s}"
    _ => "other"
  }

  fn main() {
    print("{closes(RParen)} {closes(LParen)} {closes(RBracket)}")
    print("{text(Ident("x"))} {text(Kw("fn"))} {text(Num(3))} {text(LBracket)} {text(Eof)}")
    print("{size(Circle(1.0))} {size(Square(2.0))} {size(Rect(3.0, 4.0))} {size(Dot)}")
    print("{small(1)} {small(5)}")
    print(names([P { name: "ann", age: 1 }]))
    print(names([P { name: "ann", age: 1 }, P { name: "bob", age: 2 }]))
    print("{list_rest(["a", "x", "y"])} {list_rest(["b", "z"])} {list_rest(["c"])}")
    print("{opt(some(0))} {opt(none)} {opt(some(4))}")
    print("{guarded(Ident("abc"))} {guarded(Kw("ab"))} {guarded(Num(1))}")
  }
  """

fn or_patterns_match_and_bind() uses env, fs, ffi, time {
  let p = file(OR_PROGRAM)
  t.eq(
    run_leak_free(p),
    "true false true\nx fn 3 bracket eof\n1.0 2.0 3.0 0.0\nsmall big\nann\nbob\n[\"x\", \"y\"] [\"z\"] []\n-1 -1 4\nlong abc other other\n",
    "",
  )
}

fn or_pattern_alternatives_bind_the_same_names() uses env, fs, ffi, time {
  let shape = "enum Shape {{ Circle(r: float), Square(side: float), Dot }}\n"
  let err = check_err(
    file("{shape}fn f(s: Shape): float = match s {{\n  Circle(r) | Square(side) => r\n  _ => 0.0\n}}\n"),
  )
  t.check(
    err.contains("3:22: error[E0267]: `side` is bound here but not in the first alternative"),
    err,
  )
  t.check(t.count(err, "error[") == 1, err)
  let err = check_err(
    file("{shape}fn f(s: Shape): float = match s {{\n  Circle(r) | Dot => r\n  _ => 0.0\n}}\n"),
  )
  t.check(err.contains("error[E0267]: this alternative doesn't bind `r`"), err)
  let err = check_err(
    file("fn f(x: int, s: str): int = match (x, s) {{\n  (1, n) | (n, \"a\") => 1\n  _ => 0\n}}\n"),
  )
  t.check(
    err.contains("2:13: error[E0267]: `n` is a `str` in the first alternative but an `int` here"),
    err,
  )
}

fn or_patterns_in_exhaustiveness_and_reachability() uses env, fs, ffi, time {
  let shape =
    "enum Shape {{ Circle(r: float), Square(side: float), Rect(w: float, h: float), Dot }}\n"
  // covering every variant through alternatives
  check_ok(
    file("{shape}fn f(s: Shape): float = match s {{\n  Circle(r) | Rect(_, r) => r\n  Dot | Square(_) => 0.0\n}}\n"),
  )
  let err = check_err(file("{shape}fn f(s: Shape): int = match s {{\n  Circle(_) | Dot => 1\n}}\n"))
  t.check(
    err.contains("error[E0400]: this `match` doesn't cover every case: `Square(_)` and `Rect(_, _)` are not handled"),
    err,
  )
  let err = check_err(
    file("{shape}fn f(s: Shape): int = match s {{\n  Circle(_) | Dot => 1\n  Square(_) | Circle(_) => 2\n  Dot | Circle(_) => 3\n  _ => 4\n}}\n"),
  )
  t.check(err.contains("4:15: error[E0401]: this alternative is unreachable"), err)
  t.check(err.contains("fix: remove the text at 4:12"), err)
  t.check(err.contains("5:3: error[E0401]: this arm is unreachable"), err)
  t.check(err.contains("the arm `Circle(_) | Dot` at line 3 already matches"), err)
  // a guard doesn't count toward coverage
  let err = check_err(
    file("{shape}fn f(s: Shape): int = match s {{\n  Circle(_) | Square(_) | Rect(_, _) | Dot when true => 1\n}}\n"),
  )
  t.check(err.contains("E0400"), err)
}

fn or_patterns_format() uses env, fs, ffi, time {
  let p = file("fn f(n: int): int = match n {{\n  0 |\n    1 => 1\n  _ => n\n}}\n")
  let o = auk(["fmt", p])
  assert o.success()
  t.eq(t.read(p), "fn f(n: int): int = match n {{\n  0 | 1 => 1\n  _ => n\n}}\n", "")
}

// ---- 3. `var` parameters in function types ----

let VAR_FN_PROGRAM = r"""
  struct Parser { toks: [str], pos: int, depth: int }
  enum Fail { Bad(m: str) }

  fn peek(p: Parser): str = p.toks.get(p.pos) else ""
  fn next(p: var Parser): str {
    let t = p.peek()
    p.pos += 1
    t
  }

  fn item(p: var Parser): str!Fail {
    let t = p.next()
    if t == "!" { fail(Bad("bang at {p.pos - 1}")) }
    t.upper()
  }

  /// `close`-terminated, comma-separated items, each parsed by `f`
  fn list(p: var Parser, close: str, f: (var Parser) => str!Fail): [str]!Fail {
    var out: [str] = []
    while p.peek() != close && p.peek() != "" {
      out.push(f(&p)?)
      if p.peek() == "," { p.next() }
    }
    p.next()
    out
  }

  fn nested(p: var Parser, f: (var Parser) => str!Fail): str!Fail {
    p.depth += 1
    let r = f(&p)
    p.depth -= 1
    r
  }

  fn twice(n: var int, g: (var int, int) => ()) {
    g(&n, 1)
    g(&n, 2)
  }

  fn main() {
    var p = Parser { toks: ["a", ",", "b", ",", "c", ")", "z"], pos: 0, depth: 0 }
    print(list(&p, ")", item))
    print(p.pos)
    var q = Parser { toks: ["x", "y", ")"], pos: 0, depth: 0 }
    print(list(&q, ")", r => "<{r.next()}>"))
    var s = Parser { toks: ["x", "!", ")"], pos: 0, depth: 0 }
    print(list(&s, ")", item) else e => ["{e}"])
    var u = Parser { toks: ["k"], pos: 0, depth: 3 }
    print(nested(&u, (r: var Parser) => "{r.depth}:{r.next()}"))
    print("{u.depth} {u.pos}")
    var n = 10
    twice(&n, (x, k) => { x += k })
    print(n)
    let h: (var int) => int = x => {
      x *= 2
      x
    }
    var m = 5
    print("{h(&m)} {m}")
    let fs: [(var int) => ()] = [x => { x += 1 }, x => { x *= 3 }]
    for f in fs { f(&m) }
    print(m)
  }
  """

fn var_parameters_in_function_types() uses env, fs, ffi, time {
  let p = file(VAR_FN_PROGRAM)
  t.eq(
    run_leak_free(p),
    "ok([\"A\", \"B\", \"C\"])\n6\nok([\"<x>\", \"<y>\"])\n[\"Bad(\\\"bang at 1\\\")\"]\nok(\"4:k\")\n3 1\n13\n10 10\n33\n",
    "",
  )
}

fn var_parameters_in_function_types_are_checked() uses env, fs, ffi, time {
  let err = check_err(file("fn apply(n: var int, g: (var int) => ()) {{ g(n) }}\n"))
  t.check(
    err.contains("1:46: error[E0310]: parameter 1 of `g` is `var`, so the argument needs `&`"),
    err,
  )
  t.check(err.contains("fix: insert `&` at 1:46"), err)
  let err = check_err(file("fn apply(n: int, g: (int) => ()) {{ g(&n) }}\n"))
  t.check(err.contains("error[E0311]: parameter 1 of `g` is not a `var` parameter"), err)
  // a `var` closure parameter needs a function type that says so (one error, not two)
  let err = check_err(
    file("fn plain(g: (int) => int): int = g(1)\nfn main() {{ print(plain((x: var int) => x)) }}\n"),
  )
  t.check(
    err.contains("error[E0200]: this closure parameter is `var`, but the function type here passes a plain `int`"),
    err,
  )
  t.check(t.count(err, "error[") == 1, err)
  // a function with a `var` parameter has a `var` function type
  let err = check_err(
    file("fn bump(n: var int) {{ n += 1 }}\nfn main() {{ print([1].map(bump)) }}\n"),
  )
  t.check(err.contains("found `(var int) => ()`"), err)
  // a closure inside still captures by value
  let err = check_err(
    file("fn apply(n: var int, g: (var int) => ()) {{ g(&n) }}\nfn main() {{\n  var a = 1\n  apply(&a, x => {{\n    let f = () => {{ x += 1 }}\n    f()\n  }})\n}}\n"),
  )
  t.check(err.contains("error[E0323]: a closure can't change `x`, a variable it captures"), err)
  // `var` only in a function type's parameters
  let err = check_err(file("fn f(x: (var int)) {{}}\n"))
  t.check(err.contains("1:10: error[E0023]: `var` is only for a parameter of a function type"), err)
}

// ---- 4. stack overflow ----

let OVERFLOW = r"""
  fn down(n: int): int = if n == 0 { 0 } else { 1 + down(n - 1) }

  fn forever(n: int): int = 1 + forever(n + 1)

  async fn forever_task(): int = forever(0)

  fn main(args: [str]) {
    print("deep: {down(200000)}")
    if args.len() > 1 {
      let r = catch forever(0)
      print("caught: {r}")
      let r2 = catch forever(0)
      print("again: {r2}")
      let t = forever_task()
      let r3 = catch await t
      print("task: {r3}")
    } else {
      print(forever(0))
    }
  }
  """

fn stack_overflow_is_a_panic() uses env, fs, ffi, time {
  let p = file(OVERFLOW)
  let o = auk(["run", p])
  t.check(o.code == some(101), o.describe())
  t.eq(o.stdout, "deep: 200000\n", "")
  t.eq(o.stderr, "panic: stack overflow\n  at <unknown>\n", "")
  // under a recovery point (`catch`, a task) it is an Err, again and again
  let o = auk(["run", p, "catch"])
  t.check(o.code == some(0), o.describe())
  t.eq(
    o.stdout,
    "deep: 200000\ncaught: err(panic: stack overflow at <unknown>)\nagain: err(panic: stack overflow at <unknown>)\ntask: err(panic: stack overflow at <unknown>)\n",
    "",
  )
}

fn stack_overflow_in_a_built_program_names_the_function() uses env, fs, ffi, time {
  let p = file(OVERFLOW)
  let exe = paths.join(paths.parent(p) else ".", "overflow")
  let o = auk(["build", p, "-o", exe])
  t.check(o.success(), o.describe())
  let o = cmd.new(exe).output()
  t.check(o.code == some(101), o.describe())
  t.eq(o.stderr, "panic: stack overflow\n  at forever\n", "")
  let o = cmd.new(exe).arg("catch").output()
  t.check(o.stdout.contains("again: err(panic: stack overflow at forever)"), o.describe())
}

fn stack_overflow_fails_one_test() uses env, fs, ffi, time {
  let p = file("fn forever(n: int): int = 1 + forever(n + 1)\ntest \"deep\" {{ assert forever(0) == 1 }}\ntest \"fine\" {{ assert 1 == 1 }}\n")
  let o = auk(["test", p])
  t.check(o.stdout.contains("FAIL deep\n    panic: stack overflow\n"), o.stdout)
  t.check(o.stdout.contains("ok fine\n1 passed, 1 failed"), o.stdout)
}

// ---- 5. small helpers: strings, radix, hex format, tuple assignment ----

fn string_trimming_and_stripping() uses env, fs, ffi, time {
  let p = file(r"""
    fn main() {
      let s = "  hi there \n"
      print("[{s.trim_start()}] [{s.trim_end()}] [{s.trim()}]")
      print("{"--flag".strip_prefix("--")} {"x".strip_prefix("--")} {"main.auk".strip_suffix(".auk")} {"héllo".strip_prefix("hé")}")
      let name = "file.txt".strip_suffix(".txt") else "?"
      print(name)
      print("{min(3, 1)} {max(3, 1)} {min("b", "a")} {max(2.5, -1.0)}")
      print("{"héllo ✓".byte_len()} {"".byte_len()} {"héllo".len()}")
    }
    """)
  t.eq(
    run_leak_free(p),
    "[hi there \n] [  hi there] [hi there]\nsome(\"flag\") none some(\"main\") some(\"llo\")\nfile\n1 3 a 2.5\n10 0 5\n",
    "",
  )
}

fn radix_parsing() uses env, fs, ffi, time {
  let p = file(r"""
    fn main() {
      print(int.parse("ff", 16))
      print(int.parse("-FF", 16))
      print(int.parse("1010_1010", 2))
      print(int.parse("zz", 36))
      print(int.parse("7fffffffffffffff", 16))
      print(int.parse("-8000000000000000", 16))
      print(int.parse("8000000000000000", 16))
      print(int.parse("12", 2))
      print(int.parse("", 16))
      print(int.parse("1", 37) else e => -1)
      print("{'f'.is_digit(16)} {'g'.is_digit(16)} {'7'.is_digit(8)} {'8'.is_digit(8)} {'Z'.is_digit(36)}")
    }
    """)
  t.eq(
    run_leak_free(p),
    "ok(255)\nok(-255)\nok(170)\nok(1295)\nok(9223372036854775807)\nok(-9223372036854775808)\nerr(int.parse: \"8000000000000000\" is out of range)\nerr(int.parse: invalid base-2 int \"12\")\nerr(int.parse: invalid base-16 int \"\")\n-1\ntrue false true false true\n",
    "",
  )
}

fn hex_octal_binary_formats() uses env, fs, ffi, time {
  let p = file(r"""
    fn main() {
      let n = 255
      print("{n:x} {n:X} {n:o} {n:b} {n:08x} {n:>6x}| {n:<6b}| {0:x} {-1:x}")
      print("{1.5.bits():016x}")
    }
    """)
  t.eq(
    run_leak_free(p),
    "ff FF 377 11111111 000000ff     ff| 11111111| 0 ffffffffffffffff\n3ff8000000000000\n",
    "",
  )
  let err = check_err(file("fn f(x: float): str = \"{{x:x}}\"\n"))
  t.check(
    err.contains("error[E0283]: the format spec `x` shows an `int` in hex, but this is `float`"),
    err,
  )
  let err = check_err(file("fn f(n: int): str = \"{{n:xx}}\"\n"))
  t.check(err.contains("error[E0282]: malformed format spec `xx`: unexpected `x`"), err)
}

fn tuple_assignment() uses env, fs, ffi, time {
  let p = file(r"""
    struct P { x: int, ys: [str] }
    fn main() {
      var a = "one"
      var b = "two"
      (a, b) = (b, a)
      print("{a} {b}")
      var p = P { x: 1, ys: ["k"] }
      var xs = [10, 20, 30]
      (p.x, xs[2], (a, b)) = (5, 99, ("x", "y"))
      print("{p.x} {xs} {a} {b}")
      (p.ys, b) = (["m", a], p.ys[0])
      print("{p.ys} {b}")
      var m = {"k": 1}
      (m["k"], m["j"]) = (2, 3)
      print(m)
    }
    """)
  t.eq(
    run_leak_free(p),
    "two one\n5 [10, 20, 99] x y\n[\"m\", \"x\"] k\n{{\"k\": 2, \"j\": 3}}\n",
    "",
  )
  let err = check_err(file("fn f() {{\n  var a = 1\n  let b = 2\n  (a, b) = (b, a)\n}}\n"))
  t.check(err.contains("error[E0320]: can't assign to `b`: it isn't mutable"), err)
  let err = check_err(file("fn f() {{\n  var a = 1\n  var b = 2\n  (a, b) += (1, 1)\n}}\n"))
  t.check(err.contains("4:3: error[E0027]: can't assign to this expression"), err)
  let err = check_err(file("fn f() {{\n  var a = 1\n  var b = 2\n  (a, b) = (1, \"x\")\n}}\n"))
  t.check(err.contains("E0200"), err)
}

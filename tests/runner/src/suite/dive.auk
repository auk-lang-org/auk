/// tests/dive.rs: `auk dive`, the REPL, driven through piped stdin (`--quiet`: no banner, no
/// prompts). (The Rust tests always run the Rust `auk`; these skip on a binary that lacks
/// `dive`.)

pub fn tests(): [t.Test] uses env, fs, ffi, time = [
  t.test("scripted_session", scripted_session),
  t.test("clauses_redefinition_and_unshowable_values", clauses_redefinition_and_unshowable_values),
  t.test(
    "errors_map_to_the_input_lines_and_load_skips_main",
    errors_map_to_the_input_lines_and_load_skips_main,
  ),
  t.test("bad_flag", bad_flag),
]

/// Run a dive session on `input`; returns its stdout (asserting a clean exit and empty stderr).
fn dive(input: str): str uses env, ffi, time {
  let out = t.auk().args(["dive", "--quiet"]).stdin(input).output()
  t.check(out.success(), "dive failed: {out.stderr}\n{out.stdout}")
  t.check(out.stderr == "", "stderr {out.stderr.show()}, stdout:\n{out.stdout}")
  out.stdout
}

fn scratch(name: str): str uses fs, ffi = t.temp("auk-dive-test-{name}")

/// Show `got` in full on a mismatch.
fn same(got: str, want: str) { t.check(got == want, "--- got:\n{got}\n--- want:\n{want}\n--- end") }

fn scripted_session() uses env, fs, ffi, time {
  t.skip_if_lacks("dive", "a scripted REPL session")
  let dir = scratch("session")
  let saved = paths.join(dir, "session.auk")
  let input = r"""
    1 + 2 * 3
    let xs = [1, 2, 3]
    xs.map(x => x * 2)
    fn sum_to(n: int): int {
      var t = 0
      for i in 1..=n {
        t += i
      }
      t
    }
    sum_to(10)
    struct Point { x: float, y: float }
    enum Shape { Circle(r: float), Rect(w: float, h: float) }
    fn area(Circle(r)): float = 3.0 * r * r
    fn area(Rect(w, h)): float = w * h
    area(Rect(2.0, 3.5))
    print("hello from a statement")
    let p = Point { x: 1.0, y: 2.0 }
    p
    "hi"
    xs.len() + "a"
    xs.len()
    let big = 9223372036854775807
    let boom = big + 1
    big
    :type xs.map(x => "{x}")
    :items
    :save SAVED
    :reset
    xs
    :quit
    1 + 1
    """.replace("SAVED", saved)
  let want = r"""
    7 : int
    [2, 4, 6] : [int]
    55 : int
    7.0 : float
    hello from a statement
    Point { x: 1.0, y: 2.0 } : Point
    "hi" : str
    dive:1:12: error[E0260]: can't apply `+` to `int` and `str`
      |
    1 | xs.len() + "a"
      |            ^^^
      = note: both sides of an arithmetic operator have the same type
      = help: run `auk explain E0260` for details
    3 : int
    panic: integer overflow in `+`
      at dive:1:12
    9223372036854775807 : int
    [str]
    fn sum_to(n: int): int
    struct Point { x: float, y: float }
    enum Shape { Circle(r: float), Rect(w: float, h: float) }
    fn area(Circle(r)): float  (2 clauses)
    saved SAVED
    session cleared
    dive:1:1: error[E0102]: unknown name `xs`
      |
    1 | xs
      | ^^
      = help: run `auk explain E0102` for details
    """.replace("SAVED", saved)
  same(dive(input), want)
  let file = t.read(saved)
  same(file, r"""
      fn sum_to(n: int): int {
        var t = 0
        for i in 1..=n {
          t += i
        }
        t
      }

      struct Point { x: float, y: float }

      enum Shape { Circle(r: float), Rect(w: float, h: float) }

      fn area(Circle(r)): float = 3.0 * r * r
      fn area(Rect(w, h)): float = w * h

      fn main(): ()! {
        let xs = [1, 2, 3]
        print("hello from a statement")
        let p = Point { x: 1.0, y: 2.0 }
        let big = 9223372036854775807
      }
      """)
  // The saved session is a program that checks, formats as is and runs.
  let fmt = t.auk().args(["fmt", "--check", saved]).output()
  t.check(fmt.success(), fmt.stderr)
  let run = t.auk().args(["run", saved]).output()
  assert run.stdout == "hello from a statement\n"
  t.rm_rf(dir)
}

fn clauses_redefinition_and_unshowable_values() uses env, ffi, time {
  t.skip_if_lacks("dive", "clauses and redefinitions in the REPL")
  let input = r"""
    fn fib(0): int = 0
    fn fib(1): int = 1
    fn fib(n: int): int = fib(n - 1) + fib(n - 2)
    fib(20)
    fn fib(n: int): int = n * 2
    fib(20)
    fn g(0): int = 0
    1 + 1
    let inc = (x: int) => x + 1
    inc
    var ys = [1]
    ys.push(2)
    ys.push(inc(2))
    ys
    let total =
      ys.sum()
    total
    """
  let want = r"""
    6765 : int
    40 : int
    dive:1:4: error[E0400]: the clauses of `g` don't cover every case: `g(_)` is not handled
      |
    1 | fn g(0): int = 0
      |    ^
      = note: add a clause for each missing case
      = fix: insert `
    fn g(_): int = ??` at 1:17
      = help: run `auk explain E0400` for details
    2 : int
    <fn> : (int) => int
    [1, 2, 3] : [int]
    6 : int
    """
  same(dive(input), want)
}

fn errors_map_to_the_input_lines_and_load_skips_main() uses env, fs, ffi, time {
  t.skip_if_lacks("dive", "errors and :load in the REPL")
  let dir = scratch("load")
  let lib = paths.join(dir, "lib.auk")
  t.write(lib, "fn double(x: int): int = x * 2\n\nfn main() {{\n  print(double(2))\n}}\n")
  let input = r"""
    :load LIB
    double(21)
    fn bad(x: int): int {
      let y = x + 1
      y + "s"
    }
    :items
    let s = [1,
      2,

    :help
    """.replace("LIB", lib)
  let out = dive(input)
  let want_head = r"""
    note: skipped `main` in LIB
    loaded LIB
    42 : int
    dive:3:7: error[E0260]: can't apply `+` to `int` and `str`
      |
    3 |   y + "s"
      |       ^^^
      = note: both sides of an arithmetic operator have the same type
      = help: run `auk explain E0260` for details
    fn double(x: int): int
    dive:1:9: error[E0012]: unclosed `[`
    """.replace("LIB", lib)
  t.check(out.starts_with(want_head), "--- got:\n{out}\n--- want prefix:\n{want_head}")
  t.check(out.contains("Each input compiles and runs a small native program"), out)
  t.rm_rf(dir)
}

fn bad_flag() uses env, ffi, time {
  t.skip_if_lacks("dive", "a bad `auk dive` flag")
  let out = t.auk().args(["dive", "--nope"]).output()
  assert out.code == some(2)
}

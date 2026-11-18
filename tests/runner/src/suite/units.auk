/// tests/units.rs: units of measure (`3.0<m/s>`, `float<kg*m/s^2>`): inference through
/// arithmetic, core functions and generics; every error (E0037, E0290-E0292); the `3<x` vs
/// `3 < x` lexing rule; `auk fmt`; interpolation and `to_value`; and erasure (the generated
/// program doesn't change).

pub fn tests(): [t.Test] uses env, fs, ffi, time = [
  t.test("arithmetic_infers_units", arithmetic_infers_units),
  t.test("core_functions_and_generics_carry_units", core_functions_and_generics_carry_units),
  t.test("mismatched_units_in_operators", mismatched_units_in_operators),
  t.test("mismatched_units_at_calls_returns_and_lets", mismatched_units_at_calls_returns_and_lets),
  t.test("powers_roots_and_malformed_units", powers_roots_and_malformed_units),
  t.test("a_unit_needs_an_attached_closed_bracket", a_unit_needs_an_attached_closed_bracket),
  t.test("fmt_round_trips_units", fmt_round_trips_units),
  t.test(
    "interpolation_shows_the_unit_and_values_drop_it",
    interpolation_shows_the_unit_and_values_drop_it,
  ),
  t.test("units_are_erased_in_codegen", units_are_erased_in_codegen),
  t.test(
    "the_physics_example_type_checks_its_formulas",
    the_physics_example_type_checks_its_formulas,
  ),
]

extern fn c_mkdtemp(t: ffi.Ptr): ffi.Ptr? = "char *mkdtemp(char *)"

/// A fresh, unique directory under the system's temporary directory (Rust's numbered
/// `auk-units-<pid>-<n>`).
fn uniq(prefix: str): str uses fs, ffi {
  let base = fs.temp_dir() else "/tmp"
  let tpl = paths.join(base.strip_suffix("/") else base, "{prefix}-{sys.pid()}-XXXXXX")
  let p = ffi.from_bytes(tpl.bytes() + [0])
  let r = c_mkdtemp(p)
  let d = ffi.cstr(p)
  ffi.free(p)
  if r is none { t.fail("mkdtemp {tpl} failed") }
  d
}

/// A fresh directory with `t.auk` holding `src`.
fn file(src: str): str uses fs, ffi {
  let path = paths.join(uniq("auk-units"), "t.auk")
  t.write(path, src)
  path
}

/// A JSON string field of `s` (as the Rust test reads it: from `"key":"` to the next
/// unescaped quote, `\x` as `x`).
fn field(s: str, key: str): str {
  let start = match s.find("\"{key}\":\"") {
    some(i) => i + key.len() + 4
    none => 0
  }
  var out: [char] = []
  var esc = false
  for c in s[start..s.len()].chars() {
    if esc {
      out.push(c)
      esc = false
    } else if c == '\\' {
      esc = true
    } else if c == '"' {
      break
    } else {
      out.push(c)
    }
  }
  str(out)
}

/// Rust's `trim_matches('"')`.
fn trim_quotes(s: str): str {
  var a = 0
  var b = s.len()
  while a < b && s[a] == '"' { a += 1 }
  while b > a && s[b - 1] == '"' { b -= 1 }
  s[a..b]
}

/// `auk check --json`: (code, message, notes) of every diagnostic.
fn diags(src: str): [(str, str, [str])] uses env, fs, ffi, time {
  let path = file(src)
  let report = t.auk().args(["check", path, "--json"]).output().stdout
  report.split("{{\"code\":").skip(1).map(d => {
    let d = "\"code\":{d}"
    let parts = d.split("\"notes\":[")
    let notes_part = if parts.len() > 1 { parts[1].split("]")[0] } else { "" }
    let notes = notes_part
      .split("\",\"")
      .map(n => trim_quotes(n).replace("\\\"", "\""))
      .filter(n => n != "")
    (field(d, "code"), field(d, "message"), notes)
  })
}

/// The diagnostic codes of `src`.
fn codes(src: str): [str] uses env, fs, ffi, time = diags(src).map(d => d.0)

/// The type the checker infers for `expr` after the `lets` (read from a deliberate mismatch).
fn type_of(lets: str, expr: str): str uses env, fs, ffi, time {
  let src = "fn main() {{\n{lets}\n  let probe: () = {expr}\n}}\n"
  let ds = diags(src)
  t.check(ds.len() == 1, "{src}\n{ds}")
  t.eq(ds[0].0, "E0200", "{src}\n{ds}")
  let m = ds[0].1
  match m.strip_prefix("expected `()`, found `") {
    some(rest) => match rest.strip_suffix("`") {
      some(ty) => ty
      none => t.bail("{ds[0]}")
    }
    none => t.bail("{ds[0]}")
  }
}

fn run(src: str): str uses env, fs, ffi, time {
  let path = file(src)
  let out = t.auk().args(["run", path]).output()
  t.check(out.success(), out.stderr)
  out.stdout
}

let LETS = "  let d = 3.0<m>\n  let t = 2.0<s>\n  let v = d / t\n  let n = 5<px>\n  let xs = [1.0<m>, 2.5<m>]"

fn ty(e: str): str uses env, fs, ffi, time = type_of(LETS, e)

fn arithmetic_infers_units() uses env, fs, ffi, time {
  t.eq(ty("d"), "float<m>", "")
  t.eq(ty("v"), "float<m/s>", "")
  t.eq(ty("v / t"), "float<m/s^2>", "m/s/s normalizes to m/s^2")
  t.eq(ty("d / t / t"), "float<m/s^2>", "")
  t.eq(ty("v * 4.0<s>"), "float<m>", "units cancel")
  t.eq(ty("d / d"), "float", "a ratio is dimensionless")
  t.eq(ty("2.0 * d"), "float<m>", "a plain number scales")
  t.eq(ty("d * 2.0"), "float<m>", "")
  t.eq(ty("d / 2.0"), "float<m>", "")
  t.eq(ty("1.0 / t"), "float<1/s>", "")
  t.eq(ty("d * 3.0<kg> / (t * t)"), "float<kg*m/s^2>", "base units sort by name")
  t.eq(ty("d ** 2.0"), "float<m^2>", "")
  t.eq(ty("t ** -1.0"), "float<1/s>", "")
  t.eq(ty("-d"), "float<m>", "")
  t.eq(ty("d + 0.0"), "float<m>", "zero fits any unit")
  t.eq(ty("0.0 - d"), "float<m>", "")
  t.eq(ty("d + 1.0<m>"), "float<m>", "")
  t.eq(ty("n * 2"), "int<px>", "")
  t.eq(ty("n % 3<px>"), "int<px>", "")
  t.eq(ty("3.0<m*m/m>"), "float<m>", "")
  t.eq(ty("3.0<1>"), "float", "`1` is dimensionless")
  t.eq(ty("d < 4.0<m>"), "bool", "")
}

fn core_functions_and_generics_carry_units() uses env, fs, ffi, time {
  t.eq(ty("xs"), "[float<m>]", "")
  t.eq(ty("xs.sum()"), "float<m>", "")
  t.eq(ty("xs.max()"), "float<m>?", "")
  t.eq(ty("xs.sort()"), "[float<m>]", "")
  t.eq(ty("xs.map(x => x * 2.0)"), "[float<m>]", "")
  t.eq(ty("xs.map(x => x / t)"), "[float<m/s>]", "")
  t.eq(ty("xs.first()"), "float<m>?", "")
  t.eq(ty("(d, t)"), "(float<m>, float<s>)", "")
  t.eq(ty("abs(-d)"), "float<m>", "")
  t.eq(ty("d.round()"), "float<m>", "")
  t.eq(ty("sqrt(d * d)"), "float<m>", "")
  t.eq(ty("float(d)"), "float", "`float(x)` strips the unit")
  t.eq(ty("int(d)"), "int", "")
  t.eq(ty("float(n)"), "float", "")
  t.eq(ty("int(n)"), "int", "")
  // a generic function and a struct field keep the unit
  let src = "struct Leg {{ dist: float<km> }}\nfn twice<T>(x: T): (T, T) = (x, x)\nfn main() {{\n  let l = Leg {{ dist: 2.0<km> }}\n  let probe: () = twice(l.dist)\n}}\n"
  t.eq(diags(src)[0].1, "expected `()`, found `(float<km>, float<km>)`", "")
  // a declared unit checks the body
  assert codes("fn speed(d: float<m>, t: float<s>): float<m/s> = d / t\nfn km(x: float<m>): float<km> = x / 1000.0<m/km>\nfn main() {{}}\n").len() ==
    0
}

fn one(src: str): (str, str, [str]) uses env, fs, ffi, time {
  let ds = diags(src)
  t.check(ds.len() == 1, "{src}\n{ds}")
  ds[0]
}

fn mismatched_units_in_operators() uses env, fs, ffi, time {
  let (c, m, n) = one("fn main() {{\n  let x = 3.0<m> + 1.0<s>\n}}\n")
  assert (c, m) == ("E0290", "can't combine `float<m>` and `float<s>` with `+`: the units differ")
  assert n == [
    "both sides need the same unit; convert one with a factor (a factor in `m/s` turns `s` into `m`)",
  ]
  let (c, m, n) = one("fn main() {{\n  let x = 3.0<m> + 1.0\n}}\n")
  assert (c, m) == ("E0290", "can't combine `float<m>` and `float` with `+`: the units differ")
  assert n == [
    "a plain number has no unit: write the literal with one (`2.0<m>`), or strip a unit with `float(x)`",
  ]
  let (c, m, n) = one("fn main() {{\n  let d = 3.0<m>\n  let x = d < d * d\n}}\n")
  assert (c, m) == ("E0290", "can't compare `float<m>` and `float<m^2>` with `<`: the units differ")
  assert n == ["they differ only in an exponent (`m` vs `m^2`)"]
  assert codes("fn main() {{\n  let x = 1.0 == 2.0<m>\n}}\n") == ["E0290"]
  assert codes("fn main() {{\n  let x = 5<px> - 1\n}}\n") == ["E0290"]
  assert codes("fn main() {{\n  var d = 1.0<m>\n  d += 1.0<s>\n}}\n") == ["E0290"]
  // zero fits any unit, on either side and in comparisons
  assert codes("fn main() {{\n  let d = 1.0<m>\n  let a = d + 0.0\n  let b = 0.0 < d\n  let c = d == 0.0\n}}\n").len() ==
    0
  // int and float still don't mix
  assert codes("fn main() {{\n  let x = 3.0<m> * 2\n}}\n") == ["E0260"]
}

fn mismatched_units_at_calls_returns_and_lets() uses env, fs, ffi, time {
  let ds = diags("fn speed(d: float<m>, t: float<s>): float<m/s> = d * t\nfn main() {{}}\n")
  assert ds.len() == 1
  assert ds[0].0 == "E0291"
  assert ds[0].1 == "expected `float<m/s>`, found `float<m*s>`: the units differ"
  assert ds[0].2 == [
    "they differ only in an exponent (`m*s` vs `m/s`)",
    "the function's return type says `float<m/s>`",
  ]
  let ds = diags("fn f(x: float) {{}}\nfn main() {{\n  f(2.0<m>)\n}}\n")
  assert (ds[0].0, ds[0].1) == ("E0291", "expected `float`, found `float<m>`: the units differ")
  assert ds[0].2 == ["`float(x)` / `int(x)` strip a unit when a plain number is meant"]
  let ds = diags("fn main() {{\n  let d: float<m> = 2.0\n}}\n")
  assert (ds[0].0, ds[0].1) == ("E0291", "expected `float<m>`, found `float`: the units differ")
  assert ds[0].2 ==
    ["a plain number has no unit; give it one (`2.0<m>`, or multiply by a value in `m`)"]
  let ds = diags("fn km(x: float<m>): float<km> = x\nfn main() {{}}\n")
  assert ds[0].2[0] ==
    "convert with a factor (a factor in `km/m` turns `m` into `km`), or fix the formula"
  assert codes("struct P {{ x: float<m> }}\nfn main() {{\n  let p = P {{ x: 1.0<s> }}\n}}\n") ==
    ["E0291"]
  assert codes("fn main() {{\n  var d = 1.0<m>\n  d *= d\n}}\n") == ["E0291"]
  assert codes("fn main() {{\n  let xs: [float<m>] = [1.0<s>]\n}}\n") == ["E0291"]
  // a plain literal zero takes the expected unit
  assert codes("fn main() {{\n  let d: float<m> = 0.0\n  var n: int<px> = 0\n}}\n").len() == 0
}

fn powers_roots_and_malformed_units() uses env, fs, ffi, time {
  let ds = diags("fn main() {{\n  let d = 3.0<m>\n  let n = 2.0\n  let x = d ** n\n}}\n")
  assert (ds[0].0, ds[0].1) ==
    ("E0292", "`**` on `float<m>` needs a literal integer exponent to know the result's unit")
  assert codes("fn main() {{\n  let x = 2.0 ** 1.0<s>\n}}\n") == ["E0292"]
  let ds = diags("fn main() {{\n  let x = sqrt(2.0<m>)\n}}\n")
  assert (ds[0].0, ds[0].1) == ("E0292", "`sqrt` of a `float<m>` has no unit: an exponent is odd")
  for (src, why) in [
    ("3.0<m*>", "the unit ends after an operator"),
    ("3.0<m^x>", "`^` needs an integer exponent, like `s^2` or `s^-1`"),
    ("3.0<m**2>", "expected a unit name or `1`, found `*`"),
    ("3.0<2>", "expected a unit name or `1`, found `2`"),
  ] {
    let ds = diags("fn main() {{\n  let x = {src}\n}}\n")
    t.check(ds.len() == 1, "{src}: {ds}")
    t.eq(ds[0].0, "E0037", src)
    t.eq(ds[0].1, "malformed unit of measure `{src[3..src.len()]}`: {why}", src)
  }
}

fn a_unit_needs_an_attached_closed_bracket() uses env, fs, ffi, time {
  t.skip_if_lacks("parse", "the AST of unit literals")
  // `<` right after a number (no space) with a `>` closing a unit on the same line is a unit;
  // anything else is a comparison, so no program that compiled before changes meaning
  let ast = (src: str) => {
    let path = file(src)
    let out = t.auk().args(["parse", "--ast", path]).output()
    t.check(out.success(), out.stderr)
    out.stdout
  }
  let a = ast("fn f(x: int): bool = 3<x\nfn g(x: int): bool = 3 < x\nfn h(x: int): bool = 0<x && x>2\nfn k(): float<m/s^2> = 3.0<m/s/s>\n")
  t.eq(
    a,
    "(fn f/1\n  (clause (params (x: int)) : bool = (< 3 x)))\n(fn g/1\n  (clause (params (x: int)) : bool = (< 3 x)))\n(fn h/1\n  (clause (params (x: int)) : bool = (&& (< 0 x) (> x 2))))\n(fn k/0\n  (clause (params) : float<m/s^2> = 3.0<m/s^2>))\n",
    "",
  )
  // with a space before `<` it is a comparison (here a chained one)
  assert codes("fn main() {{\n  let x = 1\n  let y = 3 <x> 2\n}}\n") == ["E0026"]
  assert codes("fn main() {{\n  let x = 1\n  let y = 3<x> 2\n}}\n") == ["E0025"]
}

fn fmt_round_trips_units() uses env, fs, ffi, time {
  let src = "fn h(d: float< m >, t: float<s>): float<m/s/s> = d / t / t\n\nfn main() {{\n  let x = 3.0<kg*m / s^2> + 0.0<m*kg/s/s>\n  let n = 5<px>\n}}\n"
  let path = file(src)
  let out = t.auk().args(["fmt", path]).output()
  t.check(out.success(), out.stderr)
  let formatted = t.read(path)
  t.eq(
    formatted,
    "fn h(d: float<m>, t: float<s>): float<m/s^2> = d / t / t\n\nfn main() {{\n  let x = 3.0<kg*m/s^2> + 0.0<kg*m/s^2>\n  let n = 5<px>\n}}\n",
    "",
  )
  let again = t.auk().args(["fmt", "--check", path]).output()
  t.check(again.success(), "formatting is idempotent")
  assert codes(formatted).len() == 0
}

fn interpolation_shows_the_unit_and_values_drop_it() uses env, fs, ffi, time {
  let out = run(r"""
    struct Leg { name: str, dist: float<km> }

    fn main() {
      let d = 3.0<m>
      let t = 2.0<s>
      let n = 5<px>
      print("{d} {d / t / t} {n} {d:.2} {d * 3.0<kg> / (t * t)} {float(d)} {d / d}")
      print(d)
      print(str(d))
      print(to_value(Leg { name: "a", dist: 1.5<km> }))
      print([1.0<m>, 2.0<m>])
    }
    """)
  t.eq(
    out,
    "3.0 m 0.75 m/s^2 5 px 3.00 m 2.25 kg*m/s^2 3.0 1.0\n3.0\n3.0\n{{\"name\": \"a\", \"dist\": 1.5}}\n[1.0, 2.0]\n",
    "",
  )
}

fn units_are_erased_in_codegen() uses env, fs, ffi, time {
  let with = r"""
    struct Body { mass: float<kg>, speed: float<m/s> }

    let g = 9.81<m/s^2>

    fn fall(h: float<m>): float<s> = sqrt(2.0 * h / g)

    fn energy(b: Body): float<kg*m^2/s^2> = 0.5 * b.mass * b.speed ** 2.0

    fn main() {
      let xs = [1.0<m>, 2.0<m>]
      let b = Body { mass: 2.0<kg>, speed: 3.0<m/s> }
      print(fall(xs.sum() + 0.0<m>))
      print(energy(b) > 1.0<kg*m^2/s^2>)
      print(xs.max()!)
      print(5<px> * 2)
      print(float(g))
    }
    """
  let without = with
    .replace("<kg>", "")
    .replace("<m/s>", "")
    .replace("<m/s^2>", "")
    .replace("<m>", "")
    .replace("<s>", "")
    .replace("<kg*m^2/s^2>", "")
    .replace("<px>", "")
  t.check(!without.contains("<"), without)
  let path = file("")
  let ir = (src: str) => {
    t.write(path, src)
    let out = t.auk().args(["ir", path]).output()
    t.check(out.success(), out.stderr)
    out.stdout
  }
  let (a, b) = (ir(with), ir(without))
  assert a.len() > 1000
  t.check(a == b, "the program with units compiles to the same IR as the program without them")
  assert run(with) == run(without)
}

fn the_physics_example_type_checks_its_formulas() uses env, fs, ffi, time {
  // swapping a `/` for `*` in a formula is caught by the units
  let src = t.read("examples/physics.auk")
  assert codes(src).len() == 0
  let broken = src.replace("sqrt(2.0 * h / g)", "sqrt(2.0 * h * g)")
  assert broken != src
  let ds = diags(broken)
  t.check(ds.len() == 1, "{ds}")
  t.eq(ds[0].1, "expected `float<s>`, found `float<m/s>`: the units differ", "")
}

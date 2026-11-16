//! Units of measure (`3.0<m/s>`, `float<kg*m/s^2>`): inference through arithmetic, core
//! functions and generics; every error (E0037, E0290-E0292); the `3<x` vs `3 < x` lexing rule;
//! `duck fmt`; interpolation and `to_value`; and erasure (the generated C doesn't change).

use std::fs;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::sync::atomic::{AtomicUsize, Ordering};

fn duck(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_duck")).args(args).output().unwrap()
}

/// A fresh directory with `t.duck` holding `src`.
fn file(src: &str) -> PathBuf {
    static N: AtomicUsize = AtomicUsize::new(0);
    let dir = std::env::temp_dir().join(format!("duck-units-{}-{}", std::process::id(), N.fetch_add(1, Ordering::SeqCst)));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    let path = dir.join("t.duck");
    fs::write(&path, src).unwrap();
    path
}

fn text(b: &[u8]) -> String {
    String::from_utf8_lossy(b).to_string()
}

/// `duck check --json`: (code, message, notes) of every diagnostic.
fn diags(src: &str) -> Vec<(String, String, Vec<String>)> {
    let path = file(src);
    let out = duck(&["check", path.to_str().unwrap(), "--json"]);
    let json = text(&out.stdout);
    let field = |s: &str, key: &str| -> String {
        let start = s.find(&format!("\"{key}\":\"")).map(|i| i + key.len() + 4).unwrap_or(0);
        let mut out = String::new();
        let mut esc = false;
        for c in s[start..].chars() {
            match (esc, c) {
                (true, c) => {
                    out.push(c);
                    esc = false;
                }
                (false, '\\') => esc = true,
                (false, '"') => break,
                (false, c) => out.push(c),
            }
        }
        out
    };
    json.split(r#"{"code":"#)
        .skip(1)
        .map(|d| {
            let d = format!(r#""code":{d}"#);
            let notes_part = d.split(r#""notes":["#).nth(1).and_then(|s| s.split(']').next()).unwrap_or("");
            let notes = notes_part.split(r#"",""#).map(|n| n.trim_matches('"').replace("\\\"", "\"")).filter(|n| !n.is_empty()).collect();
            (field(&d, "code"), field(&d, "message"), notes)
        })
        .collect()
}

/// The diagnostic codes of `src`.
fn codes(src: &str) -> Vec<String> {
    diags(src).into_iter().map(|d| d.0).collect()
}

/// The type the checker infers for `expr` after the `lets` (read from a deliberate mismatch).
fn type_of(lets: &str, expr: &str) -> String {
    let src = format!("fn main() {{\n{lets}\n  let probe: () = {expr}\n}}\n");
    let ds = diags(&src);
    assert_eq!(ds.len(), 1, "{src}\n{ds:?}");
    assert_eq!(ds[0].0, "E0200", "{src}\n{ds:?}");
    ds[0].1.strip_prefix("expected `()`, found `").and_then(|s| s.strip_suffix('`')).unwrap_or_else(|| panic!("{:?}", ds[0])).to_string()
}

fn run(src: &str) -> String {
    let path = file(src);
    let out = duck(&["run", path.to_str().unwrap()]);
    assert!(out.status.success(), "{}", text(&out.stderr));
    text(&out.stdout)
}

const LETS: &str = "  let d = 3.0<m>\n  let t = 2.0<s>\n  let v = d / t\n  let n = 5<px>\n  let xs = [1.0<m>, 2.5<m>]";

#[test]
fn arithmetic_infers_units() {
    let ty = |e: &str| type_of(LETS, e);
    assert_eq!(ty("d"), "float<m>");
    assert_eq!(ty("v"), "float<m/s>");
    assert_eq!(ty("v / t"), "float<m/s^2>", "m/s/s normalizes to m/s^2");
    assert_eq!(ty("d / t / t"), "float<m/s^2>");
    assert_eq!(ty("v * 4.0<s>"), "float<m>", "units cancel");
    assert_eq!(ty("d / d"), "float", "a ratio is dimensionless");
    assert_eq!(ty("2.0 * d"), "float<m>", "a plain number scales");
    assert_eq!(ty("d * 2.0"), "float<m>");
    assert_eq!(ty("d / 2.0"), "float<m>");
    assert_eq!(ty("1.0 / t"), "float<1/s>");
    assert_eq!(ty("d * 3.0<kg> / (t * t)"), "float<kg*m/s^2>", "base units sort by name");
    assert_eq!(ty("d ** 2.0"), "float<m^2>");
    assert_eq!(ty("t ** -1.0"), "float<1/s>");
    assert_eq!(ty("-d"), "float<m>");
    assert_eq!(ty("d + 0.0"), "float<m>", "zero fits any unit");
    assert_eq!(ty("0.0 - d"), "float<m>");
    assert_eq!(ty("d + 1.0<m>"), "float<m>");
    assert_eq!(ty("n * 2"), "int<px>");
    assert_eq!(ty("n % 3<px>"), "int<px>");
    assert_eq!(ty("3.0<m*m/m>"), "float<m>");
    assert_eq!(ty("3.0<1>"), "float", "`1` is dimensionless");
    assert_eq!(ty("d < 4.0<m>"), "bool");
}

#[test]
fn core_functions_and_generics_carry_units() {
    let ty = |e: &str| type_of(LETS, e);
    assert_eq!(ty("xs"), "[float<m>]");
    assert_eq!(ty("xs.sum()"), "float<m>");
    assert_eq!(ty("xs.max()"), "float<m>?");
    assert_eq!(ty("xs.sort()"), "[float<m>]");
    assert_eq!(ty("xs.map(x => x * 2.0)"), "[float<m>]");
    assert_eq!(ty("xs.map(x => x / t)"), "[float<m/s>]");
    assert_eq!(ty("xs.first()"), "float<m>?");
    assert_eq!(ty("(d, t)"), "(float<m>, float<s>)");
    assert_eq!(ty("abs(-d)"), "float<m>");
    assert_eq!(ty("d.round()"), "float<m>");
    assert_eq!(ty("sqrt(d * d)"), "float<m>");
    assert_eq!(ty("float(d)"), "float", "`float(x)` strips the unit");
    assert_eq!(ty("int(d)"), "int");
    assert_eq!(ty("float(n)"), "float");
    assert_eq!(ty("int(n)"), "int");
    // a generic function and a struct field keep the unit
    let src = "struct Leg { dist: float<km> }\nfn twice<T>(x: T): (T, T) = (x, x)\nfn main() {\n  let l = Leg { dist: 2.0<km> }\n  let probe: () = twice(l.dist)\n}\n";
    assert_eq!(diags(src)[0].1, "expected `()`, found `(float<km>, float<km>)`");
    // a declared unit checks the body
    assert!(codes("fn speed(d: float<m>, t: float<s>): float<m/s> = d / t\nfn km(x: float<m>): float<km> = x / 1000.0<m/km>\nfn main() {}\n").is_empty());
}

#[test]
fn mismatched_units_in_operators() {
    let one = |src: &str| {
        let ds = diags(src);
        assert_eq!(ds.len(), 1, "{src}\n{ds:?}");
        ds.into_iter().next().unwrap()
    };
    let (c, m, n) = one("fn main() {\n  let x = 3.0<m> + 1.0<s>\n}\n");
    assert_eq!((c.as_str(), m.as_str()), ("E0290", "can't combine `float<m>` and `float<s>` with `+`: the units differ"));
    assert_eq!(n, ["both sides need the same unit; convert one with a factor (a factor in `m/s` turns `s` into `m`)"]);
    let (c, m, n) = one("fn main() {\n  let x = 3.0<m> + 1.0\n}\n");
    assert_eq!((c.as_str(), m.as_str()), ("E0290", "can't combine `float<m>` and `float` with `+`: the units differ"));
    assert_eq!(n, ["a plain number has no unit: write the literal with one (`2.0<m>`), or strip a unit with `float(x)`"]);
    let (c, m, n) = one("fn main() {\n  let d = 3.0<m>\n  let x = d < d * d\n}\n");
    assert_eq!((c.as_str(), m.as_str()), ("E0290", "can't compare `float<m>` and `float<m^2>` with `<`: the units differ"));
    assert_eq!(n, ["they differ only in an exponent (`m` vs `m^2`)"]);
    assert_eq!(codes("fn main() {\n  let x = 1.0 == 2.0<m>\n}\n"), ["E0290"]);
    assert_eq!(codes("fn main() {\n  let x = 5<px> - 1\n}\n"), ["E0290"]);
    assert_eq!(codes("fn main() {\n  var d = 1.0<m>\n  d += 1.0<s>\n}\n"), ["E0290"]);
    // zero fits any unit, on either side and in comparisons
    assert!(codes("fn main() {\n  let d = 1.0<m>\n  let a = d + 0.0\n  let b = 0.0 < d\n  let c = d == 0.0\n}\n").is_empty());
    // int and float still don't mix
    assert_eq!(codes("fn main() {\n  let x = 3.0<m> * 2\n}\n"), ["E0260"]);
}

#[test]
fn mismatched_units_at_calls_returns_and_lets() {
    let ds = diags("fn speed(d: float<m>, t: float<s>): float<m/s> = d * t\nfn main() {}\n");
    assert_eq!(ds.len(), 1);
    assert_eq!(ds[0].0, "E0291");
    assert_eq!(ds[0].1, "expected `float<m/s>`, found `float<m*s>`: the units differ");
    assert_eq!(ds[0].2, ["they differ only in an exponent (`m*s` vs `m/s`)", "the function's return type says `float<m/s>`"]);
    let ds = diags("fn f(x: float) {}\nfn main() {\n  f(2.0<m>)\n}\n");
    assert_eq!((ds[0].0.as_str(), ds[0].1.as_str()), ("E0291", "expected `float`, found `float<m>`: the units differ"));
    assert_eq!(ds[0].2, ["`float(x)` / `int(x)` strip a unit when a plain number is meant"]);
    let ds = diags("fn main() {\n  let d: float<m> = 2.0\n}\n");
    assert_eq!((ds[0].0.as_str(), ds[0].1.as_str()), ("E0291", "expected `float<m>`, found `float`: the units differ"));
    assert_eq!(ds[0].2, ["a plain number has no unit; give it one (`2.0<m>`, or multiply by a value in `m`)"]);
    let ds = diags("fn km(x: float<m>): float<km> = x\nfn main() {}\n");
    assert_eq!(ds[0].2[0], "convert with a factor (a factor in `km/m` turns `m` into `km`), or fix the formula");
    assert_eq!(codes("struct P { x: float<m> }\nfn main() {\n  let p = P { x: 1.0<s> }\n}\n"), ["E0291"]);
    assert_eq!(codes("fn main() {\n  var d = 1.0<m>\n  d *= d\n}\n"), ["E0291"]);
    assert_eq!(codes("fn main() {\n  let xs: [float<m>] = [1.0<s>]\n}\n"), ["E0291"]);
    // a plain literal zero takes the expected unit
    assert!(codes("fn main() {\n  let d: float<m> = 0.0\n  var n: int<px> = 0\n}\n").is_empty());
}

#[test]
fn powers_roots_and_malformed_units() {
    let ds = diags("fn main() {\n  let d = 3.0<m>\n  let n = 2.0\n  let x = d ** n\n}\n");
    assert_eq!((ds[0].0.as_str(), ds[0].1.as_str()), ("E0292", "`**` on `float<m>` needs a literal integer exponent to know the result's unit"));
    assert_eq!(codes("fn main() {\n  let x = 2.0 ** 1.0<s>\n}\n"), ["E0292"]);
    let ds = diags("fn main() {\n  let x = sqrt(2.0<m>)\n}\n");
    assert_eq!((ds[0].0.as_str(), ds[0].1.as_str()), ("E0292", "`sqrt` of a `float<m>` has no unit: an exponent is odd"));
    for (src, why) in [
        ("3.0<m*>", "the unit ends after an operator"),
        ("3.0<m^x>", "`^` needs an integer exponent, like `s^2` or `s^-1`"),
        ("3.0<m**2>", "expected a unit name or `1`, found `*`"),
        ("3.0<2>", "expected a unit name or `1`, found `2`"),
    ] {
        let ds = diags(&format!("fn main() {{\n  let x = {src}\n}}\n"));
        assert_eq!(ds.len(), 1, "{src}: {ds:?}");
        assert_eq!(ds[0].0, "E0037", "{src}");
        assert_eq!(ds[0].1, format!("malformed unit of measure `{}`: {why}", &src[3..]), "{src}");
    }
}

#[test]
fn a_unit_needs_an_attached_closed_bracket() {
    // `<` right after a number (no space) with a `>` closing a unit on the same line is a unit;
    // anything else is a comparison, so no program that compiled before changes meaning
    let ast = |src: &str| {
        let path = file(src);
        let out = duck(&["parse", "--ast", path.to_str().unwrap()]);
        assert!(out.status.success(), "{}", text(&out.stderr));
        text(&out.stdout)
    };
    let a = ast("fn f(x: int): bool = 3<x\nfn g(x: int): bool = 3 < x\nfn h(x: int): bool = 0<x && x>2\nfn k(): float<m/s^2> = 3.0<m/s/s>\n");
    assert_eq!(
        a,
        "(fn f/1\n  (clause (params (x: int)) : bool = (< 3 x)))\n(fn g/1\n  (clause (params (x: int)) : bool = (< 3 x)))\n(fn h/1\n  (clause (params (x: int)) : bool = (&& (< 0 x) (> x 2))))\n(fn k/0\n  (clause (params) : float<m/s^2> = 3.0<m/s^2>))\n"
    );
    // with a space before `<` it is a comparison (here a chained one)
    assert_eq!(codes("fn main() {\n  let x = 1\n  let y = 3 <x> 2\n}\n"), ["E0026"]);
    assert_eq!(codes("fn main() {\n  let x = 1\n  let y = 3<x> 2\n}\n"), ["E0025"]);
}

#[test]
fn fmt_round_trips_units() {
    let src = "fn h(d: float< m >, t: float<s>): float<m/s/s> = d / t / t\n\nfn main() {\n  let x = 3.0<kg*m / s^2> + 0.0<m*kg/s/s>\n  let n = 5<px>\n}\n";
    let path = file(src);
    let out = duck(&["fmt", path.to_str().unwrap()]);
    assert!(out.status.success(), "{}", text(&out.stderr));
    let formatted = fs::read_to_string(&path).unwrap();
    assert_eq!(
        formatted,
        "fn h(d: float<m>, t: float<s>): float<m/s^2> = d / t / t\n\nfn main() {\n  let x = 3.0<kg*m/s^2> + 0.0<kg*m/s^2>\n  let n = 5<px>\n}\n"
    );
    let again = duck(&["fmt", "--check", path.to_str().unwrap()]);
    assert!(again.status.success(), "formatting is idempotent");
    assert!(codes(&formatted).is_empty());
}

#[test]
fn interpolation_shows_the_unit_and_values_drop_it() {
    let out = run(r#"struct Leg { name: str, dist: float<km> }

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
"#);
    assert_eq!(out, "3.0 m 0.75 m/s^2 5 px 3.00 m 2.25 kg*m/s^2 3.0 1.0\n3.0\n3.0\n{\"name\": \"a\", \"dist\": 1.5}\n[1.0, 2.0]\n");
}

#[test]
fn units_are_erased_in_codegen() {
    let with = "struct Body { mass: float<kg>, speed: float<m/s> }

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
";
    let without = with
        .replace("<kg>", "")
        .replace("<m/s>", "")
        .replace("<m/s^2>", "")
        .replace("<m>", "")
        .replace("<s>", "")
        .replace("<kg*m^2/s^2>", "")
        .replace("<px>", "");
    assert!(!without.contains('<'), "{without}");
    let path = file("");
    let ir = |src: &str| {
        fs::write(&path, src).unwrap();
        let out = duck(&["ir", path.to_str().unwrap()]);
        assert!(out.status.success(), "{}", text(&out.stderr));
        text(&out.stdout)
    };
    let (a, b) = (ir(with), ir(&without));
    assert!(a.len() > 1000);
    assert_eq!(a, b, "the C for a program with units is the C for the same program without them");
    assert_eq!(run(with), run(&without));
}

#[test]
fn the_physics_example_type_checks_its_formulas() {
    // swapping a `/` for `*` in a formula is caught by the units
    let src = fs::read_to_string("examples/physics.duck").unwrap();
    assert!(codes(&src).is_empty());
    let broken = src.replace("sqrt(2.0 * h / g)", "sqrt(2.0 * h * g)");
    assert_ne!(broken, src);
    let ds = diags(&broken);
    assert_eq!(ds.len(), 1, "{ds:?}");
    assert_eq!(ds[0].1, "expected `float<s>`, found `float<m/s>`: the units differ");
}

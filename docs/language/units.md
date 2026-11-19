# Units of measure

A number can carry a unit. The compiler tracks units through arithmetic and rejects a formula
whose units don't work out. Units exist only at compile time: at run time a `float<m/s>` is a
plain 64-bit float, with no cost.

```auk
let g = 9.81<m/s^2>

fn fall_time(h: float<m>): float<s> = sqrt(2.0 * h / g)
fn speed(d: float<m>, t: float<s>): float<m/s> = d / t

fn main() {
  let d = 100.0<m>
  let t = 9.58<s>
  print("{speed(d, t):.2}")        // 10.44 m/s
  print("{fall_time(20.0<m>):.2}") // 2.02 s
  print("{d + 5.0<m>}")            // 105.0 m
}
```

Write the wrong formula and it doesn't compile:

```console
u.auk:1:50: error[E0291]: expected `float<m/s>`, found `float<m*s>`: the units differ
  |
1 | fn speed(d: float<m>, t: float<s>): float<m/s> = d * t
  |                                                  ^^^^^
  = note: they differ only in an exponent (`m*s` vs `m/s`)
  = note: the function's return type says `float<m/s>`
```

## Writing units

- A literal: `3.0<m>`, `9.81<m/s^2>`, `3<items>`. There is no space before the `<`.
- A type: `float<m>`, `int<items>`, `float<kg*m^2/s^2>`.
- Unit names are yours to choose. Nothing is declared and nothing is built in: `m`, `px`,
  `usd` and `items` are all just names.

## The rules

```auk
let d = 100.0<m>
let t = 8.0<s>

print("{d + 20.0<m>}")       // 120.0 m: + - and comparisons need equal units
print("{d / t}")             // 12.5 m/s: * and / combine units
print("{d * 2.0}")           // 200.0 m: a plain number only scales
print("{d / 4.0<m>}")        // 25.0: equal units cancel to a plain number
print("{(d * d).sqrt()}")    // 100.0 m: sqrt halves the exponents
print(d > 50.0<m>)           // true
print(float(d) + 1.0)        // 101.0: float(x) drops the unit

let none_yet: float<m> = 0.0 // zero fits any unit; any other plain number does not
print("{none_yet}")          // 0.0 m
```

- `d + t` is an error (E0290): metres and seconds don't add.
- Passing a `float<s>` where a `float<m>` parameter is expected is an error (E0291), and so is
  passing a plain `float`.
- Interpolation prints the unit (`"{d}"` is `100.0 m`); `print(d)` and `str(d)` give the bare
  number.

## Converting between units

A conversion is a multiplication by a factor that has both units:

```auk
fn km(x: float<m>): float<km> = x / 1000.0<m/km>

fn main() {
  let legs = [1200.0<m>, 800.0<m>, 2500.0<m>]
  print("{km(legs.sum())}")     // 4.5 km
  print("{legs.max()!}")        // 2500.0 m: collections keep units
}
```

Keeping the factor in one small function means the number `1000` and its direction appear
once, and the compiler checks every use.

## Where units help

Units work on fields, parameters, results, lists and maps, anywhere a type is written:

```auk
struct Body { name: str, mass: float<kg>, speed: float<m/s> }

fn kinetic(b: Body): float<kg*m^2/s^2> = 0.5 * b.mass * b.speed ** 2.0

fn main() {
  print("{kinetic(Body { name: "ball", mass: 0.45<kg>, speed: 12.0<m/s> }):.1}")   // 32.4 kg*m^2/s^2
}
```

They are just as useful away from physics, wherever two numbers of the same type must not be
confused: `int<px>` and `int<cells>` in layout code, `int<ms>` and `int<s>` for timeouts,
`float<usd>` and `float<eur>` for money, `int<bytes>` and `int<chars>` in text handling.

`examples/physics.auk` is a complete program built this way.

Next: [Concurrency](concurrency.md).

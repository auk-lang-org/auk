# num

Exact decimal arithmetic for money, prices, quantities and anything else that has to add up to the cent, plus integer helpers (`gcd`, `lcm`, `pow_mod`). A `Dec` is an arbitrary-precision integer coefficient with a decimal scale. `+ - *` are always exact and never overflow. Only division and rounding drop digits, and they use the rounding mode you pick. Cross-checked against Python's `decimal` module.

**Effects:** none.

```auk
fn main(): int! {
  let price = num.dec("19.99")?
  let qty = num.from_int(3)
  let rate = num.dec("0.0825")?                             // sales tax
  let subtotal = price * qty                                // 59.97
  let tax = num.round(subtotal * rate, 2)                   // 4.947525 -> 4.95 (half-even)
  let total = subtotal + tax
  print("{subtotal} + {tax} = {total}")                     // 59.97 + 4.95 = 64.92
  assert num.dec("0.1")? + num.dec("0.2")? == num.dec("0.3")?   // exact, unlike float
  let share = num.div(total, num.from_int(4), 2, num.Down)  // 16.23
  let cents = num.to_int(num.round(total, 2) * num.from_int(100))?   // 6492, for storage
  print(num.scaled(cents, 2))                               // 64.92
  print(num.dec("2.5")? / num.dec("3")?)                    // 0.833333333333333333
  print(num.pow_mod(4, 13, 497))                            // 445
  0
}
```

## API
Types:
- `struct Dec { neg, mag, scale }`: the value `±coefficient / 10^scale`, where `mag` holds the coefficient as base-10^9 limbs. Create values with the functions below, not by hand.
- `enum Round { HalfEven, HalfUp, HalfDown, Down, Up, Floor, Ceiling }`: `HalfEven` is banker's rounding, where ties go to the even digit. `HalfUp` and `HalfDown` send ties away from zero and toward zero. `Down` truncates toward zero, and `Up` rounds away from zero. `Floor` and `Ceiling` round toward -∞ and +∞.
- `enum NumErr { BadChar(at: int, c: char), NoDigits, ExpRange(at: int), Overflow }`, and `message(e): str`.

Making and reading:
- `dec(s): Dec!NumErr`: `"19.99"`, `"-0.50"`, `".5"`, `"5."`, `"1.5e3"`, `"2E-4"`. The scale is the number of fraction digits as written, so `dec("1.50")` keeps two places. It accepts no spaces, `_`, `,`, `inf` or `nan`. Exponents are limited to ±`MAX_EXP` (1000).
- `from_int(n): Dec` (exact for every `int`), `scaled(coef, scale): Dec` (`scaled(1999, 2)` is `19.99`), `ZERO`
- `show(d)`, i.e. `"{d}"`: plain digits that keep the scale (`19.90`, `-0.005`, `1000`). There's no exponent and no grouping.
- `to_int(d): int!NumErr` truncates toward zero and fails with `Overflow` outside the 64-bit range. `to_float(d): float` gives the nearest float.
- `sign(d)` (-1, 0 or 1), `is_zero(d)`, `neg(d)`, `abs(d)`, `normalize(d)` (drops trailing fraction zeros: `1.500` → `1.5`)

Arithmetic (the operators come from `add`, `sub`, `mul`, `div`, `mod`, `cmp` and `eq`):
- `a + b`, `a - b`: exact. The result has the larger of the two scales.
- `a * b`: exact. The scales add (`1.5 * 2.25 == 3.375`), so `round` it back to cents.
- `div(a, b, places, mode): Dec`: the quotient with exactly `places` fraction digits. This is the one to use for money.
- `a / b`: computed to `DIV_PLACES` (18) fraction digits with half-even rounding. Trailing zeros are then dropped down to the larger input scale, so `10.00 / 4 == 2.50` and `1 / 8 == 0.125`, but `1 / 3 == 0.333333333333333333`.
- `a % b`: the remainder of truncating division, with the sign of `a` (as `%` works on `int`).
- `round(d, places)` (half-even) and `round(d, places, mode)`: exactly `places` digits. Asking for more places than `d` has pads it with zeros.
- `pow(d, n)` (exact, `n >= 0`), `sum(xs: [Dec])` (core's `xs.sum()` covers only `int` and `float`)
- `==`, `<`, `sort`, `min`, `max`: numeric order that ignores scale, so `dec("1.5") == dec("1.50")`.

Integers:
- `gcd(a, b)` (always >= 0, and `gcd(0, 0) == 0`), `lcm(a, b)` (always >= 0, and 0 if either argument is 0)
- `pow_mod(base, exp, m)` and `mul_mod(a, b, m)`: results in `0..m`. A negative `base` is reduced first. Neither function overflows for any `m > 0`: products of large values go through an add-and-double loop.

## Range and overflow
- **`Dec` never overflows.** The coefficient grows as needed: `9223372036854775807 + 1` is `9223372036854775808`, and `2^100` is exact. Each operation's cost grows with its digit count, and the code is tuned for money-sized values (up to a few dozen digits). Division of very long numbers, thousands of digits, is slow but correct.
- **The 64-bit limit applies only where a `Dec` becomes an `int`:** `to_int` returns `Err(Overflow)` instead of wrapping. `scaled` and `from_int` take any `int`.
- **Parsing is bounded:** exponents beyond ±1000 are rejected (`ExpRange`), so a short string like `1e999999999` can't allocate a billion digits.
- **Division by zero** in `/`, `%` or `div` fails a contract (a panic), as with `int`.
- **`int` helpers trap like `int` does:** `lcm` panics if the result exceeds 2^63 - 1, and `gcd` does so only for `gcd(int.MIN, 0)` and `gcd(int.MIN, int.MIN)`, whose answer is 2^63. `pow_mod` and `mul_mod` never overflow.

## Notes
- `==` is numeric, but the hash used by maps and `unique` still sees the scale. Normalize values before you use them as keys: `m[num.normalize(price)] = …`.
- Unary minus can't be overloaded in Auk, so write `x.neg()` or `num.ZERO - x`.
- `to_value`/`from_value` (and so `json.encode`/`decode`) use the derived struct form `{"neg", "mag", "scale"}`. For a readable JSON field, store `"{d}"` as a `str` and `num.dec` it back.
- `Big` integers (planned) would reuse the same limb arithmetic. They aren't in 0.1.

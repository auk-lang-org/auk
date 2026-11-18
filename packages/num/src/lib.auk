/// Exact decimal arithmetic for money and other base-10 quantities (`Dec`), plus integer helpers
/// (`gcd`, `lcm`, `pow_mod`). Pure: no effects. A `Dec` is an arbitrary-precision integer
/// coefficient and a decimal scale, so `+ - *` are always exact and never overflow; only `/`
/// and `round` lose digits, and they do it in a rounding mode you choose.

/// A decimal number: `(-1 if neg) * coefficient / 10^scale`. The coefficient is stored as
/// little-endian base-10^9 limbs in `mag` (no leading zero limbs; zero is `[]` and never
/// negative), and `scale >= 0` counts the digits after the point. Make values with `dec`,
/// `from_int` or `scaled` rather than by hand.
///
/// The scale is kept: `dec("1.50")` shows as `1.50`, and `a + b` has the larger scale of the two.
/// `==` and `<` compare numerically (`1.5 == 1.50`). Because the derived hash still sees the
/// scale, `normalize` values before using them as map keys or in `unique`.
pub struct Dec { neg: bool, mag: [int], scale: int }

/// How `div` and `round` drop digits. `HalfEven` (banker's rounding) is the default for `/` and
/// for `round(d, places)`; it has no upward bias over many roundings.
pub enum Round {
  HalfEven,  // to nearest; a tie goes to the even neighbour (2.5 -> 2, 3.5 -> 4)
  HalfUp,    // to nearest; a tie goes away from zero (2.5 -> 3, -2.5 -> -3)
  HalfDown,  // to nearest; a tie goes toward zero (2.5 -> 2, -2.5 -> -2)
  Down,      // toward zero, i.e. truncate (2.9 -> 2, -2.9 -> -2)
  Up,        // away from zero (2.1 -> 3, -2.1 -> -3)
  Floor,     // toward negative infinity (2.9 -> 2, -2.1 -> -3)
  Ceiling,   // toward positive infinity (2.1 -> 3, -2.9 -> -2)
}

/// Why parsing or a conversion failed. `at` is a 0-based char index into the input.
pub enum NumErr {
  BadChar(at: int, c: char),  // not part of a number
  NoDigits,                   // "", "-", ".", "1e"
  ExpRange(at: int),          // an exponent beyond +-MAX_EXP
  Overflow,                   // `to_int` of a value outside the 64-bit range
}

/// A one-line description of an error, e.g. `bad char 'x' at 3`.
pub fn message(e: NumErr): str
fn message(BadChar(at, c)): str = "bad char '{c}' at {at}"
fn message(NoDigits): str = "no digits"
fn message(ExpRange(at)): str = "exponent out of range at {at} (limit {MAX_EXP})"
fn message(Overflow): str = "value does not fit in a 64-bit int"

/// The largest exponent magnitude `dec` accepts (`1e1000`, `1e-1000`). Arithmetic itself has no
/// limit; this only stops a short string from asking for a huge number.
pub let MAX_EXP = 1000

/// The number of fraction digits `a / b` computes before rounding (half-even).
pub let DIV_PLACES = 18

let BASE = 1_000_000_000  // limb base, 10^9: a limb product fits an int with room for carries
let POW10 = [1, 10, 100, 1000, 10_000, 100_000, 1_000_000, 10_000_000, 100_000_000]

// ---- limb arithmetic on magnitudes (little-endian base 10^9, no leading zeros) ----

fn trim(xs: [int]): [int] {
  var n = xs.len()
  while n > 0 && xs[n - 1] == 0 { n -= 1 }
  if n == xs.len() { xs } else { xs.take(n) }
}

fn mag_cmp(a: [int], b: [int]): int {
  if a.len() != b.len() { return a.len() - b.len() }
  var i = a.len() - 1
  while i >= 0 {
    if a[i] != b[i] { return a[i] - b[i] }
    i -= 1
  }
  0
}

fn mag_add(a: [int], b: [int]): [int] {
  var out: [int] = []
  var carry = 0
  for i in 0..imax(a.len(), b.len()) {
    let s = (a.get(i) else 0) + (b.get(i) else 0) + carry
    out.push(s % BASE)
    carry = s / BASE
  }
  if carry > 0 { out.push(carry) }
  out
}

// a - b, for a >= b
fn mag_sub(a: [int], b: [int]): [int] {
  var out: [int] = []
  var borrow = 0
  for i in 0..a.len() {
    var s = a[i] - (b.get(i) else 0) - borrow
    borrow = 0
    if s < 0 {
      s += BASE
      borrow = 1
    }
    out.push(s)
  }
  trim(out)
}

// a * k for 0 <= k <= BASE
fn mag_mul_small(a: [int], k: int): [int] {
  if k == 0 { return [] }
  var out: [int] = []
  var carry = 0
  for x in a {
    let p = x * k + carry
    out.push(p % BASE)
    carry = p / BASE
  }
  while carry > 0 {
    out.push(carry % BASE)
    carry /= BASE
  }
  out
}

fn mag_mul(a: [int], b: [int]): [int] {
  if a.len() == 0 || b.len() == 0 { return [] }
  var out: [int] = []
  for _ in 0..a.len() + b.len() { out.push(0) }
  for i in 0..a.len() {
    var carry = 0
    let x = a[i]
    for j in 0..b.len() {
      let t = out[i + j] + x * b[j] + carry
      out[i + j] = t % BASE
      carry = t / BASE
    }
    var k = i + b.len()
    while carry > 0 {
      let t = out[k] + carry
      out[k] = t % BASE
      carry = t / BASE
      k += 1
    }
  }
  trim(out)
}

// a * 10^k, k >= 0
fn mag_shift(a: [int], k: int): [int] {
  if a.len() == 0 || k == 0 { return a }
  var out: [int] = []
  for _ in 0..k / 9 { out.push(0) }
  out + mag_mul_small(a, POW10[k % 9])
}

fn pow10(k: int): [int] = mag_shift([1], k)

// (a / b, a % b) for b != 0: schoolbook long division, one limb of quotient at a time, each
// found by binary search (b * q <= remainder).
fn mag_divmod(a: [int], b: [int]): ([int], [int]) {
  if mag_cmp(a, b) < 0 { return ([], a) }
  if b.len() == 1 { return mag_divmod_small(a, b[0]) }
  var q: [int] = []
  for _ in 0..a.len() { q.push(0) }
  var r: [int] = []
  var i = a.len() - 1
  while i >= 0 {
    r = trim([a[i]] + r)  // r = r * BASE + a[i]
    if mag_cmp(r, b) >= 0 {
      var lo = 1
      var hi = BASE - 1
      while lo < hi {
        let mid = (lo + hi + 1) / 2
        if mag_cmp(mag_mul_small(b, mid), r) <= 0 { lo = mid } else { hi = mid - 1 }
      }
      q[i] = lo
      r = mag_sub(r, mag_mul_small(b, lo))
    }
    i -= 1
  }
  (trim(q), r)
}

fn mag_divmod_small(a: [int], k: int): ([int], [int]) {
  var q: [int] = []
  for _ in 0..a.len() { q.push(0) }
  var rem = 0
  var i = a.len() - 1
  while i >= 0 {
    let cur = rem * BASE + a[i]  // < k * BASE <= 10^18
    q[i] = cur / k
    rem = cur % k
    i -= 1
  }
  (trim(q), trim([rem]))
}

fn imax(a: int, b: int): int = if a > b { a } else { b }

fn mag_is_odd(a: [int]): bool = a.len() > 0 && a[0] % 2 == 1

// The decimal digits of a magnitude ("0" for zero).
fn mag_str(a: [int]): str {
  if a.len() == 0 { return "0" }
  var parts = ["{a[a.len() - 1]}"]
  var i = a.len() - 2
  while i >= 0 {
    parts.push("{a[i]:09}")
    i -= 1
  }
  parts.join("")
}

// A magnitude from ASCII digits (already validated).
fn mag_of_digits(ds: [char]): [int] {
  var out: [int] = []
  var end = ds.len()
  while end > 0 {
    let start = imax(end - 9, 0)
    var v = 0
    for i in start..end { v = v * 10 + int(ds[i]) - int('0') }
    out.push(v)
    end = start
  }
  trim(out)
}

// ---- construction ----

fn make(neg: bool, mag: [int], scale: int): Dec = Dec { neg: neg && mag.len() > 0, mag, scale }

/// Zero (scale 0).
pub let ZERO = Dec { neg: false, mag: [], scale: 0 }

/// An integer as a `Dec` (scale 0). Every `int`, including the minimum, converts exactly.
pub fn from_int(n: int): Dec {
  var out: [int] = []
  var x = n
  while x != 0 {
    out.push((x % BASE).abs())  // `%` keeps the sign of `x`; `/` truncates toward 0
    x /= BASE
  }
  make(n < 0, out, 0)
}

/// `coef / 10^scale`, the natural way to load stored minor units: `scaled(1999, 2)` is `19.99`.
pub fn scaled(coef: int, scale: int): Dec
  requires scale >= 0
{
  Dec { scale, ..from_int(coef) }
}

/// Parses a decimal: an optional sign, digits with an optional `.` (`12`, `-0.50`, `.5`, `5.`),
/// and an optional exponent (`1.5e3`, `2E-4`). The scale is the number of fraction digits minus
/// the exponent (never below 0), so `dec("19.990")` keeps three places and `dec("1e3")` is
/// `1000`. No spaces, `_`, `,`, `inf` or `nan`.
pub fn dec(s: str): Dec!NumErr {
  let cs = s.chars()
  var i = 0
  var neg = false
  if i < cs.len() && (cs[i] == '-' || cs[i] == '+') {
    neg = cs[i] == '-'
    i += 1
  }
  var digits: [char] = []
  var frac = 0
  var seen_dot = false
  while i < cs.len() && (cs[i].is_digit() || (cs[i] == '.' && !seen_dot)) {
    if cs[i] == '.' {
      seen_dot = true
    } else {
      digits.push(cs[i])
      if seen_dot { frac += 1 }
    }
    i += 1
  }
  if digits.len() == 0 {
    if i < cs.len() { fail(BadChar(i, cs[i])) }
    fail(NoDigits)
  }
  var exp = 0
  if i < cs.len() && (cs[i] == 'e' || cs[i] == 'E') {
    i += 1
    let at = i
    var eneg = false
    if i < cs.len() && (cs[i] == '-' || cs[i] == '+') {
      eneg = cs[i] == '-'
      i += 1
    }
    if i >= cs.len() { fail(NoDigits) }
    while i < cs.len() && cs[i].is_digit() {
      exp = exp * 10 + int(cs[i]) - int('0')
      if exp > MAX_EXP { fail(ExpRange(at)) }
      i += 1
    }
    if eneg { exp = -exp }
  }
  if i < cs.len() { fail(BadChar(i, cs[i])) }
  let mag = mag_of_digits(digits)
  let scale = frac - exp
  if scale < 0 { make(neg, mag_shift(mag, -scale), 0) } else { make(neg, mag, scale) }
}

// ---- reading ----

/// The decimal text, keeping the scale: `19.99`, `-0.50`, `1000`, `0.000`. No exponent, no
/// grouping. `"{d}"` gives the same.
pub fn show(d: Dec): str {
  let ds = mag_str(d.mag)
  let sign = if d.neg { "-" } else { "" }
  if d.scale == 0 { return sign + ds }
  let padded = if ds.len() <= d.scale { "0".repeat(d.scale - ds.len() + 1) + ds } else { ds }
  let cut = padded.len() - d.scale
  "{sign}{padded[0..cut]}.{padded[cut..padded.len()]}"
}

/// The nearest `float` (through its decimal text, so `0.1` gives the float `0.1`).
pub fn to_float(d: Dec): float = float.parse(show(d))!

/// The integer part (truncated toward zero), or `Overflow` outside the 64-bit range.
pub fn to_int(d: Dec): int!NumErr {
  let m = mag_shift_down(d.mag, d.scale)
  var v = 0
  var i = m.len() - 1
  // accumulate negatively: the negative range is one larger
  while i >= 0 {
    if v < (-9_223_372_036_854_775_807 - 1 + m[i]) / BASE { fail(Overflow) }
    v = v * BASE - m[i]
    i -= 1
  }
  if d.neg { return v }
  if v == -9_223_372_036_854_775_807 - 1 { fail(Overflow) }
  -v
}

// a / 10^k, truncated
fn mag_shift_down(a: [int], k: int): [int] = if k == 0 { a } else { mag_divmod(a, pow10(k)).0 }

/// -1, 0 or 1.
pub fn sign(d: Dec): int = if d.mag.len() == 0 { 0 } else if d.neg { -1 } else { 1 }

pub fn is_zero(d: Dec): bool = d.mag.len() == 0

/// `-d` (unary minus can't be overloaded, so this is a function: `x.neg()`).
pub fn neg(d: Dec): Dec = make(!d.neg, d.mag, d.scale)

pub fn abs(d: Dec): Dec = Dec { neg: false, ..d }

/// The same value with trailing fraction zeros removed: `1.500` -> `1.5`, `2.00` -> `2`.
pub fn normalize(d: Dec): Dec {
  var m = d.mag
  var s = d.scale
  while s > 0 && m.len() > 0 && m[0] % 10 == 0 {
    m = mag_divmod_small(m, 10).0
    s -= 1
  }
  make(d.neg, m, if m.len() == 0 { 0 } else { s })
}

// ---- arithmetic ----

// Both coefficients at the larger scale.
fn align(a: Dec, b: Dec): ([int], [int], int) {
  let s = imax(a.scale, b.scale)
  (mag_shift(a.mag, s - a.scale), mag_shift(b.mag, s - b.scale), s)
}

/// `a + b`, exact; the result has the larger of the two scales.
pub fn add(a: Dec, b: Dec): Dec {
  let (x, y, s) = align(a, b)
  if a.neg == b.neg { return make(a.neg, mag_add(x, y), s) }
  let c = mag_cmp(x, y)
  if c >= 0 { make(a.neg, mag_sub(x, y), s) } else { make(b.neg, mag_sub(y, x), s) }
}

/// `a - b`, exact; the result has the larger of the two scales.
pub fn sub(a: Dec, b: Dec): Dec = add(a, neg(b))

/// `a * b`, exact; the scale is the sum of the scales (`1.5 * 2.25 == 3.375`). Use `round` to
/// bring it back to, say, cents.
pub fn mul(a: Dec, b: Dec): Dec = make(a.neg != b.neg, mag_mul(a.mag, b.mag), a.scale + b.scale)

/// `a / b`: computed to `DIV_PLACES` (18) fraction digits with `HalfEven`, then trailing zeros
/// are dropped down to the larger input scale, so an exact quotient stays short
/// (`10.00 / 4 == 2.50`, `1 / 8 == 0.125`, `1 / 3 == 0.333333333333333333`). For money, prefer
/// `div(a, b, places, mode)` and say what you want. Panics if `b` is zero, like `int` division.
pub fn div(a: Dec, b: Dec): Dec {
  let keep = imax(a.scale, b.scale)
  let q = div(a, b, imax(keep, DIV_PLACES), HalfEven)
  var m = q.mag
  var s = q.scale
  while s > keep && m.len() > 0 && m[0] % 10 == 0 {
    m = mag_divmod_small(m, 10).0
    s -= 1
  }
  make(q.neg, m, if m.len() == 0 { keep } else { s })
}

/// `a / b` rounded to exactly `places` fraction digits with `mode`:
/// `div(dec("10")?, dec("3")?, 2, HalfEven)` is `3.33`.
pub fn div(a: Dec, b: Dec, places: int, mode: Round): Dec
  requires !is_zero(b)
  requires places >= 0
{
  // a/b * 10^places = A * 10^(places + sb - sa) / B
  let e = places + b.scale - a.scale
  let n = if e >= 0 { mag_shift(a.mag, e) } else { a.mag }
  let d = if e >= 0 { b.mag } else { mag_shift(b.mag, -e) }
  let neg = a.neg != b.neg
  make(neg, round_quot(n, d, neg, mode), places)
}

/// The remainder of truncating division, with the sign of `a` (like `%` on `int`):
/// `dec("7.5")? % dec("2")? == dec("1.5")?`. Panics if `b` is zero.
pub fn mod(a: Dec, b: Dec): Dec
  requires !is_zero(b)
{
  let (x, y, s) = align(a, b)
  make(a.neg, mag_divmod(x, y).1, s)
}

/// `d` to the power `n` (n >= 0), exact: `pow(dec("1.1")?, 2) == dec("1.21")?`.
pub fn pow(d: Dec, n: int): Dec
  requires n >= 0
{
  var result = from_int(1)
  var base = d
  var k = n
  while k > 0 {
    if k % 2 == 1 { result = mul(result, base) }
    k /= 2
    if k > 0 { base = mul(base, base) }
  }
  result
}

/// `d` rounded to `places` fraction digits with banker's rounding (`HalfEven`):
/// `round(dec("2.345")?, 2) == dec("2.34")?`. Asking for more places than `d` has pads zeros.
pub fn round(d: Dec, places: int): Dec = round(d, places, HalfEven)

/// `d` with exactly `places` fraction digits, rounding with `mode` if digits are dropped.
pub fn round(d: Dec, places: int, mode: Round): Dec
  requires places >= 0
{
  if places >= d.scale { return make(d.neg, mag_shift(d.mag, places - d.scale), places) }
  make(d.neg, round_quot(d.mag, pow10(d.scale - places), d.neg, mode), places)
}

// n / d rounded to an integer magnitude; `neg` is the sign of the true quotient.
fn round_quot(n: [int], d: [int], neg: bool, mode: Round): [int] {
  let (q, r) = mag_divmod(n, d)
  if r.len() == 0 { return q }
  let half = mag_cmp(mag_add(r, r), d)  // compare the remainder with d / 2
  let bump = match mode {
    Down => false
    Up => true
    Floor => neg
    Ceiling => !neg
    HalfUp => half >= 0
    HalfDown => half > 0
    HalfEven => half > 0 || (half == 0 && mag_is_odd(q))
  }
  if bump { mag_add(q, [1]) } else { q }
}

/// Numeric order (negative, 0 or positive), ignoring scale, so `<`, `sort`, `min` and `max`
/// work: `dec("1.50")? == dec("1.5")?`.
pub fn cmp(a: Dec, b: Dec): int {
  let sa = sign(a)
  let sb = sign(b)
  if sa != sb { return sa - sb }
  let (x, y, _) = align(a, b)
  let c = mag_cmp(x, y)
  let unit = if c < 0 { -1 } else if c > 0 { 1 } else { 0 }
  if sa < 0 { -unit } else { unit }
}

/// Numeric equality, ignoring scale (`1.5 == 1.50`). This is what `==` uses.
pub fn eq(a: Dec, b: Dec): bool = cmp(a, b) == 0

/// The sum of a list (`ZERO` for an empty one). Core's `sum` covers only `int` and `float`.
pub fn sum(xs: [Dec]): Dec = xs.reduce(ZERO, (acc, x) => add(acc, x))

// ---- integers ----

/// The greatest common divisor, always >= 0; `gcd(0, 0) == 0`. Panics (overflow) only when the
/// answer is 2^63: `gcd(int.MIN, 0)` or `gcd(int.MIN, int.MIN)`.
pub fn gcd(a: int, b: int): int {
  var x = a
  var y = b
  while y != 0 {
    let t = x % y
    x = y
    y = t
  }
  x.abs()
}

/// The least common multiple, always >= 0; 0 if either is 0. Panics on overflow, like `*`.
pub fn lcm(a: int, b: int): int {
  if a == 0 || b == 0 { return 0 }
  (a / gcd(a, b) * b).abs()
}

/// `(a * b) mod m` in `0..m`, without overflowing for any `m > 0`.
pub fn mul_mod(a: int, b: int, m: int): int
  requires m > 0
{
  var x = norm_mod(a, m)
  var y = norm_mod(b, m)
  if m <= 3_037_000_499 { return x * y % m }  // both < m, so the product fits
  var r = 0
  while y > 0 {
    if y % 2 == 1 { r = add_mod(r, x, m) }
    x = add_mod(x, x, m)
    y /= 2
  }
  r
}

/// `base^exp mod m` in `0..m`, by square-and-multiply; never overflows. `exp >= 0`, `m > 0`;
/// a negative `base` is reduced first, and `pow_mod(b, 0, 1) == 0`.
pub fn pow_mod(base: int, exp: int, m: int): int
  requires exp >= 0 && m > 0
{
  var result = 1 % m
  var b = norm_mod(base, m)
  var e = exp
  while e > 0 {
    if e % 2 == 1 { result = mul_mod(result, b, m) }
    b = mul_mod(b, b, m)
    e /= 2
  }
  result
}

fn norm_mod(a: int, m: int): int {
  let r = a % m
  if r < 0 { r + m } else { r }
}

// (x + y) mod m for x, y in 0..m, without overflow
fn add_mod(x: int, y: int, m: int): int = if x >= m - y { x - (m - y) } else { x + y }

// ---- tests ----

fn d(s: str): Dec = dec(s)!

test "parse and show" {
  for s in [
    "0",
    "1",
    "-1",
    "19.99",
    "-0.50",
    "0.000",
    "1000",
    "123456789012345678901234567890.123",
  ] {
    assert show(d(s)) == s
  }
  assert "{d("+7")}" == "7"
  assert "{d(".5")}" == "0.5"
  assert "{d("5.")}" == "5"
  assert "{d("-0")}" == "0"  // no negative zero
  assert "{d("-0.00")}" == "0.00"
  assert "{d("007.10")}" == "7.10"
  assert "{d("1e3")}" == "1000"
  assert "{d("1.5E3")}" == "1500"
  assert "{d("1.5e1")}" == "15"
  assert "{d("2e-4")}" == "0.0002"
  assert "{d("12.5e-1")}" == "1.25"
  assert "{d("1e+2")}" == "100"
  assert "{d("0.000000000000000000000000000001")}" == "0.000000000000000000000000000001"
  assert d("19.99").scale == 2 && d("19.99").mag == [1999]
  assert d("1000000000").mag == [0, 1]
}

test "parse errors" {
  assert dec("") is err(NoDigits)
  assert dec("-") is err(NoDigits)
  assert dec(".") is err(NoDigits)
  assert dec("1e") is err(NoDigits)
  assert dec("1e-") is err(NoDigits)
  assert dec("abc") is err(BadChar(0, 'a'))
  assert dec("1.2.3") is err(BadChar(3, '.'))
  assert dec(" 1") is err(BadChar(0, ' '))
  assert dec("1 ") is err(BadChar(1, ' '))
  assert dec("1,000") is err(BadChar(1, ','))
  assert dec("--1") is err(BadChar(1, '-'))
  assert dec("1e5x") is err(BadChar(3, 'x'))
  assert dec("1e1001") is err(ExpRange(2))
  assert dec("1e-1001") is err(ExpRange(2))
  assert "{d("1e1000")}".len() == 1001
  assert message(BadChar(3, 'x')) == "bad char 'x' at 3"
  assert message(Overflow) == "value does not fit in a 64-bit int"
}

test "float traps are exact" {
  assert d("0.1") + d("0.2") == d("0.3")
  assert "{d("0.1") + d("0.2")}" == "0.3"
  assert 0.1 + 0.2 != 0.3  // the float version, for contrast
  var total = ZERO
  for _ in 0..10 { total = total + d("0.1") }
  assert total == from_int(1) && "{total}" == "1.0"
  assert d("1.1") * d("1.1") == d("1.21")
  assert d("3") * d("0.1") == d("0.3")
  assert d("1.0") - d("0.9") == d("0.1")
  assert d("100") - d("99.99") == d("0.01")
  assert sum([d("19.99"), d("5.01"), d("0.10")]) == d("25.10")
  assert "{sum([])}" == "0"
}

test "add, sub, mul: signs and scales" {
  assert "{d("1.5") + d("2.25")}" == "3.75"
  assert "{d("1.50") + d("2")}" == "3.50"  // the larger scale wins
  assert "{d("-1.5") + d("2.25")}" == "0.75"
  assert "{d("1.5") + d("-2.25")}" == "-0.75"
  assert "{d("-1.5") + d("-2.25")}" == "-3.75"
  assert "{d("2.25") - d("2.25")}" == "0.00"
  assert "{d("-3") - d("-5")}" == "2"
  assert "{d("1.5") * d("2.25")}" == "3.375"  // scales add
  assert "{d("-1.5") * d("2")}" == "-3.0"
  assert "{d("-1.5") * d("-2")}" == "3.0"
  assert "{d("0") * d("-2")}" == "0"
  assert "{neg(d("2.5"))} {neg(ZERO)} {abs(d("-2.5"))}" == "-2.5 0 2.5"
  assert "{pow(d("1.1"), 2)} {pow(d("2"), 0)} {pow(d("-0.5"), 3)}" == "1.21 1 -0.125"
  assert "{pow(d("2"), 100)}" == "1267650600228229401496703205376"
}

test "no overflow: big coefficients stay exact" {
  // one past int's maximum, and products far beyond 64 bits
  let big = from_int(9_223_372_036_854_775_807)
  assert "{big + from_int(1)}" == "9223372036854775808"
  assert "{big * big}" == "85070591730234615847396907784232501249"
  assert "{from_int(-9_223_372_036_854_775_807 - 1)}" == "-9223372036854775808"
  assert "{d("99999999999999999999.99") + d("0.01")}" == "100000000000000000000.00"
  assert d("12345678901234567890.123") * d("1000") - d("12345678901234567890123") == ZERO
  // limb boundaries
  assert "{d("999999999") + d("1")}" == "1000000000"
  assert "{d("1000000000") - d("1")}" == "999999999"
  assert "{d("999999999999999999") * d("999999999999999999")}" ==
    "999999999999999998000000000000000001"
  // conversion back to int is where the 64-bit range applies
  assert to_int(big) is ok(9_223_372_036_854_775_807)
  assert to_int(big + from_int(1)) is err(Overflow)
  assert to_int(neg(big) - from_int(1))? == -9_223_372_036_854_775_807 - 1
  assert to_int(neg(big) - from_int(2)) is err(Overflow)
  assert to_int(d("-12.99")) is ok(-12)
  assert to_int(d("0.5")) is ok(0)
  assert to_int(d("1e30")) is err(Overflow)
}

test "division with an explicit scale and mode" {
  assert "{div(d("10"), d("3"), 2, HalfEven)}" == "3.33"
  assert "{div(d("20"), d("3"), 2, HalfEven)}" == "6.67"
  assert "{div(d("-20"), d("3"), 2, HalfEven)}" == "-6.67"
  assert "{div(d("1"), d("8"), 2, HalfEven)}" == "0.12"  // 0.125: tie to even
  assert "{div(d("3"), d("8"), 2, HalfEven)}" == "0.38"  // 0.375: tie to even
  assert "{div(d("1"), d("8"), 2, HalfUp)}" == "0.13"
  assert "{div(d("-1"), d("8"), 2, HalfUp)}" == "-0.13"
  assert "{div(d("1"), d("8"), 2, HalfDown)}" == "0.12"
  assert "{div(d("2"), d("3"), 0, Down)}" == "0"
  assert "{div(d("2"), d("3"), 0, Up)}" == "1"
  assert "{div(d("-2"), d("3"), 0, Floor)}" == "-1"
  assert "{div(d("-2"), d("3"), 0, Ceiling)}" == "0"
  assert "{div(d("1.00"), d("0.03"), 4, HalfEven)}" == "33.3333"
  assert "{div(d("7"), d("0.5"), 0, Down)}" == "14"
  assert "{div(d("123.456"), d("1"), 1, HalfEven)}" == "123.5"  // fewer places than the input
  assert "{div(d("6"), d("2"), 3, Down)}" == "3.000"
  // a multi-limb divisor
  assert "{div(d("1"), d("12345678901234567890"), 30, HalfEven)}" ==
    "0.000000000000000000081000000729"
  assert "{div(d("152415787532388367504953515625"), d("123456789012345"), 0, Down)}" ==
    "1234567890123463"
}

test "the / and % operators" {
  assert "{d("10.00") / d("4")}" == "2.50"  // exact: trimmed to the input scale
  assert "{d("1") / d("8")}" == "0.125"
  assert "{d("1") / d("3")}" == "0.333333333333333333"
  assert "{d("2") / d("3")}" == "0.666666666666666667"
  assert "{d("-1") / d("3")}" == "-0.333333333333333333"
  assert "{d("6") / d("3")}" == "2"
  assert "{d("0") / d("3.0")}" == "0.0"
  assert d("1") / d("3") * d("3") != d("1")  // 18 places, not infinite precision
  assert "{d("7.5") % d("2")}" == "1.5"
  assert "{d("-7.5") % d("2")}" == "-1.5"
  assert "{d("7") % d("-2")}" == "1"
  assert "{d("0.3") % d("0.1")}" == "0.0"
}

test "cross-checked against Python's decimal module" {
  // "a b a+b a-b a*b places mode div(a,b,places,mode) a%b", from Python's `decimal` at 500 digits
  let rows = [
    "-750476357633517326.0 -9.08 -750476357633517335.08 -750476357633517316.92 6814325327312337320.080 0 HalfEven 82651581237171512 -6.12",
    "1754640288995955206917007.86091 0.9603082462 1754640288995955206917008.8212182462 1754640288995955206917006.9006017538 1684995538637566903648229.927862095636042 20 HalfUp 1827163617452184705520659.37357979130097362690 0.3587517542",
    "-750829545519.2199351819 730573909.86579 -750098971609.3541451819 -751560119429.0857251819 -548536476712730654891.652736728237201 4 Down -1027.7256 -530140087.0536051819",
    "-200980329511.3 -964199182854.5749118625 -1165179512365.8749118625 763218853343.2749118625 193785069484638667134815.40519779625 9 Floor 0.208442750 -200980329511.3000000000",
    "1501392826566174073872884 403728195825623183.97 1501393230294369899496067.97 1501392422837978248249700.03 606154617095094232759778757536576477126469.48 9 Up 3718820.835626379 337365930064861568.60",
    "4 4 8 0 16 9 Ceiling 1.000000000 0",
    "976614537807.50752917034236671276 -72118.46563 976614465689.04189917034236671276 976614609925.97315917034236671276 -70431941978629067.2984375583891070381424388 2 HalfDown -13541809.71 50872.98285917034236671276",
    "-86313.3 36953.02 -49360.28 -123266.32 -3189537101.166 4 HalfEven -2.3358 -12407.26",
    "990592406871355693.8 -0.86666 990592406871355692.93334 990592406871355694.66666 -858506815339129125.588708 9 HalfUp -1143000031005648920.914776268 0.79280",
    "0.1 1038737653782541257614155485942036841209.0 1038737653782541257614155485942036841209.1 -1038737653782541257614155485942036841208.9 103873765378254125761415548594203684120.90 20 Down 0.00000000000000000000 0.1",
    "9.01 -7043955674868288983041393.7 -7043955674868288983041384.69 7043955674868288983041402.71 -63466040630563283737202957.237 9 Floor -0.000000001 9.01",
    "-1069887743256727838472609534857252214411.54728 626235165620323557.0 -1069887743256727838471983299691631890854.54728 -1069887743256727838473235770022872537968.54728 -670001328093531165773704156984155185673396869685998870603.274960 4 Up -1708444051041017071909.9690 -606791927936554098.54728",
    "4.85253888539336338750 -211566542930.95755 -211566542926.10501111460663661250 211566542935.81008888539336338750 -1026634876420.7159136683173904867006250 0 Ceiling 0 4.85253888539336338750",
    "211211639.53799 8876190162784088033786916147316407719438.16372651676122202972 8876190162784088033786916147316618931077.70171651676122202972 -8876190162784088033786916147316196507798.62573651676122202972 1874754677132605582412633457527286944109540908808.4906019052924377508490628 20 HalfDown 0.00000000000000000000 211211639.53799000000000000000",
  ]
  for row in rows {
    let [a, b, sum, diff, prod, places, mode, quot, rem] = row.split(" ") else fail("bad row")
    let m = [HalfEven, HalfUp, HalfDown, Down, Up, Floor, Ceiling].find(x => "{x}" == mode)!
    assert "{d(a) + d(b)}" == sum
    assert "{d(a) - d(b)}" == diff
    assert "{d(a) * d(b)}" == prod
    assert "{div(d(a), d(b), int.parse(places)!, m)}" == quot
    assert "{d(a) % d(b)}" == rem
  }
}

test "banker's rounding" {
  let cases = [
    ("0.5", "0"),
    ("1.5", "2"),
    ("2.5", "2"),
    ("3.5", "4"),
    ("-0.5", "0"),
    ("-1.5", "-2"),
    ("-2.5", "-2"),
    ("2.51", "3"),
    ("2.49", "2"),
  ]
  for (x, want) in cases { assert "{round(d(x), 0)}" == want }
  assert "{round(d("2.345"), 2)}" == "2.34"
  assert "{round(d("2.355"), 2)}" == "2.36"
  assert "{round(d("2.3450001"), 2)}" == "2.35"  // not a tie
  // rounding many ties: half-even has no drift, half-up does
  let ties = ["0.005", "0.015", "0.025", "0.035", "0.045", "0.055", "0.065", "0.075"]
  let exact = sum(ties.map(s => d(s)))
  assert "{exact}" == "0.320"
  assert "{sum(ties.map(s => round(d(s), 2)))}" == "0.32"
  assert "{sum(ties.map(s => round(d(s), 2, HalfUp)))}" == "0.36"
}

test "round: every mode" {
  let modes = [HalfEven, HalfUp, HalfDown, Down, Up, Floor, Ceiling]
  let table = [
    ("2.5", ["2", "3", "2", "2", "3", "2", "3"]),
    ("-2.5", ["-2", "-3", "-2", "-2", "-3", "-3", "-2"]),
    ("2.1", ["2", "2", "2", "2", "3", "2", "3"]),
    ("-2.9", ["-3", "-3", "-3", "-2", "-3", "-3", "-2"]),
    ("2.0", ["2", "2", "2", "2", "2", "2", "2"]),
    ("-0.1", ["0", "0", "0", "0", "-1", "-1", "0"]),
  ]
  for (x, wants) in table {
    for i, m in modes { assert "{round(d(x), 0, m)}" == wants[i] }
  }
  assert "{round(d("1.5"), 3)}" == "1.500"  // more places pads
  assert "{round(d("-0.004"), 2)}" == "0.00"
  assert "{round(d("999.995"), 2, HalfUp)}" == "1000.00"
}

test "comparison and Ord" {
  assert d("1.5") == d("1.50") && d("1.5") != d("1.51")
  assert d("0") == d("-0.000")
  assert d("-1") < d("0") && d("0") < d("0.001") && d("-2") < d("-1.5")
  assert d("10") > d("9.99") && d("1.10") >= d("1.1") && d("1.1") <= d("1.10")
  let xs = [d("3"), d("-1.5"), d("0.25"), d("2.50"), d("-10")]
  assert xs.sort().map(x => "{x}") == ["-10", "-1.5", "0.25", "2.50", "3"]
  assert xs.max() == some(d("3")) && xs.min() == some(d("-10"))
  assert sign(d("-0.1")) == -1 && sign(ZERO) == 0 && sign(d("5")) == 1
  assert is_zero(d("0.00")) && !is_zero(d("0.01"))
}

test "normalize, scaled, from_int, to_float" {
  assert "{normalize(d("1.500"))} {normalize(d("2.00"))} {normalize(d("0.000"))}" == "1.5 2 0"
  assert "{normalize(d("100"))}" == "100"  // only fraction zeros go
  assert "{scaled(1999, 2)} {scaled(-5, 3)} {scaled(0, 2)}" == "19.99 -0.005 0.00"
  assert "{from_int(-42)} {from_int(0)}" == "-42 0"
  assert to_float(d("0.1")) == 0.1 && to_float(d("-2.5")) == -2.5
  // normalized values work as map keys
  var m: {Dec: int} = {}
  m[normalize(d("1.50"))] = 1
  assert m.get(normalize(d("1.5"))) == some(1)
}

test "Data round trip" {
  let x = d("-12.345")
  let back: Dec = from_value(to_value(x))?
  assert back == x && "{back}" == "-12.345"
}

test "gcd and lcm" {
  assert (gcd(12, 18), gcd(-12, 18), gcd(12, -18), gcd(0, 5), gcd(5, 0), gcd(0, 0)) ==
    (6, 6, 6, 5, 5, 0)
  assert gcd(17, 31) == 1
  assert gcd(-9_223_372_036_854_775_807 - 1, 6) == 2
  assert (lcm(4, 6), lcm(-4, 6), lcm(0, 6), lcm(7, 1)) == (12, 12, 0, 7)
  assert lcm(1 << 31, 1 << 30) == 1 << 31
}

test "pow_mod" {
  assert pow_mod(2, 10, 1000) == 24
  assert pow_mod(3, 0, 7) == 1
  assert pow_mod(5, 3, 1) == 0
  assert pow_mod(-2, 3, 5) == 2  // -8 mod 5
  assert pow_mod(0, 0, 7) == 1
  // Fermat: a^(p-1) = 1 mod p, with a modulus near 2^61 that would overflow a naive multiply
  let p = (1 << 61) - 1  // a Mersenne prime
  assert pow_mod(3, p - 1, p) == 1
  assert pow_mod(123_456_789, p - 1, p) == 1
  assert pow_mod(2, 61, p) == 1
  let big = 9_223_372_036_854_775_783  // the largest prime below 2^63
  assert pow_mod(2, big - 1, big) == 1
  assert mul_mod(big - 1, big - 1, big) == 1  // (-1)^2
  assert mul_mod(-1, 5, 7) == 2
}

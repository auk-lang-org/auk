/// `int.parse`.

/// An optional sign and decimal digits (`_` allowed between digits); no surrounding whitespace.
pub extern fn parse(s: str): int! = "auk_int_parse"

/// Digits in base `radix` (2 to 36; letters in either case past 9), with an optional sign and
/// `_` between digits: `int.parse("ff", 16)` is 255. No prefix such as `0x`.
pub fn parse(s: str, radix: int): int! {
  if radix < 2 || radix > 36 { fail("int.parse: radix {radix} is not between 2 and 36") }
  let cs = s.chars()
  var i = 0
  var neg = false
  if cs.len() > 0 && (cs[0] == '-' || cs[0] == '+') {
    neg = cs[0] == '-'
    i = 1
  }
  if i >= cs.len() { fail("int.parse: invalid base-{radix} int \"{s}\"") }
  // accumulated as a negative number, which reaches the smallest int
  let min = -9223372036854775807 - 1
  var acc = 0
  var prev_digit = false
  while i < cs.len() {
    let c = cs[i]
    if c == '_' && prev_digit && i + 1 < cs.len() && cs[i + 1].is_digit(radix) {
      prev_digit = false
      i += 1
      continue
    }
    if !c.is_digit(radix) { fail("int.parse: invalid base-{radix} int \"{s}\"") }
    let d = digit(c)
    if acc < (min + d) / radix { fail("int.parse: \"{s}\" is out of range") }
    acc = acc * radix - d
    prev_digit = true
    i += 1
  }
  if neg { return acc }
  if acc == min { fail("int.parse: \"{s}\" is out of range") }
  -acc
}

/// The value of the digit `c` (`is_digit` said yes).
fn digit(c: char): int = if c <= '9' {
  int(c) - int('0')
} else if c >= 'a' {
  int(c) - int('a') + 10
} else {
  int(c) - int('A') + 10
}

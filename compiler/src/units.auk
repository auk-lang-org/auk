/// Units of measure (the parsing half of src/units.rs): the text between `<` and `>` in
/// canonical form, base names sorted with non-zero integer exponents.

/// Parse `kg*m/s^2`: names or `1`, joined by `*` and `/` (left to right), each optionally
/// raised to an integer power `^n` (`n` may be negative). Fails with the reason.
pub fn parse(src: str): [(str, int)]! {
  var toks: [str] = []
  let cs = src.chars()
  var i = 0
  while i < cs.len() {
    let c = cs[i]
    if c == ' ' {
      i += 1
    } else if lexer.is_alphanumeric(c) || c == '_' {
      let from = i
      while i < cs.len() && (lexer.is_alphanumeric(cs[i]) || cs[i] == '_') { i += 1 }
      toks.push(str(cs[from..i]))
    } else {
      toks.push(str(c))
      i += 1
    }
  }
  if toks.len() == 0 { fail("the unit is empty") }
  var v: [(str, int)] = []
  var sign = 1
  var k = 0
  loop {
    let t = toks.get(k) else fail("the unit ends after an operator")
    k += 1
    var name: str? = none
    if t != "1" {
      let c0 = t.chars()[0]
      if !lexer.is_alphabetic(c0) && c0 != '_' { fail("expected a unit name or `1`, found `{t}`") }
      name = t
    }
    var e = 1
    if toks.get(k) == some("^") {
      k += 1
      let neg = toks.get(k) == some("-")
      if neg { k += 1 }
      let n = parse_i32(
        toks.get(k) else "",
      ) else fail("`^` needs an integer exponent, like `s^2` or `s^-1`")
      k += 1
      e = if neg { -n } else { n }
    }
    match name {
      some(n) => v.push((n, sign * e))
      none => {}
    }
    match toks.get(k) {
      none => break
      some("*") => sign = 1
      some("/") => sign = -1
      some(t) => fail("unexpected `{t}` in a unit (units use names, `*`, `/` and `^n`)")
    }
    k += 1
  }
  var out: [(str, int)] = []
  for (n, e) in v {
    match out.find_index(x => x.0 == n) {
      some(j) => out[j] = (n, out[j].1 + e)
      none => out.push((n, e))
    }
  }
  out.filter(x => x.1 != 0).sort()
}

/// Rust's `str::parse::<i32>` for a token of name characters.
fn parse_i32(t: str): int? {
  let cs = t.chars()
  if cs.len() == 0 || cs.len() > 10 { return none }
  var n = 0
  for c in cs {
    if !lexer.is_ascii_digit(c) { return none }
    n = n * 10 + int(c) - int('0')
  }
  if n > 2147483647 { none } else { n }
}

let numerals = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]

fn to_roman(n: int): str
  requires n >= 1 && n <= 3999
{
  var left = n
  var out = ""
  for (v, s) in numerals {
    while left >= v {
      out = out + s
      left -= v
    }
  }
  out
}

fn digit(c: char): int = match c {
  'I' => 1, 'V' => 5, 'X' => 10, 'L' => 50, 'C' => 100, 'D' => 500, 'M' => 1000, _ => 0
}

fn from_roman(s: str): int? {
  let cs = s.chars()
  var total = 0
  for i, c in cs {
    let v = digit(c)
    if v == 0 { return none }
    if i + 1 < cs.len() && digit(cs[i + 1]) > v { total -= v } else { total += v }
  }
  if total < 1 || total > 3999 || to_roman(total) != s { return none }
  some(total)
}

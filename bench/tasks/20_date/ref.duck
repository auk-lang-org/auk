fn num(cs: [char]): int? {
  var n = 0
  for c in cs {
    if c < '0' || c > '9' { return none }
    n = n * 10 + (int(c) - int('0'))
  }
  some(n)
}

fn is_valid_date(s: str): bool {
  let cs = s.chars()
  if cs.len() != 10 || cs[4] != '-' || cs[7] != '-' { return false }
  let y = num(cs[0..4]) else return false
  let m = num(cs[5..7]) else return false
  let d = num(cs[8..10]) else return false
  if y < 1 || m < 1 || m > 12 || d < 1 { return false }
  let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
  let days = [31, if leap { 29 } else { 28 }, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  d <= days[m - 1]
}

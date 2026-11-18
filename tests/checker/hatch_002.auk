if s.len() == 0 { fail(Empty) }
var total = 0
var n = 0
var have = false
for c in s.chars() {
  if c.is_digit() {
    n = n * 10 + (int(c) - int('0'))
    have = true
  } else {
    if !have { fail(NoNumber) }
    let mult = match c {
      'h' => 3_600
      'm' => 60
      's' => 1
      _ => fail(BadUnit(c))
    }
    total += n * mult
    n = 0
    have = false
  }
}
if have { fail(NoNumber) }
total

fn f(s: str): int {
  var t = 0
  for c in s { if c.is_digit() { t += 1 } }
  t
}
fn main() {}

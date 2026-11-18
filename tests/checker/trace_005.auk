fn id(n: int): int = n
fn main() {
  var t = 0
  for i in 0..20_000 { t += id(i) }
  print(t)
}

fn count([], acc: int): int = acc
fn count([_, ..t]: [int], acc: int): int = count(t, acc + 1)
fn main() {
  var xs: [int] = []
  for i in 0..200_000 { xs.push(i) }
  print(count(xs, 0))
  print(xs.map(x => x + 1).len())
}

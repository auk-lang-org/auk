fn len([], acc: int): int = acc
fn len([_, ..t]: [int], acc: int): int = len(t, acc + 1)
fn sum(xs: [int], i: int, acc: int): int {
  if i == xs.len() { return acc }
  sum(xs, i + 1, acc + xs[i])
}
fn main() {
  var xs: [int] = []
  for i in 0..1_000_000 { xs.push(i) }
  print(len(xs, 0))
  print(sum(xs, 0, 0))
}

fn len([], acc: int): int
  ensures result == acc
{ acc }
fn len([_, ..t]: [int], acc: int): int
  ensures result > acc
{ len(t, acc + 1) }
fn count(n: int, acc: int): int
  requires n >= 0
  ensures result == old(acc) + n
{
  if n == 0 { return acc }
  count(n - 1, acc + 1)
}
fn grow(xs: var [int], n: int)
  ensures xs.len() == old(xs.len()) + n
{
  if n > 0 {
    xs.push(n)
    grow(&xs, n - 1)
  }
}
fn main() {
  var xs: [int] = []
  for i in 0..300000 { xs.push(i) }
  print(len(xs, 0))
  print(len([], 5))
  print(count(1000000, 0))
  var ys = [1]
  grow(&ys, 3)
  print(ys)
}

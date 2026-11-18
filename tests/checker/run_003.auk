fn adders(): [(int) => int] {
  var out: [(int) => int] = []
  for k in 1..=3 {
    let base = k * 10
    out.push(x => x + base)
  }
  out
}
fn twice(f: (int) => int, x: int): int = f(f(x))
fn main() {
  print(adders().map(f => f(1)))
  var n = 5
  let g = x => x * n
  n = 100
  print(g(2))
  let pre = "#"
  print(["a", "b"].map(s => pre + s).join(","))
  print(twice(x => x + 1, 0))
  let pairs = [(1, "one"), (2, "two")]
  print(pairs.map((i, s) => "{s}={i}"))
}

fn main(args: [str]) {
  let n = int.parse(args[1]) else 1000
  var xs: [int] = []
  var s = 42
  for _ in 0..n {
    s = (s *% 6364136223846793005 +% 1442695040888963407)
    xs.push((s >> 33) % 1000000)
  }
  let ys = xs.sort()
  var acc = 0
  for i in 0..n { acc = (acc *% 31 +% ys[i]) }
  print("{ys[0]} {ys[n - 1]} {acc}")
}

fn main(args: [str]) {
  let n = int.parse(args[1]) else 1000
  var m: {int: int} = {}
  for i in 0..n {
    let k = (i * 7919) % (n / 2)
    m[k] = (m.get(k) else 0) + 1
  }
  var hits = 0
  for i in 0..n {
    if m.get(i) is some(_) { hits += 1 }
  }
  print("{m.len()} {hits}")
}

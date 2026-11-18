fn bump(xs: var [int]) { xs.push(99) }
struct Acc { xs: [int], n: int }
fn add(a: var Acc, x: int) {
  a.xs.push(x)
  a.n += 1
}
fn main() {
  let a = [1, 2]
  var b = a
  bump(&b)
  print("{a} {b}")
  var acc = Acc { xs: a, n: 0 }
  let snapshot = acc
  acc.add(5)
  add(&acc, 6)
  print("{acc.xs} {acc.n} {snapshot.xs} {snapshot.n} {a}")
  var m = {"k": [1]}
  let m2 = m
  m["k"] = [2]
  print("{m} {m2}")
}

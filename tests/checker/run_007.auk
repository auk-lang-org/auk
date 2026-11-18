struct Group { name: str, clauses: [str] }

fn last_index(xs: [Group]): int = xs.len() - 1

fn main() {
  var items = [Group { name: "a", clauses: [] }, Group { name: "b", clauses: ["x"] }]
  let before = items
  for i in 0..5 {
    var g = items[items.len() - 1]
    g.clauses.push("c{i}")
    g.name += "!"
    items[items.len() - 1] = g
  }
  print(items.map(g => "{g.name} {g.clauses}"))
  print(before.map(g => "{g.name} {g.clauses}"))
  // the element is used after it goes back
  var ls: [[int]] = [[1], [2]]
  var x = ls[0]
  x.push(10)
  ls[0] = x
  x.push(20)
  print("{ls} {x}")
  // reading the container in between: no move (the read sees the old value)
  var ys: [[int]] = [[1]]
  var y = ys[0]
  y.push(2)
  print(ys)
  ys[0] = y
  print(ys)
  // a map value
  var m = {"k": [1]}
  var v = m["k"]
  v.push(2)
  m["k"] = v
  print(m)
  // a different index variable changed in between: no move
  var zs: [[int]] = [[1], [2]]
  var k = 0
  var z = zs[k]
  z.push(5)
  k = 1
  zs[k] = z
  print(zs)
  // ... or changed by a tuple assignment
  var ts: [[int]] = [[1], [2]]
  var j = 0
  var tj = ts[j]
  tj.push(3)
  (j, k) = (1, 0)
  ts[j] = tj
  print("{ts} {k}")
}

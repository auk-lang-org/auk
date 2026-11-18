// The self-hosted back end's corpus: recursive enums (boxed fields), structs, maps, optionals
// and results, Value conversions, floats and their inlined operations, checked integer
// arithmetic, list writes, sorting, imprints.

enum Tree { Leaf, Node(l: Tree, v: int, r: Tree) }

fn insert(t: Tree, x: int): Tree = match t {
  Leaf => Node(Leaf, x, Leaf)
  Node(l, v, r) => if x < v { Node(insert(l, x), v, r) } else { Node(l, v, insert(r, x)) }
}

fn walk(t: Tree, out: var [int]) {
  match t {
    Leaf => {}
    Node(l, v, r) => {
      walk(l, &out)
      out.push(v)
      walk(r, &out)
    }
  }
}

struct User { name: str, age: int, boss: User? }

enum Op { Add(a: int, b: int), Neg(x: float), Pair(p: (int, str)), Nothing }

fn run(o: Op): str = match o {
  Add(a, b) => "{a + b}"
  Neg(x) => "{-x}"
  Pair((n, s)) => "{s}{n}"
  Nothing => "-"
}

fn half(n: int): int! = if n % 2 == 0 { n / 2 } else { fail("odd {n}") }

fn table(): [int] = (0..8).map(i => i * i)

imprint SQUARES = table()

struct Point { x: float, y: float }

fn main() {
  var t = Leaf
  for x in [5, 2, 8, 1, 9, 3] { t = insert(t, x) }
  var xs: [int] = []
  walk(t, &xs)
  print(xs)
  let boss = User { name: "Ada", age: 50, boss: none }
  let u = User { name: "Bo", age: 30, boss: some(boss) }
  print(u.boss?.name else "nobody")
  print([Add(1, 2), Neg(2.5), Pair((7, "x")), Nothing].map(run))
  var m: {str: int} = {}
  for w in "a b a c b a".split(" ") { m[w] = (m.get(w) else 0) + 1 }
  print(m)
  print(half(10) else 0)
  print(half(7) else e => -1)
  let v = to_value(u)
  print(v)
  let back: User = from_value(v)!
  print(back.name)
  print((sqrt(2.0), abs(-3.5), floor(2.7), ceil(2.1), round(2.5)))
  print(1.0 / 3.0)
  print((17 / 5, 17 % 5, -17 % 5, 1 << 10, -64 >> 2))
  var ys = [1, 2, 3]
  ys[1] = 20
  ys.push(4)
  print(ys)
  var ps: [Point] = []
  ps.push(Point { x: 1.0, y: 2.0 })
  ps[0] = Point { x: 3.0, ..ps[0] }
  print(ps)
  print(["pear", "fig", "apple"].sort())
  print(xs.sort_by(x => -x))
  print(SQUARES)
  let big = 9223372036854775807
  print(catch { big + 1 } else -1)
  print(catch { 1 / (big - big) } else -2)
}

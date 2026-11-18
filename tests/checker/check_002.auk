
struct Box<T> { v: T }
enum Tree<T> { Leaf, Node(l: Tree<T>, v: T, r: Tree<T>) }
fn insert<T: Ord>(t: Tree<T>, x: T): Tree<T> = match t {
  Leaf => Node(Leaf, x, Leaf)
  Node(l, v, r) when x < v => Node(insert(l, x), v, r)
  Node(l, v, r) => Node(l, v, insert(r, x))
}
fn items<T>(Leaf: Tree<T>): [T] = []
fn items<T>(Node(l, v, r): Tree<T>): [T] = items(l) + [v] + items(r)
shape Same { fn same(self, o: Self): bool }
struct Id { n: int }
fn same(a: Id, b: Id): bool = a.n == b.n
fn all_same(xs: [Same]): bool = xs.all(x => x.same(xs[0]))
struct Money { cents: int }
fn show(m: Money): str = "${m.cents / 100}"
fn unbox<T>(b: Box<T>): T = b.v
test "generics" {
  assert unbox(Box { v: 3 }) == 3
  let bs: Box<str> = Box { v: "x" }
  assert bs.v == "x"
  var t: Tree<int> = Leaf
  for x in [3, 1, 2] { t = insert(t, x) }
  assert items(t) == [1, 2, 3]
  assert all_same([Id { n: 1 }, Id { n: 1 }])
  let m = Money { cents: 250 }
  assert "{m}" == "$2" && [m].join(",") == "$2"
  let f = unbox
  assert f(Box { v: 1 }) == 1
}

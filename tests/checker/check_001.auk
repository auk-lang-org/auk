
shape Area { fn area(self): float }
struct Circle { r: float }
struct Sq { s: float }
fn area(c: Circle): float = 3.14 * c.r * c.r
fn area(s: Sq): float = s.s * s.s
fn total(xs: [Area]): float = xs.map(x => x.area()).sum()
fn draw(xs: [any Area]): float {
  var t = 0.0
  for x in xs { t += x.area() }
  t
}
fn biggest(a: Ord, b: Ord): Ord = if a > b { a } else { b }
fn pair<A: Show, B: Show>(a: A, b: B): str = a.show() + b.show()
struct V { x: int, y: int }
fn add(a: V, b: V): V = V { x: a.x + b.x, y: a.y + b.y }
enum Tree { Leaf, Node(l: Tree, v: int, r: Tree) }
fn sum(Leaf): int = 0
fn sum(Node(l, v, r)): int = sum(l) + v + sum(r)
fn push2(xs: var [int], v: int) { xs.push(v) }
async fn get(n: int): int! { n }
fn opt(n: int): int? = if n > 0 { n } else { none }
fn twice(f: (int) => int, x: int): int = f(f(x))
let LIMIT = 10
imprint TABLE = [1, 2, 3].map(x => x * x)
fn fail_with(n: int): int! {
  if n > 0 { fail("bad {n}") }
  n
}
test "features" {
  assert total([Circle { r: 1.0 }, Circle { r: 2.0 }]) > 0.0
  assert draw([Circle { r: 1.0 }, Sq { s: 2.0 }]) > 0.0
  assert biggest(3, 4) == 4 && biggest("a", "b") == "b"
  assert pair(1, "x") == "1x"
  assert V { x: 1, y: 2 } + V { x: 3, y: 4 } == V { x: 4, y: 6 }
  assert sum(Node(Leaf, 3, Node(Leaf, 4, Leaf))) == 7
  var xs = [1]
  push2(&xs, 2)
  xs.push2(3)
  let (a, b) = await (get(1), get(2))
  assert a? + b? == 3
  let all = await [1, 2, 3].map(n => get(n))
  assert all.len() == 3
  let t = get(5)
  assert (await t)? == 5
  assert opt(3)?.show() is some(_)
  assert (opt(-1) else 0) == 0
  assert twice(x => x + 1, LIMIT) == 12
  assert TABLE[2] == 9
  assert peek xs.len() * 2 == 6
  let s: Set<int> = set([1, 2, 2])
  assert s.len() == 2
  for k, v in {"a": 1} { assert k.len() == v }
  assert {"a": 1}.entries()[0] == ("a", 1)
  assert xs.enum().map((i, x) => i + x)[0] == 1
  assert xs.max()! == 3
  let z = xs.find(x => x > 1) else return
  assert z == 2
  let e: int! = fail_with(1)
  let msg = match e { ok(n) => "{n}", err(er) => "{er}" }
  assert msg.len() > 0 && e is err(_)
  assert int('a') == 97 && char(97)! == 'a'
  assert "{3.14159:.2} {42:>5} {"x":<3}|" == "3.14    42 x  |"
  assert [3, 1, 2].sort() == [1, 2, 3] && [[1], [2]] == [[1], [2]] && (1, "a") < (2, "b")
  assert str(['a', 'b']) == "ab"
  match e { ok(_) => {}, err(_) => {} }
}

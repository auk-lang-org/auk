/// Arms that take a matched value apart and reuse its boxes (design/ownership-plan.md,
/// section 6): unique and shared trees, swapped fields, inline fields, guards. The same output
/// with AUK_NO_MOVES=1 (tests/runner/src/suite/ownership.auk).

enum Tree { Leaf, Node(l: Tree, v: int, r: Tree) }
enum Item { Named(name: str, n: int), Blank }
enum List { Nil, Cons(h: str, t: List) }

fn insert(t: Tree, v: int): Tree = match t {
  Leaf => Node(Leaf, v, Leaf)
  Node(l, x, r) when v < x => Node(insert(l, v), x, r)
  Node(l, x, r) when v > x => Node(l, x, insert(r, v))
  _ => t
}

fn mirror(t: Tree): Tree = match t {
  Leaf => Leaf
  Node(l, x, r) => Node(mirror(r), x, mirror(l))
}

fn swap(t: Tree): Tree = match t {
  Node(l, x, r) => Node(r, x, l)
  _ => t
}

fn bump(i: Item): Item = match i {
  Named(name, n) => Named(name + "!", n + 1)
  Blank => Blank
}

fn shout(xs: List): List = match xs {
  Nil => Nil
  Cons(h, t) => Cons(h + "!", shout(t))
}

fn items(t: Tree): [int] = match t {
  Leaf => []
  Node(l, v, r) => items(l) + [v] + items(r)
}

fn show(xs: List): str = match xs {
  Nil => "."
  Cons(h, t) => h + " " + show(t)
}

fn main() {
  // built up alone: every level reused
  var t = Leaf
  for k in [50, 30, 70, 20, 40, 60, 80, 35, 45, 65] { t = insert(t, k) }
  print(items(t))
  // old versions kept: their boxes are shared, so they must not change
  var versions: [Tree] = []
  var u = Leaf
  for k in [5, 3, 8, 1, 4, 7, 9] {
    versions.push(u)
    u = insert(u, k)
  }
  for v in versions { print(items(v)) }
  print(items(u))
  // an alias made before the call
  let before = u
  let after = insert(u, 6)
  print(items(before))
  print(items(after))
  // both children swapped (each moved into the other's box)
  print(items(mirror(after)))
  print(items(swap(after)))
  print(items(after))
  // inline fields
  let i = Named("a", 1)
  print(bump(bump(i)))
  print(i)
  print(bump(Blank))
  // a list rebuilt cell by cell, and a shared one
  let xs = Cons("x", Cons("y", Cons("z", Nil)))
  let ys = shout(xs)
  print(show(xs))
  print(show(ys))
  print(show(shout(shout(Cons("p", Nil)))))
}

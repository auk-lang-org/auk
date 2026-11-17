enum Tree { Leaf, Node(l: Tree, r: Tree) }

fn make(0): Tree = Node(Leaf, Leaf)
fn make(d: int): Tree = Node(make(d - 1), make(d - 1))

fn check(t: Tree): int = match t {
  Leaf => 0
  Node(l, r) => 1 + check(l) + check(r)
}

fn main(args: [str]) {
  let depth = int.parse(args[1]) else 10
  var total = 0
  var d = 4
  while d <= depth {
    let iters = 1 << (depth - d + 4)
    for _ in 0..iters { total += check(make(d)) }
    d += 2
  }
  print(total)
}

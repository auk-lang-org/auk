fn insert(t: Tree, v: int): Tree = match t {
  Leaf => Node(Leaf, v, Leaf)
  Node(l, x, r) when v < x => Node(insert(l, v), x, r)
  Node(l, x, r) when v > x => Node(l, x, insert(r, v))
  _ => t
}

fn from_list(xs: [int]): Tree = xs.reduce(Leaf, (t, v) => insert(t, v))

fn to_list(t: Tree): [int] = match t {
  Leaf => []
  Node(l, v, r) => to_list(l) + [v] + to_list(r)
}

fn height(t: Tree): int = match t {
  Leaf => 0
  Node(l, _, r) => 1 + (if height(l) > height(r) { height(l) } else { height(r) })
}

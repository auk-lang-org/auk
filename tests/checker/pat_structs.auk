struct P { x: int, y: int, tag: str }

enum Node { Leaf, Pair(left: Node, right: Node), Val(v: int, at: P) }

fn at_origin(p: P): bool = match p {
  P { x: 0, y: 0, .. } => true
  P { x: 1, .. } => false
}

fn depth(n: Node): int = match n {
  Leaf => 0
  Pair(Leaf, r) => 1 + depth(r)
  Val(_, P { x: 0, .. }) => 1
}

fn nest(Pair(Leaf, Leaf)): int = 0
fn nest(Val(v, at)): int = v

fn main() {
  print(at_origin(P { x: 0, y: 0, tag: "" }))
  print(depth(Node.Leaf) + nest(Node.Leaf))
}

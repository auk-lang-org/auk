enum Tree { Leaf(v: int), Node(l: Tree, r: Tree) }
enum Wrap { A(t: Tree?), B(ws: [Wrap]) }
struct User { name: str, boss: User? }
fn sum(Leaf(v)): int = v
fn sum(Node(l, r)): int = sum(l) + sum(r)
fn depth(Leaf(_)): int = 1
fn depth(Node(l, r)): int = 1 + if depth(l) > depth(r) { depth(l) } else { depth(r) }
fn main() {
  let t = Node(Leaf(1), Node(Leaf(2), Leaf(3)))
  print("{sum(t)} {depth(t)} {t}")
  print(B([A(some(t)), A(none)]))
  print(t == Node(Leaf(1), Node(Leaf(2), Leaf(3))))
  let u = User { name: "ann", boss: some(User { name: "bob", boss: none }) }
  print(u.boss?.name else "-")
  print(u.boss?.boss?.name else "-")
  match t {
    Node(Leaf(a), Node(b, _)) => print("{a} {b}")
    _ => print("?")
  }
}

enum T { Leaf, Node(l: T, r: T) }
fn f(Leaf): int = 0
fn f(Node(Leaf, _)): int = 1
fn f(Node(Node(_, _), Node(_, _))): int = 2
fn main() {}

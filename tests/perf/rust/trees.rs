enum Tree { Leaf, Node(Box<Tree>, Box<Tree>) }
fn make(d: i64) -> Tree {
    if d == 0 { Tree::Node(Box::new(Tree::Leaf), Box::new(Tree::Leaf)) }
    else { Tree::Node(Box::new(make(d - 1)), Box::new(make(d - 1))) }
}
fn check(t: &Tree) -> i64 { match t { Tree::Leaf => 0, Tree::Node(l, r) => 1 + check(l) + check(r) } }
fn main() {
    let depth: i64 = std::env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(10);
    let mut total = 0; let mut d = 4;
    while d <= depth {
        let iters = 1i64 << (depth - d + 4);
        for _ in 0..iters { total += check(&make(d)); }
        d += 2;
    }
    println!("{}", total);
}

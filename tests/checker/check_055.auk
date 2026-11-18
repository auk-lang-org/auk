struct P { x: int }
fn cmp(a: P, b: P): int = a.x - b.x
fn main() { print([P { x: 1 }].sort().len()) }

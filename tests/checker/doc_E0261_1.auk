struct V { x: int }
fn add(a: V, b: V): V = V { x: a.x + b.x }
fn main() { print(V { x: 1 } + V { x: 2 }) }

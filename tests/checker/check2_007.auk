struct P { on: bool, n: int }
fn f(P { on: true, .. }): int = 1
fn f(P { n, .. }): int = n
fn main() {}

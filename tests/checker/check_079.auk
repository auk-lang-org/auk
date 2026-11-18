struct P { x: int, y: int }
fn f(p: P): int = match p {
  P { x } => x
}

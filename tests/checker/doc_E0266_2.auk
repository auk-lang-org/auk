struct P { x: int, y: int }
fn getx(p: P): int = match p {
  P { x, .. } => x
}

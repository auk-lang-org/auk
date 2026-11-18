enum E { A(x: int, y: int) }
fn f(e: E): int = match e {
  A(x) => x
}

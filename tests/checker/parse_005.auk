enum E { A(x: int), B }
fn g(e: E): int = match e {
  A(x) when x > 0 => x, B => 0
  _ => -1
}

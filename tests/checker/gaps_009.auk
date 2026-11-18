fn f(x: int, s: str): int = match (x, s) {
  (1, n) | (n, "a") => 1
  _ => 0
}

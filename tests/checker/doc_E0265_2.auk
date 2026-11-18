fn same(p: (int, int)): bool = match p {
  (a, b) when a == b => true
  _ => false
}

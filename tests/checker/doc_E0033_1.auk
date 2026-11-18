fn ends(xs: [int]): int = match xs {
  [a, .., b, ..] => a + b
  _ => 0
}

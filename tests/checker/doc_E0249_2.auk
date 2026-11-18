fn head(xs: [int]): int! {
  let x = xs.first() else fail("empty list")
  x
}

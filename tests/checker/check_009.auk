fn g(): int! = 1
fn f(): int! {
  let x: int = g()
  x
}

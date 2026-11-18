enum E { A }
enum F { B }
fn g(): int!E = 1
fn f(): int!F {
  let x = g()?
  x
}

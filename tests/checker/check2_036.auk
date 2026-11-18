enum One { Only(v: int) }
fn f(t: One): int {
  let Only(a) = t else { return 0 }
  a
}
fn main() {}

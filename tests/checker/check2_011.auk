fn f(x: int?): int {
  match x {
    some(n) => n
    none => 0
  }
}
fn main() {}

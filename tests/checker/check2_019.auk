fn f(xs: [int]): int {
  match xs {
    [] => 0
    [a] => a
    [a, b, .._] => a + b
  }
}
fn main() {}

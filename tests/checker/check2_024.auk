fn f(xs: [int]): int {
  match xs {
    [] => 0
    [.., last] => last
    [a, b] => a
  }
}
fn main() {}

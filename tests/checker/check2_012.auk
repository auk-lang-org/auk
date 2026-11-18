enum E { A, B(k: int) }
fn f(x: int!E): int {
  match x {
    ok(n) => n
    err(A) => 0
  }
}
fn main() {}

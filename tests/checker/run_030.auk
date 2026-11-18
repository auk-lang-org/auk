fn f(n: int): int
  ensures result >= 0
fn f(0): int = 0
fn f(n: int): int = -n
fn main() {
  print(f(0))
  print(f(3))
}

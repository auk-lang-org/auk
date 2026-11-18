/// Fibonacci with clauses: tried top to bottom, and the compiler checks they cover every `int`.

fn fib(0): int = 0
fn fib(1): int = 1
fn fib(n: int): int = fib(n - 1) + fib(n - 2)

fn main() {
  for i in 0..10 {
    print(fib(i))
  }
}

test "fib" {
  assert fib(10) == 55
  assert fib(20) == 6_765
}

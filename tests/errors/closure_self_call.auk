// error: E0102 unknown function `fib`
fn main() {
  let fib = n => if n < 2 { n } else { fib(n - 1) + fib(n - 2) }
  print(fib(10))
}

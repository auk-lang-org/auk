enum E { Odd(n: int) }
fn half(n: int): int!E {
  if n % 2 == 1 { fail(Odd(n)) }
  n / 2
}
fn quarter(n: int): int!E = half(half(n)?)?
fn main() {
  let q = quarter(6) else e => -1
  print(q)
}

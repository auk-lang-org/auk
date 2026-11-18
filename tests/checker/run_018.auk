fn bad(n: int): int
  ensures result > n
{ n }
fn main() { print(bad(1)) }

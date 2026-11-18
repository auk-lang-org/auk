fn fact(n: int): int = if n == 0 { 1 } else { n * fact(n - 1) }
imprint FACTS = (0..=20).map(n => fact(n))
fn main() { print(FACTS) }

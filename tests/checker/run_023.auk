fn fact(n: int): int = if n == 0 { 1 } else { n * fact(n - 1) }
imprint FACTS = (0..=25).map(n => fact(n))
imprint N = FACTS.len()
fn main() { print(N) }

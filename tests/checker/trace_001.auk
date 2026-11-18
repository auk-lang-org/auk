fn fact(0): int = 1
fn fact(n: int): int = n * fact(n - 1)
fn main() { print(fact(3)) }

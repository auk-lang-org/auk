fn pick(xs: [int], i: int): int = xs[i]
fn go(n: int): int = pick([1, 2], n) + 1
fn main() { print(go(5)) }

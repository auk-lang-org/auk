fn pick<T>(xs: [T], i: int): T {
    let n = xs.len()
    xs[i % n]
}

fn twice(f: (int) => int, x: int): int = f(f(x))

fn main() {
    let names = ["ann", "bob"]
    let who = pick(names, 3)
    let k = pick([10, 20, 30], 4)
    let y = twice(v => v * 3 + k, 1)
    print("{who} {k} {y}")
}

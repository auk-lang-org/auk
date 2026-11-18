fn bump(): int = 100

fn main() {
    var counts: {str: int} = {}
    for w in "a b a c b a".split(" ") {
        counts[w] = (counts.get(w) else 0) + 1
    }
    print(counts)
    var f: {int: float} = {}
    let k = 3
    let half = 0.5
    f[k] = (f.get(k) else 1.0) * half
    f[k] = (f.get(k) else 1.0) * half
    f[7] = (f.get(7) else 2.0) - half
    print(f)
    var m: {int: int} = {1: 10}
    let snapshot = m
    let one = 1
    m[one] = (m.get(one) else 0) + 5
    m[2] = (m.get(2) else 40) + 2
    print("{m} {snapshot}")
    var big: {int: int} = {5: 9223372036854775807}
    let r = catch {
        big[5] = (big.get(5) else 0) + 1
        0
    }
    print("{r is err(_)} {big}")
    var g: {int: int} = {}
    g[1] = (g.get(1) else bump()) + 1
    print(g)
}

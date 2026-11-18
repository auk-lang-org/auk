async fn work(k: int): int {
    var s = 0
    for i in 0..k {
        s += i
    }
    s
}

fn spin(): int {
    var n = 0
    while true {
        n += 1
        if n < 0 { return n }
    }
    n
}

fn boom(xs: [int]): int {
    let m = xs.map(x => x * 2)
    m[10]
}

fn main() {
    let r = catch boom([1])
    let (a, b) = await (work(3), work(4))
    print("{a} {b}")
    print("{spin()}")
}

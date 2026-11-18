async fn work(k: int): int {
    var s = 0
    for i in 0..k {
        s += i
    }
    s
}

fn boom(xs: [int]): int {
    let m = xs.map(x => x * 2)
    m[10]
}

fn main() {
    let r = catch boom([1])
    match r {
        ok(v) => print("{v}")
        err(e) => print("caught: {e}")
    }
    let a = await work(3)
    let b = await work(4)
    print("{a} {b}")
}

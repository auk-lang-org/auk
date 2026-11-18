struct Point { x: int, y: int }

fn dist2(p: Point): int = p.x * p.x + p.y * p.y

fn fact(n: int): int {
    if n <= 1 {
        return 1
    }
    n * fact(n - 1)
}

fn main() {
    let pts = [Point { x: 1, y: 2 }, Point { x: 3, y: 4 }]
    var total = 0
    for i in 0..5 {
        total += i
    }
    print("{total} {fact(5)} {pts.len()}")
}

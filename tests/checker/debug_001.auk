struct Point { x: int, y: int }

fn add(p: Point, d: int): Point {
    let nx = p.x + d
    let ny = p.y + d
    Point { x: nx, y: ny }
}

fn fact(n: int): int {
    if n <= 1 {
        return 1
    }
    n * fact(n - 1)
}

fn main() {
    var total = 0
    for i in 0..3 {
        total += i
    }
    let p = add(Point { x: 1, y: 2 }, total)
    let x = 1
    let x = x + fact(3)
    print("{p.x} {x}")
}

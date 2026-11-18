shape Area { fn area(self): float }
struct Tri { a: float }
fn total(xs: [Area]): float = 0.0
fn main() { print(total([Tri { a: 1.0 }])) }

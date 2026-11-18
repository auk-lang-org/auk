enum Shape { Circle(r: float), Rect(w: float, h: float) }
fn area(Circle(r)): float = 3.14 * r * r
fn main() { print(area(Circle(1.0))) }

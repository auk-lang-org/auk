enum Shape { Circle(r: float), Rect(w: float, h: float) }
fn area(s: Shape): float {
  match s {
    Circle(r) => 3.14 * r * r
  }
}
fn main() {}

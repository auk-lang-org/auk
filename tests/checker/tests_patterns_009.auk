enum Shape { Circle(r: float), Rect(w: float, h: float) }
fn f(x: Shape?): float {
  match x {
    some(Circle(r)) => r
    none => 0.0
  }
}
fn main() {}

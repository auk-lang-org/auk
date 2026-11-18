enum Shape { Circle(r: float), Rect(w: float, h: float) }
fn f(xs: [Shape]): float {
  var t = 0.0
  for Circle(r) in xs { t += r }
  t
}
fn main() {}

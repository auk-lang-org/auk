enum Shape { Circle(r: float), Square(side: float), Rect(w: float, h: float), Dot }
fn f(s: Shape): int = match s {
  Circle(_) | Dot => 1
  Square(_) | Circle(_) => 2
  Dot | Circle(_) => 3
  _ => 4
}

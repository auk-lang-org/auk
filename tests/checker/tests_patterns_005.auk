enum Shape { Circle(r: float), Square(side: float), Rect(w: float, h: float), Dot }
fn f(s: Shape): int = match s {
  Circle(_) | Square(_) | Rect(_, _) | Dot when true => 1
}

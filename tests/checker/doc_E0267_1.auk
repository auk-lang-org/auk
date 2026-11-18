enum Shape { Circle(r: float), Square(side: float), Dot }

fn size(s: Shape): float = match s {
  Circle(r) | Square(side) => r
  Dot => 0.0
}

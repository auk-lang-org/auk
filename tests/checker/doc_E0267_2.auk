enum Shape { Circle(r: float), Square(side: float), Dot }

fn size(s: Shape): float = match s {
  Circle(x) | Square(x) => x
  Dot => 0.0
}

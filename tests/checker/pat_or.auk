enum Dir { N, E, S, W }

enum Shape { Circle(r: float), Rect(w: float, h: float), Tri(a: float, b: float, c: float) }

fn turn(d: Dir): int = match d {
  N | E => 1
  E | S => 2
  W | N => 3
}

fn turn2(d: Dir): int = match d {
  N | S | N => 1
  E | W | S | E => 2
}

fn both(d: Dir): int = match d {
  N => 0
  E | S => 1
  N | E => 2
  W => 3
}

fn area(s: Shape): float = match s {
  Circle(r) | Rect(r, _) => r
}

fn main() {
  print(turn(Dir.N) + turn2(Dir.E) + both(Dir.W))
  print(area(Shape.Circle(1.0)))
}

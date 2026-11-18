/// A point.
pub struct Point { x: float, y: float }

pub enum Shape { Circle(r: float), Square(s: float) }

pub fn area(s: Shape): float = match s {
  Circle(r) => 3.0 * r * r
  Square(w) => w * w
}

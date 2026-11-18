fn sum_to(n: int): int {
  var t = 0
  for i in 1..=n {
    t += i
  }
  t
}

struct Point { x: float, y: float }

enum Shape { Circle(r: float), Rect(w: float, h: float) }

fn area(Circle(r)): float = 3.0 * r * r
fn area(Rect(w, h)): float = w * h

fn main(): ()! {
  let xs = [1, 2, 3]
  print("hello from a statement")
  let p = Point { x: 1.0, y: 2.0 }
  let big = 9223372036854775807
}

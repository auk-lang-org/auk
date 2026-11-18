struct Point { x: int, y: int }
fn f(p: Point): int {
  let Point { x, .. } = p else { return 0 }
  x
}
fn main() { print(f(Point { x: 1, y: 2 })) }

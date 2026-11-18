pub fn helper(): int = 1
fn main() {
  let c = geo.Circle { r: 1.0 }
  print(geo.area(c) + c.area())
  print(geo.shapes.sides(geo.shapes.Tri))
  let k: geo.Kind = geo.Big
  print(k == geo.Kind.Small)
  match k { Big => print("big"), _ => {} }
}

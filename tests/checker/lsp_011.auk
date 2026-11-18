struct Item { name: str, qty: int }

fn total(xs: [Item]): int = xs.map(i => i.qty).sum()

fn main() {
  let it = Item { name: "a", qty: 2 }
  let p = geo.Point { x: 1.0, y: 2.0 }
  let s = geo.Shape.Circle(1.0)
  match s {
    Circle(r) => print("{r}")
    _ => print("other")
  }
  print("{total([it])} {p.x} {geo.area(s)} {it.name}")
  print([("a", 1)].first()?.1)
}

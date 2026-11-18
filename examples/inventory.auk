/// Shapes as types: generic code with no interfaces to implement.

struct Item { name: str, qty: int, cents: int }
struct Order { id: int, total: int }

fn show(i: Item): str = "{i.name:<10} x{i.qty:>3}  ${i.cents / 100}.{i.cents % 100:02}"
fn show(o: Order): str = "order #{o.id}: ${o.total / 100}"

fn cmp(a: Item, b: Item): int = a.cents * a.qty - b.cents * b.qty  // Item fits Ord

/// The n largest values, largest first.
fn top(xs: [Ord], n: int): [Ord] = xs.sort().reverse().take(n)

fn report(title: str, xs: [Show]) {
  print("== {title} ==")
  for x in xs { print(x.show()) }
}

fn main() {
  let stock = [
    Item { name: "widget", qty: 40, cents: 250 },
    Item { name: "gadget", qty: 3, cents: 9_999 },
    Item { name: "gizmo", qty: 12, cents: 1_200 },
  ]
  report("top stock by value", top(stock, 2))
  report("orders", [Order { id: 1, total: 5_000 }])
}

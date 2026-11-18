test "visible top_n" {
  let items = [Item { name: "pen", price: 2, qty: 10 }, Item { name: "ink", price: 30, qty: 1 }, Item { name: "pad", price: 5, qty: 2 }]
  assert top_n(items, 2) == ["ink", "pen"]
}

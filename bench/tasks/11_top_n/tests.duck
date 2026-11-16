test "hidden top_n" {
  let items = [Item { name: "pen", price: 2, qty: 10 }, Item { name: "ink", price: 30, qty: 1 }, Item { name: "pad", price: 5, qty: 2 }]
  assert top_n(items, 2) == ["ink", "pen"]
  assert top_n(items, 0) == []
  assert top_n(items, 10) == ["ink", "pen", "pad"]
  assert top_n([], 3) == []
  let ties = [Item { name: "b", price: 5, qty: 2 }, Item { name: "a", price: 10, qty: 1 }, Item { name: "c", price: 1, qty: 10 }, Item { name: "z", price: 100, qty: 0 }, Item { name: "d", price: 11, qty: 1 }]
  assert top_n(ties, 3) == ["d", "a", "b"]
  assert top_n(ties, 5) == ["d", "a", "b", "c"]
  assert top_n([Item { name: "free", price: 0, qty: 3 }, Item { name: "gone", price: 9, qty: 0 }], 5) == ["free"]
}

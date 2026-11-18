test "visible bst" {
  assert to_list(from_list([5, 3, 8, 1, 4, 8])) == [1, 3, 4, 5, 8]
  assert height(from_list([2, 1, 3])) == 2
  assert insert(Leaf, 1) == Node(Leaf, 1, Leaf)
}

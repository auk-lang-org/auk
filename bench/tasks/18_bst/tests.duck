test "hidden bst" {
  assert to_list(from_list([5, 3, 8, 1, 4, 8])) == [1, 3, 4, 5, 8]
  assert insert(Leaf, 1) == Node(Leaf, 1, Leaf)
  assert from_list([]) == Leaf
  assert to_list(Leaf) == []
  assert height(Leaf) == 0
  assert height(from_list([2, 1, 3])) == 2
  assert height(from_list([1, 2, 3, 4])) == 4
  assert height(from_list([4, 2, 6, 1, 3, 5, 7])) == 3
  assert from_list([2, 1, 3]) == Node(Node(Leaf, 1, Leaf), 2, Node(Leaf, 3, Leaf))
  assert from_list([2, 2, 2]) == Node(Leaf, 2, Leaf)
  let t = from_list([10, 5])
  let u = insert(t, 7)
  assert to_list(t) == [5, 10]
  assert to_list(u) == [5, 7, 10]
  assert insert(u, 7) == u
  assert to_list(from_list([-3, 0, -10, 7, -3])) == [-10, -3, 0, 7]
  assert to_list(from_list((0..500).map(i => (i * 37) % 500))) == (0..500).map(i => i)
}

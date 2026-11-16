def test_hidden_bst():
    assert to_list(from_list([5, 3, 8, 1, 4, 8])) == [1, 3, 4, 5, 8]
    assert insert(None, 1) == Node(None, 1, None)
    assert from_list([]) is None
    assert to_list(None) == []
    assert height(None) == 0
    assert height(from_list([2, 1, 3])) == 2
    assert height(from_list([1, 2, 3, 4])) == 4
    assert height(from_list([4, 2, 6, 1, 3, 5, 7])) == 3
    assert from_list([2, 1, 3]) == Node(Node(None, 1, None), 2, Node(None, 3, None))
    assert from_list([2, 2, 2]) == Node(None, 2, None)
    t = from_list([10, 5])
    u = insert(t, 7)
    assert to_list(t) == [5, 10]
    assert to_list(u) == [5, 7, 10]
    assert insert(u, 7) == u
    assert to_list(from_list([-3, 0, -10, 7, -3])) == [-10, -3, 0, 7]
    assert to_list(from_list([(i * 37) % 500 for i in range(500)])) == list(range(500))

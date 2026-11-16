def test_visible_top_n():
    items = [Item("pen", 2, 10), Item("ink", 30, 1), Item("pad", 5, 2)]
    assert top_n(items, 2) == ["ink", "pen"]

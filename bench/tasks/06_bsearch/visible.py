def test_visible_bsearch():
    assert bsearch([1, 3, 5, 7], 5) == 2
    assert bsearch([1, 3, 5, 7], 4) is None

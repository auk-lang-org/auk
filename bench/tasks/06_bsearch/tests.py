def test_hidden_bsearch():
    assert bsearch([1, 3, 5, 7], 5) == 2
    assert bsearch([1, 3, 5, 7], 4) is None
    assert bsearch([], 1) is None
    assert bsearch([1, 3, 5, 7], 1) == 0
    assert bsearch([1, 3, 5, 7], 7) == 3
    assert bsearch([1, 3, 5, 7], 0) is None
    assert bsearch([1, 3, 5, 7], 8) is None
    assert bsearch([2, 2, 2, 3], 2) == 0
    assert bsearch([1, 2, 2, 2], 2) == 1
    assert bsearch([5], 5) == 0
    assert bsearch([-10, -3, 0, 0, 9], 0) == 2
    big = [i * 2 for i in range(1000)]
    assert bsearch(big, 1998) == 999
    assert bsearch(big, 777) is None

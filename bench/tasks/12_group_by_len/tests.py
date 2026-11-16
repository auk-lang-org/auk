def test_hidden_group_by_len():
    assert group_by_len(["bb", "a", "cc", "bb", "ddd"]) == {1: ["a"], 2: ["bb", "cc"], 3: ["ddd"]}
    assert group_by_len([]) == {}
    assert list(group_by_len(["xyz", "q", "ab"]).keys()) == [1, 2, 3]
    assert group_by_len(["", "", "a"]) == {0: [""], 1: ["a"]}
    assert group_by_len(["héllo", "world", "ü"]) == {1: ["ü"], 5: ["héllo", "world"]}
    assert group_by_len(["b", "a", "b", "c", "a"]) == {1: ["b", "a", "c"]}

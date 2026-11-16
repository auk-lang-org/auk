def test_visible_group_by_len():
    assert group_by_len(["bb", "a", "cc", "bb", "ddd"]) == {1: ["a"], 2: ["bb", "cc"], 3: ["ddd"]}

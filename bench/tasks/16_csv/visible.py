def test_visible_split_csv():
    assert split_csv("a,b,c") == ["a", "b", "c"]
    assert split_csv("\"x,y\",z") == ["x,y", "z"]
    assert isinstance(catch(lambda: split_csv("\"abc")), Unterminated)

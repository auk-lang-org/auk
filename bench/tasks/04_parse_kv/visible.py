def test_visible_parse_kv():
    assert parse_kv("a=1; b = -2;c=3;") == {"a": 1, "b": -2, "c": 3}
    e = catch(lambda: parse_kv("a=1;oops"))
    assert isinstance(e, MissingEq) and e.at == 1

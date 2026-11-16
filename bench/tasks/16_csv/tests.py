def _err(f, cls, **attrs):
    e = catch(f)
    return isinstance(e, cls) and all(getattr(e, k) == v for k, v in attrs.items())


def test_hidden_split_csv():
    assert split_csv("a,b,c") == ["a", "b", "c"]
    assert split_csv("") == [""]
    assert split_csv("a,,c,") == ["a", "", "c", ""]
    assert split_csv(",") == ["", ""]
    assert split_csv("\"x,y\",z") == ["x,y", "z"]
    assert split_csv("\"say \"\"hi\"\"\"") == ["say \"hi\""]
    assert split_csv("\"\"") == [""]
    assert split_csv("\"\",\"\"") == ["", ""]
    assert split_csv("ab\"c,d") == ["ab\"c", "d"]
    assert split_csv(" \"a\" , b ") == [" \"a\" ", " b "]
    assert split_csv("x,\"multi, comma, field\"") == ["x", "multi, comma, field"]
    assert split_csv("é,\"ü\"") == ["é", "ü"]


def test_hidden_split_csv_errors():
    assert _err(lambda: split_csv("\"abc"), Unterminated)
    assert _err(lambda: split_csv("a,\"b\"\""), Unterminated)
    assert _err(lambda: split_csv("\"a\"b,c"), JunkAfterQuote, at=3)
    assert _err(lambda: split_csv("x,\"a\" ,y"), JunkAfterQuote, at=5)
    assert _err(lambda: split_csv("é,\"ü\"x"), JunkAfterQuote, at=5)

def _err(f, cls, **attrs):
    e = catch(f)
    return isinstance(e, cls) and all(getattr(e, k) == v for k, v in attrs.items())


def test_hidden_parse_kv_ok():
    assert parse_kv("a=1; b = -2;c=3;") == {"a": 1, "b": -2, "c": 3}
    assert parse_kv("") == {}
    assert parse_kv(" ; ;") == {}
    assert parse_kv("a=1;b=2;a=5") == {"a": 5, "b": 2}
    assert list(parse_kv("a=1;b=2;a=5").keys()) == ["a", "b"]
    assert parse_kv("  long key  =  42  ") == {"long key": 42}


def test_hidden_parse_kv_errors():
    assert _err(lambda: parse_kv("a=1;oops"), MissingEq, at=1)
    assert _err(lambda: parse_kv(";;x"), MissingEq, at=2)
    assert _err(lambda: parse_kv("a=1;;=3"), EmptyKey, at=2)
    assert _err(lambda: parse_kv("  =3"), EmptyKey, at=0)
    assert _err(lambda: parse_kv("x=1.5"), BadValue, key="x")
    assert _err(lambda: parse_kv("k=1=2"), BadValue, key="k")
    assert _err(lambda: parse_kv("k="), BadValue, key="k")
    assert _err(lambda: parse_kv("k=x;oops"), BadValue, key="k")
    assert _err(lambda: parse_kv("oops;k=x"), MissingEq, at=0)

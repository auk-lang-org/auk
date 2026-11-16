def _err(f, cls, **attrs):
    e = catch(f)
    return isinstance(e, cls) and all(getattr(e, k) == v for k, v in attrs.items())


def test_hidden_tokenize():
    assert tokenize("12+(3)") == [Num(12), Op("+"), LParen(), Num(3), RParen()]
    assert tokenize("") == []
    assert tokenize(" 7 * 08 / -1 ") == [Num(7), Op("*"), Num(8), Op("/"), Op("-"), Num(1)]
    assert _err(lambda: tokenize("1 x"), BadToken, c="x")
    assert _err(lambda: tokenize("1.5"), BadToken, c=".")


def test_hidden_calc_values():
    assert calc("1 + 2 * 3") == 7
    assert calc("(1 + 2) * 3") == 9
    assert calc("10 / 3") == 3
    assert calc("-7 / 2") == -3
    assert calc("7 / -2") == -3
    assert calc("-7 / -2") == 3
    assert calc("2 - 3 - 4") == -5
    assert calc("8 / 2 / 2") == 2
    assert calc("--3") == 3
    assert calc("-(2+3)*2") == -10
    assert calc("2*-3") == -6
    assert calc("42") == 42
    assert calc(" ( ( 5 ) ) ") == 5
    assert calc("100 - 4 * (3 + 2) / 6") == 97


def test_hidden_calc_errors():
    assert _err(lambda: calc("1 +"), Syntax)
    assert _err(lambda: calc(""), Syntax)
    assert _err(lambda: calc("(1"), Syntax)
    assert _err(lambda: calc("1)"), Syntax)
    assert _err(lambda: calc("1 2"), Syntax)
    assert _err(lambda: calc("()"), Syntax)
    assert _err(lambda: calc("* 2"), Syntax)
    assert _err(lambda: calc("2 $ 3"), BadToken, c="$")
    assert _err(lambda: calc("a+("), BadToken, c="a")
    assert _err(lambda: calc("(1 + 2 x"), BadToken, c="x")
    assert _err(lambda: calc("1 / 0"), DivZero)
    assert _err(lambda: calc("1 / (2 - 2)"), DivZero)
    assert calc("0 / 5") == 0

def test_visible_calc():
    assert tokenize("12+(3)") == [Num(12), Op("+"), LParen(), Num(3), RParen()]
    assert calc("1 + 2 * 3") == 7
    assert calc("-7 / 2") == -3
    assert isinstance(catch(lambda: calc("1 +")), Syntax)
    e = catch(lambda: calc("2 $ 3"))
    assert isinstance(e, BadToken) and e.c == "$"
    assert isinstance(catch(lambda: calc("1 / 0")), DivZero)

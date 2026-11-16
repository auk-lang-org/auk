def test_visible_expr():
    e = Add(Num(2), Mul(Var("x"), Neg(Num(3))))
    assert eval_expr(e, {"x": 4}) == -10
    assert eval_expr(Var("y"), {}) is None
    assert render(e) == "(2 + (x * -3))"

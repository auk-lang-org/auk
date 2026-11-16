def _err(f, cls, **attrs):
    e = catch(f)
    return isinstance(e, cls) and all(getattr(e, k) == v for k, v in attrs.items())


def test_hidden_apply():
    a = Account("acc1", 100)
    assert apply(a, [Deposit(50), Withdraw(30), Fee(5)]) == Account("acc1", 115)
    assert apply(a, []) == a
    assert apply(a, [Withdraw(100)]).balance == 0
    assert _err(lambda: apply(a, [Withdraw(101)]), Overdraft, at=0)
    assert _err(lambda: apply(a, [Deposit(1), Withdraw(50), Withdraw(52)]), Overdraft, at=2)
    assert apply(a, [Fee(150)]) == Account("acc1", -50)
    assert apply(a, [Fee(150), Deposit(10)]).balance == -40
    assert _err(lambda: apply(a, [Fee(150), Withdraw(1)]), Overdraft, at=1)
    assert _err(lambda: apply(a, [Deposit(0)]), BadAmount, at=0)
    assert _err(lambda: apply(a, [Deposit(5), Fee(-3)]), BadAmount, at=1)
    assert _err(lambda: apply(a, [Withdraw(-1)]), BadAmount, at=0)
    assert _err(lambda: apply(a, [Withdraw(500), Deposit(0)]), Overdraft, at=0)
    assert a.balance == 100

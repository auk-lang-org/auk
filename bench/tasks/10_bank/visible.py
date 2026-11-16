def test_visible_apply():
    a = Account("acc1", 100)
    assert apply(a, [Deposit(50), Withdraw(30), Fee(5)]) == Account("acc1", 115)
    e = catch(lambda: apply(a, [Withdraw(101)]))
    assert isinstance(e, Overdraft) and e.at == 0

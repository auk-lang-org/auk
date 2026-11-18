test "hidden apply" {
  let a = Account { id: "acc1", balance: 100 }
  assert apply(a, [Deposit(50), Withdraw(30), Fee(5)])? == Account { id: "acc1", balance: 115 }
  assert apply(a, [])? == a
  assert (apply(a, [Withdraw(100)])?).balance == 0
  assert apply(a, [Withdraw(101)]) is err(Overdraft(0))
  assert apply(a, [Deposit(1), Withdraw(50), Withdraw(52)]) is err(Overdraft(2))
  assert apply(a, [Fee(150)])? == Account { id: "acc1", balance: -50 }
  assert (apply(a, [Fee(150), Deposit(10)])?).balance == -40
  assert apply(a, [Fee(150), Withdraw(1)]) is err(Overdraft(1))
  assert apply(a, [Deposit(0)]) is err(BadAmount(0))
  assert apply(a, [Deposit(5), Fee(-3)]) is err(BadAmount(1))
  assert apply(a, [Withdraw(-1)]) is err(BadAmount(0))
  assert apply(a, [Withdraw(500), Deposit(0)]) is err(Overdraft(0))
  assert a.balance == 100
}

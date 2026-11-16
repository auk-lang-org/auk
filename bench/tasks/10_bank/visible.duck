test "visible apply" {
  let a = Account { id: "acc1", balance: 100 }
  assert apply(a, [Deposit(50), Withdraw(30), Fee(5)])? == Account { id: "acc1", balance: 115 }
  assert apply(a, [Withdraw(101)]) is err(Overdraft(0))
}

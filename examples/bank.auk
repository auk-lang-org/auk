/// Accounts with contracts: the spec a human writes before AI fills in bodies.

struct Account { id: int, owner: str, balance: int }

fn deposit(a: var Account, amt: int)
  requires amt > 0
  ensures a.balance == old(a.balance) + amt
{
  a.balance += amt
}

fn withdraw(a: var Account, amt: int): ()!
  requires amt > 0
  ensures a.balance >= 0
{
  if amt > a.balance { fail("insufficient funds: has {a.balance}, needs {amt}") }
  a.balance -= amt
}

fn transfer(from: var Account, to: var Account, amt: int): ()!
  requires from.id != to.id
  ensures from.balance + to.balance == old(from.balance + to.balance)
{
  withdraw(&from, amt)?
  deposit(&to, amt)
}

test "transfer" {
  var a = Account { id: 1, owner: "ann", balance: 100 }
  var b = Account { id: 2, owner: "bob", balance: 0 }
  transfer(&a, &b, 30)?
  assert (a.balance, b.balance) == (70, 30)
  assert transfer(&a, &b, 500) is err(_)
  assert a.balance == 70  // failed transfer changed nothing
}

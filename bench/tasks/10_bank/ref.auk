fn apply(acct: Account, txs: [Tx]): Account!TxErr {
  var bal = acct.balance
  for i, tx in txs {
    let amount = match tx { Deposit(a) => a, Withdraw(a) => a, Fee(a) => a }
    if amount <= 0 { fail(BadAmount(i)) }
    match tx {
      Deposit(a) => bal += a
      Withdraw(a) => {
        if bal - a < 0 { fail(Overdraft(i)) }
        bal -= a
      }
      Fee(a) => bal -= a
    }
  }
  Account { balance: bal, ..acct }
}

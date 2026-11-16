def apply(acct: Account, txs: List[Tx]) -> Account:
    bal = acct.balance
    for i, tx in enumerate(txs):
        if tx.amount <= 0:
            raise BadAmount(i)
        if isinstance(tx, Deposit):
            bal += tx.amount
        elif isinstance(tx, Withdraw):
            if bal - tx.amount < 0:
                raise Overdraft(i)
            bal -= tx.amount
        else:
            bal -= tx.amount
    return Account(acct.id, bal)

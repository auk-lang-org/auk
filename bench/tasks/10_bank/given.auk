struct Account { id: str, balance: int }

enum Tx { Deposit(amount: int), Withdraw(amount: int), Fee(amount: int) }

enum TxErr { Overdraft(at: int), BadAmount(at: int) }

Apply a list of transactions to a bank account and return the updated account (same id, new balance). The input account must not be modified.

- `Deposit(amount)` adds the amount.
- `Withdraw(amount)` subtracts it, but fails with `Overdraft(at)` if the balance would go below zero.
- `Fee(amount)` subtracts it and is always applied, even if the balance goes negative.
- Every amount must be greater than zero; otherwise fail with `BadAmount(at)`.

`at` is the 0-based index of the offending transaction. Transactions are applied in order and the first error stops processing.

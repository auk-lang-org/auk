from dataclasses import dataclass
from typing import List, Union


@dataclass
class Account:
    id: str
    balance: int


@dataclass
class Deposit:
    amount: int


@dataclass
class Withdraw:
    amount: int


@dataclass
class Fee:
    amount: int


Tx = Union[Deposit, Withdraw, Fee]


class TxErr(Exception):
    pass


class Overdraft(TxErr):
    def __init__(self, at: int):
        super().__init__(at)
        self.at = at


class BadAmount(TxErr):
    def __init__(self, at: int):
        super().__init__(at)
        self.at = at


def catch(f):
    """Run f(); return the exception it raised, or None."""
    try:
        f()
    except Exception as e:
        return e
    return None

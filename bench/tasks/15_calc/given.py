from dataclasses import dataclass
from typing import List, Union


@dataclass
class Num:
    n: int


@dataclass
class Op:
    c: str


@dataclass
class LParen:
    pass


@dataclass
class RParen:
    pass


Tok = Union[Num, Op, LParen, RParen]


class CalcErr(Exception):
    pass


class BadToken(CalcErr):
    def __init__(self, c: str):
        super().__init__(c)
        self.c = c


class Syntax(CalcErr):
    pass


class DivZero(CalcErr):
    pass


def catch(f):
    """Run f(); return the exception it raised, or None."""
    try:
        f()
    except Exception as e:
        return e
    return None

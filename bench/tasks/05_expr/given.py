from dataclasses import dataclass
from typing import Dict, Optional, Union


@dataclass
class Num:
    n: int


@dataclass
class Var:
    name: str


@dataclass
class Add:
    a: "Expr"
    b: "Expr"


@dataclass
class Mul:
    a: "Expr"
    b: "Expr"


@dataclass
class Neg:
    e: "Expr"


Expr = Union[Num, Var, Add, Mul, Neg]

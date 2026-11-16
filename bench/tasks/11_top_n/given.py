from dataclasses import dataclass
from typing import List


@dataclass
class Item:
    name: str
    price: int
    qty: int

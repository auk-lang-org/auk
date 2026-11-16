from dataclasses import dataclass
from typing import List, Optional


@dataclass
class Node:
    l: Optional["Node"]
    v: int
    r: Optional["Node"]


# The empty tree is None (a "Leaf").
Tree = Optional[Node]

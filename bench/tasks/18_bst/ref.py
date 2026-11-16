def insert(t: Tree, v: int) -> Tree:
    if t is None:
        return Node(None, v, None)
    if v < t.v:
        return Node(insert(t.l, v), t.v, t.r)
    if v > t.v:
        return Node(t.l, t.v, insert(t.r, v))
    return t


def from_list(xs: List[int]) -> Tree:
    t = None
    for x in xs:
        t = insert(t, x)
    return t


def to_list(t: Tree) -> List[int]:
    return [] if t is None else to_list(t.l) + [t.v] + to_list(t.r)


def height(t: Tree) -> int:
    return 0 if t is None else 1 + max(height(t.l), height(t.r))

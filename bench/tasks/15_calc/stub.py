def tokenize(s: str) -> List[Tok]:
    """Raises BadToken."""
    raise NotImplementedError


def parse_expr(ts: List[Tok], pos: List[int]) -> int:
    """pos is a one-element list holding the current token index; advance pos[0].
    Raises Syntax or DivZero."""
    raise NotImplementedError


def parse_term(ts: List[Tok], pos: List[int]) -> int:
    raise NotImplementedError


def parse_factor(ts: List[Tok], pos: List[int]) -> int:
    raise NotImplementedError


def calc(s: str) -> int:
    """Raises BadToken, Syntax or DivZero."""
    raise NotImplementedError

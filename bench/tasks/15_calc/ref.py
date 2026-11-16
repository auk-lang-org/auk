def tokenize(s: str) -> List[Tok]:
    ts: List[Tok] = []
    i = 0
    while i < len(s):
        c = s[i]
        if "0" <= c <= "9":
            j = i
            while j < len(s) and "0" <= s[j] <= "9":
                j += 1
            ts.append(Num(int(s[i:j])))
            i = j
            continue
        if c in "+-*/":
            ts.append(Op(c))
        elif c == "(":
            ts.append(LParen())
        elif c == ")":
            ts.append(RParen())
        elif c != " ":
            raise BadToken(c)
        i += 1
    return ts


def _peek(ts, pos):
    return ts[pos[0]] if pos[0] < len(ts) else None


def parse_expr(ts: List[Tok], pos: List[int]) -> int:
    v = parse_term(ts, pos)
    while _peek(ts, pos) in (Op("+"), Op("-")):
        op = ts[pos[0]].c
        pos[0] += 1
        r = parse_term(ts, pos)
        v = v + r if op == "+" else v - r
    return v


def parse_term(ts: List[Tok], pos: List[int]) -> int:
    v = parse_factor(ts, pos)
    while _peek(ts, pos) in (Op("*"), Op("/")):
        op = ts[pos[0]].c
        pos[0] += 1
        r = parse_factor(ts, pos)
        if op == "*":
            v *= r
        else:
            if r == 0:
                raise DivZero()
            q = abs(v) // abs(r)
            v = q if (v < 0) == (r < 0) else -q
    return v


def parse_factor(ts: List[Tok], pos: List[int]) -> int:
    t = _peek(ts, pos)
    if t == Op("-"):
        pos[0] += 1
        return -parse_factor(ts, pos)
    if isinstance(t, Num):
        pos[0] += 1
        return t.n
    if isinstance(t, LParen):
        pos[0] += 1
        v = parse_expr(ts, pos)
        if not isinstance(_peek(ts, pos), RParen):
            raise Syntax()
        pos[0] += 1
        return v
    raise Syntax()


def calc(s: str) -> int:
    ts = tokenize(s)
    pos = [0]
    v = parse_expr(ts, pos)
    if pos[0] != len(ts):
        raise Syntax()
    return v

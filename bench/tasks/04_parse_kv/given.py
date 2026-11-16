class KvErr(Exception):
    pass


class MissingEq(KvErr):
    def __init__(self, at: int):
        super().__init__(at)
        self.at = at


class EmptyKey(KvErr):
    def __init__(self, at: int):
        super().__init__(at)
        self.at = at


class BadValue(KvErr):
    def __init__(self, key: str):
        super().__init__(key)
        self.key = key


def catch(f):
    """Run f(); return the exception it raised, or None."""
    try:
        f()
    except Exception as e:
        return e
    return None

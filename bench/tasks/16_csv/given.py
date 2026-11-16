from typing import List


class CsvErr(Exception):
    pass


class Unterminated(CsvErr):
    pass


class JunkAfterQuote(CsvErr):
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

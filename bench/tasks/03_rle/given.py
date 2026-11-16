class RleErr(Exception):
    pass


class LeadingDigit(RleErr):
    pass


class ZeroCount(RleErr):
    pass


def catch(f):
    """Run f(); return the exception it raised, or None."""
    try:
        f()
    except Exception as e:
        return e
    return None

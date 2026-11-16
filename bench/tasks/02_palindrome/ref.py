def is_palindrome(s: str) -> bool:
    cs = [c for c in s.lower() if ("a" <= c <= "z") or ("0" <= c <= "9")]
    return cs == cs[::-1]

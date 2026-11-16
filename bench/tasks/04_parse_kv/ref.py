import re


def parse_kv(s: str) -> dict[str, int]:
    m: dict[str, int] = {}
    for i, seg in enumerate(s.split(";")):
        if seg.strip() == "":
            continue
        if "=" not in seg:
            raise MissingEq(i)
        key, val = seg.split("=", 1)
        key, val = key.strip(), val.strip()
        if key == "":
            raise EmptyKey(i)
        if not re.fullmatch(r"-?[0-9]+", val):
            raise BadValue(key)
        m[key] = int(val)
    return m

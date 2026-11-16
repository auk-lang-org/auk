def split_csv(line: str) -> List[str]:
    fields: List[str] = []
    i = 0
    while True:
        f = []
        if i < len(line) and line[i] == '"':
            i += 1
            while True:
                if i >= len(line):
                    raise Unterminated()
                if line[i] == '"':
                    if i + 1 < len(line) and line[i + 1] == '"':
                        f.append('"')
                        i += 2
                    else:
                        i += 1
                        break
                else:
                    f.append(line[i])
                    i += 1
            if i < len(line) and line[i] != ",":
                raise JunkAfterQuote(i)
        else:
            while i < len(line) and line[i] != ",":
                f.append(line[i])
                i += 1
        fields.append("".join(f))
        if i >= len(line):
            return fields
        i += 1

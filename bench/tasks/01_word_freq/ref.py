def word_freq(text: str) -> dict[str, int]:
    m: dict[str, int] = {}
    for w in text.lower().split():
        m[w] = m.get(w, 0) + 1
    return m

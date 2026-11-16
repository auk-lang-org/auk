def group_by_len(words: List[str]) -> Dict[int, List[str]]:
    groups: Dict[int, List[str]] = {}
    for w in words:
        g = groups.setdefault(len(w), [])
        if w not in g:
            g.append(w)
    return {k: groups[k] for k in sorted(groups)}

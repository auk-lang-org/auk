def top_n(items: List[Item], n: int) -> List[str]:
    xs = sorted((i for i in items if i.qty > 0), key=lambda i: (-i.price * i.qty, i.name))
    return [i.name for i in xs[:n]]

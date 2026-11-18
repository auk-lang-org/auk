pub fn split(s: str): [text.Word] = s.split(" ").map(w => text.Word(w))

pub fn base_zero(): int = base.zero()

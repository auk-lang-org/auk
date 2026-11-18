pub enum Tok { Fn, Float(f: float), Int(n: int), Eof }
pub enum Fail { Bad(m: str) }

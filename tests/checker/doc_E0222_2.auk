struct P { x: int }
fn get(p: P?): int = p?.x else 0

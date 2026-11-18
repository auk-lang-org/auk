struct Hidden { x: int }
pub struct Pt { x: int, h: Hidden }
pub fn make(): Pt = Pt { x: 1, h: Hidden { x: 2 } }

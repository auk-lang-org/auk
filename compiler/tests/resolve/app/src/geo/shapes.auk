pub struct Point { x: int, y: int }
pub struct Circle { center: Point, r: float }
pub struct Rect { w: float, h: float }

pub fn unit(): Circle = Circle { center: app.ORIGIN, r: 1.0 }

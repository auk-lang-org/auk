enum Shape { Rect(w: int, h: int) }
fn width(s: Shape): int = match s {
  Rect(w, _) => w
}

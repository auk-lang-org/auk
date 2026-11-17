/// Drawing that keeps track of what changed (module `graphics.canvas`). A `Canvas` wraps a
/// `pixels.Frame`; its drawing calls record the rectangles they touch, and `show` sends just
/// those to the window (in one message), so redrawing a button costs a button, not a window.
///
///   var c = graphics.canvas.canvas(w, h, 0xffffff)
///   c.fill(0, 0, w, h, 0xf6f4ef)
///   c.text(&face, 20, 20, "Hello", 0x202020)
///   c.show(win)?                  // the first show sends everything
///   c.fill(20, 60, 200, 40, 0xffffff)
///   c.show(win)?                  // sends only the 200 by 40 rectangle
///
/// To draw into `c.frame` directly, call `mark` with the rectangle you changed.

pub struct Canvas {
  frame: pixels.Frame,
  dirty: [int],  // changed since the last show: x0, y0, x1, y1 (end-exclusive), four at a time
  all: bool,     // everything changed
}

/// Past this many separate rectangles, they're merged into one around them all.
let MAX_RECTS = 16

/// A `w` by `h` canvas filled with `color`. Its first `show` sends everything.
pub fn canvas(w: int, h: int, color: int): Canvas =
  Canvas { frame: pixels.frame(w, h, color), dirty: [], all: true }

pub fn width(c: Canvas): int = c.frame.width()

pub fn height(c: Canvas): int = c.frame.height()

/// Start over at a new size (after a `gui.Resize`): a fresh frame of `color`, all to be shown.
pub fn resize(c: var Canvas, w: int, h: int, color: int) {
  c.frame = pixels.frame(w, h, color)
  c.dirty = []
  c.all = true
}

fn lo(a: int, b: int): int = if a < b { a } else { b }

fn hi(a: int, b: int): int = if a > b { a } else { b }

/// Record that the `w` by `h` rectangle at (`x`, `y`) changed.
pub fn mark(c: var Canvas, x: int, y: int, w: int, h: int) {
  if c.all { return }
  let fw = c.frame.width()
  let fh = c.frame.height()
  var r = (hi(x, 0), hi(y, 0), lo(x + w, fw), lo(y + h, fh))
  if r.0 >= r.2 || r.1 >= r.3 { return }
  // merge with every rectangle it overlaps or touches, until none is left
  var merged = true
  while merged {
    merged = false
    var i = 0
    while i < c.dirty.len() {
      let d = (c.dirty[i], c.dirty[i + 1], c.dirty[i + 2], c.dirty[i + 3])
      if d.0 <= r.2 && r.0 <= d.2 && d.1 <= r.3 && r.1 <= d.3 {
        r = (lo(r.0, d.0), lo(r.1, d.1), hi(r.2, d.2), hi(r.3, d.3))
        c.dirty = c.dirty[0..i] + c.dirty[i + 4..c.dirty.len()]
        merged = true
      } else {
        i += 4
      }
    }
  }
  if (r.2 - r.0) * (r.3 - r.1) * 2 >= fw * fh {
    mark_all(&c)
    return
  }
  c.dirty = c.dirty + [r.0, r.1, r.2, r.3]
  if c.dirty.len() > MAX_RECTS * 4 {
    var b = (fw, fh, 0, 0)
    for i in 0..c.dirty.len() / 4 {
      let k = 4 * i
      b = (
        lo(b.0, c.dirty[k]),
        lo(b.1, c.dirty[k + 1]),
        hi(b.2, c.dirty[k + 2]),
        hi(b.3, c.dirty[k + 3]),
      )
    }
    c.dirty = [b.0, b.1, b.2, b.3]
  }
}

/// Record that everything changed.
pub fn mark_all(c: var Canvas) {
  c.all = true
  c.dirty = []
}

/// Whether anything changed since the last `show`.
pub fn changed(c: Canvas): bool = c.all || c.dirty.len() > 0

/// What `show` would send: rectangles as `x, y, w, h`, four ints at a time. When the changes
/// cover most of the canvas, that's the whole canvas.
pub fn changes(c: Canvas): [int] {
  let fw = c.frame.width()
  let fh = c.frame.height()
  if c.all { return [0, 0, fw, fh] }
  var out: [int] = []
  var area = 0
  for i in 0..c.dirty.len() / 4 {
    let k = 4 * i
    let w = c.dirty[k + 2] - c.dirty[k]
    let h = c.dirty[k + 3] - c.dirty[k + 1]
    out = out + [c.dirty[k], c.dirty[k + 1], w, h]
    area += w * h
  }
  // many rectangles adding up to most of the window: one copy of it all is as cheap
  if area * 5 >= fw * fh * 3 { [0, 0, fw, fh] } else { out }
}

/// Show what changed in window `win` and start recording afresh. Nothing is sent if nothing
/// changed.
pub fn show(c: var Canvas, win: int): ()! uses gui {
  if !changed(c) { return }
  gui.present_rects(win, c.frame, changes(c))?
  c.dirty = []
  c.all = false
}

// ---- drawing, as `pixels` does it, recording what it touches ----

pub fn fill(c: var Canvas, x: int, y: int, w: int, h: int, color: int) {
  c.frame.fill(x, y, w, h, color)
  mark(&c, x, y, w, h)
}

pub fn blend(c: var Canvas, x: int, y: int, w: int, h: int, color: int) {
  c.frame.blend(x, y, w, h, color)
  mark(&c, x, y, w, h)
}

pub fn blit(c: var Canvas, x: int, y: int, src: pixels.Frame, sx: int, sy: int, w: int, h: int) {
  c.frame.blit(x, y, src, sx, sy, w, h)
  mark(&c, x, y, w, h)
}

pub fn composite(
  c: var Canvas,
  x: int,
  y: int,
  src: pixels.Frame,
  sx: int,
  sy: int,
  w: int,
  h: int,
) {
  c.frame.composite(x, y, src, sx, sy, w, h)
  mark(&c, x, y, w, h)
}

pub fn set(c: var Canvas, x: int, y: int, color: int) {
  c.frame.set(x, y, color)
  mark(&c, x, y, 1, 1)
}

/// Draw `text` with `face` (see `graphics.font.draw`), the top-left of its first line at
/// (`x`, `y`); returns the x where the last line ends. It marks the text's box with a margin
/// for glyphs that reach outside it (accents, descenders, overhangs).
pub fn text(c: var Canvas, face: var graphics.font.Face, x: int, y: int, s: str, color: int): int {
  let end = face.draw(&c.frame, x, y, s, color)
  let (w, h) = face.measure(s)
  let pad = int(ceil(face.size / 4.0))
  mark(&c, x - pad, y - pad, w + 2 * pad, h + 2 * pad)
  end
}

// ---- tests ----

test "a new canvas shows everything once" {
  var c = canvas(100, 50, 0)
  assert changed(c) && changes(c) == [0, 0, 100, 50]
  c.all = false
  assert !changed(c) && changes(c) == []
}

test "changes are clipped and merged" {
  var c = canvas(100, 100, 0)
  c.all = false
  c.fill(-5, -5, 10, 10, 1)  // clipped to 5 by 5 at the corner
  c.fill(90, 90, 20, 20, 2)  // clipped to 10 by 10
  assert changes(c) == [0, 0, 5, 5, 90, 90, 10, 10]
  c.fill(4, 0, 6, 3, 3)  // overlaps the first: merged
  assert changes(c) == [90, 90, 10, 10, 0, 0, 10, 5]
  c.fill(10, 0, 5, 5, 4)  // touches the merged one: merged too
  assert changes(c) == [90, 90, 10, 10, 0, 0, 15, 5]
  c.fill(200, 200, 5, 5, 5)  // outside: nothing
  assert changes(c) == [90, 90, 10, 10, 0, 0, 15, 5]
}

test "big changes become everything" {
  var c = canvas(100, 100, 0)
  c.all = false
  c.fill(0, 0, 100, 50, 1)  // half the canvas
  assert changes(c) == [0, 0, 100, 100]
  c.all = false
  c.dirty = []
  // separate rectangles adding up to over 60%: the whole canvas too
  for i in 0..7 { c.fill(i * 14, 0, 12, 90, 1) }
  assert changes(c) == [0, 0, 100, 100]
}

test "many small changes collapse into one rectangle" {
  var c = canvas(1000, 1000, 0)
  c.all = false
  // the 17th collapses the first 17 into one rectangle; later ones start a new list
  for i in 0..20 { c.set(i * 10, 500 + i * 2, 7) }
  assert changes(c) == [0, 500, 161, 33, 170, 534, 1, 1, 180, 536, 1, 1, 190, 538, 1, 1]
}

test "text marks its box with a margin" {
  let f = graphics.font.parse(graphics.font.test_font())?
  var face = graphics.font.face(f, 10.0)
  var c = canvas(100, 40, 0xffffff)
  c.all = false
  let end = c.text(&face, 20, 10, "AA", 0)
  assert end == 31
  // "AA" measures 11 by 10; the margin is 3 (10 px / 4, rounded up)
  assert changes(c) == [17, 7, 17, 16]
  assert c.frame.get(20, 14) == 0
}

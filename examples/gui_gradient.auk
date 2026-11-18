// A native window showing pixels drawn in Auk (M0 of docs/gui-plan.md).
// A gradient fills the window and a white square follows the mouse; resizing redraws it.
// Moving the square redraws only the area it left and the area it moved to, and the
// `graphics.canvas` shows only those.
// Close it with the close button, ⌘Q or Escape.
//
//   auk run examples/gui_gradient.auk            (or `auk run --live`, and edit `color`)
//   auk run examples/gui_gradient.auk --for 2000 (closes itself after 2 s; for tests)

fn color(x: int, y: int, w: int, h: int): int {
  let r = x * 255 / w
  let g = y * 255 / h
  let b = 255 - (x + y) * 255 / (w + h)
  r << 16 | (g << 8) | b
}

fn gradient(w: int, h: int): pixels.Frame {
  var px: [int] = []
  for y in 0..h {
    for x in 0..w { px.push(color(x, y, w, h)) }
  }
  pixels.from_list(w, h, px)
}

fn main(args: [str]): int! uses gui, time {
  let limit = match args {
    [_, "--for", ms] => int.parse(ms) else 0
    _ => 0
  }
  let start = time.now()
  let win = gui.open("auk: gradient", 480, 320)?
  var w = gui.width(win)
  var h = gui.height(win)
  var bg = gradient(w, h)
  var c = graphics.canvas.canvas(w, h, 0)
  c.blit(0, 0, bg, 0, 0, w, h)
  let s = int(gui.scale(win) * 12.0)
  var mx = -100
  var my = -100
  c.show(win)?
  var full = 1
  var partial = 0
  loop {
    if limit > 0 && time.now() - start > limit { break }
    match gui.next_event(win, if limit > 0 { 50 } else { -1 }) {
      some(gui.Close) => break
      some(gui.KeyDown(53, _, _)) => break  // Escape
      some(gui.Resize(nw, nh)) => {
        w = nw
        h = nh
        bg = gradient(w, h)
        c.resize(w, h, 0)
        c.blit(0, 0, bg, 0, 0, w, h)
        c.fill(mx - s, my - s, 2 * s, 2 * s, 0xffffff)
        c.show(win)?
        full += 1
      }
      some(gui.MouseMove(x, y)) => {
        // put the background back where the square was, then draw it where it is now
        // the canvas shows just the two squares' areas
        c.blit(mx - s, my - s, bg, mx - s, my - s, 2 * s, 2 * s)
        c.fill(x - s, y - s, 2 * s, 2 * s, 0xffffff)
        c.show(win)?
        partial += 1
        mx = x
        my = y
      }
      some(e) => print("{e}")
      none => {}
    }
  }
  gui.close(win)
  print("{full} full frames, {partial} partial; {gui.width(win)}x{gui.height(win)} after closing")
  0
}

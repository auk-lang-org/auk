/// Rasterizing (module `graphics.font.raster`): outlines to anti-aliased coverage masks by signed-area
/// accumulation (as font-rs and stb_truetype 2 do). Quadratic curves are flattened into lines;
/// each line adds the area it covers to an accumulation buffer, and a running sum over that buffer
/// gives each pixel's coverage. Overlapping contours add up (the nonzero rule, clamped).

/// A coverage mask: `w` by `h` values 0 to 255, rows top to bottom. Its top-left pixel sits at
/// (`x`, `y`) from the pen position on the baseline, y down.
pub struct Mask { w: int, h: int, x: int, y: int, a: [int] }

/// A mask with nothing in it.
pub let EMPTY = Mask { w: 0, h: 0, x: 0, y: 0, a: [] }

fn lo(a: float, b: float): float = if a < b { a } else { b }

fn hi(a: float, b: float): float = if a > b { a } else { b }

fn ilo(a: int, b: int): int = if a < b { a } else { b }

fn ihi(a: int, b: int): int = if a > b { a } else { b }

/// The mask of `contours` (font units, y up) scaled by `s` pixels per unit and moved `dx` pixels
/// right (for subpixel positioning).
pub fn mask(contours: [graphics.font.ttf.Contour], s: float, dx: float): Mask {
  var x0 = 1.0e9
  var y0 = 1.0e9
  var x1 = -1.0e9
  var y1 = -1.0e9
  for ct in contours {
    for i in 0..ct.xs.len() {
      let x = ct.xs[i] * s + dx
      let y = -ct.ys[i] * s
      x0 = lo(x0, x)
      x1 = hi(x1, x)
      y0 = lo(y0, y)
      y1 = hi(y1, y)
    }
  }
  if x1 < x0 { return EMPTY }
  // one spare column on the right for the area spilling past the last pixel
  let ox = int(floor(x0))
  let oy = int(floor(y0))
  let w = int(ceil(x1)) - ox + 2
  let h = int(ceil(y1)) - oy + 1
  var acc: [float] = []
  for _ in 0..w * h + 2 { acc.push(0.0) }
  let fx = float(ox)
  let fy = float(oy)
  for ct in contours {
    let n = ct.xs.len()
    if n == 0 { continue }
    let px = ct.xs.map(x => x * s + dx - fx)
    let py = ct.ys.map(y => -y * s - fy)
    // start at an on-curve point: the first, the last, or between them
    var sx = px[0]
    var sy = py[0]
    var from = 1
    var to = n
    if !ct.on[0] {
      if ct.on[n - 1] {
        sx = px[n - 1]
        sy = py[n - 1]
        to = n - 1
      } else {
        sx = (px[n - 1] + px[0]) / 2.0
        sy = (py[n - 1] + py[0]) / 2.0
      }
      from = 0
    }
    var cx = sx
    var cy = sy
    var ctrl = false
    var kx = 0.0
    var ky = 0.0
    for i in from..to {
      if ct.on[i] {
        if ctrl {
          quad(&acc, w, h, cx, cy, kx, ky, px[i], py[i])
        } else {
          line(&acc, w, h, cx, cy, px[i], py[i])
        }
        cx = px[i]
        cy = py[i]
        ctrl = false
      } else {
        if ctrl {
          let mx = (kx + px[i]) / 2.0
          let my = (ky + py[i]) / 2.0
          quad(&acc, w, h, cx, cy, kx, ky, mx, my)
          cx = mx
          cy = my
        }
        kx = px[i]
        ky = py[i]
        ctrl = true
      }
    }
    if ctrl { quad(&acc, w, h, cx, cy, kx, ky, sx, sy) } else { line(&acc, w, h, cx, cy, sx, sy) }
  }
  var a: [int] = []
  var sum = 0.0
  for i in 0..w * h {
    sum += acc[i]
    let v = abs(sum)
    a.push(if v >= 1.0 { 255 } else { int(v * 255.0 + 0.5) })
  }
  trim(Mask { w, h, x: ox, y: oy, a })
}

/// `m` cut down to the rows and columns with any coverage, so drawing it skips empty edges.
fn trim(m: Mask): Mask {
  var x0 = m.w
  var x1 = 0
  var y0 = m.h
  var y1 = 0
  for row in 0..m.h {
    for col in 0..m.w {
      if m.a[row * m.w + col] > 0 {
        x0 = ilo(x0, col)
        x1 = ihi(x1, col + 1)
        y0 = ilo(y0, row)
        y1 = ihi(y1, row + 1)
      }
    }
  }
  if x1 <= x0 { return EMPTY }
  var a: [int] = []
  for row in y0..y1 { a = a + m.a[row * m.w + x0..row * m.w + x1] }
  Mask { w: x1 - x0, h: y1 - y0, x: m.x + x0, y: m.y + y0, a }
}

fn quad(
  acc: var [float],
  w: int,
  h: int,
  x0: float,
  y0: float,
  x1: float,
  y1: float,
  x2: float,
  y2: float,
) {
  let ddx = x0 - 2.0 * x1 + x2
  let ddy = y0 - 2.0 * y1 + y2
  let dev = ddx * ddx + ddy * ddy
  if dev < 0.333 {
    line(&acc, w, h, x0, y0, x2, y2)
    return
  }
  let n = 1 + int(floor(sqrt(sqrt(3.0 * dev))))
  var px = x0
  var py = y0
  for i in 1..=n {
    let t = float(i) / float(n)
    let u = 1.0 - t
    let x = u * u * x0 + 2.0 * u * t * x1 + t * t * x2
    let y = u * u * y0 + 2.0 * u * t * y1 + t * t * y2
    line(&acc, w, h, px, py, x, y)
    px = x
    py = y
  }
}

fn line(acc: var [float], w: int, h: int, ax: float, ay: float, bx: float, by: float) {
  if ay == by { return }
  let (dir, x0, y0, x1, y1) = if ay < by { (1.0, ax, ay, bx, by) } else { (-1.0, bx, by, ax, ay) }
  let dxdy = (x1 - x0) / (y1 - y0)
  var x = x0
  if y0 < 0.0 { x -= y0 * dxdy }
  let xmax = float(w - 1)
  for yi in ihi(0, int(floor(y0)))..ilo(h, int(ceil(y1))) {
    let row = yi * w
    let fy = float(yi)
    let dy = lo(fy + 1.0, y1) - hi(fy, y0)
    let xnext = x + dxdy * dy
    let d = dy * dir
    let xa = hi(0.0, lo(xmax, lo(x, xnext)))
    let xb = hi(0.0, lo(xmax, hi(x, xnext)))
    let xa_floor = floor(xa)
    let ia = int(xa_floor)
    let ib = int(ceil(xb))
    if ib <= ia + 1 {
      // within one pixel: split by the midpoint
      let xm = 0.5 * (xa + xb) - xa_floor
      acc[row + ia] += d - d * xm
      acc[row + ia + 1] += d * xm
    } else {
      let s = 1.0 / (xb - xa)
      let fa = xa - xa_floor
      let a0 = 0.5 * s * (1.0 - fa) * (1.0 - fa)
      let fb = xb - float(ib) + 1.0
      let am = 0.5 * s * fb * fb
      acc[row + ia] += d * a0
      if ib == ia + 2 {
        acc[row + ia + 1] += d * (1.0 - a0 - am)
      } else {
        let a1 = s * (1.5 - fa)
        acc[row + ia + 1] += d * (a1 - a0)
        for xi in ia + 2..ib - 1 { acc[row + xi] += d * s }
        let a2 = a1 + float(ib - ia - 3) * s
        acc[row + ib - 1] += d * (1.0 - a2 - am)
      }
      acc[row + ib] += d * am
    }
    x = xnext
  }
}

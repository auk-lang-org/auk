
fn hx(n: int): str = "0123456789abcdef"[n / 16 % 16..n / 16 % 16 + 1] + "0123456789abcdef"[n % 16..n % 16 + 1]

// the transparency byte only when it isn't 0 (opaque)
fn hex(f: pixels.Frame): str = f.to_list().map(p => (if p >> 24 == 0 { "" } else { hx(p >> 24 & 255) + ":" }) + hx(p >> 16 & 255) + hx(p >> 8 & 255) + hx(p & 255)).join(" ")

fn row(f: pixels.Frame, y: int): pixels.Frame {
  var r = pixels.frame(f.width(), 1, 0)
  r.blit(0, 0, f, 0, y, f.width(), 1)
  r
}

async fn total(f: pixels.Frame): int = f.to_list().map(p => p & 255).sum()

fn main() {
  var f = pixels.frame(4, 3, 0x000000)
  f.fill(1, 1, 10, 10, 0xff0000)                      // clipped at the right and bottom
  print(hex(f))
  f.blend(0, 0, 2, 1, 0x7fffffff)                      // half white over black
  print(hex(row(f, 0)))
  let src = pixels.from_list(2, 2, [0x111111, 0x222222, 0x333333, 0x444444])
  f.blit(-1, 2, src, 0, 0, 2, 2)                       // half off the left and bottom
  print(hex(row(f, 2)))
  f.blit_mask(2, 0, [255, 0, 51, 128], 2, 0x00ff00)
  print(hex(row(f, 0)) + " / " + hex(row(f, 1)))
  var same = pixels.frame(3, 1, 0x0000ff)
  let before = same
  same.set(0, 0, 0xffffff)                             // copy-on-write: `before` keeps its pixels
  print("{hex(before)} / {hex(same)}")
  // transparency: a clear frame, half-transparent white composited onto opaque blue
  var t = pixels.frame(2, 1, pixels.CLEAR)
  t.set(0, 0, pixels.argb(128, 255, 255, 255))
  print(hex(t))
  var b = pixels.frame(2, 1, 0x0000ff)
  b.composite(0, 0, t, 0, 0, 2, 1)
  print(hex(b))
  b.blit(1, 0, b, 0, 0, 1, 1)                          // from itself
  print("{hex(b)} {await total(b)}")
}

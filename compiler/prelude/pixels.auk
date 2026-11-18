/// Frames: images of 32-bit pixels, drawn into natively (pure). `gui.present` shows them, and
/// the `graphics` package draws text and shapes into them.
///
/// A color is `0xTTRRGGBB`. The top byte is *transparency*: 0 is opaque, so a plain `0xRRGGBB`
/// is an opaque color, and `0xff000000` (`CLEAR`) is fully transparent. Alpha is `255 - T`,
/// straight (not premultiplied). Windows show frames opaque, ignoring transparency.
///
/// A `Frame` is a value like any other: assigning or passing it shares the pixels, and changing
/// one (through a `var`) copies them first if they're shared. That copy is easy to cause by
/// accident (a `let before = frame` still alive while you draw) and costly at window sizes:
/// `AUK_GUI_TRACE=1` reports copies of frames of 256K pixels or more, and where they happened. Rectangles are clipped to the
/// frame, so drawing partly or wholly outside it is fine.

/// A `width` by `height` image of colors, rows top to bottom.
pub extern type Frame = "AukFrame *"

/// Fully transparent.
pub let CLEAR = 0xff000000

/// The color with alpha `a` (0 transparent to 255 opaque) and channels `r`, `g`, `b` (0 to 255).
pub fn argb(a: int, r: int, g: int, b: int): int = (255 - a) << 24 | (r << 16) | (g << 8) | b

/// The color's alpha: 0 transparent to 255 opaque.
pub fn alpha(c: int): int = 255 - ((c >> 24) & 0xff)

/// A `w` by `h` frame filled with `color`.
pub extern fn frame(w: int, h: int, color: int): Frame = "auk_frame_new +loc"
/// A `w` by `h` frame of the colors `px`, rows top to bottom.
pub extern fn from_list(w: int, h: int, px: [int]): Frame = "auk_frame_from_list +loc"
/// The frame's colors, rows top to bottom.
pub extern fn to_list(f: Frame): [int] = "auk_frame_to_list"
pub extern fn width(f: Frame): int = "auk_frame_width"
pub extern fn height(f: Frame): int = "auk_frame_height"
/// The color at (`x`, `y`); panics outside the frame.
pub extern fn get(f: Frame, x: int, y: int): int = "auk_frame_get +loc"
/// Set the color at (`x`, `y`); panics outside the frame.
pub extern fn set(f: var Frame, x: int, y: int, color: int) = "auk_frame_set +loc"
/// Set the `w` by `h` rectangle at (`x`, `y`) to `color`, transparency included.
pub extern fn fill(f: var Frame, x: int, y: int, w: int, h: int, color: int) = "auk_frame_fill +loc"
/// Paint `color` over the rectangle, as transparent as `color` is.
pub extern fn blend(f: var Frame, x: int, y: int, w: int, h: int, color: int) = "auk_frame_blend +loc"
/// Copy the `w` by `h` rectangle at (`sx`, `sy`) of `src` to (`x`, `y`), transparency included.
pub extern fn blit(f: var Frame, x: int, y: int, src: Frame, sx: int, sy: int, w: int, h: int) = "auk_frame_blit +loc"
/// Paint the `w` by `h` rectangle at (`sx`, `sy`) of `src` over (`x`, `y`), by its transparency.
pub extern fn composite(f: var Frame, x: int, y: int, src: Frame, sx: int, sy: int, w: int, h: int) = "auk_frame_composite +loc"
/// Paint `color` through `mask` (coverage 0 to 255, `mw` per row) placed at (`x`, `y`): how text
/// glyphs are drawn.
pub extern fn blit_mask(f: var Frame, x: int, y: int, mask: [int], mw: int, color: int) = "auk_frame_blit_mask +loc"

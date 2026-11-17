# graphics

Graphics in pure Duck, drawn into `pixels.Frame`s (what `gui.present` shows). Two modules:

- **`graphics.canvas`**: a `Canvas` wraps a frame and records which rectangles its drawing calls change. `show(win)` sends only those to the window, in one message, so redrawing a button costs a button, not a window. Touching or overlapping changes are merged; past 16 separate rectangles they become one, and changes covering most of the canvas send it whole. To draw into `c.frame` directly, `mark` what you changed.
- **`graphics.font`**: TrueType text:
  - parse `.ttf` files and `.ttc` collections (`glyf` outlines, simple and composite; `cmap` formats 4 and 12)
  - rasterize glyphs into anti-aliased coverage masks (signed-area accumulation, as font-rs does), trimmed to their ink
  - draw text into `pixels` frames at quarter-pixel positions with pair kerning from the `kern` table or GPOS
  - measure text, and map between x positions and caret positions
  - find a sans-serif or monospaced font among the usual system fonts on macOS, Linux and Windows

A face caches each glyph mask and each line it has laid out, so redrawing a line is just blending its glyphs. Masks were checked against Core Text (`CTFontDrawGlyphs`, antialiased, no font smoothing): with glyphs at the same positions, the total coverage differs by 1.3% at 40 px and by 2.6–6.6% at 24 and 13 px.

Not yet: hinting, CFF outlines (`.otf`), complex shaping (Arabic, Indic), color glyphs, and line wrapping. Variable fonts draw their default instance.

**Effects:** `fs` (only `graphics.font.load`, `system_sans` and `system_mono`; `parse` takes bytes and is pure) and `gui` (only `Canvas.show`).

```duck
fn main(): int! uses gui, fs {
  let win = gui.open("hello", 400, 120)?
  var face = graphics.font.face(graphics.font.system_sans()?, 24.0 * gui.scale(win))  // pixels per em
  var c = graphics.canvas.canvas(gui.width(win), gui.height(win), 0xffffff)
  c.text(&face, 20, 20, "Hello, world", 0x202020)  // top-left of the line box
  c.show(win)?                                     // the first show sends it all
  var n = 0
  loop {
    match gui.next_event(win, -1) {
      some(gui.Close) => break
      some(gui.MouseDown(_, _, _, _)) => {
        n += 1
        c.fill(20, 70, 300, 40, 0xffffff)
        c.text(&face, 20, 70, "{n} clicks", 0x3b6fd6)
        c.show(win)?                               // sends just that strip
      }
      _ => {}
    }
  }
  0
}
```

`draw` takes the face as `var` because it fills the face's mask cache. Other functions: `ascent`, `descent`, `line_height`, `hit(face, line, x)` (the caret index nearest x), `caret_x(face, line, i)`, `glyph_index`, `advance`, `kern`, and the submodules `graphics.font.ttf` (tables and outlines) and `graphics.font.raster` (masks).

See `examples/gui_text.duck` for an editable line of text in a window, redrawn on a canvas.

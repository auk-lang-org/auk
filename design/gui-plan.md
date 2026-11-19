# Plan: the `gui` package

Native desktop windows with widgets drawn in pure Auk, an Elm-style API (state → view → update),
real TTF text, layout, and `auk run --live` support. It runs on macOS, Linux and Windows.

Decisions taken (2026-11-17): native window + Auk-drawn widgets; Elm-style; all three platforms
in v1; v1 includes widgets, layout, TTF text and live reload.

## 1. Shape of the work

Three layers, built bottom-up:

| layer | where | language | what it owns |
|---|---|---|---|
| **`gui` effect** | `runtime/src/gui/`, `compiler/prelude/gui.auk` | Rust + Auk externs | windows, presenting pixels, input events, clipboard, cursor shape, DPI |
| **drawing + text** | `packages/graphics/src/{canvas,font,font/ttf,font/raster}.auk` | Auk | shapes, clipping, TTF parsing, glyph rasterizing, the glyph cache, drawing and measuring text |
| **UI framework** | `packages/ui/src/{text,node,layout,widgets,app}.auk` | Auk | text layout, the widget tree, layout, hit-testing, focus, the Elm loop |

A package can't be called `gui`, because raft keeps core module names (`gui` is the effect's
module) out of package names. So drawing is the `graphics` package (its `graphics.font` module was
done in M3; the canvas of 3.1 goes in `graphics.canvas`), and the framework will be `ui`.

The runtime surface stays small and dumb: it never draws a widget. Everything you can see on screen
comes from Auk code, so it is the same on every platform and can be changed under `--live`.

## 2. Runtime layer: the `gui` effect

### 2.1 Approach: a window process, dlopen, no crates

**Done in M0 (revised after the spike).** The program never loads a window system. Its first
`gui.open` starts a *window process* (`runtime/src/gui_host.rs`): the same executable, run again
with `posix_spawn` (a fresh exec) and `AUK_GUI_HOST` set. `auk_main_wrapper` and the `auk`
command check for that variable first. The host owns every native window. The program talks to
it over a Unix socket (`gui.rs`, `mod wire`), and frames go through POSIX shared memory.

Why: the first spike ran AppKit inside the program, with Auk `main` moved off the main
thread. Under `auk run --live`, programs run in a child that was forked without exec, and
Apple's frameworks don't support that. It showed up as XPC "Connection invalid" errors, a
sign that text input and accessibility would break. A freshly exec'd host avoids that, frees
the program's main thread, and lets windows outlive a `--live` restart.

The host loads the system libraries with `dlopen`, as `audio_out.rs` does, so `auk_rt` adds no
dependencies:

| platform | window + events | presenting pixels | status |
|---|---|---|---|
| macOS | AppKit via `libobjc` (`objc_msgSend`, an NSView subclass made with `objc_allocateClassPair`) | two shared frame buffers per window; the window process copies what changed into one of two IOSurfaces and makes it the view layer's contents, which the compositor shows directly | **done (M0)** |
| Linux | Xlib (`libX11.so.6`), XIM for text input | `XPutImage` of the changed rectangle (MIT-SHM later) | M1 |
| Windows | `user32` message pump | `gdi32` `StretchDIBits` of the changed rectangle | MW |

### 2.2 Auk surface (`compiler/prelude/gui.auk`, `uses gui`)

Windows are **int ids** (the host's), so they can be copied between tasks. As built in M0:

```auk
pub extern fn open(title: str, w: int, h: int): int! uses gui
pub extern fn close(win: int) uses gui
pub extern fn width(win: int): int uses gui                // physical pixels
pub extern fn height(win: int): int uses gui
pub extern fn scale(win: int): float uses gui              // 2.0 on Retina
/// Copy only the w×h rectangle at (x, y) of the frame `f`; the rest stays.
pub extern fn present_rect(win: int, f: pixels.Frame, x: int, y: int, w: int, h: int): ()! uses gui
pub fn present(win: int, f: pixels.Frame): ()! uses gui    // the whole frame
pub fn next_event(win: int, ms: int): Event? uses gui      // 0 = poll, -1 = wait; cancellable
```

Still to add in M1: `set_title`, `set_cursor`, `clipboard_get`/`clipboard_set`,
`request_frame` (animations), and a `Key` enum in place of raw key codes.

`Event` is an enum: `Close`, `Resize(w, h)`, `MouseMove(x, y)`, `MouseDown(button, x, y, mods)`,
`MouseUp(...)`, `Scroll(dx, dy)`, `KeyDown(code, mods, repeat)`, `KeyUp(code, mods)`,
`Text(str)` (the only source of typed characters), `Focus(bool)`. It crosses the wire as
`[int]`, and `next_event` decodes it in Auk.

The pure core module **`pixels`** (`compiler/prelude/pixels.auk`, `runtime/src/pixels.rs`) has the
frame type and its hot loops. A **`pixels.Frame`** holds `w`×`h` 32-bit colors `0xTTRRGGBB`,
where the top byte is *transparency*: 0 is opaque, so a plain `0xRRGGBB` literal is an opaque
color, and `CLEAR` (`0xff000000`) is fully transparent. Alpha is `255 - T`, straight. Windows
show frames opaque.
- **The type.** `Frame` is an `extern type` (`AukFrame *`), a new runtime *handle* kind
  (`AUK_K_FRAME`, pixels stored inline after the header). It's shared by an atomic reference
  count, so it crosses tasks without copying and isn't swept with a crashed task's heap. Every
  write goes through a `var` parameter, and the runtime copies the frame first if it's shared, so
  a frame behaves like any other copy-on-write Auk value. The compiler passes an extern's `var`
  frame by address (as it does lists and maps; `TyInfo::is_cow_opaque`), so the runtime can swap
  in the copy. Handle types like `net.Conn` still go by value.
- **Functions:** `frame(w, h, color)`, `from_list`/`to_list`, `width`, `height`, `get`/`set`
  (panic outside the frame), `fill` (sets, transparency included), `blend` (paints a color over
  by its transparency), `blit` (copies a rectangle of another frame, or of itself), `composite`
  (paints one over), `blit_mask` (a coverage mask in a color, for glyphs), and `argb(a, r, g, b)`
  / `alpha(c)`. Drawing is clipped.
- It's a module of its own because every extern in an effect's module must declare the effect
  (a resolve.rs test).

### 2.3 Processes and `--live`

- **Normally**, the host is the program's child on a socket pair, and it exits (closing its
  windows) when the program ends.
- **Under `auk run --live`**, the parent sets `AUK_GUI_SESSION` to a socket path. The first
  child starts a host listening there, and later children connect to the same one.
  - A child that ends without saying goodbye (killed for a restart, or crashed) leaves its
    windows open as orphans. The next child's `gui.open` with the same title takes the window
    over, with no close-and-reopen.
  - A child that returns normally sends `BYE`, and its windows close.
  - The next client to leave closes any orphans nobody took over.
  - The host exits when the live parent (`AUK_GUI_OWNER`) is gone, and removes the socket.
- The host inherits only the standard streams (`POSIX_SPAWN_CLOEXEC_DEFAULT`), so it never holds
  the program's sockets or files open across a restart.

### 2.4 Windows prerequisite

`auk_rt` only builds against Unix: pthreads, `libc::dlopen`, `nanosleep`, sockets, `mkdtemp`.
Supporting Windows in v1 means first porting the runtime and `auk build` linking to Windows
(threads, condvars, dlopen → `LoadLibraryW`, Winsock, file APIs, the panic/`catch.c` path,
the Windows calling convention in the C-ABI classifier, and the x64 COFF object + linker step). That is a
separate project in its own right, so it is milestone **MW**, run alongside the GUI work. The GUI
backend for Windows (`user32`/`gdi32`) is small once the runtime builds.

## 3. Drawing and text (pure Auk)

### 3.1 Canvas (`graphics.canvas`)

```auk
pub struct Canvas { w: int, h: int, px: [int], clip: Rect }
fn fill_rect(c: var Canvas, r: Rect, color: int)
fn fill_rrect(c: var Canvas, r: Rect, radius: float, color: int)  // anti-aliased corners
fn stroke_rect / line / fill_circle / blend(src over dst) / blit(alpha mask, color)
fn push_clip / pop_clip
```

Colors are `pixels` colors (`0xTTRRGGBB`, the top byte transparency) with straight alpha, blended
in sRGB at first. Gamma-correct blending
is a later tweak. Hot loops are written so the back end can compile them tightly (int maths, no
closures per pixel). Measure early: a 1600×1000 full redraw is 1.6M pixels.

### 3.2 Text: `graphics.font` (done in M3) and layout in `ui`

**Done** (`packages/graphics/src/font.auk` and `font/`, `examples/gui_text.auk`):
- **Parsing:** `.ttf` and `.ttc`; the tables `head`, `hhea`, `maxp`, `cmap` (formats 4 and 12),
  `loca`, `glyf` (quadratic outlines, composite glyphs with all their transforms), `hmtx`, `kern`
  (format 0) and GPOS pair kerning (PairPos formats 1 and 2, through extension lookups, from the
  `kern` feature). `parse(bytes)` is pure; `load(path)`, `system_sans()` and `system_mono()` use `fs`.
  Variable fonts draw their default instance.
- **Rasterizing:** signed-area accumulation (as font-rs does). Curves are flattened into lines,
  their area is accumulated, and a running sum gives anti-aliased 8-bit coverage. A glyph takes
  well under a millisecond, so it stays in Auk.
- **Glyph cache:** in a `Face` (a font at a pixel size), keyed on (glyph, x offset in quarter
  pixels). The masks are drawn with `pixels.blit_mask`. Faces also cache char→glyph lookups and
  kerning pairs.
- **Drawing and measuring:** `draw(&face, &px, stride, x, y, text, color)` (the top-left of the line
  box; `\n` starts a line), `measure`, `ascent`/`descent`/`line_height`, and caret mapping (`hit`,
  `caret_x`).
- **Testing:** unit tests on a font built in the test file check the parsing and exact coverage
  (whole and half pixels, curve areas). Masks were checked against Core Text, since no
  stb_truetype or FreeType was at hand: `CTFontDrawGlyphs`, antialiased, no smoothing, glyphs at
  the same positions. The total coverage differs by 1.3% at 40 px and by 2.6–6.6% at 24 and 13 px.
  A package test pins Arial's ink at 40 px to Core Text's within 1.5%.

**Still to do:**
- **Layout (M4, in `ui`):** line breaking at spaces and UAX-14-lite break points, wrapping to a
  width, and ellipsis truncation. There's no complex shaping (Arabic, Indic) in v1. That's a known
  limit.
- **Default font:** bundle a small OFL sans (an Inter or Noto Sans subset) as a byte constant via
  `imprint`, so text works with no system fonts. For now `system_sans()` looks in the usual places
  (Arial on macOS; DejaVu, Liberation or Noto on Linux; Segoe UI on Windows). Bundling means
  downloading the font, so it waits for a go-ahead.
- Later: hinting (or at least stem darkening at small sizes), CFF outlines, color glyphs.

## 4. UI framework

### 4.1 The Elm loop (`app.auk`)

```auk
enum Msg { Inc, Dec, Name(str) }
struct Model { n: int, name: str }

fn update(m: Model, msg: Msg): Model = match msg {
  Inc => { ..m, n: m.n + 1 }
  Dec => { ..m, n: m.n - 1 }
  Name(s) => { ..m, name: s }
}

fn view(m: Model): gui.Node<Msg> = gui.column([
  gui.text("Hello, {m.name}").size(24),
  gui.input(m.name, s => Name(s)).placeholder("your name"),
  gui.row([gui.button("-", Dec), gui.text("{m.n}"), gui.button("+", Inc)]).gap(8),
]).pad(16)

fn main(): int! uses gui {
  gui.run(gui.App { title: "counter", size: (400, 300), init: () => Model { n: 0, name: "" },
                    update: update, view: view })?
  0
}
```

`gui.run` opens the window (or adopts it, see 4.5), then loops: read the event, hit-test it
against the last layout, turn it into a `Msg` through the node's handler, run `update`, run
`view`, lay out, paint, present. Side effects come through
`update_with(m, msg): (Model, [gui.Cmd<Msg>])`, with commands for timers, clipboard, opening a
file, quitting, or running a task whose result becomes a `Msg`. This matches Elm's `Cmd` and keeps
`update` pure.

Widget-local state (the caret position, a scroll offset, hover and pressed states, which widget
has focus) lives in a framework-owned table keyed by each node's **path plus an optional
`.key(k)`**, like splash's keyed lists. That keeps the user's `Model` free of UI bookkeeping.

### 4.2 Nodes and layout (`node.auk`, `layout.auk`)

- `Node<Msg>` is an enum of a few primitives: `Box` (children, direction, padding, gap, align,
  background, border, radius), `Text`, `Image`, `Spacer`, `Scroll`, `Custom` (a paint fn plus a
  size fn, as an escape hatch). Widgets are Auk functions that build these. There are no widget
  classes.
- Layout is flexbox-lite, done in a single measure pass and a single place pass: row and column
  directions, `gap`, `pad`, `align`/`justify`, `grow(n)`, `width`/`height` as fixed, fill, or fit
  to content, and min/max sizes. Text wraps to the width it is given. No grid in v1.
- Every size is in logical units, multiplied by `gui.scale(win)` when painting, so Retina and
  high-DPI Windows come out crisp.

### 4.3 Widgets for v1 (`widgets.auk`)

`text`, `button`, `input` (single line: caret, selection, mouse selection, clipboard, word jumps
with Opt/Ctrl+arrow, Home/End, undo later), `checkbox`, `radio`, `slider`, `select` (a popup drawn
in the same window as an overlay layer), `list` (a keyed, virtualized scroll list), `scroll`,
`image` (from `[int]` pixels), `divider`, `tooltip`. Keyboard focus moves with Tab/Shift-Tab, and
Space/Enter activate the focused widget. There is one default theme (light and dark, read from a
`gui.Theme` struct) that can be overridden.

### 4.4 Redrawing

Damage tracking is part of v1, not an afterthought. The M0 numbers (below) showed that full
repaints on a Retina display are too slow to do on every change. So the framework will:
(1) skip a frame when the new view is identical to the last one (`Eq` on `Node`),
(2) diff the old and new layout boxes into damage rectangles, repaint only those (clipped), and
show them with `present_rect`, and later (3) keep a cached raster for subtrees that didn't
change. All drawing goes through `pixels` (native fills, blends and blits), never per-pixel
Auk loops.

M0 measurements (M-series Mac, 1600×1000 points = 2940×1612 pixels):

| | Auk loop / first spike | now |
|---|---|---|
| draw a full frame | 38–41 ms (`push` per pixel) | 3 ms (`pixels.new` + 40 `fill`s + 40 `blend`s) |
| show a full frame | 10 ms | 2 ms (built), 5 ms (`auk run`) |
| show a 48×48 change | 10 ms (always full) | 15 µs (built), 30 µs (`auk run`) |

Animations use `request_frame` and `Frame` events, and the loop sleeps while nothing is happening.

**Performance pass (after M3).** `examples/gui_bench.auk` times each stage in a real window, and
`AUK_GUI_TRACE=1` makes the window process print how long copying into surfaces, waiting for its
main thread, and handling requests take, and makes the program report big implicit frame copies. `AUK_GUI_SNAP=path` makes it save an image of a window
as it closes (`CGWindowListCreateImage` of its own window, which needs no screen-recording
permission), so a test can check what's really on screen. What changed:
- **Double-buffered, pipelined `present`.** Each window has two shared buffers. `present` writes
  the one the window process isn't showing, sends `PRESENT` and returns without waiting. It waits
  for the previous `PRESENTED` only before writing a buffer again, so Auk draws the next frame
  while the window process handles this one. A buffer catches up on what changed in the other
  one since it was last written, skipping what the new rectangle covers. The window process no
  longer keeps its own copy of the frame.
- **`pixels`:** `blit` no longer copies its whole source on every call (it did, in case the source
  was the frame itself: 38 MB per 48×48 blit from a full-window background, as `gui_gradient`
  does on every mouse move). `blit_mask` and `blend` work a row at a time with a division-free
  `/255` and precomputed colour terms, and give the same results as before.
- **`graphics.font`:** a face caches glyphs and masks in arrays rather than maps, looks each
  character up once per draw, and skips kerning for fonts that have none.

Measured on the same 2940×1612 frame (best of several runs; another build was loading the
machine, so single runs vary by ±50%):

| | before | after |
|---|---|---|
| full UI frame (fill + 47 lines of text + present) | 4.3 ms | 2.0–2.3 ms |
| `present`, whole frame | 2.0–2.3 ms | 1.2–1.4 ms |
| text, 47 lines × 75 chars | 1.3–1.6 ms | 0.9–1.1 ms |
| `blit_mask`, a 30×23 glyph | 1.66 µs | 0.54 µs |
| `blend`, whole frame | 7 ms | 3.9 ms |
| `blit` 48×48 from a full-frame source | ~1 ms (copied the source) | under 1 µs |

Tried and dropped: splitting fills and conversions across threads. One core already saturates
memory bandwidth (a full frame of `[int]` is 38 MB), so threads didn't help.

**Second pass.**
- **IOSurfaces instead of `drawRect:`.** Drawing a CGImage over shared memory made Core Graphics
  copy the *whole* frame on every `drawRect:` (1.3 ms), even for a 48×48 change. Now each view
  hosts a CALayer whose contents are one of two IOSurfaces owned by the window process. A present
  copies only the changed rectangle, plus what that surface missed since it was last shown, from
  the client's buffer into the back surface, then makes it the layer's contents. The compositor
  shows it directly, with no drawing step. The surfaces are tagged sRGB, so colours come out as
  before (the snapshot test reads back within 2 levels).
- **Never waiting for the compositor.** It keeps the last surface it showed until the next
  display refresh. Waiting for it capped presents at about 2.4 ms each. Now a present whose back
  surface is still in use is recorded and answered at once. It's shown about 1 ms later, merged
  with any presents that arrived in between and copied from the newest buffer. This is safe
  because the window process reads only the buffer of the latest present, and the client leaves
  that buffer alone until its next present is answered.
- **Laid-out lines in `graphics.font`.** A face caches each line it has drawn (each glyph's mask
  and position), so redrawing a known string is just `blit_mask` calls: 13–14 µs per 75-character
  line against 18–19 µs, measured side by side. Profiling shows 95% of `draw` is now inside
  `blit_mask`, at about 0.5 ns per pixel.
- **A test of what's on screen:** `gui_window_shows_the_frame` (ignored, macOS) snapshots
  `gui_gradient`'s window and checks its colours.

After both passes, best of several runs (the machine was loaded):

| | start | after pass 1 | after pass 2 |
|---|---|---|---|
| full UI frame (fill + 47 lines of text + present) | 4.3 ms | 2.0–2.3 ms | 1.9–2.0 ms |
| `present`, whole frame | 2.0–2.3 ms | 1.2–1.4 ms | 0.74–0.88 ms |
| `present_rect`, 48×48 | 36–100 µs | 60–100 µs | 17–20 µs |
| text, 47 lines × 75 chars | 1.3–1.6 ms | 0.9–1.1 ms | 0.7 ms |
| window process, per present | ~1–2 ms (copy, then `drawRect:`) | 1.3 ms per `drawRect:` | the changed area's copy (µs for small ones) |

**Third pass: 4-byte frames.** Frames were `[int]`, 8 bytes per pixel. Now they're
`pixels.Frame`s (2.2) at 4, so:
- clearing a frame writes half the memory: 4-byte fills ran 0.44 ms against 0.81–0.90 ms for
  `[int]` in the same process;
- `present` copies 4-byte rows (setting the top byte to opaque) instead of converting `[int]`:
  1.5–1.8× faster in the same process;
- `blend` takes a loop without branches when a row is all opaque, and works out red and blue
  together in one 32-bit multiply (exact; a unit test checks it against per-channel maths). Side
  by side it's about 5× faster than the old loop;
- glyph masks are trimmed to their ink when they're made, so `blit_mask` skips empty edges.
Text drawing measured the same as before (43–48 µs a line against 42–48, old and new binaries
side by side): it's bound by the blending of each glyph pixel, not by memory.

The machine was heavily loaded during this pass (load average 8–15, and the display changed to
3200×2000), so only the side-by-side comparisons above are reliable. `gui_bench` on 6.4 M pixels:
fill 0.34–0.42 ms, a whole-frame present 1.5 ms, a 48×48 present 33–46 µs.

**Fourth pass: drawing less.**
- **`graphics.canvas`.** A `Canvas` wraps a frame. Its drawing calls (`fill`, `blend`, `blit`,
  `composite`, `set`, and `text` with a margin for glyphs reaching outside their box) record the
  rectangles they change, and `show(win)` sends just those. Touching or overlapping changes are
  merged as they come; past 16 separate rectangles they collapse into one, and changes covering
  over 60% of the canvas (or one covering half) send it whole. `ui` will draw on it, so damage
  tracking (point 2 above) is just a matter of drawing only what changed. `gui_text` now redraws
  only the input box and the status line after an edit.
- **`gui.present_rects`** sends several rectangles in one message: one round trip however many
  areas changed. `present_rect` is a call of it.
- **Text:** `blit_mask` takes a loop without branches for each row whose pixels are all opaque
  (exact: coverage 0 leaves a pixel alone and 255 gives the color), 1.3–1.6× faster per line.
  Tried and dropped: run-length glyph masks (skipping empty runs, filling solid ones). At text
  sizes most glyph pixels are anti-aliased edges, so the run bookkeeping cost more than it saved
  (7 against 4 µs a line at 15 px).
- **Accidental copies:** under `AUK_GUI_TRACE=1`, copying a shared frame of 256K pixels or more
  before a write is reported with the call site (`pixels.fill at app.auk:12:3: copied a shared
  1000x1000 frame (4 MB) ...`): the first 20, then a count every 100.

The machine's load average was 9–27 during this pass, so only same-run comparisons count:
redrawing and showing one line of a full screen of text on a canvas took 0.27–0.37 ms, against
12–14 ms for redrawing and showing the whole screen, about 40× less.

### 4.5 Live reload

- The app loop runs as a task under `sup` (as splash's sessions do). The window id lives outside
  it, in `main`, and is passed to the task, so a task restart **reuses the open window**. A
  whole-program restart (exit 75) also keeps the window, because the window process outlives
  the child and the new `gui.open` takes it over (2.3).
- **Code change, same Model shape:** the next `view` call goes through the live table and picks
  up the new code. `gui.run` also checks `reloads()` after each event and re-renders when it
  changes, so a view edit shows up without any input.
- **Model shape changed:** live reload cancels the app task (which can hold the type), `sup`
  restarts it from `init()`, and it adopts the existing window.
- **A panic in `update` or `view`:** the task restarts and an error overlay is drawn in the
  window ("view panicked: …, fix and save"), like splash's self-check.
- Planned: keep the model across shape changes when `Model` derives `Data`, by trying
  `from_value(old.to_value())` with defaults for new fields. Needs a check on how `Data` handles
  missing fields.

## 5. Milestones

Each milestone ends with an example in `examples/` and tests. It's committed separately as
`gui 0.x`, like splash's.

| # | milestone | done when |
|---|---|---|
| **M0** ✅ | **macOS spike**: the window process, shared-memory `present_rect`, the `pixels` module, `--live` window takeover | `examples/gui_gradient.auk` runs under `auk run`, `auk build` and `auk run --live` (no XPC errors; a restart keeps window 1); `tests/run.rs` covers `pixels` and (ignored) a real window |
| M1 | `gui` effect on macOS + Linux/X11: open/close/present/events/scale/cursor/clipboard | `examples/gui_paint.auk` (draw with the mouse) works on both |
| M2 | canvas: rects, rounded rects, lines, circles, clip, alpha | golden-image tests (PNG-free: compare frames with a hash and dump PPM on failure) |
| **M3** ✅ | **TTF parse + rasterize + glyph cache** (`graphics.font`); the bundled font is still to do | masks within tolerance of Core Text for a reference set; `examples/gui_text.auk` |
| M4 | text layout: measure, wrap, caret mapping, ellipsis | unit tests for line breaks and caret positions |
| M5 | nodes, layout, hit-testing, the Elm loop, `Cmd` | the counter example above runs |
| M6 | widgets + focus + keyboard nav + theme | `examples/gui_form.auk` (every widget) |
| M7 | live reload: window adoption, `sup` restart, error overlay | editing `view` and `Model` while the app runs behaves as described in 4.5 |
| M8 | redraw optimisations beyond damage rects (subtree raster cache) | profiled: typing in an input redraws less than 5% of a 1600×1000 window |
| **MW** | **runtime on Windows** (alongside M1–M8), then the `user32`/`gdi32` backend | `tests/run.rs` passes on Windows; every `examples/gui_*` runs there |
| M9 | docs: `packages/ui/README.md`, spec entry for `uses gui`, the VS Code snippets | — |

## 6. Testing

- **Without a display:** the framework is pure apart from the effect, so most tests drive
  `gui.step(app, model, event, size): (Model, Canvas)` directly and check the model or the
  pixels. No window or CI display is needed.
- **Runtime backends:** a small `runtime/tests/gui.rs` that opens a hidden/offscreen window where
  possible (Xvfb on Linux CI) and checks that present + resize + close don't leak or crash.
- **Text:** a reference-mask comparison suite (3.2).
- **Performance:** a benchmark example that times a full repaint at 1600×1000, tracked across
  milestones.

## 7. Risks and open questions

1. **macOS main thread / `--live` fork:** resolved in M0 by the window process (2.1, 2.3). The
   cost is one IPC round trip per `present` (15–30 µs for small changes).
2. **Windows runtime port (2.4):** probably bigger than the GUI backend itself. It might be
   better as its own plan doc.
3. **Pixel throughput in Auk:** measured in M0 (4.4). Per-pixel Auk loops are about 10× too
   slow for full frames, hence `pixels` and damage tracking. The TTF rasterizer (M3) produces
   coverage masks in Auk once per glyph and size. After that, `blit_mask` draws them, so it
   should stay off the per-frame path.
4. **Wayland:** XWayland covers v1. A native Wayland backend with `dlopen` means writing the
   xdg-shell protocol glue by hand. It's deferred.
5. **Text input via IME:** NSTextInputClient on macOS, XIM on X11, WM_IME_* on Windows. v1 at
   least handles composed `Text` events and dead keys. Inline preedit display is deferred.
6. **Accessibility:** an Auk-drawn UI is invisible to screen readers. This is out of scope for
   v1 but worth noting. The fix later would be exposing the node tree through NSAccessibility,
   AT-SPI and UIA.
7. **Effect name:** `gui` (matches the package name) or `window`/`display`. The plan assumes
   `gui`.

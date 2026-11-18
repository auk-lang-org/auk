# term

Terminal output: ANSI colors and styles (16, 256 and 24-bit color), stripping escapes,
ANSI-aware width and padding, tables, progress bars, spinners, cursor control, window titles and
hyperlinks.

Everything builds strings and is pure, except `enabled`, `println`, `eprintln` and `columns`.
Those use `env` to honour [`NO_COLOR`](https://no-color.org) and `FORCE_COLOR`, and to check whether output is a terminal.

**Effects:** `env` (only the four functions above). **Deps:** `text`.

```auk
fn main(): int uses env {
  term.println(term.bold(term.green("✓")) + " build finished")   // plain text when piped
  term.println(term.paint("warning", term.style().bold().fg(term.Yellow)) + ": 2 unused")

  let t = term.table(["package", "size"], [["json", "12 KB"], ["http", "48 KB"]])
    .align([term.Left, term.Right])
  print(t)
  // ╭─────────┬───────╮
  // │ package │  size │
  // ├─────────┼───────┤
  // │ json    │ 12 KB │
  // │ http    │ 48 KB │
  // ╰─────────┴───────╯

  for i in 0..=50 {
    eprint(term.CLEAR_LINE + term.progress("download", i, 50, term.columns()))
  }
  0
}
```

## API

Colors and styles:
- `enum Color { Default, Black, Red, Green, Yellow, Blue, Magenta, Cyan, White, BrightBlack … BrightWhite, Idx(n), Rgb(r, g, b) }`. `Idx` is the 256-color palette. Out-of-range values are clamped to 0–255.
- `struct Style { fg, bg, bold, dim, italic, underline, inverse, strike }`. `style()` has no attributes. The chainable setters are `fg(st, c)`, `bg(st, c)`, `bold(st)`, `dim`, `italic`, `underline`, `inverse` and `strike`.
- `paint(s, st)`: `s` wrapped in `st`'s codes and a reset. A reset inside `s` (from a nested `paint`) turns `st` back on, so styles nest.
- Shortcuts on strings: `bold(s)`, `dim`, `italic`, `underline`, `inverse`, `strike`, `fg(s, c)`, `bg(s, c)`, `black`, `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`, `white`, `gray`.
- `codes(st): str` is the raw SGR sequence, and `RESET` is `ESC[0m`.
- `color(name): Color!ColorErr` takes `red`, `bright-blue`/`bright_blue`, `gray`/`grey`, `default`, `#rrggbb`, `#rgb`, or `"0"`–`"255"`. `message(e)` describes a `ColorErr`.

Measuring:
- `strip(s)` removes CSI sequences (colors, cursor moves), OSC sequences (titles, hyperlinks) and two-char `ESC x` escapes.
- `width(s)`: terminal columns after stripping. CJK and emoji count 2 (via `text.width`).
- `pad_right(s, w)`, `pad_left(s, w)`, `center(s, w)`: these ignore escapes.

Output (`uses env`):
- `enabled()` / `enabled(fd)`: false if `NO_COLOR` is non-empty. Otherwise true if `FORCE_COLOR` is set and isn't `"0"`. Otherwise true if `fd` is a terminal and `TERM` isn't `dumb`.
- `println(s)` / `eprintln(s)`: print to stdout or stderr, stripping escapes when color is off for that stream.
- `columns(): int`: the terminal width, else `$COLUMNS`, else 80.

Cursor and screen (strings to print):
- `CLEAR_LINE` (`\r` plus erase line), `CLEAR_SCREEN`, `HIDE_CURSOR`, `SHOW_CURSOR`.
- `up(n)`, `down(n)`, `left(n)`, `right(n)`, `goto(row, col)` (1-based).
- `title(s)` sets the window title. `link(label, url)` makes an OSC 8 hyperlink; terminals without support show just the label.

Progress:
- `bar(done, total, w)`: a `w`-column bar with eighth-block resolution. `done` is clamped, and a `total` of 0 gives a full bar.
- `percent(done, total)`: 0–100.
- `progress(label, done, total, w)` gives `label [bar]  42% (21/50)`, exactly `w` columns wide. The bar is at least 10 columns, so a very small `w` makes the line wider than `w`.
- `spinner(i)`: frame `i` of a braille spinner. Any `i` works; it wraps.

Tables:
- `table(header, rows): Table`, then `.align([Align])` (`Left`, `Right`, `Center`; missing columns default to `Left`) and `.border(Border)`.
- `Border` is one of `Rounded` (the default), `Sharp`, `Ascii`, `Plain` (two-space gaps, no lines) or `Markdown` (GFM, with `|` in cells escaped).
- `render(t)` / `"{t}"` give the lines joined by `\n`, with no trailing newline.
- Cells may contain colors (not counted in widths) and `\n` (the cell spans lines). Short rows are padded. An empty header draws no header row.

Not yet: truncating styled text, color downgrading (true color → 256 → 16) for limited terminals, reading keys or raw mode.

/// Terminal output: ANSI colors and styles (16, 256 and 24-bit color), stripping escapes,
/// ANSI-aware width and padding, tables, progress bars, spinners, cursor control and
/// hyperlinks. Everything builds strings and is pure, except `enabled`, `println`, `eprintln`
/// and `columns`, which use `env` to honour `NO_COLOR`, `FORCE_COLOR` and whether output is a
/// terminal.

let ESC = "\u{1b}"
let CSI = "\u{1b}["

// ---- colors and styles ----

/// A foreground or background color. `Default` is the terminal's own color; `Idx` is the
/// 256-color palette (0-255); `Rgb` is 24-bit true color (0-255 each).
pub enum Color {
  Default,
  Black,
  Red,
  Green,
  Yellow,
  Blue,
  Magenta,
  Cyan,
  White,
  BrightBlack,
  BrightRed,
  BrightGreen,
  BrightYellow,
  BrightBlue,
  BrightMagenta,
  BrightCyan,
  BrightWhite,
  Idx(n: int),
  Rgb(r: int, g: int, b: int),
}

/// A set of text attributes. Build one from `style()` with the chainable setters:
/// `term.style().bold().fg(term.Red)`.
pub struct Style {
  fg: Color,
  bg: Color,
  bold: bool,
  dim: bool,
  italic: bool,
  underline: bool,
  inverse: bool,
  strike: bool,
}

/// No attributes: `paint(s, style()) == s`.
pub fn style(): Style = Style {
  fg: Default,
  bg: Default,
  bold: false,
  dim: false,
  italic: false,
  underline: false,
  inverse: false,
  strike: false,
}

pub fn fg(st: Style, c: Color): Style = Style { fg: c, ..st }
pub fn bg(st: Style, c: Color): Style = Style { bg: c, ..st }
pub fn bold(st: Style): Style = Style { bold: true, ..st }
pub fn dim(st: Style): Style = Style { dim: true, ..st }
pub fn italic(st: Style): Style = Style { italic: true, ..st }
pub fn underline(st: Style): Style = Style { underline: true, ..st }
pub fn inverse(st: Style): Style = Style { inverse: true, ..st }
pub fn strike(st: Style): Style = Style { strike: true, ..st }

fn base(c: Color): int? = match c {
  Black => some(0)
  Red => some(1)
  Green => some(2)
  Yellow => some(3)
  Blue => some(4)
  Magenta => some(5)
  Cyan => some(6)
  White => some(7)
  BrightBlack => some(60)
  BrightRed => some(61)
  BrightGreen => some(62)
  BrightYellow => some(63)
  BrightBlue => some(64)
  BrightMagenta => some(65)
  BrightCyan => some(66)
  BrightWhite => some(67)
  _ => none
}

fn byte(n: int): int = if n < 0 { 0 } else if n > 255 { 255 } else { n }

// The SGR parameters for color `c`, where `at` is 30 (foreground) or 40 (background).
fn color_params(c: Color, at: int): [str] = match c {
  Default => []
  Idx(n) => ["{at + 8}", "5", "{byte(n)}"]
  Rgb(r, g, b) => ["{at + 8}", "2", "{byte(r)}", "{byte(g)}", "{byte(b)}"]
  _ => ["{at + base(c)!}"]
}

/// The escape sequence that turns `st` on ("" for `style()`).
pub fn codes(st: Style): str {
  var ps: [str] = []
  if st.bold { ps.push("1") }
  if st.dim { ps.push("2") }
  if st.italic { ps.push("3") }
  if st.underline { ps.push("4") }
  if st.inverse { ps.push("7") }
  if st.strike { ps.push("9") }
  ps = ps + color_params(st.fg, 30) + color_params(st.bg, 40)
  if ps.len() == 0 { "" } else { CSI + ps.join(";") + "m" }
}

/// Resets every attribute.
pub let RESET = "\u{1b}[0m"

/// `s` in style `st`, followed by a reset. Resets inside `s` (from nested `paint` calls) turn
/// `st` back on, so `paint("a " + red("b") + " c", style().bold())` keeps " c" bold.
pub fn paint(s: str, st: Style): str {
  let on = codes(st)
  if on == "" || s == "" { return s }
  // a reset already at the end needs no re-enable before ours
  let inner = if s.ends_with(RESET) { s[0..s.len() - RESET.len()] } else { s }
  on + inner.replace(RESET, RESET + on) + RESET
}

/// `s` in color `c`.
pub fn fg(s: str, c: Color): str = paint(s, style().fg(c))
/// `s` on background `c`.
pub fn bg(s: str, c: Color): str = paint(s, style().bg(c))
pub fn bold(s: str): str = paint(s, style().bold())
pub fn dim(s: str): str = paint(s, style().dim())
pub fn italic(s: str): str = paint(s, style().italic())
pub fn underline(s: str): str = paint(s, style().underline())
pub fn inverse(s: str): str = paint(s, style().inverse())
pub fn strike(s: str): str = paint(s, style().strike())
pub fn black(s: str): str = fg(s, Black)
pub fn red(s: str): str = fg(s, Red)
pub fn green(s: str): str = fg(s, Green)
pub fn yellow(s: str): str = fg(s, Yellow)
pub fn blue(s: str): str = fg(s, Blue)
pub fn magenta(s: str): str = fg(s, Magenta)
pub fn cyan(s: str): str = fg(s, Cyan)
pub fn white(s: str): str = fg(s, White)
pub fn gray(s: str): str = fg(s, BrightBlack)

pub enum ColorErr { Unknown(name: str) }

pub fn message(e: ColorErr): str = match e {
  Unknown(n) =>
    "unknown color `{n}` (want a name like `red` or `bright-blue`, `#rrggbb`, `#rgb` or 0-255)"
}

/// A color from its name (`red`, `bright-blue`, `bright_blue`, `gray`/`grey`, `default`, case
/// ignored), a hex string (`#ff8800`, `#f80`) or a 256-palette index (`"208"`).
pub fn color(name: str): Color!ColorErr {
  let n = name.trim().lower().replace("_", "-").replace(" ", "-")
  match n {
    "default" => Default
    "black" => Black
    "red" => Red
    "green" => Green
    "yellow" => Yellow
    "blue" => Blue
    "magenta" => Magenta
    "cyan" => Cyan
    "white" => White
    "gray" => BrightBlack
    "grey" => BrightBlack
    "bright-black" => BrightBlack
    "bright-red" => BrightRed
    "bright-green" => BrightGreen
    "bright-yellow" => BrightYellow
    "bright-blue" => BrightBlue
    "bright-magenta" => BrightMagenta
    "bright-cyan" => BrightCyan
    "bright-white" => BrightWhite
    "#" + hex => from_hex(hex) else fail(Unknown(name))
    _ => {
      let i = int.parse(n) else fail(Unknown(name))
      if i < 0 || i > 255 { fail(Unknown(name)) }
      Idx(i)
    }
  }
}

fn hex_digit(c: char): int? = if c >= '0' && c <= '9' {
  some(int(c) - int('0'))
} else if c >= 'a' && c <= 'f' {
  some(int(c) - int('a') + 10)
} else {
  none
}

fn from_hex(h: str): Color? {
  var ds: [int] = []
  for c in h.chars() { ds.push(hex_digit(c)?) }
  match ds.len() {
    3 => some(Rgb(ds[0] * 17, ds[1] * 17, ds[2] * 17))
    6 => some(Rgb(ds[0] * 16 + ds[1], ds[2] * 16 + ds[3], ds[4] * 16 + ds[5]))
    _ => none
  }
}

// ---- stripping and measuring ----

/// `s` without ANSI escape sequences: CSI (`ESC [ ... final`, colors and cursor moves), OSC
/// (`ESC ] ... BEL` or `ESC ] ... ESC \`, titles and hyperlinks) and two-char `ESC x`.
pub fn strip(s: str): str {
  if !s.contains(ESC) { return s }
  let cs = s.chars()
  var out: [char] = []
  var i = 0
  while i < cs.len() {
    let c = cs[i]
    if c != '\u{1b}' {
      out.push(c)
      i += 1
      continue
    }
    i += 1
    if i >= cs.len() { break }
    let k = cs[i]
    i += 1
    if k == '[' {
      // parameter and intermediate bytes, then one final byte in @..~
      while i < cs.len() && !(cs[i] >= '@' && cs[i] <= '~') { i += 1 }
      i += 1
    } else if k == ']' {
      while i < cs.len() {
        if cs[i] == '\u{7}' {
          i += 1
          break
        }
        if cs[i] == '\u{1b}' && i + 1 < cs.len() && cs[i + 1] == '\\' {
          i += 2
          break
        }
        i += 1
      }
    }
  }
  str(out)
}

/// Terminal columns `s` takes once escapes are removed (CJK and emoji count 2).
pub fn width(s: str): int = text.width(strip(s))

fn spaces(n: int): str = if n > 0 { " ".repeat(n) } else { "" }

/// Pads `s` with spaces on the right to `w` columns, ignoring escapes.
pub fn pad_right(s: str, w: int): str = s + spaces(w - width(s))
/// Pads `s` with spaces on the left to `w` columns, ignoring escapes.
pub fn pad_left(s: str, w: int): str = spaces(w - width(s)) + s

/// Centers `s` in `w` columns (an odd extra space goes on the right), ignoring escapes.
pub fn center(s: str, w: int): str {
  let extra = w - width(s)
  if extra <= 0 { return s }
  spaces(extra / 2) + s + spaces(extra - extra / 2)
}

// ---- output ----

/// Whether colored output should go to stdout: false when `NO_COLOR` is set and non-empty,
/// true when `FORCE_COLOR` is set and isn't "0", else true when stdout is a terminal and `TERM`
/// isn't `dumb`. (https://no-color.org)
pub fn enabled(): bool uses env = enabled(1)

/// As `enabled()`, for file descriptor `fd` (1 stdout, 2 stderr).
pub fn enabled(fd: int): bool uses env {
  if (env.get("NO_COLOR") else "") != "" { return false }
  match env.get("FORCE_COLOR") {
    some(v) => return v != "0"
    none => {}
  }
  env.is_terminal(fd) && env.get("TERM") != some("dumb")
}

/// Prints `s`, with its escapes stripped when color is off for stdout (see `enabled`).
pub fn println(s: str) uses env = print(if enabled(1) { s } else { strip(s) })

/// Prints `s` to stderr, with its escapes stripped when color is off for stderr.
pub fn eprintln(s: str) uses env = eprint(if enabled(2) { s } else { strip(s) })

/// The terminal's width in columns, else `$COLUMNS`, else 80.
pub fn columns(): int uses env = env.columns() else 80

// ---- cursor and screen ----

/// Moves the cursor to the start of the line and clears it: print this before redrawing a
/// progress line.
pub let CLEAR_LINE = "\r\u{1b}[2K"
/// Clears the screen and moves the cursor to the top left.
pub let CLEAR_SCREEN = "\u{1b}[2J\u{1b}[H"
pub let HIDE_CURSOR = "\u{1b}[?25l"
pub let SHOW_CURSOR = "\u{1b}[?25h"

/// Moves the cursor up `n` lines ("" for `n <= 0`).
pub fn up(n: int): str = if n > 0 { CSI + "{n}A" } else { "" }
/// Moves the cursor down `n` lines.
pub fn down(n: int): str = if n > 0 { CSI + "{n}B" } else { "" }
/// Moves the cursor right `n` columns.
pub fn right(n: int): str = if n > 0 { CSI + "{n}C" } else { "" }
/// Moves the cursor left `n` columns.
pub fn left(n: int): str = if n > 0 { CSI + "{n}D" } else { "" }
/// Moves the cursor to `row`, `col` (1-based).
pub fn goto(row: int, col: int): str = CSI + "{row};{col}H"

/// Sets the terminal window's title.
pub fn title(s: str): str = ESC + "]0;" + s + "\u{7}"

/// A clickable hyperlink (OSC 8). Terminals without support show just `label`.
pub fn link(label: str, url: str): str =
  ESC + "]8;;" + url + ESC + "\\" + label + ESC + "]8;;" + ESC + "\\"

// ---- progress ----

let EIGHTHS = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]

/// A progress bar `w` columns wide for `done` of `total`, drawn with eighth-blocks:
/// `bar(1, 3, 10) == "███▎      "`. `done` is clamped to 0..total; a `total` of 0 is full.
pub fn bar(done: int, total: int, w: int): str {
  if w <= 0 { return "" }
  let eighths = if total <= 0 { w * 8 } else { w * 8 * clamp(done, 0, total) / total }
  let full = eighths / 8
  let part = EIGHTHS[eighths % 8]
  let used = full + if part == "" { 0 } else { 1 }
  "█".repeat(full) + part + spaces(w - used)
}

fn clamp(x: int, lo: int, hi: int): int = if x < lo { lo } else if x > hi { hi } else { x }

/// The whole percentage of `done` out of `total`, 0-100 (100 when `total` is 0).
pub fn percent(done: int, total: int): int = if total <= 0 {
  100
} else {
  100 * clamp(done, 0, total) / total
}

/// A one-line progress display: `label [bar] 42% (21/50)`, `w` columns wide in all (the bar
/// takes what the rest leaves, at least 10). Start it with `CLEAR_LINE` to redraw in place.
pub fn progress(label: str, done: int, total: int, w: int): str {
  let tail = " {percent(done, total):>3}% ({clamp(done, 0, total)}/{total})"
  let head = if label == "" { "" } else { label + " " }
  let bw = w - width(head) - width(tail) - 2
  let bw2 = if bw < 10 { 10 } else { bw }
  head + "[" + bar(done, total, bw2) + "]" + tail
}

let SPIN = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

/// Frame `i` of a braille spinner (any `i`, it wraps).
pub fn spinner(i: int): str = SPIN[((i % SPIN.len()) + SPIN.len()) % SPIN.len()]

// ---- tables ----

pub enum Align { Left, Right, Center }

/// How a table is drawn. `Rounded` and `Sharp` use box-drawing lines, `Ascii` uses `+-|`,
/// `Plain` separates columns with two spaces and underlines the header with nothing, and
/// `Markdown` gives a GitHub-flavored markdown table.
pub enum Border { Rounded, Sharp, Ascii, Plain, Markdown }

/// A table to render. Cells may contain escapes (they don't count toward widths) and line
/// breaks (a cell spans several lines). Rows shorter than the header are padded with empty
/// cells. `align` gives each column's alignment; missing entries are `Left`.
pub struct Table { header: [str], rows: [[str]], align: [Align], border: Border }

/// A `Rounded`, left-aligned table. An empty `header` draws no header row.
pub fn table(header: [str], rows: [[str]]): Table =
  Table { header, rows, align: [], border: Rounded }

pub fn align(t: Table, a: [Align]): Table = Table { align: a, ..t }
pub fn border(t: Table, b: Border): Table = Table { border: b, ..t }

/// So `"{t}"` and `print(t)` render the table.
pub fn show(t: Table): str = render(t)

struct Box {
  tl: str,
  tm: str,
  tr: str,
  ml: str,
  mm: str,
  mr: str,
  bl: str,
  bm: str,
  br: str,
  h: str,
  v: str,
}

fn box_of(b: Border): Box = match b {
  Rounded => Box {
    tl: "╭",
    tm: "┬",
    tr: "╮",
    ml: "├",
    mm: "┼",
    mr: "┤",
    bl: "╰",
    bm: "┴",
    br: "╯",
    h: "─",
    v: "│",
  }
  Sharp => Box {
    tl: "┌",
    tm: "┬",
    tr: "┐",
    ml: "├",
    mm: "┼",
    mr: "┤",
    bl: "└",
    bm: "┴",
    br: "┘",
    h: "─",
    v: "│",
  }
  _ => Box {
    tl: "+",
    tm: "+",
    tr: "+",
    ml: "+",
    mm: "+",
    mr: "+",
    bl: "+",
    bm: "+",
    br: "+",
    h: "-",
    v: "|",
  }
}

fn align_at(t: Table, i: int): Align = t.align.get(i) else Left

fn fit(s: str, w: int, a: Align): str = match a {
  Left => pad_right(s, w)
  Right => pad_left(s, w)
  Center => center(s, w)
}

// Each logical row as physical lines: a list of lines, each a list of cells.
fn row_lines(cells: [str], n: int): [[str]] {
  var parts: [[str]] = []
  var h = 1
  for i in 0..n {
    let c = cells.get(i) else ""
    let ls = if c == "" { [""] } else { c.split("\n") }
    if ls.len() > h { h = ls.len() }
    parts.push(ls)
  }
  var out: [[str]] = []
  for j in 0..h { out.push(parts.map(ls => ls.get(j) else "")) }
  out
}

/// Draws the table as lines joined by `\n` (no trailing newline).
pub fn render(t: Table): str {
  var n = t.header.len()
  for r in t.rows { if r.len() > n { n = r.len() } }
  if n == 0 { return "" }
  let head = if t.header.len() == 0 { [] } else { row_lines(t.header, n) }
  let body = t.rows.map(r => row_lines(r, n))
  var ws: [int] = []
  for i in 0..n { ws.push(if t.border == Markdown { 3 } else { 1 }) }
  for line in head + body.flat_map(x => x) {
    for i, c in line { if width(c) > ws[i] { ws[i] = width(c) } }
  }
  let fmt = (line: [str]) => line.enum().map((i, c) => fit(c, ws[i], align_at(t, i)))
  var out: [str] = []
  match t.border {
    Plain => {
      for line in head { out.push(fmt(line).join("  ") |> rtrim) }
      for r in body { for line in r { out.push(fmt(line).join("  ") |> rtrim) } }
    }
    Markdown => {
      let hd = if head.len() == 0 { [ws.map(w => "")] } else { head }
      for line in hd { out.push("| " + fmt(line).join(" | ") + " |") }
      out.push("|" + ws.enum().map((i, w) => md_rule(w, align_at(t, i))).join("|") + "|")
      for r in body {
        for line in r { out.push("| " + fmt(line).map(md_escape).join(" | ") + " |") }
      }
    }
    _ => {
      let b = box_of(t.border)
      let rule = (l: str, m: str, r: str) => l + ws.map(w => b.h.repeat(w + 2)).join(m) + r
      let row = (line: [str]) => b.v + " " + fmt(line).join(" " + b.v + " ") + " " + b.v
      out.push(rule(b.tl, b.tm, b.tr))
      for line in head { out.push(row(line)) }
      if head.len() > 0 && body.len() > 0 { out.push(rule(b.ml, b.mm, b.mr)) }
      for r in body { for line in r { out.push(row(line)) } }
      out.push(rule(b.bl, b.bm, b.br))
    }
  }
  out.join("\n")
}

fn md_rule(w: int, a: Align): str = match a {
  Left => " " + "-".repeat(w) + " "
  Right => " " + "-".repeat(w - 1) + ": "
  Center => " :" + "-".repeat(w - 2) + ": "
}

fn rtrim(s: str): str {
  var cs = s.chars()
  while cs.len() > 0 && cs[cs.len() - 1] == ' ' { cs.pop() }
  str(cs)
}

fn md_escape(s: str): str = s.replace("|", "\\|")

// ---- tests ----

test "codes and paint" {
  assert codes(style()) == ""
  assert codes(style().bold().fg(Red)) == "\u{1b}[1;31m"
  assert codes(style().fg(BrightBlue).bg(Idx(208))) == "\u{1b}[94;48;5;208m"
  assert codes(style().fg(Rgb(255, 128, 0))) == "\u{1b}[38;2;255;128;0m"
  assert codes(style().fg(Rgb(300, -1, 7))) == "\u{1b}[38;2;255;0;7m"
  assert red("x") == "\u{1b}[31mx\u{1b}[0m"
  assert paint("", style().bold()) == ""
  assert bold(green("ok")) == "\u{1b}[1m\u{1b}[32mok\u{1b}[0m"
  assert paint("x", style()) == "x"
  // a nested reset turns the outer style back on
  assert bold("a " + red("b") + " c") == "\u{1b}[1ma \u{1b}[31mb\u{1b}[0m\u{1b}[1m c\u{1b}[0m"
}

test "color names" {
  assert color("red")? == Red
  assert color(" Bright_Blue ")? == BrightBlue
  assert color("grey")? == BrightBlack
  assert color("#ff8800")? == Rgb(255, 136, 0)
  assert color("#F80")? == Rgb(255, 136, 0)
  assert color("208")? == Idx(208)
  assert color("256") is err(Unknown(_))
  assert color("#12345") is err(Unknown(_))
  assert color("chartreuse") is err(Unknown("chartreuse"))
  match color("x") {
    err(e) => assert message(e).starts_with("unknown color `x`")
    ok(_) => fail("parsed x")
  }
}

test "strip and width" {
  assert strip("plain") == "plain"
  assert strip(bold(red("hi")) + "!") == "hi!"
  assert strip(link("docs", "https://x.dev")) == "docs"
  assert strip(title("t") + "a") == "a"
  assert strip(CLEAR_LINE + up(2) + "z" + HIDE_CURSOR) == "\rz"
  assert strip("a\u{1b}") == "a"
  assert width(green("日本")) == 4
  assert pad_right(red("ab"), 4) == red("ab") + "  "
  assert pad_left("ab", 4) == "  ab"
  assert center("ab", 5) == " ab  "
  assert center("abcdef", 3) == "abcdef"
}

test "bars" {
  assert bar(0, 10, 4) == "    "
  assert bar(10, 10, 4) == "████"
  assert bar(1, 3, 10) == "███▎      "
  assert bar(5, 0, 3) == "███"
  assert bar(-5, 10, 3) == "   "
  assert bar(99, 10, 3) == "███"
  assert width(bar(7, 13, 17)) == 17
  assert percent(1, 3) == 33
  assert progress("dl", 5, 10, 40) == "dl [" + bar(5, 10, 23) + "]  50% (5/10)"
  assert width(progress("dl", 5, 10, 40)) == 40
  assert spinner(0) == "⠋"
  assert spinner(11) == "⠙"
  assert spinner(-1) == "⠏"
}

test "tables" {
  let t = table(["name", "n"], [["auk", "1"], ["goose", "12"]]).align([Left, Right])
  assert render(t) + "\n" == """
    ╭───────┬────╮
    │ name  │  n │
    ├───────┼────┤
    │ auk   │  1 │
    │ goose │ 12 │
    ╰───────┴────╯
    """
  assert "{t.border(Ascii)}\n" == """
    +-------+----+
    | name  |  n |
    +-------+----+
    | auk   |  1 |
    | goose | 12 |
    +-------+----+
    """
  assert render(t.border(Plain)) == "name    n\nauk     1\ngoose  12"
  assert render(t.border(Markdown).align([Center, Right])) + "\n" == """
    | name  |   n |
    | :---: | --: |
    |  auk  |   1 |
    | goose |  12 |
    """
}

test "table edge cases" {
  assert render(table([], [])) == ""
  // colored cells and wide chars measure by columns; short rows pad; cells can span lines
  let t = table(["k", "v"], [[red("日本"), "a\nbb"], ["x"]]).border(Sharp)
  assert strip(render(t)) + "\n" == """
    ┌──────┬────┐
    │ k    │ v  │
    ├──────┼────┤
    │ 日本 │ a  │
    │      │ bb │
    │ x    │    │
    └──────┴────┘
    """
  assert render(table([], [["a", "b"]]).border(Ascii)) == "+---+---+\n| a | b |\n+---+---+"
  assert render(table(["a"], [["x|y"]]).border(Markdown)) == "| a   |\n| --- |\n| x\\|y |"
}

test "cursor" {
  assert up(0) == ""
  assert up(3) == "\u{1b}[3A"
  assert goto(2, 5) == "\u{1b}[2;5H"
  assert link("a", "u") == "\u{1b}]8;;u\u{1b}\\a\u{1b}]8;;\u{1b}\\"
}

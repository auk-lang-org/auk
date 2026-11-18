/// A small Wadler/Prettier-style document printer for `auk fmt` (src/fmt/doc.rs).
///
/// A `Doc` describes text with optional line breaks. A `Group` prints flat (every `Line` is a
/// space, every `SoftLine` nothing) when it fits in the remaining width, and broken (every
/// direct `Line` a newline) otherwise. A group that contains a hard break is always broken.
/// `Choice` picks the first of several layouts that fits, which gives last-argument hugging,
/// member-chain breaking and "break after `=`" without backtracking.
///
/// The printer builds its output as finished lines plus the current one (Rust's one `String`,
/// truncated at every line break, would be a quadratic `str` slice here); `render` joins them.

/// Comments printed at the end of a line are prefixed with this marker, so a final pass can
/// align runs of them; it never appears in Auk source.
pub let SUFFIX_MARK = "\u{1}"

pub enum Doc {
  Text(s: str),
  Concat(v: [Doc]),
  /// Indent the lines started inside by one level (2 spaces).
  Indent(d: Doc),
  /// The flag is "contains a hard break", computed by `group`.
  Group(d: Doc, hard: bool),
  /// A space when flat, a newline when broken.
  Line,
  /// Nothing when flat, a newline when broken.
  SoftLine,
  /// Always a newline; forces every enclosing group to break.
  HardLine,
  /// An empty line (put it before a `HardLine` or `Line`); forces a break like `HardLine`.
  Blank,
  /// (broken, flat): chosen by the mode of the enclosing group.
  IfBreak(b: Doc, f: Doc),
  /// A trailing comment, printed just before the next newline. Forces a break.
  LineSuffix(s: str),
  /// Alternative layouts, tried in order; the last one is used if none fits.
  Choice(opts: [(Doc, Fit)]),
  /// Printed as is, but when it follows a group being measured, it counts as flat: the group
  /// breaks rather than this tail (`f(a, b) else e => fail(e)` breaks `f`'s arguments).
  Tail(d: Doc),
}

/// When a `Choice` alternative is acceptable.
pub enum Fit {
  /// Printed entirely flat, it fits on the rest of the line.
  Flat,
  /// Its first line fits (inner groups flat unless they must break).
  FirstLine,
  /// Every line fits, with inner groups flat unless they must break.
  AllLines,
  /// Always acceptable (the fallback).
  Always,
}

pub fn text(s: str): Doc = Text(s)

pub fn concat(v: [Doc]): Doc = Concat(v)

pub fn indent(d: Doc): Doc = Indent(d)

pub fn group(d: Doc): Doc = Group(d, d.hard())

/// A group that is always broken.
pub fn broken(d: Doc): Doc = Group(d, true)

pub fn if_break(b: Doc, f: Doc): Doc = IfBreak(b, f)

pub fn nil(): Doc = Concat([])

/// Does this doc force its enclosing group to break?
pub fn hard(d: Doc): bool = match d {
  HardLine | Blank | LineSuffix(_) => true
  Text(_) | Line | SoftLine => false
  Concat(v) => v.any(x => x.hard())
  Indent(x) | Tail(x) => x.hard()
  Group(_, h) => h
  IfBreak(_, f) => f.hard()
  Choice(opts) => opts[0].0.hard()
}

enum Mode { Flat, Break }

struct Printer {
  width: int,
  /// The finished lines (each followed by a line break in the output).
  done: [str],
  /// The line being printed.
  cur: str,
  col: int,
  suffix: [str],
}

/// The number of chars after the last line break of `s`.
fn last_line_width(s: str): int {
  let cs = s.chars()
  var i = cs.len()
  while i > 0 && cs[i - 1] != '\n' { i -= 1 }
  cs.len() - i
}

/// Print `doc` with lines of at most `max` columns where possible.
pub fn render(d: Doc, max: int): str = render_lines(d, max).join("\n")

/// `render`, as lines.
pub fn render_lines(d: Doc, max: int): [str] {
  var p = Printer { width: max, done: [], cur: "", col: 0, suffix: [] }
  var stack: [(int, Mode, Doc)] = [(0, Mode.Break, d)]
  loop {
    let c = stack.pop() else break
    let ind = c.0
    let mode = c.1
    match c.2 {
      Text(s) => p.text(s)
      Concat(v) => {
        var i = v.len() - 1
        while i >= 0 {
          stack.push((ind, mode, v[i]))
          i -= 1
        }
      }
      Indent(x) => stack.push((ind + 2, mode, x))
      Tail(x) => stack.push((ind, mode, x))
      Group(x, h) => {
        let flat = mode == Mode.Flat || (!h && p.fits((ind, Mode.Flat, x), stack, false))
        stack.push((ind, if flat { Mode.Flat } else { Mode.Break }, x))
      }
      Choice(opts) => {
        if mode == Mode.Flat {
          stack.push((ind, Mode.Flat, opts[0].0))
          continue
        }
        let last = opts.len() - 1
        var k = 0
        while k < last && !p.choice_fits(opts[k].0, opts[k].1, ind, stack) { k += 1 }
        let m = if opts[k].1 == Fit.Flat { Mode.Flat } else { Mode.Break }
        stack.push((ind, m, opts[k].0))
      }
      Line => if mode == Mode.Flat { p.text(" ") } else { p.newline(ind) }
      SoftLine => if mode != Mode.Flat { p.newline(ind) }
      HardLine => p.newline(ind)
      Blank => p.blank()
      IfBreak(b, f) => stack.push((ind, mode, if mode == Mode.Break { b } else { f }))
      LineSuffix(s) => p.suffix.push(s)
    }
  }
  p.flush_suffix()
  p.done.push(p.cur)
  p.done
}

/// Is the `Choice` alternative `o` acceptable by `fit`?
fn choice_fits(
  p: Printer,
  o: Doc,
  fit: Fit,
  ind: int,
  stack: [(int, Mode, Doc)],
): bool = match fit {
  Flat => !o.hard() && p.fits((ind, Mode.Flat, o), stack, false)
  FirstLine => p.fits((ind, Mode.Flat, o), stack, false)
  AllLines => p.fits((ind, Mode.Flat, o), stack, true)
  Always => true
}

/// Append `s` to the output, tracking the column.
fn text(p: var Printer, s: str) {
  if !s.contains("\n") {
    p.cur += s
    p.col += s.len()
    return
  }
  let parts = s.split("\n")
  p.cur += parts[0]
  for k in 1..parts.len() {
    p.done.push(p.cur)
    p.cur = parts[k]
  }
  p.col = parts[parts.len() - 1].len()
}

fn flush_suffix(p: var Printer) {
  if p.suffix.len() == 0 { return }
  for s in p.suffix {
    p.cur += SUFFIX_MARK
    p.cur += s
  }
  p.suffix = []
}

/// Rust's `trim_end`: drop the spaces and tabs at the end of the current line.
fn trim_cur(p: var Printer) {
  if !p.cur.ends_with(" ") && !p.cur.ends_with("\t") { return }
  let cs = p.cur.chars()
  var n = cs.len()
  while n > 0 && (cs[n - 1] == ' ' || cs[n - 1] == '\t') { n -= 1 }
  p.cur = str(cs[0..n])
}

fn newline(p: var Printer, ind: int) {
  p.flush_suffix()
  p.trim_cur()
  p.done.push(p.cur)
  p.cur = " ".repeat(ind)
  p.col = ind
}

/// End the current line and leave an empty one (never two in a row, never at the start).
fn blank(p: var Printer) {
  p.flush_suffix()
  p.trim_cur()
  let empty = p.done.len() == 0 && p.cur == ""
  let after_blank = p.cur == "" && p.done.len() >= 2 && p.done[p.done.len() - 1] == ""
  if !empty && !after_blank {
    p.done.push(p.cur)
    p.cur = ""
  }
  p.col = 0
}

/// Does `next` fit in the rest of the line? Flat-mode groups inside stay flat unless they
/// must break; the commands after it on `rest` count until their first line break. With
/// `all_lines`, a break inside `next` starts a new line that must fit too.
fn fits(p: Printer, next: (int, Mode, Doc), rest: [(int, Mode, Doc)], all_lines: bool): bool {
  var rem = p.width - p.col
  var cmds = [next]
  var ri = rest.len()
  var in_rest = false
  loop {
    if rem < 0 { return false }
    let c = match cmds.pop() {
      some(x) => x
      none => {
        if ri == 0 { return true }
        ri -= 1
        in_rest = true
        rest[ri]
      }
    }
    let ind = c.0
    let mode = c.1
    match c.2 {
      Text(s) => match s.find("\n") {
        none => rem -= s.len()
        some(i) => {
          rem -= i
          if rem < 0 || in_rest || !all_lines { return rem >= 0 }
          rem = p.width - last_line_width(s)
        }
      }
      Concat(v) => {
        var i = v.len() - 1
        while i >= 0 {
          cmds.push((ind, mode, v[i]))
          i -= 1
        }
      }
      Indent(x) => cmds.push((ind + 2, mode, x))
      Tail(x) => cmds.push((ind, if x.hard() { mode } else { Mode.Flat }, x))
      Group(x, h) => cmds.push((ind, if h { Mode.Break } else { mode }, x))
      Choice(opts) => {
        // every choice can break near its start
        if mode == Mode.Break { return true }
        cmds.push((ind, mode, opts[0].0))
      }
      Line | SoftLine when mode == Mode.Flat => rem -= if c.2 is Line { 1 } else { 0 }
      Line | SoftLine | HardLine | Blank => {
        if in_rest || !all_lines { return true }
        rem = p.width - ind
      }
      IfBreak(b, f) => cmds.push((ind, mode, if mode == Mode.Break { b } else { f }))
      LineSuffix(_) => {}
    }
  }
}

/// Align the trailing comments of consecutive lines to one column (two spaces past the longest
/// code), and drop the markers.
pub fn align_suffixes(s: str): str = align_lines(s.split("\n")).join("\n")

/// `align_suffixes`, on lines.
pub fn align_lines(lines: [str]): [str] {
  var out: [str] = []
  var i = 0
  while i < lines.len() {
    if !lines[i].contains(SUFFIX_MARK) {
      out.push(lines[i])
      i += 1
      continue
    }
    var j = i
    while j < lines.len() && lines[j].contains(SUFFIX_MARK) { j += 1 }
    var parts: [(str, [str])] = []
    for l in lines[i..j] {
      let it = l.split(SUFFIX_MARK)
      parts.push((it[0].trim_end(), it.skip(1)))
    }
    var col = 0
    for p in parts { col = max(col, p.0.len()) }
    col += 2
    for p in parts {
      var line = p.0
      if p.0.trim() != "" { line += " ".repeat(col - p.0.len()) }
      line += p.1.join(" ")
      out.push(line)
    }
    i = j
  }
  out
}

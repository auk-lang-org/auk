//! A small Wadler/Prettier-style document printer for `duck fmt`.
//!
//! A `Doc` describes text with optional line breaks. A `Group` prints flat (every `Line` is a
//! space, every `SoftLine` nothing) when it fits in the remaining width, and broken (every
//! direct `Line` a newline) otherwise. A group that contains a hard break is always broken.
//! `Choice` picks the first of several layouts that fits, which gives last-argument hugging,
//! member-chain breaking and "break after `=`" without backtracking.

/// Comments printed at the end of a line are prefixed with this marker, so a final pass can
/// align runs of them; it never appears in Duck source.
pub const SUFFIX_MARK: char = '\u{1}';

#[derive(Debug, Clone)]
pub enum Doc {
    Text(String),
    Concat(Vec<Doc>),
    /// Indent the lines started inside by one level (2 spaces).
    Indent(Box<Doc>),
    /// The flag is "contains a hard break", computed by `group`.
    Group(Box<Doc>, bool),
    /// A space when flat, a newline when broken.
    Line,
    /// Nothing when flat, a newline when broken.
    SoftLine,
    /// Always a newline; forces every enclosing group to break.
    HardLine,
    /// An empty line (put it before a `HardLine` or `Line`); forces a break like `HardLine`.
    Blank,
    /// (broken, flat): chosen by the mode of the enclosing group.
    IfBreak(Box<Doc>, Box<Doc>),
    /// A trailing comment, printed just before the next newline. Forces a break.
    LineSuffix(String),
    /// Alternative layouts, tried in order; the last one is used if none fits.
    Choice(Vec<(Doc, Fit)>),
    /// Printed as is, but when it follows a group being measured, it counts as flat: the group
    /// breaks rather than this tail (`f(a, b) else e => fail(e)` breaks `f`'s arguments).
    Tail(Box<Doc>),
}

/// When a `Choice` alternative is acceptable.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
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

pub fn text(s: impl Into<String>) -> Doc {
    Doc::Text(s.into())
}

pub fn concat(v: Vec<Doc>) -> Doc {
    Doc::Concat(v)
}

pub fn indent(d: Doc) -> Doc {
    Doc::Indent(Box::new(d))
}

pub fn group(d: Doc) -> Doc {
    let hard = d.hard();
    Doc::Group(Box::new(d), hard)
}

/// A group that is always broken.
pub fn broken(d: Doc) -> Doc {
    Doc::Group(Box::new(d), true)
}

pub fn if_break(broken: Doc, flat: Doc) -> Doc {
    Doc::IfBreak(Box::new(broken), Box::new(flat))
}

pub fn nil() -> Doc {
    Doc::Concat(Vec::new())
}

impl Doc {
    /// Does this doc force its enclosing group to break?
    pub fn hard(&self) -> bool {
        match self {
            Doc::HardLine | Doc::Blank | Doc::LineSuffix(_) => true,
            Doc::Text(_) | Doc::Line | Doc::SoftLine => false,
            Doc::Concat(v) => v.iter().any(Doc::hard),
            Doc::Indent(d) | Doc::Tail(d) => d.hard(),
            Doc::Group(_, h) => *h,
            Doc::IfBreak(_, flat) => flat.hard(),
            Doc::Choice(opts) => opts[0].0.hard(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Mode {
    Flat,
    Break,
}

type Cmd<'a> = (usize, Mode, &'a Doc);

struct Printer {
    width: isize,
    out: String,
    col: isize,
    suffix: Vec<String>,
}

fn width(s: &str) -> isize {
    s.chars().count() as isize
}

/// Print `doc` with lines of at most `max` columns where possible.
pub fn render(doc: &Doc, max: usize) -> String {
    let mut p = Printer { width: max as isize, out: String::new(), col: 0, suffix: Vec::new() };
    let mut stack: Vec<Cmd> = vec![(0, Mode::Break, doc)];
    while let Some((ind, mode, d)) = stack.pop() {
        match d {
            Doc::Text(s) => p.text(s),
            Doc::Concat(v) => stack.extend(v.iter().rev().map(|x| (ind, mode, x))),
            Doc::Indent(x) => stack.push((ind + 2, mode, x)),
            Doc::Tail(x) => stack.push((ind, mode, x)),
            Doc::Group(x, hard) => {
                let flat = mode == Mode::Flat || (!*hard && p.fits((ind, Mode::Flat, x), &stack, false));
                stack.push((ind, if flat { Mode::Flat } else { Mode::Break }, x));
            }
            Doc::Choice(opts) => {
                if mode == Mode::Flat {
                    stack.push((ind, Mode::Flat, &opts[0].0));
                    continue;
                }
                let last = opts.len() - 1;
                let (o, fit) = opts
                    .iter()
                    .enumerate()
                    .find(|(i, (o, fit))| {
                        *i == last
                            || match fit {
                                Fit::Flat => !o.hard() && p.fits((ind, Mode::Flat, o), &stack, false),
                                Fit::FirstLine => p.fits((ind, Mode::Flat, o), &stack, false),
                                Fit::AllLines => p.fits((ind, Mode::Flat, o), &stack, true),
                                Fit::Always => true,
                            }
                    })
                    .map(|(_, (o, fit))| (o, *fit))
                    .unwrap();
                stack.push((ind, if fit == Fit::Flat { Mode::Flat } else { Mode::Break }, o));
            }
            Doc::Line | Doc::SoftLine if mode == Mode::Flat => p.text(if matches!(d, Doc::Line) { " " } else { "" }),
            Doc::Line | Doc::SoftLine | Doc::HardLine => p.newline(ind),
            Doc::Blank => p.blank(),
            Doc::IfBreak(b, f) => stack.push((ind, mode, if mode == Mode::Break { b } else { f })),
            Doc::LineSuffix(s) => p.suffix.push(s.clone()),
        }
    }
    p.flush_suffix();
    p.out
}

impl Printer {
    fn text(&mut self, s: &str) {
        self.out.push_str(s);
        match s.rfind('\n') {
            Some(i) => self.col = width(&s[i + 1..]),
            None => self.col += width(s),
        }
    }

    fn flush_suffix(&mut self) {
        for s in std::mem::take(&mut self.suffix) {
            self.out.push(SUFFIX_MARK);
            self.out.push_str(&s);
        }
    }

    fn trim_end(&mut self) {
        let n = self.out.trim_end_matches([' ', '\t']).len();
        self.out.truncate(n);
    }

    fn newline(&mut self, ind: usize) {
        self.flush_suffix();
        self.trim_end();
        self.out.push('\n');
        self.out.extend(std::iter::repeat_n(' ', ind));
        self.col = ind as isize;
    }

    /// End the current line and leave an empty one (never two in a row, never at the start).
    fn blank(&mut self) {
        self.flush_suffix();
        self.trim_end();
        if !self.out.is_empty() && !self.out.ends_with("\n\n") {
            self.out.push('\n');
        }
        self.col = 0;
    }

    /// Does `next` fit in the rest of the line? Flat-mode groups inside stay flat unless they
    /// must break; the commands after it on `rest` count until their first line break. With
    /// `all_lines`, a break inside `next` starts a new line that must fit too.
    fn fits(&self, next: Cmd, rest: &[Cmd], all_lines: bool) -> bool {
        let mut rem = self.width - self.col;
        let mut cmds = vec![next];
        let mut ri = rest.len();
        let mut in_rest = false;
        loop {
            if rem < 0 {
                return false;
            }
            let (ind, mode, d) = match cmds.pop() {
                Some(c) => c,
                None => {
                    if ri == 0 {
                        return true;
                    }
                    ri -= 1;
                    in_rest = true;
                    rest[ri]
                }
            };
            match d {
                Doc::Text(s) => match s.find('\n') {
                    None => rem -= width(s),
                    Some(i) => {
                        rem -= width(&s[..i]);
                        if rem < 0 || in_rest || !all_lines {
                            return rem >= 0;
                        }
                        rem = self.width - width(&s[s.rfind('\n').unwrap() + 1..]);
                    }
                },
                Doc::Concat(v) => cmds.extend(v.iter().rev().map(|x| (ind, mode, x))),
                Doc::Indent(x) => cmds.push((ind + 2, mode, x)),
                Doc::Tail(x) => cmds.push((ind, if x.hard() { mode } else { Mode::Flat }, x)),
                Doc::Group(x, hard) => cmds.push((ind, if *hard { Mode::Break } else { mode }, x)),
                Doc::Choice(opts) => {
                    if mode == Mode::Break {
                        // every choice can break near its start
                        return true;
                    }
                    cmds.push((ind, mode, &opts[0].0));
                }
                Doc::Line | Doc::SoftLine if mode == Mode::Flat => rem -= if matches!(d, Doc::Line) { 1 } else { 0 },
                Doc::Line | Doc::SoftLine | Doc::HardLine | Doc::Blank => {
                    if in_rest || !all_lines {
                        return true;
                    }
                    rem = self.width - ind as isize;
                }
                Doc::IfBreak(b, f) => cmds.push((ind, mode, if mode == Mode::Break { b } else { f })),
                Doc::LineSuffix(_) => {}
            }
        }
    }
}

/// Align the trailing comments of consecutive lines to one column (two spaces past the longest
/// code), and drop the markers.
pub fn align_suffixes(s: &str) -> String {
    let lines: Vec<&str> = s.split('\n').collect();
    let mut out = Vec::with_capacity(lines.len());
    let mut i = 0;
    while i < lines.len() {
        if !lines[i].contains(SUFFIX_MARK) {
            out.push(lines[i].to_string());
            i += 1;
            continue;
        }
        let mut j = i;
        while j < lines.len() && lines[j].contains(SUFFIX_MARK) {
            j += 1;
        }
        let parts: Vec<(&str, Vec<&str>)> = lines[i..j]
            .iter()
            .map(|l| {
                let mut it = l.split(SUFFIX_MARK);
                let code = it.next().unwrap().trim_end();
                (code, it.collect())
            })
            .collect();
        let col = parts.iter().map(|(c, _)| width(c)).max().unwrap_or(0) as usize + 2;
        for (code, comments) in parts {
            let mut line = code.to_string();
            if !code.trim().is_empty() {
                line.extend(std::iter::repeat_n(' ', col - width(code) as usize));
            }
            line += &comments.join(" ");
            out.push(line);
        }
        i = j;
    }
    out.join("\n")
}

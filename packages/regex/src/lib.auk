/// A backtracking regular-expression engine. Patterns are compiled to an AST
/// once by `regex(p)`, then matched with an explicit backtracking stack, so
/// long inputs never grow the call stack. All positions are char indexes.

// ---- public types ----

/// A compiled pattern. Build one with `regex(p)`.
pub struct Regex { src: str, root: Node, ngroups: int }

/// Why a pattern failed to compile. `at` is the 0-based char index in the pattern.
pub enum RegexErr {
  Unexpected(at: int, c: char),   // a stray `)`
  Unclosed(at: int, open: char),  // `(` or `[` with no closing bracket
  NothingToRepeat(at: int),       // a quantifier with nothing before it
  BadRepeat(at: int),             // a malformed `{n,m}`, or m < n
  BadRange(at: int),              // `[z-a]`, or a class escape used as a range end
  BadEscape(at: int, c: char),    // `\q`
  TrailingBackslash(at: int),     // the pattern ends in `\`
  BadGroup(at: int),              // `(?` not followed by `:`
}

// ---- AST ----

enum Kind { Digit, Word, Space }
enum Item { Span(lo: char, hi: char), Cls(k: Kind, neg: bool) }
enum CharSet { Lit(c: char), Dot, Class(items: [Item], neg: bool) }

enum Node {
  Empty,
  One(set: CharSet),
  Start,
  End,
  Cat(xs: [Node]),
  Alt(a: Node, b: Node),
  Group(n: int, body: Node),
  Rep(body: Node, lo: int, hi: int?, lazy: bool),
}

// ---- compiling ----

/// Compile `p`. Supports literals, `.`, `[a-z]`, `[^...]`, `\d \w \s \D \W \S`,
/// escaped metacharacters, `^ $`, `( )`, `(?: )`, `|`, `* + ? {n} {n,} {n,m}`
/// and lazy `*? +? ??`.
pub fn regex(p: str): Regex!RegexErr {
  var ps = P { cs: p.chars(), i: 0, groups: 0 }
  let root = ps.parse_alt()?
  if ps.more() { fail(Unexpected(ps.i, ps.cs[ps.i])) }
  Regex { src: p, root, ngroups: ps.groups }
}

/// The pattern text a regex was compiled from.
pub fn source(r: Regex): str = r.src

/// The number of capturing groups (not counting group 0).
pub fn group_count(r: Regex): int = r.ngroups

/// Backslash-escape every metacharacter in `s`, so `regex(escape(s))` matches `s` literally.
pub fn escape(s: str): str {
  let cs = s.chars()
  var out = ""
  var from = 0  // start of the chars not copied yet
  for i, c in cs {
    if is_meta(c) {
      out += str(cs[from..i])
      out += "\\"
      from = i
    }
  }
  if out == "" { return s }
  out + str(cs[from..cs.len()])
}

/// The char index in the pattern where compilation failed.
pub fn pos(e: RegexErr): int
fn pos(Unexpected(at, _)): int = at
fn pos(Unclosed(at, _)): int = at
fn pos(NothingToRepeat(at)): int = at
fn pos(BadRepeat(at)): int = at
fn pos(BadRange(at)): int = at
fn pos(BadEscape(at, _)): int = at
fn pos(TrailingBackslash(at)): int = at
fn pos(BadGroup(at)): int = at

/// A one-line, human-readable description of a compile error.
pub fn message(e: RegexErr): str
fn message(Unexpected(at, c)): str = "regex: unexpected '{c}' at {at}"
fn message(Unclosed(at, c)): str = "regex: '{c}' at {at} is never closed"
fn message(NothingToRepeat(at)): str = "regex: quantifier at {at} has nothing to repeat"
fn message(BadRepeat(at)): str = "regex: bad repeat count at {at}"
fn message(BadRange(at)): str = "regex: bad class range at {at}"
fn message(BadEscape(at, c)): str = "regex: unknown escape '\\{c}' at {at}"
fn message(TrailingBackslash(at)): str = "regex: pattern ends with '\\' at {at}"
fn message(BadGroup(at)): str = "regex: unsupported group syntax at {at} (only '(?:' is allowed)"

// Parser state: the pattern's chars, the cursor, and the capture groups seen so far.
struct P { cs: [char], i: int, groups: int }
struct Bounds { lo: int, hi: int? }

fn more(p: P): bool = p.i < p.cs.len()
fn sees(p: P, c: char): bool = p.more() && p.cs[p.i] == c
fn sees2(p: P, a: char, b: char): bool = p.sees(a) && p.i + 1 < p.cs.len() && p.cs[p.i + 1] == b

fn is_quant(c: char): bool = c == '*' || c == '+' || c == '?' || c == '{'
fn is_meta(c: char): bool = r".\^$|?*+()[]{}".contains(c)

// alt := cat ('|' cat)*
fn parse_alt(p: var P): Node!RegexErr {
  var alts = [p.parse_cat()?]
  while p.sees('|') {
    p.i += 1
    alts.push(p.parse_cat()?)
  }
  alt_of(alts)
}

// Fold right, so `a|b|c` is Alt(a, Alt(b, c)) and alternatives are tried left to right.
fn alt_of([x]: [Node]): Node = x
fn alt_of([x, ..t]: [Node]): Node = Alt(x, alt_of(t))
fn alt_of([]): Node = Empty

// cat := (atom quant?)*
fn parse_cat(p: var P): Node!RegexErr {
  var xs: [Node] = []
  while p.more() && !p.sees('|') && !p.sees(')') {
    let a = p.parse_atom()?
    xs.push(p.parse_quant(a)?)
  }
  cat_of(xs)
}

fn cat_of([]): Node = Empty
fn cat_of([x]: [Node]): Node = x
fn cat_of(xs: [Node]): Node = Cat(xs)

fn parse_atom(p: var P): Node!RegexErr {
  let at = p.i
  p.i += 1
  atom(p.cs[at], at, &p)
}

// `at` is the index of `c`; the cursor is already past it.
fn atom('.', _: int, _: var P): Node!RegexErr = One(Dot)
fn atom('^', _: int, _: var P): Node!RegexErr = Start
fn atom('$', _: int, _: var P): Node!RegexErr = End
fn atom('(', at: int, p: var P): Node!RegexErr = p.parse_group(at)
fn atom('[', at: int, p: var P): Node!RegexErr = p.parse_class(at)
fn atom('\\', at: int, p: var P): Node!RegexErr = match p.read_escape(at)? {
  Span(c, _) => One(Lit(c))
  item => One(Class([item], false))
}
fn atom(c: char, at: int, _: var P): Node!RegexErr when is_quant(c) = fail(NothingToRepeat(at))
fn atom(c: char, _: int, _: var P): Node!RegexErr = One(Lit(c))

// After `(`; `at` is the index of the `(`.
fn parse_group(p: var P, at: int): Node!RegexErr {
  var n = 0
  if p.sees2('?', ':') {
    p.i += 2
  } else if p.sees('?') {
    fail(BadGroup(p.i))
  } else {
    p.groups += 1
    n = p.groups
  }
  let body = p.parse_alt()?
  if !p.sees(')') { fail(Unclosed(at, '(')) }
  p.i += 1
  if n == 0 { body } else { Group(n, body) }
}

// After `[`; `at` is the index of the `[`. A `]` first in the class is a literal.
fn parse_class(p: var P, at: int): Node!RegexErr {
  let neg = p.sees('^')
  if neg { p.i += 1 }
  var items: [Item] = []
  var first = true
  loop {
    if !p.more() { fail(Unclosed(at, '[')) }
    if p.sees(']') && !first {
      p.i += 1
      break
    }
    first = false
    let start = p.i
    let lo = p.class_item()?
    if p.sees('-') && p.i + 1 < p.cs.len() && p.cs[p.i + 1] != ']' {
      p.i += 1
      let hi = p.class_item()?
      match (lo, hi) {
        (Span(a, _), Span(b, _)) when a <= b => items.push(Span(a, b))
        _ => fail(BadRange(start))
      }
    } else {
      items.push(lo)
    }
  }
  One(Class(items, neg))
}

fn class_item(p: var P): Item!RegexErr {
  let at = p.i
  let c = p.cs[at]
  p.i += 1
  if c == '\\' { p.read_escape(at) } else { Span(c, c) }
}

// After `\`; `at` is the index of the backslash.
fn read_escape(p: var P, at: int): Item!RegexErr {
  if !p.more() { fail(TrailingBackslash(at)) }
  let c = p.cs[p.i]
  p.i += 1
  esc_item(c, at)
}

fn esc_item('d', _: int): Item!RegexErr = Cls(Digit, false)
fn esc_item('D', _: int): Item!RegexErr = Cls(Digit, true)
fn esc_item('w', _: int): Item!RegexErr = Cls(Word, false)
fn esc_item('W', _: int): Item!RegexErr = Cls(Word, true)
fn esc_item('s', _: int): Item!RegexErr = Cls(Space, false)
fn esc_item('S', _: int): Item!RegexErr = Cls(Space, true)
fn esc_item('n', _: int): Item!RegexErr = Span('\n', '\n')
fn esc_item('t', _: int): Item!RegexErr = Span('\t', '\t')
fn esc_item('r', _: int): Item!RegexErr = Span('\r', '\r')
fn esc_item(c: char, _: int): Item!RegexErr when is_meta(c) || c == '-' || c == '/' = Span(c, c)
fn esc_item(c: char, at: int): Item!RegexErr = fail(BadEscape(at, c))

fn parse_quant(p: var P, a: Node): Node!RegexErr {
  if !p.more() || !is_quant(p.cs[p.i]) { return a }
  let at = p.i
  p.i += 1
  let b = p.bounds(p.cs[at], at)?
  let lazy = p.sees('?')
  if lazy { p.i += 1 }
  Rep(a, b.lo, b.hi, lazy)
}

// The cursor is past the quantifier char `q`, which sits at `at`.
fn bounds(_: var P, '*', _: int): Bounds!RegexErr = Bounds { lo: 0, hi: none }
fn bounds(_: var P, '+', _: int): Bounds!RegexErr = Bounds { lo: 1, hi: none }
fn bounds(_: var P, '?', _: int): Bounds!RegexErr = Bounds { lo: 0, hi: 1 }
fn bounds(p: var P, _: char, at: int): Bounds!RegexErr {  // `{n}`, `{n,}`, `{n,m}`
  let lo = p.number() else fail(BadRepeat(at))
  var hi: int? = lo
  if p.sees(',') {
    p.i += 1
    hi = p.number()
  }
  if !p.sees('}') { fail(BadRepeat(at)) }
  p.i += 1
  match hi {
    some(h) when h < lo => fail(BadRepeat(at))
    _ => Bounds { lo, hi }
  }
}

// A run of decimal digits at the cursor, or none if there are none.
fn number(p: var P): int? {
  let start = p.i
  while p.more() && p.cs[p.i].is_digit() { p.i += 1 }
  if p.i == start { return none }
  let n = int.parse(str(p.cs[start..p.i])) else return none
  n
}

// ---- matching ----

// Matching runs on a flat copy of the AST: a list of ints holding one 4-slot node
// `[kind, a, b, c]` per AST node, addressed by its offset. Slot 0 of the list is the
// root's offset, slot 1 the pattern's lead (see `lead_of`) and slot 2 the offset of its
// first-char table (see `first`), or -1 without one.
let N_EMPTY = 0
let N_LIT = 1  // a: code point
let N_DOT = 2
let N_CLASS = 3  // a: offset of the item pairs, b: how many, c: 1 if negated
let N_START = 4
let N_END = 5
let N_CAT = 6     // a: offset of the child offsets, b: how many (at least 2)
let N_ALT = 7     // a, b: the alternatives
let N_GROUP = 8   // a: group number, b: body
let N_REP = 9     // a: body, b: lo, c: hi (-1 for none); greedy
let N_REPL = 10   // the same, lazy
let N_REP1 = 11   // a greedy repeat whose body is one char set (N_LIT, N_DOT or N_CLASS)
let N_REP1L = 12  // the same, lazy

fn emit(pg: var [int], kind: int, a: int, b: int, c: int): int {
  let at = pg.len()
  pg.push(kind)
  pg.push(a)
  pg.push(b)
  pg.push(c)
  at
}

// The program for matching a subject of `n` chars.
fn compile(r: Regex, n: int): [int] {
  var pg = [0, 0, -1]
  let root = flat(r.root, &pg)
  pg[0] = root
  let lead = lead_of(pg, root)
  pg[1] = lead
  if n >= 128 && lead != -2 && (lead < 0 || pg[lead] != N_LIT) {
    // worth a table of the chars a match can start with, to skip the other start positions
    let at = pg.len()
    for _ in 0..=128 { pg.push(0) }
    if !first(&pg, root, at) { pg[2] = at }
  }
  pg
}

// Marks, in the 129 slots at `tab`, the ASCII chars a match of `nd` can start with (slot 128:
// some non-ASCII char can start one; over-marked, never under). True if `nd` can match
// without taking a char.
fn first(pg: var [int], nd: int, tab: int): bool {
  let kind = pg[nd]
  if kind == N_LIT {
    let c = pg[nd + 1]
    pg[tab + if c < 128 { c } else { 128 }] = 1
    return false
  }
  if kind == N_DOT || kind == N_CLASS {
    for x in 0..128 { if has(pg, nd, x) { pg[tab + x] = 1 } }
    pg[tab + 128] = 1
    return false
  }
  if kind == N_CAT {
    for j in pg[nd + 1]..pg[nd + 1] + pg[nd + 2] { if !first(&pg, pg[j], tab) { return false } }
    return true
  }
  if kind == N_ALT {
    let a = first(&pg, pg[nd + 1], tab)
    let b = first(&pg, pg[nd + 2], tab)
    return a || b
  }
  if kind == N_GROUP { return first(&pg, pg[nd + 2], tab) }
  if kind >= N_REP { return first(&pg, pg[nd + 1], tab) || pg[nd + 2] == 0 }
  true  // N_EMPTY, N_START, N_END
}

// Appends `n` (children first) and returns its offset.
fn flat(n: Node, pg: var [int]): int
fn flat(Empty, pg: var [int]): int = emit(&pg, N_EMPTY, 0, 0, 0)
fn flat(One(Lit(c)), pg: var [int]): int = emit(&pg, N_LIT, int(c), 0, 0)
fn flat(One(Dot), pg: var [int]): int = emit(&pg, N_DOT, 0, 0, 0)
fn flat(One(Class(items, neg)), pg: var [int]): int {
  // a class item is a pair: `lo, hi` for a span, `-1 - (2 * kind + negated), 0` for `\d` and co.
  let at = pg.len()
  for it in items {
    match it {
      Span(lo, hi) => {
        pg.push(int(lo))
        pg.push(int(hi))
      }
      Cls(k, n) => {
        let code = match k {
          Digit => 0
          Word => 2
          Space => 4
        }
        pg.push(-1 - code - if n { 1 } else { 0 })
        pg.push(0)
      }
    }
  }
  emit(&pg, N_CLASS, at, items.len(), if neg { 1 } else { 0 })
}
fn flat(Start, pg: var [int]): int = emit(&pg, N_START, 0, 0, 0)
fn flat(End, pg: var [int]): int = emit(&pg, N_END, 0, 0, 0)
fn flat(Cat(xs), pg: var [int]): int {
  let at = pg.len()
  for _ in xs { pg.push(0) }
  for j, x in xs { pg[at + j] = flat(x, &pg) }
  emit(&pg, N_CAT, at, xs.len(), 0)
}
fn flat(Alt(a, b), pg: var [int]): int {
  let x = flat(a, &pg)
  if !(b is Alt(_, _)) { return emit(&pg, N_ALT, x, flat(b, &pg), 0) }
  // `a|b|c` is Alt(a, Alt(b, c)): walk a long chain in a loop, then link it from the right
  var heads = [x]
  var rest = b
  loop {
    match rest {
      Alt(y, z) => {
        heads.push(flat(y, &pg))
        rest = z
      }
      _ => break
    }
  }
  var id = flat(rest, &pg)
  var j = heads.len() - 1
  while j >= 0 {
    id = emit(&pg, N_ALT, heads[j], id, 0)
    j -= 1
  }
  id
}
fn flat(Group(n, body), pg: var [int]): int {
  let b = flat(body, &pg)
  emit(&pg, N_GROUP, n, b, 0)
}
fn flat(Rep(body, lo, hi, lazy), pg: var [int]): int {
  let b = flat(body, &pg)
  let one = pg[b] == N_LIT || pg[b] == N_DOT || pg[b] == N_CLASS
  let kind = if one {
    if lazy { N_REP1L } else { N_REP1 }
  } else if lazy {
    N_REPL
  } else {
    N_REP
  }
  emit(&pg, kind, b, lo, hi else -1)
}

// What every match must start with: the offset of a char-set node its first char has to
// be in, -2 if it can only start at index 0 (a leading `^`), or -1 if nothing is known.
fn lead_of(pg: [int], root: int): int {
  var nd = root
  loop {
    let kind = pg[nd]
    if kind == N_LIT || kind == N_DOT || kind == N_CLASS { return nd }
    if kind == N_START { return -2 }
    if kind == N_CAT {
      nd = pg[pg[nd + 1]]
    } else if kind == N_GROUP {
      nd = pg[nd + 2]
    } else if kind >= N_REP && pg[nd + 2] > 0 {
      nd = pg[nd + 1]
    } else {
      return -1
    }
  }
}

fn kind_has(code: int, x: int): bool {
  let k = code / 2
  let yes = if k == 0 {
    x >= 48 && x <= 57
  } else if k == 1 {
    (x >= 97 && x <= 122) || (x >= 65 && x <= 90) || (x >= 48 && x <= 57) || x == 95
  } else {
    x == 32 || x == 9 || x == 10 || x == 13
  }
  yes != (code % 2 == 1)
}

// Is code point `x` in any of the `count` class items at `at`?
fn in_items(pg: [int], at: int, count: int, x: int): bool {
  var j = at
  let end = at + 2 * count
  while j < end {
    let lo = pg[j]
    if lo >= 0 {
      if x >= lo && x <= pg[j + 1] { return true }
    } else if kind_has(-1 - lo, x) {
      return true
    }
    j += 2
  }
  false
}

// Is code point `x` in the char set of node `nd`?
fn has(pg: [int], nd: int, x: int): bool {
  let kind = pg[nd]
  if kind == N_LIT { return x == pg[nd + 1] }
  if kind == N_DOT { return x != 10 }
  in_items(pg, pg[nd + 1], pg[nd + 2], x) != (pg[nd + 3] == 1)
}

// The end of the run of chars in set `nd` that starts at `i` and stops at `lim` at the latest.
fn scan(pg: [int], nd: int, cs: [char], i: int, lim: int): int {
  var j = i
  let kind = pg[nd]
  if kind == N_LIT {
    let c = pg[nd + 1]
    while j < lim && int(cs[j]) == c { j += 1 }
  } else if kind == N_DOT {
    while j < lim && cs[j] != '\n' { j += 1 }
  } else {
    let at = pg[nd + 1]
    let count = pg[nd + 2]
    let neg = pg[nd + 3] == 1
    while j < lim && in_items(pg, at, count, int(cs[j])) != neg { j += 1 }
  }
  j
}

fn unset(ngroups: int): [int] {
  var caps: [int] = []
  for _ in 0..=ngroups {
    caps.push(-1)
    caps.push(-1)
  }
  caps
}

// Frames of the continuation: what is left to match on the current path, as a linked
// list of 5-slot records `[kind, a, b, c, next]` in the matcher's arena.
let F_CAT = 0    // run the Cat children whose offsets sit at a..b
let F_CLOSE = 1  // close group a, which opened at index b
let F_MOVED = 2  // fail unless the path has moved past index a
let F_REP = 3    // repeat node a with lo = b and hi = c left

fn frame(ar: var [int], top: int, kind: int, a: int, b: int, c: int, next: int) {
  if top == ar.len() {
    ar.push(kind)
    ar.push(a)
    ar.push(b)
    ar.push(c)
    ar.push(next)
  } else {
    ar[top] = kind
    ar[top + 1] = a
    ar[top + 2] = b
    ar[top + 3] = c
    ar[top + 4] = next
  }
}

// Choice points: paths still to try, most recent last, as 7-slot records
// `[kind, i, k, top, trail, x, y]`: resume at index i with continuation k, the arena cut
// back to `top` and the captures undone back to `trail`.
let C_RUN = 0   // run node x (or just the continuation if x is -1); used once
let C_BACK = 1  // a greedy char-set repeat giving back a char at a time, down to index x;
// y: the code point that has to come next (see `next_lit`), or -1
let C_MORE = 2  // a lazy char-set repeat (set node y) taking one more char, x more allowed (-1: any)

fn choice(cp: var [int], at: int, kind: int, i: int, k: int, top: int, trail: int, x: int, y: int) {
  if at == cp.len() {
    cp.push(kind)
    cp.push(i)
    cp.push(k)
    cp.push(top)
    cp.push(trail)
    cp.push(x)
    cp.push(y)
  } else {
    cp[at] = kind
    cp[at + 1] = i
    cp[at + 2] = k
    cp[at + 3] = top
    cp[at + 4] = trail
    cp[at + 5] = x
    cp[at + 6] = y
  }
}

// Leftmost match starting at or after `at`: the capture spans (a start/end pair per group,
// -1 when unset), group 0 first. Backtracking is depth-first with the alternatives tried in
// pattern order, on explicit stacks, so long inputs never grow the call stack.
fn search(pg: [int], ngroups: int, cs: [char], at: int): [int]? {
  let n = cs.len()
  let root = pg[0]
  let lead = pg[1]
  let ftab = pg[2]
  if lead == -2 && at > 0 { return none }
  var caps = unset(ngroups)
  var dirty = false
  var ar: [int] = []  // continuation frames
  var cp: [int] = []  // choice points
  var tr: [int] = []  // capture slots overwritten since a choice point: slot, old value
  var st = at
  while st <= n {
    if ftab >= 0 {
      while st < n && pg[ftab + min(int(cs[st]), 128)] == 0 { st += 1 }
      if st >= n { return none }
    } else if lead >= 0 {
      st = skip_to(pg, lead, cs, st)
      if st >= n { return none }
    }
    if dirty {
      for j in 0..caps.len() { caps[j] = -1 }
      dirty = false
    }
    var i = st
    var nd = root  // the node to run next, or -1 to carry on with the continuation
    var k = -1     // the continuation: a frame's offset in `ar`, or -1 when nothing is left
    var top = 0    // used length of `ar`
    var cpl = 0    // used length of `cp`
    var trl = 0    // used length of `tr`
    var floor = 0  // frames at or above this offset are known to this path only
    let matched = loop {
      var ok = true
      var rep = -1  // a general repeat to run: its node, with `lo` and `hi` left
      var lo = 0
      var hi = 0
      if nd >= 0 {
        let kind = pg[nd]
        if kind == N_LIT {
          if i < n && int(cs[i]) == pg[nd + 1] {
            i += 1
            nd = -1
          } else {
            ok = false
          }
        } else if kind == N_CAT {
          let kids = pg[nd + 1]
          frame(&ar, top, F_CAT, kids + 1, kids + pg[nd + 2], 0, k)
          k = top
          top += 5
          nd = pg[kids]
        } else if kind == N_REP1 || kind == N_REP1L {
          let set = pg[nd + 1]
          let min = pg[nd + 2]
          let max = pg[nd + 3]
          if min > n - i {
            ok = false
          } else if kind == N_REP1 {
            // take as many as allowed, then give them back one at a time
            let j = scan(pg, set, cs, i, if max < 0 || max >= n - i { n } else { i + max })
            if j - i < min {
              ok = false
            } else {
              if j - i > min && k >= 0 {
                choice(&cp, cpl, C_BACK, j, k, top, trl, i + min, next_lit(pg, ar, k))
                cpl += 7
                floor = top
              }
              i = j
              nd = -1
            }
          } else {
            // take the fewest, then one more at a time
            let j = scan(pg, set, cs, i, i + min)
            if j - i < min {
              ok = false
            } else {
              if max != min && j < n && has(pg, set, int(cs[j])) {
                choice(&cp, cpl, C_MORE, j, k, top, trl, if max < 0 { -1 } else { max - min }, set)
                cpl += 7
                floor = top
              }
              i = j
              nd = -1
            }
          }
        } else if kind == N_DOT || kind == N_CLASS {
          if i < n && has(pg, nd, int(cs[i])) {
            i += 1
            nd = -1
          } else {
            ok = false
          }
        } else if kind == N_GROUP {
          frame(&ar, top, F_CLOSE, pg[nd + 1], i, 0, k)
          k = top
          top += 5
          nd = pg[nd + 2]
        } else if kind == N_ALT {
          choice(&cp, cpl, C_RUN, i, k, top, trl, pg[nd + 2], 0)
          cpl += 7
          floor = top
          nd = pg[nd + 1]
        } else if kind == N_REP || kind == N_REPL {
          rep = nd
          lo = pg[nd + 2]
          hi = pg[nd + 3]
        } else if kind == N_START {
          ok = i == 0
          nd = -1
        } else if kind == N_END {
          ok = i == n
          nd = -1
        } else {
          nd = -1  // N_EMPTY
        }
      } else if k < 0 {
        break true
      } else {
        // pop a frame; one this path made since the last choice point, on top of the arena,
        // is free again
        let f = k
        let kind = ar[f]
        let a = ar[f + 1]
        let b = ar[f + 2]
        k = ar[f + 4]
        if f + 5 == top && f >= floor { top = f }
        if kind == F_CAT {
          if a + 1 < b {
            frame(&ar, top, F_CAT, a + 1, b, 0, k)
            k = top
            top += 5
          }
          nd = pg[a]
        } else if kind == F_CLOSE {
          if cpl > 0 {
            if trl == tr.len() {
              for _ in 0..4 { tr.push(0) }
            }
            tr[trl] = 2 * a
            tr[trl + 1] = caps[2 * a]
            tr[trl + 2] = 2 * a + 1
            tr[trl + 3] = caps[2 * a + 1]
            trl += 4
          }
          caps[2 * a] = b
          caps[2 * a + 1] = i
          dirty = true
        } else if kind == F_MOVED {
          // an optional iteration that consumed nothing ends here, so `(a*)*` cannot loop forever
          ok = i > a
        } else {
          rep = a
          lo = b
          hi = ar[f + 3]
        }
      }
      if rep >= 0 {
        let body = pg[rep + 1]
        if lo > 0 {
          frame(&ar, top, F_REP, rep, lo - 1, if hi < 0 { -1 } else { hi - 1 }, k)
          k = top
          top += 5
          nd = body
        } else if hi == 0 {
          nd = -1
        } else {
          // one more optional iteration, or stop here: greedy tries the iteration first
          let left = if hi < 0 { -1 } else { hi - 1 }
          if pg[rep] == N_REPL {
            frame(&ar, top, F_REP, rep, 0, left, k)
            frame(&ar, top + 5, F_MOVED, i, 0, 0, top)
            top += 10
            choice(&cp, cpl, C_RUN, i, top - 5, top, trl, body, 0)
            cpl += 7
            floor = top
            nd = -1
          } else {
            choice(&cp, cpl, C_RUN, i, k, top, trl, -1, 0)
            cpl += 7
            floor = top
            frame(&ar, top, F_REP, rep, 0, left, k)
            frame(&ar, top + 5, F_MOVED, i, 0, 0, top)
            k = top + 5
            top += 10
            nd = body
          }
        }
      }
      if !ok {
        // backtrack to the most recent choice point
        if cpl == 0 { break false }
        let c = cpl - 7
        let kind = cp[c]
        top = cp[c + 3]
        let trail = cp[c + 4]
        while trl > trail {
          trl -= 2
          caps[tr[trl]] = tr[trl + 1]
        }
        k = cp[c + 2]
        if kind == C_RUN {
          i = cp[c + 1]
          nd = cp[c + 5]
          cpl = c
        } else if kind == C_BACK {
          i = cp[c + 1] - 1
          let min = cp[c + 5]
          let want = cp[c + 6]
          if want >= 0 {
            // ends that the next literal rules out would only fail and come back here
            while i > min && (i >= n || int(cs[i]) != want) { i -= 1 }
          }
          if i == min { cpl = c } else { cp[c + 1] = i }
          nd = -1
        } else {
          i = cp[c + 1] + 1
          let more = cp[c + 5]
          let left = if more > 0 { more - 1 } else { more }
          if left == 0 || i >= n || !has(pg, cp[c + 6], int(cs[i])) {
            cpl = c
          } else {
            cp[c + 1] = i
            cp[c + 5] = left
          }
          nd = -1
        }
        floor = if cpl > 0 { cp[cpl - 4] } else { 0 }
      }
    }
    if matched {
      caps[0] = st
      caps[1] = i
      return caps
    }
    if lead == -2 { return none }
    st += 1
  }
  none
}

// The code point continuation `k` has to match first if it is a literal, else -1: the first
// node to run, looking through group closes, groups and concatenations.
fn next_lit(pg: [int], ar: [int], k: int): int {
  var f = k
  while ar[f] == F_CLOSE {
    f = ar[f + 4]
    if f < 0 { return -1 }
  }
  if ar[f] != F_CAT { return -1 }
  var nd = pg[ar[f + 1]]
  loop {
    let kind = pg[nd]
    if kind == N_LIT { return pg[nd + 1] }
    if kind == N_CAT {
      nd = pg[pg[nd + 1]]
    } else if kind == N_GROUP {
      nd = pg[nd + 2]
    } else {
      return -1
    }
  }
}

// The first index at or after `i` whose char is in set `nd` (or the length if there is none).
fn skip_to(pg: [int], nd: int, cs: [char], i: int): int {
  let n = cs.len()
  var j = i
  let kind = pg[nd]
  if kind == N_LIT {
    let c = pg[nd + 1]
    while j < n && int(cs[j]) != c { j += 1 }
  } else if kind == N_DOT {
    while j < n && cs[j] == '\n' { j += 1 }
  } else {
    let at = pg[nd + 1]
    let count = pg[nd + 2]
    let neg = pg[nd + 3] == 1
    while j < n && in_items(pg, at, count, int(cs[j])) == neg { j += 1 }
  }
  j
}

// Every non-overlapping match, left to right. After an empty match the scan
// moves on one char so it always makes progress.
fn spans(pg: [int], ngroups: int, cs: [char]): [[int]] {
  var out: [[int]] = []
  var at = 0
  while at <= cs.len() {
    let m = search(pg, ngroups, cs, at) else break
    out.push(m)
    at = if m[1] > m[0] { m[1] } else { m[1] + 1 }
  }
  out
}

fn sub(cs: [char], a: int, b: int): str = str(cs[a..b])

fn group(m: [int], cs: [char], g: int): str? {
  if g < 0 || 2 * g + 1 >= m.len() || m[2 * g] < 0 { return none }
  sub(cs, m[2 * g], m[2 * g + 1])
}

// ---- public matching API ----

/// The leftmost match in `s`, or none.
pub fn find(r: Regex, s: str): str? {
  let cs = s.chars()
  let m = search(compile(r, cs.len()), r.ngroups, cs, 0) else return none
  sub(cs, m[0], m[1])
}

/// Every non-overlapping match in `s`, left to right.
pub fn find_all(r: Regex, s: str): [str] {
  let cs = s.chars()
  var out: [str] = []
  for m in spans(compile(r, cs.len()), r.ngroups, cs) { out.push(sub(cs, m[0], m[1])) }
  out
}

/// True if `r` matches anywhere in `s`.
pub fn is_match(r: Regex, s: str): bool {
  let cs = s.chars()
  search(compile(r, cs.len()), r.ngroups, cs, 0) is some(_)
}

/// The groups of the leftmost match: index 0 is the whole match, then one entry
/// per `( )` group (none if that group took no part). None if nothing matches.
pub fn captures(r: Regex, s: str): [str?]? {
  let cs = s.chars()
  let m = search(compile(r, cs.len()), r.ngroups, cs, 0) else return none
  var out: [str?] = []
  for g in 0..=r.ngroups { out.push(group(m, cs, g)) }
  out
}

/// Replace every match with `with`, where `$0`..`$99` insert a group (empty if
/// unset or out of range) and `$$` inserts a `$`.
pub fn replace(r: Regex, s: str, with: str): str {
  let cs = s.chars()
  let ms = spans(compile(r, cs.len()), r.ngroups, cs)
  if ms.len() == 0 { return s }
  let plain = !with.contains('$')
  let tpl = if plain { [] } else { with.chars() }
  var out = ""
  var last = 0
  for m in ms {
    if m[0] > last { out += str(cs[last..m[0]]) }
    if plain { out += with } else { expand(&out, tpl, m, cs) }
    last = m[1]
  }
  if last < cs.len() { out += str(cs[last..cs.len()]) }
  out
}

// Appends the template with its `$` references filled in from match `m`.
fn expand(out: var str, tpl: [char], m: [int], cs: [char]) {
  let n = tpl.len()
  var i = 0
  var lit = 0  // start of the literal text not appended yet
  while i < n {
    if tpl[i] != '$' || i + 1 >= n {
      i += 1
      continue
    }
    if tpl[i + 1] == '$' {
      out += str(tpl[lit..i + 1])
      i += 2
      lit = i
      continue
    }
    var j = i + 1
    while j < n && tpl[j].is_digit() && j - i <= 2 { j += 1 }
    if j == i + 1 {  // a `$` that names no group stays as it is
      i += 1
      continue
    }
    if i > lit { out += str(tpl[lit..i]) }
    let g = int.parse(str(tpl[i + 1..j])) else 0
    out += group(m, cs, g) else ""
    i = j
    lit = i
  }
  if n > lit { out += str(tpl[lit..n]) }
}

/// Split `s` around every match. An empty match splits between chars but never
/// at either end or right after another match, so `regex("").split("ab")` is `["a", "b"]`.
pub fn split(r: Regex, s: str): [str] {
  let cs = s.chars()
  var out: [str] = []
  var last = 0
  for m in spans(compile(r, cs.len()), r.ngroups, cs) {
    if m[0] == m[1] && (m[0] == last || m[0] == cs.len()) { continue }
    out.push(sub(cs, last, m[0]))
    last = m[1]
  }
  out.push(sub(cs, last, cs.len()))
  out
}

// ---- tests ----

test "literals and dot" {
  assert (regex("abc")?).find("xxabcxx") is some("abc")
  assert (regex("abc")?).find("ab") is none
  assert (regex("a.c")?).find("a-c") is some("a-c")
  assert (regex("a.c")?).find("a\nc") is none
  assert (regex("")?).find("xyz") is some("")
  assert (regex("é+")?).find("caféé!") is some("éé")
  assert (regex(r"]}")?).find(r"x]}") is some(r"]}")
}

test "classes" {
  assert (regex("[a-c]+")?).find("xxbcaz") is some("bca")
  assert (regex("[^0-9]+")?).find("12ab3") is some("ab")
  assert (regex(r"[\d_]+")?).find("ab1_2c") is some("1_2")
  assert (regex("[]a]+")?).find("x]a]y") is some("]a]")
  assert (regex("[a-]+")?).find("b-a-c") is some("-a-")
  assert (regex(r"[^\s]+")?).find("  hi there") is some("hi")
  assert (regex("[.]")?).find("a.b") is some(".")
}

test "escapes" {
  let digits = regex(r"\d+")?
  assert digits.find_all("a1b22c333") == ["1", "22", "333"]
  assert (regex(r"\w+")?).find_all("hi, you_2!") == ["hi", "you_2"]
  assert (regex(r"\D+")?).find("12ab34") is some("ab")
  assert (regex(r"\W")?).find_all("a,b;c") == [",", ";"]
  assert (regex(r"\S+")?).find_all("  x yz ") == ["x", "yz"]
  assert (regex(r"\s+")?).replace("a \t b\nc", " ") == "a b c"
  assert (regex(r"a\.b")?).is_match("a.b")
  assert !(regex(r"a\.b")?).is_match("axb")
  assert (regex(r"a\\b")?).find("xa\\by") is some("a\\b")
  assert (regex(r"\(\*\)")?).find("f(*)") is some("(*)")
  assert (regex(r"\t")?).is_match("a\tb")
}

test "anchors" {
  assert (regex("^ab")?).is_match("abc")
  assert !(regex("^ab")?).is_match("cab")
  assert (regex("ab$")?).is_match("cab")
  assert !(regex("ab$")?).is_match("abc")
  assert (regex("^$")?).is_match("")
  assert (regex("^a|b$")?).find_all("ab") == ["a", "b"]
}

test "alternation is leftmost-first" {
  assert (regex("cat|dog")?).find_all("dog cat cow") == ["dog", "cat"]
  assert (regex("a|ab")?).find("ab") is some("a")
  assert (regex("ab|a")?).find("ab") is some("ab")
  assert (regex("x(a|)y")?).find("xy") is some("xy")
}

test "greedy quantifiers" {
  assert (regex("a+")?).find("baaac") is some("aaa")
  assert (regex("ba*")?).find("baaac") is some("baaa")
  assert (regex("ba*")?).find("bc") is some("b")
  assert (regex("colou?r")?).find_all("color colour") == ["color", "colour"]
  assert (regex(r"a{2}")?).find("aaaa") is some("aa")
  assert (regex(r"a{2,}")?).find("aaaa") is some("aaaa")
  assert (regex(r"a{1,3}")?).find("aaaa") is some("aaa")
  assert (regex(r"a{0}b")?).find("aab") is some("b")
  assert (regex(r"^a{2,3}$")?).is_match("aaa")
  assert !(regex(r"^a{2,3}$")?).is_match("aaaa")
  assert (regex("<.+>")?).find("<a><b>") is some("<a><b>")
  assert (regex(r"(ab)+")?).find("xababa") is some("abab")
}

test "lazy quantifiers" {
  assert (regex("<.+?>")?).find("<a><b>") is some("<a>")
  assert (regex("<.*?>")?).find_all("<a><bc>") == ["<a>", "<bc>"]
  assert (regex("a*?")?).find("aaa") is some("")
  assert (regex("a+?")?).find("aaa") is some("a")
  assert (regex("ba??")?).find("ba") is some("b")
  assert (regex(r"a{2,}?")?).find("aaaa") is some("aa")
  assert (regex("a.*?c")?).find("abcbc") is some("abc")
}

test "backtracking" {
  assert (regex("a.*b")?).find("xaxxbxxbx") is some("axxbxxb")
  assert (regex(r"(a|ab)(c|bcd)(d*)")?).find("abcd") is some("abcd")
  assert (regex(r"^(\d+)(\d)$")?).captures("1234") is some([some("1234"), some("123"), some("4")])
  assert (regex("(a*)*b")?).find("aaac") is none
  assert (regex("(a*)*b")?).find("aab") is some("aab")
  assert (regex("(a|)*x")?).find("aax") is some("aax")
}

test "captures" {
  let r = regex(r"(\w+)@(\w+)\.com")?
  assert r.captures("mail ann@auk.com now") is some([some("ann@auk.com"), some("ann"), some("auk")])
  assert r.captures("nothing here") is none
  assert (regex(r"(\d+)-(\d+)?")?).captures("10-") is some([some("10-"), some("10"), none])
  assert (regex(r"(?:ab)+(c)")?).captures("ababc") is some([some("ababc"), some("c")])
  assert (regex(r"(a)|(b)")?).captures("b") is some([some("b"), none, some("b")])
  assert (regex(r"(?:(a)|b)+")?).captures("ab") is some([some("ab"), some("a")])
  assert (regex("((a)(b))")?).group_count() == 3
  assert (regex("(?:a)")?).group_count() == 0
}

test "find_all with empty matches" {
  assert (regex("a*")?).find_all("baa") == ["", "aa", ""]
  assert (regex("x")?).find_all("") == []
  assert (regex("")?).find_all("ab") == ["", "", ""]
}

test "replace" {
  let r = regex(r"(\w+)@(\w+)")?
  assert r.replace("ann@auk bob@goose", "$2:$1") == "auk:ann goose:bob"
  assert r.replace("ann@auk", "[$0]") == "[ann@auk]"
  assert r.replace("ann@auk", "$9|$$|$x|$") == "|$|$x|$"
  assert (regex(r"\d")?).replace("a1b2", "#") == "a#b#"
  assert (regex("z")?).replace("abc", "!") == "abc"
  assert (regex("")?).replace("ab", "-") == "-a-b-"
}

test "split" {
  assert (regex(r"\s*,\s*")?).split("a , b,c") == ["a", "b", "c"]
  assert (regex(",")?).split("a,,b") == ["a", "", "b"]
  assert (regex(",")?).split(",a,") == ["", "a", ""]
  assert (regex("x")?).split("") == [""]
  assert (regex("")?).split("abc") == ["a", "b", "c"]
  assert (regex("x*")?).split("axxb") == ["a", "b"]
}

test "escape" {
  let s = r"1+1=2? (yes) [a] {b} ^$ \ | ."
  assert (regex(escape(s))?).find("so " + s + "!") == some(s)
  assert escape("a.b") == r"a\.b"
}

test "compile errors carry the position" {
  assert regex("a(b") is err(Unclosed(1, '('))
  assert regex("a)") is err(Unexpected(1, ')'))
  assert regex("x[abc") is err(Unclosed(1, '['))
  assert regex("*a") is err(NothingToRepeat(0))
  assert regex("a**") is err(NothingToRepeat(2))
  assert regex("a|+") is err(NothingToRepeat(2))
  assert regex("(?a)") is err(BadGroup(1))
  assert regex(r"a{3,1}") is err(BadRepeat(1))
  assert regex(r"a{x}") is err(BadRepeat(1))
  assert regex(r"a{2") is err(BadRepeat(1))
  assert regex(r"{2}") is err(NothingToRepeat(0))
  assert regex("[z-a]") is err(BadRange(1))
  assert regex(r"[\d-z]") is err(BadRange(1))
  assert regex(r"a\q") is err(BadEscape(1, 'q'))
  assert regex("ab\\") is err(TrailingBackslash(2))
  assert regex("[a\\") is err(TrailingBackslash(2))
}

test "error helpers" {
  assert regex("ab(") is err(Unclosed(2, '('))
  let e = Unclosed(2, '(')
  assert e.pos() == 2
  assert e.message() == "regex: '(' at 2 is never closed"
  assert BadEscape(4, 'q').message() == "regex: unknown escape '\\q' at 4"
}

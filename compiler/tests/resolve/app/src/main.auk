/// Paths through every kind of first segment: a local module, the package itself, a
/// dependency (and its submodule), core and its modules, and names that are no module.

struct Pair<T: core.Show> { a: geo.shapes.Circle, b: [util.text.Word?], c: T }

enum Msg { Draw(s: geo.Shape), Say(w: util.text.Word, n: int!core.Err) }

shape Named { fn name(self): app.geo.Label }

let ORIGIN: geo.shapes.Point = geo.shapes.Point { x: 0, y: 0 }

fn area(s: geo.Shape, f: (geo.shapes.Circle) => float): float = match s {
  geo.Shape.Round(c) => f(c)
  geo.Shape.Box(geo.shapes.Rect { w, h }) => w * h
  _ => 0.0
}

fn main(args: [str]) uses fs, net {
  let words: [util.text.Word] = util.split(args[0])
  for i, util.text.Word(w) in words {
    print("{i} {w}")
  }
  let l = deep.a.b.depth()
  let x = core.str.missing.thing
  if words.len() is 0 { fs.read("x") else "" }
  let n = net
  let local = args.len()
  local.show()
  missing.call()
  str(1)
  app.geo.label("{geo.shapes.unit()}")
  let c = (p: geo.shapes.Point) => p.x
  base.zero()
  util.base_zero()
}

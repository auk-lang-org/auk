struct P { pos: int }

fn apply(p: var P, g: (var P) => int!): int! = g(&p)?

fn pair(g: (var P, int) => (), h: (int, var [str]) => int?) {}

let f: (var int) => () = x => { x += 1 }

fn main() {
  var p = P { pos: 0 }
  print(
    apply(&p, (q: var P) => {
      q.pos += 1
      q.pos
    }),
  )
}

shape Area {
  fn area(self): float
}

shape Loud {
  fn shout(self): str uses net, tim
}

struct Sq { s: float }

struct Disk { r: float }

fn area(q: Sq): float uses fs {
  let _ = fs.read("x") else ""
  q.s * q.s
}

fn area(d: Disk): float = d.r

fn shout(q: Sq): str uses net, rand = "sq {rand.int(1, 2)}"

fn show(d: Disk): str uses time = "disk {time.now()}"

fn total<T: Area>(xs: [T]): float {
  var t = 0.0
  for x in xs { t += x.area() }
  t
}

fn twice<T: Area>(xs: [T]): float = total(xs) + total(xs)

fn label(d: Disk): str = "it is {d}"

fn fetch(p: str): str uses fs = fs.read(p) else ""

fn all(ps: [str]): [str] = ps.map(fetch)

fn lazy(ps: [str]): [str] {
  let f = (p: str) => {
    let g = (q: str) => fs.read(q) else ""
    g(p) + "{time.now()}"
  }
  ps.map(f)
}

fn mixed(
  a: int,
  b: str
) uses env, proc {
  time.sleep(a)
}

fn mixed2(a: int, s: [str]) uses env {
  let _ = rand.int(1, a)
}

fn louder(q: Sq): any Loud = q

imprint K = twice([Sq { s: 1.0 }])

let L = label(Disk { r: 1.0 })

fn main() {
  print(twice([Sq { s: 2.0 }]) + twice([Disk { r: 1.0 }]))
  print(all(["a"]).len() + lazy([]).len())
  mixed(1, "")
  print(louder(Sq { s: 1.0 }).shout())
  mixed2(2, [")"])
}

test "tests may use anything" {
  let _ = fs.read("x") else ""
  time.sleep(1)
}

struct Doc { title: str, lines: [str] }

fn grow(s: var str, n: int) {
  for i in 0..n { s += "{i}" }
}

async fn build(n: int): str {
  var s = ""
  for i in 0..n { s += "ab" }
  s
}

fn main() {
  var s = ""
  for i in 0..1000 { s += "é" }
  print("{s.len()} {s.bytes().len()}")
  let snap = s
  s += "x"
  print("{snap.len()} {s.len()} {snap == s}")
  var t = "ab"
  t = t + t
  t += t
  print(t)
  var d = Doc { title: "a", lines: ["x"] }
  let d0 = d
  d.title += "bc"
  d.lines[0] += "yz"
  print("{d.title} {d.lines} {d0.title} {d0.lines}")
  var u = "q"
  grow(&u, 12)
  print(u)
  var w = "abc"
  w = w + "d"
  w = "z" + w
  print("{w} {w.len()} {w[3]}")
  var m = {"k": "v"}
  m["k"] += "w"
  print(m)
  var acc = ""
  for i in 0..20000 { acc = acc + "xy" }
  print(acc.len())
  let a = build(5000)
  let b = build(3000)
  print("{(await a).len()} {(await b).len()}")
}

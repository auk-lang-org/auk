fn swap() {
  var a = 1
  var b = 2
  (a, b) = (b, a)
  (p.x, xs[i], (c, d.0)) = f()
}

fn bad() {
  (a, b) += (1, 2)
}

fn bad2() {
  (a, f()) = (1, 2)
}

fn bad3() {
  () = ()
}

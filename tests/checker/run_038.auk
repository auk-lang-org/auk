fn l1(): ()! {
  loop { break }
}
fn l2(): ()? {
  loop { break }
}
fn l3(n: int): ()! {
  var i = 0
  loop {
    if i == n { break }
    if i > 5 { fail("big") }
    i += 1
  }
}
fn l4(n: int): ()? {
  var i = 0
  loop {
    if i > 3 { return none }
    if i == n { break }
    i += 1
  }
}
fn w1(n: int): ()! {
  var i = 0
  while i < n {
    if i > 5 { fail("big") }
    i += 1
  }
}
fn w2(n: int): ()? {
  var i = 0
  while i < n {
    if i > 5 { return none }
    i += 1
  }
}
fn f1(n: int): ()! {
  for i in 0..n { if i > 5 { fail("big") } }
}
fn f2(n: int): ()? {
  for i in 0..n { if i > 5 { return none } }
}
fn v1(n: int): int! {
  var i = 0
  loop {
    if i > 5 { fail("big") }
    if i == n { break i * 10 }
    i += 1
  }
}
fn v2(n: int): str? {
  var i = 0
  loop {
    if i > 5 { return none }
    if i == n { break "s{i}" }
    i += 1
  }
}
fn v3(n: int): int! {
  for i in 0..10 { if i == n { return i } }
  fail("none")
}
fn m1(n: int): ()! {
  match n {
    0 => loop { break },
    1 => while false {},
    2 => for _ in 0..3 {},
    _ => fail("bad"),
  }
}
fn m2(n: int): ()? {
  match n {
    0 => loop { break },
    _ => loop { if n > 3 { return none } else { break } },
  }
}
fn m3(n: int): int! {
  match n {
    0 => loop { break 7 },
    _ => loop { if n > 3 { fail("big") } else { break n } },
  }
}
fn i1(n: int): ()! {
  if n == 0 { loop { break } } else if n == 1 { for _ in 0..2 {} } else { loop { if n > 2 { fail("x") }
  break } }
}
fn i2(n: int): ()? {
  if n == 0 { loop { break } } else { while true { if n > 1 { return none }
  break } }
}
fn i3(n: int): int! {
  if n == 0 { loop { break 1 } } else { loop { if n > 1 { fail("x") }
  break 2 } }
}
fn ok(r: ()!): str {
  match r {
    ok(_) => "ok",
    err(e) => "err({e})",
  }
}
fn main() {
  print("{ok(l1())} {l2() is some(_)}")
  print("{ok(l3(2))} {ok(l3(9))} {l4(2) is some(_)} {l4(9) is none}")
  print("{ok(w1(2))} {ok(w1(9))} {w2(2) is some(_)} {w2(9) is none}")
  print("{ok(f1(2))} {ok(f1(9))} {f2(2) is some(_)} {f2(9) is none}")
  print("{v1(2) else -1} {v1(9) else -1} {v2(3) else "-"} {v2(9) else "-"} {v3(4) else -1} {v3(40) else -1}")
  print("{ok(m1(0))} {ok(m1(1))} {ok(m1(2))} {ok(m1(3))}")
  print("{m2(0) is some(_)} {m2(1) is some(_)} {m2(5) is none}")
  print("{m3(0) else -1} {m3(2) else -1} {m3(5) else -1}")
  print("{ok(i1(0))} {ok(i1(1))} {ok(i1(2))} {ok(i1(3))}")
  print("{i2(0) is some(_)} {i2(1) is some(_)} {i2(2) is none}")
  print("{i3(0) else -1} {i3(1) else -1} {i3(2) else -1}")
  let r: ()! = loop { break }
  let s: ()? = loop { break }
  print("{ok(r)} {s is some(_)}")
}

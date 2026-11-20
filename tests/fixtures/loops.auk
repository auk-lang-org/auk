/// `for` over lists and ranges, which run in blocks of 1024 iterations when the body makes no
/// long calls (compiler/src/mir/lower.auk, `counted_open`), and the list helpers `truncate` and
/// `repeat`.

fn upto(n: int): [int] {
  var xs: [int] = []
  for i in 0..n { xs.push(i) }
  xs
}

test "break and continue across block edges" {
  let xs = upto(3000)
  for stop in [0, 1, 1022, 1023, 1024, 1025, 2047, 2048, 2999] {
    var seen = 0
    var last = -1
    for i, x in xs {
      if x == stop { break }
      if x % 2 == 1 { continue }
      seen += 1
      last = i
    }
    assert seen == (stop + 1) / 2
    assert last == if stop == 0 { -1 } else { (stop - 1) / 2 * 2 }
  }
}

test "every length around a block" {
  for n in [0, 1, 1023, 1024, 1025, 2048, 4097] {
    let xs = upto(n)
    var t = 0
    var k = 0
    for x in xs {
      t += x
      k += 1
    }
    assert k == n
    assert t == n * (n - 1) / 2
    var r = 0
    for i in 0..n { r += 1 }
    assert r == n
    var q = 0
    for i in 1..=n { q += i }
    assert q == n * (n + 1) / 2
  }
}

test "ranges near the ends of int" {
  let max = 9223372036854775807
  let min = -max - 1
  var a: [int] = []
  for i in (max - 3)..max { a.push(max - i) }
  assert a == [3, 2, 1]
  var b: [int] = []
  for i in min..(min + 3) { b.push(i - min) }
  assert b == [0, 1, 2]
  var c = 0
  for i in min..max {
    c += 1
    if c == 3000 { break }
  }
  assert c == 3000
  var d = 0
  for i in 5..5 { d += 1 }
  for i in 5..=4 { d += 1 }
  for i in 5..-5 { d += 1 }
  assert d == 0
  var e: [int] = []
  for i in -2..=2 { e.push(i) }
  assert e == [-2, -1, 0, 1, 2]
}

test "the body changes the list it walks" {
  var xs = upto(1500)
  var n = 0
  for x in xs {
    xs.push(x)
    xs[0] = 99
    n += 1
  }
  assert n == 1500
  assert xs.len() == 3000
  assert xs[0] == 99 && xs[1500] == 0
}

test "elements with references" {
  var ws: [str] = []
  for i in 0..2000 { ws.push("w{i}") }
  var bytes = 0
  for w in ws {
    if w == "w1999" { break }
    bytes += w.byte_len()
  }
  assert bytes > 0
  assert ws.contains("w1024") && !ws.contains("w2000")
  assert upto(3000).contains(2999) && !upto(3000).contains(3000)
}

test "truncate" {
  var xs = upto(10)
  xs.truncate(4)
  assert xs == [0, 1, 2, 3]
  xs.truncate(10)
  assert xs == [0, 1, 2, 3]
  xs.push(7)
  assert xs == [0, 1, 2, 3, 7]
  let keep = xs
  xs.truncate(1)
  assert xs == [0] && keep == [0, 1, 2, 3, 7]
  var ss = ["a", "b", "c"]
  let snap = ss
  ss.truncate(2)
  assert ss == ["a", "b"] && snap == ["a", "b", "c"]
  ss.truncate(0)
  assert ss.len() == 0
  var tail = upto(6)[2..6]
  tail.truncate(2)
  assert tail == [2, 3]
}

test "repeat" {
  assert [0].repeat(5) == [0, 0, 0, 0, 0]
  assert ["a", "b"].repeat(3) == ["a", "b", "a", "b", "a", "b"]
  assert [1, 2].repeat(0).len() == 0
  assert [1, 2].repeat(1) == [1, 2]
  let e: [int] = []
  assert e.repeat(4).len() == 0
  let big = [1, 2, 3].repeat(1000)
  assert big.len() == 3000 && big[2999] == 3 && big[1500] == 1
  var grid = [[0].repeat(3)].repeat(2)
  grid[0][1] = 5
  assert grid == [[0, 5, 0], [0, 0, 0]]
}

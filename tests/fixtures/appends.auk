/// `x = x + a + b` on strings and lists is compiled as in-place appends (linear in a loop),
/// and indexing a non-ASCII string resumes from the last index looked up. Both must give the
/// same results as the plain definitions; run by tests/runner (collections.auk) under the leak
/// checker.

struct B { s: str, xs: [int], t: (str, int), inner: In }
struct In { s: str }

fn grow(s: var str, x: str) { s = s + x + s }

test "appends keep their meaning" {
  var s = "ab"
  let keep = s
  s = s + "c" + s
  s = s + s + s
  s = s + "é" + "{s.len()}"
  assert s == "abcababcababcabé15"
  assert keep == "ab"
  var xs = [1, 2]
  let kx = xs
  xs = xs + [3] + xs
  xs = xs + xs
  xs = xs + [xs.len(), xs[0]] + [9]
  assert xs == [1, 2, 3, 1, 2, 1, 2, 3, 1, 2, 10, 1, 9]
  assert kx == [1, 2]
  var b = B { s: "s", xs: [1], t: ("t", 1), inner: In { s: "i" } }
  let kb = b
  b.s = b.s + b.s + "x"
  b.xs = b.xs + [2] + b.xs
  b.t.0 = b.t.0 + "u" + b.t.0
  b.inner.s = b.inner.s + "j" + b.s
  assert b == B { s: "ssx", xs: [1, 2, 1], t: ("tut", 1), inner: In { s: "ijssx" } }
  assert kb == B { s: "s", xs: [1], t: ("t", 1), inner: In { s: "i" } }
  var ps = ["a", "b", "c"]
  var i = 0
  ps[i] = ps[i] + ps[1] + ps[i]
  i = 2
  ps[i] = ps[i] + ps[i] + "w"
  let kp = ps
  ps[0] = ps[0] + "!"
  assert ps == ["aba!", "b", "ccw"]
  assert kp == ["aba", "b", "ccw"]
  var g = "g"
  grow(&g, "-")
  grow(&g, "+")
  assert g == "g-g+g-g"
  var c = "c"
  let add = (x: str) => x + "1"
  c = c + add(c) + c
  assert c == "cc1c"
}

test "appending in a loop" {
  var s = ""
  var xs: [int] = []
  var b = B { s: "", xs: [], t: ("", 0), inner: In { s: "" } }
  for i in 0..100_000 {
    s = s + "a" + "{i % 10}"
    xs = xs + [i]
    b.s = b.s + "x"
    b.xs = b.xs + [i, i]
  }
  assert s.len() == 200_000 && s[199_999] == '9'
  assert xs.len() == 100_000 && xs[99_999] == 99_999
  assert b.s.len() == 100_000 && b.xs.len() == 200_000
}

// every char and slice of s, by index, forwards and backwards
fn walk(s: str): str {
  var out = ""
  for i in 0..s.len() { out += "{s[i]}" }
  var j = s.len() - 1
  while j >= 0 {
    out += "{s[j]}"
    j -= 2
  }
  for k in 0..s.len() { out += s[k..min(s.len(), k + 3)] + "|" }
  out
}

// the same through chars()
fn walk_chars(s: str): str {
  let cs = s.chars()
  var out = ""
  for c in cs { out += "{c}" }
  var j = cs.len() - 1
  while j >= 0 {
    out += "{cs[j]}"
    j -= 2
  }
  for k in 0..cs.len() { out += str(cs[k..min(cs.len(), k + 3)]) + "|" }
  out
}

test "indexing non-ASCII text" {
  var u = "héllo wörld 😀 ok"
  for k in 0..40 {
    assert walk(u) == walk_chars(u)
    var tmp = u + "ü"
    assert walk(tmp) == walk_chars(tmp)
    tmp = ""
    u += if k % 3 == 0 { "é" } else { "a" }
    u = u + "😀" + "z"
    assert u[u.len() - 1] == 'z' && u[u.len() - 2] == '😀'
  }
  let words = ["a", "é", "😀", "b", "ü"]
  for n in 0..60 {
    var w = ""
    for m in 0..n { w += words[(m * 7 + n) % words.len()] }
    assert walk(w) == walk_chars(w)
  }
}

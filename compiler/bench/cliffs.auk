/// Micro-benchmarks for the performance cliffs in docs/pilot-report.md (in-place mutation,
/// moving out of a container, string building, slicing). Build with `auk build` and run with
/// an iteration count: `auk build compiler/bench/cliffs.auk -o /tmp/cliffs && /tmp/cliffs 80000`.

struct Holder { xs: [int], n: int }

fn push_via_var(h: var Holder, x: int) { h.xs.push(x) }

fn bench(name: str, t0: int) uses time { print("{name}: {time.now() - t0} ms") }

fn main(args: [str]) uses time {
  let n = int.parse(args.get(1) else "100000") else 100000

  // 1. push through a var parameter into a struct field
  var t = time.now()
  var h = Holder { xs: [], n: 0 }
  for i in 0..n { push_via_var(&h, i) }
  bench("struct field push via var param ({h.xs.len()})", t)

  // 2. push into a list element of a list
  t = time.now()
  var ls: [[int]] = [[]]
  for i in 0..n { ls[0].push(i) }
  bench("xs[0].push ({ls[0].len()})", t)

  // 3. push into a map value
  t = time.now()
  var m: {str: [int]} = {"k": []}
  for i in 0..n { m["k"].push(i) }
  bench("m[k].push ({m["k"].len()})", t)

  // 4. take an element out, push, put it back
  t = time.now()
  var ls2: [[int]] = [[]]
  for i in 0..n {
    var x = ls2[0]
    x.push(i)
    ls2[0] = x
  }
  bench("x = xs[0]; x.push; xs[0] = x ({ls2[0].len()})", t)

  // 5. string += in a loop
  t = time.now()
  var s = ""
  for i in 0..n { s += "x" }
  bench("s += \"x\" ({s.len()})", t)

  // 6. [str] + join
  t = time.now()
  var parts: [str] = []
  for i in 0..n { parts.push("x") }
  let j = parts.join("")
  bench("parts.push + join ({j.len()})", t)

  // 7. str of chars
  t = time.now()
  var cs: [char] = []
  for i in 0..n { cs.push('x') }
  let s2 = str(cs)
  bench("str([char]) ({s2.len()})", t)

  // 8. slicing a non-ASCII string by char index
  t = time.now()
  let text = "é" + "a".repeat(n)
  var total = 0
  for i in 0..1000 { total += text[i..i + 5].len() }
  bench("1000 slices of a non-ASCII str of {n} chars ({total})", t)
  t = time.now()
  let ascii = "a".repeat(n)
  total = 0
  for i in 0..1000 { total += ascii[i..i + 5].len() }
  bench("1000 slices of an ASCII str of {n} chars ({total})", t)
}

/// Ownership at a value's last use (design/ownership-plan.md): loops that take a value out of a
/// list or map, change it and put it back change it in place. Each program runs under
/// `AUK_STATS`, which prints the copy-on-write copies at exit, and the leak check.

pub fn tests(): [t.Test] uses env, fs, ffi, time = [
  t.test("take_and_put_back_changes_in_place", take_and_put_back_changes_in_place),
  t.test("take_and_put_back_falls_back_when_unsafe", take_and_put_back_falls_back_when_unsafe),
  t.test("a_caught_panic_leaves_a_var_parameter_valid", a_caught_panic_leaves_a_var_parameter_valid),
]

fn scratch(name: str): str uses env, fs, ffi = t.scratch("ownership/{name}")

/// `auk run` of `src` with the copy count on: (stdout, copies).
fn run_counted(name: str, src: str, leak_check: bool): (str, int) uses env, fs, ffi, time {
  let d = scratch(name)
  let f = paths.join(d, "main.auk")
  t.write(f, src)
  var c = t.auk().args(["run", f]).setenv("AUK_STATS", "1")
  c = if leak_check { c.setenv("AUK_LEAK_CHECK", "1") } else { c.unsetenv("AUK_LEAK_CHECK") }
  let o = c.output()
  t.check(o.success(), o.describe())
  var copies = -1
  for l in o.stderr.lines() {
    if l.starts_with("auk: ") && l.ends_with(" copy-on-write copies") {
      copies = int.parse(l.split(" ")[1]) else -1
    }
  }
  t.check(copies >= 0, "no copy count in stderr:\n{o.stderr}")
  (o.stdout, copies)
}

/// `var xs = m.get(k) else d`, `xs[i]`, on locals and `var` parameters: no copies however many
/// times the loop runs.
fn take_and_put_back_changes_in_place() uses env, fs, ffi, time {
  let (out, copies) = run_counted("in_place", r"""
      fn add(m: var {str: [int]}, k: str, v: int) {
        var xs = m.get(k) else []
        xs.push(v)
        m[k] = xs
      }
      fn add_at(chans: var [[int]], c: int, v: int) {
        var ch = chans[c]
        ch.push(v)
        chans[c] = ch
      }
      fn main() {
        var m: {int: [int]} = {}
        for i in 0..2000 {
          let k = i % 4
          var xs = m.get(k) else []
          xs.push(i)
          m[k] = xs
        }
        print(m[0].len() + m[3].len())
        var s: {str: [int]} = {}
        for i in 0..2000 { add(&s, "k{i % 3}", i) }
        print(s["k0"].len() + s["k1"].len() + s["k2"].len())
        var chans: [[int]] = [[], []]
        for i in 0..2000 { add_at(&chans, i % 2, i) }
        print(chans[0].len() + chans[1].len())
        var q: {int: [int]} = {}
        var a = q.get(5) else [7]
        a.push(8)
        q[5] = a
        print(q)
      }
      """, true)
  t.eq(out, "1000\n2000\n2000\n" + r"{5: [7, 8]}" + "\n", "")
  t.eq("{copies}", "0", "copy-on-write copies")
}

/// A read of the container in between, or another `var` parameter that may be the same
/// variable: the element is copied as before, and the results are the same.
fn take_and_put_back_falls_back_when_unsafe() uses env, fs, ffi, time {
  let (out, copies) = run_counted("unsafe", r"""
      fn two(a: var {int: [int]}, b: var {int: [int]}) {
        var xs = a.get(0) else []
        let bl = b.get(0) else [-1]
        xs.push(bl.len())
        a[0] = xs
      }
      fn main() {
        var r: {int: [int]} = {1: [1]}
        var b = r.get(1) else []
        b.push(r[1].len())
        r[1] = b
        print(r)
        var al: {int: [int]} = {0: [1, 2]}
        two(&al, &al)
        print(al)
      }
      """, true)
  t.eq(out, r"{1: [1, 1]}" + "\n" + r"{0: [1, 2, 2]}" + "\n", "")
  t.eq("{copies}", "2", "copy-on-write copies")
}

/// A panic between the take and the put, caught by the caller: its variable holds a valid value
/// (unspecified: here the empty list the take left), which it can go on changing. (A `catch` on
/// the main thread leaks what the aborted code owned, so no leak check.)
fn a_caught_panic_leaves_a_var_parameter_valid() uses env, fs, ffi, time {
  let (out, _) = run_counted("panic", r"""
      fn boom(m: var {int: [int]}, k: int) {
        var xs = m.get(k) else []
        xs.push(99)
        if xs.len() > 1 {
          let z: [int] = []
          print(z[3])
        }
        m[k] = xs
      }
      fn main() {
        var p: {int: [int]} = {0: [1]}
        let res = catch boom(&p, 0)
        print(res is err(_))
        p[0].push(5)
        print(p[0].len() <= 3)
      }
      """, false)
  t.eq(out, "true\ntrue\n", "")
}

/// module doc
/// two lines

/// item doc
fn f() {
  let a = 1_000 + 0xff + 0b1010 + 1e-9 + 3.25 + 2.5E+3 + 0xD800 + 18446744073709551615
  let b = 0..3
  let c = 1.max()
  let d = t.0.1 + x?.0
  let e = 3.0<m/s^2> + 1<<4 + 3<x && y > 2 + float<kg*m/s^2> + int <px>
  let f = "a\tb\n\"q\" \\ \0 \u{41} \u{1F986} {{x}} }}"
  let g = r"a\n{b}" + r"""{"name":"ann"}"""
  let h = """
    x = {x:>5}
      y {if a { "x" } else { "y" }}
    """
  let i = "a{"b{c:>3}d":<9}e" + "{f({"k": 1})}"
  let j = 'a' + '\n' + '\u{1F986}' + '\'' + '{' + 'é'
  let café = naïve + ü
  //// not a doc
  /* nested /* comment */ here */
  x |> f()
    |> g()
  a &= b |= c ^= d <<= e >>= f && g || h |> i
  +% -% *% ** .. ..= => |> ?. ? ?? :: & ! != += -= *= /= %= && || -> < <= > >=
}
/// trailing doc

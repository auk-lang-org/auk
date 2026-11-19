raw struct Header { rc: i64, kind: u32, flags: u32 }
raw union U { i: i64, f: float }

fn wrap(): int {
  let a: u8 = 250
  let b = a + 10
  var c: i32 = 2147483647
  c += 1
  let d: u32 = 7
  let e = d / 2 + d % 2
  let f: i16 = -5
  let g = f >> 1
  let h: u64 = 1
  let big = h << 63
  let fl: f32 = 1.5
  let fx = fl * 2.0
  print("{int(b)} {int(c)} {int(e)} {int(g)} {int(big >> 60)} {float(fx)} {int(u8(300))} {bool(d)} {int(i8(int(200)))}")
  let hd = Header { rc: 1, kind: 2, flags: 3 }
  print("{int(hd.rc) + int(hd.kind) + int(hd.flags)}")
  if d == 7 && a > 200 { print("cmp ok") }
  // a literal on the left takes the right side's type, as on the right
  let l1 = 1 + d
  let l2 = 255 - a
  let l3 = 1 << d
  let l4 = -1 * f
  let l5 = 0.5 * fl
  if 7 == d && 200 < a && 251 > a && l1 == 8 && l2 == 5 && l3 == 128 && l4 == 5 && l5 == 0.75 { print("left ok") }
  0
}

fn main() {
  let _ = wrap()
}

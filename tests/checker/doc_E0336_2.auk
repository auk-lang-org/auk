async fn filled(xs: [int]): [int] = xs + [1]

fn main() {
  let t = filled([])
  let xs = await t
  print(xs)
}

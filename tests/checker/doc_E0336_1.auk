async fn fill(xs: var [int]) { xs.push(1) }

fn main() {
  var xs: [int] = []
  let t = fill(&xs)
  await t
}

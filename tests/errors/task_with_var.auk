// error: E0336 takes `xs` by `var`, so it can't run as a task
async fn fill(xs: var [int]) {
  xs.push(1)
}

fn main() {
  var xs: [int] = []
  let t = fill(&xs)
  await t
}

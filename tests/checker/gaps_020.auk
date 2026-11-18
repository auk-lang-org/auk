fn down(n: int): int = if n == 0 { 0 } else { 1 + down(n - 1) }

fn forever(n: int): int = 1 + forever(n + 1)

async fn forever_task(): int = forever(0)

fn main(args: [str]) {
  print("deep: {down(200000)}")
  if args.len() > 1 {
    let r = catch forever(0)
    print("caught: {r}")
    let r2 = catch forever(0)
    print("again: {r2}")
    let t = forever_task()
    let r3 = catch await t
    print("task: {r3}")
  } else {
    print(forever(0))
  }
}

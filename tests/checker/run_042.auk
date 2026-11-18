async fn slow(ms: int, v: int): int uses time {
  time.sleep(ms)
  v
}
async fn crash(ms: int): int uses time {
  time.sleep(ms)
  let xs = [1]
  xs[ms]
}
async fn spin(): int {
  var n = 0
  while true {
    n += 1
  }
  n
}
async fn stubborn(): int uses time {
  loop {
    let r = catch time.sleep(10_000)
    print("held {r}")
  }
}
async fn parent(): int uses time {
  let k = slow(10_000, 1)
  time.sleep(10_000)
  await k
}
fn main() uses time {
  let t0 = time.now()
  var ts = [slow(2_000, 1), slow(10, 2), crash(100)]
  let (i, r) = await any ts
  print("{i} {r}")
  ts[i] = slow(5_000, 9)
  let (j, s) = await any ts
  print("{j} {s is err(_)}")
  let sp = spin()
  time.sleep(20)
  sp.cancel()
  print(catch await sp)
  let st = stubborn()
  time.sleep(20)
  st.cancel()
  print(catch await st)
  let p = parent()
  time.sleep(20)
  p.cancel()
  print(catch await p)
  for t in ts {
    t.cancel()
  }
  print(time.now() - t0 < 3_000)
}

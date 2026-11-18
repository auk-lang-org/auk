struct Job { id: int, tags: [str] }

async fn worker(jobs: Chan<Job>, out: Chan<str>): int {
  var n = 0
  for j in jobs {
    out.send("job {j.id} {j.tags}")
    n += 1
  }
  n
}

async fn crasher(jobs: Chan<Job>): int {
  var seen: [str] = []
  for j in jobs {
    seen.push("got {j.id}")
    let _ = j.tags[10]
  }
  0
}

async fn waiter(jobs: Chan<Job>): int {
  for j in jobs {
    print("never {j.id}")
  }
  0
}

async fn grow(xs: [str]): [str] {
  var ys = xs
  ys.push("more")
  ys
}

fn main() uses time {
  let jobs: Chan<Job> = chan()
  let out: Chan<str> = chan()
  let w = worker(jobs, out)
  for i in 0..3 {
    jobs.send(Job { id: i, tags: ["t{i}"] })
  }
  jobs.close()
  print(await w)
  out.close()
  for s in out {
    print(s)
  }
  let base = ["a"]
  let g = grow(base)
  print("{await g} {base}")
  let cj: Chan<Job> = chan()
  var ts = [crasher(cj)]
  cj.send(Job { id: 7, tags: ["x"] })
  let (_, r) = await any ts
  print(r is err(_))
  let wj: Chan<Job> = chan()
  var ws = [waiter(wj)]
  time.sleep(20)
  ws[0].cancel()
  let (_, c) = await any ws
  print(c)
}

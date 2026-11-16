/// Check a list of URLs concurrently and report status + latency.

struct Check { url: str, status: int, ms: int }

async fn check(url: str): Check! uses net, time {
  let start = time.now()
  let r = await http.get(url)?
  Check { url, status: r.status, ms: time.now() - start }
}

fn main(args: [str]): int! uses net, time {
  let results = await args.skip(1).map(u => check(u))
  var failed = 0
  for r in results {
    match r {
      ok(c) when c.status < 400 => print("✓ {c.status} {c.ms:>5}ms {c.url}")
      ok(c) => {
        print("✗ {c.status} {c.url}")
        failed += 1
      }
      err(e) => {
        print("✗ ERR {e}")
        failed += 1
      }
    }
  }
  if failed > 0 { 1 } else { 0 }
}

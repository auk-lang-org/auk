import subprocess, time, resource, sys, os
SIZES = dict(fib=38, sieve=50_000_000, nbody=5_000_000, hashmap=5_000_000, trees=18, strings=5_000_000, sort=10_000_000)
RUNS = int(os.environ.get("RUNS", 5))
here = os.path.dirname(os.path.abspath(__file__))
def run(exe, arg):
    best, rss = 1e9, 0
    for _ in range(RUNS):
        t = time.perf_counter()
        p = subprocess.run([exe, str(arg)], capture_output=True, text=True)
        best = min(best, time.perf_counter() - t)
        if p.returncode: return None, 0, p.stderr.strip()[-200:]
    r = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss  # bytes on macOS; max so far
    return best, r, p.stdout.strip()
print(f"| bench | size | rust -O | rust +overflow | auk | auk/rust | auk/rust+oc | output match |")
print("|---|---|---|---|---|---|---|---|")
for b in (sys.argv[1:] or SIZES):
    n = SIZES[b]
    r, _, ro = run(f"{here}/out/{b}.rs", n)
    oc, _, _ = run(f"{here}/out/{b}.rsoc", n)
    d, _, do = run(f"{here}/out/{b}.auk", n)
    if d is None: print(f"| {b} | {n} | {r:.3f}s | {oc:.3f}s | FAILED: {do} | | | |"); continue
    print(f"| {b} | {n:,} | {r:.3f}s | {oc:.3f}s | {d:.3f}s | **{d/r:.2f}x** | {d/oc:.2f}x | {'yes' if do==ro else 'NO'} |", flush=True)

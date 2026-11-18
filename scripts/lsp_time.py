#!/usr/bin/env python3
"""Time the language servers of two auk binaries on the same sessions (scripts/diff_lsp.py's):
per file, the whole session (open = load + check, symbols, formatting, code actions, hover and
definition every `step` columns, close); best of `runs`, alternating.

usage: lsp_time.py <auk> <port> [--runs N] [--step N] <file>...
"""
import subprocess, sys, time, importlib.util, os

spec = importlib.util.spec_from_file_location("diff_lsp_mod", os.path.join(os.path.dirname(__file__), "diff_lsp.py"))
src = open(spec.origin).read().replace("\nmain()\n", "\n")
mod = {}
exec(compile(src, spec.origin, "exec"), mod)


def timed(binary, data):
    t = time.perf_counter()
    subprocess.run([binary, "lsp"], input=data, capture_output=True, timeout=600)
    return time.perf_counter() - t


args = sys.argv[1:]
opts = {"--runs": 5, "--step": 4}
for k in list(opts):
    if k in args:
        i = args.index(k)
        opts[k] = int(args[i + 1])
        del args[i : i + 2]
a, b, files = args[0], args[1], args[2:]
print(f"{'file':40} {'requests':>8} {'rust':>9} {'port':>9} {'port/rust':>9}")
ta = tb = 0
for f in files:
    data = mod["session"]([f], opts["--step"])
    n = data.count(b"Content-Length")
    best_a = best_b = 1e9
    for _ in range(opts["--runs"]):
        best_a = min(best_a, timed(a, data))
        best_b = min(best_b, timed(b, data))
    ta += best_a
    tb += best_b
    print(f"{f[-40:]:40} {n:8} {best_a * 1000:8.0f}ms {best_b * 1000:8.0f}ms {best_b / best_a:8.2f}x")
print(f"{'all':40} {'':8} {ta * 1000:8.0f}ms {tb * 1000:8.0f}ms {tb / ta:8.2f}x")

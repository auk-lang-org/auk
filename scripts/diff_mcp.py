#!/usr/bin/env python3
"""Diff the MCP servers of two auk binaries (the Rust `auk mcp` and the port's `compiler mcp`):
one session of protocol messages, errors and tool calls, replies compared by id. Each server's
tools run its own binary, so this covers the commands behind them too.

auk_debug sessions use compiler/tests/debug/ (breakpoints, conditions, expressions, tasks, a
compile error); auk_holes is left out (it finds `holes` in `help`'s usage).

usage: diff_mcp.py <auk> <port>   (run from the repository root)
"""
import json, subprocess, sys

CALLS = [
    ("auk_explain", {"code": "E0200"}),
    ("auk_explain", {}),
    ("auk_explain", {"code": "E9999"}),
    ("auk_explain", {"code": 7}),
    ("auk_spec", {}),
    ("auk_check", {"source": "fn label(n: int): str = n\n"}),
    ("auk_check", {"source": "fn main() {\n  let x = 1;\n}\n"}),
    ("auk_check", {"path": "examples/calc.auk"}),
    ("auk_check", {"path": "tests/checker/eff_chains.auk"}),
    ("auk_check", {"path": "compiler"}),
    ("auk_check", {"path": "examples/hello.auk", "source": "x"}),
    ("auk_check", {}),
    ("auk_check", {"path": "examples/no_such_file.auk"}),
    ("auk_fmt", {"source": "fn main( {"}),
    ("auk_fmt", {"source": "fn main(){print( 1+2 )}"}),
    ("auk_run", {"path": "examples/hello.auk", "timeout_seconds": -1}),
    ("auk_run", {"path": "examples/hello.auk", "args": [1]}),
    ("auk_debug", {"path": "examples/hello.auk", "max_stops": 0}),
    ("auk_debug", {"path": "compiler/tests/debug/eval.auk", "breakpoints": ["compiler/tests/debug/eval.auk:16 if i % 2 == 1", "fact if n == 2"], "print": ["total", "pts[1].x", "dist2(pts[0])", "n * 10"], "max_stops": 4}),
    ("auk_debug", {"path": "compiler/tests/debug/tasks.auk", "catch": "all", "breakpoints": ["work"]}),
    ("auk_debug", {"path": "compiler/tests/debug/args.auk", "breakpoints": ["greet"], "args": ["a", "b"]}),
    ("auk_debug", {"path": "compiler/tests/debug/bad.auk"}),
    ("auk_test", {"path": "examples/no_such_file.auk"}),
    ("auk_nope", {}),
]


def session():
    msgs = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-03-26"}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {"jsonrpc": "2.0", "id": 3, "method": "ping"},
        {"jsonrpc": "2.0", "id": 4, "method": "initialize", "params": {"protocolVersion": "1999-01-01"}},
        {"jsonrpc": "2.0", "id": 5, "method": "server/discover"},
        {"jsonrpc": "2.0", "id": 6, "result": {}},
        {"jsonrpc": "2.0", "id": 7},
        {"jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": {"name": "auk_check", "arguments": [1]}},
        {"jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": {}},
    ]
    for i, (name, args) in enumerate(CALLS):
        msgs.append({"jsonrpc": "2.0", "id": 100 + i, "method": "tools/call", "params": {"name": name, "arguments": args}})
    lines = [json.dumps(m) for m in msgs] + ["[1,2]", "{bad", "", "\"str\""]
    return ("\n".join(lines) + "\n").encode()


def run(binary, data):
    p = subprocess.run([binary, "mcp"], input=data, capture_output=True, timeout=600)
    by = {}
    for line in p.stdout.decode().splitlines():
        try:
            k = json.dumps(json.loads(line).get("id"))
        except Exception:
            k = "not json"
        by.setdefault(k, []).append(line)
    return by, p.returncode, p.stderr.decode()


def main():
    a, b = sys.argv[1], sys.argv[2]
    data = session()
    ra, rb = run(a, data), run(b, data)
    bad = 0
    if ra[1:] != rb[1:]:
        bad += 1
        print(f"DIFF exit/stderr: {ra[1:]} vs {rb[1:]}")
    keys = sorted(set(ra[0]) | set(rb[0]))
    for k in keys:
        x, y = ra[0].get(k), rb[0].get(k)
        if sorted(x or []) != sorted(y or []):
            bad += 1
            print(f"DIFF id {k}\n  rust: {str(x)[:500]}\n  port: {str(y)[:500]}")
    print(f"mcp: {len(keys)} replies, {bad} differ")
    sys.exit(1 if bad else 0)


main()

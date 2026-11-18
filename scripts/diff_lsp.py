#!/usr/bin/env python3
"""Diff the language servers of two auk binaries (the Rust `auk lsp` and the port's
`compiler lsp`): for every file given, open it, ask for its symbols, formatting, code actions,
and the hover and definition at every `step`-th column of every line, then close it; compare the
two servers' whole output streams message by message.

usage: diff_lsp.py <auk> <port> [--step N] <file>...
"""
import json, subprocess, sys, threading, os


def frame(msg):
    body = json.dumps(msg, ensure_ascii=False, separators=(",", ":")).encode()
    return b"Content-Length: %d\r\n\r\n" % len(body) + body


def read_frames(data):
    out, i = [], 0
    while i < len(data):
        j = data.index(b"\r\n\r\n", i)
        n = int(data[i:j].split(b":")[1])
        out.append(data[j + 4 : j + 4 + n].decode())
        i = j + 4 + n
    return out


def uri(path):
    ok = set(b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")
    return "file://" + "".join(chr(b) if b in ok else "%%%02X" % b for b in path.encode())


def session(files, step):
    msgs = [{"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"capabilities": {}}}]
    n = 1
    for f in files:
        text = open(f, encoding="utf-8").read()
        u = uri(os.path.realpath(f))
        doc = {"uri": u}
        msgs.append({"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {"textDocument": {"uri": u, "languageId": "auk", "version": 1, "text": text}}})
        for m in ["textDocument/documentSymbol", "textDocument/formatting"]:
            msgs.append({"jsonrpc": "2.0", "id": n, "method": m, "params": {"textDocument": doc}})
            n += 1
        lines = text.split("\n")
        whole = {"start": {"line": 0, "character": 0}, "end": {"line": len(lines), "character": 0}}
        msgs.append({"jsonrpc": "2.0", "id": n, "method": "textDocument/codeAction", "params": {"textDocument": doc, "range": whole, "context": {}}})
        n += 1
        for li, line in enumerate(lines):
            for ch in range(0, len(line) + 1, step):
                for m in ["textDocument/hover", "textDocument/definition"]:
                    pos = {"line": li, "character": ch}
                    msgs.append({"jsonrpc": "2.0", "id": n, "method": m, "params": {"textDocument": doc, "position": pos}})
                    n += 1
        msgs.append({"jsonrpc": "2.0", "method": "textDocument/didClose", "params": {"textDocument": doc}})
    msgs.append({"jsonrpc": "2.0", "id": n, "method": "shutdown"})
    msgs.append({"jsonrpc": "2.0", "method": "exit"})
    return b"".join(frame(m) for m in msgs)


def run(binary, data):
    p = subprocess.Popen([binary, "lsp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out, err = p.communicate(data, timeout=600)
    return read_frames(out), err.decode(errors="replace"), p.returncode


def main():
    args = sys.argv[1:]
    step = 3
    if "--step" in args:
        i = args.index("--step")
        step = int(args[i + 1])
        del args[i : i + 2]
    a, b, files = args[0], args[1], args[2:]
    bad = 0
    total = 0
    for f in files:
        data = session([f], step)
        ra, rb = run(a, data), run(b, data)
        total += len(ra[0])
        if ra != rb:
            bad += 1
            print(f"DIFF {f} (exit {ra[2]} vs {rb[2]})")
            for x, y in zip(ra[0], rb[0]):
                if x != y:
                    print("  rust:", x[:400])
                    print("  port:", y[:400])
                    break
            if len(ra[0]) != len(rb[0]):
                print(f"  {len(ra[0])} vs {len(rb[0])} messages")
            if ra[1] != rb[1]:
                print("  stderr:", ra[1][:200], "|", rb[1][:200])
    print(f"lsp: {len(files)} files, {total} messages, {bad} differ")
    sys.exit(1 if bad else 0)


main()

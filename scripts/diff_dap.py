#!/usr/bin/env python3
"""Diff the Debug Adapter Protocol servers of two auk binaries (the Rust `auk dap` and the
port's `compiler dap`, compiler/src/dap.auk): the same scripted sessions with each, every
message they send compared in order (responses and events).

A session is a list of steps: send a request and wait for its response, or wait for an event.
Requests that need a handle (a frame id, a variables reference) take it from an earlier reply.
Normalized, because it is inherently nondeterministic: the program's stdout and stderr reach the
server on pipes of their own, so where their `output` events fall among the engine's events is
up to the scheduler (and with it every `seq` after them). They are compared as one text per
stream, the other messages in order without `seq`, and `seq` is checked to count 1, 2, ...
Paths are not normalized: both servers debug the same files. `--repeat N` runs every session N
times per binary (flakiness).

usage: diff_dap.py <auk> <port> [--repeat N]   (run from the repository root)
"""
import json, os, subprocess, sys, threading, queue

DIR = os.path.abspath("compiler/tests/debug")


def path(name):
    return os.path.join(DIR, name)


class Client:
    def __init__(self, binary):
        self.p = subprocess.Popen([binary, "dap"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.q = queue.Queue()
        self.log = []
        self.seq = 0
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        out = self.p.stdout
        while True:
            n = None
            while True:
                line = out.readline()
                if not line:
                    self.q.put(None)
                    return
                line = line.strip()
                if not line:
                    break
                if line.startswith(b"Content-Length:"):
                    n = int(line.split(b":")[1])
            body = out.read(n)
            self.q.put(json.loads(body))

    def next(self):
        m = self.q.get(timeout=60)
        if m is None:
            raise EOFError("the server closed its output")
        self.log.append(m)
        return m

    def req(self, cmd, args=None):
        self.seq += 1
        m = {"seq": self.seq, "type": "request", "command": cmd}
        if args is not None:
            m["arguments"] = args
        b = json.dumps(m).encode()
        self.p.stdin.write(b"Content-Length: %d\r\n\r\n" % len(b) + b)
        self.p.stdin.flush()
        while True:
            r = self.next()
            if r.get("type") == "response" and r.get("request_seq") == self.seq:
                return r

    def wait(self, event):
        for m in self.log:
            if m.get("type") == "event" and m.get("event") == event and not m.get("_seen"):
                m["_seen"] = True
                return m
        while True:
            m = self.next()
            if m.get("type") == "event" and m.get("event") == event:
                m["_seen"] = True
                return m

    def close(self):
        try:
            self.p.stdin.close()
        except Exception:
            pass
        try:
            code = self.p.wait(timeout=30)
        except subprocess.TimeoutExpired:
            self.p.kill()
            code = "killed"
        # what is left (sent after the last awaited message)
        while True:
            try:
                m = self.q.get(timeout=0.5)
            except queue.Empty:
                break
            if m is None:
                break
            self.log.append(m)
        return code


def body(r, *keys):
    x = r.get("body", {})
    for k in keys:
        x = x[k]
    return x


def top(c, thread=1):
    st = c.req("stackTrace", {"threadId": thread})
    fid = body(st, "stackFrames")[0]["id"]
    sc = c.req("scopes", {"frameId": fid})
    return fid, body(sc, "scopes")[0]["variablesReference"]


def expand(c, ref, depth):
    """variables of ref, and of every part to depth."""
    v = c.req("variables", {"variablesReference": ref})
    if depth > 0:
        for x in body(v, "variables")[:6]:
            if x.get("variablesReference", 0) > 0:
                expand(c, x["variablesReference"], depth - 1)


def scene(c):
    p = path("scene.auk")
    c.req("initialize", {"adapterID": "auk"})
    c.req("launch", {"program": p, "stopOnEntry": True})
    c.wait("initialized")
    c.req("setBreakpoints", {"source": {"path": p}, "breakpoints": [{"line": 7}, {"line": 99}, {"line": 6, "condition": "  "}]})
    c.req("setExceptionBreakpoints", {"filters": ["uncaught"]})
    c.req("configurationDone")
    c.wait("stopped")
    c.req("threads")
    fid, ref = top(c)
    c.req("variables", {"variablesReference": ref})
    c.req("continue", {"threadId": 1})
    c.wait("stopped")
    c.req("threads")
    fid, ref = top(c)
    expand(c, ref, 4)
    for e in ["s.shapes[1].0.x", "s.nope", "s.tags[\"a\"]", "s.tags.\"b\"", "s.best.some.y", "big.3", "s.pair.1", "", "zz", "s.name.len()", "big.len()"]:
        c.req("evaluate", {"expression": e, "frameId": fid, "context": "hover"})
    c.req("stackTrace", {"threadId": 1, "startFrame": 1, "levels": 5})
    c.req("scopes", {"frameId": 99})
    c.req("variables", {"variablesReference": 99})
    c.req("next", {"threadId": 1})
    c.wait("stopped")
    c.req("evaluate", {"expression": "big", "frameId": top(c)[0]})
    c.req("setBreakpoints", {"source": {"path": p}, "breakpoints": []})
    c.req("nope")
    c.req("continue", {"threadId": 1})
    c.wait("output")
    c.wait("exited")
    c.wait("terminated")
    c.req("evaluate", {"expression": "s"})
    c.req("disconnect")


def evals(c):
    p = path("eval.auk")
    c.req("initialize")
    c.req("launch", {"program": p})
    c.wait("initialized")
    c.req("setBreakpoints", {"source": {"path": p}, "breakpoints": [{"line": 16, "condition": "i == 4"}]})
    c.req("setFunctionBreakpoints", {"breakpoints": [{"name": "nope"}]})
    c.req("configurationDone")
    c.wait("stopped")
    fid, ref = top(c)
    c.req("variables", {"variablesReference": ref})
    for e in ["pts.map(p => dist2(p))", "pts[1]", "nope", "i * 10 + total", "pts[7]", "1 +", "fact(4)", "total = total + 1", "total"]:
        c.req("evaluate", {"expression": e, "frameId": fid, "context": "watch"})
    fid, ref = top(c)
    c.req("setVariable", {"variablesReference": ref, "name": "total", "value": "50"})
    c.req("setVariable", {"variablesReference": ref, "name": "pts", "value": "1"})
    c.req("setVariable", {"variablesReference": 999, "name": "total", "value": "1"})
    c.req("setBreakpoints", {"source": {"path": p}, "breakpoints": []})
    c.req("setFunctionBreakpoints", {"breakpoints": [{"name": "fact", "condition": "n == 2"}, {"name": "dist2"}]})
    c.req("continue", {"threadId": 1})
    c.wait("stopped")
    fid, ref = top(c)
    c.req("variables", {"variablesReference": ref})
    c.req("stackTrace", {"threadId": 1})
    c.req("evaluate", {"expression": "n + 1", "frameId": fid})
    c.req("setFunctionBreakpoints", {"breakpoints": [{"name": "fact", "condition": "n <"}]})
    c.req("continue", {"threadId": 1})
    c.wait("stopped")
    c.wait("output")
    top(c)
    c.req("next", {"threadId": 1})
    c.wait("stopped")
    top(c)
    c.req("setFunctionBreakpoints", {"breakpoints": []})
    c.req("continue", {"threadId": 1})
    c.wait("exited")
    c.wait("terminated")
    c.req("disconnect")


def panics(c):
    c.req("initialize")
    c.req("launch", {"program": path("index.auk")})
    c.wait("initialized")
    c.req("setExceptionBreakpoints", {"filters": ["uncaught"]})
    c.req("configurationDone")
    c.wait("stopped")
    fid, ref = top(c)
    c.req("variables", {"variablesReference": ref})
    c.req("terminate")
    c.wait("terminated")
    c.req("disconnect")


def caught(c):
    c.req("initialize")
    c.req("launch", {"program": path("tasks.auk")})
    c.wait("initialized")
    c.req("setExceptionBreakpoints", {"filters": ["all", "uncaught"]})
    c.req("setBreakpoints", {"source": {"path": path("tasks.auk")}, "breakpoints": [{"line": 4}]})
    c.req("configurationDone")
    c.wait("stopped")
    top(c)
    c.req("continue", {"threadId": 1})
    st = c.wait("stopped")
    c.req("threads")
    t = st["body"]["threadId"]
    fid, ref = top(c, t)
    c.req("variables", {"variablesReference": ref})
    c.req("evaluate", {"expression": "s + k", "frameId": fid})
    c.req("setBreakpoints", {"source": {"path": path("tasks.auk")}, "breakpoints": []})
    c.req("continue", {"threadId": t})
    c.wait("exited")
    c.wait("terminated")
    c.req("disconnect")


def compile_error(c):
    c.req("initialize")
    c.req("launch", {"program": path("bad.auk")})
    c.wait("output")
    c.wait("terminated")
    c.req("threads")
    c.req("disconnect")


def protocol(c):
    c.req("threads")
    c.req("initialize")
    c.req("launch", {})
    c.req("launch", {"program": "args.auk", "cwd": "/no/such/dir"})
    c.req("launch", {"program": "args.auk", "cwd": DIR, "args": ["x", 7, "y"]})
    c.wait("initialized")
    c.req("configurationDone")
    c.wait("exited")
    c.wait("terminated")
    c.req("evaluate", {"expression": "1"})
    c.req("threads")
    c.req("pause")
    c.req("terminate")
    c.req("disconnect")


def entry_and_end(c):
    c.req("initialize")
    c.req("launch", {"program": path("generic.auk"), "stopOnEntry": True})
    c.wait("initialized")
    c.req("configurationDone")
    c.wait("stopped")
    top(c)
    for step in ["next", "next", "stepIn", "next", "stepOut", "stepIn", "stepOut"]:
        c.req(step, {"threadId": 1})
        c.wait("stopped")
        fid, ref = top(c)
        c.req("variables", {"variablesReference": ref})
    c.req("evaluate", {"expression": "who.len() + k", "frameId": fid})
    c.req("evaluate", {"expression": "y", "frameId": fid})
    c.req("pause")
    c.req("disconnect")


def eof_after_launch(c):
    c.req("initialize")
    c.req("launch", {"program": path("sleepy.auk")})
    c.wait("initialized")
    c.req("configurationDone")
    c.wait("output")


SESSIONS = [scene, evals, panics, caught, compile_error, protocol, entry_and_end, eof_after_launch]


def run(binary, session):
    c = Client(binary)
    err = None
    try:
        session(c)
    except Exception as e:
        err = repr(e)
    code = c.close()
    msgs, out = [], {}
    for m in c.log:
        m = {k: v for k, v in m.items() if k != "_seen"}
        b = m.get("body") or {}
        if m.get("event") == "output" and b.get("category") in ("stdout", "stderr"):
            out[b["category"]] = out.get(b["category"], "") + b.get("output", "")
            continue
        msgs.append(json.dumps({k: v for k, v in m.items() if k != "seq"}))
    seqs = [m.get("seq") for m in c.log]
    msgs.append(json.dumps({"output": out, "seq_ok": seqs == list(range(1, len(seqs) + 1))}))
    return msgs, code, err


def main():
    a, b = sys.argv[1], sys.argv[2]
    repeat = int(sys.argv[sys.argv.index("--repeat") + 1]) if "--repeat" in sys.argv else 1
    bad = 0
    total = 0
    for s in SESSIONS:
        for _ in range(repeat):
            ra, rb = run(a, s), run(b, s)
            total += len(ra[0])
            if ra != rb:
                bad += 1
                print(f"DIFF session {s.__name__}: exit {ra[1]}/{rb[1]}, error {ra[2]}/{rb[2]}")
                for i in range(max(len(ra[0]), len(rb[0]))):
                    x = ra[0][i] if i < len(ra[0]) else None
                    y = rb[0][i] if i < len(rb[0]) else None
                    if x != y:
                        print(f"  message {i}\n    rust: {str(x)[:400]}\n    port: {str(y)[:400]}")
                        break
            elif ra[2]:
                print(f"note: session {s.__name__} stopped early with both: {ra[2]}")
    print(f"dap: {len(SESSIONS)} sessions x {repeat}, {total} messages, {bad} differ")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()

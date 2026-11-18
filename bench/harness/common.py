"""Shared helpers for the Auk accuracy benchmark (run everything with `python3 -I`)."""
import os
import subprocess
import sys

BENCH = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TASKS = os.path.join(BENCH, "tasks")
AUK = os.environ.get("BENCH_AUK", os.path.join(BENCH, "bin", "auk"))

PY_RUNNER = '''

if __name__ == "__main__":
    import sys as _sys, traceback as _tb
    _failed = 0
    _names = [n for n in list(globals()) if n.startswith("test_") and callable(globals()[n])]
    for _n in _names:
        try:
            globals()[_n]()
            print("ok " + _n)
        except BaseException:
            _failed += 1
            print("FAIL " + _n)
            print("    " + _tb.format_exc().replace("\\n", "\\n    "))
    print("%d passed, %d failed" % (len(_names) - _failed, _failed))
    _sys.exit(1 if _failed or not _names else 0)
'''


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read()
    except FileNotFoundError:
        return default


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def task_ids():
    return sorted(d for d in os.listdir(TASKS) if os.path.isdir(os.path.join(TASKS, d)))


def task(tid):
    d = os.path.join(TASKS, tid)
    t = {"id": tid, "desc": read(os.path.join(d, "desc.md")).strip()}
    for ext, lang in (("auk", "auk"), ("py", "py")):
        for part in ("given", "stub", "ref", "visible", "tests"):
            t[f"{lang}_{part}"] = read(os.path.join(d, f"{part}.{ext}")).strip("\n")
    return t


def join(*parts):
    return "\n\n".join(p.strip("\n") for p in parts if p.strip()) + "\n"


def auk_program(t, solution):
    """given + solution + visible tests + hidden tests (the scored file)."""
    return join(t["auk_given"], solution, t["auk_visible"], t["auk_tests"])


def auk_hatch_file(t):
    """The task description (as comments) + given + stub (with ?? holes) + visible tests: what
    `auk hatch` sees. Hatch's prompt includes the whole file, so the description reaches the model."""
    desc = "\n".join(("// " + l).rstrip() for l in ("Task:\n\n" + t["desc"]).splitlines())
    return join(desc, t["auk_given"], t["auk_stub"], t["auk_visible"])


def py_program(t, solution):
    return join(t["py_given"], solution, t["py_visible"], t["py_tests"]) + PY_RUNNER


def run(cmd, cwd=None, timeout=120, stdin=None, env=None):
    """Run a command; returns (exit code, combined output). Timeout gives code 124."""
    try:
        p = subprocess.run(cmd, cwd=cwd, input=stdin, capture_output=True, text=True, timeout=timeout, env=env)
        return p.returncode, p.stdout + p.stderr
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"")
        out = out.decode() if isinstance(out, bytes) else out
        return 124, out + f"\n[timeout after {timeout}s]"


def auk_check(path):
    return run([AUK, "check", path], timeout=60)


def auk_test(path):
    return run([AUK, "test", path], timeout=180)


def py_syntax(path):
    return run([sys.executable, "-I", "-c", "import ast,sys; ast.parse(open(sys.argv[1]).read())", path], timeout=30)


def py_test(path):
    return run([sys.executable, "-I", path], timeout=120)


# ---------------------------------------------------------------- the model

import json
import tempfile
import time

MODEL = os.environ.get("BENCH_MODEL", "claude-opus-5-5")
CALL_TIMEOUT = int(os.environ.get("BENCH_CALL_TIMEOUT", "300"))


def model_argv(model=None):
    # no tools (the model must answer from the prompt alone), no user/project settings or
    # CLAUDE.md files (they could mention Auk), no saved session
    return ["claude", "-p", "--model", model or MODEL, "--output-format", "json", "--tools", "",
            "--setting-sources", "", "--no-session-persistence"]


def call_model(prompt, log_prefix, model=None, timeout=None):
    """Send `prompt` to `claude -p` (in an empty temp dir). Logs <prefix>.prompt.txt,
    <prefix>.reply.txt and <prefix>.meta.json. Returns (reply text or None, meta dict)."""
    timeout = timeout or CALL_TIMEOUT
    write(log_prefix + ".prompt.txt", prompt)
    cwd = tempfile.mkdtemp(prefix="auk-bench-cwd-")
    t0 = time.time()
    meta = {"model": model or MODEL, "timeout_s": timeout}
    text = None
    try:
        p = subprocess.run(model_argv(model), input=prompt, capture_output=True, text=True, timeout=timeout, cwd=cwd)
        meta["exit"] = p.returncode
        try:
            j = json.loads(p.stdout)
            text = j.get("result")
            meta["is_error"] = j.get("is_error")
            meta["usage"] = j.get("usage")
            meta["model_usage"] = j.get("modelUsage")
            meta["cost_usd"] = j.get("total_cost_usd")
            meta["stop_reason"] = j.get("stop_reason")
        except ValueError:
            meta["raw_stdout"] = p.stdout[-4000:]
        if p.returncode != 0:
            meta["stderr"] = p.stderr[-4000:]
    except subprocess.TimeoutExpired:
        meta["timeout"] = True
    meta["seconds"] = round(time.time() - t0, 1)
    if text is not None:
        write(log_prefix + ".reply.txt", text)
    write(log_prefix + ".meta.json", json.dumps(meta, indent=2))
    return text, meta


def extract_code(reply, lang):
    """The first ```<lang> fence (or the first ``` fence) of a reply, or the whole reply.
    Mirrors `auk hatch`'s extract_code."""
    lines = reply.splitlines()
    def find(pred):
        return next((i for i, l in enumerate(lines) if pred(l.strip())), None)
    tags = {"auk": ("```auk",), "py": ("```python", "```py")}[lang]
    i = find(lambda l: l.startswith(tags))
    if i is None:
        i = find(lambda l: l.startswith("```"))
    if i is None:
        body = lines
    else:
        rest = lines[i + 1:]
        j = next((k for k, l in enumerate(rest) if l.strip().startswith("```")), len(rest))
        body = rest[:j]
    return "\n".join(body).strip("\n").rstrip() + "\n"


# ---------------------------------------------------------------- the prompt

LANG = {
    "auk": {
        "name": "Auk",
        "fence": "auk",
        "intro": "You are writing code in Auk, a statically typed language compiled to native code. "
                 "Its complete reference is below; use only what it describes.\n\n"
                 "# The Auk language reference\n\n{spec}\n\n",
        "hole": "`{ ?? }`",
    },
    "py": {
        "name": "Python",
        "fence": "python",
        "intro": "You are writing code in Python 3.9.\n\n",
        "hole": "`raise NotImplementedError`",
    },
}

TEMPLATE = """{intro}# Task

{desc}

# Code already in the file (do not repeat it)

```{fence}
{given}
```

# Signatures to implement

The bodies are placeholders ({hole}).

```{fence}
{stub}
```

# Tests your code must pass

```{fence}
{visible}
```

# Your answer

Write the complete {name} definitions of the function(s) above, keeping their names, parameters, return types and any contracts unchanged. You may add helper functions. Do not repeat the code already in the file or the tests. Use only the standard library.

Reply with ONLY the code, in one fenced block:
```{fence}
<your code>
```
"""


def make_prompt(t, lang, spec):
    L = LANG[lang]
    given = t[f"{lang}_given"] or ("// (nothing)" if lang == "auk" else "# (nothing)")
    return TEMPLATE.format(
        intro=L["intro"].replace("{spec}", spec.strip()), desc=t["desc"], fence=L["fence"], given=given,
        hole=L["hole"], stub=t[f"{lang}_stub"], visible=t[f"{lang}_visible"], name=L["name"])

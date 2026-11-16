"""Run the Duck accuracy benchmark.

    python3 -I bench/harness/run.py [--tasks 01_word_freq,...] [--conditions duck1,hatch,py1]
                                     [--jobs 6] [--out bench/runs/<name>] [--model claude-opus-5-5]

Conditions:
  duck1  one-shot Duck: spec + task + Duck stub + visible tests -> reply -> `duck check`, `duck test`
  hatch  `duck hatch --tries 3` on given + stub + visible tests, then the hidden tests
  py1    one-shot Python: task + Python stub + visible tests -> reply -> syntax check, tests

Scoring always uses given + solution + visible tests + hidden tests (tasks/*/tests.*).
Writes <out>/<task>/<condition>/... (prompts, replies, programs, outputs) and <out>/results.json.
Then run harness/report.py <out> to count tokens and write the tables."""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common  # noqa
from common import *  # noqa

HARNESS = os.path.dirname(os.path.abspath(__file__))


def run_duck1(t, d, spec):
    prompt = make_prompt(t, "duck", spec)
    reply, meta = call_model(prompt, f"{d}/model")
    r = {"model": meta}
    if reply is None:
        r.update(error="no reply", check_ok=False, pass_=False)
        return r
    sol = extract_code(reply, "duck")
    write(f"{d}/solution.duck", sol)
    write(f"{d}/program.duck", duck_program(t, sol))
    c, out = duck_check(f"{d}/program.duck")
    write(f"{d}/check.out", out)
    c2, out2 = duck_test(f"{d}/program.duck")
    write(f"{d}/test.out", out2)
    r.update(check_ok=c == 0, pass_=c2 == 0)
    return r


def run_py1(t, d, spec):
    prompt = make_prompt(t, "py", spec)
    reply, meta = call_model(prompt, f"{d}/model")
    r = {"model": meta}
    if reply is None:
        r.update(error="no reply", check_ok=False, pass_=False)
        return r
    sol = extract_code(reply, "py")
    write(f"{d}/solution.py", sol)
    write(f"{d}/program.py", py_program(t, sol))
    c, out = py_syntax(f"{d}/program.py")
    write(f"{d}/check.out", out)
    c2, out2 = py_test(f"{d}/program.py")
    write(f"{d}/test.out", out2)
    r.update(check_ok=c == 0, pass_=c2 == 0)
    return r


def run_hatch(t, d, spec, tries=3):
    src = f"{d}/hatch.duck"
    write(src, duck_hatch_file(t))
    shutil.copy(src, f"{d}/hatch.before.duck")
    env = dict(os.environ)
    env["DUCK_HATCH_CMD"] = f"'{sys.executable}' -I '{HARNESS}/model_cmd.py' '{d}/calls'"
    holes = len(re.findall(r"\?\?", t["duck_stub"]))
    code, out = run([DUCK, "hatch", src, "--tries", str(tries)], cwd=d, env=env,
                    timeout=holes * tries * (common.CALL_TIMEOUT + 90) + 60)
    write(f"{d}/hatch.out", out)
    filled = [int(m) for m in re.findall(r"filled after (\d+) tr", out)]
    failed = len(re.findall(r"failed after \d+ tr", out))
    calls = len([f for f in os.listdir(f"{d}/calls") if f.endswith(".prompt.txt")]) if os.path.isdir(f"{d}/calls") else 0
    r = {"hatch_exit": code, "holes": holes, "holes_filled": len(filled), "holes_failed": failed,
         "tries_per_hole": filled, "calls": calls, "visible_ok": code == 0 and len(filled) == holes}
    # score the hatched file against the hidden tests
    hatched = read(src)
    write(f"{d}/program.duck", join(hatched, t["duck_tests"]))
    c, o = duck_check(f"{d}/program.duck")
    write(f"{d}/check.out", o)
    c2, o2 = duck_test(f"{d}/program.duck")
    write(f"{d}/test.out", o2)
    r.update(check_ok=c == 0, pass_=c2 == 0 and "??" not in hatched)
    # the code hatch wrote, for token counting: the hatched file minus given/visible parts
    write(f"{d}/hatched.duck", hatched)
    return r


RUNNERS = {"duck1": run_duck1, "hatch": run_hatch, "py1": run_py1}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tasks", default="")
    ap.add_argument("--conditions", default="duck1,hatch,py1")
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--out", default="")
    ap.add_argument("--model", default=common.MODEL)
    a = ap.parse_args()
    os.environ["BENCH_MODEL"] = a.model  # model_cmd.py (hatch) inherits it
    common.MODEL = a.model
    tids = a.tasks.split(",") if a.tasks else task_ids()
    conds = a.conditions.split(",")
    out = os.path.abspath(a.out or os.path.join(BENCH, "runs", time.strftime("%Y%m%d-%H%M%S")))
    os.makedirs(out, exist_ok=True)
    spec = read(os.path.join(BENCH, "spec.md"))
    # the spec in the one-shot prompt must be the one compiled into the duck binary (hatch uses that)
    rc, bin_spec = run([DUCK, "spec"])
    if bin_spec.strip() != spec.strip():
        print("warning: bench/spec.md differs from `duck spec`; the one-shot prompt uses bench/spec.md", file=sys.stderr)
    info = {"model": a.model, "duck": DUCK, "duck_sha256": run(["shasum", "-a", "256", DUCK])[1].split()[0],
            "spec_chars": len(spec), "conditions": conds, "tasks": tids, "started": time.strftime("%Y-%m-%d %H:%M:%S")}
    jobs = [(tid, c) for tid in tids for c in conds]
    results = {}

    def one(job):
        tid, c = job
        d = os.path.join(out, tid, c)
        os.makedirs(d, exist_ok=True)
        try:
            r = RUNNERS[c](task(tid), d, spec)
        except Exception as e:  # keep going; record the harness error
            r = {"error": repr(e), "pass_": False, "check_ok": False}
        write(f"{d}/result.json", json.dumps(r, indent=2))
        print(f"{tid:22} {c:6} check={'ok' if r.get('check_ok') else 'no':3} pass={'ok' if r.get('pass_') else 'FAIL'}"
              + (f" tries={r.get('tries_per_hole')} calls={r.get('calls')}" if c == "hatch" else ""), flush=True)
        return job, r

    with ThreadPoolExecutor(a.jobs) as ex:
        for (tid, c), r in ex.map(one, jobs):
            results.setdefault(tid, {})[c] = r
    info["finished"] = time.strftime("%Y-%m-%d %H:%M:%S")
    write(os.path.join(out, "results.json"), json.dumps({"info": info, "results": results}, indent=2))
    print(f"wrote {out}/results.json; now: <tiktoken python> {HARNESS}/report.py {out}")


if __name__ == "__main__":
    main()

"""Count solution tokens (tiktoken o200k_base) and write <run>/report.md with the per-task table
and totals. Needs a Python with tiktoken:

    <venv>/bin/python -I bench/harness/report.py bench/runs/<name>

Token counts: "raw" is the extracted code block exactly as the model wrote it; "code" also drops
blank lines, whole-line comments (`//`, `#`) and Python docstrings, so commenting style doesn't
decide the comparison."""
import ast
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import read, task, write  # noqa

import tiktoken

ENC = tiktoken.get_encoding("o200k_base")


def ntok(s):
    return len(ENC.encode(s))


def strip_code(src, lang):
    lines = src.splitlines()
    drop = set()
    if lang == "py":
        try:
            tree = ast.parse(src)
            for node in ast.walk(tree):
                if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef, ast.Module)) and node.body:
                    first = node.body[0]
                    if isinstance(first, ast.Expr) and isinstance(getattr(first, "value", None), ast.Constant) \
                            and isinstance(first.value.value, str):
                        drop.update(range(first.lineno - 1, first.end_lineno))
        except SyntaxError:
            pass
    keep = []
    for i, l in enumerate(lines):
        t = l.strip()
        if i in drop or not t or t.startswith("//" if lang == "auk" else "#"):
            continue
        keep.append(l)
    return "\n".join(keep) + "\n"


def tokens(src, lang):
    return {"raw": ntok(src), "code": ntok(strip_code(src, lang))}


def main():
    out = os.path.abspath(sys.argv[1])
    data = json.loads(read(os.path.join(out, "results.json")))
    info, res = data["info"], data["results"]
    rows = []
    tot = {"auk1": 0, "auk1_check": 0, "hatch": 0, "hatch_vis": 0, "py1": 0, "py1_check": 0}
    tk = {"auk": [], "py": [], "auk_ref": [], "py_ref": []}
    out_tok = {"auk1": [], "py1": []}
    hatch_calls = []
    n = 0
    for tid in info["tasks"]:
        r = res.get(tid, {})
        t = task(tid)
        d1, h, p1 = r.get("auk1", {}), r.get("hatch", {}), r.get("py1", {})
        n += 1
        dsol = read(os.path.join(out, tid, "auk1", "solution.auk"))
        psol = read(os.path.join(out, tid, "py1", "solution.py"))
        dt = tokens(dsol, "auk") if dsol else None
        pt = tokens(psol, "py") if psol else None
        dref, pref = tokens(t["auk_ref"], "auk"), tokens(t["py_ref"], "py")
        tk["auk_ref"].append(dref["code"])
        tk["py_ref"].append(pref["code"])
        if dt and pt:
            tk["auk"].append(dt["code"])
            tk["py"].append(pt["code"])
        for c in ("auk1", "py1"):
            u = (r.get(c, {}).get("model") or {}).get("usage") or {}
            if "output_tokens" in u:
                out_tok[c].append(u["output_tokens"])
        tot["auk1"] += bool(d1.get("pass_"))
        tot["auk1_check"] += bool(d1.get("check_ok"))
        tot["hatch"] += bool(h.get("pass_"))
        tot["hatch_vis"] += bool(h.get("visible_ok"))
        tot["py1"] += bool(p1.get("pass_"))
        tot["py1_check"] += bool(p1.get("check_ok"))
        if "calls" in h:
            hatch_calls.append(h["calls"])
        yn = lambda b: "pass" if b else "FAIL"
        ht = "-"
        if h:
            ht = f"{yn(h.get('pass_'))} ({h.get('calls', '?')} call{'s' if h.get('calls') != 1 else ''}"
            if h.get("holes", 1) > 1:
                ht += f", {h.get('holes_filled', 0)}/{h['holes']} holes"
            ht += ")" if h.get("visible_ok") or not h else ", visible tests not met)"
        rows.append(f"| {tid} | {yn(d1.get('pass_'))}{'' if d1.get('check_ok') else ' (no compile)'} | {ht} | "
                    f"{yn(p1.get('pass_'))}{'' if p1.get('check_ok') else ' (syntax)'} | "
                    f"{dt['code'] if dt else '-'} ({dt['raw'] if dt else '-'}) | {pt['code'] if pt else '-'} ({pt['raw'] if pt else '-'}) | "
                    f"{dref['code']} / {pref['code']} |")
        r.setdefault("tokens", {})
        r["tokens"] = {"auk1": dt, "py1": pt, "auk_ref": dref, "py_ref": pref}
    mean = lambda xs: sum(xs) / len(xs) if xs else float("nan")
    md = [f"# Run {os.path.basename(out)}", "",
          f"Model `{info['model']}`, auk binary sha256 `{info['auk_sha256'][:16]}…`, started {info['started']}, finished {info.get('finished')}.", "",
          "| task | Auk one-shot | Auk + hatch (model calls) | Python one-shot | Auk tokens code (raw) | Python tokens code (raw) | reference tokens Auk / Py |",
          "|---|---|---|---|---|---|---|", *rows, "",
          "## Totals", "",
          f"- Auk one-shot pass@1: **{tot['auk1']}/{n}** (compiles: {tot['auk1_check']}/{n})",
          f"- Auk with hatch (<=3 tries per hole), hidden tests: **{tot['hatch']}/{n}** (visible tests met: {tot['hatch_vis']}/{n}; model calls: {sum(hatch_calls)}, mean {mean(hatch_calls):.2f} per task)",
          f"- Python one-shot pass@1: **{tot['py1']}/{n}** (syntax ok: {tot['py1_check']}/{n})",
          f"- Mean one-shot solution tokens (o200k, comments/docstrings/blank lines removed), over the {len(tk['auk'])} tasks with both: "
          f"Auk **{mean(tk['auk']):.1f}**, Python **{mean(tk['py']):.1f}** (Auk/Python = {sum(tk['auk']) / max(1, sum(tk['py'])):.3f})",
          f"- Reference solutions (mine), same measure: Auk {mean(tk['auk_ref']):.1f}, Python {mean(tk['py_ref']):.1f} (Auk/Python = {sum(tk['auk_ref']) / sum(tk['py_ref']):.3f})",
          f"- Mean model output tokens per one-shot call (API usage, incl. any prose): Auk {mean(out_tok['auk1']):.1f}, Python {mean(out_tok['py1']):.1f}",
          ""]
    write(os.path.join(out, "report.md"), "\n".join(md))
    write(os.path.join(out, "results.json"), json.dumps({"info": info, "results": res}, indent=2))
    print("\n".join(md))


if __name__ == "__main__":
    main()

"""Check every task: the reference solutions pass all tests in both languages, and the
hatch file (given + stub + visible tests) type-checks with its holes.
Usage: python3 -I bench/harness/verify.py [task-id...]"""
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import *  # noqa

ok = True
tmp = tempfile.mkdtemp(prefix="duck-bench-verify-")
for tid in (sys.argv[1:] or task_ids()):
    t = task(tid)
    d = os.path.join(tmp, tid)
    write(f"{d}/ref.duck", duck_program(t, t["duck_ref"]))
    write(f"{d}/hatch.duck", duck_hatch_file(t))
    write(f"{d}/ref.py", py_program(t, t["py_ref"]))
    rd, od = duck_test(f"{d}/ref.duck")
    rh, oh = duck_check(f"{d}/hatch.duck")
    rp, op = py_test(f"{d}/ref.py")
    # sanity: the tests must FAIL against the unimplemented stubs
    write(f"{d}/stub.duck", duck_program(t, t["duck_stub"]))
    write(f"{d}/stub.py", py_program(t, t["py_stub"]))
    sd, _ = duck_test(f"{d}/stub.duck")
    sp, _ = py_test(f"{d}/stub.py")
    if sd == 0 or sp == 0:
        print(f"{tid}: tests pass against the stub (duck={sd == 0}, py={sp == 0})")
        ok = False
    status = "ok" if rd == 0 and rh == 0 and rp == 0 else "FAIL"
    if status != "ok":
        ok = False
    print(f"{tid:24} duck-ref:{'ok' if rd == 0 else 'FAIL'} hatch-file:{'ok' if rh == 0 else 'FAIL'} py-ref:{'ok' if rp == 0 else 'FAIL'}")
    for code, out in ((rd, od), (rh, oh), (rp, op)):
        if code != 0:
            print("    " + out.strip().replace("\n", "\n    "))
sys.exit(0 if ok else 1)
